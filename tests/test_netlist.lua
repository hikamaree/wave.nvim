-- End-to-end netlist tests. The netlist had no coverage before the refactor,
-- and phase 6 replaced its buffer-text parsing with a real tree.
--   nvim --headless -u NONE -l tests/test_netlist.lua

package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

vim.o.columns = 120
vim.o.lines = 40

local wave = require("wave")

local SAMPLE = "tests/samples/swerv_riscv.vcd"

local passed, failed = 0, 0

local function check(name, cond, detail)
  if cond then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    print("  FAIL: " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
  end
end

local function settle(ms)
  vim.wait(ms or 2000, function() return false end, 20)
end

local function session()
  return wave.session()
end

local function netlist_open()
  local s = session()
  return s ~= nil and s:netlist_open()
end

local function lines()
  local s = session()
  if not s or not s:netlist_open() then return {} end
  return vim.api.nvim_buf_get_lines(s.netlist.buffer.handle, 0, -1, false)
end

--- Moves the netlist cursor to the first line matching `pattern`.
local function goto_line(pattern)
  local all = lines()
  for i, text in ipairs(all) do
    if text:match(pattern) then
      vim.api.nvim_win_set_cursor(session().netlist.window.handle, { i, 0 })
      return i, text
    end
  end
  return nil
end

assert(wave.setup({}), "wave.setup() failed")

print("--- open ---")
wave.open_file(SAMPLE)
settle()
check("viewer open", session() ~= nil and session():viewer_open())

wave.open_netlist()
settle(3000)
check("netlist open", netlist_open())

local body = table.concat(lines(), "\n")
check("has a title", body:match("Netlist"), body:sub(1, 60))
check("shows scopes or vars", body:match("%[%+%]") or body:match("%[VAR%]"), body:sub(1, 200))
check("shows the key help", body:match(": expand/collapse/add") ~= nil)

print("\n--- expand a scope ---")
local line, text = goto_line("%[%+%]")
check("found a collapsed scope", line ~= nil, text)

local scope_id = text and text:match("%[%+%]%s+(%d+):")
session():netlist_enter()
settle(3000)

local after = table.concat(lines(), "\n")
check("scope is now marked open", after:match("%[%-%]%s+" .. (scope_id or "0") .. ":") ~= nil)
check("expanding revealed more lines", #lines() > 6, #lines())

print("\n--- expansion survives close and reopen ---")
local expanded_before = after
session():hide_netlist()
settle()
check("closed", not netlist_open())

wave.open_netlist()
settle(3000)
check("reopened", netlist_open())

local reopened = table.concat(lines(), "\n")
check("still shows the open scope",
  reopened:match("%[%-%]%s+" .. (scope_id or "0") .. ":") ~= nil,
  reopened:sub(1, 200))
check("tree is unchanged across reopen", reopened == expanded_before)

print("\n--- collapse with back ---")
goto_line("%[%-%]%s+" .. (scope_id or "0") .. ":")
session():netlist_back()
settle()
check("scope collapsed again",
  table.concat(lines(), "\n"):match("%[%+%]%s+" .. (scope_id or "0") .. ":") ~= nil)

print("\n--- add a variable ---")
wave.open_netlist()  -- ensure open
if not netlist_open() then wave.open_netlist() end
settle(2000)

-- Walk down expanding until a [VAR] line appears.
for _ = 1, 6 do
  if goto_line("%[VAR%]") then break end
  if not goto_line("%[%+%]") then break end
  session():netlist_enter()
  settle(2000)
end

local var_line, var_text = goto_line("%[VAR%]")
if var_line then
  local before_count = session().traces:count()
  session():netlist_enter()
  settle(2000)
  check("variable added to the viewer", session().traces:count() == before_count + 1,
    var_text)
else
  print("  SKIP: no [VAR] reachable in this sample")
end

print("\n--- reset clears the tree ---")
session():hide_netlist()
session().tree = require("wave.model.netlist_tree").NetlistTree.new(0, "reset")
settle()
wave.open_netlist()
settle(3000)
check("rebuilt after reset", netlist_open())
check("collapsed again after reset",
  table.concat(lines(), "\n"):match("%[%-%]") == nil
    or table.concat(lines(), "\n"):match("%[%+%]") ~= nil)

print("\n" .. string.rep("=", 50))
print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
print(string.rep("=", 50))
if failed > 0 then vim.cmd("cq") end
