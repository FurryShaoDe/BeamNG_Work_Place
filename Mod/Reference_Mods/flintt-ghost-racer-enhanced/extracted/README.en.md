# Ghost Racer Enhanced

English · [简体中文](README.md)

<p align="center">
  <img src="ui/modules/apps/ghostRacerApp/icon.png" alt="Ghost Racer Enhanced icon" width="96" height="96">
</p>

Ghost Racer Enhanced is a lap ghost, live comparison, and practice mod for BeamNG.drive. It records your driving line and lap time so you can race your previous runs, see where time is gained or lost, and learn a faster line.

It is designed for circuit practice, free-roam loops, Hotlapping, and Time Trials. The default wireframe is a lightweight visual replay. The optional **Ghost body** replaces the wireframe with the vehicle's static body mesh (a TSStatic, no physics). With no soft body it never accrues the native backend's over-time frame-rate decay, and it never hits the player or other vehicles; each body still has a real rendering cost, so many at once add up (the body count is capped).

> This project is an enhanced version of **Ghost Racer Replay 1.6** by **Jesus Goose**. Please visit the original [BeamNG Resources page](https://www.beamng.com/resources/ghost-racer-replay.38554/) and [BeamNG forum release/discussion thread](https://www.beamng.com/threads/ghost-racer-replay.108045/). Many thanks to the original author for providing the foundation for this project.

## Highlights

- Place a directed start/finish gate in free roam and record consecutive laps automatically.
- Compare live time delta `Δt` and speed delta `Δv` at the same point on the route, plus a live `RANK` against every Ghost on track.
- Store up to 20 completed laps, 20 incomplete recordings, and 20 manual recordings per start; partials are kept by how far they got (the shortest is dropped first).
- Combine two independent axes: amount (best / Top N / specified / selected / all) and category (completed only / incomplete only / both).
- Color Ghost trails by absolute speed or by acceleration and braking.
- Display a full best-lap racing line, route ribbon, and generated checkpoints.
- Switch between the driving camera and Ghost Chase / Onboard views.
- Save and name multiple starts, then restore them after changing vehicles or restarting the game.
- Share PBs and Ghosts between vehicles at the same saved start while retaining the source vehicle for every lap.
- Select up to five recordings and copy a compact Ghost share code to the system clipboard; import codes only into a matching map and Saved Start.
- Integrate automatically with BeamNG Hotlapping and Time Trials.
- Use either the full HUD or a compact circular race display.

## Installation

1. Disable the original Ghost Racer Replay if it is installed. The original and enhanced versions cannot be enabled together.
2. Remove or move older `ghost-racer-enhanced-*.zip` files so multiple versions do not overwrite one another.
3. Copy `dist/ghost-racer-enhanced-2.17.2.zip` into the `mods` folder in your BeamNG user directory.
4. Enter a map, open **UI Apps**, and add **Ghost Racer Enhanced**.

After replacing the ZIP, you can usually press `Ctrl+L` to reload Lua and then `F5` to refresh the UI instead of restarting immediately. The UI and Controller versions shown in the HUD title should match.

## Keybinds (optional)

Ghost Racer adds bindable actions in **Options > Controls** so you can act without opening the app (unbound by default — assign them yourself to avoid conflicts; the gate actions are free roam only):

- **Set / restart lap start**: with no start yet, place the start gate at the current position and begin a lap; with a start already set, **restart a lap on it in place** without moving or forking it (same as the HUD Set & start / Restart lap).
- **Toggle auto lap**: arm or disarm automatic lap recording.
- **Clear lap start**: deactivate the current start's live functions (its Ghost library is kept).
- **Set finish gate**: place a finish gate at the current position, making the start point-to-point (see below).
- **Clear finish gate**: remove the finish gate, returning to a circuit.
- **New track variant**: create a new track variant at the current start (see below).
- **Toggle app mini / full size**: switch the app between its full panel and the compact mini badge (same as the HUD − / + button).

## Track variants

One start position can host several **track variants**, each with its own ghost
library and finish gate. With a start set, press **+ New track variant here** in
the HUD (or its keybind) to fork a fresh track at the same start position without
touching the others. A second **Track** dropdown then appears: the Saved Start
dropdown picks the start (the location), and the Track dropdown picks the variant
under it. This is handy for running several different loops or point-to-point
routes from one grid position, each keeping its own PB and ghosts. Existing
starts become single-track groups; their data is unchanged. Deleting the active
track re-selects the neighbouring track in the same group (the previous one, or
the next if you deleted the first); deleting the only track in a group leaves
nothing selected.

## Point-to-point

By default a start is a circuit (a lap is start crossing → start crossing again). Drive to where you want the finish and press the HUD **Set finish** button (or the Set finish gate keybind) to place a finish gate; the start becomes **point-to-point**: a run is timed from the start crossing to the finish crossing. Unlike a partial, a completed point-to-point run is saved as a full lap with a real time and updates the PB ghost, and it does not need to loop back to the start. Re-crossing the start abandons the run and begins a fresh one. **P2P ✓** shows it is enabled, and a green **FINISH** gate marks the finish position in the world. Click again (or Clear finish gate) to remove the finish and return to a circuit. The finish geometry is saved with the start, so it persists across restarts and vehicle changes.

## Your first lap

### Automatic free-roam laps

1. Stop at the intended grid position and point the car in the normal lap direction; the gate is placed about five metres ahead of the vehicle.
2. Click **Set & start lap**.
3. Lap 1 begins recording immediately. There is no Ghost yet because no completed reference exists.
4. Drive a full lap and cross the start in the correct direction to save Lap 1.
5. Lap 2 starts automatically and the newly completed Ghost launches with it.

To share recordings, press the `+` control beside up to five Ghost rows and choose **Share**. The app copies a compact 20 Hz code and reports its size through a BeamNG notice. From 2.19 the code also carries the **driver inputs** (throttle/brake/gear/handbrake/clutch), so the Driver-inputs colouring works after import; codes exported by earlier versions carry no inputs and import as pose-only (they still play back, just without input colouring). Activate the matching Saved Start before choosing **Import clipboard**. Duplicate records and laps outside the current Top 20 are skipped. If an import would replace a stored complete or incomplete recording, the app asks for confirmation first.

When you return to the map, choose the previous location from **Saved Start**. A start with existing Ghosts becomes armed, and the next valid crossing begins recording and playback.

A start is **fixed** once created: **Restart lap** simply restarts a lap on it in place — it never moves the start or forks a new start line. To create a start elsewhere, click **×** to deactivate the current one first, then **Set & start** at the new spot.

### BeamNG Time Trials

No manual start placement is needed when entering a Time Trial. During countdown preparation, the mod creates a `tt-` start from the Race suffix or active Mission ID; older activities without either field fall back through the Race Path and BeamNG grid position. At GO it recalibrates from BeamNG's player-vehicle position and direction, places the gate about five metres ahead, and samples the ground there. Entering the same Time Trial later updates and reuses the same start instead of adding duplicates.

The HUD identifies it as **Time Trial Start / Auto**, and its two-pillar gate remains visible at the selected grid position. BeamNG remains authoritative for timing, circuit lap completion, and point-to-point finishes; Ghost Racer synchronizes recording, playback, and the route's PB/Ghost library.

If an older activity publishes no standard Race event, the mod creates the same `tt-` start from the foreground Time Trial Mission lifecycle. If that lifecycle event is also absent, pressing **Set & start lap** inside the activity performs the Mission lookup on demand instead of creating a normal `s001` start.

### Manual recording

When automatic laps are not needed, click **Record** to start or stop a recording, then use **Play ghost** to replay it manually. This is useful for short routes, drift lines, and open roads that do not form a loop.

## Ghost display modes

The display is the combination of two independent axes.

**Amount** (which Ghosts to show):

- **Dynamic best**: always display the fastest available lap.
- **Top N ghosts**: display the Top 2, 3, 5, or 10 together.
- **Specified ghost**: display one chosen lap.
- **Selected ghosts**: display several manually selected laps.
- **All ghosts**: display every visible Ghost; consider lowering quality when many are shown.

**Category** (the **Ghost recordings** control in Settings, choose one):

- **Completed**: show only completed laps (default).
- **Incomplete**: show only partial attempts.
- **Both**: show both.

The axes combine freely, e.g. Top 3 × Incomplete shows the 3 longest partials, and Top 3 × Both shows the 3 fastest laps **plus** the 3 longest partials (each ranked by its own metric, up to 2N, because lap time and partial length are not comparable).

If a recording is interrupted by an invalid gate crossing, race end, vehicle reset (Insert or R), start change, or the 30-minute safety limit, its captured portion is saved with a `PARTIAL` badge, reason, and duration. Under the Completed category these are hidden; switch to Incomplete or Both to view, select, delete, or replay them. When no completed lap exists, Dynamic best temporarily falls back to the longest visible partial. Partials never become the PB and never participate in the best-lap racing line, route generation, or completed-lap rankings.

The three categories have independent 20-entry capacities: completed laps discard the slowest non-PB lap; **incomplete recordings are kept by how far they got, discarding the shortest first (ties broken by age)**, so a failed run cannot evict a more valuable long partial; manual Runs discard the oldest. When a short partial saved by pressing R is shorter than every one already stored, it is dropped on the spot, and the toast says so honestly rather than claiming it was saved.

To keep a recording for good, click the 📌 **pin** on its row. A pinned ghost is **never removed by capacity pruning**, and it **does not count against its category's rotating quota** (it is an extra protected slot); it also **cannot be deleted** until you unpin it. The pin is saved with the ghost library and restored on reload.

Before a recording is running, use `PLAY` on its row to select and replay that exact Ghost, including a visible `PARTIAL`. The button changes to `VIEW` during playback so you can follow it; click **DRIVER VIEW** to return to the player vehicle. A Ghost is not a physical vehicle, so it cannot be selected with `Tab`.

### Live standings (RANK)

While recording a lap, the HUD shows your live position among **every Ghost on track** (completed and incomplete, excluding manual Runs), e.g. `P3 / 12` (a `P3/12` badge in minimized mode). It is ranked by time-to-here — the same basis as `DELTA`: a Ghost that reached your current position in less time is ahead of you. Only Ghosts currently displayed and not yet finished-and-gone are counted, and `DELTA` / `SPEED Δ` are measured against the fastest reference on track (incomplete attempts included).

### Ghost body (static body mesh)

**Ghost body** in Settings replaces the wireframe with the vehicle's static body mesh (a `TSStatic`, no physics), off by default. With no soft body it never accrues the over-time frame-rate decay or the long stalls of full soft-body vehicles, and it works in every display mode. It is still `dynamic=1` per-object rendering, so each body carries a real CPU/GPU cost that adds up with many at once; the body count is capped, and Ghosts beyond the cap stay wireframe. The frame-rate impact of a given count is best measured in game per machine (see [`docs/ghost-body-perf-matrix.md`](docs/ghost-body-perf-matrix.md)). It cannot be entered with `Tab`. If a model has no usable body mesh, or the render handshake fails, the stable wireframe is kept or restored; the mod never falls back to an expensive full-detail vehicle.

Limitations: the static mesh is the body shell only — it has **no wheels** and is **not translucent** (the paint material is opaque) — and a body may briefly stall the first time it is created. Wheels or translucency require a native vehicle, which carries a physics cost.

## Racing lines and trails

The following options are available in Settings:

- **Show ghost trail**: display a short telemetry trail behind each visible Ghost. In Driver-inputs mode this tail is drawn just like the best-lap racing line: a main line coloured by throttle/brake, a shift tick at each gear change, and the optional thin clutch (right) / handbrake (left) sub-lines (dimmed with each Ghost's rank brightness). Even a few seconds of tail read continuously because the camera stays locked on the Ghost you chase.
- **Show best lap racing line**: display the complete best-lap line.
- **Absolute speed**: color the line by speed.
- **Acceleration / braking**: color acceleration, steady speed, and braking separately (inferred from speed).
- **Driver inputs**: color by the ghost's **actual inputs** — **red for braking, green for throttle, amber for both together, white for coasting** — each dark to bright by how hard the pedal was pressed, plus a short **pink (upshift) / purple (downshift)** mark at each gear change and **blue handbrake** sections (brighter the harder it is pulled, for drifting and rallying). You can read trail-braking, throttle application, shift points, and handbrake use straight off the line. Only ghosts recorded in 2.18+ carry input data; older ghosts fall back to the Acceleration colours in this mode.
- **Show clutch sub-line** (under the racing line toggle): a thin teal line drawn just beside the best-lap line, shown only where the ghost used the clutch (brighter the further it was pressed), so launches, manual shifts and slip read without crowding the main throttle/brake colouring. Off by default; ghosts recorded before 2.18.6 carry no clutch data and draw nothing.
- **Show handbrake sub-line** (under the racing line toggle): a thin blue line to the **left** of the best-lap line, shown only where the ghost used the handbrake (brighter the harder it was pulled), for drifting and rallying. Off by default (Driver inputs mode).
- **Show live input trail (debug)**: draws your own driven trajectory behind the car whenever you drive with it on (free roam included), rendered **exactly like the best-lap racing line**: a clean main line coloured only by throttle/brake/coast/both, a pink/purple tick at each gear shift, and the optional thin clutch (right) and handbrake (left) sub-lines (sharing the racing line's two toggles). Watch your inputs in real time while tuning. Covers the whole current lap, downsampled to a configurable total segment budget (100–2000; the main line plus the shift/clutch/handbrake overlays together stay within it). Off by default; clears when the lap ends.
- **Automatic route guide**: build a route ribbon and checkpoints from the reference lap.

The route guide tries to follow mapped roads. Custom circuits and areas without navigation-road data may fall back to the original Ghost path. This does not affect recording, lap detection, or playback.

Checkpoints are drawn exactly like the start line's light pillars (two clean columns, no connecting bar). The **next checkpoint and the one after it** rise to a tall 60 m beacon so the line ahead reads from a distance, with the immediate target the widest and brightest. A checkpoint turns green only **once the car actually crosses its gate plane** (not on approach), and the next one lights up. If you **drive around** a checkpoint (cross its plane off to the side without going through it), it turns red on the spot, so a doomed lap shows immediately instead of only at the finish.

When a reference lap exists, a manually recorded lap is validated against the route: you must **pass every checkpoint in order** before re-crossing the start line for the lap to count. A lap that drives around (never comes within the pass radius of) any checkpoint is not counted — it is discarded and a fresh lap starts, with a message naming the missed checkpoint. The first lap on a fresh start line has no reference and is still recorded without a route constraint.

The best-lap line is downsampled by curvature (Douglas–Peucker): corners keep as much detail as they need, and a tight corner holds far more points than a fixed spacing would. Corners are then drawn as a short Catmull-Rom spline (the same kind of curve BeamNG's own roads use) that passes through the points and rounds the turn instead of cutting it as flat chords; straights stay straight, split back to the familiar ~6 m spacing. On an unusually long track (beyond ~24 km) that spacing widens just enough to stay under the segment budget, and the extra corner detail is counted against it too. The generated route is sampled at roughly 10 m. Every retained point is projected back onto the surface before drawing, and to protect frame rate only static segments within about 1.2 km of the camera are submitted each frame. The 100 Hz recording itself is untouched — playback, deltas and rank use full precision.

## Saved starts and vehicle changes

Saved starts belong to the map rather than one vehicle. Changing cars keeps the start, PB, and Ghost library available, and every lap shows which vehicle originally recorded it.

When upgrading from an older release, activating a saved start automatically merges records that were previously stored in separate vehicle folders. The old files remain as recovery copies, and repeated vehicle changes do not import the same lap again.

Saved starts can be renamed, deactivated, or permanently deleted. A successful rename is confirmed with a BeamNG notice. Permanent deletion requires pressing `DEL` and then `CONFIRM` within the confirmation window to protect the entire lap library from accidental removal.

## Frequently asked questions

### Why is there no Ghost on Lap 1?

A Ghost must come from a completed lap. The first lap after creating a start records the reference, and it appears automatically when Lap 2 begins.

### Why was my finish crossing not counted?

Check that you crossed in the correct direction and between the start-gate pillars. Very short laps, reverse crossings, vehicle resets, and teleport-sized position jumps are rejected. The HUD and BeamNG notice explain the rejection reason.

### Why does the generated route not follow the road center?

Road matching depends on navigation data supplied by the map. Mesh circuits, off-road surfaces, and some custom maps do not provide that data, so the guide uses the recorded Ghost path instead.

### Why does a Ghost look different from the vehicle that recorded it?

For a cross-vehicle replay, position and timing come from the original lap, while the wireframe uses the active vehicle's compatible structure.

### Why is the UI still present after disabling the mod?

Disable or remove the mod through BeamNG's Mod Manager. Ghost Racer removes its saved layout entry when the UI reloads. After enabling it again, add the app from **UI Apps** once more.

## Compatibility and limitations

- Currently developed for BeamNG.drive 0.39.
- Reads legacy Ghost Racer Replay 1.2 and 1.6 recordings.
- Legacy files do not contain speed telemetry, so some line data may be unavailable.
- Wireframe Ghosts and the Ghost body (static body mesh) do not replay wheel rotation, suspension movement, body deformation, or collisions; the Ghost body also has no wheels and is not translucent.
- Crossings, overpasses, and branching routes can occasionally confuse live route-position matching for a moment.

## Credits and license

Ghost Racer Enhanced is a community enhancement of Ghost Racer Replay:

- [Ghost Racer Replay — BeamNG Resources](https://www.beamng.com/resources/ghost-racer-replay.38554/)
- [Ghost Racer Replay — BeamNG Forums](https://www.beamng.com/threads/ghost-racer-replay.108045/)

Original author: **Jesus Goose**. Enhanced version by **flintt**. Development was assisted by **OpenAI Codex using GPT-5.6 Sol at xhigh reasoning effort**; see the [AI-assisted development disclosure](AI_DISCLOSURE.md) for its scope and responsibility statement. Covered Software is distributed under bCDDL 1.1. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the complete license and attribution details.
