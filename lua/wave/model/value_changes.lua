--- Lookups into a trace's value changes, which are ordered by time.
---
--- The viewport usually covers a slice of a long trace, so finding the ends
--- of that slice by binary search keeps a render proportional to what is on
--- screen rather than to how much data the signal holds.

local M = {}

---@param vc table[]
---@param i number
---@return number|nil
local function time_at(vc, i)
  local entry = vc[i]
  return entry and tonumber(entry[1]) or nil
end

--- Index of the last change at or before `t`, or 1 when `t` precedes them all.
---@param vc table[]
---@param t number
---@return number
function M.index_at(vc, t)
  local lo, hi = 1, #vc
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local at = time_at(vc, mid)
    if at and at <= t then lo = mid + 1 else hi = mid - 1 end
  end
  return math.max(1, hi)
end

--- Index of the first change at or after `t`, or #vc + 1 when none is.
---@param vc table[]
---@param t number
---@return number
function M.first_from(vc, t)
  local lo, hi = 1, #vc
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local at = time_at(vc, mid)
    if at and at < t then lo = mid + 1 else hi = mid - 1 end
  end
  return lo
end

--- Inclusive index range of the changes within [t0, t1].
---@param vc table[]
---@param t0 number|nil
---@param t1 number|nil
---@return number first, number last
function M.range(vc, t0, t1)
  if not t0 then return 1, #vc end
  local first = M.first_from(vc, t0)
  local last = M.index_at(vc, t1)
  -- index_at floors to 1, which is wrong when everything sits after t1.
  if (time_at(vc, last) or math.huge) > t1 then last = first - 1 end
  return first, last
end

return M
