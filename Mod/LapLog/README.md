# LapLog

A lap recorder for BeamNG.drive. It samples position, orientation, speed and
driver inputs, splits laps against a start gate you place anywhere on the map,
stores every lap on disk, and lists them with personal bests per Saved Start.

It renders nothing. There are no Ghost bodies, no replay, no trails and no racing
line -- LapLog is only the recorder and its archive. See `NOTICE.md` for the
attribution chain and the full list of what was removed from the upstream work it
is derived from.

## Install

Copy the `LapLog` folder into your BeamNG user folder, under the current game
version, in `mods/`:

```
<BeamNG user folder>/<version>/mods/LapLog/
```

Then in game open **UI Apps** and add **LapLog**.

The folder is used unpacked on purpose. It is a plain mod directory, so the game
mounts it the same way it mounts an extracted zip; do not zip it and do not add a
`mod_info/` directory.

## Layout

```
LapLog/
  lua/vehicle/extensions/auto/lapLogStart.lua   loads the controller on spawn/reset
  lua/vehicle/controller/lapLog.lua             the recorder (auxiliary controller)
  lua/vehicle/lapLog/                           recording, codec, registry, UI state
  lua/ge/extensions/laplog.lua                  GE side: gate beams, toasts, teardown
  lua/ge/lapLog/markerRenderer.lua              draws the start/finish gate beams
  ui/modules/apps/lapLogApp/                    the panel
  scripts/laplog/modScript.lua                  manual-unload registration
```

## Using it

1. Park at the start of a lap and press **Set and start lap**. The gate is placed
   about 5 m ahead of the car, snapped to the ground.
2. Drive through it. The lap is timed from that crossing.
3. Cross it again in the same direction to store the lap. The next lap starts
   automatically and the new personal best is written immediately.
4. Open the panel to see every stored lap for that start.

**Point-to-point.** Press **Set finish** where the run should end. The lap then
runs start gate to finish gate instead of start to start, and is stored with its
real time. **Remove finish** puts it back to a circuit lap.

**Multiple tracks from one gate.** **New track here** adds another lap library at
the same physical start, so several routes can share one starting point without
overwriting each other.

**Manual runs.** **Record a run** stores a clip without a lap time. It is listed
separately and never counts as a timed lap or competes for a personal best.

**A vehicle reset discards the attempt.** Pressing <kbd>R</kbd> or <kbd>Insert</kbd>
mid-lap throws the samples away and starts a fresh lap from where the car
recovered. Nothing is written to the library, so the partial pool stays clear of
failed attempts. This is the one behaviour intentionally changed from the
upstream mod, which archived every interrupted run.

## Where the data goes

Paths are relative to the level's save-slot directory:

```
lapLogs/freeRoam/<level>/startLines.json                       saved start registry
lapLogs/freeRoam/<level>/<vehicle>/starts/<id>/laplog.save.json
lapLogs/freeRoam/<level>/<vehicle>/starts/<id>/laplog.save.library.json
lapLogs/freeRoam/<level>/<vehicle>/starts/<id>/laplog.save.ghosts/<id>.json
lapLogs/<vehicle>/laplog.save.json                            manual-run library
```

These are deliberately disjoint from Ghost Racer's `ghostReplays/` tree, so both
mods can be installed at the same time without fighting over files.

Each lap is a flat array of samples at the recording rate (50 Hz by default):

| Index | Field |
| --- | --- |
| 1 | time (s) |
| 2-4 | position x, y, z |
| 5-7 | forward x, y, z |
| 8-10 | up x, y, z |
| 11 | speed (m/s) |
| 12 | throttle (0..1) |
| 13 | brake (0..1) |
| 14 | gear index |
| 15 | handbrake (0..1) |
| 16 | clutch (0..1) |

Older 11-field samples still load; they simply carry no input data. Samples from
Ghost Racer Replay 1.2 and 1.6 are also readable.

## Storage limits

Three independent quotas, 20 entries each: timed laps, incomplete attempts and
manual runs. When full, timed laps drop the slowest, partials drop the shortest
(the one that got least far), and manual runs drop the oldest. Pinning a row with
the star protects it from both pruning and deletion.

## Requirements

Developed against BeamNG.drive 0.39.

## Licence

bCDDL 1.1. See `LICENSE` and `NOTICE.md`.