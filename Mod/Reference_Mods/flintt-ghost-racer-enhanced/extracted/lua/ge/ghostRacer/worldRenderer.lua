-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Game-engine world visualization for Ghost Racer.
-- Each extension runtime owns one instance so hot reloads cannot retain state.

local M = {}

local MAX_TRAIL_SEGMENTS = 1100
local MAX_BEST_LAP_SEGMENTS = 4000
local MAX_ROUTE_POINTS = 2400
local MAX_ROUTE_CHECKPOINTS = 60
local STATIC_LINE_DRAW_DISTANCE_SQUARED = 1200 * 1200

function M.new()
  local world = {}
  local markerConfig = {savedVisible = true, activeVisible = true, markers = {}}
  local markerObjects = {}
  local legacyMarkerObjectsChecked = false
  local ghostTrailSegments = {}
  local bestLapLineSegments = {}
  local liveInputTrailSegments = {}
  local routeGuide = {
    enabled = false,
    pathVisible = true,
    checkpointsVisible = true,
    path = {},
    checkpoints = {},
    -- 1-based ordinal of the checkpoint the live lap must clear next. Ordinals
    -- below it are already passed (green), the one at it is the current target
    -- (amber), the one after it is the following beacon, the rest are upcoming
    -- (blue/orange). missedCheckpoint (0 = none) is one the car drove around; it
    -- is drawn red so a doomed lap reads on the spot.
    nextCheckpoint = 1,
    missedCheckpoint = 0
  }
  local telemetryColorValues = {
    {55 / 255, 115 / 255, 1, 0.84},
    {35 / 255, 195 / 255, 1, 0.84},
    {55 / 255, 225 / 255, 150 / 255, 0.86},
    {175 / 255, 235 / 255, 75 / 255, 0.86},
    {1, 220 / 255, 55 / 255, 0.88},
    {1, 135 / 255, 35 / 255, 0.88},
    {1, 65 / 255, 75 / 255, 0.9},
    {1, 55 / 255, 70 / 255, 0.9},
    {1, 105 / 255, 45 / 255, 0.88},
    {1, 175 / 255, 55 / 255, 0.86},
    {205 / 255, 215 / 255, 225 / 255, 0.82},
    {105 / 255, 225 / 255, 145 / 255, 0.86},
    {45 / 255, 235 / 255, 115 / 255, 0.88},
    {20 / 255, 1, 85 / 255, 0.9},
    {150 / 255, 158 / 255, 168 / 255, 0.76}
  }

  -- Driver-input colours (indexes 16+) are generated as fine gradients so pedal
  -- depth reads as a continuous change rather than a few visible steps. Layout,
  -- shared by convention with trailRenderer's index maths:
  --   16                     coasting (neutral white)
  --   17 .. 16+INPUT_STEPS   braking, dark to bright red
  --   .. +INPUT_STEPS        throttle, dark to bright green
  --   then upshift (pink), downshift (purple)
  --   then HANDBRAKE_STEPS   handbrake, dark to bright blue
  local INPUT_STEPS = 24
  local HANDBRAKE_STEPS = 8
  local function appendGradient(list, count, dark, bright)
    for step = 1, count do
      local t = count > 1 and (step - 1) / (count - 1) or 1
      list[#list + 1] = {
        dark[1] + (bright[1] - dark[1]) * t,
        dark[2] + (bright[2] - dark[2]) * t,
        dark[3] + (bright[3] - dark[3]) * t,
        dark[4] + (bright[4] - dark[4]) * t
      }
    end
  end
  telemetryColorValues[#telemetryColorValues + 1] = {0.9, 0.95, 1, 0.85} -- 16 coast
  appendGradient(telemetryColorValues, INPUT_STEPS, {0.3, 0.02, 0.02, 0.8}, {1, 0.22, 0.14, 0.96})
  appendGradient(telemetryColorValues, INPUT_STEPS, {0.03, 0.26, 0.06, 0.8}, {0.24, 1, 0.32, 0.96})
  telemetryColorValues[#telemetryColorValues + 1] = {1, 0.2, 0.78, 0.96}  -- upshift (pink)
  telemetryColorValues[#telemetryColorValues + 1] = {0.62, 0.28, 1, 0.96} -- downshift (purple)
  appendGradient(telemetryColorValues, HANDBRAKE_STEPS, {0.04, 0.28, 0.5, 0.85}, {0.26, 0.74, 1, 0.96})
  -- Throttle and brake pressed together (left-foot braking / trail overlap): amber.
  appendGradient(telemetryColorValues, INPUT_STEPS, {0.35, 0.18, 0.02, 0.82}, {1, 0.72, 0.1, 0.96})
  -- Clutch sub-line: teal, dark to bright by how far the clutch is pressed.
  appendGradient(telemetryColorValues, INPUT_STEPS, {0.02, 0.3, 0.28, 0.82}, {0.16, 0.98, 0.86, 0.96})

  local function buildTelemetryPalette(alphaScale)
    local result = {}
    for index = 1, #telemetryColorValues do
      local value = telemetryColorValues[index]
      result[index] = ColorF(value[1], value[2], value[3], value[4] * alphaScale)
    end
    return result
  end

  local trailBestColors = buildTelemetryPalette(1)
  local trailRankColors = {
    buildTelemetryPalette(0.18),
    buildTelemetryPalette(0.3),
    buildTelemetryPalette(0.42),
    buildTelemetryPalette(0.58),
    buildTelemetryPalette(0.74)
  }
  local bestLapLineColors = buildTelemetryPalette(0.68)
  local routeRoadColor = ColorF(45 / 255, 205 / 255, 1, 0.38)
  local routeFallbackColor = ColorF(1, 150 / 255, 55 / 255, 0.48)
  local routeRoadGlowColor = ColorF(30 / 255, 190 / 255, 1, 0.17)
  local routeFallbackGlowColor = ColorF(1, 135 / 255, 35 / 255, 0.18)
  local routeRoadCoreColor = ColorF(80 / 255, 220 / 255, 1, 0.74)
  local routeFallbackCoreColor = ColorF(1, 170 / 255, 70 / 255, 0.76)
  local bestTrailHaloColor = ColorF(0.85, 0.96, 1, 0.16)
  local flatRibbonSolidSupported
  local flatRibbonSolidWarningLogged = false

  local function markerSurfaceHeight(x, y, fallbackZ)
    if not be or not be.getSurfaceHeightBelow then return fallbackZ end
    local height = be:getSurfaceHeightBelow(vec3(x, y, fallbackZ + 3))
    if not height or height < -1e10 then return fallbackZ end
    return height
  end

  local function cameraPositionXY()
    if type(core_camera) ~= "table" or type(core_camera.getPositionXYZ) ~= "function" then
      return nil, nil
    end
    local ok, x, y = pcall(core_camera.getPositionXYZ)
    if not ok then return nil, nil end
    return tonumber(x), tonumber(y)
  end

  local function staticSegmentVisible(ax, ay, bx, by, cameraX, cameraY)
    if not cameraX or not cameraY then return true end
    local dx = (ax + bx) * 0.5 - cameraX
    local dy = (ay + by) * 0.5 - cameraY
    return dx * dx + dy * dy <= STATIC_LINE_DRAW_DISTANCE_SQUARED
  end

  local function vectorComponent(value, name, index)
    if not value then return nil end
    return tonumber(value[name]) or tonumber(value[index])
  end

  local function drawFlatRibbon(ax, ay, az, bx, by, bz, halfWidth, zOffset, lineColor)
    local dx, dy = bx - ax, by - ay
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return false end
    local lateralX, lateralY = -dy / length * halfWidth, dx / length * halfWidth
    local leftA = vec3(ax + lateralX, ay + lateralY, az + zOffset)
    local rightA = vec3(ax - lateralX, ay - lateralY, az + zOffset)
    local leftB = vec3(bx + lateralX, by + lateralY, bz + zOffset)
    local rightB = vec3(bx - lateralX, by - lateralY, bz + zOffset)

    if flatRibbonSolidSupported ~= false and debugDrawer.drawQuadSolid then
      local first = leftA.toPoint3F and leftA:toPoint3F() or leftA
      local second = rightA.toPoint3F and rightA:toPoint3F() or rightA
      local third = rightB.toPoint3F and rightB:toPoint3F() or rightB
      local fourth = leftB.toPoint3F and leftB:toPoint3F() or leftB

      if flatRibbonSolidSupported == nil then
        -- Debug-drawer bindings differ between BeamNG releases. Probe the full
        -- four-point/color/depth signature once under protection so a binding
        -- mismatch can never escape onPreRender and stall camera updates.
        local ok, errorMessage = pcall(
          debugDrawer.drawQuadSolid,
          debugDrawer,
          first, second, third, fourth,
          lineColor,
          true
        )
        if ok then
          flatRibbonSolidSupported = true
          return true
        end
        flatRibbonSolidSupported = false
        if not flatRibbonSolidWarningLogged and log then
          flatRibbonSolidWarningLogged = true
          log("W", "ghostlapping", "Solid ribbon unavailable; using flat lines: " .. tostring(errorMessage))
        end
      else
        debugDrawer:drawQuadSolid(first, second, third, fourth, lineColor, true)
        return true
      end
    end

    -- Older debug drawers may not expose compatible solid quads. Parallel ground lines
    -- preserve the intended horizontal orientation instead of reverting to the
    -- camera-facing/vertical square-prism ribbon.
    if debugDrawer.drawLine then
      debugDrawer:drawLine(leftA, leftB, lineColor)
      debugDrawer:drawLine(vec3(ax, ay, az + zOffset), vec3(bx, by, bz + zOffset), lineColor)
      debugDrawer:drawLine(rightA, rightB, lineColor)
      return true
    end
    return false
  end

  local function matchHybridRoad(x, y, z, directionX, directionY, previous, nodes)
    if type(map) ~= "table" or type(map.findClosestRoad) ~= "function"
        or type(nodes) ~= "table" then return nil end

    local ok, firstId, secondId = pcall(map.findClosestRoad, vec3(x, y, z))
    if not ok or not firstId or not secondId then return nil end
    local firstNode = nodes and nodes[firstId]
    local secondNode = nodes and nodes[secondId]
    if not firstNode or not secondNode then return nil end

    local firstPosition, secondPosition = firstNode.pos, secondNode.pos
    local ax = vectorComponent(firstPosition, "x", 1)
    local ay = vectorComponent(firstPosition, "y", 2)
    local az = vectorComponent(firstPosition, "z", 3)
    local bx = vectorComponent(secondPosition, "x", 1)
    local by = vectorComponent(secondPosition, "y", 2)
    local bz = vectorComponent(secondPosition, "z", 3)
    if not ax or not ay or not az or not bx or not by or not bz then return nil end

    local edgeX, edgeY, edgeZ = bx - ax, by - ay, bz - az
    local edgeLengthSquared = edgeX * edgeX + edgeY * edgeY
    if edgeLengthSquared < 0.001 then return nil end
    local amount = math.max(0, math.min(1,
      ((x - ax) * edgeX + (y - ay) * edgeY) / edgeLengthSquared
    ))
    local snappedX = ax + edgeX * amount
    local snappedY = ay + edgeY * amount
    local snappedZ = az + edgeZ * amount
    local horizontalLength = math.sqrt(edgeLengthSquared)
    local roadDirectionX, roadDirectionY = edgeX / horizontalLength, edgeY / horizontalLength

    local inputLength = math.sqrt(directionX * directionX + directionY * directionY)
    if inputLength > 0.001 then
      directionX, directionY = directionX / inputLength, directionY / inputLength
      local headingDot = directionX * roadDirectionX + directionY * roadDirectionY
      if math.abs(headingDot) < 0.28 then return nil end
      if headingDot < 0 then
        roadDirectionX, roadDirectionY = -roadDirectionX, -roadDirectionY
      end
    end

    local firstRadius = tonumber(firstNode.radius) or 6.5
    local secondRadius = tonumber(secondNode.radius) or firstRadius
    local halfWidth = math.max(3, math.min(15,
      firstRadius + (secondRadius - firstRadius) * amount
    ))
    local offsetX, offsetY = x - snappedX, y - snappedY
    local horizontalOffset = math.sqrt(offsetX * offsetX + offsetY * offsetY)
    if horizontalOffset > math.max(12, halfWidth * 1.8) or math.abs(z - snappedZ) > 6 then
      return nil
    end

    if previous and previous.matched then
      local sharesNode = previous.firstId == firstId or previous.firstId == secondId
        or previous.secondId == firstId or previous.secondId == secondId
      local snappedDx, snappedDy = snappedX - previous.x, snappedY - previous.y
      local snappedDistance = math.sqrt(snappedDx * snappedDx + snappedDy * snappedDy)
      local rawDx, rawDy = x - previous.rawX, y - previous.rawY
      local rawDistance = math.sqrt(rawDx * rawDx + rawDy * rawDy)
      if not sharesNode and snappedDistance > math.max(30, rawDistance * 2.5 + 8) then
        return nil
      end

      -- findClosestRoad can alternate between parallel or overlapping navgraph
      -- edges even while the Ghost follows one continuous lane. Reject a
      -- disconnected edge when its snap correction suddenly moves sideways;
      -- the hybrid renderer will use the original Ghost point for that sample.
      local correctionX, correctionY = snappedX - x, snappedY - y
      local previousCorrectionX = previous.x - previous.rawX
      local previousCorrectionY = previous.y - previous.rawY
      local correctionDx = correctionX - previousCorrectionX
      local correctionDy = correctionY - previousCorrectionY
      local correctionJump = math.sqrt(correctionDx * correctionDx + correctionDy * correctionDy)
      if not sharesNode and correctionJump > math.max(2.5, rawDistance * 0.45) then
        return nil
      end
    end

    return {
      x = snappedX,
      y = snappedY,
      z = markerSurfaceHeight(snappedX, snappedY, snappedZ),
      nx = roadDirectionX,
      ny = roadDirectionY,
      halfWidth = halfWidth,
      firstId = firstId,
      secondId = secondId,
      matched = true,
      rawX = x,
      rawY = y
    }
  end

  local function smoothRoutePath(path)
    if type(path) ~= "table" or #path < 3 then return path end

    local source = path
    for _ = 1, 2 do
      local smoothed = {source[1]}
      for index = 2, #source - 1 do
        local previous = source[index - 1]
        local current = source[index]
        local following = source[index + 1]
        local incomingX, incomingY = current[1] - previous[1], current[2] - previous[2]
        local outgoingX, outgoingY = following[1] - current[1], following[2] - current[2]
        local incomingLength = math.sqrt(incomingX * incomingX + incomingY * incomingY)
        local outgoingLength = math.sqrt(outgoingX * outgoingX + outgoingY * outgoingY)
        local sameSource = previous[4] == current[4] and current[4] == following[4]
        local directionDot = -1
        if incomingLength > 0.001 and outgoingLength > 0.001 then
          directionDot = (incomingX * outgoingX + incomingY * outgoingY)
            / (incomingLength * outgoingLength)
        end

        -- Only soften locally consistent, non-hairpin sections. Source changes
        -- remain exact so cyan road matches and amber Ghost fallbacks do not get
        -- blended across a boundary or cut through a real sharp corner.
        if sameSource
            and directionDot > 0.2
            and math.max(incomingLength, outgoingLength) < 50
            and math.min(incomingLength, outgoingLength)
              > math.max(incomingLength, outgoingLength) * 0.2 then
          smoothed[index] = {
            previous[1] * 0.2 + current[1] * 0.6 + following[1] * 0.2,
            previous[2] * 0.2 + current[2] * 0.6 + following[2] * 0.2,
            previous[3] * 0.2 + current[3] * 0.6 + following[3] * 0.2,
            current[4]
          }
        else
          smoothed[index] = current
        end
      end
      smoothed[#source] = source[#source]
      source = smoothed
    end
    return source
  end

  local function markerIsVisible(marker)
    -- The finish gate belongs to the active start, so it follows the same
    -- start-gate visibility toggle.
    if marker.active or marker.isFinish then return markerConfig.activeVisible end
    return markerConfig.savedVisible
  end

  local function removeMarkerObjects()
    for index = 1, #markerObjects do
      local markerObject = markerObjects[index]
      if markerObject and markerObject.delete then markerObject:delete() end
    end
    markerObjects = {}
  end

  local function removeLegacyMarkerObjects()
    if legacyMarkerObjectsChecked then return end
    if not scenetree or type(scenetree.findObject) ~= "function" then return end
    legacyMarkerObjectsChecked = true
    for serial = 1, 100 do
      for _, side in ipairs({"left", "right"}) do
        local markerObject = scenetree.findObject(
          string.format("ghostRacerCheckpoint_%d_%s", serial, side)
        )
        if markerObject and markerObject.delete then markerObject:delete() end
      end
    end
  end

  local function rebuildMarkerObjects()
    removeMarkerObjects()
    -- 2.4.2 briefly created position_marker.dae objects. Remove any surviving
    -- instances during hot reload; all current columns use filled geometry only.
    removeLegacyMarkerObjects()
  end

  function world.setFreeRoamMarkers(markers, savedVisible, activeVisible)
    markerConfig.savedVisible = savedVisible ~= false
    markerConfig.activeVisible = activeVisible ~= false
    markerConfig.markers = {}
    for index = 1, math.min(type(markers) == "table" and #markers or 0, 21) do
      local marker = markers[index]
      local nx = tonumber(marker.nx) or 0
      local ny = tonumber(marker.ny) or 1
      local length = math.sqrt(nx * nx + ny * ny)
      if length > 0.001 then
        nx, ny = nx / length, ny / length
        local lateralX, lateralY = -ny, nx
        local x, y, z = tonumber(marker.x) or 0, tonumber(marker.y) or 0, tonumber(marker.z) or 0
        local halfWidth = 6.5
        local leftX, leftY = x + lateralX * halfWidth, y + lateralY * halfWidth
        local rightX, rightY = x - lateralX * halfWidth, y - lateralY * halfWidth
        markerConfig.markers[#markerConfig.markers + 1] = {
          id = tostring(marker.id or index),
          name = tostring(marker.name or ("Start " .. index)),
          x = x, y = y, z = markerSurfaceHeight(x, y, z),
          nx = nx, ny = ny,
          leftX = leftX, leftY = leftY,
          rightX = rightX, rightY = rightY,
          leftZ = markerSurfaceHeight(leftX, leftY, z),
          rightZ = markerSurfaceHeight(rightX, rightY, z),
          ghostCount = math.max(0, tonumber(marker.ghostCount) or 0),
          pbTime = tonumber(marker.pbTime),
          active = marker.active == true,
          isFinish = marker.isFinish == true
        }
      end
    end
    rebuildMarkerObjects()
  end

  function world.setGhostTrailSegments(segments, visible)
    ghostTrailSegments = {}
    if visible == false or type(segments) ~= "table" then return end

    for index = 1, math.min(#segments, MAX_TRAIL_SEGMENTS) do
      local segment = segments[index]
      if type(segment) == "table" then
        local ax, ay, az = tonumber(segment[1]), tonumber(segment[2]), tonumber(segment[3])
        local bx, by, bz = tonumber(segment[4]), tonumber(segment[5]), tonumber(segment[6])
        if ax and ay and az and bx and by and bz then
          ghostTrailSegments[#ghostTrailSegments + 1] = {
            ax, ay, az, bx, by, bz,
            math.max(1, math.min(
              #telemetryColorValues,
              math.floor(tonumber(segment[7]) or #telemetryColorValues)
            )),
            segment[8] == true or tonumber(segment[8]) == 1,
            math.max(1, math.min(5, math.floor(tonumber(segment[9]) or 5))),
            -- 10th field flags a thin clutch/handbrake sub-line piece.
            segment[10] == true or tonumber(segment[10]) == 1
          }
        end
      end
    end
  end

  function world.setBestLapLineSegments(segments, visible)
    bestLapLineSegments = {}
    if visible == false or type(segments) ~= "table" then return end

    local previousX, previousY, previousZ, previousGroundZ
    for index = 1, math.min(#segments, MAX_BEST_LAP_SEGMENTS) do
      local segment = segments[index]
      if type(segment) == "table" then
        local ax, ay, az = tonumber(segment[1]), tonumber(segment[2]), tonumber(segment[3])
        local bx, by, bz = tonumber(segment[4]), tonumber(segment[5]), tonumber(segment[6])
        if ax and ay and az and bx and by and bz then
          local groundA = previousX == ax and previousY == ay and previousZ == az
            and previousGroundZ or markerSurfaceHeight(ax, ay, az)
          local groundB = markerSurfaceHeight(bx, by, bz)
          bestLapLineSegments[#bestLapLineSegments + 1] = {
            ax, ay, groundA,
            bx, by, groundB,
            math.max(1, math.min(
              #telemetryColorValues,
              math.floor(tonumber(segment[7]) or #telemetryColorValues)
            )),
            -- 8th field flags a clutch sub-line piece, drawn thinner and offset.
            tonumber(segment[8]) == 1 and 1 or 0
          }
          previousX, previousY, previousZ, previousGroundZ = bx, by, bz, groundB
        end
      end
    end
  end

  -- The live vehicle's own input trajectory (debug). Same layout as the best-lap
  -- line (shift ticks and thin clutch/handbrake sub-line pieces included),
  -- projected onto the surface and coloured by the telemetry palette.
  function world.setLiveInputTrailSegments(segments, visible)
    liveInputTrailSegments = {}
    if visible == false or type(segments) ~= "table" then return end
    local previousX, previousY, previousZ, previousGroundZ
    for index = 1, math.min(#segments, MAX_BEST_LAP_SEGMENTS) do
      local segment = segments[index]
      if type(segment) == "table" then
        local ax, ay, az = tonumber(segment[1]), tonumber(segment[2]), tonumber(segment[3])
        local bx, by, bz = tonumber(segment[4]), tonumber(segment[5]), tonumber(segment[6])
        if ax and ay and az and bx and by and bz then
          local groundA = previousX == ax and previousY == ay and previousZ == az
            and previousGroundZ or markerSurfaceHeight(ax, ay, az)
          local groundB = markerSurfaceHeight(bx, by, bz)
          liveInputTrailSegments[#liveInputTrailSegments + 1] = {
            ax, ay, groundA, bx, by, groundB,
            math.max(1, math.min(
              #telemetryColorValues,
              math.floor(tonumber(segment[7]) or #telemetryColorValues)
            )),
            -- 8th field flags a clutch/handbrake sub-line piece, drawn thinner.
            tonumber(segment[8]) == 1 and 1 or 0
          }
          previousX, previousY, previousZ, previousGroundZ = bx, by, bz, groundB
        end
      end
    end
  end

  function world.setRouteGuide(path, checkpoints, enabled, pathVisible, checkpointsVisible)
    routeGuide.enabled = enabled == true
    routeGuide.pathVisible = pathVisible ~= false
    routeGuide.checkpointsVisible = checkpointsVisible ~= false
    routeGuide.path = {}
    routeGuide.checkpoints = {}
    -- New geometry means a new lap's worth of progress; the vehicle re-sends the
    -- live cursor right after this, but default to "first checkpoint next".
    routeGuide.nextCheckpoint = 1
    routeGuide.missedCheckpoint = 0

    local rawPath = {}
    local navgraphNodes
    if type(map) == "table" and type(map.getMap) == "function" then
      local mapOk, mapData = pcall(map.getMap)
      if mapOk and type(mapData) == "table" and type(mapData.nodes) == "table" then
        navgraphNodes = mapData.nodes
      end
    end

    for index = 1, math.min(type(path) == "table" and #path or 0, MAX_ROUTE_POINTS) do
      local point = path[index]
      if type(point) == "table" then
        local x, y, z = tonumber(point[1]), tonumber(point[2]), tonumber(point[3])
        if x and y and z then
          rawPath[#rawPath + 1] = {x, y, z}
        end
      end
    end

    local previousMatch
    local matchedPointCount = 0
    for index = 1, #rawPath do
      local point = rawPath[index]
      local previousPoint = rawPath[math.max(1, index - 1)]
      local nextPoint = rawPath[math.min(#rawPath, index + 1)]
      local directionX = nextPoint[1] - previousPoint[1]
      local directionY = nextPoint[2] - previousPoint[2]
      local roadMatch = matchHybridRoad(
        point[1], point[2], point[3], directionX, directionY, previousMatch, navgraphNodes
      )
      local alignedPoint
      if roadMatch then
        alignedPoint = {roadMatch.x, roadMatch.y, roadMatch.z, true}
        previousMatch = roadMatch
        matchedPointCount = matchedPointCount + 1
      else
        alignedPoint = {
          point[1], point[2], markerSurfaceHeight(point[1], point[2], point[3]), false
        }
        -- Keep the last valid match as continuity context. A single rejected
        -- parallel edge must not make the next sample free to jump onto it.
      end

      local prior = routeGuide.path[#routeGuide.path]
      if not prior then
        routeGuide.path[#routeGuide.path + 1] = alignedPoint
      else
        local dx, dy, dz = alignedPoint[1] - prior[1], alignedPoint[2] - prior[2], alignedPoint[3] - prior[3]
        if dx * dx + dy * dy + dz * dz > 0.04 then
          routeGuide.path[#routeGuide.path + 1] = alignedPoint
        end
      end
    end
    routeGuide.path = smoothRoutePath(routeGuide.path)
    for index = 1, #routeGuide.path do
      local point = routeGuide.path[index]
      point[3] = markerSurfaceHeight(point[1], point[2], point[3])
    end

    local matchedCheckpointCount = 0
    for index = 1, math.min(
        type(checkpoints) == "table" and #checkpoints or 0,
        MAX_ROUTE_CHECKPOINTS
      ) do
      local checkpoint = checkpoints[index]
      if type(checkpoint) == "table" then
        local x, y, z = tonumber(checkpoint[1]), tonumber(checkpoint[2]), tonumber(checkpoint[3])
        local nx, ny = tonumber(checkpoint[4]) or 0, tonumber(checkpoint[5]) or 1
        local normalLength = math.sqrt(nx * nx + ny * ny)
        if x and y and z and normalLength > 0.001 then
          nx, ny = nx / normalLength, ny / normalLength
          local roadMatch = matchHybridRoad(x, y, z, nx, ny, nil, navgraphNodes)
          local matched = roadMatch ~= nil
          if roadMatch then
            matchedCheckpointCount = matchedCheckpointCount + 1
            x, y, z = roadMatch.x, roadMatch.y, roadMatch.z
            nx, ny = roadMatch.nx, roadMatch.ny
          end
          local lateralX, lateralY = -ny, nx
          local halfWidth = roadMatch and roadMatch.halfWidth or 6.5
          local leftX, leftY = x + lateralX * halfWidth, y + lateralY * halfWidth
          local rightX, rightY = x - lateralX * halfWidth, y - lateralY * halfWidth
          routeGuide.checkpoints[#routeGuide.checkpoints + 1] = {
            x = x,
            y = y,
            z = markerSurfaceHeight(x, y, z),
            leftX = leftX,
            leftY = leftY,
            leftZ = markerSurfaceHeight(leftX, leftY, z),
            rightX = rightX,
            rightY = rightY,
            rightZ = markerSurfaceHeight(rightX, rightY, z),
            index = math.max(1, math.floor(tonumber(checkpoint[6]) or index)),
            distance = math.max(0, tonumber(checkpoint[7]) or 0),
            matched = matched
          }
        end
      end
    end

    local totalPoints = #rawPath
    local coverage = totalPoints > 0 and matchedPointCount / totalPoints or 0
    local status = "noPath"
    if totalPoints > 0 and not navgraphNodes then
      status = "noNavgraph"
    elseif totalPoints > 0 and matchedPointCount == totalPoints then
      status = "matched"
    elseif matchedPointCount > 0 then
      status = "partial"
    elseif totalPoints > 0 then
      status = "fallback"
    end
    if guihooks and guihooks.trigger then
      guihooks.trigger("GhostRacerRouteMatchState", {
        status = status,
        matchedPoints = matchedPointCount,
        totalPoints = totalPoints,
        coverage = coverage,
        matchedCheckpoints = matchedCheckpointCount,
        totalCheckpoints = #routeGuide.checkpoints
      })
    end
  end

  function world.setRouteGuideVisibility(enabled, pathVisible, checkpointsVisible)
    routeGuide.enabled = enabled == true
    routeGuide.pathVisible = pathVisible ~= false
    routeGuide.checkpointsVisible = checkpointsVisible ~= false
  end

  -- The live lap reports which checkpoint it must clear next (and which, if any,
  -- it drove around) so the guide can colour passed, target, following, upcoming
  -- and missed checkpoints apart.
  function world.setRouteCheckpointProgress(nextCheckpoint, missedCheckpoint)
    routeGuide.nextCheckpoint = math.max(1, math.floor(tonumber(nextCheckpoint) or 1))
    routeGuide.missedCheckpoint = math.max(0, math.floor(tonumber(missedCheckpoint) or 0))
  end

  function world.onPreRender()
    if not debugDrawer then return end
    local cameraX, cameraY = cameraPositionXY()

    for index = 1, #markerConfig.markers do
      local marker = markerConfig.markers[index]
      if markerIsVisible(marker) then
      local active = marker.active
      local isFinish = marker.isFinish == true
      -- The finish gate renders at the same prominence as an active start but in
      -- a distinct green so the two ends of a point-to-point run read apart.
      local prominent = active or isFinish
      local red, green, blue
      if isFinish then
        red, green, blue = 0.2, 1, 0.45
      else
        red, green, blue = active and 1 or 0.16, active and 0.35 or 0.82, active and 0.05 or 1
      end
      local baseOffset = prominent and 0.2 or 0.09
      local leftBottom = vec3(marker.leftX, marker.leftY, marker.leftZ + baseOffset)
      local rightBottom = vec3(marker.rightX, marker.rightY, marker.rightZ + baseOffset)
      local leftTop = vec3(marker.leftX, marker.leftY, marker.leftZ + (prominent and 30 or 14))
      local rightTop = vec3(marker.rightX, marker.rightY, marker.rightZ + (prominent and 30 or 14))
      local leftCoreTop = vec3(marker.leftX, marker.leftY, marker.leftZ + (prominent and 6 or 3))
      local rightCoreTop = vec3(marker.rightX, marker.rightY, marker.rightZ + (prominent and 6 or 3))
      local glowColor = ColorF(red, green, blue, prominent and 0.2 or 0.1)
      local coreColor = ColorF(red, green, blue, prominent and 0.82 or 0.52)

      if debugDrawer.drawSquarePrism and Point2F then
        local outerSize = Point2F(prominent and 0.7 or 0.46, prominent and 0.7 or 0.46)
        local coreSize = Point2F(prominent and 0.22 or 0.14, prominent and 0.22 or 0.14)
        -- Unlike drawCylinder/drawLine, square prisms have filled faces. The
        -- active outer pair is exactly 30 m high and the bright inner pair is
        -- 6 m. Deliberately leave the two sides unconnected: a ground/cross bar
        -- tilts visibly when the road edges have different elevations.
        debugDrawer:drawSquarePrism(leftBottom, leftTop, outerSize, outerSize, glowColor)
        debugDrawer:drawSquarePrism(rightBottom, rightTop, outerSize, outerSize, glowColor)
        debugDrawer:drawSquarePrism(leftBottom, leftCoreTop, coreSize, coreSize, coreColor)
        debugDrawer:drawSquarePrism(rightBottom, rightCoreTop, coreSize, coreSize, coreColor)
      end

      if debugDrawer.drawTextAdvanced and String and ColorI then
        local labelPosition = vec3(marker.x, marker.y, marker.z + 4.5)
        local timing = marker.pbTime and string.format(" · PB %.3f", marker.pbTime) or ""
        local label = isFinish and "FINISH"
          or string.format("%s · %d ghosts%s", marker.name, marker.ghostCount, timing)
        debugDrawer:drawTextAdvanced(
          labelPosition,
          String(label),
          ColorF(1, 1, 1, prominent and 1 or 0.75),
          true,
          false,
          ColorI(10, 14, 18, 210)
        )
      end
      end
    end

    if routeGuide.enabled then
      if routeGuide.pathVisible then
        for index = 2, #routeGuide.path do
          local first = routeGuide.path[index - 1]
          local second = routeGuide.path[index]
          if staticSegmentVisible(
              first[1], first[2], second[1], second[2], cameraX, cameraY
            ) then
            drawFlatRibbon(
              first[1], first[2], first[3], second[1], second[2], second[3],
              0.24,
              0.055,
              first[4] and second[4] and routeRoadColor or routeFallbackColor
            )
          end
        end
      end

      if routeGuide.checkpointsVisible and debugDrawer.drawSquarePrism and Point2F then
        -- Checkpoints are drawn like the Start Line pillars: two clean light
        -- columns with a short bright core and no connecting cross bar (a ground
        -- bar tilts visibly when the two road edges differ in height). The next
        -- checkpoint to clear and the one after it rise to a tall 60 m beacon so
        -- the line ahead reads from a distance; the rest use the idle-start size.
        -- A missed checkpoint (driven around) is drawn red so a doomed lap shows.
        -- Idle checkpoints stay the slim Start Line pillar. The next and the
        -- following one are the tall 60 m beacons: much wider, brighter and more
        -- opaque so they read clearly from a distance, the target widest of all.
        local idleOuter = Point2F(0.46, 0.46)
        local idleCore = Point2F(0.14, 0.14)
        local targetOuter = Point2F(1.1, 1.1)
        local targetCore = Point2F(0.38, 0.38)
        local followOuter = Point2F(0.85, 0.85)
        local followCore = Point2F(0.3, 0.3)
        local TALL_HEIGHT = 60
        local nextIndex = routeGuide.nextCheckpoint or 1
        local missedIndex = routeGuide.missedCheckpoint or 0
        for index = 1, #routeGuide.checkpoints do
          local checkpoint = routeGuide.checkpoints[index]
          local ordinal = checkpoint.index or index
          local isMissed = missedIndex > 0 and ordinal == missedIndex
          local isNext = not isMissed and ordinal == nextIndex
          local isFollowing = ordinal == nextIndex + 1
          local isPassed = ordinal < nextIndex
          -- Colour: red if driven around, amber for the target, a bright cyan for
          -- the following beacon (distinct from the amber target and brighter than
          -- an idle checkpoint), green once cleared, road/fallback otherwise.
          local red, gre, blu
          if isMissed then
            red, gre, blu = 1, 0.22, 0.16
          elseif isNext then
            -- Bright vivid yellow so the immediate target is the most eye-catching
            -- beacon of all.
            red, gre, blu = 1, 0.95, 0.4
          elseif isFollowing then
            -- A vivid azure blue: clearly bluer than the greenish cyan of an idle
            -- road-matched checkpoint, and a cool contrast to the amber target.
            red, gre, blu = 0.2, 0.5, 1
          elseif isPassed then
            red, gre, blu = 0.35, 0.9, 0.5
          elseif checkpoint.matched then
            red, gre, blu = 0.31, 0.86, 1
          else
            red, gre, blu = 1, 0.6, 0.22
          end
          -- The target and missed pillars are the widest beacons; the following
          -- one is a touch slimmer so the immediate target still reads as nearest,
          -- but both are far bolder than an idle checkpoint.
          local prominent = isMissed or isNext
          local tall = prominent or isFollowing
          local outer = prominent and targetOuter or (isFollowing and followOuter or idleOuter)
          local core = prominent and targetCore or (isFollowing and followCore or idleCore)
          local outerHeight = tall and TALL_HEIGHT or 14
          local coreHeight = prominent and 14 or (isFollowing and 12 or 3)
          local baseOffset = tall and 0.2 or 0.09
          local glowColor = ColorF(red, gre, blu, tall and 0.34 or 0.1)
          local coreColor = ColorF(red, gre, blu, prominent and 0.95 or (isFollowing and 0.9 or 0.52))
          local leftBottom = vec3(checkpoint.leftX, checkpoint.leftY, checkpoint.leftZ + baseOffset)
          local rightBottom = vec3(checkpoint.rightX, checkpoint.rightY, checkpoint.rightZ + baseOffset)
          local leftTop = vec3(checkpoint.leftX, checkpoint.leftY, checkpoint.leftZ + outerHeight)
          local rightTop = vec3(checkpoint.rightX, checkpoint.rightY, checkpoint.rightZ + outerHeight)
          local leftCoreTop = vec3(checkpoint.leftX, checkpoint.leftY, checkpoint.leftZ + coreHeight)
          local rightCoreTop = vec3(checkpoint.rightX, checkpoint.rightY, checkpoint.rightZ + coreHeight)
          debugDrawer:drawSquarePrism(leftBottom, leftTop, outer, outer, glowColor)
          debugDrawer:drawSquarePrism(rightBottom, rightTop, outer, outer, glowColor)
          debugDrawer:drawSquarePrism(leftBottom, leftCoreTop, core, core, coreColor)
          debugDrawer:drawSquarePrism(rightBottom, rightCoreTop, core, core, coreColor)

          if debugDrawer.drawTextAdvanced and String and ColorI then
            local labelColor = ColorF(0.82, 0.96, 1, 0.96)
            if isMissed then
              labelColor = ColorF(1, 0.5, 0.42, 1)
            elseif isNext then
              labelColor = ColorF(1, 0.9, 0.4, 1)
            end
            debugDrawer:drawTextAdvanced(
              vec3(checkpoint.x, checkpoint.y, checkpoint.z + 3.8),
              String(string.format("CP %02d · %.0f m", ordinal, checkpoint.distance)),
              labelColor,
              true,
              false,
              ColorI(8, 18, 28, 205)
            )
          end
        end
      end
    end

    for index = 1, #bestLapLineSegments do
      local segment = bestLapLineSegments[index]
      if staticSegmentVisible(
          segment[1], segment[2], segment[4], segment[5], cameraX, cameraY
        ) then
        local clutchPiece = segment[8] == 1
        drawFlatRibbon(
          segment[1], segment[2], segment[3], segment[4], segment[5], segment[6],
          clutchPiece and 0.13 or 0.28,
          clutchPiece and 0.075 or 0.07,
          bestLapLineColors[segment[7]] or bestLapLineColors[#bestLapLineColors]
        )
      end
    end

    for index = 1, #liveInputTrailSegments do
      local segment = liveInputTrailSegments[index]
      if staticSegmentVisible(
          segment[1], segment[2], segment[4], segment[5], cameraX, cameraY
        ) then
        local subPiece = segment[8] == 1
        drawFlatRibbon(
          segment[1], segment[2], segment[3], segment[4], segment[5], segment[6],
          subPiece and 0.11 or 0.2,
          subPiece and 0.075 or 0.08,
          bestLapLineColors[segment[7]] or bestLapLineColors[#bestLapLineColors]
        )
      end
    end

    for index = 1, #ghostTrailSegments do
      local segment = ghostTrailSegments[index]
      if segment[8] then
        drawFlatRibbon(
          segment[1], segment[2], segment[3], segment[4], segment[5], segment[6],
          0.42,
          0.08,
          bestTrailHaloColor
        )
      end
      local palette = segment[8] and trailBestColors or trailRankColors[segment[9]]
      local subPiece = segment[10]
      drawFlatRibbon(
        segment[1], segment[2], segment[3], segment[4], segment[5], segment[6],
        subPiece and 0.1 or (segment[8] and 0.34 or 0.18),
        subPiece and 0.075 or (segment[8] and 0.085 or 0.065),
        palette[segment[7]] or palette[#palette]
      )
    end
  end


  function world.cleanup()
    removeMarkerObjects()
    markerConfig.markers = {}
    ghostTrailSegments = {}
    bestLapLineSegments = {}
    liveInputTrailSegments = {}
    routeGuide.enabled = false
    routeGuide.path = {}
    routeGuide.checkpoints = {}
    routeGuide.nextCheckpoint = 1
    routeGuide.missedCheckpoint = 0
  end

  function world.snapshot()
    return {
      markerCount = #markerConfig.markers,
      markerObjectsChecked = legacyMarkerObjectsChecked,
      ghostTrailSegmentCount = #ghostTrailSegments,
      bestLapSegmentCount = #bestLapLineSegments,
      liveInputTrailSegmentCount = #liveInputTrailSegments,
      routeEnabled = routeGuide.enabled,
      routePathVisible = routeGuide.pathVisible,
      routeCheckpointsVisible = routeGuide.checkpointsVisible,
      routePointCount = #routeGuide.path,
      routeCheckpointCount = #routeGuide.checkpoints,
      routeNextCheckpoint = routeGuide.nextCheckpoint
    }
  end

  return world
end

return M
