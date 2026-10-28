-- Input Telemetry (fixed port) -- publishes its own stream instead of riding on `electrics`.
--
-- The stock `electrics` stream is a shared, ref-counted subscription: any other app
-- (or a buggy one removing more than it added) changes whether it is delivered.
-- This mod keeps its own channel: the UI app subscribes to `inputTelemetryFixed`,
-- and this extension only builds the payload when that subscription exists.
--
-- Ported from ArmensG "Input Telemetry" v0.1 (last upstream update 2024).
local M = {}

local STREAM_NAME = "inputTelemetryFixed"
local payload = {}

local function num(value)
  if type(value) ~= "number" then return 0 end
  if value ~= value then return 0 end -- NaN
  return value
end

local function publish()
  -- willSend() is false when nothing subscribed: no work, no garbage on the bridge
  if not streams or type(streams.willSend) ~= "function" then return end
  if not streams.willSend(STREAM_NAME) then return end

  payload.clutch = num(electrics.values.clutch)
  payload.brake = num(electrics.values.brake)
  payload.throttle = num(electrics.values.throttle)
  payload.steeringInput = num(electrics.values.steering_input)

  guihooks.queueStream(STREAM_NAME, payload)
end

M.updateGFX = function(dt)
  publish()
end

return M
