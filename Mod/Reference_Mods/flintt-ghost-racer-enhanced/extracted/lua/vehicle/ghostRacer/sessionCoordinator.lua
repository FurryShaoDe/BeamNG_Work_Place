-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Atomic lap-session transitions across context-owned state domains.

local M = {}

function M.new(options)
  options = options or {}
  local session = assert(options.session, "session state is required")
  local recording = assert(options.recording, "recording state is required")
  local playback = assert(options.playback, "playback state is required")
  local acceptedCrossingCooldown = assert(
    options.acceptedCrossingCooldown,
    "accepted crossing cooldown is required"
  )

  local coordinator = {}

  function coordinator.stopRecordingAndPlayback()
    recording.active = false
    playback.active = false
  end

  function coordinator.resetCrossing()
    session.resetCrossing()
  end

  function coordinator.armCrossing(x, y, z, signedDistance)
    session.armCrossing(x, y, z, signedDistance)
  end

  function coordinator.activateSavedStart()
    session.autoLapEnabled = false
    session.autoLapActive = false
    session.autoLapNumber = 0
    session.autoLapCooldown = 0
    session.clearLastLapResult()
    session.autoLapLineDistance = 0
    session.autoLapLateralDistance = 0
    session.autoLapGateState = "lineReady"
    session.autoLapLastReject = nil
    session.autoLapDeltaSuppressed = false
    session.reanchorFirstLapAtGate = false
    session.resetCrossing()
  end

  function coordinator.bindRaceControlledStart()
    session.autoLapEnabled = false
    session.autoLapActive = false
    session.autoLapGateState = "raceControlled"
  end

  function coordinator.configureAutoLap(enabled)
    session.autoLapEnabled = enabled == true
    session.autoLapActive = false
    session.autoLapNumber = 0
    session.autoLapCooldown = 0
    session.clearLastLapResult()
    session.autoLapLastReject = nil
    session.autoLapDeltaSuppressed = false
    session.reanchorFirstLapAtGate = false
    session.resetCrossing()
  end

  function coordinator.beginPlacedAutoLap()
    session.autoLapEnabled = true
    session.autoLapActive = true
    session.autoLapNumber = 1
    session.autoLapCooldown = 0
    session.reanchorFirstLapAtGate = true
    session.clearLastLapResult()
    session.autoLapLastReject = nil
    session.autoLapDeltaSuppressed = false
    session.resetCrossing()
    session.autoLapGateState = "lapStarted"
  end

  function coordinator.clearStart()
    session.autoLapEnabled = false
    session.autoLapActive = false
    session.autoLapNumber = 0
    session.clearLastLapResult()
    session.autoLapGateState = "off"
    session.autoLapLastReject = nil
    session.autoLapDeltaSuppressed = false
    session.reanchorFirstLapAtGate = false
    session.resetCrossing()
  end

  function coordinator.rejectCrossing(reason)
    -- Once a forward crossing invalidates the active attempt, a later reverse
    -- pass while returning to the gate must not erase the reason archived with
    -- that incomplete recording.
    if not (reason == "wrongDirection" and session.autoLapDeltaSuppressed) then
      session.autoLapLastReject = reason
    end
    if reason ~= "wrongDirection" and session.autoLapActive and recording.active then
      session.autoLapDeltaSuppressed = true
    end
    session.autoLapGateState = "missed"
  end

  function coordinator.acceptCrossing()
    session.autoLapCooldown = acceptedCrossingCooldown
    session.autoLapLastReject = nil
    session.resetCrossing()

    if session.reanchorFirstLapAtGate then
      session.reanchorFirstLapAtGate = false
      return "reanchor"
    end
    if not session.autoLapActive then return "start" end
    if session.autoLapDeltaSuppressed then return "discard" end
    if not recording.active then return "ignore" end
    return "finish"
  end

  function coordinator.beginGateLap(action)
    if action == "discard" then
      session.autoLapDeltaSuppressed = false
      session.autoLapNumber = math.max(1, session.autoLapNumber + 1)
    else
      assert(action == "start" or action == "reanchor", "unsupported gate-lap action")
      session.autoLapActive = true
      session.autoLapNumber = 1
      session.autoLapDeltaSuppressed = false
    end
    session.autoLapGateState = "lapStarted"
    return session.autoLapNumber
  end

  function coordinator.beginLapCompletion(lapTime)
    local completedLap = session.autoLapNumber
    session.lastLapTime = lapTime
    return completedLap
  end

  function coordinator.setLastLapPlacement(rank, recordCount, stored)
    session.lastLapRank = rank
    session.lastLapRecordCount = recordCount
    session.lastLapStored = stored
  end

  function coordinator.advanceAutoLap()
    session.autoLapNumber = session.autoLapNumber + 1
    session.autoLapGateState = "lapStarted"
    return session.autoLapNumber
  end

  -- Point-to-point: a run ends at the finish gate rather than looping back to the
  -- start, so the lap goes inactive and the next start-gate crossing begins a
  -- fresh run instead of being read as a finish.
  function coordinator.endPointToPointLap()
    session.autoLapActive = false
    session.autoLapDeltaSuppressed = false
    session.autoLapGateState = "finished"
    return session.autoLapNumber
  end

  function coordinator.prepareRace()
    session.autoLapEnabled = false
    session.autoLapActive = false
    session.raceMode = true
    session.autoLapDeltaSuppressed = false
    session.autoLapLastReject = nil
    session.reanchorFirstLapAtGate = false
    session.resetCrossing()
    session.clearLastLapResult()
    session.racePrepared = true
  end

  function coordinator.markRaceStarted()
    session.racePrepared = false
  end

  function coordinator.completeRace()
    session.raceMode = false
    session.racePrepared = false
  end

  function coordinator.clearRecordingSession()
    session.raceMode = false
    session.autoLapActive = false
    session.autoLapNumber = 0
    session.autoLapDeltaSuppressed = false
    session.autoLapLastReject = nil
    session.reanchorFirstLapAtGate = false
    session.resetCrossing()
    session.clearLastLapResult()
  end

  function coordinator.softReset()
    session.autoLapActive = false
    session.autoLapNumber = 0
    session.autoLapCooldown = 1
    session.autoLapDeltaSuppressed = false
    session.autoLapLastReject = nil
    session.reanchorFirstLapAtGate = false
    session.resetCrossing()
  end

  return coordinator
end

return M
