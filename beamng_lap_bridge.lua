-- ============================================================
-- BeamNG 圈速桥（beamng_lap_bridge）
-- ------------------------------------------------------------
-- 功能：计时赛（Time Trial / Quick Race）模式下，每过线一圈自动把
--       成绩（圈速/赛道/布局/车辆/马力/驱动/动力/模组/版本/日期）
--       写入 <用户目录>/beamng_lap_bridge/records.jsonl，
--       由本地 server.py（python server.py）轮询后写入 data.json。
--
-- 安装：把本文件复制到 <用户目录>/lua/ge/extensions/ 下即可，
--       无需启用（GE 扩展自动加载）。游戏设置 → 管理用户文件夹可打开用户目录。
--
-- 数据流：BeamNG → records.jsonl → server.py → data.json → GitHub Pages
-- ============================================================

local M = {}

local logTag = 'lapBridge'

-- 输出目录/文件：统一以用户目录绝对路径为基准，
-- 与 server.py 轮询的 <用户目录>/beamng_lap_bridge/records.jsonl 一致
local OUT_DIR = FS:getUserPath() .. '/beamng_lap_bridge'
local OUT_FILE = OUT_DIR .. '/records.jsonl'

-- 计时状态
local prevCumulative = nil   -- 上次过线的累计时间（秒），起跑视为 0
local currentLap = 0
local dirReady = false

-- 车辆规格缓存（同车不重复采集）
local cachedVehKey = nil
local cachedVehicle = nil

local function logI(fmt, ...) log('I', logTag, string.format(fmt, ...)) end
local function logE(fmt, ...) log('E', logTag, string.format(fmt, ...)) end

-- MM:SS.mmm（与官方 race:raceTime 相同算法）
local function fmtTime(sec)
  if not sec then return nil end
  local m = math.floor(sec / 60)
  local s = math.floor(sec - m * 60)
  local ms = math.floor((sec - m * 60 - s) * 1000)
  return string.format('%02d:%02d.%03d', m, s, ms)
end

-- 防御性调用：任何一步出错都不影响主流程
local function safe(fn, default)
  local ok, res = pcall(fn)
  if ok then
    return res
  end
  return default
end

local function today()
  local t = os.date('*t')
  return string.format('%d-%d-%d', t.year, t.month, t.day)
end

-- ============================================================
-- 车辆规格采集（GE 侧静态数据，全部来自官方 core_vehicles 模块）
-- 注意：powertrain / wheels / v 等是车辆 Lua 状态（vehicle VM）的
--       全局，在 GE 扩展环境中不存在，不能直接使用。官方车辆选择器
--       （ui/vehicleSelector/vehicleSpecifications.lua）正是用
--       core_vehicles.getModel/getConfig 的静态规格显示马力/驱动，
--       此处采用同一数据源（Power 单位为 PS，换算为 hp）。
-- ============================================================

-- 公制马力(PS) → 英制马力(hp)
local PS_TO_HP = 0.98632

-- 配置对象：model.configs[configKey]（官方 quickAccess 同款取法），
-- 取不到时按 pcFilename 兜底匹配
local function findConfig(model, configKey, partConfig)
  if not model or not model.configs then return nil end
  local cfg = model.configs[configKey]
  if cfg then return cfg end
  for _, cfg in pairs(model.configs) do
    if cfg.key == configKey then return cfg end
    if partConfig and cfg.pcFilename == partConfig then return cfg end
  end
  return nil
end

-- 马力：规格 Power（PS）→ hp；取不到时返回 nil
local function collectPowerHp(modelDetails, config)
  local power = (config and config.Power) or (modelDetails and modelDetails.Power)
  power = tonumber(power)
  if power and power > 0 then
    return math.floor(power * PS_TO_HP + 0.5)
  end
  return nil
end

-- 动力类型：油车 / 电车 / 混动（依据 Fuel Type / Propulsion 规格字段）
local function collectPowerType(modelDetails, config)
  local fuel = tostring((config and (config['Fuel Type'] or config.FuelType)) or (modelDetails and (modelDetails['Fuel Type'] or modelDetails.FuelType)) or '')
  local prop = tostring((config and config.Propulsion) or (modelDetails and modelDetails.Propulsion) or '')
  local fuelLow, propLow = string.lower(fuel), string.lower(prop)
  if propLow:find('hybrid') then return '混动' end
  if fuelLow:find('battery') or fuelLow:find('electric') or propLow:find('electric') then return '电车' end
  if fuelLow:find('gasoline') or fuelLow:find('petrol') or fuelLow:find('diesel') or propLow:find('combustion') then return '油车' end
  return nil -- 未知类型不硬归类
end

-- 驱动：前驱 / 后驱 / 四驱（Drivetrain 规格字符串映射）
local function collectDrivetrain(modelDetails, config)
  local dt = tostring((config and config.Drivetrain) or (modelDetails and modelDetails.Drivetrain) or '')
  local low = string.lower(dt)
  if low:find('awd') or low:find('4wd') or low:find('4x4') or low:find('all.wheel') then return '四驱' end
  if low:find('fwd') or low:find('front') then return '前驱' end
  if low:find('rwd') or low:find('rear') or low:find('4x2') then return '后驱' end
  return nil
end

-- 是否模组车：优先看规格 Source 字段，否则按文件来源判断
local function collectIsMod(modelKey, config)
  return safe(function()
    local src = tostring(config and config.Source or '')
    if src ~= '' then
      return src ~= 'BeamNG - Official'
    end
    local mod = extensions.core_modmanager.getModFromPath('/vehicles/' .. modelKey .. '/')
    return mod ~= nil
  end, false)
end

-- 车辆显示名：模型名（locale 翻译） + 配置名（官方 Configuration 字段）
local function collectVehicleName(modelDetails, config, modelKey)
  return safe(function()
    local base = modelDetails and modelDetails.Name
    if base then
      base = core_locales.translate(base)
    end
    local cfgName = config and (config.Configuration or config.Name or config.displayName)
    if cfgName and cfgName ~= '' then
      return base and (base .. ' ' .. cfgName) or cfgName
    end
    return base or modelKey
  end, modelKey)
end

-- 采集当前玩家车辆规格（带缓存）
local function collectVehicleSpec()
  return safe(function()
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return nil end
    -- 优先官方推荐接口，旧接口兜底
    local veh = be:getObjectByID(vehId) or scenetree.findObjectById(vehId)
    if not veh or not veh.JBeam then return nil end

    local modelKey = veh.JBeam
    local partConfig = veh.partConfig
    local configKey = nil
    if partConfig then
      configKey = string.match(partConfig, 'vehicles/' .. modelKey .. '/(.*)%.pc')
    end
    configKey = configKey or 'base'

    local key = modelKey .. '|' .. configKey
    if cachedVehKey == key then
      return cachedVehicle
    end

    local model = core_vehicles.getModel(modelKey)
    local modelDetails = model and model.model
    local config = findConfig(model, configKey, partConfig)

    cachedVehKey = key
    cachedVehicle = {
      name = collectVehicleName(modelDetails, config, modelKey),
      modelKey = modelKey,
      configKey = configKey,
      powerHp = collectPowerHp(modelDetails, config),
      drivetrain = collectDrivetrain(modelDetails, config),
      powerType = collectPowerType(modelDetails, config),
      isMod = collectIsMod(modelKey, config),
    }
    logI('车辆规格: %s | %s hp | %s | %s%s',
      cachedVehicle.name,
      tostring(cachedVehicle.powerHp or '?'),
      cachedVehicle.drivetrain or '?',
      cachedVehicle.powerType or '?',
      cachedVehicle.isMod and ' | MOD' or '')
    return cachedVehicle
  end, nil)
end

-- ============================================================
-- 赛道信息
-- ============================================================

local function collectTrackInfo()
  return safe(function()
    local scenario = scenario_scenarios.getScenario()
    local levelId = getCurrentLevelIdentifier()
    -- 地图显示名：官方 locale 键 levels.<id>.info.title
    local levelDisplay = core_locales.translate('levels.' .. levelId .. '.info.title')
    local layoutKey = scenario and scenario.scenarioName
    local layoutName = layoutKey and core_locales.translate(layoutKey)
    return {
      id = levelId,
      levelDisplay = levelDisplay,
      layoutKey = layoutKey,
      layoutName = layoutName,
      laps = scenario and scenario.lapCount,
    }
  end, nil)
end

-- ============================================================
-- 写入 JSONL
-- ============================================================

local function ensureDir()
  if FS:directoryExists(OUT_DIR) then return true end
  local ok = safe(function()
    FS:directoryCreate(OUT_DIR)
    return true
  end, false)
  return ok and FS:directoryExists(OUT_DIR)
end

local function writeRecord(record)
  if not dirReady then
    dirReady = ensureDir()
    if not dirReady then
      logE('无法创建输出目录 %s', OUT_DIR)
      return false
    end
  end
  local f = io.open(OUT_FILE, 'a')
  if not f then
    logE('无法打开输出文件 %s（用户目录权限？）', OUT_FILE)
    return false
  end
  local ok = safe(function()
    f:write(jsonEncode(record) .. '\n')
    f:close()
    return true
  end, false)
  if not ok then
    logE('写入记录失败')
    pcall(f.close, f)
  end
  return ok
end

-- 提交一圈成绩
local function submitLap(lapTimeSec, lapIndex)
  if not lapTimeSec or lapTimeSec <= 0 then
    return
  end
  local spec = collectVehicleSpec()
  local track = collectTrackInfo()
  -- server 端硬性要求：车辆名、赛道 id、布局键必须非空
  if not spec or not spec.name then
    logE('车辆规格采集失败，跳过该圈')
    return
  end
  if not track or not track.id or not (track.layoutName or track.layoutKey) then
    logE('赛道/布局信息采集失败，跳过该圈')
    return
  end

  local record = {
    event = 'lapFinished',
    ts = os.time(),
    track = track,
    vehicle = spec,
    result = {
      lap = lapIndex or 0,
      lapTimeSec = lapTimeSec,
      lapTimeFormatted = fmtTime(lapTimeSec),
    },
    meta = {
      gameVersion = tostring(beamng_version or ''),
      date = today(),
    },
  }

  if writeRecord(record) then
    logI('已记录第 %d 圈 %s（%s / %s）',
      record.result.lap,
      record.result.lapTimeFormatted,
      track.layoutName or track.layoutKey,
      spec.name)
  end
end

-- ============================================================
-- 官方扩展事件钩子
-- ============================================================

function M.onRaceStart()
  prevCumulative = nil
  currentLap = 0
  cachedVehKey = nil -- 新比赛重新采集（车辆可能已切换）
  cachedVehicle = nil
end

-- 计时赛（Quick Race）过线触发；wpInfo.time 为累计时间（秒）
-- 注意：官方钩子分发器（extensions.hookFast）对扩展钩子是裸调用、
-- 无错误保护，这里整体包 pcall——任何异常都不能中断官方 quickRace
-- 的计圈/记分链（否则会连累游戏内竞速状态）。
function M.onRaceWaypointReached(wpInfo)
  local ok, err = pcall(function()
    local scenario = safe(function() return scenario_scenarios.getScenario() end, nil)
    if not scenario or not scenario.isQuickRace then
      return
    end
    -- 与官方 quickRace 一致：next 为空（终点/收尾）或 1（起点线）均计一圈
    if wpInfo.next and wpInfo.next ~= 1 then
      return
    end
    local totalTime = wpInfo.time
    if not totalTime then
      return
    end
    -- 乱序/反向过线（累计时间回退）：直接丢弃，避免污染后续计圈
    local prev = prevCumulative or 0
    if totalTime < prev then
      return
    end
    currentLap = currentLap + 1
    local lapTime = totalTime - prev
    prevCumulative = totalTime
    -- 首圈阈值：起跑瞬间误触发（发车格压线）时不提交、不占圈号，
    -- 仅把累计时间作为后续计时的基准
    if currentLap == 1 and lapTime < 3 then
      currentLap = 0
      return
    end
    submitLap(lapTime, currentLap)
  end)
  if not ok then
    logE('onRaceWaypointReached 处理异常: %s', tostring(err))
  end
end

function M.onRaceResult()
  -- 收尾钩子：成绩已逐圈实时提交，这里只复位状态
  prevCumulative = nil
end

function M.onClientEndMission()
  prevCumulative = nil
  currentLap = 0
end

function M.onExtensionUnloaded()
  prevCumulative = nil
end

return M
