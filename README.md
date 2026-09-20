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

`parser_binary` is optional: a build in `cmd/target/release/wave` is used when
present, then the copy downloaded to `stdpath("data")`, then `wave` on `$PATH`.
```

## Commands

| Command | Action |
|---------|--------|
| `:WaveOpen <file>` | Open waveform file |
| `:WaveToggle` | Toggle viewer |
| `:WaveNetlist` | Toggle netlist tree |
| `:WaveSearch` | Search netlist signals |
| `:WaveClose` | Close all wave windows |
| `:WaveReload` | Re-read the current file |

### Default keymaps (inside viewer buffer)

| Key | Action |
|-----|--------|
| `q` | Close viewer |
| `h` / `l` | Scroll left / right |
| `i` / `o` | Zoom in / out |
| `H` / `L` | Previous / next edge |
| `<Space>` | Set cursor at center |
| `n` | Toggle netlist tree |
| `f` | Find a signal and add it |
| `dd` | Remove signal at cursor |
| `<CR>` | Expand multi-bit signal |
| `g?` | Show the key list |

Counts work where they make sense: `10l` scrolls ten steps, `5i` zooms in five times.
`d` and `/` are left alone so they keep their usual vim meanings.

### Default keymaps (inside netlist buffer)

| Key | Action |
|-----|--------|
| `q` or `n` | Close netlist |
| `<CR>` | Expand/collapse scope, or add signal under cursor |
| `<Backspace>` | Collapse enclosing scope |
| `f` | Find a signal and add it |

With [fzf-lua](https://github.com/ibhagwan/fzf-lua) installed, search opens straight into its live fuzzy-filtered prompt — type directly, no separate query step. Otherwise it falls back to a query prompt followed by `vim.ui.select`.

These are customizable via `setup({ keymaps = { ... } })`. Unset keys fall back to defaults.

Every action also has a `<Plug>` mapping, so it can be bound outside the viewer buffer:

```lua
vim.keymap.set("n", "<leader>wz", "<Plug>(wave-zoom-in)")
vim.keymap.set("n", "<leader>wn", "<Plug>(wave-netlist)")
```

## Building

The binary is auto-downloaded from GitHub Releases on first use.  
To build from source locally:

```bash
cd cmd && cargo build --release
```

Requires the Rust toolchain.

The binary is looked up in order: `config.parser_binary` → the local build at
`cmd/target/release/wave` → `stdpath("data")/wave/wave` → `wave` on `$PATH` →
GitHub Releases download.

## Development

```bash
make build      # cargo build --release
make test       # every suite below
make purity     # architecture checks
luacheck lua/   # lint
```

Individual suites: `make syntax`, `make test-model` (pure, no Neovim needed), `test-render`,
`test-ipc`, `test-integration`, `test-netlist`, `test-app`, `golden`.

`make golden-update` re-records the golden renders in `tests/golden/`. Do that
only when a rendering change is intended, and check the diff.

### Layout

Dependencies point one way — `config`/`util` ← `model` ← `render`/`ipc` ←
`ui`/`install` ← `session`/`app`. `make purity` enforces the direction, rejects
cycles, and rejects any use of the Neovim API inside `model/` and `render/`,
which is what lets those run under a standalone Lua interpreter (LuaJIT,
the same one Neovim embeds) with no editor in the loop.

```
lua/wave/
  init.lua        public API
  app.lua         config, parser process, current session
  session.lua     one open file: traces, viewport, cursor, scope tree, views
  actions.lua     every viewer action, defined once
  config.lua      defaults and validation

  model/          pure state and math (viewport, traces, edges, scope tree)
  render/         pure data -> rows (waveform painters, layouts)
  ipc/            the parser subprocess and its protocol
  ui/             buffers, windows, painting, pickers
  install/        finding and downloading the binary
```
