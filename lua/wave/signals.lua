--- Signal management: add, remove, group displayed signals.

---@class DisplayedSignal
local M = {}

local displayed_signals = {}
local _all_edges = {} ---@type number[]
local _edges_dirty = false
local MAX_EDGES = 500000

---@param netlist_id number
---@param signal_id number
---@param name string
---@param width number|nil
---@return boolean, DisplayedSignal|string
function M.add_signal(netlist_id, signal_id, name, width)
  for _, sig in ipairs(displayed_signals) do
    if sig.signal_id == signal_id then
      return false, "Signal already displayed"
    end
  end

  ---@type DisplayedSignal
  local sig = {
    netlist_id = netlist_id,
    signal_id = signal_id,
    name = name,
    width = width or 1,
    value_changes = nil,
    expanded = false,
  }

  table.insert(displayed_signals, sig)
  _edges_dirty = true
  return true, sig
end

---@param signal_id number
---@return boolean
function M.remove_signal(signal_id)
  for i, sig in ipairs(displayed_signals) do
    if sig.signal_id == signal_id then
      table.remove(displayed_signals, i)
      _edges_dirty = true
      return true
    end
  end
  return false
end

function M.remove_all()
  displayed_signals = {}
  _edges_dirty = true
end

---@return DisplayedSignal[]
function M.get_all()
  return displayed_signals
end

---@param signal_id number
---@return DisplayedSignal|nil
function M.get_by_signal_id(signal_id)
  for _, sig in ipairs(displayed_signals) do
    if sig.signal_id == signal_id then
      return sig
    end
  end
  return nil
end

---@param signal_id number
---@param value_changes table|nil
function M.set_value_changes(signal_id, value_changes)
  local sig = M.get_by_signal_id(signal_id)
  if sig then
    sig.value_changes = value_changes
    _edges_dirty = true
  end
end

--- Builds and returns a sorted array of unique edge times across all signals.
--- The array is cached and rebuilt lazily when signals change.
---@return number[]
function M.get_edges()
  if not _edges_dirty then return _all_edges end
  _edges_dirty = false
  _all_edges = {}
  local seen = {} ---@type table<number, boolean>
  for _, sig in ipairs(displayed_signals) do
    if sig.value_changes then
      for _, vc in ipairs(sig.value_changes) do
        if type(vc) == "table" and vc[1] ~= nil then
          local t = tonumber(vc[1])
          if t and not seen[t] then
            seen[t] = true
            _all_edges[#_all_edges + 1] = t
            if #_all_edges >= MAX_EDGES then
              _all_edges = {}
              return _all_edges
            end
          end
        end
      end
    end
  end
  table.sort(_all_edges)
  return _all_edges
end

return M
