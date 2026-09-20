--- Defines the plugin's highlight groups and owns its extmark namespace.

local M = {}

local ns = vim.api.nvim_create_namespace("wave_renderer")

--- A `<key>_hl` option names a highlight group to borrow the foreground from;
--- a `<key>` option gives the colour directly.
---@param colors table
---@param key string
---@param fallback string|nil
---@return string|nil
local function resolve(colors, key, fallback)
  local group = colors[key .. "_hl"]
  if group then
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
    if ok and hl and hl.fg then return string.format("#%06x", hl.fg) end
  end
  return colors[key] or fallback
end

function M.apply()
  local config = require("wave.config")
  local colors = config.options.colors or config.defaults.colors

  pcall(vim.api.nvim_set_hl, 0, "WaveSignal", { fg = resolve(colors, "signal", "#98c379") })
  pcall(vim.api.nvim_set_hl, 0, "WaveLabel", { fg = resolve(colors, "label", "#5c6370") })

  local cursor = { bold = true }
  cursor.fg = resolve(colors, "cursor", nil)
  pcall(vim.api.nvim_set_hl, 0, "WaveCursor", cursor)
end

---@return number
function M.namespace()
  return ns
end

return M
