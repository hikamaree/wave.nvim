--- Formatting of signal values for display.

local M = {}

local NIBBLE_HEX = {}
for n = 0, 15 do
  local bits = ""
  for b = 3, 0, -1 do bits = bits .. math.floor(n / 2 ^ b) % 2 end
  NIBBLE_HEX[bits] = string.format("%X", n)
end

--- Binary string to "0x..". Values holding x/z are passed through unchanged,
--- since there is no hex digit for an unknown bit.
---@param v string
---@return string
function M.hex(v)
  if #v <= 1 or v:find("[^01]") then return v end
  local bits = string.rep("0", (4 - #v % 4) % 4) .. v
  local digits = {}
  for i = 1, #bits, 4 do
    digits[#digits + 1] = NIBBLE_HEX[bits:sub(i, i + 3)]
  end
  return "0x" .. (table.concat(digits):match("^0*(.+)$"))
end

return M
