--- Paints the time ruler: a tick row and a row of time labels above it.
---
--- When a reference clock is available the ticks land on its rising edges, so
--- the labels read as cycle boundaries rather than arbitrary column offsets.

local Sampler = require("wave.render.sampler")

local M = {}

local MAX_MARKER_DIVISOR = 8
local LABEL_GAP_COLS = 2

--- Time of the first rise within a column's span. An intermediate x/z must not
--- hide the edge, so this looks for the "1" rather than a 0->1 pair.
---@param value_changes table
---@param from_idx number
---@param to_idx number
---@return number|nil
local function first_rise_time(value_changes, from_idx, to_idx)
  for i = from_idx + 1, to_idx do
    if value_changes[i][2] == "1" then
      return tonumber(value_changes[i][1])
    end
  end
  return nil
end

--- Writes a tick at `col` and its label, unless the label would collide with
--- the previous one or run past the right edge.
---@return number the column the written label ends at
local function place(nums, ticks, col, edge_time, width, label_end)
  ticks[col + 1] = "┃"
  local s = tostring(math.floor(edge_time))
  if col < label_end + 1 or col + #s > width then return label_end end
  for j = 0, #s - 1 do
    nums[col + 1 + j] = s:sub(j + 1, j + 1)
  end
  return col + #s
end

---@param scale TimeScale
---@param reference_changes table one-bit signal used to find cycle edges
---@return string, string
function M.paint(scale, reference_changes)
  local width = scale.cols
  local nums, ticks = {}, {}
  for i = 1, width do nums[i] = " "; ticks[i] = " " end

  if scale.range <= 0 then
    return table.concat(nums), table.concat(ticks)
  end

  local rise_cols, vc_end = {}, {}
  if #reference_changes > 0 then
    local s = Sampler.of(reference_changes, scale)
    vc_end = s.vc_end
    for col = 0, width - 1 do
      if s.value[col] == "0" and s.value[col + 1] == "1" then
        table.insert(rise_cols, col)
      end
    end
  end

  ticks[1] = "┃"

  local label_width = #tostring(math.floor(scale.t1)) + LABEL_GAP_COLS
  local target = math.max(2, math.floor(width / math.max(MAX_MARKER_DIVISOR, label_width)))
  local label_end = -1

  if #rise_cols >= 2 then
    local step = math.ceil(#rise_cols / target)
    for idx = 1, #rise_cols, step do
      local col = rise_cols[idx]
      local edge_time = first_rise_time(reference_changes, vc_end[col], vc_end[col + 1])
        or scale:to_time(col + 1)
      label_end = place(nums, ticks, col, edge_time, width, label_end)
    end
  else
    local step = math.max(1, math.floor(width / target))
    for col = step, width - 1, step do
      label_end = place(nums, ticks, col, scale:to_time(col + 1), width, label_end)
    end
  end

  return table.concat(nums), table.concat(ticks)
end

return M
