-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Native Free Camera backend used by the Ghost Racer GE extension.

local M = {}
local GHOST_CAMERA_POSE_TIMEOUT = 0.75

function M.new()
  local camera = {}
  local ghostCamera = {
    enabled = false,
    mode = "chase",
    pose = nil,
    targetId = nil,
    targetLabel = nil,
    previousMode = nil,
    previousWasFree = false,
    previousFreePose = nil,
    previousFov = nil,
    smoothedPosition = nil,
    backend = nil,
    poseAge = 0,
    error = nil
  }

  local function publishGhostCameraState()
    if guihooks and guihooks.trigger then
      guihooks.trigger("GhostRacerCameraState", {
        enabled = ghostCamera.enabled,
        mode = ghostCamera.mode,
        targetId = ghostCamera.targetId,
        targetLabel = ghostCamera.targetLabel,
        backend = ghostCamera.backend,
        error = ghostCamera.error
      })
    end
  end

  local function activeCameraName()
    if type(core_camera) ~= "table" or type(core_camera.getActiveCamName) ~= "function" then
      return nil
    end
    local ok, name = pcall(core_camera.getActiveCamName)
    return ok and name or nil
  end

  local function switchCamera(name)
    if type(core_camera) ~= "table" or type(core_camera.setByName) ~= "function" then
      return false, "BeamNG camera API is unavailable"
    end
    local ok, result = pcall(core_camera.setByName, 0, name)
    if not ok or result == false then
      return false, ok and ("Camera mode unavailable: " .. tostring(name)) or tostring(result)
    end
    local selected = activeCameraName()
    if selected and selected ~= name then
      return false, "Camera mode did not activate: " .. tostring(name)
    end
    return true
  end

  local function isFreeCamera()
    if type(commands) ~= "table" or type(commands.isFreeCamera) ~= "function" then
      return nil
    end
    local ok, value = pcall(commands.isFreeCamera)
    return ok and value == true or false
  end

  local function readFreeCameraPose()
    if type(core_camera) ~= "table"
        or type(core_camera.getPositionXYZ) ~= "function"
        or type(core_camera.getQuatXYZW) ~= "function" then return nil end
    local posOk, px, py, pz = pcall(core_camera.getPositionXYZ)
    local rotOk, qx, qy, qz, qw = pcall(core_camera.getQuatXYZW)
    if not posOk or not rotOk then return nil end
    if not tonumber(px) or not tonumber(py) or not tonumber(pz)
        or not tonumber(qx) or not tonumber(qy) or not tonumber(qz)
        or not tonumber(qw) then return nil end
    return {px, py, pz, qx, qy, qz, qw}
  end

  local function normalizedComponents(x, y, z, fallbackX, fallbackY, fallbackZ)
    local length = math.sqrt(x * x + y * y + z * z)
    if length < 0.000001 then return fallbackX, fallbackY, fallbackZ end
    return x / length, y / length, z / length
  end

  local function enterNativeGhostCamera()
    if type(commands) ~= "table" or type(commands.setFreeCamera) ~= "function" then
      return false, "BeamNG Free Camera API is unavailable"
    end
    if type(core_camera) ~= "table" or type(core_camera.setPosRot) ~= "function" then
      return false, "BeamNG camera pose API is unavailable"
    end

    ghostCamera.previousWasFree = isFreeCamera() == true
    ghostCamera.previousMode = activeCameraName() or "orbit"
    ghostCamera.previousFreePose = ghostCamera.previousWasFree and readFreeCameraPose() or nil
    if type(core_camera.getFovDeg) == "function" then
      local ok, value = pcall(core_camera.getFovDeg)
      ghostCamera.previousFov = ok and tonumber(value) or nil
    end

    local ok, result = pcall(commands.setFreeCamera)
    if not ok or result == false then
      return false, ok and "BeamNG rejected Free Camera" or tostring(result)
    end
    if isFreeCamera() == false then return false, "Free Camera did not activate" end
    ghostCamera.backend = "nativeFree"
    ghostCamera.smoothedPosition = nil
    return true
  end

  local function applyNativeGhostCamera(elapsed)
    local pose = ghostCamera.pose
    if type(pose) ~= "table" then return false, "Ghost pose is unavailable" end
    if isFreeCamera() == false then
      local ok, result = pcall(commands.setFreeCamera)
      if not ok or result == false or isFreeCamera() == false then
        return false, "Free Camera was overridden"
      end
    end

    local px, py, pz = pose[1], pose[2], pose[3]
    local fx, fy, fz = normalizedComponents(pose[4], pose[5], pose[6], 0, 1, 0)
    local ux, uy, uz = normalizedComponents(pose[7], pose[8], pose[9], 0, 0, 1)
    local cameraX, cameraY, cameraZ, lookX, lookY, lookZ, fieldOfView

    if ghostCamera.mode == "onboard" then
      cameraX, cameraY, cameraZ = px + fx * 0.65 + ux * 1.28,
        py + fy * 0.65 + uy * 1.28,
        pz + fz * 0.65 + uz * 1.28
      lookX, lookY, lookZ = fx, fy, fz
      fieldOfView = 70
      ghostCamera.smoothedPosition = nil
    else
      local desiredX, desiredY, desiredZ = px - fx * 7 + ux * 2.7,
        py - fy * 7 + uy * 2.7,
        pz - fz * 7 + uz * 2.7
      local blend = elapsed > 0 and (1 - math.exp(-elapsed * 10)) or 1
      local smoothed = ghostCamera.smoothedPosition
      if not smoothed then
        smoothed = {desiredX, desiredY, desiredZ}
        ghostCamera.smoothedPosition = smoothed
      else
        smoothed[1] = smoothed[1] + (desiredX - smoothed[1]) * blend
        smoothed[2] = smoothed[2] + (desiredY - smoothed[2]) * blend
        smoothed[3] = smoothed[3] + (desiredZ - smoothed[3]) * blend
      end
      cameraX, cameraY, cameraZ = smoothed[1], smoothed[2], smoothed[3]
      lookX, lookY, lookZ = normalizedComponents(
        px + fx * 2 + ux * 0.9 - cameraX,
        py + fy * 2 + uy * 0.9 - cameraY,
        pz + fz * 2 + uz * 0.9 - cameraZ,
        fx, fy, fz
      )
      fieldOfView = 65
    end

    local quatOk, rotation = pcall(
      quatFromDir,
      vec3(lookX, lookY, lookZ),
      vec3(ux, uy, uz)
    )
    if not quatOk or not rotation then return false, "Ghost camera rotation failed" end
    local qx, qy, qz, qw = tonumber(rotation.x), tonumber(rotation.y),
      tonumber(rotation.z), tonumber(rotation.w)
    if not qx or not qy or not qz or not qw then
      return false, "Ghost camera rotation is invalid"
    end

    local poseOk, poseResult = pcall(
      core_camera.setPosRot,
      0, cameraX, cameraY, cameraZ, qx, qy, qz, qw
    )
    if not poseOk or poseResult == false then
      return false, poseOk and "BeamNG rejected Ghost camera pose" or tostring(poseResult)
    end
    if type(core_camera.setFOV) == "function" then
      pcall(core_camera.setFOV, 0, fieldOfView)
    end
    return true
  end

  local function restoreGhostCamera(reason)
    local restoreMode = ghostCamera.previousMode
    local restoreWasFree = ghostCamera.previousWasFree
    local restoreFreePose = ghostCamera.previousFreePose
    local restoreFov = ghostCamera.previousFov
    local wasEnabled = ghostCamera.enabled
    ghostCamera.enabled = false
    ghostCamera.pose = nil
    ghostCamera.poseAge = 0
    ghostCamera.targetId = nil
    ghostCamera.targetLabel = nil
    ghostCamera.previousMode = nil
    ghostCamera.previousWasFree = false
    ghostCamera.previousFreePose = nil
    ghostCamera.previousFov = nil
    ghostCamera.smoothedPosition = nil
    ghostCamera.backend = nil
    ghostCamera.error = reason
    if wasEnabled then
      if restoreWasFree then
        if restoreFreePose and type(core_camera.setPosRot) == "function" then
          pcall(core_camera.setPosRot, 0,
            restoreFreePose[1], restoreFreePose[2], restoreFreePose[3],
            restoreFreePose[4], restoreFreePose[5], restoreFreePose[6], restoreFreePose[7])
        end
      else
        if type(commands) == "table" and type(commands.setGameCamera) == "function" then
          pcall(commands.setGameCamera)
        end
        switchCamera(restoreMode or "orbit")
      end
      if restoreFov and type(core_camera) == "table"
          and type(core_camera.setFOV) == "function" then
        pcall(core_camera.setFOV, 0, restoreFov)
      end
    end
    publishGhostCameraState()
  end

  function camera.setPose(pose, enabled, mode, targetId, targetLabel)
    if enabled ~= true then
      restoreGhostCamera(nil)
      return true
    end
    if type(pose) ~= "table" then return false end

    local parsed = {}
    for index = 1, 9 do
      parsed[index] = tonumber(pose[index])
      if not parsed[index] then return false end
    end
    mode = tostring(mode or "chase")
    if mode ~= "chase" and mode ~= "onboard" then mode = "chase" end
    local normalizedTargetId = targetId and tostring(targetId) or nil
    local normalizedTargetLabel = targetLabel and tostring(targetLabel) or nil
    local stateChanged = not ghostCamera.enabled
      or ghostCamera.mode ~= mode
      or ghostCamera.targetId ~= normalizedTargetId

    ghostCamera.mode = mode
    ghostCamera.pose = parsed
    ghostCamera.targetId = normalizedTargetId
    ghostCamera.targetLabel = normalizedTargetLabel
    if not ghostCamera.enabled then
      local switched, errorMessage = enterNativeGhostCamera()
      if not switched then
        ghostCamera.error = errorMessage
        if type(log) == "function" then
          log("E", "ghostlapping.camera", "Ghost camera activation failed: " .. tostring(errorMessage))
        end
        publishGhostCameraState()
        return false
      end
    end

    ghostCamera.enabled = true
    ghostCamera.poseAge = 0
    ghostCamera.error = nil
    local applied, applyError = applyNativeGhostCamera(0)
    if not applied then
      if type(log) == "function" then
        log("E", "ghostlapping.camera", "Ghost camera pose failed: " .. tostring(applyError))
      end
      restoreGhostCamera(applyError)
      return false
    end
    if stateChanged then
      if type(log) == "function" then
        log("I", "ghostlapping.camera", "Native Free Camera active for "
          .. tostring(normalizedTargetLabel or normalizedTargetId or "Ghost"))
      end
      publishGhostCameraState()
    end
    return true
  end

  function camera.getState()
    return ghostCamera
  end

  function camera.snapshot()
    return camera.getState()
  end


  function camera.update(elapsed)
    elapsed = math.max(tonumber(elapsed) or 0, 0)
    if not ghostCamera.enabled then return true end
    ghostCamera.poseAge = ghostCamera.poseAge + elapsed
    if ghostCamera.poseAge > GHOST_CAMERA_POSE_TIMEOUT then
      restoreGhostCamera("Ghost pose stream stopped")
      return false
    end

    local applied, errorMessage = applyNativeGhostCamera(elapsed)
    if not applied then
      if type(log) == "function" then
        log("E", "ghostlapping.camera", "Ghost camera update failed: "
          .. tostring(errorMessage))
      end
      restoreGhostCamera(errorMessage)
      return false
    end
    return true
  end

  function camera.restore(reason)
    restoreGhostCamera(reason)
  end

  return camera
end

return M
