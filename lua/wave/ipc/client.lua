--- Speaks the parser protocol: typed commands in, decoded responses out.
--- Callers never build a command table or track a request id themselves.

local Process = require("wave.ipc.process")
local FrameReader = require("wave.ipc.reader")
local Request = require("wave.ipc.request")
local codec = require("wave.ipc.codec")
local log = require("wave.util.log")

local ParserClient = {}
ParserClient.__index = ParserClient

local REQUEST_TIMEOUT_MS = 30000

---@param binary_path string
---@return ParserClient
function ParserClient.new(binary_path)
  return setmetatable({
    binary_path = binary_path,
    requests = {},
    next_id = 1,
    ready = false,
    crashed = false,
    open_file = nil,
  }, ParserClient)
end

---@return boolean
function ParserClient:start()
  self.process = Process.new(self.binary_path)
  self.reader = FrameReader.new(function(frame) self:_on_frame(frame) end)

  local ok = self.process:spawn({
    on_stdout = function(data) self:_on_stdout(data) end,
    on_stderr = function(text) log.warn(text) end,
    on_exit = function() self:_on_exit() end,
  })
  if not ok then
    self.process = nil
    return false
  end

  self.ready = true
  return true
end

function ParserClient:stop()
  for _, request in pairs(self.requests) do
    request:reject("Parser stopped")
  end
  self.requests = {}
  if self.process then
    self.process:stop()
    self.process = nil
  end
  if self.reader then self.reader:reset() end
  self.ready = false
end

---@return boolean
function ParserClient:is_ready()
  return self.ready and self.process ~= nil
end

--- Restarts after a crash and re-opens whatever file was loaded, so the
--- caller's next command lands on the same state it expected.
---@return boolean
function ParserClient:try_restart()
  if not self.crashed then return false end
  self:stop()
  self.crashed = false
  if not self:start() then return false end
  if self.open_file then
    self:request({ cmd = "open", file = self.open_file }, function() end)
  end
  return true
end

function ParserClient:_on_stdout(data)
  local ok, err = self.reader:feed(data)
  if not ok then
    log.error("Parser " .. err .. "; restarting")
    self.crashed = true
  end
end

function ParserClient:_on_exit()
  self.ready = false
  self.crashed = true
  for _, request in pairs(self.requests) do
    request:reject("Process exited")
  end
  self.requests = {}
  if self.reader then self.reader:reset() end
end

---@param frame string
function ParserClient:_on_frame(frame)
  local ok, response = pcall(vim.mpack.decode, frame)
  if not ok then
    log.warn("Failed to decode response: " .. tostring(response))
    return
  end

  local request = self.requests[response.request_id]
  if not request then return end

  if response.chunk then
    request:push_chunk(response.data)
    request:arm(REQUEST_TIMEOUT_MS, function(r) self:_on_timeout(r) end)
    return
  end

  self.requests[response.request_id] = nil
  request:resolve(response)
end

---@param request Request
function ParserClient:_on_timeout(request)
  self.requests[request.id] = nil
  log.warn("Request " .. request.id .. " timed out")
  request:reject("Request timed out")
end

--- Sends a raw command. Prefer the named methods below.
---@param cmd table
---@param callback fun(response: table)
function ParserClient:request(cmd, callback)
  if not self:is_ready() and self.crashed and not self:try_restart() then
    log.error("Failed to restart parser")
    return Request.new(0, callback):reject("Failed to restart parser")
  end
  if not self:is_ready() then
    log.error("Parser not ready")
    return Request.new(0, callback):reject("Parser not ready")
  end

  if cmd.cmd == "open" then
    self.open_file = cmd.file
  elseif cmd.cmd == "close" then
    self.open_file = nil
  end

  local id = self.next_id
  self.next_id = id + 1
  cmd.request_id = id

  local ok, encoded = pcall(vim.mpack.encode, cmd)
  if not ok then
    log.error("Failed to encode command")
    return Request.new(id, callback):reject("Failed to encode command")
  end

  local request = Request.new(id, callback)
  self.requests[id] = request
  request:arm(REQUEST_TIMEOUT_MS, function(r) self:_on_timeout(r) end)

  -- A failed write against a dead child would otherwise cost a full timeout.
  self.process:write(codec.frame(encoded), function(err)
    if not err then return end
    self.requests[id] = nil
    self.crashed = true
    request:reject("Write failed: " .. tostring(err))
  end)
end

-- ─── Protocol ───

---@param path string
function ParserClient:open(path, callback)
  self:request({ cmd = "open", file = path }, callback)
end

function ParserClient:close_file(callback)
  self:request({ cmd = "close" }, callback or function() end)
end

---@param scope_id number
---@param start_index number
function ParserClient:children(scope_id, start_index, callback)
  self:request({ cmd = "get_children", id = scope_id, start_index = start_index }, callback)
end

--- Pages through get_children until the parser reports nothing remaining, so
--- callers never see start_index or remaining_items.
---@param scope_id number
---@param callback fun(children: {scopes: table[], vars: table[]}|nil)
function ParserClient:children_all(scope_id, callback)
  local acc = { scopes = {}, vars = {} }
  local function step(start_index)
    self:children(scope_id, start_index, function(response)
      if not response.success then
        callback(nil)
        return
      end
      local data = response.data or {}
      for _, s in ipairs(data.scopes or {}) do acc.scopes[#acc.scopes + 1] = s end
      for _, v in ipairs(data.vars or {}) do acc.vars[#acc.vars + 1] = v end
      if (data.remaining_items or 0) > 0 then
        step(start_index + (data.total_returned or 0))
      else
        callback(acc)
      end
    end)
  end
  step(0)
end

---@param signal_ids number[]
---@param t0 number
---@param t1 number
---@param max_points number
function ParserClient:signal_data(signal_ids, t0, t1, max_points, callback)
  self:request({
    cmd = "get_signal_data",
    signal_ids = signal_ids,
    time_start = t0,
    time_end = t1,
    max_points = max_points,
  }, callback)
end

---@param query string
function ParserClient:search(query, callback)
  self:request({ cmd = "search", search_query = query }, callback)
end

return ParserClient
