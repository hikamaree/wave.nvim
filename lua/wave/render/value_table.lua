--- Paints the expanded view of a bus: one row per value change in view.

local ValueFormat = require("wave.render.value_format")

local M = {}

--- The fetched data covers a wider window than the viewport, so the table is
--- restricted to what is actually on screen.
---@param signal table|nil
---@param t0 number|nil
---@param t1 number|nil
---@return table[]
local function visible_changes(signal, t0, t1)
  local out = {}
  for _, vc in ipairs(signal and signal.value_changes or {}) do
    local t = tonumber(vc[1])
    if not t0 or (t and t >= t0 and t <= t1) then
      out[#out + 1] = vc
    end
  end
  return out
end

--- Row count paint() will produce, so callers can lay out around it.
---@param signal table|nil
---@param max_rows number|nil
---@param t0 number|nil
---@param t1 number|nil
---@return number
function M.row_count(signal, max_rows, t0, t1)
  local total = #visible_changes(signal, t0, t1)
  if total == 0 then return 1 end
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
  local visible = visible_changes(signal, t0, t1)
  local total = #visible

  if total == 0 then
    return { pad .. "  (no data in view)" }
  end

  local lines = {}
  local count = max_rows and math.min(total, max_rows) or total
  for i = 1, count do
    local vc = visible[i]
    lines[#lines + 1] = pad .. string.format("    @%-12s %s", vc[1], ValueFormat.hex(vc[2]))
  end
  if count < total then
    lines[#lines + 1] = pad .. string.format("    … %d more in view", total - count)
  end
  return lines
end

return M
