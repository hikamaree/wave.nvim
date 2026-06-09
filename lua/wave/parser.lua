local M = {}

---@class Parser
---@field binary_path string
---@field stdin userdata|nil
---@field buf string[]
---@field pending table<number, function>
---@field pending_chunks table<number, table[]>
---@field pending_timers table<number, any>
---@field next_id number
---@field ready boolean
---@field crashed boolean
---@field _process userdata|nil
---@field _stdout userdata|nil
---@field _stderr userdata|nil
local Parser = {}
Parser.__index = Parser

local REQUEST_TIMEOUT_MS = 30000

---@param binary_path string
---@return Parser
function Parser:new(binary_path)
  return setmetatable({
    binary_path = binary_path,
    stdin = nil,
    buf = {},
    pending = {},
    pending_chunks = {},
    pending_timers = {},
    next_id = 1,
    ready = false,
    crashed = false,
  }, Parser)
end

---@param buf string
---@return string|nil, number
local function _read_frame(buf)
  if #buf < 4 then return nil, 0 end
  local len = string.byte(buf, 1)
            + string.byte(buf, 2) * 256
            + string.byte(buf, 3) * 65536
            + string.byte(buf, 4) * 16777216
  if #buf < 4 + len then return nil, 0 end
  return buf:sub(5, 4 + len), 4 + len
end

---@return boolean
function Parser:start()
  local self_ref = self

  self._stdout = vim.uv.new_pipe(false)
  self._stderr = vim.uv.new_pipe(false)
  self.stdin = vim.uv.new_pipe(false)

  self._process = vim.uv.spawn(self.binary_path, {
    stdio = { self.stdin, self._stdout, self._stderr },
  }, function()
    self_ref.ready = false
    self_ref.crashed = true
    -- Cancel all pending timers
    for id, timer in pairs(self_ref.pending_timers) do
      vim.uv.timer_stop(timer)
      vim.uv.close(timer)
      self_ref.pending_timers[id] = nil
    end
    -- Clean up pending callbacks: the process died, no responses will arrive
    for _, cb in pairs(self_ref.pending) do
      vim.schedule(function()
        local ok, err = pcall(cb, { success = false, error = "Process exited" })
        if not ok then
          vim.notify("[wave] Callback error: " .. tostring(err), vim.log.levels.WARN)
        end
      end)
    end
    self_ref.pending = {}
    self_ref.pending_chunks = {}
  end)

  if not self._process then
    vim.notify("[wave] Failed to start parser: " .. tostring(self.binary_path), vim.log.levels.ERROR)
    -- Close the pipes that were created before the spawn attempt
    if self._stdout then self._stdout:close(); self._stdout = nil end
    if self._stderr then self._stderr:close(); self._stderr = nil end
    if self.stdin then self.stdin:close(); self.stdin = nil end
    return false
  end

  self._stdout:read_start(function(err, data)
    if err then
      vim.notify("[wave] stdout error: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if not data then return end
    if #data == 0 then return end
    self_ref.buf[#self_ref.buf + 1] = data
    self_ref:_process_buf()
  end)

  self._stderr:read_start(function(err, data)
    if err or not data then return end
    local msg = data:gsub("%s+$", "")
    if msg ~= "" then
      vim.notify("[wave] " .. msg, vim.log.levels.WARN)
    end
  end)

  self.ready = true
  return true
end

function Parser:_process_buf()
  local concat = table.concat(self.buf)
  if #concat == 0 then return end

  local pos = 1
  while pos <= #concat do
    local frame, consumed = _read_frame(concat:sub(pos))
    if not frame then break end
    pos = pos + consumed
    local ok, resp = pcall(vim.mpack.decode, frame)
    if ok then
      local ok2, err2 = pcall(self._handle_response, self, resp)
      if not ok2 then
        vim.notify("[wave] Handler error: " .. tostring(err2), vim.log.levels.ERROR)
      end
    else
      vim.notify("[wave] Failed to decode response: " .. tostring(resp), vim.log.levels.WARN)
    end
  end

  -- Keep only unprocessed bytes (avoid re-allocating the entire buffer)
  local remaining = concat:sub(pos)
  if #remaining > 0 then
    self.buf = { remaining }
  else
    self.buf = {}
  end
end

function Parser:stop()
  if self.stdin then
    self.stdin:close()
    self.stdin = nil
  end
  if self._process then
    self._process:close()
    self._process = nil
  end
  if self._stdout then
    self._stdout:close()
    self._stdout = nil
  end
  if self._stderr then
    self._stderr:close()
    self._stderr = nil
  end
  self.ready = false
end

function Parser:try_restart()
  if not self.crashed then return false end
  self:stop()
  self.crashed = false
  return self:start()
end

---@param resp table
---@param chunks table[]
local function _merge_chunks(resp, chunks)
  local merged = {}
  for _, chunk in ipairs(chunks) do
    if type(chunk) == "table" then
      for _, item in ipairs(chunk) do
        table.insert(merged, item)
      end
    end
  end
  local data = resp.data
  if type(data) ~= "table" then data = {} end
  for _, item in ipairs(merged) do
    table.insert(data, item)
  end
  resp.data = data
end

function Parser:_cancel_request(id)
  if self.pending_timers[id] then
    vim.uv.timer_stop(self.pending_timers[id])
    vim.uv.close(self.pending_timers[id])
    self.pending_timers[id] = nil
  end
  self.pending[id] = nil
  self.pending_chunks[id] = nil
end

---@param resp table
function Parser:_handle_response(resp)
  local cb = self.pending[resp.request_id]
  if not cb then return end

  if resp.chunk then
    if not self.pending_chunks[resp.request_id] then
      self.pending_chunks[resp.request_id] = {}
    end
    table.insert(self.pending_chunks[resp.request_id], resp.data)
    -- Refresh timer on each chunk
    if self.pending_timers[resp.request_id] then
      vim.uv.timer_stop(self.pending_timers[resp.request_id])
      vim.uv.timer_start(self.pending_timers[resp.request_id], REQUEST_TIMEOUT_MS, 0, function()
        vim.schedule(function()
          self:_cancel_request(resp.request_id)
          vim.notify("[wave] Request " .. resp.request_id .. " timed out", vim.log.levels.WARN)
        end)
      end)
    end
  else
    if self.pending_chunks[resp.request_id] then
      local chunks = self.pending_chunks[resp.request_id]
      self.pending_chunks[resp.request_id] = nil
      if #chunks > 0 then
        _merge_chunks(resp, chunks)
      end
    end
    self:_cancel_request(resp.request_id)
    vim.schedule(function()
      local ok, err = pcall(cb, resp)
      if not ok then
        vim.notify("[wave] Callback error: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end
end

---@param cmd table
---@param callback function
function Parser:send(cmd, callback)
  if not self.stdin then
    vim.notify("[wave] Parser not started", vim.log.levels.ERROR)
    return
  end

  if not self.ready and self.crashed then
    local ok = self:try_restart()
    if not ok then
      vim.notify("[wave] Failed to restart parser", vim.log.levels.ERROR)
      return
    end
  end

  if not self.ready or not self.stdin then
    vim.notify("[wave] Parser not ready", vim.log.levels.ERROR)
    return
  end

  local id = self.next_id
  self.next_id = id + 1
  cmd.request_id = id
  self.pending[id] = callback

  -- Register timeout
  local self_ref = self
  self.pending_timers[id] = vim.uv.new_timer()
  if self.pending_timers[id] then
    vim.uv.timer_start(self.pending_timers[id], REQUEST_TIMEOUT_MS, 0, function()
      vim.schedule(function()
        self_ref:_cancel_request(id)
        vim.notify("[wave] Request " .. id .. " timed out", vim.log.levels.WARN)
      end)
    end)
  end

  local ok, encoded = pcall(vim.mpack.encode, cmd)
  if not ok then
    self:_cancel_request(id)
    vim.notify("[wave] Failed to encode command", vim.log.levels.ERROR)
    return
  end

  local len = #encoded
  self.stdin:write(string.char(
    len % 256,
    math.floor(len / 256) % 256,
    math.floor(len / 65536) % 256,
    math.floor(len / 16777216) % 256
  ))
  self.stdin:write(encoded)
end

---@param binary_path string
---@return Parser
function M.create_parser(binary_path)
  return Parser:new(binary_path)
end

return M
