-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned GE UI/mod lifecycle state.

local M = {}

function M.new()
  local state = {
    modDeactivating = false,
    modCleanupComplete = false
  }

  function state.snapshot()
    return {
      modDeactivating = state.modDeactivating,
      cleanupComplete = state.modCleanupComplete
    }
  end

  return state
end

return M
