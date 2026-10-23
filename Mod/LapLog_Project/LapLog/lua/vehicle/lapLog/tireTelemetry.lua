-- LapLog -- optional per-tyre telemetry tap.
--
-- Tyre temperature and tread wear are not part of the BeamNG vehicle API: wheel
-- rotators carry load, slip angle and a pressure group, but nothing that knows
-- how hot the rubber is. The only code on this machine that does know belongs to
-- Kagoni's Tyre Simulation (third-party mod, internal name
-- `luukstyrethermalsandwear`), which simulates tread/carcass thermals, cavity
-- pressure and physical tread wear per wheel.
--
-- That mod publishes everything it computes by calling
-- `gui.send("TyreWearThermals", stream)` at the end of its `updateGFX`
-- (lua/vehicle/extensions/auto/luukstyrethermalsandwear.lua:15851). Inside the
-- vehicle VM `gui` IS `guihooks` (lua/vehicle/main.lua:252), so the call is just
-- `guihooks.send` = `queueStream` (common/guihooks.lua:205), and it runs on every
-- graphics frame no matter whether the tyre HUD app is open: only the caching
-- inside queueStream is conditional, gated on `streams.hasActiveStreams()`
-- (common/guihooks.lua:106-120). Wrapping `gui.send` therefore hands us the real
-- numbers without needing an API the other mod never exposed, and without
-- editing its files.
--
-- Nothing here is required for LapLog to work. With the mod absent the wrapper
-- still installs (one string compare per gui.send call in this VM) and read()
-- keeps returning nil, so a recording simply carries no tyre columns.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

local M = {}

local STREAM_NAME = "TyreWearThermals"
-- Recorded in the replay envelope so a reader can tell where the numbers came
-- from; a future mod (or a renamed upstream stream) gets its own label.
local SOURCE_ID = "kagoni"
-- Corner order is fixed and matches the load columns of the sample (17-20):
-- front-left, front-right, rear-left, rear-right.
local WHEEL_NAMES = {"FL", "FR", "RL", "RR"}
-- A payload older than this counts as absent. The mod pushes one per graphics
-- frame (~16 ms at 60 fps) and stops when nobody is seated in the car
-- (`firstPlayerSeated`, luukstyrethermalsandwear.lua:83-86), so a second and a
-- half is already generous.
local STALE_SECONDS = 1.5

-- Reused scratch state: the wrapper runs once per graphics frame, so it must not
-- allocate. `slots` holds the four corner entries of the last payload.
local entries = {}
local slots = {nil, nil, nil, nil}
local slotCount = 0
local received = false
local age = STALE_SECONDS + 1

-- Reused output table. The codec copies the numbers into the sample right away,
-- so reading a sample allocates nothing.
local sample = {
  surface = {0, 0, 0, 0},
  core = {0, 0, 0, 0},
  wear = {0, 0, 0, 0}
}

local function finiteNumber(value)
  value = tonumber(value)
  if value == nil or value ~= value then return nil end
  return value
end

-- Tread surface temperature, the way a pyrometer reads it: mean of the three
-- tread zones the mod tracks. Zone order is 1 = outer shoulder, 2 = centre,
-- 3 = inner shoulder (luukstyrethermalsandwear.lua:15622-15624 names them in
-- that order), so a plain mean is the "average tread temperature".
local function surfaceTemperature(entry)
  local zones = entry.surface_temp
  if type(zones) ~= "table" then zones = entry.temp end
  if type(zones) ~= "table" then return nil end
  local sum, count = 0, 0
  for zone = 1, 3 do
    local value = finiteNumber(zones[zone])
    if value ~= nil then
      sum = sum + value
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return sum / count
end

-- Carcass/core temperature: element 4 of the mod's 1D tread field, which is
-- exactly what it reports as `core_temp`
-- (luukstyrethermalsandwear.lua:15115). This is the slow, whole-tyre number;
-- the surface above is the fast one that spikes inside a corner.
local function coreTemperature(entry)
  local temps = entry.temp
  if type(temps) ~= "table" then return nil end
  return finiteNumber(temps[4])
end

-- Remaining tread life in percent: 100 = fresh, 0 = worn through. `condition`
-- is the mod's own number and already accounts for the non-wearable reserve, so
-- it matches what its HUD shows. It is hard-zeroed on a burst tyre (the
-- `isNotDeflated` mask at :15105) because the mod considers that tyre finished,
-- and it is recorded as-is rather than second-guessed. The depth fallback only
-- covers a payload shape without `condition`.
local function wearPercent(entry)
  local condition = finiteNumber(entry.condition)
  if condition ~= nil then return condition end
  local remaining = finiteNumber(entry.tread_remaining_depth_mm)
  local nominal = finiteNumber(entry.tread_nominal_depth_mm)
  if remaining ~= nil and nominal ~= nil and nominal > 0.001 then
    return remaining / nominal * 100
  end
  return nil
end

-- Resolve the four corners once per payload instead of scanning the wheel list
-- on every sample. Two modes, mirroring the corner lookup the load columns use:
-- wheel names first (all standard vehicles name them FL/FR/RL/RR), then the
-- mod's own wheel order, which may mislabel corners on a vehicle with odd names
-- but still records four tyres instead of none.
local function ingest(data)
  local list = type(data.data) == "table" and data.data or data
  if type(list) ~= "table" then return end

  local count = 0
  for index = 1, #list do
    local entry = list[index]
    if type(entry) == "table" then
      count = count + 1
      entries[count] = entry
    end
  end
  for index = count + 1, #entries do entries[index] = nil end

  slotCount = count
  received = count >= 4

  if received then
    local matched = 0
    for corner = 1, 4 do
      local wanted = WHEEL_NAMES[corner]
      slots[corner] = nil
      for index = 1, count do
        if entries[index].name == wanted then
          slots[corner] = entries[index]
          matched = matched + 1
          break
        end
      end
    end
    if matched < 4 then
      for corner = 1, 4 do slots[corner] = entries[corner] end
    end
  else
    for corner = 1, 4 do slots[corner] = nil end
  end

  age = 0
end

-- Wrap `gui.send` once per vehicle VM. The hook table is `guihooks` (a plain Lua
-- module table, common/guihooks.lua:194-212), so assigning over `send` is safe
-- and the original is still called for every stream, ours and everyone else's.
-- A controller reload (Ctrl+L) does not rebuild that table, so the previous
-- wrapper is recognised and replaced instead of stacking a second tap on top of
-- the first.
local TAP_KEY = "__lapLogTireTap"
local TAP_SOURCE_KEY = "__lapLogTireTapSource"

function M.install()
  local hooks = gui
  if type(hooks) ~= "table" then return false end
  local current = hooks.send
  if type(current) ~= "function" then return false end

  local original = current
  local previousTap = rawget(hooks, TAP_KEY)
  if previousTap ~= nil and current == previousTap then
    original = rawget(hooks, TAP_SOURCE_KEY) or current
  end

  local function tap(name, data, ...)
    if name == STREAM_NAME and type(data) == "table" then
      -- A payload we cannot parse must not break the other mod's own stream.
      pcall(ingest, data)
    end
    return original(name, data, ...)
  end

  rawset(hooks, TAP_SOURCE_KEY, original)
  rawset(hooks, TAP_KEY, tap)
  hooks.send = tap
  return true
end

-- Physics-side freshness clock. Cheap enough to run every step, and only this
-- side knows when the payload stopped arriving.
function M.tick(dt)
  dt = tonumber(dt)
  if dt == nil or dt <= 0 then return end
  age = math.min(age + dt, STALE_SECONDS + 1)
end

-- Drop the cached payload. Called on a vehicle reset: the mod rebuilds its tyre
-- state, so numbers from before the reset must not leak into the next lap.
function M.invalidate()
  received = false
  age = STALE_SECONDS + 1
  for corner = 1, 4 do slots[corner] = nil end
  slotCount = 0
end

-- True when a payload arrived recently AND it held four usable corners.
function M.available()
  return received and age <= STALE_SECONDS and slotCount >= 4
end

-- Source label for the replay envelope, or nil when no data is arriving.
function M.source()
  if not M.available() then return nil end
  return SOURCE_ID
end

-- The label on its own, for a lap whose samples already carry the tyre block
-- (it was recorded earlier, possibly in another session) but whose live feed
-- this instance never saw.
function M.sourceId()
  return SOURCE_ID
end

-- One sample: the four corners' tread surface temperature (C), carcass/core
-- temperature (C) and remaining tread (%) in FL, FR, RL, RR order. Returns nil
-- unless every corner reported real numbers, so a caller can decide once per
-- recording whether this lap carries the tyre block at all - a half-filled
-- block would read as 0 C / 0 % wear, which is worse than an honest "not
-- recorded". The table is reused.
function M.read()
  if not M.available() then return nil end
  for corner = 1, 4 do
    local entry = slots[corner]
    if entry == nil then return nil end
    local surface = surfaceTemperature(entry)
    local core = coreTemperature(entry)
    local wear = wearPercent(entry)
    if surface == nil or core == nil or wear == nil then return nil end
    sample.surface[corner] = surface
    sample.core[corner] = core
    sample.wear[corner] = wear
  end
  return sample
end

-- Short human-readable state for the controller's diagnostic trace.
function M.status()
  return string.format(
    "installed=%s received=%s wheels=%d age=%.2f",
    tostring(rawget(gui or {}, TAP_KEY) ~= nil),
    tostring(received), slotCount, age
  )
end

return M
