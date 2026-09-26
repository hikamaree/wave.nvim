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

## Mouse

With `mouse` enabled (the default, and Neovim's own `mouse=nvi` is enough):

| Gesture | Action |
|---------|--------|
| Click in the waveform | Put the time cursor there, and select that signal |
| Click a label | Select that signal |
| Drag | Scrub the time cursor |
| Double-click a bus | Expand or collapse it |
| Wheel | Scroll the signal list |
| Shift-wheel, or a horizontal wheel | Pan through time |
| Ctrl-wheel | Zoom about the pointer |
| Double-click in the netlist | Expand a scope, or add a signal |

Set `mouse = false` to leave the mouse to Neovim.

## Setup

```lua
require("wave").setup({
  mouse = true,
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
    down        = "j",
    up          = "k",
    top         = "gg",
    bottom      = "G",
    help        = "g?",
  },
})
```
