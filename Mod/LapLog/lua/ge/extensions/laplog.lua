-- LapLog -- game-engine extension.
--
-- The vehicle VM owns every recording decision; this side only provides the two
-- things that VM cannot do for itself: drawing the start/finish gate beams in the
-- world, and rendering a toast that survives a vehicle reset (a message fired from
-- a vehicle VM mid-reset is wiped by the game's own reset UI teardown).
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

local CODE_VERSION = "1.0.0"

-- The upstream extension needed core_camera (Ghost chase camera) and a sibling
-- ghostRecord extension (race PB files). Neither exists here, so M.dependencies
-- stays empty on purpose.

-- BeamNG can reload an extension without clearing that VM's package.loaded. Drop
-- our own submodule first so Ctrl+L cannot pair a new extension body with a stale
-- renderer.
if package and type(package.loaded) == "table" then
  package.loaded["ge/lapLog/markerRenderer"] = nil
end

local markerRenderer = require("ge/lapLog/markerRenderer").new()

local playerVehicleId = nil

function M.trace(area, formatString, ...)
  if type(log) ~= "function" then return end
  local ok, message = pcall(string.format, tostring(formatString), ...)
  if not ok then
    message = tostring(formatString) .. " [format-error=" .. tostring(message) .. "]"
  end
  log("I", "LapLogDiag.GE", string.format(
    "[v%s][%s][vehicle=%s] %s",
    CODE_VERSION,
    tostring(area or "general"),
    tostring(playerVehicleId or "none"),
    tostring(message)
  ))
end

-- World marker state is pushed from whichever vehicle the player is driving. An AI
-- traffic vehicle also loads the recorder, and its empty state would otherwise
-- blank the beams, so every push is stamped and rejected unless it comes from the
-- player's own vehicle.
--
-- A nil stamp is accepted: a build where the object id cannot be read keeps
-- behaving exactly as it did before. The id is also re-resolved on a mismatch
-- rather than rejected outright, because nothing re-stamps it when the player
-- switches vehicles and that would otherwise lose the beams.
local function sentByPlayerVehicle(senderId)
  if senderId == nil then return true end
  if playerVehicleId == nil and type(getPlayerVehicle) == "function" then
    local ok, vehicle = pcall(getPlayerVehicle, 0)
    if ok and vehicle and type(vehicle.getId) == "function" then
      local idOk, id = pcall(vehicle.getId, vehicle)
      if idOk and id ~= nil then playerVehicleId = tostring(id) end
    end
  end
  if playerVehicleId == nil then return true end
  return tostring(senderId) == tostring(playerVehicleId)
end

-- ---------------------------------------------------------------------------
-- Vehicle -> game-engine bridge
-- ---------------------------------------------------------------------------

-- Replace the gate marker set. `markers` is a list of encoded literals built by
-- the vehicle controller; see its syncMarkers() for the field list.
function M.setFreeRoamMarkers(markers, savedVisible, activeVisible, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  return markerRenderer.setMarkers(markers, savedVisible, activeVisible) > 0
end

-- Toast rendered on the next game-engine frame, i.e. after a vehicle reset has
-- settled. This is the only way a message from the vehicle VM reliably reaches the
-- player in that situation.
function M.showLapLogMessage(message, seconds, senderId)
  if not sentByPlayerVehicle(senderId) then return false end
  if type(guihooks) == "table" and type(guihooks.message) == "function" then
    guihooks.message({txt = tostring(message)}, tonumber(seconds) or 3)
  end
  return true
end

function M.onPreRender()
  markerRenderer.onPreRender()
end

-- ---------------------------------------------------------------------------
-- UI layout cleanup
-- ---------------------------------------------------------------------------

-- When the mod is disabled its UI app would otherwise stay in the player's saved
-- layouts as a dead entry, so it has to be stripped on the way out.
local function isLapLogAppName(value)
  if value == nil then return false end
  local compact = tostring(value):lower():gsub("[^%w]", "")
  return compact:find("laplogapp", 1, true) ~= nil
end

local function tableIsArray(value)
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" then return false end
    count = count + 1
    if key > maximum then maximum = key end
  end
  return count == maximum
end

local function stripAppFromLayout(value)
  if type(value) ~= "table" then return value, 0 end
  local removed = 0
  if tableIsArray(value) then
    local result = {}
    for index = 1, #value do
      local child = value[index]
      if type(child) == "table"
          and (isLapLogAppName(child.appName) or isLapLogAppName(child.directive)) then
        removed = removed + 1
      else
        local cleaned, childRemoved = stripAppFromLayout(child)
        result[#result + 1] = cleaned
        removed = removed + childRemoved
      end
    end
    return result, removed
  end

  for key, child in pairs(value) do
    if isLapLogAppName(key)
        or (type(child) == "table"
          and (isLapLogAppName(child.appName) or isLapLogAppName(child.directive))) then
      value[key] = nil
      removed = removed + 1
    else
      local cleaned, childRemoved = stripAppFromLayout(child)
      value[key] = cleaned
      removed = removed + childRemoved
    end
  end
  return value, removed
end

function M.removeSavedUiLayoutEntries()
  local removed = 0
  local service = rawget(_G, "ui_apps")
    or (type(extensions) == "table" and extensions.ui_apps)

  if type(service) == "table"
      and type(service.getAvailableLayouts) == "function"
      and type(service.saveLayout) == "function" then
    local ok, layouts = pcall(service.getAvailableLayouts)
    if ok and type(layouts) == "table" then
      for index = 1, #layouts do
        local cleaned, layoutRemoved = stripAppFromLayout(layouts[index])
        if layoutRemoved > 0 then
          local saved = pcall(service.saveLayout, cleaned)
          if saved then removed = removed + layoutRemoved end
        end
      end
      if type(service.requestUIAppsData) == "function" then
        pcall(service.requestUIAppsData)
      end
      return removed
    end
  end

  -- Older builds expose no layout service; fall back to editing the files.
  if not FS or type(FS.findFiles) ~= "function" then return removed end
  local ok, filenames = pcall(
    FS.findFiles, FS, "/settings/ui_apps/layouts/", "*.uilayout.json", -1, false, false
  )
  if not ok or type(filenames) ~= "table" then return removed end
  for index = 1, #filenames do
    local filename = filenames[index]
    local layout = jsonReadFile(filename)
    if type(layout) == "table" then
      local cleaned, layoutRemoved = stripAppFromLayout(layout)
      if layoutRemoved > 0 and jsonWriteFile(filename, cleaned, true) ~= false then
        removed = removed + layoutRemoved
      end
    end
  end
  return removed
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Registered by scripts/laplog/modScript.lua with setExtensionUnloadMode(...
-- "manual"), so unloading is this extension's own responsibility.
function M.onExtensionUnloaded()
  markerRenderer.clear()
end

function M.onClientEndMission()
  markerRenderer.clear()
  M.trace("lifecycle", "client end mission")
end

function M.onUiClosed()
  markerRenderer.clear()
end

function M.onFilesChanged()
  -- Deliberately does NOT clear the beam set here.
  --
  -- This hook fires for every file the mod writes, registry saves and ghost
  -- saves included. Clearing on those made the start gate vanish right after
  -- the first completed lap: the lap save triggers this hook, the marker push
  -- in updateActiveStats follows asynchronously, and whichever lands last wins
  -- (2026-10-04 log: four "files changed" at lap-completion time).
  --
  -- A real Lua reload re-runs this whole file and re-requires the renderer
  -- (see the top of this file), so a stale beam set cannot survive that path
  -- anyway. Clearing also stays in onUiClosed / onModDeactivated, where the
  -- beams genuinely must go away.
  return true
end

local function isLapLogMod(mod)
  local identifiers
  if type(mod) == "table" then
    identifiers = {
      mod.modname, mod.filename, mod.fullpath, mod.dirname, mod.path, mod.name
    }
  elseif type(mod) == "string" then
    identifiers = {mod}
  else
    return false
  end
  for index = 1, #identifiers do
    local value = tostring(identifiers[index] or ""):lower():gsub("\\", "/")
    if value:find("laplog", 1, true) then return true end
  end
  return false
end

function M.onModDeactivated(mod)
  if not isLapLogMod(mod) then return false end
  local removed = M.removeSavedUiLayoutEntries()
  markerRenderer.clear()
  M.trace("lifecycle", "mod deactivated, layout entries removed=%d", removed)
  return true
end

return M
