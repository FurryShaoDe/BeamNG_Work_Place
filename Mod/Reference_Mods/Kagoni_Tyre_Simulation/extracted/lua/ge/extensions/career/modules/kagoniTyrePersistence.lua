
local M = {}
M.dependencies = {'career_career', 'career_saveSystem', 'career_modules_inventory'}

local extensionName = 'career_modules_kagoniTyrePersistence'
local relativeDir = '/career/kagoniTyreSimulation'
local fileName = 'wear.json'
local data = {schema = 1, vehicles = {}}
local pendingSave = nil
local saveSerial = 0
local restoreSerial = 0
local restorePending = {}
local restoredVehicleObject = {}
local pollTimer = 0

local function vehicleKey(inventoryId)
  return tostring(inventoryId)
end

local function getCurrentSavePath()
  if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then return nil end
  local _, path = career_saveSystem.getCurrentSaveSlot()
  return path
end

local function ensureDir(path)
  if not FS or not path then return false end
  if FS.directoryExists and FS:directoryExists(path) then return true end
  if FS.directoryCreate then
    local ok = pcall(function() FS:directoryCreate(path) end)
    if ok then return true end
  end
  return false
end

local function loadData()
  local savePath = getCurrentSavePath()
  data = {schema = 1, vehicles = {}}
  restorePending = {}
  restoredVehicleObject = {}
  if not savePath then return false end
  local path = savePath .. relativeDir .. '/' .. fileName
  local ok, payload = pcall(function() return jsonReadFile(path) end)
  if ok and type(payload) == 'table' and type(payload.vehicles) == 'table' then
    data.schema = tonumber(payload.schema) or 1
    data.vehicles = payload.vehicles
    log('I', 'kagoniTyrePersistence', 'Loaded KTS Career tyre wear for ' .. tostring(tableSize and tableSize(data.vehicles) or 0) .. ' inventory vehicles')
    return true
  end
  return false
end

local function writeData(savePath)
  if not savePath or not career_saveSystem or not career_saveSystem.jsonWriteFileSafe then return false end
  local dir = savePath .. relativeDir
  ensureDir(dir)
  local payload = {
    schema = 1,
    purpose = 'Kagoni Tyre Simulation Career wear persistence. Thermal state is intentionally not saved.',
    vehicles = data.vehicles or {},
  }
  local ok, result = pcall(function()
    return career_saveSystem.jsonWriteFileSafe(dir .. '/' .. fileName, payload, true)
  end)
  return ok and result ~= false
end

local function finishPendingSave()
  if not pendingSave then return end
  local path = pendingSave.path
  writeData(path)
  log('I', 'kagoniTyrePersistence', 'Saved KTS Career tyre wear to ' .. tostring(path))
  pendingSave = nil
  if career_saveSystem and career_saveSystem.asyncSaveExtensionFinished then
    career_saveSystem.asyncSaveExtensionFinished(extensionName)
  end
end

local function requestWearSnapshot(inventoryId, vehicleId, token)
  local veh = vehicleId and be:getObjectByID(vehicleId) or nil
  if not veh then return false end
  local invLiteral = serialize(inventoryId)
  local tokenLiteral = serialize(token)
  veh:queueLuaCommand(
    "if extensions and extensions.luukstyrethermalsandwear and extensions.luukstyrethermalsandwear.careerSendWearState then " ..
    "extensions.luukstyrethermalsandwear.careerSendWearState(" .. invLiteral .. "," .. tokenLiteral .. ") end"
  )
  return true
end

local function queueWearRestore(inventoryId, vehicleId, state)
  if type(state) ~= 'table' or type(state.wheels) ~= 'table' or not vehicleId then return false end
  local veh = be:getObjectByID(vehicleId)
  if not veh then return false end
  restoreSerial = restoreSerial + 1
  local token = restoreSerial
  local key = vehicleKey(inventoryId)
  restorePending[key] = {vehicleId = vehicleId, token = token, elapsed = 0, retry = 0}
  local stateLiteral = serialize(state)
  local invLiteral = serialize(inventoryId)
  local tokenLiteral = serialize(token)
  veh:queueLuaCommand(
    "if extensions and extensions.luukstyrethermalsandwear and extensions.luukstyrethermalsandwear.careerApplyWearState then " ..
    "extensions.luukstyrethermalsandwear.careerApplyWearState(" .. invLiteral .. "," .. stateLiteral .. "," .. tokenLiteral .. ") end"
  )
  return true
end

function M.receiveVehicleWearState(inventoryId, state, token)
  if type(state) ~= 'table' or type(state.wheels) ~= 'table' or #state.wheels < 1 then return false end
  local key = vehicleKey(inventoryId)
  data.vehicles[key] = state
  if pendingSave and tonumber(token) == pendingSave.token then
    pendingSave.waiting[key] = nil
    if next(pendingSave.waiting) == nil then
      finishPendingSave()
    end
  end
  return true
end

function M.confirmWearRestoreQueued(inventoryId, token)
  local key = vehicleKey(inventoryId)
  local pending = restorePending[key]
  if not pending or tonumber(token) ~= pending.token then return false end
  restoredVehicleObject[key] = pending.vehicleId
  restorePending[key] = nil
  log('I', 'kagoniTyrePersistence', 'Queued KTS wear restore for inventory vehicle ' .. key)
  return true
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveSerial = saveSerial + 1
  local token = saveSerial
  if career_saveSystem and career_saveSystem.registerAsyncSaveExtension then
    career_saveSystem.registerAsyncSaveExtension(extensionName)
  end

  pendingSave = {token = token, path = currentSavePath, waiting = {}, elapsed = 0}
  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
  for inventoryId, _ in pairs(vehicles or {}) do
    local vehicleId = career_modules_inventory.getVehicleIdFromInventoryId and career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
    if vehicleId and be:getObjectByID(vehicleId) then
      local key = vehicleKey(inventoryId)
      pendingSave.waiting[key] = true
      requestWearSnapshot(inventoryId, vehicleId, token)
    end
  end

  if next(pendingSave.waiting) == nil then
    finishPendingSave()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  local dt = tonumber(dtReal) or tonumber(dtSim) or 0

  if pendingSave then
    pendingSave.elapsed = pendingSave.elapsed + dt
    if pendingSave.elapsed >= 1.0 then
      finishPendingSave()
    end
  end

  pollTimer = pollTimer - dt
  if pollTimer <= 0 then
    pollTimer = 0.35
    local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
    for inventoryId, _ in pairs(vehicles or {}) do
      local key = vehicleKey(inventoryId)
      local state = data.vehicles[key]
      if state then
        local vehicleId = career_modules_inventory.getVehicleIdFromInventoryId and career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
        if vehicleId and be:getObjectByID(vehicleId) and restoredVehicleObject[key] ~= vehicleId then
          local pending = restorePending[key]
          if not pending then
            queueWearRestore(inventoryId, vehicleId, state)
          else
            pending.elapsed = pending.elapsed + 0.35
            if pending.elapsed >= 0.8 then
              restorePending[key] = nil
              queueWearRestore(inventoryId, vehicleId, state)
            end
          end
        end
      end
    end
  end
end

local function onCareerModulesActivated(alreadyInLevel)
  loadData()
end

local function onExtensionLoaded()
  if career_career and career_career.isActive and career_career.isActive() then
    loadData()
  end
end

local function onCareerActive(active)
  if active == false then
    data = {schema = 1, vehicles = {}}
    pendingSave = nil
    restorePending = {}
    restoredVehicleObject = {}
  end
end

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onUpdate = onUpdate
M.onCareerModulesActivated = onCareerModulesActivated
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActive = onCareerActive

return M
