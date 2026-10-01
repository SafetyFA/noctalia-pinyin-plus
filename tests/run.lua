-- tests/run.lua —— 本地验证 provider.luau 的索引与匹配逻辑（stub 掉 noctalia / launcher）
-- 用法：lua5.4 tests/run.lua

local HERE = (arg and arg[0] or "tests/run.lua"):match("^(.*)/[^/]+$") or "."
local PLUGIN = HERE .. "/.."
local HOME = os.getenv("HOME") or ""
local BIN_SRC = HOME .. "/.local/share/noctalia/plugins/pinyin-search/pinyin-data.bin"
local BIN_LOCAL = PLUGIN .. "/pinyin-data.bin"

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

do -- 数据文件准备
  local f = io.open(BIN_LOCAL, "rb")
  if f then
    f:close()
  else
    local src = readAll(BIN_SRC)
    if src then
      local dst = io.open(BIN_LOCAL, "wb")
      dst:write(src)
      dst:close()
      print("[test] copied pinyin-data.bin from pinyin-search")
    else
      print("[test] WARN: pinyin-data.bin 未找到，拼音匹配会退化")
    end
  end
end

-- lua5.4 没有 bit32（Luau 有），测试时补一个垫片（注意 band/bor 必须是变参！）
if not bit32 then
  bit32 = {
    band = function(...)
      local r = -1
      for _, v in ipairs({ ... }) do r = r & v end
      return r
    end,
    bor = function(...)
      local r = 0
      for _, v in ipairs({ ... }) do r = r | v end
      return r
    end,
    lshift = function(a, b) return a << b end,
  }
end

local captured, logLines = {}, {}

noctalia = {
  getenv = function(k) return os.getenv(k) end,
  readFile = function(p)
    local mapped = p:gsub("^.*/plugins/pinyin%-plus/", PLUGIN .. "/")
    return readAll(mapped)
  end,
  listDir = function(dir)
    -- 模拟生产行为：目录不存在返回 nil
    local probe = io.popen("test -d '" .. dir:gsub("'", "'\\''") .. "' && echo yes")
    local exists = probe:read("l") == "yes"
    probe:close()
    if not exists then return nil end
    local out = {}
    local p = io.popen("ls -1 '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
    if not p then return out end
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
  end,
  log = function(m) logLines[#logLines + 1] = m end,
  nowMs = function() return os.time() * 1000 end,
  json = { encode = function() return "{}" end, decode = function() return {} end },
  writeFile = function() return true end,
  runAsync = function(cmd, cb) if cb then cb({ stdout = "" }) end return true end,
  commandExists = function() return false end,
}
launcher = { setResults = function(q, rows) captured[q] = rows end }

require = function(path)
  if path:sub(1, 2) == "./" then
    local chunk = assert(loadfile(PLUGIN .. "/" .. path:sub(3)))
    return chunk()
  end
  return nil
end

assert(loadfile(PLUGIN .. "/provider.luau"))()

-- 顺便打印索引里所有中文名应用，便于挑测试词（onIpc("dump-index") 会把索引写进日志）
logLines = {}
onIpc("dump-index", nil)
print("--- 索引中的中文名应用（前 25 个）---")
local shown = 0
for _, l in ipairs(logLines) do
  if l:find("[\228-\233]") then
    print("    " .. l:gsub("^PinyinPlus: ", ""))
    shown = shown + 1
    if shown >= 25 then break end
  end
end

print()
print("--- 查询结果 ---")
local queries = { "wx", "weixin", "wechat", "qq", "rwzx", "renwuzhongxin", "renwu", "任务", "任务中心", "rw", "yinliang", "ylkz", "音量", "ddqd", "dida", "滴答", "微信" }
for _, extra in ipairs(arg or {}) do queries[#queries + 1] = extra end
for _, q in ipairs(queries) do
  captured[q] = nil
  onQuery(q)
  local rows = captured[q] or {}
  print(string.format("查询 %-16s → %d 条", q, #rows))
  for i, r in ipairs(rows) do
    print(string.format("      %d. %-18s | %s", i, r.title, r.subtitle or ""))
  end
end

print()
print("--- explain wx ---")
logLines = {}
onIpc("explain", "wx")
for _, l in ipairs(logLines) do print("    " .. l) end
