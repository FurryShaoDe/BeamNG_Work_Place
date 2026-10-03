-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned race lifecycle state for one Ghost Racer GE extension.

local M = {}

function M.new()
  local state = {
    pbTime = nil,
    lastLapCount = 0,
    raceActive = false,
    raceFiles = nil,
    countdownActive = false,
    raceStartPending = false,
    raceStartDelay = 0,
    countdownEndedGrace = 0,
    quickraceRaceActive = false,
    quickraceLastCumulativeTime = 0,
    quickraceLapCount = 0,
    quickraceDiscardFirstFinish = false
  }

  function state.snapshot()
    return {
      pbTime = state.pbTime,
      lastLapCount = state.lastLapCount,
      raceActive = state.raceActive,
      raceFiles = state.raceFiles,
      countdownActive = state.countdownActive,
      raceStartPending = state.raceStartPending,
      raceStartDelay = state.raceStartDelay,
      countdownEndedGrace = state.countdownEndedGrace,
      quickraceRaceActive = state.quickraceRaceActive,
      quickraceLastCumulativeTime = state.quickraceLastCumulativeTime,
      quickraceLapCount = state.quickraceLapCount,
      quickraceDiscardFirstFinish = state.quickraceDiscardFirstFinish
    }
  end

  return state
end

return M
