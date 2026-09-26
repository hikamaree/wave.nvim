--- Mouse gestures for the viewer.
---
--- Bound here rather than in the action registry: buttons are not rebindable
--- keymaps and do not belong in the help list or the key bar.

local M = {}

-- A notch moves one signal, which is three rows: vim's own default.
local WHEEL_STEPS = 1

--- Where the pointer is, if it is over `window`.
---@param window Window
---@return table|nil { line, wincol }
function M.position(window)
  if not window:valid() then return nil end
  local pos = vim.fn.getmousepos()
  if pos.winid ~= window.handle then return nil end
  return { line = pos.line, wincol = pos.wincol }
end

---@param buffer ScratchBuffer
---@param lhs string
---@param rhs fun()
local function map(buffer, lhs, rhs)
  vim.api.nvim_buf_set_keymap(buffer.handle, "n", lhs, "", {
    callback = rhs, noremap = true, silent = true, desc = "wave: mouse " .. lhs,
  })
end

--- `handlers` takes click, drag, double_click, scroll, pan and zoom.
---@param buffer ScratchBuffer
---@param handlers table
function M.bind_viewer(buffer, handlers)
  map(buffer, "<LeftMouse>", handlers.click)
  map(buffer, "<LeftDrag>", handlers.drag)
  map(buffer, "<LeftRelease>", handlers.drag)
  map(buffer, "<2-LeftMouse>", handlers.double_click)

  map(buffer, "<ScrollWheelDown>", function() handlers.scroll(WHEEL_STEPS) end)
  map(buffer, "<ScrollWheelUp>", function() handlers.scroll(-WHEEL_STEPS) end)

  -- Shift or a horizontal wheel pans time; ctrl zooms about the pointer.
  map(buffer, "<S-ScrollWheelDown>", function() handlers.pan(1) end)
  map(buffer, "<S-ScrollWheelUp>", function() handlers.pan(-1) end)
  map(buffer, "<ScrollWheelRight>", function() handlers.pan(1) end)
  map(buffer, "<ScrollWheelLeft>", function() handlers.pan(-1) end)

  map(buffer, "<C-ScrollWheelUp>", function() handlers.zoom(true) end)
  map(buffer, "<C-ScrollWheelDown>", function() handlers.zoom(false) end)
end

--- The netlist scrolls natively; only activation needs a binding.
---@param buffer ScratchBuffer
---@param handlers table
function M.bind_netlist(buffer, handlers)
  map(buffer, "<2-LeftMouse>", handlers.activate)
end

return M
