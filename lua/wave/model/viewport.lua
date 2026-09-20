--- The visible time window, and every rule for moving it.
---
--- zoom_n is a ladder rather than a factor: n >= 2 means n columns per clock
--- period, n == 1 means one column per period, and n <= -2 means one column
--- per |n| periods. Keeping it discrete is what makes the waveform snap to
--- whole cycles instead of drifting to fractional column widths.

local Viewport = {}
Viewport.__index = Viewport

-- A little headroom past the end of the file, so the last edge is not flush
-- against the right border.
local ZOOM_OUT_MARGIN = 1.05
-- Below this the zoom arithmetic has no room to mean anything.
local MIN_COLS = 20
-- Clamping must not silently shrink the span; past this it is repositioned.
local SHRINK_THRESHOLD = 0.5
-- Beyond this the ladder doubles instead of stepping, so zooming out of a
-- long trace does not take dozens of presses.
local LINEAR_LIMIT = -8
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

--- The furthest right the view may extend.
---@return number
function Viewport:max_time()
  return (self.file_end or math.huge) * ZOOM_OUT_MARGIN
end

--- Columns per period for the current rung of the ladder.
---@return number
function Viewport:zoom_value()
  if self.zoom_n >= 2 then return self.zoom_n end
  if self.zoom_n == 1 then return 1 end
  return -1.0 / self.zoom_n
end

--- How the zoom factor is shown in the header.
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

--- Slides the window one step. Each direction clamps against the boundary it
--- is moving toward, so panning into an edge stops rather than shrinking.
---@param direction number -1 left, +1 right
function Viewport:pan(direction)
  local range = self:range()
  local step = range * PAN_FRACTION
  if direction < 0 then
    self.t0 = math.max(0, self.t0 - step)
    self.t1 = self.t0 + range
  else
    self.t1 = math.min(self:max_time(), self.t1 + step)
    self.t0 = self.t1 - range
  end
  self:clamp()
end

--- Keeps a marker on screen by sliding the view, without changing its span.
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

--- Zoom with no known period: scale the span around its centre.
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

--- Recomputes the span from the current rung, keeping the cursor centred
--- when it is on screen and the view's centre otherwise.
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

--- Pulls zoom_n back into agreement after the span was changed directly, so
--- the header and the next zoom step start from what is actually on screen.
--- The inverse of apply_zoom.
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
    -- Already as tight as a two-period span: stop rather than go finer.
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
