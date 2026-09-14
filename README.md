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

The parser binary is downloaded automatically from GitHub Releases on first `setup()`.  
To build from source instead, see [Building](#building).

## Setup

```lua
require("wave").setup({
  parser_binary = vim.fn.stdpath("data") .. "/wave/wave",
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
    del         = "d",
    expand      = "<CR>",
    back        = "<Backspace>",
    search      = "/",
  },
})
```

## Commands

| Command | Action |
|---------|--------|
| `:WaveOpen <file>` | Open waveform file |
| `:WaveToggle` | Toggle viewer |
| `:WaveNetlist` | Toggle netlist tree |
| `:WaveSearch` | Search netlist signals |
| `:WaveClose` | Close all wave windows |

### Default keymaps (inside viewer buffer)

| Key | Action |
|-----|--------|
| `q` | Close viewer |
| `h` / `l` | Scroll left / right |
| `i` / `o` | Zoom in / out |
| `H` / `L` | Previous / next edge |
| `<Space>` | Set cursor at center |
| `n` | Toggle netlist tree |
| `/` | Search signals and add one |
| `d` | Remove signal at cursor |
| `<CR>` | Expand multi-bit signal |

### Default keymaps (inside netlist buffer)

| Key | Action |
|-----|--------|
| `q` | Close netlist |
| `<CR>` | Expand/collapse scope, or add signal under cursor |
| `<Backspace>` | Collapse enclosing scope |
| `/` | Search signals and add one |

With [fzf-lua](https://github.com/ibhagwan/fzf-lua) installed, search opens straight into its live fuzzy-filtered prompt — type directly, no separate query step. Otherwise it falls back to a query prompt followed by `vim.ui.select`.

These are customizable via `setup({ keymaps = { ... } })`. Unset keys fall back to defaults.

## Building

The binary is auto-downloaded from GitHub Releases on first use.  
To build from source locally:

```bash
cd cmd && cargo build --release
```

Requires the Rust toolchain.  
The binary is looked up in order: `config.parser_binary` → `stdpath("data")/wave/wave` → `$PATH` → local build → GitHub Releases download.
