-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- LapLog, derived from Ghost Racer Replay (Jesus Goose) and Ghost Racer
-- Enhanced (flintt). See NOTICE.md for the full attribution chain.

-- Vehicle-side start registry persistence and legacy Ghost migration.

local M = {}

function M.new(options)
  options = options or {}
  local registry = {}
  local startGateConfig = assert(options.state, "registry state is required")
  local sanitizePathPart = assert(options.sanitizePathPart, "path sanitizer is required")
  local normalizeReplay = assert(options.normalizeReplay, "replay normalizer is required")
  local ghostLibraryIndexFilename = assert(
    options.ghostLibraryIndexFilename,
    "library filename builder is required"
  )
  local ghostSampleFilename = assert(
    options.ghostSampleFilename,
    "sample filename builder is required"
  )
  local vehicleDirectory = assert(options.vehicleDirectory, "vehicle directory is required")
  local FORMAT_VERSION = assert(options.formatVersion, "replay format is required")
  local GHOST_LIBRARY_FORMAT_VERSION = assert(
    options.libraryFormatVersion,
    "library format is required"
  )
  local MAX_STORED_GHOSTS = assert(options.maxStoredGhosts, "storage limit is required")
  local MAX_STORED_INCOMPLETE_GHOSTS = assert(
    options.maxStoredIncompleteGhosts,
    "incomplete storage limit is required"
  )
  local CODE_VERSION = assert(options.codeVersion, "code version is required")
  local TIME = assert(options.timeIndex, "time index is required")

  function registry.startLineFilenameForId(levelName, startId)
    if startId then
      return string.format(
        "lapLogs/freeRoam/%s/starts/%s/laplog.save.json",
        sanitizePathPart(levelName, "unknown_level"),
        sanitizePathPart(startId, "start")
      )
    end
    return string.format(
      "lapLogs/freeRoam/%s/%s/laplog.save.json",
      sanitizePathPart(levelName, "unknown_level"),
      sanitizePathPart(vehicleDirectory, "unknown_vehicle")
    )
  end

  function registry.lineLibraryFilename(levelName, line)
    if line and line.kind == "timeTrial" and line.raceKey then
      return string.format(
        "lapLogs/races/%s/%s/laplog.save.json",
        sanitizePathPart(levelName, "unknown_level"),
        sanitizePathPart(line.raceKey, "temp")
      )
    end
    return startGateConfig.startLineFilenameForId(levelName, line and line.id or nil)
  end

  -- 2.9.8 and earlier stored a separate library below each vehicle directory.
  -- Keep this path builder solely for lossless migration into the shared start.
  function registry.legacyVehicleStartLineFilenameForId(levelName, startId, vehicleName)
    return string.format(
      "lapLogs/freeRoam/%s/%s/starts/%s/laplog.save.json",
      sanitizePathPart(levelName, "unknown_level"),
      sanitizePathPart(vehicleName or vehicleDirectory, "unknown_vehicle"),
      sanitizePathPart(startId, "start")
    )
  end

  function registry.copyTable(source)
    local target = {}
    for key, value in pairs(source or {}) do target[key] = value end
    return target
  end

  function registry.replaySetVehicle(levelName, replayFilename)
    local prefix = string.format(
      "lapLogs/freeRoam/%s/",
      sanitizePathPart(levelName, "unknown_level")
    )
    local normalized = tostring(replayFilename or ""):gsub("\\", "/"):gsub("^/+", "")
    if normalized:sub(1, #prefix) ~= prefix then return nil end
    local remainder = normalized:sub(#prefix + 1)
    return remainder:match("^([^/]+)/starts/[^/]+/laplog%.save%.json$")
  end

  -- Copy one old vehicle-scoped replay set into a start-scoped shared library.
  -- Source files remain untouched as recovery copies. Imported keys make this
  -- idempotent even when vehicle replacement initializes multiple controllers.
  function registry.mergeGhostReplaySet(levelName, source, target, sourceVehicle)
    if not source or not target or source == target then return false end
    local sourceManifestFilename = ghostLibraryIndexFilename(source)
    local sourceManifest = jsonReadFile(sourceManifestFilename)
    local targetManifestFilename = ghostLibraryIndexFilename(target)
    local targetManifest = jsonReadFile(targetManifestFilename)
    if type(targetManifest) ~= "table" then
      targetManifest = {
        formatVersion = GHOST_LIBRARY_FORMAT_VERSION,
        nextId = 1,
        maxStoredGhosts = MAX_STORED_GHOSTS,
        maxStoredIncompleteGhosts = MAX_STORED_INCOMPLETE_GHOSTS,
        ghosts = {},
        importedLegacyGhosts = {}
      }
    end
    if type(targetManifest.ghosts) ~= "table" then targetManifest.ghosts = {} end
    if type(targetManifest.importedLegacyGhosts) ~= "table" then
      targetManifest.importedLegacyGhosts = {}
    end

    local imported = targetManifest.importedLegacyGhosts
    for index = 1, #targetManifest.ghosts do
      local descriptor = targetManifest.ghosts[index]
      if type(descriptor) == "table" and descriptor.importedFrom then
        imported[tostring(descriptor.importedFrom)] = true
      end
    end

    local nextId = math.max(1, tonumber(targetManifest.nextId) or 1)
    for index = 1, #targetManifest.ghosts do
      local numericId = tonumber(tostring(targetManifest.ghosts[index].id or ""):match("(%d+)$"))
      if numericId then nextId = math.max(nextId, numericId + 1) end
    end

    sourceVehicle = sanitizePathPart(
      sourceVehicle or startGateConfig.replaySetVehicle(levelName, source) or "unknown_vehicle",
      "unknown_vehicle"
    )
    local changed = false

    local function appendReplay(descriptor, replayData, importKey)
      importKey = tostring(importKey)
      if imported[importKey] == true or type(replayData) ~= "table" then return end
      local points, metadata = normalizeReplay(replayData)
      if not points or #points < 2 then return end

      local id = string.format("g%06d", nextId)
      nextId = nextId + 1
      local targetSample = ghostSampleFilename(target, id)
      local migratedReplay = {
        formatVersion = FORMAT_VERSION,
        sampleInterval = tonumber(descriptor and descriptor.sampleInterval)
          or tonumber(metadata.sampleInterval) or 0.01,
        duration = tonumber(descriptor and descriptor.duration)
          or tonumber(metadata.duration) or tonumber(points[#points][TIME]) or 0,
        lapTime = tonumber(descriptor and descriptor.lapTime) or tonumber(metadata.lapTime),
        vehicle = sanitizePathPart(
          descriptor and descriptor.vehicle or metadata.vehicle or sourceVehicle,
          sourceVehicle
        ),
        groundOffset = tonumber(descriptor and descriptor.groundOffset)
          or tonumber(metadata.groundOffset),
        source = descriptor and descriptor.source or "migrated",
        complete = not descriptor or descriptor.complete ~= false,
        incompleteReason = descriptor and descriptor.incompleteReason,
        shareFingerprint = descriptor and descriptor.shareFingerprint
          or metadata.shareFingerprint,
        startLine = metadata.startLine,
        samples = points
      }
      if jsonWriteFile(targetSample, migratedReplay, false) == false then return end

      local migratedDescriptor = startGateConfig.copyTable(descriptor)
      migratedDescriptor.id = id
      migratedDescriptor.label = migratedDescriptor.label
        or string.format("导入圈速 %d", #targetManifest.ghosts + 1)
      migratedDescriptor.lapTime = migratedReplay.lapTime
      migratedDescriptor.duration = migratedReplay.duration
      migratedDescriptor.sampleInterval = migratedReplay.sampleInterval
      migratedDescriptor.groundOffset = migratedReplay.groundOffset
      migratedDescriptor.hasSpeed = metadata.hasSpeed
      migratedDescriptor.source = migratedReplay.source
      migratedDescriptor.complete = migratedReplay.complete ~= false
      migratedDescriptor.incompleteReason = migratedReplay.incompleteReason
      migratedDescriptor.vehicle = migratedReplay.vehicle
      migratedDescriptor.file = targetSample
      migratedDescriptor.selected = false
      migratedDescriptor.importedFrom = importKey
      migratedDescriptor.shareFingerprint = migratedReplay.shareFingerprint
      targetManifest.ghosts[#targetManifest.ghosts + 1] = migratedDescriptor
      imported[importKey] = true
      changed = true
    end

    if type(sourceManifest) == "table" and type(sourceManifest.ghosts) == "table"
        and #sourceManifest.ghosts > 0 then
      for index = 1, #sourceManifest.ghosts do
        local descriptor = sourceManifest.ghosts[index]
        if type(descriptor) == "table" and descriptor.file then
          appendReplay(
            descriptor,
            jsonReadFile(descriptor.file),
            sourceManifestFilename .. "#" .. tostring(descriptor.id or descriptor.file)
          )
        end
      end
    else
      appendReplay(
        {label = "导入的个人最佳", source = "personalBest", vehicle = sourceVehicle},
        jsonReadFile(source),
        source .. "#primary"
      )
    end

    if not changed then return false end

    table.sort(targetManifest.ghosts, function(first, second)
      if (first.complete == false) ~= (second.complete == false) then
        return first.complete ~= false
      end
      local firstTime = tonumber(first.lapTime) or tonumber(first.duration) or math.huge
      local secondTime = tonumber(second.lapTime) or tonumber(second.duration) or math.huge
      if firstTime == secondTime then return tostring(first.id) < tostring(second.id) end
      return firstTime < secondTime
    end)
    local function pruneCategory(incomplete, limit)
      -- Pinned ghosts are protected extra slots: the merge never prunes them and
      -- never counts them against the quota, matching the live prune and the
      -- reload loader. Counting or removing pinned here used to delete a pinned
      -- record (and its sample file) during a cross-vehicle merge.
      local function collectUnpinned()
        local list = {}
        for index = 1, #targetManifest.ghosts do
          local ghost = targetManifest.ghosts[index]
          if (ghost.complete == false) == incomplete and ghost.pinned ~= true then
            list[#list + 1] = index
          end
        end
        return list
      end
      local indexes = collectUnpinned()
      while #indexes > limit do
        local removeIndex = indexes[#indexes]
        if incomplete then
          local oldestId = math.huge
          for listIndex = 1, #indexes do
            local candidateIndex = indexes[listIndex]
            local numericId = tonumber(tostring(
              targetManifest.ghosts[candidateIndex].id or ""
            ):match("(%d+)$")) or candidateIndex
            if numericId < oldestId then
              oldestId = numericId
              removeIndex = candidateIndex
            end
          end
        end
        local removed = table.remove(targetManifest.ghosts, removeIndex)
        indexes = collectUnpinned()
        local sharedPrefix = target:gsub("%.json$", "") .. ".ghosts/"
        if type(removed.file) == "string"
            and removed.file:sub(1, #sharedPrefix) == sharedPrefix then
          startGateConfig.removeStoredFile(removed.file)
        end
      end
    end
    pruneCategory(false, MAX_STORED_GHOSTS)
    pruneCategory(true, MAX_STORED_INCOMPLETE_GHOSTS)
    targetManifest.nextId = nextId
    targetManifest.formatVersion = GHOST_LIBRARY_FORMAT_VERSION
    targetManifest.maxStoredGhosts = MAX_STORED_GHOSTS
    targetManifest.maxStoredIncompleteGhosts = MAX_STORED_INCOMPLETE_GHOSTS
    jsonWriteFile(targetManifestFilename, targetManifest, false)
    return true
  end

  function registry.importVehicleGhostLibraries(levelName, startId, target)
    if not startId then return false end
    local changed = false
    local seen = {}
    local canonicalTarget = tostring(target):gsub("\\", "/"):gsub("^/+", "")
    local function importSource(source)
      source = tostring(source or ""):gsub("\\", "/"):gsub("^/+", "")
      if source == "" or source == canonicalTarget or seen[source] then return end
      seen[source] = true
      local suffix = "/starts/" .. sanitizePathPart(startId, "start")
        .. "/laplog.save.json"
      if source:sub(-#suffix) ~= suffix then return end
      if startGateConfig.mergeGhostReplaySet(
          levelName, source, target, startGateConfig.replaySetVehicle(levelName, source)
        ) then changed = true end
    end

    -- This fallback also covers test harnesses or old BeamNG builds where file
    -- enumeration is unavailable.
    importSource(startGateConfig.legacyVehicleStartLineFilenameForId(levelName, startId))
    if FS and type(FS.findFiles) == "function" then
      local root = string.format(
        "lapLogs/freeRoam/%s/",
        sanitizePathPart(levelName, "unknown_level")
      )
      local ok, manifests = pcall(
        FS.findFiles, FS, root, "laplog.save.library.json", -1, true, false
      )
      if ok and type(manifests) == "table" then
        for index = 1, #manifests do
          importSource(tostring(manifests[index]):gsub("%.library%.json$", ".json"))
        end
      end
      local primaryOk, primaries = pcall(
        FS.findFiles, FS, root, "laplog.save.json", -1, true, false
      )
      if primaryOk and type(primaries) == "table" then
        for index = 1, #primaries do importSource(primaries[index]) end
      end
    end
    return changed
  end

  function registry.registryFilename(levelName)
    return string.format(
      "lapLogs/freeRoam/%s/startLines.json",
      sanitizePathPart(levelName, "unknown_level")
    )
  end

  function registry.legacyRegistryFilename(levelName)
    return string.format(
      "lapLogs/freeRoam/%s/%s/startLines.json",
      sanitizePathPart(levelName, "unknown_level"),
      sanitizePathPart(vehicleDirectory, "unknown_vehicle")
    )
  end

  function registry.legacyFilename(levelName)
    local activeId = startGateConfig.registry.activeId
    startGateConfig.registry.activeId = nil
    local filename = startGateConfig.lineLibraryFilename(
      levelName,
      startGateConfig.activeEntry()
    )
    startGateConfig.registry.activeId = activeId
    return filename
  end

  function registry.normalizedRegistryLine(line, fallbackIndex, registry)
    local position = line and line.position
    local normal = line and line.normal
    if type(position) ~= "table" or type(normal) ~= "table" then return nil end

    local id = tostring(line.id or string.format("s%03d", registry.nextId))
    local numericId = tonumber(id:match("^s(%d+)$"))
    if numericId then registry.nextId = math.max(registry.nextId, numericId + 1) end
    -- Registry format 2 predates the explicit flag. Conservatively retain every
    -- existing TT label as user-owned during migration; generated labels remain
    -- valid, while a custom name cannot be destroyed on the first upgraded GO.
    local userNamed = line.userNamed == true
      or (line.userNamed == nil and line.kind == "timeTrial")
    return {
      id = id,
      name = tostring(line.name or string.format("起点 %d", fallbackIndex)):sub(1, 32),
      userNamed = userNamed,
      -- Track-variant group key. Pre-variant registries have none, so each old
      -- start migrates to its own single-track group (startKey == id).
      startKey = line.startKey and tostring(line.startKey) or id,
      kind = line.kind == "timeTrial" and "timeTrial" or nil,
      raceKey = line.raceKey and sanitizePathPart(line.raceKey, "temp") or nil,
      activitySource = line.activitySource and tostring(line.activitySource):sub(1, 32) or nil,
      position = {
        tonumber(position[1]) or 0,
        tonumber(position[2]) or 0,
        tonumber(position[3]) or 0
      },
      normal = {
        tonumber(normal[1]) or 0,
        tonumber(normal[2]) or 1,
        0
      },
      -- Optional finish gate: present only for point-to-point starts. Carried
      -- through so it persists to disk and restores on activation.
      finishPosition = type(line.finishPosition) == "table" and {
        tonumber(line.finishPosition[1]) or 0,
        tonumber(line.finishPosition[2]) or 0,
        tonumber(line.finishPosition[3]) or 0
      } or nil,
      finishNormal = type(line.finishNormal) == "table" and {
        tonumber(line.finishNormal[1]) or 0,
        tonumber(line.finishNormal[2]) or 1,
        0
      } or nil,
      ghostCount = 0,
      incompleteGhostCount = 0,
      pbTime = nil
    }
  end

  function registry.sharedLineStats(levelName, line)
    local filename = startGateConfig.lineLibraryFilename(levelName, line)
    local manifest = jsonReadFile(ghostLibraryIndexFilename(filename))
    local primary = jsonReadFile(filename)
    local sidecar = jsonReadFile(filename .. ".time")
    local count = 0
    local incompleteCount = 0
    local pbTime

    if type(manifest) == "table" and type(manifest.ghosts) == "table" then
      for index = 1, #manifest.ghosts do
        local descriptor = manifest.ghosts[index]
        if type(descriptor) == "table" and descriptor.file then
          if descriptor.complete == false then
            if incompleteCount < MAX_STORED_INCOMPLETE_GHOSTS then
              incompleteCount = incompleteCount + 1
            end
          elseif count < MAX_STORED_GHOSTS then
            count = count + 1
            local lapTime = tonumber(descriptor.lapTime)
            if lapTime and (not pbTime or lapTime < pbTime) then pbTime = lapTime end
          end
        end
      end
    else
      if type(primary) == "table" then
        local samples = primary.samples or primary
        if type(samples) == "table" and #samples >= 2 then
          count = 1
          pbTime = tonumber(primary.lapTime)
        end
      end
    end

    pbTime = pbTime
      or (type(sidecar) == "table" and tonumber(sidecar[1]) or nil)
      or (type(primary) == "table" and tonumber(primary.lapTime) or nil)
    return count, pbTime, incompleteCount
  end

  function registry.refreshRegistryStats(registry)
    for index = 1, #registry.lines do
      local line = registry.lines[index]
      line.ghostCount, line.pbTime, line.incompleteGhostCount = startGateConfig.sharedLineStats(
        registry.level, line
      )
    end
  end

  -- A second vehicle can bring an old vehicle-scoped registry whose IDs collide
  -- with starts already imported by another vehicle. Merge its replay set into
  -- the map/start library while leaving the old files as a recovery copy.
  function registry.migrateStartGhostData(levelName, oldId, sharedId)
    local source = startGateConfig.legacyVehicleStartLineFilenameForId(levelName, oldId)
    local target = startGateConfig.startLineFilenameForId(levelName, sharedId)
    return startGateConfig.mergeGhostReplaySet(
      levelName, source, target, vehicleDirectory
    )
  end

  function registry.mergeLegacyRegistry(registry, legacy)
    if type(legacy) ~= "table" or type(legacy.lines) ~= "table" then return false end
    local idMap = {}
    local changed = false

    for legacyIndex = 1, math.min(#legacy.lines, startGateConfig.maxSavedStarts) do
      local sourceLine = startGateConfig.normalizedRegistryLine(
        legacy.lines[legacyIndex], legacyIndex, registry
      )
      if sourceLine then
        local targetLine
        local maximumSquared = startGateConfig.matchDistance * startGateConfig.matchDistance
        for index = 1, #registry.lines do
          local candidate = registry.lines[index]
          local dx = candidate.position[1] - sourceLine.position[1]
          local dy = candidate.position[2] - sourceLine.position[2]
          local dot = candidate.normal[1] * sourceLine.normal[1]
            + candidate.normal[2] * sourceLine.normal[2]
          if dx * dx + dy * dy <= maximumSquared and dot >= 0.75 then
            targetLine = candidate
            break
          end
        end

        if not targetLine and #registry.lines < startGateConfig.maxSavedStarts then
          local idAvailable = true
          for index = 1, #registry.lines do
            if registry.lines[index].id == sourceLine.id then idAvailable = false break end
          end
          if not idAvailable then
            sourceLine.id = string.format("s%03d", registry.nextId)
            registry.nextId = registry.nextId + 1
          end
          registry.lines[#registry.lines + 1] = sourceLine
          targetLine = sourceLine
          changed = true
        end

        if targetLine then
          idMap[tostring(legacy.lines[legacyIndex].id or sourceLine.id)] = targetLine.id
          if startGateConfig.migrateStartGhostData(
              registry.level,
              tostring(legacy.lines[legacyIndex].id or sourceLine.id),
              targetLine.id
            ) then changed = true end
        end
      end
    end

    if not registry.activeId and legacy.activeId then
      registry.activeId = idMap[tostring(legacy.activeId)]
      changed = registry.activeId ~= nil or changed
    end
    return changed
  end

  function registry.loadRegistry(levelName)
    local safeLevel = sanitizePathPart(levelName, "unknown_level")
    local registryPath = startGateConfig.registryFilename(safeLevel)
    local saved = jsonReadFile(registryPath)
    startGateConfig.trace(
      "registry.load",
      "path=%s disk=%s",
      registryPath,
      startGateConfig.registrySummary(saved)
    )
    local vehicle = sanitizePathPart(vehicleDirectory, "unknown_vehicle")
    local registry = {
      formatVersion = startGateConfig.registryFormat,
      revision = 0,
      level = safeLevel,
      nextId = 1,
      activeId = nil,
      migratedVehicles = {},
      lines = {}
    }

    if type(saved) == "table" then
      registry.revision = math.max(0, tonumber(saved.revision) or 0)
      registry.nextId = math.max(1, tonumber(saved.nextId) or 1)
      registry.activeId = saved.activeId and tostring(saved.activeId) or nil
      if type(saved.migratedVehicles) == "table" then
        for key, value in pairs(saved.migratedVehicles) do
          if value == true then registry.migratedVehicles[tostring(key)] = true end
        end
      end
      if type(saved.lines) == "table" then
        for index = 1, math.min(#saved.lines, startGateConfig.maxSavedStarts) do
          local line = startGateConfig.normalizedRegistryLine(saved.lines[index], index, registry)
          if line then registry.lines[#registry.lines + 1] = line end
        end
      end
    end

    local registryChanged = false
    if registry.migratedVehicles[vehicle] ~= true then
      local legacy = jsonReadFile(startGateConfig.legacyRegistryFilename(safeLevel))
      if startGateConfig.mergeLegacyRegistry(registry, legacy) then registryChanged = true end
      registry.migratedVehicles[vehicle] = true
      registryChanged = true
    end

    local activeExists = false
    for index = 1, #registry.lines do
      if registry.lines[index].id == registry.activeId then activeExists = true break end
    end
    if not activeExists then registry.activeId = nil end

    startGateConfig.registry = registry
    startGateConfig.refreshRegistryStats(registry)
    if registryChanged then
      startGateConfig.saveRegistry({operation = "legacyMigration"})
    end
    startGateConfig.trace(
      "registry.load",
      "complete path=%s memory=%s migrated=%s",
      registryPath,
      startGateConfig.registrySummary(registry),
      tostring(registryChanged)
    )
    return registry
  end

  function registry.activeEntry()
    for index = 1, #startGateConfig.registry.lines do
      local line = startGateConfig.registry.lines[index]
      if line.id == startGateConfig.registry.activeId then return line end
    end
    return nil
  end

  function registry.findRegistryLine(registry, id)
    for index = 1, #(registry and registry.lines or {}) do
      if registry.lines[index].id == id then return registry.lines[index] end
    end
    return nil
  end

  -- Vehicle controllers can remain alive after the player changes vehicle. An
  -- older controller must never overwrite a rename (or a newly created start)
  -- from the current one. Merge a newer on-disk registry before every write;
  -- the explicitly edited row remains authoritative for that operation.
  function registry.mergeNewerRegistry(saved, options)
    local registry = startGateConfig.registry
    if type(saved) ~= "table" or type(saved.lines) ~= "table" then return end
    if (tonumber(saved.revision) or 0) <= (tonumber(registry.revision) or 0) then return end

    options = options or {}
    startGateConfig.trace(
      "registry.merge",
      "newer disk revision detected operation=%s localRevision=%s diskRevision=%s",
      tostring(options.operation or "unspecified"),
      tostring(registry.revision),
      tostring(saved.revision)
    )
    local renamedId = options.renamedId and tostring(options.renamedId) or nil
    local updatedId = options.updatedId and tostring(options.updatedId) or nil
    local deletedId = options.deletedId and tostring(options.deletedId) or nil
    local diskRegistry = {
      nextId = math.max(1, tonumber(saved.nextId) or 1),
      lines = {}
    }

    for index = 1, math.min(#saved.lines, startGateConfig.maxSavedStarts) do
      local diskLine = startGateConfig.normalizedRegistryLine(
        saved.lines[index], index, diskRegistry
      )
      if diskLine and diskLine.id ~= deletedId then
        local localLine = startGateConfig.findRegistryLine(registry, diskLine.id)
        if not localLine then
          if #registry.lines < startGateConfig.maxSavedStarts then
            registry.lines[#registry.lines + 1] = diskLine
          end
        else
          if diskLine.id ~= renamedId and diskLine.userNamed then
            if localLine.name ~= diskLine.name or localLine.userNamed ~= true then
              startGateConfig.trace(
                "registry.merge",
                "adopting disk name id=%s local=%q disk=%q",
                diskLine.id, tostring(localLine.name), tostring(diskLine.name)
              )
            end
            localLine.name = diskLine.name
            localLine.userNamed = true
          end
          if diskLine.id ~= updatedId then
            localLine.kind = diskLine.kind
            localLine.raceKey = diskLine.raceKey
            localLine.activitySource = diskLine.activitySource
            localLine.position = diskLine.position
            localLine.normal = diskLine.normal
          end
        end
      end
    end

    registry.nextId = math.max(registry.nextId, diskRegistry.nextId)
    if type(saved.migratedVehicles) == "table" then
      registry.migratedVehicles = registry.migratedVehicles or {}
      for key, value in pairs(saved.migratedVehicles) do
        if value == true then registry.migratedVehicles[tostring(key)] = true end
      end
    end
    registry.revision = math.max(registry.revision or 0, tonumber(saved.revision) or 0)
  end

  function registry.saveRegistry(options)
    local registry = startGateConfig.registry
    options = options or {}
    if not registry.level or registry.level == "unknown" then
      startGateConfig.trace(
        "registry.save", "rejected operation=%s level=%s",
        tostring(options.operation or "unspecified"), tostring(registry.level)
      )
      return false
    end
    local filename = startGateConfig.registryFilename(registry.level)
    local diskBefore = jsonReadFile(filename)
    startGateConfig.trace(
      "registry.save",
      "begin operation=%s path=%s memory={%s} disk={%s}",
      tostring(options.operation or "unspecified"),
      filename,
      startGateConfig.registrySummary(registry),
      startGateConfig.registrySummary(diskBefore)
    )
    startGateConfig.mergeNewerRegistry(diskBefore, options)
    local active = startGateConfig.activeEntry()
    registry.revision = math.max(0, tonumber(registry.revision) or 0) + 1
    local persisted = {
      formatVersion = startGateConfig.registryFormat,
      revision = registry.revision,
      level = registry.level,
      nextId = registry.nextId,
      activeId = active and not active.transient and registry.activeId or nil,
      migratedVehicles = registry.migratedVehicles or {},
      lines = {}
    }
    for index = 1, #registry.lines do
      local line = registry.lines[index]
      if not line.transient then
        persisted.lines[#persisted.lines + 1] = {
          id = line.id,
          name = line.name,
          userNamed = line.userNamed == true,
          startKey = line.startKey and tostring(line.startKey) or line.id,
          kind = line.kind,
          raceKey = line.raceKey,
          activitySource = line.activitySource,
          position = {line.position[1], line.position[2], line.position[3]},
          normal = {line.normal[1], line.normal[2], 0},
          -- Optional finish gate for point-to-point starts.
          finishPosition = type(line.finishPosition) == "table" and {
            line.finishPosition[1], line.finishPosition[2], line.finishPosition[3]
          } or nil,
          finishNormal = type(line.finishNormal) == "table" and {
            line.finishNormal[1], line.finishNormal[2], 0
          } or nil
        }
      end
    end
    local writeOk, writeResult = pcall(jsonWriteFile, filename, persisted, false)
    local succeeded = writeOk and writeResult ~= false
    local diskAfter = succeeded and jsonReadFile(filename) or nil
    startGateConfig.trace(
      "registry.save",
      "end operation=%s path=%s writeOk=%s writeResult=%s persisted={%s} readback={%s}",
      tostring(options.operation or "unspecified"),
      filename,
      tostring(writeOk),
      tostring(writeResult),
      startGateConfig.registrySummary(persisted),
      startGateConfig.registrySummary(diskAfter)
    )
    if not succeeded and type(log) == "function" then
      log("E", "LapLogDiag.VE", string.format(
        "[v%s][registry.save] FAILED path=%s error=%s",
        CODE_VERSION, filename, tostring(writeResult)
      ))
    end
    return succeeded
  end


  return registry
end

return M
