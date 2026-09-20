--- The parser child process and its three pipes. Knows nothing about frames
--- or requests.

local log = require("wave.util.log")

local Process = {}
Process.__index = Process

---@param binary_path string
---@return Process
function Process.new(binary_path)
  return setmetatable({ binary_path = binary_path }, Process)
end

---@class ProcessHandlers
---@field on_stdout fun(data: string)
---@field on_stderr fun(text: string)
---@field on_exit fun()

---@param handlers ProcessHandlers
---@return boolean
function Process:spawn(handlers)
  self.stdin = vim.uv.new_pipe(false)
  self.stdout = vim.uv.new_pipe(false)
  self.stderr = vim.uv.new_pipe(false)

  self.handle = vim.uv.spawn(self.binary_path, {
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function()
    handlers.on_exit()
  end)

  if not self.handle then
    log.error("Failed to start parser: " .. tostring(self.binary_path))
    self:_close_pipes()
    return false
  end

  self.stdout:read_start(function(err, data)
    if err then
      log.error("stdout error: " .. tostring(err))
      return
    end
    if not data or #data == 0 then return end
    handlers.on_stdout(data)
  end)

  self.stderr:read_start(function(err, data)
    if err or not data then return end
    local text = data:gsub("%s+$", "")
    if text ~= "" then handlers.on_stderr(text) end
  end)

  return true
end

---@param bytes string
---@param on_err fun(err: string|nil)
function Process:write(bytes, on_err)
  if not self.stdin then
    on_err("parser not started")
    return
  end
  self.stdin:write(bytes, on_err)
end

---@return boolean
function Process:is_running()
  return self.handle ~= nil
end

function Process:_close_pipes()
  for _, name in ipairs({ "stdin", "stdout", "stderr" }) do
    local pipe = self[name]
    if pipe then
      pcall(function() pipe:close() end)
      self[name] = nil
    end
  end
end

function Process:stop()
  -- Close stdin first so the child sees EOF, but don't rely on it noticing.
  if self.stdin then
    pcall(function() self.stdin:close() end)
    self.stdin = nil
  end
  if self.handle then
    pcall(function() self.handle:kill("sigterm") end)
    pcall(function() self.handle:close() end)
    self.handle = nil
  end
  self:_close_pipes()
end

return Process
