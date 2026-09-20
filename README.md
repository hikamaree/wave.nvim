# wave.nvim

Waveform viewer for Neovim.

<img src="screenshot.png" alt="screenshot" width="800">

## Requirements

- Neovim ≥ 0.12

## Installation

### lazy.nvim
```lua
{
  "hikamaree/wave.nvim",
  opts = {},
}
```

### Built-in (`vim.pack.add`)
```lua
vim.pack.add({
  { src = "https://github.com/hikamaree/wave.nvim" },
})
require("wave").setup({})
```

## Setup

```lua
require("wave").setup({
  colors = {
    signal = "#98c379",
    label  = "#5c6370",
  },
  keymaps = {
    close       = "q",
    scroll_left = "h",
    scroll_right = "l",
    zoom_in     = "i",
    zoom_out    = "o",
    prev_edge   = "H",
    next_edge   = "L",
    cursor      = "<Space>",
    netlist     = "n",
    del         = "dd",
    expand      = "<CR>",
    back        = "<Backspace>",
    search      = "f",
    help        = "g?",
  },
})
```
