--- Plugin-wide state: the configuration, the parser process, and the session
--- for the file currently open.

local ParserClient = require("wave.ipc.client")
local Session = require("wave.session")
local resolver = require("wave.install.resolver")
local highlights = require("wave.ui.highlights")
local config = require("wave.config")
local picker = require("wave.ui.picker")
local log = require("wave.util.log")
local Actions = require("wave.actions")

local M = {}

---@type ParserClient|nil
local _client = nil

---@type Session|nil
local _session = nil

---@return Session|nil
function M.session()
  return _session
end

---@param opts table|nil
---@return boolean
function M.setup(opts)
  config.setup(opts)

  local binary = resolver.resolve(config.options.parser_binary)
  if not binary then return false end

  if _client then _client:stop() end
  _client = ParserClient.new(binary)
  if not _client:start() then
    log.error("Failed to start parser process")
    _client = nil
    return false
  end

  picker.setup(_client)
  highlights.apply()
  M._register_autocommands()
  return true
end

---@return boolean
local function ensure_started()
  return _client ~= nil or M.setup({})
end

---@param filepath string
function M.open_file(filepath)
  if not ensure_started() then return end

  local path = vim.fn.expand(filepath)
  if vim.fn.filereadable(path) == 0 then
    log.error("File not found: " .. path)
    return
  end

  if _session and _session.path == path then
    _session:show_viewer()
    return
  end

  if _session then
    _session:close()
    _session = nil
  end

  _client:open(path, function(resp)
    if not resp.success then
      log.error("Failed to open: " .. (resp.error or "unknown"))
      return
    end
    local info = resp.data
    vim.schedule(function()
      _session = Session.new(_client, path, info)
      log.info("Loaded: " .. _session.file_name
        .. " (" .. info.format .. ", " .. info.var_count .. " signals)")
      _session:show_viewer()
    end)
  end)
end

function M.reload()
  if not _session then return end
  local path = _session.path
  _session:close()
  _session = nil
  _client:close_file(function()
    vim.schedule(function() M.open_file(path) end)
  end)
end

function M.toggle_viewer()
  if _session then _session:toggle_viewer() end
end

function M.open_netlist()
  if _session then _session:toggle_netlist() end
end

function M.close_all()
  if _session then _session:close() end
end

function M.search_netlist()
  if not _session then
    log.warn("No file loaded")
    return
  end
  _session:prompt_add_trace()
end

--- Runs an action, by id, against the current session.
---@param id string
function M.invoke(id)
  local action = Actions.by_id(id)
  if action and _session then action.run(_session) end
end

function M.stop()
  if _session then
    _session:close()
    _session = nil
  end
  if _client then
    _client:stop()
    _client = nil
  end
end

function M._register_autocommands()
  local group = vim.api.nvim_create_augroup("WavePlugin", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(args)
      if _session then _session:on_buffer_wiped(args.buf) end
    end,
  })

  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      if _session then _session:render() end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function() highlights.apply() end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function() M.stop() end,
  })
end

return M
