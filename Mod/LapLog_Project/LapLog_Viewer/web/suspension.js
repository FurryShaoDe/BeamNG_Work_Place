/* LapLog 查看器 —— 悬架示意图（自绘 canvas，零第三方依赖）
 *
 * 画两幅示意：左边「正视图」= 前轴横截面（左/右轮 + 弹簧 + 车身横梁），
 * 右边「侧视图」= 整车侧面（前/后轮 + 弹簧 + 车身轮廓）。
 *
 * 单位约定：frame 里的 loads/base 是 **kN**，roll/pitch 是 **度**，speed 是 km/h，
 * 油门刹车是 %，frontShareDelta 是 **N** —— 全部来自 server.py 的 CHANNEL_TABLE 换算结果，
 * 本组件不再做任何单位换算。
 *
 * 数据映射（重要，别把它当成真实位移）：
 *   - 弹簧与车身的姿态由**录到的**四轮载荷与车身 roll/pitch 驱动；
 *   - 每角「压缩量」= (当前载荷 − 本圈中位数) / 本圈最大偏离 → 归一化到 −1..1，
 *     再乘以满量程像素（默认 13 px × 放大倍数）。没有弹簧刚度，所以不标毫米，
 *     数字读数仍给绝对 kN 与 ΔN；
 *   - 车轮在载荷 < 15% 静态值时画成离地（虚线接地 + 「离地」标记）；
 *   - roll/pitch 的物理正负号在引擎里没有权威文档（见 README），所以给一个
 *     「反转倾斜方向」开关，让用户按第一眼的观感校正，而不是猜。
 *
 * 全部每帧重画：本组件只有几十个图元，比 LineChart 的静态层缓存便宜得多，
 * 播放时跟随播放头逐帧更新才是重点。
 */
(function (global) {
  'use strict';

  var C = global.LapCharts;

  var COLOR = {
    frame: '#c3b867',
    frameFill: 'rgba(195, 184, 103, 0.10)',
    spring: '#b3b984',
    ground: 'rgba(219, 216, 193, 0.32)',
    tire: '#232220',
    tireStroke: 'rgba(219, 216, 193, 0.35)',
    rim: '#9a9472',
    text: '#dbd8c1',
    muted: '#837f5e',
    compress: '#ef476f',   // 载荷大于静态：悬架被压
    release: '#28d2ff',    // 载荷小于静态：悬架回弹/卸载
    ok: '#48eb7e'
  };

  function clamp(value, lo, hi) {
    return value < lo ? lo : (value > hi ? hi : value);
  }

  /* 绕原点旋转（canvas 的 y 向下，正角 = 右侧下沉） */
  function rot(x, y, ang) {
    var c = Math.cos(ang), s = Math.sin(ang);
    return [x * c - y * s, x * s + y * c];
  }

  /* 圆角矩形路径（胎体、车身都用得上；调用方负责 fill/stroke） */
  function roundRectPath(ctx, x, y, w, h, r) {
    r = Math.min(r, w / 2, h / 2);
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  function SuspensionView(canvas) {
    this.canvas = canvas;
    this.frame = { placeholder: '把鼠标移到曲线上，或点「播放」' };
    this.scale = 2;      // 形变放大倍数（1/2/4，面板里可选）
    this.flip = false;   // 反转 roll/pitch 的倾斜方向
    this.travel = 10;    // 归一化形变 ±1 对应的像素行程（再乘 scale，最后夹到 ±30）
    this.maxLift = 10;   // 车轮离地时抬起的像素
  }

  SuspensionView.prototype.setFrame = function (frame) {
    this.frame = frame || null;
  };

  SuspensionView.prototype.setScale = function (scale) {
    var value = Number(scale);
    this.scale = isFinite(value) && value > 0 ? value : 1;
  };

  SuspensionView.prototype.setFlip = function (flip) {
    this.flip = !!flip;
  };

  SuspensionView.prototype.draw = function () {
    var fit = C.fitCanvas(this.canvas);
    var ctx = fit.ctx;
    var W = fit.width;
    var H = fit.height;
    ctx.clearRect(0, 0, W, H);

    var frame = this.frame;
    if (!frame || !frame.available) {
      ctx.fillStyle = COLOR.muted;
      ctx.font = '13px "Segoe UI", "Microsoft YaHei", sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText((frame && frame.placeholder) || '没有可显示的悬架数据', W / 2, H / 2);
      return;
    }

    if (!frame.wheelRadius) frame.wheelRadius = 20;

    var stripH = 68;
    var groundY = H - stripH - 22;
    var travel = this.travel * this.scale;
    var half = W / 2;

    /* ---------- 地面 ---------- */
    this._ground(ctx, 16, half - 12, groundY);
    this._ground(ctx, half + 12, W - 16, groundY);

    /* ---------- 正视图（前轴） ---------- */
    var cxF = (16 + half - 12) / 2;
    var track = Math.min((half - 40) * 0.33, 150);
    var d = frame.deflections;
    // 几何倾斜用 frame.tiltRoll/tiltPitch（由前端按「倾斜来源」算好）：
    // 'load' 模式它们是 0 —— 车角位置本来就由四轮载荷形变决定，再叠世界姿态会重复。
    var angRoll = this._tilt(frame.tiltRoll, 12);
    // 静态车高：车底距轮胎顶 ~46 px（≈1.5 倍轮径），整车高度约为轮径的 4 倍 —— 真实车的比例。
    // 早先写成 -62（轮径 20）时车底离地 4 倍轮径，看起来像整车悬空。
    var bodyY = groundY - frame.wheelRadius - 46;

    // 车角位置 = 实测 roll 的倾斜 + 该角载荷归一化形变（压缩 → 该角下沉，
    // 于是这一侧的弹簧被压短、另一侧被拉长）。形变像素夹到 ±30，避免 ×4 时穿地。
    function cornerOffset(deflection) {
      return clamp(travel * clamp(deflection, -1, 1), -30, 30);
    }
    var bodyHalf = track * 0.82;
    function bodyPoint(dx, dy, deflection) {
      var r = rot(dx, dy, angRoll);
      return { x: cxF + r[0], y: bodyY + r[1] + cornerOffset(deflection) };
    }
    var leftPt = bodyPoint(-bodyHalf, 0, d[0]);
    var rightPt = bodyPoint(bodyHalf, 0, d[1]);
    // 车厢（前视图里就是车顶那一块）：取两角形变的均值，正好落在横梁的插值线上
    var cabinDeflection = (d[0] + d[1]) / 2;
    var cabinLeft = bodyPoint(-bodyHalf * 0.54, -12, cabinDeflection);
    var cabinRight = bodyPoint(bodyHalf * 0.54, -12, cabinDeflection);
    function bodyYAt(x) {
      var f = (x - leftPt.x) / (rightPt.x - leftPt.x || 1);
      return leftPt.y + (rightPt.y - leftPt.y) * f;
    }

    // 车身：底盘横梁 + 车厢
    ctx.save();
    ctx.fillStyle = COLOR.frameFill;
    ctx.strokeStyle = COLOR.frame;
    ctx.lineWidth = 2;
    ctx.beginPath();
    this._rotatedRect(ctx, leftPt, rightPt, 13);
    this._rotatedRect(ctx, cabinLeft, cabinRight, 11);
    ctx.fill();
    ctx.stroke();
    ctx.restore();

    // 左右轮（正视：左 = FL，右 = FR）
    var frontCorners = [
      { x: cxF - track, index: 0, name: 'FL' },
      { x: cxF + track, index: 1, name: 'FR' }
    ];
    for (var i = 0; i < frontCorners.length; i++) {
      this._corner(ctx, frame, frontCorners[i], bodyYAt(frontCorners[i].x * 0.94 + cxF * 0.06),
        groundY, i === 0 ? -1 : 1, cxF - track - 34, cxF + track + 34);
    }
    this._caption(ctx, cxF, 16, '正视图 · 前轴（左 FL / 右 FR）');

    /* ---------- 侧视图（整车，车头朝左） ---------- */
    var cxS = half + 12 + (W - 16 - (half + 12)) / 2;
    var wb = Math.min((W - half) * 0.30, 150);
    var angPitch = this._tilt(frame.tiltPitch, 10);
    var radius = frame.wheelRadius;
    /* 车底（门槛）离地高度与轮拱：真车约为 1.4 倍轮径，车身下缘因此「套」在车轮上。
       早先车底离地 1.27 倍轮径还多出一整条街，车轮整个挂在车底以下，像板车。 */
    var sillH = radius * 1.4;
    var archR = radius + 11;                 // 轮拱半径：比车轮大一圈，缝隙要一眼可见
    var archCy = sillH - radius;             // 轮心在车身坐标里的 y（正 = 在车底线之下）
    var archSpan = Math.sqrt(Math.max(1, archR * archR - archCy * archCy));  // 拱与车底线的交点横距
    var pivotY = groundY - sillH - 40;       // profilePoint 里 py + 40 偏移的基准（局部 y=0 → 离地 sillH）
    var axleFront = (d[0] + d[1]) / 2;
    var axleRear = (d[2] + d[3]) / 2;

    // 车体：实测 pitch 的旋转 + 前后轴各自的载荷形变（沿车身长度插值 → 前/后高度不同）
    function profileDeflection(px) {
      var f = (px + wb) / (2 * wb || 1);
      return axleFront + (axleRear - axleFront) * clamp(f, 0, 1);
    }
    function profilePoint(px, py) {
      var r = rot(px, py + 40, angPitch);
      return [cxS + r[0], pivotY + r[1] + cornerOffset(profileDeflection(px))];
    }

    /* 轮拱：从车底线上方鼓起的半圆（两端恰好落在车底线上，交于 ±archSpan）。
       离散成折线是为了让每个顶点都吃上 profilePoint 的旋转与形变，而不是单独画一段圆弧。 */
    function archPoints(wheelX) {
      var steps = 14;
      var out = [];
      for (var i = 0; i <= steps; i++) {
        var x = archSpan * (1 - 2 * (i / steps));      // +archSpan → -archSpan（右端 → 左端，经拱顶）
        out.push([wheelX + x, archCy - Math.sqrt(Math.max(0, archR * archR - x * x))]);
      }
      return out;
    }

    /* 轮廓（局部坐标，y 向上为负）：车头 → 引擎盖 → 挡风 → 车顶 → 后窗 → 车尾，
       再沿车底折返（后轮拱 → 中段车底 → 前轮拱）。
       前/后悬约 0.36/0.42 倍半轴距，但不短于轮拱跨距 —— 画布很窄时轮廓也不会回折。 */
    var overF = Math.max(wb * 0.36, archSpan + 6);
    var overR = Math.max(wb * 0.42, archSpan + 6);
    var profile = [
      [-wb - overF, 0], [-wb - overF, -32], [-wb - wb * 0.17, -50],
      [-wb * 0.42, -53], [-wb * 0.20, -108], [wb * 0.28, -114],
      [wb * 0.70, -58], [wb + overR * 0.30, -52], [wb + overR * 0.78, -36],
      [wb + overR, 0]
    ];
    profile.push([wb + archSpan, 0]);
    profile = profile.concat(archPoints(wb));        // 后轮拱
    profile.push([-wb + archSpan, 0]);               // 中段车底
    profile = profile.concat(archPoints(-wb));       // 前轮拱

    // 弹簧藏进轮拱（拱顶 → 轮心），端点仍由载荷形变驱动：车身下沉 → 弹簧被压短
    var springTopY = archCy - archR + 6;
    var sideCorners = [
      { x: cxS - wb, name: '前轴', total: frame.loads[0] + frame.loads[1],
        baseTotal: frame.base[0] + frame.base[1], top: profilePoint(-wb, springTopY) },
      { x: cxS + wb, name: '后轴', total: frame.loads[2] + frame.loads[3],
        baseTotal: frame.base[2] + frame.base[3], top: profilePoint(wb, springTopY) }
    ];
    // 车轮先画：车身轮廓随后盖住轮子的上半圈，轮拱缺口里只露出轮胎 ——
    // 反过来的话轮胎整圆裸露在车底之下，像把轮子摆在地板上。
    for (var s = 0; s < sideCorners.length; s++) {
      this._wheel(ctx, sideCorners[s].x, groundY - radius, radius, false, false, 'side');
    }

    ctx.save();
    ctx.beginPath();
    for (var p = 0; p < profile.length; p++) {
      var point = profilePoint(profile[p][0], profile[p][1]);
      if (p === 0) ctx.moveTo(point[0], point[1]);
      else ctx.lineTo(point[0], point[1]);
    }
    ctx.closePath();
    ctx.fillStyle = COLOR.frameFill;
    ctx.fill();
    ctx.strokeStyle = COLOR.frame;
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.restore();

    // 弹簧与读数画在车体之上：弹簧穿过轮拱缺口接到轮心，压缩看得见
    for (var s2 = 0; s2 < sideCorners.length; s2++) {
      var corner = sideCorners[s2];
      var axleDeflection = s2 === 0 ? (d[0] + d[1]) / 2 : (d[2] + d[3]) / 2;
      this._coil(ctx, { x: corner.top[0], y: corner.top[1] },
        { x: corner.x, y: groundY - radius + 6 });
      // 读数整块挂在车顶上方（三行文字的下沿刚好压在车顶线之上）
      this._cornerText(ctx, corner.x, corner.top[1] - 130, corner.name,
        corner.total, (corner.total - corner.baseTotal) * 1000,
        axleDeflection, s2 === 0 ? -1 : 1);
    }
    this._caption(ctx, cxS, 16, '侧视图 · 整车（车头朝左）');

    /* ---------- 底部：载荷分配 + G-G + 状态 ---------- */
    this._strip(ctx, W, H, stripH, frame);

  };

  /* 归一化形变 → 画布角度；scale 已是倍数，这里再限幅免得画面夸张 */
  SuspensionView.prototype._tilt = function (degrees, limit) {
    var sign = this.flip ? -1 : 1;
    var deg = clamp((degrees || 0) * this.scale * sign, -limit, limit);
    return deg * Math.PI / 180;
  };

  SuspensionView.prototype._ground = function (ctx, x0, x1, y) {
    ctx.strokeStyle = COLOR.ground;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x0, y + 0.5);
    ctx.lineTo(x1, y + 0.5);
    ctx.stroke();
    ctx.strokeStyle = 'rgba(219, 216, 193, 0.14)';
    for (var x = x0; x < x1; x += 8) {
      ctx.beginPath();
      ctx.moveTo(x, y + 1);
      ctx.lineTo(x - 5, y + 6);
      ctx.stroke();
    }
  };

  /* 一根绕中心旋转的横梁：左右端点已算好，这里按厚度展开成四边形 */
  SuspensionView.prototype._rotatedRect = function (ctx, left, right, height) {
    var dx = right.x - left.x;
    var dy = right.y - left.y;
    var len = Math.sqrt(dx * dx + dy * dy) || 1;
    var nx = -dy / len * height / 2;
    var ny = dx / len * height / 2;
    ctx.moveTo(left.x + nx, left.y + ny);
    ctx.lineTo(right.x + nx, right.y + ny);
    ctx.lineTo(right.x - nx, right.y - ny);
    ctx.lineTo(left.x - nx, left.y - ny);
    ctx.closePath();
  };

  /* 螺旋弹簧：两端点之间画成锯齿线圈 */
  SuspensionView.prototype._coil = function (ctx, top, bottom) {
    var dx = bottom.x - top.x;
    var dy = bottom.y - top.y;
    var len = Math.sqrt(dx * dx + dy * dy) || 1;
    var ux = dx / len;
    var uy = dy / len;
    var px = -uy;
    var py = ux;
    var amp = 8;
    var turns = 6;

    ctx.strokeStyle = COLOR.spring;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(top.x, top.y);
    var lead = Math.min(8, len * 0.12);
    ctx.lineTo(top.x + ux * lead, top.y + uy * lead);
    for (var i = 1; i < turns; i++) {
      var along = lead + (len - lead * 2) * (i / turns);
      var side = (i % 2 === 0 ? 1 : -1) * amp;
      ctx.lineTo(top.x + ux * along + px * side, top.y + uy * along + py * side);
    }
    ctx.lineTo(bottom.x - ux * lead, bottom.y - uy * lead);
    ctx.lineTo(bottom.x, bottom.y);
    ctx.stroke();
  };

  /* 画车轮。view：
       'tread' —— 正视图（车头对着镜头）：看到的是**胎面**，轮胎是一段带胎花的圆角矩形；
       'side'  —— 侧视图（车侧对着镜头）：看到的是**轮毂**，轮胎是圆 + 辐条 + 中心盖。
     mark = 这个视图允许显示「离地」文字（侧视图是前后轴合并的，写了会有歧义）。
     注意标记与虚线都必须挂在 lifted 条件下：曾经把文字写在外层，正视图就变成永远「离地」。 */
  SuspensionView.prototype._wheel = function (ctx, x, y, radius, lifted, mark, view) {
    ctx.save();
    if (lifted) {
      ctx.setLineDash([3, 3]);
      ctx.strokeStyle = COLOR.compress;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(x - radius - 4, y + radius + 6);
      ctx.lineTo(x + radius + 4, y + radius + 6);
      ctx.stroke();
      ctx.setLineDash([]);
      if (mark) {
        ctx.fillStyle = COLOR.compress;
        ctx.font = '10px Consolas, monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'top';
        ctx.fillText('离地', x, y + radius + 9);
      }
    }

    ctx.fillStyle = COLOR.tire;
    ctx.strokeStyle = lifted ? COLOR.compress : COLOR.tireStroke;
    ctx.lineWidth = 1.5;

    if (view === 'tread') {
      // 胎面：宽 ≈ 0.72 × 半径，高 = 直径；底部平贴地面（比圆相切更接近真实接地面）
      var halfW = Math.max(10, radius * 0.36);
      var top = y - radius;
      roundRectPath(ctx, x - halfW, top, halfW * 2, radius * 2, halfW * 0.6);
      ctx.fill();
      ctx.stroke();

      // 胎花：4 道 V 形沟槽（方向交替），两端留出胎肩
      ctx.strokeStyle = 'rgba(219, 216, 193, 0.30)';
      ctx.lineWidth = 1.5;
      for (var i = 1; i <= 4; i++) {
        var gy = top + radius * 2 * (i / 5);
        var dir = (i % 2 === 0) ? 1 : -1;
        ctx.beginPath();
        ctx.moveTo(x - halfW + 2, gy);
        ctx.lineTo(x, gy + 3 * dir);
        ctx.lineTo(x + halfW - 2, gy);
        ctx.stroke();
      }
      // 胎肩：两侧各一条竖线，暗示胎侧的圆角过渡
      ctx.strokeStyle = 'rgba(219, 216, 193, 0.18)';
      ctx.beginPath();
      ctx.moveTo(x - halfW + 2.5, top + 3);
      ctx.lineTo(x - halfW + 2.5, top + radius * 2 - 3);
      ctx.moveTo(x + halfW - 2.5, top + 3);
      ctx.lineTo(x + halfW - 2.5, top + radius * 2 - 3);
      ctx.stroke();
    } else {
      // 轮毂：外圈 = 胎侧，内圈 = 轮辋，5 根辐条 + 中心盖
      ctx.beginPath();
      ctx.arc(x, y, radius, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();

      ctx.strokeStyle = COLOR.rim;
      ctx.lineWidth = 1.6;
      ctx.beginPath();
      ctx.arc(x, y, radius * 0.66, 0, Math.PI * 2);
      ctx.stroke();

      ctx.lineWidth = 2;
      for (var s = 0; s < 5; s++) {
        var ang = s * Math.PI * 2 / 5 - Math.PI / 2;
        ctx.beginPath();
        ctx.moveTo(x + Math.cos(ang) * radius * 0.16, y + Math.sin(ang) * radius * 0.16);
        ctx.lineTo(x + Math.cos(ang) * radius * 0.62, y + Math.sin(ang) * radius * 0.62);
        ctx.stroke();
      }
      ctx.fillStyle = COLOR.rim;
      ctx.beginPath();
      ctx.arc(x, y, radius * 0.16, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  };

  /* 正视图的一角：弹簧 + 车轮 + 读数 + 形变条 */
  SuspensionView.prototype._corner = function (ctx, frame, corner, mountY, groundY, side, leftEdge, rightEdge) {
    var index = corner.index;
    var load = frame.loads[index];
    var base = frame.base[index];
    var deflection = frame.deflections[index];
    // 离地判据：载荷掉到静态值 15% 以下（真实数据里只占约 0.5% 的样本，属跳跃/腾空瞬间）
    var lifted = base > 0 && load < base * 0.15;
    var radius = frame.wheelRadius;
    var wheelY = groundY - radius - (lifted ? this.maxLift : 0);

    this._coil(ctx, { x: corner.x, y: mountY }, { x: corner.x, y: wheelY - radius * 0.2 });
    this._wheel(ctx, corner.x, wheelY, radius, lifted, true, 'tread');
    // loads/base 的单位是 kN（服务端已换算），Δ 单独换算成 N 显示，读数才有分辨率
    this._cornerText(ctx, corner.x, groundY - radius * 2 - 78, corner.name, load,
      (load - base) * 1000, deflection, side);

    // 形变条：0 线在中间，向上 = 卸载，向下 = 压紧（与画面一致）
    var barX = side < 0 ? leftEdge : rightEdge;
    var barTop = groundY - radius * 2 - 34;
    var barH = 30;
    ctx.strokeStyle = 'rgba(219, 216, 193, 0.25)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(barX - 6, barTop + barH / 2 + 0.5);
    ctx.lineTo(barX + 6, barTop + barH / 2 + 0.5);
    ctx.stroke();
    var value = clamp(deflection, -1, 1) * (barH / 2) * this.scale * 0.5;
    value = clamp(value, -barH / 2, barH / 2);
    ctx.strokeStyle = deflection >= 0 ? COLOR.compress : COLOR.release;
    ctx.lineWidth = 5;
    ctx.beginPath();
    ctx.moveTo(barX, barTop + barH / 2);
    ctx.lineTo(barX, barTop + barH / 2 + value);
    ctx.stroke();
  };

  /* 角上读数：名称 + 绝对载荷 + ΔN（按压/弹着色）。
     车身横梁会压到读数上，所以文字一律先描一圈深色底（轨迹图的度数读数同款做法）。 */
  SuspensionView.prototype._cornerText = function (ctx, x, y, name, kiloNewtons, deltaNewton, deflection, side) {
    var draw = function (text, offsetY, color, font) {
      ctx.font = font;
      ctx.lineWidth = 3;
      ctx.strokeStyle = 'rgba(30, 29, 26, 0.85)';
      ctx.strokeText(text, x, y + offsetY);
      ctx.fillStyle = color;
      ctx.fillText(text, x, y + offsetY);
    };
    ctx.textAlign = 'center';
    ctx.textBaseline = 'alphabetic';

    draw(name, 0, COLOR.muted, '11px Consolas, monospace');
    draw(kiloNewtons.toFixed(2) + ' kN', 17, COLOR.text, '13px Consolas, monospace');
    var sign = deltaNewton >= 0 ? '+' : '−';
    draw(sign + Math.round(Math.abs(deltaNewton)) + ' N', 32,
      Math.abs(deflection) < 0.04 ? COLOR.muted
        : (deltaNewton >= 0 ? COLOR.compress : COLOR.release),
      '11px Consolas, monospace');
  };

  SuspensionView.prototype._caption = function (ctx, x, y, text) {
    ctx.fillStyle = COLOR.muted;
    ctx.font = '12px "Segoe UI", "Microsoft YaHei", sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, x, y);
  };

  /* 底部条：前后载荷分配 + G-G 圆盘 + 侧倾/俯仰/速度/踏板 */
  SuspensionView.prototype._strip = function (ctx, W, H, stripH, frame) {
    var y = H - stripH;

    var frontLoad = frame.loads[0] + frame.loads[1];
    var rearLoad = frame.loads[2] + frame.loads[3];
    var total = frontLoad + rearLoad;
    var frontShare = total > 0 ? frontLoad / total : 0.5;

    var barX0 = 20;
    var barX1 = Math.max(barX0 + 160, W - 260);
    var barY = y + 14;
    var barH = 10;
    ctx.fillStyle = 'rgba(219, 216, 193, 0.10)';
    ctx.fillRect(barX0, barY, barX1 - barX0, barH);
    ctx.fillStyle = COLOR.frame;
    ctx.fillRect(barX0, barY, (barX1 - barX0) * frontShare, barH);
    ctx.fillStyle = 'rgba(40, 210, 255, 0.55)';
    ctx.fillRect(barX0 + (barX1 - barX0) * frontShare, barY, (barX1 - barX0) * (1 - frontShare), barH);
    ctx.strokeStyle = 'rgba(219, 216, 193, 0.45)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(barX0 + (barX1 - barX0) / 2 + 0.5, barY - 3);
    ctx.lineTo(barX0 + (barX1 - barX0) / 2 + 0.5, barY + barH + 3);
    ctx.stroke();

    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
    ctx.fillStyle = COLOR.muted;
    ctx.font = '11px Consolas, monospace';
    ctx.fillText('载荷分配', barX0, barY - 6);
    ctx.fillStyle = COLOR.text;
    ctx.fillText('前 ' + frontLoad.toFixed(2) + ' kN (' + (frontShare * 100).toFixed(1) +
      '%) · 后 ' + rearLoad.toFixed(2) + ' kN (' + ((1 - frontShare) * 100).toFixed(1) +
      '%) · 合计 ' + total.toFixed(2) + ' kN', barX0 + 62, barY - 6);
    ctx.fillStyle = frame.frontShareDelta >= 0 ? COLOR.compress : COLOR.release;
    ctx.fillText('轴间转移 ' + (frame.frontShareDelta >= 0 ? '+' : '−') +
      Math.round(Math.abs(frame.frontShareDelta)) + ' N', barX0, barY + barH + 16);
    // 姿态读数：roll/pitch 是实测「世界姿态」（含地形），去地形俯仰与坡度另列，便于对照
    ctx.fillStyle = COLOR.muted;
    ctx.fillText('侧倾 ' + frame.roll.toFixed(1) + '° · 俯仰 ' + frame.pitch.toFixed(1) + '°' +
      ' · 去地形 ' + frame.pitchRoad.toFixed(1) + '° · 坡度 ' + frame.grade.toFixed(1) + '%' +
      (frame.speed === null ? '' : ' · ' + frame.speed.toFixed(0) + ' km/h'), barX0 + 120, barY + barH + 16);

    // 踏板小条：油门绿 / 刹车红，宽 60 px
    var pedalX = barX1 - 130;
    var pedalY = barY + barH + 8;
    this._pedal(ctx, pedalX, pedalY, frame.throttle, COLOR.ok, '油门');
    this._pedal(ctx, pedalX + 70, pedalY, frame.brake, COLOR.compress, '刹车');

    // G-G 圆盘
    var cx = W - 86;
    var cy = y + stripH / 2;
    var r = 30;
    ctx.strokeStyle = 'rgba(219, 216, 193, 0.28)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.stroke();
    ctx.strokeStyle = 'rgba(219, 216, 193, 0.14)';
    ctx.beginPath();
    ctx.moveTo(cx - r, cy);
    ctx.lineTo(cx + r, cy);
    ctx.moveTo(cx, cy - r);
    ctx.lineTo(cx, cy + r);
    ctx.stroke();
    ctx.fillStyle = COLOR.muted;
    ctx.font = '10px Consolas, monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.fillText('G-G', cx, cy + r + 3);

    var scale = r / 1.5;                 // 盘缘 = 1.5 g
    var trail = frame.trail || [];
    for (var i = 0; i < trail.length; i++) {
      var age = trail.length > 1 ? i / (trail.length - 1) : 1;
      var tx = cx + clamp(trail[i][0] / 1.5, -1, 1) * scale;
      var ty = cy - clamp(trail[i][1] / 1.5, -1, 1) * scale;
      ctx.fillStyle = 'rgba(195, 184, 103, ' + (0.10 + 0.45 * age).toFixed(2) + ')';
      ctx.beginPath();
      ctx.arc(tx, ty, 2, 0, Math.PI * 2);
      ctx.fill();
    }
    if (trail.length) {
      var last = trail[trail.length - 1];
      var dx = cx + clamp(last[0] / 1.5, -1, 1) * scale;
      var dy = cy - clamp(last[1] / 1.5, -1, 1) * scale;
      ctx.fillStyle = COLOR.text;
      ctx.beginPath();
      ctx.arc(dx, dy, 3.5, 0, Math.PI * 2);
      ctx.fill();
    }
  };

  SuspensionView.prototype._pedal = function (ctx, x, y, value, color, label) {
    var ratio = value === null || value === undefined ? 0 : clamp(value / 100, 0, 1);
    ctx.fillStyle = 'rgba(219, 216, 193, 0.10)';
    ctx.fillRect(x, y, 60, 6);
    ctx.fillStyle = color;
    ctx.fillRect(x, y, 60 * ratio, 6);
    ctx.fillStyle = COLOR.muted;
    ctx.font = '10px Consolas, monospace';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillText(label + ' ' + Math.round(ratio * 100) + '%', x, y + 9);
  };

  global.SuspensionView = SuspensionView;
})(window);
