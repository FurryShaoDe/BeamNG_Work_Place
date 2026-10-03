/*
 * This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
 * Original Ghost Racer Replay by Jesus Goose.
 * UI and interaction modifications by flintt, 2026.
 */

angular.module('beamng.apps')
.directive('ghostRacerApp', [function () {
  return {
    templateUrl: '/ui/modules/apps/ghostRacerApp/app.html?v=2.19.8',
    replace: true,
    restrict: 'EA',
    scope: true,
    controller: ['$scope', '$element', '$document', function ($scope, $element, $document) {
      const appVersion = '2.19.8'
      const uiOwnerToken = `ghostRacer-${Date.now()}-${Math.random().toString(36).slice(2)}`
      const storagePrefix = 'ghostRacerEnhanced_'
      const colors = ['orange', 'cyan', 'green', 'magenta', 'white']
      const minimizedSize = 104
      let initialApplyTimer = null
      let connectionTimer = null
      let hostElement = null
      let expandedHostStyle = null
      let ghostModePending = null
      let ghostDeleteArmSerial = 0
      let startDeleteArmSerial = 0
      let startLineNameEditing = false
      let runtimeActive = false
      let diagnosticSerial = 0
      let lastIgnoredOwner = null
      let lastStateTraceId = null
      let lastPartialFilterStateSignature = null

      function nextDiagnosticTraceId(action) {
        diagnosticSerial += 1
        return `${action}-${Date.now()}-${diagnosticSerial}`
      }

      function diagnosticLog(area, details) {
        console.log(`[GhostRacerDiag.UI][v${appVersion}][${area}][ui=${uiOwnerToken}] ${details}`)
      }

      function startLineNameInput() {
        const root = $element && $element[0]
        if (!root || typeof root.querySelector !== 'function') return null
        return root.querySelector('.gr-start-name input')
      }

      function startLineNameInputFocused() {
        const input = startLineNameInput()
        const documentNode = $document && ($document[0] || $document)
        return Boolean(input && documentNode && documentNode.activeElement === input)
      }

      function findAppHost() {
        if (hostElement) return hostElement

        let node = $element[0]
        let fallback = node
        for (let depth = 0; node && depth < 6; depth += 1, node = node.parentElement) {
          const className = typeof node.className === 'string' ? node.className : ''
          const hasInlineSize = Boolean(node.style && node.style.width && node.style.height)
          if (hasInlineSize || /(^|\s)(bng-app|app-container|grid-stack-item|gridster-item)(\s|$)/i.test(className)) {
            hostElement = node
            break
          }
        }

        hostElement = hostElement || fallback
        return hostElement
      }

      function syncHostSize() {
        const host = findAppHost()
        if (!host || !host.style) return

        if (!expandedHostStyle) {
          expandedHostStyle = {
            width: host.style.width,
            height: host.style.height,
            minWidth: host.style.minWidth,
            minHeight: host.style.minHeight,
            maxWidth: host.style.maxWidth,
            maxHeight: host.style.maxHeight,
            overflow: host.style.overflow
          }
        }

        if ($scope.minimized) {
          const size = `${minimizedSize}px`
          host.style.width = size
          host.style.height = size
          host.style.minWidth = size
          host.style.minHeight = size
          host.style.maxWidth = size
          host.style.maxHeight = size
          host.style.overflow = 'visible'
        } else {
          Object.keys(expandedHostStyle).forEach(function (property) {
            host.style[property] = expandedHostStyle[property]
          })
        }
      }

      function removeMountedApp() {
        if ($scope.$$destroyed) return
        runtimeActive = false
        const root = $element[0]
        if (root && root.style) {
          root.style.display = 'none'
          root.style.visibility = 'hidden'
          root.style.pointerEvents = 'none'
        }
        if (typeof $scope.$destroy === 'function') $scope.$destroy()
        if ($element && typeof $element.remove === 'function') {
          $element.remove()
        }
      }

      function probeRuntime(attempt) {
        bngApi.engineLua(
          '(function() local e=extensions and extensions.ghostlapping or nil; ' +
          'return {active=e~=nil,codeVersion=e and e.getCodeVersion and ' +
          'e.getCodeVersion() or nil} end)()',
          function (result) {
            if ($scope.$$destroyed) return
            result = result || {}
            if (result.active === true && result.codeVersion === appVersion) {
              runtimeActive = true
              $scope.state.codeVersion = result.codeVersion
              armConnectionTimer()
              setTimeout(syncHostSize, 0)
              scheduleSettingsApply(250)
              return
            }
            if (result.active === true) {
              $scope.state.status = 'error'
              $scope.state.message = `GE extension ${result.codeVersion || 'unknown'} does not match UI ${appVersion}`
              return
            }
            if (attempt < 4) {
              setTimeout(function () { probeRuntime(attempt + 1) }, 250)
              return
            }
            removeMountedApp()
          }
        )
      }

      function readBoolean(key, fallback) {
        const value = localStorage.getItem(storagePrefix + key)
        return value === null ? fallback : value === 'true'
      }

      function readNumber(key, fallback) {
        const stored = localStorage.getItem(storagePrefix + key)
        if (stored === null) return fallback
        const value = Number(stored)
        return Number.isFinite(value) ? value : fallback
      }

      function readString(key, fallback) {
        return localStorage.getItem(storagePrefix + key) || fallback
      }

      function saveSetting(key, value) {
        localStorage.setItem(storagePrefix + key, String(value))
      }

      function scheduleSettingsApply(delay) {
        if (initialApplyTimer !== null) clearTimeout(initialApplyTimer)
        initialApplyTimer = setTimeout(function () {
          initialApplyTimer = null
          if ($scope.$$destroyed || !runtimeActive) return
          applyAllSettings()
        }, delay)
      }

      function callController(expression, onComplete, skipReloadRecovery) {
        if (!runtimeActive) {
          if (typeof onComplete === 'function') {
            onComplete({ok: false, error: 'Ghost Racer mod is not active'})
          }
          return
        }
        bngApi.activeObjectLua(
          '(function() local c=controller.getController and ' +
          'controller.getController("ghostRacer") or nil; ' +
          `local expectedVersion=${JSON.stringify(appVersion)}; ` +
          `local ownerToken=${JSON.stringify(uiOwnerToken)}; ` +
          'local loadError=nil; local actionResult=nil; local actionError=nil; ' +
          'local reloaded=false; ' +
          'if c then local loadedVersion=c.getCodeVersion and c.getCodeVersion() or nil; ' +
          'if loadedVersion~=expectedVersion then ' +
          'if controller.unloadControllerExternal then ' +
          'local unloadOk,unloadResult=pcall(controller.unloadControllerExternal,"ghostRacer"); ' +
          'if unloadOk and unloadResult~=false then c=nil; reloaded=true ' +
          'else loadError="Could not unload stale controller: "..tostring(unloadResult) end ' +
          'else loadError="unloadControllerExternal unavailable" end end end; ' +
          'if not c then ' +
          'if controller.loadControllerExternal then ' +
          'local ok,result=pcall(controller.loadControllerExternal,' +
          '"ghostRacer","ghostRacer",{}); ' +
          'if not ok then loadError=tostring(result) end ' +
          'else loadError="loadControllerExternal unavailable" end; ' +
          'c=controller.getController and controller.getController("ghostRacer") or nil end; ' +
          'local codeVersion=c and c.getCodeVersion and c.getCodeVersion() or nil; ' +
          'if c and codeVersion~=expectedVersion then return {ok=false,' +
          'error="Controller version "..tostring(codeVersion).." does not match UI "..expectedVersion,' +
          'codeVersion=codeVersion,expectedVersion=expectedVersion,reloadRequired=true} end; ' +
          'if c and c.requestState then ' +
          'if c.setUiOwnerToken then c.setUiOwnerToken(ownerToken) end; ' +
          'local actionOk,actionFailure=pcall(function() ' + expression + ' end); ' +
          'if not actionOk then return {ok=false,codeVersion=codeVersion,' +
          'error="Controller action failed: "..tostring(actionFailure),' +
          'actionResult=actionResult,actionError=actionError,reloaded=reloaded} end; ' +
          'local stateOk,stateFailure=pcall(c.requestState); ' +
          'if not stateOk then return {ok=false,codeVersion=codeVersion,' +
          'error="Controller state request failed: "..tostring(stateFailure),' +
          'actionResult=actionResult,actionError=actionError,reloaded=reloaded} end; ' +
          'return {ok=true,codeVersion=codeVersion,actionResult=actionResult,' +
          'actionError=actionError,reloaded=reloaded} end; ' +
          'return {ok=false,error=loadError or ' +
          '(c and "Controller API mismatch" or "Controller did not register")} end)()',
          function (result) {
            $scope.$evalAsync(function () {
              if (connectionTimer !== null) {
                clearTimeout(connectionTimer)
                connectionTimer = null
              }

              if (!result || result.ok !== true) {
                $scope.state.status = 'error'
                $scope.state.message = result && result.error
                  ? String(result.error)
                  : 'No active vehicle response'
                if (typeof onComplete === 'function') onComplete(result)
                return
              }

              if (result.codeVersion) $scope.state.codeVersion = result.codeVersion
              if (result.reloaded === true && skipReloadRecovery !== true) {
                $scope.state.message = 'Controller updated; restoring saved start…'
                loadSavedSession(function () {
                  callController(expression, onComplete, true)
                }, true)
                return
              }
              if ($scope.state.status === 'connecting' || $scope.state.status === 'error') {
                $scope.state.status = 'idle'
                $scope.state.message = 'Controller connected'
              }
              if (typeof onComplete === 'function') onComplete(result)
            })
          }
        )
      }

      function armConnectionTimer() {
        if (connectionTimer !== null) clearTimeout(connectionTimer)
        connectionTimer = setTimeout(function () {
          $scope.$evalAsync(function () {
            if ($scope.state.status === 'connecting') {
              $scope.state.status = 'error'
              $scope.state.message = 'No response from active vehicle'
            }
          })
        }, 1500)
      }

      $scope.appVersion = appVersion
      $scope.uiOwnerToken = uiOwnerToken
      $scope.minimized = readBoolean('minimized', false)
      $scope.settingsOpen = readBoolean('settingsOpen', false)
      $scope.sampleRates = [20, 30, 50, 100]
      $scope.trailDurations = [1, 2, 3, 5]
      $scope.routeCheckpointSpacings = [100, 150, 200, 300, 500]
      $scope.liveInputTrailMaxSegmentsOptions = [100, 250, 500, 1000, 2000]
      $scope.topGhostCounts = [2, 3, 5, 10]
      $scope.colors = colors
      $scope.ghostModes = [
        { value: 'best', label: 'Dynamic best', description: 'Always follow the fastest saved lap' },
        { value: 'top', label: 'Top N ghosts', description: 'Show the fastest N saved laps together' },
        { value: 'single', label: 'Specified ghost', description: 'Show one ghost selected from the list' },
        { value: 'multi', label: 'Selected ghosts', description: 'Show only the ghosts you mark' },
        { value: 'all', label: 'All ghosts', description: 'Display every saved lap together' }
      ]
      $scope.trailModes = [
        { value: 'speed', label: 'Absolute speed', description: 'Color the trail by road speed' },
        { value: 'acceleration', label: 'Acceleration / braking', description: 'Color throttle and braking forces' },
        { value: 'inputs', label: 'Driver inputs', description: 'Color by the ghost’s inputs: red braking, green throttle, amber both together, brighter the harder pressed; pink/purple gear shifts, blue handbrake (2.18+ recordings)' }
      ]
      $scope.cameraModes = [
        { value: 'chase', label: 'Chase camera', description: 'Smooth camera behind the selected Ghost' },
        { value: 'onboard', label: 'Onboard camera', description: 'Fixed forward view from the selected Ghost' }
      ]
      $scope.ghostMode = 'best'
      $scope.openOptionMenu = null
      $scope.settings = {
        quality: Math.max(1, Math.min(10, readNumber('quality', 6))),
        sampleRate: $scope.sampleRates.includes(readNumber('sampleRate', 50))
          ? readNumber('sampleRate', 50)
          : 50,
        visible: readBoolean('visible', true),
        showIncomplete: readBoolean('showIncomplete', false),
        ghostCategory: ['complete', 'incomplete', 'both'].includes(readString('ghostCategory', 'complete'))
          ? readString('ghostCategory', 'complete')
          : 'complete',
        showManual: readBoolean('showManual', true),
        ghostShell: readBoolean('ghostShell', false),
        showStartGate: readBoolean('showStartGate', true),
        restoreSavedStart: readBoolean('restoreSavedStart', true),
        showSavedStartMarkers: readBoolean('showSavedStartMarkers', true),
        showRouteGuide: readBoolean('showRouteGuide', true),
        showRoutePath: readBoolean('showRoutePath', true),
        showRouteCheckpoints: readBoolean('showRouteCheckpoints', true),
        showBestLapLine: readBoolean('showBestLapLine', false),
        showClutchLine: readBoolean('showClutchLine', false),
        showHandbrakeLine: readBoolean('showHandbrakeLine', false),
        showLiveInputTrail: readBoolean('showLiveInputTrail', false),
        liveInputTrailMaxSegments: $scope.liveInputTrailMaxSegmentsOptions.includes(
          readNumber('liveInputTrailMaxSegments', 500)
        ) ? readNumber('liveInputTrailMaxSegments', 500) : 500,
        routeCheckpointSpacing: $scope.routeCheckpointSpacings.includes(
          readNumber('routeCheckpointSpacing', 200)
        ) ? readNumber('routeCheckpointSpacing', 200) : 200,
        showGhostTrail: readBoolean('showGhostTrail', false),
        trailSeconds: $scope.trailDurations.includes(readNumber('trailSeconds', 3))
          ? readNumber('trailSeconds', 3)
          : 3,
        trailMode: ['speed', 'acceleration', 'inputs'].includes(readString('trailMode', 'speed'))
          ? readString('trailMode', 'speed')
          : 'speed',
        cameraMode: ['chase', 'onboard'].includes(readString('cameraMode', 'chase'))
          ? readString('cameraMode', 'chase')
          : 'chase',
        loop: readBoolean('loop', false),
        topGhostCount: $scope.topGhostCounts.includes(readNumber('topGhostCount', 3))
          ? readNumber('topGhostCount', 3)
          : 3,
        color: colors.includes(readString('color', 'orange'))
          ? readString('color', 'orange')
          : 'orange'
      }

      $scope.state = {
        status: 'connecting',
        message: 'Connecting…',
        codeVersion: null,
        recording: false,
        playing: false,
        raceMode: false,
        autoLapEnabled: false,
        autoLapActive: false,
        startLineSet: false,
        finishLineSet: false,
        pointToPoint: false,
        activeStartLineId: null,
        startLineName: null,
        savedStartLines: [],
        savedStartMarkersVisible: true,
        startGateVisible: true,
        ghostTrailVisible: false,
        ghostTrailMode: 'speed',
        ghostTrailSeconds: 3,
        routeGuideEnabled: true,
        routeAlignmentMode: 'hybrid',
        routePathVisible: true,
        routeCheckpointsVisible: true,
        routeCheckpointSpacing: 200,
        routeGuideActive: false,
        routeGuideReady: false,
        routeDistance: 0,
        routePointCount: 0,
        routeCheckpointCount: 0,
        routeSourceLabel: null,
        bestLapLineVisible: false,
        bestLapLineReady: false,
        bestLapLineSourceLabel: null,
        autoLapNumber: 0,
        lastLapTime: null,
        lastLapRank: null,
        lastLapRecordCount: null,
        lastLapStored: null,
        autoLapLineDistance: 0,
        autoLapLateralDistance: 0,
        autoLapGateState: 'off',
        autoLapLastReject: null,
        autoLapCrossingArmed: false,
        autoLapDeltaSuppressed: false,
        hasRecording: false,
        sampleCount: 0,
        progress: 0,
        elapsed: 0,
        duration: 0,
        pbTime: null,
        timeDelta: null,
        speedDelta: null,
        liveRank: null,
        liveRankTotal: null,
        currentSpeed: 0,
        ghostDisplayMode: 'best',
        topGhostCount: 3,
        ghostCount: 0,
        completeGhostCount: 0,
        incompleteGhostCount: 0,
        manualGhostCount: 0,
        showIncomplete: false,
        ghostCategoryFilter: 'complete',
        showManual: true,
        ghostRenderMode: 'wireframe',
        ghostShellActive: false,
        ghostShellUnavailableReason: null,
        displayedGhostCount: 0,
        ghostCameraEnabled: false,
        ghostCameraMode: 'chase',
        ghostCameraTargetId: null,
        ghostCameraTargetLabel: null,
        ghostCameraAvailable: false,
        ghostCameraBackend: null,
        maxStoredGhosts: 20,
        maxStoredIncompleteGhosts: 20,
        importPending: false,
        importPendingSummary: null,
        ghosts: []
      }
      $scope.startLineNameDraft = ''
      $scope.pendingGhostDeleteId = null
      $scope.pendingStartDeleteId = null
      $scope.shareSelection = Object.create(null)
      $scope.routeMatch = {
        status: 'idle',
        matchedPoints: 0,
        totalPoints: 0,
        coverage: 0,
        matchedCheckpoints: 0,
        totalCheckpoints: 0
      }

      $scope.toggleMinimize = function () {
        $scope.minimized = !$scope.minimized
        saveSetting('minimized', $scope.minimized)
        setTimeout(syncHostSize, 0)
      }

      $scope.toggleSettings = function () {
        $scope.settingsOpen = !$scope.settingsOpen
        saveSetting('settingsOpen', $scope.settingsOpen)
      }

      function stopMenuEvent(event) {
        if (event && typeof event.stopPropagation === 'function') event.stopPropagation()
      }

      function closeOptionMenu() {
        if (!$scope.openOptionMenu || $scope.$$destroyed) return
        $scope.$evalAsync(function () { $scope.openOptionMenu = null })
      }

      $scope.toggleOptionMenu = function (name, event) {
        stopMenuEvent(event)
        $scope.openOptionMenu = $scope.openOptionMenu === name ? null : name
      }

      $scope.ghostModeLabel = function () {
        const selected = $scope.ghostModes.find(function (mode) {
          return mode.value === $scope.ghostMode
        })
        return selected ? selected.label : 'Dynamic best'
      }

      $scope.ghostModeDescription = function () {
        const selected = $scope.ghostModes.find(function (mode) {
          return mode.value === $scope.ghostMode
        })
        return selected ? selected.description : 'Always follow the fastest saved lap'
      }

      $scope.topGhostCountDescription = function (count) {
        return `Play the ${Number(count) || 3} fastest saved laps`
      }

      $scope.trailModeLabel = function () {
        const selected = $scope.trailModes.find(function (mode) {
          return mode.value === $scope.settings.trailMode
        })
        return selected ? selected.label : 'Absolute speed'
      }

      $scope.trailModeDescription = function () {
        const selected = $scope.trailModes.find(function (mode) {
          return mode.value === $scope.settings.trailMode
        })
        return selected ? selected.description : 'Color the trail by road speed'
      }

      // In Driver-inputs mode, warn when the line/trail on screen comes from a
      // ghost recorded before 2.18, which has no pedal data and therefore falls
      // back to the acceleration colours (so the mode looks like it did nothing).
      $scope.inputsModeHasNoData = function () {
        if ($scope.settings.trailMode !== 'inputs') return false
        const ghosts = ($scope.state && $scope.state.ghosts) || []
        const shown = ghosts.filter(function (ghost) {
          return ghost && (ghost.displayed || ghost.isBest)
        })
        if (!shown.length) return false
        return !shown.some(function (ghost) { return ghost.hasInputs })
      }

      $scope.cameraModeLabel = function () {
        const selected = $scope.cameraModes.find(function (mode) {
          return mode.value === $scope.settings.cameraMode
        })
        return selected ? selected.label : 'Chase camera'
      }

      $scope.cameraModeDescription = function () {
        const selected = $scope.cameraModes.find(function (mode) {
          return mode.value === $scope.settings.cameraMode
        })
        return selected ? selected.description : 'Smooth camera behind the selected Ghost'
      }

      $scope.trailLengthDescription = function (seconds) {
        const descriptions = {
          1: 'Shortest live tail and finish linger',
          2: 'Compact tail with a 2-second finish linger',
          3: 'Balanced tail and finish continuity',
          5: 'Longest tail and finish linger; heavier with many ghosts'
        }
        return descriptions[Number(seconds)] || 'Visible time behind each ghost'
      }

      $scope.sampleRateDescription = function (rate) {
        const descriptions = {
          20: 'Lightest CPU and smallest replay files',
          30: 'Efficient recording for most vehicles',
          50: 'Balanced detail and performance',
          100: 'Maximum detail for fast motion'
        }
        return descriptions[Number(rate)] || 'Recording sample frequency'
      }

      $scope.savedStartLabel = function () {
        const selected = ($scope.state.savedStartLines || []).find(function (line) {
          return line.id === $scope.state.activeStartLineId
        })
        return selected ? selected.name : 'Choose saved start'
      }

      // Two-level starts: lines that share a startKey are one physical start
      // (a group) with several track variants. The Start dropdown lists groups;
      // the Track dropdown lists the variants of the active group.
      $scope.startGroups = function () {
        const lines = $scope.state.savedStartLines || []
        const byKey = {}
        const order = []
        lines.forEach(function (line) {
          const key = line.startKey || line.id
          if (!byKey[key]) { byKey[key] = []; order.push(key) }
          byKey[key].push(line)
        })
        return order.map(function (key) {
          const groupLines = byKey[key]
          const primary = groupLines.find(function (l) { return l.id === key }) || groupLines[0]
          const activeLine = groupLines.find(function (l) {
            return l.id === $scope.state.activeStartLineId
          })
          return {
            startKey: key,
            name: primary ? primary.name : key,
            lines: groupLines,
            count: groupLines.length,
            active: !!activeLine,
            activeLine: activeLine || primary
          }
        })
      }

      $scope.activeStartGroup = function () {
        return $scope.startGroups().find(function (group) { return group.active })
      }

      $scope.activeStartGroupLabel = function () {
        const group = $scope.activeStartGroup()
        return group ? group.name : 'Choose saved start'
      }

      $scope.activeTracks = function () {
        const group = $scope.activeStartGroup()
        return group ? group.lines : []
      }

      $scope.hasTrackVariants = function () {
        const group = $scope.activeStartGroup()
        return !!group && group.count > 1
      }

      $scope.selectStartGroup = function (group, event) {
        const target = group.activeLine || group.lines[0]
        if (target) $scope.selectSavedStart(target, event)
      }

      $scope.newStartVariant = function () {
        callController('if c.createStartVariant then c.createStartVariant() end')
      }

      $scope.reconnect = function () {
        $scope.state.status = 'connecting'
        $scope.state.message = 'Connecting…'
        armConnectionTimer()
        callController('do end')
      }

      $scope.setStartLine = function () {
        const traceId = nextDiagnosticTraceId('setStart')
        $scope.state.message = 'Reading current location…'
        diagnosticLog('setStart.request', `trace=${traceId} querying GE Time Trial profile`)
        bngApi.engineLua(
          '(function() local e=extensions and extensions.ghostlapping or nil; ' +
          'local profile=e and e.getCurrentTimeTrialProfile and ' +
          `e.getCurrentTimeTrialProfile(${JSON.stringify(traceId)}) or nil; return {` +
          'level=(getCurrentLevelIdentifier and getCurrentLevelIdentifier() or "unknown_level"),' +
          'timeTrial=profile} end)()',
          function (result) {
            result = result || {}
            const profile = result.timeTrial && result.timeTrial.id
              ? result.timeTrial
              : null
            const safeLevelName = typeof result.level === 'string'
              ? result.level
              : (profile && profile.level) || 'unknown_level'
            diagnosticLog(
              'setStart.profile',
              `trace=${traceId} level=${safeLevelName} profile=${JSON.stringify(profile)}`
            )
            let profileLiteral = 'nil'
            if (profile) {
              const fields = [
                `id=${JSON.stringify(String(profile.id))}`,
                `name=${JSON.stringify(String(profile.name || profile.id))}`,
                `level=${JSON.stringify(String(profile.level || safeLevelName))}`,
                `source=${JSON.stringify(String(profile.source || 'foregroundMission'))}`,
                `traceId=${JSON.stringify(traceId)}`
              ]
              ;['startX', 'startY', 'startZ', 'startNx', 'startNy', 'startNz']
                .forEach(function (key) {
                  const value = Number(profile[key])
                  if (isFinite(value)) fields.push(`${key}=${value}`)
                })
              profileLiteral = `{${fields.join(',')}}`
            }
            callController(
              `actionResult=(c.setStartLine and ` +
              `c.setStartLine(${JSON.stringify(safeLevelName)},${profileLiteral},` +
              `${JSON.stringify(traceId)})) ` +
              `and "started" or "failed"`,
              function (action) {
                diagnosticLog(
                  'setStart.result',
                  `trace=${traceId} action=${JSON.stringify(action)} ` +
                  `active=${$scope.state.activeStartLineId} name=${$scope.state.startLineName}`
                )
                if (!action || action.actionResult !== 'started') {
                  $scope.state.message = 'Could not create the start line'
                }
              }
            )
          }
        )
      }

      $scope.toggleAutoLap = function () {
        const enabled = !$scope.state.autoLapEnabled
        callController(`if c.setAutoLapEnabled then c.setAutoLapEnabled(${enabled}) end`)
      }

      $scope.clearStartLine = function () {
        callController('if c.clearStartLine then c.clearStartLine() end')
      }

      // Point-to-point: place a finish gate here, or clear it back to a circuit.
      $scope.toggleFinishLine = function () {
        if ($scope.state.finishLineSet) {
          callController('if c.clearFinishLine then c.clearFinishLine() end')
        } else {
          callController('if c.setFinishLine then c.setFinishLine() end')
        }
      }

      $scope.selectSavedStart = function (line, event) {
        stopMenuEvent(event)
        if (!line || !line.id) return
        startDeleteArmSerial += 1
        $scope.pendingStartDeleteId = null
        $scope.openOptionMenu = null
        callController(
          `actionResult=(c.selectSavedStartLine and ` +
          `c.selectSavedStartLine(${JSON.stringify(String(line.id))})) and "selected" or "failed"`,
          function (result) {
            if (!result || result.actionResult !== 'selected') {
              $scope.state.message = `Could not activate saved start ${line.name || line.id}`
            }
          }
        )
      }

      $scope.beginStartLineNameEdit = function () {
        startLineNameEditing = true
      }

      $scope.endStartLineNameEdit = function () {
        setTimeout(function () {
          startLineNameEditing = false
        }, 0)
      }

      $scope.renameStartLine = function (event) {
        if (event && typeof event.preventDefault === 'function') event.preventDefault()
        if (event && typeof event.stopPropagation === 'function') event.stopPropagation()
        const input = startLineNameInput()
        const domValue = input && typeof input.value === 'string' ? input.value : null
        const modelValue = $scope.startLineNameDraft
        // BeamNG's CEF/Angular 1.5 input model can lag behind the DOM until
        // blur, while the Rename click is delivered before that blur update.
        // The visible input value is authoritative for this user action.
        const name = String(domValue !== null ? domValue : modelValue || '')
          .trim().slice(0, 32)
        const id = $scope.state.activeStartLineId
          ? String($scope.state.activeStartLineId)
          : ''
        if (!name || !id) return
        const traceId = nextDiagnosticTraceId('rename')
        startLineNameEditing = false
        diagnosticLog(
          'rename.request',
          `trace=${traceId} target=${id} old=${JSON.stringify($scope.state.startLineName)} ` +
          `new=${JSON.stringify(name)} model=${JSON.stringify(modelValue)} ` +
          `dom=${JSON.stringify(domValue)} revision=${$scope.state.registryRevision}`
        )
        callController(
          `actionResult=(c.renameStartLine and ` +
          `c.renameStartLine(${JSON.stringify(name)},${JSON.stringify(id)},` +
          `${JSON.stringify(traceId)})) ` +
          `and "renamed" or "failed"`,
          function (result) {
            diagnosticLog(
              'rename.result',
              `trace=${traceId} action=${JSON.stringify(result)} ` +
              `stateName=${JSON.stringify($scope.state.startLineName)} ` +
              `revision=${$scope.state.registryRevision}`
            )
            if (!result || result.actionResult !== 'renamed') {
              $scope.state.message = 'Could not rename the selected start'
              return
            }
            $scope.state.startLineName = name
            const savedStartLines = $scope.state.savedStartLines || []
            savedStartLines.forEach(function (line) {
              if (String(line.id) === id) line.name = name
            })
            $scope.startLineNameDraft = name
            $scope.state.message = `Start renamed: ${name}`
          }
        )
      }

      $scope.requestDeleteSavedStart = function (event) {
        stopMenuEvent(event)
        const id = $scope.state.activeStartLineId
          ? String($scope.state.activeStartLineId)
          : ''
        if (!id) return
        const name = $scope.state.startLineName || $scope.savedStartLabel() || 'this start'

        if ($scope.pendingStartDeleteId === id) {
          startDeleteArmSerial += 1
          $scope.pendingStartDeleteId = null
          $scope.state.message = `Deleting ${name} and its Ghost laps…`
          callController(
            `actionResult=(c.deleteSavedStartLine and ` +
            `c.deleteSavedStartLine(${JSON.stringify(id)})) and "deleted" or "failed"`,
            function (result) {
              if (result && result.ok === true && result.actionResult === 'deleted') {
                $scope.state.message = `Deleted start ${name}`
              } else if (result && result.ok === true) {
                $scope.state.message = 'Delete failed: saved start was not found'
              }
            }
          )
          return
        }

        $scope.pendingStartDeleteId = id
        $scope.state.message = `Click CONFIRM to delete map start ${name} for every vehicle`
        const armSerial = ++startDeleteArmSerial
        setTimeout(function () {
          if (armSerial !== startDeleteArmSerial || $scope.$$destroyed) return
          $scope.$evalAsync(function () {
            if (armSerial === startDeleteArmSerial) {
              $scope.pendingStartDeleteId = null
              $scope.state.message = 'Start deletion cancelled'
            }
          })
        }, 5000)
      }

      $scope.toggleStartGate = function () {
        $scope.settings.showStartGate = !$scope.settings.showStartGate
        $scope.applyStartGateVisibility()
      }

      $scope.toggleRecording = function () {
        if ($scope.state.recording) {
          callController('if c.stopRecording then c.stopRecording() end')
        } else {
          callController('if c.startRecording then c.startRecording() end')
        }
      }

      $scope.togglePlayback = function () {
        if ($scope.state.playing) {
          callController('if c.stopPlayback then c.stopPlayback() end')
        } else {
          callController('if c.playRecording then c.playRecording() end')
        }
      }

      $scope.toggleGhostCamera = function () {
        const enabled = !$scope.state.ghostCameraEnabled
        callController(
          `actionResult=(c.setGhostCameraEnabled and c.setGhostCameraEnabled(${enabled})) ` +
          `and "applied" or "failed"`,
          function (result) {
            if (!result || result.actionResult !== 'applied') {
              $scope.state.message = enabled
                ? 'Start playback and display at least one Ghost before switching view'
                : 'Could not restore driver camera'
            }
          }
        )
      }

      $scope.selectGhostCameraTarget = function (ghost, event) {
        stopMenuEvent(event)
        if (!ghost || !ghost.id || !ghost.displayed) return
        callController(
          `local targetOk=c.setGhostCameraTarget and ` +
          `c.setGhostCameraTarget(${JSON.stringify(String(ghost.id))}); ` +
          `local cameraOk=targetOk and c.setGhostCameraEnabled and ` +
          `c.setGhostCameraEnabled(true); ` +
          `actionResult=(targetOk and cameraOk) and "applied" or "failed"`,
          function (result) {
            if (!result || result.actionResult !== 'applied') {
              $scope.state.message = 'Could not switch to this Ghost view'
            }
          }
        )
      }

      $scope.playOrViewGhost = function (ghost, event) {
        stopMenuEvent(event)
        if (!ghost || !ghost.id) return
        if ($scope.state.playing && ghost.displayed) {
          $scope.selectGhostCameraTarget(ghost)
          return
        }

        const previousMode = $scope.state.ghostDisplayMode || $scope.ghostMode || 'best'
        const filterEnabled = incompleteFilterEnabled()
        const traceId = nextDiagnosticTraceId('partialPlay')
        $scope.ghostMode = 'single'
        ghostModePending = 'single'
        diagnosticLog(
          'partial.play.request',
          `trace=${traceId} id=${String(ghost.id)} incomplete=${ghost.incomplete === true} ` +
          `source=${JSON.stringify(ghost.source)} ` +
          `filterRaw=${JSON.stringify($scope.settings.showIncomplete)} ` +
          `filterType=${typeof $scope.settings.showIncomplete} normalized=${filterEnabled} ` +
          `controllerFilter=${JSON.stringify($scope.state.showIncomplete)} ` +
          `availableRows=${$scope.visibleGhosts().length}`
        )
        callController(
          `local playOk=false; local playError="apiMissing"; ` +
          `if c.playGhost then playOk,playError=c.playGhost(` +
          `${JSON.stringify(String(ghost.id))},${filterEnabled},` +
          `${JSON.stringify(traceId)}) end; ` +
          `actionResult=playOk and "played" or "failed"; actionError=playError`,
          function (result) {
            diagnosticLog(
              'partial.play.result',
              `trace=${traceId} result=${JSON.stringify(result)} ` +
              `stateFilter=${JSON.stringify($scope.state.showIncomplete)}`
            )
            if (!result || result.actionResult !== 'played') {
              ghostModePending = null
              $scope.ghostMode = previousMode
              const errors = {
                filterDisabled: 'Partial is hidden by Show incomplete recordings',
                notFound: 'Recording is no longer present in the active Saved Start',
                loadFailed: 'Recording samples could not be read from disk',
                notDisplayed: 'Recording was loaded but could not enter the display set',
                playbackEmpty: 'Recording has too few valid samples to play',
                apiMissing: 'Vehicle controller does not provide direct Ghost playback'
              }
              $scope.state.message = errors[result && result.actionError] ||
                'Could not play this Ghost recording; check GhostRacerDiag logs'
            }
          }
        )
      }

      $scope.toggleGhostShare = function (ghost, event) {
        stopMenuEvent(event)
        if (!ghost || !ghost.id) return
        const id = String(ghost.id)
        if ($scope.shareSelection[id]) {
          delete $scope.shareSelection[id]
          return
        }
        if ($scope.shareSelectedCount() >= 5) {
          $scope.state.message = 'Share supports up to 5 selected Ghosts'
          return
        }
        $scope.shareSelection[id] = true
      }

      $scope.ghostShareSelected = function (ghost) {
        return Boolean(ghost && $scope.shareSelection[String(ghost.id)])
      }

      $scope.shareSelectedCount = function () {
        return Object.keys($scope.shareSelection).length
      }

      $scope.shareSelectedGhosts = function () {
        const ids = ($scope.state.ghosts || []).filter(function (ghost) {
          return $scope.shareSelection[String(ghost.id)] === true
        }).map(function (ghost) { return String(ghost.id) }).slice(0, 5)
        // The button stays clickable with nothing ticked so the empty case can
        // explain itself. The Vehicle controller owns the BeamNG Notice, which
        // stays readable while the HUD is collapsed, so send either way.
        if (!ids.length) {
          $scope.state.message = 'Tick the + checkbox on a Ghost row to share it'
        }
        const luaIds = `{${ids.map(function (id) { return JSON.stringify(id) }).join(',')}}`
        callController(
          `actionResult=(c.shareGhosts and c.shareGhosts(${luaIds})) ` +
          `and "sharing" or "failed"`
        )
      }

      $scope.importGhostsFromClipboard = function () {
        // Without a result callback the engine runs this text as a Lua chunk,
        // where a bare expression is a syntax error and the whole command is
        // silently dropped. It has to be a statement.
        bngApi.engineLua(
          'if extensions and extensions.ghostlapping and ' +
          'extensions.ghostlapping.importGhostsFromClipboard then ' +
          'extensions.ghostlapping.importGhostsFromClipboard() end'
        )
      }

      $scope.confirmClipboardImport = function () {
        callController(
          'actionResult=(c.confirmClipboardImport and c.confirmClipboardImport()) ' +
          'and "imported" or "failed"'
        )
      }

      $scope.cancelClipboardImport = function () {
        callController(
          'actionResult=(c.cancelClipboardImport and c.cancelClipboardImport()) ' +
          'and "cancelled" or "failed"'
        )
      }

      $scope.applyQuality = function () {
        $scope.settings.quality = Math.max(1, Math.min(10, Number($scope.settings.quality) || 6))
        saveSetting('quality', $scope.settings.quality)
        callController(`if c.setQuality then c.setQuality(${$scope.settings.quality}) end`)
      }

      $scope.applySampleRate = function () {
        const rate = Number($scope.settings.sampleRate) || 50
        $scope.settings.sampleRate = rate
        saveSetting('sampleRate', rate)
        callController(`if c.setSampleRate then c.setSampleRate(${rate}) end`)
      }

      $scope.selectSampleRate = function (rate, event) {
        stopMenuEvent(event)
        if (!$scope.sampleRates.includes(Number(rate))) return
        $scope.settings.sampleRate = Number(rate)
        $scope.openOptionMenu = null
        $scope.applySampleRate()
      }

      $scope.applyVisibility = function () {
        saveSetting('visible', $scope.settings.visible)
        callController(`if c.setVisible then c.setVisible(${$scope.settings.visible}) end`)
      }

      function incompleteFilterEnabled() {
        const value = $scope.settings.showIncomplete
        return value === true || value === 1 || value === 'true'
      }

      $scope.applyGhostCategory = function (value) {
        // Called with a value from the category buttons, and with no argument
        // from the reconnect restore path (where it reapplies the saved choice).
        const category = ['complete', 'incomplete', 'both'].includes(value)
          ? value
          : (['complete', 'incomplete', 'both'].includes($scope.settings.ghostCategory)
            ? $scope.settings.ghostCategory
            : 'complete')
        $scope.settings.ghostCategory = category
        // Keep the legacy boolean mirror in sync so the "hidden by filter" hints
        // and any other showIncomplete-driven UI keep reading a sane value.
        $scope.settings.showIncomplete = category !== 'complete'
        saveSetting('ghostCategory', category)
        saveSetting('showIncomplete', $scope.settings.showIncomplete)
        const traceId = nextDiagnosticTraceId('partialFilter')
        diagnosticLog(
          'partial.filter.category',
          `trace=${traceId} category=${category} controller=${JSON.stringify($scope.state.ghostCategoryFilter)}`
        )
        callController(
          `local ok=c.setGhostCategoryFilter and ` +
          `c.setGhostCategoryFilter(${JSON.stringify(category)}); ` +
          `actionResult=ok and "applied" or "failed"`,
          function (result) {
            diagnosticLog(
              'partial.filter.category.result',
              `trace=${traceId} result=${JSON.stringify(result)} ` +
              `stateFilter=${JSON.stringify($scope.state.ghostCategoryFilter)}`
            )
          }
        )
      }

      $scope.incompleteReasonLabel = function (reason) {
        const labels = {
          outsideWidth: 'OUTSIDE GATE',
          verticalOffset: 'VERTICAL OFFSET',
          tooSlow: 'TOO SLOW',
          segmentTooLong: 'POSITION JUMP',
          cooldown: 'GATE COOLDOWN',
          minimumLapTime: 'TOO SHORT',
          invalidGate: 'INVALID GATE',
          invalidLap: 'INVALID LAP',
          raceEnded: 'RACE ENDED',
          missionFailed: 'TIME TRIAL FAILED',
          missionAbandoned: 'TIME TRIAL ABANDONED',
          missionStopped: 'TIME TRIAL STOPPED',
          vehicleReset: 'VEHICLE RESET',
          startChanged: 'START CHANGED',
          autoLapDisabled: 'AUTO LAP OFF',
          autoLapRestarted: 'AUTO LAP RESTARTED',
          startDeactivated: 'START DEACTIVATED',
          safetyLimit: '30 MIN LIMIT'
        }
        if (labels[reason]) return labels[reason]
        return String(reason || 'INTERRUPTED')
          .replace(/([a-z])([A-Z])/g, '$1 $2')
          .toUpperCase()
      }

      $scope.manualFilterEnabled = function () {
        return $scope.settings.showManual !== false
      }

      $scope.visibleGhosts = function () {
        const ghosts = Array.isArray($scope.state.ghosts) ? $scope.state.ghosts : []
        const category = $scope.settings.ghostCategory || 'complete'
        const withManual = $scope.manualFilterEnabled()
        return ghosts.filter(function (ghost) {
          // "incomplete" shows only partials; completed laps and manual Runs are
          // hidden, matching the 3D view's category filter.
          if (category === 'incomplete') return !!ghost.incomplete
          if (category === 'complete' && ghost.incomplete) return false
          if (!withManual && ghost.manual) return false
          return true
        })
      }

      // The default TSStatic body is a cheap static mesh, so the shell is now
      // offered in every display mode and up to this many bodies.
      const SHELL_MAX_BODIES = 10
      $scope.shellCapacityExceeded = function () {
        return $scope.ghostMode === 'top' &&
          (Number($scope.settings.topGhostCount) || 3) > SHELL_MAX_BODIES
      }

      $scope.shellCapableMode = function () {
        return ['best', 'single', 'all', 'multi'].includes($scope.ghostMode) ||
          ($scope.ghostMode === 'top' && !$scope.shellCapacityExceeded())
      }

      function showTopWireframeNotice (count) {
        if (count <= SHELL_MAX_BODIES) return
        $scope.state.message = `Top ${count} uses wireframe Ghosts; ` +
          `the Ghost body supports up to Top ${SHELL_MAX_BODIES}`
      }

      $scope.shellUnavailable = function () {
        return Boolean($scope.state.ghostShellUnavailableReason)
      }

      $scope.applyGhostShell = function () {
        const enabled = $scope.settings.ghostShell === true
        saveSetting('ghostShell', enabled)
        callController(
          `if c.setGhostRenderMode then c.setGhostRenderMode(${
            JSON.stringify(enabled ? 'shell' : 'wireframe')}) end`
        )
      }

      $scope.applyManualVisibility = function () {
        const enabled = $scope.settings.showManual !== false
        $scope.settings.showManual = enabled
        saveSetting('showManual', enabled)
        callController(`if c.setShowManual then c.setShowManual(${enabled}) end`)
      }

      $scope.visibleDisplayedGhostCount = function () {
        return $scope.visibleGhosts().filter(function (ghost) { return ghost.displayed }).length
      }

      $scope.applyStartGateVisibility = function () {
        saveSetting('showStartGate', $scope.settings.showStartGate)
        callController(
          `if c.setStartGateVisible then c.setStartGateVisible(${$scope.settings.showStartGate}) end`
        )
      }

      $scope.applyGhostTrailVisibility = function () {
        saveSetting('showGhostTrail', $scope.settings.showGhostTrail)
        callController(
          `if c.setGhostTrailVisible then c.setGhostTrailVisible(${$scope.settings.showGhostTrail}) end`
        )
      }

      $scope.applyRouteGuideVisibility = function () {
        saveSetting('showRouteGuide', $scope.settings.showRouteGuide)
        callController(
          `if c.setRouteGuideEnabled then c.setRouteGuideEnabled(${$scope.settings.showRouteGuide}) end`
        )
      }

      $scope.applyBestLapLineVisibility = function () {
        saveSetting('showBestLapLine', $scope.settings.showBestLapLine)
        callController(
          `if c.setBestLapLineVisible then ` +
          `c.setBestLapLineVisible(${$scope.settings.showBestLapLine}) end`
        )
      }

      $scope.applyClutchLineVisibility = function () {
        saveSetting('showClutchLine', $scope.settings.showClutchLine)
        callController(
          `if c.setClutchLineVisible then ` +
          `c.setClutchLineVisible(${$scope.settings.showClutchLine}) end`
        )
      }

      $scope.applyHandbrakeLineVisibility = function () {
        saveSetting('showHandbrakeLine', $scope.settings.showHandbrakeLine)
        callController(
          `if c.setHandbrakeLineVisible then ` +
          `c.setHandbrakeLineVisible(${$scope.settings.showHandbrakeLine}) end`
        )
      }

      $scope.applyLiveInputTrailVisibility = function () {
        saveSetting('showLiveInputTrail', $scope.settings.showLiveInputTrail)
        callController(
          `if c.setLiveInputTrailVisible then ` +
          `c.setLiveInputTrailVisible(${$scope.settings.showLiveInputTrail}) end`
        )
      }

      $scope.applyLiveInputTrailMaxSegments = function () {
        const segments = Number($scope.settings.liveInputTrailMaxSegments)
        if (!$scope.liveInputTrailMaxSegmentsOptions.includes(segments)) return
        saveSetting('liveInputTrailMaxSegments', segments)
        callController(
          `if c.setLiveInputTrailMaxSegments then ` +
          `c.setLiveInputTrailMaxSegments(${segments}) end`
        )
      }

      $scope.selectLiveInputTrailMaxSegments = function (segments, event) {
        stopMenuEvent(event)
        $scope.openOptionMenu = null
        if (!$scope.liveInputTrailMaxSegmentsOptions.includes(segments)) return
        $scope.settings.liveInputTrailMaxSegments = segments
        $scope.applyLiveInputTrailMaxSegments()
      }

      $scope.applyRoutePathVisibility = function () {
        saveSetting('showRoutePath', $scope.settings.showRoutePath)
        callController(
          `if c.setRoutePathVisible then c.setRoutePathVisible(${$scope.settings.showRoutePath}) end`
        )
      }

      $scope.applyRouteCheckpointsVisibility = function () {
        saveSetting('showRouteCheckpoints', $scope.settings.showRouteCheckpoints)
        callController(
          `if c.setRouteCheckpointsVisible then ` +
          `c.setRouteCheckpointsVisible(${$scope.settings.showRouteCheckpoints}) end`
        )
      }

      $scope.applyRouteCheckpointSpacing = function () {
        const spacing = Number($scope.settings.routeCheckpointSpacing) || 200
        if (!$scope.routeCheckpointSpacings.includes(spacing)) return
        saveSetting('routeCheckpointSpacing', spacing)
        callController(
          `if c.setRouteCheckpointSpacing then c.setRouteCheckpointSpacing(${spacing}) end`
        )
      }

      $scope.selectRouteCheckpointSpacing = function (spacing, event) {
        stopMenuEvent(event)
        spacing = Number(spacing)
        if (!$scope.routeCheckpointSpacings.includes(spacing)) return
        $scope.settings.routeCheckpointSpacing = spacing
        $scope.openOptionMenu = null
        $scope.applyRouteCheckpointSpacing()
      }

      $scope.routeCheckpointSpacingDescription = function (spacing) {
        const descriptions = {
          100: 'Dense guidance for short or technical circuits',
          150: 'More guidance through frequent corners',
          200: 'Balanced spacing for most circuits',
          300: 'Lighter markers for long fast tracks',
          500: 'Minimal markers for very long routes'
        }
        return descriptions[Number(spacing)] || 'Distance between generated checkpoints'
      }

      $scope.applyGhostTrailMode = function () {
        const mode = String($scope.settings.trailMode || 'speed')
        if (!['speed', 'acceleration', 'inputs'].includes(mode)) return
        saveSetting('trailMode', mode)
        callController(
          `if c.setGhostTrailMode then c.setGhostTrailMode(${JSON.stringify(mode)}) end`
        )
      }

      $scope.applyGhostCameraMode = function () {
        const mode = String($scope.settings.cameraMode || 'chase')
        if (!['chase', 'onboard'].includes(mode)) return
        saveSetting('cameraMode', mode)
        callController(
          `if c.setGhostCameraMode then c.setGhostCameraMode(${JSON.stringify(mode)}) end`
        )
      }

      $scope.selectGhostCameraMode = function (mode, event) {
        stopMenuEvent(event)
        if (!['chase', 'onboard'].includes(mode)) return
        $scope.settings.cameraMode = mode
        $scope.openOptionMenu = null
        $scope.applyGhostCameraMode()
      }

      $scope.selectTrailMode = function (mode, event) {
        stopMenuEvent(event)
        if (!['speed', 'acceleration', 'inputs'].includes(mode)) return
        $scope.settings.trailMode = mode
        $scope.openOptionMenu = null
        $scope.applyGhostTrailMode()
      }

      $scope.applyGhostTrailLength = function () {
        const seconds = Number($scope.settings.trailSeconds) || 3
        if (!$scope.trailDurations.includes(seconds)) return
        $scope.settings.trailSeconds = seconds
        saveSetting('trailSeconds', seconds)
        callController(
          `if c.setGhostTrailSeconds then c.setGhostTrailSeconds(${seconds}) end`
        )
      }

      $scope.selectTrailLength = function (seconds, event) {
        stopMenuEvent(event)
        seconds = Number(seconds)
        if (!$scope.trailDurations.includes(seconds)) return
        $scope.settings.trailSeconds = seconds
        $scope.openOptionMenu = null
        $scope.applyGhostTrailLength()
      }

      $scope.applyLoop = function () {
        saveSetting('loop', $scope.settings.loop)
        callController(`if c.setLoopPlayback then c.setLoopPlayback(${$scope.settings.loop}) end`)
      }

      $scope.toggleLoopPlayback = function () {
        $scope.settings.loop = !$scope.settings.loop
        $scope.applyLoop()
      }

      $scope.applySavedStartMarkersVisibility = function () {
        saveSetting('showSavedStartMarkers', $scope.settings.showSavedStartMarkers)
        callController(
          `if c.setSavedStartMarkersVisible then ` +
          `c.setSavedStartMarkersVisible(${$scope.settings.showSavedStartMarkers}) end`
        )
      }

      $scope.applyRestoreSavedStart = function () {
        saveSetting('restoreSavedStart', $scope.settings.restoreSavedStart)
      }

      function loadSavedSession(onComplete, forceRestore) {
        bngApi.engineLua(
          '(getCurrentLevelIdentifier and getCurrentLevelIdentifier() or "unknown_level")',
          function (levelName) {
            const safeLevelName = typeof levelName === 'string' ? levelName : 'unknown_level'
            const method = forceRestore === true || $scope.settings.restoreSavedStart
              ? 'restoreSavedStartLine'
              : 'loadSavedStartMarkers'
            callController(
              `if c.${method} then c.${method}(${JSON.stringify(safeLevelName)}) end`,
              onComplete,
              true
            )
          }
        )
      }

      $scope.selectColor = function (color) {
        if (!colors.includes(color)) return
        $scope.settings.color = color
        saveSetting('color', color)
        callController(`if c.setColorPreset then c.setColorPreset("${color}") end`)
      }

      $scope.applyGhostMode = function () {
        const mode = String($scope.ghostMode || 'best')
        const valid = $scope.ghostModes.some(function (item) { return item.value === mode })
        if (!valid) return
        if (mode === 'top') {
          showTopWireframeNotice(Number($scope.settings.topGhostCount) || 3)
        }
        ghostModePending = mode
        const expression = mode === 'top'
          ? `local countOk=c.setTopGhostCount and ` +
            `c.setTopGhostCount(${Number($scope.settings.topGhostCount) || 3}); ` +
            `local modeOk=c.setGhostDisplayMode and c.setGhostDisplayMode("top"); ` +
            `actionResult=(countOk and modeOk) and "applied" or "failed"`
          : `actionResult=(c.setGhostDisplayMode and ` +
            `c.setGhostDisplayMode(${JSON.stringify(mode)})) and "applied" or "failed"`
        callController(expression, function (result) {
          if (!result || result.actionResult !== 'applied') {
            ghostModePending = null
            $scope.ghostMode = $scope.state.ghostDisplayMode || 'best'
            $scope.state.message = `Could not apply Ghost mode: ${mode}`
          }
        })
      }

      $scope.selectGhostMode = function (mode, event) {
        stopMenuEvent(event)
        const valid = $scope.ghostModes.some(function (item) { return item.value === mode })
        if (!valid) return
        $scope.ghostMode = mode
        $scope.openOptionMenu = null
        $scope.applyGhostMode()
      }

      $scope.applyTopGhostCount = function () {
        const count = Number($scope.settings.topGhostCount) || 3
        if (!$scope.topGhostCounts.includes(count)) return
        $scope.settings.topGhostCount = count
        saveSetting('topGhostCount', count)
        $scope.ghostMode = 'top'
        showTopWireframeNotice(count)
        ghostModePending = 'top'
        callController(
          `local countOk=c.setTopGhostCount and c.setTopGhostCount(${count}); ` +
          `local modeOk=c.setGhostDisplayMode and c.setGhostDisplayMode("top"); ` +
          `actionResult=(countOk and modeOk) and "applied" or "failed"`,
          function (result) {
            if (!result || result.actionResult !== 'applied') {
              ghostModePending = null
              $scope.ghostMode = $scope.state.ghostDisplayMode || 'best'
              $scope.state.message = `Could not apply Top ${count} Ghosts`
            }
          }
        )
      }

      // Startup and VehicleReset only need to restore the remembered Top N
      // quantity. Choosing a quantity interactively still selects Top mode,
      // but background settings replay must not overwrite All/Best/Specified/
      // Selected with Top every time the player presses R.
      $scope.syncTopGhostCount = function () {
        const count = Number($scope.settings.topGhostCount) || 3
        if (!$scope.topGhostCounts.includes(count)) return
        $scope.settings.topGhostCount = count
        saveSetting('topGhostCount', count)
        callController(
          `if c.setTopGhostCount then c.setTopGhostCount(${count}) end`
        )
      }

      $scope.selectTopGhostCount = function (count, event) {
        stopMenuEvent(event)
        count = Number(count)
        if (!$scope.topGhostCounts.includes(count)) return
        $scope.settings.topGhostCount = count
        $scope.openOptionMenu = null
        $scope.applyTopGhostCount()
      }

      $scope.selectGhost = function (ghost) {
        if (!ghost || !ghost.id) return
        const id = JSON.stringify(String(ghost.id))
        const mode = $scope.ghostMode || 'best'
        if (mode === 'multi') {
          callController(
            `if c.setGhostSelected then c.setGhostSelected(${id}, ${ghost.selected !== true}) end`
          )
        } else {
          $scope.ghostMode = 'single'
          ghostModePending = 'single'
          callController(
            `if c.setGhostDisplayMode then c.setGhostDisplayMode("single") end; ` +
            `if c.setGhostSelected then c.setGhostSelected(${id}, true) end`
          )
        }
      }

      $scope.togglePin = function (ghost, event) {
        stopMenuEvent(event)
        if (!ghost || !ghost.id) return
        const id = String(ghost.id)
        const nextPinned = !ghost.pinned
        // Reflect immediately; the next state stream confirms it.
        ghost.pinned = nextPinned
        $scope.state.message = nextPinned
          ? `Pinned ${ghost.label || 'lap'}`
          : `Unpinned ${ghost.label || 'lap'}`
        callController(
          `actionResult=(c.setGhostPinned and c.setGhostPinned(${JSON.stringify(id)}, ${nextPinned})) ` +
          `and "applied" or "failed"`
        )
      }

      $scope.requestDeleteGhost = function (ghost, event) {
        stopMenuEvent(event)
        if (!ghost || !ghost.id) return
        const id = String(ghost.id)
        if ($scope.pendingGhostDeleteId === id) {
          ghostDeleteArmSerial += 1
          $scope.pendingGhostDeleteId = null
          $scope.state.message = `Deleting ${ghost.label || 'lap'}…`
          callController(
            `actionResult=(c.deleteGhost and c.deleteGhost(${JSON.stringify(id)})) ` +
            `and "deleted" or "failed"`,
            function (result) {
              if (result && result.ok === true && result.actionResult === 'deleted') {
                $scope.state.message = `Deleted ${ghost.label || 'lap'}`
              } else if (result && result.ok === true) {
                $scope.state.message = 'Delete failed: lap was not found or its file could not be updated'
              }
            }
          )
          return
        }

        $scope.pendingGhostDeleteId = id
        $scope.state.message = `Click CONFIRM to delete ${ghost.label || 'this lap'}`
        const armSerial = ++ghostDeleteArmSerial
        setTimeout(function () {
          if (armSerial !== ghostDeleteArmSerial || $scope.$$destroyed) return
          $scope.$evalAsync(function () {
            if (armSerial === ghostDeleteArmSerial) {
              $scope.pendingGhostDeleteId = null
              $scope.state.message = 'Lap deletion cancelled'
            }
          })
        }, 5000)
      }

      function applyAllSettings() {
        $scope.applyQuality()
        $scope.applySampleRate()
        $scope.applyVisibility()
        $scope.applyGhostCategory()
        $scope.applyManualVisibility()
        $scope.applyGhostShell()
        $scope.applyStartGateVisibility()
        $scope.applySavedStartMarkersVisibility()
        $scope.applyRouteGuideVisibility()
        $scope.applyRoutePathVisibility()
        $scope.applyRouteCheckpointsVisibility()
        $scope.applyRouteCheckpointSpacing()
        $scope.applyBestLapLineVisibility()
        $scope.applyClutchLineVisibility()
        $scope.applyHandbrakeLineVisibility()
        $scope.applyLiveInputTrailVisibility()
        $scope.applyLiveInputTrailMaxSegments()
        $scope.applyGhostTrailVisibility()
        $scope.applyGhostTrailLength()
        $scope.applyGhostTrailMode()
        $scope.applyGhostCameraMode()
        $scope.syncTopGhostCount()
        $scope.applyLoop()
        $scope.selectColor($scope.settings.color)
        loadSavedSession()
      }

      $scope.formatTime = function (seconds, showSign) {
        if (seconds === null || seconds === undefined || !Number.isFinite(Number(seconds))) return '—'
        const value = Number(seconds)
        const absolute = Math.abs(value)
        const minutes = Math.floor(absolute / 60)
        const remainder = absolute - minutes * 60
        const sign = showSign ? (value > 0 ? '+' : value < 0 ? '−' : '±') : ''
        return minutes > 0
          ? `${sign}${minutes}:${remainder.toFixed(3).padStart(6, '0')}`
          : `${sign}${remainder.toFixed(3)}`
      }

      $scope.formatSpeedDelta = function (value) {
        if (value === null || value === undefined || !Number.isFinite(Number(value))) return '—'
        const number = Number(value)
        const sign = number > 0 ? '+' : number < 0 ? '−' : '±'
        return `${sign}${Math.abs(number).toFixed(1)}`
      }

      $scope.autoLapStatusLabel = function () {
        if ($scope.state.raceMode) return 'RACE CONTROLLED'
        if ($scope.state.autoLapDeltaSuppressed) {
          return `LAP ${$scope.state.autoLapNumber || 1} · MISSED`
        }
        if ($scope.state.autoLapActive) return `LAP ${$scope.state.autoLapNumber || 1}`
        if ($scope.state.autoLapEnabled) return 'ARMED'
        if ($scope.state.startLineSet) return 'LINE READY'
        return 'NO START LINE'
      }

      $scope.autoLapDistanceLabel = function () {
        const signed = Number($scope.state.autoLapLineDistance)
        const lateral = Number($scope.state.autoLapLateralDistance)
        if (!Number.isFinite(signed) || !Number.isFinite(lateral)) return 'LINE —'
        const side = signed >= 0 ? 'AFTER LINE' : 'APPROACH SIDE'
        return `${side} ${Math.abs(signed).toFixed(1)} m · ${lateral.toFixed(1)} m FROM CENTER`
      }

      $scope.autoLapGateLabel = function () {
        const labels = {
          lineReady: 'LINE SET · ARM AUTO LAP',
          waitingForStart: 'RETURN TO THE − SIDE, THEN CROSS FORWARD',
          startReady: 'START GATE READY',
          finishReady: 'FINISH GATE READY',
          nearLine: 'NEAR START LINE',
          cooldown: 'GATE COOLDOWN',
          lapStarted: 'LAP STARTED',
          onLap: 'ON LAP',
          missed: 'FINISH MISSED · NEXT VALID CROSSING STARTS A NEW LAP',
          raceControlled: 'RACE CONTROLLED',
          off: 'START GATE SET · CLICK ARM AUTO LAP'
        }
        return labels[$scope.state.autoLapGateState] || 'AUTO LAP'
      }

      $scope.autoLapRejectLabel = function () {
        const labels = {
          outsideWidth: 'Crossing missed: more than 15 m from line center',
          verticalOffset: 'Crossing missed: more than 4 m above/below the line',
          tooSlow: 'Crossing missed: forward speed was too low',
          wrongDirection: 'Crossing missed: wrong direction (cross from − to +)',
          segmentTooLong: 'Crossing missed: teleport or severe frame-position jump',
          cooldown: 'Crossing missed: the start gate was still in cooldown',
          minimumLapTime: 'Crossing missed: lap was shorter than 5 seconds'
        }
        return labels[$scope.state.autoLapLastReject] || ''
      }

      $scope.routeGuideStatusLabel = function () {
        if (!$scope.state.routeGuideReady) return 'NO REFERENCE LAP'
        if (!$scope.settings.showRouteGuide) return 'HIDDEN'
        if (!$scope.state.routeGuideActive) return 'READY'
        return 'ACTIVE'
      }

      $scope.routeMatchLabel = function () {
        const status = $scope.routeMatch.status
        const percentage = Math.round(Math.max(0, Math.min(1,
          Number($scope.routeMatch.coverage) || 0
        )) * 100)
        if (status === 'matched') return 'ROAD MATCH 100%'
        if (status === 'partial') return `ROAD MATCH ${percentage}%`
        if (status === 'fallback') return 'GHOST FALLBACK'
        if (status === 'noNavgraph') return 'NO ROAD NAVGRAPH'
        return ''
      }

      $scope.routeMatchMessage = function () {
        const status = $scope.routeMatch.status
        if (status === 'matched') {
          return 'Cyan path: all reference samples matched nearby navigable road edges.'
        }
        if (status === 'partial') {
          return 'Cyan sections matched roads; amber sections use the recorded Ghost path.'
        }
        if (status === 'noNavgraph') {
          return 'This map exposes no usable road navgraph. The amber Ghost path is shown instead.'
        }
        if (status === 'fallback') {
          return 'No nearby compatible road edges were found. Drive on mapped roads with matching direction and elevation, then record another valid lap.'
        }
        return ''
      }

      $scope.formatRouteDistance = function (distance) {
        const meters = Number(distance) || 0
        return meters >= 1000 ? `${(meters / 1000).toFixed(2)} km` : `${Math.round(meters)} m`
      }

      // Live standings vs every stored Ghost (complete + incomplete). Present
      // only while a lap is being recorded, so it reads null otherwise.
      $scope.hasLiveRank = function () {
        return Number($scope.state.liveRank) > 0 && Number($scope.state.liveRankTotal) > 0
      }

      $scope.rankText = function () {
        if (!$scope.hasLiveRank()) return '—'
        return 'P' + Number($scope.state.liveRank)
      }

      $scope.rankTotalText = function () {
        return $scope.hasLiveRank() ? '/ ' + Number($scope.state.liveRankTotal) : ''
      }

      // Compact form for the minimized badge, where rank and field size share one
      // small chip: "P3/12".
      $scope.miniRankText = function () {
        if (!$scope.hasLiveRank()) return ''
        return 'P' + Number($scope.state.liveRank) + '/' + Number($scope.state.liveRankTotal)
      }

      $scope.miniPrimary = function () {
        if ($scope.state.timeDelta !== null && $scope.state.timeDelta !== undefined &&
            Number.isFinite(Number($scope.state.timeDelta))) {
          return $scope.formatTime($scope.state.timeDelta, true)
        }
        return String(Math.round(Number($scope.state.currentSpeed) || 0))
      }

      $scope.miniUnit = function () {
        return $scope.state.timeDelta !== null && $scope.state.timeDelta !== undefined &&
          Number.isFinite(Number($scope.state.timeDelta)) ? 'Δ SEC' : 'KM/H'
      }

      $scope.miniLabel = function () {
        if ($scope.state.autoLapDeltaSuppressed) return 'MISS'
        if ($scope.state.autoLapActive) return `LAP ${$scope.state.autoLapNumber || 1}`
        if ($scope.state.autoLapEnabled) return 'ARMED'
        return $scope.statusLabel()
      }

      $scope.miniStatusDescription = function () {
        const descriptions = {
          connecting: 'Gray dot: connecting to the vehicle controller',
          idle: 'Gray dot: idle',
          armed: 'Green dot: auto lap armed',
          ready: 'Green dot: Ghost ready',
          playing: 'Blue dot: Ghost playing',
          recording: 'Red dot: recording',
          racing: 'Red dot: recording and playing',
          missed: 'Amber dot: finish crossing was rejected; next valid crossing starts a new lap',
          error: 'Red dot: controller error'
        }
        return descriptions[$scope.state.status] || 'Ghost Racer status indicator'
      }

      $scope.miniRingStyle = function () {
        let progress = Number($scope.state.progress) || 0
        if ($scope.state.recording && Number($scope.state.pbTime) > 0) {
          progress = (Number($scope.state.elapsed) || 0) / Number($scope.state.pbTime)
        }
        progress = Math.max(0, Math.min(1, progress))

        let color = '#ff7018'
        if ($scope.state.status === 'error') color = '#ff6574'
        else if ($scope.state.status === 'missed') color = '#ffb347'
        else if ($scope.state.timeDelta !== null && Number($scope.state.timeDelta) <= 0) {
          color = '#4ee08a'
        } else if ($scope.state.timeDelta !== null) {
          color = '#ff6574'
        } else if ($scope.state.playing) {
          color = '#64c7ff'
        }

        const degrees = Math.max($scope.state.autoLapEnabled ? 18 : 6, progress * 360)
        return {
          background: `conic-gradient(${color} 0deg, ${color} ${degrees}deg, ` +
            `rgba(255,255,255,0.09) ${degrees}deg, rgba(255,255,255,0.09) 360deg)`
        }
      }

      $scope.timeDeltaClass = function () {
        if ($scope.state.timeDelta === null || $scope.state.timeDelta === undefined ||
            !Number.isFinite(Number($scope.state.timeDelta))) return ''
        return Number($scope.state.timeDelta) <= 0 ? 'is-faster' : 'is-slower'
      }

      $scope.speedDeltaClass = function () {
        if ($scope.state.speedDelta === null || $scope.state.speedDelta === undefined ||
            !Number.isFinite(Number($scope.state.speedDelta))) return ''
        return Number($scope.state.speedDelta) >= 0 ? 'is-faster' : 'is-slower'
      }

      $scope.statusLabel = function () {
        const labels = {
          connecting: 'LINK',
          error: 'ERROR',
          armed: 'ARMED',
          idle: 'IDLE',
          ready: 'READY',
          recording: 'REC',
          playing: 'PLAY',
          racing: 'RACING',
          missed: 'MISS'
        }
        return labels[$scope.state.status] || 'IDLE'
      }

      $scope.$on('GhostRacerState', function (_event, state) {
        $scope.$evalAsync(function () {
          state = state || {}
          // Every vehicle can retain its own external controller after a
          // vehicle switch. Only the controller most recently claimed through
          // activeObjectLua may drive this HUD instance.
          if (state.uiOwnerToken !== uiOwnerToken) {
            const ignoredOwner = String(state.uiOwnerToken || 'unclaimed')
            if (ignoredOwner !== lastIgnoredOwner) {
              lastIgnoredOwner = ignoredOwner
              diagnosticLog(
                'state.ignored',
                `owner=${ignoredOwner} vehicle=${state.vehicle || 'unknown'} ` +
                `active=${state.activeStartLineId || 'none'} name=${JSON.stringify(state.startLineName)}`
              )
            }
            return
          }
          if (state.diagnosticTraceId && state.diagnosticTraceId !== lastStateTraceId) {
            lastStateTraceId = state.diagnosticTraceId
            diagnosticLog(
              'state.accepted',
              `trace=${state.diagnosticTraceId} vehicle=${state.vehicle || 'unknown'} ` +
              `active=${state.activeStartLineId || 'none'} name=${JSON.stringify(state.startLineName)} ` +
              `revision=${state.registryRevision}`
            )
          }
          if (connectionTimer !== null) {
            clearTimeout(connectionTimer)
            connectionTimer = null
          }
          if (!Object.prototype.hasOwnProperty.call(state, 'pbTime')) state.pbTime = null
          if (!Object.prototype.hasOwnProperty.call(state, 'timeDelta')) state.timeDelta = null
          if (!Object.prototype.hasOwnProperty.call(state, 'speedDelta')) state.speedDelta = null
          if (!Object.prototype.hasOwnProperty.call(state, 'liveRank')) state.liveRank = null
          if (!Object.prototype.hasOwnProperty.call(state, 'liveRankTotal')) state.liveRankTotal = null
          if (!Array.isArray(state.ghosts)) state.ghosts = []
          if (!Array.isArray(state.savedStartLines)) state.savedStartLines = []
          const partialFilterSignature = [
            incompleteFilterEnabled(),
            state.showIncomplete === true,
            Number(state.incompleteGhostCount) || 0,
            state.ghosts.length
          ].join('|')
          if (partialFilterSignature !== lastPartialFilterStateSignature) {
            lastPartialFilterStateSignature = partialFilterSignature
            diagnosticLog(
              'partial.filter.state',
              `ui=${incompleteFilterEnabled()} controller=${state.showIncomplete === true} ` +
              `partialCount=${Number(state.incompleteGhostCount) || 0} ` +
              `metadataRows=${state.ghosts.length}`
            )
          }
          if ($scope.pendingGhostDeleteId && !state.ghosts.some(function (ghost) {
            return String(ghost.id) === $scope.pendingGhostDeleteId
          })) {
            ghostDeleteArmSerial += 1
            $scope.pendingGhostDeleteId = null
          }
          Object.keys($scope.shareSelection).forEach(function (id) {
            if (!state.ghosts.some(function (ghost) { return String(ghost.id) === id })) {
              delete $scope.shareSelection[id]
            }
          })
          if ($scope.pendingStartDeleteId && !state.savedStartLines.some(function (line) {
            return String(line.id) === $scope.pendingStartDeleteId
          })) {
            startDeleteArmSerial += 1
            $scope.pendingStartDeleteId = null
          }
          if (state.ghostDisplayMode) {
            if (ghostModePending === state.ghostDisplayMode) ghostModePending = null
            if (!ghostModePending) $scope.ghostMode = state.ghostDisplayMode
          }
          if ($scope.topGhostCounts.includes(Number(state.topGhostCount))) {
            $scope.settings.topGhostCount = Number(state.topGhostCount)
            saveSetting('topGhostCount', $scope.settings.topGhostCount)
          }
          if (['complete', 'incomplete', 'both'].includes(state.ghostCategoryFilter)) {
            $scope.settings.ghostCategory = state.ghostCategoryFilter
            $scope.settings.showIncomplete = state.ghostCategoryFilter !== 'complete'
          }
          if (['chase', 'onboard'].includes(state.ghostCameraMode)) {
            $scope.settings.cameraMode = state.ghostCameraMode
          }
          if (!startLineNameEditing && !startLineNameInputFocused() &&
              Object.prototype.hasOwnProperty.call(state, 'startLineName')) {
            $scope.startLineNameDraft = state.startLineName || ''
          }
          angular.extend($scope.state, state)
        })
      })

      $scope.$on('GhostRacerRouteMatchState', function (_event, state) {
        $scope.$evalAsync(function () {
          angular.extend($scope.routeMatch, state || {})
        })
      })

      $scope.$on('GhostRacerCameraState', function (_event, cameraState) {
        $scope.$evalAsync(function () {
          cameraState = cameraState || {}
          if (typeof cameraState.enabled === 'boolean') {
            $scope.state.ghostCameraEnabled = cameraState.enabled
          }
          $scope.state.ghostCameraBackend = cameraState.backend || null
          if (cameraState.error) {
            const rawError = String(cameraState.error)
            $scope.state.message = `Ghost camera: ${rawError}`
            callController(
              `if c.handleGhostCameraError then ` +
              `c.handleGhostCameraError(${JSON.stringify(rawError)}) ` +
              `elseif c.setGhostCameraEnabled then c.setGhostCameraEnabled(false) end`
            )
          } else if (cameraState.enabled === true) {
            $scope.state.message = `Ghost camera active · ${cameraState.targetLabel || 'Ghost'}`
          }
        })
      })

      $scope.$on('VehicleReset', function () {
        $scope.state.status = 'connecting'
        $scope.state.message = 'Connecting…'
        armConnectionTimer()
        scheduleSettingsApply(150)
      })

      $scope.$on('GhostRacerModUnloaded', function () {
        removeMountedApp()
      })

      // Keybind bridge: the GE hotkey broadcasts this to flip between the full
      // panel and the compact mini badge, the same as the header button.
      $scope.$on('GhostRacerToggleMinimize', function () {
        $scope.toggleMinimize()
      })

      $scope.$on('$destroy', function () {
        ghostDeleteArmSerial += 1
        startDeleteArmSerial += 1
        if (runtimeActive) {
          bngApi.engineLua(
            'if extensions and extensions.ghostlapping and ' +
            'extensions.ghostlapping.onUiClosed then ' +
            'extensions.ghostlapping.onUiClosed() end'
          )
          runtimeActive = false
        }
        if (initialApplyTimer !== null) {
          clearTimeout(initialApplyTimer)
          initialApplyTimer = null
        }
        if (connectionTimer !== null) clearTimeout(connectionTimer)
        if ($document && typeof $document.off === 'function') {
          $document.off('click', closeOptionMenu)
        }
        if (hostElement && expandedHostStyle) {
          Object.keys(expandedHostStyle).forEach(function (property) {
            hostElement.style[property] = expandedHostStyle[property]
          })
        }
      })

      if ($document && typeof $document.on === 'function') {
        $document.on('click', closeOptionMenu)
      }
      probeRuntime(1)
    }]
  }
}])
