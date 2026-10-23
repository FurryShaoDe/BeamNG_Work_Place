local M = {}

local variablesById = {}

local ENVIRONMENT_REFRESH_INTERVAL_S = 30
local environmentRefreshElapsedS = 0

local function sendEnvironmentTemperature()
	if not be or not core_environment or not core_environment.getTemperatureK then return false end
	local ok, tempK = pcall(core_environment.getTemperatureK)
	local valueK = ok and tonumber(tempK) or nil
	if not valueK then return false end
	local envTempC = valueK - 273.15
	be:sendToMailbox("tyreWearMailboxEnvTemp", envTempC)
	return true
end

local brakeSetting = {}
local function onVehicleSpawned(vehID)
	brakeSetting = {}
	local vehicleData = core_vehicle_manager.getVehicleData(vehID)
	if not vehicleData then return end
	local vdata = vehicleData.vdata
	if not vdata then return end
	if not vdata.variables then vdata.variables = {} end
	local partConfig = be:getObjectByID(vehID).partConfig
	local tablePartConfig = jsonReadFile(partConfig) or deserialize(partConfig)
	if tablePartConfig and tablePartConfig.vars and tablePartConfig.vars["$WheelCoolingDuctFront"] then
		brakeSetting[1] = tablePartConfig.vars["$WheelCoolingDuctFront"]
	end
	if tablePartConfig and tablePartConfig.vars and tablePartConfig.vars["$WheelCoolingDuctRear"] then
		brakeSetting[2] = tablePartConfig.vars["$WheelCoolingDuctRear"]
	end

	if not variablesById[vehID] then
		variablesById[vehID] = {
			["$WheelCoolingDuctFront"] = {
				name = "$WheelCoolingDuctFront",
				category = "Brakes",
				title = "Front brake cooling",
				description = "Brake surface cooling relative to BeamNG native. 100%=native cooling, 0%=closed. Values above 100% retain the legacy extra-cooling range.",
				type = "range",
				unit = "%",

				min = 1,
				minDis = 0,
				max = 100,
				maxDis = 825,
				step = 0.12,
				stepDis = 1,
				default = 13,
				val = brakeSetting[1] or 13
			},
			["$WheelCoolingDuctRear"] = {
				name = "$WheelCoolingDuctRear",
				category = "Brakes",
				title = "Rear brake cooling",
				description = "Brake surface cooling relative to BeamNG native. 100%=native cooling, 0%=closed. Values above 100% retain the legacy extra-cooling range.",
				type = "range",
				unit = "%",

				min = 1,
				minDis = 0,
				max = 100,
				maxDis = 825,
				step = 0.12,
				stepDis = 1,
				default = 13,
				val = brakeSetting[2] or 13
			}
		}
	else
		variablesById[vehID]["$WheelCoolingDuctFront"].val = brakeSetting[1] or 13
		variablesById[vehID]["$WheelCoolingDuctRear"].val = brakeSetting[2] or 13
	end

	tableMerge(vdata.variables, variablesById[vehID])
	sendEnvironmentTemperature()
	environmentRefreshElapsedS = 0
end

local function onSpawnCCallback(vehID)
	if not variablesById[vehID] then return end
	local _, configDataIn = debug.getlocal(3, 3)
	if type(configDataIn) ~= "string" or configDataIn:sub(1, 1) ~= "{" then return end
	local deserialized = deserialize(configDataIn)

	if type(deserialized) ~= "table" or type(deserialized.vars) ~= "table" then return end

	for name, _ in pairs(variablesById[vehID]) do
		if deserialized.vars[name] then
			variablesById[vehID][name].val = deserialized.vars[name]
		else
			variablesById[vehID][name].val = variablesById[vehID][name].default or variablesById[vehID][name].val
		end
	end
end

local function onSettingsChanged()
	if not be then return end
	if not core_vehicle_manager.getPlayerVehicleData() then return end
	brakeSetting = {}
	local mailboxSend = {core_vehicle_manager.getPlayerVehicleData().vdata.variables["$WheelCoolingDuctFront"].val or 13, core_vehicle_manager.getPlayerVehicleData().vdata.variables["$WheelCoolingDuctRear"].val or 13}
	be:sendToMailbox("tyreWearMailboxDuct", serialize(mailboxSend))
	sendEnvironmentTemperature()
	environmentRefreshElapsedS = 0
end

local function onUpdate(dtReal, dtSim, dtRaw)
	local dt = tonumber(dtSim) or tonumber(dtReal) or tonumber(dtRaw) or 0
	environmentRefreshElapsedS = environmentRefreshElapsedS + math.max(dt, 0)
	if environmentRefreshElapsedS >= ENVIRONMENT_REFRESH_INTERVAL_S then
		sendEnvironmentTemperature()
		environmentRefreshElapsedS = 0
	end
end

local function onVehicleDestroyed(vehID)
	variablesById[vehID] = nil
	brakeSetting = {}
end

M.onSettingsChanged = onSettingsChanged
M.onVehicleSpawned = onVehicleSpawned
M.onSpawnCCallback = onSpawnCCallback
M.onVehicleDestroyed = onVehicleDestroyed
M.onUpdate = onUpdate
M.sendEnvironmentTemperature = sendEnvironmentTemperature
return M
