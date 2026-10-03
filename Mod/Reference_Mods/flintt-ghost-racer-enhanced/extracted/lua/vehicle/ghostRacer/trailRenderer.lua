-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Vehicle-side best-line, trail-window and wireframe playback orchestration.

local M = {}

local MAX_BEST_LAP_SEGMENTS = 4000
-- Curvature-adaptive best-lap line: keep a recorded point only where dropping it
-- would bend the drawn line away from the real path by more than this many
-- metres. Corners keep as much detail as they need; a tight hairpin holds far
-- more points than a fixed spacing would. Raised automatically if a lap would
-- exceed the segment cap.
local BEST_LAP_TOLERANCE = 0.06
local BEST_LAP_MAX_TOLERANCE = 100
-- No drawn segment is longer than this. Curvature simplification would otherwise
-- collapse a straight into one very long chord; instead such a chord is split
-- back into pieces at most this long, so straights stay at the familiar spacing
-- and only corners go finer. On an extreme-length lap this widens just enough to
-- keep the whole line inside the segment budget.
local BEST_LAP_MAX_SEGMENT_LENGTH = 6
-- Corner spans are drawn as a short Catmull-Rom curve: one piece per this many
-- metres of chord, at least two and at most a few, so bends read as smooth
-- curves rather than flat chords without exploding the segment count.
local BEST_LAP_SMOOTH_STEP = 1.5
local BEST_LAP_MAX_CORNER_PIECES = 4
-- A short span is only subdivided into Catmull pieces when the smoothed curve
-- actually bulges from its straight chord by more than this (metres). The
-- curvature-simplified best-lap line keeps short spans only in real corners, so
-- this is a no-op there; the fixed-grid ghost trail and the raw live trail sample
-- straights densely too, and without this every sub-6 m straight span was
-- needlessly split into two collinear pieces, doubling the segment count and
-- eating the trail's budget for no visible gain.
local BEST_LAP_STRAIGHT_DEVIATION = 0.06
-- In input mode, force a point wherever throttle or brake swings by more than
-- this across a sample, so a braking/throttle transition on a straight keeps
-- short segments and the colour gradient follows the input instead of jumping.
local BEST_LAP_INPUT_KEEP_DELTA = 0.08
-- Per-window piece budget for a single ghost's smoothed trail (the renderer caps
-- the combined total across all ghosts separately).
local MAX_TRAIL_WINDOW_SEGMENTS = 400

function M.new(options)
  options = options or {}
  local renderer = {}
  local state = assert(options.state, "controller state is required")
  local object = assert(options.object, "vehicle object is required")
  local bestGhostEntry = assert(options.bestGhostEntry, "best-entry resolver is required")
  local ensureGhostSamples = assert(options.ensureGhostSamples, "sample loader is required")
  local drawGhostSamples = assert(options.drawGhostSamples, "wireframe draw callback is required")
  local getTrailMode = assert(options.getTrailMode, "trail-mode getter is required")
  local clamp = assert(options.clamp, "clamp is required")
  local trailInterval = assert(options.trailInterval, "trail interval is required")
  local indexes = assert(options.indexes, "sample indexes are required")
  local TIME = indexes.time
  local POS_X, POS_Y, POS_Z = indexes.posX, indexes.posY, indexes.posZ
  local SPEED = indexes.speed
  local THROTTLE, BRAKE = indexes.throttle, indexes.brake
  local GEAR, HANDBRAKE, CLUTCH = indexes.gear, indexes.handbrake, indexes.clutch
  local HANDBRAKE_ON = 0.05

  -- Driver-input palette layout (must match worldRenderer's generated gradients):
  --   16 coast, then INPUT_STEPS brake, then INPUT_STEPS throttle, then upshift,
  --   downshift, then HANDBRAKE_STEPS handbrake. Fine step counts keep the
  --   pedal-depth gradient visually continuous rather than banded.
  local INPUT_STEPS = 24
  local HANDBRAKE_STEPS = 8
  local COAST_INDEX = 16
  local BRAKE_BASE = COAST_INDEX             -- brake = BRAKE_BASE + step
  local THROTTLE_BASE = COAST_INDEX + INPUT_STEPS
  local UPSHIFT_INDEX = THROTTLE_BASE + INPUT_STEPS + 1
  local DOWNSHIFT_INDEX = UPSHIFT_INDEX + 1
  local HANDBRAKE_BASE = DOWNSHIFT_INDEX     -- handbrake = HANDBRAKE_BASE + step
  local BOTH_BASE = HANDBRAKE_BASE + HANDBRAKE_STEPS -- both pedals (amber) = BOTH_BASE + step
  local CLUTCH_BASE = BOTH_BASE + INPUT_STEPS        -- clutch sub-line (teal) = CLUTCH_BASE + step
  local CLUTCH_ON = 0.05
  local SIDE_LINE_OFFSET = 0.5  -- metres a sub-line sits beside the main line
  local SHIFT_MARK_HALF = 1.3   -- half-length of a gear-shift tick across the line

  -- Map a pedal depth (0..1) to a brightness step (1..steps).
  local function depthStep(depth, steps)
    local step = math.ceil((tonumber(depth) or 0) * steps)
    if step < 1 then step = 1 elseif step > steps then step = steps end
    return step
  end

  -- excludeEvents: skip the in-line gear-shift and handbrake colours. The best-lap
  -- line uses it because those are drawn as separate marks (shift ticks and a
  -- handbrake sub-line); the ghost/live trails keep them in-line.
  local function ghostTrailColorIndex(entry, first, second, modeOverride, excludeEvents)
    if not first or not second then return 15 end
    if entry.hasSpeed == false then return 15 end

    local mode = modeOverride or getTrailMode()

    -- Driver-input mode: colour by the recorded pedal, brightness by how hard it
    -- was pressed. Only ghosts recorded with the 2.18 format carry inputs; for
    -- older ones there is no pedal data, so fall through to inferred acceleration.
    if mode == "inputs" and THROTTLE and BRAKE then
      local throttle = tonumber(second[THROTTLE])
      local brake = tonumber(second[BRAKE])
      if throttle ~= nil or brake ~= nil then
        throttle = throttle or 0
        brake = brake or 0
        if not excludeEvents then
          -- A gear change between this segment's endpoints is a shift: a short
          -- pink (up) or purple (down) mark that cuts through whatever colour the
          -- line would otherwise be.
          if GEAR then
            local gearFirst = tonumber(first[GEAR])
            local gearSecond = tonumber(second[GEAR])
            if gearFirst ~= nil and gearSecond ~= nil and gearFirst ~= gearSecond then
              return gearSecond > gearFirst and UPSHIFT_INDEX or DOWNSHIFT_INDEX
            end
          end
          -- Handbrake (drift/rally) takes priority over the foot pedals while it is
          -- pulled, in its own blue, brighter the harder it is pulled.
          if HANDBRAKE then
            local handbrake = tonumber(second[HANDBRAKE]) or 0
            if handbrake > HANDBRAKE_ON then
              return HANDBRAKE_BASE + depthStep(handbrake, HANDBRAKE_STEPS)
            end
          end
        end
        -- Both pedals together (left-foot braking / trail overlap): amber, by the
        -- deeper of the two.
        if brake > 0.03 and throttle > 0.03 then
          return BOTH_BASE + depthStep(math.max(brake, throttle), INPUT_STEPS)
        end
        if brake > 0.03 then
          return BRAKE_BASE + depthStep(brake, INPUT_STEPS)      -- dark to bright red
        elseif throttle > 0.03 then
          return THROTTLE_BASE + depthStep(throttle, INPUT_STEPS) -- dark to bright green
        end
        return COAST_INDEX -- coasting: neither pedal
      end
    end

    if mode == "acceleration" or mode == "inputs" then
      local elapsed = (tonumber(second[TIME]) or 0) - (tonumber(first[TIME]) or 0)
      if elapsed <= 0.0001 then return 15 end
      local acceleration = ((tonumber(second[SPEED]) or 0)
        - (tonumber(first[SPEED]) or 0)) / elapsed
      if acceleration < -6 then return 8 end
      if acceleration < -3 then return 9 end
      if acceleration < -1 then return 10 end
      if acceleration < 1 then return 11 end
      if acceleration < 3 then return 12 end
      if acceleration < 6 then return 13 end
      return 14
    end

    local speedKmh = (tonumber(second[SPEED]) or 0) * 3.6
    if speedKmh < 40 then return 1 end
    if speedKmh < 80 then return 2 end
    if speedKmh < 120 then return 3 end
    if speedKmh < 160 then return 4 end
    if speedKmh < 200 then return 5 end
    if speedKmh < 250 then return 6 end
    return 7
  end

  -- Douglas-Peucker line simplification (iterative, so a long lap cannot overflow
  -- the Lua stack). Keeps points whose perpendicular distance from the retained
  -- polyline exceeds epsilon, which is exactly the curvature-adaptive behaviour:
  -- straight runs need no interior points, tight corners keep many.
  -- keepPredicate(index) may force a point to be retained regardless of geometry;
  -- used to keep both sides of a gear change or handbrake edge so those events
  -- survive simplification as short, crisp marks.
  local function simplifyByCurvature(points, epsilon, keepPredicate)
    local count = #points
    if count < 3 then return points end
    local keep = {}
    keep[1] = true
    keep[count] = true
    if keepPredicate then
      for index = 2, count - 1 do
        if keepPredicate(index) then keep[index] = true end
      end
    end
    local stack = {{1, count}}
    while #stack > 0 do
      local segment = stack[#stack]
      stack[#stack] = nil
      local first, last = segment[1], segment[2]
      local ax, ay, az = points[first][POS_X], points[first][POS_Y], points[first][POS_Z]
      local bx, by, bz = points[last][POS_X], points[last][POS_Y], points[last][POS_Z]
      local dx, dy, dz = bx - ax, by - ay, bz - az
      local segmentLengthSq = dx * dx + dy * dy + dz * dz
      local worstDistance, worstIndex = -1, nil
      for index = first + 1, last - 1 do
        local px, py, pz = points[index][POS_X], points[index][POS_Y], points[index][POS_Z]
        local distanceSq
        if segmentLengthSq < 0.000001 then
          local ex, ey, ez = px - ax, py - ay, pz - az
          distanceSq = ex * ex + ey * ey + ez * ez
        else
          local t = ((px - ax) * dx + (py - ay) * dy + (pz - az) * dz) / segmentLengthSq
          if t < 0 then t = 0 elseif t > 1 then t = 1 end
          local ex = px - (ax + dx * t)
          local ey = py - (ay + dy * t)
          local ez = pz - (az + dz * t)
          distanceSq = ex * ex + ey * ey + ez * ez
        end
        if distanceSq > worstDistance then worstDistance = distanceSq; worstIndex = index end
      end
      if worstIndex and worstDistance > epsilon * epsilon then
        keep[worstIndex] = true
        stack[#stack + 1] = {first, worstIndex}
        stack[#stack + 1] = {worstIndex, last}
      end
    end
    local result = {}
    for index = 1, count do
      if keep[index] then result[#result + 1] = points[index] end
    end
    return result
  end

  local function chordLength(a, b)
    local dx = b[POS_X] - a[POS_X]
    local dy = b[POS_Y] - a[POS_Y]
    local dz = b[POS_Z] - a[POS_Z]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  -- Short spans are corners (the simplifier only keeps close points where the
  -- path bends), so give them a few Catmull-Rom pieces to round them.
  local function cornerPieces(chord)
    local pieces = math.ceil(chord / BEST_LAP_SMOOTH_STEP)
    if pieces < 2 then pieces = 2 elseif pieces > BEST_LAP_MAX_CORNER_PIECES then
      pieces = BEST_LAP_MAX_CORNER_PIECES
    end
    return pieces
  end

  -- Uniform Catmull-Rom through the control points: the curve passes through each
  -- one (q(0)=p1, q(1)=p2) and bends smoothly between, so corners are rounded
  -- instead of cut. Reflected end control points keep a straight span linear and
  -- evenly spaced instead of bowing it past the length cap.
  local function catmull(p0, p1, p2, p3, axis, t)
    local a1, a2 = p1[axis], p2[axis]
    local a0 = p0 and p0[axis] or (2 * a1 - a2)
    local a3 = p3 and p3[axis] or (2 * a2 - a1)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * ((2 * a1) + (-a0 + a2) * t
      + (2 * a0 - 5 * a1 + 4 * a2 - a3) * t2
      + (-a0 + 3 * a1 - 3 * a2 + a3) * t3)
  end

  -- Shared smoothing for every drawn line (best-lap line, ghost trail, live input
  -- trail): Catmull-Rom through the control points, corner spans subdivided,
  -- straights split to the length cap and widened if needed to stay under budget.
  -- emit(spanFirst, spanSecond, ax, ay, az, bx, by, bz) is called per drawn piece
  -- with the span's control points (for colour) and world-space piece endpoints,
  -- so each caller applies its own ground offset, colour and extra fields.
  -- True when the span p1->p2 needs Catmull subdivision: it is shorter than the
  -- straight length cap AND its smoothed curve bulges from the chord by more than
  -- BEST_LAP_STRAIGHT_DEVIATION. A near-collinear short span (dense trail on a
  -- straight) is left as one piece instead of being split into collinear halves.
  local function spanIsCurved(chord, p0, p1, p2, p3)
    if chord >= BEST_LAP_MAX_SEGMENT_LENGTH then return false end
    local midX = catmull(p0, p1, p2, p3, POS_X, 0.5)
    local midY = catmull(p0, p1, p2, p3, POS_Y, 0.5)
    local dx = midX - (p1[POS_X] + p2[POS_X]) * 0.5
    local dy = midY - (p1[POS_Y] + p2[POS_Y]) * 0.5
    return dx * dx + dy * dy > BEST_LAP_STRAIGHT_DEVIATION * BEST_LAP_STRAIGHT_DEVIATION
  end

  local function emitSmoothLine(controlPoints, budget, emit)
    local total = #controlPoints
    if total < 2 then return end
    local cornerPieceTotal, straightLength, straightSpanCount = 0, 0, 0
    for index = 2, total do
      local p1, p2 = controlPoints[index - 1], controlPoints[index]
      local chord = chordLength(p1, p2)
      if spanIsCurved(chord, controlPoints[index - 2], p1, p2, controlPoints[index + 1]) then
        cornerPieceTotal = cornerPieceTotal + cornerPieces(chord)
      else
        straightLength = straightLength + chord
        straightSpanCount = straightSpanCount + 1
      end
    end
    local straightBudget = math.max(1, budget - cornerPieceTotal - straightSpanCount)
    local straightStep = math.max(BEST_LAP_MAX_SEGMENT_LENGTH, straightLength / straightBudget)
    local count = 0
    local lastIndex = 1
    for index = 2, total do
      if count >= budget then break end
      local p1 = controlPoints[index - 1]
      local p2 = controlPoints[index]
      local p0 = controlPoints[index - 2]
      local p3 = controlPoints[index + 1]
      local chord = chordLength(p1, p2)
      local pieces = spanIsCurved(chord, p0, p1, p2, p3) and cornerPieces(chord)
        or math.max(1, math.ceil(chord / straightStep))
      local prevX, prevY, prevZ = p1[POS_X], p1[POS_Y], p1[POS_Z]
      for piece = 1, pieces do
        if count >= budget then break end
        local t = piece / pieces
        local nx = catmull(p0, p1, p2, p3, POS_X, t)
        local ny = catmull(p0, p1, p2, p3, POS_Y, t)
        local nz = catmull(p0, p1, p2, p3, POS_Z, t)
        emit(p1, p2, prevX, prevY, prevZ, nx, ny, nz)
        prevX, prevY, prevZ = nx, ny, nz
        count = count + 1
        lastIndex = index
      end
    end
    return count, lastIndex
  end

  -- Force a simplifier to keep both samples straddling every gear change and
  -- handbrake edge (so shift/handbrake marks land correctly and stay short) and
  -- every fast throttle/brake swing (so the colour gradient follows the input even
  -- on a geometric straight). Shared by the best-lap line and the live input trail.
  local function buildInputKeepPredicate(points)
    if not GEAR then return nil end
    return function(index)
      local current = points[index]
      local gearCurrent = tonumber(current[GEAR]) or 0
      local handbrakeCurrent = (tonumber(current[HANDBRAKE]) or 0) > HANDBRAKE_ON
      local previous = points[index - 1]
      local nextPoint = points[index + 1]
      if previous then
        if (tonumber(previous[GEAR]) or 0) ~= gearCurrent then return true end
        if ((tonumber(previous[HANDBRAKE]) or 0) > HANDBRAKE_ON) ~= handbrakeCurrent then
          return true
        end
      end
      if nextPoint then
        if (tonumber(nextPoint[GEAR]) or 0) ~= gearCurrent then return true end
        if ((tonumber(nextPoint[HANDBRAKE]) or 0) > HANDBRAKE_ON) ~= handbrakeCurrent then
          return true
        end
      end
      if THROTTLE and BRAKE and previous and nextPoint then
        local throttleSwing = math.abs(
          (tonumber(nextPoint[THROTTLE]) or 0) - (tonumber(previous[THROTTLE]) or 0)
        )
        local brakeSwing = math.abs(
          (tonumber(nextPoint[BRAKE]) or 0) - (tonumber(previous[BRAKE]) or 0)
        )
        if throttleSwing > BEST_LAP_INPUT_KEEP_DELTA
            or brakeSwing > BEST_LAP_INPUT_KEEP_DELTA then
          return true
        end
      end
      return false
    end
  end

  -- A thin parallel sub-line offset to one side of the main line, drawn only where
  -- `channelIndex` (clutch, handbrake, ...) is engaged, coloured by its depth. It
  -- walks the RAW samples (not the simplified points), because these events are
  -- brief -- a clutch dip during a shift is only a few samples and would be dropped
  -- by curvature simplification. offsetSign +1/-1 puts it right/left of the line.
  local function emitSideLine(points, sampleInterval, groundOffset, encoded, encodeSeg,
      channelIndex, threshold, colorBase, steps, offsetSign, limit)
    if not channelIndex then return end
    limit = limit or MAX_BEST_LAP_SEGMENTS
    local total = #points
    if total < 2 then return end
    local interval = tonumber(sampleInterval)
      or math.max((points[2][TIME] or 0) - (points[1][TIME] or 0), 0.01)
    local stride = math.max(1, math.floor(0.05 / interval + 0.5))
    local previousIndex = 1
    for index = 1 + stride, total, stride do
      if #encoded >= limit then break end
      local a, b = points[previousIndex], points[index]
      local value = tonumber(b[channelIndex]) or 0
      if value > threshold then
        local dx = b[POS_X] - a[POS_X]
        local dy = b[POS_Y] - a[POS_Y]
        local length = math.sqrt(dx * dx + dy * dy)
        if length > 0.001 then
          local offsetX = -dy / length * SIDE_LINE_OFFSET * offsetSign
          local offsetY = dx / length * SIDE_LINE_OFFSET * offsetSign
          encodeSeg(
            a[POS_X] + offsetX, a[POS_Y] + offsetY, a[POS_Z] - groundOffset + 0.05,
            b[POS_X] + offsetX, b[POS_Y] + offsetY, b[POS_Z] - groundOffset + 0.05,
            colorBase + depthStep(value, steps), true
          )
        end
      end
      previousIndex = index
    end
  end

  -- A gear shift lasts only a moment, so instead of a tiny in-line colour it is
  -- drawn as a short tick perpendicular to the line at the change: bright pink for
  -- an upshift, purple for a downshift. Walks the raw samples so no shift is lost.
  local function emitShiftMarks(points, groundOffset, encoded, encodeSeg, limit)
    if not GEAR then return end
    limit = limit or MAX_BEST_LAP_SEGMENTS
    local total = #points
    for index = 2, total do
      if #encoded >= limit then break end
      local a, b = points[index - 1], points[index]
      local gearA = tonumber(a[GEAR])
      local gearB = tonumber(b[GEAR])
      if gearA ~= nil and gearB ~= nil and gearA ~= gearB then
        local dx = b[POS_X] - a[POS_X]
        local dy = b[POS_Y] - a[POS_Y]
        local length = math.sqrt(dx * dx + dy * dy)
        if length > 0.001 then
          local px = -dy / length * SHIFT_MARK_HALF
          local py = dx / length * SHIFT_MARK_HALF
          local colorIndex = gearB > gearA and UPSHIFT_INDEX or DOWNSHIFT_INDEX
          local z = b[POS_Z] - groundOffset + 0.06
          encodeSeg(
            b[POS_X] - px, b[POS_Y] - py, z,
            b[POS_X] + px, b[POS_Y] + py, z,
            colorIndex, false
          )
        end
      end
    end
  end

  -- Driver-input overlays shared by the best-lap line and the live input trail:
  -- a shift tick at each gear change, plus the optional clutch (right) and
  -- handbrake (left) sub-lines. Walks the raw samples so brief events are kept.
  local function emitInputOverlays(points, sampleInterval, groundOffset, encoded, encodeSeg, limit)
    emitShiftMarks(points, groundOffset, encoded, encodeSeg, limit)
    if state.clutchLineVisible and CLUTCH then
      emitSideLine(points, sampleInterval, groundOffset, encoded, encodeSeg,
        CLUTCH, CLUTCH_ON, CLUTCH_BASE, INPUT_STEPS, 1, limit)
    end
    if state.handbrakeLineVisible and HANDBRAKE then
      emitSideLine(points, sampleInterval, groundOffset, encoded, encodeSeg,
        HANDBRAKE, HANDBRAKE_ON, HANDBRAKE_BASE, HANDBRAKE_STEPS, -1, limit)
    end
  end

  -- Overlay encoder for the best-lap line and live trail: a shift tick is 7
  -- fields; a clutch/handbrake sub-line piece adds an 8th "1" flag so the GE side
  -- draws it thin and offset. (The ghost trail uses its own 10-field encoder.)
  local function lineOverlayEncoder(encoded)
    return function(ax, ay, az, bx, by, bz, color, isSub)
      encoded[#encoded + 1] = isSub
        and string.format("{%.7g,%.7g,%.7g,%.7g,%.7g,%.7g,%d,1}",
          ax, ay, az, bx, by, bz, color)
        or string.format("{%.7g,%.7g,%.7g,%.7g,%.7g,%.7g,%d}",
          ax, ay, az, bx, by, bz, color)
    end
  end

  function renderer.syncBestLapLine()
    if not object.queueGameEngineLua then return end
    local entry = bestGhostEntry(false)
    state.bestLapLineReady = entry ~= nil
    state.bestLapLineSourceLabel = entry and entry.label or nil
    local encoded = {}

    if state.bestLapLineVisible and entry and ensureGhostSamples(entry) then
      local points = entry.samples
      if entry.groundOffset == nil and #points > 0 then
        local first = points[1]
        entry.groundOffset = first[POS_Z]
          - state.groundHeightAt(first[POS_X], first[POS_Y], first[POS_Z])
      end
      local groundOffset = tonumber(entry.groundOffset) or 0

      -- Curvature-adaptive: keep detail only where the path bends. Raise the
      -- tolerance if an unusually long/twisty lap would still exceed the segment
      -- budget, so the drawn line never overflows the renderer cap.
      -- In input mode, keep the samples that mark gear/handbrake edges and fast
      -- pedal swings so those colour details survive simplification.
      local keepPredicate = getTrailMode() == "inputs" and buildInputKeepPredicate(points) or nil

      local tolerance = BEST_LAP_TOLERANCE
      local kept = simplifyByCurvature(points, tolerance, keepPredicate)
      while #kept - 1 > MAX_BEST_LAP_SEGMENTS and tolerance < BEST_LAP_MAX_TOLERANCE do
        tolerance = tolerance * 1.8
        kept = simplifyByCurvature(points, tolerance, keepPredicate)
      end

      local function encodeSegment(ax, ay, az, bx, by, bz, colorIndex)
        encoded[#encoded + 1] = string.format(
          "{%.7g,%.7g,%.7g,%.7g,%.7g,%.7g,%d}",
          ax, ay, az - groundOffset + 0.045,
          bx, by, bz - groundOffset + 0.045,
          colorIndex
        )
      end

      -- Main line: throttle/brake/coast/both only. Gear shifts and handbrake are
      -- excluded here and drawn as their own marks below.
      emitSmoothLine(kept, MAX_BEST_LAP_SEGMENTS, function(first, second, ax, ay, az, bx, by, bz)
        encodeSegment(ax, ay, az, bx, by, bz, ghostTrailColorIndex(entry, first, second, nil, true))
      end)

      -- Driver-input overlays: a short pink/purple tick at each gear shift, the
      -- optional teal clutch sub-line to the right, and the optional blue handbrake
      -- sub-line to the left. Only in input mode, since they read the recorded
      -- inputs; each walks the raw samples so brief events are not lost.
      if getTrailMode() == "inputs" then
        emitInputOverlays(points, entry.sampleInterval, groundOffset, encoded,
          lineOverlayEncoder(encoded))
      end
    end

    object:queueGameEngineLua(
      "if extensions and extensions.ghostlapping and " ..
        "extensions.ghostlapping.setBestLapLineSegments then " ..
        "extensions.ghostlapping.setBestLapLineSegments({" .. table.concat(encoded, ",") ..
        "}," .. tostring(state.bestLapLineVisible and #encoded > 0) .. "," ..
        state.senderLiteral() .. ") end"
    )
  end

  function renderer.setBestLapLineVisible(value)
    state.bestLapLineVisible = value == true
    renderer.syncBestLapLine()
    return true
  end

  function renderer.setClutchLineVisible(value)
    state.clutchLineVisible = value == true
    renderer.syncBestLapLine()
    return true
  end

  function renderer.setHandbrakeLineVisible(value)
    state.handbrakeLineVisible = value == true
    renderer.syncBestLapLine()
    return true
  end

  -- Debug aid: draw the live vehicle's own recorded trajectory behind it, always
  -- coloured by driver inputs, downsampled to at most maxSegments so the whole
  -- current lap fits a bounded number of segments. Pushed while recording; called
  -- with visible=false to clear.
  function renderer.syncLiveInputTrail(points, groundOffset, maxSegments, visible)
    if not object.queueGameEngineLua then return end
    local encoded = {}
    if visible and type(points) == "table" and #points >= 2 then
      local budget = math.max(2, math.floor(tonumber(maxSegments) or 500))
      local offset = tonumber(groundOffset) or 0
      local liveEntry = {hasSpeed = true}
      -- Smooth the raw buffer points directly, without curvature simplification.
      -- Re-simplifying the rolling buffer each rebuild chose different points every
      -- time, which reassigned segment colours and made the line flicker. On the
      -- fixed buffer points each keeps its colour; only the head/tail change as the
      -- window rolls. Draw newest to oldest so an over-budget line drops the oldest
      -- part and the recent trail near the car stays.
      local recentFirst = {}
      for index = #points, 1, -1 do recentFirst[#recentFirst + 1] = points[index] end
      local _, lastDrawn = emitSmoothLine(recentFirst, budget,
        function(first, second, ax, ay, az, bx, by, bz)
          encoded[#encoded + 1] = string.format(
            "{%.7g,%.7g,%.7g,%.7g,%.7g,%.7g,%d}",
            ax, ay, az - offset + 0.05,
            bx, by, bz - offset + 0.05,
            ghostTrailColorIndex(liveEntry, first, second, "inputs", true)
          )
        end)
      -- Same driver-input overlays as the best-lap line, but only over the span
      -- the main line actually reached. The main line inflates (smoothing adds
      -- pieces) and stops at the budget partway through the buffer; walking the
      -- whole buffer for the overlays would leave clutch/handbrake sub-lines
      -- hanging past the end of the main line where its tail was dropped.
      -- recentFirst is newest-first, so recentFirst[lastDrawn] is the oldest point
      -- still drawn; its index in the forward buffer is #points - lastDrawn + 1.
      local firstCovered = math.max(1, #points - lastDrawn + 1)
      local coveredPoints = {}
      for index = firstCovered, #points do coveredPoints[#coveredPoints + 1] = points[index] end
      -- The user's max-segment setting is a TOTAL budget: the main line takes
      -- priority above, and the overlays fill only what is left up to it.
      emitInputOverlays(coveredPoints, nil, offset, encoded, lineOverlayEncoder(encoded), budget)
    end
    object:queueGameEngineLua(
      "if extensions and extensions.ghostlapping and " ..
        "extensions.ghostlapping.setLiveInputTrailSegments then " ..
        "extensions.ghostlapping.setLiveInputTrailSegments({" .. table.concat(encoded, ",") ..
        "}," .. tostring(#encoded > 0) .. "," .. state.senderLiteral() .. ") end"
    )
  end

  function renderer.trailSampleIndexAtOrBefore(points, time, hint)
    local index = clamp(tonumber(hint) or #points, 1, #points)
    while index > 1 and (points[index][TIME] or 0) > time do index = index - 1 end
    while index < #points and (points[index + 1][TIME] or 0) <= time do
      index = index + 1
    end
    return index
  end

  -- Returns the index the window search settled on, so a caller that repeats a
  -- window every frame can hand it back as the next hint. The search is linear
  -- from the hint, so a hint that never moves makes the scan grow without bound.
  function renderer.appendGhostTrailWindow(entry, encodedSegments, windowStart, windowEnd, hint)
    local points = entry.samples
    if windowEnd <= 0 or windowEnd < windowStart then return end

    local secondIndex = renderer.trailSampleIndexAtOrBefore(points, windowEnd, hint)
    local resolvedIndex = secondIndex
    if secondIndex <= 1 then return resolvedIndex end
    local interval = tonumber(entry.sampleInterval)
      or math.max((points[2][TIME] or 0) - (points[1][TIME] or 0), 0.01)
    local stride = math.max(1, math.floor(trailInterval / interval + 0.5))

    if entry.groundOffset == nil then
      local head = points[secondIndex]
      entry.groundOffset = head[POS_Z]
        - state.groundHeightAt(head[POS_X], head[POS_Y], head[POS_Z])
    end
    local groundOffset = tonumber(entry.groundOffset) or 0
    local best = entry.isBest and 1 or 0
    local tier = entry.trailBrightnessTier or 5
    local function emitTrailPiece(first, second, ax, ay, az, bx, by, bz)
      encodedSegments[#encodedSegments + 1] = string.format(
        "{%.7g,%.7g,%.7g,%.7g,%.7g,%.7g,%d,%d,%d}",
        ax, ay, az - groundOffset + 0.045,
        bx, by, bz - groundOffset + 0.045,
        ghostTrailColorIndex(entry, first, second, nil, true),
        best, tier
      )
    end

    -- Anchor the downsampling to an absolute index grid (multiples of stride) so
    -- the trail body is identical frame to frame instead of shimmering as the
    -- playback head advances. The body is Catmull-smoothed through the grid points
    -- alone (so the moving head cannot bend it), the same curve the best-lap line
    -- uses; the head is a straight tail piece to the exact interpolated position.
    local headGrid = secondIndex - (secondIndex % stride)
    if headGrid < 1 then headGrid = 1 end

    if headGrid < secondIndex then
      local headSample = points[secondIndex]
      local nextSample = points[secondIndex + 1]
      local hx, hy, hz = headSample[POS_X], headSample[POS_Y], headSample[POS_Z]
      if nextSample then
        local t0 = headSample[TIME] or 0
        local t1 = nextSample[TIME] or t0
        local frac = t1 > t0 and clamp((windowEnd - t0) / (t1 - t0), 0, 1) or 0
        hx = headSample[POS_X] + (nextSample[POS_X] - headSample[POS_X]) * frac
        hy = headSample[POS_Y] + (nextSample[POS_Y] - headSample[POS_Y]) * frac
        hz = headSample[POS_Z] + (nextSample[POS_Z] - headSample[POS_Z]) * frac
      end
      local gridPoint = points[headGrid]
      emitTrailPiece(gridPoint, headSample,
        gridPoint[POS_X], gridPoint[POS_Y], gridPoint[POS_Z], hx, hy, hz)
    end

    local gridIndices = {}
    local gridIndex = headGrid
    while gridIndex >= 1 and (points[gridIndex][TIME] or 0) >= windowStart do
      gridIndices[#gridIndices + 1] = gridIndex
      if gridIndex == 1 then break end
      local nextIndex = math.max(1, gridIndex - stride)
      if nextIndex == gridIndex then break end
      gridIndex = nextIndex
    end
    local controlPoints = {}
    for order = #gridIndices, 1, -1 do
      controlPoints[#controlPoints + 1] = points[gridIndices[order]]
    end
    emitSmoothLine(controlPoints, MAX_TRAIL_WINDOW_SEGMENTS, emitTrailPiece)

    -- Same driver-input overlays as the best-lap line, over the raw samples inside
    -- this window: a shift tick and the optional clutch/handbrake sub-lines. Even a
    -- 3s tail reads well because the camera stays locked on the ghost. Encoded as
    -- 10 fields: the 8th (halo) is off and the 9th carries the ghost's brightness
    -- tier so overlays dim with it; the 10th flags a thin sub-line piece.
    if getTrailMode() == "inputs" then
      local firstGrid = gridIndices[#gridIndices] or headGrid
      local overlayPoints = {}
      for order = firstGrid, secondIndex do
        overlayPoints[#overlayPoints + 1] = points[order]
      end
      emitInputOverlays(overlayPoints, interval, groundOffset, encodedSegments,
        function(ax, ay, az, bx, by, bz, color, isSub)
          encodedSegments[#encodedSegments + 1] = string.format(
            "{%.7g,%.7g,%.7g,%.7g,%.7g,%.7g,%d,%d,%d,%d}",
            ax, ay, az, bx, by, bz, color, 0, tier, isSub and 1 or 0)
        end)
    end
    return resolvedIndex
  end

  local function collectGhostTrail(entry, encodedSegments, runtime)
    if not encodedSegments or not runtime.ghostTrailVisible
        or not entry or not entry.displayed then return end
    local points = entry.samples
    if type(points) ~= "table" or #points < 2 then return end

    local duration = tonumber(entry.duration) or tonumber(points[#points][TIME]) or 0
    if duration <= 0 then return end
    local absoluteNow = math.max(0, state.trailPlaybackElapsed)
    local earliest = math.max(0, absoluteNow - runtime.ghostTrailSeconds)
    local cycleStart = 0

    if runtime.loopPlayback and runtime.playing and runtime.playbackDuration > 0 then
      cycleStart = math.max(0, absoluteNow - runtime.playbackElapsed)
      if cycleStart > 0 then
        local previousStart = cycleStart - runtime.playbackDuration
        local previousWindowStart = math.max(earliest, previousStart)
        local previousWindowEnd = math.min(absoluteNow, previousStart + duration)
        if previousWindowEnd >= previousWindowStart then
          -- Hinting with #points made this scan backwards from the end of the
          -- recording on every trail update. Remembering where the previous
          -- cycle's window landed keeps the search incremental, the same reason
          -- the current window follows the playback cursor.
          entry.previousCycleCursor = renderer.appendGhostTrailWindow(
            entry, encodedSegments,
            previousWindowStart - previousStart,
            previousWindowEnd - previousStart,
            entry.previousCycleCursor or #points
          )
        end
      end
    end

    local currentWindowStart = math.max(earliest, cycleStart)
    local currentWindowEnd = math.min(absoluteNow, cycleStart + duration)
    if currentWindowEnd >= currentWindowStart then
      renderer.appendGhostTrailWindow(
        entry, encodedSegments,
        currentWindowStart - cycleStart,
        currentWindowEnd - cycleStart,
        entry.cursor
      )
    end
  end

  function renderer.draw(encodedTrailSegments, runtime)
    local playbackIndex = runtime.playbackIndex
    if (not runtime.playing and not state.ghostTrailLingering)
        or not runtime.visible then return playbackIndex end

    if #runtime.ghostLibrary > 0 then
      for index = 1, #runtime.ghostLibrary do
        local entry = runtime.ghostLibrary[index]
        local shelled = type(runtime.shelledGhostIds) == "table"
          and runtime.shelledGhostIds[tostring(entry.id)] == true
        if runtime.playing and entry.displayed
            and runtime.playbackElapsed <= (tonumber(entry.duration) or 0) then
          if shelled then
            -- The wireframe pass is what keeps this cursor current, and the
            -- trail below uses it as the hint for a linear search. Skipping the
            -- draw for a Ghost rendered as a native body used to freeze the
            -- cursor, so every trail update rescanned from that stale index all
            -- the way to the current playback position -- a cost that grows
            -- linearly with how long the replay has been running. That is why
            -- the frame rate decayed over time only while a body was on screen,
            -- stayed fine right after Ctrl+L, and did so even with one Ghost.
            entry.cursor = renderer.trailSampleIndexAtOrBefore(
              entry.samples, runtime.playbackElapsed, entry.cursor
            )
          else
            entry.cursor = drawGhostSamples(
              entry.samples,
              entry.cursor,
              entry.debugColor or runtime.debugColor
            )
          end
        end
        if entry.displayed then collectGhostTrail(entry, encodedTrailSegments, runtime) end
      end
    elseif runtime.playing and #runtime.playbackPoints >= 2 then
      playbackIndex = drawGhostSamples(
        runtime.playbackPoints,
        playbackIndex,
        runtime.debugColor
      )
    end
    return playbackIndex
  end

  return renderer
end

return M
