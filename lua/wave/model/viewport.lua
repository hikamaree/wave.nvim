--- The visible time window, and every rule for moving it.
---
--- zoom_n is a discrete ladder, which is what snaps the waveform to whole
--- cycles: n >= 2 is n columns per period, 1 is one column per period, and
--- n <= -2 is one column per |n| periods.

local Viewport = {}
Viewport.__index = Viewport

local ZOOM_OUT_MARGIN = 1.05  -- headroom past the file end
local MIN_COLS = 20           -- below this the zoom arithmetic is meaningless
local SHRINK_THRESHOLD = 0.5  -- clamp may shrink this far before repositioning
local LINEAR_LIMIT = -8       -- past this the ladder doubles instead of stepping
local PAN_FRACTION = 0.1

---@param file_end number
---@return Viewport
function Viewport.new(file_end)
  return setmetatable({
    t0 = 0,
    t1 = (file_end or 1000) * ZOOM_OUT_MARGIN,
    file_end = file_end or 1000,
    zoom_n = -2,
  }, Viewport)
end

---@return number
function Viewport:range()
  return self.t1 - self.t0
end

---@return number
function Viewport:center()
  return (self.t0 + self.t1) / 2
end

---@return number
function Viewport:max_time()
  return (self.file_end or math.huge) * ZOOM_OUT_MARGIN
end

--- Columns per period at the current rung.
---@return number
function Viewport:zoom_value()
  if self.zoom_n >= 2 then return self.zoom_n end
  if self.zoom_n == 1 then return 1 end
  return -1.0 / self.zoom_n
end

---@return string
function Viewport:zoom_label()
  local z = self:zoom_value()
  return z >= 1 and tostring(math.floor(z)) or string.format("1/%d", -self.zoom_n)
end

function Viewport:clamp()
  local prev_range = self:range()
  if self.t0 < 0 then self.t0 = 0 end
  if self.t1 > self:max_time() then self.t1 = self:max_time() end
  if self:range() < prev_range * SHRINK_THRESHOLD then
    self.t0 = math.max(0, self.t1 - prev_range)
  end
end

--- Clamps against the boundary it moves toward, so an edge stops the pan.
---@param direction number -1 left, +1 right
---@param steps number|nil
function Viewport:pan(direction, steps)
  local range = self:range()
  local step = range * PAN_FRACTION * (steps or 1)
  if direction < 0 then
    self.t0 = math.max(0, self.t0 - step)
    self.t1 = self.t0 + range
  else
    self.t1 = math.min(self:max_time(), self.t1 + step)
    self.t0 = self.t1 - range
  end
  self:clamp()
end

--- Slides the view to keep `t` on screen, without changing the span.
---@param t number
function Viewport:follow(t)
  local range = self:range()
  local margin = range * PAN_FRACTION
  if t < self.t0 + margin then
    self.t0 = math.max(0, t - margin)
    self.t1 = self.t0 + range
  elseif t > self.t1 - margin then
    self.t1 = math.min(self:max_time(), t + margin)
    self.t0 = self.t1 - range
  end
end

--- Fallback when no period is known.
---@param factor number
---@return boolean changed
function Viewport:scale_by(factor)
  local range = math.min(self:range() * factor, self:max_time())
  if range <= 0 then return false end
  local center = self:center()
  self.t0 = math.max(0, center - range / 2)
  self.t1 = self.t0 + range
  self:clamp()
  return true
end

--- Recomputes the span from the current rung, around the cursor if visible.
---@param period number
---@param cols number
---@param cursor_time number|nil
function Viewport:apply_zoom(period, cols, cursor_time)
  if cols < MIN_COLS or not period or period <= 0 then return end

  local range = cols * (period / self:zoom_value())
  local max_range = self:max_time()
  range = math.max(math.min(period * 2, max_range), math.min(range, max_range))

  local center = self:center()
  if cursor_time and cursor_time >= self.t0 and cursor_time <= self.t1 then
    center = cursor_time
  end

  self.t0 = math.max(0, center - range / 2)
  self.t1 = self.t0 + range
  if self.t1 > max_range and self.t0 > 0 then
    self.t0 = math.max(0, max_range - range)
    self.t1 = max_range
  end
end

--- Inverse of apply_zoom: recovers the rung after a direct span change.
---@param period number
---@param cols number
function Viewport:sync_zoom(period, cols)
  if not period or self:range() <= 0 or cols < MIN_COLS then return end
  local zoom = cols * period / self:range()
  if zoom >= 1.5 then
    local n = math.floor(zoom + 0.5)
    self.zoom_n = n - n % 2
  elseif zoom >= 0.75 then
    self.zoom_n = 1
  else
    self.zoom_n = -math.max(2, math.floor(self:range() / (cols * period) + 0.5))
  end
end

---@return number
function Viewport:_next_zoom_in()
  if self.zoom_n < LINEAR_LIMIT then return math.floor(self.zoom_n / 2) end
  if self.zoom_n == -2 then return 1 end
  if self.zoom_n == 1 then return 2 end
  return self.zoom_n + 2
end

---@return number
function Viewport:_next_zoom_out()
  if self.zoom_n <= LINEAR_LIMIT then return self.zoom_n * 2 end
  if self.zoom_n == 2 then return 1 end
  if self.zoom_n == 1 then return -2 end
  return self.zoom_n - 2
end

---@param period number|nil
---@param cols number
---@param cursor_time number|nil
---@return boolean changed
function Viewport:zoom_in(period, cols, cursor_time)
  if not period then return self:scale_by(0.5) end

  local next_n = self:_next_zoom_in()
  if cols >= MIN_COLS then
    local saved = self.zoom_n
    self.zoom_n = next_n
    local new_range = cols * period / self:zoom_value()
    self.zoom_n = saved
    -- Already down to two periods.
    if new_range < period * 2 and self:range() <= period * 2 then return false end
  end

  self.zoom_n = next_n
  self:apply_zoom(period, cols, cursor_time)
  return true
end

---@param period number|nil
---@param cols number
---@param cursor_time number|nil
---@return boolean changed
function Viewport:zoom_out(period, cols, cursor_time)
  if self:range() >= self:max_time() then return false end
  if not period then return self:scale_by(2) end
  self.zoom_n = self:_next_zoom_out()
  self:apply_zoom(period, cols, cursor_time)
  return true
end

return Viewport
