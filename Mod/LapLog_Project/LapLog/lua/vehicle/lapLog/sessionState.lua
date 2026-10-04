-- LapLog -- lap-session state for one vehicle controller.
--
-- Race integration was removed with the rest of the racing code, so there is no
-- raceMode/racePrepared here any more. autoLapDeltaSuppressed survives on purpose:
-- it is what makes a forward crossing that was already rejected invalidate the
-- lap, which is a property of the start gate, not of Ghost comparison.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

function M.new()
  local state = {
    autoLapEnabled = false,
    autoLapActive = false,
    autoLapCooldown = 0,
    autoLapNumber = 0,
    lastLapTime = nil,
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
    autoLapDeltaSuppressed = false
  }

  function state.snapshot()
    return {
      autoLapEnabled = state.autoLapEnabled,
      autoLapActive = state.autoLapActive,
      autoLapCooldown = state.autoLapCooldown,
      autoLapNumber = state.autoLapNumber,
      lastLapTime = state.lastLapTime,
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
      autoLapDeltaSuppressed = state.autoLapDeltaSuppressed
    }
  end

  function state.clearLastLapResult()
    state.lastLapTime = nil
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
