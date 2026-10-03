-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Context-owned visual settings for one Ghost Racer vehicle controller.

local M = {}

function M.new(options)
  options = options or {}
  local colorFactory = assert(options.colorFactory, "display color factory is required")
  local defaultColor = assert(options.defaultColor, "default display color is required")
  local validDisplayModes = assert(options.validDisplayModes, "display modes are required")
  local validTopCounts = assert(options.validTopCounts, "Top N counts are required")
  local clamp = assert(options.clamp, "display clamp function is required")
  local minimumTrailSeconds = assert(options.minimumTrailSeconds, "minimum trail length is required")
  local maximumTrailSeconds = assert(options.maximumTrailSeconds, "maximum trail length is required")

  local state = {
    visible = true,
    loopPlayback = false,
    startGateVisible = true,
    ghostTrailVisible = false,
    ghostTrailMode = "speed",
    ghostTrailSeconds = assert(options.defaultTrailSeconds, "default trail length is required"),
    quality = 6,
    colorName = "orange",
    debugColor = colorFactory(defaultColor[1], defaultColor[2], defaultColor[3], defaultColor[4]),
    ghostDisplayMode = "best",
    topGhostCount = 3,
    -- Category axis, orthogonal to the display mode (amount). "complete" shows
    -- only finished laps, "incomplete" only partials, "both" everything. The
    -- older boolean showIncomplete is kept below as a derived mirror
    -- (showIncomplete == filter is not "complete") so the many call sites that
    -- only ask "are partials visible?" keep working unchanged.
    ghostCategoryFilter = "complete",
    showIncomplete = false,
    showManual = true,
    ghostRenderMode = "wireframe"
  }

  local VALID_CATEGORY_FILTERS = {complete = true, incomplete = true, both = true}

  function state.snapshot()
    return {
      visible = state.visible,
      loopPlayback = state.loopPlayback,
      startGateVisible = state.startGateVisible,
      trailVisible = state.ghostTrailVisible,
      trailMode = state.ghostTrailMode,
      trailSeconds = state.ghostTrailSeconds,
      quality = state.quality,
      colorName = state.colorName,
      ghostDisplayMode = state.ghostDisplayMode,
      topGhostCount = state.topGhostCount,
      ghostCategoryFilter = state.ghostCategoryFilter,
      showIncomplete = state.showIncomplete,
      showManual = state.showManual,
      ghostRenderMode = state.ghostRenderMode
    }
  end

  function state.setVisible(value)
    state.visible = value ~= false
    return state.visible
  end

  function state.setLoopPlayback(value)
    state.loopPlayback = value == true
    return state.loopPlayback
  end

  function state.setStartGateVisible(value)
    state.startGateVisible = value ~= false
    return state.startGateVisible
  end

  function state.setGhostTrailVisible(value)
    state.ghostTrailVisible = value == true
    return state.ghostTrailVisible
  end

  function state.setGhostTrailMode(mode)
    mode = tostring(mode or "")
    if mode ~= "speed" and mode ~= "acceleration" and mode ~= "inputs" then return false end
    state.ghostTrailMode = mode
    return true
  end

  function state.setGhostTrailSeconds(value)
    value = tonumber(value)
    if not value then return false end
    state.ghostTrailSeconds = clamp(
      math.floor(value + 0.5),
      minimumTrailSeconds,
      maximumTrailSeconds
    )
    return true
  end

  function state.setQuality(value)
    state.quality = clamp(math.floor(tonumber(value) or state.quality), 1, 10)
    return state.quality
  end

  function state.setColorPreset(name, presets)
    local preset = type(presets) == "table" and presets[name] or nil
    if not preset then return false end
    state.colorName = name
    state.debugColor = colorFactory(preset[1], preset[2], preset[3], preset[4])
    return true
  end

  function state.setGhostDisplayMode(mode)
    mode = tostring(mode or "")
    if not validDisplayModes[mode] then return false end
    state.ghostDisplayMode = mode
    return true
  end

  function state.setTopGhostCount(value)
    local requested = math.floor(tonumber(value) or 0)
    if not validTopCounts[requested] then return false end
    state.topGhostCount = requested
    return true
  end

  -- The three-way category filter is the source of truth; keep showIncomplete as
  -- a derived mirror so existing "are partials visible?" checks keep working.
  function state.setGhostCategoryFilter(value)
    value = tostring(value or "")
    if not VALID_CATEGORY_FILTERS[value] then return false end
    state.ghostCategoryFilter = value
    state.showIncomplete = value ~= "complete"
    return true
  end

  -- Compatibility setter: the boolean cannot express "incomplete only", so it
  -- maps onto complete/both. New callers use setGhostCategoryFilter directly.
  function state.setShowIncomplete(value)
    state.ghostCategoryFilter = (value == true) and "both" or "complete"
    state.showIncomplete = value == true
    return state.showIncomplete
  end

  -- Wireframe is the default: the vehicle shell depends on runtime mesh
  -- instantiation that not every build or vehicle can provide.
  function state.setGhostRenderMode(mode)
    mode = tostring(mode or "")
    if mode ~= "wireframe" and mode ~= "shell" then return false end
    state.ghostRenderMode = mode
    return true
  end

  function state.setShowManual(value)
    state.showManual = value ~= false
    return state.showManual
  end

  return state
end

return M
