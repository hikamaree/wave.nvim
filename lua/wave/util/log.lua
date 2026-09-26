--- User-facing notifications. Prefixed once, and safe to call from a libuv
--- callback as well as the main loop.

local M = {}

local PREFIX = "[wave] "

---@param msg string
---@param level number
local function notify(msg, level)
  if vim.in_fast_event() then
    vim.schedule(function() vim.notify(PREFIX .. msg, level) end)
  else
    vim.notify(PREFIX .. msg, level)
  end
end

---@param msg string
function M.info(msg)
  notify(msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
  notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.error(msg)
  notify(msg, vim.log.levels.ERROR)
end

return M
