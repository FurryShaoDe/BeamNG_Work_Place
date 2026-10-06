/* LapLog 查看器 —— 画图基元（自绘 canvas，零第三方依赖）
 *
 * 三个原则（沿用 flintt 的实测做法）：
 *   1. 静态层 / 游标层分离：曲线与轨迹画进离屏 canvas，鼠标移动时只重画游标层，
 *      所以拖动游标不会重算整条折线。
 *   2. 静态层缓存：只有数据/缩放/画布尺寸变化（_staticDirty）时才重画离屏层。
 *      轨迹图更进一步：离屏层比画布大一圈（TRACK_PAD），平移视野时直接搬像素，
 *      所以「视野跟随车辆」和拖动地图都是每帧可负担的。播放时每帧只重画游标层。
 *   3. DPR 安全：只有当 CSS 尺寸真的变化时才改 canvas.width/height，
 *      否则每次 draw 都会按 dpr 再乘一遍，画布尺寸指数膨胀。
 */
(function (global) {
  'use strict';

  var PALETTE = {
    orange: '#ff7018', cyan: '#28d2ff', green: '#48eb7e',
    magenta: '#eb50ff', white: '#f5f5f5'
  };
  var LAP_COLORS = [
    PALETTE.orange, PALETTE.cyan, PALETTE.green, PALETTE.magenta, PALETTE.white,
    '#ffd166', '#06d6a0', '#ef476f', '#118ab2', '#c77dff'
  ];

  function dpr() {
    return window.devicePixelRatio || 1;
  }

  function clamp(value, lo, hi) {
    return value < lo ? lo : (value > hi ? hi : value);
  }

  function lerp(a, b, t) {
    return a + (b - a) * t;
  }

  /* 按需设置 canvas 的像素尺寸，返回 CSS 尺寸下的绘图上下文 */
  function fitCanvas(canvas) {
    var rect = canvas.getBoundingClientRect();
    var width = Math.max(1, Math.round(rect.width));
    var height = Math.max(1, Math.round(rect.height));
    var scale = dpr();
    var pxWidth = Math.round(width * scale);
    var pxHeight = Math.round(height * scale);
    if (canvas.width !== pxWidth) canvas.width = pxWidth;
    if (canvas.height !== pxHeight) canvas.height = pxHeight;
    var ctx = canvas.getContext('2d');
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    return { ctx: ctx, width: width, height: height };
  }

  function niceTicks(min, max, target) {
    if (!isFinite(min) || !isFinite(max) || max <= min) return [min];
    var span = max - min;
    var step = Math.pow(10, Math.floor(Math.log10(span / target)));
    var candidates = [1, 2, 2.5, 5, 10];
    for (var i = 0; i < candidates.length; i++) {
      if (span / (step * candidates[i]) <= target * 1.5) { step *= candidates[i]; break; }
    }
    var ticks = [];
    for (var v = Math.ceil(min / step) * step; v <= max + step * 1e-6; v += step) {
      ticks.push(Math.abs(v) < step * 1e-6 ? 0 : v);
    }
    return ticks;
  }

  /* 速度色标：蓝 → 青 → 绿 → 黄 → 红 */
  var SPEED_STOPS = [
    [0.00, [40, 120, 255]], [0.30, [40, 210, 255]], [0.55, [72, 235, 126]],
    [0.80, [255, 210, 60]], [1.00, [255, 60, 40]]
  ];

  function speedColor(t) {
    t = clamp(t, 0, 1);
    for (var i = 1; i < SPEED_STOPS.length; i++) {
      if (t <= SPEED_STOPS[i][0]) {
        var lo = SPEED_STOPS[i - 1];
        var hi = SPEED_STOPS[i];
        var f = (t - lo[0]) / (hi[0] - lo[0]);
        return 'rgb(' + Math.round(lerp(lo[1][0], hi[1][0], f)) + ','
          + Math.round(lerp(lo[1][1], hi[1][1], f)) + ','
          + Math.round(lerp(lo[1][2], hi[1][2], f)) + ')';
      }
    }
    return 'rgb(255,60,40)';
  }

  /* 油门/刹车色：红=刹车，绿=油门，琥珀=同时，白=滑行（亮度随力度） */
  function inputColor(throttle, brake) {
    var t = clamp(throttle || 0, 0, 1);
    var b = clamp(brake || 0, 0, 1);
    var strong = Math.max(t, b);
    if (b > 0.05 && t > 0.05) {
      return 'rgb(' + Math.round(150 + 105 * strong) + ',' + Math.round(150 * (1 - b) + 40) + ',40)';
    }
    if (b > 0.05) {
      return 'rgb(' + Math.round(90 + 165 * b) + ',' + Math.round(50 * (1 - b) + 20) + ',40)';
    }
    if (t > 0.05) {
      return 'rgb(' + Math.round(60 * (1 - t) + 30) + ',' + Math.round(110 + 145 * t) + ',80)';
    }
    return 'rgb(215,215,215)';
  }

  var GEAR_COLORS = ['#8a8a8a', '#4f9dff', '#28d2ff', '#48eb7e', '#ffd166',
                     '#ff9f1c', '#ff7018', '#eb50ff', '#ef476f', '#c77dff'];

  function gearColor(gear) {
    var g = Math.round(gear || 0);
    if (g < 0) return '#ff4d4d';
    return GEAR_COLORS[Math.min(g, GEAR_COLORS.length - 1)];
  }

  function formatValue(value, unit) {
    if (value === null || value === undefined || !isFinite(value)) return '—';
    var abs = Math.abs(value);
    var digits = abs >= 100 ? 0 : (abs >= 10 ? 1 : 2);
    return value.toFixed(digits) + (unit ? ' ' + unit : '');
  }

  function formatClock(seconds) {
    if (!isFinite(seconds)) return '—';
    var sign = seconds < 0 ? '-' : '';
    seconds = Math.abs(seconds);
    var minutes = Math.floor(seconds / 60);
    var rest = seconds - minutes * 60;
    return sign + minutes + ':' + (rest < 10 ? '0' : '') + rest.toFixed(3);
  }

  /* ------------------------------------------------------------------ */
  /* 折线图：多序列叠加 + 共享游标                                        */
  /* ------------------------------------------------------------------ */
  var MARGIN = { left: 58, right: 14, top: 12, bottom: 24 };

  function LineChart(canvas) {
    this.canvas = canvas;
    this.back = document.createElement('canvas');
    this.series = [];          // [{id,label,unit,color,x:[],y:[]}]
    this.view = null;          // {x0,x1}
    this.yRange = null;        // [min,max]
    this.xUnit = 's';
    this.cursorX = null;
    this.emptyText = '';      // 空态提示（setEmpty 设置；为空则照常画坐标系）
    this.zeroLine = false;    // 是否把 0 基线画得比普通网格重（ΔT 图用）
    this.cursorMap = null;    // 全局游标 → 本图 x 轴的换算（ΔT 图用，见 _cursorValue）
    this.onCursor = null;
    this.onZoom = null;
    this._drag = null;
    this._staticDirty = true;
    this._staticWidth = 0;
    this._staticHeight = 0;
    this._bind();
  }

  LineChart.prototype._px = function (width) {
    return { x0: MARGIN.left, x1: Math.max(MARGIN.left + 10, width - MARGIN.right) };
  };

  LineChart.prototype._scales = function (width, height) {
    var px = this._px(width);
    var view = this.view || [0, 1];
    var yRange = this.yRange || [0, 1];
    var self = this;
    return {
      xToPx: function (x) {
        return px.x0 + (x - view[0]) / Math.max(1e-9, view[1] - view[0]) * (px.x1 - px.x0);
      },
      pxToX: function (p) {
        return view[0] + (p - px.x0) / Math.max(1e-9, px.x1 - px.x0) * (view[1] - view[0]);
      },
      yToPx: function (y) {
        var top = MARGIN.top;
        var bottom = Math.max(MARGIN.top + 10, height - MARGIN.bottom);
        return bottom - (y - yRange[0]) / Math.max(1e-9, yRange[1] - yRange[0]) * (bottom - top);
      },
      px: px
    };
  };

  LineChart.prototype._bind = function () {
    var self = this;
    var canvas = this.canvas;

    canvas.addEventListener('mousemove', function (event) {
      var rect = canvas.getBoundingClientRect();
      var fit = { width: rect.width };
      var scales = self._scales(rect.width, rect.height);
      var dataX = scales.pxToX(event.clientX - rect.left);
      if (self._drag) {
        var delta = (event.clientX - self._drag.x) / Math.max(1, scales.px.x1 - scales.px.x0)
          * (self.view[1] - self.view[0]);
        if (self.onZoom) self.onZoom(self._drag.view0 - delta, self._drag.view1 - delta);
        return;
      }
      if (self.onCursor) self.onCursor(dataX);
    });

    canvas.addEventListener('mouseleave', function () {
      self._drag = null;
      if (self.onCursor) self.onCursor(null);
    });

    canvas.addEventListener('mousedown', function (event) {
      if (!self.view) return;
      self._drag = { x: event.clientX, view0: self.view[0], view1: self.view[1] };
      event.preventDefault();
    });

    window.addEventListener('mouseup', function () { self._drag = null; });

    canvas.addEventListener('wheel', function (event) {
      if (!self.view || !self.onZoom) return;
      var rect = canvas.getBoundingClientRect();
      var scales = self._scales(rect.width, rect.height);
      var at = scales.pxToX(event.clientX - rect.left);
      var factor = event.deltaY > 0 ? 1.18 : 1 / 1.18;
      var x0 = at - (at - self.view[0]) * factor;
      var x1 = at + (self.view[1] - at) * factor;
      if (x1 - x0 < 1e-3) return;
      self.onZoom(x0, x1);
      event.preventDefault();
    }, { passive: false });
  };

  LineChart.prototype.setData = function (series, view, yRange, xUnit) {
    this.series = series || [];
    this.view = view;
    this.yRange = yRange;
    this.xUnit = xUnit || 's';
    this.emptyText = '';
    this._staticDirty = true;
    this.draw();
  };

  /* 空态：不画坐标系，只在画布中央给一句提示。
     起因：ΔT 图在没有可用数据时画的是 [0,1]×[-1,1] 的默认坐标系，
     x 轴看上去像「0.00–1.00 米」的比例尺，容易被当成坏图。 */
  LineChart.prototype.setEmpty = function (text) {
    this.emptyText = text || '没有可显示的数据';
    this.series = [];
    this.view = null;
    this.yRange = null;
    this._staticDirty = true;
    this.draw();
  };

  /* 只改视野（播放跟随时平移）而不重建序列：标记静态层脏后重画 */
  LineChart.prototype.setView = function (view) {
    this.view = view;
    this._staticDirty = true;
    this.draw();
  };

  LineChart.prototype.draw = function () {
    var fit = fitCanvas(this.canvas);
    fit.ctx.clearRect(0, 0, fit.width, fit.height);
    if (!this.series.length && this.emptyText) {
      fit.ctx.fillStyle = '#837f5e';
      fit.ctx.font = '13px "Segoe UI", "Microsoft YaHei", sans-serif';
      fit.ctx.textAlign = 'center';
      fit.ctx.textBaseline = 'middle';
      fit.ctx.fillText(this.emptyText, fit.width / 2, fit.height / 2);
      return;
    }
    var back = this.back;
    var sizeChanged = back.width !== this.canvas.width || back.height !== this.canvas.height;
    if (sizeChanged) {
      back.width = this.canvas.width;
      back.height = this.canvas.height;
    }
    if (sizeChanged || this._staticDirty ||
        this._staticWidth !== fit.width || this._staticHeight !== fit.height) {
      var bctx = back.getContext('2d');
      bctx.setTransform(dpr(), 0, 0, dpr(), 0, 0);
      bctx.clearRect(0, 0, fit.width, fit.height);
      this._drawStatic(bctx, fit.width, fit.height);
      this._staticDirty = false;
      this._staticWidth = fit.width;
      this._staticHeight = fit.height;
    }
    fit.ctx.clearRect(0, 0, fit.width, fit.height);
    fit.ctx.drawImage(back, 0, 0, fit.width, fit.height);
    this._drawCursor(fit.ctx, fit.width, fit.height);
  };

  LineChart.prototype._drawStatic = function (ctx, width, height) {
    var scales = this._scales(width, height);
    var px = scales.px;
    var view = this.view || [0, 1];
    var yRange = this.yRange || [0, 1];

    ctx.font = '11px Consolas, monospace';
    ctx.textBaseline = 'middle';

    // 横向网格 + y 轴刻度
    var yTicks = niceTicks(yRange[0], yRange[1], 4);
    ctx.strokeStyle = 'rgba(219,216,193,0.08)';
    ctx.fillStyle = 'rgba(179,185,132,0.85)';
    ctx.lineWidth = 1;
    ctx.textAlign = 'right';
    for (var i = 0; i < yTicks.length; i++) {
      var y = scales.yToPx(yTicks[i]);
      if (y < MARGIN.top - 1 || y > height - MARGIN.bottom + 1) continue;
      ctx.beginPath();
      ctx.moveTo(px.x0, Math.round(y) + 0.5);
      ctx.lineTo(px.x1, Math.round(y) + 0.5);
      ctx.stroke();
      ctx.fillText(String(+yTicks[i].toFixed(3)), px.x0 - 6, y);
    }

    // 零基线（ΔT 图用）：0 是「与最快圈打平」，比普通网格重一档，正负一眼可分
    if (this.zeroLine && yRange[0] < 0 && yRange[1] > 0) {
      var zeroY = scales.yToPx(0);
      ctx.strokeStyle = 'rgba(219,216,193,0.32)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(px.x0, Math.round(zeroY) + 0.5);
      ctx.lineTo(px.x1, Math.round(zeroY) + 0.5);
      ctx.stroke();
    }

    // 纵向网格 + x 轴刻度
    var xTicks = niceTicks(view[0], view[1], 6);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    for (var j = 0; j < xTicks.length; j++) {
      var x = scales.xToPx(xTicks[j]);
      if (x < px.x0 - 1 || x > px.x1 + 1) continue;
      ctx.strokeStyle = 'rgba(219,216,193,0.05)';
      ctx.beginPath();
      ctx.moveTo(Math.round(x) + 0.5, MARGIN.top);
      ctx.lineTo(Math.round(x) + 0.5, height - MARGIN.bottom);
      ctx.stroke();
      ctx.fillStyle = 'rgba(179,185,132,0.75)';
      var digits = (view[1] - view[0]) > 60 ? 0 : 2;
      ctx.fillText(xTicks[j].toFixed(digits), x, height - MARGIN.bottom + 5);
    }

    // 坐标轴边框
    ctx.strokeStyle = 'rgba(219,216,193,0.18)';
    ctx.beginPath();
    ctx.moveTo(px.x0 + 0.5, MARGIN.top);
    ctx.lineTo(px.x0 + 0.5, height - MARGIN.bottom + 0.5);
    ctx.lineTo(px.x1, height - MARGIN.bottom + 0.5);
    ctx.stroke();

    // 曲线（逐序列裁剪到视野）
    ctx.save();
    ctx.beginPath();
    ctx.rect(px.x0, MARGIN.top, px.x1 - px.x0, height - MARGIN.top - MARGIN.bottom);
    ctx.clip();
    for (var s = 0; s < this.series.length; s++) {
      var line = this.series[s];
      if (!line.x || line.x.length < 2) continue;
      ctx.strokeStyle = line.color;
      ctx.lineWidth = line.width || 1.6;
      // dash 可以是 true（默认虚线）或一个数组（自定义虚线样式，如四轮载荷）
      if (Array.isArray(line.dash)) ctx.setLineDash(line.dash);
      else if (line.dash) ctx.setLineDash([5, 4]);
      else ctx.setLineDash([]);
      ctx.beginPath();
      var started = false;
      for (var k = 0; k < line.x.length; k++) {
        var cx = line.x[k];
        if (cx < view[0] - (view[1] - view[0]) * 0.02) continue;
        if (cx > view[1] + (view[1] - view[0]) * 0.02) break;
        var sx = scales.xToPx(cx);
        var sy = scales.yToPx(line.y[k]);
        if (!started) { ctx.moveTo(sx, sy); started = true; } else { ctx.lineTo(sx, sy); }
      }
      if (started) ctx.stroke();
    }
    ctx.restore();

    // 单位提示
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillStyle = 'rgba(131,127,94,0.9)';
    ctx.fillText(this.xUnit, px.x1 - 18, height - MARGIN.bottom + 5);
  };

  /* 游标位置的换算：有些图的 x 轴与全局游标不是同一个量（ΔT 图恒为距离轴，
     而游标在「时间」模式下是秒），由 cursorMap 负责换算；换算不了（超出范围）返回 null。 */
  LineChart.prototype._cursorValue = function () {
    var x = this.cursorX;
    if (x === null || x === undefined) return null;
    if (this.cursorMap) x = this.cursorMap(x);
    return (x === null || x === undefined) ? null : x;
  };

  LineChart.prototype._drawCursor = function (ctx, width, height) {
    var cursorX = this._cursorValue();
    if (cursorX === null) return;
    var scales = this._scales(width, height);
    var px = scales.px;
    var x = scales.xToPx(cursorX);
    if (x < px.x0 || x > px.x1) return;
    ctx.strokeStyle = 'rgba(219,216,193,0.55)';
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 3]);
    ctx.beginPath();
    ctx.moveTo(Math.round(x) + 0.5, MARGIN.top);
    ctx.lineTo(Math.round(x) + 0.5, height - MARGIN.bottom);
    ctx.stroke();
    ctx.setLineDash([]);

    for (var s = 0; s < this.series.length; s++) {
      var line = this.series[s];
      var y = this._valueAt(line, cursorX);
      if (y === null) continue;
      ctx.fillStyle = line.color;
      ctx.beginPath();
      ctx.arc(x, scales.yToPx(y), 3, 0, Math.PI * 2);
      ctx.fill();
    }
  };

  /* 在序列上按 x 线性插值取值 */
  LineChart.prototype._valueAt = function (line, x) {
    var xs = line.x;
    if (!xs || xs.length < 2) return null;
    var lo = 0;
    var hi = xs.length - 1;
    if (x < xs[0] || x > xs[hi]) return null;
    while (hi - lo > 1) {
      var mid = (lo + hi) >> 1;
      if (xs[mid] <= x) lo = mid; else hi = mid;
    }
    var span = xs[hi] - xs[lo];
    if (span <= 1e-9) return line.y[lo];
    var f = (x - xs[lo]) / span;
    return lerp(line.y[lo], line.y[hi], f);
  };

  /* ------------------------------------------------------------------ */
  /* 轨迹图：多圈折线 + 起点/终点门 + 游标位置                            */
  /* ------------------------------------------------------------------ */
  /* 静态层在画布四周多画 35%：平移视野时先搬像素（drawImage），只有超出这一圈才重画。
     视野跟随 / 拖动地图因此几乎零成本，轨迹仍按同一比例投影，不会变形。 */
  var TRACK_PAD = 0.35;

  function TrackMap(canvas) {
    this.canvas = canvas;
    this.back = document.createElement('canvas');
    this.lines = [];        // [{id,color,width,points:[[x,y,z]...],segColors:[...]|null}]
    this.gates = [];        // [{color,center:[x,y],normal:[x,y],halfWidth}]
    /* 游标：{x,y,heading?,rays?,arc?,note?}
       heading = 车头朝向（世界弧度，屏幕上画成箭头）
       rays    = [{angle,length,color,width,dash}] 从车位置出发的指引线（长度单位：米）
       arc     = {from,to,radius,color}  两条线之间的夹角弧（半径单位：米）
       note    = {text,color}            画在车旁的角度读数 */
    this.cursor = null;
    this.view = null;       // {cx,cy,scale}
    this.onCursor = null;
    this.onTrackCursor = null;
    this._drag = null;
    this._staticDirty = true;
    this._staticView = null;   // 渲染静态层时用的视野
    this._bind();
  }

  TrackMap.prototype._bind = function () {
    var self = this;
    var canvas = this.canvas;

    /* 屏幕像素 → 世界坐标。x/y 用同一个 px/米 比例，轨迹不会被拉变形。 */
    function project(event) {
      var rect = canvas.getBoundingClientRect();
      var view = self.view;
      if (!view) return null;
      return {
        x: view.cx + (event.clientX - rect.left - rect.width / 2) / view.scale,
        y: view.cy - (event.clientY - rect.top - rect.height / 2) / view.scale
      };
    }

    canvas.addEventListener('mousedown', function (event) {
      self._drag = { x: event.clientX, y: event.clientY };
      event.preventDefault();
    });

    canvas.addEventListener('mousemove', function (event) {
      if (self._drag && self.view) {
        self.view.cx -= (event.clientX - self._drag.x) / self.view.scale;
        self.view.cy += (event.clientY - self._drag.y) / self.view.scale;
        self._drag = { x: event.clientX, y: event.clientY };
        self.draw();       // 静态层缓存够用就只搬像素，不必重画轨迹
        return;
      }
      var at = project(event);
      if (at && self.onTrackCursor) self.onTrackCursor(at.x, at.y);
    });

    canvas.addEventListener('mouseleave', function () {
      self._drag = null;
      if (self.onTrackCursor) self.onTrackCursor(null, null);
    });

    window.addEventListener('mouseup', function () { self._drag = null; });

    canvas.addEventListener('wheel', function (event) {
      if (!self.view) return;
      var at = project(event);
      if (!at) return;
      self.view.scale *= event.deltaY > 0 ? 1 / 1.2 : 1.2;
      var rect = canvas.getBoundingClientRect();
      self.view.cx = at.x - (event.clientX - rect.left - rect.width / 2) / self.view.scale;
      self.view.cy = at.y + (event.clientY - rect.top - rect.height / 2) / self.view.scale;
      self._staticDirty = true;
      self.draw();
      event.preventDefault();
    }, { passive: false });
  };

  /* keepView = true 时保留当前缩放/平移（重绘数据不该丢掉用户的视野与跟随状态） */
  TrackMap.prototype.setData = function (lines, gates, keepView) {
    this.lines = lines || [];
    this.gates = gates || [];
    if (!keepView || !this.view) this.fitToData();
    this._staticDirty = true;
    this.draw();
  };

  TrackMap.prototype.fitToData = function () {
    var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (var i = 0; i < this.lines.length; i++) {
      var points = this.lines[i].points;
      for (var k = 0; k < points.length; k++) {
        if (points[k][0] < minX) minX = points[k][0];
        if (points[k][0] > maxX) maxX = points[k][0];
        if (points[k][1] < minY) minY = points[k][1];
        if (points[k][1] > maxY) maxY = points[k][1];
      }
    }
    if (!isFinite(minX) || maxX - minX < 1e-6) return;
    var rect = this.canvas.getBoundingClientRect();
    var pad = 1.12;
    var scale = Math.min(rect.width / ((maxX - minX) * pad), rect.height / ((maxY - minY) * pad || 1));
    this.view = {
      cx: (minX + maxX) / 2,
      cy: (minY + maxY) / 2,
      scale: scale > 0 ? scale : 1
    };
    this._staticDirty = true;
  };

  TrackMap.prototype._projectWith = function (view, width, height) {
    view = view || { cx: 0, cy: 0, scale: 1 };
    return {
      toPx: function (x, y) {
        return [width / 2 + (x - view.cx) * view.scale,
                height / 2 - (y - view.cy) * view.scale];
      }
    };
  };

  TrackMap.prototype._project = function (width, height) {
    return this._projectWith(this.view, width, height);
  };

  /* 视野跟随：车在视野中央 40% 的区域内不动视野，越出边界才平移。
     死区不能太大（全览时必须也能看出镜头在跟着车走），也不能太小（否则画面一直在抖）。 */
  TrackMap.prototype.followTo = function (x, y) {
    if (!this.view) return;
    var rect = this.canvas.getBoundingClientRect();
    var limitX = rect.width / 2 / this.view.scale * 0.4;
    var limitY = rect.height / 2 / this.view.scale * 0.4;
    var dx = x - this.view.cx;
    var dy = y - this.view.cy;
    if (dx > limitX) this.view.cx = x - limitX;
    else if (dx < -limitX) this.view.cx = x + limitX;
    if (dy > limitY) this.view.cy = y - limitY;
    else if (dy < -limitY) this.view.cy = y + limitY;
  };

  TrackMap.prototype.draw = function () {
    var fit = fitCanvas(this.canvas);
    var view = this.view || { cx: 0, cy: 0, scale: 1 };
    var padX = fit.width * TRACK_PAD;
    var padY = fit.height * TRACK_PAD;
    var cssW = fit.width + padX * 2;
    var cssH = fit.height + padY * 2;
    var back = this.back;
    var pxW = Math.round(cssW * dpr());
    var pxH = Math.round(cssH * dpr());
    var resized = back.width !== pxW || back.height !== pxH;
    if (resized) {
      back.width = pxW;
      back.height = pxH;
    }

    var staticView = this._staticView;
    var stale = resized || this._staticDirty || !staticView ||
      staticView.scale !== view.scale ||
      Math.abs((staticView.cx - view.cx) * view.scale) > padX * 0.98 ||
      Math.abs((view.cy - staticView.cy) * view.scale) > padY * 0.98;
    if (stale) {
      this._staticView = { cx: view.cx, cy: view.cy, scale: view.scale };
      var bctx = back.getContext('2d');
      bctx.setTransform(dpr(), 0, 0, dpr(), 0, 0);
      bctx.clearRect(0, 0, cssW, cssH);
      bctx.save();
      bctx.translate(padX, padY);
      this._drawStatic(bctx, fit.width, fit.height);
      bctx.restore();
      this._staticDirty = false;
    }

    // 静态层按 _staticView 渲染，这里把它的原点挪到当前视野对应的位置（纯像素搬运）
    var sv = this._staticView;
    var ox = (sv.cx - view.cx) * view.scale - padX;
    var oy = (view.cy - sv.cy) * view.scale - padY;
    fit.ctx.clearRect(0, 0, fit.width, fit.height);
    fit.ctx.drawImage(back, ox, oy, cssW, cssH);
    this._drawCursor(fit.ctx, fit.width, fit.height);
  };

  TrackMap.prototype._drawStatic = function (ctx, width, height) {
    var proj = this._project(width, height);
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    for (var i = 0; i < this.gates.length; i++) {
      var gate = this.gates[i];
      var a = proj.toPx(gate.center[0] - gate.normal[0] * gate.halfWidth,
                        gate.center[1] - gate.normal[1] * gate.halfWidth);
      var b = proj.toPx(gate.center[0] + gate.normal[0] * gate.halfWidth,
                        gate.center[1] + gate.normal[1] * gate.halfWidth);
      ctx.strokeStyle = gate.color;
      ctx.lineWidth = 2;
      ctx.setLineDash([6, 4]);
      ctx.beginPath();
      ctx.moveTo(a[0], a[1]);
      ctx.lineTo(b[0], b[1]);
      ctx.stroke();
      ctx.setLineDash([]);
    }

    for (var s = 0; s < this.lines.length; s++) {
      var line = this.lines[s];
      if (!line.points || line.points.length < 2) continue;
      if (line.segColors) {
        // 逐段着色（速度 / 油门刹车 / 档位）
        for (var k = 1; k < line.points.length; k++) {
          var p0 = proj.toPx(line.points[k - 1][0], line.points[k - 1][1]);
          var p1 = proj.toPx(line.points[k][0], line.points[k][1]);
          ctx.strokeStyle = line.segColors[k];
          ctx.lineWidth = line.width || 3;
          ctx.beginPath();
          ctx.moveTo(p0[0], p0[1]);
          ctx.lineTo(p1[0], p1[1]);
          ctx.stroke();
        }
      } else {
        ctx.strokeStyle = line.color;
        ctx.lineWidth = line.width || 2.5;
        ctx.beginPath();
        for (var j = 0; j < line.points.length; j++) {
          var p = proj.toPx(line.points[j][0], line.points[j][1]);
          if (j === 0) ctx.moveTo(p[0], p[1]); else ctx.lineTo(p[0], p[1]);
        }
        ctx.stroke();
      }
    }
  };

  TrackMap.prototype._drawCursor = function (ctx, width, height) {
    if (!this.cursor) return;
    var proj = this._project(width, height);
    var carX = this.cursor.x;
    var carY = this.cursor.y;
    var p = proj.toPx(carX, carY);
    ctx.lineCap = 'round';

    // 指引线：从车位置沿给定世界角度伸出 length 米
    var rays = this.cursor.rays || [];
    for (var i = 0; i < rays.length; i++) {
      var ray = rays[i];
      var tip = proj.toPx(carX + Math.cos(ray.angle) * ray.length,
                          carY + Math.sin(ray.angle) * ray.length);
      ctx.strokeStyle = ray.color;
      ctx.lineWidth = ray.width || 2;
      ctx.setLineDash(ray.dash ? [7, 5] : []);
      ctx.beginPath();
      ctx.moveTo(p[0], p[1]);
      ctx.lineTo(tip[0], tip[1]);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = ray.color;
      ctx.beginPath();
      ctx.arc(tip[0], tip[1], 2.6, 0, Math.PI * 2);
      ctx.fill();
    }

    // 两条指引线之间的夹角弧（滑移角）
    var arc = this.cursor.arc;
    if (arc && Math.abs(arc.to - arc.from) > 1e-4) {
      var steps = Math.max(3, Math.round(Math.abs(arc.to - arc.from) / 0.13));
      ctx.strokeStyle = arc.color;
      ctx.lineWidth = 1.6;
      ctx.beginPath();
      for (var k = 0; k <= steps; k++) {
        var a = arc.from + (arc.to - arc.from) * k / steps;
        var q = proj.toPx(carX + Math.cos(a) * arc.radius, carY + Math.sin(a) * arc.radius);
        if (k === 0) ctx.moveTo(q[0], q[1]); else ctx.lineTo(q[0], q[1]);
      }
      ctx.stroke();
    }

    if (typeof this.cursor.heading === 'number') {
      /* 播放头：三角形指向车头朝向。世界 XY 平面（z 上）→ 屏幕 y 轴翻转，故旋转 -heading */
      ctx.save();
      ctx.translate(p[0], p[1]);
      ctx.rotate(-this.cursor.heading);
      ctx.fillStyle = '#ffd166';
      ctx.strokeStyle = 'rgba(0,0,0,0.6)';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(10, 0);
      ctx.lineTo(-6, 6.5);
      ctx.lineTo(-3, 0);
      ctx.lineTo(-6, -6.5);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
      ctx.restore();
    } else {
      ctx.fillStyle = '#ffd166';
      ctx.beginPath();
      ctx.arc(p[0], p[1], 4.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,0.55)';
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }

    // 角度读数（描边保证在深色轨迹上也看得清）
    var note = this.cursor.note;
    if (note) {
      ctx.font = '12px Consolas, monospace';
      ctx.textAlign = 'left';
      ctx.textBaseline = 'middle';
      ctx.lineWidth = 3;
      ctx.strokeStyle = 'rgba(0,0,0,0.75)';
      ctx.strokeText(note.text, p[0] + 14, p[1] - 13);
      ctx.fillStyle = note.color;
      ctx.fillText(note.text, p[0] + 14, p[1] - 13);
    }
  };

  global.LapCharts = {
    PALETTE: PALETTE,
    LAP_COLORS: LAP_COLORS,
    fitCanvas: fitCanvas,
    niceTicks: niceTicks,
    speedColor: speedColor,
    inputColor: inputColor,
    gearColor: gearColor,
    formatValue: formatValue,
    formatClock: formatClock,
    LineChart: LineChart,
    TrackMap: TrackMap
  };
})(window);
