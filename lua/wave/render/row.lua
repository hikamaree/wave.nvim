--- One rendered buffer line, carrying what produced it.
---
--- The owner is the point: a row knows which trace or node it came from, so
--- "what is under the cursor" is a lookup rather than a second traversal of
--- the layout arithmetic that can disagree with what was drawn.

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

--- Adds a highlight span. Columns are byte offsets, as extmarks want.
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

--- Marks this row as one the time cursor is drawn through.
---@return Row
function Row:track_cursor()
  self.cursor_track = true
  return self
end

return Row
