-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Non-physics TSStatic backend for replay Ghost bodies, behind the same proxy
-- contract as the native BeamNGVehicle backend so the renderer can switch
-- between them at runtime. A TSStatic has no soft body, so it never accrues the
-- per-vehicle simulation cost the native shell decays under: it can be moved
-- every frame for free and never needs recycling.
--
-- The open question this backend exists to answer is the render-thread twitch
-- that made the 2.14.x DAE proxy unusable. A TSStatic defaults to the static
-- shape manager, which batches static meshes and is not built to move; the
-- `dynamic` field forces it onto its own TSShapeInstance (the per-object render
-- path), which is the fix the 2.14.x attempts never applied. Whether that
-- actually removes the twitch on a given build is measured in game.

local M = {}

function M.new(options)
  options = options or {}
  local trace = assert(options.trace, "trace is required")
  local opacity = assert(options.opacity, "shell opacity is required")
  local backend = {}
  -- Capability flags the renderer reads: a TSStatic never decays, so it is
  -- never recycled, and it costs nothing to move, so the teleport throttle that
  -- exists only to slow the native decay is switched off (keeping it smooth).
  backend.wantsRecycle = false
  backend.wantsThrottle = false
  -- A TSStatic has no spawn stall, so unlike the native backend it may be built
  -- on demand when the pool is empty (for example right after a live backend
  -- switch) instead of only being reused from a prewarmed pool.
  backend.allowsOnDemandCreate = true
  local spawns, deletes = 0, 0
  local reportedTransformBackend = false

  -- A BeamNG vehicle has no single whole-car mesh: the body is assembled from
  -- flexbody meshes over one or more .dae files with no mandatory naming, so
  -- the body shape is discovered in the model's directory, preferring a file
  -- named after the vehicle. Ported unchanged from the 2.14.x renderer.
  local shapeCache = {}
  local function describeCandidates(files)
    local names = {}
    for index = 1, math.min(#files, 8) do
      names[#names + 1] = tostring(files[index]):match("([^/\\]+)$") or tostring(files[index])
    end
    if #files > 8 then names[#names + 1] = "... +" .. (#files - 8) .. " more" end
    return table.concat(names, ", ")
  end

  local function shapePathFor(model)
    model = tostring(model or "")
    if model == "" or model == "unknown_vehicle" then return nil, "unknownVehicle" end
    local cached = shapeCache[model]
    if cached ~= nil then
      if cached == false then return nil, "shapeMissing" end
      return cached
    end
    if not FS or type(FS.findFiles) ~= "function" then return nil, "noFileSystemApi" end
    local directory = "/vehicles/" .. model .. "/"
    local found, files = pcall(FS.findFiles, FS, directory, "*.dae", -1, true, false)
    if not found or type(files) ~= "table" or #files == 0 then
      shapeCache[model] = false
      trace("shell.shape", "model=%s REJECTED no .dae files under %s", model, directory)
      return nil, "shapeMissing"
    end
    local rejectedParts = {
      "engine", "interior", "wheel", "tire", "tyre", "brake", "suspension",
      "glass", "light", "seat", "steering", "exhaust", "gearbox", "transmission",
      "radiator", "battery", "fuel", "frame", "chassis", "roll", "cage"
    }
    local function looksLikeAPart(name)
      for index = 1, #rejectedParts do
        if name:find(rejectedParts[index], 1, true) then return true end
      end
      return false
    end
    local preferred = (directory .. model .. ".dae"):lower()
    local bodyCandidate, onlyCandidate, candidateCount = nil, nil, 0
    for index = 1, #files do
      local candidate = tostring(files[index]):gsub("\\", "/")
      local lowered = candidate:lower()
      if lowered == preferred then
        shapeCache[model] = candidate
        trace("shell.shape", "model=%s chose=%s reason=exactName candidates=%d [%s]",
          model, candidate, #files, describeCandidates(files))
        return candidate
      end
      if not looksLikeAPart(lowered) then
        candidateCount = candidateCount + 1
        onlyCandidate = onlyCandidate or candidate
        if lowered:find("body", 1, true) then bodyCandidate = bodyCandidate or candidate end
      end
    end
    local chosen = bodyCandidate or (candidateCount == 1 and onlyCandidate or nil)
    if not chosen then
      shapeCache[model] = false
      trace("shell.shape", "model=%s REJECTED no identifiable body mesh among %d files [%s]",
        model, #files, describeCandidates(files))
      return nil, "shapeAmbiguous"
    end
    shapeCache[model] = chosen
    trace("shell.shape", "model=%s chose=%s reason=%s candidates=%d [%s]",
      model, chosen, bodyCandidate and "bodyName" or "onlyCandidate", #files, describeCandidates(files))
    return chosen
  end

  -- Mirrors the native backend's three-value return so the renderer's pooling
  -- and prewarm can treat both alike: key, error, {reference}. Same body mesh
  -- means interchangeable, so the shape path is the compatibility key.
  function backend.compatibilityKey(descriptor)
    local shape, shapeError = shapePathFor(descriptor and descriptor.model)
    if not shape then return nil, shapeError or "shapeMissing" end
    return shape, nil, { reference = shape, source = "dae" }
  end

  local function setProxyVisible(proxy, visible)
    local object = proxy.object
    if not object then return false end
    if proxy.visible == visible then return true end
    if type(object.setHidden) == "function" then
      pcall(object.setHidden, object, not visible)
    end
    pcall(function()
      object:setField("instanceColor", 0,
        string.format("1 1 1 %.3f", visible and opacity or 0))
    end)
    proxy.visible = visible
    return true
  end
  backend.hide = function(proxy)
    if not proxy or not proxy.object then return false end
    return setProxyVisible(proxy, false)
  end

  function backend.create(objectName, descriptor, pose)
    local shape, shapeError = shapePathFor(descriptor and descriptor.model)
    if not shape then return nil, shapeError or "shapeMissing" end
    local factory = rawget(_G, "createObject")
    if type(factory) ~= "function" then return nil, "noObjectFactory" end
    local created, object = pcall(factory, "TSStatic")
    if not created or not object then return nil, "objectCreateFailed" end

    local reportDynamic = false
    local configured = pcall(function()
      object:setField("shapeName", 0, shape)
      -- The whole point of this backend: force the per-object dynamic render
      -- path instead of the batched static shape manager, so a per-frame
      -- transform is not fought by the render thread.
      object:setField("dynamic", 0, "1")
      reportDynamic = true
      object:setField("useInstanceRenderData", 0, "1")
      object:setField("instanceColor", 0, string.format("1 1 1 %.3f", opacity))
      object:setField("collisionType", 0, "None")
      object:setField("decalType", 0, "None")
      object:setField("allowPlayerStep", 0, "0")
      object:setField("canSave", 0, "0")
      object:setField("canSaveDynamicFields", 0, "0")
      local registered = object:registerObject(objectName)
      if registered == false then error("shell proxy registration failed") end
      if scenetree and scenetree.MissionGroup then
        scenetree.MissionGroup:addObject(object)
      end
    end)
    if not configured then
      pcall(function() object:delete() end)
      return nil, "objectSetupFailed"
    end

    local proxy = {
      object = object,
      objectName = objectName,
      model = tostring(descriptor and descriptor.model or ""),
      shape = shape,
      ready = true,
      visible = false
    }
    setProxyVisible(proxy, false)
    spawns = spawns + 1
    if reportDynamic then
      trace("shell.tsstatic", "id=%s shape=%s dynamic=1", tostring(objectName), shape)
    end
    return proxy
  end

  -- Log which transform entry points this build exposes on the object, once.
  -- 2.14.x required setRenderTransform and gave up when it was missing; with
  -- dynamic=1 the object is on the per-instance render path, so setTransform (or
  -- even setPosition) alone may already move smoothly. Name what exists rather
  -- than assuming, and use the best available.
  local probedApi = false
  local function probeTransformApi(object)
    if probedApi then return end
    probedApi = true
    trace("shell.tsstatic.api",
      "setTransform=%s setRenderTransform=%s setPosRot=%s setPosition=%s MatrixF=%s Point3F=%s",
      tostring(type(object.setTransform) == "function"),
      tostring(type(object.setRenderTransform) == "function"),
      tostring(type(object.setPosRot) == "function"),
      tostring(type(object.setPosition) == "function"),
      tostring(type(rawget(_G, "MatrixF")) == "function"),
      tostring(type(rawget(_G, "Point3F")) == "function"))
  end

  function backend.applyPose(proxy, pose)
    if not proxy or not proxy.object then return false, "objectMissing" end
    local object = proxy.object
    local rotationFactory = rawget(_G, "quatFromDir")
    local vectorFactory = rawget(_G, "vec3")
    if type(rotationFactory) ~= "function" or type(vectorFactory) ~= "function" then
      return false, "noMathApi"
    end
    probeTransformApi(object)
    local builtRotation, rotation = pcall(rotationFactory,
      vectorFactory(pose[4], pose[5], pose[6]), vectorFactory(pose[7], pose[8], pose[9]))
    if not builtRotation or not rotation then return false, "rotationFailed" end

    -- Try the richest available placement first, degrading to weaker ones. Only
    -- an object with no usable placement at all falls back to the wireframe.
    local matrixFactory = rawget(_G, "MatrixF")
    local pointFactory = rawget(_G, "Point3F")
    local applied, mode = false, nil
    if type(matrixFactory) == "function" and type(object.setTransform) == "function" then
      local builtMatrix, transform = pcall(matrixFactory, rotation,
        vectorFactory(pose[1], pose[2], pose[3]))
      if builtMatrix and transform then
        applied = pcall(object.setTransform, object, transform)
        if applied then
          mode = "setTransform"
          -- Optional: if the render transform exists, keep it in lockstep.
          if type(object.setRenderTransform) == "function" then
            pcall(object.setRenderTransform, object, transform)
            mode = "object+render"
          end
        end
      end
    end
    if not applied and type(object.setPosRot) == "function" then
      applied = pcall(object.setPosRot, object,
        pose[1], pose[2], pose[3], rotation.x, rotation.y, rotation.z, rotation.w)
      if applied then mode = "setPosRot" end
    end
    if not applied and type(object.setPosition) == "function" then
      local position = type(pointFactory) == "function"
        and pointFactory(pose[1], pose[2], pose[3])
        or vectorFactory(pose[1], pose[2], pose[3])
      applied = pcall(object.setPosition, object, position)
      if applied then mode = "setPosition" end
    end
    if not applied then return false, "noTransformApi" end

    setProxyVisible(proxy, true)
    if not reportedTransformBackend then
      reportedTransformBackend = true
      trace("shell.backend", "class=TSStatic transform=%s", tostring(mode))
    end
    return true, nil, true
  end

  function backend.isReady(proxy)
    return proxy ~= nil and proxy.ready == true
  end
  function backend.readiness(proxy)
    if not proxy then return false, "objectMissing" end
    return proxy.ready == true, nil
  end
  -- No async handshake: a TSStatic is ready the moment it is created.
  function backend.markReady() return true end

  function backend.canReuse(proxy, descriptor)
    if not proxy or not proxy.object then return false end
    local shape = shapePathFor(descriptor and descriptor.model)
    return shape ~= nil and shape == proxy.shape
  end
  function backend.prepareReuse(proxy, descriptor)
    if not backend.canReuse(proxy, descriptor) then return false end
    proxy.parked = false
    setProxyVisible(proxy, false)
    proxy.model = tostring(descriptor.model or proxy.model)
    return true
  end
  function backend.park(proxy)
    if not proxy or not proxy.object then return false end
    local hidden = setProxyVisible(proxy, false)
    proxy.parked = true
    return hidden
  end

  function backend.destroy(proxy)
    if not proxy then return true end
    local object = proxy.object
    proxy.object = nil
    proxy.visible = false
    deletes = deletes + 1
    if not object then return true end
    return pcall(function() object:delete() end)
  end

  function backend.describe(proxy)
    return string.format("object=%s model=%s",
      tostring(proxy and proxy.objectName or "none"),
      tostring(proxy and proxy.model or "none"))
  end

  function backend.snapshot()
    return {
      kind = "tsstatic",
      objectClass = "TSStatic",
      transformMode = "object+render",
      dynamic = true,
      spawns = spawns,
      deletes = deletes
    }
  end

  return backend
end

return M
