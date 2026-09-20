--- Choosing a signal from the file.
---
--- Two backends, because they differ in kind rather than in detail: fzf-lua
--- can stream results as the query changes, vim.ui.select needs the whole
--- list up front. The backend is chosen once, before anything is shown.

local log = require("wave.util.log")

local M = {}

---@type ParserClient|nil
local _client = nil

---@param client ParserClient
function M.setup(client)
  _client = client
end

---@param r table
---@return string
local function label(r)
  local width = (r.width and r.width > 1) and ("[" .. r.width .. "]") or ""
  return string.format("%-40s %s%s", r.instance_path, r.item_type or "", width)
end

--- Variables matching `query`, and whether the parser had more to give.
---@param query string
---@param on_results fun(results: table[]|nil, truncated: boolean)
local function fetch(query, on_results)
  _client:search(query, function(resp)
    if not (resp.success and resp.data) then
      log.warn("Search failed: " .. (resp.error or "unknown"))
      on_results(nil, false)
      return
    end

    local returned = resp.data.search_results or {}
    local results = {}
    for _, r in ipairs(returned) do
      if r.is_var then results[#results + 1] = r end
    end
    on_results(results, #returned < (resp.data.total_results or 0))
  end)
end

---@param by_label table<string, table>
---@param on_select fun(result: table)
---@return table
local function actions_for(by_label, on_select)
  return {
    ["default"] = function(selected)
      local path = selected and selected[1] and selected[1]:match("^(%S+)")
      local chosen = path and by_label[path]
      if chosen then on_select(chosen) end
    end,
  }
end

--- The whole list fits: hand it to fzf once and let it filter locally.
local function fzf_static(fzf, results, on_select)
  local by_label, items = {}, {}
  for _, r in ipairs(results) do
    by_label[r.instance_path] = r
    items[#items + 1] = label(r)
  end
  fzf.fzf_exec(items, { prompt = "Signals> ", actions = actions_for(by_label, on_select) })
end

--- Too many to send at once: re-query the parser on each keystroke.
local function fzf_live(fzf, on_select)
  local by_label = {}
  fzf.fzf_live(function(args)
    local query = args[1] or ""
    return function(cb)
      fetch(query, function(results)
        for _, r in ipairs(results or {}) do
          by_label[r.instance_path] = r
          cb(label(r))
        end
        cb(nil)
      end)
    end
  end, {
    prompt = "Signals> ",
    exec_empty_query = true,
    actions = actions_for(by_label, on_select),
  })
end

--- No fzf-lua: ask for a query first, then show what came back.
local function native(on_select)
  vim.ui.input({ prompt = "Search signals: " }, function(query)
    if not query or query == "" then return end
    fetch(query, function(results, truncated)
      if not results then return end
      if #results == 0 then
        log.info("No signals found for: " .. query)
        return
      end
      if truncated then
        log.info(string.format("Too many matches, showing first %d", #results))
      end

      local items = {}
      for _, r in ipairs(results) do items[#items + 1] = label(r) end
      vim.ui.select(items, { prompt = "Signals matching query:" }, function(_, idx)
        if idx then on_select(results[idx]) end
      end)
    end)
  end)
end

--- Opens a picker and calls `on_select` with the chosen search result.
---@param on_select fun(result: table)
function M.prompt(on_select)
  if not _client then
    log.error("Parser not initialized")
    return
  end

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    native(on_select)
    return
  end

  fetch("", function(results, truncated)
    if not results then return end
    if truncated then
      fzf_live(fzf, on_select)
    elseif #results == 0 then
      log.info("No signals in this file")
    else
      fzf_static(fzf, results, on_select)
    end
  end)
end

return M
