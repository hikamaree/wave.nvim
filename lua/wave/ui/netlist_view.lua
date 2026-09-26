--- The netlist side panel over the Session's scope tree.

local NetlistLayout = require("wave.render.netlist_layout")
local ScratchBuffer = require("wave.ui.buffer")
local Window = require("wave.ui.window")
local Painter = require("wave.ui.painter")
local Mouse = require("wave.ui.mouse")
local config = require("wave.config")
local log = require("wave.util.log")

local NetlistView = {}
NetlistView.__index = NetlistView

local WIDTH = 50

---@param session Session
---@param handlers table<string, fun()>
---@return NetlistView
function NetlistView.open(session, handlers)
  local viewer_win = session:viewer_window()
  if viewer_win then viewer_win:focus() end

  local buffer = ScratchBuffer.new(nil, "wave-netlist")
  local window = Window.new(vim.api.nvim_open_win(buffer.handle, true, {
    split = "right",
    win = viewer_win and viewer_win.handle or 0,
    width = WIDTH,
  }))
  window:set_options({
    winfixwidth = true,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldenable = false,
  })

  local self = setmetatable({
    session = session,
    buffer = buffer,
    window = window,
    layout = nil,
    loading = {},
  }, NetlistView)

  local km = session.keymaps
  for _, binding in ipairs({
    { km.expand or "<CR>", handlers.enter },
    { km.back or "<Backspace>", handlers.back },
    { km.search or "f", handlers.search },
    { km.close or "q", handlers.close },
    { km.netlist or "n", handlers.close },
  }) do
    vim.api.nvim_buf_set_keymap(buffer.handle, "n", binding[1], "", {
      callback = binding[2], noremap = true, silent = true,
    })
  end

  if config.options.mouse then
    Mouse.bind_netlist(buffer, { activate = handlers.enter })
  end

  -- :q wipes the buffer before the close handler runs, so track the view.
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    buffer = buffer.handle,
    callback = function()
      if self.window:valid() then session.netlist_view_state = self.window:save_view() end
    end,
  })

  return self
end

---@return boolean
function NetlistView:is_open()
  return self.window:valid() and self.buffer:valid()
end

---@return number
function NetlistView:cursor_line()
  return self.window:valid() and self.window:cursor_line() or 0
end

--- Fetches children, then redraws if the panel is still open.
---@param scope_id number
---@param on_loaded fun()|nil
function NetlistView:load_children(scope_id, on_loaded)
  if self.loading[scope_id] then return end
  self.loading[scope_id] = true

  self.session.client:children_all(scope_id, function(children)
    self.loading[scope_id] = nil
    local tree = self.session.tree
    if not tree then return end

    if children then
      tree:set_children(scope_id, children.scopes, children.vars)
    else
      tree:mark_failed(scope_id)
    end

    if on_loaded then on_loaded() end
    vim.schedule(function()
      if self:is_open() then self:render() end
    end)
  end)
end

--- A single top scope is one pointless level; open it eagerly.
---@param root ScopeNode
function NetlistView:skip_lone_root(root)
  if #root.scopes ~= 1 or #root.vars > 0 then return end
  local only = root.scopes[1]
  if only.expanded or only.loaded then return end
  self.session.tree:expand(only.id)
  self:load_children(only.id)
end

function NetlistView:render()
  if not self:is_open() then return end
  local tree = self.session.tree
  local root = tree:root_node()

  if not root.loaded then
    self:load_children(root.id, function() self:skip_lone_root(root) end)
    self.layout = NetlistLayout.loading()
    Painter.paint(self.buffer, self.layout)
    return
  end

  self.layout = NetlistLayout.build({
    tree = tree,
    width = self.window:width(),
    keymaps = self.session.keymaps,
  })

  local ok, err = Painter.paint(self.buffer, self.layout)
  if not ok then
    log.error("Netlist render error: " .. tostring(err))
    return
  end

  local view = self.session.netlist_view_state
  if view then
    self.session.netlist_view_state = nil
    view.lnum = math.min(view.lnum, #self.layout.rows)
    self.window:restore_view(view)
  end
end

function NetlistView:close()
  self.session.netlist_view_state = self.window:save_view()
  self.window:close()
end

return NetlistView
