-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned live playback state for one Ghost Racer controller.

local M = {}

function M.new(options)
  options = options or {}
  local state = {
    active = false,
    elapsed = 0,
    duration = 0,
    cursor = 1,
    progressCursor = 1,
    points = {},
    cameraEnabled = false,
    cameraMode = "chase",
    cameraTargetId = nil,
    cameraTargetLabel = nil,
    cameraCursor = 1,
    geCameraActive = false,
    ghosts = {},
    nextGhostId = 1,
    activeLibraryFilename = nil,
    pbTime = nil,
    pendingImport = nil
  }

  function state.snapshot()
    return {
      active = state.active,
      elapsed = state.elapsed,
      duration = state.duration,
      cursor = state.cursor,
      progressCursor = state.progressCursor,
      sampleCount = #state.points,
      ghostCount = #state.ghosts,
      nextGhostId = state.nextGhostId,
      activeLibraryFilename = state.activeLibraryFilename,
      pbTime = state.pbTime,
      importPending = state.pendingImport ~= nil,
      cameraEnabled = state.cameraEnabled,
      cameraMode = state.cameraMode,
      cameraTargetId = state.cameraTargetId,
      cameraTargetLabel = state.cameraTargetLabel,
      cameraCursor = state.cameraCursor,
      geCameraActive = state.geCameraActive
    }
  end

  function state.setPoints(points)
    assert(type(points) == "table", "playback points must be a table")
    state.points = points
    return points
  end

  function state.resetCursors(resetProgress)
    state.cursor = 1
    state.cameraCursor = 1
    if resetProgress ~= false then state.progressCursor = 1 end
  end

  function state.resetClock()
    state.active = false
    state.elapsed = 0
    state.duration = 0
    state.resetCursors()
  end

  function state.setCameraMode(mode)
    mode = tostring(mode or "")
    if mode ~= "chase" and mode ~= "onboard" then return false end
    state.cameraMode = mode
    return true
  end

  function state.setCameraTarget(id, label)
    state.cameraTargetId = id ~= nil and tostring(id) or nil
    state.cameraTargetLabel = label ~= nil and tostring(label) or nil
    state.cameraCursor = 1
  end

  function state.disableCamera()
    local wasEnabled = state.cameraEnabled or state.geCameraActive
    state.cameraEnabled = false
    state.cameraCursor = 1
    return wasEnabled
  end

  return state
end

return M
