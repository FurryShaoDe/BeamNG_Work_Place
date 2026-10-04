-- LapLog -- HUD/presentation bridge state for one vehicle controller.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

function M.new()
  local state = {
    uiAccumulator = 0,
    lastMessage = "就绪",
    snapshotBuilder = nil
  }

  function state.setSnapshotBuilder(builder)
    if type(builder) ~= "function" then return false end
    state.snapshotBuilder = builder
    return true
  end

  function state.snapshot()
    if state.snapshotBuilder then return state.snapshotBuilder() end
    return {
      uiAccumulator = state.uiAccumulator,
      lastMessage = state.lastMessage
    }
  end

  return state
end

return M
