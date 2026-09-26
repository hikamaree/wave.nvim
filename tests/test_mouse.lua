-- Mouse wiring. The gesture logic is covered deterministically in
-- test_app.lua; this proves the bindings are reached by real mouse events,
-- which needs an event loop, so it runs without -l and drives itself.
--
--   nvim --headless -u tests/test_mouse.lua </dev/null

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.mouse = "a"

local wave = require("wave")
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

assert(wave.setup({}), "wave.setup() failed")
wave.open_file("tests/samples/jtag.vcd")

local fired = {}
local GESTURES = {
  "mouse_click", "mouse_drag", "mouse_double_click",
  "mouse_zoom", "scroll_signals", "scroll_time",
}

-- Recorded as the events land, since a click's effect can only be read back
-- once the loop has consumed the input.
local observed = {}

local steps = {
  function(s)
    for _, name in ipairs(GESTURES) do
      local original = s[name]
      s[name] = function(self, ...)
        fired[name] = (fired[name] or 0) + 1
        return original(self, ...)
      end
    end
    for i = 1, 14 do
      s:add_trace(SignalRef.new({ signal_id = 500 + i, path = "tb.sig" .. i, width = 8 }))
    end
  end,
  function(s)
    -- Click a known column; the cursor bar must be drawn in that column.
    observed.gutter = s.viewer.layout.cursor_offset
    observed.clicked_col = 12
    -- nvim_input_mouse columns are 0-based; getmousepos().wincol is 1-based.
    vim.api.nvim_input_mouse("left", "press", "", 0, 7, observed.gutter + observed.clicked_col)
  end,
  function(s) observed.drawn_col = s.viewer.layout.cursor_col end,
  function() vim.api.nvim_input_mouse("left", "drag", "", 0, 9, 55) end,
  function(s)
    s.row_offset = 0
    s:render()
    vim.api.nvim_input_mouse("wheel", "down", "", 0, 9, 40)
  end,
  function(s)
    observed.wheel_offset = s.row_offset
    observed.wheel_top = s.viewer.layout.rows[s.viewer.layout.body_first].kind
    vim.api.nvim_input_mouse("wheel", "down", "", 0, 9, 40)
  end,
  function(s)
    observed.wheel_offset2 = s.row_offset
    observed.wheel_top2 = s.viewer.layout.rows[s.viewer.layout.body_first].kind
  end,
  function() vim.api.nvim_input_mouse("wheel", "up", "S", 0, 9, 40) end,
  function() vim.api.nvim_input_mouse("wheel", "up", "C", 0, 9, 40) end,
  -- A double click has to arrive inside 'mousetime', so both presses go in
  -- the same tick rather than as separate steps.
  function()
    vim.api.nvim_input_mouse("left", "press", "", 0, 7, 40)
    vim.api.nvim_input_mouse("left", "press", "", 0, 7, 40)
  end,
}

local index = 0
local function step()
  index = index + 1
  local session = wave.session()
  if steps[index] and session then steps[index](session) end

  if index < #steps then
    vim.defer_fn(step, 250)
    return
  end

  vim.defer_fn(function()
    check("a session was opened", session ~= nil)
    check("left click reaches the viewer", (fired.mouse_click or 0) > 0)
    check("drag reaches the viewer", (fired.mouse_drag or 0) > 0)
    check("double click reaches the viewer", (fired.mouse_double_click or 0) > 0)
    check("ctrl-wheel reaches the zoom", (fired.mouse_zoom or 0) > 0)
    check("wheel scrolls the signal list", (fired.scroll_signals or 0) > 0)
    check("shift-wheel pans time", (fired.scroll_time or 0) > 0)

    if session then
      check("clicking placed a time cursor", session.cursor_time ~= nil)

      -- The bar must land in the column that was clicked, not beside it.
      check("the cursor bar lands in the clicked column",
        observed.drawn_col == observed.clicked_col,
        tostring(observed.drawn_col) .. " vs " .. tostring(observed.clicked_col))

      check("the wheel moved the body", (observed.wheel_offset or 0) > 0, observed.wheel_offset)
      check("the wheel kept moving", (observed.wheel_offset2 or 0) > (observed.wheel_offset or 0),
        tostring(observed.wheel_offset2))
      check("the wheel lands on a whole signal", observed.wheel_top == "wave_top", observed.wheel_top)
      check("and again on the next notch", observed.wheel_top2 == "wave_top", observed.wheel_top2)
    end

    print(string.rep("=", 50))
    print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
    print(string.rep("=", 50))
    vim.cmd(failed > 0 and "cq" or "qa!")
  end, 400)
end

vim.defer_fn(step, 900)
