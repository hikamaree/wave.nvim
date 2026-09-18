local signals = require("wave.signals")
local renderer = require("wave.renderer")
local config = require("wave.config")
local search = require("wave.search")

local M = {}

local ZOOM_OUT_MARGIN = 1.05
local LABEL_GAP = 3
local MIN_WAVEFORM_WIDTH = 20
local FIRST_SIGNAL_LINE = 5
local SHRINK_THRESHOLD = 0.5
local BOTTOM_BAR_LINES = 2
local CURSOR_SKIP_LINES = 2  -- header (1) + ruler numbers (1)
local MAX_EXPANDED_ROWS = 1000
local MAX_LABEL_RATIO = 0.3
local LABEL_LEAD_SPACE = 1
local MAX_SIGNAL_POINTS = 20000
local FETCH_MARGIN = 1
local REFETCH_ZOOM_FACTOR = 2

local HELP_GROUPS = {
  { "close" },
  { "scroll_left", "scroll_right" },
  { "zoom_in", "zoom_out" },
  { "prev_edge", "next_edge", "cursor" },
  { "netlist", "search", "del", "expand" },
}

---@class ViewerState

---@type table<number, ViewerState>
local _states = {}
---@type number|nil
local _viewer_buf = nil

---@return ViewerState|nil
local function _get_state()
  if not _viewer_buf then return nil end
  return _states[_viewer_buf]
end

---@param buf number
---@param win number|nil
---@return ViewerState
local function _make_state(buf, win)
  local st = {
    buf = buf,
    win = win,
    time_start = 0, time_end = 1000, file_time_end = 1000,
    time_unit = "ns",
    cursor_time = nil,
    file_info = nil,
    label_width = 22,
    zoom_n = -2,
  }
  _states[buf] = st
  _viewer_buf = buf
  return st
end

---@type Parser|nil
local _parser = nil

---@type fun()|nil
local _open_netlist = nil

--- Lets init.lua wire up netlist.toggle() without viewer.lua requiring
--- wave.netlist, which already requires wave.viewer.
---@param fn fun()
function M.set_netlist_opener(fn)
  _open_netlist = fn
end

---@return number
local function _waveform_width()
  local st = _get_state()
  if not st or not st.win then return MIN_WAVEFORM_WIDTH end
  return vim.api.nvim_win_get_width(st.win) - st.label_width - LABEL_GAP
end

---@param zoom_n number
---@return number
local function _zoom_value(zoom_n)
  if zoom_n >= 2 then return zoom_n
  elseif zoom_n == 1 then return 1
  end
  return -1.0 / zoom_n
end

---@param parser table
function M.setup(parser)
  _parser = parser
  renderer.setup_highlights()
end

---@return boolean
function M.is_open()
  if not _viewer_buf then return false end
  local st = _states[_viewer_buf]
  return st and st.win and vim.api.nvim_win_is_valid(st.win) or false
end

function M.close()
  if not _viewer_buf then return end
  -- Only ever delete the buffer, never the window: M.open() reuses whatever
  -- window is current rather than owning a dedicated one, and this can be the
  -- last window left.
  local buf = _viewer_buf
  _states[buf] = nil
  _viewer_buf = nil
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---@param buf number
function M.cleanup_buf(buf)
  if _viewer_buf ~= buf then return end
  _states[buf] = nil
  _viewer_buf = nil
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---@param uri string|nil
function M.open(uri)
  if not _parser then
    vim.notify("[wave] Parser not initialized", vim.log.levels.ERROR)
    return
  end

  if M.is_open() then
    local st = _get_state()
    if st and st.file_info and st.file_info.uri == uri then
      return
    end
    M.close()
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local st = _make_state(buf, nil)
  st.file_name = uri and vim.fn.fnamemodify(uri, ":t") or "waveform"
  local fname = st.file_name
  vim.api.nvim_buf_set_name(buf, "Wave: " .. fname)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "wave"
  vim.bo[buf].swapfile = false

  vim.api.nvim_set_current_buf(buf)
  st.win = vim.api.nvim_get_current_win()

  vim.wo[st.win].number = false
  vim.wo[st.win].relativenumber = false
  vim.wo[st.win].signcolumn = "no"
  vim.wo[st.win].foldenable = false
  vim.wo[st.win].cursorline = false

  M._setup_keymaps()

  if uri then
    _parser:send({ cmd = "open", file = uri }, function(resp)
      if not resp.success then
        vim.schedule(function()
          vim.notify("[wave] Failed to open: " .. (resp.error or "unknown"), vim.log.levels.ERROR)
          M.close()
        end)
        return
      end
      local info = resp.data
      local st2 = _get_state()
      if not st2 then return end
      st2.file_info = { uri = uri }
      st2.file_time_end = info.time_end or 1000
      st2.time_end = st2.file_time_end * ZOOM_OUT_MARGIN
      st2.time_unit = info.time_unit or "ns"
      st2.time_start = 0
      vim.schedule(function()
        vim.notify("[wave] Loaded: " .. fname .. " (" .. info.format .. ", " .. info.var_count .. " signals)")
        M._render()
      end)
    end)
  else
    M._render()
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
    return
  end
  M.open()
end

local KEYMAP_ACTIONS = {
  close = function() M.close() end,
  scroll_left = function() M.scroll_left() end,
  scroll_right = function() M.scroll_right() end,
  zoom_in = function() M.zoom_in() end,
  zoom_out = function() M.zoom_out() end,
  prev_edge = function() M.marker_prev_edge() end,
  next_edge = function() M.marker_next_edge() end,
  cursor = function() M.set_cursor_at_view() end,
  netlist = function() if _open_netlist then _open_netlist() end end,
  search = function() M.add_signal_prompt() end,
  del = function() M.remove_signal_at_cursor() end,
  expand = function() M._toggle_signal_expand() end,
}

function M._setup_keymaps()
  local st = _get_state()
  if not st or not st.win then return end
  local buf = vim.api.nvim_win_get_buf(st.win)
  local km = config.options.keymaps

  for action, lhs in pairs(km) do
    local cb = KEYMAP_ACTIONS[action]
    if cb then
      vim.api.nvim_buf_set_keymap(buf, "n", lhs, "", {
        callback = cb, noremap = true, silent = true, desc = action,
      })
    end
  end
end

---@param direction number
function M._move_view_line(direction)
  local st = _get_state()
  if not st or not st.win or not vim.api.nvim_win_is_valid(st.win) then return end
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local buf = vim.api.nvim_win_get_buf(st.win)
  local lines = vim.api.nvim_buf_line_count(buf)
  local new_row = math.max(1, math.min(cursor[1] + direction, lines))
  vim.api.nvim_win_set_cursor(st.win, { new_row, 0 })
end

function M._go_to_time_prompt()
  local st = _get_state()
  if not st then return end
  vim.ui.input({ prompt = "Go to time: " }, function(input)
    if input and input ~= "" then
      local t = tonumber(input)
      if t then
        st.cursor_time = t
        M._render()
      end
    end
  end)
end

function M._reload()
  local st = _get_state()
  if not st or not st.file_info then return end
  local uri = st.file_info.uri
  signals.remove_all()
  -- M.open() no-ops when already open on the same uri, so close first.
  M.close()
  if not _parser then return end
  _parser:send({ cmd = "close" }, function()
    M.open(uri)
  end)
end

---@param netlist_id number
---@param signal_id number
---@param name string
---@param width number|nil
function M.add_signal(netlist_id, signal_id, name, width)
  local ok, sig = signals.add_signal(netlist_id, signal_id, name, width or 1)
  if not ok then
    vim.notify("[wave] " .. sig, vim.log.levels.INFO)
    return
  end
  M._render()
end

---@param sig DisplayedSignal
---@param st ViewerState
---@return boolean
local function _needs_fetch(sig, st)
  if sig.loading then return false end
  local w = sig.window
  if not w then return true end
  local range = st.time_end - st.time_start
  return st.time_start < w[1] or st.time_end > w[2]
    or w[2] - w[1] > range * (1 + 2 * FETCH_MARGIN) * REFETCH_ZOOM_FACTOR
end

function M._fetch_visible_data()
  local st = _get_state()
  if not st or not st.file_info or not _parser then return end
  local range = st.time_end - st.time_start
  local window = {
    math.max(0, math.floor(st.time_start - range * FETCH_MARGIN)),
    math.ceil(st.time_end + range * FETCH_MARGIN),
  }
  for _, sig in ipairs(signals.get_all()) do
    if _needs_fetch(sig, st) then
      sig.loading = true
      _parser:send({
        cmd = "get_signal_data",
        signal_ids = { sig.signal_id },
        time_start = window[1],
        time_end = window[2],
        max_points = MAX_SIGNAL_POINTS,
      }, function(resp)
        sig.loading = false
        sig.window = window
        local data = resp.success and resp.data and resp.data[1]
        if data then
          sig.period = data.period
          signals.set_value_changes(sig.signal_id, data.value_changes)
        end
        if M.is_open() then M._render() end
      end)
    end
  end
end

function M.add_signal_prompt()
  local st = _get_state()
  if not st or not st.file_info then
    vim.notify("[wave] No file loaded", vim.log.levels.WARN)
    return
  end
  search.prompt(function(r)
    M.add_signal(r.netlist_id or 0, r.signal_id or 0, r.instance_path, r.width or 1)
  end)
end

---@return number|nil
function M._detect_period()
  local period
  for _, sig in ipairs(signals.get_all()) do
    if sig.period and (not period or sig.period < period) then
      period = sig.period
    end
  end
  return period
end

--- Inverse of _update_viewport_from_zoom.
---@param st ViewerState
---@param period number
---@return number
local function _zoom_n_for_view(st, period)
  local ww = _waveform_width()
  local range = st.time_end - st.time_start
  if range <= 0 or ww < MIN_WAVEFORM_WIDTH then return st.zoom_n end

  local zoom = ww * period / range
  if zoom >= 1.5 then
    local n = math.floor(zoom + 0.5)
    return n - n % 2
  elseif zoom >= 0.75 then
    return 1
  end
  return -math.max(2, math.floor(range / (ww * period) + 0.5))
end

function M._sync_zoom_to_view()
  local st = _get_state()
  local period = M._detect_period()
  if not st or not period then return end
  st.zoom_n = _zoom_n_for_view(st, period)
end

function M._update_viewport_from_zoom()
  local st = _get_state()
  if not st then return end
  local ww = _waveform_width()
  if ww < MIN_WAVEFORM_WIDTH then return end

  local period = M._detect_period()
  if not period or period <= 0 then return end

  local zoom = _zoom_value(st.zoom_n)
  local col_width = period / zoom
  local range = ww * col_width

  local max_range = (st.file_time_end or math.huge) * ZOOM_OUT_MARGIN
  local min_range = math.min(period * 2, max_range)
  range = math.max(min_range, math.min(range, max_range))

  local center = st.cursor_time or (st.time_start + st.time_end) / 2
  st.time_start = math.max(0, center - range / 2)
  st.time_end = st.time_start + range
  if st.time_end > max_range and st.time_start > 0 then
    st.time_start = math.max(0, max_range - range)
    st.time_end = max_range
  end
end

---@param sig DisplayedSignal
---@return number
--- Returns the number of buffer lines occupied by a signal:
--   non-expanded: 3 (top, bot, gap), expanded: 3 + value rows.
local function _signal_block(sig)
  if sig.expanded and sig.value_changes then
    return 3 + math.min(#sig.value_changes, MAX_EXPANDED_ROWS)
  end
  return 3
end

---@param line number
---@return DisplayedSignal|nil, number, number|nil
local function _signal_at_line(line)
  local all_signals = signals.get_all()
  local cur = FIRST_SIGNAL_LINE
  for _, sig in ipairs(all_signals) do
    local block = _signal_block(sig)
    if line >= cur and line < cur + block then
      return sig, cur, block
    end
    cur = cur + block
  end
  return nil, cur
end

function M.remove_signal_at_cursor()
  local st = _get_state()
  if not st or not st.win or not vim.api.nvim_win_is_valid(st.win) then return end
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local sig, cur = _signal_at_line(cursor[1])
  if sig and cursor[1] >= cur and cursor[1] < cur + 2 then
    signals.remove_signal(sig.signal_id)
    M._render()
  end
end

function M._toggle_signal_expand()
  local st = _get_state()
  if not st or not st.win then return end
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local sig, cur = _signal_at_line(cursor[1])
  if sig and cursor[1] == cur and sig.width and sig.width > 1 then
    sig.expanded = not sig.expanded
    M._render()
  end
end

local ZOOM_OUT_LINEAR_LIMIT = -8

---@return number
local function _next_zoom_in()
  local st = _get_state()
  if not st then return 1 end
  if st.zoom_n < ZOOM_OUT_LINEAR_LIMIT then return math.floor(st.zoom_n / 2)
  elseif st.zoom_n == -2 then return 1
  elseif st.zoom_n == 1 then return 2
  else return st.zoom_n + 2
  end
end

---@return number
local function _next_zoom_out()
  local st = _get_state()
  if not st then return -2 end
  if st.zoom_n <= ZOOM_OUT_LINEAR_LIMIT then return st.zoom_n * 2
  elseif st.zoom_n == 2 then return 1
  elseif st.zoom_n == 1 then return -2
  else return st.zoom_n - 2
  end
end

function M.zoom_in()
  local st = _get_state()
  if not st then return end
  local next_n = _next_zoom_in()
  local period = M._detect_period()
  if not period then return end
  local ww = _waveform_width()
  if ww >= MIN_WAVEFORM_WIDTH then
    local new_range = ww * period / _zoom_value(next_n)
    local cur_range = st.time_end - st.time_start
    if new_range < period * 2 and cur_range <= period * 2 then return end
  end
  st.zoom_n = next_n
  M._update_viewport_from_zoom()
  M._render()
end

function M.zoom_out()
  local st = _get_state()
  if not st then return end
  local zoom_out_limit = (st.file_time_end or math.huge) * ZOOM_OUT_MARGIN
  if st.time_end - st.time_start >= zoom_out_limit then return end
  st.zoom_n = _next_zoom_out()
  M._update_viewport_from_zoom()
  M._render()
end


function M._clamp_view()
  local st = _get_state()
  if not st then return end
  local max_t = (st.file_time_end or math.huge) * ZOOM_OUT_MARGIN
  local prev_range = st.time_end - st.time_start
  if st.time_start < 0 then st.time_start = 0 end
  if st.time_end > max_t then st.time_end = max_t end
  if st.time_end - st.time_start < prev_range * SHRINK_THRESHOLD then
    st.time_start = math.max(0, st.time_end - prev_range)
  end
end

function M.scroll_left()
  local st = _get_state()
  if not st then return end
  local range = st.time_end - st.time_start
  local step = range * 0.1
  st.time_start = math.max(0, st.time_start - step)
  st.time_end = st.time_start + range
  M._clamp_view()
  M._render()
end

function M.scroll_right()
  local st = _get_state()
  if not st then return end
  local range = st.time_end - st.time_start
  local step = range * 0.1
  st.time_end = math.min(st.file_time_end or math.huge, st.time_end + step)
  st.time_start = st.time_end - range
  M._clamp_view()
  M._render()
end

function M.set_cursor_at_view()
  local st = _get_state()
  if not st then return end
  local ref_time = st.cursor_time or (st.time_start + (st.time_end - st.time_start) / 2)
  local all_signals = signals.get_all()
  if #all_signals == 0 or not all_signals[1].value_changes then
    st.cursor_time = ref_time
    M._render()
    return
  end
  local nearest
  local min_dist = math.huge
  for _, sig in ipairs(all_signals) do
    if sig.value_changes then
      for _, vc in ipairs(sig.value_changes) do
        local t = tonumber(vc[1])
        if t then
          local dist = math.abs(t - ref_time)
          if dist < min_dist then
            min_dist = dist
            nearest = t
          end
        end
      end
    end
  end
  st.cursor_time = nearest or ref_time
  M._render()
end

---@param edges number[]
---@param t number
---@return number|nil
local function _edge_prev(edges, t)
  local lo, hi = 1, #edges
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if edges[mid] < t then lo = mid + 1 else hi = mid - 1 end
  end
  return edges[hi]
end

---@param edges number[]
---@param t number
---@return number|nil
local function _edge_next(edges, t)
  local lo, hi = 1, #edges
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if edges[mid] > t then hi = mid - 1 else lo = mid + 1 end
  end
  return edges[lo]
end

---@param cursor_time number
---@param less_than boolean
---@param default number
---@return number
local function _find_edge(cursor_time, less_than, default)
  local edges = signals.get_edges()
  if #edges > 0 then
    if less_than then
      return _edge_prev(edges, cursor_time) or default
    else
      return _edge_next(edges, cursor_time) or default
    end
  end
  -- Fallback: scan all signals (edge cap exceeded)
  local all_signals = signals.get_all()
  local nearest = default
  for _, sig in ipairs(all_signals) do
    if sig.value_changes then
      for _, vc in ipairs(sig.value_changes) do
        if type(vc) == "table" and vc[1] ~= nil then
          local t = tonumber(vc[1])
          if t then
            if less_than then
              if t < cursor_time and t > nearest then nearest = t end
            else
              if t > cursor_time and (nearest == default or t < nearest) then nearest = t end
            end
          end
        end
      end
    end
  end
  return nearest
end

function M.marker_prev_edge()
  local st = _get_state()
  if not st then return end
  if not st.cursor_time then
    st.cursor_time = st.time_start
    M._render()
    return
  end
  st.cursor_time = _find_edge(st.cursor_time, true, st.time_start)
  M._render()
end

function M.marker_next_edge()
  local st = _get_state()
  if not st then return end
  if not st.cursor_time then
    st.cursor_time = st.time_start
    M._render()
    return
  end
  st.cursor_time = _find_edge(st.cursor_time, false, st.time_end)
  M._render()
end

---@param st table
---@return string
local function _build_header(st)
  local parts = {}
  if st.file_name then table.insert(parts, st.file_name) end
  table.insert(parts, math.floor(st.time_start) .. "-" .. math.floor(st.time_end) .. " " .. (st.time_unit or "ns"))
  if st.cursor_time then
    table.insert(parts, "────  @" .. math.floor(st.cursor_time))
  end
  local zv = _zoom_value(st.zoom_n)
  table.insert(parts, string.format("Z:%sx", zv >= 1 and math.floor(zv) or string.format("1/%d", -st.zoom_n)))
  return table.concat(parts, "  ")
end

---@param st table
---@param ww number
---@return number|nil
local function _cursor_col(st, ww)
  if not st.cursor_time then return nil end
  local time_range = st.time_end - st.time_start
  if time_range <= 0 then return nil end
  return renderer.time_to_col(st.cursor_time, st.time_start, time_range, ww)
end

---@param lines string[]
---@param st table
---@param ww number
---@param all_signals table[]
local function _add_ruler_rows(lines, st, ww, all_signals)
  local ruler_vc = {}
  for _, sig in ipairs(all_signals) do
    if sig.width == 1 and sig.value_changes and #sig.value_changes > 0 then
      ruler_vc = sig.value_changes
      break
    end
  end
  local num_line, tick_line = renderer.render_ruler(st.time_start, st.time_end, ww, ruler_vc)
  local pad = string.rep(" ", st.label_width + 1)
  table.insert(lines, pad .. num_line)
  table.insert(lines, pad .. tick_line)
  table.insert(lines, "")
end

---@param sig table
---@param lw number
---@return string
local function _signal_label(sig, lw)
  local label = sig.name or "?"
  if sig.width and sig.width > 1 then
    label = label .. "[" .. sig.width .. "]"
  end
  if sig.expanded then label = label .. " ▼" end
  -- Display width, not byte length: "▼"/"…" are multi-byte but one column.
  local width = vim.fn.strdisplaywidth(label)
  if width > lw then
    return vim.fn.strcharpart(label, 0, lw - 1) .. "…"
  end
  return label .. string.rep(" ", lw - width)
end

---@param sig table
---@param st table
---@param ww number
---@param is_multi boolean
---@return string, string
local function _render_waveform(sig, st, ww, is_multi)
  if not sig.value_changes then
    return string.rep(" ", ww) .. " (loading...)", string.rep(" ", ww)
  end

  local ok, top_str, bot_str
  if is_multi then
    ok, top_str, bot_str = pcall(renderer.render_multi_bit, sig.value_changes, st.time_start, st.time_end, ww)
  else
    ok, top_str, bot_str = pcall(renderer.render_single_bit, sig.value_changes, st.time_start, st.time_end, ww)
  end

  if not ok then
    vim.notify("[wave] Render error for " .. (sig.name or "?"), vim.log.levels.WARN)
    return string.rep("?", ww), string.rep("?", ww)
  end

  return top_str, bot_str
end

---@param hlmarks table[]
---@param top_ndx number
---@param bot_ndx number
---@param lw number
---@param top_str string
---@param bot_str string
local function _add_signal_hlmarks(hlmarks, top_ndx, bot_ndx, lw, top_str, bot_str)
  table.insert(hlmarks, { top_ndx, LABEL_LEAD_SPACE, LABEL_LEAD_SPACE + lw, "WaveLabel" })
  if #top_str > 0 then
    table.insert(hlmarks, { top_ndx, lw + 1, lw + 1 + #top_str, "WaveSignal" })
  end
  if #bot_str > 0 then
    table.insert(hlmarks, { bot_ndx, lw + 1, lw + 1 + #bot_str, "WaveSignal" })
  end
end

---@param lines string[]
---@param hlmarks table[]
---@param all_signals table[]
---@param st table
---@param ww number
---@param lw number
local function _add_signal_rows(lines, hlmarks, all_signals, st, ww, lw)
  if #all_signals == 0 then
    table.insert(lines, string.rep(" ", lw) .. "  No signals added yet")
    return
  end

  for _, sig in ipairs(all_signals) do
    local label = _signal_label(sig, lw)
    local is_multi = sig.width and sig.width > 1
    local top_str, bot_str = _render_waveform(sig, st, ww, is_multi)
    local top_ndx = #lines
    local bot_ndx = #lines + 1

    table.insert(lines, string.rep(" ", LABEL_LEAD_SPACE) .. label .. top_str)
    table.insert(lines, string.rep(" ", LABEL_LEAD_SPACE) .. string.rep(" ", lw) .. bot_str)
    _add_signal_hlmarks(hlmarks, top_ndx, bot_ndx, lw, top_str, bot_str)

    if is_multi and sig.expanded then
      local vlines = renderer.render_value_table(sig, lw, MAX_EXPANDED_ROWS)
      for _, vl in ipairs(vlines) do
        table.insert(lines, vl)
      end
    end

    table.insert(lines, string.rep(" ", LABEL_LEAD_SPACE + lw + ww))
  end
end

---@param lines string[]
---@param lw number
---@param ww number
local function _add_bottom_bar(lines, lw, ww)
  table.insert(lines, string.rep(" ", LABEL_LEAD_SPACE + lw + ww))
  local km = config.options.keymaps
  local group_parts = {}
  for _, group in ipairs(HELP_GROUPS) do
    local entries = {}
    for _, action in ipairs(group) do
      local lhs = km[action]
      if lhs then
        local disp = lhs:gsub("^<(.+)>$", function(s) return s:upper() end)
        table.insert(entries, disp .. ":" .. action)
      end
    end
    table.insert(group_parts, table.concat(entries, "  "))
  end
  table.insert(lines, table.concat(group_parts, "  │  "))
end

---@param buf number
---@param lines string[]
local function _write_buffer(buf, lines)
  local min_width = 0
  for _, line in ipairs(lines) do
    if #line > min_width then min_width = #line end
  end
  if min_width == 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return
  end
  for i = 1, #lines do
    local pad = min_width - #lines[i]
    if pad > 0 then
      lines[i] = lines[i] .. string.rep(" ", pad)
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

---@param buf number
---@param hlmarks table[]
---@param lines string[]
---@param cursor_col number|nil
---@param lw number
local function _apply_extmarks(buf, hlmarks, lines, cursor_col, lw)
  local ns_id = renderer.get_ns()
  for _, m in ipairs(hlmarks) do
    vim.api.nvim_buf_set_extmark(buf, ns_id, m[1], m[2], { hl_group = m[4], end_col = m[3] })
  end
  if not cursor_col then return end
  local abs_col = cursor_col + lw + 1
  for i = 1 + CURSOR_SKIP_LINES, #lines - BOTTOM_BAR_LINES do
    local prefix = vim.fn.strcharpart(lines[i], 0, abs_col)
    vim.api.nvim_buf_set_extmark(buf, ns_id, i - 1, #prefix, {
      virt_text = { { "┃", "WaveCursor" } },
      virt_text_pos = "overlay",
      priority = 1000,
    })
  end
end

function M._render()
  local st = _get_state()
  if not st or not st.win or not vim.api.nvim_win_is_valid(st.win) then return end
  local buf = vim.api.nvim_win_get_buf(st.win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  M._fetch_visible_data()

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, renderer.get_ns(), 0, -1)

  local ok = pcall(function()
    local ww_total = vim.api.nvim_win_get_width(st.win)
    st.label_width = math.max(15, math.min(40, math.floor(ww_total * MAX_LABEL_RATIO)))
    local lw = st.label_width
    local ww = math.max(ww_total - lw - LABEL_GAP, MIN_WAVEFORM_WIDTH)
    local all_signals = signals.get_all()

    local lines = {}
    local hlmarks = {}
    local cursor_col = _cursor_col(st, ww)
    M._sync_zoom_to_view()

    table.insert(lines, _build_header(st))
    _add_ruler_rows(lines, st, ww, all_signals)
    _add_signal_rows(lines, hlmarks, all_signals, st, ww, lw)
    _add_bottom_bar(lines, lw, ww)
    _write_buffer(buf, lines)
    _apply_extmarks(buf, hlmarks, lines, cursor_col, lw)
  end)
  vim.bo[buf].modifiable = false
  if not ok then
    vim.notify("[wave] Render error", vim.log.levels.ERROR)
  end
end

return M
