--- User-facing notifications. Every message the plugin emits goes through here
--- so the prefix is written once and callers never have to know whether they
--- are on the main loop or inside a libuv callback.

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
