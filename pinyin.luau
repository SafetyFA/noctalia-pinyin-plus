-- pinyin.luau —— 汉字 -> 拼音 查表（复用 pinyin-data.bin 紧凑格式）
-- 数据布局（pinyin-data.bin）：
--   [0, SIZE)              : 每字首字母（字节值 + 'a'，0 表示未知）
--   [SIZE, SIZE*2)         : 每字全拼在数据区的起始偏移（uint16 little-endian）
--   [SIZE*2, ...)          : 全拼字符串数据区
local START = 0x4E00
local SIZE = 20992

local home = noctalia.getenv("HOME") or ""
local DATA_FILE = home .. "/.local/share/noctalia/plugins/pinyin-plus/pinyin-data.bin"

local M = {}

-- 惰性读取：模块加载时不做任何重活（Luau 回调有 CPU 预算）
local data, loaded = "", false

local function ensureData()
  if not loaded then
    loaded = true
    data = noctalia.readFile(DATA_FILE) or ""
  end
  return #data > 0
end

-- 让宿主可以单独安排一次"读表"回调
function M.preload()
  return ensureData()
end

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift

-- UTF-8 逐字迭代
local function utf8chars(s)
  local i = 1
  return function()
    if i > #s then return nil end
    local b = s:byte(i)
    local len = 1
    if b >= 0xF0 then len = 4 elseif b >= 0xE0 then len = 3 elseif b >= 0xC0 then len = 2 end
    local ch = s:sub(i, i + len - 1)
    i = i + len
    return ch
  end
end

local function codepoint(ch)
  local code = ch:byte()
  if not code then return 0 end
  if code >= 0x80 then
    local b2 = ch:byte(2)
    local b3 = ch:byte(3)
    if b2 and b3 then
      code = bor(lshift(band(code, 0x0F), 12), lshift(band(b2, 0x3F), 6), band(b3, 0x3F))
    end
  end
  return code
end

-- 单字首字母（非汉字原样返回）
function M.initial(ch)
  if not ensureData() then return ch end
  local idx = codepoint(ch) - START
  if idx < 0 or idx >= SIZE then return ch end
  local b = string.byte(data, idx + 1)
  if b == 0 then return ch end
  return string.char(b + 96)
end

-- 单字全拼（非汉字/未知原样返回）
function M.syllable(ch)
  if not ensureData() then return ch end
  local idx = codepoint(ch) - START
  if idx < 0 or idx >= SIZE then return ch end
  local offPos = SIZE + idx * 2 + 1
  local off = bor(string.byte(data, offPos), lshift(string.byte(data, offPos + 1), 8))
  local nextOff = idx < SIZE - 1
      and bor(string.byte(data, offPos + 2), lshift(string.byte(data, offPos + 3), 8))
      or (#data - off)
  if off == nextOff then return ch end
  local dataStart = SIZE + SIZE * 2 + 1
  return string.sub(data, dataStart + off, dataStart + nextOff - 1)
end

-- 文本 -> (全拼, 首字母)
--   "任务中心"            -> "renwuzhongxin", "rwzx"
--   "微信 WeChat"         -> "weixinwechat",  "wxw"
--   "Mission Center"      -> "missioncenter", "mc"
function M.forms(text)
  local full, ini, word = {}, {}, {}
  local function flush()
    if #word > 0 then
      local w = table.concat(word)
      full[#full + 1] = w
      ini[#ini + 1] = w:sub(1, 1)
      word = {}
    end
  end
  for ch in utf8chars(text) do
    local code = ch:byte()
    if code and code < 0x80 then
      if ch:match("[%w]") then
        word[#word + 1] = ch:lower()
      else
        flush()
      end
    else
      flush()
      local syl = M.syllable(ch)
      if syl ~= ch and syl ~= "" then
        full[#full + 1] = syl:lower()
        ini[#ini + 1] = syl:sub(1, 1):lower()
      end
    end
  end
  flush()
  return table.concat(full), table.concat(ini)
end

return M
