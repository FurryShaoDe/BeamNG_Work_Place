-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned Saved Start geometry, registry, and associated route state.

local M = {}

function M.new()
  local state = {
    rayStartAbove = 1,
    rayLength = 20,
    forwardOffset = 5,
    registryFormat = 3,
    maxSavedStarts = 20,
    matchDistance = 8,
    ghostStartHoldFrames = 0,
    routeGuideEnabled = true,
    routeAlignmentMode = "hybrid",
    routePathVisible = true,
    routeCheckpointsVisible = true,
    routeCheckpointSpacing = 200,
    routeActive = false,
    routeReady = false,
    routeDistance = 0,
    routeSourceId = nil,
    routeSourceLabel = nil,
    routePath = {},
    routeCheckpoints = {},
    -- 1-based index of the next checkpoint the live lap must still pass. Ordinals
    -- below it are already cleared; > #routeCheckpoints means the whole route was
    -- covered. Reset to 1 at the start of every lap.
    routeCheckpointNext = 1,
    bestLapLineVisible = false,
    bestLapLineReady = false,
    -- Optional parallel clutch sub-line drawn beside the best-lap racing line.
    clutchLineVisible = false,
    handbrakeLineVisible = false,
    -- Debug: live input-coloured trajectory drawn behind the driven vehicle. It
    -- captures the car's own pose + inputs into a rolling buffer whenever the
    -- toggle is on (independent of lap recording), so it shows while just driving.
    liveInputTrailVisible = false,
    liveInputTrailMaxSegments = 500,
    liveInputTrailAccumulator = 0,
    liveInputTrailCaptureAccumulator = 0,
    liveInputTrailTime = 0,
    liveInputTrailBuffer = {},
    bestLapLineSourceLabel = nil,
    preparedRaceProfile = nil,
    trailPlaybackElapsed = 0,
    ghostTrailLingering = false,
    savedMarkersVisible = true,
    uiOwnerToken = nil,
    diagnosticTraceId = nil,
    objectId = nil,
    importedLegacyGhosts = {},
    startLineSet = false,
    startLineLevel = "unknown",
    startLineX = 0,
    startLineY = 0,
    startLineZ = 0,
    startLineNormalX = 0,
    startLineNormalY = 1,
    startLineNormalZ = 0,
    previousPositionX = 0,
    previousPositionY = 0,
    previousPositionZ = 0,
    currentFilename = nil,
    preparedLoadFilename = nil,
    preparedSaveFilename = nil,
    registry = {
      formatVersion = 3,
      revision = 0,
      nextId = 1,
      activeId = nil,
      migratedVehicles = {},
      lines = {}
    }
  }

  function state.snapshot()
    return {
      activeId = state.registry.activeId,
      count = #state.registry.lines,
      lineSet = state.startLineSet,
      level = state.startLineLevel,
      position = {state.startLineX, state.startLineY, state.startLineZ},
      normal = {
        state.startLineNormalX,
        state.startLineNormalY,
        state.startLineNormalZ
      },
      currentFilename = state.currentFilename,
      routeReady = state.routeReady,
      routeDistance = state.routeDistance
    }
  end

  return state
end

return M
