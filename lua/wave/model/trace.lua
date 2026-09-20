--- One displayed signal: what it is, the data fetched for it, and how it is
--- currently shown.

local Trace = {}
Trace.__index = Trace

-- Data is fetched for a window wider than the viewport so small pans do not
-- trigger a round trip; a window this much wider than needed is refetched.
local FETCH_MARGIN = 1
local REFETCH_ZOOM_FACTOR = 2

---@param ref SignalRef
---@return Trace
function Trace.new(ref)
  return setmetatable({
    ref = ref,
    value_changes = nil,
    period = nil,
    window = nil,
    loading = false,
    expanded = false,
  }, Trace)
end

---@return number
function Trace.signal_id(self)
  return self.ref.signal_id
end

--- The time window to fetch for a viewport, with margin on both sides.
---@param t0 number
---@param t1 number
---@return number, number
function Trace.fetch_window(t0, t1)
  local range = t1 - t0
  return math.max(0, math.floor(t0 - range * FETCH_MARGIN)), math.ceil(t1 + range * FETCH_MARGIN)
end

--- True when the viewport has moved outside the fetched window, or zoomed in
--- far enough that the held data is much coarser than the view deserves.
---@param t0 number
---@param t1 number
---@return boolean
function Trace:needs_fetch(t0, t1)
  if self.loading then return false end
  if not self.window then return true end
  local range = t1 - t0
  return t0 < self.window[1]
    or t1 > self.window[2]
    or self.window[2] - self.window[1] > range * (1 + 2 * FETCH_MARGIN) * REFETCH_ZOOM_FACTOR
end

---@param value_changes table|nil
---@param period number|nil
---@param window number[]
function Trace:set_data(value_changes, period, window)
  self.value_changes = value_changes
  self.period = period
  self.window = window
end

function Trace:toggle_expand()
  self.expanded = not self.expanded
end

--- Only a bus has anything to expand into.
---@return boolean
function Trace:can_expand()
  return self.ref:is_multi_bit()
end

return Trace
