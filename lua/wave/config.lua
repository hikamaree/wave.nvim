---@class WaveColors
---@field signal string|nil
---@field cursor string|nil
---@field label string|nil
---@field signal_hl string|nil
---@field cursor_hl string|nil
---@field label_hl string|nil

---@class WaveConfig
---@field parser_binary string
---@field colors WaveColors
---@field keymaps table<string, string>

local M = {}

---@type WaveConfig
M.defaults = {
  parser_binary = vim.fn.stdpath("data") .. "/wave/wave",
  colors = {
    signal = "#98c379",
    cursor = nil,
    label = "#5c6370",
  },
  keymaps = {
    close = "q",
    scroll_left = "h",
    scroll_right = "l",
    zoom_in = "i",
    zoom_out = "o",
    fit = "0",
    prev_edge = "H",
    next_edge = "L",
    cursor = "<Space>",
    add = "a",
    del = "d",
    expand = "<CR>",
  },
}

---@type WaveConfig
M.options = {}

---@param opts WaveConfig|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("keep", opts or {}, M.defaults)
end

return M
