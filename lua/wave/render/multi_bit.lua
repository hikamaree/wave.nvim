--- A bus as two rows, with the value inside each segment wide enough for it.

local Sampler = require("wave.render.sampler")
local ValueFormat = require("wave.render.value_format")

local M = {}

--- Segment body over (start_col, end_col], labelled if it fits.
---@param top string[]
---@param bot string[]
---@param v string
---@param start_col number
---@param end_col number
local function place_segment(top, bot, v, start_col, end_col)
  top[start_col] = "┌"; bot[start_col] = "└"
  local avail = end_col - start_col
  local labelled = #v <= avail
  for c = 1, avail do
    local idx = start_col + c
    if labelled and c <= #v then top[idx] = v:sub(c, c) else top[idx] = "─" end
    bot[idx] = "─"
  end
end

---@param value_changes table|nil
---@param scale TimeScale
---@return string, string
function M.paint(value_changes, scale)
  local width = scale.cols
  if not value_changes or #value_changes == 0 then
    return string.rep(" ", width), string.rep(" ", width)
  end

  local s = Sampler.of(value_changes, scale)

  local text = {}
  for col = 0, width do text[col] = ValueFormat.hex(s.value[col]) end

  local top, bot = {}, {}
  for i = 1, width do top[i] = " "; bot[i] = " " end

  local transitions = {}
  for col = 0, width - 1 do
    if text[col + 1] ~= text[col] or s.count[col] >= 2 then
      table.insert(transitions, col)
    end
  end

  if #transitions == 0 then
    place_segment(top, bot, text[0], 1, width)
    return table.concat(top), table.concat(bot)
  end

  if transitions[1] > 0 then
    place_segment(top, bot, text[0], 1, transitions[1])
  end

  for ti, col in ipairs(transitions) do
    if col == 0 then
      -- Fresh start at the viewport edge, matching place_segment.
      top[col + 1] = "┌"
      bot[col + 1] = "└"
    else
      top[col + 1] = "┬"
      bot[col + 1] = "┴"
    end

    local v = text[col + 1]
    local next_col = transitions[ti + 1] or width
    local space = next_col - col - 1
    local labelled = #v <= space
    for c = 1, space do
      local idx = col + 1 + c
      if idx <= width then
        if labelled and c <= #v then top[idx] = v:sub(c, c) else top[idx] = "─" end
        bot[idx] = "─"
      end
    end
  end

  return table.concat(top), table.concat(bot)
end

return M
