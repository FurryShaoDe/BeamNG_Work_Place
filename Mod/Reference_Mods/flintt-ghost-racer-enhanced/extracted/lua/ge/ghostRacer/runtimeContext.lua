-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Runtime ownership boundary for one Ghost Racer GE extension instance.

local M = {}

local nextGeneration = 0
local requiredStateDomains = {"race", "timeTrial", "camera", "world", "ui"}
local allowedRuntimeFields = {
  vehicle = true,
  vehicleId = true,
  level = true
}

local function sortedKeys(value)
  local result = {}
  for key in pairs(value or {}) do result[#result + 1] = tostring(key) end
  table.sort(result)
  return result
end

local function validateStateDomains(state)
  assert(type(state) == "table", "GE context state is required")
  for index = 1, #requiredStateDomains do
    local name = requiredStateDomains[index]
    assert(type(state[name]) == "table", "GE context state." .. name .. " is required")
  end
end

function M.new(options)
  options = options or {}
  validateStateDomains(options.state)
  assert(type(options.codeVersion) == "string", "GE context code version is required")

  nextGeneration = nextGeneration + 1
  local context = {
    kind = "ge",
    schemaVersion = 1,
    codeVersion = options.codeVersion,
    lifecycle = {
      generation = "ge-" .. tostring(nextGeneration),
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
    assert(type(values) == "table", "GE runtime update must be a table")
    for key, value in pairs(values) do
      assert(allowedRuntimeFields[key], "unsupported GE runtime field: " .. tostring(key))
      self.runtime[key] = value
    end
    return true
  end

  function context:clearRuntime(fields)
    assert(type(fields) == "table", "GE runtime clear list must be a table")
    for index = 1, #fields do
      local key = fields[index]
      assert(allowedRuntimeFields[key], "unsupported GE runtime field: " .. tostring(key))
      self.runtime[key] = nil
    end
    return true
  end

  function context:registerService(name, service)
    assert(type(name) == "string" and name ~= "", "GE service name is required")
    assert(service ~= nil, "GE service is required: " .. name)
    local previous = self.services[name]
    if previous ~= nil and previous ~= service then
      return false, "GE service already registered: " .. name
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
    self.lifecycle.activationReason = tostring(reason or "extension active")
    self.lifecycle.invalidReason = nil
    return true
  end

  function context:markReset(reason)
    if self.lifecycle.phase == "invalid" then return false end
    self.lifecycle.resetSequence = self.lifecycle.resetSequence + 1
    self.lifecycle.lastResetReason = tostring(reason or "GE runtime reset")
    return true
  end

  function context:invalidate(reason)
    if self.lifecycle.phase == "invalid" then return false end
    self.lifecycle.transitionSequence = self.lifecycle.transitionSequence + 1
    self.lifecycle.phase = "invalid"
    self.lifecycle.active = false
    self.lifecycle.invalidReason = tostring(reason or "extension invalidated")
    self:clearRuntime({"vehicle", "vehicleId"})
    return true
  end

  function context:isCurrent(generation)
    return self.lifecycle.active and generation == self.lifecycle.generation
  end

  function context:snapshotState(name)
    assert(type(name) == "string" and name ~= "", "GE state domain name is required")
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
      vehicleId = self.runtime.vehicleId,
      level = self.runtime.level,
      stateDomains = sortedKeys(self.state),
      services = sortedKeys(self.services)
    }
  end

  context:updateRuntime(options.runtime or {})
  return context
end

return M
