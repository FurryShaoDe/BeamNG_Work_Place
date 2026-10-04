-- LapLog -- start/finish gate beam renderer for the game-engine VM.
--
-- This is the only thing left of the upstream world renderer. It draws the pair of
-- light beams that mark where a lap starts, and the green pair that marks a
-- point-to-point finish, snapped to the ground. There are no Ghost bodies, no
-- trails, no racing line and no route ribbon.
--
-- Drawing goes through the engine's debugDrawer, which is what the upstream mod
-- used too, so the beams behave the same way across Ctrl+L / F5 reloads.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

-- One gate is two beams. A registry holds up to 20 starts plus a finish, so cap
-- the count instead of trusting whatever the vehicle VM sends.
local MAX_MARKERS = 21
local BEAM_HALF_WIDTH = 6.5

function M.new()
  local world = {}
  local config = { savedVisible = true, activeVisible = true }
  local markers = {}

  -- Ground snap. A gate on a banked or multi-level surface needs each beam foot on
  -- the actual ground rather than on the centre height, or one side floats.
  local function surfaceHeight(x, y, fallbackZ)
    if not be or not be.getSurfaceHeightBelow then return fallbackZ end
    local height = be:getSurfaceHeightBelow(vec3(x, y, fallbackZ + 3))
    if not height or height < -1e10 then return fallbackZ end
    return height
  end

  -- The finish gate is a live function of the active start, so it follows the
  -- same visibility toggle; every other marker follows the saved-starts toggle.
  local function isVisible(marker)
    if marker.active or marker.isFinish then return config.activeVisible end
    return config.savedVisible
  end

  function world.setMarkers(list, savedVisible, activeVisible)
    config.savedVisible = savedVisible ~= false
    config.activeVisible = activeVisible ~= false
    markers = {}
    local count = type(list) == "table" and #list or 0
    if count > MAX_MARKERS then count = MAX_MARKERS end

    for index = 1, count do
      local marker = list[index]
      local nx = tonumber(marker.nx) or 0
      local ny = tonumber(marker.ny) or 1
      local length = math.sqrt(nx * nx + ny * ny)
      if length > 0.001 then
        nx, ny = nx / length, ny / length
        local lateralX, lateralY = -ny, nx
        local x = tonumber(marker.x) or 0
        local y = tonumber(marker.y) or 0
        local z = tonumber(marker.z) or 0
        local leftX = x + lateralX * BEAM_HALF_WIDTH
        local leftY = y + lateralY * BEAM_HALF_WIDTH
        local rightX = x - lateralX * BEAM_HALF_WIDTH
        local rightY = y - lateralY * BEAM_HALF_WIDTH
        markers[#markers + 1] = {
          id = tostring(marker.id or index),
          name = tostring(marker.name or ("Start " .. index)),
          x = x,
          y = y,
          z = surfaceHeight(x, y, z),
          leftX = leftX,
          leftY = leftY,
          leftZ = surfaceHeight(leftX, leftY, z),
          rightX = rightX,
          rightY = rightY,
          rightZ = surfaceHeight(rightX, rightY, z),
          lapCount = math.max(
            0,
            tonumber(marker.lapCount) or tonumber(marker.ghostCount) or 0
          ),
          pbTime = tonumber(marker.pbTime),
          active = marker.active == true,
          isFinish = marker.isFinish == true
        }
      end
    end
    return #markers
  end

  function world.onPreRender()
    if not debugDrawer then return end
    local canPrism = debugDrawer.drawSquarePrism ~= nil and Point2F ~= nil
    local canText = debugDrawer.drawTextAdvanced ~= nil
      and String ~= nil and ColorI ~= nil

    for index = 1, #markers do
      local marker = markers[index]
      if isVisible(marker) then
        local prominent = marker.active or marker.isFinish
        local red, green, blue
        if marker.isFinish then
          red, green, blue = 0.2, 1, 0.45
        else
          red = prominent and 1 or 0.16
          green = prominent and 0.35 or 0.82
          blue = prominent and 0.05 or 1
        end

        if canPrism then
          -- Two nested pairs of square prisms: a wide translucent glow and a
          -- narrow bright core. The two sides are deliberately left unconnected,
          -- because a cross bar tilts visibly wherever the road edges differ.
          local outer = prominent and 0.7 or 0.46
          local core = prominent and 0.22 or 0.14
          local glow = ColorF(red, green, blue, prominent and 0.2 or 0.1)
          local coreColor = ColorF(red, green, blue, prominent and 0.82 or 0.52)
          local tallHeight = prominent and 30 or 14
          local coreHeight = prominent and 6 or 3
          local lift = prominent and 0.2 or 0.09

          local leftBottom = vec3(marker.leftX, marker.leftY, marker.leftZ + lift)
          local rightBottom = vec3(marker.rightX, marker.rightY, marker.rightZ + lift)
          local leftTop = vec3(marker.leftX, marker.leftY, marker.leftZ + tallHeight)
          local rightTop = vec3(marker.rightX, marker.rightY, marker.rightZ + tallHeight)
          local leftCore = vec3(marker.leftX, marker.leftY, marker.leftZ + coreHeight)
          local rightCore = vec3(marker.rightX, marker.rightY, marker.rightZ + coreHeight)

          debugDrawer:drawSquarePrism(
            leftBottom, leftTop, Point2F(outer, outer), Point2F(outer, outer), glow
          )
          debugDrawer:drawSquarePrism(
            rightBottom, rightTop, Point2F(outer, outer), Point2F(outer, outer), glow
          )
          debugDrawer:drawSquarePrism(
            leftBottom, leftCore, Point2F(core, core), Point2F(core, core), coreColor
          )
          debugDrawer:drawSquarePrism(
            rightBottom, rightCore, Point2F(core, core), Point2F(core, core), coreColor
          )
        end

        if canText then
          local label
          if marker.isFinish then
            label = "FINISH"
          else
            local timing = marker.pbTime and string.format("  PB %.3f", marker.pbTime) or ""
            label = string.format("%s  %d laps%s", marker.name, marker.lapCount, timing)
          end
          local ok, errorMessage = pcall(
            debugDrawer.drawTextAdvanced,
            debugDrawer,
            vec3(marker.x, marker.y, marker.z + 4.5),
            String(label),
            ColorF(1, 1, 1, prominent and 1 or 0.75),
            true,
            false,
            ColorI(10, 14, 18, 210)
          )
          -- A label must never take the whole pre-render pass down with it.
          if not ok and type(log) == "function" then
            log("W", "LapLogDiag.GE", "[marker.label] drawTextAdvanced failed: "
              .. tostring(errorMessage))
          end
        end
      end
    end
  end

  function world.clear()
    markers = {}
  end

  function world.snapshot()
    return { markerCount = #markers }
  end

  return world
end

return M
