--- Builds the netlist window's content from the scope tree.

local Row = require("wave.render.row")

local NetlistLayout = {}
NetlistLayout.__index = NetlistLayout

local INDENT = "  "

---@param node ScopeNode
---@param depth number
---@param rows Row[]
local function emit_level(node, depth, rows)
  local indent = string.rep(INDENT, depth) .. INDENT

  for _, child in ipairs(node.scopes) do
    local marker = child.expanded and "-" or "+"
    rows[#rows + 1] = Row.new(
      indent .. "[" .. marker .. "] " .. tostring(child.id) .. ":" .. child.name,
      "scope", { node = child, parent = node })
    if child.expanded then
      emit_level(child, depth + 1, rows)
    end
  end

  for _, ref in ipairs(node.vars) do
    local suffix = ref:bit_suffix()
    rows[#rows + 1] = Row.new(
      indent .. "[VAR] " .. (ref.name or "?") .. (suffix == "" and "" or " " .. suffix),
      "var", { ref = ref, parent = node })
  end
end

---@param opts table tree, width, keymaps
---@return NetlistLayout
function NetlistLayout.build(opts)
  local root = opts.tree:root_node()
  local rows = {}

  rows[#rows + 1] = Row.new("Netlist > " .. root.name, "title")
  rows[#rows + 1] = Row.new(string.rep("─", opts.width), "rule")

  local first_tree_row = #rows + 1
  emit_level(root, 0, rows)

  if #rows < first_tree_row then
    rows[#rows + 1] = Row.new(
      root.failed and "  (no netlist for this file)" or "  (empty)", "empty")
  end

  local km = opts.keymaps
  rows[#rows + 1] = Row.new("", "blank")
  rows[#rows + 1] = Row.new((km.expand or "<CR>") .. ": expand/collapse/add", "help")
  rows[#rows + 1] = Row.new((km.back or "<Backspace>") .. ": back", "help")
  rows[#rows + 1] = Row.new((km.search or "/") .. ": search", "help")
  rows[#rows + 1] = Row.new((km.close or "q") .. ": close", "help")

  return setmetatable({ rows = rows }, NetlistLayout)
end

---@return NetlistLayout
function NetlistLayout.loading()
  return setmetatable({ rows = {
    Row.new("Netlist", "title"),
    Row.new("  (loading...)", "empty"),
  } }, NetlistLayout)
end

---@param line number
---@return string|nil kind, table|nil owner
function NetlistLayout:at(line)
  local row = self.rows[line]
  if not row then return nil, nil end
  return row.kind, row.owner
end

---@param line number
---@return ScopeNode|nil
function NetlistLayout:node_at(line)
  local kind, owner = self:at(line)
  return kind == "scope" and owner.node or nil
end

---@param line number
---@return SignalRef|nil
function NetlistLayout:var_at(line)
  local kind, owner = self:at(line)
  return kind == "var" and owner.ref or nil
end

--- The scope owning this line's entry.
---@param line number
---@return ScopeNode|nil
function NetlistLayout:parent_at(line)
  local _, owner = self:at(line)
  return owner and owner.parent or nil
end

return NetlistLayout
