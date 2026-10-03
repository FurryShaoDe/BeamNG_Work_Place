-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Original Ghost Racer Replay by Jesus Goose.
-- Loader reliability modifications by flintt, 2026.

local M = {}

local function methodResult(name)
  local method = obj and obj[name]
  if type(method) ~= "function" then return nil end
  local ok, value = pcall(method, obj)
  if not ok then return nil end
  return tostring(value or "")
end

local function isNativeGhostVehicle()
  -- Checked first because it is the only signal observed to be populated this
  -- early. In 2.15.2 this guard relied on getName/getJBeamFilename alone and
  -- silently failed: every spawned Ghost vehicle still loaded a full
  -- controller, which the GE log showed as three extra `controller.init` lines
  -- with vehicleDirectory=/vehicles/simple_traffic/.
  --
  -- simple_traffic is BeamNG's optimized AI-only representation. A player never
  -- drives one, so it must not own Saved Starts, claim the HUD, or push world
  -- state to GE.
  local directory = v and v.data and v.data.vehicleDirectory
  if type(directory) == "string"
      and directory:lower():find("simple_traffic", 1, true) then
    return true
  end

  -- `vehicleName` is supplied during spawn, so getName is the natural check.
  -- Kept as a secondary signal for builds where it is available in time.
  local name = methodResult("getName")
  if name and name:find("^GhostRacerShell_") then return true end

  local jbeam = methodResult("getJBeamFilename")
  if jbeam and jbeam:lower():find("simple_traffic", 1, true) then return true end
  return false
end

local function ensureControllerLoaded()
  if isNativeGhostVehicle() then return end
  local existing = controller.getController and controller.getController("ghostRacer")
  if existing and existing.startRecording then return end

  controller.loadControllerExternal("ghostRacer", "ghostRacer", {})
end

M.onExtensionLoaded = ensureControllerLoaded
M.onReset = ensureControllerLoaded

return M
