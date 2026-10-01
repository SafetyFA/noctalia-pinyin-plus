-- provider.luau —— Pinyin Plus：Listary 风格的中文应用搜索（Noctalia launcher provider）
--
-- 设计要点
--   1. 运行时索引：直接从 XDG applications 目录读 .desktop，不需要 python、不需要预生成数据
--   2. 按 XDG 优先级去重（用户级覆盖系统级）→ 每个应用最多产出 1 行
--   3. 只补内置 Applications provider 搜不到的结果（名称/关键字/英文名能直接命中的交给它）
--      → 因此不会再出现"一个应用两行/三行"
--   4. 匹配：全拼 / 首字母 / 紧凑子序列 / 描述 / 可执行名，并按使用频率加权
--
-- 调参都在下面的常量里；保存本文件即热重载

local pinyin = require("./pinyin.luau")

-- ───────────────────────────── 可调参数 ─────────────────────────────
local MAX_RESULTS = 12            -- 最多返回几条结果
local INDEX_TTL_MS = 60 * 1000    -- 索引缓存时间（新装应用后最迟 1 分钟生效）
local USAGE_WEIGHT = 8            -- 每次使用加分
local USAGE_CAP = 400             -- 使用频率加分上限
-- 同时吃 noctalia 自己的使用统计（按 .desktop 条目 id 汇总），这样你以前从启动器启动的次数也算数
local USE_NOCTALIA_USAGE = true
local EXTERNAL_USAGE_TTL_MS = 30000
local SHOW_PINYIN_IN_SUBTITLE = true
-- 把命中的拼音也写进标题（例："微信 (weixin)"）——宿主自己的模糊匹配更容易给高分，
-- 若插件结果总是排在内置模糊匹配之后，可以把它打开
local PINYIN_IN_TITLE = false
-- 子序列最多允许几个"跳过的字"：越小越严格，避免 qq/wx 这种短查询带出噪音
local MAX_SUBSEQ_GAPS = 2
-- 最短的纯首字母查询长度（1 个字母太容易命中，交给子序列规则去管）
local MIN_INITIALS_LEN = 2
-- 子序列匹配的最短查询长度（2 个字母做子序列太容易误伤）
local MIN_SUBSEQ_LEN = 3
-- 描述/可执行名/图标这类"弱匹配"的最短查询长度
local MIN_WEAK_LEN = 3
-- 字幕里描述文字的最大长度（滴答清单这类超长描述会被截断）
local MAX_SUBTITLE = 64
-- 分片构建索引（Luau 回调有 CPU 预算，冷启动时更紧）
local BUILD_CHUNK = 4              -- 每次回调处理多少个 .desktop
local BUILD_YIELD = "sleep 0.05"   -- 让出时执行的最小命令，给 shell 喘息时间
local BUILD_STALE_MS = 15000       -- 超过这么久没有推进就认为构建链断了（自适应重试）
-- 名称/GenericName/Keywords 能直接命中的查询交给内置 provider（避免重复行）
local DEFER_SUBSTRING_TO_BUILTIN = true
-- 纯 ASCII 查询对纯 ASCII 名称的子序列匹配也交给内置（内置是模糊匹配，避免重复行）
local DEFER_ASCII_FUZZY_TO_BUILTIN = true
-- ────────────────────────────────────────────────────────────────────

local home = noctalia.getenv("HOME") or ""
local USAGE_DIR = home .. "/.local/state/noctalia"
local USAGE_FILE = USAGE_DIR .. "/pinyin-plus-usage.json"
local EXTERNAL_USAGE_FILE = USAGE_DIR .. "/usage_counts.json"

-- ───────────────────────────── 小工具 ─────────────────────────────
local function split(s, sep)
  local out = {}
  for part in (s or ""):gmatch("([^" .. sep .. "]+)") do out[#out + 1] = part end
  return out
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function shellQuote(s)
  return "'" .. (s or ""):gsub("'", "'\\''") .. "'"
end

local function basename(p)
  return (p or ""):match("([^/]+)$") or ""
end

local function lower(s)
  return (s or ""):lower()
end

-- 归一化查询：小写 + 去掉空白/常见分隔符（Listary 里 "wei xin" == "weixin"）
local function normalizeQuery(s)
  return (lower(trim(s)):gsub("[%s_%-%.]+", ""))
end

-- 紧凑子序列匹配：返回 跳过字数, 起始位置；不匹配或过于松散返回 nil
local function subseqInfo(needle, hay)
  if needle == "" or hay == "" or #needle > #hay then return nil end
  local i, j, gaps, start = 1, 1, 0, nil
  while i <= #needle and j <= #hay do
    if needle:sub(i, i) == hay:sub(j, j) then
      if not start then start = j end
      i = i + 1
    elseif start then
      gaps = gaps + 1
    end
    j = j + 1
  end
  if i <= #needle then return nil end
  return gaps, (start or 1)
end

local function execBaseName(exec)
  local first = exec:match("^%s*(%S+)")
  if not first then return "" end
  if first == "env" then
    local rest = exec:gsub("^%s*env%s+", "")
    for tok in rest:gmatch("%S+") do
      if not tok:match("^[%w_]+=") then return basename(tok) end
    end
    return ""
  end
  return basename(first)
end

-- ───────────────────────── .desktop 解析与索引 ─────────────────────────
local function desktopDirs()
  local out, seen = {}, {}
  local function add(p)
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  add((noctalia.getenv("XDG_DATA_HOME") or (home .. "/.local/share")) .. "/applications")
  for _, d in ipairs(split(noctalia.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share", ":")) do
    add(d .. "/applications")
  end
  return out
end

local function parseDesktop(content)
  local e = {}
  local inMain = false
  for line in (content or ""):gmatch("[^\r\n]+") do
    local t = trim(line)
    if t == "[Desktop Entry]" then
      inMain = true
    elseif t:sub(1, 1) == "[" then
      inMain = false
    elseif inMain and t ~= "" and t:sub(1, 1) ~= "#" then
      -- 注意键名可能含下划线（Name[zh_CN]）和方括号
      local k, v = t:match("^(%w[%w_%-%[%]]*)%s*=%s*(.-)%s*$")
      if k and v and e[k] == nil then e[k] = v end
    end
  end
  return e
end

local function shownInCurrentDesktop(e)
  local desktops = split(noctalia.getenv("XDG_CURRENT_DESKTOP") or "", ":")
  desktops[#desktops + 1] = noctalia.getenv("XDG_SESSION_DESKTOP") or ""
  local function listed(list)
    for _, item in ipairs(split(list, ";")) do
      for _, d in ipairs(desktops) do
        if d ~= "" and item == d then return true end
      end
    end
    return false
  end
  if e.OnlyShowIn and e.OnlyShowIn ~= "" and not listed(e.OnlyShowIn) then return false end
  if e.NotShowIn and e.NotShowIn ~= "" and listed(e.NotShowIn) then return false end
  return true
end

local index, byId, builtAt = {}, {}, 0
local buildJob = nil

local retryChunk = BUILD_CHUNK

-- 让出一次回调（Luau 回调有 CPU 预算，长任务必须分片）
local function yieldToNextChunk(fn)
  noctalia.runAsync(BUILD_YIELD, fn)
end

local function finishBuild(job)
  index = job.apps
  byId = {}
  for _, app in ipairs(index) do byId[app.id] = app end
  builtAt = noctalia.nowMs()
  buildJob = nil
  noctalia.log(string.format("PinyinPlus: indexed %d apps", #index))
end

local function buildStep()
  local job = buildJob
  if not job then return end
  local processed = 0
  local chunk = job.chunk or BUILD_CHUNK
  while processed < chunk do
    if not job.names then
      local dir = job.dirs[job.dirIndex]
      if not dir then
        finishBuild(job)
        return
      end
      job.dir = dir
      job.names = noctalia.listDir(dir) or {}
      job.nameIndex = 1
      job.dirIndex = job.dirIndex + 1
    end
    local name = job.names[job.nameIndex]
    job.nameIndex = job.nameIndex + 1
    if name == nil then
      job.names = nil
    elseif name:sub(-8) == ".desktop" then
      local id = name:sub(1, -9)
      if not job.ids[id] then -- XDG 优先级：先扫到的（用户级）胜出
        local e = parseDesktop(noctalia.readFile(job.dir .. "/" .. name))
        if e.Type == "Application"
            and e.Exec and e.Exec ~= ""
            and e.NoDisplay ~= "true"
            and e.Hidden ~= "true"
            and shownInCurrentDesktop(e) then
          job.ids[id] = true
          local exec = trim((e.Exec or ""):gsub("%%[fFuUdDnNickvm]", ""))
          local displayName = e["Name[zh_CN]"] or e["Name[zh_TW]"] or e.Name or id
          local plainName = e.Name or ""
          -- 只对含中文的名字算拼音（省时间，也让分片更小）
          local full, ini = "", ""
          if displayName:find("[\228-\233]") then full, ini = pinyin.forms(displayName) end
          local fullAlt, iniAlt = "", ""
          if plainName ~= "" and plainName ~= displayName and plainName:find("[\228-\233]") then
            fullAlt, iniAlt = pinyin.forms(plainName)
            if fullAlt == full and iniAlt == ini then fullAlt, iniAlt = "", "" end
          end
          local generic = e["GenericName[zh_CN]"] or e.GenericName or ""
          job.apps[#job.apps + 1] = {
            id = id,
            name = displayName,
            nameLower = lower(displayName),
            plainLower = lower(plainName),
            full = full,
            initials = ini,
            fullAlt = fullAlt,
            initialsAlt = iniAlt,
            generic = generic,
            genericLower = lower(generic),
            keywordsLower = lower((e.Keywords or "") .. ";" .. (e["Keywords[zh_CN]"] or "")),
            comment = e["Comment[zh_CN]"] or e.Comment or "",
            exec = exec,
            execBase = lower(execBaseName(exec)),
            icon = e.Icon or "",
            terminal = e.Terminal == "true",
          }
        end
      end
      processed = processed + 1
    end
  end
  job.startedAt = noctalia.nowMs()   -- 每推进一片就续期，只有"卡住"才会被看门狗判定为断链
  yieldToNextChunk(buildStep)
end

-- 分片重建索引：先单独一片读拼音表，再逐批解析 .desktop
local function buildIndex()
  buildJob = {
    dirs = desktopDirs(),
    dirIndex = 1,
    names = nil,
    nameIndex = 1,
    apps = {},
    ids = {},
    chunk = retryChunk,
    startedAt = noctalia.nowMs(),
  }
  noctalia.log(string.format("PinyinPlus: building index (chunk=%d)", retryChunk))
  yieldToNextChunk(function()
    pinyin.preload()
    yieldToNextChunk(buildStep)   -- 读表单独占一片，避免和解析挤在一起
  end)
end

-- 看门狗：构建链若被 CPU 预算打断，会自动以更小的分片重试（避免索引永远为空）
local function refreshIndexIfStale()
  local now = noctalia.nowMs()
  local job = buildJob
  if job then
    if (now - (job.startedAt or now)) > BUILD_STALE_MS then
      retryChunk = math.max(2, math.floor((job.chunk or BUILD_CHUNK) / 2))
      noctalia.log(string.format("PinyinPlus: index build stalled, retrying with chunk=%d", retryChunk))
      buildJob = nil
    else
      return
    end
  end
  if #index == 0 or (now - builtAt) > INDEX_TTL_MS then buildIndex() end
end

-- ───────────────────────────── 使用频率 ─────────────────────────────
local usage = nil

local function loadUsage()
  if usage then return end
  usage = {}
  local raw = noctalia.readFile(USAGE_FILE)
  if type(raw) == "string" and raw ~= "" then
    local ok, decoded = pcall(noctalia.json.decode, raw)
    if ok and type(decoded) == "table" then usage = decoded end
  end
end

local function bumpUsage(id)
  loadUsage()
  usage[id] = (usage[id] or 0) + 1
  noctalia.runAsync("mkdir -p " .. shellQuote(USAGE_DIR))
  noctalia.writeFile(USAGE_FILE, noctalia.json.encode(usage) or "{}")
end

-- noctalia 自己的统计（~/.local/state/noctalia/usage_counts.json），形如
--   { "Applications": { "/path/to/wechat.desktop": 16, ... } }
-- 按条目 id（文件名去掉 .desktop）汇总，这样用户级/系统级两条路径的次数会合并
local externalUsage, externalLoadedAt = {}, 0

local function entryIdFromPath(path)
  local base = tostring(path):match("([^/]+)$") or ""
  return (base:gsub("%.desktop$", ""))
end

local function loadExternalUsage()
  externalUsage = {}
  local raw = noctalia.readFile(EXTERNAL_USAGE_FILE)
  if type(raw) == "string" and raw ~= "" then
    local ok, decoded = pcall(noctalia.json.decode, raw)
    if ok and type(decoded) == "table" then
      local apps = decoded.Applications or decoded.applications or {}
      for path, count in pairs(apps) do
        if type(count) == "number" then
          local id = entryIdFromPath(path)
          if id ~= "" then externalUsage[id] = (externalUsage[id] or 0) + count end
        end
      end
    end
  end
  externalLoadedAt = noctalia.nowMs()
end

local function effectiveUsage(id)
  loadUsage()
  if USE_NOCTALIA_USAGE then
    if (noctalia.nowMs() - externalLoadedAt) > EXTERNAL_USAGE_TTL_MS then loadExternalUsage() end
    return (usage[id] or 0) + (externalUsage[id] or 0)
  end
  return usage[id] or 0
end

-- ───────────────────────────── 匹配打分 ─────────────────────────────
-- 单个拼音串（全拼 + 首字母）的打分；返回 分数, 命中标记（用于字幕）
local function scoreForm(q, full, ini)
  local n = #q
  if full ~= "" and full == q then return 1200, full end
  if ini ~= "" and n >= MIN_INITIALS_LEN and ini == q then return 1180, full ~= "" and full or ini end
  if full ~= "" and full:sub(1, n) == q then return 1120 - math.min(#full, 40), full end
  if ini ~= "" and n >= MIN_INITIALS_LEN and ini:sub(1, n) == q then
    return 1100 - math.min(#ini, 40), full ~= "" and full or ini
  end
  if full ~= "" and n >= 3 and full:find(q, 1, true) then return 1000 - (#full - n), full end
  if ini ~= "" and n >= 3 and ini:find(q, 1, true) then return 980 - (#ini - n), full ~= "" and full or ini end
  if n >= MIN_SUBSEQ_LEN then
    local gaps, start = subseqInfo(q, full)
    if gaps and gaps <= MAX_SUBSEQ_GAPS then
      return 900 - gaps * 6 - math.min(start, 20), full
    end
    local gi, si = subseqInfo(q, ini)
    if gi and gi <= MAX_SUBSEQ_GAPS then
      return 880 - gi * 6 - math.min(si, 20), full ~= "" and full or ini
    end
  end
  return nil
end

local function scoreFor(app, q, rawQuery, isPrimary)
  local n = #q
  if n == 0 then return nil end
  local rq = rawQuery or q

  -- 内置 provider 能直接命中的 → 让给它，避免重复行（用原始查询判断）
  if DEFER_SUBSTRING_TO_BUILTIN then
    if app.nameLower:find(rq, 1, true) then return nil end
    if app.plainLower ~= "" and app.plainLower:find(rq, 1, true) then return nil end
    if app.genericLower ~= "" and app.genericLower:find(rq, 1, true) then return nil end
    if app.keywordsLower ~= "" and app.keywordsLower:find(rq, 1, true) then return nil end
  end
  if DEFER_ASCII_FUZZY_TO_BUILTIN
      and q:match("^[%w]+$")
      and app.plainLower ~= ""
      and app.plainLower:match("^[%w%s%-%._]+$") then
    local gaps = subseqInfo(q, app.plainLower:gsub("[%s%-%._]", ""))
    if gaps and gaps <= MAX_SUBSEQ_GAPS then return nil end
  end

  local best, marker
  local s1, m1 = scoreForm(q, app.full, app.initials)
  if s1 then best, marker = s1, m1 end
  local s2 = scoreForm(q, app.fullAlt, app.initialsAlt)
  if s2 and (not best or s2 > best) then best, marker = s2, nil end
  if best then return best, marker or "" end

  -- 描述 / 可执行名 / 图标：只对用户实际输入的查询生效，且不能太短
  if isPrimary and n >= MIN_WEAK_LEN then
    if app.comment ~= "" and lower(app.comment):find(q, 1, true) then return 700, "" end
    if app.execBase ~= "" and app.execBase:find(q, 1, true) then return 640, "" end
    local gi, si = subseqInfo(q, app.execBase)
    if gi and gi <= MAX_SUBSEQ_GAPS and si == 1 then return 600, "" end
    if app.icon ~= "" and lower(app.icon):find(q, 1, true) then return 520, "" end
  end
  return nil
end

-- 查询变体：原始查询，以及（仅当查询含中文时）它自己的全拼/首字母
-- 注意：ASCII 查询不能派生变体，否则 "wx" 会拆出单字母 "w" 命中一大片
local function queryVariants(text)
  local q = normalizeQuery(text)
  local variants = {}
  if q ~= "" then variants[#variants + 1] = q end
  if text:find("[\228-\233]") then
    local f, i = pinyin.forms(text)
    local fq = (f or ""):gsub("[%s_%-%.]+", "")
    local iq = (i or ""):gsub("[%s_%-%.]+", "")
    if fq ~= "" and fq ~= q then variants[#variants + 1] = fq end
    if iq ~= "" and iq ~= fq and iq ~= q then variants[#variants + 1] = iq end
  end
  return variants
end

-- ───────────────────────────── launcher 入口 ─────────────────────────────
function onQuery(text)
  -- 空查询也要检查索引是否过期：这样"一打开启动器"就会后台重建，新装的中文应用最迟 60 秒内可搜
  refreshIndexIfStale()
  local variants = queryVariants(text)
  if #variants == 0 then
    launcher.setResults(text, {})
    return
  end
  loadUsage()
  local rawQuery = variants[1]

  local scored = {}
  for _, app in ipairs(index) do
    local s, marker
    for vi, q in ipairs(variants) do
      local sc, mk = scoreFor(app, q, rawQuery, vi == 1)
      if sc and (not s or sc > s) then s, marker = sc, mk end
    end
    if s then
      s = s + math.min(effectiveUsage(app.id) * USAGE_WEIGHT, USAGE_CAP)
      scored[#scored + 1] = { app = app, score = s, marker = marker or "" }
    end
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if #a.app.name ~= #b.app.name then return #a.app.name < #b.app.name end
    return a.app.name < b.app.name
  end)

  local rows = {}
  for i = 1, math.min(#scored, MAX_RESULTS) do
    local item = scored[i]
    local app = item.app
    local desc = app.comment ~= "" and app.comment or app.generic
    if #desc > MAX_SUBTITLE then desc = desc:sub(1, MAX_SUBTITLE - 1) .. "…" end
    local subtitle = desc
    if SHOW_PINYIN_IN_SUBTITLE and item.marker ~= "" then
      subtitle = desc ~= "" and (item.marker .. "  ·  " .. desc) or item.marker
    end
    local title = app.name
    if PINYIN_IN_TITLE and item.marker ~= "" then
      -- 直接把用户输入的字母放进标题：宿主若按标题/名称算模糊分，这就是"字面包含"，分数最高
      local tag = normalizeQuery(text)
      if tag == "" then tag = item.marker end
      title = app.name .. " (" .. tag .. ")"
    end
    rows[#rows + 1] = {
      id = app.id,
      name = title,           -- 有的宿主版本读 name，有的读 title，两个都给
      title = title,
      subtitle = subtitle,
      icon = app.icon,
      score = item.score,     -- 宿主支持的话就能参与跨 provider 排序
    }
  end
  launcher.setResults(text, rows)
end

function onActivate(id)
  local app = byId[id]
  if not app or app.exec == "" then return end
  bumpUsage(id)

  local cmd = app.exec
  if app.terminal then
    local term = noctalia.getenv("TERMINAL")
    if not term or term == "" then
      for _, candidate in ipairs({ "kitty", "foot", "wezterm", "ghostty", "alacritty", "konsole", "xterm" }) do
        if noctalia.commandExists(candidate) then
          term = candidate
          break
        end
      end
    end
    if term and term ~= "" then cmd = term .. " -e " .. cmd end
  end

  -- setsid -f：与 noctalia 分离，避免阻塞 shell / 关掉启动器时被带走
  noctalia.runAsync("setsid -f sh -c " .. shellQuote(cmd) .. " >/dev/null 2>&1")
end

-- 维护用 IPC：rebuild=重建索引，dump-index=把索引写进日志
function onIpc(event, _payload)
  if event == "rebuild" or event == "refresh-index" then
    buildIndex()
    return true
  end
  if event == "explain" and _payload then
    local variants = queryVariants(tostring(_payload))
    noctalia.log("PinyinPlus explain: variants=[" .. table.concat(variants, ",") .. "]")
    for _, app in ipairs(index) do
      local best, mk
      for vi, q in ipairs(variants) do
        local sc, m = scoreFor(app, q, variants[1], vi == 1)
        if sc and (not best or sc > best) then best, mk = sc, m end
      end
      if best then
        noctalia.log(string.format("PinyinPlus explain: %-28s score=%-6s marker=%-16s full=%-26s ini=%-12s alt=%s/%s comment=%s",
          app.name, tostring(best), tostring(mk), app.full, app.initials, app.fullAlt, app.initialsAlt, app.comment))
      end
    end
    return true
  end
  if event == "dump-index" then
    for _, app in ipairs(index) do
      noctalia.log(string.format("PinyinPlus: %s | pinyin=%s | initials=%s | exec=%s",
        app.name, app.full, app.initials, app.exec))
    end
    return true
  end
  return false
end

function onExit(_signal, _reason)
  if usage then
    noctalia.writeFile(USAGE_FILE, noctalia.json.encode(usage) or "{}")
  end
end

-- 顶层代码在入口加载时执行一次：只做最轻的事，重建索引走分片
loadUsage()
buildIndex()
