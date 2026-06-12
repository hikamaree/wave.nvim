local M = {}

local ns = vim.api.nvim_create_namespace("wave_renderer")
local EPS = 1e-12
local MAX_MARKER_DIVISOR = 8

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

---@param v string
---@return string
local function fmt_val(v)
  if #v > 1 and not v:find("[^01]") then
    local d = tonumber(v, 2)
    if d then return string.format("0x%X", d) end
  end
  return v
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
      elseif nv == "1" then
        top[c] = "┌"
        bot[c] = "┘"
      else
        top[c] = "┐"
        bot[c] = "└"
      end

    else -- tc >= 2
      if v ~= "0" and v ~= "1" then
        top[c] = "─"
        bot[c] = "─"
      else
        local prev_clean = (col == 0) or (col_tc[col - 1] <= 1)
        local next_clean = (col == width - 1) or (col_tc[col + 1] <= 1)
        if next_clean then
          if v == "0" then top[c] = "┐"; bot[c] = "┴"
          else top[c] = "┬"; bot[c] = "┘" end
        elseif prev_clean then
          if v == "0" then top[c] = "┌"; bot[c] = "┘"
          else top[c] = "┐"; bot[c] = "└" end
        else
          top[c] = "┬"
          bot[c] = "┴"
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
  local vlen = math.min(#v, end_col - start_col)
  for c = 1, end_col - start_col do
    local idx = start_col + c
    if c <= vlen then top[idx] = v:sub(c, c) else top[idx] = "─" end
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
    top[col + 1] = "┬"
    bot[col + 1] = "┴"
    local v = col_val_fmt[col + 1]
    local next_col = trans[ti + 1] or width
    local space = next_col - col - 1
    local vlen = math.min(#v, space)
    for c = 1, next_col - col - 1 do
      local idx = col + 1 + c
      if idx <= width then
        if c <= vlen then
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
---@return string[]
function M.render_value_table(signal, label_width)
  local lines = {}
  if not signal or not signal.value_changes or #signal.value_changes == 0 then
    table.insert(lines, string.rep(" ", label_width) .. "  (no data)")
    return lines
  end
  for _, vc in ipairs(signal.value_changes) do
    table.insert(lines, string.rep(" ", label_width) .. "    @" .. vc[1] .. "  " .. fmt_val(vc[2]))
  end
  return lines
end

---@param value_changes table
---@param from_idx number
---@param to_idx number
---@return number|nil
local function _find_first_rise_time(value_changes, from_idx, to_idx)
  for i = from_idx + 1, to_idx do
    if value_changes[i - 1][2] == "0" and value_changes[i][2] == "1" then
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
local function _ruler_place(nums, ticks, col, edge_time, width)
  ticks[col + 1] = "┃"
  local s = tostring(math.floor(edge_time))
  for j = 0, #s - 1 do
    local c = col + 1 + j
    if c <= width then nums[c] = s:sub(j + 1, j + 1) end
  end
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

  if #value_changes > 0 and time_range > 0 then
    local col_vc_end = {}
    local col_val = _build_col_val(value_changes, time_start, time_end, width, col_vc_end)

    local rise_cols = {}
    for col = 0, width - 1 do
      if col_val[col] == "0" and col_val[col + 1] == "1" then
        table.insert(rise_cols, col)
      end
    end

    ticks[1] = "┃"

    if #rise_cols >= 2 then
      local target = math.max(2, math.floor(width / MAX_MARKER_DIVISOR))
      local step = math.ceil(#rise_cols / target)
      for idx = 1, #rise_cols, step do
        local col = rise_cols[idx]
        local edge_time = _find_first_rise_time(value_changes, col_vc_end[col], col_vc_end[col + 1])
        _ruler_place(nums, ticks, col, edge_time or (time_start + (col + 1) * (time_range / width)), width)
      end
    else
      local n = math.max(2, math.floor(width / MAX_MARKER_DIVISOR))
      local step = math.floor(width / n)
      for col = step, width - 1, step do
        _ruler_place(nums, ticks, col, time_start + col * (time_range / width), width)
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
