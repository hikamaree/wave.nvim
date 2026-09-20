--- Length-prefixed framing for the parser protocol: a 4-byte little-endian
--- payload length followed by the msgpack payload.

local M = {}

M.HEADER_LEN = 4
M.MAX_FRAME_LEN = 512 * 1024 * 1024

---@param len number
---@return string
function M.encode_len(len)
  return string.char(
    len % 256,
    math.floor(len / 256) % 256,
    math.floor(len / 65536) % 256,
    math.floor(len / 16777216) % 256
  )
end

---@param data string
---@param offset number 1-based
---@return number
function M.decode_len(data, offset)
  return string.byte(data, offset)
    + string.byte(data, offset + 1) * 256
    + string.byte(data, offset + 2) * 65536
    + string.byte(data, offset + 3) * 16777216
end

---@param payload string
---@return string
function M.frame(payload)
  return M.encode_len(#payload) .. payload
end

return M
