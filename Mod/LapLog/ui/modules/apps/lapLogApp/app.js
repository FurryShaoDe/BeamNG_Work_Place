// LapLog UI controller.
//
// Talks to the vehicle-side lapLog controller over two channels:
//   bngApi.activeObjectLua(...)  -- imperative calls (button presses)
//   scope.$on('LapLogState')     -- the 10 Hz state broadcast from the recorder
//
// Rules that keep the panel responsive. Each one is a bug that was lived
// through, so please do not "simplify" them away.
//
// 1. No cross-VM call happens while Angular is digesting. activeObjectLua is a
//    blocking round trip into the vehicle VM, and each one comes back through
//    requestState, which re-enters this panel with a fresh state object. Doing
//    several of those inside the controller constructor makes the digest loop
//    churn, so the whole startup sequence is batched into a single call and
//    pushed outside the current digest.
//
// 2. No template expression may call a function that builds a new value.
//    ng-repeat and ng-class both watch their expression; if it returns a fresh
//    array or object on every digest the watcher can never settle. The lap list,
//    its CSS classes and the visible-lap count are therefore computed once when
//    a state packet arrives, and the template reads plain properties.
//    formatTime is the one permitted exception: it is pure, and returns the same
//    string for the same input.
//
// 3. The directive registers on the shared `beamng.apps` module, the same way
//    Ghost Racer and every built-in app do. BeamNG's loader (ocLazyLoad plus
//    the directive cache refresh in app-service.js) is built around that
//    module; a private module with its own dependencies misses that path.
//
// 4. State packets arrive through the bridge's hook pipeline, which ends in a
//    plain `rootScope.$broadcast` - outside any digest. Mutating the scope from
//    that callback does not repaint the panel on its own, so every packet is
//    wrapped in $evalAsync. Ghost Racer does the same. Without this the panel
//    sits on "正在连接…" forever even while the recorder broadcasts fine.
//
// 5. Dropdowns are custom button + menu widgets, never a native <select>. Under
//    CEF off-screen rendering the native select popup cannot open, so a
//    <select> looks clickable and does nothing at all. Ghost Racer ships the
//    same widget for the same reason.

angular.module('beamng.apps').directive('lapLogApp', [function () {
  var APP_VERSION = '1.0.0';
  var STORAGE_PREFIX = 'lapLog_';
  var CONTROLLER = 'lapLog';

  // Vehicle-side status values -> panel labels.
  var STATUS_LABELS = {
    connecting: '连接中',
    idle: '待机',
    ready: '就绪',
    recording: '录制中',
    armed: '自动计圈已启用',
    missed: '过门无效'
  };

  // Vehicle-side incomplete reasons -> panel labels.
  var REASON_LABELS = {
    outsideWidth: '偏离门宽',
    verticalOffset: '垂直门偏移',
    tooSlow: '过门速度过低',
    segmentTooLong: '瞬移或位置跳变',
    cooldown: '起点门冷却中',
    minimumLapTime: '低于最短圈速',
    invalidGate: '无效的过门',
    invalidLap: '圈速被判定无效',
    startChanged: '已存起点变更',
    autoLapDisabled: '自动计圈未启用',
    autoLapRestarted: '自动计圈重新开始',
    startDeactivated: '已存起点已停用',
    safetyLimit: '30 分钟安全上限'
  };

  // Vehicle-side gate-state enum -> panel labels. The enum itself must stay as
  // it is: Lua uses the same values for its own comparisons.
  var GATE_STATE_LABELS = {
    off: '自动计圈已关闭',
    lineReady: '起点就绪',
    startReady: '起点就绪',
    finishReady: '终点就绪',
    nearLine: '接近起点门',
    onLap: '计时中',
    lapStarted: '计时中',
    waitingForStart: '等待过起点门',
    cooldown: '冷却中',
    missed: '过门无效',
    finished: '已完成'
  };

  // Resolves the vehicle-side recorder instance. controller.getController is the
  // documented path, but on 0.39 it returns nil for an externally loaded
  // controller even though init()/reset() run - the 2026-10-04 game log shows
  // "controller.init ... ready" immediately followed by a failed lookup. That
  // left the panel stuck on "connecting" and turned every button into a no-op.
  // The controller therefore publishes its instance to package.loaded /
  // controller / _G, and every bridge call below resolves through all of those
  // slots. Keep the names in sync with the publish block at the end of
  // lua/vehicle/controller/lapLog.lua.
  var LUA_FIND_CONTROLLER =
    'local c = nil;' +
    'if controller and type(controller.getController) == "function" then' +
    '  local names = {"' + CONTROLLER + '", "' + CONTROLLER.toLowerCase() + '"};' +
    '  for i = 1, #names do' +
    '    local hit = controller.getController(names[i]);' +
    '    if hit then c = hit break end;' +
    '  end;' +
    'end;' +
    'if not c and controller then c = controller.lapLogInstance end;' +
    'if not c and package and package.loaded then' +
    '  c = package.loaded["vehicle/controller/lapLog"] end;' +
    'if not c then c = rawget(_G, "lapLogController") end;';

  function readSetting(key, fallback) {
    try {
      var raw = localStorage.getItem(STORAGE_PREFIX + key);
      return raw === null ? fallback : JSON.parse(raw);
    } catch (error) {
      return fallback;
    }
  }

  function writeSetting(key, value) {
    try {
      localStorage.setItem(STORAGE_PREFIX + key, JSON.stringify(value));
    } catch (error) {
      // Private-mode storage failures must not break the panel.
    }
  }

  return {
    restrict: 'E',
    templateUrl: '/ui/modules/apps/lapLogApp/app.html?v=' + APP_VERSION,
    link: function (scope) {
      // The state broadcast arrives ten times a second. Mutate the existing
      // object instead of replacing it, otherwise every binding in the panel is
      // invalidated on every packet. $evalAsync schedules the digest that the
      // bridge broadcast does not provide (rule 4).
      scope.$on('LapLogState', function (event, payload) {
        scope.$evalAsync(function () {
          try {
            scope.applyState(payload || {});
          } catch (error) {
            scope.state.message = '状态更新失败：' + (error && error.message);
          }
        });
      });
    },
    controller: ['$scope', '$timeout', '$document', function ($scope, $timeout, $document) {
      var connectionTimer = null;
      var connectionAttempts = 0;

      $scope.sampleRates = [20, 30, 50, 100];
      $scope.categories = [
        { id: 'complete', label: '完整圈' },
        { id: 'incomplete', label: '未完成' },
        { id: 'both', label: '全部' }
      ];
      $scope.renameDraft = '';
      $scope.deleteArmed = false;
      $scope.deleteArmedUntil = 0;
      $scope.visibleLaps = [];
      $scope.visibleLapCount = 0;
      $scope.dotClass = '';
      $scope.openOptionMenu = null;
      $scope.statusText = STATUS_LABELS.connecting;
      $scope.selectedStartLabel = '未选择';
      $scope.categoryLabel = '完整圈';
      $scope.gateStateText = '';

      $scope.state = {
        status: 'connecting', message: '正在连接…', ghosts: [], savedStartLines: []
      };
      $scope.settings = {
        sampleRate: readSetting('sampleRate', 50),
        categoryFilter: readSetting('categoryFilter', 'complete'),
        showManual: readSetting('showManual', true),
        showStartGate: readSetting('showStartGate', true),
        showSavedStartMarkers: readSetting('showSavedStartMarkers', true),
        restoreSavedStart: readSetting('restoreSavedStart', true),
        selectedStartId: null
      };
      if (!$scope.categories.some(function (c) {
        return c.id === $scope.settings.categoryFilter;
      })) {
        $scope.settings.categoryFilter = 'complete';
      }

      // ---- dropdown widgets (rule 5) ---------------------------------------

      function closeOptionMenu() {
        $scope.openOptionMenu = null;
      }

      function stopMenuEvent($event) {
        if ($event && typeof $event.stopPropagation === 'function') {
          $event.stopPropagation();
        }
      }

      $scope.toggleOptionMenu = function (name, $event) {
        // Without this the document-level close handler fires for the same
        // click and the menu never opens.
        stopMenuEvent($event);
        $scope.openOptionMenu = $scope.openOptionMenu === name ? null : name;
      };

      $scope.selectSampleRate = function (rate, $event) {
        stopMenuEvent($event);
        $scope.openOptionMenu = null;
        if ($scope.settings.sampleRate === rate) return;
        $scope.settings.sampleRate = rate;
        $scope.applySampleRate();
      };

      $scope.selectSavedStart = function (line, $event) {
        stopMenuEvent($event);
        $scope.openOptionMenu = null;
        if (!line || !line.id) return;
        $scope.settings.selectedStartId = line.id;
        callMethod('selectSavedStartLine', [JSON.stringify(String(line.id))]);
      };

      $scope.selectCategory = function (category, $event) {
        stopMenuEvent($event);
        $scope.openOptionMenu = null;
        if (!category || $scope.settings.categoryFilter === category.id) return;
        $scope.settings.categoryFilter = category.id;
        $scope.applyCategoryFilter();
      };
      // ---- derived values, computed once per state packet ----------------

      function formatTime(seconds) {
        var value = Number(seconds);
        if (!isFinite(value) || value <= 0) return '--.---';
        var minutes = Math.floor(value / 60);
        var rest = value - minutes * 60;
        // 7 characters covers "30.200"; pad so 1:05.400 does not read 1:5.400.
        var frac = ('000' + rest.toFixed(3)).slice(-7);
        return minutes > 0 ? minutes + ':' + frac.slice(1) : rest.toFixed(3);
      }

      function startLabelFor(lines, id) {
        if (!id) return '未选择';
        if (lines) {
          for (var i = 0; i < lines.length; i += 1) {
            if (lines[i] && lines[i].id === id) return lines[i].name || String(id);
          }
        }
        return String(id);
      }

      function categoryLabelFor(id) {
        for (var i = 0; i < $scope.categories.length; i += 1) {
          if ($scope.categories[i].id === id) return $scope.categories[i].label;
        }
        return '完整圈';
      }

      function subtitleFor(lap) {
        var parts = [lap.vehicle];
        if (lap.incomplete === true) {
          parts.push('未完成' + (lap.incompleteReason
            ? ' · ' + (REASON_LABELS[lap.incompleteReason] || lap.incompleteReason)
            : ''));
        } else if (lap.manual === true) {
          parts.push('手动录制');
        } else {
          parts.push(lap.isBest === true ? '个人最佳' : '圈速');
        }
        if (lap.hasInputs === true) parts.push('含输入');
        if (lap.pinned === true) parts.push('已置顶');
        return parts.filter(Boolean).join(' · ');
      }

      function decorateLap(lap) {
        var classes = [];
        if (lap.displayed === true) classes.push('is-reference');
        if (lap.incomplete === true) classes.push('is-partial');
        if (lap.manual === true) classes.push('is-manual');
        if (lap.pinned === true) classes.push('is-pinned');
        lap.cssClass = classes.join(' ');
        lap.timeText = formatTime(lap.lapTime || lap.duration);
        lap.subtitle = subtitleFor(lap);
        return lap;
      }
      // ---- controller bridge ----------------------------------------------

      function activeObjectLua(code) {
        try {
          if (!bngApi || !bngApi.activeObjectLua) return;
          bngApi.activeObjectLua(code);
        } catch (error) {
          $scope.state.message = '通信错误：' + (error && error.message);
        }
      }

      // Runs `body` with the lapLog controller as `c`, inside a pcall. State is
      // re-requested afterwards so the panel cannot drift from the recorder.
      function withController(body) {
        activeObjectLua(
          LUA_FIND_CONTROLLER +
          'if not c then' +
          '  if type(log) == "function" then' +
          '    log("W", "LapLogDiag.UI", "[bridge] recorder instance not found") end;' +
          '  return end;' +
          body +
          'if c.requestState then pcall(c.requestState) end'
        );
      }

      function callMethod(name, args) {
        withController('if c.' + name + ' then c.' + name + '(' + (args || '') + ') end;');
      }

      // Makes sure the vehicle VM has a controller matching this panel. The
      // vehicle-side auto-extension loader is not guaranteed to have fired
      // (panel added before the vehicle, a Lua reload, an AI-proxy vehicle), and
      // without a controller every later requestState() silently hits nothing -
      // the panel then sits on "正在连接…" forever. Ghost Racer performs the same
      // load inside every call; LapLog does it on connect.
      //
      // The outcome is logged through LapLogDiag.UI so a failed load is visible
      // in the game log instead of being swallowed.
      function ensureController() {
        activeObjectLua(
          LUA_FIND_CONTROLLER +
          'if not controller or type(controller.loadControllerExternal) ~= "function" then' +
          '  if type(log) == "function" then' +
          '    log("W", "LapLogDiag.UI", "[ensureController] no loader, existing=" .. tostring(c ~= nil)) end;' +
          '  return end;' +
          'local expected = "' + APP_VERSION + '";' +
          'if c and c.getCodeVersion and c.getCodeVersion() == expected then return end;' +
          'if c and controller.unloadControllerExternal then' +
          '  pcall(controller.unloadControllerExternal, "' + CONTROLLER + '") end;' +
          'local ok, err = pcall(controller.loadControllerExternal, "' + CONTROLLER + '", "' + CONTROLLER + '", {});' +
          'if type(log) == "function" then' +
          '  log("I", "LapLogDiag.UI", "[ensureController] ok=" .. tostring(ok) ..' +
          '    " existing=" .. tostring(c ~= nil) .. " err=" .. tostring(err)) end'
        );
      }

      // One batched settings push plus a state request. Kept as a single string
      // so the whole thing is one cross-VM round trip (rule 1).
      function applySettingsToController() {
        var s = $scope.settings;
        activeObjectLua(
          LUA_FIND_CONTROLLER +
          'if not c then' +
          '  if type(log) == "function" then' +
          '    log("W", "LapLogDiag.UI", "[settings] recorder instance not found") end;' +
          '  return end;' +
          'if c.setUiOwnerToken then c.setUiOwnerToken("lapLogApp") end;' +
          'if c.setStartGateVisible then c.setStartGateVisible(' +
            (s.showStartGate ? 'true' : 'false') + ') end;' +
          'if c.setSavedStartMarkersVisible then c.setSavedStartMarkersVisible(' +
            (s.showSavedStartMarkers ? 'true' : 'false') + ') end;' +
          'if c.setSampleRate then c.setSampleRate(' +
            (Number(s.sampleRate) || 50) + ') end;' +
          'if c.setShowManual then c.setShowManual(' +
            (s.showManual ? 'true' : 'false') + ') end;' +
          'if c.setGhostCategoryFilter then c.setGhostCategoryFilter("' +
            s.categoryFilter + '") end;' +
          'if c.requestState then pcall(c.requestState) end'
        );
      }

      // Asks the game engine for the current level identifier, then calls into the
      // vehicle controller with it. Restoring a Saved Start is keyed by level, so
      // the panel cannot pick one without this round trip. bngApi.engineLua takes
      // a callback and hands it the chunk's return value.
      function currentLevel(callback) {
        if (!bngApi || !bngApi.engineLua) {
          callback('unknown_level');
          return;
        }
        try {
          bngApi.engineLua(
            '(function() return (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) ' +
            'or "unknown_level" end)()',
            function (level) {
              callback(typeof level === 'string' && level ? level : 'unknown_level');
            }
          );
        } catch (error) {
          callback('unknown_level');
        }
      }

      function loadSavedSession() {
        // restoreSavedStartLine activates and arms the previous start;
        // loadSavedStartMarkers only lists what is on the map.
        var method = $scope.settings.restoreSavedStart
          ? 'restoreSavedStartLine'
          : 'loadSavedStartMarkers';
        currentLevel(function (level) {
          callMethod(method, [JSON.stringify(level)]);
        });
      }

      // ---- connection watchdog --------------------------------------------
      //
      // The panel is usually added before (or without) a vehicle. The startup
      // push then lands nowhere and nothing would ever retry, so the panel must
      // (a) retry when a vehicle appears and (b) be honest about it instead of
      // sitting on "connecting" forever.

      // A panel is often added before the vehicle exists, and the controller can
      // take a moment to appear after a spawn, so the whole handshake is retried
      // a few times before the player is told it failed - and told what to do.
      function armConnectionTimer() {
        if (connectionTimer !== null) {
          $timeout.cancel(connectionTimer);
        }
        connectionTimer = $timeout(function () {
          connectionTimer = null;
          if ($scope.state.status !== 'connecting') return;
          if (connectionAttempts < 3) {
            connectionAttempts += 1;
            connect(0);
            return;
          }
          $scope.state.message = '尚未检测到车辆：请先生成车辆，再点右上角 ↻ 重试';
        }, 4000);
      }

      function connect(delay) {
        $scope.state.status = 'connecting';
        $scope.state.message = '正在连接…';
        armConnectionTimer();
        $timeout(function () {
          ensureController();
          applySettingsToController();
          // Controller reloads are asynchronous; give the vehicle VM a moment
          // before the settings snapshot is pushed at the fresh instance.
          $timeout(function () {
            applySettingsToController();
          }, 400);
        }, delay || 0);
      }

      // ---- scope surface --------------------------------------------------

      $scope.applyState = function (payload) {
        connectionAttempts = 0;
        if (connectionTimer !== null) {
          $timeout.cancel(connectionTimer);
          connectionTimer = null;
        }
        var keys = Object.keys(payload);
        for (var i = 0; i < keys.length; i += 1) {
          $scope.state[keys[i]] = payload[keys[i]];
        }
        if (!$scope.settings.selectedStartId && $scope.state.activeStartLineId) {
          $scope.settings.selectedStartId = $scope.state.activeStartLineId;
        }
        $scope.statusText = STATUS_LABELS[$scope.state.status]
          || $scope.state.status || '待机';
        $scope.selectedStartLabel = startLabelFor(
          $scope.state.savedStartLines, $scope.settings.selectedStartId);
        $scope.categoryLabel = categoryLabelFor($scope.settings.categoryFilter);
        $scope.gateStateText = GATE_STATE_LABELS[$scope.state.autoLapGateState] || '';

        var filter = $scope.settings.categoryFilter;
        var showManual = $scope.settings.showManual !== false;
        var source = $scope.state.ghosts; [];
        var rows = [];
        for (var j = 0; j < source.length; j += 1) {
          var lap = source[j];
          if (filter === 'incomplete' && lap.incomplete !== true) continue;
          if (filter === 'complete' && lap.incomplete === true) continue;
          if (lap.manual === true && !showManual) continue;
          rows.push(decorateLap(lap));
        }
        $scope.visibleLaps = rows;
        // The template reads this plain property. It must never call a function
        // from an expression: `visibleLaps()` is not callable, and the thrown
        // TypeError interrupts every digest that evaluates it.
        $scope.visibleLapCount = rows.length;

        $scope.dotClass = $scope.state.recording ? 'is-recording'
          : ($scope.state.autoLapEnabled ? 'is-armed'
            : ($scope.state.totalGhostCount ? 'is-ready' : ''));
      };

      $scope.formatTime = formatTime;
      // ---- actions -------------------------------------------------------

      $scope.reload = function () {
        connectionAttempts = 0;
        connect(0);
      };

      $scope.toggleRecording = function () {
        if ($scope.state.recording) callMethod('stopRecording', '');
        else callMethod('startRecording', '');
      };

      $scope.applySampleRate = function () {
        writeSetting('sampleRate', $scope.settings.sampleRate);
        callMethod('setSampleRate', [String(Number($scope.settings.sampleRate) || 50)]);
      };

      $scope.setStartLine = function () {
        currentLevel(function (level) {
          callMethod('setStartLine', [JSON.stringify(level)]);
        });
      };

      $scope.toggleAutoLap = function () { callMethod('toggleAutoLap', ''); };

      $scope.toggleFinishGate = function () {
        callMethod($scope.state.finishLineSet ? 'clearFinishLine' : 'setFinishLine', '');
      };

      $scope.newStartVariant = function () { callMethod('createStartVariant', ''); };

      $scope.clearStartLine = function () {
        callMethod('clearStartLine', '');
        $scope.settings.selectedStartId = null;
      };

      $scope.renameStart = function () {
        var name = String($scope.renameDraft || '').trim();
        if (!name || !$scope.settings.selectedStartId) return;
        callMethod('renameStartLine',
          [JSON.stringify(name), JSON.stringify(String($scope.settings.selectedStartId))]);
        $scope.renameDraft = '';
      };

      // Two-step delete, with the confirmation window measured against the clock
      // rather than a $timeout: scheduling a timer from inside the panel is one
      // more thing that can keep a digest busy.
      $scope.requestDeleteStart = function () {
        if (!$scope.settings.selectedStartId) return;
        if (!$scope.deleteArmed) {
          $scope.deleteArmed = true;
          $scope.deleteArmedUntil = Date.now() + 4000;
          return;
        }
        if (Date.now() > $scope.deleteArmedUntil) {
          $scope.deleteArmed = false;
          return;
        }
        $scope.deleteArmed = false;
        callMethod('deleteSavedStartLine', [JSON.stringify(String($scope.settings.selectedStartId))]);
        $scope.settings.selectedStartId = null;
      };

      $scope.togglePin = function (lap) {
        callMethod('setGhostPinned', [JSON.stringify(String(lap.id)), lap.pinned ? 'false' : 'true']);
      };

      $scope.deleteLap = function (lap) {
        callMethod('deleteGhost', [JSON.stringify(String(lap.id))]);
      };

      $scope.clearLibrary = function () { callMethod('clearRecording', ''); };

      $scope.applyCategoryFilter = function () {
        writeSetting('categoryFilter', $scope.settings.categoryFilter);
        callMethod('setGhostCategoryFilter', [JSON.stringify(String($scope.settings.categoryFilter))]);
        // The stored rows no longer match the filter, so recompute now instead
        // of waiting for the next broadcast.
        $scope.applyState({});
      };

      $scope.applyManualVisibility = function () {
        writeSetting('showManual', $scope.settings.showManual);
        callMethod('setShowManual', [$scope.settings.showManual ? 'true' : 'false']);
        $scope.applyState({});
      };

      $scope.applyStartGateVisibility = function () {
        writeSetting('showStartGate', $scope.settings.showStartGate);
        callMethod('setStartGateVisible', [$scope.settings.showStartGate ? 'true' : 'false']);
      };

      $scope.applySavedStartMarkersVisibility = function () {
        writeSetting('showSavedStartMarkers', $scope.settings.showSavedStartMarkers);
        callMethod('setSavedStartMarkersVisible',
          [$scope.settings.showSavedStartMarkers ? 'true' : 'false']);
      };

      $scope.applyRestoreSavedStart = function () {
        writeSetting('restoreSavedStart', $scope.settings.restoreSavedStart);
        $scope.state.message = $scope.settings.restoreSavedStart
          ? '加载地图时将自动恢复并激活上次的起点'
          : '仅列出已存起点，不自动激活';
      };

      // ---- vehicle lifecycle ----------------------------------------------
      //
      // Adding the panel before a vehicle exists is normal, and switching or
      // resetting a vehicle replaces the controller instance the panel talks
      // to. Both cases start from scratch: re-handshake, re-apply settings,
      // re-request state. Restoring the saved session stays a startup-only
      // action so a reconnect never re-arms a start mid-session.

      $scope.$on('VehicleReset', function () { connect(300); });
      $scope.$on('VehicleFocusChanged', function () { connect(300); });

      // ---- startup -------------------------------------------------------
      //
      // One batched call, deferred out of the current digest. Sending seven
      // separate ones from the constructor is what wedged the UI before.

      $timeout(function () {
        connect(0);
        loadSavedSession();
      }, 0);

      // Menus close on any click that was not on the trigger or an option.
      if ($document && typeof $document.on === 'function') {
        $document.on('click', closeOptionMenu);
      }

      $scope.$on('$destroy', function () {
        if (connectionTimer !== null) {
          $timeout.cancel(connectionTimer);
          connectionTimer = null;
        }
        if ($document && typeof $document.off === 'function') {
          $document.off('click', closeOptionMenu);
        }
        try {
          if (bngApi && bngApi.engineLua) {
            bngApi.engineLua('if extensions and extensions.laplog and ' +
              'extensions.laplog.onUiClosed then extensions.laplog.onUiClosed() end');
          }
        } catch (error) {
          // Nothing useful to do while the panel is being torn down.
        }
      });
    }]
  };
}]);
