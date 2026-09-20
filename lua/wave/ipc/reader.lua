--- Accumulates bytes from the parser's stdout and emits whole frames.

local codec = require("wave.ipc.codec")

local FrameReader = {}
FrameReader.__index = FrameReader

---@param on_frame fun(frame: string)
---@return FrameReader
function FrameReader.new(on_frame)
  return setmetatable({ chunks = {}, len = 0, on_frame = on_frame }, FrameReader)
end

function FrameReader:reset()
  self.chunks = {}
  self.len = 0
end

--- Feeds received bytes and emits every complete frame they finish.
--- A length past MAX_FRAME_LEN means the stream is no longer frame-aligned
--- and cannot be recovered by reading further.
---@param data string
---@return boolean ok, string|nil err
function FrameReader:feed(data)
  self.chunks[#self.chunks + 1] = data
  self.len = self.len + #data

  while self.len >= codec.HEADER_LEN do
    if #self.chunks[1] < codec.HEADER_LEN then
      self.chunks = { table.concat(self.chunks) }
    end

    local payload_len = codec.decode_len(self.chunks[1], 1)
    if payload_len > codec.MAX_FRAME_LEN then
      self:reset()
      return false, "stream out of sync"
    end
    if self.len < codec.HEADER_LEN + payload_len then return true end

    local buf = #self.chunks > 1 and table.concat(self.chunks) or self.chunks[1]
    local frame = buf:sub(codec.HEADER_LEN + 1, codec.HEADER_LEN + payload_len)
    local tail = buf:sub(codec.HEADER_LEN + payload_len + 1)
    self.chunks = tail == "" and {} or { tail }
    self.len = #tail

    self.on_frame(frame)
  end

  return true
end

return FrameReader
