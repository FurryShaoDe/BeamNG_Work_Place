-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- UI-state projection for the Ghost Racer vehicle controller.

local M = {}

function M.new(options)
  options = options or {}
  local builder = {}
  local startGateConfig = assert(options.state, "controller state is required")
  local getRuntime = assert(options.getRuntime, "runtime getter is required")
  local findProgressSample = assert(
    options.findProgressSample,
    "progress matcher is required"
  )
  local getCurrentSpeed = assert(options.getCurrentSpeed, "speed getter is required")
  local sanitizedVehicle = assert(options.vehicle, "vehicle identity is required")
  local CODE_VERSION = assert(options.codeVersion, "code version is required")
  local AUTO_LINE_HALF_WIDTH = assert(options.startLineHalfWidth, "line width is required")
  local MAX_STORED_GHOSTS = assert(options.maxStoredGhosts, "storage limit is required")
  local MAX_STORED_INCOMPLETE_GHOSTS = assert(
    options.maxStoredIncompleteGhosts,
    "incomplete storage limit is required"
  )
  local MAX_STORED_MANUAL_GHOSTS = assert(
    options.maxStoredManualGhosts,
    "manual storage limit is required"
  )
  local clamp = assert(options.clamp, "clamp is required")
  local indexes = assert(options.indexes, "sample indexes are required")
  local TIME, SPEED = indexes.time, indexes.speed

  function builder.build()
      local runtime = getRuntime()
    local matchedPoint = findProgressSample()
    local currentSpeed = getCurrentSpeed()
    local timeDelta
    local speedDelta
    local ghostUi = {}
    local savedStartUi = {}
    local displayedGhostCount = 0
    local completeGhostCount = 0
    local incompleteGhostCount = 0
    local manualGhostCount = 0
    local cameraTarget = runtime.playing and startGateConfig.resolveGhostCameraTarget() or nil

    for index = 1, #runtime.ghostLibrary do
      local entry = runtime.ghostLibrary[index]
      local incomplete = entry.complete == false
      local manual = not incomplete and startGateConfig.ghostIsManual ~= nil
        and startGateConfig.ghostIsManual(entry) or false
      if incomplete then
        incompleteGhostCount = incompleteGhostCount + 1
      elseif manual then
        manualGhostCount = manualGhostCount + 1
      else
        completeGhostCount = completeGhostCount + 1
      end
      if entry.displayed then displayedGhostCount = displayedGhostCount + 1 end
      ghostUi[#ghostUi + 1] = {
        id = entry.id,
        label = entry.label,
        lapTime = entry.lapTime,
        duration = entry.duration,
        source = entry.source,
        complete = not incomplete,
        incomplete = incomplete,
        manual = manual,
        incompleteReason = entry.incompleteReason,
        vehicle = entry.vehicle or "unknown_vehicle",
        color = entry.colorName,
        selected = entry.selected == true,
        pinned = entry.pinned == true,
        hasInputs = entry.hasInputs == true,
        displayed = entry.displayed == true,
        cameraTarget = cameraTarget and entry.id == cameraTarget.id or false,
        isBest = entry.isBest == true,
        displayRank = entry.displayRank,
        trailBrightnessTier = entry.trailBrightnessTier
      }
    end

    for index = 1, #startGateConfig.registry.lines do
      local line = startGateConfig.registry.lines[index]
      savedStartUi[#savedStartUi + 1] = {
        id = line.id,
        name = line.name,
        userNamed = line.userNamed == true,
        startKey = line.startKey or line.id,
        kind = line.kind,
        activitySource = line.activitySource,
        ghostCount = tonumber(line.ghostCount) or 0,
        incompleteGhostCount = tonumber(line.incompleteGhostCount) or 0,
        pbTime = tonumber(line.pbTime),
        active = line.id == startGateConfig.registry.activeId
      }
    end

    local activeStart = startGateConfig.activeEntry()

    if not runtime.autoLapDeltaSuppressed then
      -- Prefer the live standings delta, which is measured against the best
      -- reference on track including incomplete attempts. Fall back to the
      -- single-ghost match only when no on-track leader was resolved.
      if type(runtime.liveDelta) == "number" then
        timeDelta = runtime.liveDelta
        if type(runtime.liveSpeedDelta) == "number" then
          speedDelta = runtime.liveSpeedDelta
        end
      elseif matchedPoint then
        timeDelta = runtime.recordElapsed - matchedPoint[TIME]
        if matchedPoint[SPEED] and matchedPoint[SPEED] > 0 then
          speedDelta = (currentSpeed - matchedPoint[SPEED]) * 3.6
        end
      end
    end

    local status = "idle"
    if runtime.autoLapDeltaSuppressed and runtime.recording then
      status = "missed"
    elseif runtime.recording and runtime.playing then
      status = "racing"
    elseif runtime.recording then
      status = "recording"
    elseif runtime.playing then
      status = "playing"
    elseif runtime.autoLapEnabled then
      status = "armed"
    elseif #runtime.ghostLibrary > 0 or #runtime.playbackPoints > 0 or #runtime.lastRecording > 0 then
      status = "ready"
    end

    return {
      codeVersion = CODE_VERSION,
      uiOwnerToken = startGateConfig.uiOwnerToken,
      diagnosticTraceId = startGateConfig.diagnosticTraceId,
      registryRevision = tonumber(startGateConfig.registry.revision) or 0,
      vehicle = sanitizedVehicle,
      status = status,
      message = runtime.lastMessage,
      recording = runtime.recording,
      playing = runtime.playing,
      visible = runtime.visible,
      loopPlayback = runtime.loopPlayback,
      raceMode = runtime.raceMode,
      autoLapEnabled = runtime.autoLapEnabled,
      autoLapActive = runtime.autoLapActive,
      startLineSet = runtime.startLineSet,
      finishLineSet = runtime.finishLineSet == true,
      pointToPoint = runtime.finishLineSet == true,
      activeStartLineId = startGateConfig.registry.activeId,
      startLineName = activeStart and activeStart.name or nil,
      startLineKind = activeStart and activeStart.kind or nil,
      startIdentitySource = activeStart and activeStart.activitySource or nil,
      savedStartLines = savedStartUi,
      savedStartMarkersVisible = startGateConfig.savedMarkersVisible,
      startGateVisible = runtime.startGateVisible,
      ghostTrailVisible = runtime.ghostTrailVisible,
      ghostTrailMode = runtime.ghostTrailMode,
      ghostTrailSeconds = runtime.ghostTrailSeconds,
      routeGuideEnabled = startGateConfig.routeGuideEnabled,
      routeAlignmentMode = startGateConfig.routeAlignmentMode,
      routePathVisible = startGateConfig.routePathVisible,
      routeCheckpointsVisible = startGateConfig.routeCheckpointsVisible,
      routeCheckpointSpacing = startGateConfig.routeCheckpointSpacing,
      routeGuideActive = startGateConfig.routeActive,
      routeGuideReady = startGateConfig.routeReady,
      routeDistance = startGateConfig.routeDistance,
      routePointCount = #startGateConfig.routePath,
      routeCheckpointCount = #startGateConfig.routeCheckpoints,
      routeSourceLabel = startGateConfig.routeSourceLabel,
      bestLapLineVisible = startGateConfig.bestLapLineVisible,
      bestLapLineReady = startGateConfig.bestLapLineReady,
      bestLapLineSourceLabel = startGateConfig.bestLapLineSourceLabel,
      autoLapNumber = runtime.autoLapNumber,
      lastLapTime = runtime.lastLapTime,
      lastLapRank = runtime.lastLapRank,
      lastLapRecordCount = runtime.lastLapRecordCount,
      lastLapStored = runtime.lastLapStored,
      autoLapLineDistance = runtime.autoLapLineDistance,
      autoLapLateralDistance = runtime.autoLapLateralDistance,
      autoLapGateState = runtime.autoLapGateState,
      autoLapLastReject = runtime.autoLapLastReject,
      autoLapCrossingArmed = runtime.autoLapCrossingArmed,
      autoLapDeltaSuppressed = runtime.autoLapDeltaSuppressed,
      startLineHalfWidth = AUTO_LINE_HALF_WIDTH,
      hasRecording = #runtime.ghostLibrary > 0 or #runtime.playbackPoints > 0 or #runtime.lastRecording > 0,
      sampleCount = runtime.recording and #runtime.recordPoints or math.max(#runtime.lastRecording, #runtime.playbackPoints),
      sampleRate = runtime.sampleRate,
      quality = runtime.currentQuality,
      color = runtime.currentColorName,
      ghostDisplayMode = runtime.ghostDisplayMode,
      topGhostCount = runtime.topGhostCount,
      showIncomplete = runtime.showIncomplete,
      ghostCategoryFilter = runtime.ghostCategoryFilter or "complete",
      showManual = runtime.showManual ~= false,
      ghostRenderMode = runtime.ghostRenderMode or "wireframe",
      ghostShellActive = runtime.ghostShellActive == true,
      ghostShellConfirmed = runtime.ghostShellConfirmed == true,
      ghostShellUnavailableReason = runtime.ghostShellUnavailableReason,
      manualGhostCount = manualGhostCount,
      ghostCount = completeGhostCount + (runtime.showIncomplete and incompleteGhostCount or 0),
      totalGhostCount = #ghostUi,
      completeGhostCount = completeGhostCount,
      incompleteGhostCount = incompleteGhostCount,
      displayedGhostCount = displayedGhostCount,
      ghostCameraEnabled = runtime.ghostCameraEnabled,
      ghostCameraMode = runtime.ghostCameraMode,
      ghostCameraTargetId = runtime.ghostCameraTargetId,
      ghostCameraTargetLabel = runtime.ghostCameraTargetLabel,
      ghostCameraAvailable = cameraTarget ~= nil,
      maxStoredGhosts = MAX_STORED_GHOSTS,
      maxStoredIncompleteGhosts = MAX_STORED_INCOMPLETE_GHOSTS,
      maxStoredManualGhosts = MAX_STORED_MANUAL_GHOSTS,
      importPending = runtime.pendingImport ~= nil,
      importPendingSummary = runtime.pendingImport,
      ghosts = ghostUi,
      elapsed = runtime.recording and runtime.recordElapsed or runtime.playbackElapsed,
      duration = runtime.playbackDuration,
      progress = runtime.playbackDuration > 0 and clamp(runtime.playbackElapsed / runtime.playbackDuration, 0, 1) or 0,
      playbackElapsed = runtime.playbackElapsed,
      pbTime = runtime.currentPbTime,
      timeDelta = timeDelta,
      speedDelta = speedDelta,
      liveRank = runtime.liveRank,
      liveRankTotal = runtime.liveRankTotal,
      currentSpeed = currentSpeed * 3.6
    }
  end


  return builder
end

return M
