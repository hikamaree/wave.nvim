---@class WaveColors
---@class WaveConfig

local M = {}

---@type WaveConfig
M.defaults = {
  parser_binary = vim.fn.stdpath("data") .. "/wave/wave",
  ---@type WaveColors
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
M.options = vim.deepcopy(M.defaults)

---@param opts WaveConfig|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("keep", opts or {}, M.defaults)
end

return M
