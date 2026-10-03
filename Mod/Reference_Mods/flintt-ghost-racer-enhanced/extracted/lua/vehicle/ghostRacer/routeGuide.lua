-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Vehicle-side route geometry and GE synchronization.

local M = {}

local ROUTE_TARGET_SPACING = 10
local MAX_ROUTE_POINTS = 2400
-- A checkpoint is a gate plane through its centre, perpendicular to the reference
-- lap's direction of travel. The live car clears it only when the car body
-- actually crosses that plane going forward (not merely by approaching it), and
-- only if the crossing point is within this half-width of the centre -- otherwise
-- the car drove around the checkpoint off the route.
local CHECKPOINT_GATE_HALF_WIDTH = 20
local CHECKPOINT_GATE_HALF_WIDTH_SQ = CHECKPOINT_GATE_HALF_WIDTH * CHECKPOINT_GATE_HALF_WIDTH

function M.new(options)
  options = options or {}
  local route = {}
  local startGateConfig = assert(options.state, "route state is required")
  local obj = assert(options.object, "vehicle object is required")
  local ensureGhostSamples = assert(options.ensureGhostSamples, "sample loader is required")
  local bestGhostEntry = assert(options.bestGhostEntry, "best-entry resolver is required")
  local clamp = assert(options.clamp, "clamp is required")
  local indexes = assert(options.indexes, "sample indexes are required")
  local POS_X, POS_Y, POS_Z = indexes.posX, indexes.posY, indexes.posZ
  local FRONT_X, FRONT_Y = indexes.frontX, indexes.frontY

  function route.syncRouteGuide(includeGeometry)
    if not obj.queueGameEngineLua then return end
    local enabled = startGateConfig.routeGuideEnabled
      and startGateConfig.routeActive
      and startGateConfig.routeReady
      and not raceMode
    if includeGeometry ~= true then
      obj:queueGameEngineLua(
        "if extensions and extensions.ghostlapping and " ..
          "extensions.ghostlapping.setRouteGuideVisibility then " ..
          "extensions.ghostlapping.setRouteGuideVisibility(" .. tostring(enabled) .. "," ..
          tostring(startGateConfig.routePathVisible) .. "," ..
          tostring(startGateConfig.routeCheckpointsVisible) .. "," ..
          startGateConfig.senderLiteral() .. ") end"
      )
      return
    end

    local encodedPath = {}
    local encodedCheckpoints = {}
    for index = 1, #startGateConfig.routePath do
      local point = startGateConfig.routePath[index]
      encodedPath[#encodedPath + 1] = string.format(
        "{%.8g,%.8g,%.8g}", point[1], point[2], point[3]
      )
    end
    for index = 1, #startGateConfig.routeCheckpoints do
      local checkpoint = startGateConfig.routeCheckpoints[index]
      encodedCheckpoints[#encodedCheckpoints + 1] = string.format(
        "{%.8g,%.8g,%.8g,%.8g,%.8g,%d,%.8g}",
        checkpoint[1], checkpoint[2], checkpoint[3], checkpoint[4], checkpoint[5],
        index, checkpoint[6]
      )
    end

    obj:queueGameEngineLua(
      "if extensions and extensions.ghostlapping and " ..
        "extensions.ghostlapping.setRouteGuide then " ..
        "extensions.ghostlapping.setRouteGuide({" .. table.concat(encodedPath, ",") .. "},{" ..
        table.concat(encodedCheckpoints, ",") .. "}," .. tostring(enabled) .. "," ..
        tostring(startGateConfig.routePathVisible) .. "," ..
        tostring(startGateConfig.routeCheckpointsVisible) .. "," ..
        startGateConfig.senderLiteral() .. ") end"
    )
    -- New geometry resets the renderer's checkpoint colours, so re-send where the
    -- live lap currently stands in the same batch.
    route.syncCheckpointProgress()
  end

  function route.clearRouteGuide()
    startGateConfig.routeReady = false
    startGateConfig.routeActive = false
    startGateConfig.routeDistance = 0
    startGateConfig.routeSourceId = nil
    startGateConfig.routeSourceLabel = nil
    startGateConfig.routePath = {}
    startGateConfig.routeCheckpoints = {}
    startGateConfig.routeCheckpointNext = 1
    startGateConfig.syncRouteGuide(true)
  end

  -- A checkpoint is stored as {x, y, z, normalX, normalY, cumulativeDistance}.
  -- Progress is tracked purely from the live car's proximity to those centres, so
  -- no reference-sample bookkeeping is needed here.
  local function checkpointCount()
    return #startGateConfig.routeCheckpoints
  end

  -- Validation only applies when there is a reference lap to follow. On a fresh
  -- start line with no comparison ghost there are no checkpoints, so the first
  -- lap is recorded without a route constraint.
  function route.checkpointValidationActive()
    return startGateConfig.routeReady == true
      and startGateConfig.routeActive == true
      and checkpointCount() > 0
  end

  function route.allCheckpointsPassed()
    return (startGateConfig.routeCheckpointNext or 1) > checkpointCount()
  end

  -- The first checkpoint ordinal that has not been cleared yet, or nil once the
  -- whole route is covered.
  function route.missedCheckpointIndex()
    local nextIndex = startGateConfig.routeCheckpointNext or 1
    if nextIndex > checkpointCount() then return nil end
    return nextIndex
  end

  -- Push the progress cursor and the missed-checkpoint marker to GE so the
  -- renderer can recolour passed, next, upcoming and missed checkpoints.
  -- Deliberately tiny compared with the geometry sync so it is cheap to send
  -- whenever the cursor or the miss marker changes. A missed value of 0 means no
  -- checkpoint has been skipped this lap.
  function route.syncCheckpointProgress()
    if not obj.queueGameEngineLua then return end
    obj:queueGameEngineLua(
      "if extensions and extensions.ghostlapping and " ..
        "extensions.ghostlapping.setRouteCheckpointProgress then " ..
        "extensions.ghostlapping.setRouteCheckpointProgress(" ..
        tostring(startGateConfig.routeCheckpointNext or 1) .. "," ..
        tostring(startGateConfig.routeCheckpointMissed or 0) .. "," ..
        startGateConfig.senderLiteral() .. ") end"
    )
  end

  -- Start a fresh lap. Any checkpoint the car already sits in front of at the lap
  -- start is pre-cleared: a reference whose first gate falls behind the start
  -- line would otherwise be a gate the car can never cross forward, making the
  -- lap impossible to complete.
  function route.resetCheckpointProgress(px, py)
    startGateConfig.routeCheckpointNext = 1
    startGateConfig.routeCheckpointMissed = nil
    if px ~= nil and py ~= nil then
      local checkpoints = startGateConfig.routeCheckpoints
      local total = #checkpoints
      local nextIndex = 1
      while nextIndex <= total do
        local checkpoint = checkpoints[nextIndex]
        local nx, ny = checkpoint[4] or 0, checkpoint[5] or 1
        local normalLength = math.sqrt(nx * nx + ny * ny)
        if normalLength > 0.001 then nx, ny = nx / normalLength, ny / normalLength end
        local signed = (px - checkpoint[1]) * nx + (py - checkpoint[2]) * ny
        if signed >= 0 then nextIndex = nextIndex + 1 else break end
      end
      startGateConfig.routeCheckpointNext = nextIndex
    end
    route.syncCheckpointProgress()
  end

  -- Advance the cursor for every gate the car crossed this frame, in order. The
  -- car clears checkpoint N only when its body passes forward through N's gate
  -- plane (the previous position was behind the plane, the current one is in
  -- front) near the centre -- not on approach. Passing is strictly sequential:
  -- the car must clear N before N+1, so driving around one leaves the cursor
  -- stuck there and the lap reads as off-route. The previous position is the same
  -- one the start-gate detector latches, so the crossing point is interpolated
  -- the same way and a graphics hitch cannot skip a gate between frames.
  function route.updateCheckpointProgress(px, py)
    local checkpoints = startGateConfig.routeCheckpoints
    local total = #checkpoints
    if total == 0 then return end
    local prevPx = startGateConfig.previousPositionX
    local prevPy = startGateConfig.previousPositionY
    if prevPx == nil or prevPy == nil then return end
    local nextIndex = startGateConfig.routeCheckpointNext or 1
    local changed = false
    while nextIndex <= total do
      local checkpoint = checkpoints[nextIndex]
      local cx, cy = checkpoint[1], checkpoint[2]
      local nx, ny = checkpoint[4] or 0, checkpoint[5] or 1
      local normalLength = math.sqrt(nx * nx + ny * ny)
      if normalLength > 0.001 then nx, ny = nx / normalLength, ny / normalLength end
      local currentSigned = (px - cx) * nx + (py - cy) * ny
      local previousSigned = (prevPx - cx) * nx + (prevPy - cy) * ny
      if previousSigned < 0 and currentSigned >= 0 then
        local denominator = currentSigned - previousSigned
        local amount = denominator > 0.0001 and (-previousSigned / denominator) or 1
        if amount < 0 then amount = 0 elseif amount > 1 then amount = 1 end
        local crossX = prevPx + (px - prevPx) * amount
        local crossY = prevPy + (py - prevPy) * amount
        local lateralX = crossX - cx
        local lateralY = crossY - cy
        if lateralX * lateralX + lateralY * lateralY <= CHECKPOINT_GATE_HALF_WIDTH_SQ then
          nextIndex = nextIndex + 1
          changed = true
        else
          -- The car passed this gate's plane going forward but off to the side:
          -- it drove around the checkpoint. Flag it missed so the guide turns it
          -- red on the spot, and stop -- the cursor stays here so the lap is
          -- discarded at the finish.
          if startGateConfig.routeCheckpointMissed ~= nextIndex then
            startGateConfig.routeCheckpointMissed = nextIndex
            changed = true
          end
          break
        end
      else
        break
      end
    end
    if changed then
      startGateConfig.routeCheckpointNext = nextIndex
      route.syncCheckpointProgress()
    end
  end

  -- Convert the comparison ghost into a bounded, ground-projected route. The
  -- replay remains the source of truth; this compact guide is regenerated when
  -- the selected comparison or checkpoint spacing changes, so no extra route
  -- file can become stale.
  function route.buildRouteGuide(entry)
    startGateConfig.routePath = {}
    startGateConfig.routeCheckpoints = {}
    startGateConfig.routeCheckpointNext = 1
    startGateConfig.routeDistance = 0
    startGateConfig.routeReady = false
    startGateConfig.routeSourceId = entry and entry.id or nil
    startGateConfig.routeSourceLabel = entry and entry.label or nil
    if not entry or not ensureGhostSamples(entry) or #entry.samples < 2 then return false end

    local points = entry.samples
    local groundOffset = tonumber(entry.groundOffset) or 0
    local lastPoint = points[#points]
    local firstPoint = points[1]
    local closingDx = firstPoint[POS_X] - lastPoint[POS_X]
    local closingDy = firstPoint[POS_Y] - lastPoint[POS_Y]
    local closingDz = firstPoint[POS_Z] - lastPoint[POS_Z]
    local closingDistance = math.sqrt(
      closingDx * closingDx + closingDy * closingDy + closingDz * closingDz
    )
    local includeClosingSegment = closingDistance <= math.max(
      50, (tonumber(startGateConfig.routeCheckpointSpacing) or 200) * 0.5
    )
    local segmentEnd = #points + (includeClosingSegment and 1 or 0)
    local totalDistance = 0

    for index = 2, segmentEnd do
      local first = points[index - 1]
      local second = index <= #points and points[index] or points[1]
      local dx = second[POS_X] - first[POS_X]
      local dy = second[POS_Y] - first[POS_Y]
      local dz = second[POS_Z] - first[POS_Z]
      totalDistance = totalDistance + math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    if totalDistance < 5 then return false end

    local pathStep = math.max(ROUTE_TARGET_SPACING, totalDistance / (MAX_ROUTE_POINTS - 1))
    local requestedCheckpointSpacing = tonumber(startGateConfig.routeCheckpointSpacing) or 200
    local checkpointSpacing = math.max(requestedCheckpointSpacing, totalDistance / 60)
    if totalDistance < requestedCheckpointSpacing * 1.5 then
      checkpointSpacing = totalDistance * 0.5
    end
    local checkpointLimit = totalDistance < 80 and totalDistance * 0.8
      or totalDistance - math.min(25, checkpointSpacing * 0.25)
    local nextPathDistance = 0
    local nextCheckpointDistance = checkpointSpacing
    local accumulated = 0

    for index = 2, segmentEnd do
      local first = points[index - 1]
      local second = index <= #points and points[index] or points[1]
      local dx = second[POS_X] - first[POS_X]
      local dy = second[POS_Y] - first[POS_Y]
      local dz = second[POS_Z] - first[POS_Z]
      local segmentDistance = math.sqrt(dx * dx + dy * dy + dz * dz)
      local segmentFinish = accumulated + segmentDistance

      if segmentDistance > 0.001 then
        while nextPathDistance <= segmentFinish + 0.001
            and #startGateConfig.routePath < MAX_ROUTE_POINTS do
          local amount = clamp((nextPathDistance - accumulated) / segmentDistance, 0, 1)
          startGateConfig.routePath[#startGateConfig.routePath + 1] = {
            first[POS_X] + dx * amount,
            first[POS_Y] + dy * amount,
            first[POS_Z] + dz * amount - groundOffset + 0.055
          }
          nextPathDistance = nextPathDistance + pathStep
        end

        while nextCheckpointDistance <= segmentFinish + 0.001
            and nextCheckpointDistance <= checkpointLimit
            and #startGateConfig.routeCheckpoints < 60 do
          local amount = clamp((nextCheckpointDistance - accumulated) / segmentDistance, 0, 1)
          local horizontalLength = math.sqrt(dx * dx + dy * dy)
          local normalX = horizontalLength > 0.001 and dx / horizontalLength
            or tonumber(second[FRONT_X]) or 0
          local normalY = horizontalLength > 0.001 and dy / horizontalLength
            or tonumber(second[FRONT_Y]) or 1
          startGateConfig.routeCheckpoints[#startGateConfig.routeCheckpoints + 1] = {
            first[POS_X] + dx * amount,
            first[POS_Y] + dy * amount,
            first[POS_Z] + dz * amount - groundOffset,
            normalX,
            normalY,
            nextCheckpointDistance
          }
          nextCheckpointDistance = nextCheckpointDistance + checkpointSpacing
        end
      end
      accumulated = segmentFinish
    end

    local routeEnd = includeClosingSegment and points[1] or points[#points]
    local currentEnd = startGateConfig.routePath[#startGateConfig.routePath]
    if currentEnd and #startGateConfig.routePath < MAX_ROUTE_POINTS then
      local endX, endY, endZ = routeEnd[POS_X], routeEnd[POS_Y], routeEnd[POS_Z] - groundOffset + 0.055
      local endDx, endDy, endDz = endX - currentEnd[1], endY - currentEnd[2], endZ - currentEnd[3]
      if endDx * endDx + endDy * endDy + endDz * endDz > 1 then
        startGateConfig.routePath[#startGateConfig.routePath + 1] = {endX, endY, endZ}
      end
    end

    startGateConfig.routeDistance = totalDistance
    startGateConfig.routeReady = #startGateConfig.routePath >= 2
      and #startGateConfig.routeCheckpoints >= 1
    return startGateConfig.routeReady
  end

  function route.refreshRouteGuide(force)
    local entry = bestGhostEntry(true)
    local sameSource = entry and startGateConfig.routeSourceId == entry.id
    local geometryChanged = false
    if force == true or not sameSource or not startGateConfig.routeReady then
      startGateConfig.buildRouteGuide(entry)
      geometryChanged = true
    end
    startGateConfig.syncRouteGuide(geometryChanged)
    return startGateConfig.routeReady
  end

  function route.activateRouteGuide(includeGeometry)
    startGateConfig.routeActive = startGateConfig.routeReady
    startGateConfig.syncRouteGuide(includeGeometry == true)
  end

  function route.deactivateRouteGuide()
    startGateConfig.routeActive = false
    startGateConfig.syncRouteGuide()
  end

  function route.setRouteGuideEnabled(value)
    startGateConfig.routeGuideEnabled = value ~= false
    startGateConfig.syncRouteGuide()
    return true
  end

  function route.setRoutePathVisible(value)
    startGateConfig.routePathVisible = value ~= false
    startGateConfig.syncRouteGuide()
    return true
  end

  function route.setRouteCheckpointsVisible(value)
    startGateConfig.routeCheckpointsVisible = value ~= false
    startGateConfig.syncRouteGuide()
    return true
  end

  function route.setRouteCheckpointSpacing(value)
    local requested = math.floor(tonumber(value) or startGateConfig.routeCheckpointSpacing)
    local allowed = {[100] = true, [150] = true, [200] = true, [300] = true, [500] = true}
    if not allowed[requested] then return false end
    if startGateConfig.routeCheckpointSpacing == requested then return true end
    startGateConfig.routeCheckpointSpacing = requested
    startGateConfig.refreshRouteGuide(true)
    return true
  end


  return route
end

return M
