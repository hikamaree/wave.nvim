--- Paints a one-bit signal as a two-row waveform.

local Sampler = require("wave.render.sampler")

local M = {}

--- Columns holding more transitions than can be drawn individually are shown
--- as a dense band; the neighbours then have to meet that band with a
--- through-shape rather than a dead-end corner.
---@param value_changes table|nil
---@param scale TimeScale
---@return string, string
function M.paint(value_changes, scale)
  local width = scale.cols
  if not value_changes or #value_changes == 0 then
    return string.rep(" ", width), string.rep(" ", width)
  end

  local s = Sampler.of(value_changes, scale)
  s:align_left_edge(value_changes, scale.t0)

  local top, bot = {}, {}
  for c = 1, width do top[c] = " "; bot[c] = " " end

  for col = 0, width - 1 do
    local c = col + 1
    local v, nv = s.value[col], s.value[col + 1]
    local transitions = s.count[col]

    if transitions == 0 then
      if v == "1" then
        top[c] = "─"
      elseif v == "0" then
        bot[c] = "─"
      else
        top[c] = "─"; bot[c] = "─"
      end

    elseif transitions == 1 then
      if v ~= "0" and v ~= "1" then
        top[c] = "─"; bot[c] = "─"
      else
        local prev_dense = col > 0 and s.count[col - 1] >= 2
        local next_dense = col < width - 1 and s.count[col + 1] >= 2
        if nv == "1" then
          top[c] = prev_dense and "┬" or "┌"
          bot[c] = next_dense and "┴" or "┘"
        else
          top[c] = next_dense and "┬" or "┐"
          bot[c] = prev_dense and "┴" or "└"
        end
      end

    else
      top[c] = "┬"
      bot[c] = "┴"

      local left_flat = col > 0 and s.count[col - 1] == 0
      local right_flat = col < width - 1 and s.count[col + 1] == 0

      if left_flat and right_flat and v == nv then
        -- Isolated blip: connects to neither side, so use a half-line toward
        -- the other row instead of a dangling corner.
        if v == "1" then bot[c] = "╵" else top[c] = "╷" end
      else
        -- Drop to a corner on the row the flat neighbour doesn't use.
        if left_flat then
          if v == "1" then bot[c] = "└" else top[c] = "┌" end
        end
        if right_flat then
          if nv == "1" then bot[c] = "┘" else top[c] = "┐" end
        end
      end
    end
  end

  return table.concat(top), table.concat(bot)
end

return M
