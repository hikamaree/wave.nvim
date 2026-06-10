--- Signal management: add, remove, group displayed signals.

---@class DisplayedSignal
local M = {}

local displayed_signals = {}

---@param netlist_id number
---@param signal_id number
---@param name string
---@param width number|nil
---@return boolean, DisplayedSignal|string
function M.add_signal(netlist_id, signal_id, name, width)
  for _, sig in ipairs(displayed_signals) do
    if sig.netlist_id == netlist_id then
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
  return true, sig
end

---@param netlist_id number
---@return boolean
function M.remove_signal(netlist_id)
  for i, sig in ipairs(displayed_signals) do
    if sig.netlist_id == netlist_id then
      table.remove(displayed_signals, i)
      return true
    end
  end
  return false
end

function M.remove_all()
  displayed_signals = {}
end

---@return DisplayedSignal[]
function M.get_all()
  return displayed_signals
end

---@param netlist_id number
---@return DisplayedSignal|nil
function M.get_by_netlist_id(netlist_id)
  for _, sig in ipairs(displayed_signals) do
    if sig.netlist_id == netlist_id then
      return sig
    end
  end
  return nil
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

---@param netlist_id number
---@param value_changes table|nil
function M.set_value_changes(netlist_id, value_changes)
  local sig = M.get_by_netlist_id(netlist_id)
  if sig then
    sig.value_changes = value_changes
  end
end

return M
