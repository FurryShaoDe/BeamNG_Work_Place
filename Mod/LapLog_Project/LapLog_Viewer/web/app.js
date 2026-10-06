/* LapLog 查看器 —— 应用层
 *
 * 数据来自本地 Python 服务的 /api/*（浏览只读；删除会写 lapLogs）。
 * 渲染全部走 charts.js 的自绘 canvas：轨迹图 + 通道曲线 + 共享游标 + 多圈叠加 +
 * ΔT + 按实时秒播放主圈。
 */
(function () {
  'use strict';

  var C = window.LapCharts;

  /* 必须与 server.py 的 VIEWER_CODE_VERSION 一致。查看器是「常驻进程 + 每次请求现读静态文件」：
     服务端没重启时，浏览器会拿到新前端配旧 API，新通道全部缺席、面板静默留空
     （2026-10-04 用户实际踩到）。两侧版本不一致就在这里明说，别再让人猜。 */
  var SERVER_CODE = 6;

  /* 数据里已经有第 17 列、但服务端没发 load_fl：同样是"查看器进程没重启"的迹象 */
  function serverTooOldForChassis(lap) {
    return !!(!lap.channels.load_fl && lap.meta && lap.meta.columns >= 17);
  }

  /* 同理：第 23 列（转向）已经在数据里，但服务端没发 steering 通道 */
  function serverTooOldForSteering(lap) {
    return !!(!lap.channels.steering && lap.meta && lap.meta.columns >= 23);
  }

  /* 四轮载荷通道，顺序固定 前左/前右/后左/后右（与模组样本第 17-20 列一致） */
  var CORNER_CHANNELS = ['load_fl', 'load_fr', 'load_rl', 'load_rr'];

  /* 转向平衡图的速度段（km/h，[下限, 上限)，兜底下限 40 是为了躲开停车/挪车的方向盘噪声） */
  var BALANCE_BANDS = {
    'all': [40, Infinity],
    '40-80': [40, 80],
    '80-140': [80, 140],
    '140-200': [140, 200],
    '200+': [200, Infinity]
  };
  var BALANCE_BAND_LABELS = {
    'all': '全部（≥40 km/h）',
    '40-80': '40–80 km/h',
    '80-140': '80–140 km/h',
    '140-200': '140–200 km/h',
    '200+': '200+ km/h'
  };
  /* "剔除打滑/异常样本"的判据：滑移角超过这个度数（打滑/掉头），
     或者四轮总载荷不到本圈中位数的一半（腾空、骑上路肩、靠护栏）。 */
  var BALANCE_SLIP_LIMIT_DEG = 15;

  var state = {
    catalog: null,
    sel: null,          // {group, level, id}
    laps: [],           // 当前起点的圈清单
    store: {},          // 'group|level|start|gid' -> {meta, channels}
    visible: [],        // 叠加显示的圈 id（第一个是主圈）
    primaryId: null,
    xMode: 'time',      // 'time' | 'dist'
    colorMode: 'lap',   // 'lap' | 'speed' | 'input' | 'gear'
    /* 悬架示意的倾斜来源：
       'load'  = 只由四轮载荷决定（纯悬架形变，默认 —— 不掺地形坡度）
       'world' = 叠实测世界姿态（roll/pitch 原样，含地形）
       'road'  = 叠实测 − 地形坡度（只对俯仰有效；侧倾的坡度分量样本里还原不出来） */
    suspTilt: 'load',
    /* 转向平衡图：只统计选定速度段里的样本（停车/巡航时方向盘角与横向 g 都不代表极限），
       clean = 剔除打滑与"轮胎没在承重"的样本，
       flip  = 把记录的转向符号翻转。默认开启：用左右轮载荷差实测（corr(g, 右−左载荷)=+0.88），
       记录的 steering 正号 = 右转，而横向 g 正号 = 左转，两者天生相反（两台车、三份数据一致），
       翻过来之后"正 = 左转"，散点回到一、三象限。 */
    balance: { band: 'all', clean: true, flip: true },
    filter: 'all',      // 'all' | 'complete' | 'manual' | 'incomplete'
    view: null,         // [x0, x1]
    viewAuto: true,     // true = 视野随数据自动适配；用户缩放/平移后置 false
    cursorX: null,
    mapFit: true,       // true = 下次画轨迹图时重新适配视野（换起点时置位）
    busy: false,
    message: ''
  };

  /* 播放状态：play.t 是被播圈 t 通道上的秒数；1× = 现实 1 秒走 1 秒记录 */
  var play = {
    playing: false,
    t: 0,
    rate: 1,
    follow: true,
    loop: false,
    lastFrame: 0,
    lastReadout: 0,
    seeking: false,
    headingRay: true,    // 车头朝向指引线（黄实线）
    velocityRay: true,   // 行进方向线（青虚线，按位置差分）
    rayLength: 40        // 指引线长度（米）
  };

  /* 是否已经"动过"播放头：用于鼠标移出地图后把播放头（含指引线）恢复回来 */
  function playheadActive() {
    return play.playing || play.t > 0;
  }

  var charts = {};
  var map = null;
  var susp = null;
  var balance = null;
  var el = {};

  function $(id) {
    return document.getElementById(id);
  }

  function api(path, options) {
    return fetch(path, options || {}).then(function (response) {
      return response.json().catch(function () { return null; }).then(function (body) {
        if (!response.ok) {
          throw new Error((body && body.error) || ('HTTP ' + response.status));
        }
        return body;
      });
    });
  }

  function key(group, level, startId, ghostId) {
    return [group, level, startId, ghostId].join('|');
  }

  function lapColor(lap, index) {
    if (lap.color && C.PALETTE[lap.color]) return C.PALETTE[lap.color];
    return C.LAP_COLORS[index % C.LAP_COLORS.length];
  }

  /* ---------------- 目录与圈清单 ---------------- */

  function loadCatalog() {
    state.message = '读取存档目录…';
    renderSidebar();
    return api('/api/catalog').then(function (catalog) {
      state.catalog = catalog;
      state.message = '';
      if (!state.sel) {
        var first = pickDefaultStart(catalog);
        if (first) selectStart(first.group, first.level, first.id);
      }
      renderSidebar();
    }).catch(function (error) {
      state.message = '读取失败：' + error.message;
      renderSidebar();
    });
  }

  /* 默认落在「最近在用、圈最多」的起点上：优先注册表 activeId，其次圈数，最后才看 PB。
     只按最快 PB 选会挑到测试图上的几秒圈，跟用户真正在跑的赛道无关。 */
  function pickDefaultStart(catalog) {
    var levels = (catalog && catalog.levels) || [];
    var best = null;
    var bestScore = -1;
    for (var i = 0; i < levels.length; i++) {
      var level = levels[i];
      for (var k = 0; k < level.starts.length; k++) {
        var start = level.starts[k];
        var score = (start.lapCount || 0) * 10;
        if (level.activeId && level.activeId === start.id) score += 100;
        if (start.pbTime) score += 1;
        if (score > bestScore) {
          bestScore = score;
          best = { group: level.group, level: level.level, id: start.id };
        }
      }
    }
    return best;
  }

  function selectStart(group, level, startId) {
    state.sel = { group: group, level: level, id: startId };
    state.laps = [];
    state.visible = [];
    state.primaryId = null;
    state.view = null;
    state.cursorX = null;
    state.mapFit = true;         // 换了起点：轨迹图重新适配视野
    stopPlayback();
    play.t = 0;
    state.message = '读取圈清单…';
    renderSidebar();
    renderAll();
    api('/api/laps?start=' + encodeURIComponent([group, level, startId].join('/')))
      .then(function (data) {
        state.laps = data.laps || [];
        state.message = '';
        // 默认显示最快的一圈
        var fastest = fastestLap(state.laps);
        if (fastest) makeVisible(fastest.id, true);
        renderSidebar();
        renderAll();
      })
      .catch(function (error) {
        state.message = '读取圈清单失败：' + error.message;
        renderSidebar();
      });
  }

  function fastestLap(laps) {
    var best = null;
    for (var i = 0; i < laps.length; i++) {
      if (laps[i].lapTime && (!best || laps[i].lapTime < best.lapTime)) best = laps[i];
    }
    return best || laps[0] || null;
  }

  function findLap(ghostId) {
    for (var i = 0; i < state.laps.length; i++) {
      if (state.laps[i].id === ghostId) return state.laps[i];
    }
    return null;
  }

  /* ---------------- 圈数据 ---------------- */

  function lapData(ghostId) {
    if (!state.sel) return null;
    var id = key(state.sel.group, state.sel.level, state.sel.id, ghostId);
    return state.store[id] || null;
  }

  function ensureLap(ghostId) {
    if (!state.sel) return Promise.resolve(null);
    var id = key(state.sel.group, state.sel.level, state.sel.id, ghostId);
    if (state.store[id]) return Promise.resolve(state.store[id]);
    var query = '/api/lap?start=' + encodeURIComponent(
      [state.sel.group, state.sel.level, state.sel.id].join('/')) + '&id=' + encodeURIComponent(ghostId);
    return api(query).then(function (data) {
      state.store[id] = data;
      return data;
    }).catch(function (error) {
      state.store[id] = { error: error.message };
      state.message = '读取圈样本失败（' + ghostId + '）：' + error.message;
      return null;
    });
  }

  function makeVisible(ghostId, single) {
    if (single) state.visible = [ghostId];
    else if (state.visible.indexOf(ghostId) === -1) state.visible.push(ghostId);
    state.primaryId = state.visible[0] || null;
    state.view = null;
    state.viewAuto = true;
    ensureLap(ghostId).then(function () { renderAll(); });
  }

  function toggleVisible(ghostId) {
    var index = state.visible.indexOf(ghostId);
    if (index === -1) {
      state.visible.push(ghostId);
      // 等样本到位再重画，避免先按空曲线算一遍视野
      ensureLap(ghostId).then(function () {
        updateRangeFromData();
        renderAll();
      });
      return;
    }
    state.visible.splice(index, 1);
    if (state.primaryId === ghostId) state.primaryId = state.visible[0] || null;
    updateRangeFromData();
    renderAll();
  }

  function setPrimary(ghostId) {
    if (state.visible.indexOf(ghostId) === -1) {
      makeVisible(ghostId, false);
      return;
    }
    state.primaryId = ghostId;
    renderAll();
  }

  /* ---------------- 派生数据 ---------------- */

  function visibleLaps() {
    var list = [];
    for (var i = 0; i < state.visible.length; i++) {
      var data = lapData(state.visible[i]);
      if (data && data.channels) {
        list.push({ id: state.visible[i], meta: data.meta, channels: data.channels });
      }
    }
    return list;
  }

  function axisValues(lap) {
    return state.xMode === 'dist' ? lap.channels.dist.values : lap.channels.t.values;
  }

  /* 这一圈到底有没有记这一列：旧档案（format ≤ 3）缺载荷/姿态列，
     服务端把通道标成 available=false，曲线与读数都据此跳过。 */
  function channelAvailable(lap, cid) {
    var channel = lap.channels[cid];
    return !!(channel && channel.available !== false);
  }

  /* 四轮载荷一行读数的紧凑写法：前 3.5|3.6 后 3.1|3.3 kN */
  function loadReadout(lap) {
    if (serverTooOldForChassis(lap)) return '⚠ 需重启查看器';
    if (!channelAvailable(lap, 'load_fl')) return '—';
    var at = state.cursorX;
    if (at === null || at === undefined) return '—';
    var v = function (cid) { return lap.channels[cid].values; };
    var axis = axisValues(lap);
    var pair = function (left, right) {
      var l = interp(axis, v(left), at);
      var r = interp(axis, v(right), at);
      if (l === null || r === null) return '—';
      return l.toFixed(1) + '|' + r.toFixed(1);
    };
    return '前 ' + pair('load_fl', 'load_fr') + ' 后 ' + pair('load_rl', 'load_rr') + ' kN';
  }

  /* 姿态读数：侧倾 / 俯仰，带正负号（引擎原始符号） */
  function attitudeReadout(lap) {
    if (!channelAvailable(lap, 'roll')) return null;
    if (state.cursorX === null || state.cursorX === undefined) return null;
    var axis = axisValues(lap);
    var roll = interp(axis, lap.channels.roll.values, state.cursorX);
    var pitch = interp(axis, lap.channels.pitch.values, state.cursorX);
    if (roll === null || pitch === null) return null;
    var signed = function (value) { return (value > 0 ? '+' : '') + value.toFixed(1) + '°'; };
    return { text: '侧倾 ' + signed(roll) + ' 俯仰 ' + signed(pitch) };
  }

  function updateRangeFromData(force) {
    if (state.view && !state.viewAuto && !force) return;
    var laps = visibleLaps();
    var min = Infinity;
    var max = -Infinity;
    for (var i = 0; i < laps.length; i++) {
      var axis = axisValues(laps[i]);
      if (!axis.length) continue;
      if (axis[0] < min) min = axis[0];
      if (axis[axis.length - 1] > max) max = axis[axis.length - 1];
    }
    if (isFinite(min) && max > min) {
      state.view = [min, max];
      state.viewAuto = true;
    }
  }

  /* 在「参考量」上插值：返回给定 x 处的 y */
  function interp(xs, ys, x) {
    if (!xs.length) return null;
    if (x < xs[0] || x > xs[xs.length - 1]) return null;
    var lo = 0;
    var hi = xs.length - 1;
    while (hi - lo > 1) {
      var mid = (lo + hi) >> 1;
      if (xs[mid] <= x) lo = mid; else hi = mid;
    }
    var span = xs[hi] - xs[lo];
    if (span <= 1e-9) return ys[lo];
    var f = (x - xs[lo]) / span;
    return ys[lo] + (ys[hi] - ys[lo]) * f;
  }

  /* ΔT 图在数据不足时的提示（少于两圈没有可比对象） */
  var DELTA_EMPTY_TEXT = '勾选两圈以上后，这里显示相对最快圈的时间差（ΔT）';

  /* ΔT：以最快圈为参考，按距离对齐的真实时间差 */
  function deltaSeries(reference, lap) {
    var refDist = reference.channels.dist.values;
    var refTime = reference.channels.t.values;
    var lapDist = lap.channels.dist.values;
    var lapTime = lap.channels.t.values;
    var xs = [];
    var ys = [];
    for (var i = 0; i < refDist.length; i++) {
      var d = refDist[i];
      var tRef = refTime[i];
      var tLap = interp(lapDist, lapTime, d);
      if (tLap === null) continue;
      xs.push(d);
      ys.push(tLap - tRef);
    }
    return { xs: xs, ys: ys };
  }

  /* ---------------- 渲染 ---------------- */

  function renderSidebar() {
    var parts = [];
    if (state.message) parts.push('<div class="msg">' + escapeHtml(state.message) + '</div>');
    if (!state.catalog) {
      el.catalog.innerHTML = parts.join('');
      return;
    }
    parts.push('<div class="tree">');
    var levels = state.catalog.levels || [];
    for (var i = 0; i < levels.length; i++) {
      var level = levels[i];
      /* 旧版按车辆存放的库（lapLogs/vehicles/<车辆>/）：模组在没有活动起点时把手动录制
         落在这里，没有地图/起点信息，所以单独标注一句，别让人以为是某个赛道。 */
      var legacy = level.legacyVehicle === true;
      parts.push('<div class="level"><span class="lvl-name">' + escapeHtml(level.level) +
        '</span><span class="lvl-tag">' + escapeHtml(legacy ? '按车辆存放' : level.group) +
        '</span></div>');
      if (legacy) {
        parts.push('<div class="hint">没有活动起点时保存的库（手动录制常见）· ' +
          '不属于任何地图，轨迹图无起点门</div>');
      }
      for (var k = 0; k < level.starts.length; k++) {
        var start = level.starts[k];
        var active = state.sel && state.sel.group === level.group &&
          state.sel.level === level.level && state.sel.id === start.id;
        parts.push('<div class="start' + (active ? ' active' : '') + '" data-start="' +
          escapeHtml([level.group, level.level, start.id].join('/')) + '">' +
          '<span class="s-name">' + escapeHtml(start.name) + '</span>' +
          '<span class="s-meta">' + start.lapCount + ' 圈' +
          (start.orphanCount ? ' +' + start.orphanCount + ' 外' : '') +
          (start.pbTime ? ' · PB ' + C.formatClock(start.pbTime) : '') + '</span></div>');
      }
    }
    parts.push('</div>');

    if (state.sel) {
      parts.push('<div class="list-head">圈列表' +
        '<span class="filters">' +
        filterButton('all', '全部') + filterButton('complete', '完整') +
        filterButton('incomplete', '未完成') + filterButton('manual', '手动') +
        '</span></div>');
      parts.push('<div class="lap-list">');
      var laps = filteredLaps();
      if (!laps.length) parts.push('<div class="msg">没有符合条件的记录</div>');
      for (var j = 0; j < laps.length; j++) {
        parts.push(lapRow(laps[j], j));
      }
      parts.push('</div>');
    }

    el.catalog.innerHTML = parts.join('');

    var startNodes = el.catalog.querySelectorAll('[data-start]');
    for (var s = 0; s < startNodes.length; s++) {
      startNodes[s].addEventListener('click', function () {
        var pieces = this.getAttribute('data-start').split('/');
        selectStart(pieces[0], pieces[1], pieces[2]);
      });
    }
    var filterNodes = el.catalog.querySelectorAll('[data-filter]');
    for (var f = 0; f < filterNodes.length; f++) {
      filterNodes[f].addEventListener('click', function () {
        state.filter = this.getAttribute('data-filter');
        renderSidebar();
      });
    }
    var lapNodes = el.catalog.querySelectorAll('[data-lap]');
    for (var l = 0; l < lapNodes.length; l++) {
      lapNodes[l].addEventListener('click', function (event) {
        var tag = event.target && event.target.tagName;
        if (tag === 'INPUT' || tag === 'A' || tag === 'BUTTON') return;   // 勾选框 / CSV / 删除各管各的
        setPrimary(this.getAttribute('data-lap'));
      });
    }
    var delNodes = el.catalog.querySelectorAll('[data-del]');
    for (var d = 0; d < delNodes.length; d++) {
      delNodes[d].addEventListener('click', function () {
        deleteLap(this.getAttribute('data-del'));
      });
    }
    var checkNodes = el.catalog.querySelectorAll('[data-check]');
    for (var c = 0; c < checkNodes.length; c++) {
      checkNodes[c].addEventListener('change', function () {
        toggleVisible(this.getAttribute('data-check'));
      });
    }
  }

  function filterButton(id, label) {
    return '<button class="chip' + (state.filter === id ? ' on' : '') +
      '" data-filter="' + id + '">' + label + '</button>';
  }

  function filteredLaps() {
    return state.laps.filter(function (lap) {
      if (state.filter === 'complete') return lap.complete && !lap.manual;
      if (state.filter === 'incomplete') return !lap.complete;
      if (state.filter === 'manual') return lap.manual;
      return true;
    });
  }

  function lapRow(lap, index) {
    var visible = state.visible.indexOf(lap.id) !== -1;
    var primary = state.primaryId === lap.id;
    var color = lapColor(lap, index);
    var badges = [];
    if (lap.orphan) badges.push('<span class="badge warn">清单外</span>');
    if (lap.manual) badges.push('<span class="badge">手动</span>');
    if (!lap.complete) badges.push('<span class="badge bad">未完成</span>');
    if (lap.pinned) badges.push('<span class="badge">置顶</span>');
    var csv = state.sel ? apiUrl('/api/export.csv?start=' +
      encodeURIComponent([state.sel.group, state.sel.level, state.sel.id].join('/')) +
      '&id=' + encodeURIComponent(lap.id)) : '#';
    return '<div class="lap' + (visible ? ' visible' : '') + (primary ? ' primary' : '') +
      '" data-lap="' + escapeHtml(lap.id) + '">' +
      '<input type="checkbox" ' + (visible ? 'checked' : '') + ' data-check="' + escapeHtml(lap.id) + '">' +
      '<span class="dot" style="background:' + color + '"></span>' +
      '<span class="l-name">' + escapeHtml(lap.label || lap.id) + '</span>' +
      '<span class="l-time">' + (lap.lapTime ? C.formatClock(lap.lapTime) : (lap.duration ? '~' + lap.duration.toFixed(2) + 's' : '—')) + '</span>' +
      badges.join('') +
      '<a class="csv" href="' + csv + '" download title="导出 CSV">CSV</a>' +
      '<button class="del" data-del="' + escapeHtml(lap.id) + '" title="删除该圈记录（样本移入 _trash）">✕</button>' +
      '</div>';
  }

  function apiUrl(path) {
    return path;
  }

  /* 转向读数：方向盘角（度，服务端已按该车锁角换算），括号里是助力前的同一信号
     —— 两者不同时才有必要显示，差值就是助力介入量。没有转向列的记录返回 null。 */
  function steerReadout(lap) {
    if (serverTooOldForSteering(lap)) return '⚠ 需重启查看器';
    if (!channelAvailable(lap, 'steering')) return null;
    var at = state.cursorX;
    if (at === null || at === undefined) return '—';
    var axis = axisValues(lap);
    var flip = state.balance.flip ? -1 : 1;
    var value = interp(axis, lap.channels.steering.values, at) * flip;
    var text = (value > 0 ? '+' : '') + value.toFixed(1) + '°';
    if (channelAvailable(lap, 'steering_raw')) {
      var raw = interp(axis, lap.channels.steering_raw.values, at) * flip;
      if (Math.abs(raw - value) >= 0.1) {
        text += '（助力前 ' + (raw > 0 ? '+' : '') + raw.toFixed(1) + '°）';
      }
    }
    return text;
  }

  function renderReadout() {
    var laps = visibleLaps();
    if (!laps.length) {
      el.readout.innerHTML = '<span class="hint">勾选左侧圈记录后，这里显示游标处的读数</span>';
      return;
    }
    var html = [];
    for (var i = 0; i < laps.length; i++) {
      var lap = laps[i];
      var axis = axisValues(lap);
      var at = state.cursorX === null ? null : state.cursorX;
      var color = lapColor(findLap(lap.id) || {}, i);
      var t = at === null ? null : interp(axis, lap.channels.t.values, at);
      var speed = at === null ? null : interp(axis, lap.channels.speed.values, at);
      var throttle = at === null ? null : interp(axis, lap.channels.throttle.values, at);
      var brake = at === null ? null : interp(axis, lap.channels.brake.values, at);
      var gear = at === null ? null : interp(axis, lap.channels.gear.values, at);
      var glat = at === null ? null : interp(axis, lap.channels.g_lat.values, at);
      var slip = at === null ? null : slipAt(lap, t);
      var staleServer = serverTooOldForChassis(lap);
      var loads = staleServer ? '⚠ 需重启查看器' : (at === null ? '—' : loadReadout(lap));
      var attitude = (at === null || staleServer) ? null : attitudeReadout(lap);
      var steer = channelAvailable(lap, 'steering') ? steerReadout(lap) : null;
      var slipText = '—';
      var slipStyle = '';
      if (slip !== null) {
        var slipDeg = slip * 180 / Math.PI;
        slipText = (slipDeg > 0 ? '+' : '') + slipDeg.toFixed(1) + '°';
        slipStyle = ' style="color:' + slipColor(slip) + '"';
      }
      html.push('<div class="ro"><span class="dot" style="background:' + color + '"></span>' +
        '<b>' + (lap.meta.lapTime ? C.formatClock(lap.meta.lapTime) : lap.id) + '</b>' +
        '<span>t ' + (t === null ? '—' : t.toFixed(3) + ' s') + '</span>' +
        '<span>速度 ' + (speed === null ? '—' : speed.toFixed(1) + ' km/h') + '</span>' +
        '<span>挡 ' + (gear === null ? '—' : Math.round(gear)) + '</span>' +
        '<span>油门 ' + (throttle === null ? '—' : throttle.toFixed(0) + '%') + '</span>' +
        '<span>刹车 ' + (brake === null ? '—' : brake.toFixed(0) + '%') + '</span>' +
        '<span>横向G ' + (glat === null ? '—' : glat.toFixed(2)) + '</span>' +
        (steer ? '<span title="方向盘角 = 记录输入 × 该车锁角（正 = 左转，已按左右轮载荷定标）；括号内是助力前的同一信号，差值 = 助力介入量">方向 ' +
          steer + '</span>' : '') +
        '<span title="四轮垂直接地载荷（前左|前右 后左|后右）；旧记录没有这一列">载荷 ' + loads + '</span>' +
        (attitude ? '<span title="侧倾 / 俯仰，正负为引擎 getRollPitchYaw() 原始符号">' +
          attitude.text + '</span>' : '') +
        '<span' + slipStyle + ' title="滑移角 = 车头朝向 − 行进方向（正 = 车头偏向行进方向左侧）；' +
        '低速时方向不可靠，显示 —">滑移 ' + slipText + '</span>' +
        '</div>');
    }
    el.readout.innerHTML = html.join('');
  }

  function labelMap() {
    var labels = {};
    for (var i = 0; i < state.laps.length; i++) labels[state.laps[i].id] = state.laps[i];
    return labels;
  }

  /* 只重画视图（读数/轨迹/曲线），不动侧栏与汇总——缩放与游标移动走这里 */
  function renderViews() {
    updateRangeFromData();
    var laps = visibleLaps();
    var labels = labelMap();
    renderReadout();
    renderMap(laps, labels);
    renderCharts(laps, labels);
    renderBalance(laps);
    renderSuspension();
    return { laps: laps, labels: labels };
  }

  function renderAll() {
    var context = renderViews();
    renderSummary(context.laps, context.labels);
    renderSidebar();
    syncPlayhead();
  }

  function renderMap(laps, labels) {
    if (!laps.length) {
      map.setData([], []);
      return;
    }
    var series = [];
    var globalMax = 0;
    for (var i = 0; i < laps.length; i++) {
      var max = 0;
      var values = laps[i].channels.speed.values;
      for (var k = 0; k < values.length; k++) if (values[k] > max) max = values[k];
      if (max > globalMax) globalMax = max;
    }
    for (var j = 0; j < laps.length; j++) {
      var lap = laps[j];
      var posX = lap.channels.pos_x.values;
      var posY = lap.channels.pos_y.values;
      var points = [];
      for (var p = 0; p < posX.length; p++) points.push([posX[p], posY[p]]);
      var entry = {
        id: lap.id,
        color: lapColor(labels[lap.id] || {}, j),
        width: j === 0 ? 3 : 2,
        points: points
      };
      if (state.colorMode !== 'lap') {
        var colors = [];
        for (var q = 0; q < points.length; q++) colors.push(segmentColor(lap, q, globalMax));
        entry.segColors = colors;
      }
      series.push(entry);
    }

    var gates = [];
    var sel = currentStartInfo();
    if (sel && sel.startLine && sel.startLine.position) {
      gates.push({
        color: '#48eb7e',
        center: [sel.startLine.position[0], sel.startLine.position[1]],
        normal: [sel.startLine.normal[0], sel.startLine.normal[1]],
        halfWidth: sel.startLine.halfWidth || 15
      });
    }
    if (sel && sel.finishPosition) {
      gates.push({
        color: '#ffd166',
        center: [sel.finishPosition[0], sel.finishPosition[1]],
        normal: (sel.finishNormal || [0, 1]),
        halfWidth: 15
      });
    }
    // 换起点时才重新适配视野；平时重绘保留用户的缩放/平移（否则每次重画都会打断跟随）
    map.setData(series, gates, !state.mapFit);
    state.mapFit = false;
  }

  function segmentColor(lap, index, globalMax) {
    if (state.colorMode === 'speed') {
      var speed = lap.channels.speed.values[index] || 0;
      return C.speedColor(globalMax > 1 ? speed / globalMax : 0);
    }
    if (state.colorMode === 'input') {
      return C.inputColor((lap.channels.throttle.values[index] || 0) / 100,
                          (lap.channels.brake.values[index] || 0) / 100);
    }
    if (state.colorMode === 'gear') {
      return C.gearColor(lap.channels.gear.values[index]);
    }
    return '#ffffff';
  }

  function currentStartInfo() {
    if (!state.sel || !state.catalog) return null;
    var levels = state.catalog.levels || [];
    for (var i = 0; i < levels.length; i++) {
      if (levels[i].group !== state.sel.group || levels[i].level !== state.sel.level) continue;
      for (var k = 0; k < levels[i].starts.length; k++) {
        if (levels[i].starts[k].id === state.sel.id) return levels[i].starts[k];
      }
    }
    return null;
  }

  function range(values) {
    var min = Infinity;
    var max = -Infinity;
    for (var i = 0; i < values.length; i++) {
      if (values[i] < min) min = values[i];
      if (values[i] > max) max = values[i];
    }
    if (!isFinite(min)) return [0, 1];
    if (max - min < 1e-6) return [min - 1, max + 1];
    var pad = (max - min) * 0.08;
    return [min - pad, max + pad];
  }

  function buildSeries(laps, labels, accessor) {
    var series = [];
    for (var i = 0; i < laps.length; i++) {
      var lap = laps[i];
      var color = lapColor(labels[lap.id] || {}, i);
      var made = accessor(lap, color, i);
      for (var k = 0; k < made.length; k++) series.push(made[k]);
    }
    return series;
  }

  function allRange(series) {
    var min = Infinity;
    var max = -Infinity;
    for (var i = 0; i < series.length; i++) {
      for (var k = 0; k < series[i].y.length; k++) {
        if (series[i].y[k] < min) min = series[i].y[k];
        if (series[i].y[k] > max) max = series[i].y[k];
      }
    }
    if (!isFinite(min)) return [0, 1];
    if (max - min < 1e-6) return [min - 1, max + 1];
    var pad = (max - min) * 0.08;
    return [min - pad, max + pad];
  }

  function renderCharts(laps, labels) {
    var view = state.view || [0, 1];
    var xUnit = state.xMode === 'dist' ? 'm' : 's';

    if (!laps.length) {
      ['speed', 'pedals', 'gear', 'gforce', 'steering', 'loads', 'attitude']
        .forEach(function (name) {
        charts[name].setData([], view, [0, 1], xUnit);
      });
      charts.delta.cursorMap = null;
      charts.delta.setEmpty(DELTA_EMPTY_TEXT);
      return;
    }

    var speedSeries = buildSeries(laps, labels, function (lap, color) {
      return [{
        id: lap.id, color: color, width: 1.8,
        x: axisValues(lap), y: lap.channels.speed.values
      }];
    });
    charts.speed.setData(speedSeries, view, allRange(speedSeries), xUnit + ' · km/h');

    var single = laps.length === 1;
    var pedalSeries = buildSeries(laps, labels, function (lap, color) {
      var axis = axisValues(lap);
      // 只显示一圈时用语义色（绿=油门 红=刹车），一眼能分清；
      // 多圈叠加时回到每圈一色（实线/虚线区分两者），否则颜色会打架。
      return [
        { id: lap.id + ':throttle', color: single ? '#48eb7e' : color, width: 1.6,
          x: axis, y: lap.channels.throttle.values },
        { id: lap.id + ':brake', color: single ? '#ef476f' : color, width: 1.2, dash: true,
          x: axis, y: lap.channels.brake.values }
      ];
    });
    charts.pedals.setData(pedalSeries, view, [0, 105], xUnit + ' · %  （实线=油门，虚线=刹车）');

    var gearSeries = buildSeries(laps, labels, function (lap, color) {
      return [{ id: lap.id, color: color, width: 1.4, x: axisValues(lap), y: lap.channels.gear.values }];
    });
    charts.gear.setData(gearSeries, view, allRange(gearSeries), xUnit + ' · 挡位');

    var gSeries = buildSeries(laps, labels, function (lap, color) {
      var axis = axisValues(lap);
      return [
        { id: lap.id + ':lat', color: color, width: 1.6, x: axis, y: lap.channels.g_lat.values },
        { id: lap.id + ':lon', color: color, width: 1.2, dash: true, x: axis, y: lap.channels.accel_lon.values }
      ];
    });
    charts.gforce.setData(gSeries, view, allRange(gSeries), xUnit + ' · g  （实线=横向，虚线=纵向）');

    // 转向：format 5 才有的列，服务端已按该记录的车辆锁角把 -1..1 输入换算成度。
    // 旧档案没有这两列（通道 available=false，曲线直接跳过）。
    var anySteering = false;
    var steeringStale = false;
    for (var si = 0; si < laps.length; si++) {
      if (channelAvailable(laps[si], 'steering')) anySteering = true;
      if (serverTooOldForSteering(laps[si])) steeringStale = true;
    }
    var steeringHint = steeringStale
      ? '  ⚠ 查看器服务端代码过旧：重启查看器后才显示'
      : (anySteering ? '' : '  （该记录没有转向列：format 5 起才记录）');
    var steerFlip = state.balance.flip ? -1 : 1;
    var steeringSeries = buildSeries(laps, labels, function (lap, color) {
      if (!channelAvailable(lap, 'steering')) return [];
      var axis = axisValues(lap);
      var made = [{
        id: lap.id + ':steering', color: color, width: 1.6, x: axis,
        y: lap.channels.steering.values.map(function (v) { return v * steerFlip; })
      }];
      if (channelAvailable(lap, 'steering_raw')) {
        made.push({
          id: lap.id + ':steeringraw', color: color, width: 1.2, dash: true, x: axis,
          y: lap.channels.steering_raw.values.map(function (v) { return v * steerFlip; })
        });
      }
      return made;
    });
    charts.steering.setData(steeringSeries, view, allRange(steeringSeries),
      xUnit + ' · °  （实线=实际转向（助力后） 虚线=助力前）' + steeringHint);

    // 悬架载荷 / 车身姿态：format 4 才有的列。旧档案在这里没有数据，
    // 服务端会把这些通道标 available=false，于是曲线被跳过、面板留空。
    var loadChannels = CORNER_CHANNELS;
    var loadDashes = [null, [6, 3], [2, 3], [9, 3, 2, 3]];
    var staleChassis = false;
    for (var s = 0; s < laps.length; s++) {
      if (serverTooOldForChassis(laps[s])) staleChassis = true;
    }
    var staleHint = staleChassis ? '  ⚠ 查看器服务端代码过旧：重启查看器后才显示' : '';
    var loadSeries = buildSeries(laps, labels, function (lap, color) {
      if (!channelAvailable(lap, 'load_fl')) return [];
      var axis = axisValues(lap);
      var made = [];
      for (var c = 0; c < loadChannels.length; c++) {
        made.push({
          id: lap.id + ':' + loadChannels[c], color: color, width: 1.4,
          dash: loadDashes[c], x: axis, y: lap.channels[loadChannels[c]].values
        });
      }
      return made;
    });
    charts.loads.setData(loadSeries, view, allRange(loadSeries),
      xUnit + ' · kN  （实线=前左 虚线=前右 点线=后左 点划线=后右）' + staleHint);

    var attitudeSeries = buildSeries(laps, labels, function (lap, color) {
      if (!channelAvailable(lap, 'roll')) return [];
      var axis = axisValues(lap);
      var made = [
        { id: lap.id + ':roll', color: color, width: 1.6, x: axis, y: lap.channels.roll.values },
        { id: lap.id + ':pitch', color: color, width: 1.2, dash: true, x: axis, y: lap.channels.pitch.values }
      ];
      // 去地形俯仰（服务端派生）：实线俯仰里绝大部分是坡道，这条才是悬架俯仰
      if (channelAvailable(lap, 'pitch_road')) {
        made.push({ id: lap.id + ':pitchroad', color: color, width: 1.2,
                    dash: [2, 3], x: axis, y: lap.channels.pitch_road.values });
      }
      return made;
    });
    charts.attitude.setData(attitudeSeries, view, allRange(attitudeSeries),
      xUnit + ' · °  （实线=侧倾  虚线=俯仰(含地形)  点线=俯仰去地形）' + staleHint);

    // ΔT：参考圈 = 最快的一圈（不足两圈时给提示，不再画默认坐标系）
    var deltaSeriesList = [];
    var reference = null;
    if (laps.length >= 2) {
      reference = laps[0];
      for (var i = 1; i < laps.length; i++) {
        if (laps[i].meta.lapTime && reference.meta.lapTime &&
            laps[i].meta.lapTime < reference.meta.lapTime) reference = laps[i];
      }
      for (var j = 0; j < laps.length; j++) {
        if (laps[j].id === reference.id) continue;
        var delta = deltaSeries(reference, laps[j]);
        if (!delta.xs.length) continue;
        deltaSeriesList.push({
          id: laps[j].id,
          color: lapColor(labels[laps[j].id] || {}, j),
          width: 1.6,
          x: delta.xs,
          y: delta.ys
        });
      }
    }
    var deltaView = state.xMode === 'dist' ? view : null;
    if (!deltaView && deltaSeriesList.length) {
      var min = Infinity;
      var max = -Infinity;
      for (var m = 0; m < deltaSeriesList.length; m++) {
        min = Math.min(min, deltaSeriesList[m].x[0]);
        max = Math.max(max, deltaSeriesList[m].x[deltaSeriesList[m].x.length - 1]);
      }
      deltaView = [min, max];
    }
    if (!deltaSeriesList.length || !reference) {
      charts.delta.cursorMap = null;
      charts.delta.setEmpty(DELTA_EMPTY_TEXT);
    } else {
      /* y 轴以 0 为中心对称：0 = 与最快圈打平，正值（慢）与负值（快）各占一半高度，
         曲线不会因为数据整体偏一侧而贴着上/下边框，读差值时比例才直观。 */
      var deltaRange = allRange(deltaSeriesList);
      var reach = Math.max(Math.abs(deltaRange[0]), Math.abs(deltaRange[1])) * 1.04;
      if (!isFinite(reach) || reach < 0.05) reach = 0.05;
      /* 参考圈顺带给出「时间 → 距离」的换算：游标在时间模式下是秒，而 ΔT 图恒为距离轴，
         不换算的话游标会落在 x 轴的百分之几处（画错位置、读数也错）。 */
      var refTimes = reference.channels.t.values;
      var refDist = reference.channels.dist.values;
      charts.delta.cursorMap = function (x) {
        if (state.xMode === 'dist') return x;
        return interp(refTimes, refDist, x);
      };
      charts.delta.setData(deltaSeriesList, deltaView || [0, 1], [-reach, reach],
        'm（距离轴）· s  相对最快圈');
    }
  }

  /* 每圈的滑移角数组（度）= 车头朝向 − 行进方向，和读数里的滑移角同一套算法，
     只是这里按样本算一遍并缓存在通道上（平衡图要按它筛掉打滑段）。 */
  function balanceSlipDeg(lap) {
    if (lap.channels._slipDeg) return lap.channels._slipDeg;
    var heading = lap.channels.heading ? lap.channels.heading.values : null;
    var posX = lap.channels.pos_x.values;
    var posY = lap.channels.pos_y.values;
    var out = new Array(posX.length);
    for (var i = 0; i < posX.length; i++) {
      var lo = Math.max(0, i - 2);
      var hi = Math.min(posX.length - 1, i + 2);
      var dx = posX[hi] - posX[lo];
      var dy = posY[hi] - posY[lo];
      if (!heading || (Math.abs(dx) < 1e-3 && Math.abs(dy) < 1e-3)) {
        out[i] = 0;
        continue;
      }
      out[i] = normalizeAngle(heading[i] - Math.atan2(dy, dx)) * 180 / Math.PI;
    }
    lap.channels._slipDeg = out;
    return out;
  }

  /* 四轮总载荷（N）：判断轮胎到底在不在承重，用来剔除腾空/骑路肩/靠护栏的样本 */
  function balanceTotalLoad(lap) {
    if (!channelAvailable(lap, 'load_fl')) return null;
    var fl = lap.channels.load_fl.values;
    var fr = lap.channels.load_fr.values;
    var rl = lap.channels.load_rl.values;
    var rr = lap.channels.load_rr.values;
    var out = new Array(fl.length);
    for (var i = 0; i < fl.length; i++) out[i] = fl[i] + fr[i] + rl[i] + rr[i];
    return out;
  }

  function medianOf(values) {
    var sorted = values.slice().sort(function (a, b) { return a - b; });
    return sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0;
  }

  /* 转向平衡图：方向盘角 vs 横向 g。
     形状交给 balance.js 的 5° 分箱中位数/分位带（散点只当背景），数字只报两个：
     ±15° 内的小角度斜率（转向效率）与平台值（抓地上限）。
     注意这不是严格的转向不足梯度 K（K = δ/ay − L/v² 需要轴距并分段速度），
     所以入口给的是速度段筛选 + 两个可比数字，而不是一根全段回归线。 */
  function renderBalance(laps) {
    if (!balance) return;
    var flip = state.balance.flip ? -1 : 1;
    var clean = state.balance.clean !== false;
    var bandKey = BALANCE_BANDS[state.balance.band] ? state.balance.band : 'all';
    var band = BALANCE_BANDS[bandKey];
    var series = [];
    var stale = false;
    var anySteering = false;
    var dropped = 0;
    for (var i = 0; i < laps.length; i++) {
      var lap = laps[i];
      if (serverTooOldForSteering(lap)) stale = true;
      if (!channelAvailable(lap, 'steering') || !channelAvailable(lap, 'g_lat')) continue;
      anySteering = true;
      var steer = lap.channels.steering.values;
      var ay = lap.channels.g_lat.values;
      var speed = lap.channels.speed.values;
      var slip = clean ? balanceSlipDeg(lap) : null;
      var total = clean ? balanceTotalLoad(lap) : null;
      var loadFloor = total ? medianOf(total) * 0.5 : 0;
      var points = [];
      var limit = Math.min(steer.length, ay.length, speed.length);
      for (var k = 0; k < limit; k++) {
        if (!(speed[k] >= band[0] && speed[k] < band[1])) continue;
        if (clean) {
          if (slip && Math.abs(slip[k]) > BALANCE_SLIP_LIMIT_DEG) { dropped += 1; continue; }
          if (total && total[k] < loadFloor) { dropped += 1; continue; }
        }
        points.push([steer[k] * flip, ay[k]]);
      }
      series.push({
        id: lap.id,
        label: lap.meta.lapTime ? C.formatClock(lap.meta.lapTime) : lap.id,
        color: lapColor(findLap(lap.id) || {}, i),
        points: points
      });
    }
    var placeholder = stale ? '⚠ 查看器服务端代码过旧：重启查看器后才显示'
      : (anySteering ? '当前速度段/筛选下没有可用样本' : '该记录没有转向列（format 5 起记录）');
    var stats = balance.setData(series, { placeholder: placeholder, maxAbsDelta: 90 });
    balance.draw();
    // 一圈都没有转向列时别写"样本不足"——那是"根本没记"，不是"没跑到"
    if (el.balanceNote) {
      el.balanceNote.textContent = stats.length ? balanceNoteText(stats, laps, {
        dropped: dropped,
        cleaned: clean,
        bandLabel: BALANCE_BAND_LABELS[bandKey]
      }) : placeholder;
    }
  }

  /* 平衡图下方的说明：只报"小角度斜率 + 平台值 + 拐点"，并写清筛选口径与锁角来源 */
  function balanceNoteText(stats, laps, info) {
    var parts = [];
    var negative = false;
    for (var i = 0; i < stats.length; i++) {
      var stat = stats[i];
      var text = stat.label + '：';
      if (stat.slope === null) {
        text += '±15° 内样本不足';
      } else {
        if (stat.slope < 0) negative = true;
        text += '±15° 内 ' + stat.slope.toFixed(4) + ' g/°（≈ ' +
          Math.abs(1 / stat.slope).toFixed(0) + ' °/g，n=' + stat.slopeSamples + '）';
      }
      if (stat.plateau !== null) {
        text += ' · 平台 ' + stat.plateau.toFixed(2) + ' g（p90 ' +
          stat.plateauP90.toFixed(2) + ' g）';
        if (stat.kneeDeg !== null) text += ' · ≈' + Math.round(stat.kneeDeg) + '° 到顶';
      }
      if (stat.hidden) text += ' · ±90° 外 ' + stat.hidden + ' 点未画';
      parts.push(text);
    }
    var note = parts.length ? parts.join('　·　') : '样本不足（换个速度段，或跑得再狠一点）';
    if (negative) note += '　·　⚠ 斜率为负：记录的转向符号与横向 G 相反，勾/取消「反转转向方向」再看';
    if (info.cleaned) {
      note += '　·　已剔除打滑/异常 ' + info.dropped + ' 点（|滑移| > ' +
        BALANCE_SLIP_LIMIT_DEG + '° 或总载荷 < 一半中位）';
    }
    note += '　·　速度段 ' + info.bandLabel;
    return note + steeringLockNote(laps);
  }

  /* 锁角提示：角度 = 记录输入 × 该记录里的锁角；用了缺省值时必须说明 */
  function steeringLockNote(laps) {
    for (var i = 0; i < laps.length; i++) {
      if (!channelAvailable(laps[i], 'steering')) continue;
      var meta = laps[i].meta || {};
      return '　·　锁角 ' + Number(meta.steeringWheelLock || 450).toFixed(0) + '°' +
        (meta.steeringWheelLockDefault ? '（该记录没写锁角，按缺省值换算）' : '');
    }
    return '';
  }

  function renderSummary(laps, labels) {
    if (!laps.length) {
      el.summary.innerHTML = '<div class="msg">勾选左侧圈记录后显示汇总</div>';
      return;
    }
    var rows = ['<table><thead><tr><th>圈</th><th>圈速</th><th>距离</th><th>最高速</th>' +
      '<th>平均速</th><th>全油门</th><th>刹车</th><th>滑行</th><th>采样点</th><th>车型</th>' +
      '<th>来源</th></tr></thead><tbody>'];
    for (var i = 0; i < laps.length; i++) {
      var lap = laps[i];
      var meta = lap.meta;
      var info = labels[lap.id] || {};
      var speed = lap.channels.speed.values;
      var throttle = lap.channels.throttle.values;
      var brake = lap.channels.brake.values;
      var dist = lap.channels.dist.values;
      var maxSpeed = 0;
      var sum = 0;
      var full = 0;
      var braking = 0;
      var coast = 0;
      for (var k = 0; k < speed.length; k++) {
        if (speed[k] > maxSpeed) maxSpeed = speed[k];
        sum += speed[k];
        if (throttle[k] >= 95) full += 1;
        if (brake[k] >= 5) braking += 1;
        if (throttle[k] < 5 && brake[k] < 5) coast += 1;
      }
      var count = Math.max(1, speed.length);
      var color = lapColor(info, i);
      rows.push('<tr>' +
        '<td><span class="dot" style="background:' + color + '"></span>' +
        escapeHtml(meta.label || lap.id) + (meta.complete === false ? ' <span class="badge bad">未完成</span>' : '') + '</td>' +
        '<td>' + (meta.lapTime ? C.formatClock(meta.lapTime) : '—') + '</td>' +
        '<td>' + (dist.length ? dist[dist.length - 1].toFixed(1) + ' m' : '—') + '</td>' +
        '<td>' + maxSpeed.toFixed(1) + ' km/h</td>' +
        '<td>' + (sum / count).toFixed(1) + ' km/h</td>' +
        '<td>' + (full / count * 100).toFixed(0) + '%</td>' +
        '<td>' + (braking / count * 100).toFixed(0) + '%</td>' +
        '<td>' + (coast / count * 100).toFixed(0) + '%</td>' +
        '<td>' + meta.sampleCount + ' @ ' + (meta.sampleInterval || 0.02) + 's</td>' +
        '<td>' + escapeHtml(meta.vehicle || '—') + '</td>' +
        '<td>' + escapeHtml(meta.source || '—') + '</td>' +
        '</tr>');
    }
    rows.push('</tbody></table>');
    el.summary.innerHTML = rows.join('');
  }

  function escapeHtml(text) {
    return String(text === null || text === undefined ? '' : text)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /* ---------------- 游标 ---------------- */

  var cursorPending = false;

  function setCursor(x) {
    state.cursorX = x;
    if (play.playing) return;      // 播放中交给播放头，别被悬停覆盖
    if (cursorPending) return;
    cursorPending = true;
    window.requestAnimationFrame(function () {
      cursorPending = false;
      if (play.playing) return;
      if (x === null && playheadActive()) {   // 鼠标移出：把播放头（含指引线）恢复回来
        applyPlayhead();
        return;
      }
      var laps = visibleLaps();
      // 轨迹图上的游标点：主圈在游标处的插值位置
      var primary = null;
      for (var i = 0; i < laps.length; i++) {
        if (laps[i].id === state.primaryId) primary = laps[i];
      }
      if (!primary) primary = laps[0] || null;
      if (primary && x !== null) {
        var axis = axisValues(primary);
        var px = interp(axis, primary.channels.pos_x.values, x);
        var py = interp(axis, primary.channels.pos_y.values, x);
        map.cursor = (px === null || py === null) ? null : { x: px, y: py };
      } else {
        map.cursor = null;
      }
      map.draw();
      for (var name in charts) {
        if (!charts.hasOwnProperty(name)) continue;
        charts[name].cursorX = x;
        charts[name].draw();
      }
      renderReadout();
      renderSuspension();
    });
  }

  function onMapHover(x, y) {
    if (play.playing) return;      // 播放中由播放头占用游标，避免两套光标打架
    if (x === null) {
      setCursor(null);
      return;
    }
    var laps = visibleLaps();
    var primary = null;
    for (var i = 0; i < laps.length; i++) {
      if (laps[i].id === state.primaryId) primary = laps[i];
    }
    if (!primary) primary = laps[0] || null;
    if (!primary) return;
    var posX = primary.channels.pos_x.values;
    var posY = primary.channels.pos_y.values;
    var axis = axisValues(primary);
    var best = -1;
    var bestDist = Infinity;
    for (var k = 0; k < posX.length; k += 2) {
      var dx = posX[k] - x;
      var dy = posY[k] - y;
      var d = dx * dx + dy * dy;
      if (d < bestDist) { bestDist = d; best = k; }
    }
    if (best >= 0) setCursor(axis[best]);
  }

  /* ---------------- 悬架示意（正视图 / 侧视图） ----------------
   *
   * 数据映射：每角「压缩量」= (当前载荷 − 本圈中位数) / 本圈最大偏离，归一化到 −1..1；
   * 画布上弹簧与车身的姿态由它和录到的 roll/pitch 一起驱动（没有弹簧刚度，所以不标毫米）。
   * 参考值按圈缓存：11k 个样本排序一次，别每帧重算。
   */

  var suspStatCache = {};

  function suspensionStat(lap) {
    var cacheKey = state.sel
      ? key(state.sel.group, state.sel.level, state.sel.id, lap.id)
      : lap.id;
    if (suspStatCache[cacheKey]) return suspStatCache[cacheKey];
    var stat = null;
    if (channelAvailable(lap, 'load_fl')) {
      var base = [];
      var span = 0;
      for (var c = 0; c < CORNER_CHANNELS.length; c++) {
        var values = lap.channels[CORNER_CHANNELS[c]].values;
        var sorted = values.slice().sort(function (a, b) { return a - b; });
        var median = sorted.length ? sorted[sorted.length >> 1] : 0;
        base.push(median);
        for (var k = 0; k < values.length; k++) {
          var delta = Math.abs(values[k] - median);
          if (delta > span) span = delta;
        }
      }
      // 下限 0.2 kN：静止/匀速圈的噪声不该被放大成满量程（通道单位是 kN）
      stat = { base: base, span: Math.max(0.2, span) };
    }
    suspStatCache[cacheKey] = stat;
    return stat;
  }

  function suspensionFrame() {
    var lap = primaryLap();
    if (!lap) return { placeholder: '勾选一圈后显示悬架形变' };
    if (serverTooOldForChassis(lap)) return { placeholder: '⚠ 查看器服务端代码过旧：重启查看器后才显示' };
    if (!channelAvailable(lap, 'load_fl')) {
      return { placeholder: '该圈没有悬架数据（format 2/3 的记录没有载荷与姿态列）' };
    }
    var at = state.cursorX;
    if (at === null || at === undefined) return { placeholder: '把鼠标移到曲线上，或点「播放」' };

    var axis = axisValues(lap);
    var stat = suspensionStat(lap);
    // 注意单位：服务端 CHANNEL_TABLE 已经换算过 —— load_* 是 kN、roll/pitch 是度、
    // speed 是 km/h、油门刹车是 %。这里只做「相对本圈中位数」的归一化，不再换算单位
    // （曾经在这里又除 1000/乘 180/π，画出来的载荷只有 0.00 kN、侧倾 145.9°）。
    var loads = [];
    var deflections = [];
    var frame = {
      available: true,
      loads: loads,
      base: stat.base,
      span: stat.span,
      deflections: deflections,
      roll: 0, pitch: 0, speed: null, throttle: null, brake: null,
      trail: [], frontShareDelta: 0, wheelRadius: 30
    };

    for (var c = 0; c < CORNER_CHANNELS.length; c++) {
      var load = interp(axis, lap.channels[CORNER_CHANNELS[c]].values, at);
      loads.push(load);
      deflections.push(load === null ? 0 : (load - stat.base[c]) / stat.span);
    }
    if (loads[0] === null) return { placeholder: '游标在数据范围之外' };

    var roll = interp(axis, lap.channels.roll.values, at);
    var pitch = interp(axis, lap.channels.pitch.values, at);
    frame.roll = roll === null ? 0 : roll;
    frame.pitch = pitch === null ? 0 : pitch;
    // 地形坡度与「去地形俯仰」是服务端派生通道（老服务端没有 → 取不到时退化为实测值）
    var grade = channelAvailable(lap, 'grade')
      ? interp(axis, lap.channels.grade.values, at) : null;
    var pitchRoad = channelAvailable(lap, 'pitch_road')
      ? interp(axis, lap.channels.pitch_road.values, at) : null;
    frame.grade = grade === null ? 0 : grade;
    frame.pitchRoad = pitchRoad === null ? frame.pitch : pitchRoad;

    // 几何用的倾斜：'load' 模式下为 0 —— 车角位置本来就由四轮载荷决定，再叠世界姿态就重复了
    var tiltMode = state.suspTilt || 'load';
    frame.tiltRoll = tiltMode === 'load' ? 0 : frame.roll;
    frame.tiltPitch = tiltMode === 'load' ? 0
      : (tiltMode === 'road' ? frame.pitchRoad : frame.pitch);
    frame.speed = interp(axis, lap.channels.speed.values, at);
    frame.throttle = interp(axis, lap.channels.throttle.values, at);
    frame.brake = interp(axis, lap.channels.brake.values, at);
    // 轴间转移换算成牛顿，读数才够细（kN 只到小数点后两位）
    frame.frontShareDelta = ((loads[0] + loads[1]) - (stat.base[0] + stat.base[1])) * 1000;

    // G-G 拖尾：游标往前约 1 秒
    var times = lap.channels.t.values;
    var now = interp(axis, times, at);
    if (now !== null) {
      for (var step = 12; step >= 0; step--) {
        var sampleT = now - step * 0.08;
        var gLat = interp(times, lap.channels.g_lat.values, sampleT);
        var gLon = interp(times, lap.channels.accel_lon.values, sampleT);
        if (gLat === null || gLon === null) break;
        frame.trail.push([gLat, gLon]);
      }
    }
    return frame;
  }

  function renderSuspension() {
    if (!susp) return;
    susp.setFrame(suspensionFrame());
    susp.draw();
  }

  /* ---------------- 播放（主圈，按实时秒） ---------------- */

  function primaryLap() {
    var laps = visibleLaps();
    for (var i = 0; i < laps.length; i++) {
      if (laps[i].id === state.primaryId) return laps[i];
    }
    return laps[0] || null;
  }

  function lapDuration(lap) {
    if (!lap) return 0;
    var times = lap.channels.t.values;
    return times.length ? times[times.length - 1] : 0;
  }

  function xAtTime(lap, t) {
    if (state.xMode === 'time') return t;
    return interp(lap.channels.t.values, lap.channels.dist.values, t);
  }

  /* 航向：按 sin/cos 插值，跨 ±pi 不会跳变。展开结果缓存在 channels 上（同一圈只算一次） */
  function headingAt(lap, t) {
    var channel = lap.channels.heading;
    if (!channel) return null;
    var sin = lap.channels._headingSin;
    var cos = lap.channels._headingCos;
    if (!sin) {
      var raw = channel.values;
      sin = [];
      cos = [];
      for (var i = 0; i < raw.length; i++) {
        sin.push(Math.sin(raw[i]));
        cos.push(Math.cos(raw[i]));
      }
      lap.channels._headingSin = sin;
      lap.channels._headingCos = cos;
    }
    var times = lap.channels.t.values;
    var s = interp(times, sin, t);
    var c = interp(times, cos, t);
    return (s === null || c === null) ? null : Math.atan2(s, c);
  }

  /* 最近样本下标（样本时间轴为升序） */
  function indexAt(xs, x) {
    if (!xs.length || x < xs[0] || x > xs[xs.length - 1]) return -1;
    var lo = 0;
    var hi = xs.length - 1;
    while (hi - lo > 1) {
      var mid = (lo + hi) >> 1;
      if (xs[mid] <= x) lo = mid; else hi = mid;
    }
    return (x - xs[lo] <= xs[hi] - x) ? lo : hi;
  }

  /* 行进方向（世界弧度）：用位置的前后差分算，等价于速度方向。
     记录里只有速度标量、没有速度向量，所以方向只能这样求。 */
  function trackDirAt(lap, t) {
    var times = lap.channels.t.values;
    var i = indexAt(times, t);
    if (i < 0) return null;
    var lo = Math.max(0, i - 2);
    var hi = Math.min(times.length - 1, i + 2);
    var dx = lap.channels.pos_x.values[hi] - lap.channels.pos_x.values[lo];
    var dy = lap.channels.pos_y.values[hi] - lap.channels.pos_y.values[lo];
    if (Math.abs(dx) < 1e-3 && Math.abs(dy) < 1e-3) return null;
    return Math.atan2(dy, dx);
  }

  function normalizeAngle(a) {
    while (a > Math.PI) a -= 2 * Math.PI;
    while (a < -Math.PI) a += 2 * Math.PI;
    return a;
  }

  /* 滑移角（弧度）= 车头朝向 − 行进方向；低速时方向噪声大，不显示 */
  function slipAt(lap, t) {
    if (t === null || t === undefined) return null;
    var heading = headingAt(lap, t);
    var travel = trackDirAt(lap, t);
    if (heading === null || travel === null) return null;
    var speed = interp(lap.channels.t.values, lap.channels.speed.values, t);
    if (speed !== null && speed < 8) return null;      // < 8 km/h：多半在挪车/打转
    return normalizeAngle(heading - travel);
  }

  function slipColor(slip) {
    var deg = Math.abs(slip * 180 / Math.PI);
    if (deg >= 15) return '#ef476f';
    if (deg >= 5) return '#ffd166';
    return '#48eb7e';
  }

  function updatePlayUI() {
    var lap = primaryLap();
    var duration = lapDuration(lap);
    if (!play.seeking) {
      el.playSeek.max = String(duration > 0 ? duration : 1);
      el.playSeek.value = String(Math.max(0, Math.min(play.t, duration)));
    }
    el.playSeek.disabled = duration <= 0;
    el.playTime.textContent = C.formatClock(play.t) + ' / ' + C.formatClock(duration);
    el.btnPlay.textContent = play.playing ? '⏸ 暂停' : '▶ 播放';
    el.btnPlay.classList.toggle('on', play.playing);
  }

  /* 主圈换人/被删后：把播放位置夹回合法区间，没有可播的圈就停下 */
  function syncPlayhead() {
    var lap = primaryLap();
    if (!lap) {
      stopPlayback();
      play.t = 0;
    } else {
      var duration = lapDuration(lap);
      if (play.t > duration) play.t = duration;
    }
    updatePlayUI();
  }

  /* 视图跟随：播放头撞到（用户缩放过的）视野边缘时按原跨度平移 */
  function followView(x) {
    if (!play.follow || x === null || !state.view || state.viewAuto) return;
    var span = state.view[1] - state.view[0];
    if (!(span > 1e-9)) return;
    if (x >= state.view[0] + span * 0.02 && x <= state.view[1] - span * 0.02) return;
    var x0 = x - span * 0.15;
    state.view = [x0, x0 + span];
    Object.keys(charts).forEach(function (name) { charts[name].setView(state.view); });
  }

  function applyPlayhead() {
    var lap = primaryLap();
    if (!lap) return;
    var duration = lapDuration(lap);
    if (play.t < 0) play.t = 0;
    if (play.t > duration) play.t = duration;

    var x = xAtTime(lap, play.t);
    if (x === null) x = play.t;                       // 距离轴兜底
    var times = lap.channels.t.values;
    var px = interp(times, lap.channels.pos_x.values, play.t);
    var py = interp(times, lap.channels.pos_y.values, play.t);
    var heading = headingAt(lap, play.t);
    var travel = trackDirAt(lap, play.t);

    state.cursorX = x;
    var cursor = (px === null || py === null) ? null : { x: px, y: py };
    if (cursor && heading !== null) cursor.heading = heading;
    if (cursor) {
      var scale = (map.view && map.view.scale) || 1;
      // 线长按设定米数，但保底约 55 px：地图缩得很小时也看得清朝向
      var rayLen = Math.max(play.rayLength, 55 / scale);
      var rays = [];
      if (heading !== null && play.headingRay) {
        rays.push({ angle: heading, length: rayLen, color: '#ffd166', width: 2 });
      }
      if (travel !== null && play.velocityRay) {
        rays.push({ angle: travel, length: rayLen, color: '#28d2ff', width: 1.8, dash: true });
      }
      if (rays.length) cursor.rays = rays;
      // 两条线都开且有一定速度时，画出夹角弧与度数（滑移角 = 车头朝向 − 行进方向）
      var speed = interp(times, lap.channels.speed.values, play.t);
      if (heading !== null && travel !== null && speed !== null && speed >= 8 &&
          play.headingRay && play.velocityRay) {
        var slip = normalizeAngle(heading - travel);
        cursor.arc = { from: travel, to: heading, radius: 26 / scale, color: slipColor(slip) };
        cursor.note = { text: (slip * 180 / Math.PI).toFixed(1) + '°', color: slipColor(slip) };
      }
      if (play.follow) map.followTo(px, py);   // 视野跟随车辆（轨迹图）
    }
    map.cursor = cursor;
    map.draw();
    for (var name in charts) {
      if (!charts.hasOwnProperty(name)) continue;
      charts[name].cursorX = x;
      charts[name].draw();
    }
    renderSuspension();      // 悬架示意逐帧跟随播放头（图元很少，不用节流）
    var now = window.performance.now();
    if (!play.playing || now - play.lastReadout > 60) {   // 播放中节流，避免每帧重建 DOM
      play.lastReadout = now;
      renderReadout();
    }
    followView(x);
    updatePlayUI();
  }

  function playbackTick(now) {
    if (!play.playing) return;
    var lap = primaryLap();
    var duration = lap ? lapDuration(lap) : 0;
    if (!lap || duration <= 0) { stopPlayback(); return; }
    // 现实经过的秒数 × 速率；标签页挂起后 dt 很大，夹到 0.25s 防跳
    var dt = Math.max(0, Math.min(0.25, (now - play.lastFrame) / 1000));
    play.lastFrame = now;
    play.t += dt * play.rate;
    if (play.t >= duration) {
      if (play.loop) {
        play.t = play.t % duration;
      } else {
        play.t = duration;
        stopPlayback();
        applyPlayhead();
        return;
      }
    }
    applyPlayhead();
    window.requestAnimationFrame(playbackTick);
  }

  function startPlayback() {
    var lap = primaryLap();
    if (!lap) {
      state.message = '先在左侧勾选一圈，再点播放';
      renderSidebar();
      return;
    }
    var duration = lapDuration(lap);
    if (duration <= 0) return;
    if (play.t >= duration - 1e-6) play.t = 0;
    play.playing = true;
    play.lastFrame = window.performance.now();
    play.lastReadout = 0;
    updatePlayUI();
    window.requestAnimationFrame(playbackTick);
  }

  function stopPlayback() {
    if (!play.playing) {
      updatePlayUI();
      return;
    }
    play.playing = false;
    updatePlayUI();
  }

  function togglePlayback() {
    if (play.playing) stopPlayback(); else startPlayback();
  }

  function seekPlayhead() {
    play.lastFrame = window.performance.now();
    applyPlayhead();
  }

  /* 改了指引线开关/长度后立刻重画播放头（没动过播放头就不用管） */
  function refreshPlayhead() {
    if (playheadActive()) applyPlayhead();
  }

  function onPlayKeydown(event) {
    var tag = ((event.target && event.target.tagName) || '').toUpperCase();
    if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return;
    if (event.code === 'Space' || event.key === ' ') {
      event.preventDefault();
      togglePlayback();
      return;
    }
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault();
      play.t += (event.key === 'ArrowLeft' ? -1 : 1) * (event.shiftKey ? 5 : 1);
      seekPlayhead();
    }
  }

  /* ---------------- 删除记录 ---------------- */

  function forgetLap(ghostId) {
    var index = state.visible.indexOf(ghostId);
    if (index !== -1) state.visible.splice(index, 1);
    delete state.store[key(state.sel.group, state.sel.level, state.sel.id, ghostId)];
    suspStatCache = {};
    state.laps = state.laps.filter(function (lap) { return lap.id !== ghostId; });
    if (state.primaryId === ghostId) {
      stopPlayback();
      play.t = 0;
      state.primaryId = state.visible[0] || null;
    }
    // 主圈被删光时自动改看剩余最快圈
    if (!state.primaryId && state.laps.length) {
      var fastest = fastestLap(state.laps);
      if (fastest) makeVisible(fastest.id, true);
    }
  }

  function deleteLap(ghostId) {
    if (!state.sel) return;
    var lap = findLap(ghostId) || { id: ghostId };
    var lines = [
      '确定删除这条圈速记录吗？',
      '',
      '名称：' + (lap.label || ghostId),
      '圈速：' + (lap.lapTime ? C.formatClock(lap.lapTime)
        : (lap.duration ? '未完成 · 约 ' + lap.duration.toFixed(2) + ' 秒' : '—')),
      '类型：' + (lap.orphan ? '清单外样本（只删样本文件）' : '圈速库记录（同步更新清单）'),
      lap.pinned ? '注意：该圈在游戏内已置顶，游戏会拒绝删除，本查看器仍会删除。' : null,
      '',
      '样本文件会先移入 lapLogs/_trash/ 回收站，可手工恢复；',
      '若游戏正在运行且已加载该起点，游戏可能按内存状态回写，请先退出游戏。'
    ].filter(function (line) { return line !== null; });
    if (!window.confirm(lines.join('\n'))) return;

    var startPath = [state.sel.group, state.sel.level, state.sel.id].join('/');
    state.message = '正在删除 ' + (lap.label || ghostId) + ' …';
    renderSidebar();
    api('/api/delete?start=' + encodeURIComponent(startPath) + '&id=' + encodeURIComponent(ghostId),
        { method: 'POST' })
      .then(function (result) {
        forgetLap(ghostId);
        var tail = (result.remaining === null || result.remaining === undefined)
          ? '' : '；该起点还剩 ' + result.remaining + ' 条';
        var note = '已删除 ' + (result.label || ghostId) + '（' +
          (result.scope === 'orphan' ? '清单外样本' : '库内记录') + '已移入 _trash' + tail + '）';
        // loadCatalog 会先写"读取存档目录…"再清空提示，所以删除结果要等它完成后再落笔
        return loadCatalog().then(function () {
          state.message = note;
          renderAll();
        });
      })
      .catch(function (error) {
        state.message = '删除失败：' + error.message;
        renderSidebar();
      });
  }

  /* ---------------- 启动 ---------------- */

  function bindControls() {
    $('suspTilt').addEventListener('change', function () {
      state.suspTilt = this.value;
      renderSuspension();
    });
    $('suspScale').addEventListener('change', function () {
      if (!susp) return;
      susp.setScale(this.value);
      susp.draw();
    });
    $('suspFlip').addEventListener('change', function () {
      if (!susp) return;
      susp.setFlip(this.checked);
      susp.draw();
    });
    $('btnRescan').addEventListener('click', function () {
      api('/api/rescan', { method: 'POST' }).then(function () {
        stopPlayback();
        play.t = 0;
        state.store = {};
        suspStatCache = {};
        state.laps = [];
        state.visible = [];
        state.primaryId = null;
        state.view = null;
        state.mapFit = true;
        state.sel = null;
        loadCatalog();
      });
    });
    el.btnPlay.addEventListener('click', togglePlayback);
    el.btnRewind.addEventListener('click', function () {
      play.t = 0;
      stopPlayback();
      seekPlayhead();
    });
    el.playRate.addEventListener('change', function () {
      play.rate = parseFloat(this.value) || 1;
    });
    el.playFollow.addEventListener('change', function () { play.follow = this.checked; });
    el.playLoop.addEventListener('change', function () { play.loop = this.checked; });
    el.rayHeading.addEventListener('change', function () { play.headingRay = this.checked; refreshPlayhead(); });
    el.rayTravel.addEventListener('change', function () { play.velocityRay = this.checked; refreshPlayhead(); });
    el.rayLength.addEventListener('change', function () {
      play.rayLength = parseFloat(this.value) || 40;
      refreshPlayhead();
    });
    el.playSeek.addEventListener('pointerdown', function () { play.seeking = true; });
    el.playSeek.addEventListener('input', function () {
      play.t = parseFloat(this.value) || 0;
      seekPlayhead();
    });
    window.addEventListener('pointerup', function () {
      if (!play.seeking) return;
      play.seeking = false;
      updatePlayUI();
    });
    window.addEventListener('keydown', onPlayKeydown);
    $('btnFit').addEventListener('click', function () {
      state.view = null;
      state.viewAuto = true;
      updateRangeFromData(true);
      map.fitToData();
      renderAll();
    });
    $('xMode').addEventListener('change', function () {
      state.xMode = this.value;
      state.view = null;
      state.viewAuto = true;
      updateRangeFromData(true);
      renderAll();
    });
    $('colorMode').addEventListener('change', function () {
      state.colorMode = this.value;
      renderAll();
    });
    // 平衡图的样本口径（速度段 / 剔除异常）：只影响这张图，不碰曲线，所以不整页重画
    $('balBand').addEventListener('change', function () {
      state.balance.band = this.value;
      renderBalance(visibleLaps());
    });
    $('balClean').addEventListener('change', function () {
      state.balance.clean = this.checked;
      renderBalance(visibleLaps());
    });
    // 转向符号翻转要同时影响转向曲线、读数与平衡图
    $('balFlip').addEventListener('change', function () {
      state.balance.flip = this.checked;
      renderAll();
    });
  }

  function boot() {
    el.catalog = $('catalog');
    el.readout = $('readout');
    el.summary = $('summary');
    el.rootInfo = $('rootInfo');
    el.btnPlay = $('btnPlay');
    el.btnRewind = $('btnRewind');
    el.playSeek = $('playSeek');
    el.playTime = $('playTime');
    el.playRate = $('playRate');
    el.playFollow = $('playFollow');
    el.playLoop = $('playLoop');
    el.rayHeading = $('rayHeading');
    el.rayTravel = $('rayTravel');
    el.rayLength = $('rayLength');
    el.balanceNote = $('balanceNote');

    charts.speed = new C.LineChart($('ch-speed'));
    charts.pedals = new C.LineChart($('ch-pedals'));
    charts.gear = new C.LineChart($('ch-gear'));
    charts.gforce = new C.LineChart($('ch-gforce'));
    charts.steering = new C.LineChart($('ch-steering'));
    charts.loads = new C.LineChart($('ch-loads'));
    charts.attitude = new C.LineChart($('ch-attitude'));
    charts.delta = new C.LineChart($('ch-delta'));
    charts.delta.zeroLine = true;    // ΔT = 0（打平最快圈）的基线画重一档
    map = new C.TrackMap($('map'));
    susp = new window.SuspensionView($('ch-suspension'));
    balance = new window.LapBalance.BalanceView($('ch-balance'));

    Object.keys(charts).forEach(function (name) {
      charts[name].onCursor = function (x) {
        if (!play.playing) setCursor(x);
      };
      charts[name].onZoom = function (x0, x1) {
        state.view = [x0, x1];
        state.viewAuto = false;   // 用户手动缩放后，勾选新圈不再抢走视野
        renderViews();
      };
    });
    map.onTrackCursor = onMapHover;

    bindControls();

    window.addEventListener('resize', function () {
      if (map) { map.draw(); }
      if (susp) { susp.draw(); }
      if (balance) { balance.draw(); }
      Object.keys(charts).forEach(function (name) { charts[name].draw(); });
    });

    loadCatalog().then(function () {
      var catalog = state.catalog;
      if (catalog && el.rootInfo) {
        el.rootInfo.textContent = '数据目录：' + catalog.root;
        if (catalog.code !== SERVER_CODE) {
          el.rootInfo.style.color = 'var(--bad)';
          el.rootInfo.textContent += '  ⚠ 查看器服务端代码是旧的：请关掉正在运行的查看器窗口，' +
            '重新运行「一键启动查看器.bat」（否则新曲线不会显示）';
          console.warn('LapLog 查看器：服务端 code=' + catalog.code +
            '，前端期望 ' + SERVER_CODE + ' —— 需要重启查看器');
        }
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
