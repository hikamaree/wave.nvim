--- The scope hierarchy, as a tree.
---
--- Holding it as data rather than as rendered text is what lets the netlist
--- view answer "which scope is this line" by lookup instead of by matching
--- patterns against its own output.

local SignalRef = require("wave.model.signal_ref")

local ScopeNode = {}
ScopeNode.__index = ScopeNode

---@param id number
---@param name string
---@return ScopeNode
function ScopeNode.new(id, name)
  return setmetatable({
    id = id,
    name = name,
    expanded = false,
    loaded = false,
    failed = false,
    scopes = {},
    vars = {},
  }, ScopeNode)
end

---@return boolean
function ScopeNode:is_empty()
  return #self.scopes == 0 and #self.vars == 0
end

local NetlistTree = {}
NetlistTree.__index = NetlistTree

---@param root_id number
---@param root_name string
---@return NetlistTree
function NetlistTree.new(root_id, root_name)
  local root = ScopeNode.new(root_id, root_name)
  -- The root's children are the view itself, so it is always open.
  root.expanded = true
  return setmetatable({ root = root, index = { [root_id] = root } }, NetlistTree)
end

---@param id number
---@return ScopeNode|nil
function NetlistTree:node(id)
  return self.index[id]
end

---@return ScopeNode
function NetlistTree:root_node()
  return self.root
end

--- Attaches a fetched level. `scopes` and `vars` are raw parser entries.
---@param id number
---@param scopes table[]|nil
---@param vars table[]|nil
function NetlistTree:set_children(id, scopes, vars)
  local node = self.index[id]
  if not node then return end

  node.scopes = {}
  for _, entry in ipairs(scopes or {}) do
    local child = self.index[entry.id] or ScopeNode.new(entry.id, entry.name)
    child.name = entry.name
    self.index[entry.id] = child
    node.scopes[#node.scopes + 1] = child
  end

  node.vars = {}
  for _, entry in ipairs(vars or {}) do
    node.vars[#node.vars + 1] = SignalRef.from_var(entry)
  end

  node.loaded = true
end

---@param id number
function NetlistTree:mark_failed(id)
  local node = self.index[id]
  if not node then return end
  node.loaded = true
  node.failed = true
end

---@param id number
function NetlistTree:expand(id)
  local node = self.index[id]
  if node then node.expanded = true end
end

--- Collapsing the root would empty the view, so it is refused.
---@param id number
function NetlistTree:collapse(id)
  local node = self.index[id]
  if node and node ~= self.root then node.expanded = false end
end

--- True when a scope is open but its level has not been fetched yet.
---@param id number
---@return boolean
function NetlistTree:needs_children(id)
  local node = self.index[id]
  return node ~= nil and node.expanded and not node.loaded
end

return { NetlistTree = NetlistTree, ScopeNode = ScopeNode }
