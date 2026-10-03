-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Runtime ownership boundary for one Ghost Racer vehicle controller instance.

local M = {}

local nextGeneration = 0
local requiredStateDomains = {"recording", "playback", "session", "starts", "display", "ui"}
local allowedRuntimeFields = {
  object = true,
  vehicleData = true,
  objectId = true,
  vehicleDirectory = true
}

local function sortedKeys(value)
  local result = {}
  for key in pairs(value or {}) do result[#result + 1] = tostring(key) end
  table.sort(result)
  return result
end

local function validateStateDomains(state)
  assert(type(state) == "table", "vehicle context state is required")
  for index = 1, #requiredStateDomains do
    local name = requiredStateDomains[index]
    assert(type(state[name]) == "table", "vehicle context state." .. name .. " is required")
  end
end

function M.new(options)
  options = options or {}
  validateStateDomains(options.state)
  assert(type(options.codeVersion) == "string", "vehicle context code version is required")

  nextGeneration = nextGeneration + 1
  local context = {
    kind = "vehicle",
    schemaVersion = 2,
    codeVersion = options.codeVersion,
    lifecycle = {
      generation = "vehicle-" .. tostring(nextGeneration),
      phase = "created",
      active = false,
      transitionSequence = 0,
      resetSequence = 0,
      activationReason = nil,
      invalidReason = nil,
      lastResetReason = nil
    },
    runtime = {},
    state = options.state,
    services = {}
  }

  function context:updateRuntime(values)
    assert(type(values) == "table", "vehicle runtime update must be a table")
    for key, value in pairs(values) do
      assert(allowedRuntimeFields[key], "unsupported vehicle runtime field: " .. tostring(key))
      self.runtime[key] = value
    end
    return true
  end

  function context:clearRuntime(fields)
    assert(type(fields) == "table", "vehicle runtime clear list must be a table")
    for index = 1, #fields do
      local key = fields[index]
      assert(allowedRuntimeFields[key], "unsupported vehicle runtime field: " .. tostring(key))
      self.runtime[key] = nil
    end
    return true
  end

  function context:registerService(name, service)
    assert(type(name) == "string" and name ~= "", "vehicle service name is required")
    assert(service ~= nil, "vehicle service is required: " .. name)
    local previous = self.services[name]
    if previous ~= nil and previous ~= service then
      return false, "vehicle service already registered: " .. name
    end
    self.services[name] = service
    return true
  end

  function context:activate(reason)
    if self.lifecycle.phase == "invalid" then return false end
    if not self.lifecycle.active then
      self.lifecycle.transitionSequence = self.lifecycle.transitionSequence + 1
    end
    self.lifecycle.phase = "active"
    self.lifecycle.active = true
    self.lifecycle.activationReason = tostring(reason or "controller active")
    self.lifecycle.invalidReason = nil
    return true
  end

  function context:markReset(reason)
    if self.lifecycle.phase == "invalid" then return false end
    self.lifecycle.resetSequence = self.lifecycle.resetSequence + 1
    self.lifecycle.lastResetReason = tostring(reason or "vehicle reset")
    return true
  end

  function context:invalidate(reason)
    if self.lifecycle.phase == "invalid" then return false end
    self.lifecycle.transitionSequence = self.lifecycle.transitionSequence + 1
    self.lifecycle.phase = "invalid"
    self.lifecycle.active = false
    self.lifecycle.invalidReason = tostring(reason or "controller invalidated")
    self:clearRuntime({"object", "vehicleData"})
    return true
  end

  function context:isCurrent(generation)
    return self.lifecycle.active and generation == self.lifecycle.generation
  end

  function context:snapshotState(name)
    assert(type(name) == "string" and name ~= "", "vehicle state domain name is required")
    local domain = self.state[name]
    if type(domain) ~= "table" or type(domain.snapshot) ~= "function" then return nil end
    return domain.snapshot()
  end

  function context:snapshot()
    return {
      kind = self.kind,
      schemaVersion = self.schemaVersion,
      codeVersion = self.codeVersion,
      generation = self.lifecycle.generation,
      phase = self.lifecycle.phase,
      active = self.lifecycle.active,
      transitionSequence = self.lifecycle.transitionSequence,
      resetSequence = self.lifecycle.resetSequence,
      activationReason = self.lifecycle.activationReason,
      invalidReason = self.lifecycle.invalidReason,
      lastResetReason = self.lifecycle.lastResetReason,
      objectId = self.runtime.objectId,
      vehicleDirectory = self.runtime.vehicleDirectory,
      stateDomains = sortedKeys(self.state),
      services = sortedKeys(self.services)
    }
  end

  context:updateRuntime(options.runtime or {})
  return context
end

return M
