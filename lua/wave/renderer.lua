local M = {}

local ns = vim.api.nvim_create_namespace("wave_renderer")

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

local function time_to_col(t, time_start, time_range, width)
  if time_range <= 0 then return 0 end
  return math.floor(((t - time_start) / time_range) * width)
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

local function _build_col_val(value_changes, time_start, time_end, width)
  local time_range = time_end - time_start
  local col_val = {}
  local vc_idx = 1
  for col = 0, width do
    local col_time = time_start + (col / width) * time_range
    while vc_idx < #value_changes and tonumber(value_changes[vc_idx + 1][1]) <= col_time do
      vc_idx = vc_idx + 1
    end
    col_val[col] = value_changes[vc_idx][2]
  end
  return col_val
end

function M.is_high_freq(col_val, width, value_changes, time_start, time_range)
  local trans = 0
  for col = 0, width - 2 do
    if (col_val[col] == "1") ~= (col_val[col + 1] == "1") then trans = trans + 1 end
  end
  if trans > 0 and (width / trans) < 3 then return true end
  local total = 0
  local time_end = time_start + time_range
  for _, vc in ipairs(value_changes) do
    local t = tonumber(vc[1])
    if t >= time_start and t <= time_end then
      total = total + 1
    end
  end
  return total > width
end

function M._render_high_freq(width)
  local top = {}
  local bot = {}
  for c = 1, width do top[c] = "█"; bot[c] = "█" end
  return table.concat(top), table.concat(bot)
end

function M._render_low_freq(col_val, width)
  local top = {}
  local bot = {}
  for c = 1, width do top[c] = " "; bot[c] = " " end

  local function bit(v) return v == "1" end

  for col = 0, width - 1 do
    local v, nv = col_val[col], col_val[col + 1]
    local vb, nb = bit(v), bit(nv)
    if vb ~= nb then
      if nb then
        top[col + 1] = "┌"
        if col > 0 then
          local bc = bot[col]
          if bc ~= "┘" and bc ~= "└" then bot[col] = "─" end
        end
        bot[col + 1] = "┘"
      else
        if col > 0 then
          local tc = top[col]
          if tc ~= "┌" and tc ~= "┐" then top[col] = "─" end
        end
        top[col + 1] = "┐"
        bot[col + 1] = "└"
      end
    elseif vb then
      top[col + 1] = "─"
    else
      bot[col + 1] = "─"
    end
  end
  return table.concat(top), table.concat(bot)
end

function M.render_single_bit(value_changes, time_start, time_end, width)
  if not value_changes or #value_changes == 0 then
    return string.rep(" ", width), string.rep(" ", width)
  end

  local col_val = _build_col_val(value_changes, time_start, time_end, width)

  if M.is_high_freq(col_val, width, value_changes, time_start, time_end - time_start) then
    return M._render_high_freq(width)
  end
  return M._render_low_freq(col_val, width)
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

function M.render_ruler(time_start, time_end, width)
  local time_range = time_end - time_start
  local nums = {}
  local ticks = {}
  for i = 1, width do nums[i] = " "; ticks[i] = " " end

  if time_range > 0 then
    local raw_step = time_range / 10
    local mag = 10 ^ math.floor(math.log10(raw_step))
    local norm = raw_step / mag
    local nice_step
    if norm <= 1.5 then
      nice_step = mag
    elseif norm <= 3.5 then
      nice_step = 2 * mag
    elseif norm <= 7.5 then
      nice_step = 5 * mag
    else
      nice_step = 10 * mag
    end
    local t = math.ceil(time_start / nice_step) * nice_step
    while t <= time_end do
      local col = time_to_col(t, time_start, time_range, width)
      if col >= 0 and col < width then
        local s = tostring(math.floor(t))
        for j = 0, #s - 1 do
          if col + 1 + j <= width then nums[col + 1 + j] = s:sub(j + 1, j + 1) end
        end
        ticks[col + 1] = "┃"
      end
      t = t + nice_step
    end
  end

  return table.concat(nums), table.concat(ticks)
end

function M.get_ns()
  return ns
end

return M
