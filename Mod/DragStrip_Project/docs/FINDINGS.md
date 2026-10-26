# DragStrip Project - 源码调研记录

- 调研日期：2026-10-26
- 目标游戏版本：BeamNG.drive 0.40
- 目标地图：SSRB（`ssrb.zip`，level id `ssrb`）
- 方式：只读检查游戏目录与 SSRB 压缩包；未修改游戏目录，未修改 `ssrb.zip`，未创建运行时代码。
- 说明：本文是内部调研记录，不是用户文档。README 的英文版为权威；本文中的“源码核对”不等于“游戏内已验证”。

---

## 0. 结论

1. **不需要在 gridmap 上做事，也不需要 World Editor 新建场景对象。** SSRB 本身就是 100 km 直路，且已有 `wp2`/`wp3` 两个 AI 导航节点。
2. **纯 JSON 可以定义赛道**：`levels/ssrb/dragstrips/ssrbDrag.strip.json` + `ssrbDrag.dragSettings.json`。
3. **AI 对手走官方任务类型**：`gameplay/missions/ssrb/dragStripRace/...`，使用官方 `dragStripRace` mission type。其 flowgraph 明确把第二辆车设为 `isPlayable_2 = false`、`lane_2 = 2`。
4. **1000 m 在这个地图上是可行的**：车道区域可以覆盖 1000 m，终点放在 `y = -20100`；这解决了 gridmap 官方赛道只有约 401 m、1000 m 计时器必然无法完赛的问题。
5. **v0.1 没有实体圣诞树/记分牌**：只有 HUD 树和 HUD timeslip。缺失的灯对象会打 `E` 日志，但不阻断逻辑。
6. **最大的未验证点**：AI 从 `wp1 -> wp2` 边的中段（spawn）出发，能否稳定地沿该边开到 `wp2`。这是源码推导，必须在游戏里实测。

### 0.1 MVP 实测后的修订（2026-10-26）

1. **删除 strip 级 `drag_stop`**。官方 stop 阶段只发 `ai.setSpeedMode("off")` + `ai.setTarget(drag_stop)`（`phaseHandlers.lua:1017-1022`），AI 会全速冲向 400 m 外的 `wp3`，表现为"冲线不刹车"。改为由任务目录的 `script.lua`（`missionManager.lua:426-438` 自动加载）每 0.2 s 发 `ai.setSpeed(0)` + `ai:scriptStop(true, true)`。
2. **AI 后段跑偏**：`isRacerInsideBoundary` 用四个轮心判定，AI 侧原来只有 2.6 m 容差。分界从 `x = -3` 挪到 `-4.5`，两侧各约 4.3 m；`script.lua` 另加 2.5 m 阈值的 `ai.setTarget("wp2")` 重发纠偏。
3. **任务触发点**移到 SSRB 默认出生点 `(0, 0, 70.5)`（`ssrb.mis:216-232` 的 `SpawnSphere`）。
3.1. **`important` 计时器会污染 dial 表（实测 bug）**：`saveDialTimes`（`saveSystem.lua:469-484`）把 `dragData.importantTimerId` 的值写进 `settings/dragDialTimes.json` 的 `time_1_4`。我们把 1000 m 设为 important，于是跑完一局后 30 s 左右的 1000 m 成绩被当作 1/4 mile dial；下一局 `generateDragOpponents.getPlayerDial` 读到它，在 `[dial-0.1, dial+0.4)` 窗口里只剩重型车（表现为"第二局起固定匹配大货车"）。官方所有 drag 设置的 important 都是 `time_1_4`，所以没暴露这个问题。
   修复：任务 `script.lua` 在首帧快照该车 dial 条目（顺带清掉历史遗留的 `time_1000m` 字段），玩家冲线后 0.8 s 把 `time_1_4` / `time_1000m` 还原，保留 `history`。
   备选方案（未采用）：把 important 改回 `time_1_4`（402.336 m），代价是胜负按 402 m 而不是 1000 m 判定（`headsUpRace.generateWinData` 按 important 计时器排序）。
4. **赛道整体北移**到出生点正前方：spawn `y = -20`、stage `y = -40`、endLine `y = -1040`，zone `y [10, -1240]`。原来放在 `y = -19080 ... -20100`，进任务后车会被 flow 的 `moveTo` 搬到 19 km 外，与出生点处的任务入口脱节。
   该段几何：`road_0`（`y = 0`，覆盖 `500 ... -500`）+ `road_1`（`y = -1000`，覆盖 `-500 ... -1500`）；`tunnel_1`（`ssrb_tunnel.dae`，`y = 500 ... -500`，内壁 `|x| ≈ 17.05`，路面 24 m 在隧道内仍有余量），所以前 500 m 跑在隧道里。`y = -500` 处是路段接缝。`ssrb_end.dae`（`y = 498 ... 500`）是路北端封头，不影响。第 8 节坐标表已被本节取代。

---

## 1. 目标关卡事实（SSRB）

### 1.1 文件结构

`C:\Users\ShaoDe\AppData\Local\BeamNG\BeamNG.drive\current\mods\repo\ssrb.zip` 内：

- `levels/ssrb/info.json`：标题 `Special Stage Route B`，作者 `Nadeox1 DoullPepper`。
- `levels/ssrb/ssrb.mis`：旧 Torque 场景树，3533 行，118 KB。没有 `main/` 目录。
- `levels/ssrb/map.json`：AI 路径定义，只有 `main` 段，节点为 `wp1 ... wp10`。
- `mod_info/MNKDTY7XZ/info.json`：版本 `1.1`，resource_id `523`。

因为 `ssrb` 没有 `main/`，`core_levels` 会走旧 `.mis` 入口：

- `core/levels.lua:39-50`：优先 `main/`，其次 `path.getPathLevelMain()`，再退到目录内第一个 `*.mis`。
- `server.lua:240-257`：有 `main/` 走新格式；否则 `Sim.deserializeObjectsFromFile` 或 `TorqueScriptLua.exec` 旧 `.mis`。

### 1.2 道路几何

`levels/ssrb/art/shapes/ssrb_road_1km.dae` 是 COLLADA，单位米：

- 顶点包围盒：`X[-17.73123, 17.73123]`，`Y[-500, 500.0431]`，`Z[-102.9705, 0.7425489]`。
- 路面顶面在 `z ≈ 0`；桥墩/结构在负 Z。
- 横向可行驶宽度约 24 m（x 约 -12 ... +12），两侧护栏在 x 约 ±17。

`ssrb.mis` 中每段道路对象都在 `z = 70`：

- `road_19`：`0 -19000 70`（`ssrb.mis:1817-1830`），覆盖 y=-19500 ... -18500。
- `road_20`：`0 -20000 70`（`ssrb.mis:1837-1850`），覆盖 y=-20500 ... -19500。
- `split_1`：`0 -21000 70`（`ssrb.mis:397-410`）。
- `warning_3`：`-1.14441e-005 -20059.5 70`，`collisionType = "None"`（`ssrb.mis:1314-1327`）。

结论：y=-19080 ... -20300 是一段没有隧道、没有分叉、没有碰撞障碍的直路。

### 1.3 既有 AI 节点

`ssrb.mis` 末尾：

- `wp1`：`0 0 70`
- `wp2`：`0 -20500 70`（`ssrb.mis:3446-3454`）
- `wp3`：`100 -21500 70`（`ssrb.mis:3455-3463`）
- `wp4` ... `wp10` 继续沿路。

`levels/ssrb/map.json`：

```json
{
  "segments": {
    "main": {
      "nodes": ["wp1", "wp2", "wp3", "wp4", "wp5", "wp6", "wp7", "wp8", "wp9", "wp10"],
      "drivability": 1
    }
  }
}
```

因此 `wp1 -> wp2` 是 map 图中的一条直边；`wp2 -> wp3` 是下一条边。

---

## 2. 赛道发现与加载链路

### 2.1 发现

`lua/ge/extensions/gameplay/drag/core.lua:1487-1503`：

```lua
local levelDir = core_levels.getLevelByName(levelIdentifier).dir
local settingsFiles = FS:findFiles(levelDir.."/dragstrips/", "*.dragSettings.json", -1, true, false)
```

- 对 `ssrb`，`levelDir` 为 `/levels/ssrb`。
- 只要 mod 在 VFS 中提供 `/levels/ssrb/dragstrips/*.dragSettings.json`，就会被扫描到。
- 扫描结果按 level 缓存在 `levelDragStrips[levelIdentifier]`（`core.lua:1489`）；改文件后要重载关卡。

### 2.2 加载

`lua/ge/extensions/gameplay/drag/saveSystem.lua:367-396`：

- 读取 `dragSettings.json`。
- 通过 `stripId` 读取 `*.strip.json`（`saveSystem.lua:379-382`）。
- 用 settings 的 `id` 覆盖 strip 的 `id`（`saveSystem.lua:382`），所以场景对象命名要以 settings 的 `id` 为准。
- `dragType`、`context`、`phases`、`prefabs`、`canBeReseted`、`canBeTeleported` 来自 settings（`saveSystem.lua:383-388`）。
- `timers` 经过 `normalizeTimersConfig`（`saveSystem.lua:389-395`），只保留 `distanceTimer` / `velocity`，且最多一个 `important`。

### 2.3 进入赛道（freeroam）

`lua/ge/extensions/gameplay/drag/poi.lua`：

- 从 JSON 的 `lane.waypoints.stage.transform.position` 取 stage 坐标（`poi.lua:21-28`）。
- 为每条车道创建一个不可见 trigger，半径 6 m，`onInside` 时调用 `startDragRaceActivity`（`poi.lua:68-137`）。
- 所有 level 的 drag data 都会生成 POI（`poi.lua:205-218`）。

因此 v0.1 **不需要 facility / doors / 大地图图标**，只要 stage 坐标正确，freeroam 就能在 stage 处进入。

---

## 3. AI 起步条件（核心）

### 3.1 AI 代码只认 `endLine.name`

`lua/ge/extensions/gameplay/drag/phaseHandlers.lua`：

- stage 阶段：`local aiTarget = laneData.waypoints.endLine.name`，然后 `ai.setTarget("<name>")`（`phaseHandlers.lua:509-525`）。
- race 阶段：`local aiTarget = endLine.name`，再次 `ai.setTarget`（`phaseHandlers.lua:846-890`）。
- race 结束只看最远距离计时器：`racer.timers[raceEndTimerId].isSet`（`phaseHandlers.lua:912-918`）。

### 3.2 `ai.setTarget` 的解析

`lua/vehicle/ai.lua`：

- `setTarget(wp)` 只把名字存进 `M.manualTargetName` / `wpList`（`ai.lua:5939-5943`）。
- manual 模式下调用 `validateUserInput(wpList)`（`ai.lua:5352-5358`）。
- `validateUserInput` 先查 `mapmgr.nodeAliases[name]`（`ai.lua:3986`）：
  - 如果 `nodeAliases[name]` 存在，替换成图节点名；
  - 如果不存在，**不会直接判错**，保留原名；
  - 最终 `newManualPath` 用 `mapData:getPointNodePath(ego.pos, wpList[1], ...)` 找路径（`ai.lua:3901`）。

### 3.3 图节点从哪里来

`lua/ge/map.lua`：

- 地图加载时收集场景里的 `BeamNGWaypoint`（`map.lua:567-580`）。
- 读取 `map.json` 的 `segments`（`map.lua:800-824`）。
- 对每个 segment，把相邻节点连成边；如果节点不存在，打 E 日志并中断该段（`map.lua:888-895`）。
- 只有在 `gp.graph[nodeName] == nil` 时，才把手工 waypoint 通过 `nodeAliases` 吸附到最近图节点（`map.lua:2637-2674`）。

### 3.4 关键推理

- **没有场景 waypoint / map.json 节点，AI 不能起步**：`endLine.name` 既不是图节点，也未必能吸附到 100 m 内的图节点，`getPointNodePath` 会失败。
- **SSRB 的 `wp2` 是图节点**：它在 `map.json` 的 `main` 段里，有 `wp1 -> wp2` 和 `wp2 -> wp3` 两条边，所以 `ai.setTarget("wp2")` 不需要 `nodeAliases` 兜底，`getPointNodePath` 可以直接用这个名字。
- 因此本方案把 `endLine.name` 设为 `wp2`，把 `drag_stop` 设为 `wp3`，AI 就能复用既有图。

> 注意：AI 从 `wp1 -> wp2` 边的中段（spawn y=-19080）出发，`getPointNodePath` 是否能稳定找到去 `wp2` 的路径，**尚未实测**。这是 v0.1 的首要验证项。

---

## 4. 任务型 AI 对手

### 4.1 为什么不用 freeroam

`lua/ge/extensions/gameplay/drag/core.lua:863-870`：

```lua
if not isMP and lane ~= nil and gameplayContext == "freeroam" then
  if not dragData.racers or not next(dragData.racers) then
    dragData.racers = {}
    ...
    setupRacer(vehicleId or be:getPlayerVehicleID(0), lane)
```

- 单机 freeroam 只有在 `racers` 为空时才登记玩家；后续车辆不会通过这条路径自动加入。
- 官方单机 freeroam 的 drag 活动本质是单人。

### 4.2 官方任务类型

`gameplay/missionTypes/dragStripRace/constructor.lua:18`：

```lua
self.fgPath = "/gameplay/missionTypes/dragStripRace/dragRace.flow.json"
```

`gameplay/missionTypes/dragStripRace/dragRace.flow.json:1668-1706`：

- `setDragVehicle` 节点硬编码 `isPlayable_1 = true`、`isPlayable_2 = false`、`lane_2 = 2`。
- 这意味着第二辆车是 AI，车道 2。

`lua/ge/extensions/flowgraph/nodes/gameplay/dragRace/setDragVehicle.lua:107-121`：

- 收集 `{id, isPlayable, dial, lane}`。
- 调用 `gameplay_drag_dragBridge.setVehicles(vehicleList)`。

`lua/ge/extensions/gameplay/drag/dragBridge.lua:345-363`：

- 对每个车辆 `setupRacer(id, lane)`。
- 然后把 `dragData.racers[id].isPlayable` 覆盖为传入值。

因此：官方任务类型 + 我们的 `dragSettings.json` 就能得到“玩家车道 1、AI 车道 2”的布局，不需要自己写 AI 扩展。

### 4.3 任务 info.json 的关键字段

官方样例 `gameplay/missions/gridmap_v2/dragStripRace/001-dragRace_500/info.json`：

- `missionType: "dragStripRace"`（`info.json:53`）。
- `missionTypeData.dragFilepath` 指向本任务的 `dragSettings.json`（`info.json:59`）。
- `startTrigger` 使用 `type: "coordinates"`、`level`、`pos`、`radius`、`rot`（`info.json:88-103`）。

任务类型还提供 `randomOpponent` / `lane` 用户设置（`constructor.lua:239-257`）；默认 `randomOpponent = true`、`lane = 1`。

---

## 5. 计时与 1000 m

### 5.1 比赛结束看“最远距离计时器”

`lua/ge/extensions/gameplay/drag/core.lua:477-491`：

```lua
local function resolveRaceEndTimerId(data)
  ...
  for _, t in ipairs(timerConfig) do
    if t.distance and t.distance > maxDist then
      maxDist = t.distance
      maxDistTimerId = id
    end
  end
  return maxDistTimerId or importantId
end
```

`phaseHandlers.lua:194-210` 有同样的逻辑，并把结果缓存到 `data.raceEndTimerId`。

结论：`important` 只决定胜负比较；**比赛在“最远距离”计时器置位时结束**。所以 1000 m 必须是计时器列表里最远的那个。

### 5.2 计时按距 stage 的距离

`lua/ge/extensions/gameplay/drag/times.lua:198-204`：

```lua
for timerName, timer in pairs(timers) do
  if timer.distance and not timer.isSet and distanceFromOrigin >= timer.distance then
    local t = inverseLerp(prevDistance, distanceFromOrigin, timer.distance)
    ...
```

`distanceFromOrigin` 来自 `phaseHandlers.lua:1171` 的前轮到 stage 的距离，沿 `lane.stageToEndNormalized` 投影（`phaseHandlers.lua:50-68`）。

因此只要车道 zone 覆盖到 1000 m，计时器就能正常置位。

### 5.3 gridmap 为什么不行（历史背景）

- gridmap 官方 endLine 在 x≈442.33，stage 在 x≈41.13，约 401.2 m。
- 官方 lane zone 最远到 x≈675。
- 如果在 gridmap 上把 1000 m 设为最远计时器，比赛会在 zone 结束处先出界 DQ，1000 m 永远不会置位。
- SSRB 的路足够长，所以本方案不存在这个问题。

---

## 6. 显示 / HUD

### 6.1 `.500` 树时序

`lua/ge/extensions/gameplay/drag/display.lua:31-36`：

```lua
local lightStages = {
  {1.0, 1.5, "amberLight1", false},
  {1.5, 2.0, "amberLight1", true, "amberLight2", false},
  {2.0, 2.5, "amberLight2", true, "amberLight3", false},
  {2.5, math.huge, "amberLight3", true, "greenLight", false}
}
```

`display.lua:917-949` 的 `handle500TreeLogic` 按这个时序切换；`treeType` 从 `dragData.prefabs.christmasTree.treeType` 读取（`display.lua:1132`）。

### 6.2 没有实体灯也能工作

- `createTreeLightsForLane` 为每条车道创建 prestage/stage/amber1-3/green/red 条目（`display.lua:259-281`）。
- 必需灯找不到对象时会打 E 日志（`display.lua:190-198`、`262-272`）。
- `hasTreeLights()` 在所有灯对象都不存在时返回 false（`display.lua:328-348`）。
- `updateTreeLightState` 只在 `hasTree` 为 true 时操作场景对象；HUD 更新仍会对 `racer.isPlayable` 执行（`display.lua:811-833`）。
- `updateMultipleTreeLights` 同理（`display.lua:835-863`）。

结论：v0.1 没有实体树时，HUD 树仍然会亮；日志会有缺失对象的 E 行，但不影响 staging/countdown 逻辑。

### 6.3 成绩显示

`core.lua:57-69` 的 `doSendTimeslipDataToUi` 会通过 `guihooks.trigger("onDragRaceTimeslipData", slipData)` 把成绩发给 UI。任务结束时由官方任务 flowgraph 接管结算/重试。

---

## 7. 方案对比

| 方案 | 做法 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| A | 纯 JSON + 复用 `wp2`/`wp3` + 官方任务 | 文件少；不改 SSRB；AI 走官方实现 | AI 只在任务模式；复用 `wp2` 的路径未实测 | **采用** |
| B | World Editor 新建 waypoint/灯，保存 level mod | 可有实体树/记分牌；可自定义终点 | 要把旧 `.mis` 转成 `main/` 整棵场景树；`map.json` 可能冲突；文件多 | 仅作为 fallback |
| C | 运行时 `createObject('BeamNGWaypoint')` + `map.reset()` | 不用改 level | `map.onAddWaypoint` 只在编辑器里自动重建（`map.lua:3708-3712`）；运行时需手动 rebuild，风险高 | 不纳入 v0.1 |

`createObject` 的 API 确实存在（`ge_utils.lua:414-425`），运行时创建 BeamNGWaypoint 也有先例（`splineTrack.lua:244-250`、`procTrack.lua:1180-1187`），但本方案不需要。

---

## 8. 坐标与布局依据

| 项目 | 值 | 依据 |
|---|---|---|
| 车道 1 x | -8 | 路面 x 约 -12 ... +12；两车道各留余量 |
| 车道 2 x | 0 | 与 `wp2` 的 x=0 对齐，AI 不需要横向修正 |
| Spawn y | -19080 | 在 `road_19` 内，距 stage 20 m |
| Stage y | -19100 | 在 `road_19` 内，避开 y=-19500 的路段接缝 |
| EndLine y | -20100 | 1000 m；在 `road_20` 内，距 `wp2` 400 m |
| AI endLine name | `wp2` | `ssrb.mis:3446-3454`；`map.json` 图节点 |
| AI drag_stop name | `wp3` | `ssrb.mis:3455-3463`；`map.json` 图节点 |
| 车道 zone y | -19060 ... -20300 | 覆盖 spawn、stage、1000 m 终点与 200 m 缓冲 |
| 任务 trigger | (-4, -19050, 70.5)，半径 10 | 在 spawn 前方 30 m，避免与 stage POI 重叠 |

Spawn 朝向使用绕 Z 轴 180° 的四元数 `{x:0,y:0,z:1,w:0}`，让车头朝 -Y；这需要游戏内确认。

---

## 9. 计划文件

```text
Mod/DragStrip_Project/
├─ README.md
├─ README.zh-CN.md
├─ NOTICE.md
├─ docs/FINDINGS.md
└─ DragStrip/
   ├─ levels/ssrb/dragstrips/
   │  ├─ ssrbDrag.strip.json
   │  └─ ssrbDrag.dragSettings.json          # freeroam, 1000 m important
   └─ gameplay/missions/ssrb/dragStripRace/
      ├─ 001-ssrbDrag_1000m/
      │  ├─ info.json
      │  └─ dragSettings.json               # mission, 1000 m important
      └─ 002-ssrbDrag_1_4/
         ├─ info.json
         └─ dragSettings.json               # mission, 1/4 mile important
```

不再使用的旧计划：

- `levels/gridmap_v2/dragstrips/gridmapStrip.dragSettings.json`：取消。
- `levels/ssrb/main/` 或 `ssrb.mis` 覆盖：v0.1 不需要。
- `map.json` 覆盖：v0.1 不需要。

---

## 10. 未验证项与风险

### 10.1 未验证项

- AI 从 spawn（`wp1 -> wp2` 边中段）到 `wp2` 的路径是否成立。
- 任务 flowgraph 是否按预期把 AI 放在车道 2，并在 stage 前保持停止。
- Spawn 四元数/高度是否让车正确落在路面。
- 1000 m 计时器是否在 y=-20100 准确置位（受前轮采样和插值影响，误差在一帧内）。
- 任务 startTrigger 与 freeroam stage POI 是否互不干扰。
- SSRB 的 `warning_3` 在终点后 40 m，视觉上是否遮挡。

### 10.2 风险

1. **AI 路径失败**是最大风险；fallback 是新增 `map.json` segment + 专用 waypoint（需要 level mod），或自定义 GE extension。
2. **`wp2` 在终点后 400 m**：AI 冲线后还会继续开；如果它在冲线前就减速，需要把终点移到更靠近 `wp2`，或改用专用 waypoint。
3. **无实体树**：只有 HUD 树；缺失灯对象会产生 E 日志。
4. **第三方地图依赖**：SSRB 更新后 `wp2`/`wp3` 坐标可能变化。
5. **缓存**：`getDragDataForLevel` 按 level 缓存；改 JSON 后要重载关卡/重启。
6. **重复 POI**：freeroam 只放一份 level 设置，避免同一 stage 多个 trigger。
7. **任务随机对手**：官方任务类型按玩家 dial 选择对手；车型不合适属于官方行为。

---

## 11. 源码索引

| 主题 | 位置 |
|---|---|
| 关卡发现 / 旧 `.mis` 入口 | `lua/ge/extensions/core/levels.lua:15-50`；`lua/ge/server/server.lua:240-257` |
| drag 设置扫描 | `lua/ge/extensions/gameplay/drag/core.lua:1487-1503` |
| strip 加载 | `lua/ge/extensions/gameplay/drag/saveSystem.lua:367-396` |
| waypoint 命名/同步 | `lua/ge/extensions/gameplay/drag/saveSystem.lua:109-193` |
| stage POI | `lua/ge/extensions/gameplay/drag/poi.lua:21-28`、`68-137`、`205-218` |
| AI stage/race | `lua/ge/extensions/gameplay/drag/phaseHandlers.lua:509-525`、`846-890` |
| 比赛结束计时器 | `lua/ge/extensions/gameplay/drag/core.lua:477-491`；`phaseHandlers.lua:194-210`、`912-918` |
| 计时采样 | `lua/ge/extensions/gameplay/drag/times.lua:198-204` |
| AI 目标解析 | `lua/vehicle/ai.lua:3901`、`3980-4001`、`5939-5943` |
| 图构建 | `lua/ge/map.lua:567-580`、`800-824`、`888-895`、`2637-2674` |
| 运行时 waypoint API | `lua/ge/ge_utils.lua:414-425`；`lua/ge/extensions/util/trackBuilder/splineTrack.lua:244-250` |
| 任务类型 | `gameplay/missionTypes/dragStripRace/constructor.lua:18`；`dragRace.flow.json:1668-1706` |
| setDragVehicle | `lua/ge/extensions/flowgraph/nodes/gameplay/dragRace/setDragVehicle.lua:107-121` |
| setVehicles | `lua/ge/extensions/gameplay/drag/dragBridge.lua:345-363` |
| 任务 info 样例 | `gameplay/missions/gridmap_v2/dragStripRace/001-dragRace_500/info.json:53-59`、`88-103` |
| `.500` 树 | `lua/ge/extensions/gameplay/drag/display.lua:31-36`、`917-949` |
| HUD 树回退 | `lua/ge/extensions/gameplay/drag/display.lua:811-833` |
| SSRB 道路/waypoint | `levels/ssrb/ssrb.mis:397-410`、`1314-1327`、`1817-1850`、`3446-3463` |
| SSRB AI 路线 | `levels/ssrb/map.json` |
| SSRB 关卡信息 | `levels/ssrb/info.json`；`mod_info/MNKDTY7XZ/info.json` |
