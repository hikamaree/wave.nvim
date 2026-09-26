-- App-level command tests: the entry points the user commands drive.
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

print("\n--- the viewer appears before parsing finishes ---")
do
  -- Opening must not wait on the parser.
  wave.close_all()
  require("wave.app").stop()
  wave.setup({})

  wave.open_file(OTHER)
  local immediate = wave.session()
  check("session exists with no wait", immediate ~= nil)
  if immediate then
    check("viewer window is already up", immediate:viewer_open())
    -- These samples are small, so accept either state.
    local layout = immediate:build_layout(80, 24)
    local body = ""
    for _, row in ipairs(layout.rows) do body = body .. row.text .. "\n" end
    if immediate.loading then
      check("loading screen shown while parsing", body:match("Parsing waveform") ~= nil, body)
    else
      check("parsed already, real viewer shown", body:match("Parsing waveform") == nil)
    end
  end

  settle(2500)
  local done = wave.session()
  check("loading clears once parsed", done and done.loading == false)
  check("spinner timer stopped", done and done.spinner_timer == nil)
  check("viewport adopted from the file", done and done.viewport.file_end > 0)
end

print("\n--- viewer keys are inert while parsing ---")
do
  local Session = require("wave.session")
  local Actions = require("wave.actions")
  local Client = require("wave.ipc.client")
  local client = Client.new("cmd/target/release/wave")
  client:start()

  local loading = Session.new(client, "/tmp/never-parsed.vcd")
  loading:show_viewer()
  local handlers = Actions.handlers(loading)

  -- The placeholder spans 0..1050; acting on it strands a cursor past the end.
  handlers.cursor()
  handlers.zoom_in()
  handlers.scroll_right()
  handlers.next_edge()
  check("no cursor placed while parsing", loading.cursor_time == nil)
  check("zoom untouched while parsing", loading.viewport.zoom_n == -2)

  loading:loaded({ time_end = 200, time_unit = "ns" })
  check("cursor still unset after parse", loading.cursor_time == nil)
  check("viewport came from the file", loading.viewport.t1 == 210, loading.viewport.t1)

  -- close and help must keep working on the loading screen.
  local other = Session.new(client, "/tmp/also-never.vcd")
  other:show_viewer()
  Actions.handlers(other).close()
  check("close works while parsing", not other:viewer_open())

  loading:close()
  other:close()
  client:stop()
end

print("\n--- cursor and scroll are safe on the loading screen ---")
do
  -- Opening a slow file put the loading screen up, and the first cursor
  -- movement crashed in CursorMoved: the loading layout had no body_first.
  local Session = require("wave.session")
  local Client = require("wave.ipc.client")
  local client = Client.new("cmd/target/release/wave")
  client:start()

  local parsing = Session.new(client, "/tmp/still-parsing.vcd")
  parsing:show_viewer()
  check("the loading screen is up", parsing.loading and parsing:viewer_open())

  for _, case in ipairs({
    { "clamp_cursor", function() return parsing:clamp_cursor(1) end },
    { "move_cursor down", function() parsing:move_cursor(1) end },
    { "move_cursor up", function() parsing:move_cursor(-1) end },
    { "scroll_signals", function() parsing:scroll_signals(3) end },
    { "scroll to the end", function() parsing:scroll_extreme(true) end },
    { "scroll to the top", function() parsing:scroll_extreme(false) end },
    { "trace under the cursor", function() return parsing.viewer:under_cursor() end },
    { "click", function() parsing:mouse_click({ line = 3, wincol = 40 }) end },
    { "drag", function() parsing:mouse_drag({ line = 3, wincol = 40 }) end },
    { "double click", function() parsing:mouse_double_click({ line = 3, wincol = 40 }) end },
    { "ctrl-wheel zoom", function() parsing:mouse_zoom(true, { line = 3, wincol = 40 }) end },
    { "render", function() parsing:render() end },
  }) do
    local ok, err = pcall(case[2])
    check("loading screen survives " .. case[1], ok, err)
  end

  check("nothing was selected while parsing", parsing.cursor_time == nil)
  parsing:close()
  client:stop()
end

print("\n--- the spinner stops when there is nothing to animate ---")
do
  -- Never finishes loading, so the spinner lifecycle stays observable.
  local Session = require("wave.session")
  local Client = require("wave.ipc.client")
  local client = Client.new("cmd/target/release/wave")
  check("probe client starts", client:start())

  local stuck = Session.new(client, "/tmp/never-parsed.vcd")
  stuck:show_viewer()
  settle(250)
  check("spinner runs while visible", stuck.spinner_frame > 0, stuck.spinner_frame)

  -- Closing mid-parse must not leave the timer firing against a dead window.
  stuck:hide_viewer()
  settle(300)
  check("timer released when the viewer closes", stuck.spinner_timer == nil)
  local frozen = stuck.spinner_frame
  settle(250)
  check("no work while hidden", stuck.spinner_frame == frozen, stuck.spinner_frame)

  -- Reopening before the parse finishes resumes it.
  stuck:show_viewer()
  settle(300)
  check("spinner resumes on reopen", stuck.spinner_frame > frozen)

  stuck:close()
  check("timer released on close", stuck.spinner_timer == nil)
  client:stop()
end

print("\n--- a file that cannot be opened leaves no stuck session ---")
do
  -- Missing file: rejected before a session or window is ever made.
  wave.close_all()
  require("wave.app").stop()
  wave.setup({})
  wave.open_file("tests/samples/nope.vcd")
  settle(500)
  check("no session for a missing file", wave.session() == nil)

  -- Readable but not a waveform: the window is already up when it fails.
  local before_buf = vim.api.nvim_get_current_buf()
  wave.open_file("tests/samples/not_a_waveform.vcd")
  check("window opened before the parse failed", wave.session() ~= nil)
  settle(2500)
  check("no session after the parser rejects it", wave.session() == nil)
  check("returned to the previous buffer", vim.api.nvim_get_current_buf() == before_buf)
  check("landed somewhere usable", vim.bo[vim.api.nvim_get_current_buf()].modifiable)
end

wave.open_file(SAMPLE)
settle(2000)
session = wave.session()

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

print("\n--- scrolling keeps the chrome in place ---")
do
  wave.close_all()
  require("wave.app").stop()
  wave.setup({})
  wave.open_file(SAMPLE)
  settle(2000)
  local sess = wave.session()
  for i = 0, 15 do
    sess:add_trace(SignalRef.new({ signal_id = 100 + i, path = "tb.s" .. i, width = 1 }))
  end
  settle(1500)

  local win = sess:viewer_window()
  local function lines()
    return vim.api.nvim_buf_get_lines(win:buffer(), 0, -1, false)
  end

  check("buffer matches the window height", #lines() == win:height(),
    #lines() .. " vs " .. win:height())
  check("there is more to scroll than fits", sess.viewer.layout.max_offset > 0,
    sess.viewer.layout.max_offset)

  local header = lines()[1]
  local keybar = lines()[#lines()]
  check("header names the file", header:match("random_counter") ~= nil)
  check("key bar is the last line", keybar:match("q:close") ~= nil)

  -- Scroll through every position; the chrome must never move, and every one
  -- must start on a whole signal.
  local moved_body = false
  local partial = 0
  local first_body = lines()[5]
  for _ = 1, 200 do
    if not sess:scroll_signals(1) then break end
    if sess.viewer.layout.rows[sess.viewer.layout.body_first].kind ~= "wave_top" then
      partial = partial + 1
    end
    local L = lines()
    if L[1] ~= header or L[#L] ~= keybar or #L ~= win:height() then
      check("chrome stayed put at offset " .. sess.row_offset, false)
      break
    end
    if L[5] ~= first_body then moved_body = true end
  end
  check("chrome survived every scroll position", lines()[1] == header
    and lines()[#lines()] == keybar)
  check("the body actually scrolled", moved_body)
  check("no scroll position starts mid-signal", partial == 0, partial)

  sess:scroll_extreme(true)
  check("cannot scroll past the end", sess:scroll_signals(1) == false)
  sess:scroll_extreme(false)
  check("jump to top", sess.row_offset == 0)
  sess:scroll_extreme(true)
  check("jump to bottom", sess.row_offset == sess.viewer.layout.max_offset)

  -- Clicking snaps to a transition inside the clicked column, so an edge can
  -- be selected exactly even when a column spans many time units.
  sess.row_offset = 0
  sess:render()
  local edges = sess.traces:edge_index()
  if edges:count() > 0 then
    local snapped = 0
    for col = 4, 24 do
      local t = sess:time_under(sess.viewer.layout.cursor_offset + col)
      if t and edges:floor(t) == t then snapped = snapped + 1 end
    end
    check("clicks snap onto transitions", snapped > 0, snapped)
  end

  -- The cursor is held inside the body, off the header and key bar.
  sess.row_offset = 0
  sess:render()
  local body_first = sess.viewer.layout.body_first
  local body_last = sess.viewer.layout.body_last
  check("cursor off the header", sess:clamp_cursor(1) == body_first)
  check("cursor off the key bar", sess:clamp_cursor(#lines()) == body_last)
  check("cursor left alone inside the body", sess:clamp_cursor(body_first + 1) == body_first + 1)
end

print("\n--- a count on j travels as far as the presses would ---")
do
  wave.close_all()
  require("wave.app").stop()
  wave.setup({})
  wave.open_file(SAMPLE)
  settle(2000)
  local sess = wave.session()
  for i = 0, 15 do
    sess:add_trace(SignalRef.new({ signal_id = 400 + i, path = "tb.c" .. i, width = 1 }))
  end
  settle(1500)

  local layout = sess.viewer.layout
  check("there is more than one screenful", layout.max_offset > 0, layout.max_offset)

  -- A count must not collapse to a single step: this reached one signal when
  -- move_cursor stopped tracking how far past the edge the count went.
  sess.row_offset = 0
  sess:render()
  sess.viewer:place_cursor(sess.viewer.layout.body_first)
  sess:move_cursor(200)
  check("a big count reaches the end", sess.row_offset == sess.viewer.layout.max_offset,
    sess.row_offset .. " of " .. sess.viewer.layout.max_offset)

  sess:move_cursor(-200)
  check("and comes all the way back", sess.row_offset == 0, sess.row_offset)

  -- A count that fits inside the body must move the cursor without scrolling.
  local body_first = sess.viewer.layout.body_first
  sess.viewer:place_cursor(body_first)
  sess:move_cursor(2)
  check("a small count moves the cursor", sess.viewer.window:cursor_line() == body_first + 2,
    sess.viewer.window:cursor_line())
  check("a small count does not scroll", sess.row_offset == 0, sess.row_offset)

  -- Stepping off the top at the very top must stay put.
  sess.viewer:place_cursor(body_first)
  sess:move_cursor(-5)
  check("cannot step above the first signal", sess.row_offset == 0
    and sess.viewer.window:cursor_line() == body_first)
end

print("\n--- mouse gestures ---")
do
  wave.close_all()
  require("wave.app").stop()
  wave.setup({})
  wave.open_file(SAMPLE)
  settle(2000)
  local sess = wave.session()
  for i = 0, 11 do
    sess:add_trace(SignalRef.new({ signal_id = 700 + i, path = "tb.m" .. i, width = 8 }))
  end
  settle(1500)

  local layout = sess.viewer.layout
  local gutter = layout.cursor_offset
  local body_first, body_last = layout.body_first, layout.body_last

  -- Clicking the waveform drops the time cursor and selects the row.
  sess:mouse_click({ line = body_first + 1, wincol = gutter + 8 })
  local first_time = sess.cursor_time
  check("click sets the time cursor", first_time ~= nil)
  check("click selects the row", sess.viewer.window:cursor_line() == body_first + 1,
    sess.viewer.window:cursor_line())

  sess:mouse_click({ line = body_first + 1, wincol = gutter + 30 })
  check("clicking further right reads later", sess.cursor_time > first_time,
    tostring(sess.cursor_time) .. " vs " .. tostring(first_time))

  -- Clicking the label gutter selects without moving the time cursor.
  local held = sess.cursor_time
  sess:mouse_click({ line = body_first + 4, wincol = 2 })
  check("label click leaves the time alone", sess.cursor_time == held)
  check("label click still selects", sess.viewer.window:cursor_line() == body_first + 4)

  -- The chrome is not selectable.
  sess:mouse_click({ line = 1, wincol = gutter + 5 })
  check("click on the header clamps into the body",
    sess.viewer.window:cursor_line() == body_first, sess.viewer.window:cursor_line())
  sess:mouse_click({ line = body_last + 2, wincol = gutter + 5 })
  check("click on the key bar clamps into the body",
    sess.viewer.window:cursor_line() == body_last, sess.viewer.window:cursor_line())

  -- Dragging scrubs the time without changing the selected row.
  sess:mouse_click({ line = body_first + 2, wincol = gutter + 5 })
  local row = sess.viewer.window:cursor_line()
  sess:mouse_drag({ line = body_last, wincol = gutter + 40 })
  check("drag moves the time cursor", sess.cursor_time ~= nil)
  check("drag keeps the selected row", sess.viewer.window:cursor_line() == row)

  -- Wheel scrolls the list; the chrome stays pinned.
  sess.row_offset = 0
  sess:render()
  local head = vim.api.nvim_buf_get_lines(sess.viewer.buffer.handle, 0, 1, false)[1]
  sess:scroll_signals(3)
  check("wheel scrolls the body", sess.row_offset > 0, sess.row_offset)
  -- Scrolling counts signals, so it lands on a stop, never mid-signal.
  check("scrolling lands on a stop",
    sess.viewer.layout:next_stop(sess.row_offset - 1) == sess.row_offset
      or sess.row_offset == 0, sess.row_offset)
  check("the top row is a whole signal",
    sess.viewer.layout.rows[sess.viewer.layout.body_first].kind == "wave_top",
    sess.viewer.layout.rows[sess.viewer.layout.body_first].kind)
  check("wheel leaves the header alone",
    vim.api.nvim_buf_get_lines(sess.viewer.buffer.handle, 0, 1, false)[1] == head)

  -- Ctrl-wheel zooms about the pointer.
  local span = sess.viewport:range()
  sess:mouse_zoom(true, { line = body_first, wincol = gutter + 20 })
  check("ctrl-wheel zooms in", sess.viewport:range() < span,
    sess.viewport:range() .. " vs " .. span)
  local zoomed = sess.viewport:range()
  sess:mouse_zoom(false, { line = body_first, wincol = gutter + 20 })
  check("ctrl-wheel zooms out", sess.viewport:range() > zoomed)

  -- Double-clicking a bus expands it.
  sess.row_offset = 0
  sess:render()
  local trace = sess.viewer.layout:at(body_first)
  check("a bus is under the pointer", trace ~= nil and trace.ref:is_multi_bit())
  if trace then
    local was = trace.expanded
    sess:mouse_double_click({ line = body_first, wincol = 5 })
    check("double click expands the bus", trace.expanded ~= was)
  end

  -- Nothing may act on a pointer outside the window, or while parsing.
  local ok = pcall(function()
    sess:mouse_click(nil); sess:mouse_drag(nil); sess:mouse_double_click(nil)
    sess:mouse_zoom(true, nil)
  end)
  check("a pointer outside the window is ignored", ok)

  sess.loading = true
  local frozen = sess.cursor_time
  sess:mouse_click({ line = body_first, wincol = gutter + 50 })
  check("clicks do nothing while parsing", sess.cursor_time == frozen)
  sess.loading = false
end

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
