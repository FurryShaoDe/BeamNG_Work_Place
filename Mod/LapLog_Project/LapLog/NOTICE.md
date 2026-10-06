# NOTICE

> **中文说明（仅为方便阅读，非权威；以下英文原文为准）**
>
> LapLog 是**派生作品**：本目录里的每个 Lua / JavaScript 文件都源自
> **Jesus Goose** 的 *Ghost Racer Replay* 与 **flintt** 的 *Ghost Racer Enhanced*（链接见下方英文原文），
> 两者均以 **bCDDL 1.1** 发布；完整许可证文本在本目录的 `LICENSE`，所有保留下来的源文件都带有 bCDDL 头声明。
>
> 下方英文的 *What was changed relative to the upstream work* 一节逐条列出相对上游删掉了什么，以及三处
> **有意改动**的行为：① 车辆重置不再把中断的尝试存成残圈（直接丢弃并重新布防）；② 磁盘路径与 Ghost Racer 的
> `ghostReplays/` 完全分离，两个模组可同时安装；③ "ghost" 只作为内部标识符保留，所有用户可见的名称/文件名一律用 "lap"。

LapLog is a derivative work. It contains no code authored for this project; every
Lua and JavaScript file here began as a copy of, or was mechanically derived from,
the following:

- **Ghost Racer Replay** -- Original Ghost Racer Replay by **Jesus Goose**.
  BeamNG Resources: https://www.beamng.com/resources/ghost-racer-replay.38554/
  BeamNG thread: https://www.beamng.com/threads/ghost-racer-replay.108045/
- **Ghost Racer Enhanced** -- performance, telemetry and interaction work by
  **flintt**, which this derivative is based on.
  Upstream project: https://github.com/flintt/ghost-racer-telemetry

Both are published under the **bCDDL 1.1**. A copy of the licence text ships in
`LICENSE` next to this file, and every retained source file keeps the bCDDL
header notice.

## What was changed relative to the upstream work

LapLog keeps the recording, archiving and Saved Start half of Ghost Racer
Enhanced and removes the rest. Removed outright:

| Removed | Notes |
| --- | --- |
| Ghost bodies and wireframes | `shellRenderer`, `shellVehicleBackend`, `shellTSStaticBackend`, `wireframeRenderer` |
| Ghost playback and the playback clock | `updatePlaybackClock`, `playRecording`, `playGhost` |
| Ghost camera and camera backend | `cameraBackend`, `setGhostCamera*` |
| Trail, best-lap line and live input trail | `trailRenderer` and its geometry pipeline |
| Route guide and checkpoint enforcement | `routeGuide`; the "must pass every checkpoint" rule is gone with it |
| Racing and Time Trial integration | `prepareRace` / `beginRace` / `finishRaceLap` / `endRace`, `raceState`, `timeTrialState`, `lifecycleCoordinator` |
| Clipboard share codes and telemetry export | `shareCodec`, `shareManager` |
| Camera mode, colour presets, render mode, Top-N display | display settings with no remaining consumer |

Behaviour that was deliberately changed rather than merely removed:

- **A vehicle reset no longer archives the attempt.** Upstream stored every
  interrupted run as an `Incomplete` partial. LapLog discards the samples and
  restarts a fresh lap from the recovered position, because a reset means the run
  was abandoned rather than that a fragment is worth keeping.
- **On-disk paths are disjoint.** Everything is written under `lapLogs/` with
  `laplog.save.json` filenames, so LapLog never reads or writes Ghost Racer's
  `ghostReplays/` tree and the two mods can be installed side by side.
- **"Ghost" survives only as an internal identifier.** The upstream domain model
  calls a stored lap a "ghost" and the field names still do. This is deliberate:
  renaming ~200 local identifiers would add risk without changing behaviour, and
  the storage format is the upstream one on purpose. Every user-visible string,
  file name and mod-level name says "lap", never "ghost".

## Third-party code

`ui/modules/apps/lapLogApp/app.js` is an AngularJS directive, matching the UI
framework BeamNG itself uses. It is loaded by BeamNG's own module system and
bundles nothing.