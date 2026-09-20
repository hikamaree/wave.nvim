--- The floating help window listing the viewer's keys.

local M = {}

---@param keymaps table
---@param groups string[][]
---@param descriptions table<string, string>
function M.open(keymaps, groups, descriptions)
  local lines = { " wave.nvim", "" }
  for _, group in ipairs(groups) do
    for _, action in ipairs(group) do
      if keymaps[action] then
        lines[#lines + 1] = string.format(" %-12s %s", keymaps[action], descriptions[action] or action)
      end
    end
  end
  lines[#lines + 1] = ""

  local width = 0
  for _, line in ipairs(lines) do width = math.max(width, #line + 1) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = #lines,
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })

  for _, key in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.api.nvim_buf_set_keymap(buf, "n", key, "", {
      callback = function() pcall(vim.api.nvim_win_close, win, true) end,
      noremap = true, silent = true,
    })
  end
end

return M
