--- A scratch buffer for plugin output: created unlisted and wiped on hide,
--- never modifiable except while it is being written.

local ScratchBuffer = {}
ScratchBuffer.__index = ScratchBuffer

---@param name string|nil
---@param filetype string
---@return ScratchBuffer
function ScratchBuffer.new(name, filetype)
  local handle = vim.api.nvim_create_buf(false, true)
  if name then
    pcall(vim.api.nvim_buf_set_name, handle, name)
  end

  local options = {
    buftype = "nofile",
    bufhidden = "wipe",
    modified = false,
    filetype = filetype,
    swapfile = false,
  }
  for key, value in pairs(options) do
    vim.bo[handle][key] = value
  end

  return setmetatable({ handle = handle }, ScratchBuffer)
end

---@param handle number
---@return ScratchBuffer
function ScratchBuffer.wrap(handle)
  return setmetatable({ handle = handle }, ScratchBuffer)
end

---@return boolean
function ScratchBuffer:valid()
  return self.handle ~= nil and vim.api.nvim_buf_is_valid(self.handle)
end

--- Runs `fn` with the buffer writable, restoring it even if `fn` throws.
---@param fn fun()
---@return boolean ok, string|nil err
function ScratchBuffer:with_modifiable(fn)
  if not self:valid() then return false, "invalid buffer" end
  vim.bo[self.handle].modifiable = true
  local ok, err = pcall(fn)
  if self:valid() then
    vim.bo[self.handle].modifiable = false
  end
  return ok, err
end

---@param lines string[]
function ScratchBuffer:set_lines(lines)
  vim.api.nvim_buf_set_lines(self.handle, 0, -1, false, lines)
end

---@param ns number
function ScratchBuffer:clear_namespace(ns)
  if self:valid() then
    vim.api.nvim_buf_clear_namespace(self.handle, ns, 0, -1)
  end
end

function ScratchBuffer:show()
  vim.api.nvim_set_current_buf(self.handle)
end

function ScratchBuffer:delete()
  if self:valid() then
    pcall(vim.api.nvim_buf_delete, self.handle, { force = true })
  end
end

return ScratchBuffer
