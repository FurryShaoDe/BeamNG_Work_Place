/* LapLog 查看器 —— 转向平衡图（自绘 canvas，零依赖）
 *
 * 画什么：x = 方向盘角（度，服务端已按该车锁角把输入空间换算好；正 = 左转），
 *         y = 横向 g（服务端派生 g_lat = v · yawRate / g），每圈一种颜色。
 * 每圈三件东西（原始散点只是背景，形状由包络决定）：
 *   细点   = 原始样本（淡）
 *   阴影带 = 5° 分箱的 25%~75% 分位
 *   实线   = 5° 分箱的中位数（= 这条曲线才是要读的东西）
 *   点线   = 分箱 p90（这一档方向盘能摸到的上限）
 *
 * 两个要读的数字（由 setData 返回，面板下方文字用）：
 *   1. 小角度斜率：|δ| ≤ 15° 的过原点最小二乘 —— "每度方向盘换到多少 g"（转向效率）
 *   2. 平台值：分箱中位数里的最大值，以及它到 90% 的那个角度（"打多少方向到顶"）
 *
 * 为什么不做全段回归：把线性段和饱和段混在一根直线里，斜率既不是效率也不是极限
 * （实测同一份数据换口径能差 2~5 倍，还会被大角度段带反符号）。
 *
 * 数据由 app.js 组装并完成样本筛选（速度段、滑移角、总载荷），这里只管画与统计。
 */
(function (global) {
  'use strict';

  var C = global.LapCharts;
  var MARGIN = { left: 64, right: 16, top: 14, bottom: 30 };
  var BIN_DEG = 5;          // 分箱宽度
  var MIN_BIN_SAMPLES = 10; // 一个箱至少有这么多点才画/参与统计
  var KNEE_RATIO = 0.9;     // 中位数达到平台值 90% 的那个角度 = 拐点

  function BalanceView(canvas) {
    this.canvas = canvas;
    this.series = [];        // [{id, label, color, points: [[deltaDeg, ay], ...]}]
    this.stats = [];
    this.placeholder = '';
    this.maxAbsDelta = 90;   // 横轴默认窗口（超出的样本不画，但参与统计）
    this.slopeMaxAbsDeg = 15; // 小角度斜率的取样窗口
  }

  /* 过原点最小二乘：slope = Σ(x·y) / Σ(x²)，只用 |x| 在 [1, slopeMaxAbsDeg] 的样本 */
  BalanceView.prototype._smallAngleFit = function (points) {
    var sxy = 0;
    var sxx = 0;
    var used = 0;
    for (var i = 0; i < points.length; i++) {
      var x = points[i][0];
      var y = points[i][1];
      var absX = Math.abs(x);
      if (!isFinite(x) || !isFinite(y)) continue;
      if (absX < 1 || absX > this.slopeMaxAbsDeg) continue;
      sxy += x * y;
      sxx += x * x;
      used += 1;
    }
    if (used < 10 || sxx < 1e-9) return { slope: null, samples: used };
    return { slope: sxy / sxx, samples: used };
  };

  /* 分箱：有符号（左右分开，不假设左右对称），每箱返回中位/p25/p75/p90 与样本数 */
  BalanceView.prototype._bins = function (points) {
    var buckets = {};
    for (var i = 0; i < points.length; i++) {
      var x = points[i][0];
      var y = points[i][1];
      if (!isFinite(x) || !isFinite(y)) continue;
      var slot = Math.floor(x / BIN_DEG);
      (buckets[slot] = buckets[slot] || []).push(y);
    }
    var bins = [];
    for (var key in buckets) {
      if (!buckets.hasOwnProperty(key)) continue;
      var values = buckets[key].sort(function (a, b) { return a - b; });
      if (values.length < MIN_BIN_SAMPLES) continue;
      bins.push({
        slot: Number(key),
        center: (Number(key) + 0.5) * BIN_DEG,
        count: values.length,
        median: quantile(values, 0.5),
        p25: quantile(values, 0.25),
        p75: quantile(values, 0.75),
        p90: quantile(values, 0.9)
      });
    }
    bins.sort(function (a, b) { return a.center - b.center; });
    return bins;
  };

  function quantile(sorted, q) {
    if (!sorted.length) return 0;
    var index = (sorted.length - 1) * q;
    var lo = Math.floor(index);
    var hi = Math.min(sorted.length - 1, lo + 1);
    var f = index - lo;
    return sorted[lo] + (sorted[hi] - sorted[lo]) * f;
  }

  /* 平台与拐点：直接按样本折叠成 |δ| 分箱、取 **|g| 中位数**（不能拿左右两侧的有符号
     中位数去平均 —— 左弯负、右弯正，平均会互相抵消，实测会得到 0.07 g 这种假平台）。
     只统计窗口内（默认 |δ| ≤ 90°）：再往外是掉头/满舵段，那里的 v·ω 不再等于横向加速度，
     中位数会二次上翘（实测 ETK800 在 ~173° 那档最高），拿它当"平台"是错的。 */
  BalanceView.prototype._plateau = function (points, maxAbsDeg) {
    var buckets = {};
    for (var i = 0; i < points.length; i++) {
      var x = Math.abs(points[i][0]);
      var y = Math.abs(points[i][1]);
      if (!isFinite(x) || !isFinite(y)) continue;
      var slot = Math.floor(x / BIN_DEG);
      if (maxAbsDeg && (slot + 0.5) * BIN_DEG > maxAbsDeg) continue;
      (buckets[slot] = buckets[slot] || []).push(y);
    }
    var rows = [];
    for (var key in buckets) {
      if (!buckets.hasOwnProperty(key)) continue;
      var values = buckets[key].sort(function (a, b) { return a - b; });
      if (values.length < MIN_BIN_SAMPLES) continue;
      rows.push({
        deg: (Number(key) + 0.5) * BIN_DEG,
        median: quantile(values, 0.5),
        p90: quantile(values, 0.9)
      });
    }
    rows.sort(function (a, b) { return a.deg - b.deg; });
    if (!rows.length) return { plateau: null, p90: null, kneeDeg: null };
    var best = rows[0];
    for (var r = 1; r < rows.length; r++) if (rows[r].median > best.median) best = rows[r];
    var knee = null;
    for (var k = 0; k < rows.length; k++) {
      if (rows[k].median >= best.median * KNEE_RATIO) { knee = rows[k].deg; break; }
    }
    return { plateau: best.median, p90: best.p90, kneeDeg: knee };
  };

  BalanceView.prototype.setData = function (series, options) {
    options = options || {};
    this.series = (series || []).filter(function (entry) {
      return entry && entry.points && entry.points.length;
    });
    this.placeholder = options.placeholder || '';
    if (options.maxAbsDelta) this.maxAbsDelta = options.maxAbsDelta;

    // 横轴窗口：默认 ±maxAbsDelta，数据本身更窄就跟着窄（这样小角度段能占满宽度）
    var allAbs = [];
    for (var a = 0; a < this.series.length; a++) {
      var entryPoints = this.series[a].points;
      for (var b = 0; b < entryPoints.length; b++) {
        if (isFinite(entryPoints[b][0])) allAbs.push(Math.abs(entryPoints[b][0]));
      }
    }
    this.xLimit = Math.min(this.maxAbsDelta,
      Math.max(15, Math.ceil(percentile(allAbs, 0.99) / BIN_DEG) * BIN_DEG));

    var stats = [];
    for (var i = 0; i < this.series.length; i++) {
      var entry = this.series[i];
      var fit = this._smallAngleFit(entry.points);
      var bins = this._bins(entry.points);
      var plateau = this._plateau(entry.points, this.maxAbsDelta);
      var hidden = 0;
      for (var k = 0; k < entry.points.length; k++) {
        if (Math.abs(entry.points[k][0]) > this.xLimit) hidden += 1;
      }
      stats.push({
        id: entry.id,
        label: entry.label,
        color: entry.color,
        count: entry.points.length,
        hidden: hidden,
        slope: fit.slope,
        slopeSamples: fit.samples,
        plateau: plateau.plateau,
        plateauP90: plateau.p90,
        kneeDeg: plateau.kneeDeg,
        bins: bins
      });
    }
    this.stats = stats;
    return stats;
  };

  function extent(values) {
    var min = Infinity;
    var max = -Infinity;
    for (var i = 0; i < values.length; i++) {
      if (!isFinite(values[i])) continue;
      if (values[i] < min) min = values[i];
      if (values[i] > max) max = values[i];
    }
    return [min, max];
  }

  BalanceView.prototype.draw = function () {
    var fitted = C.fitCanvas(this.canvas);
    var ctx = fitted.ctx;
    var width = fitted.width;
    var height = fitted.height;
    ctx.clearRect(0, 0, width, height);

    var plotW = Math.max(10, width - MARGIN.left - MARGIN.right);
    var plotH = Math.max(10, height - MARGIN.top - MARGIN.bottom);

    if (!this.series.length) {
      ctx.fillStyle = 'rgba(210, 208, 195, 0.55)';
      ctx.font = '12px system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(this.placeholder || '没有可画的转向数据', width / 2, height / 2);
      return;
    }

    // ---- 坐标范围：x 固定 ±窗口（数据窄就跟着窄），y 按 1%~99% 分位（不让个别尖峰拉爆） ----
    var ys = [];
    for (var s = 0; s < this.series.length; s++) {
      var points = this.series[s].points;
      for (var i = 0; i < points.length; i++) {
        if (isFinite(points[i][1])) ys.push(points[i][1]);
      }
    }
    var xLimit = this.xLimit || this.maxAbsDelta;
    var yRange = percentileRange(ys, 0.01, 0.99);
    var yMin = Math.min(0, yRange[0]);
    var yMax = Math.max(0, yRange[1]);
    var yPad = Math.max(0.05, (yMax - yMin) * 0.08);
    yMin -= yPad;
    yMax += yPad;

    function px(x) { return MARGIN.left + (x + xLimit) / (2 * xLimit) * plotW; }
    function py(y) { return MARGIN.top + plotH - (y - yMin) / (yMax - yMin) * plotH; }

    // ---- 网格与刻度 ----
    ctx.strokeStyle = 'rgba(120, 118, 108, 0.18)';
    ctx.fillStyle = 'rgba(210, 208, 195, 0.6)';
    ctx.font = '11px system-ui, sans-serif';
    ctx.lineWidth = 1;
    var xTicks = C.niceTicks(-xLimit, xLimit, 6);
    var yTicks = C.niceTicks(yMin, yMax, 5);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    for (var xi = 0; xi < xTicks.length; xi++) {
      var gx = Math.round(px(xTicks[xi])) + 0.5;
      ctx.beginPath();
      ctx.moveTo(gx, MARGIN.top);
      ctx.lineTo(gx, MARGIN.top + plotH);
      ctx.stroke();
      ctx.fillText(String(Math.round(xTicks[xi])), gx, MARGIN.top + plotH + 6);
    }
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    for (var yi = 0; yi < yTicks.length; yi++) {
      var gy = Math.round(py(yTicks[yi])) + 0.5;
      ctx.beginPath();
      ctx.moveTo(MARGIN.left, gy);
      ctx.lineTo(MARGIN.left + plotW, gy);
      ctx.stroke();
      ctx.fillText(yTicks[yi].toFixed(2), MARGIN.left - 6, gy);
    }

    // 零轴（回正 / 0 g）
    ctx.strokeStyle = 'rgba(195, 184, 103, 0.45)';
    ctx.beginPath();
    ctx.moveTo(Math.round(px(0)) + 0.5, MARGIN.top);
    ctx.lineTo(Math.round(px(0)) + 0.5, MARGIN.top + plotH);
    ctx.moveTo(MARGIN.left, Math.round(py(0)) + 0.5);
    ctx.lineTo(MARGIN.left + plotW, Math.round(py(0)) + 0.5);
    ctx.stroke();

    // ---- 数据层（裁剪到绘图区，窗口外的样本不画） ----
    ctx.save();
    ctx.beginPath();
    ctx.rect(MARGIN.left, MARGIN.top, plotW, plotH);
    ctx.clip();

    for (var k = 0; k < this.series.length; k++) {
      var entry = this.series[k];
      ctx.fillStyle = entry.color;
      ctx.globalAlpha = 0.13;
      var pts = entry.points;
      for (var p = 0; p < pts.length; p++) {
        if (Math.abs(pts[p][0]) > xLimit || !isFinite(pts[p][1])) continue;
        ctx.fillRect(px(pts[p][0]) - 1, py(pts[p][1]) - 1, 2, 2);
      }
      ctx.globalAlpha = 1;
    }

    for (var b = 0; b < this.stats.length; b++) {
      var stat = this.stats[b];
      var bins = stat.bins;
      var visible = [];
      for (var v = 0; v < bins.length; v++) {
        if (Math.abs(bins[v].center) <= xLimit + BIN_DEG) visible.push(bins[v]);
      }
      if (visible.length < 2) continue;

      // 25%~75% 分位带
      ctx.fillStyle = stat.color;
      ctx.globalAlpha = 0.16;
      ctx.beginPath();
      ctx.moveTo(px(visible[0].center), py(visible[0].p75));
      for (var u = 1; u < visible.length; u++) ctx.lineTo(px(visible[u].center), py(visible[u].p75));
      for (var d = visible.length - 1; d >= 0; d--) ctx.lineTo(px(visible[d].center), py(visible[d].p25));
      ctx.closePath();
      ctx.fill();
      ctx.globalAlpha = 1;

      // p90 上限（细点线）
      ctx.strokeStyle = stat.color;
      ctx.globalAlpha = 0.55;
      ctx.setLineDash([2, 3]);
      ctx.lineWidth = 1;
      ctx.beginPath();
      for (var q = 0; q < visible.length; q++) {
        var qx = px(visible[q].center);
        var qy = py(visible[q].p90);
        q === 0 ? ctx.moveTo(qx, qy) : ctx.lineTo(qx, qy);
      }
      ctx.stroke();
      ctx.setLineDash([]);

      // 中位数（要读的那条）
      ctx.globalAlpha = 1;
      ctx.lineWidth = 2;
      ctx.beginPath();
      for (var w = 0; w < visible.length; w++) {
        var wx = px(visible[w].center);
        var wy = py(visible[w].median);
        w === 0 ? ctx.moveTo(wx, wy) : ctx.lineTo(wx, wy);
      }
      ctx.stroke();
    }
    ctx.restore();

    // ---- 轴标题 ----
    ctx.fillStyle = 'rgba(210, 208, 195, 0.75)';
    ctx.font = '11px system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'bottom';
    ctx.fillText('方向盘角 °（正 = 左转）· 实线 = 分箱中位数（5°），阴影 = 25%–75%，点线 = p90', 
      MARGIN.left + plotW / 2, height - 2);
    ctx.save();
    ctx.translate(12, MARGIN.top + plotH / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.textBaseline = 'middle';
    ctx.fillText('横向 g', 0, 0);
    ctx.restore();
  };

  function percentile(values, q) {
    if (!values.length) return 0;
    var sorted = values.slice().sort(function (a, b) { return a - b; });
    return quantile(sorted, q);
  }

  function percentileRange(values, lo, hi) {
    var usable = [];
    for (var i = 0; i < values.length; i++) if (isFinite(values[i])) usable.push(values[i]);
    if (!usable.length) return [0, 0];
    var sorted = usable.sort(function (a, b) { return a - b; });
    return [quantile(sorted, lo), quantile(sorted, hi)];
  }

  global.LapBalance = { BalanceView: BalanceView };
})(window);
