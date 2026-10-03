-- LapLog -- display/list state for one vehicle controller.
--
-- Only the settings that affect what the UI lists survive here. Everything about
-- Ghost rendering (wireframe/TSStatic bodies, trails, best-lap lines, colour
-- presets, quality/LOD) was removed together with the renderer, so there is no
-- render mode to remember and no quality to keep in sync.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

function M.new(options)
  options = options or {}
  local state = {
    -- The start gate is a world marker, not a Ghost, so it stays available: the
    -- player needs to see where the lap begins.
    startGateVisible = true,
    -- Category axis for the stored-lap list. "complete" shows only timed laps,
    -- "incomplete" only partial attempts, "both" everything. showIncomplete is a
    -- derived mirror so the many "are partials visible?" call sites keep working.
    ghostCategoryFilter = "complete",
    showIncomplete = false,
    showManual = true
  }

  local VALID_CATEGORY_FILTERS = {complete = true, incomplete = true, both = true}

  function state.snapshot()
    return {
      startGateVisible = state.startGateVisible,
      ghostCategoryFilter = state.ghostCategoryFilter,
      showIncomplete = state.showIncomplete,
      showManual = state.showManual
    }
  end

  function state.setStartGateVisible(value)
    state.startGateVisible = value ~= false
    return state.startGateVisible
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
  -- maps onto complete/both.
  function state.setShowIncomplete(value)
    state.ghostCategoryFilter = (value == true) and "both" or "complete"
    state.showIncomplete = value == true
    return state.showIncomplete
  end

  function state.setShowManual(value)
    state.showManual = value ~= false
    return state.showManual
  end

  return state
end

return M
