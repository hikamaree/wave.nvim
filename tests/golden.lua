-- Golden-file render tests: drives the real plugin against the sample
-- waveforms and diffs the rendered buffer against recorded output.
--
--   nvim --headless -u NONE -l tests/golden.lua           compare
--   nvim --headless -u NONE -l tests/golden.lua update    re-record

package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local UPDATE = (_G.arg and _G.arg[1]) == "update"
local GOLDEN_DIR = "tests/golden"
local BINARY = "cmd/target/release/wave"

vim.o.columns = 100
vim.o.lines = 40

local ParserClient = require("wave.ipc.client")
local wave = require("wave")
local SignalRef = require("wave.model.signal_ref")

if not wave.setup({}) then
  print("FATAL: wave.setup() failed (is cmd/target/release/wave built?)")
  vim.cmd("cq")
end

local pass, fail = 0, 0

-- ─── A private parser, used only to enumerate signals for each sample ───

local discovery = ParserClient.new(BINARY)
assert(discovery:start(), "failed to start discovery parser")

local function await(fn)
  local done, result = false, nil
  fn(function(resp) result = resp; done = true end)
  vim.wait(20000, function() return done end, 10)
  return result
end

--- Signal list for a file, ordered by instance path so runs are reproducible.
local function signals_in(path)
  local opened = await(function(cb) discovery:open(path, cb) end)
  assert(opened and opened.success, "discovery open failed for " .. path)
  local found = await(function(cb) discovery:search("", cb) end)
  assert(found and found.success, "discovery search failed for " .. path)
  local vars = {}
  for _, r in ipairs(found.data.search_results or {}) do
    if r.is_var then table.insert(vars, r) end
  end
  table.sort(vars, function(a, b) return a.instance_path < b.instance_path end)
  return vars
end

-- ─── Golden comparison ───

local function record(name, lines)
  local file = GOLDEN_DIR .. "/" .. name .. ".txt"
  local text = table.concat(lines, "\n") .. "\n"

  if UPDATE then
    local f = assert(io.open(file, "w"))
    f:write(text)
    f:close()
    print("  recorded " .. name)
    return
  end

  local f = io.open(file, "r")
  if not f then
    fail = fail + 1
    print("  FAIL " .. name .. ": no golden file (run: make golden-update)")
    return
  end
  local want = f:read("*a")
  f:close()

  if want == text then
    pass = pass + 1
    print("  PASS " .. name)
    return
  end

  fail = fail + 1
  print("  FAIL " .. name .. ": output differs")
  local want_lines = vim.split(want, "\n", { plain = true })
  for i = 1, math.max(#want_lines, #lines) do
    if want_lines[i] ~= lines[i] then
      print(string.format("    line %d\n      want |%s|\n      got  |%s|",
        i, want_lines[i] or "<missing>", lines[i] or "<missing>"))
    end
  end
end

--- Rendered viewer buffer, with trailing layout padding stripped.
local function snapshot()
  local session = wave.session()
  local win = session and session:viewer_window()
  if not win then return { "<viewer not open>" } end
  local lines = vim.api.nvim_buf_get_lines(win:buffer(), 0, -1, false)
  for i, l in ipairs(lines) do lines[i] = (l:gsub("%s+$", "")) end
  return lines
end

--- Lets pending parser responses and the re-render they trigger land.
local function settle(ms)
  vim.wait(ms or 1500, function() return false end, 20)
end

-- ─── The cases ───

local SAMPLES = {
  { name = "counter", path = "tests/samples/random_counter.vcd", take = 4 },
  { name = "jtag", path = "tests/samples/jtag.vcd", take = 4 },
  { name = "varfreq", path = "tests/var_freq.vcd", take = 3 },
}

local VIEWS = {
  { "default", function() end },
  { "zoom_in", function(s) s:zoom_in(); s:zoom_in() end },
  { "zoom_out", function(s) s:zoom_out() end },
  { "scroll_right", function(s) s:scroll_right(); s:scroll_right() end },
  { "cursor", function(s) s:cursor_to_view() end },
  { "next_edge", function(s) s:cursor_to_view(); s:next_edge() end },
  { "expanded", function(s)
      for _, trace in ipairs(s.traces:all()) do
        if trace:can_expand() then trace.expanded = true end
      end
      s:render()
    end },
}

for _, sample in ipairs(SAMPLES) do
  print("=== " .. sample.name .. " ===")
  local vars = signals_in(sample.path)

  for _, view in ipairs(VIEWS) do
    local label, apply = view[1], view[2]

    wave.close_all()
    wave.open_file(sample.path)
    settle()

    local session = wave.session()
    assert(session, "no session after opening " .. sample.path)
    -- Reopening reuses the session, so reset before every case.
    session.traces:clear()
    session.cursor_time = nil
    session.viewport = require("wave.model.viewport").new(session.viewport.file_end)

    local added = 0
    for _, v in ipairs(vars) do
      if added >= sample.take then break end
      session:add_trace(SignalRef.from_search(v))
      added = added + 1
    end
    settle()

    apply(session)
    settle()

    record(sample.name .. "_" .. label, snapshot())
  end
end

discovery:stop()

print(string.rep("=", 50))
if UPDATE then
  print("golden files recorded")
else
  print(string.format("Results: %d passed, %d failed, %d total", pass, fail, pass + fail))
end
print(string.rep("=", 50))
if fail > 0 then vim.cmd("cq") end
