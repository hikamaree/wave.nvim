--- The waveform window: a buffer, the window showing it, and the last layout
--- drawn into it. Holds no domain state — that lives on the Session.

local ViewerLayout = require("wave.render.viewer_layout")
local ScratchBuffer = require("wave.ui.buffer")
local Window = require("wave.ui.window")
local Painter = require("wave.ui.painter")
local Keymaps = require("wave.ui.keymaps")
local log = require("wave.util.log")

local ViewerView = {}
ViewerView.__index = ViewerView

--- Takes over the current window rather than opening one, so the viewer can
--- be the only window on screen.
---@param session Session
---@param actions table
---@return ViewerView
function ViewerView.open(session, actions)
  local buffer = ScratchBuffer.new("Wave: " .. session.file_name, "wave")
  buffer:show()

  local window = Window.current()
  window:set_options({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldenable = false,
    cursorline = false,
    wrap = false,
  })

  local self = setmetatable({
    session = session,
    buffer = buffer,
    window = window,
    layout = nil,
  }, ViewerView)

  Keymaps.bind(buffer, actions.keymaps, actions.handlers, actions.repeatable)
  return self
end

---@return boolean
function ViewerView:is_open()
  return self.window:valid() and self.buffer:valid()
end

---@return number
function ViewerView:wave_cols()
  if not self.window:valid() then return 0 end
  local _, cols = ViewerLayout.columns(self.window:width())
  return cols
end

function ViewerView:render()
  if not self:is_open() then return end
  local session = self.session

  local ok, layout = pcall(ViewerLayout.build, {
    traces = session.traces:all(),
    viewport = session.viewport,
    cursor_time = session.cursor_time,
    time_unit = session.time_unit,
    file_name = session.file_name,
    total_cols = self.window:width(),
    keymaps = session.keymaps,
    help_groups = session.help_groups,
  })
  if not ok then
    log.error("Render error: " .. tostring(layout))
    return
  end

  self.layout = layout
  local painted, err = Painter.paint(self.buffer, layout)
  if not painted then
    log.error("Render error: " .. tostring(err))
  end
end

--- The trace on the cursor's line, and which part of its block.
---@return Trace|nil, string|nil
function ViewerView:under_cursor()
  if not self.layout or not self.window:valid() then return nil, nil end
  return self.layout:at(self.window:cursor_line())
end

--- Deletes the buffer but never the window: this view took over whichever
--- window was current, and it may be the last one open.
function ViewerView:close()
  self.buffer:delete()
end

return ViewerView
