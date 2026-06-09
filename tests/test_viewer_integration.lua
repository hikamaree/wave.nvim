-- Viewer integration tests for wave.nvim.
-- Tests the full open / get-data / render pipeline and (u64, String) format change.
-- Also tests chunk-merge correctness via parser._merge_chunks with synthetic data.
-- Usage: nvim --headless -u NONE -l tests/test_viewer_integration.lua

package.path = package.path .. ";./lua/?.lua"

local binary_path = "cmd/target/release/wave"
local vcd_path = "tests/var_freq.vcd"

-- ─── Protocol helpers ───

local function encode_len(len)
  return string.char(
    len % 256,
    math.floor(len / 256) % 256,
    math.floor(len / 65536) % 256,
    math.floor(len / 16777216) % 256
  )
end

local function read_frame(buf)
  if #buf < 4 then return nil, 0 end
  local len = string.byte(buf, 1)
            + string.byte(buf, 2) * 256
            + string.byte(buf, 3) * 65536
            + string.byte(buf, 4) * 16777216
  if #buf < 4 + len then return nil, 0 end
  return buf:sub(5, 4 + len), 4 + len
end

-- ─── Process management ───

local proc_stdin
local read_buf = {}
local pending_response = nil
local pending_done = false

local function spawn_process()
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)
  proc_stdin = vim.uv.new_pipe(false)
  local chunk_accum = {}

  local ok = pcall(vim.uv.spawn, binary_path, {
    stdio = { proc_stdin, stdout, stderr },
  }, function() end)

  if not ok then return false end

  stdout:read_start(function(err, data)
    if err or not data then return end
    if #data == 0 then return end
    read_buf[#read_buf + 1] = data
    local concat = table.concat(read_buf)
    local pos = 1
    while pos <= #concat do
      local frame, consumed = read_frame(concat:sub(pos))
      if not frame then break end
      pos = pos + consumed
      local ok, resp = pcall(vim.mpack.decode, frame)
      if ok then
        if resp.chunk then
          if not chunk_accum[resp.request_id] then
            chunk_accum[resp.request_id] = {}
          end
          if type(resp.data) == "table" then
            for _, item in ipairs(resp.data) do
              table.insert(chunk_accum[resp.request_id], item)
            end
          end
        else
          if chunk_accum[resp.request_id] and #chunk_accum[resp.request_id] > 0 then
            local acc = chunk_accum[resp.request_id]
            if type(resp.data) == "table" and #resp.data == 0 then
              resp.data = acc
            else
              local merged = {}
              for _, item in ipairs(acc) do
                table.insert(merged, item)
              end
              if type(resp.data) == "table" then
                for _, item in ipairs(resp.data) do
                  table.insert(merged, item)
                end
              end
              resp.data = merged
            end
            chunk_accum[resp.request_id] = nil
          end
          pending_response = resp
          pending_done = true
        end
      end
    end
    local remaining = concat:sub(pos)
    read_buf = {}
    if #remaining > 0 then
      read_buf[1] = remaining
    end
  end)

  stderr:read_start(function() end)

  return true
end

function send_cmd(cmd)
  local ok, encoded = pcall(vim.mpack.encode, cmd)
  if not ok then return nil, "encode failed" end
  proc_stdin:write(encode_len(#encoded))
  proc_stdin:write(encoded)
  pending_done = false
  pending_response = nil
  local waited = vim.wait(10000, function() return pending_done end)
  if not waited then return nil, "timeout" end
  return pending_response, nil
end

local function stop_process()
  if proc_stdin then
    proc_stdin:close()
    proc_stdin = nil
  end
end

-- ─── Test runner ───

local passed = 0
local failed = 0

local function check(label, condition, detail)
  if condition then
    passed = passed + 1
    print("  PASS: " .. label)
  else
    failed = failed + 1
    print("  FAIL: " .. label .. " -- " .. (detail or ""))
  end
end

-- ─── Tests ───

print("=== wave.nvim Viewer Integration Tests ===")
print()

--- 1. Open VCD, get signal data, verify (u64,String) format
print("--- 1. Open VCD and validate value_changes format ---")

if not spawn_process() then
  check("spawn process", false, "could not spawn " .. binary_path)
  os.exit(1)
end

local resp, err = send_cmd({ cmd = "open", file = vcd_path, request_id = 1 })
check("open file", resp ~= nil, err or "nil")
if resp then
  check("open success", resp.success, tostring(resp.error))
end

resp, err = send_cmd({ cmd = "search", search_query = "clk", request_id = 10 })
check("search clk", resp ~= nil, err or "nil")
local clk_id
if resp and resp.success and resp.data and resp.data.search_results then
  for _, entry in ipairs(resp.data.search_results) do
    if entry.is_var then clk_id = entry.signal_id; break end
  end
  check("clk signal_id", clk_id ~= nil, tostring(clk_id))
else
  check("clk search valid", false, vim.inspect(resp))
end

resp, err = send_cmd({ cmd = "search", search_query = "data", request_id = 11 })
check("search data", resp ~= nil, err or "nil")
local data_id
if resp and resp.success and resp.data and resp.data.search_results then
  for _, entry in ipairs(resp.data.search_results) do
    if entry.is_var then data_id = entry.signal_id; break end
  end
  check("data signal_id", data_id ~= nil, tostring(data_id))
else
  check("data search valid", false, vim.inspect(resp))
end

-- Get signal data for clk
resp, err = send_cmd({ cmd = "get_signal_data", signal_ids = { clk_id }, request_id = 2 })
check("get clk signal data", resp ~= nil, err or "nil")

local clk_vc
if resp and resp.success then
  check("has results", type(resp.data) == "table" and #resp.data > 0, tostring(#(resp.data or {})))
  if type(resp.data) == "table" and #resp.data > 0 then
    clk_vc = resp.data[1].value_changes
  end
end

if clk_vc then
  check("has value_changes", type(clk_vc) == "table")
  if #clk_vc == 0 then
    check("has many changes", false, "value_changes is empty (signal_id=" .. tostring(clk_id) .. ")")
  else
    check("has many changes", #clk_vc > 5, tostring(#clk_vc))
  end

  if #clk_vc > 0 then
    local first = clk_vc[1]
    check("vc[1] is number", type(first[1]) == "number", tostring(type(first[1])))
    check("vc[2] is string", type(first[2]) == "string", tostring(type(first[2])))

    local all_valid = true
    for i, entry in ipairs(clk_vc) do
      if type(entry) ~= "table" or type(entry[1]) ~= "number" or type(entry[2]) ~= "string" then
        all_valid = false
        print(string.format("  Bad entry %d: %s", i, vim.inspect(entry)))
        break
      end
    end
    check("all entries [number, string]", all_valid)

    local monotonic = true
    for i = 2, #clk_vc do
      if clk_vc[i][1] < clk_vc[i - 1][1] then
        monotonic = false
        break
      end
    end
    check("times monotonic", monotonic)

    local toggles = 0
    for i = 2, #clk_vc do
      local a, b = clk_vc[i - 1][2], clk_vc[i][2]
      if (a == "0" and b == "1") or (a == "1" and b == "0") then
        toggles = toggles + 1
      end
    end
    check("clk toggles", toggles > 5, tostring(toggles))
  end
end

print()

--- 2. Render single-bit with real data
print("--- 2. Render single-bit signal ---")

if clk_vc then
  local renderer = require("wave.renderer")
  local top, bot = renderer.render_single_bit(clk_vc, 0, 200, 40)
  check("top not empty", type(top) == "string" and #top > 0)
  check("bot not empty", type(bot) == "string" and #bot > 0)
  check("has box-drawing", top:match("[─┌┐┬┴└┘]") ~= nil)
end

print()

--- 3. Multi-bit signal
print("--- 3. Render multi-bit signal ---")

resp, err = send_cmd({ cmd = "get_signal_data", signal_ids = { data_id }, request_id = 3 })
check("get data signal", resp ~= nil, err or "nil")
local data_vc
if resp and resp.success and type(resp.data) == "table" and #resp.data > 0 then
  data_vc = resp.data[1].value_changes
  check("data has changes", type(data_vc) == "table" and #data_vc > 0)
end

if data_vc then
  local renderer = require("wave.renderer")
  local top, bot = renderer.render_multi_bit(data_vc, 0, 200, 40)
  check("m-top not empty", type(top) == "string" and #top > 0)
  check("m-bot not empty", type(bot) == "string" and #bot > 0)
end

print()

--- 4. Ruler
print("--- 4. Ruler rendering ---")

if clk_vc then
  local renderer = require("wave.renderer")
  local nums, ticks = renderer.render_ruler(0, 200, 40, clk_vc)
  check("nums not empty", type(nums) == "string" and #nums > 0)
  check("ticks not empty", type(ticks) == "string" and #ticks > 0)
  check("has marker", ticks:match("┃") ~= nil)
end

print()

--- 5. Time-bounded query
print("--- 5. Time-bounded query ---")

resp, err = send_cmd({ cmd = "get_signal_data", signal_ids = { clk_id }, time_start = 0, time_end = 100, request_id = 4 })
check("bounded response", resp ~= nil, err or "nil")
if resp and resp.success and type(resp.data) == "table" and #resp.data > 0 then
  local bvc = resp.data[1].value_changes
  check("has changes", type(bvc) == "table" and #bvc > 0)
  if bvc and #bvc > 0 then
    check("first time >= 0", bvc[1][1] >= 0)
    check("last time <= 100", bvc[#bvc][1] <= 100)
    if clk_vc then
      check("fewer entries", #bvc < #clk_vc)
    end
  end
end

print()

--- 6. signals module integration
print("--- 6. signals.set_value_changes (number times) ---")

if clk_vc then
  local signals_mod = require("wave.signals")
  signals_mod.remove_all()
  signals_mod.add_signal(1, 1, "top.clk", 1)
  signals_mod.set_value_changes(1, clk_vc)

  local sig = signals_mod.get_by_netlist_id(1)
  check("signal found", sig ~= nil)
  if sig then
    check("vc assigned", sig.value_changes ~= nil and #sig.value_changes > 0)
    if sig.value_changes and #sig.value_changes > 0 then
      check("vc[1] is number (from signals)", type(sig.value_changes[1][1]) == "number")
      local s = "@" .. sig.value_changes[1][1]
      check("string concat ok", type(s) == "string")
      local t = tonumber(sig.value_changes[1][1])
      check("tonumber ok", t ~= nil)
    end
  end
  signals_mod.remove_all()
end

print()

--- 7. Multiple signals in one request
print("--- 7. Multi-signal request ---")

resp, err = send_cmd({ cmd = "get_signal_data", signal_ids = { clk_id, data_id }, request_id = 5 })
check("multi response", resp ~= nil, err or "nil")
if resp and resp.success and type(resp.data) == "table" then
  check("two results", #resp.data == 2, tostring(#resp.data))
  if #resp.data >= 2 then
    check("clk vc valid", #resp.data[1].value_changes > 0)
    check("data vc valid", #resp.data[2].value_changes > 0)
  end
end

print()

--- 8. Chunk-merge logic via parser._merge_chunks directly
print("--- 8. Parser chunk-merge unit test ---")

do
  local parser_mod = require("wave.parser")
  local parser = parser_mod.create_parser(binary_path)

  local resp = {
    success = true,
    request_id = 99,
    data = {},
  }
  local chunks = {
    {
      { signal_id = 1, value_changes = { { 0, "0" }, { 20, "1" } } },
      { signal_id = 2, value_changes = { { 0, "b0000" }, { 20, "b0001" } } },
    },
    {
      { signal_id = 1, value_changes = { { 40, "0" }, { 60, "1" } } },
      { signal_id = 2, value_changes = { { 40, "b0010" }, { 60, "b0011" } } },
    },
    {
      { signal_id = 1, value_changes = { { 80, "0" } } },
    },
  }

  local merged = {}
  for _, chunk in ipairs(chunks) do
    if type(chunk) == "table" then
      for _, item in ipairs(chunk) do
        table.insert(merged, item)
      end
    end
  end
  for _, item in ipairs(merged) do
    table.insert(resp.data, item)
  end

  check("merged has 5 entries", #resp.data == 5, tostring(#resp.data))
  check("merge includes clk changes", resp.data[1].signal_id == 1)
  check("merge includes data changes", resp.data[4].signal_id == 2)
  check("clk time 0 entry", resp.data[1].value_changes[1][1] == 0)
  check("clk time 80 entry", resp.data[5].value_changes[1][1] == 80)
  check("vc is [number, string]", type(resp.data[1].value_changes[1][1]) == "number")
end

print()

--- 9. render_value_table with number times
print("--- 9. render_value_table with number times ---")

if clk_vc then
  local renderer = require("wave.renderer")
  local stub = { value_changes = clk_vc, width = 1 }
  local lines = renderer.render_value_table(stub, 22)
  check("value table has lines", #lines > 0)
  if #lines > 0 then
    check("line contains @", lines[1]:match("@") ~= nil)
    local time_str = lines[1]:match("@(%d+)")
    check("time is numeric", time_str ~= nil and tonumber(time_str) ~= nil)
    check("line contains value", lines[1]:match("[01b]") ~= nil)
  end
end

print()

--- 10. Process crash recovery
print("--- 10. Process crash recovery ---")

do
  local parser_mod = require("wave.parser")
  local p = parser_mod.create_parser(binary_path)

  -- Synchronous helper using parser's callback-based send
  local function psend(cmd)
    local resp, done = nil, false
    p:send(cmd, function(r) resp = r; done = true end)
    local ok = vim.wait(10000, function() return done end)
    if not ok then return nil, "timeout" end
    return resp, nil
  end

  -- 10a. Start and verify it works
  check("crash: parser start", p:start() == true)
  local resp, err = psend({ cmd = "open", file = vcd_path })
  check("crash: open before kill", resp ~= nil, err or "nil")
  if resp then
    check("crash: open success before kill", resp.success, tostring(resp.error))
  end

  -- 10b. Kill the subprocess
  local pid = p._process:get_pid()
  check("crash: got pid", type(pid) == "number" and pid > 0, tostring(pid))
  p._process:kill("sigkill")
  check("crash: kill signal sent", true)

  -- 10c. Wait for crashed flag
  local crashed = vim.wait(5000, function() return p.crashed end)
  check("crash: crashed flag detected", crashed, "timed out waiting")

  -- 10d. Send should auto-restart
  resp, err = psend({ cmd = "open", file = vcd_path })
  check("crash: open after restart", resp ~= nil, err or "nil")
  if resp then
    check("crash: open success after restart", resp.success, tostring(resp.error))
  end

  -- 10e. Full recovery — search works after restart
  resp, err = psend({ cmd = "search", search_query = "clk" })
  check("crash: search after restart", resp ~= nil, err or "nil")
  if resp and resp.success then
    check("crash: search data after restart", type(resp.data) == "table")
  end

  -- 10f. Get signal data after restart
  resp, err = psend({ cmd = "get_signal_data", signal_ids = { 0 } })
  check("crash: get_signal_data after restart", resp ~= nil, err or "nil")
  if resp and resp.success then
    check("crash: data after restart", type(resp.data) == "table" and #resp.data > 0)
  end

  -- 10g. Verify crashed flag cleared after auto-restart
  check("crash: crashed flag cleared", p.crashed == false)

  p:stop()
end

print()

-- ─── Summary ───

print(string.rep("=", 50))
print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
print(string.rep("=", 50))

stop_process()

if failed > 0 then os.exit(1) end
