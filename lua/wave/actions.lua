--- Every viewer action, defined once. The keymaps, <Plug> mappings, help
--- popup and status bar all read this.
---
---   id            the config.keymaps key, and the name shown in the status bar
---   plug          the <Plug>(wave-<plug>) suffix
---   group         status bar and help are ordered and separated by this
---   repeatable    honours a count, so "5l" scrolls five steps
---   while_loading still allowed before the file has been parsed
---   run           what it does to a session

local M = {}

---@type table[]
M.list = {
  { id = "close", plug = "close", group = 1, desc = "close the viewer",
    while_loading = true,
    run = function(s) s:hide_viewer() end },

  { id = "scroll_left", plug = "scroll-left", group = 2, repeatable = true,
    desc = "scroll left",
    run = function(s, n) s:scroll_left(n) end },
  { id = "scroll_right", plug = "scroll-right", group = 2, repeatable = true,
    desc = "scroll right",
    run = function(s, n) s:scroll_right(n) end },

  { id = "zoom_in", plug = "zoom-in", group = 3, repeatable = true, desc = "zoom in",
    run = function(s, n) s:zoom_in(n) end },
  { id = "zoom_out", plug = "zoom-out", group = 3, repeatable = true, desc = "zoom out",
    run = function(s, n) s:zoom_out(n) end },

  { id = "prev_edge", plug = "prev-edge", group = 4, repeatable = true,
    desc = "jump to previous edge",
    run = function(s, n) s:prev_edge(n) end },
  { id = "next_edge", plug = "next-edge", group = 4, repeatable = true,
    desc = "jump to next edge",
    run = function(s, n) s:next_edge(n) end },
  { id = "cursor", plug = "set-cursor", group = 4,
    desc = "put the time cursor at the centre",
    run = function(s) s:cursor_to_view() end },

  { id = "netlist", plug = "netlist", group = 5, desc = "toggle the netlist",
    run = function(s) s:toggle_netlist() end },
  { id = "search", plug = "find-signal", group = 5, desc = "find a signal",
    run = function(s) s:prompt_add_trace() end },
  { id = "del", plug = "remove-signal", group = 5,
    desc = "remove the signal under the cursor",
    run = function(s) s:remove_trace_at_cursor() end },
  { id = "expand", plug = "expand-signal", group = 5,
    desc = "expand a bus into its values",
    run = function(s) s:toggle_expand_at_cursor() end },

  { id = "down", plug = "cursor-down", group = 6, repeatable = true,
    desc = "move down a row",
    run = function(s, n) s:move_cursor(n) end },
  { id = "up", plug = "cursor-up", group = 6, repeatable = true,
    desc = "move up a row",
    run = function(s, n) s:move_cursor(-n) end },

  { id = "top", plug = "go-top", group = 6, desc = "jump to the first signal",
    run = function(s) s:scroll_extreme(false) end },
  { id = "bottom", plug = "go-bottom", group = 6, desc = "jump to the last signal",
    run = function(s) s:scroll_extreme(true) end },

  { id = "help", plug = "help", group = 7, desc = "show this help",
    while_loading = true,
    run = function(s) s:show_help() end },
}

---@param id string
---@return table|nil
function M.by_id(id)
  for _, action in ipairs(M.list) do
    if action.id == id then return action end
  end
  return nil
end

---@return string[][]
function M.groups()
  local groups, seen = {}, {}
  for _, action in ipairs(M.list) do
    if not seen[action.group] then
      seen[action.group] = {}
      groups[#groups + 1] = seen[action.group]
    end
    table.insert(seen[action.group], action.id)
  end
  return groups
end

---@return table<string, string>
function M.descriptions()
  local out = {}
  for _, action in ipairs(M.list) do out[action.id] = action.desc end
  return out
end

---@return table<string, boolean>
function M.repeatable()
  local out = {}
  for _, action in ipairs(M.list) do
    if action.repeatable then out[action.id] = true end
  end
  return out
end

--- Keys are live on the loading screen, where the viewport is still a
--- placeholder, so acting on it would strand state the real one never had.
---@param action table
---@param session Session
---@param count number|nil
function M.invoke(action, session, count)
  if not action.while_loading and session:is_busy() then return end
  action.run(session, count or 1)
end

---@param session Session
---@return table<string, fun()>
function M.handlers(session)
  local out = {}
  for _, action in ipairs(M.list) do
    out[action.id] = function(count) M.invoke(action, session, count) end
  end
  return out
end

return M
