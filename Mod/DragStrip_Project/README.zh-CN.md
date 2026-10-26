# DragStrip 项目

**状态：** MVP 文件已写入（1 条赛道 + 1 个任务入口，含 AI 对手）。尚未在游戏内验证任何功能。

**版本：** 0.1.0-dev

**目标：** BeamNG.drive 0.40，SSRB 地图（关卡标识 `ssrb`），unpacked 模组。

## 目的

在 SSRB 地图上增加一条直线加速赛道，包含：

- staging（prestage / stage 光束）
- `.500` 圣诞树倒计时
- 1000 m 与 1/4 mile 成绩
- 另一车道的 AI 对手
- 通过不同任务入口配置比赛距离

方案刻意不改 SSRB 的 `.mis`、`map.json` 或任何游戏文件，只在新路径下增加 JSON。

## 方案摘要

实现方式：

1. 在 `levels/ssrb/dragstrips/` 下新增 `ssrbDrag.strip.json`，定义两条车道与车道 zone。
2. 在 `gameplay/missions/ssrb/dragStripRace/001-ssrbDrag/` 下新增一个任务（`info.json` + `dragSettings.json`），使用官方 `dragStripRace` 任务类型提供 AI 对手。
3. 不使用 World Editor 场景对象，不新建 `BeamNGWaypoint`，也不覆盖 `map.json`。
4. MVP 不做 freeroam 入口与 1/4 mile 变体；验证 AI 链路之后再补。

赛道复用 SSRB 已有的两个 AI 图节点：

| 节点 | 坐标 | 用途 |
|---|---|---|
| `wp2` | `0 -20500 70` | AI 目标（`endLine.name`）；玩家 1000 m 终点在其前方 400 m |
| `wp3` | `100 -21500 70` | AI 停车目标（`drag_stop`） |

因为 `wp1 -> wp2` 已经是 SSRB `map.json` 中的一条边，AI 出生在这条边上后可以直接把 `wp2` 作为目标。这样就不需要新建场景 waypoint。

## 为什么选 SSRB

SSRB 是一条 100 km 直线测试路，不是封闭赛道：

- 场景保存在 `levels/ssrb/ssrb.mis`（旧 Torque 格式）。
- AI 路线定义在 `levels/ssrb/map.json`，节点为 `wp1 ... wp10`。
- 道路由 1 km 的 `ssrb_road_1km.dae` 路段拼接，对象位于 `z = 70`；路面宽约 24 m（x 约 -12 ... +12）。
- MVP 赛道放在出生点正前方，跨两段路面：
  - `road_0` 在 `y = 0`（覆盖 `y = 500 ... -500`）
  - `road_1` 在 `y = -1000`（覆盖 `y = -500 ... -1500`）
  - 前 500 m 在 `tunnel_1` 内（`y = 500 ... -500`，内壁在 `x ≈ ±17`，路面 24 m 在隧道内有余量），后 500 m 露天
  - 该段没有分叉；`split_1` 远在 `y = -21000`

## 实际布局（MVP）

| 项目 | 值 |
|---|---|
| 车道 1（玩家，左） | `x = -9` |
| 车道 2（AI，右/中） | `x = 0` |
| Spawn | `y = -20`，`z = 70`（出生点前 20 m） |
| Stage | `y = -40`，`z = 70` |
| 终点线（1000 m） | `y = -1040`，`z = 70` |
| AI `endLine` 名称 | `wp2` |
| `drag_stop` | 不设，AI 停车由 `script.lua` 控制 |
| 车道 1 zone | `x [-13.5, -4.7]`，`y [10, -1240]` |
| 车道 2 zone | `x [-4.3, 13.4]`，`y [10, -1240]` |
| 任务起点触发区 | `(0, 0, 70.5)`（SSRB 默认出生点），半径 12 |

`z` 用路面高度（官方 gridmap 的 spawn 也贴地：`99.99` 对路面 `100`），不写 `70.5`。两条 zone 之间留 0.4 m 缝，避免多车时互相判出界；分界放在两车中线 `x = -4.5`，两侧各留约 4.3 m 横向容差。

zone 只是判定用的隐形多边形，游戏里不渲染；SSRB 也没有官方 gridmap 那样的实体车道涂装。因此 `script.lua` 用 `debugDrawer` 在任务里画出车道中心线、两条边界线、stage 与 endLine 横线（纯装饰，删掉文件不影响比赛）。

赛道起点距出生点只有 20 m，进任务时车基本原地就位；终点在 `road_1` 内（`y = -1040`），中途跨过 `y = -500` 的路段接缝。Spawn 到 Stage 只有 20 m，官方 AI 的 staging 爬行距离很短。AI 冲线后不会自己刹车（官方 stop 阶段只是 `setSpeedMode("off")` 并指向 20 km 外的图节点），所以 `script.lua` 在 AI 进入 stop 阶段后每 0.2 s 发一次 `ai.setSpeed(0)` + `ai:scriptStop(true, true)` 把它刹住；race 阶段若横向偏离车道中心超过 2.5 m，每秒重发一次 `ai.setTarget("wp2")` 纠偏。

## 实际文件

```text
Mod/DragStrip_Project/
├─ README.md
├─ README.zh-CN.md
├─ NOTICE.md
├─ docs/
│  └─ FINDINGS.md
└─ DragStrip/                         # unpacked 模组根目录
   ├─ levels/ssrb/dragstrips/
   │  └─ ssrbDrag.strip.json          # 2 车道 + zone + drag_stop
   └─ gameplay/missions/ssrb/dragStripRace/
      └─ 001-ssrbDrag/
         ├─ info.json                 # missionType dragStripRace
         ├─ dragSettings.json         # 1000 m important，.500 树
         └─ script.lua                # 车道引导线（missionManager 自动加载）
```

暂不写入：freeroam 用的 `ssrbDrag.dragSettings.json`、1/4 mile 变体任务。两者都在 AI 链路验证通过后再补。

不加 `mod_info`，不打 zip，没有 `app.json`（没有 UI）。

## 为什么 AI 对手走任务

官方单机 freeroam 的 drag 流程只登记玩家：

- `gameplay_drag_core.startDragRaceActivity` 只在 `dragData.racers` 为空时调用 `setupRacer`（`core.lua:863-870`）。
- 官方 `dragStripRace` 任务类型的 flowgraph 明确设置 `isPlayable_2 = false`、`lane_2 = 2`（`gameplay/missionTypes/dragStripRace/dragRace.flow.json:1668-1706`）。
- 该 flowgraph 调用 `gameplay_drag_dragBridge.setVehicles`，在 `setupRacer` 之后覆盖 `isPlayable`（`dragBridge.lua:345-363`）。

因此使用官方任务类型就能得到 AI 对手，不需要自己写 AI 代码。v0.1 的 freeroam 仍然是玩家单车。

## 验证状态

下表没有任何一项在游戏内实测过。"源码路径"表示已在 `docs/FINDINGS.md` 中核对并引用代码。

| 项目 | 状态 | 说明 |
|---|---|---|
| MVP JSON 写入 | 已完成 | 3 个 JSON 文件，仅做过语法与坐标一致性静态检查 |
| 车道引导线 | 未验证 | `script.lua` 已用 lupa 模拟执行（每帧 10 条线，参数正确），实机是否可见待测 |
| 任务在列表中出现 | 未验证 | 目录扫描：`missions.lua:713`（递归找 `info.json`，路径不能含空格） |
| 赛道被 drag 系统发现 | 未验证 | 源码路径：`core.lua:1487-1503` |
| Stage 触发区 / POI | 未验证 | 源码路径：`poi.lua:68-137`、`205-218` |
| Staging 光束 | 未验证 | 源码路径：`phaseHandlers.lua:219-233` |
| `.500` 倒计时 | 未验证 | 源码路径：`display.lua:31-36`、`917-949` |
| 1000 m 冲线 / timeslip | 未验证 | 源码路径：`phaseHandlers.lua:194-210`、`912-918` |
| Reset / 重试 | 未验证 | 任务使用 `retryBehaviour: infiniteRetries` |
| AI staging 与起步 | 未验证 | 风险最高；依赖 `wp2` 的图路径 |
| AI 后段跑偏 | 已缓解 | zone 横向容差从 2.6 m 加到 4.3 m，并加 2.5 m 阈值的目标重发 |
| AI 冲线后停车 | 未验证 | `script.lua` 每 0.2 s 发刹车命令；已用 lupa 验证命令序列 |
| 第二局起对手变成大货车 | 已修 | 根因是 `saveDialTimes` 把 important 计时器（1000 m）写进 `time_1_4`；`script.lua` 现在快照并恢复 dial 条目，已用 lupa 验证 |
| 实体圣诞树 | v0.1 不支持 | 只有 HUD 树，没有场景灯对象 |
| 实体记分牌 | v0.1 不支持 | 只有 HUD timeslip |
| 大地图 dragstrip 图标 | v0.1 不支持 | 只有任务 marker，没有 facility/doors |

## 安装

1. 安装 SSRB 1.1（resource_id 523）。
2. 把 `DragStrip/` 复制到 `<BeamNG 用户目录>/mods/unpacked/DragStrip/`。
3. 启动游戏，加载 SSRB，在 freeroam 里先按 F 生成一辆车，再从活动列表进入 `SSRB 1000 m Drag Race`（触发区就在默认出生点 `(0, 0, 70.5)`，出生即可见）。
4. 修改 JSON 后需要重载关卡。

## 文档

- `docs/FINDINGS.md` - 详细源码证据、坐标与待验证问题。
- `NOTICE.md` - 第三方署名与依赖说明。

## 已知风险

1. AI 从边中段出生后前往 `wp2` 的路径是源码推导，未实测。
2. `wp2` 在 1000 m 终点之后 400 m；`script.lua` 的刹车只在 AI 进入 stop 阶段后生效，冲线到刹车之间会有约一帧到几十米的滑行。
3. v0.1 没有实体树/记分牌；缺失的必需灯对象会产生 `E` 日志，但不阻断逻辑。
4. SSRB 是第三方地图；`wp2` 坐标可能随 SSRB 版本变化。
5. Spawn 朝向（绕 Z 180°）和贴地高度需要在游戏内确认。
6. AI 车道 zone 左界 `x = -4.3`，约 4.3 m 横向容差；若仍被 `outOfLane`，说明 AI 已经明显蛇行，把左界推到 `-6` 并同步把车道 1 右界推到 `-6.4`（玩家余量会降到 2.6 m）。
7. 没有实体灯对象时 `display.lua` 会打 `E` 日志，属预期噪音；staging 光束状态由 `processTreeLights` 纯逻辑计算，不依赖场景灯。
8. `script.lua` 的引导线依赖 `debugDrawer`；若日志出现 `drawLineInstance ok` 但实际看不到线，说明该渲染通道在普通游戏里被关闭，只能改用实体标线（需 level mod）。
