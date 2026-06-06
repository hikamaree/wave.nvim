local config = require("wave.config")
local signals = require("wave.signals")
local renderer = require("wave.renderer")

local M = {}

local state = {
  buf = nil, win = nil, parser = nil,
  time_start = 0, time_end = 1000, file_time_end = 1000,
  time_unit = "ns",
  cursor_time = nil,
  time_scale = 1, event_count = 0, file_info = nil,
  label_width = 22,
}

function M.setup(parser)
  state.parser = parser
  renderer.setup_highlights()
end

function M.is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
end

function M.open(uri)
  if not state.parser then
    vim.notify("[wave] Parser not initialized", vim.log.levels.ERROR)
    return
  end

  if M.is_open() then
    if state.file_info and state.file_info.uri == uri then
      return
    end
    M.close()
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local fname = uri and vim.fn.fnamemodify(uri, ":t") or "waveform"
  vim.api.nvim_buf_set_name(buf, "Wave: " .. fname)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "wave"
  vim.bo[buf].swapfile = false

  state.buf = buf
  vim.api.nvim_set_current_buf(buf)
  state.win = vim.api.nvim_get_current_win()

  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].foldenable = false
  vim.wo[state.win].cursorline = false

  M._setup_keymaps()

  if uri then
    state.parser:send({ cmd = "open", file = uri }, function(resp)
      if not resp.success then
        vim.schedule(function()
          vim.notify("[wave] Failed to open: " .. (resp.error or "unknown"), vim.log.levels.ERROR)
          M.close()
        end)
        return
      end
      local info = resp.data
      state.file_info = { uri = uri }
      state.file_time_end = info.time_end or 1000
      state.time_end = state.file_time_end
      state.time_scale = info.time_scale or 1
      state.time_unit = info.time_unit or "ns"
      state.event_count = info.event_count or 0
      state.time_start = 0
      vim.schedule(function()
        vim.notify("[wave] Loaded: " .. fname .. " (" .. info.format .. ", " .. info.var_count .. " signals)")
        M._render()
      end)
    end)
  end
  M._render()
end

function M.toggle()
  if M.is_open() then
    M.close()
    return
  end
  M.open()
end

function M._setup_keymaps()
  local buf = state.buf
  local map = function(lhs, rhs, opts)
    vim.api.nvim_buf_set_keymap(buf, "n", lhs, "", {
      callback = rhs, noremap = true, silent = true,
      desc = (opts or {}).desc or "",
    })
  end

  map("q",           function() M.close() end, { desc = "Close viewer" })
  map("i",           function() M.zoom_in() end, { desc = "Zoom in" })
  map("o",           function() M.zoom_out() end, { desc = "Zoom out" })
  map("0",           function() M.zoom_fit() end, { desc = "Zoom fit" })
  map("h",           function() M.scroll_left() end, { desc = "Scroll left" })
  map("l",           function() M.scroll_right() end, { desc = "Scroll right" })
  map("H",           function() M.marker_prev_edge() end, { desc = "Previous edge" })
  map("L",           function() M.marker_next_edge() end, { desc = "Next edge" })
  map("<Space>",     function() M.set_cursor_at_view() end, { desc = "Place cursor" })
  map("a",           function() M.add_signal_prompt() end, { desc = "Add signal" })
  map("d",           function() M.remove_signal_at_cursor() end, { desc = "Remove signal" })
  map("j",           function() M._move_view_line(1) end, { desc = "Move down" })
  map("k",           function() M._move_view_line(-1) end, { desc = "Move up" })
  map("<CR>",        function() M._toggle_signal_expand() end, { desc = "Toggle value table" })
  map("r",           function()
    if state.file_info then M._reload() end
  end, { desc = "Reload" })
  map("g",           function() M._go_to_time_prompt() end, { desc = "Go to time" })
end

function M._move_view_line(direction)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local lines = vim.api.nvim_buf_line_count(state.buf)
  local new_row = math.max(1, math.min(cursor[1] + direction, lines))
  vim.api.nvim_win_set_cursor(state.win, { new_row, 0 })
end

function M._go_to_time_prompt()
  vim.ui.input({ prompt = "Go to time: " }, function(input)
    if input and input ~= "" then
      local t = tonumber(input)
      if t then
        state.cursor_time = t
        M._render()
      end
    end
  end)
end

function M._reload()
  if state.file_info then
    signals.remove_all()
    state.parser:send({ cmd = "close" }, function()
      M.open(state.file_info.uri)
    end)
  end
end

function M.add_signal(netlist_id, signal_id, name, width)
  local ok, sig = signals.add_signal(netlist_id, signal_id, name, width or 1)
  if not ok then
    vim.notify("[wave] " .. sig, vim.log.levels.INFO)
    return
  end
  M._render()
  state.parser:send({ cmd = "get_signal_data", signal_ids = { signal_id } }, function(resp)
    if resp.success and resp.data and #resp.data > 0 then
      local data = resp.data[1]
      signals.set_value_changes(netlist_id, data.value_changes)
      vim.schedule(function()
        if M.is_open() then M._render() end
      end)
    end
  end)
end

function M.add_signal_prompt()
  vim.ui.input({ prompt = "Signal name: " }, function(input)
    if input and input ~= "" then
      if state.file_info then
        state.parser:send({ cmd = "search", search_query = input }, function(resp)
          if resp.success and resp.data and resp.data.search_results and #resp.data.search_results > 0 then
            local results = resp.data.search_results
            local vars = {}
            for _, r in ipairs(results) do
              if r.is_var then table.insert(vars, r) end
            end
            if #vars == 0 then
              vim.notify("[wave] No signal found matching: " .. input, vim.log.levels.INFO)
              return
            end
            local found
            local lower_input = input:lower()
            for _, r in ipairs(vars) do
              if r.instance_path:lower() == lower_input then found = r; break end
            end
            if not found then
              local name_only = input:match("[^.]*$"):lower()
              for _, r in ipairs(vars) do
                if r.instance_path:match("[^.]*$"):lower() == name_only then found = r; break end
              end
            end
            if not found then found = vars[1] end
            M.add_signal(found.netlist_id or 0, found.signal_id or 0, found.instance_path, found.width or 1)
          else
            vim.notify("[wave] Signal not found: " .. input, vim.log.levels.WARN)
          end
        end)
      else
        vim.notify("[wave] No file loaded", vim.log.levels.WARN)
      end
    end
  end)
end

local function _signal_block(sig)
  if sig.expanded and sig.value_changes then
    return 3 + #sig.value_changes
  end
  return 3
end

local function _signal_lines(sig)
  return 2
end

function M._signal_at_line(line)
  local all_signals = signals.get_all()
  local cur = 5
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
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local sig, cur = M._signal_at_line(cursor[1])
  if sig and cursor[1] >= cur and cursor[1] < cur + _signal_lines(sig) then
    signals.remove_signal(sig.netlist_id)
    M._render()
  end
end

function M._toggle_signal_expand()
  if not state.win then return end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local sig, cur = M._signal_at_line(cursor[1])
  if sig and cursor[1] == cur and sig.width and sig.width > 1 then
    sig.expanded = not sig.expanded
    M._render()
  end
end

function M.zoom_in()
  local range = state.time_end - state.time_start
  local center = state.cursor_time or (state.time_start + range / 2)
  local new_range = range / 1.3
  state.time_start = math.max(0, center - new_range / 2)
  state.time_end = math.min(state.file_time_end, state.time_start + new_range)
  M._render()
end

function M.zoom_out()
  local range = state.time_end - state.time_start
  local center = state.cursor_time or (state.time_start + range / 2)
  local new_range = range * 1.3
  state.time_start = math.max(0, center - new_range / 2)
  state.time_end = math.min(state.file_time_end, state.time_start + new_range)
  M._render()
end

function M.zoom_fit()
  state.time_start = 0
  state.time_end = state.file_time_end or 1000
  M._render()
end

function M._clamp_view()
  local max_t = state.file_time_end or math.huge
  local range = state.time_end - state.time_start
  if state.time_start < 0 then state.time_start = 0 end
  if state.time_end > max_t then state.time_end = max_t end
  if state.time_end - state.time_start < range * 0.5 then
    state.time_start = math.max(0, state.time_end - range)
  end
end

function M.scroll_left()
  local range = state.time_end - state.time_start
  local step = range * 0.1
  state.time_start = math.max(0, state.time_start - step)
  state.time_end = state.time_start + range
  M._clamp_view()
  M._render()
end

function M.scroll_right()
  local range = state.time_end - state.time_start
  local step = range * 0.1
  state.time_end = math.min(state.file_time_end or math.huge, state.time_end + step)
  state.time_start = state.time_end - range
  M._clamp_view()
  M._render()
end

function M.set_cursor_at_view()
  local ref_time = state.cursor_time or (state.time_start + (state.time_end - state.time_start) / 2)
  local all_signals = signals.get_all()
  if #all_signals == 0 or not all_signals[1].value_changes then
    state.cursor_time = ref_time
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
  state.cursor_time = nearest or ref_time
  M._render()
end

function M.marker_prev_edge()
  if not state.cursor_time then
    state.cursor_time = state.time_start
    M._render()
    return
  end
  local all_signals = signals.get_all()
  if #all_signals == 0 then return end
  local nearest_time = state.time_start
  for _, sig in ipairs(all_signals) do
    if sig.value_changes then
      for _, vc in ipairs(sig.value_changes) do
        local t = tonumber(vc[1])
        if t and t < state.cursor_time and t > nearest_time then nearest_time = t end
      end
    end
  end
  state.cursor_time = nearest_time
  M._render()
end

function M.marker_next_edge()
  if not state.cursor_time then
    state.cursor_time = state.time_start
    M._render()
    return
  end
  local all_signals = signals.get_all()
  if #all_signals == 0 then return end
  local nearest_time = state.time_end
  for _, sig in ipairs(all_signals) do
    if sig.value_changes then
      for _, vc in ipairs(sig.value_changes) do
        local t = tonumber(vc[1])
        if t and t > state.cursor_time and t < nearest_time then nearest_time = t end
      end
    end
  end
  state.cursor_time = nearest_time
  M._render()
end

function M._render()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local buf = state.buf
  local win_width = vim.api.nvim_win_get_width(state.win)

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_clear_namespace(buf, renderer.get_ns(), 0, -1)

  local lines = {}
  local hlmarks = {}
  local lw = state.label_width
  local ww = win_width - lw - 3
  if ww < 20 then ww = 20 end

  -- Header
  local header = ""
  if state.file_info then
    header = header .. vim.fn.fnamemodify(state.file_info.uri, ":t")
  end
  local time_range = state.time_end - state.time_start
  header = header .. "  " .. math.floor(state.time_start) .. "-" .. math.floor(state.time_end) .. " " .. (state.time_unit or "ns")
  if state.cursor_time then
    header = header .. "  ────  @" .. math.floor(state.cursor_time)
  end
  table.insert(lines, header)

  -- Ruler
  local num_line, tick_line = renderer.render_ruler(state.time_start, state.time_end, ww)
  table.insert(lines, string.rep(" ", lw + 1) .. num_line)
  table.insert(lines, string.rep(" ", lw + 1) .. tick_line)
  table.insert(lines, "")

  -- Pre-calculate cursor column for highlights
  local cursor_col
  if state.cursor_time then
    local time_range = state.time_end - state.time_start
    if time_range > 0 then
      cursor_col = math.min(math.floor((state.cursor_time - state.time_start) / time_range * ww), ww - 1)
    end
  end

  -- Signals
  local all_signals = signals.get_all()
  if #all_signals == 0 then
    table.insert(lines, string.rep(" ", lw) .. "  No signals. Press 'a' to add, or :WaveNetlist")
  else
    for _, sig in ipairs(all_signals) do
      local label = sig.name or "?"
      if sig.width and sig.width > 1 then
        label = label .. "[" .. sig.width .. "]"
      end
      if sig.expanded then label = label .. " ▼" end
      if #label > lw then
        label = label:sub(1, lw)
      else
        label = label .. string.rep(" ", lw - #label)
      end

      local is_multi = sig.width and sig.width > 1

      local top_str, bot_str
      if sig.value_changes then
        if is_multi then
          top_str, bot_str = renderer.render_multi_bit(sig.value_changes, state.time_start, state.time_end, ww)
        else
          top_str, bot_str = renderer.render_single_bit(sig.value_changes, state.time_start, state.time_end, ww)
        end
      else
        top_str = string.rep(" ", ww)
        if is_multi then top_str = top_str .. " (loading...)" end
        bot_str = string.rep(" ", ww)
      end
      local top_ndx = #lines
      local bot_ndx = #lines + 1
      local sig_top = " " .. label .. top_str
      local sig_bot = " " .. string.rep(" ", lw) .. bot_str
      table.insert(lines, sig_top)
      table.insert(lines, sig_bot)
      table.insert(hlmarks, { top_ndx, 1, 1 + lw, "WaveLabel" })
      if #sig_top > lw + 1 then
        table.insert(hlmarks, { top_ndx, lw + 1, #sig_top, "WaveSignal" })
      end
      if #sig_bot > lw + 1 then
        table.insert(hlmarks, { bot_ndx, lw + 1, #sig_bot, "WaveSignal" })
      end
      -- Multi-bit expanded value table
      if is_multi and sig.expanded and sig.value_changes then
        local vlines = renderer.render_value_table(sig, lw)
        for _, vl in ipairs(vlines) do
          table.insert(lines, vl)
        end
      end

      table.insert(lines, string.rep(" ", 1 + lw + ww))
    end
  end

  -- Bottom
  table.insert(lines, string.rep(" ", 1 + lw + ww))
  local info = "h/l:scroll  i/o:zoom  0:fit  H/L:edge  SP:cursor  a:add  d:del  <CR>:expand  q:close"
  table.insert(lines, info)

  -- Pad short lines so cursor extmarks can be placed
  local min_width = 1 + lw + ww
  for i = 1, #lines do
    if #lines[i] < min_width then
      lines[i] = lines[i] .. string.rep(" ", min_width - #lines[i])
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local ns_id = renderer.get_ns()
  for _, m in ipairs(hlmarks) do
    vim.api.nvim_buf_set_extmark(buf, ns_id, m[1], m[2], { hl_group = m[4], end_col = m[3] })
  end
  -- Cursor vertical bar through waveform area (skip header and info)
  if cursor_col then
    local abs_col = cursor_col + lw + 1
    for i = 4, #lines - 2 do
      local byte_col = vim.fn.byteidx(lines[i], abs_col)
      if byte_col >= 0 then
        vim.api.nvim_buf_set_extmark(buf, ns_id, i - 1, byte_col, {
          virt_text = { { "┃", "WaveCursor" } },
          virt_text_pos = "overlay",
          priority = 1000,
        })
      end
    end
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

return M
