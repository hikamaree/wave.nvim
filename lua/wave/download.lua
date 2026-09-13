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
    vim.notify("[wave] Unsupported platform: " .. vim.uv.os_uname().sysname, vim.log.levels.WARN)
    return nil
  end
  local dest = vim.fn.stdpath("data") .. "/wave"
  local binary = dest .. "/wave"

  vim.fn.mkdir(dest, "p")

  local api_url = ("https://api.github.com/repos/%s/releases/latest"):format(repo)
  local ok2, resp = pcall(vim.fn.system, { "curl", "-sL", "--connect-timeout", "10", api_url })
  if not ok2 or vim.v.shell_error ~= 0 then
    vim.notify("[wave] Failed to fetch latest release info. "
      .. "If rate-limited, try: gh auth token | xargs -I{} curl -sL -H 'Authorization: Bearer {}' "
      .. api_url, vim.log.levels.WARN)
    return nil
  end

  local ok, data = pcall(vim.json.decode, resp)
  if not ok or type(data) ~= "table" then
    if type(data) == "table" and data.message then
      vim.notify("[wave] GitHub API: " .. data.message, vim.log.levels.WARN)
    else
      vim.notify("[wave] Failed to parse release info", vim.log.levels.WARN)
    end
    return nil
  end

  if type(data.assets) ~= "table" then
    vim.notify("[wave] No releases found. The repo may have no releases yet.", vim.log.levels.WARN)
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
    vim.notify("[wave] No release asset for " .. target, vim.log.levels.WARN)
    return nil
  end

  -- Download to a temp file first to avoid partial downloads.
  local tmp = binary .. ".tmp." .. vim.fn.getpid()
  local url = asset.browser_download_url
  local ok3 = pcall(vim.fn.system, { "curl", "-fsL", "--connect-timeout", "10", "-o", tmp, url })
  if not ok3 or vim.v.shell_error ~= 0 then
    vim.notify("[wave] Failed to download parser binary from " .. url, vim.log.levels.WARN)
    pcall(os.remove, tmp)
    return nil
  end

  -- Verify the downloaded file is non-empty (curl with -f would have errored on HTTP errors).
  local size = vim.fn.getfsize(tmp)
  if size <= 0 then
    vim.notify("[wave] Downloaded file is empty", vim.log.levels.WARN)
    pcall(os.remove, tmp)
    return nil
  end

  -- Atomically rename temp file to target
  local rename_ok = os.rename(tmp, binary)
  if not rename_ok then
    pcall(os.remove, tmp)
    vim.notify("[wave] Failed to move downloaded binary", vim.log.levels.WARN)
    return nil
  end

  vim.fn.setfperm(binary, "rwxr-xr-x")

  if vim.fn.executable(binary) == 0 then
    vim.notify("[wave] Downloaded binary is not executable", vim.log.levels.WARN)
    pcall(os.remove, binary)
    return nil
  end

  vim.notify("[wave] Downloaded parser binary to " .. binary, vim.log.levels.INFO)
  return binary
end

return M
