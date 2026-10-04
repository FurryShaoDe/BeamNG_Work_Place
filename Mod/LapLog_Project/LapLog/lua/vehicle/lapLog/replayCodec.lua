-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- LapLog, derived from Ghost Racer Replay (Jesus Goose) and Ghost Racer
-- Enhanced (flintt). See NOTICE.md for the full attribution chain.

-- Stateless replay serialization helpers for the Ghost Racer vehicle VM.

local M = {}

function M.new(options)
  options = options or {}
  local formatVersion = assert(options.formatVersion, "formatVersion is required")
  local indexes = assert(options.indexes, "sample indexes are required")
  local vectorFactory = assert(options.vectorFactory, "vectorFactory is required")

  local TIME = indexes.time
  local POS_X, POS_Y, POS_Z = indexes.posX, indexes.posY, indexes.posZ
  local FRONT_X, FRONT_Y, FRONT_Z = indexes.frontX, indexes.frontY, indexes.frontZ
  local UP_X, UP_Y, UP_Z = indexes.upX, indexes.upY, indexes.upZ
  local SPEED = indexes.speed
  -- Optional driver inputs (2.18+). Absent in older layouts.
  local THROTTLE, BRAKE = indexes.throttle, indexes.brake
  local GEAR, HANDBRAKE, CLUTCH = indexes.gear, indexes.handbrake, indexes.clutch
  -- Optional chassis telemetry (LapLog format 4). Per-wheel vertical load in
  -- newtons in a fixed front-left, front-right, rear-left, rear-right order; a
  -- wheel that does not exist records 0, so a reader can label the corners
  -- without knowing the vehicle. Body roll and pitch follow, in radians, exactly
  -- as obj:getRollPitchYaw() reports them. Absent in older layouts.
  local LOAD_FL, LOAD_FR = indexes.loadFL, indexes.loadFR
  local LOAD_RL, LOAD_RR = indexes.loadRL, indexes.loadRR
  local ROLL, PITCH = indexes.roll, indexes.pitch

  local function quantizePedal(value)
    value = tonumber(value)
    if value == nil then return nil end
    if value < 0 then value = 0 elseif value > 1 then value = 1 end
    -- Two decimals is ample for colour and keeps the samples compact.
    return math.floor(value * 100 + 0.5) / 100
  end

  -- Whole newtons: a road car corner carries a few kN, so 1 N resolution is far
  -- beyond what the loading needs while keeping the sample short.
  local function quantizeNewton(value)
    value = tonumber(value) or 0
    if value < 0 then return -math.floor(-value + 0.5) end
    return math.floor(value + 0.5)
  end

  -- Three decimals of a radian (about 0.06 degrees) is plenty for a roll/pitch
  -- curve and keeps the value to a few characters.
  local function quantizeRadians(value)
    value = tonumber(value) or 0
    if value < 0 then return -math.floor(-value * 1000 + 0.5) / 1000 end
    return math.floor(value * 1000 + 0.5) / 1000
  end

  local codec = {}

  local function pointTime(point, fallbackIndex, interval)
    return tonumber(point and point[TIME]) or ((fallbackIndex - 1) * interval)
  end

  local function normalizeOldPoint(point, index, interval)
    local pos = vectorFactory(point.pos)
    local front = vectorFactory(point.dirFront)
    local up = vectorFactory(point.dirUp)
    return {
      (index - 1) * interval,
      pos.x, pos.y, pos.z,
      front.x, front.y, front.z,
      up.x, up.y, up.z,
      tonumber(point.speed) or 0
    }
  end

  -- `chassis` is the optional format-4 block
  -- {loadFL=, loadFR=, loadRL=, loadRR=, roll=, pitch=}. It is absent when the
  -- caller has no suspension data, which keeps the sample at the previous length
  -- so nothing else has to care about the added columns.
  function codec.captureSample(vehicleObject, timestamp, throttle, brake, gear, handbrake, clutch, chassis)
    local px, py, pz = vehicleObject:getPositionXYZ()
    local front = vehicleObject:getDirectionVector()
    local up = vehicleObject:getDirectionVectorUp()
    local velocity = vehicleObject:getVelocity()
    local sample = {
      timestamp,
      px, py, pz,
      front.x, front.y, front.z,
      up.x, up.y, up.z,
      velocity:length()
    }
    -- Only extend the sample when the input indexes are configured and at least
    -- one input is available, so a context without electrics records old-format
    -- (length-11) samples. Gear and handbrake ride along with the pedals.
    if THROTTLE and BRAKE and (throttle ~= nil or brake ~= nil) then
      sample[THROTTLE] = quantizePedal(throttle) or 0
      sample[BRAKE] = quantizePedal(brake) or 0
      if GEAR then sample[GEAR] = math.floor(tonumber(gear) or 0) end
      if HANDBRAKE then sample[HANDBRAKE] = quantizePedal(handbrake) or 0 end
      if CLUTCH then sample[CLUTCH] = quantizePedal(clutch) or 0 end
    end
    if LOAD_FL and chassis then
      sample[LOAD_FL] = quantizeNewton(chassis.loadFL)
      sample[LOAD_FR] = quantizeNewton(chassis.loadFR)
      sample[LOAD_RL] = quantizeNewton(chassis.loadRL)
      sample[LOAD_RR] = quantizeNewton(chassis.loadRR)
      if ROLL and PITCH then
        sample[ROLL] = quantizeRadians(chassis.roll)
        sample[PITCH] = quantizeRadians(chassis.pitch)
      end
    end
    return sample
  end

  function codec.normalizeReplay(data)
    if type(data) ~= "table" then return nil end

    local metadata = {}
    local sourcePoints = data
    local interval = 0.01

    if data.samples then
      sourcePoints = data.samples
      interval = tonumber(data.sampleInterval) or interval
      metadata.formatVersion = tonumber(data.formatVersion) or 1
      metadata.sampleInterval = interval
      metadata.duration = tonumber(data.duration)
      metadata.lapTime = tonumber(data.lapTime)
      metadata.vehicle = data.vehicle
      metadata.startLine = data.startLine
      metadata.groundOffset = tonumber(data.groundOffset)
      metadata.complete = data.complete ~= false
      metadata.incompleteReason = data.incompleteReason
      metadata.shareFingerprint = data.shareFingerprint
    end

    if type(sourcePoints) ~= "table" or #sourcePoints == 0 then return nil end

    local points = {}
    local hasSpeed = false
    local hasInputs = false
    local hasChassis = false
    for index = 1, #sourcePoints do
      local point = sourcePoints[index]
      if type(point) == "table" then
        if point.pos and point.dirFront and point.dirUp then
          if tonumber(point.speed) ~= nil then hasSpeed = true end
          points[#points + 1] = normalizeOldPoint(point, index, interval)
        elseif tonumber(point[POS_X]) and tonumber(point[UP_Z]) then
          if tonumber(point[SPEED]) ~= nil then hasSpeed = true end
          local normalized = {
            pointTime(point, index, interval),
            tonumber(point[POS_X]), tonumber(point[POS_Y]), tonumber(point[POS_Z]),
            tonumber(point[FRONT_X]), tonumber(point[FRONT_Y]), tonumber(point[FRONT_Z]),
            tonumber(point[UP_X]), tonumber(point[UP_Y]), tonumber(point[UP_Z]),
            tonumber(point[SPEED]) or 0
          }
          if THROTTLE and BRAKE then
            local throttle = tonumber(point[THROTTLE])
            local brake = tonumber(point[BRAKE])
            if throttle ~= nil or brake ~= nil then
              normalized[THROTTLE] = throttle or 0
              normalized[BRAKE] = brake or 0
              if GEAR then normalized[GEAR] = tonumber(point[GEAR]) or 0 end
              if HANDBRAKE then normalized[HANDBRAKE] = tonumber(point[HANDBRAKE]) or 0 end
              if CLUTCH then normalized[CLUTCH] = tonumber(point[CLUTCH]) or 0 end
              hasInputs = true
            end
          end
          -- Format 4 chassis telemetry. Rows written before format 4 are simply
          -- shorter, so the columns stay absent and read as "not recorded".
          if LOAD_FL and #point >= LOAD_RR then
            normalized[LOAD_FL] = tonumber(point[LOAD_FL]) or 0
            normalized[LOAD_FR] = tonumber(point[LOAD_FR]) or 0
            normalized[LOAD_RL] = tonumber(point[LOAD_RL]) or 0
            normalized[LOAD_RR] = tonumber(point[LOAD_RR]) or 0
            if ROLL and PITCH and #point >= PITCH then
              normalized[ROLL] = tonumber(point[ROLL]) or 0
              normalized[PITCH] = tonumber(point[PITCH]) or 0
            end
            hasChassis = true
          end
          points[#points + 1] = normalized
        end
      end
    end

    if #points == 0 then return nil end
    metadata.sampleInterval = interval
    metadata.duration = metadata.duration or points[#points][TIME] or 0
    metadata.hasSpeed = hasSpeed
    metadata.hasInputs = hasInputs
    metadata.hasChassis = hasChassis
    return points, metadata
  end

  function codec.replayEnvelope(points, lapTime, settings)
    settings = settings or {}
    local duration = #points > 0 and points[#points][TIME] or 0
    local envelope = {
      formatVersion = formatVersion,
      sampleInterval = settings.sampleInterval,
      duration = duration,
      lapTime = lapTime,
      vehicle = settings.vehicle,
      groundOffset = settings.groundOffset,
      complete = settings.complete ~= false,
      incompleteReason = settings.incompleteReason,
      shareFingerprint = settings.shareFingerprint,
      samples = points
    }

    if settings.startLine then envelope.startLine = settings.startLine end
    return envelope
  end

  function codec.defaultReplayFilename(vehicleDirectory)
    return "lapLogs/" .. vehicleDirectory .. "/laplog.save.json"
  end

  function codec.libraryIndexFilename(filename, defaultFilename)
    filename = filename or defaultFilename
    local replaced, count = filename:gsub("%.json$", ".library.json")
    return count > 0 and replaced or (filename .. ".library.json")
  end

  function codec.sampleFilename(filename, id, defaultFilename)
    filename = filename or defaultFilename
    local stem, count = filename:gsub("%.json$", "")
    if count == 0 then stem = filename end
    return string.format("%s.ghosts/%s.json", stem, id)
  end

  return codec
end

return M
