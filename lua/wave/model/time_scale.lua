--- Time <-> waveform columns. Both directions live here so they cannot
--- drift apart and leave the cursor a column off its transition.

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

--- 0-indexed column for `t`, clamped. An edge lands on the first column
--- whose start reaches it, one left of the ceiling.
---@param t number
---@return number
function TimeScale:to_col(t)
  if self.range <= 0 then return 0 end
  local col = math.ceil(((t - self.t0 - EPS) / self.range) * self.cols) - 1
  if col < 0 then return 0 end
  if col >= self.cols then return self.cols - 1 end
  return col
end

--- Middle of `col`. A click reports the column it landed in, and only a time
--- inside that column maps back to it: to_time gives the left boundary, which
--- to_col's ceiling sends back to the column before.
---@param col number
---@return number
function TimeScale:center_of(col)
  return self.t0 + (col + 0.5) * (self.range / self.cols)
end

--- Time at the left edge of `col`.
---@param col number
---@return number
function TimeScale:to_time(col)
  return self.t0 + col * (self.range / self.cols)
end

return TimeScale
