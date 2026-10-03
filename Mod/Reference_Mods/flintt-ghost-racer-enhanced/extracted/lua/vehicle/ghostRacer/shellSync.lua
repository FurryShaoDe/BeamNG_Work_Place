-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Vehicle-side bookkeeping for the GE shell renderer.
--
-- Poses are deliberately NOT sent. The wireframe is smooth because it resolves
-- a pose and draws it in the same frame inside one VM. A pose pushed over the
-- queued bridge always arrives late and in bursts, which no amount of
-- smoothing turns back into steady motion. So the renderer is told which
-- Ghosts to show and where their recordings already live on disk, and it
-- resolves poses from that data in GE. Only the playback
-- clock crosses the bridge, and only when it cannot be predicted.

local M = {}

function M.new(options)
  options = options or {}
  local object = assert(options.object, "vehicle object is required")
  local maximumGhosts = assert(options.maximumGhosts, "shell limit is required")
  -- Stamps the sender so GE can drop a push from a native Ghost vehicle that
  -- loaded this controller in its own VM. See startGateConfig.senderLiteral.
  local senderLiteral = assert(options.senderLiteral, "sender literal is required")

  local sync = {}
  local lastSetSignature = nil
  local lastPrewarmSignature = nil
  local lastClockSent = nil
  local lastPlayingSent = nil
  local lastDurationSent = nil
  local lastLoopingSent = nil

  local function queue(command)
    if not object.queueGameEngineLua then return false end
    object:queueGameEngineLua(
      "if extensions and extensions.ghostlapping and " ..
        "extensions.ghostlapping." .. command .. " end"
    )
    return true
  end

  -- Appended as the final argument of every shell bridge call.
  local function sender()
    return "," .. senderLiteral()
  end

  -- A Ghost library stores the sanitised vehicle directory, because that is
  -- what names the folder its replays live in: "/vehicles/vivace/" is written
  -- as "_vehicles_vivace_". Native vehicle spawning needs the original model
  -- key, and recovering it here keeps every existing recording usable without
  -- a metadata migration.
  function sync.vehicleModelName(value)
    value = tostring(value or "")
    if value == "" or value == "unknown_vehicle" then return nil end
    local model = value:match("^/?vehicles/([^/]+)/?$")
      or value:match("^_*vehicles_(.-)_*$")
      or value
    model = model:gsub("^_+", ""):gsub("_+$", "")
    if model == "" or model == "unknown" then return nil end
    return model
  end

  local function encodeEntries(entries)
    local descriptors = {}
    local signature = {}
    for index = 1, math.min(#entries, maximumGhosts) do
      local entry = entries[index]
      local model = sync.vehicleModelName(entry.vehicle) or ""
      -- The recording is already on disk, so the renderer reads it directly
      -- instead of having every sample marshalled across the bridge.
      descriptors[#descriptors + 1] = string.format(
        "{id=%q,model=%q,config=%q,file=%q}",
        tostring(entry.id or ""),
        model,
        tostring(entry.config or ""),
        tostring(entry.file or "")
      )
      signature[#signature + 1] = tostring(entry.id) .. ":" .. model
        .. ":" .. tostring(entry.config or "") .. ":" .. tostring(entry.file or "")
    end
    return descriptors, table.concat(signature, "|")
  end

  -- The set changes far less often than the clock, so it is only resent when
  -- it actually differs.
  function sync.pushSet(entries)
    local descriptors, joined = encodeEntries(entries)
    if joined == lastSetSignature then return false end
    lastSetSignature = joined
    return queue(
      "setGhostShellSet then extensions.ghostlapping.setGhostShellSet({"
        .. table.concat(descriptors, ",") .. "}" .. sender() .. ")"
    )
  end

  -- Ask GE to allocate expensive native vehicles while no replay is running.
  -- Signatures keep the per-frame controller update from restarting a queued
  -- prewarm before all requested bodies have been created.
  function sync.pushPrewarm(entries)
    local descriptors, joined = encodeEntries(entries)
    if joined == "" or joined == lastPrewarmSignature then return false end
    lastPrewarmSignature = joined
    return queue(
      "prewarmGhostShellSet then extensions.ghostlapping.prewarmGhostShellSet({"
        .. table.concat(descriptors, ",") .. "}" .. sender() .. ")"
    )
  end

  -- The renderer advances and loops the clock itself between updates, so this
  -- only has to establish playback state and correct discontinuities such as a
  -- seek. Supplying the duration is important: waiting for a queued post-loop
  -- clock used to leave every body deleted at the end of each lap.
  --
  -- The interval is what makes that work. Sending every frame would have the
  -- renderer correcting towards a value that is always one bridge hop stale
  -- while it is also advancing locally, and those two fight: the playback rate
  -- oscillates and the body surges. Playback runs on simulation time, so an
  -- interval expressed in elapsed seconds is a rate limit.
  local CLOCK_INTERVAL_SECONDS = 0.25

  function sync.pushClock(elapsed, playing, duration, looping, force)
    elapsed = tonumber(elapsed) or 0
    playing = playing == true
    duration = math.max(tonumber(duration) or 0, 0)
    looping = looping == true and duration > 0
    local playbackChanged = playing ~= lastPlayingSent
      or duration ~= lastDurationSent
      or looping ~= lastLoopingSent
    if not force and not playbackChanged and lastClockSent
        and math.abs(elapsed - lastClockSent) < CLOCK_INTERVAL_SECONDS then
      return false
    end
    lastClockSent = elapsed
    lastPlayingSent = playing
    lastDurationSent = duration
    lastLoopingSent = looping
    return queue(string.format(
      "setGhostShellClock then extensions.ghostlapping.setGhostShellClock(%.4f,%s,%.4f,%s,%s%s)",
      elapsed, tostring(playing), duration, tostring(looping), tostring(force == true),
      sender()
    ))
  end

  function sync.clearShells()
    lastSetSignature = ""
    lastClockSent = nil
    lastPlayingSent = nil
    lastDurationSent = nil
    lastLoopingSent = nil
    return queue(
      "setGhostShellSet then extensions.ghostlapping.setGhostShellSet({}"
        .. sender() .. ")"
    )
  end

  function sync.releasePool()
    sync.reset()
    return queue(
      "releaseGhostShellPool then extensions.ghostlapping.releaseGhostShellPool("
        .. senderLiteral() .. ")"
    )
  end

  -- After a reset the renderer's state is unknown, so the next push of either
  -- channel has to actually go out.
  function sync.reset()
    lastSetSignature = nil
    lastPrewarmSignature = nil
    lastClockSent = nil
    lastPlayingSent = nil
    lastDurationSent = nil
    lastLoopingSent = nil
  end

  return sync
end

return M
