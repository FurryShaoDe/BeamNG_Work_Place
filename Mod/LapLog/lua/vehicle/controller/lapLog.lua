-- LapLog -- a lap recorder for BeamNG.drive.
--
-- Derived from Ghost Racer Replay by Jesus Goose, and from Ghost Racer Enhanced
-- by flintt, both under the bCDDL 1.1. This derivative keeps only the recording,
-- archiving and Saved Start half of that work: it samples position, orientation,
-- speed and driver inputs, splits laps on a start gate, stores every lap on disk
-- and lists them in the UI. None of the Ghost rendering, Ghost playback, trail,
-- racing, checkpoint-route, camera or clipboard-sharing code is included.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file, You can obtain
-- one at http://beamng.com/bCDDL-1.1.txt.

local M = {}
M.type = "auxiliary"

local CODE_VERSION = "1.0.0"
-- BeamNG can reload an external controller without invalidating package.loaded
-- in that Vehicle VM. Clear only this mod's own submodules before the first
-- require so Ctrl+L/F5 cannot combine a new controller with an older
-- displayState/uiStateBuilder implementation.
local vehicleSubmodules = {
  "vehicle/lapLog/displayState",
  "vehicle/lapLog/playbackState",
  "vehicle/lapLog/recordingState",
  "vehicle/lapLog/replayCodec",
  "vehicle/lapLog/runtimeContext",
  "vehicle/lapLog/sessionCoordinator",
  "vehicle/lapLog/sessionState",
  "vehicle/lapLog/startRegistry",
  "vehicle/lapLog/startState",
  "vehicle/lapLog/uiRuntimeState",
  "vehicle/lapLog/uiStateBuilder"
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
local DEFAULT_SAMPLE_RATE = 50
local MIN_SAMPLE_RATE = 20
local MAX_SAMPLE_RATE = 100
local MAX_RECORDING_SECONDS = 30 * 60
local UI_UPDATE_INTERVAL = 0.1
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
local startGateConfig = require("vehicle/lapLog/startState").new()

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
  log("I", "LapLogDiag.VE", string.format(
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

local replayCodec = require("vehicle/lapLog/replayCodec").new({
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

local colorPresets = {
  orange = {255, 112, 24, 230},
  cyan = {40, 210, 255, 230},
  green = {72, 235, 126, 230},
  magenta = {235, 80, 255, 230},
  white = {245, 245, 245, 220}
}
local colorOrder = {"orange", "cyan", "green", "magenta", "white"}
local displayState = require("vehicle/lapLog/displayState").new({
  colorFactory = color,
  defaultColor = colorPresets.orange,
  clamp = function(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
  end
})
if displayState.showManual == nil then displayState.showManual = true end
if type(displayState.setShowManual) ~= "function" then
  function displayState.setShowManual(value)
    displayState.showManual = value ~= false
    return displayState.showManual
  end
end

local recordingState = require("vehicle/lapLog/recordingState").new({
  defaultSampleRate = DEFAULT_SAMPLE_RATE,
  minimumSampleRate = MIN_SAMPLE_RATE,
  maximumSampleRate = MAX_SAMPLE_RATE,
  maximumRecordingSeconds = MAX_RECORDING_SECONDS
})
local playbackState = require("vehicle/lapLog/playbackState").new()
local sessionState = require("vehicle/lapLog/sessionState").new()
local uiRuntimeState = require("vehicle/lapLog/uiRuntimeState").new()

-- Every mutable gameplay/presentation domain is instance-owned by this context.
local runtimeState = {
  recording = recordingState,
  playback = playbackState,
  session = sessionState,
  starts = startGateConfig,
  display = displayState,
  ui = uiRuntimeState
}
local runtimeContext = require("vehicle/lapLog/runtimeContext").new({
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
local sessionCoordinator = require("vehicle/lapLog/sessionCoordinator").new({
  session = sessionState,
  recording = recordingState,
  playback = playbackState,
  acceptedCrossingCooldown = AUTO_LAP_COOLDOWN
})
runtimeContext:registerService("sessionCoordinator", sessionCoordinator)

-- These public arrays are a frozen external compatibility surface. They
-- intentionally mirror their context-owned buffers and are not state owners.
M.recordPoints = recordingState.points
M.ghostPB = playbackState.points
M.ghostPoints = playbackState.points

local groundRay = {origin = vec3(), direction = vec3()}
groundRay.direction.x, groundRay.direction.y, groundRay.direction.z = 0, 0, -1

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

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
    "if extensions and extensions.laplog and " ..
      "extensions.laplog.showLapLogMessage then " ..
      "extensions.laplog.showLapLogMessage(" ..
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
  local placement = rank and string.format("#%d/%d", rank, recordCount) or "未排名"
  local storage = stored == false and " · 未保存" or ""
  return string.format(
    "%s · %s 秒 · %s%s",
    isBest and "新纪录" or "圈速完成",
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

-- Rotating palette used only to tag stored laps in the UI list; LapLog renders
-- nothing, so the colour is a label, not a draw call.
local function paletteColorName(index)
  return colorOrder[((index - 1) % #colorOrder) + 1]
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

local function resetGhostCursors()
  for index = 1, #playbackState.ghosts do playbackState.ghosts[index].cursor = 1 end
  playbackState.progressCursor = 1
end

-- LapLog never renders or replays a Ghost, so "displayed" carries a much smaller
-- meaning than in the upstream mod: it marks the single reference lap the UI
-- treats as current (the fastest timed lap, or the longest partial when the
-- category filter is set to Incomplete). Everything else about the library --
-- storage quotas, pinning, pruning, per-category retention -- is unchanged.
local function syncGhostSelection()
  local best = bestGhostEntry(false)

  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    entry.displayed = false
    entry.isBest = entry == best
    entry.displayRank = nil
  end

  local hero
  if displayState.ghostCategoryFilter == "incomplete" then
    hero = longestIncompleteGhostEntry(false)
  else
    hero = best or newestIncompleteGhostEntry(false)
  end
  if hero and ghostCanBeShown(hero) and ensureGhostSamples(hero) then
    hero.displayed = true
  end

  local ranked = {}
  for index = 1, #playbackState.ghosts do
    local entry = playbackState.ghosts[index]
    if entry.displayed then ranked[#ranked + 1] = entry end
  end
  table.sort(ranked, function(first, second)
    if ghostIsIncomplete(first) ~= ghostIsIncomplete(second) then
      return not ghostIsIncomplete(first)
    end
    local firstTime, secondTime = ghostComparableTime(first), ghostComparableTime(second)
    if firstTime == secondTime then return tostring(first.id) < tostring(second.id) end
    return firstTime < secondTime
  end)

  playbackState.duration = 0
  for rank = 1, #ranked do
    local entry = ranked[rank]
    entry.displayRank = rank
    playbackState.duration = math.max(playbackState.duration, tonumber(entry.duration) or 0)
  end

  setPublicPlaybackPoints(ranked[1] and ranked[1].samples or {})
  resetGhostCursors()
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
    label = label or string.format("第 %d 圈", playbackState.nextGhostId - 1),
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
  playbackState.nextGhostId = 1
  setPublicPlaybackPoints({})
  playbackState.duration = 0
  playbackState.elapsed = 0
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
          label = descriptor.label or string.format("第 %d 圈", #playbackState.ghosts + 1),
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
    uiRuntimeState.lastMessage = "删除失败：未找到该条圈速"
    notify(uiRuntimeState.lastMessage, 3)
    return false
  end

  if playbackState.ghosts[removeIndex].pinned == true then
    uiRuntimeState.lastMessage = "该圈速已置顶 · 请先取消置顶再删除"
    notify(uiRuntimeState.lastMessage, 3)
    return false
  end

  local removed = startGateConfig.removeGhostAt(removeIndex)
  startGateConfig.reconcilePrimaryGhost()
  syncGhostSelection()
  saveGhostManifest()
  if startGateConfig.updateActiveStats then startGateConfig.updateActiveStats(true) end
  uiRuntimeState.lastMessage = string.format("已删除 %s", removed.label or "圈速")
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
    uiRuntimeState.lastMessage = "置顶失败：未找到该条圈速"
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
    "%s %s", nextPinned and "已置顶" or "已取消置顶", entry.label or "圈速"
  )
  notify(uiRuntimeState.lastMessage, 2)
  return true
end

local function setSampleRate(value)
  recordingState.setSampleRate(value)
  return recordingState.sampleRate
end

local function setStartGateVisible(value)
  displayState.setStartGateVisible(value)
  if startGateConfig.syncMarkers then startGateConfig.syncMarkers() end
end

local function startRecording()
  local px, py, pz = obj:getPositionXYZ()
  local groundOffset = pz - startGateConfig.groundHeightAt(px, py, pz)
  setPublicRecordPoints(recordingState.begin(groundOffset))
  playbackState.progressCursor = 1
  captureSample(0)
  if sessionState.autoLapActive then
    uiRuntimeState.lastMessage = "自动计圈录制中"
  else
    uiRuntimeState.lastMessage = "录制中"
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
      string.format("记录 %d", playbackState.nextGhostId),
      "manual",
      recordingState.activeSampleInterval
    )
  end

  uiRuntimeState.lastMessage = "录制就绪"
  return true
end

local incompleteReasonLabels = {
  outsideWidth = "偏离起点门宽度",
  verticalOffset = "起点门垂直偏移",
  tooSlow = "过门速度过低",
  segmentTooLong = "瞬移或位置跳变",
  cooldown = "起点门冷却中",
  minimumLapTime = "低于最短圈速",
  invalidGate = "无效的过门",
  invalidLap = "圈速被判定无效",
  raceEnded = "比赛结束",
  missionFailed = "计时赛失败",
  missionAbandoned = "计时赛已放弃",
  missionStopped = "计时赛已停止",
  vehicleReset = "车辆重置",
  startChanged = "已存起点变更",
  autoLapDisabled = "自动计圈未启用",
  autoLapRestarted = "自动计圈重新开始",
  startDeactivated = "已存起点已停用",
  safetyLimit = "30 分钟安全上限"
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

  local reasonLabel = incompleteReasonLabels[reason] or reason:gsub("([a-z])([A-Z])", "%1 %2")

  -- Be honest about what actually happened. The length-retention rule can prune
  -- this partial the instant it is inserted (it is the shortest of a full pool),
  -- and a "saved" toast in that case is a lie -- the player looks for it and it
  -- is not there. Announce "saved" only when it survived; otherwise say plainly
  -- that it was too short to keep, and how many longer partials outrank it.
  local message
  if survived then
    message = string.format(
      "未完成记录已保存 · %.1f 秒 · %s",
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
      "未保留该未完成记录 · %.1f 秒，短于已有的 %d 条未完成记录",
      tonumber(entry.duration) or 0,
      storedIncomplete
    )
  end
  notify(message, 5)
  return entry, survived, message
end

local function saveRecording(filename, lapTime)
  filename = filename or ("lapLogs/" .. v.data.vehicleDirectory .. "/laplog.save.json")
  local points = #recordingState.lastRecording > 0 and recordingState.lastRecording or playbackState.points
  if #points == 0 then
    notify("没有可保存的内容")
    return false
  end

  local effectiveLapTime = tonumber(lapTime) or playbackState.pbTime
  local success = jsonWriteFile(filename, replayEnvelope(points, effectiveLapTime), false)
  if effectiveLapTime then
    -- Keep the 1.6 sidecar for backward compatibility.
    jsonWriteFile(filename .. ".time", {effectiveLapTime}, false)
  end

  if success == false then
    notify("保存失败")
    return false
  end

  startGateConfig.currentFilename = filename
  playbackState.pbTime = effectiveLapTime
  if startGateConfig.updateActiveStats then startGateConfig.updateActiveStats(true) end
  notify("已保存", 2)
  return true
end

local function loadRecording(filename, quiet)
  filename = filename or defaultReplayFilename()
  local data = jsonReadFile(filename)
  local points, metadata = normalizeReplay(data)

  if not points then
    if not quiet then notify("未找到已保存的记录") end
    return false
  end

  playbackState.pbTime = metadata.lapTime or (jsonReadFile(filename .. ".time") or {})[1]
  startGateConfig.currentFilename = filename
  metadata.lapTime = metadata.lapTime or playbackState.pbTime
  loadGhostLibrary(filename, filename, points, metadata)
  uiRuntimeState.lastMessage = "已载入记录"
  if not quiet then notify("已载入记录", 2) end
  return true
end

local function loadTime(filename)
  filename = filename or "lapLogs/templaplog.save.json"
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
  outsideWidth = "该圈未计入 · 过门位置偏离 15 米门宽",
  verticalOffset = "该圈未计入 · 过门时垂直偏离过大",
  tooSlow = "该圈未计入 · 过门速度过低",
  wrongDirection = "该圈未计入 · 过门方向相反",
  segmentTooLong = "该圈未计入 · 疑似瞬移或位置跳变",
  cooldown = "该圈未计入 · 起点门仍在冷却",
  minimumLapTime = "该圈未计入 · 过门低于 5 秒下限"
}

function startGateConfig.rejectAutoLapCrossing(reason)
  -- A reverse pass is diagnostic only: the same lap may still turn around and
  -- finish correctly. Rejected forward passes invalidate position delta until
  -- the next valid crossing starts a clean attempt.
  sessionCoordinator.rejectCrossing(reason)
  local message = startGateConfig.autoLapRejectMessages[reason]
    or "该圈未计入 · 过门无效"
  uiRuntimeState.lastMessage = message
  notify(message, 5)
end

local startRegistry = require("vehicle/lapLog/startRegistry").new({
  state = startGateConfig,
  sanitizePathPart = sanitizePathPart,
  normalizeReplay = normalizeReplay,
  ghostLibraryIndexFilename = ghostLibraryIndexFilename,
  ghostSampleFilename = ghostSampleFilename,
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
    "if extensions and extensions.laplog and " ..
      "extensions.laplog.setFreeRoamMarkers then " ..
      "extensions.laplog.setFreeRoamMarkers({" .. table.concat(encoded, ",") .. "}," ..
      tostring(startGateConfig.savedMarkersVisible) .. "," ..
      tostring(displayState.startGateVisible and startGateConfig.startLineSet) .. "," ..
      startGateConfig.senderLiteral() .. ") end"
  )
end

function startGateConfig.updateActiveStats()
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

  line.ghostCount, line.incompleteGhostCount = ghostLibraryCounts()
  line.pbTime = playbackState.pbTime
  startGateConfig.saveRegistry({updatedId = line.id, operation = "activateStart"})
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = string.format("%s · 已载入 %d 圈", line.name, #playbackState.ghosts)
  return true
end

local function setAutoLapEnabled(value)
  local enabled = value == true
  if enabled and not startGateConfig.startLineSet then
    uiRuntimeState.lastMessage = "请先设置起点"
    return false
  end

  if recordingState.active then
    archiveIncompleteRecording(enabled and "autoLapRestarted" or "autoLapDisabled")
  end
  sessionCoordinator.configureAutoLap(enabled)
  sessionCoordinator.stopRecordingAndPlayback()
  setPublicRecordPoints({})
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
    uiRuntimeState.lastMessage = "自动计圈已启用"
  else
    sessionState.autoLapGateState = "off"
    uiRuntimeState.lastMessage = "自动计圈已关闭"
  end

  return true
end

function startGateConfig.restoreSaved(levelName, requestedId)
  local safeLevel = sanitizePathPart(levelName, "unknown_level")
  if startGateConfig.startLineSet and not requestedId and safeLevel == startGateConfig.startLineLevel then
    setAutoLapEnabled(true)
    startGateConfig.syncMarkers()
    uiRuntimeState.lastMessage = "已恢复并激活上次起点"
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
    uiRuntimeState.lastMessage = "没有已存起点"
    return false
  end
  if not startGateConfig.activateLine(target, true) then return false end
  setAutoLapEnabled(true)
  uiRuntimeState.lastMessage = string.format("%s 已激活 · %d 条记录", target.name, #playbackState.ghosts)
  return true
end

function startGateConfig.loadSavedMarkers(levelName)
  startGateConfig.loadRegistry(levelName)
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = #startGateConfig.registry.lines > 0
    and string.format("共 %d 个已存起点", #startGateConfig.registry.lines)
    or "没有已存起点"
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
    uiRuntimeState.lastMessage = "无法在磁盘上校验重命名结果"
    notify(uiRuntimeState.lastMessage, 3)
    startGateConfig.trace(
      "rename.result",
      "FAILED target=%s previous=%q requested=%q saveReturned=%s",
      line.id, previousName, name, tostring(saved)
    )
    return false
  end
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = "起点已重命名：" .. line.name .. " [" .. line.id .. "]"
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

  startRecording()
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = "自动计圈：第 1 圈录制中 · "
    .. tostring(startGateConfig.registry.activeId or "unsaved")
  return true
end

local function setStartLine(levelName, diagnosticTraceId)
  startGateConfig.diagnosticTraceId = diagnosticTraceId and tostring(diagnosticTraceId) or nil
  startGateConfig.trace(
    "setStart.request", "level=%s", tostring(levelName)
  )

  -- Restart of an existing start: re-arm it in place instead of deriving a fresh
  -- gate from the current position. Once a start is created it stays fixed;
  -- "Restart lap" restarts the lap on it. Re-deriving a gate from wherever the car
  -- stopped could miss the match radius and fork off a brand-new start (its own
  -- track group), or silently jump to a different variant that shares the same
  -- gate. To move a start, clear it and set again.
  local restartTarget = startGateConfig.activeEntry()
  if startGateConfig.startLineSet and restartTarget then
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
    uiRuntimeState.lastMessage = "无法读取车辆朝向"
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
    uiRuntimeState.lastMessage = "已存起点数量已达上限"
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
  if not startGateConfig.startLineSet then
    uiRuntimeState.lastMessage = "请先设置起点，再设置终点"
    return false
  end
  local px, py, pz = obj:getPositionXYZ()
  local front = obj:getDirectionVector()
  local horizontalLength = math.sqrt(front.x * front.x + front.y * front.y)
  if horizontalLength < 0.001 then
    uiRuntimeState.lastMessage = "无法读取车辆朝向"
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
  uiRuntimeState.lastMessage = "终点已设置 · 点对点"
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
  uiRuntimeState.lastMessage = "终点已移除 · 环形计圈"
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return true
end

-- Add a track variant to the active start: a new line sharing the same gate
-- position and startKey group, but with its own id, ghost library and finish
-- gate. Lets several tracks run from one start without clearing the others.
local function createStartVariant()
  local active = startGateConfig.activeEntry()
  if not active or not startGateConfig.startLineSet then
    uiRuntimeState.lastMessage = "请先设置起点，再新建赛道"
    return false
  end
  local groupKey = active.startKey or active.id
  -- createLine reads the active start's live geometry, so the variant shares the
  -- gate; it only earns its own id, group key and (empty) ghost library.
  local line = startGateConfig.createLine()
  if not line then
    uiRuntimeState.lastMessage = "已存起点数量已达上限"
    return false
  end
  line.startKey = groupKey
  line.userNamed = false
  local count = 0
  for index = 1, #startGateConfig.registry.lines do
    local candidate = startGateConfig.registry.lines[index]
    if (candidate.startKey or candidate.id) == groupKey then count = count + 1 end
  end
  line.name = string.format("赛道 %d", count)
  if not startGateConfig.activateLine(line, true) then return false end
  beginAutoLapRecordingAtStart()
  if startGateConfig.saveRegistry then startGateConfig.saveRegistry() end
  uiRuntimeState.lastMessage = "新赛道 · " .. line.name
  if startGateConfig.sendUiState then startGateConfig.sendUiState() end
  return true
end

local function clearStartLine(preserveIncomplete)
  if preserveIncomplete ~= false and recordingState.active then
    archiveIncompleteRecording("startDeactivated")
  end
  sessionCoordinator.clearStart()
  startGateConfig.startLineSet = false
  -- The finish gate is a live function of the start; its geometry stays on the
  -- registry line and restores when the start is reactivated.
  startGateConfig.finishLineSet = false
  startGateConfig.previousFinishSigned = nil
  sessionCoordinator.stopRecordingAndPlayback()
  setPublicRecordPoints({})
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = "起点已停用 · 数据已保留"
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
    uiRuntimeState.lastMessage = "删除失败：未找到该起点"
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
      "lapLogs/freeRoam/%s/",
      sanitizePathPart(registry.level or startGateConfig.startLineLevel, "unknown_level")
    )
    local suffix = "/starts/" .. sanitizePathPart(id, "start") .. "/laplog.save"
    local ok, manifests = pcall(
      FS.findFiles, FS, levelRoot, "laplog.save.library.json", -1, true, false
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
      FS.findFiles, FS, levelRoot, "laplog.save.json", -1, true, false
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
  end

  table.remove(registry.lines, removeIndex)
  for index = 1, #cleanupFiles do
    startGateConfig.removeStoredFile(cleanupFiles[index])
  end
  startGateConfig.saveRegistry({deletedId = id, operation = "deleteStart"})
  startGateConfig.syncMarkers()
  uiRuntimeState.lastMessage = string.format(
    "已删除起点 %s · 原有 %d 条圈速",
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
    startRecording()
    uiRuntimeState.lastMessage = "自动计圈：第 1 圈已对齐起点门"
    return
  end

  if crossingAction == "start" then
    sessionCoordinator.beginGateLap(crossingAction)
    startRecording()
    uiRuntimeState.lastMessage = "自动计圈：第 1 圈开始"
    return
  end

  if crossingAction == "discard" then
    if recordingState.active then archiveIncompleteRecording(rejectionReason or "invalidGate") end
    sessionCoordinator.beginGateLap(crossingAction)
    startRecording()
    uiRuntimeState.lastMessage = string.format("未完成圈已保存 · 第 %d 圈开始", sessionState.autoLapNumber)
    notify(uiRuntimeState.lastMessage, 4)
    return
  end

  if crossingAction ~= "finish" then return end

  -- Point-to-point: the finish is the finish gate, so re-crossing the start gate
  -- abandons the current run and begins a fresh one from here.
  if startGateConfig.finishLineSet then
    if recordingState.active then archiveIncompleteRecording("restarted") end
    sessionCoordinator.beginGateLap("start")
    startRecording()
    uiRuntimeState.lastMessage = "点对点计时已重新开始"
    return
  end

  local lapTime = recordingState.elapsed
  local completedLap = sessionCoordinator.beginLapCompletion(lapTime)
  stopRecording(false)

  local isBest = not playbackState.pbTime or lapTime < playbackState.pbTime
  local _, rank, recordCount, stored = addGhostToLibrary(
    recordingState.lastRecording,
    lapTime,
    string.format("自由圈 %d", completedLap),
    "freeRoam",
    recordingState.activeSampleInterval
  )
  sessionCoordinator.setLastLapStored(stored)
  if isBest and #recordingState.lastRecording > 0 then
    playbackState.pbTime = lapTime
    saveRecording(startGateConfig.currentFilename, lapTime)
    syncGhostSelection()
  end

  sessionCoordinator.advanceAutoLap()
  startRecording()
  local placement = rank and string.format("#%d/%d", rank, recordCount) or "未排名"
  if stored == false then placement = placement .. " 未保存" end
  uiRuntimeState.lastMessage = isBest
    and string.format("新纪录 %.3f · %s · 第 %d 圈", lapTime, placement, sessionState.autoLapNumber)
    or string.format(
      "第 %d 圈 %.3f · %s · 第 %d 圈开始",
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
    string.format("点对点 %d", completedLap),
    "freeRoam",
    recordingState.activeSampleInterval
  )
  sessionCoordinator.setLastLapStored(stored)
  if isBest and #recordingState.lastRecording > 0 then
    playbackState.pbTime = lapTime
    saveRecording(startGateConfig.currentFilename, lapTime)
    syncGhostSelection()
  end

  sessionCoordinator.endPointToPointLap()
  local placement = rank and string.format("#%d/%d", rank, recordCount) or "未排名"
  if stored == false then placement = placement .. " 未保存" end
  uiRuntimeState.lastMessage = isBest
    and string.format("新纪录 %.3f · %s · 再过起点门即可再跑", lapTime, placement)
    or string.format("点对点 %.3f · %s · 再过起点门即可再跑", lapTime, placement)
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
  if not startGateConfig.startLineSet or not sessionState.autoLapEnabled then
    sessionState.autoLapGateState = sessionState.autoLapEnabled and "lineReady" or "off"
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

  -- Point-to-point runs end at the finish gate rather than by re-crossing start.
  updateFinishGate(px, py, pz)

  startGateConfig.previousPositionX, startGateConfig.previousPositionY, startGateConfig.previousPositionZ = px, py, pz
end

local function clearRecording()
  sessionCoordinator.stopRecordingAndPlayback()
  sessionCoordinator.clearRecordingSession()
  recordingState.lastRecording = {}
  setPublicRecordPoints({})
  clearGhostLibraryMemory()
  playbackState.duration = 0
  playbackState.elapsed = 0
  playbackState.pbTime = nil
  uiRuntimeState.lastMessage = "已清空"
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

uiRuntimeState.setSnapshotBuilder(function()
  return {
    recording = recordingState.active,
    autoLapEnabled = sessionState.autoLapEnabled,
    autoLapActive = sessionState.autoLapActive,
    startLineSet = startGateConfig.startLineSet,
    finishLineSet = startGateConfig.finishLineSet == true,
    startGateVisible = displayState.startGateVisible,
    autoLapNumber = sessionState.autoLapNumber,
    lastLapTime = sessionState.lastLapTime,
    lastLapStored = sessionState.lastLapStored,
    autoLapLineDistance = sessionState.autoLapLineDistance,
    autoLapLateralDistance = sessionState.autoLapLateralDistance,
    autoLapGateState = sessionState.autoLapGateState,
    autoLapLastReject = sessionState.autoLapLastReject,
    autoLapCrossingArmed = sessionState.autoLapCrossingArmed,
    sampleRate = recordingState.sampleRate,
    showIncomplete = displayState.showIncomplete,
    ghostCategoryFilter = displayState.ghostCategoryFilter,
    showManual = displayState.showManual,
    recordElapsed = recordingState.elapsed,
    referenceDuration = playbackState.duration,
    currentPbTime = playbackState.pbTime,
    lastMessage = uiRuntimeState.lastMessage,
    ghostLibrary = playbackState.ghosts,
    playbackPoints = playbackState.points,
    lastRecording = recordingState.lastRecording,
    recordPoints = recordingState.points
  }
end)

local uiStateBuilder = require("vehicle/lapLog/uiStateBuilder").new({
  state = startGateConfig,
  getRuntime = uiRuntimeState.snapshot,
  getCurrentSpeed = function() return obj:getVelocity():length() end,
  vehicle = sanitizePathPart(v.data.vehicleDirectory, "unknown_vehicle"),
  codeVersion = CODE_VERSION,
  startLineHalfWidth = AUTO_LINE_HALF_WIDTH,
  maxStoredGhosts = MAX_STORED_GHOSTS,
  maxStoredIncompleteGhosts = MAX_STORED_INCOMPLETE_GHOSTS,
  maxStoredManualGhosts = MAX_STORED_MANUAL_GHOSTS
})
runtimeContext:registerService("uiStateBuilder", uiStateBuilder)
startGateConfig.buildUiState = uiStateBuilder.build
-- The state build touches every runtime domain, so one nil field would
-- otherwise abort the hook silently - and through updateGFX it would do that
-- ten times a second. Build inside a pcall and report the first failure once,
-- so a panel stuck on "connecting" always leaves a reason in the log.
local uiStateBuildErrorReported = false

function startGateConfig.sendUiState()
  if not (guihooks and guihooks.trigger) then return end
  local ok, state = pcall(startGateConfig.buildUiState)
  if not ok then
    if not uiStateBuildErrorReported and type(log) == "function" then
      uiStateBuildErrorReported = true
      log("W", "LapLogDiag.VE", "[ui] buildUiState failed: " .. tostring(state))
    end
    return
  end
  guihooks.trigger("LapLogState", state)
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

-- Fixed-step physics tick: this is where the recorder samples the car.
function startGateConfig.update(dtSim)
  updateRecording(dtSim)
end

-- Render tick: the start-gate crossing detector runs here, and the UI state is
-- pushed on a fixed interval so the panel does not rebuild every frame.
function startGateConfig.updateGFX(dtSim)
  updateAutoLap(dtSim)

  uiRuntimeState.uiAccumulator = uiRuntimeState.uiAccumulator + math.max(dtSim, 0)
  if uiRuntimeState.uiAccumulator >= UI_UPDATE_INTERVAL then
    uiRuntimeState.uiAccumulator = uiRuntimeState.uiAccumulator % UI_UPDATE_INTERVAL
    startGateConfig.sendUiState()
  end
end

-- BeamNG's `simple_traffic` is its optimized AI-only representation of a vehicle.
-- A player never drives one, so the recorder treats those VMs as dormant: the
-- per-frame hooks stay registered but do no work, which keeps a handful of idle
-- controller instances off every traffic car's update path.
local function vehicleIsAiProxy()
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
  if vehicleIsAiProxy() then
    startGateConfig.dormant = true
    startGateConfig.trace(
      "controller.dormant", "AI proxy vehicle directory=%s",
      tostring(v and v.data and v.data.vehicleDirectory)
    )
    return
  end
  runtimeContext:activate("controller init")
  startGateConfig.trace("controller.init", "initializing vehicle controller")
  local refNodeData = v.data.refNodes and v.data.refNodes[0]
  if not refNodeData then
    notify("LapLog：车辆缺少参考节点", 5)
    return
  end
  startGateConfig.trace("controller.init", "ready")
  startGateConfig.sendUiState()
end

function startGateConfig.reset()
  startGateConfig.trace("controller.reset", "recording=%s livePoints=%d",
    tostring(recordingState.active), #recordingState.points)

  -- A vehicle reset deliberately does NOT archive the interrupted attempt. The
  -- upstream Ghost Racer mod stores it as an "Incomplete" partial; here a reset
  -- means the run was abandoned, so the samples are thrown away instead of filling
  -- the partial pool with every failed attempt.
  local discarded = recordingState.active and #recordingState.points >= 2
  recordingState.reset(true)

  runtimeContext:markReset("vehicle reset")
  sessionCoordinator.stopRecordingAndPlayback()
  sessionCoordinator.softReset()
  setPublicPlaybackPoints({})
  if startGateConfig.startLineSet then rememberCurrentPosition(0) end
  startGateConfig.syncMarkers()

  -- Re-arm straight away rather than waiting for the next gate crossing, so a
  -- reset mid-lap does not leave a dead stretch where nothing is recorded. Only
  -- meaningful when a start exists and free-roam auto lap is armed.
  if discarded and startGateConfig.startLineSet and sessionState.autoLapEnabled then
    beginAutoLapRecordingAtStart()
  end

  if discarded then
    -- Toast through the GE VM: a message fired from this VM mid-reset is wiped by
    -- the game's own reset UI teardown, so the player would never see it.
    notifyViaGe("残圈已丢弃 · 重新开始计圈", 4)
  else
    uiRuntimeState.lastMessage = sessionState.autoLapEnabled
      and "重置后自动计圈已启用" or "就绪"
  end
  startGateConfig.sendUiState()
end

M.init = startGateConfig.init
M.reset = function(...)
  if startGateConfig.dormant then return end
  return startGateConfig.reset(...)
end
-- A dormant instance belongs to an AI proxy vehicle. It keeps its per-frame hooks
-- registered but does no work at all, so those cannot cost frames while the
-- player is driving.
M.update = function(...)
  if startGateConfig.dormant then return end
  return startGateConfig.update(...)
end
M.updateGFX = function(...)
  if startGateConfig.dormant then return end
  return startGateConfig.updateGFX(...)
end

-- Recording
M.startRecording = startRecording
M.stopRecording = stopRecording
M.clearRecording = clearRecording
M.saveRecording = saveRecording
M.loadRecording = loadRecording
M.loadTime = loadTime
M.setSampleRate = setSampleRate

-- Saved Starts
M.setStartLine = setStartLine
M.setFinishLine = setFinishLine
M.clearFinishLine = clearFinishLine
M.clearStartLine = clearStartLine
M.createStartVariant = createStartVariant
M.setAutoLapEnabled = setAutoLapEnabled
M.toggleAutoLap = function() return setAutoLapEnabled(not sessionState.autoLapEnabled) end
M.restoreSavedStartLine = startGateConfig.restoreSaved
M.loadSavedStartMarkers = startGateConfig.loadSavedMarkers
M.selectSavedStartLine = startGateConfig.selectSaved
M.renameStartLine = startGateConfig.renameActive
M.deleteSavedStartLine = startGateConfig.deleteSavedStart
M.setSavedStartMarkersVisible = startGateConfig.setSavedMarkersVisible
M.setStartGateVisible = setStartGateVisible

-- Stored laps
M.deleteGhost = startGateConfig.deleteGhost
M.setGhostPinned = startGateConfig.setGhostPinned
M.setShowManual = function(value)
  displayState.setShowManual(value == true)
  syncGhostSelection()
  uiRuntimeState.lastMessage = displayState.showManual
    and "已显示手动录制" or "已隐藏手动录制"
  startGateConfig.sendUiState()
  return displayState.showManual
end
M.setGhostCategoryFilter = function(value)
  if not displayState.setGhostCategoryFilter(value) then return false end
  syncGhostSelection()
  startGateConfig.sendUiState()
  return true
end

-- UI plumbing
-- Publish this instance for the UI bridge.
--
-- The engine path is controller.getController(name), but on 0.39 that lookup
-- returns nil for this externally loaded controller even though init() and
-- reset() clearly run - the 2026-10-04 game log shows "controller.init ...
-- ready" in the same millisecond as a failed getController lookup. Without a
-- fallback the panel stays on "connecting" and every button silently does
-- nothing. Keep the slot names in sync with LUA_FIND_CONTROLLER in app.js.
pcall(function() package.loaded["vehicle/controller/lapLog"] = M end)
pcall(function() controller.lapLogInstance = M end)
pcall(function() lapLogController = M end)

M.requestState = startGateConfig.requestState
M.setUiOwnerToken = startGateConfig.setUiOwnerToken
M.getCodeVersion = startGateConfig.getCodeVersion
M.getRuntimeContextSnapshot = startGateConfig.getRuntimeContextSnapshot
M.getRuntimeContextStateSnapshot = startGateConfig.getRuntimeContextStateSnapshot
M.invalidateRuntimeContext = startGateConfig.invalidateRuntimeContext

return M
