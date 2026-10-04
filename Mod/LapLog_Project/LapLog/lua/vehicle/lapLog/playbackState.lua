-- LapLog -- stored-lap library state.
--
-- The upstream mod used this domain for Ghost playback: a clock, a cursor and a
-- set of camera fields. LapLog never plays anything back, so what remains is the
-- library itself: the array of stored laps, the id counter, which file the library
-- is bound to, and the current personal best.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

function M.new()
  local state = {
    points = {},
    ghosts = {},
    nextGhostId = 1,
    activeLibraryFilename = nil,
    pbTime = nil
  }

  function state.snapshot()
    return {
      sampleCount = #state.points,
      ghostCount = #state.ghosts,
      nextGhostId = state.nextGhostId,
      activeLibraryFilename = state.activeLibraryFilename,
      pbTime = state.pbTime
    }
  end

  function state.setPoints(points)
    if type(points) ~= "table" then return nil end
    state.points = points
    return points
  end

  return state
end

return M
