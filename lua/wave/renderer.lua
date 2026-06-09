local M = {}

local ns = vim.api.nvim_create_namespace("wave_renderer")
local EPS = 1e-12
local MAX_MARKER_DIVISOR = 8

local function resolve_color(c, key_prefix, fallback)
  local hl_key = key_prefix .. "_hl"
  if c[hl_key] then
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = c[hl_key] })
    if ok and hl and hl.fg then return hl.fg end
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

-- Returns the 0-indexed column in the waveform string where the point t is displayed.
-- An edge at time t rendered by _build_col_val at column K (first with col_time >= t)
-- appears at top_str[K-1] (0-indexed). So time_to_col(t) = K-1.
function M.time_to_col(t, time_start, time_range, width)
  if time_range <= 0 then return 0 end
  local col = math.ceil(((t - time_start) / time_range) * width) - 1
  if col < 0 then return 0 end
  if col >= width then return width - 1 end
  return col
end

local function fmt_val(v)
  local bin = true
  for ch in v:gmatch(".") do
    if ch ~= "0" and ch ~= "1" then bin = false; break end
  end
  if bin and #v > 1 then
    local d = tonumber(v, 2)
    if d then return string.format("0x%X", d) end
  end
  return v
end

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

local function _col_vc_counts(col_vc_end, width)
  local counts = {}
  for col = 0, width - 1 do
    counts[col] = col_vc_end[col + 1] - col_vc_end[col]
  end
  return counts
end

function M.render_single_bit(value_changes, time_start, time_end, width)
  if not value_changes or #value_changes == 0 then
    return string.rep(" ", width), string.rep(" ", width)
  end

  local col_vc_end = {}
  local col_val = _build_col_val(value_changes, time_start, time_end, width, col_vc_end)
  local col_tc = _col_vc_counts(col_vc_end, width)

  -- If a VC falls exactly at time_start, shift col_val[0] to the value before it
  -- so the transition at the left edge is visible (counted in tc[0]).
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
      if v == "0" then
        top[c] = "┌"
        bot[c] = "┘"
      else
        top[c] = "┐"
        bot[c] = "└"
      end

    else -- tc >= 2
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

  return table.concat(top), table.concat(bot)
end

function M.render_multi_bit(value_changes, time_start, time_end, width)
  if not value_changes or #value_changes == 0 then
    return string.rep(" ", width), string.rep(" ", width)
  end
  local col_val = _build_col_val(value_changes, time_start, time_end, width)
  local top = {}
  local bot = {}
  for i = 1, width do top[i] = " "; bot[i] = " " end

  local trans = {}
  for col = 0, width - 1 do
    if col_val[col + 1] ~= col_val[col] then
      table.insert(trans, col)
    end
  end

  if #trans == 0 then
    local v = fmt_val(col_val[0])
    local vlen = math.min(#v, width)
    for j = 1, vlen do top[j] = v:sub(j, j) end
    for i = 1, width do
      if top[i] == " " then top[i] = "─"; bot[i] = "─" end
    end
    return table.concat(top), table.concat(bot)
  end

  if trans[1] > 0 then
    top[1] = "┌"
    bot[1] = "└"
    local init_v = fmt_val(col_val[0])
    local init_len = math.min(#init_v, trans[1] - 1)
    for c = 1, trans[1] - 1 do
      if c <= init_len then
        top[1 + c] = init_v:sub(c, c)
      else
        top[1 + c] = "─"
      end
      bot[1 + c] = "─"
    end
  end

  for ti, col in ipairs(trans) do
    top[col + 1] = "┬"
    bot[col + 1] = "┴"
    local v = fmt_val(col_val[col + 1])
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

local function _find_first_rise_time(value_changes, from_idx, to_idx)
  for i = from_idx + 1, to_idx do
    if value_changes[i - 1][2] == "0" and value_changes[i][2] == "1" then
      return tonumber(value_changes[i][1])
    end
  end
  return nil
end

function M.render_ruler(time_start, time_end, width, value_changes)
  local time_range = time_end - time_start
  local nums = {}
  local ticks = {}
  for i = 1, width do nums[i] = " "; ticks[i] = " " end

  if value_changes and #value_changes > 0 and time_range > 0 then
    local col_vc_end = {}
    local col_val = _build_col_val(value_changes, time_start, time_end, width, col_vc_end)

    -- Collect rise columns (markers at actual edge positions)
    local rise_cols = {}
    for col = 0, width - 1 do
      if col_val[col] == "0" and col_val[col + 1] == "1" then
        table.insert(rise_cols, col)
      end
    end

    -- Place start tick at column 0
    ticks[1] = "┃"

    if #rise_cols >= 2 then
      -- Sample rises to at most ~width/8 markers
      local target = math.max(2, math.floor(width / MAX_MARKER_DIVISOR))
      local step = math.ceil(#rise_cols / target)
      for idx = 1, #rise_cols, step do
        local col = rise_cols[idx]
        local edge_time = _find_first_rise_time(value_changes, col_vc_end[col], col_vc_end[col + 1])
        if not edge_time then
          edge_time = time_start + (col + 1) * (time_range / width)
        end
        ticks[col + 1] = "┃"
        local s = tostring(math.floor(edge_time))
        local num_col = col + 1
        for j = 0, #s - 1 do
          local c = num_col + j
          if c <= width then nums[c] = s:sub(j + 1, j + 1) end
        end
      end
    else
      -- Too few rises — periodic fallback
      local n = math.max(2, math.floor(width / MAX_MARKER_DIVISOR))
      local step = math.floor(width / n)
      for col = step, width - 1, step do
        local edge_time = time_start + col * (time_range / width)
        ticks[col + 1] = "┃"
        local s = tostring(math.floor(edge_time))
        local num_col = col + 1
        for j = 0, #s - 1 do
          local c = num_col + j
          if c <= width then nums[c] = s:sub(j + 1, j + 1) end
        end
      end
    end
  end

  return table.concat(nums), table.concat(ticks)
end

function M.get_ns()
  return ns
end

return M
