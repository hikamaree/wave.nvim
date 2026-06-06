--- Signal management: add, remove, group displayed signals.

local M = {}

---@class DisplayedSignal
---@field netlist_id number
---@field signal_id number
---@field name string
---@field value_changes table|nil
---@field width number
local displayed_signals = {}

function M.add_signal(netlist_id, signal_id, name, width)
  for _, sig in ipairs(displayed_signals) do
    if sig.netlist_id == netlist_id then
      return false, "Signal already displayed"
    end
  end

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

function M.get_all()
  return displayed_signals
end

function M.get_by_netlist_id(netlist_id)
  for _, sig in ipairs(displayed_signals) do
    if sig.netlist_id == netlist_id then
      return sig
    end
  end
  return nil
end

function M.set_value_changes(netlist_id, value_changes)
  local sig = M.get_by_netlist_id(netlist_id)
  if sig then
    sig.value_changes = value_changes
  end
end

return M
