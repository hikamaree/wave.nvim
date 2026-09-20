--- The mapping between simulation time and waveform columns.
---
--- Both directions live here so they cannot drift apart: a cursor placed with
--- to_col() and a waveform sampled with to_time() must agree on where an edge
--- sits, or the cursor bar lands a column away from the transition it marks.

local TimeScale = {}
TimeScale.__index = TimeScale

local EPS = 1e-12

---@param t0 number
---@param t1 number
---@param cols number
---@return TimeScale
function TimeScale.new(t0, t1, cols)
  return setmetatable({ t0 = t0, t1 = t1, range = t1 - t0, cols = cols }, TimeScale)
end

--- 0-indexed column displaying time `t`, clamped to the visible range.
--- An edge at `t` is drawn at the first column whose start time reaches it,
--- which is one column left of the ceiling.
---@param t number
---@return number
function TimeScale:to_col(t)
  if self.range <= 0 then return 0 end
  local col = math.ceil(((t - self.t0 - EPS) / self.range) * self.cols) - 1
  if col < 0 then return 0 end
  if col >= self.cols then return self.cols - 1 end
  return col
end

--- Time at the left edge of column `col`.
---@param col number
---@return number
function TimeScale:to_time(col)
  return self.t0 + col * (self.range / self.cols)
end

return TimeScale
