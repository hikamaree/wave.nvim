local viewer = require("wave.viewer")
local config = require("wave.config")
local search = require("wave.search")

local M = {}
local _pending_requests = {} ---@type table<number, boolean>

---@class NetlistState

---@type Parser|nil
local _parser = nil

local _states = {}
---@type number|nil
local _netlist_buf = nil

local function _get_state()
  if not _netlist_buf then return nil end
  return _states[_netlist_buf]
end

---@return NetlistState
local function _make_state(buf, win, scope_id, scope_name)
  ---@type NetlistState
  local st = {
    buf = buf,
    win = win,
    children_cache = {},
    expanded_scopes = {},
    root_name = scope_name or tostring(scope_id),
    current_scope_id = scope_id,
    line_scope = {},
  }
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
  local buf = _netlist_buf
  if not buf then return end
  local st = _states[buf]
  if not st then return end
  -- Clear state before closing: the buffer is bufhidden=wipe, so nvim_win_close
  -- synchronously re-enters this via BufWipeout -> cleanup_buf.
  _states[buf] = nil
  _netlist_buf = nil
  _pending_requests = {}
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_win_close(st.win, true)
  end
end

---@param buf number
function M.cleanup_buf(buf)
  if _netlist_buf ~= buf then return end
  local st = _states[buf]
  -- Same reentrancy hazard as M.close (this is also the BufWipeout handler).
  _states[buf] = nil
  _netlist_buf = nil
  _pending_requests = {}
  if st and st.win and vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_win_close, st.win, true)
  end
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
  _make_state(buf, win, sid, scope_name or tostring(sid))

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

  local km = config.options.keymaps
  map(km.expand or "<CR>", function() M._on_enter() end)
  map(km.back or "<Backspace>", function() M._on_back() end)
  map(km.search or "/", function() M.search() end)
  map(km.close or "q", function() M.close() end)
end

function M.search()
  search.prompt(function(r)
    viewer.add_signal(r.netlist_id or 0, r.signal_id or 0, r.instance_path, r.width or 1)
  end)
end

--- Pages through get_children while remaining_items > 0.
---@param scope_id number
---@param on_done fun(children: {scopes: table[], vars: table[]}|nil)
local function _fetch_all_children(scope_id, on_done)
  if not _parser then
    on_done(nil)
    return
  end
  local acc = { scopes = {}, vars = {} }
  local function step(start_index)
    _parser:send({ cmd = "get_children", id = scope_id, start_index = start_index }, function(resp)
      if not resp.success then
        on_done(nil)
        return
      end
      local data = resp.data or {}
      for _, s in ipairs(data.scopes or {}) do table.insert(acc.scopes, s) end
      for _, v in ipairs(data.vars or {}) do table.insert(acc.vars, v) end
      if (data.remaining_items or 0) > 0 then
        step(start_index + (data.total_returned or 0))
      else
        on_done(acc)
      end
    end)
  end
  step(0)
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

  local indicator, sid_str = text:match("%[([%+%-])%]%s+(%d+):(.+)$")
  if indicator then
    local sid = tonumber(sid_str)
    if not sid then return end

    if indicator == "+" then
      st.expanded_scopes[sid] = true
      M._refresh_view()
      local req_id = sid
      _fetch_all_children(sid, function(children)
        if not children then return end
        local st2 = _get_state()
        if not st2 then return end
        st2.children_cache[req_id] = children
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

  if text:match("%[VAR%]") then
    M._add_signal_at_cursor()
  end
end

--- Collapses the scope under the cursor, or its owning scope if the cursor
--- is on one of that scope's children, folding back up toward the root.
function M._on_back()
  local st = _get_state()
  if not st or not st.win then return end
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local buf = vim.api.nvim_win_get_buf(st.win)
  local line_text = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""
  local own_sid = line_text:match("%[%-%]%s+(%d+):")
  local scope_id = own_sid and tonumber(own_sid) or st.line_scope[cursor[1]]
  if not scope_id or not st.expanded_scopes[scope_id] then return end
  st.expanded_scopes[scope_id] = nil
  M._refresh_view()
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

  -- Resolve via the line's owning scope; sibling scopes can share a variable name.
  local scope_id = st.line_scope[line]
  local cache = scope_id and st.children_cache[scope_id]
  if not cache then return end
  local var
  for _, v in ipairs(cache.vars) do
    if v.name == var_name then
      var = v
      break
    end
  end
  if var then
    viewer.add_signal(var.netlist_id or 0, var.signal_id or 0, var.name, var.width or 1)
  end
end

---@param scope_id number
---@param indent number
---@param lines string[] output, appended in place
---@param line_scopes number[] output, appended in place
local function _render_level(scope_id, indent, lines, line_scopes)
  local st = _get_state()
  if not st then return end
  local cache = st.children_cache[scope_id]
  if not cache then return end
  local ind = string.rep("  ", indent)
  for _, s in ipairs(cache.scopes) do
    local expanded = st.expanded_scopes[s.id]
    table.insert(lines, ind .. "  [" .. (expanded and "-" or "+") .. "] " .. tostring(s.id) .. ":" .. s.name)
    table.insert(line_scopes, scope_id)
    if expanded then
      _render_level(s.id, indent + 1, lines, line_scopes)
    end
  end
  for _, v in ipairs(cache.vars) do
    local val_str = ""
    if v.width and v.width > 1 then
      val_str = string.format(" [%d:0]", v.width - 1)
    end
    table.insert(lines, ind .. "  [VAR] " .. v.name .. val_str)
    table.insert(line_scopes, scope_id)
  end
end

function M._refresh_view()
  local st = _get_state()
  if not st or not st.win then return end
  local buf = vim.api.nvim_win_get_buf(st.win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not st.children_cache[st.current_scope_id] then
    if not _parser then return end
    if _pending_requests[st.current_scope_id] then return end
    _pending_requests[st.current_scope_id] = true
    local load_scope = st.current_scope_id
    _fetch_all_children(load_scope, function(children)
      _pending_requests[load_scope] = nil
      if not children then return end
      local st2 = _get_state()
      if not st2 or st2.current_scope_id ~= load_scope then return end
      st2.children_cache[load_scope] = children
      vim.schedule(function()
        if M.is_open() then M._refresh_view() end
      end)
    end)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Netlist", "  (loading...)" })
    vim.bo[buf].modifiable = false
    return
  end

  local ok = pcall(function()
    vim.bo[buf].modifiable = true
    local lines = {}

    table.insert(lines, "Netlist > " .. st.root_name)
    table.insert(lines, string.rep("─", vim.api.nvim_win_get_width(st.win) or 50))

    local header_lines = #lines
    local tree_lines = {}
    local tree_scopes = {}
    _render_level(st.current_scope_id, 0, tree_lines, tree_scopes)
    for _, l in ipairs(tree_lines) do table.insert(lines, l) end

    st.line_scope = {}
    for i, sid in ipairs(tree_scopes) do
      st.line_scope[header_lines + i] = sid
    end

    if #tree_lines == 0 then
      table.insert(lines, "  (empty)")
    end

    table.insert(lines, "")
    local km = config.options.keymaps
    table.insert(lines, (km.expand or "<CR>") .. ": expand/collapse/add")
    table.insert(lines, (km.back or "<Backspace>") .. ": back")
    table.insert(lines, (km.search or "/") .. ": search")
    table.insert(lines, (km.close or "q") .. ": close")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end)
  if not ok then
    vim.bo[buf].modifiable = false
    vim.notify("[wave] Netlist render error", vim.log.levels.ERROR)
  end
end

return M
