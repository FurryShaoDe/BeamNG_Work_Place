-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Original Ghost Racer Replay by Jesus Goose.
-- Persistence modifications by flintt, 2026.

local M = {}

local function sanitizePathPart(value, fallback)
  value = tostring(value or fallback or "unknown")
  value = value:gsub("[^%w%._%-]", "_")
  value = value:gsub("_+", "_")
  if value == "" then return fallback or "unknown" end
  return value
end

local function readLapTime(filename)
  if not filename then return nil end

  local replay = jsonReadFile(filename)
  if type(replay) == "table" and tonumber(replay.lapTime) then
    return tonumber(replay.lapTime)
  end

  return tonumber((jsonReadFile(filename .. ".time") or {})[1])
end

local function replayExists(filename)
  if not filename then return false end
  local replay = jsonReadFile(filename)
  return type(replay) == "table" and next(replay) ~= nil
end

local function currentLevelName()
  if type(getCurrentLevelIdentifier) == "function" then
    return sanitizePathPart(getCurrentLevelIdentifier(), "unknown_level")
  end
  return "unknown_level"
end

local function resolveRaceFiles(raceName)
  local safeRaceName = sanitizePathPart(raceName, "temp")
  local levelName = currentLevelName()
  local preferred = string.format(
    "ghostReplays/races/%s/%s/ghostracer.save.json",
    levelName,
    safeRaceName
  )

  -- Import old 1.6 saves transparently. New personal bests are written to the
  -- level-scoped path so equal race suffixes on different maps cannot collide.
  local legacy = string.format("ghostReplays/%s/ghostracer.save.json", safeRaceName)
  local loadFilename = preferred
  if not replayExists(preferred) and replayExists(legacy) then
    loadFilename = legacy
  end

  return {
    loadFilename = loadFilename,
    saveFilename = preferred,
    pbTime = readLapTime(loadFilename),
    persistent = safeRaceName ~= "temp",
    raceName = safeRaceName,
    levelName = levelName
  }
end

M.sanitizePathPart = sanitizePathPart
M.readLapTime = readLapTime
M.loadTime = readLapTime -- 1.6 compatibility
M.replayExists = replayExists
M.resolveRaceFiles = resolveRaceFiles

return M
