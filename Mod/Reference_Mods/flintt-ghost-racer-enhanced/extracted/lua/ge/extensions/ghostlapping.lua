-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Original Ghost Racer Replay by Jesus Goose.
-- Race lifecycle modifications by flintt, 2026.

local M = {}
M.dependencies = {"ghostRecord", "core_camera"}

local CODE_VERSION = "2.19.8"
local geSubmodules = {
  "ge/ghostRacer/cameraBackend",
  "ge/ghostRacer/lifecycleCoordinator",
  "ge/ghostRacer/raceState",
  "ge/ghostRacer/runtimeContext",
  "ge/ghostRacer/timeTrialState",
  "ge/ghostRacer/uiLifecycleState",
  "ge/ghostRacer/shellVehicleBackend",
  "ge/ghostRacer/shellTSStaticBackend",
  "ge/ghostRacer/shellRenderer",
  "ge/ghostRacer/worldRenderer"
}
local clearedGeSubmodules = 0
if package and type(package.loaded) == "table" then
  for index = 1, #geSubmodules do
    local moduleName = geSubmodules[index]
    if package.loaded[moduleName] ~= nil then
      package.loaded[moduleName] = nil
      clearedGeSubmodules = clearedGeSubmodules + 1
    end
  end
end

local RACE_START_GRACE_SECONDS = 0.35
-- The Ghost body budget, matching the Vehicle-side MAX_SHELL_BODIES
-- (MAX_STORED_GHOSTS + incomplete + manual = 60). With the default TSStatic
-- backend a body is a cheap static mesh, so the budget covers a full library and
-- "all" mode renders every displayed Ghost as a body rather than mixing bodies
-- with wireframes. Keep this in sync with the Vehicle-side ceiling.
local MAX_SHELL_GHOSTS = 60
local GHOST_SHARE_PREFIX = "GRE1:"
local GHOST_SHARE_MAX_BYTES = 16 * 1024 * 1024
local GHOST_SHARE_IMPORT_FILE = "ghostReplays/clipboard/ghostRacerShareImport.json"
local startPendingRace
-- Forward declaration: the shell renderer below reports its fallback through
-- this bridge, which is defined once the runtime context exists.
local queueController
-- Also forward declared: reporting shell status needs the player vehicle
-- resolved, which only happens once the runtime helpers below exist.
local reportShellStatus
local raceState = require("ge/ghostRacer/raceState").new()
local timeTrialState = require("ge/ghostRacer/timeTrialState").new()
local worldRenderer = require("ge/ghostRacer/worldRenderer").new()
local cameraBackend = require("ge/ghostRacer/cameraBackend").new()
local uiLifecycleState = require("ge/ghostRacer/uiLifecycleState").new()
local shellRenderer = require("ge/ghostRacer/shellRenderer").new({
  trace = function(...) return M.trace(...) end,
  maximumGhosts = MAX_SHELL_GHOSTS,
  onUnavailable = function(reason)
    -- The Vehicle controller owns the render mode, so it decides to fall back.
    reportShellStatus(
      "if c.reportGhostShellUnavailable then c.reportGhostShellUnavailable("
        .. string.format("%q", tostring(reason or "unsupported")) .. ") end"
    )
  end,
  onAvailable = function(visibleIds)
    local encoded = {}
    for index = 1, #(visibleIds or {}) do
      encoded[index] = string.format("%q", tostring(visibleIds[index]))
    end
    reportShellStatus(
      "if c.reportGhostShellActive then c.reportGhostShellActive({"
        .. table.concat(encoded, ",") .. "}) end"
    )
  end
})

-- GE and Vehicle Lua own separate contexts. Race and Time Trial state is
-- instance-owned; BeamNG event hooks below remain the lifecycle facade.
local runtimeState = {
  race = raceState,
  timeTrial = timeTrialState,
  camera = cameraBackend,
  world = worldRenderer,
  shell = shellRenderer,
  ui = uiLifecycleState
}
local runtimeContext = require("ge/ghostRacer/runtimeContext").new({
  codeVersion = CODE_VERSION,
  state = runtimeState
})
runtimeContext:registerService("worldRenderer", worldRenderer)
runtimeContext:registerService("shellRenderer", shellRenderer)
runtimeContext:registerService("cameraBackend", cameraBackend)
local lifecycleCoordinator = require("ge/ghostRacer/lifecycleCoordinator").new({
  race = raceState,
  timeTrial = timeTrialState,
  raceStartGrace = RACE_START_GRACE_SECONDS
})
runtimeContext:registerService("lifecycleCoordinator", lifecycleCoordinator)

local function setRuntimeVehicle(value)
  if value then
    runtimeContext:updateRuntime({vehicle = value, vehicleId = value:getID()})
  else
    runtimeContext:clearRuntime({"vehicle", "vehicleId"})
  end
  return value
end

-- Every one of the calls below writes GE state that belongs to the whole
-- world, not to the vehicle that sent it. Native Ghost vehicles are real
-- BeamNGVehicles with their own Lua VM, so one of them loading this mod's
-- controller is enough to push an empty marker or trail set and erase the
-- player's Start Line pillars. Refusing a push whose sender is demonstrably
-- not the player's vehicle fixes that at the layer where ownership is known,
-- instead of relying on every spawned VM declining to load the controller.
--
-- A push without a sender, or one that arrives before the player vehicle is
-- resolved, is still accepted: only a known mismatch is rejected.
local ownershipRejections = 0
local function sentByPlayerVehicle(senderId)
  if senderId == nil then return true end
  local playerId = runtimeContext.runtime.vehicleId
  if playerId ~= nil and tostring(senderId) == tostring(playerId) then return true end
  -- No vehicle-switch hook refreshes the cached id, so a mismatch is not proof
  -- of a foreign sender: the player may simply have changed vehicles. Resolve
  -- the current player vehicle once before rejecting, otherwise this gate would
  -- itself become a way to lose the Start Line pillars.
  if type(getPlayerVehicle) == "function" then
    local resolved = setRuntimeVehicle(getPlayerVehicle(0))
    playerId = resolved and runtimeContext.runtime.vehicleId or playerId
  end
  if playerId == nil then return true end
  if tostring(senderId) == tostring(playerId) then return true end
  ownershipRejections = ownershipRejections + 1
  if ownershipRejections <= 8 or ownershipRejections % 200 == 0 then
    M.trace(
      "bridge.owner", "rejected sender=%s player=%s rejections=%d",
      tostring(senderId), tostring(playerId), ownershipRejections
    )
  end
  return false
end
M.sentByPlayerVehicle = sentByPlayerVehicle

function M.trace(area, formatString, ...)
  if type(log) ~= "function" then return end
  local ok, message = pcall(string.format, tostring(formatString), ...)
  if not ok then message = tostring(formatString) .. " [format-error=" .. tostring(message) .. "]" end
  log("I", "GhostRacerDiag.GE", string.format(
    "[v%s][%s][vehicle=%s][raceActive=%s][racePending=%s] %s",
    CODE_VERSION,
    tostring(area or "general"),
    tostring(runtimeContext.runtime.vehicleId or "none"),
    tostring(raceState.raceActive),
    tostring(raceState.raceStartPending),
    tostring(message)
  ))
end

M.trace("module.cache", "clearedGeSubmodules=%d", clearedGeSubmodules)

local function isGhostRacerAppName(value)
  value = tostring(value or ""):lower():gsub("[^%w]", "")
  return value == "ghostracerapp"
end

local function isGhostRacerMod(mod)
  local identifiers
  if type(mod) == "table" then
    identifiers = {
      mod.modname,
      mod.filename,
      mod.fullpath,
      mod.dirname,
      mod.path,
      mod.name
    }
  elseif type(mod) == "string" then
    identifiers = {mod}
  else
    return false
  end
  for index = 1, #identifiers do
    local value = tostring(identifiers[index] or ""):lower():gsub("\\", "/")
    local compact = value:gsub("[^%w]", "")
    if compact:find("ghostracerenhanced", 1, true)
        or compact:find("bngghost", 1, true) then
      return true
    end
  end
  return false
end

local function tableIsArray(value)
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return count == maximum
end

local function stripAppFromLayout(value)
  if type(value) ~= "table" then return value, 0 end
  local removed = 0
  if tableIsArray(value) then
    local result = {}
    for index = 1, #value do
      local child = value[index]
      if type(child) == "table"
          and (isGhostRacerAppName(child.appName)
            or isGhostRacerAppName(child.directive)) then
        removed = removed + 1
      else
        local cleaned, childRemoved = stripAppFromLayout(child)
        result[#result + 1] = cleaned
        removed = removed + childRemoved
      end
    end
    return result, removed
  end

  for key, child in pairs(value) do
    if isGhostRacerAppName(key)
        or (type(child) == "table"
          and (isGhostRacerAppName(child.appName)
            or isGhostRacerAppName(child.directive))) then
      value[key] = nil
      removed = removed + 1
    else
      local cleaned, childRemoved = stripAppFromLayout(child)
      value[key] = cleaned
      removed = removed + childRemoved
    end
  end
  return value, removed
end

function M.removeSavedUiLayoutEntries()
  local removed = 0
  local service = rawget(_G, "ui_apps")
    or (type(extensions) == "table" and extensions.ui_apps)
  if type(service) == "table"
      and type(service.getAvailableLayouts) == "function"
      and type(service.saveLayout) == "function" then
    local ok, layouts = pcall(service.getAvailableLayouts)
    if ok and type(layouts) == "table" then
      for index = 1, #layouts do
        local layout = layouts[index]
        local cleaned, layoutRemoved = stripAppFromLayout(layout)
        if layoutRemoved > 0 then
          local saved = pcall(service.saveLayout, cleaned)
          if saved then removed = removed + layoutRemoved end
        end
      end
      if type(service.requestUIAppsData) == "function" then
        pcall(service.requestUIAppsData)
      end
      return removed
    end
  end

  if not FS or type(FS.findFiles) ~= "function" then return removed end
  local ok, filenames = pcall(
    FS.findFiles,
    FS,
    "/settings/ui_apps/layouts/",
    "*.uilayout.json",
    -1,
    false,
    false
  )
  if not ok or type(filenames) ~= "table" then return removed end
  for index = 1, #filenames do
    local filename = filenames[index]
    local layout = jsonReadFile(filename)
    if type(layout) == "table" then
      local cleaned, layoutRemoved = stripAppFromLayout(layout)
      if layoutRemoved > 0 and jsonWriteFile(filename, cleaned, true) ~= false then
        removed = removed + layoutRemoved
      end
    end
  end
  if type(service) == "table" and type(service.requestUIAppsData) == "function" then
    pcall(service.requestUIAppsData)
  end
  return removed
end

local function asLuaString(value)
  if value == nil then return "nil" end
  return string.format("%q", tostring(value))
end

local function asLuaNumber(value)
  value = tonumber(value)
  return value and tostring(value) or "nil"
end

local function raceDisplayName(race, fallback)
  local candidate
  if type(race) == "table" then
    candidate = race.name or race.title
    if type(candidate) ~= "string" and type(race.path) == "table" then
      candidate = race.path.name
    end
  end
  if type(candidate) ~= "string" or candidate == "" then candidate = fallback end
  if type(candidate) == "string" and candidate ~= "" then
    return candidate:gsub("[%c]+", " "):sub(1, 64)
  end
  return "Time Trial"
end

local function callModuleGetter(module, methodName, argument)
  local method = type(module) == "table" and module[methodName] or nil
  if type(method) ~= "function" then return nil end
  local ok, result
  if argument ~= nil then
    ok, result = pcall(method, argument)
    if not ok or result == nil then ok, result = pcall(method, module, argument) end
  else
    ok, result = pcall(method)
    if not ok or result == nil then ok, result = pcall(method, module) end
  end
  return ok and result or nil
end

local function foregroundMissionInfo()
  local manager = rawget(_G, "gameplay_missions_missionManager")
  if type(manager) ~= "table" then return nil, nil end

  local foregroundMission = callModuleGetter(manager, "getForegroundMission")
    or callModuleGetter(manager, "getForegroundMissionData")
  local missionId = callModuleGetter(manager, "getForegroundMissionId")
  if type(missionId) == "table" then
    foregroundMission = missionId
    missionId = missionId.id or missionId.missionId
  end
  if (missionId == nil or tostring(missionId) == "") and type(foregroundMission) == "table" then
    missionId = foregroundMission.id or foregroundMission.missionId
  end
  if missionId == nil or tostring(missionId) == "" then return nil, nil end

  local mission = type(foregroundMission) == "table" and foregroundMission or nil
  local missions = rawget(_G, "gameplay_missions_missions")
  if not mission and type(missions) == "table" then
    local result = callModuleGetter(missions, "getMissionById", missionId)
    if type(result) == "table" then mission = result end
  end
  return tostring(missionId), mission
end

local function isTimeTrialMission(missionId, mission)
  local candidates = {missionId}
  if type(mission) == "table" then
    candidates[#candidates + 1] = mission.missionType
    candidates[#candidates + 1] = mission.missionTypeLabel
    candidates[#candidates + 1] = mission.type
    candidates[#candidates + 1] = mission.id
    candidates[#candidates + 1] = mission.missionId
    local typeData = mission.missionTypeData
    if type(typeData) == "table" then
      candidates[#candidates + 1] = typeData.type
      candidates[#candidates + 1] = typeData.id
      candidates[#candidates + 1] = typeData.name
    end
  end
  for index = 1, #candidates do
    local normalized = tostring(candidates[index] or ""):lower():gsub("[^%w]", "")
    if normalized:find("timetrial", 1, true) then return true end
  end
  return false
end

local function timeTrialMissionProfile(missionId, mission, source)
  if type(mission) == "table" then
    missionId = missionId or mission.id or mission.missionId
  end
  if not missionId or not isTimeTrialMission(missionId, mission) then return nil end
  local files = ghostRecord.resolveRaceFiles(missionId)
  return {
    id = files.raceName,
    name = mission and type(mission.name) == "string" and mission.name or files.raceName,
    level = files.levelName,
    source = source or "foregroundMission",
    traceId = "mission-" .. tostring(files.raceName)
  }
end

local function tableNumber(value, key, index)
  if value == nil then return nil end
  local ok, result = pcall(function()
    local candidate = value[key]
    if candidate == nil and index ~= nil then candidate = value[index] end
    return tonumber(candidate)
  end)
  return ok and result or nil
end

local function currentQuickraceScenario()
  local scenarios = rawget(_G, "scenario_scenarios")
    or type(extensions) == "table" and extensions.scenario_scenarios
  local scenario = callModuleGetter(scenarios, "getScenario")
  if type(scenario) ~= "table" or scenario.isQuickRace ~= true then
    return nil, type(scenario) == "table" and scenario or nil
  end
  local state = tostring(scenario.state or "")
  local scenarioRaceState = tostring(scenario.raceState or "")
  if (state ~= "" and state ~= "pre-running" and state ~= "deferredRunning"
      and state ~= "running") or scenarioRaceState == "done" then
    return nil, scenario
  end
  return scenario, scenario
end

local function quickraceStartPose(scenario)
  local track = type(scenario) == "table" and scenario.track or nil
  local transform = type(track) == "table" and track.startTransform or nil
  local position = type(transform) == "table" and transform.pos or nil
  local rotation = type(transform) == "table" and transform.rot or nil
  local px = tableNumber(position, "x", 1)
  local py = tableNumber(position, "y", 2)
  local pz = tableNumber(position, "z", 3)
  if not px or not py or not pz or rotation == nil or type(vec3) ~= "function" then
    return nil
  end

  -- Quick Race spawns use this quaternion directly. BeamNG vehicles face
  -- local -Y, so rotating that axis reconstructs getDirectionVector() at the
  -- official grid even when Ghost Racer is hot-reloaded later in the lap.
  local ok, forward = pcall(function() return rotation * vec3(0, -1, 0) end)
  if not ok or forward == nil then return nil end
  local nx = tableNumber(forward, "x", 1)
  local ny = tableNumber(forward, "y", 2)
  local nz = tableNumber(forward, "z", 3) or 0
  if not nx or not ny then return nil end
  local horizontalLength = math.sqrt(nx * nx + ny * ny)
  if horizontalLength < 0.001 then return nil end
  return {
    startX = px,
    startY = py,
    startZ = pz,
    startNx = nx / horizontalLength,
    startNy = ny / horizontalLength,
    startNz = nz
  }
end

local function quickraceScenarioProfile(scenario)
  if type(scenario) ~= "table" or scenario.isQuickRace ~= true then return nil end
  local track = type(scenario.track) == "table" and scenario.track or {}
  local identity = scenario.scenarioName or track.trackName or track.raceFile
    or scenario.sourceFile
  if identity == nil or tostring(identity) == "" then return nil end

  identity = "quickrace-" .. tostring(identity)
  if scenario.isReverse == true or track.reverse == true then
    identity = identity .. "-reverse"
  end
  if scenario.rollingStart == true or track.rollingStart == true then
    identity = identity .. "-rolling"
  end
  local files = ghostRecord.resolveRaceFiles(identity)
  local displayName = scenario.name or track.name or scenario.scenarioName
    or files.raceName
  if type(displayName) ~= "string" or displayName == "" then
    displayName = files.raceName
  elseif type(translateLanguage) == "function" then
    local ok, translated = pcall(translateLanguage, displayName, displayName)
    if ok and type(translated) == "string" and translated ~= "" then
      displayName = translated
    end
  end

  local profile = {
    id = files.raceName,
    name = displayName:gsub("[%c]+", " "):sub(1, 64),
    level = tostring(scenario.levelName or files.levelName),
    source = "quickraceScenario",
    traceId = "quickrace-" .. tostring(files.raceName)
  }
  local pose = quickraceStartPose(scenario)
  if pose then
    for key, value in pairs(pose) do profile[key] = value end
  end
  return profile
end

function M.getCurrentTimeTrialProfile(diagnosticTraceId)
  local missionId, mission = foregroundMissionInfo()
  -- A live Quick Race Scenario is the authoritative activity selected by the
  -- home-screen Time Trials entry. Prefer it over a Mission manager value that
  -- may still describe the previously active activity during HUD transitions.
  local quickrace, inspectedScenario = currentQuickraceScenario()
  local quickraceProfile = quickraceScenarioProfile(quickrace)
  if quickraceProfile then
    if diagnosticTraceId then
      M.trace(
        "tt.query",
        "request=%s result=quickraceScenario id=%s name=%q level=%s scenarioName=%s raceFile=%s state=%s raceState=%s startPose=%s",
        tostring(diagnosticTraceId), tostring(quickraceProfile.id),
        tostring(quickraceProfile.name), tostring(quickraceProfile.level),
        tostring(quickrace.scenarioName),
        tostring(quickrace.track and quickrace.track.raceFile),
        tostring(quickrace.state), tostring(quickrace.raceState),
        tostring(quickraceProfile.startX ~= nil)
      )
    end
    return quickraceProfile
  end
  local foregroundProfile = timeTrialMissionProfile(
    missionId, mission, "foregroundMission"
  )
  if foregroundProfile then
    if diagnosticTraceId then
      M.trace(
        "tt.query",
        "request=%s result=foregroundMission id=%s name=%q level=%s missionId=%s missionType=%s",
        tostring(diagnosticTraceId), tostring(foregroundProfile.id),
        tostring(foregroundProfile.name), tostring(foregroundProfile.level),
        tostring(missionId), tostring(mission and mission.missionType)
      )
    end
    return foregroundProfile
  end
  if type(timeTrialState.activeTimeTrialProfile) == "table" and (raceState.raceActive or raceState.raceStartPending) then
    if diagnosticTraceId then
      M.trace(
        "tt.query",
        "request=%s result=raceHook id=%s name=%q level=%s source=%s",
        tostring(diagnosticTraceId), tostring(timeTrialState.activeTimeTrialProfile.id),
        tostring(timeTrialState.activeTimeTrialProfile.name), tostring(timeTrialState.activeTimeTrialProfile.level),
        tostring(timeTrialState.activeTimeTrialProfile.source)
      )
    end
    return timeTrialState.activeTimeTrialProfile
  end
  if type(timeTrialState.missionStartFallback.profile) == "table" then
    -- Quick Race profiles are discoverable from the live Scenario for their
    -- entire valid lifetime. If no active Scenario was found above, a cached
    -- quickraceScenario profile belongs to an activity that has already been
    -- left and must never turn a Freeroam Set & start into a tt- line.
    if timeTrialState.missionStartFallback.profile.source == "quickraceScenario" then
      if diagnosticTraceId then
        M.trace(
          "tt.query",
          "request=%s result=staleQuickraceRejected id=%s name=%q scenarioPresent=%s state=%s raceState=%s",
          tostring(diagnosticTraceId), tostring(timeTrialState.missionStartFallback.profile.id),
          tostring(timeTrialState.missionStartFallback.profile.name),
          tostring(inspectedScenario ~= nil),
          tostring(inspectedScenario and inspectedScenario.state),
          tostring(inspectedScenario and inspectedScenario.raceState)
        )
      end
      lifecycleCoordinator.clearFallback()
    else
      if diagnosticTraceId then
        M.trace(
          "tt.query",
          "request=%s result=missionLifecycle id=%s name=%q level=%s source=%s",
          tostring(diagnosticTraceId), tostring(timeTrialState.missionStartFallback.profile.id),
          tostring(timeTrialState.missionStartFallback.profile.name),
          tostring(timeTrialState.missionStartFallback.profile.level),
          tostring(timeTrialState.missionStartFallback.profile.source)
        )
      end
      return timeTrialState.missionStartFallback.profile
    end
  end
  if diagnosticTraceId then
    M.trace(
      "tt.query",
      "request=%s result=nil foregroundMissionId=%s foregroundMissionType=%s scenarioPresent=%s isQuickRace=%s scenarioName=%s state=%s raceState=%s",
      tostring(diagnosticTraceId), tostring(missionId),
      tostring(mission and mission.missionType),
      tostring(inspectedScenario ~= nil),
      tostring(inspectedScenario and inspectedScenario.isQuickRace),
      tostring(inspectedScenario and inspectedScenario.scenarioName),
      tostring(inspectedScenario and inspectedScenario.state),
      tostring(inspectedScenario and inspectedScenario.raceState)
    )
  end
  return nil
end

local function raceIdentity(race)
  local suffix = race and race.saveFileSuffix
  if suffix ~= nil and tostring(suffix) ~= "" and tostring(suffix) ~= "temp" then
    return tostring(suffix), nil, "saveFileSuffix"
  end

  local missionId, mission = foregroundMissionInfo()
  if missionId then
    local missionName = mission and type(mission.name) == "string" and mission.name or nil
    return missionId, missionName, "foregroundMission"
  end

  local path = race and type(race.path) == "table" and race.path or nil
  local config = path and type(path.config) == "table" and path.config or nil
  local pathIdentity = path and (path.id or path.name)
    or config and (config.id or config.name)
  if pathIdentity ~= nil and tostring(pathIdentity) ~= "" then
    return tostring(pathIdentity), tostring(pathIdentity), "racePath"
  end

  local activeVehicle = runtimeContext.runtime.vehicle
  if activeVehicle and type(activeVehicle.getPositionXYZ) == "function" then
    local ok, x, y, z = pcall(activeVehicle.getPositionXYZ, activeVehicle)
    if ok and tonumber(x) and tonumber(y) and tonumber(z) then
      return string.format("grid_%.1f_%.1f_%.1f", x, y, z), "Time Trial", "gridPose"
    end
  end
  return "session", "Time Trial", "session"
end

local function raceProfile(race, files, displayFallback, source)
  if not files then return nil end
  return {
    id = files.raceName,
    name = raceDisplayName(race, displayFallback or files.raceName),
    level = files.levelName,
    source = source or "raceHook",
    traceId = "race-" .. tostring(files.raceName)
  }
end

local function timeTrialProfileLiteral(profile)
  if type(profile) ~= "table" then return "nil" end
  local fields = {
    "id=" .. asLuaString(profile.id),
    "name=" .. asLuaString(profile.name),
    "level=" .. asLuaString(profile.level),
    "source=" .. asLuaString(profile.source),
    "traceId=" .. asLuaString(profile.traceId)
  }
  local poseKeys = {"startX", "startY", "startZ", "startNx", "startNy", "startNz"}
  for index = 1, #poseKeys do
    local key = poseKeys[index]
    local value = tonumber(profile[key])
    if value then fields[#fields + 1] = key .. "=" .. tostring(value) end
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function raceProfileLiteral(race, files, displayFallback, source)
  if not files then return "nil" end
  return timeTrialProfileLiteral(
    raceProfile(race, files, displayFallback, source)
  )
end

queueController = function(command)
  local activeVehicle = runtimeContext.runtime.vehicle
  if not activeVehicle then
    M.trace("bridge.queue", "rejected: no player vehicle command=%s", tostring(command))
    return false
  end
  M.trace(
    "bridge.queue", "queue command=%s",
    tostring(command):gsub("%s+", " "):sub(1, 500)
  )
  activeVehicle:queueLuaCommand(
    'local c=controller.getController and controller.getController("ghostRacer"); '
      .. 'local hadGhostRacerController=c~=nil; '
      .. 'if not c and controller.loadControllerExternal then '
      .. 'pcall(controller.loadControllerExternal,"ghostRacer","ghostRacer",{}); '
      .. 'c=controller.getController and controller.getController("ghostRacer") end; '
      .. 'if type(log)=="function" then log("I","GhostRacerDiag.BRIDGE",'
      .. string.format(
        '%q',
        "[v" .. CODE_VERSION .. "] GE command received; controller existed before load="
      )
      .. '..tostring(hadGhostRacerController).." controller available="..tostring(c~=nil)) end; '
      .. 'if c then ' .. command .. ' end'
  )
  return true
end

-- A shell status report is useless if it cannot reach the Vehicle VM, and the
-- runtime vehicle reference is only populated by some hooks. Resolve the player
-- vehicle the same way the clipboard bridge does before giving up.
reportShellStatus = function(command)
  if not runtimeContext.runtime.vehicle and type(getPlayerVehicle) == "function" then
    setRuntimeVehicle(getPlayerVehicle(0))
  end
  return queueController(command)
end

-- Keybind entry points, declared in
-- lua/ge/extensions/core/input/actions/ghostRacer.json. They run in the GE VM
-- (ctx=tlua) and forward to the player vehicle's ghostRacer controller, mirroring
-- the matching HUD buttons. The player may bind them in Options > Controls.
local function resolvePlayerVehicleForHotkey()
  if not runtimeContext.runtime.vehicle and type(getPlayerVehicle) == "function" then
    setRuntimeVehicle(getPlayerVehicle(0))
  end
  return runtimeContext.runtime.vehicle
end

function M.hotkeySetStartLine()
  if not resolvePlayerVehicleForHotkey() then return false end
  -- Free-roam only, matching the HUD button (which is disabled during a race);
  -- the level is resolved here just as the HUD resolves it before the call.
  local level = (type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier())
    or "unknown_level"
  return queueController(
    "if c.setStartLine then c.setStartLine("
      .. string.format("%q", tostring(level)) .. ",nil,\"hotkey\") end"
  )
end

function M.hotkeyToggleAutoLap()
  if not resolvePlayerVehicleForHotkey() then return false end
  return queueController("if c.toggleAutoLap then c.toggleAutoLap() end")
end

function M.hotkeySetFinishLine()
  if not resolvePlayerVehicleForHotkey() then return false end
  return queueController("if c.setFinishLine then c.setFinishLine() end")
end

function M.hotkeyClearFinishLine()
  if not resolvePlayerVehicleForHotkey() then return false end
  return queueController("if c.clearFinishLine then c.clearFinishLine() end")
end

function M.hotkeyCreateStartVariant()
  if not resolvePlayerVehicleForHotkey() then return false end
  return queueController("if c.createStartVariant then c.createStartVariant() end")
end

function M.hotkeyClearStartLine()
  if not resolvePlayerVehicleForHotkey() then return false end
  return queueController("if c.clearStartLine then c.clearStartLine() end")
end

-- Purely a UI toggle, so unlike the other keybinds it does not need the player
-- vehicle or the controller: broadcast to the app, which flips between its full
-- panel and the compact mini badge exactly as its header button does.
function M.hotkeyToggleMinimize()
  if guihooks and guihooks.trigger then
    guihooks.trigger("GhostRacerToggleMinimize")
    return true
  end
  return false
end

local function clipboardNotice(message, seconds)
  if guihooks and guihooks.message then
    guihooks.message({txt = tostring(message)}, seconds or 4)
  end
end

local function removeClipboardTemp(filename)
  if not filename or not FS or type(FS.removeFile) ~= "function" then return end
  pcall(FS.removeFile, FS, filename)
end

local function formattedBytes(bytes)
  bytes = math.max(0, tonumber(bytes) or 0)
  if bytes >= 1024 * 1024 then return string.format("%.2f MB", bytes / (1024 * 1024)) end
  if bytes >= 1024 then return string.format("%.1f KB", bytes / 1024) end
  return string.format("%d B", bytes)
end

function M.copyGhostShareFile(filename, ghostCount, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  filename = tostring(filename or "")
  if filename ~= "ghostReplays/clipboard/ghostRacerShareExport.json" then
    clipboardNotice("Share failed · invalid temporary source", 5)
    return false
  end
  local packageData = jsonReadFile(filename)
  removeClipboardTemp(filename)
  if type(packageData) ~= "table" or packageData.kind ~= "ghostRacerShare"
      or type(packageData.ghosts) ~= "table" then
    clipboardNotice("Share failed · prepared data could not be read", 5)
    return false
  end
  local encoder = rawget(_G, "jsonEncode")
  if type(encoder) ~= "function" then
    clipboardNotice("Share failed · JSON encoder unavailable", 5)
    return false
  end
  local encodedOk, encoded = pcall(encoder, packageData)
  if not encodedOk or type(encoded) ~= "string" then
    clipboardNotice("Share failed · data encoding error", 5)
    return false
  end
  local shareText = GHOST_SHARE_PREFIX .. encoded
  if #shareText > GHOST_SHARE_MAX_BYTES then
    clipboardNotice(
      "Share code is " .. formattedBytes(#shareText)
        .. " · select fewer Ghosts (16 MB clipboard limit)",
      7
    )
    return false
  end
  local writer = rawget(_G, "setClipboard")
  if type(writer) ~= "function" then
    clipboardNotice("Share failed · system clipboard is unavailable", 5)
    return false
  end
  local copied, copyError = pcall(writer, shareText)
  if not copied then
    M.trace("clipboard.export", "setClipboard failed error=%s", tostring(copyError))
    clipboardNotice("Share failed · system clipboard rejected the data", 5)
    return false
  end
  ghostCount = math.max(1, math.floor(tonumber(ghostCount) or #packageData.ghosts))
  clipboardNotice(string.format(
    "Ghost share code copied · %d selected · %s",
    ghostCount,
    formattedBytes(#shareText)
  ), 6)
  M.trace("clipboard.export", "copied ghosts=%d bytes=%d", ghostCount, #shareText)
  return true
end

function M.importGhostsFromClipboard()
  clipboardNotice("Reading Ghost share code from clipboard…", 4)
  local reader = rawget(_G, "getClipboard")
  if type(reader) ~= "function" then
    clipboardNotice("Import failed · system clipboard is unavailable", 5)
    return false
  end
  local readOk, clipboardText = pcall(reader)
  if not readOk or type(clipboardText) ~= "string" or clipboardText == "" then
    clipboardNotice("Import failed · clipboard does not contain text", 5)
    return false
  end
  if #clipboardText > GHOST_SHARE_MAX_BYTES then
    clipboardNotice(
      "Import failed · clipboard text is " .. formattedBytes(#clipboardText)
        .. " (16 MB limit)",
      7
    )
    return false
  end
  clipboardText = clipboardText:gsub("^%s+", ""):gsub("%s+$", "")
  if clipboardText:sub(1, #GHOST_SHARE_PREFIX) ~= GHOST_SHARE_PREFIX then
    clipboardNotice("Import failed · clipboard is not a Ghost Racer share code", 6)
    return false
  end
  local decoder = rawget(_G, "jsonDecodeSilent") or rawget(_G, "jsonDecode")
  if type(decoder) ~= "function" then
    clipboardNotice("Import failed · JSON decoder unavailable", 5)
    return false
  end
  local decodedOk, packageData = pcall(
    decoder,
    clipboardText:sub(#GHOST_SHARE_PREFIX + 1),
    "GhostRacerClipboardImport"
  )
  if not decodedOk or type(packageData) ~= "table"
      or packageData.kind ~= "ghostRacerShare" or type(packageData.ghosts) ~= "table" then
    clipboardNotice("Import failed · share code is damaged or unsupported", 6)
    return false
  end
  if jsonWriteFile(GHOST_SHARE_IMPORT_FILE, packageData, false) == false then
    clipboardNotice("Import failed · could not stage clipboard data", 5)
    return false
  end
  local activeVehicle = setRuntimeVehicle(getPlayerVehicle(0))
  if not activeVehicle or not queueController(
      "if c.prepareClipboardImport then c.prepareClipboardImport("
        .. asLuaString(GHOST_SHARE_IMPORT_FILE) .. ") end"
    ) then
    removeClipboardTemp(GHOST_SHARE_IMPORT_FILE)
    clipboardNotice("Import failed · player vehicle controller unavailable", 5)
    return false
  end
  M.trace(
    "clipboard.import",
    "queued ghosts=%d bytes=%d",
    #packageData.ghosts,
    #clipboardText
  )
  return true
end

local function queueMissionTimeTrialStart(profile)
  if type(profile) ~= "table" then
    M.trace("tt.fallback", "rejected: profile type=%s", type(profile))
    return false
  end
  local activeVehicle = setRuntimeVehicle(getPlayerVehicle(0))
  if not activeVehicle then
    M.trace(
      "tt.fallback", "waiting: no player vehicle profile=%s source=%s",
      tostring(profile.id), tostring(profile.source)
    )
    return false
  end
  M.trace(
    "tt.fallback",
    "queue profile id=%s name=%q level=%s source=%s trace=%s startPose=%s",
    tostring(profile.id), tostring(profile.name), tostring(profile.level),
    tostring(profile.source), tostring(profile.traceId),
    tostring(profile.startX ~= nil)
  )
  profile.source = profile.source or "foregroundMission"
  profile.traceId = profile.traceId or ("mission-" .. tostring(profile.id))
  return queueController(
    "if c.ensureTimeTrialStart then c.ensureTimeTrialStart("
      .. timeTrialProfileLiteral(profile) .. ") end"
  )
end

function M.setGhostCameraPose(pose, enabled, mode, targetId, targetLabel, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return cameraBackend.setPose(pose, enabled, mode, targetId, targetLabel)
end

function M.getGhostCameraState()
  return cameraBackend.getState()
end
local function getPlayerState(race)
  local activeVehicleId = runtimeContext.runtime.vehicleId
  if not race or not race.states or not activeVehicleId then return nil end
  return race.states[activeVehicleId]
end

local function isLapFinishNode(tbl)
  local graph = tbl
    and tbl.race
    and tbl.race.path
    and tbl.race.path.config
    and tbl.race.path.config.graph
  if not graph or not tbl.pathnode then return false end

  for _, edge in pairs(graph) do
    if edge.targetNode == tbl.pathnode.id and edge.lastInLap then
      return true
    end
  end
  return false
end

local function recordingIsValid(history)
  if not history then return false end
  if history.valid == false or history.invalid == true then return false end
  return tonumber(history.lapTime) ~= nil
end

function M.setFreeRoamMarkers(markers, savedVisible, activeVisible, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return worldRenderer.setFreeRoamMarkers(markers, savedVisible, activeVisible)
end

function M.setGhostShellSet(descriptors, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return shellRenderer.setSet(descriptors)
end

function M.prewarmGhostShellSet(descriptors, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return shellRenderer.prewarm(descriptors)
end

function M.releaseGhostShellPool(senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return shellRenderer.releasePool()
end

-- Diagnostic only, and deliberately not wired to the HUD: it parks the Ghost
-- body in the wrong place for the first minute. Run from the Lua console with
--   extensions.ghostlapping.setGhostShellPhaseProbe(true)
-- then start a replay and read the phase= field in shell.health.
function M.setGhostShellPhaseProbe(enabled)
  return shellRenderer.setPhaseProbe(enabled)
end

-- Experiment: dynamic collision is disabled on every Ghost body now, and this
-- forces the teleport back to every frame so the smoothness can be compared to
-- the throttled default live. If the frame rate no longer decays at per-frame,
-- turning collision off has broken the smooth-versus-decay trade-off. Run from
-- the Lua console with
--   extensions.ghostlapping.setGhostShellPerFrame(true)
-- and read fps in shell.health while it plays.
function M.setGhostShellPerFrame(enabled)
  return shellRenderer.setTeleportPerFrame(enabled)
end

-- Switch the Ghost body backend between the default non-physics TSStatic mesh
-- (cheap, never decays, moves every frame) and the native BeamNGVehicle fallback,
-- kept for A/B measurement. Run from the Lua console with
--   extensions.ghostlapping.setGhostShellBackend("native")
-- then restart the replay so the pool repopulates through the chosen backend;
-- pass "tsstatic" to switch back to the default.
function M.setGhostShellBackend(kind)
  return shellRenderer.setBackendKind(kind)
end

function M.setGhostShellClock(elapsed, playing, duration, looping, resync, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return shellRenderer.setClock(elapsed, playing, duration, looping, resync)
end

function M.onGhostVehicleReady(objectId, ghostEnabled, frozen)
  return shellRenderer.markBackendReady(objectId, ghostEnabled, frozen)
end

function M.setGhostTrailSegments(segments, visible, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return worldRenderer.setGhostTrailSegments(segments, visible)
end

-- Render a player-facing toast from the GE VM. The controller runs in the
-- vehicle VM; a toast fired there during a vehicle reset (R key) is wiped by the
-- game's own reset UI clear, so the player saw nothing. Forwarding it here and
-- letting it render on the next GE frame puts it up after the reset settles.
function M.showGhostMessage(message, seconds, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  if guihooks and guihooks.message then
    guihooks.message({txt = tostring(message)}, tonumber(seconds) or 3)
  end
  M.trace("ui.toast", "shown text=%s", tostring(message))
  return true
end

function M.setBestLapLineSegments(segments, visible, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return worldRenderer.setBestLapLineSegments(segments, visible)
end

function M.setLiveInputTrailSegments(segments, visible, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return worldRenderer.setLiveInputTrailSegments(segments, visible)
end

function M.setRouteGuide(path, checkpoints, enabled, pathVisible, checkpointsVisible, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return worldRenderer.setRouteGuide(
    path,
    checkpoints,
    enabled,
    pathVisible,
    checkpointsVisible
  )
end

function M.setRouteGuideVisibility(enabled, pathVisible, checkpointsVisible, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return worldRenderer.setRouteGuideVisibility(enabled, pathVisible, checkpointsVisible)
end

function M.setRouteCheckpointProgress(nextCheckpoint, missedCheckpoint, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return worldRenderer.setRouteCheckpointProgress(nextCheckpoint, missedCheckpoint)
end

function M.onPreRender()
  -- Persistent native-vehicle placement is committed from onUpdate. This hook
  -- remains reserved for immediate debug drawing.
  return worldRenderer.onPreRender()
end
local function beginQuickrace(profile, recoveredMidLap)
  if type(profile) ~= "table" or raceState.raceActive or raceState.raceStartPending then return false end
  local activeVehicle = setRuntimeVehicle(getPlayerVehicle(0))
  if not activeVehicle then
    M.trace("quickrace.start", "rejected: no player vehicle")
    return false
  end

  local files = ghostRecord.resolveRaceFiles(profile.id)
  files.profileLiteral = timeTrialProfileLiteral(profile)
  files.identitySource = profile.source
  lifecycleCoordinator.beginQuickrace(files, profile, recoveredMidLap)

  local loadFilename = raceState.raceFiles.persistent and raceState.raceFiles.loadFilename or nil
  local saveFilename = raceState.raceFiles.persistent and raceState.raceFiles.saveFilename or nil
  M.trace(
    "quickrace.start",
    "begin id=%s name=%q level=%s source=%s startPose=%s recoveredMidLap=%s",
    tostring(profile.id), tostring(profile.name), tostring(profile.level),
    tostring(profile.source), tostring(profile.startX ~= nil),
    tostring(raceState.quickraceDiscardFirstFinish)
  )
  return queueController(string.format(
    "if c.beginRace then c.beginRace(%s, %s, %s, %s) end",
    asLuaString(loadFilename),
    asLuaString(saveFilename),
    asLuaNumber(raceState.pbTime),
    raceState.raceFiles.profileLiteral
  ))
end

-- The home-screen Time Trials mode runs through the legacy Quick Race
-- Scenario pipeline. It emits onRaceStart (singular), not the modern
-- gameplay/race onRaceStarted event handled below.
function M.onRaceStart()
  local scenario = currentQuickraceScenario()
  local profile = quickraceScenarioProfile(scenario)
  M.trace(
    "quickrace.hook",
    "onRaceStart scenarioPresent=%s isQuickRace=%s scenarioName=%s raceState=%s profile=%s",
    tostring(scenario ~= nil), tostring(scenario and scenario.isQuickRace),
    tostring(scenario and scenario.scenarioName),
    tostring(scenario and scenario.raceState), tostring(profile and profile.id)
  )
  if profile then
    if raceState.quickraceRaceActive or raceState.raceActive or raceState.raceStartPending then
      queueController("if c.endRace then c.endRace() end")
      lifecycleCoordinator.stopQuickraceActivity()
    end
    beginQuickrace(profile, false)
  end
end

function M.onRaceWaypointReached(info)
  if not raceState.quickraceRaceActive or not raceState.raceActive then return end
  if info and info.vehicleId ~= nil
      and tonumber(info.vehicleId) ~= tonumber(runtimeContext.runtime.vehicleId) then
    return
  end
  if info and info.next ~= nil and tonumber(info.next) ~= 1 then return end

  local cumulativeTime = tonumber(info and info.time)
  if not cumulativeTime then
    M.trace("quickrace.lap", "ignored finish waypoint without numeric time")
    return
  end
  local lapTime = cumulativeTime - raceState.quickraceLastCumulativeTime
  if lapTime <= 0 then
    M.trace(
      "quickrace.lap",
      "ignored non-positive lap cumulative=%.6f previous=%.6f",
      cumulativeTime, raceState.quickraceLastCumulativeTime
    )
    return
  end

  raceState.quickraceLastCumulativeTime = cumulativeTime
  local continueRace = info and info.next ~= nil
  if raceState.quickraceDiscardFirstFinish then
    raceState.quickraceDiscardFirstFinish = false
    M.trace(
      "quickrace.lap",
      "discarding hot-reload partial cumulative=%.6f next=%s continue=%s",
      cumulativeTime, tostring(info and info.next), tostring(continueRace)
    )
    if continueRace then
      queueController(
        "if c.finishRaceLap then c.finishRaceLap(nil, nil, false, true) end"
      )
    else
      queueController("if c.endRace then c.endRace() end")
      lifecycleCoordinator.finishQuickraceLap()
    end
    return
  end

  raceState.quickraceLapCount = raceState.quickraceLapCount + 1
  local isBest = not raceState.pbTime or lapTime < raceState.pbTime
  if isBest then raceState.pbTime = lapTime end
  local saveFilename = raceState.raceFiles and raceState.raceFiles.persistent and raceState.raceFiles.saveFilename or nil
  M.trace(
    "quickrace.lap",
    "finish lap=%d lapTime=%.6f cumulative=%.6f next=%s continue=%s best=%s",
    raceState.quickraceLapCount, lapTime, cumulativeTime, tostring(info and info.next),
    tostring(continueRace), tostring(isBest)
  )
  queueController(string.format(
    "if c.finishRaceLap then c.finishRaceLap(%s, %s, %s, %s) end",
    asLuaString(saveFilename),
    asLuaNumber(lapTime),
    tostring(isBest),
    tostring(continueRace)
  ))

  if not continueRace then
    lifecycleCoordinator.finishQuickraceLap()
  end
end

function M.onRaceResult(result)
  if not raceState.quickraceRaceActive or not raceState.raceActive then return end
  local cumulativeTime = tonumber(result and result.finalTime)
  local lapTime = cumulativeTime and (cumulativeTime - raceState.quickraceLastCumulativeTime) or nil
  if raceState.quickraceDiscardFirstFinish then
    M.trace(
      "quickrace.result",
      "discarding hot-reload partial finalTime=%s",
      tostring(cumulativeTime)
    )
    queueController("if c.endRace then c.endRace() end")
  elseif not lapTime or lapTime <= 0 then
    M.trace(
      "quickrace.result",
      "no usable final lap finalTime=%s previous=%.6f; ending controller race",
      tostring(cumulativeTime), raceState.quickraceLastCumulativeTime
    )
    queueController("if c.endRace then c.endRace() end")
  else
    local isBest = not raceState.pbTime or lapTime < raceState.pbTime
    if isBest then raceState.pbTime = lapTime end
    local saveFilename = raceState.raceFiles and raceState.raceFiles.persistent and raceState.raceFiles.saveFilename or nil
    M.trace(
      "quickrace.result",
      "fallback final lapTime=%.6f finalTime=%.6f best=%s",
      lapTime, cumulativeTime, tostring(isBest)
    )
    queueController(string.format(
      "if c.finishRaceLap then c.finishRaceLap(%s, %s, %s, false) end",
      asLuaString(saveFilename), asLuaNumber(lapTime), tostring(isBest)
    ))
  end
  lifecycleCoordinator.finishQuickraceResult()
end

function M.onRaceStarted(tbl)
  -- Some activities emit this hook both while the countdown is being prepared
  -- and again at GO. Treat it as session discovery and make the actual
  -- controller start idempotent.
  M.trace(
    "race.hook",
    "onRaceStarted active=%s pending=%s racePresent=%s started=%s suffix=%s",
    tostring(raceState.raceActive), tostring(raceState.raceStartPending),
    tostring(tbl and tbl.race ~= nil),
    tostring(tbl and tbl.race and tbl.race.started),
    tostring(tbl and tbl.race and tbl.race.saveFileSuffix)
  )
  if raceState.raceActive then return end
  if raceState.raceStartPending then
    if tbl and tbl.race and tbl.race.started == true then
      if raceState.raceFiles then raceState.raceFiles.awaitGo = false end
      if not raceState.countdownActive then startPendingRace() end
    end
    return
  end

  local race = tbl and tbl.race
  if not race then return end
  lifecycleCoordinator.beginRaceDiscovery()

  local activeVehicle = setRuntimeVehicle(getPlayerVehicle(0))
  if not activeVehicle then
    return
  end

  local state = getPlayerState(race)
  if not state or state.isAiVeh then return end

  local raceName, displayFallback, identitySource = raceIdentity(race)
  local files = ghostRecord.resolveRaceFiles(raceName)
  local profile = raceProfile(race, files, displayFallback, identitySource)
  files.profileLiteral = raceProfileLiteral(
    race, files, displayFallback, identitySource
  )
  files.awaitGo = race.started ~= true
  files.identitySource = identitySource
  lifecycleCoordinator.prepareRace(files, profile)
  M.trace(
    "race.hook",
    "profile id=%s name=%q level=%s source=%s trace=%s",
    tostring(timeTrialState.activeTimeTrialProfile.id), tostring(timeTrialState.activeTimeTrialProfile.name),
    tostring(timeTrialState.activeTimeTrialProfile.level), tostring(timeTrialState.activeTimeTrialProfile.source),
    tostring(timeTrialState.activeTimeTrialProfile.traceId)
  )
  local loadFilename = raceState.raceFiles.persistent and raceState.raceFiles.loadFilename or nil
  local saveFilename = raceState.raceFiles.persistent and raceState.raceFiles.saveFilename or nil
  queueController(string.format(
    "if c.prepareRace then c.prepareRace(%s, %s, %s, %s) end",
    asLuaString(loadFilename),
    asLuaString(saveFilename),
    asLuaNumber(raceState.pbTime),
    raceState.raceFiles.profileLiteral
  ))
  if type(log) == "function" then
    log("I", "ghostlapping.timeTrial", string.format(
      "Automatic start tt-%s prepared from %s (race.started=%s)",
      tostring(raceState.raceFiles.raceName),
      tostring(identitySource),
      tostring(race.started == true)
    ))
  end

  -- onCountdownEnded is the authoritative GO signal. The short delayed
  -- fallback supports activities that do not use a countdown at all.
  if raceState.countdownEndedGrace > 0 then
    startPendingRace()
    return
  end
  if raceState.countdownActive then return end
end

startPendingRace = function()
  if not runtimeContext.runtime.vehicle
      or not lifecycleCoordinator.startPreparedRace() then return false end

  local loadFilename = raceState.raceFiles.persistent and raceState.raceFiles.loadFilename or nil
  local saveFilename = raceState.raceFiles.persistent and raceState.raceFiles.saveFilename or nil
  queueController(string.format(
    "if c.beginRace then c.beginRace(%s, %s, %s, %s) end",
    asLuaString(loadFilename),
    asLuaString(saveFilename),
    asLuaNumber(raceState.pbTime),
    raceState.raceFiles.profileLiteral or "nil"
  ))
  return true
end

function M.onCountdownStarted()
  if raceState.quickraceRaceActive then
    queueController("if c.endRace then c.endRace() end")
  end
  lifecycleCoordinator.startCountdown()
end

function M.onCountdownEnded()
  lifecycleCoordinator.endCountdown()
  startPendingRace()
end

function M.onUpdate(dtReal, dtSim)
  local elapsed = math.max(tonumber(dtReal) or 0, 0)
  -- Vehicle playback advances on simulation time. Commit the corresponding
  -- scene transform during GE update, before the scene is handed to rendering.
  -- Retain the one-argument fallback for older builds and the test harness.
  local shellDeltaTime = dtSim
  if shellDeltaTime == nil then shellDeltaTime = dtReal end
  shellRenderer.advance(shellDeltaTime, elapsed)
  cameraBackend.update(elapsed)
  if timeTrialState.missionStartFallback.attempts > 0 and not raceState.raceActive and not raceState.raceStartPending then
    timeTrialState.missionStartFallback.delay = timeTrialState.missionStartFallback.delay - elapsed
    if timeTrialState.missionStartFallback.delay <= 0 then
      local profile = timeTrialState.missionStartFallback.profile or M.getCurrentTimeTrialProfile()
      local quickrace = currentQuickraceScenario()
      local recoveredRunningQuickrace = profile
        and profile.source == "quickraceScenario"
        and quickrace and quickrace.raceState == "racing"
      local queued = recoveredRunningQuickrace
        and beginQuickrace(profile, true)
        or profile and queueMissionTimeTrialStart(profile)
      if queued then
        lifecycleCoordinator.markFallbackQueued()
        M.trace(
          "tt.fallback",
          "queued successfully id=%s name=%q level=%s source=%s recoveredRunningQuickrace=%s",
          tostring(profile.id), tostring(profile.name), tostring(profile.level),
          tostring(profile.source), tostring(recoveredRunningQuickrace)
        )
        if type(log) == "function" then
          log("I", "ghostlapping.timeTrial",
            "Created fallback start tt-" .. tostring(profile.id)
              .. " from " .. tostring(profile.source))
        end
      else
        if timeTrialState.missionStartFallback.attempts == 40
            or timeTrialState.missionStartFallback.attempts == 20
            or timeTrialState.missionStartFallback.attempts == 1 then
          M.trace(
            "tt.fallback",
            "retry pending attemptsBeforeDecrement=%d profile=%s",
            timeTrialState.missionStartFallback.attempts,
            tostring(profile and profile.id)
          )
        end
        timeTrialState.missionStartFallback.attempts = timeTrialState.missionStartFallback.attempts - 1
        timeTrialState.missionStartFallback.delay = 0.25
      end
    end
  end
  raceState.countdownEndedGrace = math.max(0, raceState.countdownEndedGrace - elapsed)
  if not raceState.raceStartPending or raceState.countdownActive then return end
  if raceState.raceFiles and raceState.raceFiles.awaitGo then return end
  raceState.raceStartDelay = raceState.raceStartDelay - elapsed
  if raceState.raceStartDelay <= 0 then startPendingRace() end
end

function M.onScenarioChange(scenario)
  local profile = quickraceScenarioProfile(scenario)
  local scenarioState = type(scenario) == "table" and tostring(scenario.state or "") or ""
  local scenarioRaceState = type(scenario) == "table"
    and tostring(scenario.raceState or "") or ""
  local scenarioActive = profile and (scenarioState == "" or scenarioState == "pre-running"
    or scenarioState == "deferredRunning" or scenarioState == "running")
    and scenarioRaceState ~= "done"
  M.trace(
    "quickrace.lifecycle",
    "scenarioPresent=%s isQuickRace=%s scenarioName=%s state=%s raceState=%s profile=%s",
    tostring(type(scenario) == "table"),
    tostring(type(scenario) == "table" and scenario.isQuickRace),
    tostring(type(scenario) == "table" and scenario.scenarioName),
    tostring(type(scenario) == "table" and scenario.state),
    tostring(type(scenario) == "table" and scenario.raceState),
    tostring(profile and profile.id)
  )
  if scenarioActive then
    timeTrialState.activeTimeTrialProfile = profile
    lifecycleCoordinator.armFallback(profile, 0.05)
  else
    local cachedQuickrace = type(timeTrialState.missionStartFallback.profile) == "table"
      and timeTrialState.missionStartFallback.profile.source == "quickraceScenario"
    local activeQuickrace = type(timeTrialState.activeTimeTrialProfile) == "table"
      and timeTrialState.activeTimeTrialProfile.source == "quickraceScenario"
    if cachedQuickrace then
      lifecycleCoordinator.clearFallback()
    end
    if activeQuickrace then timeTrialState.activeTimeTrialProfile = nil end
    if not profile and (cachedQuickrace or activeQuickrace) then
      if raceState.quickraceRaceActive or raceState.raceActive or raceState.raceStartPending then
        queueController("if c.endRace then c.endRace() end")
      end
      lifecycleCoordinator.stopQuickraceActivity()
    end
    if profile and scenario.state == "post" then
      if raceState.quickraceRaceActive or raceState.raceActive then
        queueController("if c.endRace then c.endRace() end")
      end
      lifecycleCoordinator.stopQuickraceActivity()
    end
  end
end

function M.onAnyMissionChanged(state, mission)
  local lifecycleState = type(state) == "table"
    and (state.state or state.status or state.event) or state
  local missionData = type(mission) == "table" and mission
    or type(state) == "table" and (state.mission or state.missionData) or nil
  local missionId = missionData and (missionData.id or missionData.missionId)
  M.trace(
    "mission.lifecycle",
    "event=%s missionId=%s missionType=%s missionName=%q stateType=%s missionArgType=%s",
    tostring(lifecycleState), tostring(missionId),
    tostring(missionData and missionData.missionType),
    tostring(missionData and missionData.name), type(state), type(mission)
  )
  if lifecycleState == "started" then
    local profile = timeTrialMissionProfile(
      missionId, missionData, "missionLifecycle"
    )
    -- Give the authoritative Race hook one short window to identify a more
    -- specific route suffix before falling back to the foreground Mission ID.
    lifecycleCoordinator.armFallback(profile, 0.2)
    M.trace(
      "mission.lifecycle",
      "fallback armed profileId=%s profileName=%q profileLevel=%s source=%s attempts=%d",
      tostring(timeTrialState.missionStartFallback.profile and timeTrialState.missionStartFallback.profile.id),
      tostring(timeTrialState.missionStartFallback.profile and timeTrialState.missionStartFallback.profile.name),
      tostring(timeTrialState.missionStartFallback.profile and timeTrialState.missionStartFallback.profile.level),
      tostring(timeTrialState.missionStartFallback.profile and timeTrialState.missionStartFallback.profile.source),
      timeTrialState.missionStartFallback.attempts
    )
  elseif lifecycleState == "stopped" or lifecycleState == "abandoned"
      or lifecycleState == "failed" then
    if raceState.raceActive or raceState.raceStartPending then
      local reason = lifecycleState == "failed" and "missionFailed"
        or lifecycleState == "abandoned" and "missionAbandoned"
        or "missionStopped"
      queueController(string.format(
        "if c.endRace then c.endRace(%q) end",
        reason
      ))
      lifecycleCoordinator.stopRace()
    end
    lifecycleCoordinator.clearFallback()
    M.trace("mission.lifecycle", "fallback cleared")
  end
end

function M.onRacePathnodeReached(tbl)
  if not raceState.raceActive or not isLapFinishNode(tbl) then return end

  local state = getPlayerState(tbl.race)
  if not state or state.isAiVeh then return end

  local historicTimes = state.historicTimes or {}
  local lapCount = #historicTimes
  if lapCount == 0 or lapCount == raceState.lastLapCount then return end

  local history = historicTimes[lapCount]
  local valid = recordingIsValid(history)
  local lapTime = valid and tonumber(history.lapTime) or nil
  local isBest = valid and (not raceState.pbTime or lapTime < raceState.pbTime)
  if isBest then raceState.pbTime = lapTime end

  local continueRace = state.complete ~= true
  local saveFilename = raceState.raceFiles and raceState.raceFiles.persistent and raceState.raceFiles.saveFilename or nil
  raceState.lastLapCount = lapCount

  queueController(string.format(
    "if c.finishRaceLap then c.finishRaceLap(%s, %s, %s, %s) end",
    asLuaString(saveFilename),
    asLuaNumber(lapTime),
    tostring(isBest == true),
    tostring(continueRace)
  ))

  lifecycleCoordinator.finishModernRaceLap(continueRace)
end

-- Point-to-point races do not always emit a last-in-lap path node. Exporting
-- this hook also fixes the 1.6 bug where onRaceComplete was declared local and
-- therefore never called by the extension system.
function M.onRaceComplete(tbl)
  if raceState.raceStartPending and not raceState.raceActive then startPendingRace() end
  if not raceState.raceActive then return end

  local raceTime = tonumber(tbl and tbl.time)
  if raceTime and raceState.lastLapCount == 0 then
    local isBest = not raceState.pbTime or raceTime < raceState.pbTime
    if isBest then raceState.pbTime = raceTime end
    local saveFilename = raceState.raceFiles and raceState.raceFiles.persistent and raceState.raceFiles.saveFilename or nil
    queueController(string.format(
      "if c.finishRaceLap then c.finishRaceLap(%s, %s, %s, false) end",
      asLuaString(saveFilename),
      asLuaNumber(raceTime),
      tostring(isBest)
    ))
  else
    queueController("if c.endRace then c.endRace() end")
  end

  lifecycleCoordinator.completeRace()
end

function M.onRaceStopped()
  if raceState.raceActive or raceState.raceStartPending then
    queueController("if c.endRace then c.endRace() end")
  end
  lifecycleCoordinator.stopRace()
  if type(timeTrialState.missionStartFallback.profile) == "table"
      and timeTrialState.missionStartFallback.profile.source == "quickraceScenario" then
    lifecycleCoordinator.clearFallback()
  end
end

function M.onClientEndMission()
  runtimeContext:markReset("client mission ended")
  if raceState.raceActive or raceState.raceStartPending then
    queueController("if c.endRace then c.endRace() end")
  end
  cameraBackend.restore(nil)
  worldRenderer.cleanup()
  shellRenderer.reset()
  lifecycleCoordinator.clearRuntime()
end

local function cleanupRuntime(removeUi, unloadVehicleRuntime, reason)
  runtimeContext:markReset(reason or "GE runtime cleanup")
  if raceState.raceActive or raceState.raceStartPending then
    queueController("if c.endRace then c.endRace() end")
  end
  lifecycleCoordinator.clearRuntime()
  cameraBackend.restore(nil)
  worldRenderer.cleanup()
  shellRenderer.reset()

  if unloadVehicleRuntime then
    local targetVehicle = runtimeContext.runtime.vehicle
    if not targetVehicle and type(getPlayerVehicle) == "function" then
      targetVehicle = getPlayerVehicle(0)
    end
    if targetVehicle and targetVehicle.queueLuaCommand then
      targetVehicle:queueLuaCommand(
        'local ghostRacerController=controller and controller.getController '
          .. 'and controller.getController("ghostRacer"); '
          .. 'if ghostRacerController and ghostRacerController.invalidateRuntimeContext then '
          .. 'pcall(ghostRacerController.invalidateRuntimeContext,"GE runtime cleanup") end; '
          .. 'if extensions and extensions.unload then '
          -- Deliberately exclusive. The auto extension is registered under one
          -- name but reachable under both, so unloading it and then trying the
          -- other name made BeamNG log `extension unavailable: ghostRacerStart`
          -- at error level on every teardown. pcall does not suppress that,
          -- because the engine logs it before returning.
          .. 'if extensions.auto_ghostRacerStart then '
          .. 'pcall(extensions.unload,"auto_ghostRacerStart") '
          .. 'elseif extensions.ghostRacerStart then '
          .. 'pcall(extensions.unload,"ghostRacerStart") end end; '
          .. 'if controller and controller.unloadControllerExternal then '
          .. 'pcall(controller.unloadControllerExternal,"ghostRacer") end'
      )
    end
    runtimeContext:clearRuntime({"vehicle", "vehicleId"})
  end

  if removeUi and guihooks and guihooks.trigger then
    guihooks.trigger("GhostRacerModUnloaded")
  end
end

function M.onExtensionUnloaded()
  if not uiLifecycleState.modCleanupComplete then
    cleanupRuntime(uiLifecycleState.modDeactivating, uiLifecycleState.modDeactivating, "extension unloaded")
  end
  runtimeContext:invalidate("extension unloaded")
end

function M.onExtensionLoaded()
  runtimeContext:activate("extension loaded")
  uiLifecycleState.modDeactivating = false
  uiLifecycleState.modCleanupComplete = false
  -- Ctrl+L can reload this extension after Quick Race has already emitted its
  -- discovery hooks. Poll the live Scenario briefly so the official tt start
  -- is reconstructed without requiring a full game or race restart.
  lifecycleCoordinator.armFallback(nil, 0.05)
  M.trace("extension.lifecycle", "loaded")
end

-- BeamNG owns the outer HUD container. Closing or rebuilding the directive
-- should only stop Ghost Racer's runtime; the UI layout service remains free
-- to destroy/recreate its own container during F5, layout changes, and mod
-- activation changes.
function M.onUiClosed()
  if uiLifecycleState.modCleanupComplete or uiLifecycleState.modDeactivating then return true end
  cleanupRuntime(false, true, "UI closed")
  return true
end

local function retireManualExtensionRegistration()
  if type(setExtensionUnloadMode) ~= "function" then return false end
  local ok = pcall(setExtensionUnloadMode, M, "auto")
  if not ok then ok = pcall(setExtensionUnloadMode, "ghostlapping", "auto") end
  return ok
end

local function unloadOwnedExtension()
  if type(extensions) ~= "table" or type(extensions.unload) ~= "function" then
    return false
  end
  local ok, result = pcall(extensions.unload, M)
  if not ok or result == false then
    ok, result = pcall(extensions.unload, "ghostlapping")
  end
  if not ok and type(log) == "function" then
    log("E", "ghostlapping.lifecycle",
      "Could not unload ghostlapping: " .. tostring(result))
  end
  return ok and result ~= false
end

local function shutdownOwnedRuntime(reason)
  if uiLifecycleState.modCleanupComplete or uiLifecycleState.modDeactivating then return true end
  uiLifecycleState.modDeactivating = true
  local removed = M.removeSavedUiLayoutEntries()
  if type(log) == "function" then
    log("I", "ghostlapping.lifecycle", string.format(
      "Ghost Racer owner removed (%s); removed %d saved UI layout entries",
      tostring(reason or "unknown"), removed
    ))
  end
  cleanupRuntime(true, true, reason or "owner shutdown")
  runtimeContext:invalidate(reason or "owner shutdown")
  uiLifecycleState.modCleanupComplete = true
  -- Manual extensions survive ordinary level transitions and Ctrl+L. Remove
  -- this registration before unloading, otherwise a later Lua reload can
  -- resurrect an extension whose owning mod is disabled or gone.
  retireManualExtensionRegistration()
  unloadOwnedExtension()
  return true
end

function M.onModDeactivated(mod)
  if not isGhostRacerMod(mod) then return end
  return shutdownOwnedRuntime("onModDeactivated")
end

-- File-manager deletion of an unpacked mod may bypass onModDeactivated. If a
-- filesystem event explicitly touches our files and both defining files have
-- disappeared from the mounted VFS, apply the same cleanup while this loaded
-- extension still has a chance to run.
function M.onFilesChanged(files)
  if uiLifecycleState.modCleanupComplete or type(files) ~= "table"
      or not FS or type(FS.fileExists) ~= "function" then return end
  local ownerFilesTouched = false
  for _, entry in pairs(files) do
    local filename = type(entry) == "table" and entry.filename or entry
    filename = tostring(filename or ""):lower():gsub("\\", "/")
    if filename:find("ui/modules/apps/ghostracerapp/", 1, true)
        or filename:find("lua/ge/extensions/ghostlapping.lua", 1, true)
        or filename:find("ghost-racer-enhanced", 1, true)
        or filename:find("bng_ghost", 1, true) then
      ownerFilesTouched = true
      break
    end
  end
  if not ownerFilesTouched then return end

  local function mounted(filename)
    local ok, exists = pcall(FS.fileExists, FS, filename)
    if ok and exists == true then return true end
    ok, exists = pcall(FS.fileExists, FS, filename:gsub("^/", ""))
    return ok and exists == true
  end
  if not mounted("/ui/modules/apps/ghostRacerApp/app.json")
      and not mounted("/lua/ge/extensions/ghostlapping.lua") then
    shutdownOwnedRuntime("owner files removed")
  end
end

function M.getCodeVersion()
  return CODE_VERSION
end

function M.getRuntimeContextSnapshot()
  return runtimeContext:snapshot()
end

function M.getRuntimeContextStateSnapshot(name)
  return runtimeContext:snapshotState(name)
end

return M
