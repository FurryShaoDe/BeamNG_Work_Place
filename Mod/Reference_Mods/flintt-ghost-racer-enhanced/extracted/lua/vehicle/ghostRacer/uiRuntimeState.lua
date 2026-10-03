-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned HUD/presentation bridge state for one vehicle controller.

local M = {}

function M.new(options)
  options = options or {}
  local state = {
    uiAccumulator = 0,
    trailSyncAccumulator = tonumber(options.initialTrailSyncAccumulator) or 0,
    geTrailVisible = false,
    lastMessage = "Ready",
    snapshotBuilder = nil
  }

  function state.setSnapshotBuilder(builder)
    assert(type(builder) == "function", "UI snapshot builder is required")
    state.snapshotBuilder = builder
  end

  function state.snapshot()
    if state.snapshotBuilder then return state.snapshotBuilder() end
    return {
      uiAccumulator = state.uiAccumulator,
      trailSyncAccumulator = state.trailSyncAccumulator,
      geTrailVisible = state.geTrailVisible,
      lastMessage = state.lastMessage
    }
  end

  return state
end

return M
