--- One open waveform file.
---
--- The session owns the domain state — traces, viewport, cursor, scope tree —
--- and the two views are disposable windows onto it. That is why closing the
--- viewer or the netlist loses nothing but the window itself.

local TraceList = require("wave.model.trace_list")
local Trace = require("wave.model.trace")
local Viewport = require("wave.model.viewport")
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

---@param client ParserClient
---@param path string
---@param info table the parser's FileInfo
---@return Session
function Session.new(client, path, info)
  return setmetatable({
    client = client,
    path = path,
    file_name = vim.fn.fnamemodify(path, ":t"),
    time_unit = info.time_unit or "ns",
    traces = TraceList.new(),
    viewport = Viewport.new(info.time_end or 1000),
    tree = NetlistTree.new(0, vim.fn.fnamemodify(path, ":t")),
    cursor_time = nil,
    keymaps = config.options.keymaps,
    help_groups = Actions.groups(),
    viewer = nil,
    netlist = nil,
    netlist_view_state = nil,
  }, Session)
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

--- Columns available to the waveform, or a sane default before a window exists.
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

--- Called from BufWipeout: a view's buffer went away underneath us.
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
  if self:viewer_open() then
    self:fetch_visible()
    self.viewport:sync_zoom(self.traces:min_period(), self:wave_cols())
    self.viewer:render()
  end
end

function Session:close()
  self:hide_netlist()
  self:hide_viewer()
end

-- ─── Data ───

--- Requests data for any trace whose fetched window no longer covers the view.
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

---@param ref SignalRef
function Session:add_trace(ref)
  local _, err = self.traces:add(ref)
  if err then
    log.info(err)
    return
  end
  if not self:viewer_open() then self:show_viewer() end
  self:render()
end

function Session:prompt_add_trace()
  picker.prompt(function(result)
    self:add_trace(SignalRef.from_search(result))
  end)
end

-- ─── Viewer commands ───

function Session:zoom_in()
  if self.viewport:zoom_in(self.traces:min_period(), self:wave_cols(), self.cursor_time) then
    self:render()
  end
end

function Session:zoom_out()
  if self.viewport:zoom_out(self.traces:min_period(), self:wave_cols(), self.cursor_time) then
    self:render()
  end
end

function Session:scroll_left()
  self.viewport:pan(-1)
  self:render()
end

function Session:scroll_right()
  self.viewport:pan(1)
  self:render()
end

--- Puts the marker on the transition nearest the centre of the view.
function Session:cursor_to_view()
  local center = self.viewport:center()
  self.cursor_time = self.traces:edge_index():nearest(center) or center
  self:render()
end

---@param backwards boolean
function Session:_marker_edge(backwards)
  local from = self.cursor_time or self.viewport:center()
  local edges = self.traces:edge_index()
  self.cursor_time = (backwards and edges:prev(from) or edges:next(from)) or from
  self.viewport:follow(self.cursor_time)
  self:render()
end

function Session:prev_edge()
  self:_marker_edge(true)
end

function Session:next_edge()
  self:_marker_edge(false)
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

--- Collapses the scope under the cursor, or its owning scope if the cursor
--- is on one of that scope's children, folding back up toward the root.
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
