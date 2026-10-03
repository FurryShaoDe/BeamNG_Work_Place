-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Spatial matching between the live vehicle and a replay reference lap.

local M = {}

function M.new(options)
  options = options or {}
  local object = assert(options.object, "vehicle object is required")
  local maximumDistanceSquared = assert(
    options.maximumDistanceSquared,
    "maximum match distance is required"
  )
  local indexes = assert(options.indexes, "sample indexes are required")
  local POS_X, POS_Y, POS_Z = indexes.posX, indexes.posY, indexes.posZ
  local FRONT_X, FRONT_Y, FRONT_Z = indexes.frontX, indexes.frontY, indexes.frontZ
  local matcher = {}

  function matcher.find(recording, playbackPoints, progressIndex)
    if not recording or #playbackPoints == 0 then return nil, progressIndex end

    local px, py, pz = object:getPositionXYZ()
    local currentFront = object:getDirectionVector()
    local firstIndex = math.max(1, progressIndex - 40)
    local lastIndex = math.min(#playbackPoints, progressIndex + 300)
    local bestIndex
    local bestDistance = math.huge

    for index = firstIndex, lastIndex do
      local point = playbackPoints[index]
      local dx = point[POS_X] - px
      local dy = point[POS_Y] - py
      local dz = point[POS_Z] - pz
      local distance = dx * dx + dy * dy + dz * dz
      local headingDot = currentFront.x * point[FRONT_X]
        + currentFront.y * point[FRONT_Y]
        + currentFront.z * point[FRONT_Z]
      if headingDot > -0.25 and distance < bestDistance then
        bestDistance = distance
        bestIndex = index
      end
    end

    if bestIndex and bestDistance <= maximumDistanceSquared then
      return playbackPoints[bestIndex], bestIndex
    end
    return nil, progressIndex
  end

  return matcher
end

return M
