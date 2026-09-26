--- A window handle that knows whether it is still valid.

local Window = {}
Window.__index = Window

---@param handle number
---@return Window
function Window.new(handle)
  return setmetatable({ handle = handle }, Window)
end

---@return Window
function Window.current()
  return Window.new(vim.api.nvim_get_current_win())
end

---@return boolean
function Window:valid()
  return self.handle ~= nil and vim.api.nvim_win_is_valid(self.handle)
end

---@return number
function Window:width()
  return self:valid() and vim.api.nvim_win_get_width(self.handle) or 0
end

---@return number
function Window:height()
  return self:valid() and vim.api.nvim_win_get_height(self.handle) or 0
end

---@return number
function Window:cursor_line()
  if not self:valid() then return 1 end
  return vim.api.nvim_win_get_cursor(self.handle)[1]
end

---@return number|nil
function Window:buffer()
  if not self:valid() then return nil end
  return vim.api.nvim_win_get_buf(self.handle)
end

---@param opts table
function Window:set_options(opts)
  if not self:valid() then return end
  for name, value in pairs(opts) do
    vim.wo[self.handle][name] = value
  end
end

function Window:focus()
  if self:valid() then vim.api.nvim_set_current_win(self.handle) end
end

---@return table|nil
function Window:save_view()
  if not self:valid() then return nil end
  return vim.api.nvim_win_call(self.handle, vim.fn.winsaveview)
end

---@param view table|nil
function Window:restore_view(view)
  if not view or not self:valid() then return end
  vim.api.nvim_win_call(self.handle, function() vim.fn.winrestview(view) end)
end

--- Never closes the last window; the viewer does not own one.
function Window:close()
  if self:valid() and #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, self.handle, true)
  end
end

return Window
