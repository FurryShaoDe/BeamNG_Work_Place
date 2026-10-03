# -*- coding: utf-8 -*-
# One-off: actually load and drive the LapLog vehicle controller in a lupa
# sandbox with stubbed engine globals, to see whether init/sendUiState can
# really run in-game (the UI stays "connecting" when the state hook never
# leaves the vehicle VM).
import lupa

BASE = 'c:/Users/ShaoDe/Desktop/Github_Project/BeamNG_Work_Place/Mod/LapLog/lua'

stub = r'''
-- Lua-5.1 helpers BeamNG ships but stock Lua may not have
if not table.clear then
  table.clear = function(t) for k in pairs(t) do t[k] = nil end end
end
if not table.getn then table.getn = function(t) return #t end end
if not math.round then math.round = function(x) return math.floor(x + 0.5) end end

package.path = 'BASE/?.lua;BASE/?/init.lua;' .. package.path

local function noop() end
log = function(level, domain, msg) end
nop = noop
dumps = function(v) return tostring(v) end
debugPrint = noop
registerCoreModule = noop

vec3 = function(x, y, z)
  local v = {x = x or 0, y = y or 0, z = z or 0}
  function v:length() return 0 end
  function v:normalized() return vec3(0, 0, 1) end
  return v
end

color = function(r, g, b, a) return {r = r or 1, g = g or 1, b = b or 1, a = a or 1} end
colorGetRGBA = function() return 1, 1, 1, 1 end

jsonEncodeWorkBuffer = function(t) return '{}' end
jsonEncode = function(t) return '{}' end
jsonDecode = function(s) return {} end
jsonReadFile = function(p) return nil end
jsonWriteFile = function(p, d) end

path = {split = function(p) return p end, basename = function(p) return p end}
FS = {}
function FS:fileExists(p) return false end
function FS:findFiles(root, pattern, depth, skipHidden, includeDirs) return {} end
function FS:removeFile(p) return true end

tableValuesAsLookupDict = function(tbl)
  local r = {}
  for _, v in pairs(tbl) do r[v] = true end
  return r
end

playerInfo = {firstPlayerSeated = true}
execCtxWebId = 0
electrics = {values = {}}
controller = {getController = function(name) return nil end}

v = {data = {vehicleDirectory = 'test_vehicle', refNodes = {[0] = {nodeMaterialName = 'x'}}}}
function v:getObjectId() return 1 end
function v:getPositionXYZ() return 0, 0, 0 end
function v:getVelocity() return vec3(0, 0, 0) end

obj = {}
function obj:getObjectId() return 1 end
function obj:getPositionXYZ() return 0, 0, 0 end
function obj:getVelocity() return vec3(0, 0, 0) end
function obj:getDirectionVector(a, b) return 0, 1, 0 end
function obj:queueGameEngineLua(cmd) end
function obj:queueLuaCommand(cmd) end
function obj:queueHookJS(a, b, c) end

be = {}
function be:getSurfaceHeightBelow(x, y, z) return 0 end

guihooks = {
  trigger = function(name, data)
    _G.__hooks = (_G.__hooks or 0) + 1
    _G.__lastHook = name
  end,
  message = function(...) end
}
'''

probe = r'''
local ok, mod = pcall(require, "vehicle/controller/lapLog")
print("require controller      -> ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(mod))))
if not ok then return end

print("exports: init=" .. tostring(type(mod.init)) ..
      " requestState=" .. tostring(type(mod.requestState)) ..
      " sendUiState=" .. tostring(type(mod.sendUiState)) ..
      " updateGFX=" .. tostring(type(mod.updateGFX)))

local h0 = _G.__hooks or 0
local okInit, errInit = pcall(function() mod.init({}) end)
print("init({})                -> ok=" .. tostring(okInit) .. (okInit and "" or (" err=" .. tostring(errInit))))
print("   hooks fired: " .. ((_G.__hooks or 0) - h0))

local h1 = _G.__hooks or 0
local okState, errState = pcall(function() mod.requestState() end)
print("requestState()          -> ok=" .. tostring(okState) .. (okState and "" or (" err=" .. tostring(errState))))
print("   hooks fired: " .. ((_G.__hooks or 0) - h1) .. " last=" .. tostring(_G.__lastHook))

if type(mod.updateGFX) == "function" then
  for i = 1, 30 do
    local okU, errU = pcall(function() mod.updateGFX(0.1) end)
    if not okU then
      print("updateGFX #" .. i .. "       -> FAILED: " .. tostring(errU))
      break
    end
    if i == 30 then
      print("updateGFX x30           -> ok, hooks total=" .. tostring(_G.__hooks))
    end
  end
else
  print("updateGFX               -> NOT EXPORTED (no 10 Hz broadcast path!)")
end
'''

runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
try:
    runtime.execute(stub.replace('BASE', BASE))
    runtime.execute(probe)
except lupa.LuaError as e:
    print('LUA ERROR:', e)
