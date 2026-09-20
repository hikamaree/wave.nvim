--- Every viewer action, defined once.
---
--- Four tables used to name the same set: the keymap dispatch, the repeatable
--- set, the <Plug> mapping list, and the help text — with the status bar and
--- the help popup each re-deriving the grouping. They all read this now.
---
---   id         the config.keymaps key, and the name shown in the status bar
---   plug       the <Plug>(wave-<plug>) suffix
---   group      status bar and help are ordered and separated by this
---   repeatable honours a count, so "5l" scrolls five steps
---   run        what it does to a session

local M = {}

---@type table[]
M.list = {
  { id = "close", plug = "close", group = 1, desc = "close the viewer",
    run = function(s) s:hide_viewer() end },

  { id = "scroll_left", plug = "scroll-left", group = 2, repeatable = true,
    desc = "scroll left",
    run = function(s) s:scroll_left() end },
  { id = "scroll_right", plug = "scroll-right", group = 2, repeatable = true,
    desc = "scroll right",
    run = function(s) s:scroll_right() end },

  { id = "zoom_in", plug = "zoom-in", group = 3, repeatable = true, desc = "zoom in",
    run = function(s) s:zoom_in() end },
  { id = "zoom_out", plug = "zoom-out", group = 3, repeatable = true, desc = "zoom out",
    run = function(s) s:zoom_out() end },

  { id = "prev_edge", plug = "prev-edge", group = 4, repeatable = true,
    desc = "jump to previous edge",
    run = function(s) s:prev_edge() end },
  { id = "next_edge", plug = "next-edge", group = 4, repeatable = true,
    desc = "jump to next edge",
    run = function(s) s:next_edge() end },
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

  { id = "help", plug = "help", group = 6, desc = "show this help",
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

--- Action ids grouped for display, in definition order.
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

--- Handlers bound to a session, keyed by action id.
---@param session Session
---@return table<string, fun()>
function M.handlers(session)
  local out = {}
  for _, action in ipairs(M.list) do
    out[action.id] = function() action.run(session) end
  end
  return out
end

return M
