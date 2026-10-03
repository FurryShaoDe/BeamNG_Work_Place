-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Vehicle-side Ghost wireframe renderer. Mutable caches belong to one
-- renderer instance and are never shared between controller runtimes.

local M = {}
local qualityStrides = {16, 12, 9, 7, 5, 4, 3, 2, 2, 1}

local function clear(target)
  for key in pairs(target) do target[key] = nil end
end

function M.new(options)
  options = options or {}
  local poseMath = assert(options.poseMath, "poseMath is required")
  local vectorFactory = assert(options.vectorFactory, "vectorFactory is required")
  local rotationFromDirection = assert(
    options.rotationFromDirection,
    "rotationFromDirection is required"
  )
  local tableSize = assert(options.tableSize, "tableSize is required")
  local timeIndex = assert(options.timeIndex, "timeIndex is required")
  local clamp = assert(options.clamp, "clamp is required")

  local renderer = {}
  local currentQuality = 6
  local vehicleObject
  local allStructuralBeams = {}
  local renderBeams = {}
  local renderNodeIds = {}
  local relativeNodePositions = {}
  local nodeRenderPositions = {}
  local renderPose = poseMath.newBuffer()
  local rotatedNode = vectorFactory()
  local worldNode = vectorFactory()

  local function rebuildRenderCache()
    clear(renderBeams)
    clear(renderNodeIds)
    local stride = qualityStrides[currentQuality] or 1
    local usedNodes = {}
    for index = 1, #allStructuralBeams, stride do
      local beam = allStructuralBeams[index]
      renderBeams[#renderBeams + 1] = beam
      if not usedNodes[beam[1]] then
        usedNodes[beam[1]] = true
        renderNodeIds[#renderNodeIds + 1] = beam[1]
      end
      if not usedNodes[beam[2]] then
        usedNodes[beam[2]] = true
        renderNodeIds[#renderNodeIds + 1] = beam[2]
      end
    end
  end

  function renderer.setQuality(value)
    currentQuality = clamp(math.floor(tonumber(value) or currentQuality), 1, 10)
    rebuildRenderCache()
    return currentQuality
  end

  function renderer.init(vehicleData, object)
    local beams = vehicleData.beams or {}
    local nodes = vehicleData.nodes or {}
    local refNodeData = vehicleData.refNodes and vehicleData.refNodes[0]
    if not refNodeData then return false end

    local referencePosition = nodes[refNodeData.ref].pos
    vehicleObject = object
    clear(allStructuralBeams)
    clear(relativeNodePositions)
    clear(nodeRenderPositions)

    local beamCount = tableSize(beams)
    for index = 0, beamCount - 1 do
      local beam = beams[index]
      if beam and beam.beamType == 0 then
        allStructuralBeams[#allStructuralBeams + 1] = {beam.id1, beam.id2}
      end
    end

    local nodeCount = tableSize(nodes)
    for index = 0, nodeCount - 1 do
      if nodes[index] then
        relativeNodePositions[index] = nodes[index].pos - referencePosition
        nodeRenderPositions[index] = vectorFactory()
      end
    end

    rebuildRenderCache()
    return true
  end

  function renderer.drawSamples(points, cursor, playbackElapsed, lineColor)
    if type(points) ~= "table" or #points < 2 or not vehicleObject then return cursor end
    cursor = clamp(tonumber(cursor) or 1, 1, math.max(1, #points - 1))
    while cursor < #points - 1 and points[cursor + 1][timeIndex] <= playbackElapsed do
      cursor = cursor + 1
    end

    local first = points[cursor]
    local second = points[math.min(cursor + 1, #points)]
    local span = math.max(
      (second[timeIndex] or 0) - (first[timeIndex] or 0),
      0.000001
    )
    local amount = clamp((playbackElapsed - (first[timeIndex] or 0)) / span, 0, 1)
    poseMath.interpolate(renderPose, first, second, amount)

    local rotation = rotationFromDirection(renderPose.negativeFront, renderPose.up)
    for index = 1, #renderNodeIds do
      local nodeId = renderNodeIds[index]
      rotatedNode:set(relativeNodePositions[nodeId])
      rotatedNode:setRotate(rotation)
      worldNode:setAdd2(renderPose.position, rotatedNode)
      nodeRenderPositions[nodeId]:set(worldNode)
    end

    for index = 1, #renderBeams do
      local beam = renderBeams[index]
      vehicleObject.debugDrawProxy:drawLine(
        nodeRenderPositions[beam[1]],
        nodeRenderPositions[beam[2]],
        lineColor
      )
    end
    return cursor
  end

  return renderer
end

return M
