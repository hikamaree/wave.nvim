--- Paints the expanded view of a bus: one row per value change in view.

local ValueFormat = require("wave.render.value_format")
local ValueChanges = require("wave.model.value_changes")

local M = {}

--- Fetched data is wider than the viewport, so restrict to what is shown.
---@return number first, number last
local function visible_range(signal, t0, t1)
  local vc = signal and signal.value_changes
  if not vc or #vc == 0 then return 1, 0 end
  return ValueChanges.range(vc, t0, t1)
end

--- Row count paint() will produce, for callers laying out around it.
---@param signal table|nil
---@param max_rows number|nil
---@param t0 number|nil
---@param t1 number|nil
---@return number
function M.row_count(signal, max_rows, t0, t1)
  local first, last = visible_range(signal, t0, t1)
  local total = last - first + 1
  if total <= 0 then return 1 end
  local count = max_rows and math.min(total, max_rows) or total
  return count < total and count + 1 or count
end

---@param signal table|nil
---@param label_width number
---@param max_rows number|nil
---@param t0 number|nil
---@param t1 number|nil
---@return string[]
function M.paint(signal, label_width, max_rows, t0, t1)
  local pad = string.rep(" ", label_width)
  local first, last = visible_range(signal, t0, t1)
  local total = last - first + 1

  if total <= 0 then
    return { pad .. "  (no data in view)" }
  end

  local lines = {}
  local count = max_rows and math.min(total, max_rows) or total
  local vc = signal.value_changes
  for i = first, first + count - 1 do
    lines[#lines + 1] = pad .. string.format("    @%-12s %s", vc[i][1], ValueFormat.hex(vc[i][2]))
  end
  if count < total then
    lines[#lines + 1] = pad .. string.format("    … %d more in view", total - count)
  end
  return lines
end

return M
