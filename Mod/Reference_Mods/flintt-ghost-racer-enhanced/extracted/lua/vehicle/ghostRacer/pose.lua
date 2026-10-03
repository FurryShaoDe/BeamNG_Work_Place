-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Stateless pose interpolation with caller-owned reusable vector buffers.

local M = {}

function M.new(options)
  options = options or {}
  local indexes = assert(options.indexes, "sample indexes are required")
  local vectorFactory = assert(options.vectorFactory, "vectorFactory is required")

  local POS_X, POS_Y, POS_Z = indexes.posX, indexes.posY, indexes.posZ
  local FRONT_X, FRONT_Y, FRONT_Z = indexes.frontX, indexes.frontY, indexes.frontZ
  local UP_X, UP_Y, UP_Z = indexes.upX, indexes.upY, indexes.upZ

  local pose = {}

  function pose.newBuffer()
    return {
      position = vectorFactory(),
      front = vectorFactory(),
      up = vectorFactory(),
      negativeFront = vectorFactory()
    }
  end

  local function normalizeDirection(target, fallbackX, fallbackY, fallbackZ)
    local lengthSquared = target.x * target.x + target.y * target.y + target.z * target.z
    if lengthSquared < 0.000001 then
      target.x, target.y, target.z = fallbackX, fallbackY, fallbackZ
      return
    end
    local inverseLength = 1 / math.sqrt(lengthSquared)
    target.x = target.x * inverseLength
    target.y = target.y * inverseLength
    target.z = target.z * inverseLength
  end

  function pose.interpolate(buffer, first, second, amount)
    local inverse = 1 - amount
    local position, front, up = buffer.position, buffer.front, buffer.up

    position.x = first[POS_X] * inverse + second[POS_X] * amount
    position.y = first[POS_Y] * inverse + second[POS_Y] * amount
    position.z = first[POS_Z] * inverse + second[POS_Z] * amount

    front.x = first[FRONT_X] * inverse + second[FRONT_X] * amount
    front.y = first[FRONT_Y] * inverse + second[FRONT_Y] * amount
    front.z = first[FRONT_Z] * inverse + second[FRONT_Z] * amount
    normalizeDirection(front, 0, -1, 0)

    up.x = first[UP_X] * inverse + second[UP_X] * amount
    up.y = first[UP_Y] * inverse + second[UP_Y] * amount
    up.z = first[UP_Z] * inverse + second[UP_Z] * amount

    local dot = front.x * up.x + front.y * up.y + front.z * up.z
    up.x = up.x - front.x * dot
    up.y = up.y - front.y * dot
    up.z = up.z - front.z * dot
    normalizeDirection(up, 0, 0, 1)

    buffer.negativeFront.x = -front.x
    buffer.negativeFront.y = -front.y
    buffer.negativeFront.z = -front.z
    return buffer
  end

  return pose
end

return M
