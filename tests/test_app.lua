-- App-level command tests: the entry points plugin/wave.lua and the user
-- commands drive. Covers the Session lifecycle introduced in phase 7.
--   nvim --headless -u NONE -l tests/test_app.lua

package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

vim.o.columns = 100
vim.o.lines = 40

local wave = require("wave")
local SignalRef = require("wave.model.signal_ref")

local SAMPLE = "tests/samples/random_counter.vcd"
local OTHER = "tests/samples/jtag.vcd"

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
  vim.wait(ms or 1500, function() return false end, 20)
end

print("--- setup ---")
check("setup succeeds", wave.setup({}) == true)
check("no session before opening", wave.session() == nil)

print("\n--- open ---")
wave.open_file(SAMPLE)
settle()
local session = wave.session()
check("session created", session ~= nil)
check("session knows its path", session and session.path:match("random_counter%.vcd") ~= nil)
check("file name set", session and session.file_name == "random_counter.vcd")
check("viewer open", session and session:viewer_open())
check("viewport spans the file", session and session.viewport.file_end > 0)

print("\n--- missing file is reported, not fatal ---")
wave.open_file("tests/samples/does_not_exist.vcd")
settle(300)
check("session unchanged", wave.session() == session)

print("\n--- toggle the viewer ---")
wave.toggle_viewer()
settle(300)
check("viewer hidden", not session:viewer_open())
check("session survives hiding the viewer", wave.session() == session)

wave.toggle_viewer()
settle(300)
check("viewer shown again", session:viewer_open())

print("\n--- traces survive a viewer toggle ---")
local ref = SignalRef.new({ signal_id = 0, path = "tb.clk", width = 1 })
session:add_trace(ref)
settle()
check("trace added", session.traces:count() == 1)

local dup_count = session.traces:count()
session:add_trace(ref)
check("duplicate ignored", session.traces:count() == dup_count)

wave.toggle_viewer()
settle(300)
wave.toggle_viewer()
settle()
check("trace still present after toggle", session.traces:count() == 1)

print("\n--- netlist toggles independently ---")
wave.open_netlist()
settle(2000)
check("netlist open", session:netlist_open())
check("viewer still open", session:viewer_open())

wave.open_netlist()
settle(300)
check("netlist closed", not session:netlist_open())

print("\n--- opening a second file replaces the session ---")
wave.open_file(OTHER)
settle(2000)
local second = wave.session()
check("new session", second ~= nil and second ~= session)
check("new path", second and second.path:match("jtag%.vcd") ~= nil)
check("traces start empty", second and second.traces:count() == 0)

print("\n--- reopening the same file keeps the session ---")
second:add_trace(SignalRef.new({ signal_id = 0, path = "keep", width = 1 }))
settle(300)
wave.open_file(OTHER)
settle(500)
check("same session reused", wave.session() == second)
check("its traces are kept", second.traces:count() == 1)

print("\n--- reload ---")
wave.reload()
settle(2500)
local reloaded = wave.session()
check("session rebuilt", reloaded ~= nil)
check("same file", reloaded and reloaded.path:match("jtag%.vcd") ~= nil)
check("reload clears traces", reloaded and reloaded.traces:count() == 0)

print("\n--- close_all ---")
wave.close_all()
settle(300)
check("viewer closed", not reloaded:viewer_open())
check("netlist closed", not reloaded:netlist_open())

print("\n--- <Plug> mappings registered ---")
local maps = {}
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
  maps[m.lhs] = true
end
for _, name in ipairs({ "zoom-in", "zoom-out", "scroll-left", "scroll-right",
  "prev-edge", "next-edge", "set-cursor", "remove-signal",
  "expand-signal", "find-signal", "help", "close", "netlist" }) do
  check("<Plug>(wave-" .. name .. ")", maps["<Plug>(wave-" .. name .. ")"] == true)
end

print("\n--- commands are safe with no session ---")
require("wave.app").stop()
check("no session after stop", wave.session() == nil)
local ok = pcall(function()
  wave.toggle_viewer()
  wave.open_netlist()
  wave.close_all()
  wave.reload()
  wave.search_netlist()
end)
check("no errors without a session", ok)

print("\n--- Actions registry ---")
do
  local Actions = require("wave.actions")
  local config = require("wave.config")

  -- Every configured key except the netlist-only "back" must map to an action.
  for id in pairs(config.defaults.keymaps) do
    if id ~= "back" then
      check("keymap '" .. id .. "' has an action", Actions.by_id(id) ~= nil)
    end
  end

  -- And every action must be reachable from a default keymap.
  for _, action in ipairs(Actions.list) do
    check("action '" .. action.id .. "' has a default key",
      config.defaults.keymaps[action.id] ~= nil)
  end

  local ids = {}
  local plugs = {}
  for _, action in ipairs(Actions.list) do
    check("action '" .. action.id .. "' is unique", ids[action.id] == nil)
    check("plug '" .. action.plug .. "' is unique", plugs[action.plug] == nil)
    ids[action.id] = true
    plugs[action.plug] = true
    check("action '" .. action.id .. "' has a description",
      type(action.desc) == "string" and #action.desc > 0)
    check("action '" .. action.id .. "' is runnable", type(action.run) == "function")
  end

  local groups = Actions.groups()
  local grouped = 0
  for _, group in ipairs(groups) do grouped = grouped + #group end
  check("groups cover every action", grouped == #Actions.list, grouped)
end

print("\n--- config validation ---")
do
  local config = require("wave.config")
  check("clean config has no problems", #config.validate({}) == 0)
  check("clean full config has no problems",
    #config.validate({ colors = { signal = "#112233" }, keymaps = { zoom_in = "z" } }) == 0)
  check("unknown option flagged", #config.validate({ nope = 1 }) == 1)
  check("unknown keymap flagged", #config.validate({ keymaps = { fly = "x" } }) == 1)
  check("unknown colour flagged", #config.validate({ colors = { neon = "#ffffff" } }) == 1)
  check("bad colour flagged", #config.validate({ colors = { signal = "green" } }) == 1)
  check("highlight-group colour accepted",
    #config.validate({ colors = { signal_hl = "String" } }) == 0)
  check("non-string keymap flagged", #config.validate({ keymaps = { zoom_in = 7 } }) == 1)
  check("back keymap accepted", #config.validate({ keymaps = { back = "<BS>" } }) == 0)
end

print("\n" .. string.rep("=", 50))
print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
print(string.rep("=", 50))
if failed > 0 then vim.cmd("cq") end
