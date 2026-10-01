-- tests/bin-probe.lua —— 对比 Lua 与 python 对 pinyin-data.bin 的解码中间值
if not bit32 then
  bit32 = {
    band = function(...) local r = -1; for _, v in ipairs({...}) do r = r & v end; return r end,
    bor = function(...) local r = 0; for _, v in ipairs({...}) do r = r | v end; return r end,
    lshift = function(a, b) return a << b end,
  }
end

local START, SIZE = 0x4E00, 20992
local path = (os.getenv("HOME") or "") .. "/.local/share/noctalia/plugins/pinyin-search/pinyin-data.bin"
local f = assert(io.open(path, "rb"))
local data = f:read("a")
f:close()

print(string.format("file size=%d  #data=%d", #data, #data))
print(string.format("initials[0]=%d initials[1]=%d", data:byte(1), data:byte(2)))

local band, bor, lshift = bit32.band, bit32.bor, bit32.lshift

local function codepoint(ch)
  local c = ch:byte()
  local b2, b3 = ch:byte(2), ch:byte(3)
  if c >= 0x80 and b2 and b3 then
    c = bor(lshift(band(c, 0x0F), 12), lshift(band(b2, 0x3F), 6), band(b3, 0x3F))
  end
  return c
end

local function syllable(ch)
  local idx = codepoint(ch) - START
  if idx < 0 or idx >= SIZE then return "<oob>" end
  local offPos = SIZE + idx * 2 + 1
  local off = bor(data:byte(offPos), lshift(data:byte(offPos + 1), 8))
  local nextOff = idx < SIZE - 1
      and bor(data:byte(offPos + 2), lshift(data:byte(offPos + 3), 8))
      or (#data - off)
  local dataStart = SIZE + SIZE * 2 + 1
  if off == nextOff then return "" end
  return data:sub(dataStart + off, dataStart + nextOff - 1)
end

for _, ch in ipairs({ "微", "信", "滴", "答", "清", "单" }) do
  local cp = codepoint(ch)
  local idx = cp - START
  local offPos = SIZE + idx * 2 + 1
  print(string.format("%s U+%04X idx=%d offPos=%d off=%d next=%d -> %q",
    ch, cp, idx, offPos,
    bor(data:byte(offPos), lshift(data:byte(offPos + 1), 8)),
    bor(data:byte(offPos + 2), lshift(data:byte(offPos + 3), 8)),
    syllable(ch)))
end
