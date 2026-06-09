-- Generate a VCD test file with a signal that transitions:
-- low freq (period 40) → high freq (period 2) → low freq (period 40)
-- All timestamps are integers for parser compatibility.
--
-- Usage: lua gen_test_vcd.lua > ../test_var_freq.vcd
local function emit(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  print(table.concat(parts, " "))
end

-- Header
print("$date June 8 2026 $end")
print("$version wave.nvim test $end")
print("$timescale 1ns $end")
print("$scope module top $end")
print("$var wire 1 ! clk $end")
print("$var wire 4 # data $end")
print("$upscope $end")
print("$enddefinitions $end")
print("$dumpvars")
print("0!")
print("b0000 #")
print("#0")
print("$end")

local t = 0
local clk = 0
local data_val = 0

local function toggle()
  clk = 1 - clk
  data_val = (data_val + 1) % 16
end

local function to_bin(n, bits)
  local s = {}
  for i = bits - 1, 0, -1 do
    local bit = math.floor(n / (2 ^ i)) % 2
    s[#s + 1] = tostring(bit)
  end
  return table.concat(s)
end

local function emit_transition(step)
  t = t + step
  toggle()
  emit("#" .. tostring(t))
  emit(tostring(clk) .. "!")
  emit("b" .. to_bin(data_val, 4) .. " #")
end

-- Slow section: period 40 (toggle every 20), for 200 time units → 10 transitions
for _ = 1, 10 do
  emit_transition(20)
end

-- Fast section: period 2 (toggle every 1), for 400 time units → 400 transitions
for _ = 1, 400 do
  emit_transition(1)
end

-- Slow section: period 40 (toggle every 20), for 200 time units → 10 transitions
for _ = 1, 10 do
  emit_transition(20)
end
