--- The waveform window. Holds no domain state; that lives on the Session.
---
--- `self.layout` is whichever screen is current — ViewerLayout once the file
--- is read, LoadingLayout before that. Both answer the same questions, so
--- nothing here branches on which it holds; test_model.lua pins the contract.

local ViewerLayout = require("wave.render.viewer_layout")
local ScratchBuffer = require("wave.ui.buffer")
local Window = require("wave.ui.window")
local Painter = require("wave.ui.painter")
local Keymaps = require("wave.ui.keymaps")
local Mouse = require("wave.ui.mouse")
local config = require("wave.config")
local log = require("wave.util.log")

local ViewerView = {}
ViewerView.__index = ViewerView

--- Takes over the current window, so the viewer can be the only one open.
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

  if config.options.mouse then
    Mouse.bind_viewer(buffer, {
      click = function() session:mouse_click(Mouse.position(self.window)) end,
      drag = function() session:mouse_drag(Mouse.position(self.window)) end,
      double_click = function() session:mouse_double_click(Mouse.position(self.window)) end,
      scroll = function(signals) session:scroll_signals(signals) end,
      pan = function(direction) session:scroll_time(direction) end,
      zoom = function(inward) session:mouse_zoom(inward, Mouse.position(self.window)) end,
    })
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buffer.handle,
    callback = function() self:keep_cursor_in_body() end,
  })

  return self
end

--- The header and key bar are part of the buffer, so the cursor has to be
--- held off them; running into either edge scrolls the body instead.
function ViewerView:keep_cursor_in_body()
  if self.adjusting or not self:is_open() or not self.layout then return end
  local line = self.window:cursor_line()
  local wanted = self.session:clamp_cursor(line)
  if wanted == line then return end

  self:place_cursor(wanted)
end

---@param line number
function ViewerView:place_cursor(line)
  if not self:is_open() then return end
  self.adjusting = true
  pcall(vim.api.nvim_win_set_cursor, self.window.handle, { line, 0 })
  self.adjusting = false
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

  local ok, layout = pcall(session.build_layout, session,
    self.window:width(), self.window:height())
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

---@return Trace|nil, string|nil
function ViewerView:under_cursor()
  if not self.layout or not self.window:valid() then return nil, nil end
  return self.layout:at(self.window:cursor_line())
end

--- Buffer only, never the window: it was not ours, and may be the last.
function ViewerView:close()
  self.buffer:delete()
end

return ViewerView
