local M = {}

--- Persistent connection to the Rust wave parser binary via stdin/stdout JSON protocol.

local Parser = {}
Parser.__index = Parser

function Parser:new(binary_path)
  return setmetatable({
    binary_path = binary_path,
    job_id = nil,
    buf = "",
    pending = {},
    next_id = 1,
    ready = false,
  }, Parser)
end

function Parser:start()
  local self_ref = self
  self.job_id = vim.fn.jobstart(self.binary_path, {
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          self_ref.buf = self_ref.buf .. line
          while true do
            local ok, parsed = pcall(vim.json.decode, self_ref.buf)
            if not ok then
              break
            end
            self_ref.buf = ""
            self_ref:_handle_response(parsed)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        local msg = table.concat(data, " ")
        if msg ~= "" then
          vim.notify("[wave] " .. msg, vim.log.levels.WARN)
        end
      end
    end,
    on_exit = function()
      self_ref.ready = false
    end,
  })

  if self.job_id and self.job_id > 0 then
    self.ready = true
    return true
  end
  vim.notify("[wave] Failed to start parser: jobstart returned " .. tostring(self.job_id), vim.log.levels.ERROR)
  return false, "Failed to start parser process"
end

function Parser:stop()
  if self.job_id and self.job_id > 0 then
    vim.fn.jobstop(self.job_id)
    self.job_id = nil
    self.ready = false
  end
end

function Parser:_handle_response(resp)
  local cb = self.pending[resp.request_id]
  if cb then
    self.pending[resp.request_id] = nil
    vim.schedule(function()
      cb(resp)
    end)
  end
end

--- Send a command to the parser and call callback(response) with the result.
---@param cmd table: JSON-encodable command table
---@param callback function: receives the response table {success, data, error}
function Parser:send(cmd, callback)
  if not self.ready or not self.job_id then
    vim.notify("[wave] Parser not ready", vim.log.levels.ERROR)
    return
  end

  local id = self.next_id
  self.next_id = id + 1
  cmd.request_id = id
  self.pending[id] = callback

  local ok, encoded = pcall(vim.json.encode, cmd)
  if not ok then
    self.pending[id] = nil
    vim.notify("[wave] Failed to encode command", vim.log.levels.ERROR)
    return
  end

  vim.fn.chansend(self.job_id, encoded .. "\n")
end

function M.create_parser(binary_path)
  return Parser:new(binary_path)
end

return M
