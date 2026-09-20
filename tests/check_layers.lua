-- Architecture checks, run in CI so the layering cannot quietly rot back.
--   lua tests/check_layers.lua
--
-- Rules:
--   1. model/ and render/ never touch the Neovim API.
--   2. Dependencies point one way: model <- render <- ui <- app.
--   3. No module cycles.

local ROOT = "lua/wave"

-- Higher number = further from the core. A module may only require its own
-- layer or a lower one.
local DIRECTORY_LAYER = {
  util = 0,     -- logging
  model = 1,    -- pure state and math
  render = 2,   -- pure data -> rows
  ipc = 2,      -- the parser process
  ui = 3,       -- Neovim buffers and windows
  install = 3,  -- finding the binary
}

-- Top-level modules, named individually.
local MODULE_LAYER = {
  ["wave.config"] = 0,   -- foundation: read by every layer
  ["wave.actions"] = 0,  -- a data table; binds to a session at call time
  ["wave.session"] = 4,
  ["wave.app"] = 4,
  ["wave.init"] = 4,
}

local PURE = { model = true, render = true }

local problems = {}

local function fail(msg)
  problems[#problems + 1] = msg
end

---@return string[]
local function lua_files()
  local out = {}
  local pipe = io.popen("find " .. ROOT .. " -name '*.lua' | sort")
  for line in pipe:lines() do out[#out + 1] = line end
  pipe:close()
  return out
end

---@param path string
---@return string
local function module_name(path)
  return (path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", "."))
end

---@param mod string
---@return string name, number layer
local function layer_of(mod)
  local dir = mod:match("^wave%.([%w_]+)%.")
  if dir and DIRECTORY_LAYER[dir] then return dir, DIRECTORY_LAYER[dir] end
  if MODULE_LAYER[mod] then return mod, MODULE_LAYER[mod] end
  error("unclassified module: " .. mod .. " (add it to check_layers.lua)")
end

local sources, requires = {}, {}

for _, path in ipairs(lua_files()) do
  local f = assert(io.open(path, "r"))
  local body = f:read("*a")
  f:close()

  local mod = module_name(path)
  sources[mod] = body
  requires[mod] = {}
  for dep in body:gmatch('require%("(wave[%w_.]*)"%)') do
    requires[mod][#requires[mod] + 1] = dep
  end
end

-- 1. Purity.
for mod, body in pairs(sources) do
  local name = layer_of(mod)
  if PURE[name] then
    local line_no = 0
    for line in body:gmatch("[^\n]*") do
      line_no = line_no + 1
      if not line:match("^%s*%-%-") and line:match("vim%.[%w_]+") then
        fail(("%s:%d uses the Neovim API in a pure layer"):format(mod, line_no))
      end
    end
  end
end

-- 2. Direction.
for mod, deps in pairs(requires) do
  local from_name, from = layer_of(mod)
  for _, dep in ipairs(deps) do
    if sources[dep] then
      local to_name, to = layer_of(dep)
      if to > from then
        fail(("%s (%s) requires %s (%s): dependencies must point down")
          :format(mod, from_name, dep, to_name))
      end
    end
  end
end

-- 3. Cycles.
local state = {}
local function visit(mod, stack)
  state[mod] = "open"
  for _, dep in ipairs(requires[mod] or {}) do
    if sources[dep] then
      if state[dep] == "open" then
        fail("dependency cycle: " .. table.concat(stack, " -> ") .. " -> " .. dep)
      elseif state[dep] == nil then
        stack[#stack + 1] = dep
        visit(dep, stack)
        stack[#stack] = nil
      end
    end
  end
  state[mod] = "done"
end

local names = {}
for mod in pairs(sources) do names[#names + 1] = mod end
table.sort(names)
for _, mod in ipairs(names) do
  if state[mod] == nil then visit(mod, { mod }) end
end

print(("checked %d modules"):format(#names))
if #problems == 0 then
  print("  OK: layers are pure, one-way, and acyclic")
  os.exit(0)
end
for _, problem in ipairs(problems) do
  print("  FAIL: " .. problem)
end
os.exit(1)
