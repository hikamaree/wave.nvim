--- The viewer's content: a pinned header and ruler, a scrolling body of
--- trace blocks, and a pinned key bar.
---
--- The layout fills the window exactly, so the buffer never scrolls and the
--- header and key bar cannot slide out of view. Moving through more traces
--- than fit scrolls the body by `row_offset` instead.

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

-- header, ruler numbers, ruler ticks, gap
local HEADER_ROWS = 4
-- gap, key bar
local FOOTER_ROWS = 2

--- Splits the window between label gutter and waveform.
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

--- Elided from the middle-right so the bit range stays readable.
---@param trace Trace
---@param cols number
---@return string
local function label_text(trace, cols)
  local label = (trace.ref.name or "?") .. trace.ref:bit_suffix()
  if trace.expanded then label = label .. " ▼" end

  local width = Text.width(label)
  if width <= cols then return Text.pad(label, cols) end

  local suffix = trace.ref:bit_suffix()
  local keep = cols - 1 - Text.width(suffix)
  if keep < 1 then return Text.truncate(label, cols - 1) .. "…" end
  return Text.truncate(label, keep) .. "…" .. suffix
end

--- The first single-bit trace with data is the ruler's clock reference.
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

--- Drops whole groups from the right until it fits.
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

--- Rows one trace occupies: two waveform rows, any expanded values, a gap.
--- Counted without painting, so the body can be measured cheaply.
---@param trace Trace
---@param opts table
---@return number
local function block_height(trace, opts)
  if trace.ref:is_multi_bit() and trace.expanded then
    return 3 + ValueTable.row_count(trace, MAX_EXPANDED_ROWS, opts.viewport.t0, opts.viewport.t1)
  end
  return 3
end

--- Paints one trace's block into `rows`.
local function paint_block(rows, trace, opts, scale, label_cols, wave_cols)
  local lead = string.rep(" ", LEAD_SPACE)
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
      -- Tracked too, or the cursor breaks into pieces across an expansion.
      rows[#rows + 1] = Row.new(line, "values", trace):track_cursor()
    end
  end

  rows[#rows + 1] = Row.new(string.rep(" ", LEAD_SPACE + label_cols + wave_cols), "gap", trace)
    :track_cursor()
end

--- The visible slice of the body.
---
--- Only traces that intersect the window are painted, so a render costs what
--- is on screen rather than what is loaded: scrolling a hundred signals is
--- the same work as scrolling five.
---@return Row[] rows, number total_rows, number offset, number[] starts
local function body_slice(opts, scale, label_cols, wave_cols, height)
  if #opts.traces == 0 then
    return { Row.new(string.rep(" ", label_cols) .. "  No signals added yet", "empty") }, 1, 0, { 0 }
  end

  local heights, starts, total = {}, {}, 0
  for i, trace in ipairs(opts.traces) do
    starts[i] = total
    heights[i] = block_height(trace, opts)
    total = total + heights[i]
  end

  -- Clamped to the last stop, not to total - height: the last stop is a block
  -- boundary and may sit past it, showing a blank row or two.
  local last = ViewerLayout.last_stop(starts, total, height)
  local offset = math.max(0, math.min(opts.row_offset or 0, last))

  -- Walk to the trace holding the first visible row, then paint forward until
  -- the window is covered.
  local rows, row = {}, 0
  local skipped = 0
  for i, trace in ipairs(opts.traces) do
    if row + heights[i] > offset then
      if #rows == 0 then skipped = offset - row end
      paint_block(rows, trace, opts, scale, label_cols, wave_cols)
      if #rows - skipped >= height then break end
    end
    row = row + heights[i]
  end

  -- Drop the part of the first block that sits above the window.
  for _ = 1, skipped do table.remove(rows, 1) end

  return rows, total, offset, starts
end

--- Rows the body can show, given the window height.
---@param total_rows number
---@return number
function ViewerLayout.body_height(total_rows)
  return math.max(1, (total_rows or 24) - HEADER_ROWS - FOOTER_ROWS)
end

--- Where the body may start.
---
--- A signal is three rows, so a free offset would put the body's first line
--- on a waveform's underside or a blank gap two times out of three. Stops are
--- the block boundaries. A block taller than the window — an expanded bus —
--- also has row stops from its value table onward, or its later rows could
--- not be reached; those are derived on demand, since enumerating them for a
--- twenty-thousand-row table would cost more than the render.
---
--- A block is two waveform rows, then value rows, then a gap, so a sub-stop
--- starts no earlier than two rows in.
local VALUE_ROWS_FROM = 2

--- Index of the block containing `offset`.
---@param starts number[]
---@param offset number
---@return number
local function block_of(starts, offset)
  for i = #starts, 1, -1 do
    if starts[i] <= offset then return i end
  end
  return 1
end

--- Last offset worth scrolling to: the first block boundary from which the
--- remaining rows fit, or a row stop inside a block too tall to fit.
---@param starts number[]
---@param total number
---@param height number
---@return number
function ViewerLayout.last_stop(starts, total, height)
  for i, start in ipairs(starts) do
    if total - start <= height then return start end
    local next_start = starts[i + 1] or total
    if next_start - start > height then
      -- A tall block: stop where its own tail reaches the bottom.
      local inside = total - height
      if inside < next_start then return math.max(start + VALUE_ROWS_FROM, inside) end
    end
  end
  return math.max(0, total - height)
end

--- Row stops inside block `i`, or nil when the block fits the window.
---
--- They run from its value table to the offset where its own last row reaches
--- the bottom; past that the next block's start is the stop, or the top of the
--- screen would show this block's trailing gap.
---@param i number
---@return number|nil first, number|nil last
local function sub_range(layout, i)
  local starts = layout.block_starts
  local from = starts[i]
  local to = starts[i + 1] or layout.body_rows
  if to - from <= layout.body_height then return nil end

  local first = from + VALUE_ROWS_FROM
  local last = to - layout.body_height
  if last < first then return nil end
  return first, last
end

---@param offset number
---@return number
function ViewerLayout:next_stop(offset)
  local starts = self.block_starts
  local i = block_of(starts, offset)

  local first, last = sub_range(self, i)
  if first and offset + 1 <= last then
    return math.min(self.max_offset, math.max(offset + 1, first))
  end
  return math.min(self.max_offset, starts[i + 1] or self.max_offset)
end

---@param offset number
---@return number
function ViewerLayout:prev_stop(offset)
  if offset <= 0 then return 0 end
  local starts = self.block_starts
  local i = block_of(starts, offset)

  local first = sub_range(self, i)
  if first and offset > first then return offset - 1 end
  if offset > starts[i] then return starts[i] end

  -- At a block start, step back into the previous block's rows if it has any.
  if i <= 1 then return 0 end
  local _, prev_last = sub_range(self, i - 1)
  return prev_last or starts[i - 1]
end

---@param opts table traces, viewport, cursor_time, time_unit, file_name,
---            total_cols, total_rows, row_offset, keymaps, help_groups
---@return ViewerLayout
function ViewerLayout.build(opts)
  local label_cols, wave_cols = ViewerLayout.columns(opts.total_cols)
  local scale = TimeScale.new(opts.viewport.t0, opts.viewport.t1, wave_cols)
  local full_width = LEAD_SPACE + label_cols + wave_cols
  local rows = {}

  rows[#rows + 1] = Row.new(header_text(opts), "header")

  local nums, ticks = Ruler.paint(scale, ruler_reference(opts.traces))
  local ruler_pad = string.rep(" ", label_cols + 1)
  rows[#rows + 1] = Row.new(ruler_pad .. nums, "ruler_nums")
  rows[#rows + 1] = Row.new(ruler_pad .. ticks, "ruler_ticks"):track_cursor()
  rows[#rows + 1] = Row.new("", "gap"):track_cursor()

  local height = ViewerLayout.body_height(opts.total_rows)
  local body, body_rows, offset, starts = body_slice(opts, scale, label_cols, wave_cols, height)

  -- Padding below the last signal is not part of any waveform, so the cursor
  -- stops at the content rather than running on to the key bar.
  for i = 1, height do
    rows[#rows + 1] = body[i] or Row.new(string.rep(" ", full_width), "pad")
  end

  rows[#rows + 1] = Row.new(string.rep(" ", full_width), "gap")
  rows[#rows + 1] = Row.new(key_bar(opts.keymaps, opts.help_groups, full_width), "keys")

  return setmetatable({
    rows = rows,
    scale = scale,
    label_cols = label_cols,
    wave_cols = wave_cols,
    body_first = HEADER_ROWS + 1,
    body_last = HEADER_ROWS + height,
    body_rows = body_rows,
    body_height = height,
    block_starts = starts,
    row_offset = offset,
    max_offset = ViewerLayout.last_stop(starts, body_rows, height),
    cursor_col = opts.cursor_time and scale.range > 0 and scale:to_col(opts.cursor_time) or nil,
    cursor_offset = LEAD_SPACE + label_cols,
  }, ViewerLayout)
end

--- Waveform column under a 1-based window column, or nil outside it.
---@param wincol number
---@return number|nil
function ViewerLayout:column_at(wincol)
  local col = (wincol - 1) - self.cursor_offset
  if col < 0 or col >= self.wave_cols or self.scale.range <= 0 then return nil end
  return col
end

--- Time under a 1-based window column, or nil outside the waveform area.
---@param wincol number
---@return number|nil
function ViewerLayout:time_at(wincol)
  local col = self:column_at(wincol)
  return col and self.scale:center_of(col) or nil
end

--- Time range a window column covers, for snapping a click to an edge.
---@param wincol number
---@return number|nil from, number|nil to
function ViewerLayout:column_span(wincol)
  local col = self:column_at(wincol)
  if not col then return nil, nil end
  return self.scale:to_time(col), self.scale:to_time(col + 1)
end

--- Trace on a 1-based buffer line, and which part of its block.
---@param line number
---@return Trace|nil, string|nil
function ViewerLayout:at(line)
  local row = self.rows[line]
  if not row then return nil, nil end
  return row.owner, row.kind
end

return ViewerLayout
