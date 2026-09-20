-- Unit tests for the pure model layer. No Neovim required:
--   lua tests/test_model.lua
-- The zoom ladder in particular had no coverage before the refactor.

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
  -- Shrinking is tolerated down to half the span; past that the window is
  -- slid back instead, so a clamp never collapses the view.
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
