-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Native BeamNGVehicle backend for replay Ghost bodies. The renderer owns
-- playback and interpolation; this module owns spawning, the collision/freeze
-- handshake, native vehicle placement, transparency and destruction.

local M = {}

local READY_UPDATE_LIMIT = 600
local SIMPLIFIED_MODEL = "simple_traffic"

-- BeamNG 0.39 groups its optimized traffic bodies under one vehicle model.
-- Config filenames retain the source model key (for example vivace_*), which
-- lets old recordings select a close visual match without knowing a .pc file.
local MODEL_ALIASES = {
  etk800 = {"etk800", "etk_800"},
  etkc = {"etkc", "etk_k"},
  etki = {"etki", "etk_i"},
  fullsize = {"fullsize", "grand_marshal"},
  midsize = {"midsize", "pessima_1996", "pessima_96"},
  pessima = {"pessima"},
  pickup = {"pickup", "d_series"},
  roamer = {"roamer"},
  sunburst = {"sunburst"},
  vivace = {"vivace"},
  van = {"van", "h_series"},
  wendover = {"wendover"}
}

function M.new(options)
  options = options or {}
  local trace = assert(options.trace, "trace is required")
  local opacity = assert(options.opacity, "ghost opacity is required")
  local backend = {}
  local byObjectId = {}
  local reportedTransformBackend = false
  -- Spawn/delete counters. A frame rate that decays over laps is either
  -- accumulated deformation or leaked vehicles, and these two numbers tell
  -- those apart from a log alone: leaks show spawns climbing without matching
  -- deletes and a live count above the body budget.
  local spawns = 0
  local deletes = 0
  local simplifiedConfigByModel = {}

  local function normaliseToken(value)
    value = tostring(value or ""):lower():gsub("[^%w]+", "_")
    return value:gsub("^_+", ""):gsub("_+$", "")
  end

  local function candidateScore(identity, sourceModel)
    identity = "_" .. normaliseToken(identity) .. "_"
    local aliases = MODEL_ALIASES[sourceModel] or {sourceModel}
    local matched = false
    for _, alias in ipairs(aliases) do
      alias = normaliseToken(alias)
      if alias ~= "" and identity:find("_" .. alias .. "_", 1, true) then
        matched = true
        break
      end
    end
    if not matched then return nil end

    local score = 100
    if identity:find("_parked_", 1, true) then
      score = score - 40
    else
      score = score + 20
    end
    if identity:find("_base_", 1, true) then score = score + 8 end
    if identity:find("_standard_", 1, true) then score = score + 6 end
    if identity:find("_taxi_", 1, true)
        or identity:find("_police_", 1, true)
        or identity:find("_service_", 1, true) then
      score = score - 10
    end
    return score
  end

  local function simplifiedCandidates()
    local candidates = {}
    local seen = {}
    local function add(reference, identity, source)
      reference = tostring(reference or "")
      if reference == "" or seen[reference] then return end
      seen[reference] = true
      candidates[#candidates + 1] = {
        reference = reference,
        identity = tostring(identity or reference),
        source = source
      }
    end

    if core_vehicles and type(core_vehicles.getConfigList) == "function" then
      local ok, result = pcall(core_vehicles.getConfigList, true)
      local configs = ok and type(result) == "table" and result.configs or nil
      if type(configs) == "table" then
        for tableKey, config in pairs(configs) do
          if type(config) == "table" and config.model_key == SIMPLIFIED_MODEL then
            local key = config.key or tableKey
            local identity = table.concat({
              tostring(key or ""),
              tostring(config.Name or config.name or ""),
              tostring(config.Configuration or "")
            }, "_")
            add(key, identity, "catalog")
          end
        end
      end
    end

    if rawget(_G, "FS") and type(FS.findFiles) == "function" then
      local ok, files = pcall(function()
        return FS:findFiles("/vehicles/simple_traffic/", "*.pc", -1, true, false)
      end)
      if ok and type(files) == "table" then
        for _, path in ipairs(files) do
          add(tostring(path):gsub("^/", ""), path, "filesystem")
        end
      end
    end
    return candidates
  end

  local function resolveSimplifiedConfig(model)
    model = normaliseToken(model)
    local cached = simplifiedConfigByModel[model]
    if cached ~= nil then return cached or nil end

    local best, bestScore
    for _, candidate in ipairs(simplifiedCandidates()) do
      local score = candidateScore(candidate.identity, model)
      if score and (not bestScore or score > bestScore) then
        best = candidate
        bestScore = score
      end
    end
    simplifiedConfigByModel[model] = best or false
    return best
  end

  function backend.compatibilityKey(descriptor)
    local sourceModel = tostring(descriptor and descriptor.model or "")
    if sourceModel == "" or sourceModel == "unknown_vehicle" then
      return nil, "unknownVehicle"
    end
    local simplified = resolveSimplifiedConfig(sourceModel)
    if not simplified then return nil, "simplifiedVehicleUnavailable" end
    return SIMPLIFIED_MODEL .. "|" .. tostring(simplified.reference), nil, simplified
  end

  function backend.canReuse(proxy, descriptor)
    local key = backend.compatibilityKey(descriptor)
    return proxy ~= nil and key ~= nil
      and key == SIMPLIFIED_MODEL .. "|" .. tostring(proxy.config)
  end

  function backend.isReady(proxy)
    return proxy ~= nil and proxy.ready == true and proxy.setupError == nil
  end

  function backend.readiness(proxy)
    if not proxy or not proxy.vehicle then return false, "vehicleMissing" end
    if proxy.setupError then return false, proxy.setupError end
    if proxy.ready then return true end
    proxy.pendingUpdates = (proxy.pendingUpdates or 0) + 1
    if proxy.pendingUpdates > READY_UPDATE_LIMIT then
      return false, "vehicleReadyTimeout"
    end
    return false
  end

  local function objectId(vehicle)
    if not vehicle or type(vehicle.getID) ~= "function" then return nil end
    local ok, id = pcall(vehicle.getID, vehicle)
    if not ok then return nil end
    return tonumber(id)
  end

  local function rotationForPose(pose)
    local rotationFactory = rawget(_G, "quatFromDir")
    local vectorFactory = rawget(_G, "vec3")
    if type(rotationFactory) ~= "function" or type(vectorFactory) ~= "function" then
      return nil, "noMathApi"
    end
    local ok, rotation = pcall(
      rotationFactory,
      vectorFactory(pose[4], pose[5], pose[6]),
      vectorFactory(pose[7], pose[8], pose[9])
    )
    if not ok or not rotation then return nil, "rotationFailed" end
    return rotation
  end

  local function hideVehicle(vehicle)
    if not vehicle or type(vehicle.setMeshAlpha) ~= "function" then
      return false
    end
    return pcall(vehicle.setMeshAlpha, vehicle, 0, "")
  end

  -- A parked vehicle is invisible, so the fact that setActive(0) also stops it
  -- rendering costs nothing here while it removes the pooled vehicles from the
  -- physics and audio budget. Prewarm keeps up to three of them alive for the
  -- whole session, which is standing cost the player pays even while idle.
  -- Builds without the accessor simply keep a frozen, hidden vehicle.
  local function setVehicleActive(vehicle, active)
    if not vehicle or type(vehicle.setActive) ~= "function" then return false end
    return pcall(vehicle.setActive, vehicle, active and 1 or 0)
  end

  -- Try the GE-side vehicle object as well as the Vehicle VM: the accessor may
  -- live on either, and a Ghost has no reason to collide with anything.
  local reportedCollisionApi = false
  local function disableDynamicCollision(vehicle)
    if not vehicle then return "noVehicle" end
    if type(vehicle.setDynamicCollisionEnabled) ~= "function" then return "geMissing" end
    return pcall(vehicle.setDynamicCollisionEnabled, vehicle, false)
        and "geDisabled" or "geCallFailed"
  end

  -- Only a vehicle that has already acknowledged Ghost collision and freeze may
  -- be deactivated: the handshake runs inside its own Lua VM, and an inactive
  -- vehicle would never get to finish it.
  function backend.park(proxy)
    if not proxy or not proxy.vehicle then return false end
    local hidden = hideVehicle(proxy.vehicle)
    if hidden then proxy.visible = false end
    if backend.isReady(proxy) and not proxy.parked then
      proxy.parked = setVehicleActive(proxy.vehicle, false)
    end
    return hidden
  end

  function backend.prepareReuse(proxy, descriptor)
    if not backend.canReuse(proxy, descriptor) then return false end
    if proxy.parked then
      if not setVehicleActive(proxy.vehicle, true) then return false end
      proxy.parked = false
    end
    hideVehicle(proxy.vehicle)
    proxy.model = tostring(descriptor.model or proxy.model)
    proxy.visible = false
    return true
  end

  local function deleteVehicle(vehicle)
    if not vehicle then return true end
    hideVehicle(vehicle)
    if type(vehicle.delete) ~= "function" then return false end
    return pcall(vehicle.delete, vehicle)
  end

  local function queuePhysicsSetup(vehicle, id)
    if type(vehicle.queueLuaCommand) ~= "function" then return false end
    -- This runs inside the spawned vehicle's own VM. Keep it invisible until
    -- both operations have completed: setGhostEnabled disables interaction
    -- with other vehicles, and setFreeze stops the powertrain driving it.
    --
    -- setFreeze is NOT a physics freeze. BeamNG's own Vehicle Controller
    -- documentation describes it as "Enables the transmission lock", so the
    -- soft body keeps being simulated in full. What actually holds a Ghost on
    -- its replay line is the per-frame setPositionRotation below, not this.
    -- The only call that does stop the simulation, setActive(0), stops
    -- rendering with it, so a visible Ghost always costs a whole vehicle.
    -- That is why the body budget is one -- see MAX_SHELL_BODIES.
    -- Experiment: a Ghost never needs to collide with anything -- it is a
    -- visual reference held on its line by setPositionRotation + setFreeze.
    -- The hold/pin/drive probe showed the per-frame teleport decays because it
    -- keeps the soft body awake re-running its simulation and terrain contact;
    -- turning collision off removes the contact half, which may let the body be
    -- teleported every frame (smooth) without the decay. Guarded and logged so
    -- a build without the accessor simply keeps colliding.
    local command = string.format(
      'local ghostOk=pcall(function() obj:setGhostEnabled(true) end); '
        .. 'local freezeOk=pcall(function() controller.setFreeze(1) end); '
        .. 'local collVm=(type(obj.setDynamicCollisionEnabled)=="function"); '
        .. 'local collOk=collVm and pcall(function() '
        .. 'obj:setDynamicCollisionEnabled(false) end) or false; '
        .. 'if log then log("I","GhostRacerDiag.COLLISION",'
        .. '"vm present=" .. tostring(collVm) .. " disabled=" .. tostring(collOk)) end; '
        .. 'if obj.queueGameEngineLua then obj:queueGameEngineLua('
        .. '"if extensions and extensions.ghostlapping and '
        .. 'extensions.ghostlapping.onGhostVehicleReady then '
        .. 'extensions.ghostlapping.onGhostVehicleReady(%d," '
        .. '.. tostring(ghostOk) .. "," .. tostring(freezeOk) .. ") end") end',
      id
    )
    return pcall(vehicle.queueLuaCommand, vehicle, command)
  end

  function backend.create(objectName, descriptor, pose)
    local sourceModel = tostring(descriptor and descriptor.model or "")
    if sourceModel == "" or sourceModel == "unknown_vehicle" then
      return nil, "unknownVehicle"
    end
    if not core_vehicles or type(core_vehicles.spawnNewVehicle) ~= "function" then
      return nil, "noVehicleSpawner"
    end
    local _, compatibilityError, simplified = backend.compatibilityKey(descriptor)
    if not simplified then return nil, compatibilityError end

    local rotation, rotationError = rotationForPose(pose)
    if not rotation then return nil, rotationError end
    local vectorFactory = rawget(_G, "vec3")
    local spawnOptions = {
      autoEnterVehicle = false,
      playerUsable = false,
      vehicleName = objectName,
      cling = false,
      -- Loading a vehicle is synchronous and its Vehicle VM needs a short
      -- handshake before Ghost collision/freeze is active. Spawn it well above
      -- the course while invisible so a prewarm can never touch the player or
      -- world objects during that window.
      pos = vectorFactory(pose[1], pose[2], pose[3] + 1000),
      rot = rotation
    }
    spawnOptions.config = simplified.reference

    local spawned, vehicle = pcall(
      core_vehicles.spawnNewVehicle, SIMPLIFIED_MODEL, spawnOptions
    )
    if not spawned or not vehicle then return nil, "vehicleSpawnFailed" end
    local id = objectId(vehicle)
    if not id then
      deleteVehicle(vehicle)
      return nil, "vehicleIdentityFailed"
    end
    if type(vehicle.setMeshAlpha) ~= "function"
        or type(vehicle.setPositionRotation) ~= "function" then
      deleteVehicle(vehicle)
      return nil, "vehicleVisualApiMissing"
    end
    if not hideVehicle(vehicle) then
      deleteVehicle(vehicle)
      return nil, "vehicleAlphaFailed"
    end

    -- These are additional safeguards around the spawn options. They are not
    -- essential engine APIs, so a build that rejects a dynamic property still
    -- proceeds with the explicit autoEnterVehicle/playerUsable options above.
    pcall(function() vehicle.playerUsable = false end)
    pcall(function() vehicle.ignoreTraffic = true end)
    pcall(function() vehicle.uiState = 0 end)
    local collisionResult = disableDynamicCollision(vehicle)
    if not reportedCollisionApi then
      reportedCollisionApi = true
      trace("shell.collision", "ge=%s", tostring(collisionResult))
    end
    if type(vehicle.setField) == "function" then
      pcall(vehicle.setField, vehicle, "canSave", 0, "0")
      pcall(vehicle.setField, vehicle, "canSaveDynamicFields", 0, "0")
    end

    local proxy = {
      vehicle = vehicle,
      objectId = id,
      objectName = objectName,
      model = sourceModel,
      spawnModel = SIMPLIFIED_MODEL,
      config = simplified.reference,
      ready = false,
      visible = false,
      pendingUpdates = 0,
      setupError = nil
    }
    byObjectId[id] = proxy
    spawns = spawns + 1
    if not queuePhysicsSetup(vehicle, id) then
      byObjectId[id] = nil
      deleteVehicle(vehicle)
      return nil, "vehicleSetupQueueFailed"
    end
    trace(
      "shell.vehicle.spawn",
      "id=%s object=%d sourceModel=%s spawnModel=%s config=%s configSource=%s "
        .. "alpha=0 awaitingGhostFreeze=true",
      tostring(descriptor and descriptor.id or "unknown"), id, sourceModel,
      SIMPLIFIED_MODEL, tostring(spawnOptions.config), simplified.source
    )
    return proxy
  end

  -- A Ghost is dragged over the terrain at replay speed with its wheels
  -- touching, so every frame looks like a maximum-slip skid to the tyre model.
  -- Skid decals accumulate in the world and are known to cost enormous frame
  -- rate over time, which fits a decay that continues while the player's own
  -- car is parked and that a body reset does not undo.
  --
  -- Rather than guess at an API name, ask the vehicle's own VM which related
  -- entry points exist and log them. The next log names the real one instead of
  -- another assumption.
  local probedSurfaceApi = false
  local function probeSurfaceApi(vehicle)
    if probedSurfaceApi or type(vehicle.queueLuaCommand) ~= "function" then return end
    probedSurfaceApi = true
    pcall(
      vehicle.queueLuaCommand,
      vehicle,
      'local found = {}; '
        .. 'for _, name in ipairs({"setSkidmarksEnabled","setSkidmarks",'
        .. '"setParticlesEnabled","setTireMarks","setDecalsEnabled",'
        .. '"setPlanarSlipVector","setSurfaceSounds"}) do '
        .. 'if obj and type(obj[name]) ~= "nil" then '
        .. 'found[#found+1] = name .. ":" .. type(obj[name]) end end; '
        .. 'for _, name in ipairs({"particles","wheels","beamstate"}) do '
        .. 'local mod = rawget(_G, name); '
        .. 'if type(mod) == "table" then '
        .. 'for _, fn in ipairs({"setEnabled","disable","setSkidmarksEnabled"}) do '
        .. 'if type(mod[fn]) ~= "nil" then '
        .. 'found[#found+1] = name .. "." .. fn end end end end; '
        .. 'if log then log("I","GhostRacerDiag.SURFACE",'
        .. '"candidates=[" .. table.concat(found, ", ") .. "]") end'
    )
  end

  -- A full collect inside the Ghost VM does not reclaim the growth: the heap
  -- after collecting still climbed 5.5 -> 10.5 -> 15.4 -> 15.5 MB over forty
  -- seconds. That is retention, not collector lag, and this mod runs no
  -- persistent code in that VM -- so something in BeamNG's own vehicle Lua
  -- holds on to memory when a vehicle is teleported every frame.
  --
  -- Which table is growing is answerable rather than guessable: walk the VM's
  -- own globals and report the largest by entry count. Repeated every interval,
  -- whichever one climbs is the one retaining.
  local function reportGhostTables(vehicle)
    if not vehicle or type(vehicle.queueLuaCommand) ~= "function" then return end
    pcall(
      vehicle.queueLuaCommand,
      vehicle,
      'local sizes = {}; '
        .. 'for key, value in pairs(_G) do '
        .. 'if type(value) == "table" then '
        .. 'local ok, count = pcall(function() '
        .. 'local n = 0; for _ in pairs(value) do n = n + 1 end; return n end); '
        .. 'if ok and count and count > 24 then '
        .. 'sizes[#sizes+1] = {key, count} end end end; '
        .. 'table.sort(sizes, function(a, b) return a[2] > b[2] end); '
        .. 'local parts = {}; '
        .. 'for index = 1, math.min(#sizes, 10) do '
        .. 'parts[#parts+1] = sizes[index][1] .. "=" .. sizes[index][2] end; '
        .. 'if log then log("I","GhostRacerDiag.GHOSTTABLES", '
        .. 'table.concat(parts, " ")) end'
    )
  end
  backend.reportGhostTables = function(proxy)
    if proxy then reportGhostTables(proxy.vehicle) end
  end

  function backend.markReady(id, ghostEnabled, frozen)
    id = tonumber(id)
    local proxy = id and byObjectId[id] or nil
    if not proxy then return false end
    if ghostEnabled ~= true then
      proxy.setupError = "vehicleGhostModeFailed"
    elseif frozen ~= true then
      proxy.setupError = "vehicleFreezeFailed"
    elseif not hideVehicle(proxy.vehicle) then
      proxy.setupError = "vehicleAlphaFailed"
    else
      proxy.ready = true
      probeSurfaceApi(proxy.vehicle)
    end
    trace(
      "shell.vehicle.ready",
      "object=%s ghostEnabled=%s frozen=%s ready=%s",
      tostring(id), tostring(ghostEnabled == true), tostring(frozen == true),
      tostring(proxy.ready)
    )
    return proxy.ready == true
  end

  function backend.applyPose(proxy, pose)
    if not proxy or not proxy.vehicle then return false, "vehicleMissing" end
    if proxy.setupError then return false, proxy.setupError end
    if not proxy.ready then
      proxy.pendingUpdates = proxy.pendingUpdates + 1
      if proxy.pendingUpdates > READY_UPDATE_LIMIT then
        return false, "vehicleReadyTimeout"
      end
      return true, nil, false
    end

    local rotation, rotationError = rotationForPose(pose)
    if not rotation then return false, rotationError end
    local applied = pcall(
      proxy.vehicle.setPositionRotation,
      proxy.vehicle,
      pose[1], pose[2], pose[3],
      rotation.x, rotation.y, rotation.z, rotation.w
    )
    if not applied then return false, "vehiclePoseFailed" end
    if not proxy.visible then
      if not pcall(proxy.vehicle.setMeshAlpha, proxy.vehicle, opacity, "") then
        return false, "vehicleAlphaFailed"
      end
      proxy.visible = true
      trace(
        "shell.vehicle.visible",
        "object=%d sourceModel=%s spawnModel=%s alpha=%.3f",
        proxy.objectId, proxy.model, proxy.spawnModel, opacity
      )
    end
    if not reportedTransformBackend then
      reportedTransformBackend = true
      trace("shell.backend", "class=BeamNGVehicle transform=setPositionRotation")
    end
    return true, nil, true
  end

  -- Whether the body really is wrecking itself is the open question, so log
  -- whatever this build exposes rather than assuming an accessor exists.
  function backend.damageReading(proxy)
    if not proxy or not proxy.vehicle then return "none" end
    for _, name in ipairs({"getDamage", "damage", "getBeamBreakCount"}) do
      local field = proxy.vehicle[name]
      if type(field) == "function" then
        local ok, value = pcall(field, proxy.vehicle)
        if ok and value ~= nil then return name .. "=" .. tostring(value) end
      elseif field ~= nil then
        return name .. "=" .. tostring(field)
      end
    end
    return "unavailable"
  end

  function backend.hide(proxy)
    if not proxy or not proxy.vehicle then return false end
    local hidden = hideVehicle(proxy.vehicle)
    if hidden then proxy.visible = false end
    return hidden
  end

  function backend.destroy(proxy)
    if not proxy then return true end
    if proxy.objectId then byObjectId[proxy.objectId] = nil end
    local vehicle = proxy.vehicle
    proxy.vehicle = nil
    proxy.visible = false
    deletes = deletes + 1
    return deleteVehicle(vehicle)
  end

  function backend.describe(proxy)
    return string.format(
      "object=%s model=%s",
      tostring(proxy and proxy.objectId or "none"),
      tostring(proxy and proxy.spawnModel or "unknown")
    )
  end

  function backend.snapshot()
    local pending = 0
    for _, proxy in pairs(byObjectId) do
      if not proxy.ready then pending = pending + 1 end
    end
    return {
      kind = "simplifiedNativeVehicle",
      spawns = spawns,
      deletes = deletes,
      liveVehicles = (function()
        local live = 0
        for _, proxy in pairs(byObjectId) do
          if proxy.vehicle then live = live + 1 end
        end
        return live
      end)(),
      parkedInactive = (function()
        local parked = 0
        for _, proxy in pairs(byObjectId) do
          if proxy.parked then parked = parked + 1 end
        end
        return parked
      end)(),
      objectClass = "BeamNGVehicle",
      spawnModel = SIMPLIFIED_MODEL,
      transformMode = "setPositionRotation",
      pendingVehicles = pending
    }
  end

  return backend
end

return M
