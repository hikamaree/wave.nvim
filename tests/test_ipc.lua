-- IPC integration tests for wave.nvim Rust↔Lua protocol.
-- Usage: nvim --headless -u NONE -l tests/test_ipc.lua

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

  local ok = pcall(vim.uv.spawn, binary_path, {
    stdio = { proc_stdin, stdout, stderr },
  }, function()
    -- process exited
  end)

  if not ok then
    return false
  end

  -- Accumulate chunk data for get_signal_data
  local chunk_accum = {}

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
          -- Merge any accumulated chunks
          if chunk_accum[resp.request_id] and #chunk_accum[resp.request_id] > 0 then
            if type(resp.data) == "table" and #resp.data == 0 then
              resp.data = chunk_accum[resp.request_id]
            else
              local merged = {}
              for _, item in ipairs(chunk_accum[resp.request_id]) do
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

local function send_cmd(cmd)
  local ok, encoded = pcall(vim.mpack.encode, cmd)
  if not ok then return nil, "encode failed" end
  proc_stdin:write(encode_len(#encoded))
  proc_stdin:write(encoded)
  pending_done = false
  pending_response = nil
  local waited = vim.wait(5000, function() return pending_done end)
  if not waited then
    return nil, "timeout waiting for response"
  end
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

local function check_eq(label, a, b)
  check(label, a == b, string.format("expected %s, got %s", tostring(b), tostring(a)))
end

-- ─── Tests ───

print("=== wave.nvim IPC Integration Tests ===")
print()

print("Spawning process...")
if not spawn_process() then
  print("FAIL: Could not spawn " .. binary_path)
  os.exit(1)
end
print()

-- Test 1: Open valid VCD file
do
  print("--- 1. Open valid VCD file ---")
  local resp, err = send_cmd({ cmd = "open", file = vcd_path, request_id = 1 })
  check("got response", resp ~= nil, err or "nil")
  if resp then
    check("success", resp.success, tostring(resp.error))
    check("has request_id", resp.request_id == 1)
    check("has data.format", type(resp.data) == "table" and type(resp.data.format) == "string")
    check("has data.time_end", tonumber(resp.data.time_end) ~= nil)
    check("has data.var_count", type(resp.data.var_count) == "number" and resp.data.var_count > 0)
    check("has data.scope_count", type(resp.data.scope_count) == "number" and resp.data.scope_count > 0)
    check("has data.time_unit", type(resp.data.time_unit) == "string")
  end
  print()
end

-- Test 2: Open nonexistent file
do
  print("--- 2. Open nonexistent file ---")
  local resp, err = send_cmd({ cmd = "open", file = "/nonexistent/foo.vcd", request_id = 2 })
  check("got response", resp ~= nil, err or "nil")
  if resp then
    check("success is false", resp.success == false)
    check("has error message", type(resp.error) == "string" and #resp.error > 0)
  end
  print()
end

-- Test 3: Get children (top-level scopes)
do
  print("--- 3. Get children (scope 1) ---")
  local resp, err = send_cmd({ cmd = "get_children", id = 1, start_index = 0, request_id = 3 })
  check("got response", resp ~= nil, err or "nil")
  if resp then
    check("success", resp.success, tostring(resp.error))
    check("has scopes", type(resp.data.scopes) == "table")
    check("has vars", type(resp.data.vars) == "table")
    check("has 2 vars (clk, data)", #resp.data.vars == 2)
  end
  print()
end

-- Test 4: Search for signal "clk"
do
  print("--- 4. Search for 'clk' ---")
  local resp, err = send_cmd({ cmd = "search", search_query = "clk", request_id = 4 })
  check("got response", resp ~= nil, err or "nil")
  if resp then
    check("success", resp.success, tostring(resp.error))
    check("has results", type(resp.data.search_results) == "table")
    check("total_results > 0", resp.data.total_results > 0)
    if #resp.data.search_results > 0 then
      local found = false
      for _, r in ipairs(resp.data.search_results) do
        if r.instance_path and r.instance_path:match("clk") then found = true end
      end
      check("found 'clk' in results", found)
    end
  end
  print()
end

-- Test 5: Get signal data for clk (signal_id = 1)
do
  print("--- 5. Get signal data for clk ---")
  local resp, err = send_cmd({ cmd = "get_signal_data", signal_ids = { 1 }, request_id = 5 })
  check("got final response", resp ~= nil, err or "nil")
  if resp then
    check("success", resp.success, tostring(resp.error))
    -- Chunk mode: first responses are chunks (chunk = true), last is final (chunk = nil)
    -- In our simplified test, we just check we get some response
    -- The actual parser.lua handles chunk accumulation; here we check the final
    -- response data shape.
  end
  print()
end

-- Test 6: Get signal data with time bounds
do
  print("--- 6. Get signal data (time 0-100) ---")
  local resp, err = send_cmd({ cmd = "get_signal_data", signal_ids = { 1 }, time_start = 0, time_end = 100, request_id = 6 })
  check("got final response", resp ~= nil, err or "nil")
  if resp then
    check("success", resp.success, tostring(resp.error))
  end
  print()
end

-- Test 7: Unknown command
do
  print("--- 7. Unknown command ---")
  local resp, err = send_cmd({ cmd = "nonexistent_cmd", request_id = 7 })
  check("got response", resp ~= nil, err or "nil")
  if resp then
    check("success is false", resp.success == false)
    check("has error message", type(resp.error) == "string")
  end
  print()
end

-- Test 8: Close and reopen
do
  print("--- 8. Close command ---")
  local resp, err = send_cmd({ cmd = "close", request_id = 8 })
  check("got response", resp ~= nil, err or "nil")
  if resp then
    check("success", resp.success, tostring(resp.error))
  end

  print("  Reopening...")
  resp, err = send_cmd({ cmd = "open", file = vcd_path, request_id = 9 })
  check("got response", resp ~= nil, err or "nil")
  if resp then
    check("success after reopen", resp.success, tostring(resp.error))
  end
  print()
end

-- Test 9: Get signal data for multi-bit signal "data" (signal_id = 2)
do
  print("--- 9. Get signal data for data (multi-bit) ---")
  local resp, err = send_cmd({ cmd = "get_signal_data", signal_ids = { 2 }, request_id = 10 })
  check("got final response", resp ~= nil, err or "nil")
  if resp then
    check("success", resp.success, tostring(resp.error))
  end
  print()
end

-- ─── Summary ───

print(string.rep("=", 50))
print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
print(string.rep("=", 50))

stop_process()

if failed > 0 then os.exit(1) end
