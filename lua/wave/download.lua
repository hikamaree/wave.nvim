local M = {}

local repo = "hikamaree/wave.nvim"

local function platform()
  local sysname = vim.loop.os_uname().sysname
  local machine = vim.loop.os_uname().machine
  local os = sysname:lower():match("linux") and "linux" or "macos"
  local arch = machine:lower():gsub("amd64", "x86_64"):gsub("arm64", "aarch64")
  return arch .. "-" .. os
end

function M.download()
  local target = platform()
  local dest = vim.fn.stdpath("data") .. "/wave"
  local binary = dest .. "/wave"

  vim.fn.mkdir(dest, "p")

  local api_url = ("https://api.github.com/repos/%s/releases/latest"):format(repo)
  local resp = vim.fn.system({ "curl", "-sL", api_url })
  if vim.v.shell_error ~= 0 then
    vim.notify("[wave] Failed to fetch latest release info", vim.log.levels.WARN)
    return nil
  end

  local ok, data = pcall(vim.json.decode, resp)
  if not ok or type(data) ~= "table" or type(data.assets) ~= "table" then
    vim.notify("[wave] Failed to parse release info", vim.log.levels.WARN)
    return nil
  end

  local asset
  for _, a in ipairs(data.assets) do
    if a.name and a.name:find(target, 1, true) then
      asset = a
      break
    end
  end

  if not asset then
    vim.notify("[wave] No release asset for " .. target, vim.log.levels.WARN)
    return nil
  end

  local url = asset.browser_download_url
  vim.fn.system({ "curl", "-fsL", "-o", binary, url })
  if vim.v.shell_error ~= 0 then
    vim.notify("[wave] Failed to download parser binary", vim.log.levels.WARN)
    os.remove(binary)
    return nil
  end

  vim.fn.setfperm(binary, "rwxr-xr-x")

  if vim.fn.executable(binary) == 0 then
    vim.notify("[wave] Downloaded binary is not executable", vim.log.levels.WARN)
    return nil
  end

  vim.notify("[wave] Downloaded parser binary to " .. binary, vim.log.levels.INFO)
  return binary
end

return M
