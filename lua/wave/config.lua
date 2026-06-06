local M = {}

M.defaults = {
  parser_binary = vim.fn.stdpath("data") .. "/wave/wave",
  auto_open = true,
  keymaps = {
    toggle_viewer = "<leader>wv",
    toggle_netlist = "<leader>wn",
    add_signal = "<leader>wa",
    remove_signal = "<leader>wd",
    zoom_in = "<C-=>",
    zoom_out = "<C-->",
    zoom_fit = "<C-0>",
    scroll_left = "<Left>",
    scroll_right = "<Right>",
    marker_prev_edge = "<S-Left>",
    marker_next_edge = "<S-Right>",
    search_netlist = "<leader>wf",
  },
  window = {
    width_ratio = 0.7,
    height_ratio = 0.6,
  },
  colors = {
    signal = "#98c379",
    cursor = nil,
    label = "#5c6370",
    -- or set *_hl to read from a highlight group (e.g. signal_hl = "Type")
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("keep", opts or {}, M.defaults)
end

return M
