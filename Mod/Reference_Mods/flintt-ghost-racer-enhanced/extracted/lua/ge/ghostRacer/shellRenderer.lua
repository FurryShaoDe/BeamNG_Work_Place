-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- GE-side semi-transparent native vehicles for replay Ghosts. The backend
-- spawns non-player BeamNGVehicles, switches them to vehicle Ghost collision,
-- freezes their soft-body simulation and removes them on every teardown path.
--
-- Every engine call is guarded. When the running BeamNG build cannot provide a
-- shell the renderer reports the reason once and the Vehicle controller falls
-- back to the wireframe, so an unsupported build degrades instead of failing.

local M = {}

local SHELL_OPACITY = 0.35
-- Large enough that only a real discontinuity snaps the clock, small enough
-- that a genuine desync cannot persist.
local CLOCK_RESYNC_SECONDS = 0.3
local PREWARM_INTERVAL_SECONDS = 0.75
-- The hold/pin/drive probe on 2.15.20 named the decay: a body left untouched
-- holds a flat frame rate, but calling setPositionRotation every frame -- even
-- to an unchanging pose -- makes it fall away, because the teleport keeps the
-- soft body from ever sleeping and re-runs its simulation and terrain contact.
-- The one lever that does not need an engine API BeamNG has not exposed is to
-- teleport less often: reposition the body on a fixed real-time cadence rather
-- than once per render frame. A moving Ghost is a translucent reference, so a
-- ~30 Hz update reads as smooth while roughly halving the teleport rate.
local TELEPORT_INTERVAL_SECONDS = 1 / 30

function M.new(options)
  options = options or {}
  local trace = assert(options.trace, "trace is required")
  local maximumGhosts = assert(options.maximumGhosts, "shell limit is required")
  local onUnavailable = assert(options.onUnavailable, "fallback reporter is required")
  local onAvailable = assert(options.onAvailable, "success reporter is required")
  local backendOptions = { trace = trace, opacity = SHELL_OPACITY }
  local nativeBackend = (options.proxyBackendFactory
      or require("ge/ghostRacer/shellVehicleBackend").new)(backendOptions)
  -- TSStatic is the default: it has no soft body, so it never decays and moves
  -- every frame for free. The native BeamNGVehicle backend stays available as a
  -- fallback (and for A/B measurement) and can be selected from the console.
  local tsstaticBackend = (options.tsstaticBackendFactory
      or require("ge/ghostRacer/shellTSStaticBackend").new)(backendOptions)
  local backendsByKind = { native = nativeBackend, tsstatic = tsstaticBackend }
  local activeBackendKind = (options.defaultBackendKind == "native")
      and "native" or "tsstatic"
  local proxyBackend = backendsByKind[activeBackendKind]

  local renderer = {}
  local proxies = {}
  local parkedProxies = {}
  local order = {}
  local cursors = {}
  local sampleCache = {}
  local clock = nil
  local clockPlaying = false
  local clockDuration = 0
  local clockLooping = false
  local descriptorsById = {}
  local unavailableReason = nil
  local reportedUnavailable = false
  local reportedAvailable = false
  local lastVisibleSignature = nil
  local staleProxiesRemoved = 0
  -- The retention measured in the Ghost VM is per vehicle and grows with how
  -- long that vehicle has been alive, so it can be bounded by construction
  -- without knowing what BeamNG is holding on to: destroy the body and build a
  -- fresh one before the heap has had time to matter. A warm respawn costs
  -- roughly half a second and the Ghost falls back to its wireframe while the
  -- replacement completes its handshake, which is a far better trade than
  -- decaying from 50 fps to 18 over the same period.
  -- Age belongs to the vehicle, not to the Ghost showing it. A parked vehicle
  -- keeps whatever its VM has already retained, and setActive(0) pauses its
  -- running cost without clearing that, so reusing it under another Ghost id
  -- would silently restart the clock on an already-bloated VM.
  --
  -- The 2.15.21 teleport throttle made the decay shallow (a single body held
  -- ~42-48 fps across a whole cycle instead of collapsing to 18), so the body
  -- no longer needs replacing as often. Each recycle still costs a synchronous
  -- ~0.5 s vehicle load that cannot be hidden -- warming behind the visible body
  -- removes the on-screen gap, not the CPU hitch -- so a longer interval is a
  -- direct halving of how often that hitch is paid.
  local RECYCLE_SECONDS = 90
  local recycles = 0
  -- Only a full teardown clears the per-vehicle retention -- an in-place reset
  -- was tried in 2.15.9 and did not arrest the decay -- but a teardown reloads
  -- the JBeam/config synchronously and leaves a gap with no body on screen.
  -- Warm the successor this many seconds before the deadline, behind the still
  -- visible body, so its load never lands on a visible frame and the swap is a
  -- pose call rather than a spawn. The cost is a second live vehicle for the
  -- lead window only.
  local RECYCLE_LEAD_SECONDS = 4
  local pendingReplacements = {}

  -- Experiment toggle: force the teleport back to every frame (smooth) so the
  -- collision-disabled body can be compared against the throttled default in
  -- the same session. Off by default -- 2.15.22 behaviour is unchanged until a
  -- player asks for it from the console.
  local teleportPerFrame = false
  function renderer.setTeleportPerFrame(enabled)
    teleportPerFrame = enabled == true
    trace("shell.teleport", "perFrame=%s", tostring(teleportPerFrame))
    return teleportPerFrame
  end

  -- Switch the active proxy backend at runtime. The pool is torn down through
  -- the outgoing backend first so its own objects are released by the code that
  -- created them; the player restarts playback to repopulate through the new
  -- one. Native stays the default and its tests never build the other backend.
  function renderer.setBackendKind(kind)
    kind = (kind == "native") and "native" or "tsstatic"
    if kind == activeBackendKind then return activeBackendKind end
    renderer.releasePool()
    proxyBackend = backendsByKind[kind]
    activeBackendKind = kind
    trace("shell.backendKind", "kind=%s", kind)
    return activeBackendKind
  end

  -- Whether the Ghost VM's retention is caused by the per-frame teleport, by
  -- the teleport call itself, or merely by a live vehicle existing has been
  -- inferred rather than measured, and "GC cost is what costs the frames" is
  -- inference too. Three phases separate all of it in a single run:
  --
  --   hold   a visible body, setPositionRotation never called
  --   pin    setPositionRotation called every frame with one unchanging pose
  --   drive  the normal moving replay
  --
  -- Heap slope and frame rate are already reported every ten seconds, so the
  -- phase boundaries are all that is missing. Off unless explicitly switched
  -- on: it deliberately shows the Ghost in the wrong place for the first two
  -- phases, so it is a diagnostic, never a default.
  local abPhases = {
    {name = "hold", seconds = 30},
    {name = "pin", seconds = 30},
    {name = "drive", seconds = 0}
  }
  local abEnabled = false
  local abIndex = 1
  local abElapsed = 0
  local abPinnedPose = nil

  function renderer.setPhaseProbe(enabled)
    abEnabled = enabled == true
    abIndex = 1
    abElapsed = 0
    abPinnedPose = nil
    trace("shell.ab", "probe=%s", tostring(abEnabled))
    return abEnabled
  end

  local function abPhaseName()
    if not abEnabled then return "off" end
    return abPhases[abIndex] and abPhases[abIndex].name or "drive"
  end

  -- One shared pinned pose would stack a Top 2/3 set in a single spot, which
  -- changes the overlap, the physics and the render load all at once. The
  -- probe measures one body or it measures nothing.
  local function abSkipsGhost(index)
    return abEnabled and index > 1
  end

  local function abAdvance(step)
    if not abEnabled then return end
    local phase = abPhases[abIndex]
    if not phase or phase.seconds <= 0 then return end
    abElapsed = abElapsed + step
    if abElapsed >= phase.seconds then
      abElapsed = 0
      abIndex = math.min(abIndex + 1, #abPhases)
      abPinnedPose = nil
      trace("shell.ab", "phase=%s", abPhaseName())
    end
  end
  -- Counters only reachable through renderer.snapshot() are useless for
  -- diagnosing a frame rate that decays during play: nothing queries the
  -- snapshot while driving, so they never reach the log. This emits them on a
  -- slow cadence while a body is on screen instead.
  local HEALTH_INTERVAL_SECONDS = 10
  local healthCountdown = 0
  -- "The frame rate drops" is the one fact that has never been in a log, so it
  -- has had to be judged by eye against everything else. Sampling the real
  -- frame delta here puts the decay on the same timeline as the Ghost's own
  -- events, and shows whether it starts when a body appears or was already
  -- under way.
  local frameSamples = 0
  local frameSeconds = 0
  local worstFrame = 0
  -- The decay is flat for the first twenty seconds of playback and then falls
  -- away sharply. Over that window the one quantity that changes monotonically
  -- is how far the Ghost has driven from the parked player. Recording the
  -- distance says whether the collapse tracks it or something else.
  local lastPose = nil
  -- Following the Ghost keeps the distance small and the frame rate still
  -- falls, so distance is a control variable now, not a suspect. What is left
  -- is a cost that compounds with elapsed playback: something accumulates.
  -- Lua heap size in each VM says whether that something is ours, and if so
  -- which side it is on.
  local function heapKb()
    local ok, kb = pcall(collectgarbage, "count")
    return ok and tonumber(kb) or -1
  end
  -- The Ghost vehicle's own Lua heap grows by roughly a quarter of a megabyte
  -- per second while it is dragged along a replay -- 8.9 MB to 16.9 MB over
  -- thirty seconds in the measured run. Garbage collection cost scales with the
  -- live set, which is exactly the shape of the decay: flat at first, then
  -- compounding.
  --
  -- Nothing in this mod runs inside that VM, so either the growth is garbage
  -- the incremental collector is not keeping up with, or BeamNG's own vehicle
  -- Lua retains something when a vehicle is teleported every frame. A full
  -- collect there answers which: the heap after the collect either falls back
  -- or it does not, and if it falls back this is also the fix.
  local function reportGhostHeap(proxy)
    if not proxy or not proxy.vehicle then return end
    if type(proxy.vehicle.queueLuaCommand) ~= "function" then return end
    pcall(
      proxy.vehicle.queueLuaCommand,
      proxy.vehicle,
      'local ok, kb = pcall(collectgarbage, "count"); '
        .. 'if log then log("I","GhostRacerDiag.GHOSTVM", '
        .. '"heapKb=" .. tostring(ok and math.floor(kb) or -1)) end'
    )
  end
  local prewarmDescriptors = {}
  local prewarmCursor = 1
  local prewarmCooldown = 0
  local poolGenerationCleaned = false

  local function reportUnavailable(reason)
    unavailableReason = reason
    if reportedUnavailable then return end
    reportedUnavailable = true
    trace("shell.unavailable", "reason=%s", tostring(reason))
    onUnavailable(reason)
  end

  -- A pending successor is a hidden, never-shown body; if its Ghost leaves the
  -- world before the swap it is simply destroyed, not pooled.
  local function discardPending(id)
    local pending = pendingReplacements[id]
    if not pending then return end
    pendingReplacements[id] = nil
    proxyBackend.destroy(pending)
    trace("shell.recycle.discard", "id=%s", tostring(id))
  end

  local function discardAllPending()
    local ids = {}
    for id in pairs(pendingReplacements) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do discardPending(id) end
  end

  local function destroyProxy(id)
    discardPending(id)
    local proxy = proxies[id]
    if not proxy then return end
    proxies[id] = nil
    proxyBackend.destroy(proxy)
    trace("shell.removed", "id=%s", tostring(id))
  end

  local function destroyParkedProxy(index)
    local proxy = table.remove(parkedProxies, index)
    if not proxy then return end
    proxyBackend.destroy(proxy)
    trace("shell.removed", "pooled=true %s", proxyBackend.describe(proxy))
  end

  local function parkProxy(id)
    discardPending(id)
    local proxy = proxies[id]
    if not proxy then return false end
    proxies[id] = nil
    proxyBackend.park(proxy)
    parkedProxies[#parkedProxies + 1] = proxy
    while #parkedProxies > maximumGhosts do destroyParkedProxy(1) end
    trace("shell.pooled", "id=%s %s", tostring(id), proxyBackend.describe(proxy))
    return true
  end

  local function acquireParkedProxy(id, descriptor)
    local fallbackIndex
    for index = 1, #parkedProxies do
      local proxy = parkedProxies[index]
      if proxyBackend.canReuse(proxy, descriptor) then
        if proxyBackend.isReady(proxy) then
          fallbackIndex = index
          break
        end
        fallbackIndex = fallbackIndex or index
      end
    end
    if not fallbackIndex then return nil end
    local proxy = table.remove(parkedProxies, fallbackIndex)
    if not proxyBackend.prepareReuse(proxy, descriptor) then
      proxyBackend.destroy(proxy)
      return nil
    end
    trace("shell.reused", "id=%s %s", tostring(id), proxyBackend.describe(proxy))
    return proxy
  end

  local function proxyObjectName(id)
    return "GhostRacerShell_" .. tostring(id)
  end

  -- A successor must coexist with the visible body, so it takes the other of
  -- two per-Ghost slot names. They alternate every recycle: whichever slot the
  -- live body is not on is free for its replacement, and a stale-object sweep
  -- of that slot never touches the body still on screen.
  local function replacementSlotId(id, currentProxy)
    local base = tostring(id)
    local altSlot = base .. "__b"
    local currentName = currentProxy and currentProxy.objectName or nil
    if currentName == proxyObjectName(altSlot) then return base end
    return altSlot
  end

  -- Scene objects survive some GE Lua reload paths even though the renderer's
  -- Lua tables do not. Pool-slot names stay stable across recordings and Lua
  -- generations, so preparing the same slot removes any orphaned vehicle
  -- before creating its replacement.
  local function removeStaleProxies(id)
    if not scenetree or type(scenetree.findObject) ~= "function" then return true end
    local objectName = proxyObjectName(id)
    local removed = 0
    for _ = 1, 16 do
      local found, existing = pcall(function() return scenetree.findObject(objectName) end)
      if not found then return false end
      if not existing then break end
      if type(existing.delete) ~= "function"
          or not pcall(function() existing:delete() end) then
        return false
      end
      removed = removed + 1
    end
    if removed > 0 then
      staleProxiesRemoved = staleProxiesRemoved + removed
      trace("shell.stale", "id=%s removed=%d", tostring(id), removed)
    end
    local found, remaining = pcall(function() return scenetree.findObject(objectName) end)
    return found and not remaining
  end

  local function createProxy(id, descriptor, pose)
    if not removeStaleProxies(id) then return nil, "staleObjectCleanupFailed" end
    local proxy, createError = proxyBackend.create(proxyObjectName(id), descriptor, pose)
    if not proxy then return nil, createError or "objectCreateFailed" end
    trace("shell.created", "id=%s %s", tostring(id), proxyBackend.describe(proxy))
    return proxy
  end

  local function removeOwnedPoolSlot(slotId)
    local objectName = proxyObjectName(slotId)
    for index = #parkedProxies, 1, -1 do
      if parkedProxies[index].objectName == objectName then
        destroyParkedProxy(index)
      end
    end
  end

  function renderer.markBackendReady(objectId, ghostEnabled, frozen)
    return proxyBackend.markReady(objectId, ghostEnabled, frozen)
  end

  function renderer.setSet(descriptors)
    local keep = {}
    descriptorsById = {}
    order = {}
    -- A Vehicle controller reload clears its own record of the confirmation
    -- while this renderer instance survives. Without re-confirming, the
    -- controller would keep drawing the wireframe on top of every body for the
    -- rest of the session. The set changes rarely, so this is cheap.
    reportedAvailable = false
    lastVisibleSignature = nil
    for index = 1, math.min(#(descriptors or {}), maximumGhosts) do
      local descriptor = descriptors[index]
      local id = tostring(descriptor and descriptor.id or "")
      if id ~= "" then
        keep[id] = true
        descriptorsById[id] = descriptor
        order[#order + 1] = id
      end
    end
    local parkIds = {}
    for id, proxy in pairs(proxies) do
      if not keep[id] or not proxyBackend.canReuse(proxy, descriptorsById[id]) then
        parkIds[#parkIds + 1] = id
      end
    end
    for _, id in ipairs(parkIds) do parkProxy(id) end
    for _, id in ipairs(order) do
      if not proxies[id] then
        proxies[id] = acquireParkedProxy(id, descriptorsById[id])
        cursors[id] = nil
      end
    end
    if #order == 0 then clockPlaying = false end
    trace(
      "shell.set", "tracked=%d active=%d pooled=%d",
      #(descriptors or {}), #order, #parkedProxies
    )
  end

  function renderer.prewarm(descriptors)
    prewarmDescriptors = {}
    for index = 1, math.min(#(descriptors or {}), maximumGhosts) do
      prewarmDescriptors[index] = descriptors[index]
    end
    -- A switch from Top 3 to Best/Specified should not leave two hidden
    -- vehicle VMs consuming resources. Retain only the capacity this mode can
    -- actually use; missing compatibility is repaired during idle prewarm.
    while #parkedProxies > #prewarmDescriptors do destroyParkedProxy(1) end
    prewarmCursor = 1
    prewarmCooldown = math.min(prewarmCooldown, 0.1)
    trace("shell.prewarm.request", "vehicles=%d", #prewarmDescriptors)
    return true
  end

  -- Recordings are read straight from disk: a Ghost that is on screen already
  -- has its samples persisted, and marshalling thousands of them across the
  -- bridge every time the set changes would cost far more than a file read.
  local function loadSamples(file)
    file = tostring(file or "")
    if file == "" then return nil end
    local cached = sampleCache[file]
    if cached ~= nil then
      if cached == false then return nil end
      return cached
    end
    local data = jsonReadFile(file)
    local samples = type(data) == "table" and data.samples or nil
    if type(samples) ~= "table" or #samples < 2 then
      sampleCache[file] = false
      trace("shell.samples", "REJECTED file=%s", file)
      return nil
    end
    sampleCache[file] = samples
    trace("shell.samples", "loaded file=%s samples=%d", file, #samples)
    return samples
  end

  -- Mirrors the Vehicle-side pose interpolation. The two VMs cannot share a
  -- module, so replay format 2's sample layout is applied here as well.
  local function resolvePose(samples, cursor, elapsed)
    local count = #samples
    if count < 2 then return nil, 1 end
    cursor = math.max(1, math.min(cursor or 1, count - 1))
    if (samples[cursor][1] or 0) > elapsed then cursor = 1 end
    while cursor < count - 1 and (samples[cursor + 1][1] or 0) <= elapsed do
      cursor = cursor + 1
    end
    local first = samples[cursor]
    local second = samples[math.min(cursor + 1, count)]
    local span = math.max((second[1] or 0) - (first[1] or 0), 0.000001)
    local amount = math.max(0, math.min((elapsed - (first[1] or 0)) / span, 1))
    local inverse = 1 - amount

    local function blend(indexA)
      return first[indexA] * inverse + second[indexA] * amount
    end
    local function normalised(x, y, z, fallbackX, fallbackY, fallbackZ)
      local lengthSquared = x * x + y * y + z * z
      if lengthSquared < 0.000001 then return fallbackX, fallbackY, fallbackZ end
      local scale = 1 / math.sqrt(lengthSquared)
      return x * scale, y * scale, z * scale
    end

    local px, py, pz = blend(2), blend(3), blend(4)
    local fx, fy, fz = normalised(blend(5), blend(6), blend(7), 0, -1, 0)
    local ux, uy, uz = blend(8), blend(9), blend(10)
    local dot = fx * ux + fy * uy + fz * uz
    ux, uy, uz = normalised(ux - fx * dot, uy - fy * dot, uz - fz * dot, 0, 0, 1)
    return {px, py, pz, -fx, -fy, -fz, ux, uy, uz}, cursor
  end

  local function compatibleProxyCount(descriptor)
    local count = 0
    for _, proxy in pairs(proxies) do
      if proxyBackend.canReuse(proxy, descriptor) then count = count + 1 end
    end
    for _, proxy in ipairs(parkedProxies) do
      if proxyBackend.canReuse(proxy, descriptor) then count = count + 1 end
    end
    return count
  end

  local function requiredCompatibleCount(targetIndex, compatibilityKey)
    local count = 0
    for index = 1, targetIndex do
      local key = proxyBackend.compatibilityKey(prewarmDescriptors[index])
      if key == compatibilityKey then count = count + 1 end
    end
    return count
  end

  local function processPrewarm(realDeltaTime)
    if unavailableReason or #order > 0 or prewarmCursor > #prewarmDescriptors then
      return false
    end
    prewarmCooldown = math.max(0, prewarmCooldown - math.max(realDeltaTime, 0))
    -- A pooled vehicle can only be deactivated once its own VM has finished the
    -- Ghost/freeze handshake, so idle prewarm is where that is picked up.
    for index = 1, #parkedProxies do proxyBackend.park(parkedProxies[index]) end
    if prewarmCooldown > 0 then return false end

    if not poolGenerationCleaned then
      for slot = 1, maximumGhosts do
        if not removeStaleProxies("pool_" .. tostring(slot)) then
          reportUnavailable("staleObjectCleanupFailed")
          return false
        end
      end
      poolGenerationCleaned = true
    end

    while prewarmCursor <= #prewarmDescriptors do
      local descriptor = prewarmDescriptors[prewarmCursor]
      local compatibilityKey, compatibilityError =
        proxyBackend.compatibilityKey(descriptor)
      if not compatibilityKey then
        reportUnavailable(compatibilityError)
        return false
      end
      local required = requiredCompatibleCount(prewarmCursor, compatibilityKey)
      if compatibleProxyCount(descriptor) < required then
        local samples = loadSamples(descriptor.file)
        local elapsed = samples and tonumber(samples[1] and samples[1][1]) or 0
        local pose = samples and resolvePose(samples, 1, elapsed)
        if not pose then
          trace(
            "shell.prewarm.skip", "id=%s reason=samplesMissing",
            tostring(descriptor.id)
          )
          prewarmCursor = prewarmCursor + 1
        else
          local slotId = "pool_" .. tostring(prewarmCursor)
          -- This renderer can also own the stable slot with an incompatible
          -- config from an earlier mode. Remove its Lua bookkeeping before the
          -- scene-tree stale cleanup replaces the underlying C++ object.
          removeOwnedPoolSlot(slotId)
          local proxy, reason = createProxy(
            slotId,
            descriptor,
            pose
          )
          if not proxy then
            reportUnavailable(reason)
            return false
          end
          proxyBackend.hide(proxy)
          parkedProxies[#parkedProxies + 1] = proxy
          local desiredPoolSize = math.min(#prewarmDescriptors, maximumGhosts)
          while #parkedProxies > desiredPoolSize do destroyParkedProxy(1) end
          trace(
            "shell.prewarm.created", "id=%s pooled=%d",
            tostring(descriptor.id), #parkedProxies
          )
          prewarmCursor = prewarmCursor + 1
          prewarmCooldown = PREWARM_INTERVAL_SECONDS
          return true
        end
      else
        prewarmCursor = prewarmCursor + 1
      end
    end
    return false
  end

  local function clockDifference(incoming, current, duration, looping)
    local difference = incoming - current
    if looping and duration > 0 then
      -- Compare positions on the playback cycle. A pre-loop heartbeat can sit
      -- in the VM queue until after the renderer has already wrapped; treating
      -- 17.4 and 0.1 as far apart would incorrectly jump back to the lap end.
      difference = (difference + duration * 0.5) % duration - duration * 0.5
    end
    return difference
  end

  function renderer.setClock(elapsed, playing, duration, looping, resync)
    elapsed = tonumber(elapsed)
    if elapsed == nil then return false end
    playing = playing == true
    duration = math.max(tonumber(duration) or 0, 0)
    looping = looping == true and duration > 0
    resync = resync == true
    if looping then elapsed = elapsed % duration end
    -- Between corrections the clock runs purely on local frame time, which is
    -- what keeps the rate constant. Nudging it towards every arriving value
    -- reintroduces the surging the local clock exists to avoid, so only a
    -- discontinuity the renderer cannot predict -- a stop or an explicit
    -- resync -- is applied. A routine heartbeat that is behind the local clock
    -- is stale by definition and must never pull the body backwards; a heartbeat
    -- ahead of it means GE missed simulation time and can safely catch it up.
    -- Loops are predictable now that the renderer knows the playback duration,
    -- so bodies do not disappear while a post-loop message is queued.
    local difference = clock == nil and 0
      or clockDifference(elapsed, clock, duration, looping)
    if clock == nil or playing ~= clockPlaying or resync
        or difference > CLOCK_RESYNC_SECONDS then
      clock = elapsed
    end
    clockPlaying = playing
    clockDuration = duration
    clockLooping = looping
    if clockLooping and clock ~= nil then clock = clock % clockDuration end
    return true
  end

  -- Called from the GE update phase before scene submission. The clock runs
  -- locally between bridge updates and native vehicle placement stays on this
  -- update path rather than the immediate debug-draw hook.
  function renderer.advance(deltaTime, realDeltaTime)
    -- Sampled before every early return so the log carries a baseline from
    -- before a body exists. Without that, "the frame rate drops" can only be
    -- compared against memory.
    local realStep = math.max(tonumber(realDeltaTime) or 0, 0)
    if realStep > 0 then
      frameSamples = frameSamples + 1
      frameSeconds = frameSeconds + realStep
      if realStep > worstFrame then worstFrame = realStep end
    end
    healthCountdown = healthCountdown - realStep
    if healthCountdown <= 0 then
      healthCountdown = HEALTH_INTERVAL_SECONDS
      local backendState = proxyBackend.snapshot() or {}
      local bodies = 0
      for _ in pairs(proxies) do bodies = bodies + 1 end
      local averageFps = frameSamples > 0 and frameSeconds > 0
        and frameSamples / frameSeconds or 0
      local distance = -1
      if lastPose and type(getPlayerVehicle) == "function" then
        local ok, player = pcall(getPlayerVehicle, 0)
        if ok and player and type(player.getPosition) == "function" then
          local gotPosition, position = pcall(player.getPosition, player)
          if gotPosition and position then
            local dx = (tonumber(position.x) or 0) - lastPose[1]
            local dy = (tonumber(position.y) or 0) - lastPose[2]
            local dz = (tonumber(position.z) or 0) - lastPose[3]
            distance = math.sqrt(dx * dx + dy * dy + dz * dz)
          end
        end
      end
      -- A leak and a growing per-frame cost look identical from the outside;
      -- spawns against deletes, and live vehicles against the budget, separate
      -- them. fps and worstFrameMs put the symptom itself on this timeline.
      trace(
        "shell.health",
        "bodies=%d pooled=%d spawns=%s deletes=%s live=%s fps=%.1f worstFrameMs=%.1f "
          .. "clock=%.1f playing=%s phase=%s distanceM=%.0f pos=%.0f,%.0f,%.0f "
          .. "geHeapKb=%.0f damage=%s budget=%d",
        bodies, #parkedProxies,
        tostring(backendState.spawns), tostring(backendState.deletes),
        tostring(backendState.liveVehicles),
        averageFps, worstFrame * 1000, clock or 0, tostring(clockPlaying),
        abPhaseName(), distance,
        lastPose and lastPose[1] or 0, lastPose and lastPose[2] or 0,
        lastPose and lastPose[3] or 0, heapKb(),
        tostring(order[1] and proxies[order[1]] and proxyBackend.damageReading
          and proxyBackend.damageReading(proxies[order[1]]) or "none"),
        maximumGhosts
      )
      reportGhostHeap(order[1] and proxies[order[1]])
      if proxyBackend.reportGhostTables then
        proxyBackend.reportGhostTables(order[1] and proxies[order[1]])
      end
      frameSamples = 0
      frameSeconds = 0
      worstFrame = 0
    end
    processPrewarm(tonumber(realDeltaTime) or tonumber(deltaTime) or 0)
    if unavailableReason or clock == nil then return false end
    deltaTime = tonumber(deltaTime) or 0
    if clockPlaying and deltaTime > 0 then
      clock = clock + deltaTime
      if clockLooping and clockDuration > 0 then clock = clock % clockDuration end
    end
    if not clockPlaying then return false end


    -- Acquire and validate the complete set before showing any member. This
    -- preserves the representation invariant: a Top 2/3 group is either all
    -- native vehicles or all wireframes, never a temporary mixture while a
    -- second vehicle is still finishing its setup handshake.
    local allReady = #order > 0
    -- Build at most one body on demand per update. A backend with no spawn stall
    -- (TSStatic) builds on demand when the pool is empty -- e.g. after a live
    -- backend switch that drains the pool without re-triggering prewarm -- but
    -- loading every missing body's mesh/material in a single update can hitch the
    -- lap-crossing frame. Spread it: a drained pool refills over several frames,
    -- and because the group stays wireframe until the whole set is ready (below)
    -- and only then switches atomically, spreading the builds never shows a
    -- half-built mixture.
    local onDemandCreatesLeft = 1
    for index = 1, #order do
      local id = order[index]
      if not proxies[id] then
        proxies[id] = acquireParkedProxy(id, descriptorsById[id])
      end
      if not proxies[id] and proxyBackend.allowsOnDemandCreate and onDemandCreatesLeft > 0 then
        onDemandCreatesLeft = onDemandCreatesLeft - 1
        local descriptor = descriptorsById[id]
        local samples = descriptor and loadSamples(descriptor.file)
        local pose = samples and resolvePose(samples, cursors[id], clock or 0)
        if pose then
          local proxy = createProxy(id, descriptor, pose)
          if proxy then proxies[id] = proxy end
        end
      end
      if not proxies[id] then
        allReady = false
      else
        local ready, readinessError = proxyBackend.readiness(proxies[id])
        if readinessError then
          destroyProxy(id)
          reportUnavailable(readinessError)
          return false
        end
        if not ready then allReady = false end
      end
    end
    if not allReady then
      for _, proxy in pairs(proxies) do proxyBackend.hide(proxy) end
      return false
    end

    local shown = 0
    local visibleIds = {}
    for index = 1, #order do
      local id = order[index]
      local descriptor = descriptorsById[id]
      local samples = (not abSkipsGhost(index)) and descriptor
        and loadSamples(descriptor.file) or nil
      if samples then
        local pose, cursor = resolvePose(samples, cursors[id], clock)
        cursors[id] = cursor
        if pose and clock <= (samples[#samples][1] or 0) then
          -- Recycle before applying: the replacement is created at this same
          -- pose in the same frame, so the body never lingers at a stale one.
          if proxies[id] then
            proxies[id].ageSeconds = (proxies[id].ageSeconds or 0) + realStep
          end
          -- Suspended while the probe runs: rebuilding the body halfway
          -- through a phase resets the very heap the phase is measuring.
          if proxyBackend.wantsRecycle ~= false and not abEnabled and proxies[id] then
            local age = proxies[id].ageSeconds or 0
            -- Warm the successor behind the still-visible body. It spawns above
            -- the course and hidden, so its JBeam/config load never reaches a
            -- visible frame.
            if age > (RECYCLE_SECONDS - RECYCLE_LEAD_SECONDS)
                and not pendingReplacements[id] then
              local slot = replacementSlotId(id, proxies[id])
              local replacement, warmError = createProxy(slot, descriptor, pose)
              if replacement then
                pendingReplacements[id] = replacement
                trace(
                  "shell.recycle.warm", "id=%s slot=%s", tostring(id), tostring(slot)
                )
              else
                -- Not fatal: the deadline check keeps the old body until a later
                -- frame can warm a replacement.
                trace(
                  "shell.recycle.warm", "id=%s FAILED reason=%s",
                  tostring(id), tostring(warmError)
                )
              end
            end
            -- Swap only once the successor is ready and shown at the live pose,
            -- so the two never both render and the Ghost never blinks out. A
            -- successor that never readies simply leaves the old body in place.
            local pending = pendingReplacements[id]
            if pending and age > RECYCLE_SECONDS and proxyBackend.isReady(pending) then
              local shownOk, _, shownVisible = proxyBackend.applyPose(pending, pose)
              if shownOk and shownVisible then
                pendingReplacements[id] = nil
                destroyProxy(id)
                proxies[id] = pending
                recycles = recycles + 1
                trace(
                  "shell.recycle", "id=%s total=%d swap=hidden",
                  tostring(id), recycles
                )
              end
            end
          end
          local phase = abPhaseName()
          if phase == "hold" then
            -- Placed once so the body exists and renders, then never moved.
            if proxies[id] and not proxies[id].abHeld then
              proxies[id].abHeld = true
              proxyBackend.applyPose(proxies[id], pose)
            end
            shown = shown + 1
            visibleIds[#visibleIds + 1] = id
          elseif phase == "pin" then
            abPinnedPose = abPinnedPose or pose
            local ok = proxyBackend.applyPose(proxies[id], abPinnedPose)
            if ok then
              shown = shown + 1
              visibleIds[#visibleIds + 1] = id
            end
          elseif proxies[id] then
            local proxy = proxies[id]
            -- Teleport on a real-time cadence, not every frame. The body stays
            -- where the last teleport left it in between, so it is on screen the
            -- whole time but the engine is not repositioning it 60+ times a
            -- second. The first placement (reveal) and the probe are never
            -- throttled: the probe must keep measuring the raw per-frame cost.
            proxy.sinceTeleport = (proxy.sinceTeleport or math.huge) + realStep
            -- A free-moving backend (TSStatic) declares it does not want the
            -- throttle: it costs nothing to move, so it stays per-frame smooth.
            local due = proxyBackend.wantsThrottle == false
              or teleportPerFrame or abEnabled or (not proxy.visible)
              or proxy.sinceTeleport >= TELEPORT_INTERVAL_SECONDS
            local visible = proxy.visible
            if due then
              proxy.sinceTeleport = 0
              local ok, reason, applied = proxyBackend.applyPose(proxy, pose)
              if not ok then
                destroyProxy(id)
                reportUnavailable(reason)
                return false
              end
              visible = applied
            end
            if visible then
              shown = shown + 1
              visibleIds[#visibleIds + 1] = id
              if #visibleIds == 1 then lastPose = pose end
            end
          end
        elseif proxies[id] then
          -- Native vehicles are expensive to respawn. Hide a shorter recording
          -- until the shared playback clock loops instead of reloading its
          -- complete JBeam/config every lap.
          proxyBackend.hide(proxies[id])
        end
      end
    end
    -- Phases only advance once there is something to measure. Counting from
    -- the moment the probe is switched on burned the whole hold phase before
    -- the Ghost had even been created.
    if shown > 0 then abAdvance(realStep) end

    -- Report exactly which Ghosts have a visible body, not merely that some
    -- body exists. A set whose recordings differ in length always has a Ghost
    -- past its own end while the others are still driving, so an all-or-nothing
    -- confirmation either never fires -- leaving a solid body and its wireframe
    -- on screen together -- or hides the wireframe of a Ghost with no body.
    -- Per-Ghost suppression is correct in both directions.
    local visibleSignature = table.concat(visibleIds, "|")
    if visibleSignature ~= lastVisibleSignature then
      lastVisibleSignature = visibleSignature
      reportedAvailable = #visibleIds > 0
      trace("shell.visible", "bodies=%d of=%d [%s]", #visibleIds, #order, visibleSignature)
      onAvailable(visibleIds)
    end
    return shown > 0
  end

  function renderer.releasePool()
    local activeIds = {}
    for id in pairs(proxies) do activeIds[#activeIds + 1] = id end
    for _, id in ipairs(activeIds) do destroyProxy(id) end
    discardAllPending()
    while #parkedProxies > 0 do destroyParkedProxy(#parkedProxies) end
    cursors = {}
    clock = nil
    clockPlaying = false
    clockDuration = 0
    clockLooping = false
    prewarmDescriptors = {}
    prewarmCursor = 1
    prewarmCooldown = 0
    poolGenerationCleaned = false
    descriptorsById = {}
    order = {}
    reportedAvailable = false
    lastVisibleSignature = nil
  end

  function renderer.clear()
    renderer.releasePool()
  end

  function renderer.reset()
    renderer.clear()
    descriptorsById = {}
    order = {}
    sampleCache = {}
  end

  function renderer.snapshot()
    local active = 0
    for _ in pairs(proxies) do active = active + 1 end
    local pending = 0
    for _ in pairs(pendingReplacements) do pending = pending + 1 end
    return {
      activeProxies = active,
      pooledProxies = #parkedProxies,
      pendingReplacements = pending,
      opacity = SHELL_OPACITY,
      maximumGhosts = maximumGhosts,
      unavailableReason = unavailableReason,
      clock = clock,
      playing = clockPlaying,
      duration = clockDuration,
      looping = clockLooping,
      staleProxiesRemoved = staleProxiesRemoved,
      recycles = recycles,
      recycleSeconds = RECYCLE_SECONDS,
      backend = proxyBackend.snapshot()
    }
  end

  return renderer
end

return M
