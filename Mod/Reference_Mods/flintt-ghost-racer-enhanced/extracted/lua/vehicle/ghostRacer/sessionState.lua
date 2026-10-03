-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned lap-session state for one Ghost Racer controller.

local M = {}

function M.new()
  local state = {
    raceMode = false,
    racePrepared = false,
    autoLapEnabled = false,
    autoLapActive = false,
    autoLapCooldown = 0,
    autoLapNumber = 0,
    lastLapTime = nil,
    lastLapRank = nil,
    lastLapRecordCount = nil,
    lastLapStored = nil,
    autoLapLineDistance = 0,
    autoLapLateralDistance = 0,
    autoLapGateState = "off",
    autoLapLastReject = nil,
    autoLapCrossingArmed = false,
    autoLapApproachValid = false,
    autoLapApproachX = 0,
    autoLapApproachY = 0,
    autoLapApproachZ = 0,
    autoLapApproachSigned = 0,
    autoLapDeltaSuppressed = false,
    reanchorFirstLapAtGate = false
  }

  function state.snapshot()
    return {
      raceMode = state.raceMode,
      racePrepared = state.racePrepared,
      autoLapEnabled = state.autoLapEnabled,
      autoLapActive = state.autoLapActive,
      autoLapCooldown = state.autoLapCooldown,
      autoLapNumber = state.autoLapNumber,
      lastLapTime = state.lastLapTime,
      lastLapRank = state.lastLapRank,
      lastLapRecordCount = state.lastLapRecordCount,
      lastLapStored = state.lastLapStored,
      autoLapLineDistance = state.autoLapLineDistance,
      autoLapLateralDistance = state.autoLapLateralDistance,
      autoLapGateState = state.autoLapGateState,
      autoLapLastReject = state.autoLapLastReject,
      autoLapCrossingArmed = state.autoLapCrossingArmed,
      autoLapApproachValid = state.autoLapApproachValid,
      autoLapApproachX = state.autoLapApproachX,
      autoLapApproachY = state.autoLapApproachY,
      autoLapApproachZ = state.autoLapApproachZ,
      autoLapApproachSigned = state.autoLapApproachSigned,
      autoLapDeltaSuppressed = state.autoLapDeltaSuppressed,
      reanchorFirstLapAtGate = state.reanchorFirstLapAtGate
    }
  end

  function state.clearLastLapResult()
    state.lastLapTime = nil
    state.lastLapRank = nil
    state.lastLapRecordCount = nil
    state.lastLapStored = nil
  end

  function state.resetCrossing()
    state.autoLapCrossingArmed = false
    state.autoLapApproachValid = false
    state.autoLapApproachSigned = 0
  end

  function state.armCrossing(x, y, z, signedDistance)
    state.autoLapCrossingArmed = true
    state.autoLapApproachValid = true
    state.autoLapApproachX = x
    state.autoLapApproachY = y
    state.autoLapApproachZ = z
    state.autoLapApproachSigned = signedDistance
  end

  return state
end

return M
