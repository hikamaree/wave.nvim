--- wave.nvim - waveform viewer for Neovim. See README.md.

local app = require("wave.app")
local Actions = require("wave.actions")

local M = {}

---@param opts WaveConfig|nil
---@return boolean
function M.setup(opts)
  local ok = app.setup(opts)
  if ok then M._register_plug_mappings() end
  return ok
end

---@param filepath string
function M.open_file(filepath)
  app.open_file(filepath)
end

function M.reload()
  app.reload()
end

function M.toggle_viewer()
  app.toggle_viewer()
end

function M.open_netlist()
  app.open_netlist()
end

function M.close_all()
  app.close_all()
end

function M.search_netlist()
  app.search_netlist()
end

---@return Session|nil
function M.session()
  return app.session()
end

function M._register_plug_mappings()
  for _, action in ipairs(Actions.list) do
    vim.keymap.set("n", "<Plug>(wave-" .. action.plug .. ")",
      function() app.invoke(action.id) end,
      { silent = true, desc = "wave: " .. action.id })
  end
end

return M
