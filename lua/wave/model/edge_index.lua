--- Sorted, de-duplicated transition times across every displayed trace.
---
--- One implementation of "where is the next edge", used by cursor placement
--- and by both edge-jump commands.

local EdgeIndex = {}
EdgeIndex.__index = EdgeIndex

-- A guard against pathological files. Past this the index is truncated and
-- navigation covers only the earlier part of the trace set, which beats
-- spending seconds sorting tens of millions of timestamps.
local MAX_EDGES = 500000

--- Adds one trace's distinct times. Returns false once the cap is reached,
--- so the caller stops walking the remaining traces.
---@param times number[]
---@param seen table<number, boolean>
---@param value_changes table[]
---@return boolean room_left
local function collect(times, seen, value_changes)
  for _, vc in ipairs(value_changes) do
    local t = tonumber(vc[1])
    if t and not seen[t] then
      seen[t] = true
      times[#times + 1] = t
      if #times >= MAX_EDGES then return false end
    end
  end
  return true
end

---@param traces Trace[]
---@return EdgeIndex
function EdgeIndex.build(traces)
  local times, seen = {}, {}
  for _, trace in ipairs(traces) do
    if not collect(times, seen, trace.value_changes or {}) then break end
  end
  table.sort(times)
  return setmetatable({ times = times }, EdgeIndex)
end

---@return number
function EdgeIndex:count()
  return #self.times
end

--- Greatest edge strictly before `t`.
---@param t number
---@return number|nil
function EdgeIndex:prev(t)
  local lo, hi = 1, #self.times
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if self.times[mid] < t then lo = mid + 1 else hi = mid - 1 end
  end
  return self.times[hi]
end

--- Least edge strictly after `t`.
---@param t number
---@return number|nil
function EdgeIndex:next(t)
  local lo, hi = 1, #self.times
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if self.times[mid] > t then hi = mid - 1 else lo = mid + 1 end
  end
  return self.times[lo]
end

--- Greatest edge at or before `t`, unlike prev() which is strict.
---@param t number
---@return number|nil
function EdgeIndex:floor(t)
  local lo, hi = 1, #self.times
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if self.times[mid] <= t then lo = mid + 1 else hi = mid - 1 end
  end
  return self.times[hi]
end

--- Edge closest to `t` in either direction. An edge exactly at `t` wins.
---@param t number
---@return number|nil
function EdgeIndex:nearest(t)
  local before, after = self:floor(t), self:next(t)
  if not before then return after end
  if not after then return before end
  return (t - before) <= (after - t) and before or after
end

return EdgeIndex
