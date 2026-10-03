-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned Time Trial discovery/fallback state for one GE extension.

local M = {}

function M.new()
  local state = {
    activeTimeTrialProfile = nil,
    missionStartFallback = {
      attempts = 0,
      delay = 0,
      profile = nil
    }
  }

  function state.snapshot()
    return {
      activeTimeTrialProfile = state.activeTimeTrialProfile,
      fallbackAttempts = state.missionStartFallback.attempts,
      fallbackDelay = state.missionStartFallback.delay,
      fallbackProfile = state.missionStartFallback.profile
    }
  end

  return state
end

return M
