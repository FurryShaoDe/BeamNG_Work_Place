-- Custom mission script for 001-ssrbDrag (loaded by missionManager from <missionFolder>/script.lua).
-- Draws in-world guides for the lane zones, which are pure logic polygons and otherwise invisible.
-- Purely cosmetic: removing this file only removes the lines, the race keeps working.

local C = {}

local zLift = 0.06          -- keep the lines just above the road surface
local centerWidth = 0.35
local edgeWidth = 0.2
local crossWidth = 0.8
local lineAlpha = 0.55
local loggedOnce = false

local colorByName = {
  blue = { 0.15, 0.55, 1.0 },
  red = { 1.0, 0.4, 0.2 },
  green = { 0.2, 0.9, 0.35 },
  white = { 1, 1, 1 },
  black = { 0.1, 0.1, 0.1 },
}

local function zoneBounds(zone)
  if not zone or not zone.vertices or #zone.vertices < 3 then return nil end
  local xmin, xmax, ymin, ymax, z = math.huge, -math.huge, math.huge, -math.huge, nil
  for i = 1, #zone.vertices do
    local p = zone.vertices[i].pos
    if p then
      xmin = math.min(xmin, p.x)
      xmax = math.max(xmax, p.x)
      ymin = math.min(ymin, p.y)
      ymax = math.max(ymax, p.y)
      if not z then z = p.z end
    end
  end
  if xmin == math.huge then return nil end
  return xmin, xmax, ymin, ymax, z or 0
end

local wideLineWorks = nil

local function drawWideLine(p1, p2, width, color)
  if wideLineWorks == false then return end
  local ok = pcall(function()
    debugDrawer:drawLineInstance(p1, p2, width, color, false)
  end)
  if wideLineWorks == nil then
    wideLineWorks = ok
    if not ok then
      log("W", "dragstrip_guides", "drawLineInstance failed, falling back to 1px drawLine")
    else
      log("I", "dragstrip_guides", "drawLineInstance ok")
    end
  end
end

local function drawThinLine(p1, p2, color)
  pcall(function()
    debugDrawer:drawLine(p1, p2, color)
  end)
end

local function drawGuideLine(p1, p2, width, color)
  drawWideLine(p1, p2, width, color)
  drawThinLine(p1, p2, color)
end

local function drawLane(lane)
  local xmin, xmax, ymin, ymax, z = zoneBounds(lane.zone)
  if not xmin then return end

  local rgb = colorByName[lane.color] or colorByName.white
  local laneColor = ColorF(rgb[1], rgb[2], rgb[3], lineAlpha)
  local white = ColorF(1, 1, 1, 0.85)
  local zz = z + zLift

  -- driving line: use the actual lane waypoint x, not the zone centre (the zone is asymmetric on purpose)
  local wps = lane.waypoints
  local cx = (xmin + xmax) * 0.5
  if wps and wps.stage and wps.stage.transform then
    cx = wps.stage.transform.position.x
  end

  -- lane center line, from the zone start to the zone end
  drawGuideLine(vec3(cx, ymin, zz), vec3(cx, ymax, zz), centerWidth, laneColor)

  -- inner edge (the one shared with the other lane) and outer edge
  drawGuideLine(vec3(xmin, ymin, zz), vec3(xmin, ymax, zz), edgeWidth, laneColor)
  drawGuideLine(vec3(xmax, ymin, zz), vec3(xmax, ymax, zz), edgeWidth, laneColor)

  local stage = wps and wps.stage
  if stage and stage.transform then
    local p = stage.transform.position
    drawGuideLine(vec3(xmin, p.y, p.z + zLift), vec3(xmax, p.y, p.z + zLift), crossWidth, white)
  end

  local endLine = wps and wps.endLine
  if endLine and endLine.transform then
    local p = endLine.transform.position
    drawGuideLine(vec3(xmin, p.y, p.z + zLift), vec3(xmax, p.y, p.z + zLift), crossWidth, white)
  end
end

-- AI helpers ----------------------------------------------------------------
-- The stock stop phase sets the AI speed mode to "off" and targets a far-away graph node,
-- so the AI keeps running at full speed after the finish line. We brake it ourselves and
-- nudge it back on line when it wanders during the race.

local aiBrakeInterval = 0.2      -- seconds between brake commands once the AI finished
local aiRetargetInterval = 1.0   -- minimum seconds between forced retargets
local aiMaxOffset = 2.5          -- metres of lateral drift before forcing a retarget
local brakeTimer = 0
local retargetTimer = 0

local function laneDrivingX(lane)
  local wps = lane and lane.waypoints
  if wps and wps.stage and wps.stage.transform then
    return wps.stage.transform.position.x
  end
  local xmin, xmax = zoneBounds(lane and lane.zone)
  if xmin then return (xmin + xmax) * 0.5 end
  return nil
end

local function updateAiRacer(racer, lane, dtSim)
  if not racer or racer.isPlayable ~= false then return end
  if racer.vehicleRemoved or not racer.vehId or racer.vehId <= 0 then return end
  local veh = scenetree.findObjectById(racer.vehId)
  if not veh then return end

  if racer.isFinished or racer.currentPhase == 4 then
    brakeTimer = brakeTimer + dtSim
    if brakeTimer >= aiBrakeInterval then
      brakeTimer = 0
      veh:queueLuaCommand('ai.setSpeedMode("set")')
      veh:queueLuaCommand('ai.setSpeed(0)')
      veh:queueLuaCommand('ai:scriptStop(true, true)')
    end
    return
  end

  local targetX = laneDrivingX(lane)
  if not targetX then return end
  local ok, pos = pcall(function() return veh:getPosition() end)
  if not ok or not pos then return end

  retargetTimer = retargetTimer + dtSim
  if math.abs(pos.x - targetX) > aiMaxOffset and retargetTimer >= aiRetargetInterval then
    retargetTimer = 0
    local wps = lane and lane.waypoints
    local targetName = wps and wps.endLine and wps.endLine.name
    if targetName then
      veh:queueLuaCommand('ai.setTarget("' .. targetName .. '")')
    end
  end
end

-- Dial table hygiene ---------------------------------------------------------
-- saveDialTimes() stores the *important* timer into time_1_4 (saveSystem.lua:469-484).
-- Our important timer is the 1000 m one, so finishing a race writes a ~30 s value as
-- a quarter mile, and the next opponent is then picked among slow trucks
-- (generateDragOpponents.lua:157-187). Snapshot the player's entry when the mission
-- starts and put the quarter-mile fields back after the finish.

local DIAL_FILE = "settings/dragDialTimes.json"
local dialSnapshot = nil
local dialRestoreTimer = nil

local function playerDialKey()
  local bridge = gameplay_drag_dragBridge
  if not bridge or not bridge.generateHashFromFile or not be then return nil end
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId <= 0 then return nil end
  local ok, key = pcall(bridge.generateHashFromFile, vehId)
  if ok then return key end
  return nil
end

local function readDialFile()
  local ok, data = pcall(jsonReadFile, DIAL_FILE)
  if ok and type(data) == "table" then return data end
  return nil
end

local dialSnapshotDone = false

-- Called on the first frame where drag data exists, i.e. after the flow has spawned
-- the racers and the player vehicle id is valid.
local function takeDialSnapshot()
  if dialSnapshotDone then return end
  dialSnapshotDone = true

  local key = playerDialKey()
  if not key then
    log("W", "dragstrip_guides", "no player vehicle id yet, dial table left alone")
    return
  end
  local data = readDialFile()
  if not data then return end

  -- heal entries written by an earlier run: a stored 1000 m timer can only come from us
  local entry = data[key]
  if entry and entry.time_1000m ~= nil then
    entry.time_1_4 = nil
    entry.time_1000m = nil
    pcall(jsonWriteFile, DIAL_FILE, data, true)
    log("I", "dragstrip_guides", "cleared a stale 1000 m dial entry")
    entry = data[key]
  end

  dialSnapshot = {
    key = key,
    hadEntry = entry ~= nil,
    time_1_4 = entry and entry.time_1_4,
    time_1000m = entry and entry.time_1000m,
  }
end

function C:onStart()
  dialSnapshot = nil
  dialSnapshotDone = false
  dialRestoreTimer = nil
end

local function restoreDialTable()
  if not dialSnapshot then return end
  local snap = dialSnapshot
  dialSnapshot = nil

  local data = readDialFile()
  if not data then return end
  local entry = data[snap.key]
  if entry then
    entry.time_1_4 = snap.time_1_4
    entry.time_1000m = snap.time_1000m
    if not snap.hadEntry and not entry.history then data[snap.key] = nil end
    pcall(jsonWriteFile, DIAL_FILE, data, true)
    log("I", "dragstrip_guides", "restored quarter-mile dial entry")
  end
end

function C:onUpdate(dtReal, dtSim, dtRaw)
  local core = gameplay_drag_core
  if not core then return end
  local data = core.getData()
  if not data or not data.strip or not data.strip.lanes then return end

  for _, lane in ipairs(data.strip.lanes) do
    drawLane(lane)
  end

  if data.racers then
    takeDialSnapshot()

    for _, racer in pairs(data.racers) do
      local lane = racer.lane and data.strip.lanes[racer.lane]
      if lane then
        updateAiRacer(racer, lane, dtSim)
      end
    end

    if dialSnapshot and not dialRestoreTimer then
      for _, racer in pairs(data.racers) do
        if racer.isPlayable and (racer.isFinished or racer.currentPhase == 4) then
          dialRestoreTimer = 0.8 -- let saveDialTimes() run first
          break
        end
      end
    end
  end

  if dialRestoreTimer then
    dialRestoreTimer = dialRestoreTimer - dtSim
    if dialRestoreTimer <= 0 then
      dialRestoreTimer = nil
      restoreDialTable()
    end
  end

  if not loggedOnce then
    loggedOnce = true
    log("I", "dragstrip_guides", "lane guide lines active")
  end
end

function C:onStop()
  dialRestoreTimer = nil
  restoreDialTable()
  dialSnapshotDone = false
  loggedOnce = false
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  if o.init then
    o:init(...)
  end
  return o
end
