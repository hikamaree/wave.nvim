--- wave.nvim - Waveform viewer for Neovim
---
--- Features:
---   - Open VCD, FST, GHW waveform files
---   - Browse netlist hierarchy in a floating window
---   - Add/remove signals to waveform viewer
---   - Pan, zoom, time markers
---   - Search netlist by signal name
---
--- Usage:
---   :WaveOpen <filename>
---   :WaveToggle
---   :WaveNetlist
---   :WaveClose

local config = require("wave.config")
local Parser = require("wave.parser")
local viewer = require("wave.viewer")
local netlist = require("wave.netlist")
local download = require("wave.download")

local M = {}

---@type Parser|nil
local parser

---@type string|nil
local current_file = nil

---@param opts WaveConfig|nil
---@return boolean
function M.setup(opts)
  config.setup(opts)

  local candidates = {
    config.options.parser_binary,
    vim.fn.stdpath("data") .. "/wave/wave",
    "wave",
    vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":p:h:h:h") .. "/cmd/target/release/wave",
  }
  local binary_path
  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) ~= 0 then
      binary_path = path
      break
    end
  end
  if not binary_path then
    binary_path = download.download()
    if not binary_path then
      vim.notify("[wave] Parser binary not found. Build with: cd cmd && cargo build --release, then copy to "
        .. vim.fn.stdpath("data") .. "/wave/wave", vim.log.levels.WARN)
      return false
    end
  end

  parser = Parser.create_parser(binary_path)

  local ok = parser:start()
  if not ok then
    vim.notify("[wave] Failed to start parser process", vim.log.levels.ERROR)
    return false
  end

  viewer.setup(parser)
  netlist.setup(parser)

  M._register_commands()
  M._register_autocommands()
  return true
end

---@param filepath string
function M.open_file(filepath)
  if not parser then
    vim.notify("[wave] Parser not initialized. Call setup() first.", vim.log.levels.ERROR)
    return
  end

  local abs_path = vim.fn.expand(filepath)
  if vim.fn.filereadable(abs_path) == 0 then
    vim.notify("[wave] File not found: " .. abs_path, vim.log.levels.ERROR)
    return
  end

  current_file = abs_path
  viewer.open(abs_path)
end

function M.toggle_viewer()
  viewer.toggle()
end

function M.open_netlist()
  if current_file and viewer.is_open() then
    netlist.toggle(1, "top")
  else
    netlist.toggle(nil)
  end
end

function M.close_all()
  viewer.close()
  netlist.close()
end

function M.search_netlist()
  if not parser then
    vim.notify("[wave] Parser not initialized", vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = "Search netlist: " }, function(query)
    if query and query ~= "" then
      parser:send({ cmd = "search", search_query = query }, function(resp)
        if resp.success and resp.data then
          local results = resp.data.search_results
          if not results or #results == 0 then
            vim.notify("[wave] No results for: " .. query, vim.log.levels.INFO)
            return
          end

          local items = {}
          for _, r in ipairs(results) do
            table.insert(items, r.instance_path .. " (" .. r.item_type .. ")")
          end

          vim.ui.select(items, { prompt = "Netlist search results:" }, function(choice)
            if choice then
              local selected
              for i, item in ipairs(items) do
                if item == choice then
                  selected = results[i]
                  break
                end
              end
              if selected and selected.is_var then
                viewer.add_signal(
                  selected.netlist_id or 0,
                  selected.signal_id or 0,
                  selected.instance_path,
                  selected.width or 1
                )
              end
            end
          end)
        end
      end)
    end
  end)
end

function M._register_commands()
  vim.api.nvim_create_user_command("WaveOpen", function(opts)
    M.open_file(opts.args)
  end, { nargs = 1, complete = "file" })

  vim.api.nvim_create_user_command("WaveToggle", function()
    M.toggle_viewer()
  end, {})

  vim.api.nvim_create_user_command("WaveNetlist", function()
    M.open_netlist()
  end, {})

  vim.api.nvim_create_user_command("WaveClose", function()
    M.close_all()
  end, {})

  vim.api.nvim_create_user_command("WaveSearch", function()
    M.search_netlist()
  end, {})

  vim.api.nvim_create_user_command("WaveReload", function()
    if current_file then
      M.open_file(current_file)
    end
  end, {})
end

function M._register_autocommands()
  local group = vim.api.nvim_create_augroup("WavePlugin", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      viewer.cleanup_buf(args.buf)
      netlist.cleanup_buf(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if parser then
        parser:stop()
      end
    end,
  })
end

return M
