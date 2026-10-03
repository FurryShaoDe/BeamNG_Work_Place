-- LapLog -- vehicle extension that loads the lap-log controller on demand.
--
-- The controller is an external controller, so it is not created with the vehicle.
-- This file lives in lua/vehicle/extensions/auto/, which BeamNG loads for every
-- vehicle, and pulls the controller in the first time the vehicle is spawned or
-- reset. The UI panel also requests the controller directly (see its
-- ensureController) so a panel added to a running session heals itself even if
-- this loader never ran. Both paths log through LapLogDiag, so one grep of the
-- game log says which one loaded the controller -- or why neither could.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

local CONTROLLER_NAME = "lapLog"

local function trace(area, message)
  if type(log) == "function" then
    log("I", "LapLogDiag.Loader", "[" .. tostring(area) .. "] " .. tostring(message))
  end
end

-- pcall wrapper: an absent method or a throwing method must not abort the load.
local function methodResult(object, method, ...)
  if type(object) ~= "table" and type(object) ~= "userdata" then return nil end
  local candidate = nil
  local ok, result = pcall(function() return object[method] end)
  if ok then candidate = result end
  if type(candidate) ~= "function" then return nil end
  local called, value = pcall(candidate, object, ...)
  if not called then return nil end
  return value
end

-- BeamNG simple_traffic vehicles are its AI-only representation. The player never
-- drives one, so loading a full controller into every traffic car would add idle
-- instances to the update path of the whole level.
local function isAiProxyVehicle()
  local data = v and v.data or nil
  if type(data) ~= "table" then return false end
  local directory = data.vehicleDirectory
  if type(directory) ~= "string" then return false end
  return directory:lower():find("simple_traffic", 1, true) ~= nil
end

local function ensureControllerLoaded()
  if isAiProxyVehicle() then return false end
  if not controller or type(controller.getController) ~= "function" then
    trace("skip", "controller manager unavailable")
    return false
  end

  -- getController only hands back a live table once the file has executed, so the
  -- presence of a real method is the reliable "already loaded" signal. The
  -- controller also publishes itself to package.loaded / globals because on
  -- 0.39 the registry lookup can miss it even after init ran.
  local existing = methodResult(controller, "getController", CONTROLLER_NAME)
  if not existing and type(package) == "table" and package.loaded then
    existing = package.loaded["vehicle/controller/lapLog"]
  end
  if not existing then existing = rawget(_G, "lapLogController") end
  if existing and methodResult(existing, "startRecording") ~= nil then
    return true
  end

  -- Probe every plausible registry name once: the name the engine registers an
  -- external controller under is not necessarily the one the panel queries with,
  -- and this single line answers that question for good.
  local probes = { CONTROLLER_NAME, CONTROLLER_NAME:lower() }
  local report = {}
  for i = 1, #probes do
    local hit = methodResult(controller, "getController", probes[i])
    report[#report + 1] = probes[i] .. "=" .. tostring(hit ~= nil)
  end
  trace("probe", table.concat(report, " "))

  -- Loaded with a raw pcall: the error text is exactly what the log needs when
  -- the controller file cannot be resolved or executed.
  local ok, err = pcall(
    controller.loadControllerExternal, CONTROLLER_NAME, CONTROLLER_NAME, {}
  )
  local loaded = methodResult(controller, "getController", CONTROLLER_NAME)
    or (type(package) == "table" and package.loaded
      and package.loaded["vehicle/controller/lapLog"])
    or rawget(_G, "lapLogController")
  trace("load", string.format(
    "ok=%s controller=%s err=%s",
    tostring(ok), tostring(loaded ~= nil), tostring(err)
  ))
  return ok and loaded ~= nil
end

M.onExtensionLoaded = ensureControllerLoaded
M.onReset = ensureControllerLoaded

return M
