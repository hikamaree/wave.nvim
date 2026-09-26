--- One in-flight request: its callback, chunks and timeout timer. Keeping
--- them together lets a chunked response refresh its own deadline.

local log = require("wave.util.log")

local Request = {}
Request.__index = Request

---@param id number
---@param callback fun(response: table)
---@return Request
function Request.new(id, callback)
  return setmetatable({ id = id, callback = callback, chunks = {}, timer = nil, done = false }, Request)
end

--- Starts or restarts the deadline.
---@param timeout_ms number
---@param on_timeout fun(request: Request)
function Request:arm(timeout_ms, on_timeout)
  if self.done then return end
  if not self.timer then
    self.timer = vim.uv.new_timer()
    if not self.timer then return end
  end
  vim.uv.timer_stop(self.timer)
  vim.uv.timer_start(self.timer, timeout_ms, 0, function()
    vim.schedule(function()
      if self.done then return end
      on_timeout(self)
    end)
  end)
end

function Request:stop_timer()
  if not self.timer then return end
  vim.uv.timer_stop(self.timer)
  vim.uv.close(self.timer)
  self.timer = nil
end

---@param data any
function Request:push_chunk(data)
  self.chunks[#self.chunks + 1] = data
end

--- The final frame's data was produced last, so it goes after the chunks.
---@param response table
function Request:merge_chunks(response)
  if #self.chunks == 0 then return end
  local merged = {}
  for _, chunk in ipairs(self.chunks) do
    if type(chunk) == "table" then
      for _, item in ipairs(chunk) do
        merged[#merged + 1] = item
      end
    end
  end
  if type(response.data) == "table" then
    for _, item in ipairs(response.data) do
      merged[#merged + 1] = item
    end
  end
  response.data = merged
end

---@param response table
function Request:resolve(response)
  if self.done then return end
  self.done = true
  self:stop_timer()
  self:merge_chunks(response)
  vim.schedule(function()
    local ok, err = pcall(self.callback, response)
    if not ok then
      log.error("Callback error: " .. tostring(err))
    end
  end)
end

---@param reason string
function Request:reject(reason)
  if self.done then return end
  self.done = true
  self:stop_timer()
  vim.schedule(function()
    local ok, err = pcall(self.callback, { success = false, error = reason })
    if not ok then
      log.error("Callback error: " .. tostring(err))
    end
  end)
end

--- Drops it without calling back; the owner has already reported the failure.
function Request:cancel()
  self.done = true
  self:stop_timer()
end

return Request
