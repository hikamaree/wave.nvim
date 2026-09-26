--- One rendered buffer line. It carries its owner, so "what is under the
--- cursor" is a lookup rather than a second pass over the layout arithmetic.

local Row = {}
Row.__index = Row

---@param text string
---@param kind string
---@param owner any|nil
---@return Row
function Row.new(text, kind, owner)
  return setmetatable({
    text = text,
    kind = kind,
    owner = owner,
    highlights = {},
    cursor_track = false,
  }, Row)
end

--- Byte offsets, as extmarks want.
---@param group string
---@param from number
---@param to number
---@return Row
function Row:hl(group, from, to)
  if to > from then
    self.highlights[#self.highlights + 1] = { group = group, from = from, to = to }
  end
  return self
end

---@return Row
function Row:track_cursor()
  self.cursor_track = true
  return self
end

return Row
