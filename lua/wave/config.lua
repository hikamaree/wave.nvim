--- User configuration: defaults, validation, and the merged options.

local log = require("wave.util.log")

---@class WaveColors
---@field signal string|nil      hex colour for the waveform
---@field signal_hl string|nil   highlight group to take the waveform colour from
---@field cursor string|nil      hex colour for the time cursor
---@field cursor_hl string|nil   highlight group to take the cursor colour from
---@field label string|nil       hex colour for signal labels
---@field label_hl string|nil    highlight group to take the label colour from

---@class WaveConfig
---@field parser_binary string|nil
---@field colors WaveColors
---@field keymaps table<string, string>

local M = {}

---@type WaveConfig
M.defaults = {
  parser_binary = nil,
  ---@type WaveColors
  colors = {
    signal = "#98c379",
    signal_hl = nil,
    cursor = nil,
    cursor_hl = nil,
    label = "#5c6370",
    label_hl = nil,
  },
  keymaps = {
    close = "q",
    scroll_left = "h",
    scroll_right = "l",
    zoom_in = "i",
    zoom_out = "o",
    prev_edge = "H",
    next_edge = "L",
    cursor = "<Space>",
    netlist = "n",
    del = "dd",
    expand = "<CR>",
    back = "<Backspace>",
    search = "f",
    help = "g?",
  },
}

---@type WaveConfig
M.options = vim.deepcopy(M.defaults)

--- `back` is netlist-only, so it has no entry in the action registry.
local EXTRA_KEYMAPS = { back = true }

---@param value any
---@return boolean
local function is_hex_colour(value)
  return type(value) == "string" and value:match("^#%x%x%x%x%x%x$") ~= nil
end

--- Reports anything that would be silently ignored, rather than leaving the
--- user to wonder why their setting had no effect.
---@param opts table
---@return string[]
function M.validate(opts)
  local problems = {}

  for key in pairs(opts) do
    if M.defaults[key] == nil and key ~= "parser_binary" then
      problems[#problems + 1] = "unknown option: " .. tostring(key)
    end
  end

  if opts.parser_binary ~= nil and type(opts.parser_binary) ~= "string" then
    problems[#problems + 1] = "parser_binary must be a string"
  end

  for key, value in pairs(opts.colors or {}) do
    if M.defaults.colors[key] == nil and not key:match("_hl$") then
      problems[#problems + 1] = "unknown colour: " .. tostring(key)
    elseif not key:match("_hl$") and value ~= nil and not is_hex_colour(value) then
      problems[#problems + 1] = ("colors.%s must be #rrggbb, got %s"):format(key, tostring(value))
    elseif key:match("_hl$") and value ~= nil and type(value) ~= "string" then
      problems[#problems + 1] = ("colors.%s must be a highlight group name"):format(key)
    end
  end

  local Actions = require("wave.actions")
  for key, value in pairs(opts.keymaps or {}) do
    if not Actions.by_id(key) and not EXTRA_KEYMAPS[key] then
      problems[#problems + 1] = "unknown keymap: " .. tostring(key)
    elseif type(value) ~= "string" then
      problems[#problems + 1] = ("keymaps.%s must be a string"):format(key)
    end
  end

  return problems
end

---@param opts WaveConfig|nil
function M.setup(opts)
  opts = opts or {}
  for _, problem in ipairs(M.validate(opts)) do
    log.warn("config: " .. problem)
  end
  M.options = vim.tbl_deep_extend("keep", opts, M.defaults)
end

return M
