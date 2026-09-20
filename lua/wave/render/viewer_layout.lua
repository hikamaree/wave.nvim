--- Builds the viewer's buffer content: header, ruler, one block per trace,
--- and the key bar. Pure — it produces Rows, it does not touch a buffer.

local Row = require("wave.render.row")
local Text = require("wave.render.text")
local TimeScale = require("wave.model.time_scale")
local SingleBit = require("wave.render.single_bit")
local MultiBit = require("wave.render.multi_bit")
local Ruler = require("wave.render.ruler")
local ValueTable = require("wave.render.value_table")

local ViewerLayout = {}
ViewerLayout.__index = ViewerLayout

local LEAD_SPACE = 1
local LABEL_GAP = 3
local MIN_WAVE_COLS = 20
local MAX_LABEL_RATIO = 0.3
local MIN_LABEL_COLS = 15
local MAX_LABEL_COLS = 40
local MAX_EXPANDED_ROWS = 1000

--- Splits the window between the label gutter and the waveform area.
---@param total_cols number
---@return number label_cols, number wave_cols
function ViewerLayout.columns(total_cols)
  local label = math.max(MIN_LABEL_COLS, math.min(MAX_LABEL_COLS, math.floor(total_cols * MAX_LABEL_RATIO)))
  return label, math.max(total_cols - label - LABEL_GAP, MIN_WAVE_COLS)
end

---@param opts table
---@return string
local function header_text(opts)
  local parts = {}
  if opts.file_name then parts[#parts + 1] = opts.file_name end
  parts[#parts + 1] = math.floor(opts.viewport.t0) .. "-" .. math.floor(opts.viewport.t1)
    .. " " .. (opts.time_unit or "ns")
  if opts.cursor_time then
    parts[#parts + 1] = "────  @" .. math.floor(opts.cursor_time)
  end
  parts[#parts + 1] = "Z:" .. opts.viewport:zoom_label() .. "x"
  return table.concat(parts, "  ")
end

--- The label, elided from the middle-right so the bit range stays readable.
---@param trace Trace
---@param cols number
---@return string
local function label_text(trace, cols)
  local label = (trace.ref.path or "?") .. trace.ref:bit_suffix()
  if trace.expanded then label = label .. " ▼" end

  local width = Text.width(label)
  if width <= cols then return Text.pad(label, cols) end

  local suffix = trace.ref:bit_suffix()
  local keep = cols - 1 - Text.width(suffix)
  if keep < 1 then return Text.truncate(label, cols - 1) .. "…" end
  return Text.truncate(label, keep) .. "…" .. suffix
end

--- The first single-bit trace with data acts as the ruler's clock reference.
---@param traces Trace[]
---@return table
local function ruler_reference(traces)
  for _, trace in ipairs(traces) do
    if trace.ref.width == 1 and trace.value_changes and #trace.value_changes > 0 then
      return trace.value_changes
    end
  end
  return {}
end

---@param trace Trace
---@param scale TimeScale
---@return string, string
local function waveform(trace, scale)
  if not trace.value_changes then
    return Text.pad(Text.truncate("(loading...)", scale.cols), scale.cols), string.rep(" ", scale.cols)
  end

  local painter = trace.ref:is_multi_bit() and MultiBit or SingleBit
  local ok, top, bot = pcall(painter.paint, trace.value_changes, scale)
  if not ok then
    return string.rep("?", scale.cols), string.rep("?", scale.cols)
  end
  return top, bot
end

--- The key bar, dropping whole groups from the right until it fits.
---@param keymaps table
---@param groups string[][]
---@param cols number
---@return string
local function key_bar(keymaps, groups, cols)
  local bar = ""
  for _, group in ipairs(groups) do
    local entries = {}
    for _, action in ipairs(group) do
      local lhs = keymaps[action]
      if lhs then
        entries[#entries + 1] = lhs:gsub("^<(.+)>$", string.upper) .. ":" .. action
      end
    end
    local candidate = bar == "" and table.concat(entries, "  ")
      or (bar .. "  │  " .. table.concat(entries, "  "))
    if Text.width(candidate) > cols then break end
    bar = candidate
  end
  return bar
end

---@param opts table traces, viewport, cursor_time, time_unit, file_name, total_cols, keymaps, help_groups
---@return ViewerLayout
function ViewerLayout.build(opts)
  local label_cols, wave_cols = ViewerLayout.columns(opts.total_cols)
  local scale = TimeScale.new(opts.viewport.t0, opts.viewport.t1, wave_cols)
  local lead = string.rep(" ", LEAD_SPACE)
  local rows = {}

  rows[#rows + 1] = Row.new(header_text(opts), "header")

  local nums, ticks = Ruler.paint(scale, ruler_reference(opts.traces))
  local ruler_pad = string.rep(" ", label_cols + 1)
  rows[#rows + 1] = Row.new(ruler_pad .. nums, "ruler_nums")
  rows[#rows + 1] = Row.new(ruler_pad .. ticks, "ruler_ticks"):track_cursor()
  rows[#rows + 1] = Row.new("", "gap"):track_cursor()

  if #opts.traces == 0 then
    rows[#rows + 1] = Row.new(string.rep(" ", label_cols) .. "  No signals added yet", "empty")
  end

  for _, trace in ipairs(opts.traces) do
    local label = label_text(trace, label_cols)
    local top, bot = waveform(trace, scale)

    local label_end = LEAD_SPACE + #label
    local wave_start = LEAD_SPACE + label_cols

    rows[#rows + 1] = Row.new(lead .. label .. top, "wave_top", trace)
      :hl("WaveLabel", LEAD_SPACE, label_end)
      :hl("WaveSignal", label_end, label_end + #top)
      :track_cursor()

    rows[#rows + 1] = Row.new(lead .. string.rep(" ", label_cols) .. bot, "wave_bot", trace)
      :hl("WaveSignal", wave_start, wave_start + #bot)
      :track_cursor()

    if trace.ref:is_multi_bit() and trace.expanded then
      for _, line in ipairs(ValueTable.paint(trace, label_cols, MAX_EXPANDED_ROWS,
        opts.viewport.t0, opts.viewport.t1)) do
        rows[#rows + 1] = Row.new(line, "values", trace)
      end
    end

    rows[#rows + 1] = Row.new(string.rep(" ", LEAD_SPACE + label_cols + wave_cols), "gap", trace)
      :track_cursor()
  end

  rows[#rows + 1] = Row.new(string.rep(" ", LEAD_SPACE + label_cols + wave_cols), "gap")
  rows[#rows + 1] = Row.new(key_bar(opts.keymaps, opts.help_groups, LEAD_SPACE + label_cols + wave_cols), "keys")

  return setmetatable({
    rows = rows,
    label_cols = label_cols,
    wave_cols = wave_cols,
    cursor_col = opts.cursor_time and scale.range > 0 and scale:to_col(opts.cursor_time) or nil,
    cursor_offset = LEAD_SPACE + label_cols,
  }, ViewerLayout)
end

--- The trace occupying a 1-based buffer line, and which part of its block.
---@param line number
---@return Trace|nil, string|nil
function ViewerLayout:at(line)
  local row = self.rows[line]
  if not row then return nil, nil end
  return row.owner, row.kind
end

return ViewerLayout
