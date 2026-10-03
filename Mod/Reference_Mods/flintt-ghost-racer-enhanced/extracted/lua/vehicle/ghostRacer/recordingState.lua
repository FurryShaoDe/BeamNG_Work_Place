-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned live recording state for one Ghost Racer controller.

local M = {}

function M.new(options)
  options = options or {}
  local defaultSampleRate = assert(options.defaultSampleRate, "default sample rate is required")
  local minimumSampleRate = assert(options.minimumSampleRate, "minimum sample rate is required")
  local maximumSampleRate = assert(options.maximumSampleRate, "maximum sample rate is required")
  local maximumRecordingSeconds = assert(
    options.maximumRecordingSeconds,
    "maximum recording duration is required"
  )
  local defaultInterval = 1 / defaultSampleRate
  local state = {
    active = false,
    elapsed = 0,
    accumulator = 0,
    sampleRate = defaultSampleRate,
    sampleInterval = defaultInterval,
    activeSampleInterval = defaultInterval,
    maxSamples = math.floor(maximumRecordingSeconds / defaultInterval) + 1,
    points = {},
    lastRecording = {},
    groundOffset = 0
  }

  local function updateMaximumSamples()
    state.maxSamples = math.floor(
      maximumRecordingSeconds / state.activeSampleInterval
    ) + 1
  end

  function state.snapshot()
    return {
      active = state.active,
      elapsed = state.elapsed,
      accumulator = state.accumulator,
      sampleRate = state.sampleRate,
      sampleInterval = state.activeSampleInterval,
      sampleCount = #state.points,
      lastSampleCount = #state.lastRecording,
      maxSamples = state.maxSamples,
      groundOffset = state.groundOffset
    }
  end

  function state.setPoints(points)
    assert(type(points) == "table", "recording points must be a table")
    state.points = points
    return points
  end

  function state.setSampleRate(value)
    local requested = math.floor(tonumber(value) or defaultSampleRate)
    state.sampleRate = math.max(minimumSampleRate, math.min(maximumSampleRate, requested))
    state.sampleInterval = 1 / state.sampleRate
    if not state.active then
      state.activeSampleInterval = state.sampleInterval
      updateMaximumSamples()
    end
    return state.sampleRate
  end

  function state.begin(groundOffset)
    state.points = {}
    state.activeSampleInterval = state.sampleInterval
    updateMaximumSamples()
    state.elapsed = 0
    state.accumulator = 0
    state.groundOffset = tonumber(groundOffset) or 0
    state.active = true
    return state.points
  end

  function state.finish()
    if not state.active then return false end
    state.active = false
    state.lastRecording = state.points
    return state.lastRecording
  end

  function state.reset(clearLastRecording)
    state.active = false
    state.elapsed = 0
    state.accumulator = 0
    state.points = {}
    if clearLastRecording == true then state.lastRecording = {} end
  end

  return state
end

return M
