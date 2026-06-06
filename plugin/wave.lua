if vim.g.loaded_wave then
  return
end
vim.g.loaded_wave = 1

local function ensure_setup()
  local ok, wave = pcall(require, "wave")
  if not ok then
    vim.notify("[wave] Plugin not loaded. Call require('wave').setup() in your config.", vim.log.levels.ERROR)
    return nil
  end
  return wave
end

vim.api.nvim_create_autocmd({ "BufReadCmd", "FileReadCmd" }, {
  pattern = { "*.vcd", "*.VCD", "*.fst", "*.FST", "*.ghw", "*.GHW" },
  group = vim.api.nvim_create_augroup("WaveAutoOpen", { clear = true }),
  callback = function(ev)
    local wave = ensure_setup()
    if wave then
      wave.open_file(ev.file)
    end
  end,
  desc = "Open waveform files with wave.nvim",
})

vim.api.nvim_create_user_command("WaveOpen", function(opts)
  local wave = ensure_setup()
  if wave then wave.open_file(opts.args) end
end, { nargs = 1, complete = "file", desc = "Open waveform file with wave.nvim" })

vim.api.nvim_create_user_command("WaveToggle", function()
  local wave = ensure_setup()
  if wave then wave.toggle_viewer() end
end, { desc = "Toggle waveform viewer" })

vim.api.nvim_create_user_command("WaveNetlist", function()
  local wave = ensure_setup()
  if wave then wave.open_netlist() end
end, { desc = "Toggle netlist tree view" })

vim.api.nvim_create_user_command("WaveClose", function()
  local wave = ensure_setup()
  if wave then wave.close_all() end
end, { desc = "Close all wave.nvim windows" })

vim.api.nvim_create_user_command("WaveSearch", function()
  local wave = ensure_setup()
  if wave then wave.search_netlist() end
end, { desc = "Search netlist" })

