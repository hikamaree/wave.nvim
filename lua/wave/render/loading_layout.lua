--- The screen shown while the parser reads a file, so a slow open does not
--- look like a hang.

local Row = require("wave.render.row")
local Text = require("wave.render.text")

local LoadingLayout = {}
LoadingLayout.__index = LoadingLayout

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local SHOW_ELAPSED_AFTER_MS = 1500

---@param frame number
---@return string
function LoadingLayout.spinner(frame)
  return SPINNER[(frame % #SPINNER) + 1]
end

---@param ms number
---@return string
local function elapsed_text(ms)
  if ms < SHOW_ELAPSED_AFTER_MS then return "" end
  return string.format("  %.1fs", ms / 1000)
end

---@param text string
---@param cols number
---@return string
local function centred(text, cols)
  local pad = math.max(0, math.floor((cols - Text.width(text)) / 2))
  return string.rep(" ", pad) .. text
end

---@param opts table file_name, frame, elapsed_ms, total_cols, total_rows
---@return LoadingLayout
function LoadingLayout.build(opts)
  local rows = {}
  rows[#rows + 1] = Row.new(" " .. (opts.file_name or "waveform"), "header")

  local message = LoadingLayout.spinner(opts.frame or 0)
    .. "  Parsing waveform…" .. elapsed_text(opts.elapsed_ms or 0)

  local target = math.max(2, math.floor((opts.total_rows or 24) / 2) - 2)
  for _ = #rows + 1, target do
    rows[#rows + 1] = Row.new("", "blank")
  end

  rows[#rows + 1] = Row.new(centred(message, opts.total_cols or 80), "loading")

  -- Same shape as ViewerLayout: the viewer's cursor and scroll handling reads
  -- these off whichever layout is current, and must not have to ask which.
  return setmetatable({
    rows = rows,
    body_first = 1,
    body_last = #rows,
    body_rows = #rows,
    row_offset = 0,
    max_offset = 0,
    cursor_col = nil,
    cursor_offset = 0,
  }, LoadingLayout)
end

---@return nil, nil
function LoadingLayout.at()
  return nil, nil
end

--- No time axis until the file has been read.
---@return nil
function LoadingLayout.time_at()
  return nil
end

---@return nil
function LoadingLayout.column_at()
  return nil
end

---@return nil, nil
function LoadingLayout.column_span()
  return nil, nil
end

--- Nothing to scroll while the file is being read.
---@return number
function LoadingLayout.next_stop()
  return 0
end

---@return number
function LoadingLayout.prev_stop()
  return 0
end

return LoadingLayout
