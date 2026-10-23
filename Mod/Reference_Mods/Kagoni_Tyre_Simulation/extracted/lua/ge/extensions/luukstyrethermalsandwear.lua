local M = {}

-- Traffic/AI performance option. Disabled by default to reduce background simulation cost.
-- OFF by default: every vehicle still initializes KTS, but continuous tyre
-- simulation runs only on the currently seated player vehicle.
local enableAllSpawnedCars = false

local function applyTrafficSimulationMode(vehID)
    local vehicleObj = be and be:getObjectByID(vehID) or nil
    if not vehicleObj then return false end
    vehicleObj:queueLuaCommand(
        "local e=extensions.luukstyrethermalsandwear; if e and e.setEnableAllSpawnedCarsLocal then e.setEnableAllSpawnedCarsLocal(" ..
        (enableAllSpawnedCars and "true" or "false") .. ") end"
    )
    return true
end

local function setEnableAllSpawnedCars(enabled)
    enableAllSpawnedCars = enabled == true
    if be and be.sendToMailbox then
        be:sendToMailbox("ktsEnableAllSpawnedCars", enableAllSpawnedCars and 1 or 0)
    end
    if be and be.queueAllObjectLua then
        be:queueAllObjectLua(
            "local e=extensions.luukstyrethermalsandwear; if e and e.setEnableAllSpawnedCarsLocal then e.setEnableAllSpawnedCarsLocal(" ..
            (enableAllSpawnedCars and "true" or "false") .. ") end"
        )
    end
    return enableAllSpawnedCars
end

local function onVehicleSpawned(vehID)
    if be and be.sendToMailbox then
        be:sendToMailbox("ktsEnableAllSpawnedCars", enableAllSpawnedCars and 1 or 0)
    end
    applyTrafficSimulationMode(vehID)
end

local function getGroundModels()
    local payload = {debug = 0}

    for key, model in pairs(core_environment.groundModels or {}) do
        local name = tostring(key or "")
        local cdata = model and model.cdata or nil
        if name ~= "" and cdata then
            payload[name] = {
                staticFrictionCoefficient = tonumber(cdata.staticFrictionCoefficient) or 0,
                slidingFrictionCoefficient = tonumber(cdata.slidingFrictionCoefficient) or 0,
                roughnessCoefficient = tonumber(cdata.roughnessCoefficient) or 0,
                defaultDepth = tonumber(cdata.defaultDepth) or 0,
                strength = tonumber(cdata.strength) or 0,
                fluidDensity = tonumber(cdata.fluidDensity) or 0,
                flowConsistencyIndex = tonumber(cdata.flowConsistencyIndex) or 0,
                hydrodynamicFriction = tonumber(cdata.hydrodynamicFriction) or 0,
                shearStrength = tonumber(cdata.shearStrength) or 0
            }
        end
    end

    local veh = be and be:getPlayerVehicle(0) or nil
    if not veh then return end

    local ok, literal = pcall(serialize, payload)
    if not ok or type(literal) ~= "string" then
        log("E", "luukstyrethermalsandwear", "Unable to serialize ground-model data")
        return
    end

    veh:queueLuaCommand("groundModels = " .. literal)
end

M.getGroundModels = getGroundModels
M.setEnableAllSpawnedCars = setEnableAllSpawnedCars
M.getEnableAllSpawnedCars = function() return enableAllSpawnedCars end
M.onVehicleSpawned = onVehicleSpawned

return M
