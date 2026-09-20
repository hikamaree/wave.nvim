--- Samples a signal's value changes onto waveform columns.
---
--- Shared by every painter, so they all agree on which value is in effect in
--- a column and how many transitions that column has to represent.

local Sampler = {}
Sampler.__index = Sampler

local EPS = 1e-12

---@class ColumnSamples
---@field value table<number, string>  value in effect at each column, 0..cols
---@field vc_end table<number, number> index of the last change applied, 0..cols
---@field count table<number, number>  transitions falling inside each column, 0..cols-1

---@param value_changes table
---@param scale TimeScale
---@return ColumnSamples
function Sampler.of(value_changes, scale)
  local value, vc_end = {}, {}
  local idx = 1
  for col = 0, scale.cols do
    local col_time = scale:to_time(col)
    while idx < #value_changes and tonumber(value_changes[idx + 1][1]) <= col_time + EPS do
      idx = idx + 1
    end
    value[col] = value_changes[idx][2]
    vc_end[col] = idx
  end

  local count = {}
  for col = 0, scale.cols - 1 do
    count[col] = vc_end[col + 1] - vc_end[col]
  end

  return setmetatable({ value = value, vc_end = vc_end, count = count }, Sampler)
end

--- A change exactly at the left edge belongs to the previous value, so the
--- transition is drawn rather than swallowed by the viewport boundary.
---@param value_changes table
function Sampler:align_left_edge(value_changes, t0)
  if self.vc_end[0] <= 1 then return end
  local first = tonumber(value_changes[self.vc_end[0]][1])
  if not first or math.abs(first - t0) > EPS then return end
  self.value[0] = value_changes[self.vc_end[0] - 1][2]
  self.vc_end[0] = self.vc_end[0] - 1
  self.count[0] = self.vc_end[1] - self.vc_end[0]
end

return Sampler
