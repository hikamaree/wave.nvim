--- Finds the parser binary: local build, previous download, $PATH, download.

local downloader = require("wave.install.downloader")
local log = require("wave.util.log")

local M = {}

---@return string
local function repo_build()
  local root = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":p:h:h:h:h")
  return root .. "/cmd/target/release/wave"
end

---@param configured string|nil
---@return string|nil
function M.resolve(configured)
  local candidates = { repo_build(), vim.fn.stdpath("data") .. "/wave/wave", "wave" }
  if configured then
    table.insert(candidates, 1, configured)
  end

  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) ~= 0 then return path end
  end

  local downloaded = downloader.download()
  if downloaded then return downloaded end

  log.warn("Parser binary not found. Build with: cd cmd && cargo build --release, then copy to "
    .. vim.fn.stdpath("data") .. "/wave/wave")
  return nil
end

return M
