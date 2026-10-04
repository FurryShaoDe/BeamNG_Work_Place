-- LapLog -- Saved Start geometry, registry and library state.
--
-- Everything the route guide and the trail renderer used to own (route path,
-- checkpoints, best-lap line, live input trail buffer) was dropped along with
-- those renderers. What remains is the start gate itself plus the registry that
-- maps a map location to a stored lap library.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

function M.new()
  local state = {
    rayStartAbove = 1,
    rayLength = 20,
    forwardOffset = 5,
    registryFormat = 3,
    maxSavedStarts = 20,
    matchDistance = 8,
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
      position = {
        state.startLineX,
        state.startLineY,
        state.startLineZ
      },
      normal = {
        state.startLineNormalX,
        state.startLineNormalY,
        state.startLineNormalZ
      },
      currentFilename = state.currentFilename
    }
  end

  return state
end

return M
