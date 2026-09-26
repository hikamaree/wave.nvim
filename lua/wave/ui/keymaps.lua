--- Binds configured keys to handlers in a buffer.

local M = {}

--- `handlers` maps an action name to a function taking a count; `repeatable`
--- names the actions that honour one, so `5l` scrolls five steps. The count
--- is passed rather than replayed, so the action redraws once.
---@param buffer ScratchBuffer
---@param keymaps table<string, string>
---@param handlers table<string, fun()>
---@param repeatable table<string, boolean>|nil
function M.bind(buffer, keymaps, handlers, repeatable)
  for action, lhs in pairs(keymaps) do
    local handler = handlers[action]
    if handler then
      local counts = repeatable and repeatable[action]
      vim.api.nvim_buf_set_keymap(buffer.handle, "n", lhs, "", {
        callback = function()
          handler(counts and vim.v.count1 or 1)
        end,
        noremap = true, silent = true, desc = "wave: " .. action,
      })
    end
  end
end

return M
