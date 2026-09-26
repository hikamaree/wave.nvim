--- Rows into a buffer. The only place that sets buffer lines or extmarks.

local Text = require("wave.render.text")
local highlights = require("wave.ui.highlights")

local M = {}

--- Pad to the widest, so the cursor bar has something to sit on all the
--- way down and highlights do not stop short.
---@param rows Row[]
---@return string[]
local function padded_lines(rows)
  local widths, widest = {}, 0
  for i, row in ipairs(rows) do
    widths[i] = Text.width(row.text)
    if widths[i] > widest then widest = widths[i] end
  end

  local lines = {}
  for i, row in ipairs(rows) do
    local short = widest - widths[i]
    lines[i] = short > 0 and (row.text .. string.rep(" ", short)) or row.text
  end
  return lines
end

--- An overlay, so it sits on the waveform without displacing it.
---@param buffer ScratchBuffer
---@param rows Row[]
---@param lines string[]
---@param col number display column, 0-indexed
local function paint_cursor(buffer, rows, lines, col)
  local ns = highlights.namespace()
  for i, row in ipairs(rows) do
    if row.cursor_track then
      -- Extmarks want a byte offset; the column is a display offset.
      local prefix = vim.fn.strcharpart(lines[i] or "", 0, col)
      pcall(vim.api.nvim_buf_set_extmark, buffer.handle, ns, i - 1, #prefix, {
        virt_text = { { "┃", "WaveCursor" } },
        virt_text_pos = "overlay",
        priority = 1000,
      })
    end
  end
end

---@param buffer ScratchBuffer
---@param layout table rows, plus cursor_col and cursor_offset when a cursor is set
---@return boolean ok, string|nil err
function M.paint(buffer, layout)
  if not buffer:valid() then return false, "invalid buffer" end
  local ns = highlights.namespace()
  buffer:clear_namespace(ns)

  return buffer:with_modifiable(function()
    local rows = layout.rows
    local lines = padded_lines(rows)
    buffer:set_lines(lines)

    for i, row in ipairs(rows) do
      for _, hl in ipairs(row.highlights) do
        pcall(vim.api.nvim_buf_set_extmark, buffer.handle, ns, i - 1, hl.from,
          { hl_group = hl.group, end_col = hl.to })
      end
    end

    if layout.cursor_col then
      paint_cursor(buffer, rows, lines, layout.cursor_col + layout.cursor_offset)
    end
  end)
end

return M
