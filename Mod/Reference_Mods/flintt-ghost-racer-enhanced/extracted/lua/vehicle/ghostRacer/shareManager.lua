-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Route-scoped clipboard export/import orchestration. The GE extension owns
-- system clipboard access; this Vehicle service owns replay validation,
-- duplicate/capacity planning, confirmation, and library mutation.

local M = {}

function M.new(options)
  options = options or {}
  local manager = {}
  local state = assert(options.state, "Saved Start state is required")
  local playback = assert(options.playback, "playback state is required")
  local display = assert(options.display, "display state is required")
  local codec = assert(options.codec, "share codec is required")
  local object = assert(options.object, "vehicle object is required")
  local codeVersion = assert(options.codeVersion, "code version is required")
  local maximumCompleted = assert(options.maximumCompleted, "completed limit is required")
  local maximumIncomplete = assert(options.maximumIncomplete, "incomplete limit is required")
  local maximumManual = assert(options.maximumManual, "manual limit is required")
  local maximumBytes = assert(options.maximumBytes, "clipboard byte limit is required")
  local maximumVertical = assert(options.maximumVertical, "vertical tolerance is required")
  local sanitizePathPart = assert(options.sanitizePathPart, "path sanitizer is required")
  local ensureGhostSamples = assert(options.ensureGhostSamples, "sample loader is required")
  local ghostEntryById = assert(options.ghostEntryById, "Ghost lookup is required")
  local ghostIsIncomplete = assert(options.ghostIsIncomplete, "partial classifier is required")
  local ghostIsManual = assert(options.ghostIsManual, "manual classifier is required")
  local adoptRoute = assert(options.adoptRoute, "route adoption is required")
  local ghostComparableTime = assert(options.ghostComparableTime, "Ghost ranking is required")
  local addGhostToLibrary = assert(options.addGhostToLibrary, "library writer is required")
  local saveManifest = assert(options.saveManifest, "manifest writer is required")
  local removeStoredFile = assert(options.removeStoredFile, "file remover is required")
  local notify = assert(options.notify, "notice function is required")
  local sendUiState = assert(options.sendUiState, "UI state sender is required")
  local updateActiveStats = assert(options.updateActiveStats, "start stats updater is required")

  local exportFilename = "ghostReplays/clipboard/ghostRacerShareExport.json"
  local importFilename = "ghostReplays/clipboard/ghostRacerShareImport.json"

  -- Sharing needs the route identity, not a live start gate: the Saved Start
  -- that owns the loaded Ghost library still speaks for these recordings even
  -- once the HUD "x" has switched its live functions off.
  local function activeRoute()
    local line = state.activeLibraryOwnerEntry()
    if not line then return nil end
    return {
      level = tostring(state.startLineLevel or state.registry.level or "unknown"),
      startId = tostring(line.id or "unknown"),
      name = tostring(line.name or "Saved Start"):gsub("[%c]", " "):sub(1, 48),
      kind = line.kind == "timeTrial" and "timeTrial" or "manual",
      raceKey = line.raceKey and tostring(line.raceKey):sub(1, 96) or nil,
      position = {
        tonumber(state.startLineX) or 0,
        tonumber(state.startLineY) or 0,
        tonumber(state.startLineZ) or 0
      },
      normal = {
        tonumber(state.startLineNormalX) or 0,
        tonumber(state.startLineNormalY) or 1,
        0
      }
    }
  end

  local function queueClipboardExport(ghostCount)
    if not object.queueGameEngineLua then return false end
    -- If the GE extension is not there the prepared file would sit on disk
    -- forever, so the same command removes it in that case.
    object:queueGameEngineLua(
      "if extensions and extensions.ghostlapping and " ..
        "extensions.ghostlapping.copyGhostShareFile then " ..
        "extensions.ghostlapping.copyGhostShareFile(" ..
        string.format("%q", exportFilename) .. "," .. tostring(ghostCount) .. "," ..
        state.senderLiteral() .. ") " ..
        "elseif FS and FS.removeFile then pcall(FS.removeFile, FS, " ..
        string.format("%q", exportFilename) .. ") end"
    )
    return true
  end

  function manager.shareGhosts(ids)
    if type(ids) ~= "table" or #ids < 1 then
      notify("Nothing selected · tick the + checkbox on a Ghost row to share it", 5)
      return false
    end
    if #ids > codec.maximumGhosts then
      notify(string.format("Select no more than %d Ghosts to share", codec.maximumGhosts), 5)
      return false
    end
    local route = activeRoute()
    if not route or not playback.activeLibraryFilename then
      notify(
        state.activeEntry()
          and "These Ghosts belong to a finished activity · activate a Saved Start to share"
          or "Activate a Saved Start before sharing Ghosts",
        5
      )
      return false
    end

    local selected = {}
    local seen = {}
    for index = 1, #ids do
      local id = tostring(ids[index] or "")
      if id ~= "" and not seen[id] then
        seen[id] = true
        local entry = ghostEntryById(id)
        if entry then selected[#selected + 1] = entry end
      end
    end
    if #selected == 0 then
      notify("Selected Ghosts are no longer available", 4)
      return false
    end

    notify(string.format("Preparing %d selected Ghost%s for sharing…", #selected,
      #selected == 1 and "" or "s"), 4)
    local encodedGhosts = {}
    for index = 1, #selected do
      local entry = selected[index]
      if not ensureGhostSamples(entry) then
        notify("Share failed · a selected recording could not be loaded", 5)
        return false
      end
      local encoded, errorCode = codec.encode(entry.samples, {
        label = entry.label,
        lapTime = entry.lapTime,
        complete = not ghostIsIncomplete(entry),
        manual = ghostIsManual(entry),
        incompleteReason = entry.incompleteReason,
        vehicle = entry.vehicle,
        groundOffset = entry.groundOffset,
        sampleInterval = entry.sampleInterval
      })
      if not encoded then
        notify("Share failed · invalid recording data (" .. tostring(errorCode) .. ")", 5)
        return false
      end
      entry.shareFingerprint = encoded.fingerprint
      encodedGhosts[#encodedGhosts + 1] = encoded
    end

    local estimatedBytes = codec.estimatePackageBytes(encodedGhosts)
    if estimatedBytes > maximumBytes then
      notify(string.format(
        "Share cancelled · about %.1f MB exceeds the %d MB clipboard limit · select fewer Ghosts",
        estimatedBytes / (1024 * 1024),
        math.floor(maximumBytes / (1024 * 1024))
      ), 7)
      return false
    end

    local packageData = codec.package(route, encodedGhosts, codeVersion)
    if not packageData then
      notify("Share failed · could not build transfer package", 5)
      return false
    end
    if jsonWriteFile(exportFilename, packageData, false) == false then
      notify("Share failed · could not prepare clipboard data", 5)
      return false
    end
    saveManifest()
    if not queueClipboardExport(#encodedGhosts) then
      removeStoredFile(exportFilename)
      notify("Share failed · clipboard bridge unavailable", 5)
      return false
    end
    return true
  end

  local function routeMatches(route)
    local active = activeRoute()
    if not active or type(route) ~= "table" then return false, "noActiveStart" end
    if sanitizePathPart(route.level, "unknown") ~= sanitizePathPart(active.level, "unknown") then
      return false, "differentMap"
    end
    local importedKind = route.kind == "timeTrial" and "timeTrial" or "manual"
    if importedKind ~= active.kind then return false, "differentStartType" end
    if active.kind == "timeTrial" then
      if tostring(route.raceKey or "") ~= tostring(active.raceKey or "") then
        return false, "differentTimeTrial"
      end
      return true
    end
    if type(route.position) ~= "table" or type(route.normal) ~= "table" then
      return false, "missingStartGeometry"
    end
    local dx = (tonumber(route.position[1]) or math.huge) - active.position[1]
    local dy = (tonumber(route.position[2]) or math.huge) - active.position[2]
    local dz = (tonumber(route.position[3]) or math.huge) - active.position[3]
    local dot = (tonumber(route.normal[1]) or 0) * active.normal[1]
      + (tonumber(route.normal[2]) or 0) * active.normal[2]
    if dx * dx + dy * dy > state.matchDistance * state.matchDistance
        or math.abs(dz) > maximumVertical or dot < 0.75 then
      return false, "differentStartLine"
    end
    return true
  end

  local function existingFingerprints()
    local fingerprints = {}
    for index = 1, #playback.ghosts do
      local value = playback.ghosts[index].shareFingerprint
      if type(value) == "string" and value ~= "" then fingerprints[value] = true end
    end
    return fingerprints
  end

  local function planImport(packageData)
    local valid, errorCode = codec.validatePackage(packageData)
    if not valid then return nil, errorCode end
    local routeOk, routeError = routeMatches(packageData.route)
    if not routeOk then return nil, routeError end

    local fingerprints = existingFingerprints()
    local candidates = {}
    local duplicateCount = 0
    for index = 1, #packageData.ghosts do
      local points, metadata, decodeError = codec.decode(packageData.ghosts[index])
      if not points then return nil, decodeError end
      if fingerprints[metadata.fingerprint] then
        duplicateCount = duplicateCount + 1
      else
        fingerprints[metadata.fingerprint] = true
        candidates[#candidates + 1] = {points = points, metadata = metadata, order = index}
      end
    end

    -- Measured laps are ranked against each other; manual Runs and partial
    -- attempts are unranked and each keeps its own newest-first quota.
    local completedPool = {}
    local incompleteCandidates = {}
    local manualCandidates = {}
    for index = 1, #playback.ghosts do
      local entry = playback.ghosts[index]
      if not ghostIsIncomplete(entry) and not ghostIsManual(entry) then
        completedPool[#completedPool + 1] = {
          existing = true,
          comparableTime = ghostComparableTime(entry),
          tie = index
        }
      end
    end
    for index = 1, #candidates do
      local candidate = candidates[index]
      if candidate.metadata.complete == false then
        incompleteCandidates[#incompleteCandidates + 1] = candidate
      elseif candidate.metadata.manual == true then
        manualCandidates[#manualCandidates + 1] = candidate
      else
        completedPool[#completedPool + 1] = {
          existing = false,
          comparableTime = tonumber(candidate.metadata.lapTime)
            or tonumber(candidate.metadata.duration) or math.huge,
          tie = #playback.ghosts + index,
          candidate = candidate
        }
      end
    end
    table.sort(completedPool, function(first, second)
      if first.comparableTime == second.comparableTime then
        if first.existing ~= second.existing then return first.existing end
        return first.tie < second.tie
      end
      return first.comparableTime < second.comparableTime
    end)

    local retained = {}
    local replaceComplete = 0
    local skippedSlow = 0
    for index = 1, #completedPool do
      local item = completedPool[index]
      if index <= maximumCompleted then
        if item.candidate then retained[#retained + 1] = item.candidate end
      elseif item.existing then
        replaceComplete = replaceComplete + 1
      else
        skippedSlow = skippedSlow + 1
      end
    end

    local existingIncomplete = 0
    local existingManual = 0
    for index = 1, #playback.ghosts do
      local entry = playback.ghosts[index]
      if ghostIsIncomplete(entry) then
        existingIncomplete = existingIncomplete + 1
      elseif ghostIsManual(entry) then
        existingManual = existingManual + 1
      end
    end
    local replaceIncomplete = math.min(existingIncomplete, math.max(
      0,
      existingIncomplete + #incompleteCandidates - maximumIncomplete
    ))
    local replaceManual = math.min(existingManual, math.max(
      0,
      existingManual + #manualCandidates - maximumManual
    ))
    for index = 1, #incompleteCandidates do retained[#retained + 1] = incompleteCandidates[index] end
    for index = 1, #manualCandidates do retained[#retained + 1] = manualCandidates[index] end
    table.sort(retained, function(first, second) return first.order < second.order end)

    return {
      candidates = retained,
      duplicateCount = duplicateCount,
      skippedSlow = skippedSlow,
      replaceComplete = replaceComplete,
      replaceIncomplete = replaceIncomplete,
      replaceManual = replaceManual,
      sourceName = type(packageData.route) == "table"
        and tostring(packageData.route.name or "Saved Start"):sub(1, 48) or nil,
      exporterVersion = tostring(packageData.exporterVersion or "unknown"):sub(1, 24),
      libraryFilename = playback.activeLibraryFilename,
      activeStartId = state.registry.activeId
    }
  end

  local function applyImport(plan)
    if not plan or playback.activeLibraryFilename ~= plan.libraryFilename
        or state.registry.activeId ~= plan.activeStartId then
      playback.pendingImport = nil
      notify("Import cancelled · active Saved Start changed", 5)
      return false
    end

    local imported = 0
    for index = 1, #plan.candidates do
      local candidate = plan.candidates[index]
      local metadata = candidate.metadata
      local entry, _, _, stored = addGhostToLibrary(
        candidate.points,
        metadata.lapTime,
        metadata.label,
        "clipboard",
        metadata.sampleInterval,
        true,
        metadata.groundOffset,
        metadata.complete == false and metadata.incompleteReason or nil,
        metadata.fingerprint,
        metadata.vehicle,
        metadata.manual == true
      )
      if entry and stored ~= false then imported = imported + 1 end
    end
    playback.pendingImport = nil
    saveManifest()
    updateActiveStats(true)
    sendUiState()

    local details = {string.format("%d imported", imported)}
    if plan.duplicateCount > 0 then details[#details + 1] = plan.duplicateCount .. " duplicate skipped" end
    if plan.skippedSlow > 0 then details[#details + 1] = plan.skippedSlow .. " outside Top 20" end
    if plan.replaceComplete > 0 then details[#details + 1] = plan.replaceComplete .. " slowest replaced" end
    if plan.replaceIncomplete > 0 then details[#details + 1] = plan.replaceIncomplete .. " oldest partial replaced" end
    if plan.replaceManual > 0 then details[#details + 1] = plan.replaceManual .. " oldest manual replaced" end
    if imported > 0 and not display.showIncomplete then
      local importedPartial = false
      for index = 1, #plan.candidates do
        if plan.candidates[index].metadata.complete == false then importedPartial = true break end
      end
      if importedPartial then details[#details + 1] = "partials hidden by filter" end
    end
    notify("Clipboard import complete · " .. table.concat(details, " · "), 6)
    return imported > 0
  end

  local importErrorMessages = {
    unsupportedFormat = "unsupported or damaged share code",
    differentStartType = "Saved Start type does not match",
    differentTimeTrial = "share code belongs to another Time Trial",
    missingStartGeometry = "share code has no start geometry",
    differentStartLine = "the shared Saved Start could not be matched",
    startLimit = "this map already holds the maximum number of Saved Starts",
    startActivationFailed = "the shared Saved Start could not be activated",
    noLibrary = "the shared Saved Start has no Ghost library",
    checksumMismatch = "share code checksum failed",
    invalidSamples = "share code contains invalid samples",
    invalidSample = "share code contains a damaged sample",
    invalidOrientation = "share code contains an invalid orientation",
    invalidSpeed = "share code contains an invalid speed",
    durationLimit = "share code exceeds the 30 minute limit",
    invalidLapTime = "share code contains an invalid lap time"
  }

  local function importErrorText(errorCode, packageData)
    if errorCode == "differentMap" then
      local level = type(packageData) == "table" and type(packageData.route) == "table"
        and tostring(packageData.route.level or "another map") or "another map"
      return "share code is for map " .. level
    end
    return importErrorMessages[errorCode] or tostring(errorCode or "invalid data")
  end

  function manager.prepareClipboardImport(filename)
    if filename ~= importFilename then
      notify("Import rejected · invalid temporary source", 5)
      return false
    end
    notify("Validating Ghost share code…", 4)
    local packageData = jsonReadFile(filename)
    removeStoredFile(filename)

    local validPackage, packageError = codec.validatePackage(packageData)
    if not validPackage then
      notify("Import failed · " .. importErrorText(packageError, packageData), 6)
      return false
    end

    -- Sharing is for other players, who have no way of knowing which Saved
    -- Start the sender used. Adopt the route carried by the code instead of
    -- asking the recipient to reproduce it.
    local adopted, adoptError, createdStart, startName = adoptRoute(packageData.route)
    if not adopted then
      notify("Import failed · " .. importErrorText(adoptError, packageData), 6)
      return false
    end
    if createdStart then
      notify(string.format(
        "Saved Start \"%s\" created from the share code",
        tostring(startName or "Shared Start")
      ), 5)
    end
    if not playback.activeLibraryFilename then
      notify("Import failed · " .. importErrorText("noLibrary", packageData), 5)
      return false
    end

    local plan, errorCode = planImport(packageData)
    if not plan then
      notify("Import failed · " .. importErrorText(errorCode, packageData), 6)
      return false
    end

    if #plan.candidates == 0 then
      -- Report every reason rather than only the first, so a mixed package
      -- does not look like a pure duplicate.
      local reasons = {}
      if plan.duplicateCount > 0 then
        reasons[#reasons + 1] = plan.duplicateCount .. " already stored"
      end
      if plan.skippedSlow > 0 then
        reasons[#reasons + 1] = plan.skippedSlow .. " outside the current Top 20"
      end
      local details = #reasons > 0 and table.concat(reasons, " · ")
        or "no importable Ghosts"
      notify("Nothing imported · " .. details, 5)
      return false
    end

    if plan.replaceComplete > 0 or plan.replaceIncomplete > 0 or plan.replaceManual > 0 then
      plan.ui = {
        ghostCount = #plan.candidates,
        duplicateCount = plan.duplicateCount,
        skippedSlow = plan.skippedSlow,
        replaceComplete = plan.replaceComplete,
        replaceIncomplete = plan.replaceIncomplete,
        replaceManual = plan.replaceManual,
        sourceName = plan.sourceName,
        exporterVersion = plan.exporterVersion
      }
      playback.pendingImport = plan
      sendUiState()
      local replacements = {}
      if plan.replaceComplete > 0 then
        replacements[#replacements + 1] = plan.replaceComplete .. " slowest complete"
      end
      if plan.replaceIncomplete > 0 then
        replacements[#replacements + 1] = plan.replaceIncomplete .. " oldest incomplete"
      end
      if plan.replaceManual > 0 then
        replacements[#replacements + 1] = plan.replaceManual .. " oldest manual"
      end
      notify(string.format(
        "Import ready · %d Ghost%s · confirm replacing %s in the app",
        #plan.candidates,
        #plan.candidates == 1 and "" or "s",
        table.concat(replacements, " + ")
      ), 7)
      return true
    end
    return applyImport(plan)
  end

  function manager.confirmClipboardImport()
    if not playback.pendingImport then
      notify("No clipboard import is waiting for confirmation", 4)
      return false
    end
    notify("Importing confirmed Ghost recordings…", 4)
    return applyImport(playback.pendingImport)
  end

  function manager.cancelClipboardImport()
    if not playback.pendingImport then return false end
    playback.pendingImport = nil
    sendUiState()
    notify("Clipboard import cancelled · existing records kept", 4)
    return true
  end

  manager.activeRoute = activeRoute
  return manager
end

return M
