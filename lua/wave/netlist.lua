local M = {}

---@class NetlistState
---@field buf number|nil
---@field win number|nil
---@field children_cache table<number, {scopes:table[], vars:table[]}>
---@field expanded_scopes table<number, boolean>
---@field tree_stack table[]
---@field current_scope_id number|nil

---@type Parser|nil
local _parser = nil

local _states = {}
---@type number|nil
local _netlist_buf = nil

local function _get_state()
  if not _netlist_buf then return nil end
  return _states[_netlist_buf]
end

local function _make_state(buf, win, scope_id, scope_name)
  local st = {
    buf = buf,
    win = win,
    children_cache = {},
    expanded_scopes = {},
    tree_stack = {},
    current_scope_id = scope_id,
  }
  st.tree_stack = { { id = scope_id, name = scope_name or tostring(scope_id) } }
  _states[buf] = st
  _netlist_buf = buf
  return st
end

---@param parser table
function M.setup(parser)
  _parser = parser
end

---@return boolean
function M.is_open()
  if not _netlist_buf then return false end
  local st = _states[_netlist_buf]
  return st and st.win and vim.api.nvim_win_is_valid(st.win)
end

function M.close()
  if not _netlist_buf then return end
  local st = _states[_netlist_buf]
  if not st then return end
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_win_close(st.win, true)
  end
  _states[_netlist_buf] = nil
  _netlist_buf = nil
end

---@param buf number
function M.cleanup_buf(buf)
  if _netlist_buf ~= buf then return end
  local st = _states[buf]
  if st and st.win and vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_win_close, st.win, true)
  end
  _states[buf] = nil
  _netlist_buf = nil
end

---@param scope_id number|nil
---@param scope_name string|nil
function M.toggle(scope_id, scope_name)
  if M.is_open() then
    M.close()
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    split = "right",
    win = 0,
    width = 50,
  })
  vim.wo[win].winfixwidth = true
  local sid = scope_id or 1
  local st = _make_state(buf, win, sid, scope_name or tostring(sid))

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "wave-netlist"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldenable = false

  M._setup_keymaps()
  M._refresh_view()
end

function M._setup_keymaps()
  local st = _get_state()
  if not st or not st.win then return end
  local buf = vim.api.nvim_win_get_buf(st.win)
  ---@param lhs string
  ---@param rhs function
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
  local st = _get_state()
  if not st or not st.win then return end
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local buf = vim.api.nvim_win_get_buf(st.win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line = cursor[1]
  if line < 1 or line > #lines then return end
  local text = lines[line]

  local indicator, sid_str, scope_name = text:match("%[([%+%-])%]%s+(%d+):(.+)$")
  if indicator then
    local sid = tonumber(sid_str)
    if not sid then return end

    if indicator == "+" then
      st.expanded_scopes[sid] = true
      M._refresh_view()
      _parser:send({ cmd = "get_children", id = sid, start_index = 0 }, function(resp)
        if not resp.success then return end
        st = _get_state()
        if not st then return end
        st.children_cache[sid] = { scopes = resp.data.scopes or {}, vars = resp.data.vars or {} }
        vim.schedule(function()
          if M.is_open() then M._refresh_view() end
        end)
      end)
    else
      st.expanded_scopes[sid] = nil
      M._refresh_view()
    end
    return
  end
end

function M._on_back()
  local st = _get_state()
  if not st then return end
  if #st.tree_stack > 1 then
    table.remove(st.tree_stack)
    st.current_scope_id = st.tree_stack[#st.tree_stack].id
    M._refresh_view()
  end
end

---@param scope_id number
---@param name string
---@return table|nil
local function _find_var_recursive(scope_id, name)
  local st = _get_state()
  if not st then return nil end
  local cache = st.children_cache[scope_id]
  if not cache then return nil end
  for _, v in ipairs(cache.vars) do
    if v.name == name then return v end
  end
  for _, s in ipairs(cache.scopes) do
    if st.expanded_scopes[s.id] then
      local found = _find_var_recursive(s.id, name)
      if found then return found end
    end
  end
  return nil
end

function M._add_signal_at_cursor()
  local st = _get_state()
  if not st or not st.win then return end
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local buf = vim.api.nvim_win_get_buf(st.win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line = cursor[1]
  if line < 1 or line > #lines then return end
  local text = lines[line]

  if not text:match("%[VAR%]") then return end

  local var_name = text:match("%[VAR%]%s+(.+)%s*$")
  if not var_name then return end
  var_name = var_name:gsub("%s+%[%d+:%d+%]$", "")

  local var = _find_var_recursive(st.current_scope_id, var_name)
  if var then
    local viewer = require("wave.viewer")
    viewer.add_signal(var.netlist_id or 0, var.signal_id or 0, var.name, var.width or 1)
  end
end

---@param scope_id number
---@param indent number
---@return string[]
local function _render_level(scope_id, indent)
  local st = _get_state()
  if not st then return {} end
  local cache = st.children_cache[scope_id]
  if not cache then return {} end
  local lines = {}
  local ind = string.rep("  ", indent)
  for _, s in ipairs(cache.scopes) do
    local expanded = st.expanded_scopes[s.id]
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
  local st = _get_state()
  if not st or not st.win then return end
  local buf = vim.api.nvim_win_get_buf(st.win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not st.children_cache[st.current_scope_id] then
    _parser:send({ cmd = "get_children", id = st.current_scope_id, start_index = 0 }, function(resp)
      if not resp.success then return end
      st = _get_state()
      if not st then return end
      st.children_cache[st.current_scope_id] = { scopes = resp.data.scopes or {}, vars = resp.data.vars or {} }
      vim.schedule(function()
        if M.is_open() then M._refresh_view() end
      end)
    end)
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Netlist", "  (loading...)" })
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    return
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  local lines = {}

  local breadcrumb = "Netlist"
  for _, item in ipairs(st.tree_stack) do
    breadcrumb = breadcrumb .. " > " .. item.name
  end
  table.insert(lines, breadcrumb)
  table.insert(lines, string.rep("─", vim.api.nvim_win_get_width(st.win) or 50))

  local tree_lines = _render_level(st.current_scope_id, 0)
  for _, l in ipairs(tree_lines) do table.insert(lines, l) end

  if #tree_lines == 0 then
    table.insert(lines, "  (empty)")
  end

  table.insert(lines, "")
  table.insert(lines, "<CR>:expand/collapse  <BS>:back  a:add signal  q:close")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

return M
