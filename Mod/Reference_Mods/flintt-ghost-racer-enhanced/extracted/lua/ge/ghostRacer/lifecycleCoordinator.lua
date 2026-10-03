-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Atomic GE Race/Time Trial lifecycle transitions.

local M = {}

function M.new(options)
  options = options or {}
  local race = assert(options.race, "GE race state is required")
  local timeTrial = assert(options.timeTrial, "GE Time Trial state is required")
  local raceStartGrace = assert(options.raceStartGrace, "race start grace is required")
  local coordinator = {}

  function coordinator.clearFallback()
    timeTrial.missionStartFallback.attempts = 0
    timeTrial.missionStartFallback.delay = 0
    timeTrial.missionStartFallback.profile = nil
  end

  function coordinator.armFallback(profile, delay, attempts)
    timeTrial.missionStartFallback.profile = profile
    timeTrial.missionStartFallback.attempts = tonumber(attempts) or 40
    timeTrial.missionStartFallback.delay = tonumber(delay) or 0
  end

  function coordinator.markFallbackQueued()
    timeTrial.missionStartFallback.attempts = 0
  end

  function coordinator.beginQuickrace(files, profile, recoveredMidLap)
    race.raceFiles = files
    timeTrial.activeTimeTrialProfile = profile
    race.pbTime = files.persistent and files.pbTime or nil
    race.lastLapCount = 0
    race.quickraceLastCumulativeTime = 0
    race.quickraceLapCount = 0
    race.quickraceDiscardFirstFinish = recoveredMidLap == true
    race.quickraceRaceActive = true
    race.raceActive = true
    race.raceStartPending = false
    race.countdownActive = false
    race.countdownEndedGrace = 0
    coordinator.clearFallback()
  end

  function coordinator.beginRaceDiscovery()
    race.quickraceRaceActive = false
    race.quickraceDiscardFirstFinish = false
    timeTrial.missionStartFallback.attempts = 0
    timeTrial.missionStartFallback.profile = nil
  end

  function coordinator.prepareRace(files, profile)
    race.raceFiles = files
    timeTrial.activeTimeTrialProfile = profile
    race.pbTime = files.persistent and files.pbTime or nil
    race.lastLapCount = 0
    race.raceStartPending = true
    race.raceStartDelay = raceStartGrace
  end

  function coordinator.startPreparedRace()
    if not race.raceStartPending or race.raceActive then return false end
    race.raceStartPending = false
    race.raceStartDelay = 0
    race.raceActive = true
    return true
  end

  function coordinator.stopQuickraceActivity()
    race.quickraceRaceActive = false
    race.quickraceDiscardFirstFinish = false
    race.raceActive = false
    race.raceStartPending = false
  end

  function coordinator.finishQuickraceLap()
    race.quickraceRaceActive = false
    race.raceActive = false
  end

  function coordinator.finishQuickraceResult()
    race.quickraceRaceActive = false
    race.raceActive = false
    race.quickraceDiscardFirstFinish = false
  end

  function coordinator.startCountdown()
    local interruptedQuickrace = race.quickraceRaceActive == true
    if interruptedQuickrace then coordinator.stopQuickraceActivity() end
    race.countdownActive = true
    race.countdownEndedGrace = 0
    return interruptedQuickrace
  end

  function coordinator.endCountdown()
    race.countdownActive = false
    race.countdownEndedGrace = 1
    if race.raceFiles then race.raceFiles.awaitGo = false end
  end

  function coordinator.completeRace()
    race.raceActive = false
    race.raceStartPending = false
    race.countdownActive = false
    race.countdownEndedGrace = 0
  end

  function coordinator.finishModernRaceLap(continueRace)
    if continueRace ~= true then race.raceActive = false end
  end

  function coordinator.stopRace()
    race.raceActive = false
    race.raceStartPending = false
    race.raceStartDelay = 0
    race.countdownActive = false
    race.countdownEndedGrace = 0
    race.quickraceRaceActive = false
    race.quickraceLastCumulativeTime = 0
    race.quickraceLapCount = 0
    race.quickraceDiscardFirstFinish = false
  end

  function coordinator.clearRuntime()
    coordinator.stopRace()
    timeTrial.activeTimeTrialProfile = nil
    race.raceFiles = nil
    coordinator.clearFallback()
  end

  return coordinator
end

return M
