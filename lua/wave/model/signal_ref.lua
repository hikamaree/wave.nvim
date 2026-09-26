--- Identity of one signal, built once where it is discovered.

local SignalRef = {}
SignalRef.__index = SignalRef

--- Last component of a dotted instance path: "tb.cpu.clk" -> "clk".
---@param path string|nil
---@return string|nil
local function leaf_of(path)
  if not path then return nil end
  return path:match("([^.]+)$") or path
end

--- `name` is the displayed leaf of `path`. Repeated leaves are not
--- disambiguated: tb.cpu.clk and tb.mem.clk both show as `clk`.
---@param fields table
---@return SignalRef
function SignalRef.new(fields)
  local path = fields.path
  return setmetatable({
    netlist_id = fields.netlist_id or 0,
    signal_id = fields.signal_id or 0,
    path = path,
    name = fields.name or leaf_of(path),
    width = fields.width or 1,
    msb = fields.msb,
    lsb = fields.lsb,
  }, SignalRef)
end

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

--- Search results carry no name field, so the leaf is split off the path.
---@param v table
---@return SignalRef
function SignalRef.from_var(v)
  return SignalRef.new({
    netlist_id = v.netlist_id,
    signal_id = v.signal_id,
    path = v.instance_path or v.name,
    name = v.name,
    width = v.width,
    msb = v.msb,
    lsb = v.lsb,
  })
end

---@return boolean
function SignalRef:is_multi_bit()
  return self.width > 1
end

--- `[msb:lsb]`, else `[width-1:0]`, else empty for a single bit.
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
