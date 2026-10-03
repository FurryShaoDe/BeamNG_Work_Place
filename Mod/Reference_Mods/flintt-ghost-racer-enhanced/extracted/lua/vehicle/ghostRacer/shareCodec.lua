-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Compact, versioned clipboard transfer codec. Share data deliberately omits
-- local filenames and library IDs: an import always receives a new local ID.

local M = {}

function M.new(options)
  options = options or {}
  local indexes = assert(options.indexes, "sample indexes are required")
  local shareRate = tonumber(options.shareRate) or 20
  local maximumSeconds = tonumber(options.maximumSeconds) or 30 * 60
  local maximumGhosts = tonumber(options.maximumGhosts) or 5

  local TIME = indexes.time
  local POS_X, POS_Y, POS_Z = indexes.posX, indexes.posY, indexes.posZ
  local FRONT_X, FRONT_Y, FRONT_Z = indexes.frontX, indexes.frontY, indexes.frontZ
  local UP_X, UP_Y, UP_Z = indexes.upX, indexes.upY, indexes.upZ
  local SPEED = indexes.speed
  -- Optional driver-input channels (2.18 recordings). When the caller supplies
  -- these indexes and the ghost carries inputs, they travel in a separate
  -- optional stream so the pose/speed sample stream and its fingerprint stay
  -- byte-identical -- importers that predate inputs still decode the ghost and
  -- duplicate detection is unchanged.
  local THROTTLE, BRAKE, GEAR, HANDBRAKE, CLUTCH =
    indexes.throttle, indexes.brake, indexes.gear, indexes.handbrake, indexes.clutch
  local hasInputIndexes = THROTTLE and BRAKE and GEAR and HANDBRAKE and CLUTCH
  local shareInterval = 1 / shareRate
  local directionScale = 32767
  local adlerModulus = 65521
  local codec = {}
  local base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local base64Values = {}
  for index = 1, #base64Alphabet do
    base64Values[base64Alphabet:sub(index, index)] = index - 1
  end

  -- Clipboard payloads are transported as base64 varint streams rather than
  -- JSON number arrays: the same lap costs roughly a third of the characters,
  -- and no value ever passes through a textual number representation.
  local base64Shifts = {1, 2, 4, 8, 16, 32, 64, 128}

  local function base64Encode(bytes)
    local out = {}
    local length = #bytes
    local index = 1
    while index + 2 <= length do
      local a, b, c = bytes:byte(index, index + 2)
      local packed = a * 65536 + b * 256 + c
      out[#out + 1] = base64Alphabet:sub(math.floor(packed / 262144) + 1, math.floor(packed / 262144) + 1)
        .. base64Alphabet:sub(math.floor(packed / 4096) % 64 + 1, math.floor(packed / 4096) % 64 + 1)
        .. base64Alphabet:sub(math.floor(packed / 64) % 64 + 1, math.floor(packed / 64) % 64 + 1)
        .. base64Alphabet:sub(packed % 64 + 1, packed % 64 + 1)
      index = index + 3
    end
    local remaining = length - index + 1
    if remaining == 1 then
      local a = bytes:byte(index)
      local packed = a * 16
      out[#out + 1] = base64Alphabet:sub(math.floor(packed / 64) + 1, math.floor(packed / 64) + 1)
        .. base64Alphabet:sub(packed % 64 + 1, packed % 64 + 1) .. "=="
    elseif remaining == 2 then
      local a, b = bytes:byte(index, index + 1)
      local packed = (a * 256 + b) * 4
      out[#out + 1] = base64Alphabet:sub(math.floor(packed / 4096) + 1, math.floor(packed / 4096) + 1)
        .. base64Alphabet:sub(math.floor(packed / 64) % 64 + 1, math.floor(packed / 64) % 64 + 1)
        .. base64Alphabet:sub(packed % 64 + 1, packed % 64 + 1) .. "="
    end
    return table.concat(out)
  end

  local function base64Decode(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("%s", "")
    local padding = 0
    while text:sub(-1) == "=" do
      padding = padding + 1
      text = text:sub(1, -2)
    end
    if padding > 2 or #text % 4 == 1 then return nil end
    local out = {}
    local accumulator = 0
    local bits = 0
    for index = 1, #text do
      local value = base64Values[text:sub(index, index)]
      if not value then return nil end
      accumulator = accumulator * 64 + value
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        local divisor = base64Shifts[bits + 1]
        local byte = math.floor(accumulator / divisor)
        accumulator = accumulator - byte * divisor
        out[#out + 1] = string.char(byte)
      end
    end
    return table.concat(out)
  end

  local function writeVarint(out, value)
    -- Zigzag first so small negative deltas stay one byte wide.
    value = value >= 0 and value * 2 or -value * 2 - 1
    repeat
      local byte = value % 128
      value = math.floor(value / 128)
      if value > 0 then byte = byte + 128 end
      out[#out + 1] = string.char(byte)
    until value == 0
  end

  local function readVarint(bytes, position)
    local value = 0
    local shift = 1
    local length = #bytes
    repeat
      if position > length then return nil end
      local byte = bytes:byte(position)
      position = position + 1
      value = value + (byte % 128) * shift
      shift = shift * 128
      if shift > 2 ^ 56 then return nil end
    until byte < 128
    -- math.floor keeps the result an integer on every supported Lua version;
    -- plain division would hand back a float whose text form differs, and the
    -- fingerprint is computed from those values.
    if value % 2 == 0 then return math.floor(value / 2), position end
    return -math.floor((value + 1) / 2), position
  end


  local function finite(value)
    value = tonumber(value)
    return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
  end

  local function rounded(value)
    value = tonumber(value) or 0
    local result = value < 0 and math.ceil(value - 0.5) or math.floor(value + 0.5)
    -- Rounding towards zero from below yields negative zero on Lua builds
    -- whose math library returns floats. It compares equal to zero but is not
    -- interchangeable with it once written out, so normalise it here.
    if result == 0 then return 0 end
    return result
  end

  local function clampedInteger(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, rounded(value)))
  end

  -- The fingerprint must not depend on how a Lua build happens to represent a
  -- number. tostring prints an integer-valued float differently from an
  -- integer, and negative zero differently from zero, so quantization that
  -- lands on zero from below used to produce a code whose own importer
  -- rejected it. Every sample value is an integer by construction, so format
  -- it as one; anything else is pinned to a fixed textual form.
  local function fingerprintText(value)
    value = tonumber(value)
    if value == nil or value ~= value then return "?" end
    if value >= -9007199254740992 and value <= 9007199254740992
        and value == math.floor(value) then
      return string.format("%d", value)
    end
    return string.format("%.14g", value)
  end

  local function adlerText(a, b, value)
    value = fingerprintText(value) .. ","
    for index = 1, #value do
      a = (a + value:byte(index)) % adlerModulus
      b = (b + a) % adlerModulus
    end
    return a, b
  end

  function codec.fingerprint(samples)
    local a, b = 1, 0
    local durationMilliseconds = 0
    for sampleIndex = 1, #(samples or {}) do
      local sample = samples[sampleIndex]
      for valueIndex = 1, #(sample or {}) do
        a, b = adlerText(a, b, sample[valueIndex])
      end
      durationMilliseconds = durationMilliseconds + (tonumber(sample and sample[1]) or 0)
    end
    return string.format(
      "grs2-%08x-%d-%d",
      b * 65536 + a,
      #(samples or {}),
      durationMilliseconds
    )
  end

  -- Sample 1 carries absolute values; later samples carry deltas for every
  -- field. Time and position are already deltas from the quantizer, while
  -- orientation and speed change slowly, so delta coding keeps almost every
  -- value inside a single varint byte.
  local function packSamples(compact)
    local out = {}
    local previous
    for index = 1, #compact do
      local sample = compact[index]
      if not previous then
        for valueIndex = 1, 11 do writeVarint(out, sample[valueIndex]) end
      else
        for valueIndex = 1, 4 do writeVarint(out, sample[valueIndex]) end
        for valueIndex = 5, 11 do
          writeVarint(out, sample[valueIndex] - previous[valueIndex])
        end
      end
      previous = sample
    end
    return base64Encode(table.concat(out))
  end

  -- Driver inputs travel as a parallel stream, one 5-tuple per pose sample
  -- (throttle, brake, gear, handbrake, clutch). Values change slowly, so the
  -- first sample is absolute and the rest are deltas; a held pedal costs one
  -- zero byte per field.
  local function packInputs(inputs)
    local out = {}
    local previous
    for index = 1, #inputs do
      local sample = inputs[index]
      for valueIndex = 1, 5 do
        writeVarint(out, previous and sample[valueIndex] - previous[valueIndex] or sample[valueIndex])
      end
      previous = sample
    end
    return base64Encode(table.concat(out))
  end

  local function unpackInputs(text, count)
    local bytes = base64Decode(text)
    if not bytes then return nil end
    local out = {}
    local position = 1
    local previous
    for index = 1, count do
      local sample = {}
      for valueIndex = 1, 5 do
        local value
        value, position = readVarint(bytes, position)
        if value == nil then return nil end
        if previous then value = value + previous[valueIndex] end
        sample[valueIndex] = value
      end
      out[index] = sample
      previous = sample
    end
    if position ~= #bytes + 1 then return nil end
    return out
  end

  local function unpackSamples(text, count)
    local bytes = base64Decode(text)
    if not bytes then return nil end
    count = tonumber(count)
    if not count or count ~= math.floor(count) or count < 2
        or count > math.floor(maximumSeconds * shareRate) + 2 then
      return nil
    end
    local compact = {}
    local position = 1
    local previous
    for index = 1, count do
      local sample = {}
      for valueIndex = 1, 11 do
        local value
        value, position = readVarint(bytes, position)
        if value == nil then return nil end
        if previous and valueIndex >= 5 then
          value = value + previous[valueIndex]
        end
        sample[valueIndex] = value
      end
      compact[index] = sample
      previous = sample
    end
    if position ~= #bytes + 1 then return nil end
    return compact
  end

  local function quantizedDirection(value)
    return clampedInteger((tonumber(value) or 0) * directionScale, -directionScale, directionScale)
  end

  function codec.encode(points, metadata)
    if type(points) ~= "table" or #points < 2 then return nil, "tooFewSamples" end
    metadata = metadata or {}

    local compact = {}
    local inputCompact = {}
    local ghostHasInputs = hasInputIndexes and type(points[1]) == "table"
      and points[1][THROTTLE] ~= nil
    local previousTimeMilliseconds = 0
    local previousX, previousY, previousZ = 0, 0, 0
    local nextShareTime = tonumber(points[1][TIME]) or 0
    local lastSourceIndex = 0

    local function append(point, sourceIndex)
      if type(point) ~= "table" then return false end
      local timestamp = tonumber(point[TIME])
      if not timestamp or timestamp < 0 or timestamp > maximumSeconds then return false end
      if not finite(point[POS_X]) or not finite(point[POS_Y]) or not finite(point[POS_Z])
          or not finite(point[FRONT_X]) or not finite(point[FRONT_Y]) or not finite(point[FRONT_Z])
          or not finite(point[UP_X]) or not finite(point[UP_Y]) or not finite(point[UP_Z])
          or not finite(point[SPEED]) then return false end

      local timeMilliseconds = math.max(previousTimeMilliseconds, rounded(timestamp * 1000))
      -- Importers require a strictly increasing millisecond clock. Two source
      -- samples inside the same millisecond would otherwise produce a share
      -- code that this exporter accepts and every importer rejects.
      if #compact > 0 and timeMilliseconds == previousTimeMilliseconds then
        lastSourceIndex = sourceIndex
        return true
      end
      local x = rounded(point[POS_X] * 100)
      local y = rounded(point[POS_Y] * 100)
      local z = rounded(point[POS_Z] * 100)
      compact[#compact + 1] = {
        timeMilliseconds - previousTimeMilliseconds,
        #compact == 0 and x or x - previousX,
        #compact == 0 and y or y - previousY,
        #compact == 0 and z or z - previousZ,
        quantizedDirection(point[FRONT_X]),
        quantizedDirection(point[FRONT_Y]),
        quantizedDirection(point[FRONT_Z]),
        quantizedDirection(point[UP_X]),
        quantizedDirection(point[UP_Y]),
        quantizedDirection(point[UP_Z]),
        clampedInteger(point[SPEED] * 100, 0, 10000000)
      }
      if ghostHasInputs then
        -- Aligned 1:1 with compact: pushed only when a pose sample is kept.
        inputCompact[#inputCompact + 1] = {
          clampedInteger((tonumber(point[THROTTLE]) or 0) * 100, 0, 100),
          clampedInteger((tonumber(point[BRAKE]) or 0) * 100, 0, 100),
          clampedInteger(tonumber(point[GEAR]) or 0, -100, 100),
          clampedInteger((tonumber(point[HANDBRAKE]) or 0) * 100, 0, 100),
          clampedInteger((tonumber(point[CLUTCH]) or 0) * 100, 0, 100)
        }
      end
      previousTimeMilliseconds = timeMilliseconds
      previousX, previousY, previousZ = x, y, z
      lastSourceIndex = sourceIndex
      return true
    end

    for index = 1, #points do
      local point = points[index]
      local timestamp = tonumber(point and point[TIME])
      local include = index == 1 or index == #points
        or timestamp and timestamp + 0.000001 >= nextShareTime
      if include and index ~= lastSourceIndex then
        if not append(point, index) then return nil, "invalidSample" end
        if timestamp then
          repeat
            nextShareTime = nextShareTime + shareInterval
          until nextShareTime > timestamp + 0.000001
        end
      end
    end

    if #compact < 2 then return nil, "tooFewSamples" end
    local fingerprint = codec.fingerprint(compact)
    return {
      label = tostring(metadata.label or "Shared Ghost"):gsub("[%c]", " "):sub(1, 48),
      lapTime = tonumber(metadata.lapTime),
      duration = previousTimeMilliseconds / 1000,
      complete = metadata.complete ~= false,
      manual = metadata.manual == true or nil,
      incompleteReason = metadata.complete == false
        and tostring(metadata.incompleteReason or "interrupted"):sub(1, 48) or nil,
      vehicle = tostring(metadata.vehicle or "unknown_vehicle"):sub(1, 96),
      groundOffset = tonumber(metadata.groundOffset) or 0,
      originalSampleInterval = tonumber(metadata.sampleInterval),
      shareSampleInterval = shareInterval,
      fingerprint = fingerprint,
      sampleCount = #compact,
      sampleData = packSamples(compact),
      hasInputs = ghostHasInputs and #inputCompact == #compact or nil,
      inputData = ghostHasInputs and #inputCompact == #compact
        and packInputs(inputCompact) or nil
    }
  end

  local function validInteger(value, minimum, maximum)
    return finite(value) and value == math.floor(value)
      and value >= minimum and value <= maximum
  end

  function codec.decode(entry)
    if type(entry) ~= "table" then return nil, nil, "invalidSamples" end
    -- Format 2 carries a compact stream; format 1 codes shared by 2.12.x are
    -- still accepted so existing share codes keep importing.
    local samples = type(entry.sampleData) == "string"
      and unpackSamples(entry.sampleData, entry.sampleCount)
      or entry.samples
    if type(samples) ~= "table" or #samples < 2
        or #samples > math.floor(maximumSeconds * shareRate) + 2 then
      return nil, nil, "invalidSamples"
    end
    -- The fingerprint is computed from the decoded values, so it keeps
    -- identifying the same lap across both transport formats and duplicate
    -- detection survives the format change.
    if type(entry.fingerprint) ~= "string"
        or entry.fingerprint ~= codec.fingerprint(samples) then
      return nil, nil, "checksumMismatch"
    end

    local points = {}
    local timeMilliseconds = 0
    local x, y, z = 0, 0, 0
    for index = 1, #samples do
      local sample = samples[index]
      local minimumTimeDelta = index == 1 and 0 or 1
      if type(sample) ~= "table" or #sample ~= 11
          or not validInteger(sample[1], minimumTimeDelta, maximumSeconds * 1000)
          or not validInteger(sample[2], -1000000000, 1000000000)
          or not validInteger(sample[3], -1000000000, 1000000000)
          or not validInteger(sample[4], -1000000000, 1000000000) then
        return nil, nil, "invalidSample"
      end
      for valueIndex = 5, 10 do
        if not validInteger(sample[valueIndex], -directionScale, directionScale) then
          return nil, nil, "invalidOrientation"
        end
      end
      if not validInteger(sample[11], 0, 10000000) then
        return nil, nil, "invalidSpeed"
      end
      local frontMagnitudeSquared = sample[5] * sample[5]
        + sample[6] * sample[6] + sample[7] * sample[7]
      local upMagnitudeSquared = sample[8] * sample[8]
        + sample[9] * sample[9] + sample[10] * sample[10]
      if frontMagnitudeSquared < directionScale * directionScale * 0.25
          or upMagnitudeSquared < directionScale * directionScale * 0.25 then
        return nil, nil, "invalidOrientation"
      end

      timeMilliseconds = timeMilliseconds + sample[1]
      if timeMilliseconds > maximumSeconds * 1000 then return nil, nil, "durationLimit" end
      if index == 1 then
        x, y, z = sample[2], sample[3], sample[4]
      else
        x, y, z = x + sample[2], y + sample[3], z + sample[4]
      end
      points[#points + 1] = {
        timeMilliseconds / 1000,
        x / 100, y / 100, z / 100,
        sample[5] / directionScale,
        sample[6] / directionScale,
        sample[7] / directionScale,
        sample[8] / directionScale,
        sample[9] / directionScale,
        sample[10] / directionScale,
        sample[11] / 100
      }
    end

    -- Optional driver-input stream. Absent (older codes) or malformed inputs
    -- degrade gracefully to a pose-only ghost rather than failing the import.
    local hasInputs = false
    if hasInputIndexes and type(entry.inputData) == "string" then
      local inputs = unpackInputs(entry.inputData, #samples)
      if inputs and #inputs == #points then
        local valid = true
        for index = 1, #inputs do
          local sample = inputs[index]
          if not (validInteger(sample[1], 0, 100) and validInteger(sample[2], 0, 100)
              and validInteger(sample[3], -100, 100) and validInteger(sample[4], 0, 100)
              and validInteger(sample[5], 0, 100)) then
            valid = false
            break
          end
        end
        if valid then
          for index = 1, #points do
            local sample = inputs[index]
            points[index][THROTTLE] = sample[1] / 100
            points[index][BRAKE] = sample[2] / 100
            points[index][GEAR] = sample[3]
            points[index][HANDBRAKE] = sample[4] / 100
            points[index][CLUTCH] = sample[5] / 100
          end
          hasInputs = true
        end
      end
    end

    local metadata = {
      label = tostring(entry.label or "Shared Ghost"):gsub("[%c]", " "):sub(1, 48),
      lapTime = tonumber(entry.lapTime),
      duration = timeMilliseconds / 1000,
      complete = entry.complete ~= false,
      manual = entry.manual == true,
      incompleteReason = entry.complete == false
        and tostring(entry.incompleteReason or "interrupted"):sub(1, 48) or nil,
      vehicle = tostring(entry.vehicle or "unknown_vehicle"):sub(1, 96),
      groundOffset = tonumber(entry.groundOffset) or 0,
      sampleInterval = shareInterval,
      hasSpeed = true,
      hasInputs = hasInputs,
      fingerprint = entry.fingerprint
    }
    if metadata.lapTime and (metadata.lapTime < 0 or metadata.lapTime > maximumSeconds) then
      return nil, nil, "invalidLapTime"
    end
    return points, metadata
  end

  function codec.package(route, ghosts, exporterVersion)
    if type(route) ~= "table" or type(ghosts) ~= "table"
        or #ghosts < 1 or #ghosts > maximumGhosts then return nil end
    return {
      kind = "ghostRacerShare",
      formatVersion = 2,
      codec = "delta-cm-20hz-v2",
      exporterVersion = tostring(exporterVersion or "unknown"):sub(1, 24),
      shareRate = shareRate,
      route = route,
      ghosts = ghosts
    }
  end

  -- The clipboard limit is enforced on the finished text by the GE side, but
  -- the Vehicle side can estimate it first and refuse before spending a full
  -- encode, a disk write and a VM round trip. The base64 sample stream carries
  -- no characters JSON has to escape, so its length transfers one to one.
  function codec.estimatePackageBytes(ghosts)
    local total = 256
    for index = 1, #(ghosts or {}) do
      local ghost = ghosts[index]
      total = total + 320 + #tostring(ghost and ghost.sampleData or "")
        + #tostring(ghost and ghost.inputData or "")
    end
    return total
  end

  function codec.validatePackage(data)
    local version = tonumber(data ~= nil and data.formatVersion)
    local expectedCodec = version == 2 and "delta-cm-20hz-v2"
      or version == 1 and "delta-cm-20hz-v1" or nil
    if type(data) ~= "table" or data.kind ~= "ghostRacerShare"
        or not expectedCodec
        or data.codec ~= expectedCodec
        or tonumber(data.shareRate) ~= shareRate
        or type(data.route) ~= "table"
        or type(data.ghosts) ~= "table"
        or #data.ghosts < 1 or #data.ghosts > maximumGhosts then
      return false, "unsupportedFormat"
    end
    return true
  end

  codec.shareRate = shareRate
  codec.maximumGhosts = maximumGhosts
  return codec
end

return M
