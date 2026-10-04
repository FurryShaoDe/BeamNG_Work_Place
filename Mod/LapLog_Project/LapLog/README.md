# LapLog

A lap recorder for BeamNG.drive. It samples position, orientation, speed, driver
inputs and chassis telemetry (the four wheel loads plus body roll/pitch), splits
laps against a start gate you place anywhere on the map, stores every lap on disk,
and lists them with personal bests per Saved Start.

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

1. Park at the start of a lap and press **Set start**. The gate is placed about 5 m
   ahead of the car, snapped to the ground, and auto lap is armed -- but nothing is
   timed yet.
2. Drive through it. The lap starts on that crossing, so lap 1 is timed gate to
   gate exactly like every lap after it. Until then the panel reports the gate
   state as waiting for the start gate instead of showing a running clock.
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
mid-lap throws the samples away and re-arms the start: the next lap is timed from
the next forward pass through the start gate, not from wherever the car
recovered. Nothing is written to the library, so the partial pool stays clear of
failed attempts. This is the one behaviour intentionally changed from the
upstream mod, which archived every interrupted run.

## Timing precision

The lap clock accumulates simulation time on the physics tick (`update`), while the
gate crossing is detected on the render tick (`updateGFX`). A lap time is the
accumulated clock at the render frame that *noticed* the crossing; the interpolated
crossing point is used only for the lateral/vertical gate checks, never to refine
the time. Each detection is therefore 0 .. one render frame late.

In practice the two errors -- start detection and finish detection -- come from the
same mechanism and largely cancel out. Measured by re-deriving the true crossing
instants from the stored samples (first sample's distance past the plane / speed =
start lag; last sample's distance to the plane / speed = finish room;
`lapTime - last sample time` = detection lag):

| Lap | lapTime | start lag | finish room | detection lag | reported - geometric |
| --- | --- | --- | --- | --- | --- |
| hirochi 67.2 s | 67.205 | 6.3 ms | 0.0 ms | 4.5 ms | **-1.8 ms** |
| hirochi 63.7 s | 63.708 | 2.0 ms | 5.2 ms | 7.5 ms | **+0.3 ms** |
| smallgrid 25.4 s | 25.442 | 0.0 ms | 0.0 ms | 1.5 ms | **+1.5 ms** |

Day-to-day error is a couple of milliseconds. The worst case is still bounded by one
render frame (~17 ms at 60 fps, more if the frame rate drops or the engine hitches),
so treat differences below ~20 ms between two laps as being inside the timer's noise.
Sampling is not affected by any of this: samples carry the physics-accumulated
timestamp, so the trace grid stays regular even when the frame rate dips.

**Same behaviour upstream.** Ghost Racer Enhanced detects crossings the same way
(`updateRecording` from `update`, `updateAutoLap` from `updateGFX`, no crossing-time
interpolation, no timestamp on the approach latch), so this is inherited rather than
introduced. Its race / Time Trial / Quick Race modes differ: there `updateAutoLap`
returns `raceControlled` and the mod records the *game's* lap time instead
(`historicTimes[].lapTime`, `onRaceWaypointReached(info.time)`,
`onRaceResult(finalTime)`, handed to the controller through `finishRaceLap`). LapLog
has no race integration, so every lap uses the estimator above.

**Deferred, not implemented:** timestamping the approach latch when the gate is armed
and using `amount` to correct the crossing instant would push the worst case into
sub-millisecond range. Kept as a documented option because the measured error is
already a couple of milliseconds.

**Laps whose start gate does not match the recording.** A normal lap starts on the
crossing, so its first sample sits a few centimetres past the gate plane and the path
crosses the plane once per lap. Records written by the earlier "Set start also starts
recording" behaviour can start mid-track instead: the first sample is already metres
past the plane and the sample path never crosses it forwards. Their `lapTime` is
measured from wherever the recording began, so it is not comparable with real laps.
Quick check per lap: `signed(first sample) / speed` near zero = gate-started; more
than about a metre, with no forward crossing in the samples = mismatched.

## Where the data goes

Paths are relative to the level's save-slot directory:

```
lapLogs/freeRoam/<level>/startLines.json                       saved start registry
lapLogs/freeRoam/<level>/<vehicle>/starts/<id>/laplog.save.json
lapLogs/freeRoam/<level>/<vehicle>/starts/<id>/laplog.save.library.json
lapLogs/freeRoam/<level>/<vehicle>/starts/<id>/laplog.save.ghosts/<id>.json
lapLogs/vehicles/<vehicle>/laplog.save.json                    manual-run library
lapLogs/vehicles/<vehicle>/laplog.save.ghosts/<id>.json
```

The manual-run library is the fallback when no start line is active: the default
filename is `lapLogs/<vehicleDirectory>/laplog.save.json`, and BeamNG's
`vehicleDirectory` is itself `vehicles/<vehicle>` — hence the doubled name. Quick
manual clips recorded before setting a start (or after a reset with no active start)
land there, and the lap viewer lists them under its `vehicles` group.

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
| 17 | front-left wheel vertical load (N) |
| 18 | front-right wheel vertical load (N) |
| 19 | rear-left wheel vertical load (N) |
| 20 | rear-right wheel vertical load (N) |
| 21 | body roll (rad) |
| 22 | body pitch (rad) |

Older 11-field samples still load; they simply carry no input data, and format-3
samples carry no chassis telemetry. Samples from Ghost Racer Replay 1.2 and 1.6 are
also readable. Columns are only ever appended, so a reader can always index what it
knows and ignore the rest.

## Chassis telemetry (format 4)

The four loads are the wheels module's smoothed vertical tire load
(`wd.downForce`, N) in a fixed **front-left, front-right, rear-left, rear-right**
order. Wheels are matched by name (`FL`/`FR`/`RL`/`RR`, the same names BeamNG itself
uses, e.g. in `wheels.wheelRotatorIDs`); a vehicle that names its wheels differently
falls back to the game's own wheel order and the panel badge still says the lap has
chassis data, but the corners of that vehicle may then be mislabelled. A missing,
destroyed or airborne wheel records 0.

Roll and pitch come straight from `obj:getRollPitchYaw()` in radians, unmodified --
no smoothing, no sign flip, no interpolation. They are the **world attitude**, not the
body's attitude relative to the road: on a hilly map the pitch is dominated by the
gradient under the car. Measured on a 223 s hill lap (ks_nord, one of our own records):
correlation of pitch with the terrain grade is **+0.97**, against longitudinal
acceleration only -0.10, throttle +0.01, brake +0.07. So to read *suspension* pitch,
subtract the grade (the grade can be re-derived from the samples: `pos_z` over
horizontal distance, a 25 m look-ahead window is enough -- after subtracting it the
pitch correlates +0.27 with longitudinal acceleration, with the sane sign: nose up
under acceleration, nose down under braking). Roll includes the road's banking the
same way, but that cannot be recovered from the samples. The viewer does this
subtraction for you (`grade` / `pitch_road` derived channels); the recorder stores the
raw values on purpose, since the grade is a property of the track, not of the lap.

Sampling cost is one engine call per sample (the loads are plain table reads of data
`wheels.lua` refreshes once per graphics frame, so they are one frame old at
physics-step sample time -- the same freshness as everything read from
`electrics.values`). The six extra columns add roughly 35 bytes/sample, about 17% on
top of the format-3 size.

What they are good for: weight transfer under braking/acceleration (front/rear
split), cornering load distribution and inside-wheel lift (left/right split), steady
state aero/ride load, and body roll/pitch as the suspension response to steering and
pedal inputs.

## Sample rate

Selectable in the panel: 20 / 30 / 50 / 100 Hz, default 50 (`DEFAULT_SAMPLE_RATE`,
`MIN_SAMPLE_RATE`, `MAX_SAMPLE_RATE`). The recorder accumulates simulation time on
the physics tick and captures one sample when the interval elapses. It never repeats
a pose to catch up after a long frame, so the grid stays regular in simulation time;
a request above the physics tick rate would simply not be honoured.

Measured costs, on a real 63.7 s lap: 202 bytes/sample in the format-3 layout, i.e.
630 KB at 50 Hz versus 1260 KB at 100 Hz, roughly 10 versus 20 KB/s of driving. The
format-4 chassis columns add roughly 35 bytes/sample on top of that (unmeasured, from
the digit widths involved). The viewer's per-lap parse
and channel build take 20 versus 40 ms and the payload sent to the browser doubles
(264 versus 528 KB). The save happens on the frame the lap completes, so the doubled
file size also doubles the encode/write cost at that instant.

Measured benefit, on the same lap: resample the 50 Hz recording down to 25 Hz,
recompute the derived channels and compare -- distance 0.00%, top speed 0.02%,
p99 lateral G 0.90%, p99 longitudinal G 0.62%, peak slip angle 0.15%, slip trace RMS
difference 0.03 deg. Halving the rate costs about one percent, so doubling it buys
about that little. Content above 5 Hz: speed 0.08%, yaw rate 4.8%, throttle 11% and
brake 7% (pedal steps and jitter, not driver intent -- human pedal bandwidth is 2-3 Hz).

Conclusion: 50 Hz is already 5-10x oversampled for the fields above -- including the
format-4 loads and body attitude, which move with the suspension at a few Hz -- and
the lap timer does not depend on the rate at all. Raise it to 100 Hz only when
recording transient channels (tire slip, contact state, suspension travel,
damage/collision), which carry content in the tens of Hz. Also note that **changing the rate changes
file sizes and PB/trace resolution, not lap-time accuracy**.

## Storage limits

Three independent quotas, 20 entries each: timed laps, incomplete attempts and
manual runs. When full, timed laps drop the slowest, partials drop the shortest
(the one that got least far), and manual runs drop the oldest. Pinning a row with
the star protects it from both pruning and deletion.

## Requirements

Developed against BeamNG.drive 0.39.

## Licence

bCDDL 1.1. See `LICENSE` and `NOTICE.md`.