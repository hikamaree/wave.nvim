--- Display-width arithmetic over UTF-8, without the editor. Layout runs
--- before any buffer exists. Every glyph drawn is one cell wide, so
--- counting codepoints gives the same answer as strdisplaywidth.

local M = {}

---@param byte number
---@return boolean
local function is_continuation(byte)
  return byte >= 0x80 and byte < 0xC0
end

---@param s string
---@return number
function M.width(s)
  local n = 0
  for i = 1, #s do
    if not is_continuation(string.byte(s, i)) then n = n + 1 end
  end
  return n
end

--- Never splits a codepoint.
---@param s string
---@param cells number
---@return string
function M.truncate(s, cells)
  if cells <= 0 then return "" end
  local seen = 0
  for i = 1, #s do
    if not is_continuation(string.byte(s, i)) then
      if seen == cells then return s:sub(1, i - 1) end
      seen = seen + 1
    end
  end
  return s
end

---@param s string
---@param cells number
---@return string
function M.pad(s, cells)
  local short = cells - M.width(s)
  return short > 0 and (s .. string.rep(" ", short)) or s
end

return M
