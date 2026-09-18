local M = {}

---@type Parser|nil
local _parser = nil

---@param parser table
function M.setup(parser)
  _parser = parser
end

---@param r table
---@return string
local function label(r)
  local width = (r.width and r.width > 1) and ("[" .. r.width .. "]") or ""
  return string.format("%-40s %s%s", r.instance_path, r.item_type or "", width)
end

---@param query string
---@param on_results fun(results: table[]|nil, truncated: boolean)
local function fetch(query, on_results)
  _parser:send({ cmd = "search", search_query = query }, function(resp)
    if not (resp.success and resp.data) then
      vim.schedule(function()
        vim.notify("[wave] Search failed: " .. (resp.error or "unknown"), vim.log.levels.WARN)
        on_results(nil, false)
      end)
      return
    end

    local returned = resp.data.search_results or {}
    local results = {}
    for _, r in ipairs(returned) do
      if r.is_var then table.insert(results, r) end
    end
    local truncated = #returned < (resp.data.total_results or 0)

    vim.schedule(function() on_results(results, truncated) end)
  end)
end

---@param by_path table<string, table>
---@param on_select fun(result: table)
---@return table
local function fzf_actions(by_path, on_select)
  return {
    ["default"] = function(selected)
      local path = selected and selected[1] and selected[1]:match("^(%S+)")
      local chosen = path and by_path[path]
      if chosen then on_select(chosen) end
    end,
  }
end

---@param fzf table
---@param results table[]
---@param on_select fun(result: table)
local function open_fzf(fzf, results, on_select)
  local by_path = {}
  local items = {}
  for _, r in ipairs(results) do
    by_path[r.instance_path] = r
    table.insert(items, label(r))
  end

  fzf.fzf_exec(items, {
    prompt = "Signals> ",
    actions = fzf_actions(by_path, on_select),
  })
end

---@param fzf table
---@param on_select fun(result: table)
local function open_fzf_live(fzf, on_select)
  local by_path = {}

  fzf.fzf_live(function(args)
    local query = args[1] or ""
    return function(cb)
      fetch(query, function(results)
        for _, r in ipairs(results or {}) do
          by_path[r.instance_path] = r
          cb(label(r))
        end
        cb(nil)
      end)
    end
  end, {
    prompt = "Signals> ",
    exec_empty_query = true,
    actions = fzf_actions(by_path, on_select),
  })
end

---@param results table[]
---@param on_select fun(result: table)
local function open_native(results, on_select)
  local items = {}
  for _, r in ipairs(results) do
    table.insert(items, label(r))
  end
  vim.ui.select(items, { prompt = "Signals matching query:" }, function(_, idx)
    if idx then on_select(results[idx]) end
  end)
end

--- Opens a signal picker and calls on_select with the chosen result. With
--- fzf-lua the full signal list is loaded when it fits in one search, and
--- queried per keystroke when it doesn't. Otherwise prompts for a query and
--- shows a vim.ui.select list.
---@param on_select fun(result: table)
function M.prompt(on_select)
  if not _parser then
    vim.notify("[wave] Parser not initialized", vim.log.levels.ERROR)
    return
  end

  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fetch("", function(results, truncated)
      if not results then return end
      if truncated then
        open_fzf_live(fzf, on_select)
      elseif #results == 0 then
        vim.notify("[wave] No signals in this file", vim.log.levels.INFO)
      else
        open_fzf(fzf, results, on_select)
      end
    end)
    return
  end

  vim.ui.input({ prompt = "Search signals: " }, function(query)
    if not query or query == "" then return end
    fetch(query, function(results, truncated)
      if not results then return end
      if #results == 0 then
        vim.notify("[wave] No signals found for: " .. query, vim.log.levels.INFO)
        return
      end
      if truncated then
        vim.notify(string.format("[wave] Too many matches, showing first %d", #results), vim.log.levels.INFO)
      end
      open_native(results, on_select)
    end)
  end)
end

return M
