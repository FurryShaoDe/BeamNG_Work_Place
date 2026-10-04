-- LapLog -- UI-state projection for the vehicle controller.
--
-- The upstream projection carried roughly 95 top-level fields, most of them
-- describing how a Ghost should be drawn (render mode, trail seconds, shell
-- availability, camera target, live rank, time/speed deltas, route guide state).
-- With the renderer gone none of that has a consumer, so this projects only what
-- the LapLog panel actually reads.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

function M.new(options)
  options = options or {}
  local builder = {}
  local startGateConfig = assert(options.state, "controller state is required")
  local getRuntime = assert(options.getRuntime, "runtime getter is required")
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

  local function lapRow(entry, incomplete, manual)
    return {
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
      pinned = entry.pinned == true,
      hasInputs = entry.hasInputs == true,
      hasChassis = entry.hasChassis == true,
      displayed = entry.displayed == true,
      isBest = entry.isBest == true,
      displayRank = entry.displayRank
    }
  end

  local function startRow(line)
    return {
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

  function builder.build()
    local runtime = getRuntime()
    local lapUi = {}
    local savedStartUi = {}
    local completeLapCount = 0
    local incompleteLapCount = 0
    local manualLapCount = 0
    local displayedLapCount = 0

    for index = 1, #runtime.ghostLibrary do
      local entry = runtime.ghostLibrary[index]
      local incomplete = entry.complete == false
      local manual = not incomplete
        and startGateConfig.ghostIsManual ~= nil
        and startGateConfig.ghostIsManual(entry) or false
      if incomplete then
        incompleteLapCount = incompleteLapCount + 1
      elseif manual then
        manualLapCount = manualLapCount + 1
      else
        completeLapCount = completeLapCount + 1
      end
      if entry.displayed then displayedLapCount = displayedLapCount + 1 end
      lapUi[#lapUi + 1] = lapRow(entry, incomplete, manual)
    end

    for index = 1, #startGateConfig.registry.lines do
      savedStartUi[#savedStartUi + 1] = startRow(startGateConfig.registry.lines[index])
    end

    local activeStart = startGateConfig.activeEntry()

    local status = "idle"
    if runtime.recording and runtime.autoLapDeltaSuppressed then
      status = "missed"
    elseif runtime.recording then
      status = "recording"
    elseif runtime.autoLapEnabled then
      status = "armed"
    elseif #runtime.ghostLibrary > 0 or #runtime.lastRecording > 0 then
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
      autoLapEnabled = runtime.autoLapEnabled,
      autoLapActive = runtime.autoLapActive,
      autoLapNumber = runtime.autoLapNumber,
      lastLapTime = runtime.lastLapTime,
      lastLapStored = runtime.lastLapStored,
      autoLapGateState = runtime.autoLapGateState,
      autoLapLastReject = runtime.autoLapLastReject,
      startLineSet = runtime.startLineSet,
      finishLineSet = runtime.finishLineSet == true,
      startLineHalfWidth = AUTO_LINE_HALF_WIDTH,
      startLineName = activeStart and activeStart.name or nil,
      startLineKind = activeStart and activeStart.kind or nil,
      activeStartLineId = startGateConfig.registry.activeId,
      savedStartLines = savedStartUi,
      savedStartMarkersVisible = startGateConfig.savedMarkersVisible,
      startGateVisible = runtime.startGateVisible,
      sampleRate = runtime.sampleRate,
      sampleCount = runtime.recording and #runtime.recordPoints
        or math.max(#runtime.lastRecording, #runtime.playbackPoints),
      hasRecording = #runtime.ghostLibrary > 0
        or #runtime.playbackPoints > 0
        or #runtime.lastRecording > 0,
      showIncomplete = runtime.showIncomplete,
      ghostCategoryFilter = runtime.ghostCategoryFilter or "complete",
      showManual = runtime.showManual ~= false,
      ghosts = lapUi,
      ghostCount = completeLapCount + (runtime.showIncomplete and incompleteLapCount or 0),
      totalGhostCount = #lapUi,
      completeGhostCount = completeLapCount,
      incompleteGhostCount = incompleteLapCount,
      manualGhostCount = manualLapCount,
      displayedGhostCount = displayedLapCount,
      maxStoredGhosts = MAX_STORED_GHOSTS,
      maxStoredIncompleteGhosts = MAX_STORED_INCOMPLETE_GHOSTS,
      maxStoredManualGhosts = MAX_STORED_MANUAL_GHOSTS,
      pbTime = runtime.currentPbTime,
      elapsed = runtime.recordElapsed or 0,
      referenceDuration = runtime.referenceDuration or 0,
      currentSpeed = getCurrentSpeed() * 3.6
    }
  end

  return builder
end

return M
