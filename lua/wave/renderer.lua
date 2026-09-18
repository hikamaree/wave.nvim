local M = {}

local ns = vim.api.nvim_create_namespace("wave_renderer")
local EPS = 1e-12
local MAX_MARKER_DIVISOR = 8
local LABEL_GAP_COLS = 2

---@param c table
---@param key_prefix string
---@param fallback string|nil
---@return string|nil
local function resolve_color(c, key_prefix, fallback)
  local hl_key = key_prefix .. "_hl"
  if c[hl_key] then
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = c[hl_key] })
    if ok and hl and hl.fg then return tostring(hl.fg) end
  end
  return c[key_prefix] or fallback
end

function M.setup_highlights()
  local config = require("wave.config")
  local c = config.options.colors or config.defaults.colors
  local sig = resolve_color(c, "signal", "#98c379")
  local cur = resolve_color(c, "cursor", nil)
  local lbl = resolve_color(c, "label", "#5c6370")
  pcall(vim.api.nvim_set_hl, 0, "WaveSignal", { fg = sig })
  local cursor_hl = { bold = true }
  if cur then cursor_hl.fg = cur end
  pcall(vim.api.nvim_set_hl, 0, "WaveCursor", cursor_hl)
  pcall(vim.api.nvim_set_hl, 0, "WaveLabel", { fg = lbl })
end

--- Returns the 0-indexed column in the waveform string where the point t is displayed.
--- An edge at time t rendered by _build_col_val at column K (first with col_time >= t)
--- appears at top_str[K-1] (0-indexed). So time_to_col(t) = K-1.
---@param t number
---@param time_start number
---@param time_range number
---@param width number
---@return number
function M.time_to_col(t, time_start, time_range, width)
  if time_range <= 0 then return 0 end
  local col = math.ceil(((t - time_start - EPS) / time_range) * width) - 1
  if col < 0 then return 0 end
  if col >= width then return width - 1 end
  return col
end

local NIBBLE_HEX = {}
for n = 0, 15 do
  local bits = ""
  for b = 3, 0, -1 do bits = bits .. math.floor(n / 2 ^ b) % 2 end
  NIBBLE_HEX[bits] = string.format("%X", n)
end

---@param v string
---@return string
local function fmt_val(v)
  if #v <= 1 or v:find("[^01]") then return v end
  local bits = string.rep("0", (4 - #v % 4) % 4) .. v
  local hex = {}
  for i = 1, #bits, 4 do
    hex[#hex + 1] = NIBBLE_HEX[bits:sub(i, i + 3)]
  end
  return "0x" .. (table.concat(hex):match("^0*(.+)$"))
end

---@param value_changes table
---@param time_start number
---@param time_end number
---@param width number
---@param col_vc_end table|nil
---@return table
local function _build_col_val(value_changes, time_start, time_end, width, col_vc_end)
  local time_range = time_end - time_start
  local col_val = {}
  local vc_idx = 1
  for col = 0, width do
    local col_time = time_start + col * (time_range / width)
    while vc_idx < #value_changes and tonumber(value_changes[vc_idx + 1][1]) <= col_time + EPS do
      vc_idx = vc_idx + 1
    end
    col_val[col] = value_changes[vc_idx][2]
    if col_vc_end then col_vc_end[col] = vc_idx end
  end
  return col_val
end

---@param col_vc_end table
---@param width number
---@return table
local function _col_vc_counts(col_vc_end, width)
  local counts = {}
  for col = 0, width - 1 do
    counts[col] = col_vc_end[col + 1] - col_vc_end[col]
  end
  return counts
end

---@param value_changes table|nil
---@param time_start number
---@param time_end number
---@param width number
---@return string, string
function M.render_single_bit(value_changes, time_start, time_end, width)
  if not value_changes or #value_changes == 0 then
    return string.rep(" ", width), string.rep(" ", width)
  end

  local col_vc_end = {}
  local col_val = _build_col_val(value_changes, time_start, time_end, width, col_vc_end)
  local col_tc = _col_vc_counts(col_vc_end, width)

  if col_vc_end[0] > 1 then
    local first_vc_time = tonumber(value_changes[col_vc_end[0]][1])
    if first_vc_time and math.abs(first_vc_time - time_start) <= EPS then
      col_val[0] = value_changes[col_vc_end[0] - 1][2]
      col_vc_end[0] = col_vc_end[0] - 1
      col_tc[0] = col_vc_end[1] - col_vc_end[0]
    end
  end

  local top = {}
  local bot = {}
  for c = 1, width do top[c] = " "; bot[c] = " " end

  for col = 0, width - 1 do
    local c = col + 1
    local v, nv = col_val[col], col_val[col + 1]
    local tc = col_tc[col]

    if tc == 0 then
      if v == "1" then
        top[c] = "─"
      else
        bot[c] = "─"
      end

    elseif tc == 1 then
      if v ~= "0" and v ~= "1" then
        if nv == "1" then top[c] = "─" else bot[c] = "─" end
      else
        -- A dense neighbor's row always expects a connection, so the edge
        -- facing it must be a "┬"/"┴" through-shape instead of a dead-end corner.
        local prev_dense = col > 0 and col_tc[col - 1] >= 2
        local next_dense = col < width - 1 and col_tc[col + 1] >= 2
        if nv == "1" then
          top[c] = prev_dense and "┬" or "┌"
          bot[c] = next_dense and "┴" or "┘"
        else
          top[c] = next_dense and "┬" or "┐"
          bot[c] = prev_dense and "┴" or "└"
        end
      end

    else -- tc >= 2: too many transitions to draw individually, render as a dense band
      top[c] = "┬"
      bot[c] = "┴"

      local left_flat = col > 0 and col_tc[col - 1] == 0
      local right_flat = col < width - 1 and col_tc[col + 1] == 0

      if left_flat and right_flat and v == nv then
        -- Isolated blip: connects to neither side, so use a half-line toward
        -- the other row instead of a dangling corner.
        if v == "1" then bot[c] = "╵" else top[c] = "╷" end
      else
        -- Drop to a corner on the row the flat neighbor doesn't use.
        if left_flat then
          if v == "1" then bot[c] = "└" else top[c] = "┌" end
        end
        if right_flat then
          if nv == "1" then bot[c] = "┘" else top[c] = "┐" end
        end
      end
    end
  end

  return table.concat(top), table.concat(bot)
end

---@param top string[]
---@param bot string[]
---@param v string
---@param start_col number
---@param end_col number
local function _place_initial(top, bot, v, start_col, end_col)
  top[start_col] = "┌"; bot[start_col] = "└"
  local avail = end_col - start_col
  local show_label = #v <= avail
  for c = 1, avail do
    local idx = start_col + c
    if show_label and c <= #v then top[idx] = v:sub(c, c) else top[idx] = "─" end
    bot[idx] = "─"
  end
end

---@param value_changes table|nil
---@param time_start number
---@param time_end number
---@param width number
---@return string, string
function M.render_multi_bit(value_changes, time_start, time_end, width)
  if not value_changes or #value_changes == 0 then
    return string.rep(" ", width), string.rep(" ", width)
  end
  local col_val = _build_col_val(value_changes, time_start, time_end, width)
  local col_val_fmt = {}
  for col = 0, width do col_val_fmt[col] = fmt_val(col_val[col]) end
  local top = {}
  local bot = {}
  for i = 1, width do top[i] = " "; bot[i] = " " end

  local trans = {}
  for col = 0, width - 1 do
    if col_val_fmt[col + 1] ~= col_val_fmt[col] then
      table.insert(trans, col)
    end
  end

  if #trans == 0 then
    _place_initial(top, bot, col_val_fmt[0], 1, width)
    return table.concat(top), table.concat(bot)
  end

  if trans[1] > 0 then
    _place_initial(top, bot, col_val_fmt[0], 1, trans[1])
  end

  for ti, col in ipairs(trans) do
    if col == 0 then
      -- Fresh start at the viewport edge, matching _place_initial.
      top[col + 1] = "┌"
      bot[col + 1] = "└"
    else
      top[col + 1] = "┬"
      bot[col + 1] = "┴"
    end
    local v = col_val_fmt[col + 1]
    local next_col = trans[ti + 1] or width
    local space = next_col - col - 1
    local show_label = #v <= space
    for c = 1, next_col - col - 1 do
      local idx = col + 1 + c
      if idx <= width then
        if show_label and c <= #v then
          top[idx] = v:sub(c, c)
        else
          top[idx] = "─"
        end
        bot[idx] = "─"
      end
    end
  end

  return table.concat(top), table.concat(bot)
end

---@param signal table|nil
---@param label_width number
---@param max_rows number|nil truncate to this many rows if set
---@return string[]
function M.render_value_table(signal, label_width, max_rows)
  local lines = {}
  if not signal or not signal.value_changes or #signal.value_changes == 0 then
    table.insert(lines, string.rep(" ", label_width) .. "  (no data)")
    return lines
  end
  local count = #signal.value_changes
  if max_rows then count = math.min(count, max_rows) end
  for i = 1, count do
    local vc = signal.value_changes[i]
    table.insert(lines, string.rep(" ", label_width) .. "    @" .. vc[1] .. "  " .. fmt_val(vc[2]))
  end
  return lines
end

---@param value_changes table
---@param from_idx number
---@param to_idx number
---@return number|nil
local function _find_first_rise_time(value_changes, from_idx, to_idx)
  -- Don't require the immediately preceding sample to be "0": an intermediate
  -- "x"/"z" would otherwise hide the edge.
  for i = from_idx + 1, to_idx do
    if value_changes[i][2] == "1" then
      return tonumber(value_changes[i][1])
    end
  end
  return nil
end

---@param nums string[]
---@param ticks string[]
---@param col number
---@param edge_time number
---@param width number
---@param label_end number
---@return number
local function _ruler_place(nums, ticks, col, edge_time, width, label_end)
  ticks[col + 1] = "┃"
  local s = tostring(math.floor(edge_time))
  if col < label_end + 1 or col + #s > width then return label_end end
  for j = 0, #s - 1 do
    nums[col + 1 + j] = s:sub(j + 1, j + 1)
  end
  return col + #s
end

---@param time_start number
---@param time_end number
---@param width number
---@param value_changes table
---@return string, string
function M.render_ruler(time_start, time_end, width, value_changes)
  local time_range = time_end - time_start
  local nums = {}
  local ticks = {}
  for i = 1, width do nums[i] = " "; ticks[i] = " " end

  if time_range > 0 then
    local col_vc_end = {}
    local rise_cols = {}
    if #value_changes > 0 then
      local col_val = _build_col_val(value_changes, time_start, time_end, width, col_vc_end)
      for col = 0, width - 1 do
        if col_val[col] == "0" and col_val[col + 1] == "1" then
          table.insert(rise_cols, col)
        end
      end
    end

    ticks[1] = "┃"

    local label_width = #tostring(math.floor(time_end)) + LABEL_GAP_COLS
    local target = math.max(2, math.floor(width / math.max(MAX_MARKER_DIVISOR, label_width)))
    local label_end = -1

    if #rise_cols >= 2 then
      local step = math.ceil(#rise_cols / target)
      for idx = 1, #rise_cols, step do
        local col = rise_cols[idx]
        local edge_time = _find_first_rise_time(value_changes, col_vc_end[col], col_vc_end[col + 1])
        edge_time = edge_time or (time_start + (col + 1) * (time_range / width))
        label_end = _ruler_place(nums, ticks, col, edge_time, width, label_end)
      end
    else
      local step = math.max(1, math.floor(width / target))
      for col = step, width - 1, step do
        label_end = _ruler_place(nums, ticks, col, time_start + (col + 1) * (time_range / width), width, label_end)
      end
    end
  end

  return table.concat(nums), table.concat(ticks)
end

---@return number
function M.get_ns()
  return ns
end

return M
