-- Unit tests for the pure model layer. No Neovim required:
--   lua tests/test_model.lua

package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local TimeScale = require("wave.model.time_scale")
local Viewport = require("wave.model.viewport")
local EdgeIndex = require("wave.model.edge_index")
local TraceList = require("wave.model.trace_list")
local SignalRef = require("wave.model.signal_ref")

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

local function close(a, b)
  return math.abs(a - b) < 1e-6
end

print("--- TimeScale ---")
do
  local s = TimeScale.new(0, 100, 50)
  check("to_time at 0", close(s:to_time(0), 0))
  check("to_time midpoint", close(s:to_time(25), 50))
  check("to_col clamps low", s:to_col(-10) == 0)
  check("to_col clamps high", s:to_col(1000) == 49)
  check("to_col is inverse-ish", s:to_col(s:to_time(20)) == 19 or s:to_col(s:to_time(20)) == 20)

  local degenerate = TimeScale.new(5, 5, 40)
  check("zero range gives col 0", degenerate:to_col(5) == 0)
end

print("\n--- Viewport: ladder ---")
do
  local vp = Viewport.new(1000)
  check("starts zoomed out", vp.zoom_n == -2)
  check("zoom value of -2 is 1/2", close(vp:zoom_value(), 0.5))
  check("label of -2", vp:zoom_label() == "1/2")

  vp.zoom_n = 1
  check("zoom value of 1", close(vp:zoom_value(), 1))
  vp.zoom_n = 4
  check("zoom value of 4", close(vp:zoom_value(), 4))
  check("label of 4", vp:zoom_label() == "4")

  -- The rungs: -2 -> 1 -> 2 -> 4 -> 6 ... and back down again.
  local up = Viewport.new(1000)
  up.zoom_n = -2
  local seen = {}
  for _ = 1, 4 do
    up.zoom_n = up:_next_zoom_in()
    seen[#seen + 1] = up.zoom_n
  end
  check("zoom-in ladder", table.concat(seen, ",") == "1,2,4,6", table.concat(seen, ","))

  local down = Viewport.new(1000)
  down.zoom_n = 4
  seen = {}
  for _ = 1, 4 do
    down.zoom_n = down:_next_zoom_out()
    seen[#seen + 1] = down.zoom_n
  end
  check("zoom-out ladder", table.concat(seen, ",") == "2,1,-2,-4", table.concat(seen, ","))

  -- Past the linear limit the ladder doubles instead of stepping.
  local deep = Viewport.new(1000)
  deep.zoom_n = -8
  check("doubles past the limit", deep:_next_zoom_out() == -16)
  deep.zoom_n = -16
  check("halves coming back", deep:_next_zoom_in() == -8)
end

print("\n--- Viewport: span ---")
do
  local vp = Viewport.new(1000)
  check("initial span covers the file", vp.t0 == 0 and close(vp.t1, 1050))
  check("max_time has margin", close(vp:max_time(), 1050))

  vp.t0, vp.t1 = 100, 200
  check("range", close(vp:range(), 100))
  check("center", close(vp:center(), 150))

  vp:pan(1)
  check("pan right moves forward", vp.t0 > 100)
  check("pan right keeps the span", close(vp:range(), 100))

  vp.t0, vp.t1 = 0, 100
  vp:pan(-1)
  check("pan left stops at zero", vp.t0 == 0)
  check("pan left keeps the span", close(vp:range(), 100))

  -- Panning right at the end must not shrink the window.
  vp.t0, vp.t1 = 1000, 1050
  vp:pan(1)
  check("pan right at the end keeps the span", close(vp:range(), 50), vp:range())

  vp.t0, vp.t1 = 900, 1200
  vp:clamp()
  check("clamp pulls back inside", close(vp.t1, 1050))
  -- Shrink is tolerated to half the span; past that the window slides back.
  check("clamp shrinks at most half", vp:range() >= 150, vp:range())

  vp.t0, vp.t1 = 1000, 1400
  vp:clamp()
  check("clamp slides back rather than collapse", close(vp:range(), 400), vp:range())
  check("slid window ends at the limit", close(vp.t1, 1050))
end

print("\n--- Viewport: follow ---")
do
  local vp = Viewport.new(10000)
  vp.t0, vp.t1 = 100, 200

  vp:follow(150)
  check("cursor inside does not move the view", close(vp.t0, 100))

  vp:follow(195)
  check("cursor near the right edge slides forward", vp.t0 > 100)
  check("follow keeps the span", close(vp:range(), 100))

  vp.t0, vp.t1 = 100, 200
  vp:follow(102)
  check("cursor near the left edge slides back", vp.t0 < 100)
end

print("\n--- Viewport: zoom guards ---")
do
  -- With no period known, zoom falls back to scaling the span.
  local vp = Viewport.new(1000)
  vp.t0, vp.t1 = 0, 400
  check("zoom in without a period scales", vp:zoom_in(nil, 80, nil) == true)
  check("span halved", close(vp:range(), 200), vp:range())

  -- Fully zoomed out already: zoom_out is a no-op.
  local out = Viewport.new(1000)
  check("zoom out at the limit does nothing", out:zoom_out(10, 80, nil) == false)

  -- Too few columns for the arithmetic to mean anything.
  local narrow = Viewport.new(1000)
  narrow.t0, narrow.t1 = 0, 100
  local before = narrow:range()
  narrow:apply_zoom(10, 5, nil)
  check("apply_zoom ignores a tiny window", close(narrow:range(), before))

  -- sync_zoom is the inverse of apply_zoom.
  local sync = Viewport.new(100000)
  sync.zoom_n = 4
  sync:apply_zoom(10, 80, nil)
  local span = sync:range()
  sync.zoom_n = -2
  sync:sync_zoom(10, 80)
  check("sync recovers the rung", sync.zoom_n == 4, sync.zoom_n)
  check("sync leaves the span alone", close(sync:range(), span))
end

print("\n--- EdgeIndex ---")
do
  local traces = {
    { value_changes = { { 0, "0" }, { 10, "1" }, { 20, "0" } } },
    { value_changes = { { 5, "0" }, { 10, "1" }, { 30, "1" } } },
  }
  local idx = EdgeIndex.build(traces)
  check("de-duplicates across traces", idx:count() == 5, idx:count())
  check("sorted", table.concat(idx.times, ",") == "0,5,10,20,30")

  check("next is strict", idx:next(10) == 20)
  check("prev is strict", idx:prev(10) == 5)
  check("floor includes the point", idx:floor(10) == 10)
  check("next past the end is nil", idx:next(30) == nil)
  check("prev before the start is nil", idx:prev(0) == nil)

  check("nearest hits an exact edge", idx:nearest(10) == 10)
  check("nearest rounds down", idx:nearest(11) == 10)
  check("nearest rounds up", idx:nearest(19) == 20)
  check("nearest ties go earlier", idx:nearest(15) == 10)
  check("nearest past the end", idx:nearest(1000) == 30)

  local empty = EdgeIndex.build({})
  check("empty index returns nil", empty:nearest(5) == nil and empty:next(5) == nil)
end

print("\n--- SignalRef ---")
do
  local ref = SignalRef.from_search({ instance_path = "top.bus", signal_id = 3, width = 8, msb = 7, lsb = 0 })
  check("path from instance_path", ref.path == "top.bus")
  check("multi bit", ref:is_multi_bit())
  check("suffix from msb/lsb", ref:bit_suffix() == "[7:0]")

  local bare = SignalRef.from_var({ name = "clk", signal_id = 1 })
  check("path falls back to name", bare.path == "clk")
  check("width defaults to 1", bare.width == 1)
  check("single bit has no suffix", bare:bit_suffix() == "")

  local no_index = SignalRef.new({ path = "b", width = 4 })
  check("suffix derived from width", no_index:bit_suffix() == "[3:0]")
end

print("\n--- SignalRef: leaf name ---")
do
  -- Displayed as the leaf; the full path is kept for identity.
  local deep = SignalRef.from_search({ instance_path = "tb.cpu.core.clk", signal_id = 1 })
  check("leaf of a deep path", deep.name == "clk", deep.name)
  check("full path retained", deep.path == "tb.cpu.core.clk")

  local flat = SignalRef.from_search({ instance_path = "clk", signal_id = 2 })
  check("leaf of a bare name", flat.name == "clk")

  local indexed = SignalRef.from_search({ instance_path = "tb.mem.data[3]", signal_id = 3 })
  check("index kept on the leaf", indexed.name == "data[3]", indexed.name)

  -- A netlist var carries an authoritative name; prefer it over splitting.
  local var = SignalRef.from_var({ name = "rstn", instance_path = "tb.top.rstn" })
  check("parser name wins", var.name == "rstn")
  check("parser path kept", var.path == "tb.top.rstn")

  -- Vars whose own name contains a dot must not be split.
  local dotted = SignalRef.from_var({ name = "a.b", instance_path = "tb.a.b" })
  check("dotted var name not split", dotted.name == "a.b", dotted.name)

  -- The paths disagree for a name holding a dot: SearchEntry has no name
  -- field, so the picker can only split. Known limit.
  local from_netlist = SignalRef.from_var({ name = "a.b", instance_path = "tb.a.b" })
  local from_picker = SignalRef.from_search({ instance_path = "tb.a.b" })
  check("netlist keeps the dotted name", from_netlist.name == "a.b")
  check("picker can only take the leaf", from_picker.name == "b")
  check("both agree on the path", from_netlist.path == from_picker.path)

  -- A repeated leaf is not disambiguated; identity stays on signal_id.
  local cpu = SignalRef.from_search({ instance_path = "tb.cpu.clk", signal_id = 1 })
  local mem = SignalRef.from_search({ instance_path = "tb.mem.clk", signal_id = 2 })
  check("colliding leaves render alike", cpu.name == mem.name)
  check("but remain distinct signals", cpu.signal_id ~= mem.signal_id)

  local none = SignalRef.new({ signal_id = 4 })
  check("missing path gives no name", none.name == nil)

  local explicit = SignalRef.new({ path = "x.y.z", name = "override" })
  check("explicit name wins", explicit.name == "override")
end

print("\n--- LoadingLayout ---")
do
  local LoadingLayout = require("wave.render.loading_layout")

  local layout = LoadingLayout.build({
    file_name = "big.vcd", frame = 0, elapsed_ms = 0,
    total_cols = 80, total_rows = 24,
  })
  local text = {}
  for _, row in ipairs(layout.rows) do text[#text + 1] = row.text end
  local body = table.concat(text, "\n")

  check("names the file", body:match("big%.vcd") ~= nil)
  check("says what it is doing", body:match("Parsing waveform") ~= nil)
  check("no elapsed time early on", body:match("%d%.%ds") == nil, body)
  check("cursor lookups find nothing", LoadingLayout.at() == nil)

  -- The spinner advances and wraps.
  local first = LoadingLayout.spinner(0)
  check("spinner turns", LoadingLayout.spinner(1) ~= first)
  check("spinner wraps", LoadingLayout.spinner(10) == first)

  -- Elapsed time appears once the wait is worth reporting.
  local slow = LoadingLayout.build({
    file_name = "big.vcd", frame = 2, elapsed_ms = 4200,
    total_cols = 80, total_rows = 24,
  })
  local slow_body = ""
  for _, row in ipairs(slow.rows) do slow_body = slow_body .. row.text .. "\n" end
  check("shows elapsed once slow", slow_body:match("4%.2s") ~= nil, slow_body)

  -- The message is centred, and a narrow window must not produce a negative pad.
  local narrow = LoadingLayout.build({
    file_name = "b.vcd", frame = 0, elapsed_ms = 0, total_cols = 4, total_rows = 6,
  })
  for _, row in ipairs(narrow.rows) do
    check("no negative padding at " .. #row.text, row.text:match("^%s*") ~= nil)
  end
end

print("\n--- ValueChanges: range lookups ---")
do
  local VC = require("wave.model.value_changes")
  local vc = {}
  for i = 0, 9 do vc[i + 1] = { i * 10, tostring(i) } end   -- times 0,10,..,90

  check("index_at exact", VC.index_at(vc, 30) == 4)
  check("index_at between", VC.index_at(vc, 35) == 4)
  check("index_at before all", VC.index_at(vc, -5) == 1)
  check("index_at after all", VC.index_at(vc, 999) == 10)

  check("first_from exact", VC.first_from(vc, 30) == 4)
  check("first_from between", VC.first_from(vc, 31) == 5)
  check("first_from before all", VC.first_from(vc, -5) == 1)
  check("first_from after all", VC.first_from(vc, 999) == 11)

  local function span(t0, t1)
    local a, b = VC.range(vc, t0, t1)
    return b - a + 1
  end
  check("range covering all", span(0, 90) == 10)
  check("range inclusive at both ends", span(20, 40) == 3)
  check("range between points", span(21, 39) == 1)
  check("range entirely before", span(-20, -10) == 0)
  check("range entirely after", span(200, 300) == 0)
  check("range of a single point", span(50, 50) == 1)
  check("nil start means everything", select(2, VC.range(vc, nil, nil)) == 10)

  check("empty input is empty", select(2, VC.range({}, 0, 10)) == 0)
end

print("\n--- ViewerLayout: pinned chrome ---")
do
  local ViewerLayout = require("wave.render.viewer_layout")
  local Viewport = require("wave.model.viewport")
  local SignalRef = require("wave.model.signal_ref")
  local Trace = require("wave.model.trace")

  local traces = {}
  for i = 1, 20 do
    local t = Trace.new(SignalRef.new({ signal_id = i, path = "sig" .. i, width = 1 }))
    t:set_data({ { 0, "0" }, { 50, "1" } }, 100, { 0, 200 })
    traces[i] = t
  end

  local function build(rows, offset)
    return ViewerLayout.build({
      traces = traces, viewport = Viewport.new(1000), time_unit = "ns",
      file_name = "f.vcd", total_cols = 80, total_rows = rows,
      row_offset = offset, keymaps = { close = "q" }, help_groups = { { "close" } },
    })
  end

  local layout = build(24, 0)
  check("fills the window exactly", #layout.rows == 24, #layout.rows)
  check("header first", layout.rows[1].kind == "header")
  check("ruler pinned", layout.rows[2].kind == "ruler_nums" and layout.rows[3].kind == "ruler_ticks")
  check("key bar last", layout.rows[24].kind == "keys")

  -- The chrome must stay put at every scroll position, which is the point.
  local mid = build(24, 5)
  local bottom = build(24, layout.max_offset)
  for _, l in ipairs({ mid, bottom }) do
    check("header still first", l.rows[1].kind == "header")
    check("ruler still pinned", l.rows[3].kind == "ruler_ticks")
    check("key bar still last", l.rows[#l.rows].kind == "keys")
    check("still exactly one window", #l.rows == 24)
  end

  check("scrolling changes the body", mid.rows[5].text ~= layout.rows[5].text)
  check("offset clamped to the end", build(24, 9999).row_offset == layout.max_offset)
  check("offset clamped at zero", build(24, -50).row_offset == 0)

  -- A short window must still produce a usable screen.
  local tiny = build(7, 0)
  check("tiny window still has chrome", tiny.rows[1].kind == "header"
    and tiny.rows[#tiny.rows].kind == "keys")
  check("tiny window keeps a body row", ViewerLayout.body_height(7) >= 1)

  -- Fewer traces than fit: no scrolling offered.
  local few = ViewerLayout.build({
    traces = { traces[1] }, viewport = Viewport.new(1000), time_unit = "ns",
    file_name = "f.vcd", total_cols = 80, total_rows = 30,
    row_offset = 0, keymaps = { close = "q" }, help_groups = { { "close" } },
  })
  check("nothing to scroll when it all fits", few.max_offset == 0)
  check("short list still fills the window", #few.rows == 30)
end

print("\n--- ViewerLayout: pointer to time ---")
do
  local ViewerLayout = require("wave.render.viewer_layout")
  local Viewport = require("wave.model.viewport")
  local SignalRef = require("wave.model.signal_ref")
  local Trace = require("wave.model.trace")

  local tr = Trace.new(SignalRef.new({ signal_id = 1, path = "tb.clk", width = 1 }))
  tr:set_data({ { 0, "0" }, { 500, "1" } }, 100, { 0, 1000 })

  local vp = Viewport.new(1000)
  vp.t0, vp.t1 = 0, 1000
  local layout = ViewerLayout.build({
    traces = { tr }, viewport = vp, time_unit = "ns", file_name = "f.vcd",
    total_cols = 100, total_rows = 24, row_offset = 0,
    keymaps = { close = "q" }, help_groups = { { "close" } },
  })

  local gutter = layout.cursor_offset       -- label columns before the waveform
  check("label area has no time", layout:time_at(1) == nil)
  check("last gutter column has no time", layout:time_at(gutter) == nil)
  -- A column covers many time units, and only a time inside it maps back to
  -- it, so time_at reports the middle rather than the left boundary.
  local first = layout:time_at(gutter + 1)
  local per_col = (vp.t1 - vp.t0) / layout.wave_cols
  check("first waveform column is inside column 0", first > 0 and first < per_col, first)
  check("first column round-trips to column 0", layout.scale:to_col(first) == 0)

  local from, to = layout:column_span(gutter + 1)
  check("column span starts at t0", from == 0)
  check("column span is one column wide", math.abs((to - from) - per_col) < 1e-9)
  check("the reported time sits inside the span", first > from and first < to)

  local mid = layout:time_at(gutter + math.floor(layout.wave_cols / 2))
  check("mid waveform is mid time", mid > 400 and mid < 600, mid)

  check("last waveform column in range", layout:time_at(gutter + layout.wave_cols) ~= nil)
  check("past the waveform has no time", layout:time_at(gutter + layout.wave_cols + 1) == nil)

  -- Clicking further right must read later, monotonically.
  local prev = -1
  local monotonic = true
  for c = gutter + 1, gutter + layout.wave_cols do
    local t = layout:time_at(c)
    if t <= prev then monotonic = false end
    prev = t
  end
  check("time increases across the waveform", monotonic)

  -- A pointer column round-trips to the column the cursor bar is drawn at.
  -- Every pointer column must round-trip to itself, or the cursor bar lands
  -- beside the transition it was clicked on.
  local off_by = 0
  for c = 1, layout.wave_cols do
    if layout.scale:to_col(layout:time_at(gutter + c)) ~= c - 1 then off_by = off_by + 1 end
  end
  check("every column round-trips exactly", off_by == 0, off_by .. " columns off")

  -- A degenerate viewport must not produce a time.
  local flat = Viewport.new(1000); flat.t0, flat.t1 = 5, 5
  local flat_layout = ViewerLayout.build({
    traces = { tr }, viewport = flat, time_unit = "ns", file_name = "f.vcd",
    total_cols = 100, total_rows = 24, row_offset = 0,
    keymaps = { close = "q" }, help_groups = { { "close" } },
  })
  check("zero-width viewport yields no time", flat_layout:time_at(gutter + 5) == nil)
end

print("\n--- every scroll stop shows a whole signal ---")
do
  local ViewerLayout = require("wave.render.viewer_layout")
  local Viewport = require("wave.model.viewport")
  local SignalRef = require("wave.model.signal_ref")
  local Trace = require("wave.model.trace")

  local function trace(i, w, expanded, points)
    local tr = Trace.new(SignalRef.new({ signal_id = i, path = "s" .. i, width = w }))
    local vc = {}
    for k = 0, (points or 4) do
      vc[#vc + 1] = { k * 10, w > 1 and ("b" .. string.rep("1", w)) or tostring(k % 2) }
    end
    tr:set_data(vc, 20, { 0, 400 })
    tr.expanded = expanded
    return tr
  end

  --- Walks every stop in both directions; the body's first row must always be
  --- a signal, or a value row inside a bus too tall to fit.
  local function walk(name, traces, rows)
    local function build(offset)
      return ViewerLayout.build({ traces = traces, viewport = Viewport.new(400),
        time_unit = "ns", file_name = "f", total_cols = 70, total_rows = rows,
        row_offset = offset, keymaps = { close = "q" }, help_groups = { { "close" } } })
    end

    local function bad_positions(step)
      local offset, bad, guard = step == 1 and 0 or build(0).max_offset, {}, 0
      while guard < 400 do
        guard = guard + 1
        local layout = build(offset)
        local kind = layout.rows[layout.body_first].kind
        if kind ~= "wave_top" and kind ~= "values" then
          bad[#bad + 1] = offset .. "=" .. kind
        end
        local moved = step == 1 and layout:next_stop(offset) or layout:prev_stop(offset)
        if moved == offset then break end
        offset = moved
      end
      return bad, offset
    end

    local down, ended = bad_positions(1)
    local up, started = bad_positions(-1)
    check(name .. ": no bad stop going down", #down == 0, table.concat(down, " "))
    check(name .. ": no bad stop going up", #up == 0, table.concat(up, " "))
    check(name .. ": reaches the end", ended == build(0).max_offset, ended)
    check(name .. ": reaches the top", started == 0, started)
  end

  local plain = {}
  for i = 1, 12 do plain[i] = trace(i, 1, false) end
  walk("12 collapsed", plain, 16)
  walk("expanded in the middle", { trace(1,1,false), trace(2,8,true,20), trace(3,1,false) }, 16)
  walk("bus taller than the window", { trace(1,1,false), trace(2,8,true,60), trace(3,1,false) }, 16)
  -- Two tall buses used to land on a trailing gap between them.
  walk("two tall buses", { trace(1,8,true,40), trace(2,1,false), trace(3,8,true,40) }, 16)
  walk("one signal", { trace(1,1,false) }, 24)
  walk("only a tall bus", { trace(1,8,true,80) }, 16)
end

print("\n--- the time cursor is one unbroken line over the signals ---")
do
  local ViewerLayout = require("wave.render.viewer_layout")
  local Viewport = require("wave.model.viewport")
  local SignalRef = require("wave.model.signal_ref")
  local Trace = require("wave.model.trace")

  local function trace(i, w, expanded)
    local tr = Trace.new(SignalRef.new({ signal_id = i, path = "s" .. i, width = w }))
    local vc = {}
    for k = 0, 5 do
      vc[#vc + 1] = { k * 20, w > 1 and ("b" .. string.rep("1", w)) or tostring(k % 2) }
    end
    tr:set_data(vc, 40, { 0, 200 })
    tr.expanded = expanded
    return tr
  end

  local function build(traces, rows)
    return ViewerLayout.build({ traces = traces, viewport = Viewport.new(200),
      time_unit = "ns", file_name = "f", total_cols = 60, total_rows = rows,
      row_offset = 0, cursor_time = 100,
      keymaps = { close = "q" }, help_groups = { { "close" } } })
  end

  local function span(layout)
    local first, last, holes = nil, nil, 0
    for i, row in ipairs(layout.rows) do
      if row.cursor_track then
        if first and i > last + 1 then holes = holes + (i - last - 1) end
        first = first or i
        last = i
      end
    end
    return first, last, holes
  end

  -- With an expanded bus in the middle, the line used to break across it.
  local expanded = build({ trace(1, 1, false), trace(2, 8, true), trace(3, 1, false) }, 30)
  local first, last, holes = span(expanded)
  check("cursor starts on the ruler ticks", expanded.rows[first].kind == "ruler_ticks")
  check("no gaps through an expanded bus", holes == 0, holes .. " untracked rows inside")

  local values_tracked = 0
  for _, row in ipairs(expanded.rows) do
    if row.kind == "values" and row.cursor_track then values_tracked = values_tracked + 1 end
  end
  check("value rows carry the cursor", values_tracked > 0)

  -- It used to run on through the padding to the key bar.
  check("cursor stops before the padding", expanded.rows[last].kind ~= "pad",
    expanded.rows[last].kind)
  for i = last + 1, #expanded.rows do
    check("nothing tracked at row " .. i, not expanded.rows[i].cursor_track)
  end

  -- A window with room to spare is where the overrun showed worst.
  local roomy = build({ trace(1, 1, false) }, 40)
  local _, roomy_last, roomy_holes = span(roomy)
  check("no gaps with one signal", roomy_holes == 0)
  check("cursor stops at the signal, not the window", roomy_last < roomy.body_last,
    roomy_last .. " of " .. roomy.body_last)

  -- A full window has no padding at all; the line runs to the last signal.
  local full = build({ trace(1,1,false), trace(2,1,false), trace(3,1,false),
                       trace(4,1,false), trace(5,1,false) }, 16)
  local _, _, full_holes = span(full)
  check("no gaps when the body is full", full_holes == 0)
end

print("\n--- both layouts answer the same questions ---")
do
  -- The viewer reads these off whichever screen is current. A field present
  -- on one and missing on the other crashed the cursor handler as soon as a
  -- slow file put the loading screen up.
  local ViewerLayout = require("wave.render.viewer_layout")
  local LoadingLayout = require("wave.render.loading_layout")
  local Viewport = require("wave.model.viewport")
  local SignalRef = require("wave.model.signal_ref")
  local Trace = require("wave.model.trace")

  local tr = Trace.new(SignalRef.new({ signal_id = 1, path = "tb.clk", width = 1 }))
  tr:set_data({ { 0, "0" }, { 50, "1" } }, 100, { 0, 200 })

  local viewer = ViewerLayout.build({
    traces = { tr }, viewport = Viewport.new(1000), time_unit = "ns",
    file_name = "f.vcd", total_cols = 90, total_rows = 24, row_offset = 0,
    keymaps = { close = "q" }, help_groups = { { "close" } },
  })
  local loading = LoadingLayout.build({
    file_name = "f.vcd", frame = 0, elapsed_ms = 0, total_cols = 90, total_rows = 24,
  })

  for _, field in ipairs({ "rows", "body_first", "body_last", "body_rows",
                           "row_offset", "max_offset", "cursor_offset" }) do
    check("loading screen has ." .. field, loading[field] ~= nil, "missing")
    check("viewer has ." .. field, viewer[field] ~= nil, "missing")
  end

  for _, method in ipairs({ "at", "time_at", "column_at", "column_span",
                            "next_stop", "prev_stop" }) do
    check("loading screen answers :" .. method, type(loading[method]) == "function")
    check("viewer answers :" .. method, type(viewer[method]) == "function")
  end

  -- The loading screen has nothing to point at or scroll.
  check("loading screen has no trace under the cursor", loading:at(1) == nil)
  check("loading screen has no time axis", loading:time_at(50) == nil)
  check("loading screen cannot scroll", loading.max_offset == 0)
  check("loading screen body covers its rows", loading.body_last == #loading.rows)
end

print("\n--- TraceList ---")
do
  local list = TraceList.new()
  local trace = list:add(SignalRef.new({ signal_id = 1, path = "a", width = 1 }))
  check("add returns the trace", trace ~= nil)
  check("count", list:count() == 1)

  local dup, err = list:add(SignalRef.new({ signal_id = 1, path = "a" }))
  check("duplicate rejected", dup == nil and err == "Signal already displayed")

  list:add(SignalRef.new({ signal_id = 2, path = "b", width = 8 }))
  check("second added", list:count() == 2)
  check("get by id", list:get(2).ref.path == "b")

  check("no period yet", list:min_period() == nil)
  list:set_data(1, { { 0, "0" }, { 10, "1" } }, 20, { 0, 100 })
  list:set_data(2, { { 0, "b0" }, { 5, "b1" } }, 8, { 0, 100 })
  check("min period is the shortest", list:min_period() == 8)

  -- The index must reflect data loaded after it was first built.
  -- Both traces carry an edge at 0, so the union is three distinct times.
  local idx = list:edge_index()
  check("index is the union of both traces", idx:count() == 3, idx:count())
  list:set_data(1, { { 0, "0" }, { 40, "1" } }, 20, { 0, 100 })
  check("index rebuilt after new data", list:edge_index():next(10) == 40)

  check("remove", list:remove(1) == true and list:count() == 1)
  check("remove missing", list:remove(99) == false)
  list:clear()
  check("clear", list:count() == 0)
end

print("\n--- Trace fetching ---")
do
  local list = TraceList.new()
  local trace = list:add(SignalRef.new({ signal_id = 1, path = "a", width = 4 }))

  check("needs fetch when empty", trace:needs_fetch(0, 100))
  check("can expand a bus", trace:can_expand())
  trace:toggle_expand()
  check("toggle expand", trace.expanded == true)

  local from, to = require("wave.model.trace").fetch_window(100, 200)
  check("window has margin below", from == 0, from)
  check("window has margin above", to == 300, to)

  trace:set_data({}, nil, { 0, 300 })
  check("no fetch inside the window", trace:needs_fetch(100, 200) == false)
  check("fetch when panned past the window", trace:needs_fetch(250, 400) == true)
  check("fetch when zoomed far in", trace:needs_fetch(100, 110) == true)

  trace.loading = true
  check("no fetch while loading", trace:needs_fetch(9000, 9999) == false)
end

print("\n" .. string.rep("=", 50))
print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
print(string.rep("=", 50))
os.exit(failed == 0 and 0 or 1)
