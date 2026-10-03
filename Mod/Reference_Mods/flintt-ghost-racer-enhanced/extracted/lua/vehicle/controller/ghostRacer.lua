-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file, You can obtain
-- one at http://beamng.com/bCDDL-1.1.txt.
--
-- Original Ghost Racer Replay by Jesus Goose.
-- Performance, telemetry, and interaction modifications by flintt, 2026.

local M = {}
M.type = "auxiliary"

local CODE_VERSION = "2.19.8"
-- BeamNG can reload an external controller without invalidating package.loaded
-- in that Vehicle VM. Clear only this mod's extracted submodules before the
-- first require so Ctrl+L/F5 cannot combine a new controller with an older
-- displayState/uiStateBuilder implementation.
local vehicleSubmodules = {
  "vehicle/ghostRacer/displayState",
  "vehicle/ghostRacer/playbackState",
  "vehicle/ghostRacer/pose",
  "vehicle/ghostRacer/progressMatcher",
  "vehicle/ghostRacer/recordingState",
  "vehicle/ghostRacer/replayCodec",
  "vehicle/ghostRacer/routeGuide",
  "vehicle/ghostRacer/runtimeContext",
  "vehicle/ghostRacer/sessionCoordinator",
  "vehicle/ghostRacer/sessionState",
  "vehicle/ghostRacer/shareCodec",
  "vehicle/ghostRacer/shellSync",
  "vehicle/ghostRacer/shareManager",
  "vehicle/ghostRacer/startRegistry",
  "vehicle/ghostRacer/startState",
  "vehicle/ghostRacer/trailRenderer",
  "vehicle/ghostRacer/uiRuntimeState",
  "vehicle/ghostRacer/uiStateBuilder",
  "vehicle/ghostRacer/wireframeRenderer"
}
local clearedVehicleSubmodules = 0
if package and type(package.loaded) == "table" then
  for index = 1, #vehicleSubmodules do
    local moduleName = vehicleSubmodules[index]
    if package.loaded[moduleName] ~= nil then
      package.loaded[moduleName] = nil
      clearedVehicleSubmodules = clearedVehicleSubmodules + 1
    end
  end
end
-- 3 adds optional per-sample driver pedal inputs (throttle/brake). Older format-2
-- replays load unchanged; they simply carry no input data.
local FORMAT_VERSION = 3
local GHOST_LIBRARY_FORMAT_VERSION = 1
local MAX_STORED_GHOSTS = 20
local MAX_STORED_INCOMPLETE_GHOSTS = 20
local MAX_STORED_MANUAL_GHOSTS = 20
-- The vehicle shell instantiates real meshes, so it stays deliberately small.
-- It is only offered for the display modes that show a bounded set of Ghosts.
-- Mirrors the GE clipboard limit so an oversized share is refused before the
-- full encode and VM round trip.
local GHOST_SHARE_MAX_BYTES = 16 * 1024 * 1024
-- Which display modes may use native bodies at all. Top 5/10 are excluded
-- because their whole set would have to be considered.
local MAX_SHELL_GHOSTS = 10
-- How many Ghost bodies may be rendered at once. The default backend is the
-- cheap TSStatic static mesh (non-physics), so this is no longer a per-vehicle
-- simulation budget -- it is a hard ceiling sized to a full rotation of every
-- category, so "all" mode normally renders every displayed Ghost as a body
-- rather than shelling the first few and leaving the rest as wireframe (a mix
-- reads as inconsistent). Pinned ghosts are protected extra slots, so a library
-- deliberately pinned past this many bodies exceeds the ceiling; the overflow
-- then falls back to wireframe rather than lifting the perf cap -- a rare case,
-- since pinning is manual. MAX_SHELL_GHOSTS above stays the separate Top-N gate.
local MAX_SHELL_BODIES =
  MAX_STORED_GHOSTS + MAX_STORED_INCOMPLETE_GHOSTS + MAX_STORED_MANUAL_GHOSTS
local SHELL_DISPLAY_MODES = {best = true, single = true, top = true, all = true, multi = true}
local DEFAULT_SAMPLE_RATE = 50
local MIN_SAMPLE_RATE = 20
local MAX_SAMPLE_RATE = 100
local MAX_RECORDING_SECONDS = 30 * 60
local UI_UPDATE_INTERVAL = 0.1
local MAX_MATCH_DISTANCE_SQUARED = 50 * 50
local AUTO_LINE_HALF_WIDTH = 15
local AUTO_LINE_MAX_VERTICAL = 4
-- The start gate is an infinite plane, so a lap on a track that doubles back
-- across that plane far from the gate crosses it in a place that is not a finish
-- attempt at all. Only treat an off-gate crossing as a "missed finish" (which
-- invalidates the lap) when it is close enough to the pillars to have been an
-- attempt; a crossing beyond these bands is ignored so the lap is not cancelled.
local AUTO_LINE_MAX_LATERAL_MISS = 30
local AUTO_LINE_MAX_VERTICAL_MISS = 12
local AUTO_LINE_BASE_MAX_SEGMENT = 35
local AUTO_LINE_MAX_DYNAMIC_SEGMENT = 500
local AUTO_LINE_MIN_FORWARD_SPEED = 0.75
local AUTO_LINE_HYSTERESIS = 0.2
local AUTO_LAP_MIN_SECONDS = 5
local AUTO_LAP_COOLDOWN = 2
local DEFAULT_GHOST_TRAIL_SECONDS = 3
local MIN_GHOST_TRAIL_SECONDS = 1
local MAX_GHOST_TRAIL_SECONDS = 5
local GHOST_TRAIL_INTERVAL = 0.1
-- Debug live input trail: how often the car's own pose+inputs are captured while
-- the toggle is on, and the rolling-buffer point cap.
local LIVE_TRAIL_CAPTURE_INTERVAL = 0.1
local MAX_LIVE_TRAIL_POINTS = 4000
local GHOST_TRAIL_SYNC_INTERVAL = 0.1
local startGateConfig = require("vehicle/ghostRacer/startState").new()

function startGateConfig.getObjectId()
  if startGateConfig.objectId ~= nil then return startGateConfig.objectId end
  local getter = obj and (obj.getID or obj.getId)
  if type(getter) == "function" then
    local ok, value = pcall(getter, obj)
    if ok and value ~= nil then startGateConfig.objectId = tostring(value) end
  end
  startGateConfig.objectId = startGateConfig.objectId or "unknown"
  return startGateConfig.objectId
end

-- Start Line pillars, trails, route guides and the shell bridge are all GE
-- state that belongs to the player's vehicle, but a native Ghost vehicle is a
-- real BeamNGVehicle with its own Lua VM. If one of them loads this controller
-- its empty state overwrites the player's, which is what makes the pillars and
-- the trail vanish. Stamping the sender lets GE drop those pushes.
--
-- An unresolved id sends nil, which GE accepts: a build where the object id
-- cannot be read keeps behaving exactly as it did before.
function startGateConfig.senderLiteral()
  local id = startGateConfig.getObjectId()
  if id == nil or id == "unknown" then return "nil" end
  return string.format("%q", id)
end

function startGateConfig.registrySummary(registry)
  if type(registry) ~= "table" then return "<nil>" end
  local entries = {}
  for index = 1, #(registry.lines or {}) do
    local line = registry.lines[index]
    entries[#entries + 1] = string.format(
      "%s=%q(userNamed=%s,kind=%s)",
      tostring(line.id),
      tostring(line.name),
      tostring(line.userNamed == true),
      tostring(line.kind or "manual")
    )
  end
  return string.format(
    "format=%s revision=%s active=%s lines=[%s]",
    tostring(registry.formatVersion),
    tostring(registry.revision),
    tostring(registry.activeId),
    table.concat(entries, "; ")
  )
end

function startGateConfig.trace(area, formatString, ...)
  if type(log) ~= "function" then return end
  local ok, message = pcall(string.format, tostring(formatString), ...)
  if not ok then message = tostring(formatString) .. " [format-error=" .. tostring(message) .. "]" end
  log("I", "GhostRacerDiag.VE", string.format(
    "[v%s][%s][vehicle=%s][object=%s][ui=%s][trace=%s] %s",
    CODE_VERSION,
    tostring(area or "general"),
    tostring(v and v.data and v.data.vehicleDirectory or "unknown_vehicle"),
    startGateConfig.getObjectId(),
    tostring(startGateConfig.uiOwnerToken or "unclaimed"),
    tostring(startGateConfig.diagnosticTraceId or "none"),
    tostring(message)
  ))
end

startGateConfig.trace(
  "module.cache", "clearedVehicleSubmodules=%d", clearedVehicleSubmodules
)

-- Compact sample layout. Numeric arrays are substantially smaller and cheaper
-- to serialize than a table containing three vec3 objects per sample.
local TIME = 1
local POS_X, POS_Y, POS_Z = 2, 3, 4
local FRONT_X, FRONT_Y, FRONT_Z = 5, 6, 7
local UP_X, UP_Y, UP_Z = 8, 9, 10
local SPEED = 11
-- Driver inputs, added in the 2.18 recording format. Older ghosts have no values
-- here (their sample arrays stop at SPEED), so the input colour mode falls back
-- to inferred acceleration for them. GEAR is the numeric gear index (used to mark
-- shift points); HANDBRAKE is the parking/hand brake (0..1); CLUTCH (0..1) drives
-- the optional parallel clutch sub-line.
local THROTTLE, BRAKE, GEAR, HANDBRAKE, CLUTCH = 12, 13, 14, 15, 16

local replayCodec = require("vehicle/ghostRacer/replayCodec").new({
  formatVersion = FORMAT_VERSION,
  vectorFactory = vec3,
  indexes = {
    time = TIME,
    posX = POS_X, posY = POS_Y, posZ = POS_Z,
    frontX = FRONT_X, frontY = FRONT_Y, frontZ = FRONT_Z,
    upX = UP_X, upY = UP_Y, upZ = UP_Z,
    speed = SPEED,
    throttle = THROTTLE, brake = BRAKE, gear = GEAR, handbrake = HANDBRAKE, clutch = CLUTCH
  }
})
local poseMath = require("vehicle/ghostRacer/pose").new({
  vectorFactory = vec3,
  indexes = {
    posX = POS_X, posY = POS_Y, posZ = POS_Z,
    frontX = FRONT_X, frontY = FRONT_Y, frontZ = FRONT_Z,
    upX = UP_X, upY = UP_Y, upZ = UP_Z
  }
})
local shareCodec = require("vehicle/ghostRacer/shareCodec").new({
  shareRate = 20,
  maximumSeconds = MAX_RECORDING_SECONDS,
  maximumGhosts = 5,
  indexes = {
    time = TIME,
    posX = POS_X, posY = POS_Y, posZ = POS_Z,
    frontX = FRONT_X, frontY = FRONT_Y, frontZ = FRONT_Z,
    upX = UP_X, upY = UP_Y, upZ = UP_Z,
    speed = SPEED,
    throttle = THROTTLE, brake = BRAKE, gear = GEAR, handbrake = HANDBRAKE, clutch = CLUTCH
  }
})

local colorPresets = {
  orange = {255, 112, 24, 230},
  cyan = {40, 210, 255, 230},
  green = {72, 235, 126, 230},
  magenta = {235, 80, 255, 230},
  white = {245, 245, 245, 220}
}
local colorOrder = {"orange", "cyan", "green", "magenta", "white"}
local validDisplayModes = {best = true, top = true, single = true, multi = true, all = true}
local displayState = require("vehicle/ghostRacer/displayState").new({
  colorFactory = color,
  defaultColor = colorPresets.orange,
  validDisplayModes = validDisplayModes,
  validTopCounts = {[2] = true, [3] = true, [5] = true, [10] = true},
  clamp = function(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
  end,
  defaultTrailSeconds = DEFAULT_GHOST_TRAIL_SECONDS,
  minimumTrailSeconds = MIN_GHOST_TRAIL_SECONDS,
  maximumTrailSeconds = MAX_GHOST_TRAIL_SECONDS
})
-- Defensive migration for a VM where a third-party loader bypasses standard
-- package.loaded semantics. The current module already exposes both members;
-- this path makes an older cached Display domain safe instead of crashing.
if displayState.showIncomplete == nil then displayState.showIncomplete = false end
if displayState.ghostCategoryFilter == nil then
  displayState.ghostCategoryFilter = displayState.showIncomplete and "both" or "complete"
end
if type(displayState.setShowIncomplete) ~= "function" then
  function displayState.setShowIncomplete(value)
    displayState.ghostCategoryFilter = (value == true) and "both" or "complete"
    displayState.showIncomplete = value == true
    return displayState.showIncomplete
  end
end
if type(displayState.setGhostCategoryFilter) ~= "function" then
  function displayState.setGhostCategoryFilter(value)
    value = tostring(value or "")
    if value ~= "complete" and value ~= "incomplete" and value ~= "both" then return false end
    displayState.ghostCategoryFilter = value
    displayState.showIncomplete = value ~= "complete"
    return true
  end
end
if displayState.ghostRenderMode == nil then displayState.ghostRenderMode = "wireframe" end
if type(displayState.setGhostRenderMode) ~= "function" then
  function displayState.setGhostRenderMode(mode)
    mode = tostring(mode or "")
    if mode ~= "wireframe" and mode ~= "shell" then return false end
    displayState.ghostRenderMode = mode
    return true
  end
end
if displayState.showManual == nil then displayState.showManual = true end
if type(displayState.setShowManual) ~= "function" then
  function displayState.setShowManual(value)
    displayState.showManual = value ~= false
    return displayState.showManual
  end
end

local recordingState = require("vehicle/ghostRacer/recordingState").new({
  defaultSampleRate = DEFAULT_SAMPLE_RATE,
  minimumSampleRate = MIN_SAMPLE_RATE,
  maximumSampleRate = MAX_SAMPLE_RATE,
  maximumRecordingSeconds = MAX_RECORDING_SECONDS
})
local playbackState = require("vehicle/ghostRacer/playbackState").new()
local sessionState = require("vehicle/ghostRacer/sessionState").new()
local uiRuntimeState = require("vehicle/ghostRacer/uiRuntimeState").new({
  initialTrailSyncAccumulator = GHOST_TRAIL_SYNC_INTERVAL
})

-- Every mutable gameplay/presentation domain is instance-owned by this context.
local runtimeState = {
  recording = recordingState,
  playback = playbackState,
  session = sessionState,
  starts = startGateConfig,
  display = displayState,
  ui = uiRuntimeState
}
local runtimeContext = require("vehicle/ghostRacer/runtimeContext").new({
  codeVersion = CODE_VERSION,
  runtime = {
    object = obj,
    vehicleData = v and v.data or nil,
    objectId = startGateConfig.getObjectId(),
    vehicleDirectory = v and v.data and v.data.vehicleDirectory or "unknown_vehicle"
  },
  state = runtimeState
})
runtimeContext:activate("controller module loaded")
runtimeContext:registerService("replayCodec", replayCodec)
runtimeContext:registerService("poseMath", poseMath)
runtimeContext:registerService("shareCodec", shareCodec)
local sessionCoordinator = require("vehicle/ghostRacer/sessionCoordinator").new({
  session = sessionState,
  recording = recordingState,
  playback = playbackState,
  acceptedCrossingCooldown = AUTO_LAP_COOLDOWN
})
runtimeContext:registerService("sessionCoordinator", sessionCoordinator)

-- These three public arrays are a frozen external compatibility surface. They
-- intentionally mirror their context-owned buffers and are not state owners.
M.recordPoints = recordingState.points
M.ghostPB = playbackState.points
M.ghostPoints = playbackState.points

local cameraPose = poseMath.newBuffer()
local groundRay = {origin = vec3(), direction = vec3()}
groundRay.direction.x, groundRay.direction.y, groundRay.direction.z = 0, 0, -1

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local wireframeRenderer = require("vehicle/ghostRacer/wireframeRenderer").new({
  poseMath = poseMath,
  vectorFactory = vec3,
  rotationFromDirection = quatFromDir,
  tableSize = tableSizeC,
  timeIndex = TIME,
  clamp = clamp
})
runtimeContext:registerService("wireframeRenderer", wireframeRenderer)

local function sanitizePathPart(value, fallback)
  value = tostring(value or fallback or "unknown")
  value = value:gsub("[^%w%._%-]", "_")
  value = value:gsub("_+", "_")
  if value == "" then return fallback or "unknown" end
  return value
end

local function setPublicRecordPoints(points)
  recordingState.setPoints(points)
  M.recordPoints = points
end

local function setPublicPlaybackPoints(points)
  playbackState.setPoints(points)
  M.ghostPB = points
  M.ghostPoints = points
end

local function queueGeGhostTrail(encodedSegments, enabled)
  if not obj.queueGameEngineLua then return end
  obj:queueGameEngineLua(
    "if extensions and extensions.ghostlapping and " ..
      "extensions.ghostlapping.setGhostTrailSegments then " ..
      "extensions.ghostlapping.setGhostTrailSegments({" ..
      table.concat(encodedSegments or {}, ",") .. "}," ..
      tostring(enabled == true) .. "," .. startGateConfig.senderLiteral() .. ") end"
  )
  uiRuntimeState.geTrailVisible = enabled == true
end

local function clearGeGhostTrail(force)
  if not force and not uiRuntimeState.geTrailVisible then return end
  queueGeGhostTrail({}, false)
end

function startGateConfig.queueGeGhostCamera(pose, enabled, targetId, targetLabel)
  if not obj.queueGameEngineLua then return end
  local encodedPose = "{}"
  if enabled and type(pose) == "table" then
    encodedPose = string.format(
      "{%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g}",
      pose[1], pose[2], pose[3], pose[4], pose[5], pose[6],
      pose[7], pose[8], pose[9]
    )
  end
  obj:queueGameEngineLua(
    "if extensions and extensions.ghostlapping and " ..
      "extensions.ghostlapping.setGhostCameraPose then " ..
      "extensions.ghostlapping.setGhostCameraPose(" .. encodedPose .. "," ..
      tostring(enabled == true) .. "," .. string.format("%q", playbackState.cameraMode) .. "," ..
      (targetId and string.format("%q", tostring(targetId)) or "nil") .. "," ..
      (targetLabel and string.format("%q", tostring(targetLabel)) or "nil") .. "," ..
      startGateConfig.senderLiteral() .. ") end"
  )
  playbackState.geCameraActive = enabled == true
end

function startGateConfig.disableGhostCamera(message)
  local wasEnabled = playbackState.disableCamera()
  if wasEnabled then startGateConfig.queueGeGhostCamera(nil, false) end
  if message then uiRuntimeState.lastMessage = message end
end

local function notify(message, seconds)
  uiRuntimeState.lastMessage = message
  if guihooks and guihooks.message then
    guihooks.message({txt = message}, seconds or 3)
  end
end
runtimeContext:registerService("notify", notify)

-- Some events (pressing R to reset) tear down and rebuild the vehicle's on-screen
-- UI as part of the reset, wiping any toast fired from this vehicle VM mid-reset.
-- Forward the toast to the GE VM instead: it renders on the next GE frame, after
-- the reset has settled, so the message actually reaches the player. Used for the
-- reset verdict; ordinary notify() toasts render fine in place.
local function notifyViaGe(message, seconds)
  uiRuntimeState.lastMessage = message
  if not obj.queueGameEngineLua then
    if guihooks and guihooks.message then guihooks.message({txt = message}, seconds or 3) end
    return
  end
  obj:queueGameEngineLua(
    "if extensions and extensions.ghostlapping and " ..
      "extensions.ghostlapping.showGhostMessage then " ..
      "extensions.ghostlapping.showGhostMessage(" ..
      string.format("%q", tostring(message)) .. "," ..
      tostring(tonumber(seconds) or 3) .. "," ..
      startGateConfig.senderLiteral() .. ") end"
  )
end

local function lapResultNotice(lapTime, rank, recordCount, stored, isBest)
  local totalSeconds = math.max(0, tonumber(lapTime) or 0)
  local minutes = math.floor(totalSeconds / 60)
  local remainder = totalSeconds - minutes * 60
  local formattedTime = minutes > 0
    and string.format("%d:%06.3f", minutes, remainder)
    or string.format("%.3f", remainder)
  local placement = rank and string.format("#%d/%d", rank, recordCount) or "unranked"
  local storage = stored == false and " · not saved" or ""
  return string.format(
    "%s · %s s · %s%s",
    isBest and "New PB" or "Lap complete",
    formattedTime,
    placement,
    storage
  )
end

-- Driver inputs read from the vehicle electrics: throttle/brake/handbrake as
-- 0..1, gear as a numeric index. Guarded so a vehicle or context without
-- electrics simply records no input data.
local function readDriverInputs()
  local values = electrics and electrics.values
  if type(values) ~= "table" then return nil, nil, nil, nil, nil end
  local gear = tonumber(values.gearIndex)
  if gear == nil then gear = tonumber(values.gear) end
  return tonumber(values.throttle), tonumber(values.brake), gear,
    tonumber(values.parkingbrake), tonumber(values.clutch)
end

local function captureSample(timestamp)
  local throttle, brake, gear, handbrake, clutch = readDriverInputs()
  recordingState.points[#recordingState.points + 1] =
    replayCodec.captureSample(obj, timestamp, throttle, brake, gear, handbrake, clutch)
end

local function normalizeReplay(data)
  return replayCodec.normalizeReplay(data)
end

local function replayEnvelope(points, lapTime)
  local startLine = startGateConfig.activeLibraryOwnerEntry() and {
    level = startGateConfig.startLineLevel,
    position = {startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineZ},
    normal = {startGateConfig.startLineNormalX, startGateConfig.startLineNormalY, startGateConfig.startLineNormalZ},
    halfWidth = AUTO_LINE_HALF_WIDTH
  } or nil
  return replayCodec.replayEnvelope(points, lapTime, {
    sampleInterval = recordingState.activeSampleInterval,
    vehicle = v.data.vehicleDirectory,
    groundOffset = recordingState.groundOffset,
    startLine = startLine
  })
end

local function defaultReplayFilename()
  return replayCodec.defaultReplayFilename(v.data.vehicleDirectory)
end

local function ghostLibraryIndexFilename(filename)
  return replayCodec.libraryIndexFilename(filename, defaultReplayFilename())
end

local function ghostSampleFilename(filename, id)
  return replayCodec.sampleFilename(filename, id, defaultReplayFilename())
end

local function colorForName(name)
  local preset = colorPresets[name] or colorPresets.orange
  return color(preset[1], preset[2], preset[3], preset[4])
end

local function paletteColorName(index)
  local offset = 1
  for colorIndex = 1, #colorOrder do
    if colorOrder[colorIndex] == displayState.colorName then
      offset = colorIndex
      break
    end
  end
  return colorOrder[((offset + index - 2) % #colorOrder) + 1]
end

local function ghostComparableTime(entry)
  return tonumber(entry and entry.lapTime)
    or tonumber(entry and entry.duration)
    or math.huge
end

local function ghostIsIncomplete(entry)
  if not entry then return false end
  return entry.complete == false
    or entry.source == "incomplete"
    or entry.incompleteReason ~= nil
    or tostring(entry.label or ""):match("^Incomplete%s") ~= nil
end

-- A manual Run is stopped by hand rather than by a start-gate crossing, so it
-- is neither a timed lap nor a failed attempt at one. It gets its own label and
-- filter instead of being forced into either category.
local function ghostIsManual(entry)
  if not entry or ghostIsIncomplete(entry) then return false end
  if entry.manual ~= nil then return entry.manual == true end
  -- Libraries written before the category existed are classified by how the
  -- recording was produced.
  return entry.source == "manual"
    or tostring(entry.label or ""):match("^Run%s") ~= nil
end

startGateConfig.ghostIsManual = ghostIsManual

-- The category axis (complete / incomplete / both) decides which kinds are
-- eligible, independent of the display mode (best / top / all ...). "incomplete"
-- hides finished laps and manual Runs so the view is only partials.
local function ghostCategoryVisible(entry)
  local filter = displayState.ghostCategoryFilter or "complete"
  local incomplete = ghostIsIncomplete(entry)
  if filter == "incomplete" then return incomplete end
  if filter == "both" then return true end
  return not incomplete
end

local function ghostCanBeShown(entry)
  return entry and entry.available ~= false
    and ghostCategoryVisible(entry)
    and (not ghostIsManual(entry) or displayState.showManual)
end

-- Timed laps, manual Runs and failed attempts are three separate categories
-- with independent storage quotas: a hand-stopped Run has no lap time, so it
-- must never rank against a measured lap or take one of their slots.
local function ghostCategory(entry)
  if ghostIsIncomplete(entry) then return "incomplete" end
  if ghostIsManual(entry) then return "manual" end
  return "lap"
end

local function ghostLibraryCounts()
  local completed, incomplete, manual = 0, 0, 0
  for index = 1, #playbackState.ghosts do
    local category = ghostCategory(playbackState.ghosts[index])
    if category == "incomplete" then
      incomplete = incomplete + 1
    elseif category == "manual" then
      manual = manual + 1
    else
      completed = completed + 1
    end
  end
  return completed, incomplete, manual
end

local function bestGhostEntry(entriesOnly)
  local best
  local hasTimedLap = false
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    if not ghostIsIncomplete(entry) and entry.available ~= false
        and (not entriesOnly or entry.displayed) then
      local isTimedLap = tonumber(entry.lapTime) ~= nil
      if (isTimedLap and not hasTimedLap)
          or (isTimedLap == hasTimedLap
            and (not best or ghostComparableTime(entry) < ghostComparableTime(best))) then
        best = entry
        hasTimedLap = isTimedLap
      end
    end
  end
  return best
end

local function newestIncompleteGhostEntry(entriesOnly)
  if not displayState.showIncomplete then return nil end
  for index = #playbackState.ghosts, 1, -1 do
    local entry = playbackState.ghosts[index]
    if ghostIsIncomplete(entry) and entry.available ~= false
        and (not entriesOnly or entry.displayed) then
      return entry
    end
  end
  return nil
end

-- The "best" partial is the one that got furthest -- the longest by recorded
-- duration -- so best/single modes have a sensible hero when the category filter
-- is showing only incompletes.
local function longestIncompleteGhostEntry(entriesOnly)
  local chosen, longest = nil, -1
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    if ghostIsIncomplete(entry) and entry.available ~= false
        and ghostCanBeShown(entry)
        and (not entriesOnly or entry.displayed) then
      local length = tonumber(entry.duration) or 0
      if length > longest then chosen, longest = entry, length end
    end
  end
  return chosen
end

local function ensureGhostSamples(entry)
  if not entry then return false end
  if type(entry.samples) == "table" and #entry.samples >= 2 then return true end
  if not entry.file then
    entry.available = false
    startGateConfig.trace(
      "ghost.samples.load", "FAILED id=%s reason=noFile", tostring(entry.id)
    )
    return false
  end

  startGateConfig.trace(
    "ghost.samples.load", "begin id=%s file=%s", tostring(entry.id), tostring(entry.file)
  )
  local rawReplay = jsonReadFile(entry.file)
  local points, metadata = normalizeReplay(rawReplay)
  if not points then
    entry.available = false
    startGateConfig.trace(
      "ghost.samples.load", "FAILED id=%s file=%s reason=%s rawType=%s",
      tostring(entry.id), tostring(entry.file),
      rawReplay == nil and "missingOrUnreadable" or "invalidReplay",
      type(rawReplay)
    )
    return false
  end
  entry.samples = points
  entry.lapTime = tonumber(entry.lapTime) or metadata.lapTime
  entry.duration = tonumber(entry.duration) or metadata.duration
  entry.sampleInterval = tonumber(entry.sampleInterval) or metadata.sampleInterval
  entry.groundOffset = tonumber(entry.groundOffset) or metadata.groundOffset
  entry.vehicle = entry.vehicle or metadata.vehicle
  if entry.complete == nil then entry.complete = metadata.complete ~= false end
  entry.incompleteReason = entry.incompleteReason or metadata.incompleteReason
  entry.shareFingerprint = entry.shareFingerprint or metadata.shareFingerprint
  if entry.hasSpeed == nil then entry.hasSpeed = metadata.hasSpeed end
  -- The loaded samples are authoritative for whether inputs were recorded, so
  -- correct a stale/missing manifest flag from the real data.
  entry.hasInputs = metadata.hasInputs == true
  entry.available = true
  entry.cursor = 1
  startGateConfig.trace(
    "ghost.samples.load",
    "SUCCESS id=%s file=%s samples=%d duration=%s complete=%s",
    tostring(entry.id), tostring(entry.file), #points,
    tostring(entry.duration), tostring(entry.complete ~= false)
  )
  return true
end

function startGateConfig.ghostEntryById(id)
  id = id and tostring(id) or nil
  if not id then return nil end
  for index = 1, #playbackState.ghosts do
    if playbackState.ghosts[index].id == id then return playbackState.ghosts[index] end
  end
  return nil
end

function startGateConfig.resolveGhostCameraTarget()
  local target = startGateConfig.ghostEntryById(playbackState.cameraTargetId)
  if target and (not target.displayed or not ensureGhostSamples(target)) then target = nil end
  target = target or bestGhostEntry(true)
  if not target or not ensureGhostSamples(target) then return nil end
  if playbackState.cameraTargetId ~= target.id then playbackState.cameraCursor = 1 end
  playbackState.cameraTargetId = target.id
  playbackState.cameraTargetLabel = target.label
  return target
end

local routeGuide = require("vehicle/ghostRacer/routeGuide").new({
  state = startGateConfig,
  object = obj,
  ensureGhostSamples = ensureGhostSamples,
  bestGhostEntry = bestGhostEntry,
  clamp = clamp,
  indexes = {
    posX = POS_X, posY = POS_Y, posZ = POS_Z,
    frontX = FRONT_X, frontY = FRONT_Y
  }
})
runtimeContext:registerService("routeGuide", routeGuide)
startGateConfig.syncRouteGuide = routeGuide.syncRouteGuide
startGateConfig.clearRouteGuide = routeGuide.clearRouteGuide
startGateConfig.buildRouteGuide = routeGuide.buildRouteGuide
startGateConfig.refreshRouteGuide = routeGuide.refreshRouteGuide
startGateConfig.activateRouteGuide = routeGuide.activateRouteGuide
startGateConfig.deactivateRouteGuide = routeGuide.deactivateRouteGuide
startGateConfig.setRouteGuideEnabled = routeGuide.setRouteGuideEnabled
startGateConfig.setRoutePathVisible = routeGuide.setRoutePathVisible
startGateConfig.setRouteCheckpointsVisible = routeGuide.setRouteCheckpointsVisible
startGateConfig.setRouteCheckpointSpacing = routeGuide.setRouteCheckpointSpacing
startGateConfig.resetCheckpointProgress = routeGuide.resetCheckpointProgress
startGateConfig.updateCheckpointProgress = routeGuide.updateCheckpointProgress
startGateConfig.checkpointValidationActive = routeGuide.checkpointValidationActive
startGateConfig.allCheckpointsPassed = routeGuide.allCheckpointsPassed
startGateConfig.missedCheckpointIndex = routeGuide.missedCheckpointIndex
local function resetGhostCursors(resetProgress)
  for index = 1, #playbackState.ghosts do playbackState.ghosts[index].cursor = 1 end
  playbackState.resetCursors(resetProgress)
end

local function syncGhostSelection()
  local best = bestGhostEntry(false)
  local selected

  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    entry.displayed = false
    entry.isBest = entry == best
    if entry.selected and ghostCanBeShown(entry) and not selected then selected = entry end
  end

  if displayState.ghostDisplayMode == "all" then
    for index = 1, #playbackState.ghosts do
      local entry = playbackState.ghosts[index]
      entry.displayed = ghostCanBeShown(entry)
    end
  elseif displayState.ghostDisplayMode == "top" then
    -- Completed laps rank by lap time (fastest first); partials rank by how far
    -- they got (longest duration first). Each category shows its own Top N, so
    -- the "both" filter shows up to 2N: the N fastest laps and the N longest
    -- attempts. ghostCanBeShown already applies the category filter, so a list
    -- outside the current filter is simply empty.
    local completes, incompletes = {}, {}
    for index = 1, #playbackState.ghosts do
      local entry = playbackState.ghosts[index]
      if ghostCanBeShown(entry) then
        if ghostIsIncomplete(entry) then
          incompletes[#incompletes + 1] = entry
        elseif not ghostIsManual(entry) then
          completes[#completes + 1] = entry
        end
      end
    end
    table.sort(completes, function(first, second)
      local firstTime, secondTime = ghostComparableTime(first), ghostComparableTime(second)
      if firstTime == secondTime then return tostring(first.id) < tostring(second.id) end
      return firstTime < secondTime
    end)
    table.sort(incompletes, function(first, second)
      local firstLength = tonumber(first.duration) or 0
      local secondLength = tonumber(second.duration) or 0
      if firstLength == secondLength then return tostring(first.id) < tostring(second.id) end
      return firstLength > secondLength
    end)
    local function displayTopOf(list)
      local shown = 0
      for index = 1, #list do
        if shown >= displayState.topGhostCount then break end
        if ensureGhostSamples(list[index]) then
          list[index].displayed = true
          shown = shown + 1
        end
      end
    end
    displayTopOf(completes)
    displayTopOf(incompletes)
  elseif displayState.ghostDisplayMode == "multi" then
    local displayedCount = 0
    for index = 1, #playbackState.ghosts do
      local entry = playbackState.ghosts[index]
      entry.displayed = entry.selected == true and ghostCanBeShown(entry)
      if entry.displayed then displayedCount = displayedCount + 1 end
    end
    if displayedCount == 0 then
      local fallback = (displayState.ghostCategoryFilter == "incomplete")
        and longestIncompleteGhostEntry(false) or best
      if fallback then fallback.displayed = true end
    end
  elseif displayState.ghostDisplayMode == "single" then
    local singleEntry = selected
    if not singleEntry then
      if displayState.ghostCategoryFilter == "incomplete" then
        singleEntry = longestIncompleteGhostEntry(false)
      else
        singleEntry = best or newestIncompleteGhostEntry(false)
      end
    end
    if singleEntry then singleEntry.displayed = true end
  else
    local dynamicEntry
    if displayState.ghostCategoryFilter == "incomplete" then
      dynamicEntry = longestIncompleteGhostEntry(false)
    else
      dynamicEntry = best or newestIncompleteGhostEntry(false)
    end
    if dynamicEntry then dynamicEntry.displayed = true end
  end

  -- Every display mode picks its own candidates, so enforce the visibility
  -- filters once here: a recording the player has filtered out must never end
  -- up displayed, whichever branch selected it.
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    if entry.displayed and not ghostCanBeShown(entry) then entry.displayed = false end
  end

  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    if entry.displayed then
      if not ensureGhostSamples(entry) then entry.displayed = false end
    elseif entry.file and entry.samples ~= recordingState.lastRecording then
      -- Best mode normally keeps only one lap resident. Multi/all load the
      -- selected files on demand and retain only those visible samples.
      entry.samples = nil
      entry.cursor = 1
    end
  end

  local comparison = bestGhostEntry(true)
  if not comparison then
    for index = 1, #playbackState.ghosts do
      local candidate = playbackState.ghosts[index]
      if candidate.displayed and ensureGhostSamples(candidate) then
        comparison = candidate
        break
      end
    end
  end
  if not comparison then
    for _ = 1, #playbackState.ghosts do
      local fallback = bestGhostEntry(false)
      if not fallback or not ghostCanBeShown(fallback) then break end
      if ensureGhostSamples(fallback) then
        fallback.displayed = true
        comparison = fallback
        break
      end
    end
  end
  if comparison then
    setPublicPlaybackPoints(comparison.samples)
  else
    setPublicPlaybackPoints({})
  end

  local rankedDisplayed = {}
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    entry.displayRank = nil
    entry.trailBrightnessTier = nil
    if entry.displayed then rankedDisplayed[#rankedDisplayed + 1] = entry end
  end
  table.sort(rankedDisplayed, function(first, second)
    if ghostIsIncomplete(first) ~= ghostIsIncomplete(second) then
      return not ghostIsIncomplete(first)
    end
    local firstTime, secondTime = ghostComparableTime(first), ghostComparableTime(second)
    if firstTime == secondTime then return tostring(first.id) < tostring(second.id) end
    return firstTime < secondTime
  end)
  for rank = 1, #rankedDisplayed do
    local entry = rankedDisplayed[rank]
    entry.displayRank = rank
    entry.trailBrightnessTier = #rankedDisplayed <= 1 and 5 or math.max(1, math.min(5,
      math.floor(5 - (rank - 1) * 4 / (#rankedDisplayed - 1) + 0.5)
    ))
  end

  playbackState.duration = 0
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    if entry.displayed then
      playbackState.duration = math.max(
        playbackState.duration,
        tonumber(entry.duration) or 0
      )
    end
  end
  resetGhostCursors()
  startGateConfig.refreshRouteGuide(false)
  if startGateConfig.syncBestLapLine then startGateConfig.syncBestLapLine() end
end

local saveGhostManifest

local function persistGhostSamples(entry)
  if not playbackState.activeLibraryFilename or not entry or #entry.samples < 2 then return false end
  local targetFilename = entry.file or ghostSampleFilename(playbackState.activeLibraryFilename, entry.id)
  local envelope = replayEnvelope(entry.samples, entry.lapTime)
  envelope.sampleInterval = entry.sampleInterval or envelope.sampleInterval
  envelope.groundOffset = entry.groundOffset or envelope.groundOffset
  envelope.source = entry.source
  envelope.vehicle = entry.vehicle or envelope.vehicle
  envelope.complete = entry.complete ~= false
  envelope.incompleteReason = entry.incompleteReason
  envelope.shareFingerprint = entry.shareFingerprint
  local success = jsonWriteFile(targetFilename, envelope, false) ~= false
  if success then entry.file = targetFilename end
  return success
end

function startGateConfig.removeStoredFile(filename)
  if not filename or not FS or type(FS.removeFile) ~= "function" then return false end
  local ok, removed = pcall(FS.removeFile, FS, filename)
  return ok and removed ~= false
end

function startGateConfig.removeGhostAt(index)
  local entry = playbackState.ghosts[index]
  if not entry then return nil end
  table.remove(playbackState.ghosts, index)
  if entry.samples == recordingState.lastRecording then recordingState.lastRecording = {} end
  startGateConfig.removeStoredFile(entry.file)
  return entry
end

function startGateConfig.reconcilePrimaryGhost()
  local filename = playbackState.activeLibraryFilename or startGateConfig.currentFilename
  local best = bestGhostEntry(false)
  while best and not ensureGhostSamples(best) do best = bestGhostEntry(false) end
  playbackState.pbTime = best and tonumber(best.lapTime) or nil

  if not filename then return best end
  if not best then
    startGateConfig.removeStoredFile(filename)
    startGateConfig.removeStoredFile(filename .. ".time")
    return nil
  end

  local envelope = replayEnvelope(best.samples, playbackState.pbTime)
  envelope.sampleInterval = best.sampleInterval or envelope.sampleInterval
  envelope.groundOffset = best.groundOffset or envelope.groundOffset
  envelope.source = best.source
  envelope.vehicle = best.vehicle or envelope.vehicle
  envelope.complete = true
  jsonWriteFile(filename, envelope, false)
  if playbackState.pbTime then
    jsonWriteFile(filename .. ".time", {playbackState.pbTime}, false)
  else
    startGateConfig.removeStoredFile(filename .. ".time")
  end
  startGateConfig.currentFilename = filename
  return best
end

local function pruneGhostLibrary()
  -- Pinned ghosts are never pruned, and they do not count against a category's
  -- quota: pinning a ghost keeps it as an extra protected slot rather than eating
  -- into the rotating capacity for new laps.
  local function countEntries(category)
    local count = 0
    for index = 1, #playbackState.ghosts do
      local entry = playbackState.ghosts[index]
      if entry.pinned ~= true and ghostCategory(entry) == category then
        count = count + 1
      end
    end
    return count
  end

  -- Timed laps are ranked, so the slowest one goes first and the current best
  -- is always protected.
  while countEntries("lap") > MAX_STORED_GHOSTS do
    local best = bestGhostEntry(false)
    local removeIndex
    local longestTime = -math.huge
    for index = 1, #playbackState.ghosts do
      local entry = playbackState.ghosts[index]
      local entryTime = ghostComparableTime(entry)
      if ghostCategory(entry) == "lap" and entry ~= best and entry.pinned ~= true
          and (not removeIndex or entryTime > longestTime) then
        removeIndex = index
        longestTime = entryTime
      end
    end
    if not removeIndex then break end
    startGateConfig.removeGhostAt(removeIndex)
  end

  -- Manual Runs are unranked -- elapsed time says nothing about a clip's value
  -- -- so they keep their newest entries within quota (evict the oldest first).
  while countEntries("manual") > MAX_STORED_MANUAL_GHOSTS do
    local removeIndex
    for index = 1, #playbackState.ghosts do
      local entry = playbackState.ghosts[index]
      if ghostCategory(entry) == "manual" and entry.pinned ~= true then
        removeIndex = index
        break
      end
    end
    if not removeIndex then break end
    startGateConfig.removeGhostAt(removeIndex)
  end

  -- Incomplete attempts are kept by how far they got: a longer partial recording
  -- captured more of the route and is worth more, so the shortest (by recorded
  -- duration) is discarded first, and among equal lengths the oldest goes.
  while countEntries("incomplete") > MAX_STORED_INCOMPLETE_GHOSTS do
    local removeIndex
    local shortest = math.huge
    for index = 1, #playbackState.ghosts do
      local entry = playbackState.ghosts[index]
      if ghostCategory(entry) == "incomplete" and entry.pinned ~= true then
        local length = tonumber(entry.duration) or 0
        if not removeIndex or length < shortest then
          removeIndex = index
          shortest = length
        end
      end
    end
    if not removeIndex then break end
    startGateConfig.removeGhostAt(removeIndex)
  end
end

local function ghostEntryPlacement(entry)
  if not entry or ghostCategory(entry) ~= "lap" then return nil, nil, entry ~= nil end

  local entryTime = ghostComparableTime(entry)
  local rank = 1
  local stored = false
  for index = 1, #playbackState.ghosts do
    local candidate = playbackState.ghosts[index]
    if ghostCategory(candidate) ~= "lap" then
      -- Only measured laps participate in completed-lap placement.
    elseif candidate == entry then
      stored = true
    elseif ghostComparableTime(candidate) < entryTime then
      rank = rank + 1
    end
  end

  -- If pruning discarded the just-finished lap, include that attempt in the
  -- displayed comparison count so the HUD can explain why it was not saved.
  local completedCount = 0
  for index = 1, #playbackState.ghosts do
    if ghostCategory(playbackState.ghosts[index]) == "lap" then
      completedCount = completedCount + 1
    end
  end
  return rank, completedCount + (stored and 0 or 1), stored
end

local function addGhostToLibrary(points, lapTime, label, source, sampleIntervalOverride,
    hasSpeedOverride, groundOffsetOverride, incompleteReasonOverride,
    shareFingerprintOverride, vehicleOverride, manualOverride)
  if type(points) ~= "table" or #points < 2 then return nil end

  local id = string.format("g%06d", playbackState.nextGhostId)
  playbackState.nextGhostId = playbackState.nextGhostId + 1
  local duration = tonumber(points[#points][TIME]) or tonumber(lapTime) or 0
  local entry = {
    id = id,
    label = label or string.format("Lap %d", playbackState.nextGhostId - 1),
    lapTime = tonumber(lapTime),
    duration = duration,
    source = source or "lap",
    complete = incompleteReasonOverride == nil,
    incompleteReason = incompleteReasonOverride,
    vehicle = sanitizePathPart(
      vehicleOverride or v.data.vehicleDirectory,
      "unknown_vehicle"
    ),
    sampleInterval = tonumber(sampleIntervalOverride) or recordingState.activeSampleInterval,
    groundOffset = tonumber(groundOffsetOverride) or recordingState.groundOffset,
    hasSpeed = hasSpeedOverride ~= false,
    samples = points,
    selected = incompleteReasonOverride == nil and bestGhostEntry(false) == nil,
    colorName = paletteColorName(#playbackState.ghosts + 1),
    cursor = 1,
    available = true,
    -- Pinned ghosts are protected from capacity pruning and manual deletion until
    -- unpinned. New ghosts start unpinned.
    pinned = false,
    -- Whether this recording carries per-sample driver inputs (2.18+). Drives the
    -- "no input data" hint in the Driver-inputs colour mode.
    hasInputs = type(points[1]) == "table" and points[1][THROTTLE] ~= nil
  }
  entry.shareFingerprint = shareFingerprintOverride
  if manualOverride ~= nil then
    entry.manual = manualOverride == true
  else
    entry.manual = source == "manual"
  end
  entry.debugColor = colorForName(entry.colorName)
  playbackState.ghosts[#playbackState.ghosts + 1] = entry

  persistGhostSamples(entry)
  -- Prune after insertion so the incoming lap participates in the comparison.
  -- At capacity, a newly completed slowest lap is discarded instead of
  -- evicting a faster historical lap merely because it arrived later.
  pruneGhostLibrary()
  syncGhostSelection()
  if saveGhostManifest then saveGhostManifest() end
  if startGateConfig.updateActiveStats then startGateConfig.updateActiveStats(true) end
  local rank, recordCount, stored = ghostEntryPlacement(entry)
  return entry, rank, recordCount, stored
end

saveGhostManifest = function()
  if not playbackState.activeLibraryFilename then return false end

  local descriptors = {}
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    descriptors[#descriptors + 1] = {
      id = entry.id,
      label = entry.label,
      lapTime = entry.lapTime,
      duration = entry.duration,
      sampleInterval = entry.sampleInterval,
      groundOffset = entry.groundOffset,
      hasSpeed = entry.hasSpeed ~= false,
      source = entry.source,
      complete = entry.complete ~= false,
      incompleteReason = entry.incompleteReason,
      vehicle = entry.vehicle,
      importedFrom = entry.importedFrom,
      shareFingerprint = entry.shareFingerprint,
      manual = entry.manual == true,
      color = entry.colorName,
      selected = entry.selected == true,
      pinned = entry.pinned == true,
      hasInputs = entry.hasInputs == true,
      file = entry.file
    }
  end

  local manifest = {
    formatVersion = GHOST_LIBRARY_FORMAT_VERSION,
    nextId = playbackState.nextGhostId,
    displayMode = displayState.ghostDisplayMode,
    topGhostCount = displayState.topGhostCount,
    maxStoredGhosts = MAX_STORED_GHOSTS,
    maxStoredIncompleteGhosts = MAX_STORED_INCOMPLETE_GHOSTS,
    maxStoredManualGhosts = MAX_STORED_MANUAL_GHOSTS,
    importedLegacyGhosts = startGateConfig.importedLegacyGhosts,
    ghosts = descriptors
  }
  if startGateConfig.activeLibraryOwnerEntry() then
    manifest.startLine = {
      level = startGateConfig.startLineLevel,
      position = {startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineZ},
      normal = {startGateConfig.startLineNormalX, startGateConfig.startLineNormalY, startGateConfig.startLineNormalZ},
      halfWidth = AUTO_LINE_HALF_WIDTH
    }
  end
  return jsonWriteFile(ghostLibraryIndexFilename(playbackState.activeLibraryFilename), manifest, false) ~= false
end

local function clearGhostLibraryMemory()
  table.clear(playbackState.ghosts)
  table.clear(startGateConfig.importedLegacyGhosts)
  playbackState.pendingImport = nil
  playbackState.nextGhostId = 1
  setPublicPlaybackPoints({})
  playbackState.duration = 0
  playbackState.elapsed = 0
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  resetGhostCursors()
end

local function loadGhostLibrary(loadFilename, saveFilename, fallbackPoints, fallbackMetadata)
  clearGhostLibraryMemory()
  playbackState.activeLibraryFilename = saveFilename or loadFilename or defaultReplayFilename()

  local preferredIndex = ghostLibraryIndexFilename(playbackState.activeLibraryFilename)
  local loadIndex = ghostLibraryIndexFilename(loadFilename or playbackState.activeLibraryFilename)
  local manifest = jsonReadFile(preferredIndex)
  local sourceIndex = preferredIndex
  if type(manifest) ~= "table" or type(manifest.ghosts) ~= "table" then
    manifest = jsonReadFile(loadIndex)
    sourceIndex = loadIndex
  end

  if type(manifest) == "table" and type(manifest.ghosts) == "table" then
    if type(manifest.importedLegacyGhosts) == "table" then
      for key, value in pairs(manifest.importedLegacyGhosts) do
        if value == true then startGateConfig.importedLegacyGhosts[tostring(key)] = true end
      end
    end
    playbackState.nextGhostId = math.max(1, tonumber(manifest.nextId) or 1)
    displayState.setGhostDisplayMode(manifest.displayMode)
    local savedTopCount = math.floor(tonumber(manifest.topGhostCount) or 0)
    displayState.setTopGhostCount(savedTopCount)

    -- Each category owns its own quota, so they are counted independently.
    -- The unranked ones keep their newest entries, which means the oldest
    -- overflow is skipped rather than the newest. Pinned ghosts are protected
    -- extra slots: exactly as the prune step keeps them, the loader always loads
    -- them and never counts them against a category's rotation quota. Measuring
    -- the quota against pinned entries here is what used to drop pinned (or the
    -- newest unpinned) records on reload and orphan their sample files.
    local categoryLimits = {
      lap = MAX_STORED_GHOSTS,
      manual = MAX_STORED_MANUAL_GHOSTS,
      incomplete = MAX_STORED_INCOMPLETE_GHOSTS
    }
    local loadedByCategory = {lap = 0, manual = 0, incomplete = 0}
    local skipByCategory = {lap = 0, manual = 0, incomplete = 0}
    for index = 1, #manifest.ghosts do
      local descriptor = manifest.ghosts[index]
      if descriptor and descriptor.pinned ~= true then
        local category = ghostCategory(descriptor)
        skipByCategory[category] = skipByCategory[category] + 1
      end
    end
    skipByCategory.lap = 0
    skipByCategory.manual = math.max(0, skipByCategory.manual - categoryLimits.manual)
    skipByCategory.incomplete = math.max(0, skipByCategory.incomplete - categoryLimits.incomplete)
    for index = 1, #manifest.ghosts do
      local descriptor = manifest.ghosts[index]
      local category = ghostCategory(descriptor)
      local incomplete = category == "incomplete"
      local pinned = descriptor and descriptor.pinned == true
      local shouldLoad = descriptor and descriptor.file ~= nil
      if not pinned then
        -- Unpinned entries fill the rotation quota; oldest overflow is skipped.
        if skipByCategory[category] > 0 then
          skipByCategory[category] = skipByCategory[category] - 1
          shouldLoad = false
        elseif loadedByCategory[category] >= categoryLimits[category] then
          shouldLoad = false
        end
      end
      if shouldLoad then
        local id = tostring(descriptor.id or string.format("g%06d", playbackState.nextGhostId))
        local numericId = tonumber(id:match("(%d+)$"))
        if numericId then playbackState.nextGhostId = math.max(playbackState.nextGhostId, numericId + 1) end
        local colorName = colorPresets[descriptor.color] and descriptor.color
          or paletteColorName(#playbackState.ghosts + 1)
        playbackState.ghosts[#playbackState.ghosts + 1] = {
          id = id,
          label = descriptor.label or string.format("Lap %d", #playbackState.ghosts + 1),
          lapTime = tonumber(descriptor.lapTime),
          duration = tonumber(descriptor.duration),
          source = descriptor.source or "lap",
          complete = not incomplete,
          incompleteReason = descriptor.incompleteReason,
          vehicle = descriptor.vehicle,
          importedFrom = descriptor.importedFrom,
          shareFingerprint = descriptor.shareFingerprint,
          manual = descriptor.manual,
          sampleInterval = tonumber(descriptor.sampleInterval),
          groundOffset = tonumber(descriptor.groundOffset),
          hasSpeed = descriptor.hasSpeed,
          samples = nil,
          selected = descriptor.selected == true,
          colorName = colorName,
          debugColor = colorForName(colorName),
          file = descriptor.file,
          cursor = 1,
          available = true,
          pinned = descriptor.pinned == true,
          hasInputs = descriptor.hasInputs == true
        }
        if not pinned then
          loadedByCategory[category] = loadedByCategory[category] + 1
        end
      end
    end
  end

  if #playbackState.ghosts == 0 and type(fallbackPoints) == "table" and #fallbackPoints >= 2 then
    addGhostToLibrary(
      fallbackPoints,
      fallbackMetadata and fallbackMetadata.lapTime or playbackState.pbTime,
      "Imported PB",
      "personalBest",
      fallbackMetadata and fallbackMetadata.sampleInterval,
      fallbackMetadata and fallbackMetadata.hasSpeed,
      fallbackMetadata and fallbackMetadata.groundOffset,
      fallbackMetadata and fallbackMetadata.complete == false
        and (fallbackMetadata.incompleteReason or "interrupted") or nil,
      fallbackMetadata and fallbackMetadata.shareFingerprint,
      fallbackMetadata and fallbackMetadata.vehicle
    )
  else
    syncGhostSelection()
    if sourceIndex ~= preferredIndex and #playbackState.ghosts > 0 then saveGhostManifest() end
  end

  return #playbackState.ghosts > 0
end

local function setGhostDisplayMode(mode)
  if not displayState.setGhostDisplayMode(mode) then return false end
  mode = displayState.ghostDisplayMode
  syncGhostSelection()
  saveGhostManifest()
  local exceedsShellCapacity = mode == "top"
    and displayState.topGhostCount > MAX_SHELL_GHOSTS
  if exceedsShellCapacity then
    if startGateConfig.clearGhostShells then startGateConfig.clearGhostShells(true) end
    if startGateConfig.shellCapacityWarningCount ~= displayState.topGhostCount then
      startGateConfig.shellCapacityWarningCount = displayState.topGhostCount
      notify(string.format(
        "Top %d uses wireframe Ghosts; optimized native vehicles support up to Top %d",
        displayState.topGhostCount, MAX_SHELL_GHOSTS
      ), 6)
      startGateConfig.trace(
        "shell.capacity", "requested=%d maximum=%d fallback=wireframe",
        displayState.topGhostCount, MAX_SHELL_GHOSTS
      )
    end
  else
    startGateConfig.shellCapacityWarningCount = nil
    if not SHELL_DISPLAY_MODES[mode] and startGateConfig.clearGhostShells then
      startGateConfig.clearGhostShells(true)
    end
    uiRuntimeState.lastMessage = "Ghost mode: " .. mode
  end
  return true
end

function startGateConfig.setTopGhostCount(value)
  if not displayState.setTopGhostCount(value) then return false end
  syncGhostSelection()
  saveGhostManifest()
  local exceedsShellCapacity = displayState.ghostDisplayMode == "top"
    and displayState.topGhostCount > MAX_SHELL_GHOSTS
  if exceedsShellCapacity then
    if startGateConfig.clearGhostShells then startGateConfig.clearGhostShells(true) end
    if startGateConfig.shellCapacityWarningCount ~= displayState.topGhostCount then
      startGateConfig.shellCapacityWarningCount = displayState.topGhostCount
      notify(string.format(
        "Top %d uses wireframe Ghosts; optimized native vehicles support up to Top %d",
        displayState.topGhostCount, MAX_SHELL_GHOSTS
      ), 6)
      startGateConfig.trace(
        "shell.capacity", "requested=%d maximum=%d fallback=wireframe",
        displayState.topGhostCount, MAX_SHELL_GHOSTS
      )
    end
  else
    startGateConfig.shellCapacityWarningCount = nil
    uiRuntimeState.lastMessage = string.format("Top %d ghosts", displayState.topGhostCount)
  end
  return true
end

local function setGhostSelected(id, value)
  id = tostring(id or "")
  local target
  for index = 1, #playbackState.ghosts do
    if playbackState.ghosts[index].id == id then target = playbackState.ghosts[index] break end
  end
  if not target then return false end

  if displayState.ghostDisplayMode == "single" and value == true then
    for index = 1, #playbackState.ghosts do playbackState.ghosts[index].selected = false end
  end
  target.selected = value == true
  syncGhostSelection()
  saveGhostManifest()
  return true
end

function startGateConfig.deleteGhost(id)
  id = tostring(id or "")
  local removeIndex
  for index = 1, #playbackState.ghosts do
    if playbackState.ghosts[index].id == id then
      removeIndex = index
      break
    end
  end
  if not removeIndex then
    uiRuntimeState.lastMessage = "Delete failed: saved lap not found"
    notify(uiRuntimeState.lastMessage, 3)
    return false
  end

  if playbackState.ghosts[removeIndex].pinned == true then
    uiRuntimeState.lastMessage = "Ghost is pinned · unpin it first to delete"
    notify(uiRuntimeState.lastMessage, 3)
    return false
  end

  local removed = startGateConfig.removeGhostAt(removeIndex)
  startGateConfig.reconcilePrimaryGhost()
  playbackState.elapsed = 0
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  if #playbackState.ghosts == 0 then
    playbackState.active = false
    startGateConfig.disableGhostCamera()
    clearGeGhostTrail()
  end
  syncGhostSelection()
  saveGhostManifest()
  if startGateConfig.updateActiveStats then startGateConfig.updateActiveStats(true) end
  uiRuntimeState.lastMessage = string.format("Deleted %s", removed.label or "lap")
  notify(uiRuntimeState.lastMessage, 2)
  return true
end

-- Pin or unpin a ghost. A pinned ghost is protected from capacity pruning and
-- from manual deletion until it is unpinned.
function startGateConfig.setGhostPinned(id, pinned)
  id = tostring(id or "")
  local entry
  for index = 1, #playbackState.ghosts do
    if playbackState.ghosts[index].id == id then
      entry = playbackState.ghosts[index]
      break
    end
  end
  if not entry then
    uiRuntimeState.lastMessage = "Pin failed: saved lap not found"
    notify(uiRuntimeState.lastMessage, 3)
    return false
  end
  local nextPinned = pinned == true
  if entry.pinned == nextPinned then return true end
  entry.pinned = nextPinned
  saveGhostManifest()
  syncGhostSelection()
  if startGateConfig.updateActiveStats then startGateConfig.updateActiveStats(true) end
  uiRuntimeState.lastMessage = string.format(
    "%s %s", nextPinned and "Pinned" or "Unpinned", entry.label or "lap"
  )
  notify(uiRuntimeState.lastMessage, 2)
  return true
end

local function setQuality(value)
  wireframeRenderer.setQuality(displayState.setQuality(value))
end

-- Compatibility alias: the original console command used setDetail(1-10),
-- where 10 represented the best quality.
local function setDetail(value)
  setQuality(value)
end

local function setSampleRate(value)
  recordingState.setSampleRate(value)
end

local function setVisible(value)
  displayState.setVisible(value)
  if not displayState.visible then
    startGateConfig.ghostTrailLingering = false
    clearGeGhostTrail(true)
  end
end

local function setStartGateVisible(value)
  displayState.setStartGateVisible(value)
  if startGateConfig.syncMarkers then startGateConfig.syncMarkers() end
end

local function setGhostTrailVisible(value)
  displayState.setGhostTrailVisible(value)
  uiRuntimeState.trailSyncAccumulator = GHOST_TRAIL_SYNC_INTERVAL
  if not displayState.ghostTrailVisible then
    startGateConfig.ghostTrailLingering = false
    clearGeGhostTrail(true)
  end
end

local function setGhostTrailMode(mode)
  if not displayState.setGhostTrailMode(mode) then return false end
  uiRuntimeState.trailSyncAccumulator = GHOST_TRAIL_SYNC_INTERVAL
  if startGateConfig.syncBestLapLine then startGateConfig.syncBestLapLine() end
  return true
end

local function setGhostTrailSeconds(value)
  if not displayState.setGhostTrailSeconds(value) then return false end
  uiRuntimeState.trailSyncAccumulator = GHOST_TRAIL_SYNC_INTERVAL
  return true
end

local function setLoopPlayback(value)
  local enabled = value == true
  if displayState.loopPlayback and not enabled and playbackState.active then
    -- Return the non-wrapping trail clock to this final play-through's local
    -- time so its finish linger is measured from the upcoming endpoint.
    startGateConfig.trailPlaybackElapsed = playbackState.elapsed
  end
  displayState.setLoopPlayback(enabled)
end

local function setColorPreset(name)
  if not displayState.setColorPreset(name, colorPresets) then return false end
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    entry.colorName = paletteColorName(index)
    entry.debugColor = colorForName(entry.colorName)
  end
  saveGhostManifest()
  return true
end

local function startRecording()
  local px, py, pz = obj:getPositionXYZ()
  local groundOffset = pz - startGateConfig.groundHeightAt(px, py, pz)
  setPublicRecordPoints(recordingState.begin(groundOffset))
  playbackState.progressCursor = 1
  -- Fresh lap: restart each Ghost's rank-trajectory cursor from its start.
  if startGateConfig.resetRankCursors then startGateConfig.resetRankCursors() end
  -- A fresh lap must clear every checkpoint again from the first one. Pass the
  -- current position so any gate the car already sits in front of is pre-cleared.
  if startGateConfig.resetCheckpointProgress then startGateConfig.resetCheckpointProgress(px, py) end
  captureSample(0)
  if sessionState.raceMode then
    uiRuntimeState.lastMessage = "Racing ghost"
  elseif sessionState.autoLapActive then
    uiRuntimeState.lastMessage = "Auto lap recording"
  else
    uiRuntimeState.lastMessage = "Recording"
  end
  return true
end

local function stopRecording(promoteToPlayback)
  if not recordingState.active then return false end
  recordingState.finish()

  if promoteToPlayback ~= false and #recordingState.lastRecording > 0 then
    playbackState.activeLibraryFilename = playbackState.activeLibraryFilename or startGateConfig.currentFilename or defaultReplayFilename()
    addGhostToLibrary(
      recordingState.lastRecording,
      nil,
      string.format("Run %d", playbackState.nextGhostId),
      "manual",
      recordingState.activeSampleInterval
    )
  end

  uiRuntimeState.lastMessage = "Recording ready"
  return true
end

local incompleteReasonLabels = {
  outsideWidth = "outside the start gate",
  verticalOffset = "vertical gate offset",
  tooSlow = "crossing speed too low",
  segmentTooLong = "teleport or position jump",
  cooldown = "start gate cooldown",
  minimumLapTime = "below minimum lap time",
  invalidGate = "invalid start gate crossing",
  invalidLap = "official lap invalidated",
  raceEnded = "race ended",
  missionFailed = "Time Trial failed",
  missionAbandoned = "Time Trial abandoned",
  missionStopped = "Time Trial stopped",
  vehicleReset = "vehicle reset",
  startChanged = "saved start changed",
  autoLapDisabled = "automatic lap disabled",
  autoLapRestarted = "automatic lap restarted",
  startDeactivated = "saved start deactivated",
  safetyLimit = "30 minute safety limit"
}

local function archiveIncompleteRecording(reason)
  reason = tostring(reason or "interrupted")
  if not recordingState.active then
    startGateConfig.trace("archive.skip", "reason=%s cause=notRecording", reason)
    return nil
  end
  stopRecording(false)
  if #recordingState.lastRecording < 2 then
    startGateConfig.trace("archive.skip", "reason=%s cause=tooShort points=%d",
      reason, #recordingState.lastRecording)
    return nil
  end

  -- Never drop the recording just because no library filename was set yet: fall
  -- back to this vehicle's default replay library so a reset mid-lap always has
  -- somewhere to save the partial. A missing filename was one way the save was
  -- lost silently.
  playbackState.activeLibraryFilename = playbackState.activeLibraryFilename
    or startGateConfig.currentFilename
    or defaultReplayFilename()

  local entry = addGhostToLibrary(
    recordingState.lastRecording,
    nil,
    string.format("Incomplete %d", playbackState.nextGhostId),
    "incomplete",
    recordingState.activeSampleInterval,
    true,
    recordingState.groundOffset,
    reason
  )
  if not entry then
    startGateConfig.trace("archive.skip", "reason=%s cause=addFailed", reason)
    return nil
  end

  -- addGhostToLibrary prunes on insert. With the length-retention rule a partial
  -- shorter than a full pool of longer ones is discarded immediately, so record
  -- whether the just-saved entry actually survived -- that distinguishes "not
  -- saved" from "saved then pruned as the shortest".
  local survived = false
  for index = 1, #playbackState.ghosts do
    if playbackState.ghosts[index] == entry then survived = true break end
  end
  startGateConfig.trace("archive.saved",
    "reason=%s id=%s duration=%.3f library=%s survived=%s",
    reason, tostring(entry.id), tonumber(entry.duration) or 0,
    tostring(playbackState.activeLibraryFilename), tostring(survived))

  if startGateConfig.updateTimeTrialStartStats and sessionState.raceMode then
    startGateConfig.updateTimeTrialStartStats()
  end
  local reasonLabel = incompleteReasonLabels[reason] or reason:gsub("([a-z])([A-Z])", "%1 %2")

  -- Be honest about what actually happened. The length-retention rule can prune
  -- this partial the instant it is inserted (it is the shortest of a full pool),
  -- and a "saved" toast in that case is a lie -- the player looks for it and it
  -- is not there. Announce "saved" only when it survived; otherwise say plainly
  -- that it was too short to keep, and how many longer partials outrank it.
  local message
  if survived then
    message = string.format(
      "Incomplete recording saved · %.1f s · %s",
      tonumber(entry.duration) or 0,
      reasonLabel
    )
  else
    local storedIncomplete = 0
    for index = 1, #playbackState.ghosts do
      if ghostCategory(playbackState.ghosts[index]) == "incomplete" then
        storedIncomplete = storedIncomplete + 1
      end
    end
    message = string.format(
      "Incomplete not kept · %.1f s is shorter than all %d saved partials",
      tonumber(entry.duration) or 0,
      storedIncomplete
    )
  end
  notify(message, 5)
  return entry, survived, message
end

local shareManager = require("vehicle/ghostRacer/shareManager").new({
  state = startGateConfig,
  playback = playbackState,
  display = displayState,
  codec = shareCodec,
  object = obj,
  codeVersion = CODE_VERSION,
  maximumCompleted = MAX_STORED_GHOSTS,
  maximumIncomplete = MAX_STORED_INCOMPLETE_GHOSTS,
  maximumManual = MAX_STORED_MANUAL_GHOSTS,
  maximumBytes = GHOST_SHARE_MAX_BYTES,
  maximumVertical = AUTO_LINE_MAX_VERTICAL,
  sanitizePathPart = sanitizePathPart,
  ensureGhostSamples = ensureGhostSamples,
  ghostEntryById = startGateConfig.ghostEntryById,
  ghostIsIncomplete = ghostIsIncomplete,
  ghostIsManual = ghostIsManual,
  adoptRoute = function(route) return startGateConfig.adoptSharedRoute(route) end,
  ghostComparableTime = ghostComparableTime,
  addGhostToLibrary = addGhostToLibrary,
  saveManifest = saveGhostManifest,
  removeStoredFile = startGateConfig.removeStoredFile,
  notify = notify,
  sendUiState = function() return startGateConfig.sendUiState() end,
  updateActiveStats = function(persist)
    return startGateConfig.updateActiveStats(persist)
  end
})
runtimeContext:registerService("shareManager", shareManager)
local shareGhosts = shareManager.shareGhosts
local prepareClipboardImport = shareManager.prepareClipboardImport
local confirmClipboardImport = shareManager.confirmClipboardImport
local cancelClipboardImport = shareManager.cancelClipboardImport
local function stopPlayback(lingerTrail)
  local keepTrail = lingerTrail == true
    and displayState.ghostTrailVisible and displayState.visible
    and playbackState.duration > 0
    and math.max(0, playbackState.elapsed - playbackState.duration)
      < displayState.ghostTrailSeconds
  playbackState.active = false
  if startGateConfig.clearGhostShells then startGateConfig.clearGhostShells() end
  startGateConfig.ghostTrailLingering = keepTrail
  playbackState.elapsed = keepTrail and playbackState.duration or 0
  if not keepTrail then startGateConfig.trailPlaybackElapsed = 0 end
  playbackState.cursor = 1
  startGateConfig.ghostStartHoldFrames = 0
  startGateConfig.disableGhostCamera()
  if keepTrail then
    uiRuntimeState.trailSyncAccumulator = GHOST_TRAIL_SYNC_INTERVAL
  else
    clearGeGhostTrail()
  end
  uiRuntimeState.lastMessage = recordingState.active and "Recording" or "Playback stopped"
end

local function playRecording()
  if #playbackState.ghosts > 0 then syncGhostSelection() end
  if #playbackState.points < 2 then
    notify("No ghost recording loaded")
    return false
  end

  playbackState.elapsed = 0
  -- The playback clock jumped back to 0. GE ignores a backward clock heartbeat
  -- unless it is told to resync, so flag one or the shells stay hidden at the
  -- previous lap's clock (wireframe from lap 2 on).
  startGateConfig.shellClockResyncPending = true
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  startGateConfig.ghostStartHoldFrames = 0
  if #playbackState.ghosts == 0 then
    playbackState.duration = playbackState.points[#playbackState.points][TIME] or 0
  end
  resetGhostCursors()
  playbackState.active = true
  uiRuntimeState.lastMessage = recordingState.active and "Racing ghost" or "Playing"
  return true
end

-- Select and start one stored Ghost as a single atomic user action. This is
-- especially important for partial attempts: they are intentionally excluded
-- from PB/Top N ranking, so the generic Play button may otherwise keep playing
-- only the completed comparison set even though the partial row is visible.
local function normalizedBoolean(value)
  return value == true or value == 1 or value == "true"
end

local function playGhost(id, showIncomplete, requestTraceId)
  -- The HUD passes its current filter value together with the row action. A
  -- freshly loaded Vehicle controller starts with the default false value, so
  -- applying both atomically prevents a visible partial row from being
  -- rejected during settings-restoration races after reset or hot reload.
  local filterBefore = displayState.showIncomplete
  if showIncomplete ~= nil then
    displayState.setShowIncomplete(normalizedBoolean(showIncomplete))
    syncGhostSelection()
  end
  startGateConfig.trace(
    "partial.play.request",
    "request=%s id=%s filterRaw=%s filterType=%s before=%s after=%s library=%d",
    tostring(requestTraceId or "none"), tostring(id), tostring(showIncomplete),
    type(showIncomplete), tostring(filterBefore), tostring(displayState.showIncomplete),
    #playbackState.ghosts
  )
  local target = startGateConfig.ghostEntryById(id)
  if not target then
    notify("Ghost recording not found")
    startGateConfig.trace(
      "partial.play.result", "request=%s FAILED code=notFound id=%s",
      tostring(requestTraceId or "none"), tostring(id)
    )
    return false, "notFound"
  end
  startGateConfig.trace(
    "partial.play.target",
    "request=%s id=%s label=%q source=%s reason=%s complete=%s available=%s file=%s residentSamples=%d",
    tostring(requestTraceId or "none"), tostring(target.id), tostring(target.label),
    tostring(target.source), tostring(target.incompleteReason),
    tostring(not ghostIsIncomplete(target)), tostring(target.available ~= false),
    tostring(target.file), type(target.samples) == "table" and #target.samples or 0
  )
  if ghostIsIncomplete(target) and not displayState.showIncomplete then
    notify("Enable Show incomplete recordings to play this partial")
    startGateConfig.trace(
      "partial.play.result", "request=%s FAILED code=filterDisabled id=%s",
      tostring(requestTraceId or "none"), tostring(target.id)
    )
    return false, "filterDisabled"
  end
  if not ghostCanBeShown(target) or not ensureGhostSamples(target) then
    notify("Ghost recording could not be loaded")
    startGateConfig.trace(
      "partial.play.result",
      "request=%s FAILED code=loadFailed id=%s available=%s file=%s samples=%d",
      tostring(requestTraceId or "none"), tostring(target.id),
      tostring(target.available ~= false), tostring(target.file),
      type(target.samples) == "table" and #target.samples or 0
    )
    return false, "loadFailed"
  end

  displayState.setGhostDisplayMode("single")
  for index = 1, #playbackState.ghosts do
    playbackState.ghosts[index].selected = false
  end
  target.selected = true
  syncGhostSelection()
  saveGhostManifest()
  if not target.displayed then
    startGateConfig.trace(
      "partial.play.result", "request=%s FAILED code=notDisplayed id=%s mode=%s",
      tostring(requestTraceId or "none"), tostring(target.id),
      tostring(displayState.ghostDisplayMode)
    )
    return false, "notDisplayed"
  end
  if not playRecording() then
    startGateConfig.trace(
      "partial.play.result",
      "request=%s FAILED code=playbackEmpty id=%s samples=%d duration=%s",
      tostring(requestTraceId or "none"), tostring(target.id),
      type(target.samples) == "table" and #target.samples or 0,
      tostring(target.duration)
    )
    return false, "playbackEmpty"
  end

  uiRuntimeState.lastMessage = ghostIsIncomplete(target)
    and ("Playing partial: " .. tostring(target.label or target.id))
    or ("Playing: " .. tostring(target.label or target.id))
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  startGateConfig.trace(
    "partial.play.result",
    "request=%s SUCCESS id=%s samples=%d duration=%s mode=%s filter=%s",
    tostring(requestTraceId or "none"), tostring(target.id), #target.samples,
    tostring(target.duration), tostring(displayState.ghostDisplayMode),
    tostring(displayState.showIncomplete)
  )
  return true, nil
end

-- Auto-lap crossings can create the first library entry and start playback in
-- the same graphics update. Refresh the selected set explicitly, then hold the
-- playback clock for one rendered frame so the new ghost is visibly placed on
-- the start line instead of first appearing some distance down the track.
function startGateConfig.playAutoLapGhost()
  if #playbackState.ghosts > 0 then syncGhostSelection() end
  -- In a looping display the Ghosts run continuously on their own clock. A
  -- real-car start-line crossing must not restart that playback: doing so left
  -- the previous cycle's trail orphaned (a trail with no body) while the Ghosts
  -- were meant to keep running. Only restart when playback is not already live.
  if displayState.loopPlayback and playbackState.active then
    return true
  end
  if #playbackState.points < 2 then
    playbackState.active = false
    startGateConfig.trailPlaybackElapsed = 0
    startGateConfig.ghostTrailLingering = false
    startGateConfig.disableGhostCamera()
    startGateConfig.ghostStartHoldFrames = 0
    return false
  end
  if not playRecording() then return false end
  startGateConfig.ghostStartHoldFrames = 1
  return true
end

local function saveRecording(filename, lapTime)
  filename = filename or ("ghostReplays/" .. v.data.vehicleDirectory .. "/ghost.save.json")
  local points = #recordingState.lastRecording > 0 and recordingState.lastRecording or playbackState.points
  if #points == 0 then
    notify("Nothing to save")
    return false
  end

  local effectiveLapTime = tonumber(lapTime) or playbackState.pbTime
  local success = jsonWriteFile(filename, replayEnvelope(points, effectiveLapTime), false)
  if effectiveLapTime then
    -- Keep the 1.6 sidecar for backward compatibility.
    jsonWriteFile(filename .. ".time", {effectiveLapTime}, false)
  end

  if success == false then
    notify("Could not save ghost")
    return false
  end

  startGateConfig.currentFilename = filename
  playbackState.pbTime = effectiveLapTime
  if startGateConfig.updateActiveStats then startGateConfig.updateActiveStats(true) end
  notify("Ghost saved", 2)
  return true
end

local function loadRecording(filename, quiet)
  filename = filename or defaultReplayFilename()
  local data = jsonReadFile(filename)
  local points, metadata = normalizeReplay(data)

  if not points then
    if not quiet then notify("No saved ghost found") end
    return false
  end

  playbackState.pbTime = metadata.lapTime or (jsonReadFile(filename .. ".time") or {})[1]
  startGateConfig.currentFilename = filename
  metadata.lapTime = metadata.lapTime or playbackState.pbTime
  loadGhostLibrary(filename, filename, points, metadata)
  uiRuntimeState.lastMessage = "Ghost loaded"
  if not quiet then notify("Ghost loaded", 2) end
  return true
end

local function loadTime(filename)
  filename = filename or "ghostReplays/tempghost.save.json"
  local data = jsonReadFile(filename)
  if type(data) == "table" and tonumber(data.lapTime) then
    return tonumber(data.lapTime)
  end
  return (jsonReadFile(filename .. ".time") or {})[1]
end

local function rememberCurrentPosition(offsetBehindLine)
  local px, py, pz = obj:getPositionXYZ()
  local offset = tonumber(offsetBehindLine) or 0
  startGateConfig.previousPositionX = px - startGateConfig.startLineNormalX * offset
  startGateConfig.previousPositionY = py - startGateConfig.startLineNormalY * offset
  startGateConfig.previousPositionZ = pz - startGateConfig.startLineNormalZ * offset
end

function startGateConfig.resetAutoLapCrossingState()
  sessionCoordinator.resetCrossing()
end

function startGateConfig.armAutoLapCrossing(x, y, z, signedDistance)
  sessionCoordinator.armCrossing(x, y, z, signedDistance)
end

startGateConfig.autoLapRejectMessages = {
  outsideWidth = "Lap not counted · crossed outside the 15 m start gate",
  verticalOffset = "Lap not counted · crossed too far above or below the start gate",
  tooSlow = "Lap not counted · forward crossing speed was too low",
  wrongDirection = "Lap not counted · crossed the start gate in the wrong direction",
  segmentTooLong = "Lap not counted · crossing looked like a teleport or severe position jump",
  cooldown = "Lap not counted · start gate was still in cooldown",
  minimumLapTime = "Lap not counted · crossing was under the 5 second minimum"
}

function startGateConfig.rejectAutoLapCrossing(reason)
  -- A reverse pass is diagnostic only: the same lap may still turn around and
  -- finish correctly. Rejected forward passes invalidate position delta until
  -- the next valid crossing starts a clean attempt.
  sessionCoordinator.rejectCrossing(reason)
  local message = startGateConfig.autoLapRejectMessages[reason]
    or "Lap not counted · invalid start gate crossing"
  uiRuntimeState.lastMessage = message
  notify(message, 5)
end

local startRegistry = require("vehicle/ghostRacer/startRegistry").new({
  state = startGateConfig,
  sanitizePathPart = sanitizePathPart,
  normalizeReplay = normalizeReplay,
  ghostLibraryIndexFilename = ghostLibraryIndexFilename,
  ghostSampleFilename = ghostSampleFilename,
  getGhostDisplayMode = function() return displayState.ghostDisplayMode end,
  getTopGhostCount = function() return displayState.topGhostCount end,
  vehicleDirectory = v.data.vehicleDirectory,
  formatVersion = FORMAT_VERSION,
  libraryFormatVersion = GHOST_LIBRARY_FORMAT_VERSION,
  maxStoredGhosts = MAX_STORED_GHOSTS,
  maxStoredIncompleteGhosts = MAX_STORED_INCOMPLETE_GHOSTS,
  codeVersion = CODE_VERSION,
  timeIndex = TIME
})
runtimeContext:registerService("startRegistry", startRegistry)
startGateConfig.startLineFilenameForId = startRegistry.startLineFilenameForId
startGateConfig.lineLibraryFilename = startRegistry.lineLibraryFilename
startGateConfig.legacyVehicleStartLineFilenameForId = startRegistry.legacyVehicleStartLineFilenameForId
startGateConfig.copyTable = startRegistry.copyTable
startGateConfig.replaySetVehicle = startRegistry.replaySetVehicle
startGateConfig.mergeGhostReplaySet = startRegistry.mergeGhostReplaySet
startGateConfig.importVehicleGhostLibraries = startRegistry.importVehicleGhostLibraries
startGateConfig.registryFilename = startRegistry.registryFilename
startGateConfig.legacyRegistryFilename = startRegistry.legacyRegistryFilename
startGateConfig.legacyFilename = startRegistry.legacyFilename
startGateConfig.normalizedRegistryLine = startRegistry.normalizedRegistryLine
startGateConfig.sharedLineStats = startRegistry.sharedLineStats
startGateConfig.refreshRegistryStats = startRegistry.refreshRegistryStats
startGateConfig.migrateStartGhostData = startRegistry.migrateStartGhostData
startGateConfig.mergeLegacyRegistry = startRegistry.mergeLegacyRegistry
startGateConfig.loadRegistry = startRegistry.loadRegistry
startGateConfig.activeEntry = startRegistry.activeEntry
startGateConfig.findRegistryLine = startRegistry.findRegistryLine
startGateConfig.mergeNewerRegistry = startRegistry.mergeNewerRegistry
startGateConfig.saveRegistry = startRegistry.saveRegistry
local function startLineFilename(levelName)
  return startGateConfig.lineLibraryFilename(levelName, startGateConfig.activeEntry())
end

-- Deactivating a Saved Start with the HUD "x" switches off its live functions
-- but keeps its registry identity, geometry and Ghost library. Ownership of the
-- loaded library, not the live gate, decides whether that start still speaks
-- for these recordings. A library left behind by a finished activity must not
-- borrow a stale Saved Start identity, so an inactive start qualifies only
-- while the loaded library is still the one it owns.
function startGateConfig.activeLibraryOwnerEntry()
  local line = startGateConfig.activeEntry()
  if not line then return nil end
  if startGateConfig.startLineSet then return line end
  local owned = startGateConfig.lineLibraryFilename(
    startGateConfig.startLineLevel or startGateConfig.registry.level,
    line
  )
  if owned and owned == playbackState.activeLibraryFilename then return line end
  return nil
end

local function savedStartLineMatches(metadata)
  local line = metadata and metadata.startLine
  local position = line and line.position
  local normal = line and line.normal
  if type(position) ~= "table" or type(normal) ~= "table" then return false end

  local dx = (tonumber(position[1]) or math.huge) - startGateConfig.startLineX
  local dy = (tonumber(position[2]) or math.huge) - startGateConfig.startLineY
  local dz = (tonumber(position[3]) or math.huge) - startGateConfig.startLineZ
  local distanceSquared = dx * dx + dy * dy + dz * dz
  local directionDot = (tonumber(normal[1]) or 0) * startGateConfig.startLineNormalX
    + (tonumber(normal[2]) or 0) * startGateConfig.startLineNormalY
    + (tonumber(normal[3]) or 0) * startGateConfig.startLineNormalZ

  return distanceSquared <= AUTO_LINE_HALF_WIDTH * AUTO_LINE_HALF_WIDTH
    and directionDot >= 0.75
end

function startGateConfig.groundHeightAt(x, y, fallbackZ)
  if type(castRayStatic) ~= "function" then return fallbackZ end

  groundRay.origin.x = x
  groundRay.origin.y = y
  groundRay.origin.z = fallbackZ + startGateConfig.rayStartAbove
  local ok, hitDistance = pcall(
    castRayStatic,
    groundRay.origin,
    groundRay.direction,
    startGateConfig.rayLength,
    true
  )
  hitDistance = ok and tonumber(hitDistance) or nil
  if not hitDistance or hitDistance < 0
      or hitDistance >= startGateConfig.rayLength - 0.001 then
    return fallbackZ
  end
  return groundRay.origin.z - hitDistance
end

function startGateConfig.sampleSurface(fallbackZ)
  startGateConfig.startLineZ = startGateConfig.groundHeightAt(startGateConfig.startLineX, startGateConfig.startLineY, fallbackZ)
end

function startGateConfig.syncMarkers()
  if not obj.queueGameEngineLua then return end
  local encoded = {}
  for index = 1, #startGateConfig.registry.lines do
    local line = startGateConfig.registry.lines[index]
    local position = line.position
    local normal = line.normal
    encoded[#encoded + 1] = string.format(
      "{id=%q,name=%q,x=%.9g,y=%.9g,z=%.9g,nx=%.9g,ny=%.9g," ..
        "ghostCount=%d,pbTime=%s,active=%s}",
      line.id,
      line.name,
      position[1], position[2], position[3],
      normal[1], normal[2],
      tonumber(line.ghostCount) or 0,
      line.pbTime and string.format("%.9g", line.pbTime) or "nil",
      tostring(startGateConfig.startLineSet and line.id == startGateConfig.registry.activeId)
    )
  end
  -- The finish gate is a synthetic marker for the active point-to-point start,
  -- flagged so GE renders it distinctly and follows the start-gate visibility.
  if startGateConfig.startLineSet and startGateConfig.finishLineSet then
    encoded[#encoded + 1] = string.format(
      "{id=%q,name=%q,x=%.9g,y=%.9g,z=%.9g,nx=%.9g,ny=%.9g," ..
        "ghostCount=0,pbTime=nil,active=false,isFinish=true}",
      "finish", "FINISH",
      startGateConfig.finishLineX, startGateConfig.finishLineY, startGateConfig.finishLineZ,
      startGateConfig.finishLineNormalX, startGateConfig.finishLineNormalY
    )
  end
  obj:queueGameEngineLua(
    "if extensions and extensions.ghostlapping and " ..
      "extensions.ghostlapping.setFreeRoamMarkers then " ..
      "extensions.ghostlapping.setFreeRoamMarkers({" .. table.concat(encoded, ",") .. "}," ..
      tostring(startGateConfig.savedMarkersVisible) .. "," ..
      tostring(displayState.startGateVisible and startGateConfig.startLineSet) .. "," ..
      startGateConfig.senderLiteral() .. ") end"
  )
end

function startGateConfig.timeTrialLineId(profile)
  local key = sanitizePathPart(profile and profile.id, "temp")
  return "tt-" .. key
end

-- Modern Race hooks capture the player's current grid pose. Legacy Quick Race
-- profiles can additionally carry the official Scenario start transform so a
-- Ctrl+L reload during a lap does not relocate the gate to the moving car.
function startGateConfig.ensureTimeTrialStart(profile)
  if type(profile) ~= "table" then
    startGateConfig.trace("tt.ensure", "rejected: profile type=%s", type(profile))
    return nil
  end
  if profile.traceId ~= nil then
    startGateConfig.diagnosticTraceId = tostring(profile.traceId)
  end
  startGateConfig.trace(
    "tt.ensure",
    "profile id=%s name=%q level=%s source=%s",
    tostring(profile.id), tostring(profile.name), tostring(profile.level),
    tostring(profile.source)
  )
  local levelName = sanitizePathPart(profile.level, "unknown_level")
  if startGateConfig.registry.level ~= levelName then
    startGateConfig.loadRegistry(levelName)
  end

  local id = startGateConfig.timeTrialLineId(profile)
  local line
  local created = false
  for index = 1, #startGateConfig.registry.lines do
    if startGateConfig.registry.lines[index].id == id then
      line = startGateConfig.registry.lines[index]
      break
    end
  end

  startGateConfig.trace(
    "tt.ensure",
    "resolved target=%s existing=%s existingName=%q existingUserNamed=%s",
    id,
    tostring(line ~= nil),
    tostring(line and line.name),
    tostring(line and line.userNamed == true)
  )

  if not line then
    created = true
    line = {
      id = id,
      name = "TT · " .. tostring(profile.name or profile.id or "Time Trial"):sub(1, 27),
      userNamed = false,
      kind = "timeTrial",
      raceKey = sanitizePathPart(profile.id, "temp"),
      activitySource = profile.source and tostring(profile.source):sub(1, 32) or "timeTrial",
      position = {0, 0, 0},
      normal = {0, 1, 0},
      ghostCount = 0,
      incompleteGhostCount = 0,
      pbTime = nil,
      transient = #startGateConfig.registry.lines >= startGateConfig.maxSavedStarts
    }
    startGateConfig.registry.lines[#startGateConfig.registry.lines + 1] = line
  end

  local px = tonumber(profile.startX)
  local py = tonumber(profile.startY)
  local pz = tonumber(profile.startZ)
  local frontX = tonumber(profile.startNx)
  local frontY = tonumber(profile.startNy)
  local usedOfficialPose = px ~= nil and py ~= nil and pz ~= nil
    and frontX ~= nil and frontY ~= nil
  if not usedOfficialPose then
    px, py, pz = obj:getPositionXYZ()
    local front = obj:getDirectionVector()
    frontX = front.x
    frontY = front.y
  end
  local horizontalLength = math.sqrt(frontX * frontX + frontY * frontY)
  if horizontalLength < 0.001 then return nil end

  startGateConfig.startLineNormalX = frontX / horizontalLength
  startGateConfig.startLineNormalY = frontY / horizontalLength
  startGateConfig.startLineNormalZ = 0
  startGateConfig.startLineX = px + startGateConfig.startLineNormalX * startGateConfig.forwardOffset
  startGateConfig.startLineY = py + startGateConfig.startLineNormalY * startGateConfig.forwardOffset
  startGateConfig.startLineZ = pz
  startGateConfig.startLineLevel = levelName
  startGateConfig.sampleSurface(startGateConfig.startLineZ)

  -- Keep an automatic label current until the user edits it. Once renamed,
  -- countdown preparation and GO recalibration may move the gate but must not
  -- silently restore the generated TT label.
  if created or not line.userNamed then
    line.name = "TT · " .. tostring(profile.name or profile.id or "Time Trial"):sub(1, 27)
  end
  line.kind = "timeTrial"
  line.raceKey = sanitizePathPart(profile.id, "temp")
  line.activitySource = profile.source and tostring(profile.source):sub(1, 32)
    or line.activitySource or "timeTrial"
  line.position = {startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineZ}
  line.normal = {startGateConfig.startLineNormalX, startGateConfig.startLineNormalY, 0}
  startGateConfig.registry.activeId = id
  startGateConfig.startLineSet = true
  sessionCoordinator.bindRaceControlledStart()
  rememberCurrentPosition(0)

  if not line.transient then
    startGateConfig.saveRegistry({updatedId = id, operation = "ensureTimeTrialStart"})
  end
  startGateConfig.syncMarkers()
  startGateConfig.trace(
    "tt.ensure",
    "complete target=%s created=%s name=%q userNamed=%s position=(%.3f,%.3f,%.3f) officialPose=%s",
    id, tostring(created), line.name, tostring(line.userNamed == true),
    startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineZ, tostring(usedOfficialPose)
  )
  return line
end

function startGateConfig.updateTimeTrialStartStats()
  local line = startGateConfig.activeEntry()
  if not line or line.kind ~= "timeTrial" then return end
  line.ghostCount, line.incompleteGhostCount = ghostLibraryCounts()
  line.pbTime = playbackState.pbTime
  if not line.transient then
    startGateConfig.saveRegistry({operation = "updateTimeTrialStats"})
  end
  startGateConfig.syncMarkers()
end

function startGateConfig.updateActiveStats(_persist)
  if sessionState.raceMode then return end
  local line = startGateConfig.activeLibraryOwnerEntry()
  if not line then return end
  line.ghostCount, line.incompleteGhostCount = ghostLibraryCounts()
  line.pbTime = playbackState.pbTime
  startGateConfig.syncMarkers()
end

function startGateConfig.findMatchingLine(x, y, normalX, normalY)
  local maximumSquared = startGateConfig.matchDistance * startGateConfig.matchDistance
  local best
  local bestDistance = maximumSquared
  for index = 1, #startGateConfig.registry.lines do
    local line = startGateConfig.registry.lines[index]
    -- Manual Set & start must not recycle an activity-owned tt- line merely
    -- because the player happens to place a Freeroam gate at the same grid.
    if line.kind ~= "timeTrial" then
      local dx = line.position[1] - x
      local dy = line.position[2] - y
      local distance = dx * dx + dy * dy
      local dot = line.normal[1] * normalX + line.normal[2] * normalY
      if distance <= bestDistance and dot >= 0.75 then
        best, bestDistance = line, distance
      end
    end
  end
  return best
end

function startGateConfig.createLine()
  local registry = startGateConfig.registry
  if #registry.lines >= startGateConfig.maxSavedStarts then
    return nil
  end
  local id = string.format("s%03d", registry.nextId)
  local line = {
    id = id,
    name = string.format("Start %d", registry.nextId),
    userNamed = false,
    kind = "manual",
    -- Track variants that share one physical start share this key. A plain new
    -- start is its own group (startKey == id); createStartVariant overrides it.
    startKey = id,
    position = {startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineZ},
    normal = {startGateConfig.startLineNormalX, startGateConfig.startLineNormalY, 0},
    ghostCount = 0,
    incompleteGhostCount = 0,
    pbTime = nil
  }
  registry.nextId = registry.nextId + 1
  registry.lines[#registry.lines + 1] = line
  return line
end

-- A share code is meant for other players, who cannot be expected to already
-- have the sender's Saved Start selected -- they have no way of knowing which
-- one was used. The code carries the full route identity, so adopt it: reuse a
-- matching local start when one exists, otherwise create it from the shared
-- geometry, then activate it so the import lands in the right library.
function startGateConfig.adoptSharedRoute(route)
  if type(route) ~= "table" then return false, "unsupportedFormat" end
  local registry = startGateConfig.registry
  local level = registry.level or startGateConfig.startLineLevel
  if sanitizePathPart(route.level, "unknown") ~= sanitizePathPart(level, "unknown") then
    return false, "differentMap"
  end

  local isTimeTrial = route.kind == "timeTrial" and route.raceKey ~= nil
  local position = type(route.position) == "table" and route.position or nil
  local normal = type(route.normal) == "table" and route.normal or nil
  if not isTimeTrial and (not position or not normal) then
    return false, "missingStartGeometry"
  end

  local target
  if isTimeTrial then
    target = startGateConfig.findRegistryLine(
      registry,
      startGateConfig.timeTrialLineId({id = route.raceKey})
    )
  else
    target = startGateConfig.findMatchingLine(
      tonumber(position[1]) or 0,
      tonumber(position[2]) or 0,
      tonumber(normal[1]) or 0,
      tonumber(normal[2]) or 1
    )
  end

  local created = false
  if not target then
    if #registry.lines >= startGateConfig.maxSavedStarts then
      return false, "startLimit"
    end
    local name = tostring(route.name or "Shared Start"):gsub("[%c]", " "):sub(1, 48)
    startGateConfig.startLineX = tonumber(position and position[1]) or 0
    startGateConfig.startLineY = tonumber(position and position[2]) or 0
    startGateConfig.startLineZ = tonumber(position and position[3]) or 0
    startGateConfig.startLineNormalX = tonumber(normal and normal[1]) or 0
    startGateConfig.startLineNormalY = tonumber(normal and normal[2]) or 1
    startGateConfig.startLineNormalZ = 0
    if isTimeTrial then
      -- The Time Trial id is derived from the activity, so the line the
      -- sender used and the one created here resolve to the same identity.
      -- A later Time Trial session reuses it together with these Ghosts.
      target = {
        id = startGateConfig.timeTrialLineId({id = route.raceKey}),
        name = name,
        userNamed = false,
        kind = "timeTrial",
        raceKey = sanitizePathPart(route.raceKey, "temp"),
        activitySource = "clipboard",
        position = {
          startGateConfig.startLineX,
          startGateConfig.startLineY,
          startGateConfig.startLineZ
        },
        normal = {startGateConfig.startLineNormalX, startGateConfig.startLineNormalY, 0},
        ghostCount = 0,
        incompleteGhostCount = 0
      }
      registry.lines[#registry.lines + 1] = target
    else
      target = startGateConfig.createLine()
      if not target then return false, "startLimit" end
      target.name = name
      target.userNamed = true
    end
    created = true
  end

  if registry.activeId ~= target.id or not startGateConfig.startLineSet then
    if not startGateConfig.activateLine(target) then
      return false, "startActivationFailed"
    end
  end
  startGateConfig.saveRegistry({updatedId = target.id, operation = "adoptSharedRoute"})
  return true, nil, created, target.name
end

function startGateConfig.activateLine(line, allowLegacy)
  if not line then return false end
  local normalLength = math.sqrt(line.normal[1] * line.normal[1] + line.normal[2] * line.normal[2])
  if normalLength < 0.001 then return false end

  if recordingState.active then archiveIncompleteRecording("startChanged") end

  startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineZ = line.position[1], line.position[2], line.position[3]
  startGateConfig.startLineNormalX = line.normal[1] / normalLength
  startGateConfig.startLineNormalY = line.normal[2] / normalLength
  startGateConfig.startLineNormalZ = 0
  startGateConfig.startLineLevel = startGateConfig.registry.level
  startGateConfig.registry.activeId = line.id
  startGateConfig.sampleSurface(startGateConfig.startLineZ)
  line.position = {startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineZ}
  line.normal = {startGateConfig.startLineNormalX, startGateConfig.startLineNormalY, 0}

  -- Restore an optional finish gate (point-to-point). A start without one is a
  -- circuit, so clear any stale finish state when switching to it.
  startGateConfig.previousFinishSigned = nil
  local finishPosition = line.finishPosition
  local finishNormal = line.finishNormal
  local finishNormalLength = type(finishNormal) == "table"
    and math.sqrt((tonumber(finishNormal[1]) or 0) ^ 2 + (tonumber(finishNormal[2]) or 0) ^ 2) or 0
  if type(finishPosition) == "table" and finishNormalLength >= 0.001 then
    startGateConfig.finishLineX = tonumber(finishPosition[1]) or 0
    startGateConfig.finishLineY = tonumber(finishPosition[2]) or 0
    startGateConfig.finishLineZ = tonumber(finishPosition[3]) or 0
    startGateConfig.finishLineNormalX = (tonumber(finishNormal[1]) or 0) / finishNormalLength
    startGateConfig.finishLineNormalY = (tonumber(finishNormal[2]) or 0) / finishNormalLength
    startGateConfig.finishLineNormalZ = 0
    startGateConfig.finishLineSet = true
  else
    startGateConfig.finishLineSet = false
  end

  startGateConfig.startLineSet = true
  sessionCoordinator.activateSavedStart()
  sessionCoordinator.stopRecordingAndPlayback()
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  startGateConfig.disableGhostCamera()
  startGateConfig.clearRouteGuide()
  recordingState.lastRecording = {}
  setPublicRecordPoints({})
  startGateConfig.currentFilename = startLineFilename(startGateConfig.startLineLevel)
  rememberCurrentPosition(0.5)

  local migratedGhosts = line.kind ~= "timeTrial" and startGateConfig.importVehicleGhostLibraries(
    startGateConfig.startLineLevel, line.id, startGateConfig.currentFilename
  ) or false
  line.ghostCount, line.pbTime, line.incompleteGhostCount = startGateConfig.sharedLineStats(
    startGateConfig.startLineLevel, line
  )

  local savedData = jsonReadFile(startGateConfig.currentFilename)
  local savedPoints, metadata = normalizeReplay(savedData)
  playbackState.pbTime = (metadata and metadata.lapTime)
    or line.pbTime
    or (jsonReadFile(startGateConfig.currentFilename .. ".time") or {})[1]
  if metadata then metadata.lapTime = metadata.lapTime or playbackState.pbTime end
  loadGhostLibrary(startGateConfig.currentFilename, startGateConfig.currentFilename, savedPoints, metadata)

  if #playbackState.ghosts == 0 and allowLegacy and line.kind ~= "timeTrial" then
    local legacyFilename = startGateConfig.legacyFilename(startGateConfig.startLineLevel)
    local legacyData = jsonReadFile(legacyFilename)
    local legacyPoints, legacyMetadata = normalizeReplay(legacyData)
    if legacyPoints and savedStartLineMatches(legacyMetadata) then
      playbackState.pbTime = legacyMetadata.lapTime
        or (jsonReadFile(legacyFilename .. ".time") or {})[1]
      legacyMetadata.lapTime = legacyMetadata.lapTime or playbackState.pbTime
      loadGhostLibrary(legacyFilename, startGateConfig.currentFilename, legacyPoints, legacyMetadata)
    end
  end

  if migratedGhosts and #playbackState.ghosts > 0 then
    startGateConfig.reconcilePrimaryGhost()
  end

  startGateConfig.refreshRouteGuide(false)
  -- Resend the selected route with enabled=true. This also reconstructs GE
  -- geometry after a Lua/controller hot reload instead of relying on a prior
  -- disabled geometry upload still being resident.
  startGateConfig.activateRouteGuide(true)
  line.ghostCount, line.incompleteGhostCount = ghostLibraryCounts()
  line.pbTime = playbackState.pbTime
  startGateConfig.saveRegistry({updatedId = line.id, operation = "activateStart"})
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = string.format("%s · %d ghosts loaded", line.name, #playbackState.ghosts)
  return true
end

local function setAutoLapEnabled(value)
  local enabled = value == true
  if enabled and sessionState.raceMode then
    uiRuntimeState.lastMessage = "Free-roam auto lap is unavailable during a race"
    return false
  end
  if enabled and not startGateConfig.startLineSet then
    uiRuntimeState.lastMessage = "Set a start line first"
    return false
  end

  if recordingState.active then
    archiveIncompleteRecording(enabled and "autoLapRestarted" or "autoLapDisabled")
  end
  sessionCoordinator.configureAutoLap(enabled)
  sessionCoordinator.stopRecordingAndPlayback()
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  startGateConfig.disableGhostCamera()
  setPublicRecordPoints({})
  if startGateConfig.routeReady then startGateConfig.activateRouteGuide() end

  if enabled then
    local px, py, pz = obj:getPositionXYZ()
    local signedDistance = (px - startGateConfig.startLineX) * startGateConfig.startLineNormalX
      + (py - startGateConfig.startLineY) * startGateConfig.startLineNormalY
      + (pz - startGateConfig.startLineZ) * startGateConfig.startLineNormalZ
    if math.abs(signedDistance) <= 1 then
      startGateConfig.armAutoLapCrossing(
        px - startGateConfig.startLineNormalX * (signedDistance + 0.5),
        py - startGateConfig.startLineNormalY * (signedDistance + 0.5),
        pz - startGateConfig.startLineNormalZ * (signedDistance + 0.5),
        -0.5
      )
    elseif signedDistance <= -AUTO_LINE_HYSTERESIS then
      startGateConfig.armAutoLapCrossing(px, py, pz, signedDistance)
    end
    rememberCurrentPosition(0)
    sessionState.autoLapGateState = "waitingForStart"
    uiRuntimeState.lastMessage = "Auto lap armed"
  else
    sessionState.autoLapGateState = "off"
    uiRuntimeState.lastMessage = "Auto lap off"
  end

  return true
end

function startGateConfig.restoreSaved(levelName, requestedId)
  local safeLevel = sanitizePathPart(levelName, "unknown_level")
  if startGateConfig.startLineSet and not requestedId and safeLevel == startGateConfig.startLineLevel then
    setAutoLapEnabled(true)
    startGateConfig.syncMarkers()
    uiRuntimeState.lastMessage = "Saved start restored and armed"
    return true
  end
  local registry = startGateConfig.loadRegistry(levelName)
  local targetId = requestedId and tostring(requestedId) or registry.activeId
  local target
  for index = 1, #registry.lines do
    if registry.lines[index].id == targetId then target = registry.lines[index] break end
  end
  if not target and not requestedId then target = registry.lines[1] end

  if not target then
    local legacyFilename = startGateConfig.legacyFilename(registry.level)
    local points, metadata = normalizeReplay(jsonReadFile(legacyFilename))
    local saved = metadata and metadata.startLine
    if points and saved and type(saved.position) == "table" and type(saved.normal) == "table" then
      startGateConfig.startLineX = tonumber(saved.position[1]) or 0
      startGateConfig.startLineY = tonumber(saved.position[2]) or 0
      startGateConfig.startLineZ = tonumber(saved.position[3]) or 0
      startGateConfig.startLineNormalX = tonumber(saved.normal[1]) or 0
      startGateConfig.startLineNormalY = tonumber(saved.normal[2]) or 1
      target = startGateConfig.createLine()
    end
  end

  if not target then
    startGateConfig.syncMarkers()
    uiRuntimeState.lastMessage = "No saved start line"
    return false
  end
  if not startGateConfig.activateLine(target, true) then return false end
  setAutoLapEnabled(true)
  uiRuntimeState.lastMessage = string.format("%s armed · %d ghosts", target.name, #playbackState.ghosts)
  return true
end

function startGateConfig.loadSavedMarkers(levelName)
  startGateConfig.loadRegistry(levelName)
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = #startGateConfig.registry.lines > 0
    and string.format("%d saved starts available", #startGateConfig.registry.lines)
    or "No saved start line"
  return true
end

function startGateConfig.selectSaved(requestedId)
  local levelName = startGateConfig.registry.level or startGateConfig.startLineLevel
  return startGateConfig.restoreSaved(levelName, requestedId)
end

function startGateConfig.renameActive(name, requestedId, diagnosticTraceId)
  startGateConfig.diagnosticTraceId = diagnosticTraceId and tostring(diagnosticTraceId) or nil
  local line
  local targetId = requestedId and tostring(requestedId) or startGateConfig.registry.activeId
  startGateConfig.trace(
    "rename.request",
    "target=%s requestedName=%q registryPath=%s memory={%s}",
    tostring(targetId),
    tostring(name),
    startGateConfig.registry.level
      and startGateConfig.registryFilename(startGateConfig.registry.level) or "<no-level>",
    startGateConfig.registrySummary(startGateConfig.registry)
  )
  for index = 1, #startGateConfig.registry.lines do
    if startGateConfig.registry.lines[index].id == targetId then
      line = startGateConfig.registry.lines[index]
      break
    end
  end
  if not line then
    startGateConfig.trace("rename.result", "rejected: target not found")
    return false
  end
  name = tostring(name or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    startGateConfig.trace("rename.result", "rejected: sanitized name is empty")
    return false
  end
  local previousName = line.name
  local previousUserNamed = line.userNamed
  line.name = name:sub(1, 32)
  line.userNamed = true
  local saved = startGateConfig.saveRegistry({
    renamedId = line.id, operation = "renameStart"
  })
  local verified = false
  if saved then
    local persisted = jsonReadFile(startGateConfig.registryFilename(
      startGateConfig.registry.level
    ))
    for index = 1, #(persisted and persisted.lines or {}) do
      local persistedLine = persisted.lines[index]
      if tostring(persistedLine.id or "") == line.id then
        verified = persistedLine.name == line.name and persistedLine.userNamed == true
        startGateConfig.trace(
          "rename.verify",
          "target=%s expected=%q readback=%q readbackUserNamed=%s verified=%s",
          line.id,
          line.name,
          tostring(persistedLine.name),
          tostring(persistedLine.userNamed),
          tostring(verified)
        )
        break
      end
    end
  end
  if not verified then
    line.name = previousName
    line.userNamed = previousUserNamed
    uiRuntimeState.lastMessage = "Could not verify renamed start on disk"
    notify(uiRuntimeState.lastMessage, 3)
    startGateConfig.trace(
      "rename.result",
      "FAILED target=%s previous=%q requested=%q saveReturned=%s",
      line.id, previousName, name, tostring(saved)
    )
    return false
  end
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = "Start renamed: " .. line.name .. " [" .. line.id .. "]"
  notify(uiRuntimeState.lastMessage, 3)
  startGateConfig.trace(
    "rename.result",
    "SUCCESS target=%s previous=%q current=%q revision=%s",
    line.id, previousName, line.name, tostring(startGateConfig.registry.revision)
  )
  return true
end

function startGateConfig.setSavedMarkersVisible(value)
  startGateConfig.savedMarkersVisible = value ~= false
  startGateConfig.syncMarkers()
  return true
end

function startGateConfig.ensureActivityTimeTrialStart(profile)
  if type(profile) ~= "table" then return false end
  local line = startGateConfig.ensureTimeTrialStart(profile)
  if not line or not startGateConfig.activateLine(line, false) then
    uiRuntimeState.lastMessage = "Could not create automatic TT start"
    return false
  end
  uiRuntimeState.lastMessage = "TT start ready: " .. line.id
  return true
end

local function beginAutoLapRecordingAtStart()
  sessionCoordinator.beginPlacedAutoLap()
  rememberCurrentPosition(0)
  local px, py, pz = obj:getPositionXYZ()
  local signedDistance = (px - startGateConfig.startLineX) * startGateConfig.startLineNormalX
    + (py - startGateConfig.startLineY) * startGateConfig.startLineNormalY
    + (pz - startGateConfig.startLineZ) * startGateConfig.startLineNormalZ
  if signedDistance < 0 then
    startGateConfig.armAutoLapCrossing(px, py, pz, signedDistance)
  end

  startGateConfig.playAutoLapGhost()
  startGateConfig.activateRouteGuide()
  startRecording()
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = "Auto lap 1 recording · "
    .. tostring(startGateConfig.registry.activeId or "unsaved")
  return true
end

local function setStartLine(levelName, raceProfile, diagnosticTraceId)
  startGateConfig.diagnosticTraceId = diagnosticTraceId and tostring(diagnosticTraceId)
    or type(raceProfile) == "table" and raceProfile.traceId
    or nil
  startGateConfig.trace(
    "setStart.request",
    "level=%s raceMode=%s profileType=%s profileId=%s profileSource=%s",
    tostring(levelName), tostring(sessionState.raceMode), type(raceProfile),
    tostring(type(raceProfile) == "table" and raceProfile.id or nil),
    tostring(type(raceProfile) == "table" and raceProfile.source or nil)
  )
  if sessionState.raceMode then
    uiRuntimeState.lastMessage = "Exit the race before setting a free-roam line"
    startGateConfig.trace("setStart.result", "FAILED: raceMode is active")
    return false
  end

  if type(raceProfile) == "table" then
    raceProfile.level = raceProfile.level or levelName
    if not startGateConfig.ensureActivityTimeTrialStart(raceProfile) then
      startGateConfig.trace("setStart.result", "FAILED: TT start creation rejected")
      return false
    end
    local started = beginAutoLapRecordingAtStart()
    startGateConfig.trace(
      "setStart.result", "TT result=%s active=%s name=%q",
      tostring(started), tostring(startGateConfig.registry.activeId),
      tostring(startGateConfig.activeEntry() and startGateConfig.activeEntry().name)
    )
    return started
  end

  -- Restart of an existing free-roam start: re-arm the active start in place
  -- instead of deriving a fresh gate from the current position. Once a start is
  -- created it stays fixed; "Restart lap here" restarts the lap on it. Re-deriving
  -- a gate from wherever the car stopped could miss the match radius and fork off a
  -- brand-new start (its own track group), or silently jump to a different variant
  -- that shares the same gate. To move a start, clear it and set again.
  local restartTarget = startGateConfig.activeEntry()
  if startGateConfig.startLineSet and restartTarget and restartTarget.kind ~= "timeTrial" then
    if not startGateConfig.activateLine(restartTarget, true) then
      startGateConfig.trace(
        "setStart.result", "FAILED: restart re-activation rejected id=%s",
        tostring(restartTarget.id)
      )
      return false
    end
    local restarted = beginAutoLapRecordingAtStart()
    startGateConfig.trace(
      "setStart.result", "restart result=%s active=%s name=%q",
      tostring(restarted), tostring(restartTarget.id), tostring(restartTarget.name)
    )
    return restarted
  end

  local px, py, pz = obj:getPositionXYZ()
  local front = obj:getDirectionVector()
  local horizontalLength = math.sqrt(front.x * front.x + front.y * front.y)
  if horizontalLength < 0.001 then
    uiRuntimeState.lastMessage = "Could not read vehicle direction"
    startGateConfig.trace("setStart.result", "FAILED: invalid vehicle direction")
    return false
  end

  startGateConfig.startLineNormalX = front.x / horizontalLength
  startGateConfig.startLineNormalY = front.y / horizontalLength
  startGateConfig.startLineNormalZ = 0
  startGateConfig.startLineX = px + startGateConfig.startLineNormalX * startGateConfig.forwardOffset
  startGateConfig.startLineY = py + startGateConfig.startLineNormalY * startGateConfig.forwardOffset
  startGateConfig.sampleSurface(pz)
  startGateConfig.startLineLevel = sanitizePathPart(levelName, "unknown_level")
  startGateConfig.loadRegistry(startGateConfig.startLineLevel)
  local matched = startGateConfig.findMatchingLine(
    startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineNormalX, startGateConfig.startLineNormalY
  )
  local line = matched or startGateConfig.createLine()
  if not line then
    uiRuntimeState.lastMessage = "Saved start limit reached"
    startGateConfig.trace("setStart.result", "FAILED: saved start limit reached")
    return false
  end
  if not matched then
    -- Only a brand-new start takes the freshly derived gate. Setting a start near
    -- an existing (inactive) one reuses and activates it in place -- overwriting
    -- its stored position would make the old start look like it jumped to the car.
    line.position = {startGateConfig.startLineX, startGateConfig.startLineY, startGateConfig.startLineZ}
    line.normal = {startGateConfig.startLineNormalX, startGateConfig.startLineNormalY, 0}
  end
  if not startGateConfig.activateLine(line, true) then
    startGateConfig.trace("setStart.result", "FAILED: line activation rejected id=%s", line.id)
    return false
  end
  local started = beginAutoLapRecordingAtStart()
  startGateConfig.trace(
    "setStart.result", "manual result=%s active=%s name=%q",
    tostring(started), tostring(line.id), tostring(line.name)
  )
  return started
end

-- Place a finish gate at the current position, turning the active start into a
-- point-to-point run (start crossing -> finish crossing) instead of a circuit.
-- Geometry mirrors the start gate and is stored on the active registry line so
-- it persists and restores with the start.
local function setFinishLine()
  if sessionState.raceMode then
    uiRuntimeState.lastMessage = "Exit the race before setting a finish gate"
    return false
  end
  if not startGateConfig.startLineSet then
    uiRuntimeState.lastMessage = "Set a start line before the finish gate"
    return false
  end
  local px, py, pz = obj:getPositionXYZ()
  local front = obj:getDirectionVector()
  local horizontalLength = math.sqrt(front.x * front.x + front.y * front.y)
  if horizontalLength < 0.001 then
    uiRuntimeState.lastMessage = "Could not read vehicle direction"
    return false
  end
  startGateConfig.finishLineNormalX = front.x / horizontalLength
  startGateConfig.finishLineNormalY = front.y / horizontalLength
  startGateConfig.finishLineNormalZ = 0
  startGateConfig.finishLineX = px + startGateConfig.finishLineNormalX * startGateConfig.forwardOffset
  startGateConfig.finishLineY = py + startGateConfig.finishLineNormalY * startGateConfig.forwardOffset
  startGateConfig.finishLineZ = startGateConfig.groundHeightAt(
    startGateConfig.finishLineX, startGateConfig.finishLineY, pz
  )
  startGateConfig.finishLineSet = true
  startGateConfig.previousFinishSigned = nil
  local line = startGateConfig.activeEntry()
  if line then
    line.finishPosition = {
      startGateConfig.finishLineX, startGateConfig.finishLineY, startGateConfig.finishLineZ
    }
    line.finishNormal = {
      startGateConfig.finishLineNormalX, startGateConfig.finishLineNormalY, 0
    }
    if startGateConfig.saveRegistry then startGateConfig.saveRegistry() end
  end
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = "Finish gate set · point-to-point"
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return true
end

-- Remove the finish gate, returning the start to a circuit (lap = start -> start).
local function clearFinishLine()
  if not startGateConfig.finishLineSet then return false end
  startGateConfig.finishLineSet = false
  startGateConfig.previousFinishSigned = nil
  local line = startGateConfig.activeEntry()
  if line then
    line.finishPosition = nil
    line.finishNormal = nil
    if startGateConfig.saveRegistry then startGateConfig.saveRegistry() end
  end
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = "Finish gate cleared · circuit lap"
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return true
end

-- Add a track variant to the active start: a new line sharing the same gate
-- position and startKey group, but with its own id, ghost library and finish
-- gate. Lets several tracks run from one start without clearing the others.
local function createStartVariant()
  if sessionState.raceMode then
    uiRuntimeState.lastMessage = "Exit the race before adding a track variant"
    return false
  end
  local active = startGateConfig.activeEntry()
  if not active or not startGateConfig.startLineSet then
    uiRuntimeState.lastMessage = "Set a start before adding a track variant"
    return false
  end
  local groupKey = active.startKey or active.id
  -- createLine reads the active start's live geometry, so the variant shares the
  -- gate; it only earns its own id, group key and (empty) ghost library.
  local line = startGateConfig.createLine()
  if not line then
    uiRuntimeState.lastMessage = "Saved start limit reached"
    return false
  end
  line.startKey = groupKey
  line.userNamed = false
  local count = 0
  for index = 1, #startGateConfig.registry.lines do
    local candidate = startGateConfig.registry.lines[index]
    if (candidate.startKey or candidate.id) == groupKey then count = count + 1 end
  end
  line.name = string.format("Track %d", count)
  if not startGateConfig.activateLine(line, true) then return false end
  beginAutoLapRecordingAtStart()
  if startGateConfig.saveRegistry then startGateConfig.saveRegistry() end
  uiRuntimeState.lastMessage = "New track variant · " .. line.name
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return true
end

local function clearStartLine(preserveIncomplete)
  if preserveIncomplete ~= false and recordingState.active then
    archiveIncompleteRecording("startDeactivated")
  end
  sessionCoordinator.clearStart()
  if startGateConfig.clearGhostShells then startGateConfig.clearGhostShells() end
  startGateConfig.startLineSet = false
  -- The finish gate is a live function of the start; its geometry stays on the
  -- registry line and restores when the start is reactivated.
  startGateConfig.finishLineSet = false
  startGateConfig.previousFinishSigned = nil
  sessionCoordinator.stopRecordingAndPlayback()
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  startGateConfig.disableGhostCamera()
  setPublicRecordPoints({})
  clearGeGhostTrail(true)
  startGateConfig.clearRouteGuide()
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = "Start deactivated · saved data kept"
end

function startGateConfig.deleteSavedStart(requestedId)
  local id = tostring(requestedId or "")
  local registry = startGateConfig.registry
  local removeIndex
  local line
  for index = 1, #registry.lines do
    if registry.lines[index].id == id then
      removeIndex = index
      line = registry.lines[index]
      break
    end
  end
  if not removeIndex then
    uiRuntimeState.lastMessage = "Delete failed: saved start not found"
    notify(uiRuntimeState.lastMessage, 3)
    return false
  end

  -- When the deleted line is one track of a start group, remember which sibling
  -- to fall back to: the closest earlier variant, or the next one if it was the
  -- first. Deleting the active track then lands on its neighbour instead of
  -- leaving nothing selected.
  local groupKey = line.startKey or line.id
  local previousSiblingId, nextSiblingId
  for index = 1, #registry.lines do
    if index ~= removeIndex then
      local candidate = registry.lines[index]
      if (candidate.startKey or candidate.id) == groupKey then
        if index < removeIndex then
          previousSiblingId = candidate.id
        elseif nextSiblingId == nil then
          nextSiblingId = candidate.id
        end
      end
    end
  end
  local reselectId = previousSiblingId or nextSiblingId

  local filename = startGateConfig.lineLibraryFilename(registry.level or startGateConfig.startLineLevel, line)
  local cleanupFiles = {}
  local cleanupSeen = {}
  local function queueCleanup(target)
    target = type(target) == "string" and target or nil
    if target and target ~= "" and not cleanupSeen[target] then
      cleanupSeen[target] = true
      cleanupFiles[#cleanupFiles + 1] = target
    end
  end
  local function queueReplaySet(replayFilename)
    local manifestFilename = ghostLibraryIndexFilename(replayFilename)
    local manifest = jsonReadFile(manifestFilename)
    local samplePrefix = replayFilename:gsub("%.json$", "") .. ".ghosts/"
    if type(manifest) == "table" and type(manifest.ghosts) == "table" then
      for index = 1, #manifest.ghosts do
        local descriptor = manifest.ghosts[index]
        if type(descriptor) == "table" then
          local target = descriptor.file
          if type(target) == "string" and target:sub(1, #samplePrefix) == samplePrefix then
            queueCleanup(target)
          end
          if descriptor.id then
            queueCleanup(ghostSampleFilename(
              replayFilename, sanitizePathPart(descriptor.id, "ghost")
            ))
          end
        end
      end
    end
    queueCleanup(replayFilename)
    queueCleanup(replayFilename .. ".time")
    queueCleanup(manifestFilename)
  end

  queueReplaySet(filename)
  if registry.activeId == id then
    local samplePrefix = filename:gsub("%.json$", "") .. ".ghosts/"
    for index = 1, #playbackState.ghosts do
      local target = playbackState.ghosts[index].file
      if type(target) == "string" and target:sub(1, #samplePrefix) == samplePrefix then
        queueCleanup(target)
      end
    end
  end

  -- The marker is map-shared, so permanent deletion also removes the same
  -- start ID from every vehicle's isolated Ghost directory when BeamNG's file
  -- enumeration API is available.
  if FS and type(FS.findFiles) == "function" then
    local levelRoot = string.format(
      "ghostReplays/freeRoam/%s/",
      sanitizePathPart(registry.level or startGateConfig.startLineLevel, "unknown_level")
    )
    local suffix = "/starts/" .. sanitizePathPart(id, "start") .. "/ghostracer.save"
    local ok, manifests = pcall(
      FS.findFiles, FS, levelRoot, "ghostracer.save.library.json", -1, true, false
    )
    if ok and type(manifests) == "table" then
      for index = 1, #manifests do
        local path = tostring(manifests[index]):gsub("\\", "/")
        local base = path:gsub("%.library%.json$", ".json")
        if base:sub(-#(suffix .. ".json")) == suffix .. ".json" then
          queueReplaySet(base)
        end
      end
    end
    local primaryOk, primaries = pcall(
      FS.findFiles, FS, levelRoot, "ghostracer.save.json", -1, true, false
    )
    if primaryOk and type(primaries) == "table" then
      for index = 1, #primaries do
        local path = tostring(primaries[index]):gsub("\\", "/")
        if path:sub(-#(suffix .. ".json")) == suffix .. ".json" then
          queueReplaySet(path)
        end
      end
    end
  end

  local wasActive = registry.activeId == id
  if wasActive then
    clearStartLine(false)
    clearGhostLibraryMemory()
    playbackState.activeLibraryFilename = nil
    startGateConfig.currentFilename = nil
    playbackState.pbTime = nil
    recordingState.lastRecording = {}
    registry.activeId = nil
    if startGateConfig.syncBestLapLine then startGateConfig.syncBestLapLine() end
  end

  table.remove(registry.lines, removeIndex)
  for index = 1, #cleanupFiles do
    startGateConfig.removeStoredFile(cleanupFiles[index])
  end
  startGateConfig.saveRegistry({deletedId = id, operation = "deleteStart"})
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = string.format(
    "Deleted start %s from map · %d current-vehicle ghosts",
    line.name or id,
    tonumber(line.ghostCount) or 0
  )
  notify(uiRuntimeState.lastMessage, 3)

  -- Deleting the active track lands on its neighbouring variant so the group
  -- stays selected; if it was the only track in its group, nothing is selected.
  if wasActive and reselectId then
    startGateConfig.selectSaved(reselectId)
  end
  return true
end

local function onAutoLapLineCrossed()
  local rejectionReason = sessionState.autoLapLastReject
  local crossingAction = sessionCoordinator.acceptCrossing()

  if crossingAction == "reanchor" then
    if recordingState.active then stopRecording(false) end
    sessionCoordinator.beginGateLap(crossingAction)
    startGateConfig.playAutoLapGhost()
    startGateConfig.activateRouteGuide()
    startRecording()
    uiRuntimeState.lastMessage = "Auto lap 1 aligned to start gate"
    return
  end

  if crossingAction == "start" then
    sessionCoordinator.beginGateLap(crossingAction)
    startGateConfig.playAutoLapGhost()
    startGateConfig.activateRouteGuide()
    startRecording()
    uiRuntimeState.lastMessage = "Auto lap 1 started"
    return
  end

  if crossingAction == "discard" then
    if recordingState.active then archiveIncompleteRecording(rejectionReason or "invalidGate") end
    sessionCoordinator.beginGateLap(crossingAction)
    startGateConfig.playAutoLapGhost()
    startGateConfig.activateRouteGuide()
    startRecording()
    uiRuntimeState.lastMessage = string.format("Incomplete lap saved · Lap %d started", sessionState.autoLapNumber)
    notify(uiRuntimeState.lastMessage, 4)
    return
  end

  if crossingAction ~= "finish" then return end

  -- Point-to-point: the finish is the finish gate, so re-crossing the start gate
  -- abandons the current run and begins a fresh one from here.
  if startGateConfig.finishLineSet then
    if recordingState.active then archiveIncompleteRecording("restarted") end
    sessionCoordinator.beginGateLap("start")
    startGateConfig.playAutoLapGhost()
    startGateConfig.activateRouteGuide()
    startRecording()
    uiRuntimeState.lastMessage = "Point-to-point run restarted"
    return
  end

  -- Route enforcement: when the lap is being run against a reference route, a
  -- start crossing only counts if every checkpoint was cleared in order. A lap
  -- that skipped one drove a different line, so discard it (nothing is saved) and
  -- begin a fresh lap from this crossing.
  if startGateConfig.checkpointValidationActive
      and startGateConfig.checkpointValidationActive()
      and not startGateConfig.allCheckpointsPassed() then
    local missed = startGateConfig.missedCheckpointIndex()
    local total = #startGateConfig.routeCheckpoints
    if recordingState.active then stopRecording(false) end
    sessionCoordinator.beginGateLap("start")
    startGateConfig.playAutoLapGhost()
    startGateConfig.activateRouteGuide()
    startRecording()
    uiRuntimeState.lastMessage = string.format(
      "Lap not counted · missed checkpoint %d/%d · restarted",
      missed or total, total
    )
    notify(uiRuntimeState.lastMessage, 5)
    return
  end

  local lapTime = recordingState.elapsed
  local completedLap = sessionCoordinator.beginLapCompletion(lapTime)
  stopRecording(false)

  local isBest = not playbackState.pbTime or lapTime < playbackState.pbTime
  local _, rank, recordCount, stored = addGhostToLibrary(
    recordingState.lastRecording,
    lapTime,
    string.format("Free lap %d", completedLap),
    "freeRoam",
    recordingState.activeSampleInterval
  )
  sessionCoordinator.setLastLapPlacement(rank, recordCount, stored)
  if isBest and #recordingState.lastRecording > 0 then
    playbackState.pbTime = lapTime
    saveRecording(startGateConfig.currentFilename, lapTime)
    syncGhostSelection()
  end

  startGateConfig.playAutoLapGhost()
  startGateConfig.activateRouteGuide()
  sessionCoordinator.advanceAutoLap()
  startRecording()
  local placement = rank and string.format("#%d/%d", rank, recordCount) or "unranked"
  if stored == false then placement = placement .. " not saved" end
  uiRuntimeState.lastMessage = isBest
    and string.format("New PB %.3f · %s · Lap %d", lapTime, placement, sessionState.autoLapNumber)
    or string.format(
      "Lap %d %.3f · %s · Lap %d started",
      completedLap,
      lapTime,
      placement,
      sessionState.autoLapNumber
    )
  notify(lapResultNotice(lapTime, rank, recordCount, stored, isBest), 5)
end

-- Point-to-point completion: the run ends at the finish gate, so record the lap
-- with its real time (start crossing -> finish crossing), update the PB, and go
-- idle until the next start-gate crossing. Mirrors the circuit finish path but
-- does not loop straight into another lap.
local function completePointToPointLap()
  local lapTime = recordingState.elapsed
  local completedLap = sessionCoordinator.beginLapCompletion(lapTime)
  stopRecording(false)

  local isBest = not playbackState.pbTime or lapTime < playbackState.pbTime
  local _, rank, recordCount, stored = addGhostToLibrary(
    recordingState.lastRecording,
    lapTime,
    string.format("Point-to-point %d", completedLap),
    "freeRoam",
    recordingState.activeSampleInterval
  )
  sessionCoordinator.setLastLapPlacement(rank, recordCount, stored)
  if isBest and #recordingState.lastRecording > 0 then
    playbackState.pbTime = lapTime
    saveRecording(startGateConfig.currentFilename, lapTime)
    syncGhostSelection()
  end

  sessionCoordinator.endPointToPointLap()
  startGateConfig.playAutoLapGhost()
  startGateConfig.activateRouteGuide()
  local placement = rank and string.format("#%d/%d", rank, recordCount) or "unranked"
  if stored == false then placement = placement .. " not saved" end
  uiRuntimeState.lastMessage = isBest
    and string.format("New PB %.3f · %s · cross the start to run again", lapTime, placement)
    or string.format("Point-to-point %.3f · %s · cross the start to run again", lapTime, placement)
  notify(lapResultNotice(lapTime, rank, recordCount, stored, isBest), 5)
end

-- Compact finish-gate crossing detector for point-to-point starts. The start
-- gate keeps its full arming/hysteresis handling; the finish only needs a
-- forward plane crossing within the gate bounds while a run is being recorded.
local function updateFinishGate(px, py, pz)
  if not startGateConfig.finishLineSet or not sessionState.autoLapActive
      or not recordingState.active or recordingState.elapsed < AUTO_LAP_MIN_SECONDS then
    startGateConfig.previousFinishSigned = nil
    return
  end
  local currentSigned = (px - startGateConfig.finishLineX) * startGateConfig.finishLineNormalX
    + (py - startGateConfig.finishLineY) * startGateConfig.finishLineNormalY
    + (pz - startGateConfig.finishLineZ) * startGateConfig.finishLineNormalZ
  local previousSigned = startGateConfig.previousFinishSigned
  local prevX = startGateConfig.previousFinishX
  local prevY = startGateConfig.previousFinishY
  local prevZ = startGateConfig.previousFinishZ
  startGateConfig.previousFinishSigned = currentSigned
  startGateConfig.previousFinishX, startGateConfig.previousFinishY, startGateConfig.previousFinishZ = px, py, pz
  if previousSigned == nil or prevX == nil then return end
  if previousSigned >= 0 or currentSigned < 0 then return end

  -- Measure at the interpolated point where the path actually crosses the plane,
  -- not at the sampled frame: a fast or angled pass is already off to the side by
  -- the next frame, and checking there would miss otherwise-valid finishes.
  local denominator = currentSigned - previousSigned
  local amount = denominator > 0.0001 and clamp(-previousSigned / denominator, 0, 1) or 1
  local crossX = prevX + (px - prevX) * amount
  local crossY = prevY + (py - prevY) * amount
  local crossZ = prevZ + (pz - prevZ) * amount
  local offsetX = crossX - startGateConfig.finishLineX
  local offsetY = crossY - startGateConfig.finishLineY
  local alongNormal = offsetX * startGateConfig.finishLineNormalX
    + offsetY * startGateConfig.finishLineNormalY
  local lateralX = offsetX - alongNormal * startGateConfig.finishLineNormalX
  local lateralY = offsetY - alongNormal * startGateConfig.finishLineNormalY
  local lateralSquared = lateralX * lateralX + lateralY * lateralY
  if lateralSquared <= AUTO_LINE_HALF_WIDTH * AUTO_LINE_HALF_WIDTH
      and math.abs(crossZ - startGateConfig.finishLineZ) <= AUTO_LINE_MAX_VERTICAL then
    completePointToPointLap()
  end
end

local function updateAutoLap(dtSim)
  local px, py, pz = obj:getPositionXYZ()
  if not startGateConfig.startLineSet or not sessionState.autoLapEnabled or sessionState.raceMode then
    sessionState.autoLapGateState = sessionState.autoLapEnabled and "raceControlled" or "off"
    startGateConfig.resetAutoLapCrossingState()
    startGateConfig.previousPositionX, startGateConfig.previousPositionY, startGateConfig.previousPositionZ = px, py, pz
    return
  end

  sessionState.autoLapCooldown = math.max(0, sessionState.autoLapCooldown - math.max(dtSim, 0))

  local previousSigned = (startGateConfig.previousPositionX - startGateConfig.startLineX) * startGateConfig.startLineNormalX
    + (startGateConfig.previousPositionY - startGateConfig.startLineY) * startGateConfig.startLineNormalY
    + (startGateConfig.previousPositionZ - startGateConfig.startLineZ) * startGateConfig.startLineNormalZ
  local currentSigned = (px - startGateConfig.startLineX) * startGateConfig.startLineNormalX
    + (py - startGateConfig.startLineY) * startGateConfig.startLineNormalY
    + (pz - startGateConfig.startLineZ) * startGateConfig.startLineNormalZ
  sessionState.autoLapLineDistance = currentSigned
  local currentOffsetX = px - startGateConfig.startLineX
  local currentOffsetY = py - startGateConfig.startLineY
  local currentLateralX = currentOffsetX - currentSigned * startGateConfig.startLineNormalX
  local currentLateralY = currentOffsetY - currentSigned * startGateConfig.startLineNormalY
  sessionState.autoLapLateralDistance = math.sqrt(
    currentLateralX * currentLateralX + currentLateralY * currentLateralY
  )
  local moveX = px - startGateConfig.previousPositionX
  local moveY = py - startGateConfig.previousPositionY
  local moveZ = pz - startGateConfig.previousPositionZ
  local moveSquared = moveX * moveX + moveY * moveY + moveZ * moveZ

  -- Latch the last approach-side pose, including the old 0.2 m deadband. A
  -- graphics hitch can therefore jump directly to the far side without
  -- silently losing the crossing between two sampled frames.
  if currentSigned < 0
      and (currentSigned <= -AUTO_LINE_HYSTERESIS or sessionState.autoLapCrossingArmed) then
    startGateConfig.armAutoLapCrossing(px, py, pz, currentSigned)
  end

  -- A restored start parked exactly on its plane uses a virtual approach pose.
  -- Require real vehicle movement before consuming that latch so merely
  -- arming the route cannot start lap 1 while stationary.
  if sessionState.autoLapCrossingArmed and sessionState.autoLapApproachValid and currentSigned >= 0
      and moveSquared >= 0.0025 then
    local segmentX = px - sessionState.autoLapApproachX
    local segmentY = py - sessionState.autoLapApproachY
    local segmentZ = pz - sessionState.autoLapApproachZ
    local segmentSquared = segmentX * segmentX + segmentY * segmentY + segmentZ * segmentZ
    local denominator = currentSigned - sessionState.autoLapApproachSigned
    local amount = denominator > 0.0001
      and clamp(-sessionState.autoLapApproachSigned / denominator, 0, 1) or 1
    local crossX = sessionState.autoLapApproachX + segmentX * amount
    local crossY = sessionState.autoLapApproachY + segmentY * amount
    local crossZ = sessionState.autoLapApproachZ + segmentZ * amount
    local lateralX = crossX - startGateConfig.startLineX
    local lateralY = crossY - startGateConfig.startLineY
    local lateralZ = crossZ - startGateConfig.startLineZ
    local lateralSquared = lateralX * lateralX + lateralY * lateralY
    -- Both positions and the start-line normal are world-space. Deriving the
    -- crossing speed from the signed-distance change avoids rejecting valid
    -- laps on vehicles whose velocity API is expressed in a different frame.
    local forwardSpeed = denominator / math.max(tonumber(dtSim) or 0, 0.001)
    local currentSpeed = obj:getVelocity():length()
    local maximumSegment = math.min(
      AUTO_LINE_MAX_DYNAMIC_SEGMENT,
      math.max(
        AUTO_LINE_BASE_MAX_SEGMENT,
        currentSpeed * math.max(tonumber(dtSim) or 0, 0) * 3 + 12
      )
    )
    startGateConfig.resetAutoLapCrossingState()

    if sessionState.autoLapCooldown > 0 then
      startGateConfig.rejectAutoLapCrossing("cooldown")
    elseif segmentSquared > maximumSegment * maximumSegment then
      startGateConfig.rejectAutoLapCrossing("segmentTooLong")
    elseif lateralSquared > AUTO_LINE_HALF_WIDTH * AUTO_LINE_HALF_WIDTH then
      -- Only a near miss counts as a missed finish; a crossing far off the gate
      -- centre is the plane doubling back through the track, not an attempt, so
      -- ignore it instead of cancelling the lap.
      if lateralSquared <= AUTO_LINE_MAX_LATERAL_MISS * AUTO_LINE_MAX_LATERAL_MISS then
        startGateConfig.rejectAutoLapCrossing("outsideWidth")
      else
        startGateConfig.trace(
          "autolap.ignore", "reason=outsideWidth lateral=%.1f", math.sqrt(lateralSquared)
        )
      end
    elseif math.abs(lateralZ) > AUTO_LINE_MAX_VERTICAL then
      if math.abs(lateralZ) <= AUTO_LINE_MAX_VERTICAL_MISS then
        startGateConfig.rejectAutoLapCrossing("verticalOffset")
      else
        startGateConfig.trace(
          "autolap.ignore", "reason=verticalOffset vertical=%.1f", math.abs(lateralZ)
        )
      end
    elseif forwardSpeed < AUTO_LINE_MIN_FORWARD_SPEED then
      startGateConfig.rejectAutoLapCrossing("tooSlow")
    elseif sessionState.autoLapActive and recordingState.active
        and recordingState.elapsed < AUTO_LAP_MIN_SECONDS
        and not sessionState.reanchorFirstLapAtGate then
      startGateConfig.rejectAutoLapCrossing("minimumLapTime")
    elseif lateralSquared <= AUTO_LINE_HALF_WIDTH * AUTO_LINE_HALF_WIDTH
        and math.abs(lateralZ) <= AUTO_LINE_MAX_VERTICAL
        and forwardSpeed >= AUTO_LINE_MIN_FORWARD_SPEED then
      onAutoLapLineCrossed()
    end
  end

  if previousSigned >= AUTO_LINE_HYSTERESIS and currentSigned <= 0
      and sessionState.autoLapLateralDistance <= AUTO_LINE_HALF_WIDTH
      and math.abs(pz - startGateConfig.startLineZ) <= AUTO_LINE_MAX_VERTICAL then
    startGateConfig.rejectAutoLapCrossing("wrongDirection")
  end

  if sessionState.autoLapDeltaSuppressed then
    sessionState.autoLapGateState = "missed"
  elseif sessionState.autoLapCooldown > 0 then
    sessionState.autoLapGateState = "cooldown"
  elseif currentSigned <= -AUTO_LINE_HYSTERESIS
      and sessionState.autoLapLateralDistance <= AUTO_LINE_HALF_WIDTH then
    sessionState.autoLapGateState = sessionState.autoLapActive and "finishReady" or "startReady"
  elseif math.abs(currentSigned) <= 3
      and sessionState.autoLapLateralDistance <= AUTO_LINE_HALF_WIDTH then
    sessionState.autoLapGateState = "nearLine"
  else
    sessionState.autoLapGateState = sessionState.autoLapActive and "onLap" or "waitingForStart"
  end

  -- While a lap is being recorded against a reference route, clear checkpoints as
  -- the car passes them so the finish can confirm the whole route was driven and
  -- the guide can highlight which checkpoint is next.
  if recordingState.active and startGateConfig.checkpointValidationActive
      and startGateConfig.checkpointValidationActive() then
    startGateConfig.updateCheckpointProgress(px, py)
  end

  -- Point-to-point runs end at the finish gate rather than by re-crossing start.
  updateFinishGate(px, py, pz)

  startGateConfig.previousPositionX, startGateConfig.previousPositionY, startGateConfig.previousPositionZ = px, py, pz
end

local function prepareRace(loadFilename, saveFilename, pbTime, raceProfile)
  if recordingState.active then archiveIncompleteRecording("startChanged") end
  sessionCoordinator.prepareRace()
  startGateConfig.startLineSet = false
  sessionCoordinator.stopRecordingAndPlayback()
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  startGateConfig.disableGhostCamera()
  startGateConfig.deactivateRouteGuide()
  startGateConfig.preparedRaceProfile = raceProfile
  startGateConfig.preparedLoadFilename = loadFilename
  startGateConfig.preparedSaveFilename = saveFilename
  startGateConfig.currentFilename = saveFilename or loadFilename
  playbackState.pbTime = tonumber(pbTime)

  local savedData = loadFilename and jsonReadFile(loadFilename) or nil
  local savedPoints, metadata = normalizeReplay(savedData)
  if savedPoints then
    playbackState.pbTime = playbackState.pbTime or metadata.lapTime
      or (jsonReadFile(loadFilename .. ".time") or {})[1]
    metadata.lapTime = metadata.lapTime or playbackState.pbTime
  end
  if loadFilename or startGateConfig.currentFilename then
    loadGhostLibrary(loadFilename, startGateConfig.currentFilename, savedPoints, metadata)
  else
    clearGhostLibraryMemory()
    playbackState.activeLibraryFilename = nil
  end
  if raceProfile then
    startGateConfig.ensureTimeTrialStart(raceProfile)
    startGateConfig.updateTimeTrialStartStats()
  end
  local readyLabel = raceProfile
    and ("TT start " .. startGateConfig.timeTrialLineId(raceProfile))
    or "Race ready"
  uiRuntimeState.lastMessage = #playbackState.ghosts > 0
    and string.format("%s · %d ghosts", readyLabel, #playbackState.ghosts)
    or readyLabel .. " · no ghost"
  return true
end

local function beginRace(loadFilename, saveFilename, pbTime, raceProfile)
  if not sessionState.racePrepared
      or startGateConfig.preparedLoadFilename ~= loadFilename
      or startGateConfig.preparedSaveFilename ~= saveFilename then
    prepareRace(loadFilename, saveFilename, pbTime, raceProfile)
  else
    playbackState.pbTime = tonumber(pbTime) or playbackState.pbTime
    startGateConfig.preparedRaceProfile = raceProfile
  end

  if startGateConfig.preparedRaceProfile then
    startGateConfig.ensureTimeTrialStart(startGateConfig.preparedRaceProfile)
    startGateConfig.updateTimeTrialStartStats()
  end

  sessionCoordinator.markRaceStarted()
  if #playbackState.points >= 2 then
    playRecording()
  else
    playbackState.active = false
    startGateConfig.trailPlaybackElapsed = 0
    startGateConfig.ghostTrailLingering = false
  end

  startRecording()
end

local function finishRaceLap(filename, lapTime, isBest, continueRace)
  lapTime = tonumber(lapTime)
  if lapTime then
    stopRecording(false)
  else
    archiveIncompleteRecording("invalidLap")
  end
  sessionCoordinator.beginLapCompletion(lapTime)
  local rank, recordCount, stored

  if lapTime and #recordingState.lastRecording > 0 then
    local _
    _, rank, recordCount, stored = addGhostToLibrary(
      recordingState.lastRecording,
      lapTime,
      string.format("Race lap %d", playbackState.nextGhostId),
      "race",
      recordingState.activeSampleInterval
    )
    sessionCoordinator.setLastLapPlacement(rank, recordCount, stored)
  else
    sessionCoordinator.setLastLapPlacement(nil, nil, nil)
  end

  if isBest == true and #recordingState.lastRecording > 0 then
    playbackState.pbTime = lapTime
    if filename then saveRecording(filename, lapTime) end
    syncGhostSelection()
  end
  startGateConfig.updateTimeTrialStartStats()

  if continueRace == true then
    playRecording()
    startRecording()
  else
    sessionCoordinator.stopRecordingAndPlayback()
    startGateConfig.trailPlaybackElapsed = 0
    startGateConfig.ghostTrailLingering = false
    clearGeGhostTrail()
    startGateConfig.disableGhostCamera()
    sessionCoordinator.completeRace()
    startGateConfig.preparedRaceProfile = nil
    uiRuntimeState.lastMessage = isBest and "New personal best" or "Race complete"
  end

  if lapTime and rank then
    notify(lapResultNotice(lapTime, rank, recordCount, stored, isBest == true), 5)
  end
end

local function endRace(reason)
  if recordingState.active then archiveIncompleteRecording(reason or "raceEnded") end
  sessionCoordinator.stopRecordingAndPlayback()
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  clearGeGhostTrail()
  startGateConfig.disableGhostCamera()
  sessionCoordinator.completeRace()
  startGateConfig.preparedRaceProfile = nil
  uiRuntimeState.lastMessage = "Race ended"
end

local function clearRecording()
  sessionCoordinator.stopRecordingAndPlayback()
  startGateConfig.disableGhostCamera()
  sessionCoordinator.clearRecordingSession()
  recordingState.lastRecording = {}
  setPublicRecordPoints({})
  clearGhostLibraryMemory()
  startGateConfig.clearRouteGuide()
  if startGateConfig.syncBestLapLine then startGateConfig.syncBestLapLine() end
  playbackState.duration = 0
  playbackState.elapsed = 0
  playbackState.pbTime = nil
  uiRuntimeState.lastMessage = "Cleared"
end

local function updateRecording(dtSim)
  if not recordingState.active or dtSim <= 0 then return end

  recordingState.elapsed = recordingState.elapsed + dtSim
  recordingState.accumulator = recordingState.accumulator + dtSim

  -- Capture once using the current physics pose. Repeating the same pose to
  -- catch up after a long frame increases file size without adding detail.
  if recordingState.accumulator >= recordingState.activeSampleInterval then
    recordingState.accumulator = recordingState.accumulator % recordingState.activeSampleInterval
    captureSample(recordingState.elapsed)
  end

  if #recordingState.points >= recordingState.maxSamples then
    archiveIncompleteRecording("safetyLimit")
  end
end

function startGateConfig.setGhostCameraMode(mode)
  if not playbackState.setCameraMode(mode) then return false end
  mode = playbackState.cameraMode
  uiRuntimeState.lastMessage = mode == "onboard" and "Ghost camera: onboard" or "Ghost camera: chase"
  return true
end

function startGateConfig.setGhostCameraTarget(id)
  local target = startGateConfig.ghostEntryById(id)
  if not target or not target.displayed or not ensureGhostSamples(target) then
    uiRuntimeState.lastMessage = "Camera target must be a displayed Ghost"
    return false
  end
  playbackState.setCameraTarget(target.id, target.label)
  uiRuntimeState.lastMessage = "Camera target: " .. tostring(target.label or target.id)
  return true
end

function startGateConfig.setGhostCameraEnabled(value)
  if value ~= true then
    startGateConfig.disableGhostCamera("Driver camera restored")
    return true
  end
  if not playbackState.active then
    notify("Start Ghost playback before switching camera", 4)
    return false
  end
  local target = startGateConfig.resolveGhostCameraTarget()
  if not target then
    notify("No displayed Ghost is available for the camera", 4)
    return false
  end
  playbackState.cameraEnabled = true
  playbackState.cameraCursor = 1
  uiRuntimeState.lastMessage = "Ghost camera: " .. tostring(target.label or target.id)
  return true
end

function startGateConfig.handleGhostCameraError(message)
  startGateConfig.disableGhostCamera()
  notify("Ghost camera unavailable · " .. tostring(message or "unknown error"), 5)
  return true
end

function startGateConfig.syncGhostCameraPose()
  if not playbackState.cameraEnabled then return end
  if not playbackState.active then
    startGateConfig.disableGhostCamera("Ghost playback ended · driver camera restored")
    return
  end

  local target = startGateConfig.resolveGhostCameraTarget()
  if not target then
    startGateConfig.disableGhostCamera("Ghost camera target unavailable · driver camera restored")
    return
  end
  local points = target.samples
  if type(points) ~= "table" or #points < 2 then
    startGateConfig.disableGhostCamera("Ghost camera target has no replay samples")
    return
  end

  playbackState.cameraCursor = clamp(
    tonumber(playbackState.cameraCursor) or 1,
    1,
    #points - 1
  )
  if playbackState.elapsed < (points[playbackState.cameraCursor][TIME] or 0) then
    playbackState.cameraCursor = 1
  end
  while playbackState.cameraCursor < #points - 1
      and points[playbackState.cameraCursor + 1][TIME] <= playbackState.elapsed do
    playbackState.cameraCursor = playbackState.cameraCursor + 1
  end

  local first = points[playbackState.cameraCursor]
  local second = points[math.min(playbackState.cameraCursor + 1, #points)]
  local span = math.max((second[TIME] or 0) - (first[TIME] or 0), 0.000001)
  local amount = clamp((playbackState.elapsed - (first[TIME] or 0)) / span, 0, 1)
  poseMath.interpolate(cameraPose, first, second, amount)
  startGateConfig.queueGeGhostCamera({
    cameraPose.position.x, cameraPose.position.y, cameraPose.position.z,
    cameraPose.front.x, cameraPose.front.y, cameraPose.front.z,
    cameraPose.up.x, cameraPose.up.y, cameraPose.up.z
  }, true, target.id, target.label)
end

local function updatePlaybackClock(dtSim)
  if not playbackState.active then return false end

  if startGateConfig.ghostStartHoldFrames > 0 then
    startGateConfig.ghostStartHoldFrames = startGateConfig.ghostStartHoldFrames - 1
    return true
  end
  if dtSim <= 0 then return false end

  playbackState.elapsed = playbackState.elapsed + dtSim
  startGateConfig.trailPlaybackElapsed = startGateConfig.trailPlaybackElapsed + dtSim
  if playbackState.duration <= 0 then
    stopPlayback()
    return false
  end

  if playbackState.elapsed >= playbackState.duration then
    if displayState.loopPlayback and not sessionState.raceMode then
      playbackState.elapsed = playbackState.elapsed % playbackState.duration
      -- Visual Ghosts loop on their own clock, but the player's current-lap
      -- position comparison must remain near the end of the reference lap.
      -- Resetting progressIndex here makes a slower player approaching a
      -- closed start/finish line match the time-zero sample and show a huge
      -- false positive delta.
      resetGhostCursors(false)
    else
      stopPlayback(true)
      return false
    end
  end

  while playbackState.cursor < #playbackState.points - 1
      and playbackState.points[playbackState.cursor + 1][TIME]
        <= playbackState.elapsed do
    playbackState.cursor = playbackState.cursor + 1
  end

  return true
end

local function drawGhostSamples(points, cursor, lineColor)
  return wireframeRenderer.drawSamples(points, cursor, playbackState.elapsed, lineColor)
end

local shellSync = require("vehicle/ghostRacer/shellSync").new({
  object = obj,
  maximumGhosts = MAX_SHELL_BODIES,
  senderLiteral = startGateConfig.senderLiteral
})
runtimeContext:registerService("shellSync", shellSync)

-- The shell is opt-in, bounded to display modes that show a small set of
-- Ghosts, and disabled for the rest of the session as soon as the GE side
-- reports that this build or vehicle cannot provide one.
local function shellRenderingEnabled()
  return displayState.ghostRenderMode == "shell"
    and SHELL_DISPLAY_MODES[displayState.ghostDisplayMode] == true
    and not (displayState.ghostDisplayMode == "top"
      and displayState.topGhostCount > MAX_SHELL_GHOSTS)
    and startGateConfig.ghostShellUnavailableReason == nil
end

local function collectShellCandidates()
  local candidates = {}
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    if entry.displayed and entry.file and type(entry.samples) == "table"
        and #entry.samples >= 2 then
      candidates[#candidates + 1] = entry
      if #candidates >= MAX_SHELL_BODIES then break end
    end
  end
  return candidates
end

-- 2.16.9 removed prewarming after reading an idle frame rate of exactly 30.0
-- as the cost of holding a pooled vehicle. It was not: the same 30.0, with the
-- same 33.5 ms worst frame, appears with no Ghost vehicle in the world at all
-- and lifts the moment the player touches anything. That is BeamNG's own idle
-- throttle, and removing prewarm only restored the five-second Start Line stall
-- prewarm existed to prevent.
local function prewarmGhostShells()
  if not shellRenderingEnabled() or playbackState.active or not displayState.visible then
    return false
  end
  local candidates = collectShellCandidates()
  if #candidates == 0 then return false end
  if shellSync.pushPrewarm(candidates) then
    startGateConfig.trace(
      "shell.prewarm", "requested=%d mode=%s",
      #candidates, tostring(displayState.ghostDisplayMode)
    )
    return true
  end
  return false
end

local function updateGhostShells()
  if not shellRenderingEnabled() or not playbackState.active or not displayState.visible then
    if startGateConfig.ghostShellActive then
      startGateConfig.ghostShellActive = false
      startGateConfig.confirmedShellIds = {}
      startGateConfig.shelledGhostIds = {}
      shellSync.clearShells()
    end
    return
  end

  -- The set follows what is displayed and only carries where each recording
  -- lives; the renderer reads the samples and resolves poses on its own frames.
  local candidates = collectShellCandidates()
  local shelled = {}
  for index = 1, #candidates do
    shelled[tostring(candidates[index].id)] = true
  end

  if shellSync.pushSet(candidates) then
    -- A changed set must earn a fresh all-bodies-visible acknowledgement.
    -- Keeping the previous confirmation hides the new wireframe while its
    -- pooled vehicle is still completing the Ghost/freeze handshake.
    startGateConfig.ghostShellConfirmed = false
    startGateConfig.confirmedShellIds = {}
    startGateConfig.shelledGhostIds = {}
    local models = {}
    for index = 1, #candidates do
      models[#models + 1] = tostring(candidates[index].id) .. "=" ..
        tostring(candidates[index].vehicle or "unknown_vehicle")
    end
    startGateConfig.trace(
      "shell.request", "ghosts=%d [%s]", #candidates, table.concat(models, ", ")
    )
  end

  -- The wireframe is only suppressed once the GE side has confirmed it really
  -- drew a body. Suppressing it optimistically left nothing on screen at all
  -- whenever the shell could not be created.
  -- Suppression is per Ghost: only the ones GE says it is actually drawing.
  local confirmed = startGateConfig.confirmedShellIds or {}
  local suppressed = {}
  local suppressedCount = 0
  for id in pairs(shelled) do
    if confirmed[id] then
      suppressed[id] = true
      suppressedCount = suppressedCount + 1
    end
  end
  local suppressing = suppressedCount > 0
  startGateConfig.shelledGhostIds = suppressed
  if suppressing ~= (startGateConfig.shellSuppressingWireframe == true) then
    startGateConfig.shellSuppressingWireframe = suppressing
    -- Drawing both at once puts two copies of the same lap on screen a short
    -- distance apart, which reads as flicker rather than as two Ghosts.
    startGateConfig.trace(
      "shell.wireframe", "suppressed=%d of=%d confirmed=%s",
      suppressedCount, #candidates, tostring(startGateConfig.ghostShellConfirmed)
    )
  end
  local wasActive = startGateConfig.ghostShellActive == true
  startGateConfig.ghostShellActive = #candidates > 0
  if startGateConfig.ghostShellActive ~= wasActive then
    -- trail= tells apart the two suspects that both grow with playback time;
    -- heapKb says whether this VM is the one accumulating something, since the
    -- decay compounds even with the player parked and the Ghost nearby.
    local heapOk, heapKb = pcall(collectgarbage, "count")
    startGateConfig.trace(
      "shell.state", "active=%s bodies=%d mode=%s trail=%s trailSeconds=%d heapKb=%d",
      tostring(startGateConfig.ghostShellActive), #candidates,
      tostring(displayState.ghostDisplayMode),
      tostring(displayState.ghostTrailVisible),
      math.floor(tonumber(displayState.ghostTrailSeconds) or 0),
      math.floor(heapOk and tonumber(heapKb) or -1)
    )
  end
  -- Force a GE clock resync when a new lap has just reset the playback clock to
  -- zero. Without it a seamless lap restart (the shells never went inactive)
  -- sends elapsed=0, which GE treats as a stale backward heartbeat and ignores,
  -- leaving its clock at the previous lap's end so every body is past its own
  -- duration and hides -- the Ghosts silently drop to wireframe on lap 2+. The
  -- inactive-state change already forces a resync; this covers the seamless case.
  local forceClock = wasActive ~= startGateConfig.ghostShellActive
    or startGateConfig.shellClockResyncPending == true
  startGateConfig.shellClockResyncPending = false
  shellSync.pushClock(
    playbackState.elapsed,
    true,
    playbackState.duration,
    displayState.loopPlayback and not sessionState.raceMode,
    forceClock
  )
end

function startGateConfig.clearGhostShells(releasePool)
  startGateConfig.ghostShellActive = false
  startGateConfig.ghostShellConfirmed = false
  startGateConfig.confirmedShellIds = {}
  startGateConfig.shellSuppressingWireframe = false
  startGateConfig.shelledGhostIds = {}
  if releasePool == true then
    shellSync.releasePool()
  else
    shellSync.reset()
    shellSync.clearShells()
  end
end

local trailRenderer = require("vehicle/ghostRacer/trailRenderer").new({
  state = startGateConfig,
  object = obj,
  bestGhostEntry = bestGhostEntry,
  ensureGhostSamples = ensureGhostSamples,
  drawGhostSamples = drawGhostSamples,
  getTrailMode = function() return displayState.ghostTrailMode end,
  clamp = clamp,
  trailInterval = GHOST_TRAIL_INTERVAL,
  indexes = {
    time = TIME,
    posX = POS_X, posY = POS_Y, posZ = POS_Z,
    speed = SPEED,
    throttle = THROTTLE, brake = BRAKE, gear = GEAR, handbrake = HANDBRAKE, clutch = CLUTCH
  }
})
runtimeContext:registerService("trailRenderer", trailRenderer)
startGateConfig.syncBestLapLine = trailRenderer.syncBestLapLine
startGateConfig.setBestLapLineVisible = trailRenderer.setBestLapLineVisible
startGateConfig.setClutchLineVisible = trailRenderer.setClutchLineVisible
startGateConfig.setHandbrakeLineVisible = trailRenderer.setHandbrakeLineVisible
startGateConfig.trailSampleIndexAtOrBefore = trailRenderer.trailSampleIndexAtOrBefore

function startGateConfig.setLiveInputTrailVisible(value)
  startGateConfig.liveInputTrailVisible = value == true
  startGateConfig.liveInputTrailAccumulator = 0
  startGateConfig.liveInputTrailCaptureAccumulator = 0
  -- Start each session fresh; clear the drawn trail when turning it off.
  startGateConfig.liveInputTrailBuffer = {}
  if not startGateConfig.liveInputTrailVisible then
    startGateConfig.liveInputTrailDrawn = false
    trailRenderer.syncLiveInputTrail(nil, 0, 0, false)
  end
  return true
end

function startGateConfig.setLiveInputTrailMaxSegments(value)
  local allowed = {[100] = true, [250] = true, [500] = true, [1000] = true, [2000] = true}
  local requested = math.floor(tonumber(value) or startGateConfig.liveInputTrailMaxSegments)
  if not allowed[requested] then return false end
  startGateConfig.liveInputTrailMaxSegments = requested
  return true
end
startGateConfig.appendGhostTrailWindow = trailRenderer.appendGhostTrailWindow

local function drawGhost(encodedTrailSegments)
  -- Shell poses are resolved first so the wireframe pass can skip any Ghost
  -- that is already represented by a solid body.
  updateGhostShells()
  playbackState.cursor = trailRenderer.draw(encodedTrailSegments, {
    shelledGhostIds = startGateConfig.shelledGhostIds,
    ghostTrailVisible = displayState.ghostTrailVisible,
    ghostTrailSeconds = displayState.ghostTrailSeconds,
    loopPlayback = displayState.loopPlayback,
    playing = playbackState.active,
    playbackDuration = playbackState.duration,
    playbackElapsed = playbackState.elapsed,
    playbackIndex = playbackState.cursor,
    visible = displayState.visible,
    ghostLibrary = playbackState.ghosts,
    playbackPoints = playbackState.points,
    debugColor = displayState.debugColor
  })
end
local progressMatcher = require("vehicle/ghostRacer/progressMatcher").new({
  object = obj,
  maximumDistanceSquared = MAX_MATCH_DISTANCE_SQUARED,
  indexes = {
    posX = POS_X, posY = POS_Y, posZ = POS_Z,
    frontX = FRONT_X, frontY = FRONT_Y, frontZ = FRONT_Z
  }
})
runtimeContext:registerService("progressMatcher", progressMatcher)

local function findProgressSample()
  local sample, matchedIndex = progressMatcher.find(
    recordingState.active,
    playbackState.points,
    playbackState.progressCursor
  )
  playbackState.progressCursor = matchedIndex
  return sample
end

-- Live standings: while recording a lap, rank the player against the Ghosts that
-- are actually on track right now -- the currently displayed ones, minus manual
-- Runs and any that have finished and vanished -- by time-to-here, the same basis
-- as the DELTA readout. A Ghost that reached the player's current position in
-- less time is ahead. Each Ghost keeps a downsampled trajectory and the rank is
-- recomputed a few times a second rather than every frame.
local RANK_TRAJECTORY_INTERVAL = 0.15
local RANK_MATCH_MAX_DISTANCE_SQ = 900 -- 30 m; further means a different part of the track
-- Building a trajectory loads and downsamples a Ghost's full samples. Cap how
-- many are built per rank tick so a large library does not stall the first lap
-- all at once; the rest are picked up over the next few ticks and then cached.
local RANK_TRAJECTORY_BUILDS_PER_TICK = 3
local rankTrajectoryBuildBudget = 0

local function ensureRankTrajectory(entry)
  if type(entry.rankTrajectory) == "table" then return entry.rankTrajectory end
  if rankTrajectoryBuildBudget <= 0 then return nil end
  rankTrajectoryBuildBudget = rankTrajectoryBuildBudget - 1
  local hadResidentSamples = type(entry.samples) == "table" and #entry.samples >= 2
  if not hadResidentSamples and not ensureGhostSamples(entry) then return nil end
  local samples = entry.samples
  if type(samples) ~= "table" or #samples < 2 then return nil end
  local trajectory = {}
  local lastTime = -math.huge
  for index = 1, #samples do
    local sample = samples[index]
    local time = tonumber(sample[TIME]) or 0
    if index == 1 or index == #samples or (time - lastTime) >= RANK_TRAJECTORY_INTERVAL then
      trajectory[#trajectory + 1] = {
        [TIME] = time,
        [POS_X] = sample[POS_X], [POS_Y] = sample[POS_Y], [POS_Z] = sample[POS_Z],
        [SPEED] = sample[SPEED],
        sampleIndex = index
      }
      lastTime = time
    end
  end
  entry.rankTrajectory = trajectory
  entry.rankCursor = 1
  -- Free the full samples if we loaded them only to build this and the display
  -- system is not otherwise keeping them resident.
  if not hadResidentSamples and not entry.displayed then entry.samples = nil end
  return trajectory
end

local function resetRankCursors()
  for index = 1, #playbackState.ghosts do
    playbackState.ghosts[index].rankCursor = 1
  end
end
startGateConfig.resetRankCursors = resetRankCursors

-- Returns the Ghost's elapsed time at (nearest to) the player's current position,
-- or "behind" when it never reached this far, or nil when it cannot be matched.
-- Returns the Ghost's trajectory point nearest the player's position (carrying
-- its TIME and SPEED), or "behind" when the Ghost ended before reaching here, or
-- nil when it cannot be matched around the cursor.
local function ghostPointAtPosition(entry, px, py, pz)
  local trajectory = ensureRankTrajectory(entry)
  if not trajectory or #trajectory == 0 then return nil end
  local cursor = entry.rankCursor or 1
  local firstIndex = math.max(1, cursor - 20)
  local lastIndex = math.min(#trajectory, cursor + 200)
  local bestIndex, bestDistance = nil, math.huge
  for index = firstIndex, lastIndex do
    local point = trajectory[index]
    local dx = point[POS_X] - px
    local dy = point[POS_Y] - py
    local dz = point[POS_Z] - pz
    local distance = dx * dx + dy * dy + dz * dz
    if distance < bestDistance then bestDistance = distance; bestIndex = index end
  end
  if not bestIndex then return nil end
  entry.rankCursor = bestIndex
  if bestDistance > RANK_MATCH_MAX_DISTANCE_SQ then
    -- The nearest point around the cursor is far away. If that is the Ghost's
    -- final point, it ended before reaching here, so the player is ahead of it.
    if bestIndex >= #trajectory then return "behind" end
    return nil
  end
  return trajectory[bestIndex]
end

local function computeLiveRank()
  if not recordingState.active then
    startGateConfig.liveRank = nil
    startGateConfig.liveRankTotal = nil
    startGateConfig.liveDelta = nil
    startGateConfig.liveSpeedDelta = nil
    return
  end
  local px, py, pz = obj:getPositionXYZ()
  local myTime = recordingState.elapsed
  local mySpeed = obj:getVelocity():length()
  local playbackElapsed = playbackState.elapsed
  local looping = displayState.loopPlayback
  rankTrajectoryBuildBudget = RANK_TRAJECTORY_BUILDS_PER_TICK
  local ahead, participants = 0, 0
  local leaderTime, leaderEntry, leaderPoint = nil, nil, nil
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    -- Only rank against Ghosts that are actually on the track right now: those
    -- currently displayed, not a manual Run, and not already finished and gone
    -- (a play-once Ghost past its own end has vanished, so it drops out).
    local onTrack = entry.displayed == true
      and not ghostIsManual(entry)
      and (looping or (tonumber(entry.duration) or 0) >= playbackElapsed)
    if onTrack then
      participants = participants + 1
      local point = ghostPointAtPosition(entry, px, py, pz)
      if type(point) == "table" then
        local ghostTime = point[TIME]
        if type(ghostTime) == "number" then
          if ghostTime < myTime then ahead = ahead + 1 end
          -- Track the best (earliest to here) Ghost on track -- completed OR
          -- incomplete -- so the DELTA reflects the whole field, not just laps.
          if not leaderTime or ghostTime < leaderTime then
            leaderTime = ghostTime
            leaderEntry = entry
            leaderPoint = point
          end
        end
      end
    end
  end
  startGateConfig.liveRank = ahead + 1
  startGateConfig.liveRankTotal = participants + 1

  -- DELTA/SPEED Δ against the best reference on track (incompletes included).
  -- Once a leader is chosen it ALWAYS drives the delta -- never fall back to a
  -- different (e.g. completed) Ghost, which would show the wrong sign. The
  -- downsampled trajectory is enough to pick the leader but too coarse for the
  -- headline number, so refine against the leader's full samples in a window
  -- anchored on the matched trajectory point (reliable, no cursor drift).
  startGateConfig.liveDelta = nil
  startGateConfig.liveSpeedDelta = nil
  if leaderEntry and leaderPoint then
    local refTime, refSpeed = leaderPoint[TIME], leaderPoint[SPEED]
    local samples = leaderEntry.samples
    if type(samples) == "table" and #samples >= 2 then
      local anchor = tonumber(leaderPoint.sampleIndex) or 1
      local firstIndex = math.max(1, anchor - 120)
      local lastIndex = math.min(#samples, anchor + 120)
      local bestIndex, bestDistance = nil, math.huge
      for index = firstIndex, lastIndex do
        local sample = samples[index]
        local dx = sample[POS_X] - px
        local dy = sample[POS_Y] - py
        local dz = sample[POS_Z] - pz
        local distance = dx * dx + dy * dy + dz * dz
        if distance < bestDistance then bestDistance = distance; bestIndex = index end
      end
      if bestIndex then
        refTime = samples[bestIndex][TIME]
        refSpeed = samples[bestIndex][SPEED]
      end
    end
    if type(refTime) == "number" then
      startGateConfig.liveDelta = myTime - refTime
      if type(refSpeed) == "number" and refSpeed > 0 then
        startGateConfig.liveSpeedDelta = (mySpeed - refSpeed) * 3.6
      end
    end
  end

  -- Trace only when the leader identity changes, so the log shows which Ghost the
  -- DELTA is measured against (and whether it is the incomplete) without spamming.
  local leaderId = leaderEntry and tostring(leaderEntry.id) or "none"
  if leaderId ~= startGateConfig.lastLeaderId then
    startGateConfig.lastLeaderId = leaderId
    startGateConfig.trace(
      "rank.leader",
      "id=%s incomplete=%s leaderTime=%.3f myTime=%.3f delta=%s participants=%d",
      leaderId, tostring(leaderEntry and ghostIsIncomplete(leaderEntry) or false),
      tonumber(leaderTime) or -1, myTime,
      tostring(startGateConfig.liveDelta), participants
    )
  end
end

uiRuntimeState.setSnapshotBuilder(function()
  return {
      recording = recordingState.active,
      playing = playbackState.active,
      visible = displayState.visible,
      loopPlayback = displayState.loopPlayback,
      raceMode = sessionState.raceMode,
      autoLapEnabled = sessionState.autoLapEnabled,
      autoLapActive = sessionState.autoLapActive,
      startLineSet = startGateConfig.startLineSet,
      finishLineSet = startGateConfig.finishLineSet == true,
      startGateVisible = displayState.startGateVisible,
      ghostTrailVisible = displayState.ghostTrailVisible,
      ghostTrailMode = displayState.ghostTrailMode,
      ghostTrailSeconds = displayState.ghostTrailSeconds,
      autoLapNumber = sessionState.autoLapNumber,
      lastLapTime = sessionState.lastLapTime,
      lastLapRank = sessionState.lastLapRank,
      lastLapRecordCount = sessionState.lastLapRecordCount,
      lastLapStored = sessionState.lastLapStored,
      autoLapLineDistance = sessionState.autoLapLineDistance,
      autoLapLateralDistance = sessionState.autoLapLateralDistance,
      autoLapGateState = sessionState.autoLapGateState,
      autoLapLastReject = sessionState.autoLapLastReject,
      autoLapCrossingArmed = sessionState.autoLapCrossingArmed,
      autoLapDeltaSuppressed = sessionState.autoLapDeltaSuppressed,
      sampleRate = recordingState.sampleRate,
      currentQuality = displayState.quality,
      currentColorName = displayState.colorName,
      ghostDisplayMode = displayState.ghostDisplayMode,
      topGhostCount = displayState.topGhostCount,
      showIncomplete = displayState.showIncomplete,
      ghostCategoryFilter = displayState.ghostCategoryFilter,
      showManual = displayState.showManual,
      ghostRenderMode = displayState.ghostRenderMode,
      ghostShellActive = startGateConfig.ghostShellActive == true,
      ghostShellConfirmed = startGateConfig.ghostShellConfirmed == true,
      ghostShellUnavailableReason = startGateConfig.ghostShellUnavailableReason,
      ghostCameraEnabled = playbackState.cameraEnabled,
      ghostCameraMode = playbackState.cameraMode,
      ghostCameraTargetId = playbackState.cameraTargetId,
      ghostCameraTargetLabel = playbackState.cameraTargetLabel,
      recordElapsed = recordingState.elapsed,
      -- Live standings only mean something during a lap; never surface a value
      -- left over from the previous one.
      liveRank = recordingState.active and startGateConfig.liveRank or nil,
      liveRankTotal = recordingState.active and startGateConfig.liveRankTotal or nil,
      liveDelta = recordingState.active and startGateConfig.liveDelta or nil,
      liveSpeedDelta = recordingState.active and startGateConfig.liveSpeedDelta or nil,
      playbackElapsed = playbackState.elapsed,
      playbackDuration = playbackState.duration,
      currentPbTime = playbackState.pbTime,
      lastMessage = uiRuntimeState.lastMessage,
      ghostLibrary = playbackState.ghosts,
      pendingImport = playbackState.pendingImport and playbackState.pendingImport.ui or nil,
      playbackPoints = playbackState.points,
      lastRecording = recordingState.lastRecording,
      recordPoints = recordingState.points
  }
end)

local uiStateBuilder = require("vehicle/ghostRacer/uiStateBuilder").new({
  state = startGateConfig,
  getRuntime = uiRuntimeState.snapshot,
  findProgressSample = findProgressSample,
  getCurrentSpeed = function() return obj:getVelocity():length() end,
  vehicle = sanitizePathPart(v.data.vehicleDirectory, "unknown_vehicle"),
  codeVersion = CODE_VERSION,
  startLineHalfWidth = AUTO_LINE_HALF_WIDTH,
  maxStoredGhosts = MAX_STORED_GHOSTS,
  maxStoredIncompleteGhosts = MAX_STORED_INCOMPLETE_GHOSTS,
  maxStoredManualGhosts = MAX_STORED_MANUAL_GHOSTS,
  clamp = clamp,
  indexes = {time = TIME, speed = SPEED}
})
runtimeContext:registerService("uiStateBuilder", uiStateBuilder)
startGateConfig.buildUiState = uiStateBuilder.build
function startGateConfig.sendUiState()
  if guihooks and guihooks.trigger then
    guihooks.trigger("GhostRacerState", startGateConfig.buildUiState())
  end
end

function startGateConfig.requestState()
  startGateConfig.sendUiState()
end

function startGateConfig.setUiOwnerToken(token)
  local nextToken = token ~= nil and tostring(token) or nil
  if nextToken ~= startGateConfig.uiOwnerToken then
    startGateConfig.trace(
      "ui.claim", "owner change previous=%s next=%s",
      tostring(startGateConfig.uiOwnerToken), tostring(nextToken)
    )
    startGateConfig.uiOwnerToken = nextToken
    startGateConfig.trace("ui.claim", "owner active")
  end
  return true
end

function startGateConfig.getCodeVersion()
  return CODE_VERSION
end

function startGateConfig.getRuntimeContextSnapshot()
  return runtimeContext:snapshot()
end

function startGateConfig.getRuntimeContextStateSnapshot(name)
  return runtimeContext:snapshotState(name)
end

function startGateConfig.invalidateRuntimeContext(reason)
  return runtimeContext:invalidate(reason or "vehicle controller unload")
end

function startGateConfig.update(dtSim)
  updateRecording(dtSim)

  -- Capture the driven car's own pose + inputs into a rolling buffer while the
  -- debug live input trail is on, so it shows even without a lap recording.
  if startGateConfig.liveInputTrailVisible and dtSim > 0 then
    startGateConfig.liveInputTrailTime = (startGateConfig.liveInputTrailTime or 0) + dtSim
    startGateConfig.liveInputTrailCaptureAccumulator =
      (startGateConfig.liveInputTrailCaptureAccumulator or 0) + dtSim
    if startGateConfig.liveInputTrailCaptureAccumulator >= LIVE_TRAIL_CAPTURE_INTERVAL then
      startGateConfig.liveInputTrailCaptureAccumulator = 0
      local throttle, brake, gear, handbrake, clutch = readDriverInputs()
      local buffer = startGateConfig.liveInputTrailBuffer
      buffer[#buffer + 1] = replayCodec.captureSample(
        obj, startGateConfig.liveInputTrailTime, throttle, brake, gear, handbrake, clutch
      )
      -- Rolling window: keep only the most recent points, dropping the oldest, so
      -- the live trail always shows recent driving instead of an ever-growing (and
      -- eventually truncated) history. Capped by the max-segments setting.
      local cap = math.min(
        MAX_LIVE_TRAIL_POINTS,
        math.max(2, tonumber(startGateConfig.liveInputTrailMaxSegments) or 500)
      )
      while #buffer > cap do table.remove(buffer, 1) end
    end
  end
end

function startGateConfig.updateGFX(dtSim)
  updateAutoLap(dtSim)
  -- Recompute live standings every render frame so the RANK and DELTA readouts
  -- stay smooth. It only scans the on-track (displayed) Ghosts, so it is cheap.
  computeLiveRank()
  -- Vehicle creation is deliberately moved off the Start Line path. While the
  -- replay is idle GE prepares hidden, frozen native bodies one at a time;
  -- playback itself only reuses those bodies and otherwise remains wireframe.
  prewarmGhostShells()
  local playbackWasRunning = playbackState.active
  updatePlaybackClock(dtSim)
  if startGateConfig.ghostTrailLingering and not playbackWasRunning then
    startGateConfig.trailPlaybackElapsed = startGateConfig.trailPlaybackElapsed + math.max(dtSim, 0)
    if startGateConfig.trailPlaybackElapsed - playbackState.duration
        >= displayState.ghostTrailSeconds then
      startGateConfig.ghostTrailLingering = false
      playbackState.elapsed = 0
      startGateConfig.trailPlaybackElapsed = 0
      clearGeGhostTrail()
    end
  end
  uiRuntimeState.trailSyncAccumulator = uiRuntimeState.trailSyncAccumulator + math.max(dtSim, 0)
  local shouldSyncTrail = (playbackState.active or startGateConfig.ghostTrailLingering)
    and displayState.visible and displayState.ghostTrailVisible
    and uiRuntimeState.trailSyncAccumulator >= GHOST_TRAIL_SYNC_INTERVAL
  local encodedTrailSegments = shouldSyncTrail and {} or nil
  drawGhost(encodedTrailSegments)
  startGateConfig.syncGhostCameraPose()
  if shouldSyncTrail then
    uiRuntimeState.trailSyncAccumulator = uiRuntimeState.trailSyncAccumulator % GHOST_TRAIL_SYNC_INTERVAL
    queueGeGhostTrail(encodedTrailSegments, true)
  elseif uiRuntimeState.geTrailVisible and (not playbackState.active
      and not startGateConfig.ghostTrailLingering
      or not displayState.visible or not displayState.ghostTrailVisible) then
    clearGeGhostTrail()
  end

  -- Debug live input trail: rebuild a few times a second from the rolling capture
  -- buffer (filled in update while the toggle is on, with or without a lap).
  if startGateConfig.liveInputTrailVisible then
    startGateConfig.liveInputTrailAccumulator =
      (startGateConfig.liveInputTrailAccumulator or 0) + math.max(dtSim, 0)
    if startGateConfig.liveInputTrailAccumulator >= 0.2 then
      startGateConfig.liveInputTrailAccumulator = 0
      local buffer = startGateConfig.liveInputTrailBuffer
      if type(buffer) == "table" and #buffer >= 2 then
        trailRenderer.syncLiveInputTrail(
          buffer, 0, startGateConfig.liveInputTrailMaxSegments, true
        )
        startGateConfig.liveInputTrailDrawn = true
      elseif startGateConfig.liveInputTrailDrawn then
        trailRenderer.syncLiveInputTrail(nil, 0, 0, false)
        startGateConfig.liveInputTrailDrawn = false
      end
    end
  end

  uiRuntimeState.uiAccumulator = uiRuntimeState.uiAccumulator + math.max(dtSim, 0)
  if uiRuntimeState.uiAccumulator >= UI_UPDATE_INTERVAL then
    uiRuntimeState.uiAccumulator = uiRuntimeState.uiAccumulator % UI_UPDATE_INTERVAL
    startGateConfig.sendUiState()
  end
end

-- A native Ghost vehicle is spawned by this mod itself and must never behave
-- like a driven one: it owns no Saved Start, claims no HUD and pushes no world
-- state. The auto-loader tries to keep the controller out of those VMs
-- entirely, but `getName`/`getJBeamFilename` are not reliable that early, so
-- the same check is repeated here where `v.data` is populated for certain.
--
-- `simple_traffic` is BeamNG's optimized AI-only representation. A player never
-- drives one, so treating it as dormant costs nothing and removes three idle
-- controller instances from every frame while native Ghosts exist.
local function vehicleIsNativeGhost()
  local directory = v and v.data and v.data.vehicleDirectory
  if type(directory) ~= "string" then return false end
  return directory:lower():find("simple_traffic", 1, true) ~= nil
end

function startGateConfig.init()
  runtimeContext:updateRuntime({
    object = obj,
    vehicleData = v and v.data or nil,
    objectId = startGateConfig.getObjectId(),
    vehicleDirectory = v and v.data and v.data.vehicleDirectory or "unknown_vehicle"
  })
  if vehicleIsNativeGhost() then
    startGateConfig.dormant = true
    startGateConfig.trace(
      "controller.dormant", "native Ghost vehicle directory=%s",
      tostring(v and v.data and v.data.vehicleDirectory)
    )
    return
  end
  runtimeContext:activate("controller init")
  startGateConfig.trace("controller.init", "initializing vehicle controller")
  local refNodeData = v.data.refNodes and v.data.refNodes[0]
  if not refNodeData then
    notify("Ghost Racer: vehicle has no reference node", 5)
    return
  end
  wireframeRenderer.init(v.data, obj)
  startGateConfig.trace("controller.init", "ready")
  startGateConfig.sendUiState()
end

function startGateConfig.reset()
  -- Diagnostic: which reset kinds reach this hook, and is a lap still recording
  -- when they do? Pressing R (reset-to-recovery) is reported not to save an
  -- incomplete while Insert (recover-in-place) does, and this line's presence or
  -- absence in the log after each says whether the hook even fired.
  startGateConfig.trace("controller.reset", "recording=%s recordedPoints=%d livePoints=%d",
    tostring(recordingState.active), #recordingState.lastRecording, #recordingState.points)
  local archivedMessage = nil
  if recordingState.active then
    local _, _, message = archiveIncompleteRecording("vehicleReset")
    archivedMessage = message
  end
  if playbackState.pendingImport then playbackState.pendingImport = nil end
  runtimeContext:markReset("vehicle reset")
  sessionCoordinator.stopRecordingAndPlayback()
  startGateConfig.trailPlaybackElapsed = 0
  startGateConfig.ghostTrailLingering = false
  startGateConfig.ghostStartHoldFrames = 0
  sessionCoordinator.softReset()
  setPublicRecordPoints({})
  startGateConfig.disableGhostCamera()
  clearGeGhostTrail(true)
  if startGateConfig.routeReady then startGateConfig.activateRouteGuide() end
  if startGateConfig.startLineSet then rememberCurrentPosition(0) end
  startGateConfig.syncMarkers()
  -- The archive's own "saved" toast fires mid-reset and is then overwritten by
  -- the reset's status line (and can be lost behind the game's own reset
  -- feedback), so a player who pressed R saw no confirmation even though the
  -- partial was saved. Re-announce it as the very last thing instead.
  if archivedMessage then
    -- Re-announce the archive's own verdict (saved vs. not kept) through the GE
    -- VM so it renders after the reset settles instead of being wiped by the
    -- reset's own UI teardown -- pressing R showed no toast because of that wipe.
    notifyViaGe(archivedMessage, 5)
  else
    uiRuntimeState.lastMessage = sessionState.autoLapEnabled and "Auto lap armed after reset" or "Ready"
  end
  startGateConfig.sendUiState()
end

M.init = startGateConfig.init
M.reset = function(...)
  if startGateConfig.dormant then return end
  return startGateConfig.reset(...)
end
-- A dormant instance belongs to a native Ghost vehicle this mod spawned. It
-- keeps its per-frame hooks registered but does no work at all, so three of
-- them cannot cost frames while the player is driving.
M.update = function(...)
  if startGateConfig.dormant then return end
  return startGateConfig.update(...)
end
M.updateGFX = function(...)
  if startGateConfig.dormant then return end
  return startGateConfig.updateGFX(...)
end

M.startRecording = startRecording
M.stopRecording = stopRecording
M.playRecording = playRecording
M.playGhost = playGhost
M.stopPlayback = stopPlayback
M.saveRecording = saveRecording
M.loadRecording = loadRecording
M.loadTime = loadTime
M.clearRecording = clearRecording

M.beginRace = beginRace
M.prepareRace = prepareRace
M.finishRaceLap = finishRaceLap
M.endRace = endRace

M.setDetail = setDetail
M.setQuality = setQuality
M.setSampleRate = setSampleRate
M.setVisible = setVisible
M.setStartGateVisible = setStartGateVisible
M.setGhostTrailVisible = setGhostTrailVisible
M.setGhostTrailMode = setGhostTrailMode
M.setGhostTrailSeconds = setGhostTrailSeconds
M.setBestLapLineVisible = startGateConfig.setBestLapLineVisible
M.setClutchLineVisible = startGateConfig.setClutchLineVisible
M.setHandbrakeLineVisible = startGateConfig.setHandbrakeLineVisible
M.setLiveInputTrailVisible = startGateConfig.setLiveInputTrailVisible
M.setLiveInputTrailMaxSegments = startGateConfig.setLiveInputTrailMaxSegments
M.setRouteGuideEnabled = startGateConfig.setRouteGuideEnabled
M.setRoutePathVisible = startGateConfig.setRoutePathVisible
M.setRouteCheckpointsVisible = startGateConfig.setRouteCheckpointsVisible
M.setRouteCheckpointSpacing = startGateConfig.setRouteCheckpointSpacing
M.setLoopPlayback = setLoopPlayback
M.setColorPreset = setColorPreset
M.setGhostDisplayMode = setGhostDisplayMode
M.setTopGhostCount = startGateConfig.setTopGhostCount
M.setGhostRenderMode = function(mode)
  if not displayState.setGhostRenderMode(mode) then return false end
  local preserveNotice = false
  if displayState.ghostRenderMode == "shell"
      and startGateConfig.ghostShellUnavailableReason ~= nil then
    -- A build that already failed to provide a shell must not silently pretend
    -- the setting took effect.
    displayState.setGhostRenderMode("wireframe")
    notify("Native vehicle Ghosts are not available on this setup", 5)
    preserveNotice = true
  elseif displayState.ghostRenderMode == "shell"
      and displayState.ghostDisplayMode == "top"
      and displayState.topGhostCount > MAX_SHELL_GHOSTS then
    startGateConfig.clearGhostShells(true)
    if startGateConfig.shellCapacityWarningCount ~= displayState.topGhostCount then
      startGateConfig.shellCapacityWarningCount = displayState.topGhostCount
      notify(string.format(
        "Top %d uses wireframe Ghosts; optimized native vehicles support up to Top %d",
        displayState.topGhostCount, MAX_SHELL_GHOSTS
      ), 6)
    end
    preserveNotice = true
  elseif displayState.ghostRenderMode ~= "shell" then
    startGateConfig.clearGhostShells(true)
  end
  if not preserveNotice then
    uiRuntimeState.lastMessage = displayState.ghostRenderMode == "shell"
      and "Ghost body: vehicle shell"
      or "Ghost body: wireframe"
  end
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return displayState.ghostRenderMode == "shell"
end

-- Called from the GE extension with the ids whose native body is on screen
-- right now. Until a Ghost appears in that list its wireframe keeps rendering,
-- so a broken bridge or an unsupported build can never leave it invisible, and
-- a Ghost that has run past the end of its own recording cannot leave a solid
-- body and a wireframe drawn on top of each other.
M.reportGhostShellActive = function(visibleIds)
  if not shellRenderingEnabled() or not playbackState.active or not displayState.visible then
    return false
  end
  local confirmed = {}
  local count = 0
  if type(visibleIds) == "table" then
    for index = 1, #visibleIds do
      confirmed[tostring(visibleIds[index])] = true
      count = count + 1
    end
  end
  startGateConfig.confirmedShellIds = confirmed
  startGateConfig.ghostShellConfirmed = count > 0
  if count > 0 then startGateConfig.ghostShellUnavailableReason = nil end
  startGateConfig.trace("shell.confirmed", "GE reported %d rendered bodies", count)
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return count > 0
end

-- Called from the GE extension when a shell could not be created. The Vehicle
-- controller owns the render mode, so the fallback decision is made here and
-- stays in force for the rest of the session.
M.reportGhostShellUnavailable = function(reason)
  if startGateConfig.ghostShellUnavailableReason ~= nil then return false end
  startGateConfig.ghostShellUnavailableReason = tostring(reason or "unsupported")
  startGateConfig.ghostShellConfirmed = false
  startGateConfig.confirmedShellIds = {}
  startGateConfig.shelledGhostIds = {}
  startGateConfig.clearGhostShells(true)
  displayState.setGhostRenderMode("wireframe")
  local reasons = {
    unknownVehicle = "the recording does not name its vehicle",
    noVehicleSpawner = "this BeamNG build cannot spawn a native Ghost vehicle",
    simplifiedVehicleUnavailable = "this model has no optimized BeamNG traffic vehicle",
    noMathApi = "this BeamNG build is missing the required maths helpers",
    vehicleSpawnFailed = "the recorded vehicle model could not be spawned",
    vehicleIdentityFailed = "the spawned Ghost vehicle has no object identity",
    vehicleVisualApiMissing = "this BeamNG build cannot place or fade a Ghost vehicle",
    vehicleAlphaFailed = "the Ghost vehicle transparency could not be applied",
    vehicleSetupQueueFailed = "the Ghost vehicle setup command could not be queued",
    vehicleGhostModeFailed = "the spawned vehicle could not disable vehicle collisions",
    vehicleFreezeFailed = "the spawned vehicle could not freeze its physics",
    vehicleReadyTimeout = "the spawned Ghost vehicle did not finish loading",
    vehicleMissing = "the spawned Ghost vehicle disappeared",
    vehiclePoseFailed = "the native Ghost vehicle could not be positioned",
    staleObjectCleanupFailed = "a stale Ghost vehicle could not be removed",
    rotationFailed = "the Ghost orientation could not be applied",
    objectCreateFailed = "the native Ghost vehicle could not be created"
  }
  notify(
    "Ghost body fell back to wireframe · "
      .. (reasons[startGateConfig.ghostShellUnavailableReason]
        or tostring(startGateConfig.ghostShellUnavailableReason)),
    6
  )
  startGateConfig.trace(
    "shell.fallback", "reason=%s",
    tostring(startGateConfig.ghostShellUnavailableReason)
  )
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return true
end

M.setShowManual = function(value)
  displayState.setShowManual(normalizedBoolean(value))
  syncGhostSelection()
  uiRuntimeState.lastMessage = displayState.showManual
    and "Manual recordings shown"
    or "Manual recordings hidden"
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return displayState.showManual
end

M.setShowIncomplete = function(value, requestTraceId)
  local before = displayState.showIncomplete
  local enabled = normalizedBoolean(value)
  startGateConfig.trace(
    "partial.filter.request",
    "request=%s raw=%s type=%s before=%s normalized=%s",
    tostring(requestTraceId or "none"), tostring(value), type(value),
    tostring(before), tostring(enabled)
  )
  displayState.setShowIncomplete(enabled)
  syncGhostSelection()
  uiRuntimeState.lastMessage = displayState.showIncomplete
    and "Incomplete recordings shown"
    or "Incomplete recordings hidden"
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  local completeCount, incompleteCount = ghostLibraryCounts()
  local displayedCount = 0
  for index = 1, #playbackState.ghosts do
    if playbackState.ghosts[index].displayed then displayedCount = displayedCount + 1 end
  end
  startGateConfig.trace(
    "partial.filter.result",
    "request=%s after=%s visible=%d total=%d displayed=%d",
    tostring(requestTraceId or "none"), tostring(displayState.showIncomplete),
    completeCount + (displayState.showIncomplete and incompleteCount or 0),
    #playbackState.ghosts, displayedCount
  )
  return true
end

-- The three-way category axis (complete / incomplete / both), orthogonal to the
-- display mode. setShowIncomplete above remains for the old boolean callers;
-- this is what the new HUD control uses.
local CATEGORY_FILTER_MESSAGES = {
  complete = "Showing completed laps",
  incomplete = "Showing incomplete attempts",
  both = "Showing completed laps and attempts"
}
M.setGhostCategoryFilter = function(value)
  if not displayState.setGhostCategoryFilter(value) then return false end
  syncGhostSelection()
  uiRuntimeState.lastMessage =
    CATEGORY_FILTER_MESSAGES[displayState.ghostCategoryFilter] or "Ghost filter updated"
  startGateConfig.trace(
    "partial.filter.category", "filter=%s", tostring(displayState.ghostCategoryFilter)
  )
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return true
end
M.setGhostSelected = setGhostSelected
M.setGhostCameraEnabled = startGateConfig.setGhostCameraEnabled
M.setGhostCameraMode = startGateConfig.setGhostCameraMode
M.setGhostCameraTarget = startGateConfig.setGhostCameraTarget
M.handleGhostCameraError = startGateConfig.handleGhostCameraError
M.deleteGhost = startGateConfig.deleteGhost
M.setGhostPinned = startGateConfig.setGhostPinned
M.shareGhosts = shareGhosts
M.prepareClipboardImport = prepareClipboardImport
M.confirmClipboardImport = confirmClipboardImport
M.cancelClipboardImport = cancelClipboardImport
M.setStartLine = setStartLine
M.setFinishLine = setFinishLine
M.clearFinishLine = clearFinishLine
M.createStartVariant = createStartVariant
M.ensureTimeTrialStart = startGateConfig.ensureActivityTimeTrialStart
M.restoreSavedStartLine = startGateConfig.restoreSaved
M.loadSavedStartMarkers = startGateConfig.loadSavedMarkers
M.selectSavedStartLine = startGateConfig.selectSaved
M.renameStartLine = startGateConfig.renameActive
M.deleteSavedStartLine = startGateConfig.deleteSavedStart
M.setSavedStartMarkersVisible = startGateConfig.setSavedMarkersVisible
M.setAutoLapEnabled = setAutoLapEnabled
-- Flip the auto-lap arm state; used by the keybind, which has no current value.
M.toggleAutoLap = function() return setAutoLapEnabled(not sessionState.autoLapEnabled) end
M.clearStartLine = clearStartLine
M.requestState = startGateConfig.requestState
M.setUiOwnerToken = startGateConfig.setUiOwnerToken
M.getCodeVersion = startGateConfig.getCodeVersion
M.getRuntimeContextSnapshot = startGateConfig.getRuntimeContextSnapshot
M.getRuntimeContextStateSnapshot = startGateConfig.getRuntimeContextStateSnapshot
M.invalidateRuntimeContext = startGateConfig.invalidateRuntimeContext

return M
