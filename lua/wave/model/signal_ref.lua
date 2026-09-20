--- Identity of one signal in the open file.
---
--- Built once where the signal is discovered — a search hit or a netlist var —
--- so the rest of the plugin passes a single value instead of five positional
--- arguments that each caller has to default the same way.

local SignalRef = {}
SignalRef.__index = SignalRef

---@param fields table
---@return SignalRef
function SignalRef.new(fields)
  return setmetatable({
    netlist_id = fields.netlist_id or 0,
    signal_id = fields.signal_id or 0,
    path = fields.path,
    width = fields.width or 1,
    msb = fields.msb,
    lsb = fields.lsb,
  }, SignalRef)
end

--- From a `search` result.
---@param r table
---@return SignalRef
function SignalRef.from_search(r)
  return SignalRef.new({
    netlist_id = r.netlist_id,
    signal_id = r.signal_id,
    path = r.instance_path,
    width = r.width,
    msb = r.msb,
    lsb = r.lsb,
  })
end

--- From a `get_children` var entry, which may only carry a bare name.
---@param v table
---@return SignalRef
function SignalRef.from_var(v)
  return SignalRef.new({
    netlist_id = v.netlist_id,
    signal_id = v.signal_id,
    path = v.instance_path or v.name,
    width = v.width,
    msb = v.msb,
    lsb = v.lsb,
  })
end

---@return boolean
function SignalRef:is_multi_bit()
  return self.width > 1
end

--- `[msb:lsb]` when the file gives an index, `[width-1:0]` otherwise, and
--- nothing at all for a single-bit signal.
---@return string
function SignalRef:bit_suffix()
  if self.msb and self.lsb and self.msb >= 0 and self.lsb >= 0 then
    return string.format("[%d:%d]", self.msb, self.lsb)
  end
  if self.width > 1 then
    return string.format("[%d:0]", self.width - 1)
  end
  return ""
end

return SignalRef
