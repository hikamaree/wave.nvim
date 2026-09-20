-- Precise rendering test using the actual wave render painters.
-- Usage: nvim --headless -u NONE -l tests/test_render.lua

package.path = package.path .. ";./lua/?.lua"

local TimeScale = require("wave.model.time_scale")
local SingleBit = require("wave.render.single_bit")
local MultiBit = require("wave.render.multi_bit")
local Ruler = require("wave.render.ruler")
local ValueTable = require("wave.render.value_table")


local EPS = 1e-12

local function utf8_chars(str)
  local chars = {}
  local i = 1
  while i <= #str do
    local b = str:byte(i)
    local len = b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4
    table.insert(chars, str:sub(i, i + len - 1))
    i = i + len
  end
  return chars
end

local function gen_clk_vc()
  local vc = {}
  local val = "0"
  for t = 0, 200, 20 do
    table.insert(vc, {t, val})
    val = val == "0" and "1" or "0"
  end
  for t = 201, 600, 1 do
    table.insert(vc, {t, val})
    val = val == "0" and "1" or "0"
  end
  for t = 620, 800, 20 do
    table.insert(vc, {t, val})
    val = val == "0" and "1" or "0"
  end
  return vc
end

local function gen_multi_vc()
  local vc = {}
  -- constant b1010 throughout
  for t = 0, 1000, 100 do
    table.insert(vc, {t, "b1010"})
  end
  return vc
end

local function gen_multi_transition_vc()
  local vc = {}
  -- starts at b1010, transitions to b0101
  table.insert(vc, {0, "b1010"})
  table.insert(vc, {500, "b0101"})
  return vc
end

local VALID = {}
for _, c in ipairs({"─","┌","┐","└","┘","┬","┴","╷","╵"," "}) do VALID[c] = true end

local MB_VALID = {}
for _, c in ipairs({"─","┌","┐","└","┘","┬","┴"," ","0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f","x","z"}) do MB_VALID[c] = true end

local function find_glitches(top, bot, label, width, time_start, time_end)
  local tchars = utf8_chars(top)
  local bchars = utf8_chars(bot)
  local glitches = {}

  for i = 1, #tchars do
    local col = i - 1
    local tc = tchars[i]
    local bc = bchars[i]

    if not VALID[tc] then
      table.insert(glitches, string.format("col %d: INVALID top char byte=0x%02X", col, tc:byte()))
    end
    if not VALID[bc] then
      table.insert(glitches, string.format("col %d: INVALID bot char byte=0x%02X", col, bc:byte()))
    end

    -- Both spaces in a column with signal activity (shouldn't ever happen with current logic)
    if tc == " " and bc == " " then
      table.insert(glitches, string.format("col %d: both lines blank", col))
    end

    -- ┴┴ or ┬┬ adjacent in NOISE region: expected.
    -- Previously had noise-boundary mismatch checks here, but they produced
    -- false positives at noise-to-clean transitions with the actual module renderer.
  end

  return glitches
end

local function show_zoom(vc, time_start, time_end, width, label)
  local top, bot = SingleBit.paint(vc, TimeScale.new(time_start, time_end, width))
  local gl = find_glitches(top, bot, label, width, time_start, time_end)

  print(string.rep("=", 70))
  print(string.format("%s  (%d-%d, w=%d, cw=%.2fns)", label, time_start, time_end, width, (time_end-time_start)/width))
  print(string.rep("=", 70))
  print("T:" .. top)
  print("B:" .. bot)
  if #gl > 0 then
    print("GLITCHES:")
    for _, g in ipairs(gl) do print("  " .. g) end
  else
    print("OK")
  end
  print()
  return #gl == 0, gl
end

local function show_multi(vc, time_start, time_end, width, label)
  local top, bot = MultiBit.paint(vc, TimeScale.new(time_start, time_end, width))
  local tchars = utf8_chars(top)
  local bchars = utf8_chars(bot)
  local glitches = {}

  for i = 1, #tchars do
    local col = i - 1
    local tc = tchars[i]
    local bc = bchars[i]
    if not MB_VALID[tc] then
      table.insert(glitches, string.format("col %d: INVALID top char byte=0x%02X", col, tc:byte()))
    end
    if not MB_VALID[bc] then
      table.insert(glitches, string.format("col %d: INVALID bot char byte=0x%02X", col, bc:byte()))
    end
  end

  print(string.rep("=", 70))
  print(string.format("MB: %s  (%d-%d, w=%d, cw=%.2fns)", label, time_start, time_end, width, (time_end-time_start)/width))
  print(string.rep("=", 70))
  print("T:" .. top)
  print("B:" .. bot)
  if #glitches > 0 then
    print("GLITCHES:")
    for _, g in ipairs(glitches) do print("  " .. g) end
  else
    print("OK")
  end
  print()
  return #glitches == 0, glitches
end

local vc = gen_clk_vc()
local mb_vc = gen_multi_vc()
local mb_trans_vc = gen_multi_transition_vc()
print(string.format("Generated %d value_changes, %d mb_vc, %d mb_trans_vc", #vc, #mb_vc, #mb_trans_vc))
print()

local all_ok = true
local total_g = 0
local tests = {
  {"full 80 cols", 0, 800, 80},
  {"fast 259 cols (1ns/col)", 201, 460, 259},
  {"fast 200 cols", 201, 460, 200},
  {"fast 400 cols", 201, 460, 400},
  {"full 50 cols", 0, 800, 50},
  {"fast 500 cols", 200, 460, 500},
  {"transition 130 cols", 180, 320, 130},
  {"slow 100 cols", 0, 180, 100},
  {"fast 130 cols (2ns/col)", 200, 460, 130},
  {"slow 100 cols (0-100)", 0, 100, 100},
  {"fast start @200, 100 cols", 200, 400, 100},
  {"fast start @200, 50 cols", 200, 400, 50},
  {"fast exact @201, 259 cols", 201, 460, 259},
  {"mixed 150-350, 80 cols", 150, 350, 80},
  {"all fast 300 cols", 200, 600, 300},
  {"very zoomed out 30 cols", 0, 800, 30},
  {"fast high zoom 600 cols", 200, 400, 600},
  {"full 20 cols", 0, 800, 20},
  -- stress: zoomed into single transition
  {"single rise 50 cols", 200, 220, 50},
  {"single fall 50 cols", 201, 221, 50},
  {"fast tiny 300 cols", 200, 250, 300},
  {"fast near-integer 259 cols @200", 200, 459, 259},
}

for _, t in ipairs(tests) do
  local ok, gl = show_zoom(vc, t[2], t[3], t[4], t[1])
  all_ok = all_ok and ok
  total_g = total_g + #gl
end

-- Multi-bit tests
local mb_tests = {
  {"const 4-bit wide", 0, 300, 30},
  {"const 4-bit narrow", 0, 200, 10},
  {"transition 4-bit full", 0, 1000, 50},
  {"transition 4-bit zoom", 200, 800, 40},
}

for _, t in ipairs(mb_tests) do
  local vc_src = t[1]:match("^const") and mb_vc or mb_trans_vc
  local ok, gl = show_multi(vc_src, t[2], t[3], t[4], t[1])
  all_ok = all_ok and ok
  total_g = total_g + #gl
end

local function check_ruler(vc_src, time_start, time_end, width, label)
  local nums, ticks = Ruler.paint(TimeScale.new(time_start, time_end, width), vc_src)
  local tick_chars = utf8_chars(ticks)
  local ok = true
  local prev_end = -1
  for start, run in nums:gmatch("()(%d+)") do
    if start <= prev_end + 1 then
      print(string.format("RULER FAIL (%s): labels touch at col %d: %s", label, start, nums))
      ok = false
    end
    if tick_chars[start] ~= "┃" then
      print(string.format("RULER FAIL (%s): label %s at col %d has no tick", label, run, start))
      ok = false
    end
    local col = TimeScale.new(time_start, time_end, width):to_col(tonumber(run))
    if col ~= start - 1 then
      print(string.format("RULER FAIL (%s): label %s sits at col %d but its time maps to %d", label, run, start - 1, col))
      ok = false
    end
    prev_end = start + #run - 1
  end
  return ok
end

local shifted = {}
for i, e in ipairs(vc) do shifted[i] = { e[1] + 10000000, e[2] } end
local ruler_cases = {
  { vc, 0, 620, 176, "small times, full range" },
  { vc, 200, 260, 176, "small times, zoomed" },
  { shifted, 10000000, 10000620, 176, "8-digit times, full range" },
  { shifted, 10000200, 10000260, 176, "8-digit times, zoomed" },
  { shifted, 10000000, 10000620, 60, "8-digit times, narrow" },
  { { { 10000000, "0000" }, { 10000620, "1111" } }, 10000000, 10000620, 176, "no rising edges (bus only)" },
  { {}, 10000000, 10000620, 176, "no data" },
}
for _, c in ipairs(ruler_cases) do
  if not check_ruler(c[1], c[2], c[3], c[4], c[5]) then
    all_ok = false
    total_g = total_g + 1
  end
end

local hex_cases = {
  { string.rep("1", 64), "0xFFFFFFFFFFFFFFFF" },
  { "1" .. string.rep("0", 52) .. "1", "0x20000000000001" },
  { "101", "0x5" },
  { "0000", "0x0" },
  { "10x1", "10x1" },
}
for _, c in ipairs(hex_cases) do
  local line = ValueTable.paint({ value_changes = { { 0, c[1] } } }, 0)[1]
  local got = line:match("@%S+%s+(.+)$")
  if got ~= c[2] then
    all_ok = false
    total_g = total_g + 1
    print(string.format("HEX FAIL: %s -> %s (expected %s)", c[1], tostring(got), c[2]))
  end
end

print(string.rep("=", 70))
if all_ok then
  print("ALL PASS - no rendering glitches")
else
  print(string.format("GLITCHES: %d total", total_g))
end
