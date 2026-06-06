local config = require("wave.config")

local M = {}

local state = {
  buf = nil, win = nil, parser = nil,
  children_cache = {}, expanded_scopes = {}, tree_stack = {},
  current_scope_id = nil,
}

function M.setup(parser)
  state.parser = parser
end

function M.is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

function M.toggle(scope_id, scope_name)
  if M.is_open() then
    M.close()
    return
  end

  vim.api.nvim_command("rightbelow 50vnew")
  state.buf = vim.api.nvim_get_current_buf()
  state.win = vim.api.nvim_get_current_win()

  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].modified = false
  vim.bo[state.buf].filetype = "wave-netlist"
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].foldenable = false

  state.current_scope_id = scope_id or 1
  state.tree_stack = { { id = state.current_scope_id, name = scope_name or tostring(state.current_scope_id) } }

  M._setup_keymaps()
  M._refresh_view()
end

function M._setup_keymaps()
  local buf = state.buf
  local map = function(lhs, rhs)
    vim.api.nvim_buf_set_keymap(buf, "n", lhs, "", {
      callback = rhs, noremap = true, silent = true,
    })
  end

  map("<CR>", function() M._on_enter() end)
  map("<Backspace>", function() M._on_back() end)
  map("a", function() M._add_signal_at_cursor() end)
  map("q", function() M.close() end)
end

function M._on_enter()
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local line = cursor[1]
  if line < 1 or line > #lines then return end
  local text = lines[line]

  local indicator, sid_str, scope_name = text:match("%[([%+%-])%]%s+(%d+):(.+)$")
  if indicator then
    local sid = tonumber(sid_str)
    if not sid then return end

    if indicator == "+" then
      state.expanded_scopes[sid] = true
      M._refresh_view()
      -- Fetch and insert children inline
      state.parser:send({ cmd = "get_children", id = sid, start_index = 0 }, function(resp)
        if not resp.success then return end
        state.children_cache[tostring(sid)] = { scopes = resp.data.scopes or {}, vars = resp.data.vars or {} }
        vim.schedule(function()
          if M.is_open() then M._refresh_view() end
        end)
      end)
    else
      state.expanded_scopes[sid] = nil
      M._refresh_view()
    end
    return
  end
end

function M._on_back()
  if #state.tree_stack > 1 then
    table.remove(state.tree_stack)
    state.current_scope_id = state.tree_stack[#state.tree_stack].id
    M._refresh_view()
  end
end

local function _find_var_recursive(scope_id, name)
  local cache = state.children_cache[tostring(scope_id)]
  if not cache then return nil end
  for _, v in ipairs(cache.vars) do
    if v.name == name then return v end
  end
  for _, s in ipairs(cache.scopes) do
    if state.expanded_scopes[s.id] then
      local found = _find_var_recursive(s.id, name)
      if found then return found end
    end
  end
  return nil
end

function M._add_signal_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local line = cursor[1]
  if line < 1 or line > #lines then return end
  local text = lines[line]

  if not text:match("%[VAR%]") then return end

  local var_name = text:match("%[VAR%]%s+(.+)%s*$")
  if not var_name then return end
  var_name = var_name:gsub("%s+%[%d+:%d+%]$", "")

  local var = _find_var_recursive(state.current_scope_id, var_name)
  if var then
    local viewer = require("wave.viewer")
    viewer.add_signal(var.netlist_id or 0, var.signal_id or 0, var.name, var.width or 1)
  end
end

local function _render_level(scope_id, indent)
  local cache = state.children_cache[tostring(scope_id)]
  if not cache then return {} end
  local lines = {}
  local ind = string.rep("  ", indent)
  for _, s in ipairs(cache.scopes) do
    local expanded = state.expanded_scopes[s.id]
    table.insert(lines, ind .. "  [" .. (expanded and "-" or "+") .. "] " .. tostring(s.id) .. ":" .. s.name)
    if expanded then
      local sub = _render_level(s.id, indent + 1)
      for _, l in ipairs(sub) do table.insert(lines, l) end
    end
  end
  for _, v in ipairs(cache.vars) do
    local val_str = ""
    if v.width and v.width > 1 then
      val_str = string.format(" [%d:0]", v.width - 1)
    end
    table.insert(lines, ind .. "  [VAR] " .. v.name .. val_str)
  end
  return lines
end

function M._refresh_view()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local cache_key = tostring(state.current_scope_id)

  if not state.children_cache[cache_key] then
    state.parser:send({ cmd = "get_children", id = state.current_scope_id, start_index = 0 }, function(resp)
      if not resp.success then return end
      state.children_cache[cache_key] = { scopes = resp.data.scopes or {}, vars = resp.data.vars or {} }
      vim.schedule(function()
        if M.is_open() then M._refresh_view() end
      end)
    end)
    vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "Netlist", "  (loading...)" })
    vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
    return
  end

  vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
  local lines = {}

  local breadcrumb = "Netlist"
  for _, item in ipairs(state.tree_stack) do
    breadcrumb = breadcrumb .. " > " .. item.name
  end
  table.insert(lines, breadcrumb)
  table.insert(lines, string.rep("─", vim.api.nvim_win_get_width(state.win) or 50))

  local tree_lines = _render_level(state.current_scope_id, 0)
  for _, l in ipairs(tree_lines) do table.insert(lines, l) end

  if #tree_lines == 0 then
    table.insert(lines, "  (empty)")
  end

  table.insert(lines, "")
  table.insert(lines, "<CR>:expand/collapse  <BS>:back  a:add signal  q:close")

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
end

return M
