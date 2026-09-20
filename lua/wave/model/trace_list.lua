--- The ordered set of displayed traces, and the edge index derived from them.

local Trace = require("wave.model.trace")
local EdgeIndex = require("wave.model.edge_index")

local TraceList = {}
TraceList.__index = TraceList

---@return TraceList
function TraceList.new()
  return setmetatable({ traces = {}, edges = nil }, TraceList)
end

--- Rebuilt lazily, because a fetch completing invalidates it far more often
--- than anything reads it.
function TraceList:_invalidate()
  self.edges = nil
end

---@param ref SignalRef
---@return Trace|nil, string|nil
function TraceList:add(ref)
  if self:get(ref.signal_id) then
    return nil, "Signal already displayed"
  end
  local trace = Trace.new(ref)
  self.traces[#self.traces + 1] = trace
  self:_invalidate()
  return trace
end

---@param signal_id number
---@return boolean
function TraceList:remove(signal_id)
  for i, trace in ipairs(self.traces) do
    if trace.ref.signal_id == signal_id then
      table.remove(self.traces, i)
      self:_invalidate()
      return true
    end
  end
  return false
end

function TraceList:clear()
  self.traces = {}
  self:_invalidate()
end

---@return Trace[]
function TraceList:all()
  return self.traces
end

---@return number
function TraceList:count()
  return #self.traces
end

---@param signal_id number
---@return Trace|nil
function TraceList:get(signal_id)
  for _, trace in ipairs(self.traces) do
    if trace.ref.signal_id == signal_id then return trace end
  end
  return nil
end

---@param signal_id number
---@param value_changes table|nil
---@param period number|nil
---@param window number[]|nil
function TraceList:set_data(signal_id, value_changes, period, window)
  local trace = self:get(signal_id)
  if not trace then return end
  trace:set_data(value_changes, period, window or trace.window)
  self:_invalidate()
end

---@return EdgeIndex
function TraceList:edge_index()
  if not self.edges then
    self.edges = EdgeIndex.build(self.traces)
  end
  return self.edges
end

--- Shortest period across the traces, which sets the zoom ladder's unit.
---@return number|nil
function TraceList:min_period()
  local shortest
  for _, trace in ipairs(self.traces) do
    if trace.period and (not shortest or trace.period < shortest) then
      shortest = trace.period
    end
  end
  return shortest
end

return TraceList
