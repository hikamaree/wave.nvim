--- One open waveform file. Owns the domain state; the views are disposable.

local TraceList = require("wave.model.trace_list")
local Trace = require("wave.model.trace")
local Viewport = require("wave.model.viewport")
local LoadingLayout = require("wave.render.loading_layout")
local ViewerLayout = require("wave.render.viewer_layout")
local NetlistTreeMod = require("wave.model.netlist_tree")
local ViewerView = require("wave.ui.viewer_view")
local NetlistView = require("wave.ui.netlist_view")
local HelpPopup = require("wave.ui.help_popup")
local SignalRef = require("wave.model.signal_ref")
local picker = require("wave.ui.picker")
local config = require("wave.config")
local log = require("wave.util.log")
local Actions = require("wave.actions")

local NetlistTree = NetlistTreeMod.NetlistTree

local Session = {}
Session.__index = Session

local MAX_SIGNAL_POINTS = 20000
local DEFAULT_COLS = 80
local SPINNER_INTERVAL_MS = 100

--- Starts loading; call :loaded() when the parser answers.
---@param client ParserClient
---@param path string
---@return Session
function Session.new(client, path)
  local name = vim.fn.fnamemodify(path, ":t")
  return setmetatable({
    client = client,
    path = path,
    file_name = name,
    time_unit = "ns",
    traces = TraceList.new(),
    viewport = Viewport.new(1000),
    tree = NetlistTree.new(0, name),
    cursor_time = nil,
    keymaps = config.options.keymaps,
    help_groups = Actions.groups(),
    viewer = nil,
    netlist = nil,
    netlist_view_state = nil,
    row_offset = 0,
    loading = true,
    spinner_frame = 0,
    started_at = vim.uv.hrtime(),
  }, Session)
end

---@param info table the parser's FileInfo
function Session:loaded(info)
  self.loading = false
  self:_stop_spinner()
  self.time_unit = info.time_unit or "ns"
  self.viewport = Viewport.new(info.time_end or 1000)
  self:render()
end

--- Reports why a keypress did nothing, rather than ignoring it silently.
---@return boolean
function Session:is_busy()
  if not self.loading then return false end
  log.info("Still parsing " .. self.file_name .. "…")
  return true
end

---@return number
function Session:elapsed_ms()
  return (vim.uv.hrtime() - self.started_at) / 1e6
end

function Session:_start_spinner()
  if self.spinner_timer or not self.loading then return end
  self.spinner_timer = vim.uv.new_timer()
  if not self.spinner_timer then return end
  vim.uv.timer_start(self.spinner_timer, SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, function()
    vim.schedule(function()
      -- render() restarts it if the viewer returns before the parse does.
      if not self.loading or not self:viewer_open() then
        self:_stop_spinner()
        return
      end
      self.spinner_frame = self.spinner_frame + 1
      self:render()
    end)
  end)
end

function Session:_stop_spinner()
  if not self.spinner_timer then return end
  vim.uv.timer_stop(self.spinner_timer)
  vim.uv.close(self.spinner_timer)
  self.spinner_timer = nil
end

---@param total_cols number
---@param total_rows number
---@return table
function Session:build_layout(total_cols, total_rows)
  if self.loading then
    return LoadingLayout.build({
      file_name = self.file_name,
      frame = self.spinner_frame,
      elapsed_ms = self:elapsed_ms(),
      total_cols = total_cols,
      total_rows = total_rows,
    })
  end

  return ViewerLayout.build({
    traces = self.traces:all(),
    viewport = self.viewport,
    cursor_time = self.cursor_time,
    time_unit = self.time_unit,
    file_name = self.file_name,
    total_cols = total_cols,
    total_rows = total_rows,
    row_offset = self.row_offset,
    keymaps = self.keymaps,
    help_groups = self.help_groups,
  })
end

-- ─── Views ───

---@return boolean
function Session:viewer_open()
  return self.viewer ~= nil and self.viewer:is_open()
end

---@return boolean
function Session:netlist_open()
  return self.netlist ~= nil and self.netlist:is_open()
end

---@return Window|nil
function Session:viewer_window()
  return self:viewer_open() and self.viewer.window or nil
end

---@return number
function Session:wave_cols()
  return self:viewer_open() and self.viewer:wave_cols() or DEFAULT_COLS
end

function Session:show_viewer()
  if self:viewer_open() then return end
  self.viewer = ViewerView.open(self, {
    keymaps = self.keymaps,
    handlers = Actions.handlers(self),
    repeatable = Actions.repeatable(),
  })
  self:render()
end

function Session:hide_viewer()
  if not self.viewer then return end
  local view = self.viewer
  self.viewer = nil
  view:close()
  self:hide_netlist()
end

function Session:toggle_viewer()
  if self:viewer_open() then self:hide_viewer() else self:show_viewer() end
end

function Session:toggle_netlist()
  if self:is_busy() then return end
  if self:netlist_open() then
    self:hide_netlist()
    return
  end
  self.netlist = NetlistView.open(self, {
    enter = function() self:netlist_enter() end,
    back = function() self:netlist_back() end,
    search = function() self:prompt_add_trace() end,
    close = function() self:hide_netlist() end,
  })
  self.netlist:render()
  self:render()
end

function Session:hide_netlist()
  if not self.netlist then return end
  local view = self.netlist
  self.netlist = nil
  view:close()
  self:render()
end

--- BufWipeout: a view's buffer went away underneath us.
---@param buf number
function Session:on_buffer_wiped(buf)
  if self.viewer and self.viewer.buffer.handle == buf then
    self.viewer = nil
    if self.netlist then
      local view = self.netlist
      self.netlist = nil
      vim.schedule(function() view:close() end)
    end
  elseif self.netlist and self.netlist.buffer.handle == buf then
    local view = self.netlist
    self.netlist = nil
    view:close()
    vim.schedule(function() self:render() end)
  end
end

function Session:render()
  if not self:viewer_open() then return end
  if self.loading then
    self:_start_spinner()
    self.viewer:render()
    return
  end
  self:fetch_visible()
  self.viewport:sync_zoom(self.traces:min_period(), self:wave_cols())
  self.viewer:render()
end

function Session:close()
  self:_stop_spinner()
  self:hide_netlist()
  self:hide_viewer()
end

-- ─── Data ───

function Session:fetch_visible()
  local from, to = Trace.fetch_window(self.viewport.t0, self.viewport.t1)

  for _, trace in ipairs(self.traces:all()) do
    if trace:needs_fetch(self.viewport.t0, self.viewport.t1) then
      trace.loading = true
      self.client:signal_data({ trace.ref.signal_id }, from, to, MAX_SIGNAL_POINTS, function(resp)
        trace.loading = false
        local data = resp.success and resp.data and resp.data[1]
        self.traces:set_data(trace.ref.signal_id, data and data.value_changes,
          data and data.period, { from, to })
        self:render()
      end)
    end
  end
end

--- The screen currently drawn, or nil when there is no window.
---@return table|nil
function Session:layout()
  return self:viewer_open() and self.viewer.layout or nil
end

--- Scrolls the trace list by whole signals. The header and key bar do not
--- move, and the body always starts on a signal rather than on the underside
--- of one.
---@param steps number signals, negative for up
---@return boolean moved
function Session:scroll_signals(steps)
  local layout = self:layout()
  if not layout then return false end

  local wanted = self.row_offset
  for _ = 1, math.abs(steps) do
    wanted = steps > 0 and layout:next_stop(wanted) or layout:prev_stop(wanted)
  end

  if wanted == self.row_offset then return false end
  self.row_offset = wanted
  self:render()
  return true
end

--- Moves the cursor a row, scrolling the body once it is against an end.
--- The buffer is exactly window-height, so vim's own motions cannot reach
--- past it; the viewer drives this itself.
---@param delta number
function Session:move_cursor(delta)
  local layout = self:layout()
  if not layout then return end

  local line = self.viewer.window:cursor_line()
  local step = delta > 0 and 1 or -1
  local offset = self.row_offset

  -- Walked a row at a time so a count travels as far as the same number of
  -- presses would, but drawn once at the end rather than on every step.
  for _ = 1, math.abs(delta) do
    line = line + step
    if line < layout.body_first then
      line, offset = layout.body_first, layout:prev_stop(offset)
    elseif line > layout.body_last then
      line, offset = layout.body_last, layout:next_stop(offset)
    end
  end

  if offset ~= self.row_offset then
    self.row_offset = offset
    self:render()
  end
  self.viewer:place_cursor(line)
end

--- Jumps the body to the first or last trace row.
---@param to_end boolean
function Session:scroll_extreme(to_end)
  local layout = self:layout()
  if not layout then return end
  self.row_offset = to_end and layout.max_offset or 0
  self:render()
  self.viewer:place_cursor(to_end and self.viewer.layout.body_last or self.viewer.layout.body_first)
end

--- Keeps the cursor in the body. Stepping off either end scrolls instead.
---@param line number
---@return number line the cursor should sit on
function Session:clamp_cursor(line)
  local layout = self:layout()
  if not layout then return line end

  if line < layout.body_first then
    self:scroll_signals(-1)
    return layout.body_first
  end
  if line > layout.body_last then
    self:scroll_signals(1)
    return layout.body_last
  end
  return line
end

---@param ref SignalRef
function Session:add_trace(ref)
  if self.loading then return end
  local _, err = self.traces:add(ref)
  if err then
    log.info(err)
    return
  end
  if not self:viewer_open() then self:show_viewer() end
  self:render()
end

function Session:prompt_add_trace()
  if self:is_busy() then return end
  picker.prompt(function(result)
    self:add_trace(SignalRef.from_search(result))
  end)
end

-- ─── Viewer commands ───

--- The model steps are cheap arithmetic; only the redraw is not, so a count
--- is applied in full before drawing once.
---@param count number|nil
function Session:zoom_in(count)
  local period, cols = self.traces:min_period(), self:wave_cols()
  local changed = false
  for _ = 1, count or 1 do
    if not self.viewport:zoom_in(period, cols, self.cursor_time) then break end
    changed = true
  end
  if changed then self:render() end
end

---@param count number|nil
function Session:zoom_out(count)
  local period, cols = self.traces:min_period(), self:wave_cols()
  local changed = false
  for _ = 1, count or 1 do
    if not self.viewport:zoom_out(period, cols, self.cursor_time) then break end
    changed = true
  end
  if changed then self:render() end
end

---@param direction number -1 left, +1 right
---@param count number|nil
function Session:scroll_time(direction, count)
  self.viewport:pan(direction, count)
  self:render()
end

---@param count number|nil
function Session:scroll_left(count)
  self:scroll_time(-1, count)
end

---@param count number|nil
function Session:scroll_right(count)
  self:scroll_time(1, count)
end

--- Marks the transition nearest the centre of the view.
function Session:cursor_to_view()
  local center = self.viewport:center()
  self.cursor_time = self.traces:edge_index():nearest(center) or center
  self:render()
end

---@param backwards boolean
---@param count number|nil
function Session:_marker_edge(backwards, count)
  local edges = self.traces:edge_index()
  local at = self.cursor_time or self.viewport:center()
  for _ = 1, count or 1 do
    local next_at = backwards and edges:prev(at) or edges:next(at)
    if not next_at then break end
    at = next_at
  end
  self.cursor_time = at
  self.viewport:follow(at)
  self:render()
end

---@param count number|nil
function Session:prev_edge(count)
  self:_marker_edge(true, count)
end

---@param count number|nil
function Session:next_edge(count)
  self:_marker_edge(false, count)
end

function Session:remove_trace_at_cursor()
  if not self:viewer_open() then return end
  local trace, kind = self.viewer:under_cursor()
  if trace and (kind == "wave_top" or kind == "wave_bot") then
    self.traces:remove(trace.ref.signal_id)
    self:render()
  end
end

function Session:toggle_expand_at_cursor()
  if not self:viewer_open() then return end
  local trace, kind = self.viewer:under_cursor()
  if trace and kind == "wave_top" and trace:can_expand() then
    trace:toggle_expand()
    self:render()
  end
end

function Session:show_help()
  HelpPopup.open(self.keymaps, Actions.groups(), Actions.descriptions())
end

-- ─── Mouse ───

--- The layout to act on for a pointer event, or nil when there is nothing to
--- point at: no pointer, no window, or the file is still being read.
---@param pos table|nil
---@return table|nil
function Session:_pointer_layout(pos)
  if self.loading or not pos then return nil end
  return self:layout()
end

--- Time a click should land on: the transition inside the clicked column if
--- there is one, else the column itself.
---
--- A column covers many time units when zoomed out, so an edge within it
--- cannot be named by clicking. Snapping inside the clicked column — and no
--- further — makes edges exactly selectable without the cursor jumping
--- somewhere the pointer was not.
---@param wincol number
---@return number|nil
function Session:time_under(wincol)
  local layout = self:layout()
  if not layout then return nil end

  local time = layout:time_at(wincol)
  if not time then return nil end

  local from, to = layout:column_span(wincol)
  local edge = self.traces:edge_index():nearest(time)
  if edge and edge >= from and edge < to then return edge end
  return time
end

--- Clicking in the waveform drops the time cursor there; clicking anywhere
--- in the body also selects that row, so dd and <CR> follow the pointer.
---@param pos table|nil { line, wincol }
function Session:mouse_click(pos)
  if not self:_pointer_layout(pos) then return end

  self.viewer:place_cursor(self:clamp_cursor(pos.line))

  local time = self:time_under(pos.wincol)
  if time then self.cursor_time = time end
  self:render()
end

--- Dragging scrubs the time cursor without moving the row selection.
---@param pos table|nil
function Session:mouse_drag(pos)
  if not self:_pointer_layout(pos) then return end
  local time = self:time_under(pos.wincol)
  if not time then return end
  self.cursor_time = time
  self:render()
end

--- Double-clicking a bus expands it.
---@param pos table|nil
function Session:mouse_double_click(pos)
  if not self:_pointer_layout(pos) then return end
  self.viewer:place_cursor(self:clamp_cursor(pos.line))
  self:toggle_expand_at_cursor()
end

--- Zoom about the pointer: the viewport keeps a visible cursor centred, so
--- putting the cursor under the pointer first is what anchors the zoom.
---@param inward boolean
---@param pos table|nil
function Session:mouse_zoom(inward, pos)
  if self.loading then return end
  local time = self:_pointer_layout(pos) and self:time_under(pos.wincol)
  if time then self.cursor_time = time end
  if inward then self:zoom_in(1) else self:zoom_out(1) end
end

-- ─── Netlist commands ───

function Session:netlist_enter()
  if not self:netlist_open() or not self.netlist.layout then return end
  local line = self.netlist:cursor_line()

  local node = self.netlist.layout:node_at(line)
  if node then
    if node.expanded then
      self.tree:collapse(node.id)
    else
      self.tree:expand(node.id)
      if not node.loaded then self.netlist:load_children(node.id) end
    end
    self.netlist:render()
    return
  end

  local ref = self.netlist.layout:var_at(line)
  if ref then self:add_trace(ref) end
end

--- Collapses the scope under the cursor, else its parent: folds toward root.
function Session:netlist_back()
  if not self:netlist_open() or not self.netlist.layout then return end
  local line = self.netlist:cursor_line()

  local node = self.netlist.layout:node_at(line)
  local target = (node and node.expanded) and node or self.netlist.layout:parent_at(line)
  if not target or not target.expanded then return end

  self.tree:collapse(target.id)
  self.netlist:render()
end

return Session
