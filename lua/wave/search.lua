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
---@param on_results fun(results: table[]|nil)
local function fetch(query, on_results)
  _parser:send({ cmd = "search", search_query = query }, function(resp)
    if not (resp.success and resp.data) then
      vim.schedule(function()
        vim.notify("[wave] Search failed: " .. (resp.error or "unknown"), vim.log.levels.WARN)
        on_results(nil)
      end)
      return
    end

    local results = {}
    for _, r in ipairs(resp.data.search_results or {}) do
      if r.is_var then table.insert(results, r) end
    end

    vim.schedule(function()
      if resp.data.total_results and resp.data.total_results > #resp.data.search_results then
        vim.notify(string.format(
          "[wave] Showing %d of %d matching signals", #results, resp.data.total_results
        ), vim.log.levels.INFO)
      end
      on_results(results)
    end)
  end)
end

---@param fzf table the required fzf-lua module
---@param results table[]
---@param on_select fun(result: table)
local function open_fzf(fzf, results, on_select)
  local by_label = {}
  local items = {}
  for _, r in ipairs(results) do
    local l = label(r)
    by_label[l] = r
    table.insert(items, l)
  end

  fzf.fzf_exec(items, {
    prompt = "Signals> ",
    actions = {
      ["default"] = function(selected)
        local chosen = selected and selected[1] and by_label[selected[1]]
        if chosen then on_select(chosen) end
      end,
    },
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
--- fzf-lua installed this loads every signal once and opens it immediately,
--- so typing happens inside fzf's own live-filtered prompt. Otherwise prompts
--- for a query first, searches, and shows a static vim.ui.select list.
---@param on_select fun(result: table) called with the chosen search result
function M.prompt(on_select)
  if not _parser then
    vim.notify("[wave] Parser not initialized", vim.log.levels.ERROR)
    return
  end

  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fetch("", function(results)
      if not results then return end
      if #results == 0 then
        vim.notify("[wave] No signals in this file", vim.log.levels.INFO)
        return
      end
      open_fzf(fzf, results, on_select)
    end)
    return
  end

  vim.ui.input({ prompt = "Search signals: " }, function(query)
    if not query or query == "" then return end
    fetch(query, function(results)
      if not results then return end
      if #results == 0 then
        vim.notify("[wave] No signals found for: " .. query, vim.log.levels.INFO)
        return
      end
      open_native(results, on_select)
    end)
  end)
end

return M
