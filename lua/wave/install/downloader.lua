local log = require("wave.util.log")
local M = {}

local repo = "hikamaree/wave.nvim"

---@return string|nil
local function platform()
  local sysname = vim.uv.os_uname().sysname:lower()
  local os
  if sysname:match("linux") then
    os = "linux"
  elseif sysname:match("darwin") then
    os = "macos"
  else
    return nil
  end
  local machine = vim.uv.os_uname().machine
  local arch = machine:lower():gsub("amd64", "x86_64"):gsub("arm64", "aarch64")
  return arch .. "-" .. os
end

local NON_BINARY_SUFFIXES = { "%.sha256$", "%.sha512$", "%.sig$", "%.asc$", "%.md5$", "%.txt$" }

---@param name string
---@return boolean
local function looks_like_binary_asset(name)
  for _, suffix in ipairs(NON_BINARY_SUFFIXES) do
    if name:match(suffix) then return false end
  end
  return true
end

---@return string|nil
function M.download()
  local target = platform()
  if not target then
    log.warn("Unsupported platform: " .. vim.uv.os_uname().sysname)
    return nil
  end
  local dest = vim.fn.stdpath("data") .. "/wave"
  local binary = dest .. "/wave"

  vim.fn.mkdir(dest, "p")

  local api_url = ("https://api.github.com/repos/%s/releases/latest"):format(repo)
  local ok2, resp = pcall(vim.fn.system, { "curl", "-sL", "--connect-timeout", "10", api_url })
  if not ok2 or vim.v.shell_error ~= 0 then
    log.warn("Failed to fetch latest release info. "
      .. "If rate-limited, try: gh auth token | xargs -I{} curl -sL -H 'Authorization: Bearer {}' "
      .. api_url)
    return nil
  end

  local ok, data = pcall(vim.json.decode, resp)
  if not ok or type(data) ~= "table" then
    if type(data) == "table" and data.message then
      log.warn("GitHub API: " .. data.message)
    else
      log.warn("Failed to parse release info")
    end
    return nil
  end

  if type(data.assets) ~= "table" then
    log.warn("No releases found. The repo may have no releases yet.")
    return nil
  end

  local asset
  for _, a in ipairs(data.assets) do
    if a.name and a.name:find(target, 1, true) and looks_like_binary_asset(a.name) then
      asset = a
      break
    end
  end

  if not asset then
    log.warn("No release asset for " .. target)
    return nil
  end

  -- Download to a temp file first to avoid partial downloads.
  local tmp = binary .. ".tmp." .. vim.fn.getpid()
  local url = asset.browser_download_url
  local ok3 = pcall(vim.fn.system, { "curl", "-fsL", "--connect-timeout", "10", "-o", tmp, url })
  if not ok3 or vim.v.shell_error ~= 0 then
    log.warn("Failed to download parser binary from " .. url)
    pcall(os.remove, tmp)
    return nil
  end

  -- Verify the downloaded file is non-empty (curl with -f would have errored on HTTP errors).
  local size = vim.fn.getfsize(tmp)
  if size <= 0 then
    log.warn("Downloaded file is empty")
    pcall(os.remove, tmp)
    return nil
  end

  -- Atomically rename temp file to target
  local rename_ok = os.rename(tmp, binary)
  if not rename_ok then
    pcall(os.remove, tmp)
    log.warn("Failed to move downloaded binary")
    return nil
  end

  vim.fn.setfperm(binary, "rwxr-xr-x")

  if vim.fn.executable(binary) == 0 then
    log.warn("Downloaded binary is not executable")
    pcall(os.remove, binary)
    return nil
  end

  log.info("Downloaded parser binary to " .. binary)
  return binary
end

return M
