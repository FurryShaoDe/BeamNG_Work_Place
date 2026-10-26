# DragStrip Project

**Status:** MVP files written (one strip + one mission entry, with an AI opponent). Nothing has been verified in-game yet.

**Version:** 0.1.0-dev

**Target:** BeamNG.drive 0.40, SSRB level (`ssrb`), unpacked mod.

## Purpose

Add a drag strip to the SSRB map with:

- staging (prestage / stage beams)
- `.500` tree countdown
- 1000 m and 1/4 mile results
- an AI opponent in the other lane
- a configurable race distance through separate mission entries

The design deliberately avoids editing SSRB's `.mis`, `map.json`, or any game content. It adds new JSON files under new paths only.

## Design summary

The implementation is:

1. A new `ssrbDrag.strip.json` under `levels/ssrb/dragstrips/` defining two lanes and their zones.
2. One mission folder under `gameplay/missions/ssrb/dragStripRace/001-ssrbDrag/` (`info.json` + `dragSettings.json`) using the stock `dragStripRace` mission type for the AI opponent.
3. No World Editor scene objects, no new `BeamNGWaypoint` objects, and no `map.json` override.
4. No freeroam entry point and no 1/4 mile variant in the MVP; both come after the AI chain is verified.

The strip reuses two existing SSRB AI graph nodes:

| Node | Position | Role |
|---|---|---|
| `wp2` | `0 -20500 70` | AI target (`endLine.name`); the player's 1000 m finish line is 400 m before it |
| `wp3` | `100 -21500 70` | AI stop target (`drag_stop`) |

Because `wp1 -> wp2` is already an edge in SSRB's `map.json`, an AI vehicle spawned on that edge can target `wp2` directly. This removes the need for new scene waypoints.

## Why SSRB

SSRB is a 100 km straight test road, not a closed circuit:

- The scene is stored in `levels/ssrb/ssrb.mis` (old Torque format).
- AI routes are defined in `levels/ssrb/map.json` with nodes `wp1 ... wp10`.
- The road is made of 1 km `ssrb_road_1km.dae` pieces at `z = 70`; the road surface is about 24 m wide (x roughly -12 ... +12).
- The MVP strip sits right in front of the level spawn point and spans two pieces:
  - `road_0` at `y = 0` (covers `y = 500 ... -500`)
  - `road_1` at `y = -1000` (covers `y = -500 ... -1500`)
  - The first 500 m run inside `tunnel_1` (`y = 500 ... -500`, inner walls at `x ≈ ±17`, so the 24 m road has room), the rest is open air
  - No splits in this section; `split_1` is far away at `y = -21000`

## Actual layout (MVP)

| Item | Value |
|---|---|
| Lane 1 (player, left) | `x = -9` |
| Lane 2 (AI, right/center) | `x = 0` |
| Spawn | `y = -20`, `z = 70` (20 m past the level spawn point) |
| Stage | `y = -40`, `z = 70` |
| End line (1000 m) | `y = -1040`, `z = 70` |
| AI `endLine` name | `wp2` |
| `drag_stop` | none; the AI is braked by `script.lua` |
| Lane 1 zone | `x [-13.5, -4.7]`, `y [10, -1240]` |
| Lane 2 zone | `x [-4.3, 13.4]`, `y [10, -1240]` |
| Mission start trigger | `(0, 0, 70.5)` (SSRB default spawn point), radius 12 |

`z` is the road surface height (the official gridmap strip is grounded too: spawn `99.99` against road `100`), not `70.5`. The two zones leave a 0.4 m gap so multi-racer lane checks cannot flag both cars; the split sits on the midpoint between the two lanes (`x = -4.5`), leaving about 4.3 m of lateral tolerance on each side.

Zones are invisible logic polygons; SSRB has none of the painted lane markings the stock gridmap strip has. `script.lua` therefore draws the lane centre line, both zone edges, and the stage/endLine bars with `debugDrawer` while the mission runs (cosmetic only; deleting the file leaves the race working).

The stock stop phase only sets `ai.setSpeedMode("off")` and targets a graph node far past the finish, so the AI does not brake on its own. `script.lua` sends `ai.setSpeed(0)` + `ai:scriptStop(true, true)` every 0.2 s once the AI enters the stop phase, and re-sends `ai.setTarget("wp2")` once per second if the AI drifts more than 2.5 m off its lane centre during the race.

The spawn-to-stage distance is 20 m, so the stock AI staging creep is short. The car is placed 20 m from the level spawn point, and the 1000 m finish lands inside `road_1` (`y = -1040`), crossing the `y = -500` section seam halfway.

## Actual files

```text
Mod/DragStrip_Project/
├─ README.md
├─ README.zh-CN.md
├─ NOTICE.md
├─ docs/
│  └─ FINDINGS.md
└─ DragStrip/                         # unpacked mod root
   ├─ levels/ssrb/dragstrips/
   │  └─ ssrbDrag.strip.json          # 2 lanes + zones + drag_stop
   └─ gameplay/missions/ssrb/dragStripRace/
      └─ 001-ssrbDrag/
         ├─ info.json                 # missionType dragStripRace
         ├─ dragSettings.json         # 1000 m important, .500 tree
         └─ script.lua                # lane guides (loaded by missionManager)
```

Not written yet: the freeroam `ssrbDrag.dragSettings.json` and the 1/4 mile mission variant. Both wait until the AI chain is verified.

No `mod_info` folder, no zip, no `app.json` (there is no UI).

## Why the AI opponent uses a mission

The stock single-player freeroam drag flow only registers the player:

- `gameplay_drag_core.startDragRaceActivity` calls `setupRacer` only when `dragData.racers` is empty (`core.lua:863-870`).
- The stock `dragStripRace` mission type, on the other hand, explicitly sets `isPlayable_2 = false` and `lane_2 = 2` in its flowgraph (`gameplay/missionTypes/dragStripRace/dragRace.flow.json:1668-1706`).
- That flowgraph calls `gameplay_drag_dragBridge.setVehicles`, which overrides `isPlayable` after `setupRacer` (`dragBridge.lua:345-363`).

Using the official mission type therefore gives the AI opponent without custom AI code. Freeroam remains player-only in v0.1.

## Verification status

No item below has been tested in-game. "Source path" means the code path was read and cited in `docs/FINDINGS.md`.

| Item | Status | Notes |
|---|---|---|
| MVP JSON written | Done | 3 JSON files; only syntax and coordinate consistency were statically checked |
| Lane guide lines | Not verified | `script.lua` was run under lupa with mocked drag data (10 lines per frame, correct arguments); in-game visibility untested |
| Mission appears in the activity list | Not verified | Directory scan: `missions.lua:713` (recursive `info.json`, no spaces in path) |
| Strip discovered by the drag system | Not verified | Source path: `core.lua:1487-1503` |
| Stage trigger / POI | Not verified | Source path: `poi.lua:68-137`, `205-218` |
| Staging beams | Not verified | Source path: `phaseHandlers.lua:219-233` |
| `.500` countdown | Not verified | Source path: `display.lua:31-36`, `917-949` |
| 1000 m finish / timeslip | Not verified | Source path: `phaseHandlers.lua:194-210`, `912-918` |
| Reset / retry | Not verified | Mission uses `retryBehaviour: infiniteRetries` |
| AI stages and launches | Not verified | Highest-risk item; depends on `wp2` graph path |
| AI drifting in the second half | Mitigated | Zone tolerance raised from 2.6 m to 4.3 m, plus a 2.5 m retarget threshold |
| AI stops after the finish | Not verified | `script.lua` brakes every 0.2 s; command sequence verified under lupa |
| Opponent becomes a truck from round two | Fixed | `saveDialTimes` stores the important timer (1000 m) into `time_1_4`; `script.lua` snapshots and restores the dial entry (verified under lupa) |
| Physical Christmas tree | Not supported in v0.1 | HUD tree only; no scene light objects |
| Physical scoreboard | Not supported in v0.1 | HUD timeslip only |
| Big-map dragstrip icon | Not supported in v0.1 | Mission marker only; no facility/doors |

## Install

1. Install SSRB 1.1 (resource_id 523).
2. Copy `DragStrip/` to `<BeamNG user directory>/mods/unpacked/DragStrip/`.
3. Start BeamNG.drive, load SSRB, spawn a vehicle in freeroam, then start `SSRB 1000 m Drag Race` from the activity list. The start trigger sits on the default spawn point `(0, 0, 70.5)`, so it is visible as soon as you spawn.
4. Reload the level after changing JSON files.

## Documentation

- `docs/FINDINGS.md` - detailed source evidence, coordinates, and open questions.
- `NOTICE.md` - third-party attribution and dependency notice.

## Known risks

1. The AI path from a mid-edge spawn to `wp2` is source-derived, not tested.
2. `wp2` is 400 m past the 1000 m finish; the `script.lua` brake only starts once the AI enters the stop phase, so it coasts for a frame to a few dozen metres after the line.
3. No physical tree or scoreboard exists in v0.1; missing required light objects produce `E` log lines but do not stop the logic.
4. SSRB is a third-party level; `wp2` positions may change in a future SSRB version.
5. The spawn rotation (180 deg around Z) and ground height need in-game confirmation.
6. Lane 2's zone starts at `x = -4.3`, about 4.3 m of lateral tolerance. If it still gets `outOfLane`, the AI is weaving badly: move that edge to `-6` and lane 1's right edge to `-6.4` (player margin drops to 2.6 m).
7. With no physical tree objects `display.lua` logs `E` lines. That is expected noise: staging beams are computed in `processTreeLights`, not read from scene objects.
8. The `script.lua` guides depend on `debugDrawer`. If the log shows `drawLineInstance ok` but no lines appear, that render channel is closed in normal gameplay and only physical markings (level mod) can help.
