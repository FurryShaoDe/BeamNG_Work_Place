# Changelog

## Unreleased

## 2.19.8 - 2026-09-06

- Revert the 2.19.7 `forceDetail = 0` Ghost-body change. The "blurry body" turned
  out to be the viewer's **motion blur** post-process, not the mod's level of
  detail -- turning motion blur off resolves it. Automatic LOD is restored (as
  BeamNG recommends), so distant bodies are not forced to full detail for no gain.

## 2.19.7 - 2026-09-06

- Sharpen the Ghost body. It rendered a coarse, blurry level of detail even in a
  close chase camera because automatic LOD picks a level from the object's
  screen-space pixel size, and for this per-frame teleported dynamic proxy that
  estimate came out low. The body now pins the finest LOD (`forceDetail = 0`), so
  it matches the driven vehicle's sharpness. (Not temporal-AA related; it was
  blurry with AA off too.)

## 2.19.6 - 2026-09-06

- Bring the Ghost-body wording in line with the evidence (review P1-5). The README
  no longer says the body "costs very little frame rate" or shows "a full library
  of bodies at once"; it now says the TSStatic body has no soft-body over-time
  decay (the real win over native) but still carries a real per-body render cost
  that adds up with count, with the count capped and the overflow left wireframe.
  Added docs/ghost-body-perf-matrix.md: a repeatable in-game measurement protocol
  (body count x trail x state, recording avg / 1% low / worst frame) to decide the
  body-count defaults from data. This closes the review-driven hardening pass.

## 2.19.5 - 2026-09-06

- Keep Ghost-body creation off the lap-crossing frame (review P1-6). When the
  body pool was empty at playback time (e.g. after a live backend switch that
  drains it), the renderer built every missing body in a single update, so the
  first mesh/material loads could hitch exactly as you crossed the start. It now
  builds at most one body per update: a drained pool refills over several frames
  while the group stays wireframe, then switches to bodies atomically once the
  whole set is ready. No change when the pool is already prewarmed.

## 2.19.4 - 2026-09-06

- Make the live input trail's max-segment setting a true total budget (review
  P1-3). The main line already honoured it, but the shift ticks and clutch/
  handbrake sub-lines were appended under a separate global 4000-segment cap, so
  a setting of 500 could still draw well past that. The main line now takes
  priority up to the budget and the overlays fill only what remains, so the whole
  live trail -- line plus every overlay -- stays within the chosen limit and its
  per-frame cross-VM rebuild and ground-height work stay bounded.

## 2.19.3 - 2026-09-06

- Stop the trails over-subdividing straights (review P1-4). The shared smoothing
  treated every span shorter than 6 m as a corner and split it into at least two
  Catmull pieces. That is right for the curvature-simplified best-lap line, whose
  short spans are real corners, but the fixed-grid ghost trail and the raw live
  trail sample straights densely too, so a straight run was drawn at double the
  segments for no visible gain -- and that inflation is what made the live trail's
  main line stop short of its buffer. A short span is now subdivided only when its
  smoothed curve actually bulges from the chord by more than ~6 cm, so straights
  cost one piece per span and real corners still smooth. No visible change to the
  best-lap line.

## 2.19.2 - 2026-09-06

- Align the hot-reload manifest, the static checks and the docs with the actual
  default backend (review P2-7). In-game Lua reload now also clears the
  `shellTSStaticBackend` module, so reloading no longer leaves the default body
  backend running stale cached code. Removed a dead, backwards `check.sh` guard
  that claimed "Ghosts must use the native backend" (it never matched, since the
  backend creates its object indirectly, and native is no longer the default).
  Corrected the "native (default)" console comment, restored the lost 2.16.3
  changelog heading (TSStatic became the default in 2.16.3, not 2.16.0), and
  refreshed HANDOFF/TODO version and default-since notes. No runtime behaviour
  change beyond the reload-cache fix.

## 2.19.1 - 2026-09-06

- Fix pinned ghosts (and the newest unpinned ones) being dropped on reload and
  during cross-vehicle merges. Pinning kept a ghost as a protected extra slot at
  runtime, but the manifest loader and the merge prune still capped each category
  at 20 without a pinned exception, so a category holding more than 20 records
  lost the overflow on the next load/merge and orphaned its sample file. The
  loader and the merge now treat pinned ghosts exactly as the live prune does:
  always kept, never counted against the 20-slot rotation. The "all" body-render
  comment is corrected — a library pinned past the body ceiling renders the
  overflow as wireframe rather than lifting the cap. (Review P0-1.)

## 2.19.0 - 2026-09-06

Start of the review-driven hardening pass (see docs/agent-direction-review-2026-09-06-response.md).

- Clipboard share now carries the 2.18 driver inputs (throttle, brake, gear,
  handbrake, clutch), so a shared Ghost keeps its Driver-inputs colouring after
  import instead of silently losing all inputs. The inputs ride in a separate
  optional stream, so the pose/speed stream and its fingerprint are unchanged:
  older importers still decode the same Ghost (pose-only) and duplicate detection
  is unaffected. Codes exported before 2.19 import as pose-only; a corrupt input
  stream degrades to pose-only rather than failing the whole import.

## 2.18.17 - 2026-09-06

- Fix "Set & start lap" snapping an existing start onto the car. When parked near
  an existing but inactive start, Set & start matched that start (within 8 m) and
  then overwrote its stored position with a freshly derived gate, so the old start
  looked like it jumped/moved. It now reuses and activates the matched start in
  place; only a genuinely new start (no match nearby) takes the derived gate.

## 2.18.16 - 2026-09-06

- Fix "Restart lap" forking a new start line (and, with variants, a whole new
  track group). It used to re-derive a fresh gate from wherever the car stopped
  and only reuse the existing start within an 8 m radius, so normal restart drift
  spawned a brand-new start; a match could even reposition the line or jump between
  same-spot variants. A free-roam start is now fixed once created: pressing Restart
  re-arms that same start in place — no reposition, no new line. To make a start
  elsewhere, deactivate the current one (the × button) and Set again. The HUD
  button is now labelled "Restart lap" (was "Restart lap here").

## 2.18.15 - 2026-09-06

- Unify the ghost playback trail with the best-lap racing line too. In Driver-inputs
  mode the moving tail behind a ghost now drops the in-line gear/handbrake colours
  and instead draws a shift tick and the optional thin clutch (right) / handbrake
  (left) sub-lines, exactly like the racing line and the live trail — the overlays
  dim with each ghost's rank brightness. Even a short tail reads well because the
  camera stays locked on the ghost you are chasing. All three input lines now share
  one drawing path (`emitInputOverlays` with a per-line encoder).

## 2.18.14 - 2026-09-06

- Fix the live input trail leaving clutch/handbrake sub-lines hanging past the end
  of the main line. The main line inflates while smoothing and stops at the segment
  budget partway through the buffer, but the sub-lines walked the whole buffer, so
  the oldest stretch showed a sub-line with no main line beside it. The sub-lines
  (and shift ticks) now stop exactly where the main line stops.

## 2.18.13 - 2026-09-06

- Unify the live input trail (debug) with the best-lap racing line. It now uses
  the same pipeline: a clean main line coloured only by throttle/brake/coast/both,
  a short pink/purple tick at each gear shift, and the optional thin clutch (right)
  and handbrake (left) sub-lines — all read off the raw buffer and sharing the
  same clutch/handbrake toggles as the best line. The gear/handbrake colours are
  no longer drawn in the trail body. (The ghost playback tail keeps its own short
  quick-glance colouring.)

## 2.18.12 - 2026-09-06

- Rework the Driver-inputs racing line so each input reads clearly. The main line
  now shows only throttle/brake/coast/both. A **gear shift is a short pink
  (upshift) / purple (downshift) tick across the line** at the change, since a
  shift is too brief for an in-line colour. **Handbrake gets its own optional
  sub-line** (thin blue, to the left of the line), matching the clutch sub-line
  (to the right) — so clutch and handbrake flank the main line. Both walk the raw
  samples, so brief events are never lost.
- Stop the live input trail flickering its colours. It re-simplified the rolling
  buffer every rebuild, which re-picked points and reassigned colours; it now
  smooths the fixed buffer points directly, so colours stay put and only the tip
  changes as the window scrolls.

## 2.18.11 - 2026-09-06

- Fix the clutch sub-line never appearing. It looked for the clutch on the
  simplified racing-line points, but a clutch dip during a shift is only a few
  samples and was dropped by curvature simplification, so nothing was ever drawn.
  It now walks the raw recorded samples, so brief clutch use shows even on a
  straight.
- Fix the live input trail stopping instead of scrolling. It filled a fixed
  buffer and then drew the oldest part until the budget ran out, so the recent
  trail near the car vanished. It now keeps a rolling window of the most recent
  points (sized by the max-segments setting) and draws newest-first, so old data
  is dropped and the part by the car always shows.

## 2.18.10 - 2026-09-06

- Unify how all three lines are drawn. The best-lap line, the ghost trail and the
  live input trail now share one smoothing pipeline (curvature simplification,
  Catmull-Rom spline, corner/straight piece budgeting, and the input-keep points),
  so the ghost trail and live input trail are now spline-smoothed through corners
  like the best-lap line instead of being straight polylines — while the ghost
  trail stays rock-steady frame to frame (the body is smoothed through fixed grid
  points; only the tip follows the playback head).

## 2.18.9 - 2026-09-06

- The debug live input trail now shows whenever you drive with it on, not only
  during a lap recording (that was why enabling it often showed nothing). It
  captures the car's own pose and inputs into a rolling buffer while the toggle is
  on — free roam included — and draws the most recent history, downsampled to the
  max segment count. It resets when you toggle it and clears when turned off.

## 2.18.8 - 2026-09-06

- Add a debug "live input trail": a toggle that draws your own driven trajectory
  behind the car while recording a lap, always coloured by driver inputs (the
  same red/green/amber/coast + shift/handbrake scheme), so you can watch your own
  inputs in real time for tuning. It covers the whole current lap, downsampled to
  a configurable maximum segment count (100–2000). Off by default; it clears when
  the lap ends.

## 2.18.7 - 2026-09-06

- Fix the ghost trail shimmering. The trail is built from the recording (not the
  moving body), but it downsampled the samples on a grid anchored to the playback
  head, which advances a sample or two every frame — so the whole line, and its
  colours, jittered frame to frame. The downsampling is now anchored to fixed
  sample indices, so the trail body is rock-steady; only the tip is interpolated
  to the exact playback time so it still follows the ghost smoothly.

## 2.18.6 - 2026-09-06

- Add an optional clutch sub-line. The clutch is now recorded too, and a new
  "Show clutch sub-line" toggle (under the racing line) draws a thin teal line
  just beside the best-lap line wherever the ghost used the clutch, brighter the
  further it was pressed — so clutch use (launches, manual shifts, slip) reads
  without crowding the main line's throttle/brake/coast colouring. Off by
  default; ghosts recorded before this carry no clutch data and draw nothing.

## 2.18.5 - 2026-09-06

- Show left-foot braking / trail overlap in the Driver-inputs mode: when throttle
  and brake are pressed together the line is amber (brighter by the deeper of the
  two), distinct from plain braking (red) or throttle (green).

## 2.18.4 - 2026-09-06

- Make the Driver-inputs colour continuous. The pedal-depth gradient used only a
  few brightness steps, so it looked banded; it now uses a fine 24-step gradient
  per pedal (8 for handbrake), generated smoothly, so it reads as continuous. The
  recording itself was already fine (inputs are stored to two decimals at 100 Hz)
  — the banding was purely in the colour mapping.
- Follow fast inputs on the racing line. The best-lap line kept points only by
  shape, so a braking or throttle change on a straight was smoothed away and the
  colour jumped. It now also keeps a point wherever throttle or brake swings
  quickly, so the colour gradient tracks the input there too.

## 2.18.3 - 2026-09-06

- Smooth the best-lap racing line through corners. It was drawn as straight
  chords between points, so bends looked faceted. Corners are now drawn as a
  short Catmull-Rom spline (the same kind of curve BeamNG's own roads use) that
  passes through the recorded points and rounds the turn; straights stay straight
  and capped at the familiar spacing, and the extra corner detail is counted
  against the segment budget so long tracks still fit. All colour modes keep
  their per-segment colouring.

## 2.18.2 - 2026-09-05

- Explain why Driver-inputs mode can look like it did nothing: ghosts recorded
  before 2.18 carry no pedal data, so the mode falls back to the acceleration
  colours for them — and the racing line follows your **best** ghost, which is
  usually an older PB. The app now flags whether a ghost has input data and shows
  a "No input data on this ghost — record a new lap" hint in Driver-inputs mode
  when the line/trail on screen has none. Record a fresh lap (or make one your PB)
  to see the input colours.

## 2.18.1 - 2026-09-05

- Extend the Driver-inputs line mode with gear shifts and handbrake. Each sample
  now also records the gear and handbrake, so the input line marks a **gear
  change as a short pink (upshift) or purple (downshift)** cut, and draws
  **handbrake sections in blue** (dark to bright by how hard it is pulled) for
  drifting and rallying. Shift marks and handbrake edges are kept through line
  simplification so they land in the right place and stay short. Older ghosts
  without this data are unaffected.

## 2.18.0 - 2026-09-05

- Record the ghost's actual pedal inputs (throttle and brake) with each lap, and
  add a **Driver inputs** line-telemetry mode. The racing line and ghost trail
  are coloured by what the driver was doing: **red for braking, green for
  throttle, neutral white for coasting**, and each colour goes from dark to
  bright with how hard the pedal was pressed — so you can read trail-braking into
  a corner and how early the throttle came back on. Unlike the existing
  Acceleration mode (which infers forces from speed), this shows the real inputs.
  Recording format is now 3; older ghosts have no input data and fall back to the
  Acceleration colours in this mode. Inputs are quantized to keep files compact.
  (Gear-change and handbrake markers are planned as follow-ups.)

## 2.17.15 - 2026-09-05

- Fix the ghost rows becoming two lines tall. Adding the pin button in 2.17.14
  left the row's CSS grid with one fewer column than it had buttons, so the pin
  wrapped to a second line. The row now declares a column per button, and a test
  keeps the two counts in step.

## 2.17.14 - 2026-09-05

- Pin ghosts to protect them. Each ghost row has a 📌 pin button; a pinned ghost
  is never removed by capacity pruning (and it no longer counts against the
  category's rotating quota, so it is an extra kept slot) and cannot be deleted
  until you unpin it. The pin state is saved with the ghost library and restored
  on reload.

## 2.17.13 - 2026-09-05

- Brighten and separate the checkpoint beacon colours. The target checkpoint is
  now a bright vivid yellow (was a darker amber) so it is the most eye-catching
  beacon. The following checkpoint is now a vivid azure blue — 2.17.12's "bright
  cyan" was almost identical to the greenish cyan of an idle road-matched
  checkpoint, so it did not read as different; the azure blue is clearly apart
  from both the idle cyan and the yellow target.

## 2.17.12 - 2026-09-05

- Make the next/following checkpoint beacons far easier to see. They were tall
  but thin and semi-transparent, and the following one reused the dim idle
  colour, so both washed out at a distance. The beacons are now much wider,
  brighter and more opaque, and the following one is a distinct bright cyan so it
  reads apart from the amber target.

## 2.17.11 - 2026-09-05

- Deleting the active track now re-selects the neighbouring track in the same
  start group (the previous variant, or the next one if the first was deleted)
  instead of leaving nothing selected. Deleting the only track in a group still
  clears the selection.

## 2.17.10 - 2026-09-05

- Add a bindable keybind, **Ghost Racer: Toggle app mini / full size**, that
  switches the app between its full panel and the compact mini badge — the same
  as the header − / + button — so you can collapse or expand the HUD without a
  mouse. Unbound by default; assign it in Options > Controls.

## 2.17.9 - 2026-09-05

- The next checkpoint and the one after it now rise to a tall 60 m beacon so the
  line ahead reads from a distance; the immediate target stays the widest so it
  is still clearly the nearest.
- A checkpoint you drive around now turns red on the spot (as soon as you pass
  its plane off to the side) instead of only being reported when you cross the
  finish, so a doomed lap shows immediately.
- Robustness: if a lap starts with the car already in front of the first
  checkpoint(s) — a reference whose first gate falls behind the start line —
  those gates are pre-cleared so the lap is not made impossible to complete.

## 2.17.8 - 2026-09-05

- Checkpoints are now drawn exactly like the Start Line light pillars: two clean
  light columns with a short bright core and no connecting ground bar (2.17.6
  still drew a cross bar, so they read as gates rather than pillars). The next
  checkpoint to clear uses the prominent active-start size so it stands out as
  the beacon to drive at.
- Fixed the checkpoint colour flipping on approach. It changed to "cleared" as
  soon as the car came within range of a checkpoint; now the colour only flips
  once the car body actually crosses the checkpoint's gate plane going forward,
  the same way the start line is detected. This also makes the pass/skip check
  match what you see: a checkpoint counts only when you drive through it.

## 2.17.7 - 2026-09-05

- Best-lap racing line: cap segment length and sharpen corners. The curvature
  simplification added in 2.17.5 could leave a straight as one very long chord;
  now no drawn segment exceeds ~6 m — a long chord is split back to that familiar
  spacing, so straights never look coarser than before. The corner tolerance was
  tightened (0.15 m to 0.06 m) so tight corners hold noticeably more detail than
  the cap. On an extreme-length track the length cap widens just enough to stay
  under the segment budget. The 100 Hz recording is unchanged.

## 2.17.6 - 2026-09-05

- Route checkpoints now share the start line's light-pillar look: taller glow
  columns with a short bright core instead of the old shorter posts.
- The checkpoint the lap must clear next is highlighted as a raised amber target.
  As the car passes each checkpoint its pillar turns green (cleared) and the next
  one lights up, so the route reads at a glance while driving.
- A manually recorded lap is now validated against the route. Previously any
  trajectory counted as long as it re-crossed the start line; now, when a
  reference lap exists, the lap must pass every checkpoint in order. A lap that
  skipped one is not counted — it is discarded and a fresh lap starts, with a
  message naming the missed checkpoint. The first lap on a fresh start line has
  no reference and is still recorded without a route constraint.

## 2.17.5 - 2026-09-05

- Make the best-lap racing line curvature-adaptive. It was resampled at a fixed
  ~6 m spacing, which faceted corners (and on very long tracks the segment cap
  forced it coarser still). It now uses Douglas–Peucker simplification: straights
  collapse to a couple of long segments and corners keep as much detail as they
  need, so corners are far smoother for the same segment budget. The tolerance
  loosens automatically if a lap would exceed the segment cap. The 100 Hz
  recording is unchanged; only the drawn line is affected.

## 2.17.4 - 2026-09-05

- Add track variants so several tracks can share one start position. A start is
  now a group; each variant under it has its own ghost library and finish gate.
  The Saved Start dropdown lists starts, and a second Track dropdown appears when
  a start has more than one variant. **+ New track variant here** (HUD button and
  keybind) forks a fresh track at the current start without clearing the others.
  Backward compatible: existing starts become single-track groups (each keeps its
  own gate and ghosts).

## 2.17.3 - 2026-09-05

- Fix the point-to-point finish sometimes not registering. The finish crossing
  was measured at the sampled frame, so a fast or angled pass that was already
  off to the side by the next frame was rejected. It now measures at the
  interpolated point where the path actually crosses the plane, matching the
  start gate, so those crossings count.
- Tidy the auto-lap button row. The finish control was overflowing a four-column
  grid; the row is now five columns and the finish button is a compact flag icon
  (green when point-to-point is on) beside the clear and visibility icons.

## 2.17.2 - 2026-09-05

- Draw the point-to-point finish gate in the world. It renders as a distinct
  green gate labelled FINISH, at the same prominence as the active start, and
  follows the start-gate visibility toggle, so you can see where the finish is
  instead of remembering where you placed it.

## 2.17.1 - 2026-09-05

- Add point-to-point starts. Drive to where you want the finish and press **Set
  finish** (HUD button or the new keybind) to place a finish gate; the start
  becomes a point-to-point run timed from the start crossing to the finish
  crossing. Unlike a partial, the run is saved as a completed lap with a real lap
  time and updates the PB ghost, and it no longer needs to loop back to the
  start. Re-crossing the start abandons the run and begins a fresh one; **Clear
  finish** returns to a circuit. The finish geometry is stored with the saved
  start, so it persists and restores. Adds Set/Clear finish keybinds in Options >
  Controls. (A 3D finish-gate marker is coming next.)

## 2.17.0 - 2026-09-05

- Add bindable keyboard/controller shortcuts. Three Ghost Racer actions now
  appear in Options > Controls: **Set / restart lap start**, **Toggle auto lap**,
  and **Clear lap start**. They are unbound by default (bind them yourself to
  avoid conflicts) and mirror the matching HUD buttons, so you can set a start
  and arm laps without opening the app. Free-roam only, like the buttons.

## 2.16.19 - 2026-09-05

- Stop a lap being cancelled when the track doubles back across the start gate's
  plane far from the gate (e.g. Tsukuba's hairpin). The gate is an infinite
  plane, so a crossing tens of metres off the pillars was treated as a missed
  finish and invalidated the lap, even though it was never a finish attempt. An
  off-gate crossing now only counts as a missed finish within a near-miss band
  (30 m lateral, 12 m vertical); beyond that it is ignored (logged as
  `autolap.ignore`) so the lap continues. Genuine near-misses still invalidate.

## 2.16.18 - 2026-08-30

- Fix Ghost bodies dropping to wireframe from the second lap on (every mode
  except a single best Ghost, intermittently). A new lap resets the playback
  clock to 0, but GE deliberately ignores a backward clock heartbeat unless told
  to resync -- and a seamless lap restart (the shells never went inactive) did
  not request one, so GE kept the previous lap's clock, every body was past its
  own end and hid, and only the wireframe remained. The intermittency was the
  timing race on whether playback briefly went inactive between laps. A lap
  restart now always forces a clock resync.

## 2.16.17 - 2026-08-30

- Fix the DELTA still reading against a completed lap (often the wrong sign) when
  a faster incomplete was ahead. The leader's precise time was re-matched with a
  drifting cursor that could miss the player's position on longer Ghosts, and the
  code then fell back to the single completed-lap delta. Now the leader among all
  on-track Ghosts (incomplete included) always drives the delta -- never a
  fallback to a different Ghost -- and the precise match is anchored on the
  matched trajectory point's own sample index, so it stays correct on long laps.
  Added a rank.leader diagnostic (logged only when the leader changes) naming the
  Ghost the delta is measured against.

## 2.16.16 - 2026-08-30

- Minimized-mode RANK badge now shows the field size too ("P3/12"), so the
  position reads against a known number of cars on track rather than on its own.
- DELTA and SPEED Δ now measure against the best reference on track including
  incomplete attempts, not just completed laps. Previously the delta was always
  taken against the fastest completed lap, so a partial that was actually ahead
  of you was ignored. The live standings engine picks the leader among all
  on-track Ghosts (completed and incomplete) each frame and the headline delta is
  measured against that leader's full-resolution samples, so it stays smooth.

## 2.16.15 - 2026-08-30

- Fix the app.css cache-busting version, which was stuck at 2.15.19 while the
  markup kept advancing. The game served a stale stylesheet with fresh HTML, so
  newly added controls fell back to unstyled browser defaults -- the "Ghost
  recordings" category buttons rendered as plain white with no visible selected
  state, and the minimized-mode RANK badge had no styling. The stylesheet link
  now tracks the app version, and a test locks the two together so it cannot
  drift again.
- Correct the live RANK to reflect the race you can actually see: it now ranks
  only against Ghosts currently on track -- the displayed ones -- and drops any
  that have finished and vanished (a play-once Ghost past its own end) as well as
  manual Runs. Previously it compared against the entire stored library, which
  counted Ghosts that were filtered out or already gone.
- Reposition the minimized-mode RANK badge to sit inside the circular readout
  (bottom-center) so it is legible.

## 2.16.14 - 2026-08-30

- Show a live race position (RANK) while recording a lap: where the player
  currently stands against every stored Ghost -- completed and incomplete, not
  just the displayed set -- ranked by time-to-here, the same basis as the DELTA
  readout. A Ghost that reached the player's current track position in less time
  is ahead; one that ended before reaching it counts as behind. Shown in the HUD
  in both normal mode (a RANK tile, "P3 / 12") and minimized mode (a corner
  badge), never as a toast, since the value updates continuously. It is chosen
  over a notice precisely because a toast is transient. To keep it cheap, each
  Ghost caches a downsampled trajectory (built a few per tick, then reused across
  laps) and the rank recomputes a few times a second rather than every frame.

## 2.16.13 - 2026-08-30

- Split Ghost display into two orthogonal axes so partials get first-class
  filtering. The old "Show incomplete recordings" checkbox becomes a three-way
  category control -- Completed / Incomplete / Both -- that is independent of the
  display mode (Best / Top N / All / ...). New combinations follow directly:
  Top N Incomplete shows the N longest partials, and Top N Both shows the N
  fastest laps AND the N longest partials together (up to 2N), since lap time and
  partial length are not comparable metrics and each category ranks by its own.
  Best/Single under the Incomplete category show the furthest partial. The HUD
  Ghost list mirrors the same filter. The old showIncomplete boolean is kept
  internally as a derived mirror so existing behaviour and callers are unchanged.

## 2.16.12 - 2026-08-30

- All-Ghost mode with the Ghost body enabled now renders every displayed Ghost as
  a body instead of shelling the first 10 and leaving the rest as wireframe. The
  body budget was a leftover from the native-vehicle backend, where each body was
  a fully simulated car; the default TSStatic backend is a cheap static mesh, so
  the ceiling is raised to cover a full library (completed + incomplete + manual)
  on both the vehicle and GE sides. A mix of solid bodies and wireframes side by
  side read as inconsistent; "all" is now all-body. Top-N keeps its own separate
  shell gate. Note: showing dozens of bodies at once still costs GPU; this favours
  visual consistency over a hard frame-rate cap, matching the earlier decision to
  lift the all-ghost and Top-N limits.

## 2.16.11 - 2026-08-30

- Make the reset (R key) toast actually reach the player. The controller runs in
  the vehicle Lua VM; a toast fired from there during a vehicle reset is wiped by
  the game's own reset UI teardown, so pressing R showed nothing even when a
  partial was saved -- while Insert (a lighter in-place recovery) kept its toast.
  The in-game log confirmed both keys reach the same reset hook, so the
  difference was the teardown, not the code path. The reset verdict is now
  forwarded to the GE VM (via the existing bridge) and rendered there on the next
  frame, after the reset settles, so it survives. Added GE-side showGhostMessage
  for this. Note: the toast only appears when a lap was actually recording at
  reset time; pressing R while not mid-lap has nothing to save and stays silent.

## 2.16.10 - 2026-08-29

- Stop the reset toast from lying when a partial is not actually kept. The
  R-reset save works -- the diagnostic showed every press reaches the reset hook
  with a lap recording and the partial is archived -- but the length-retention
  rule can prune it the instant it is inserted when the incomplete pool is full
  of longer partials (it is the shortest, so it is discarded first). The old
  toast still said "Incomplete lap saved", so a player who pressed R saw a save
  confirmation for a recording that was already gone, which read as "R does not
  save" for the common case of a short partial. The archive now reports the
  truth: "Incomplete recording saved" only when the partial survives insertion,
  and "Incomplete not kept · N s is shorter than all M saved partials" when the
  retention rule drops it on the spot. reset() re-announces that same verdict as
  its last step so it is not overwritten. Retention behaviour is unchanged --
  longest partials are still kept; only the feedback is now honest.

## 2.16.9 - 2026-08-29

- Confirm and surface the reset-saves-incomplete fix. The 2.16.8 trace proved the
  partial is saved on R (`archive.saved survived=true`), but the "Incomplete
  recording saved" toast fired mid-reset and was immediately overwritten by the
  reset's own status line -- and can be lost behind the game's reset feedback --
  so a player saw no confirmation and believed nothing was saved. Re-announce it
  as the last step of the reset ("Incomplete lap saved · N s · enable Show
  incomplete to view"), which also points to where the partial actually is.

## 2.16.8 - 2026-08-29

- The reset-saves-incomplete trace confirmed R does reach the reset hook with a
  lap still recording (recording=true, 970 live samples), so the save was lost
  after that. Give the incomplete archive a fallback library filename (this
  vehicle's default replay library) so a missing activeLibraryFilename can no
  longer drop it silently, and trace the archive outcome (`archive.saved` with
  id/duration/library/survived, or `archive.skip cause=addFailed`) so the next R
  press says whether it saved, and whether the length-retention prune then
  discarded it as the shortest of a full partial pool.

## 2.16.7 - 2026-08-29

- Diagnostic for the reset-saves-incomplete gap: pressing R (reset-to-recovery)
  is reported not to save an in-progress lap as an incomplete recording, while
  Insert (recover-in-place) does. Both should reach the controller reset hook
  that archives it. Trace whether that hook fires and whether a lap is still
  recording when it does (`controller.reset`), and why an archive is skipped
  (`archive.skip` notRecording/tooShort), so the next in-game R press says
  exactly where the save is lost. No behaviour change.

## 2.16.6 - 2026-08-29

- Fix the looping all-Ghost display regenerating on the wrong trigger. A real-car
  start-line crossing called playAutoLapGhost, which restarted the whole Ghost
  playback -- but in a looping display the Ghosts already run continuously on
  their own clock, so the restart left the previous cycle's trail orphaned (a
  trail with no body) and churned the visible set. The player crossing now leaves
  a live looping playback running; it still restarts playback when none is live,
  and single/best race-yourself restarts are unchanged.

## 2.16.5 - 2026-08-29

- Retain incomplete recordings by how far they got instead of by age. When the
  20-entry partial pool is full, the shortest recording (by recorded duration)
  is discarded first, and among equal lengths the oldest goes -- a longer partial
  captured more of the route and is worth keeping over a newer short one.
  Completed laps (ranked by time) and Manual Runs (newest-kept) are unchanged.

## 2.16.4 - 2026-08-29

- Lift the Ghost-body count and mode limits now that the default body is a cheap
  TSStatic mesh rather than a simulated vehicle. The body renders in every
  display mode -- all-Ghost and Multi included, not just Best/Specified/Top --
  and up to ten bodies, so Top 5 and Top 10 get bodies instead of dropping the
  whole group to wireframe. The count cap (`MAX_SHELL_GHOSTS`) rises 3 -> 10 on
  both the Vehicle and GE sides. The native BeamNGVehicle backend remains a
  console-selected fallback; driving many Ghosts on it is expensive by nature.
- Rename the toggle from "Optimized native Ghost" to "Ghost body" and drop the
  "only renders in Best/Top 3" help now that every mode is supported.
- Tests updated across the UI and the Vehicle controller to expect all-Ghost and
  Top 5 to keep the body rather than fall back to wireframe.

## 2.16.3 - 2026-08-29

- Make the non-physics TSStatic body the default Ghost backend. It was confirmed
  in game to move smoothly (the `dynamic=1` render path removed the 2.14.x
  twitch) and to hold the frame rate through Top N with no soft-body decay, so
  it no longer needs the console opt-in. The native BeamNGVehicle backend
  remains available as a fallback and for A/B measurement via
  `extensions.ghostlapping.setGhostShellBackend("native")`.
- Known TSStatic limitations still open, tracked for follow-up: the body shows
  no wheels (the chosen mesh is the body shell only), it renders opaque rather
  than translucent (the vehicle material does not honour the per-instance
  alpha), and passing the Start Line still hitches briefly.

## 2.16.2 - 2026-08-29

- The TSStatic body now builds and takes its `dynamic=1` render path in game
  (`shell.tsstatic ... dynamic=1`, mesh chosen by name), but 2.16.1 then bailed
  with `noRenderTransformApi` because this build's TSStatic exposes no
  `setRenderTransform` -- the same wall the 2.14.x DAE proxy hit. That
  requirement was written before `dynamic=1`: on the per-instance render path a
  plain `setTransform` (or even `setPosition`) may already move smoothly, so
  requiring the render transform was too strict.
- Place the body with the richest method the build actually exposes, degrading
  `setTransform` (+ optional `setRenderTransform`) -> `setPosRot` -> `setPosition`,
  and only fall back to the wireframe when none exists. Log which transform
  entry points the object has (`shell.tsstatic.api`) and which one is used
  (`shell.backend transform=...`), so the next run says definitively what this
  build supports and whether it is smooth. New spec pins the setPosRot-only path.

## 2.16.1 - 2026-08-29

- Fix the TSStatic backend never producing a body. Switching to it drains the
  proxy pool, but nothing re-triggers prewarm, and the reuse-only playback rule
  (added for the native backend to avoid on-demand spawn stalls) then left every
  Ghost on its wireframe -- the switch log showed `bodies=0 spawns=0` and the
  wireframe never suppressed, so the flat frame rate after the switch was just
  the wireframe, not a measured TSStatic body.
- A backend with no spawn stall now declares `allowsOnDemandCreate`, and the
  renderer builds its body on demand when the pool is empty. The native backend
  is unchanged: it still only reuses prewarmed bodies. So a live switch to
  TSStatic now actually renders and moves a body to measure.

## 2.16.0 - 2026-08-29

- Native-vehicle Ghosts are capped: teleporting a live soft body decays the
  frame rate (only slowed, never stopped, by the throttle), and every
  physics-suppression lever is unavailable on this build (reset ineffective,
  setActive kills rendering, no collision toggle). So bring back the non-physics
  TSStatic body -- which never decays and moves every frame for free -- as an
  opt-in backend behind the same proxy contract, to settle whether the
  render-thread twitch that retired it in 2.15.0 can be fixed.
- The likely cause of that twitch, from the TSStatic docs: an ordinary TSStatic
  is drawn by the batched static shape manager, which is not built to move. The
  new backend sets `dynamic = 1` so the object is drawn on its own
  TSShapeInstance (the per-object render path) -- the step the 2.14.x attempts
  never took -- and commits each pose to both the object and render transforms.
  Whether that removes the twitch is what the in-game test decides.
- Switch backends live from the Lua console:
  `extensions.ghostlapping.setGhostShellBackend("tsstatic")` (or `"native"`),
  then restart the replay so the pool repopulates through the chosen backend.
  Native remains the default; nothing about the native path or its tests
  changes until a player opts in. The renderer reads two capability flags from
  the active backend, so a TSStatic is neither recycled nor throttled.
- New unit spec pins the TSStatic backend: dynamic render path enabled, pose
  committed to both transforms, body-mesh discovery, reuse and hide.

## 2.15.23 - 2026-08-29

- Experiment toward breaking the smooth-versus-decay trade-off, from the insight
  that BeamNG's own replay is smooth because it suspends physics. A Ghost never
  needs to collide with anything -- it is held on its line by setPositionRotation
  and setFreeze -- and the hold/pin/drive probe showed the per-frame teleport
  decays because it keeps the soft body awake re-running its simulation and
  terrain contact. So disable dynamic collision on every Ghost body, trying
  `setDynamicCollisionEnabled(false)` on both the GE vehicle object and inside
  the Vehicle VM, each guarded and logged (`shell.collision`, `COLLISION`), so a
  build without the accessor simply keeps colliding.
- Add a console toggle to force the teleport back to every frame so the
  collision-disabled body can be compared to the throttled default in the same
  session: `extensions.ghostlapping.setGhostShellPerFrame(true)`. If the frame
  rate no longer decays at per-frame with collision off, smoothness and the
  decay fix stop pulling against each other. Off by default; 2.15.22 behaviour
  is unchanged until asked for.

## 2.15.22 - 2026-08-29

- The 2.15.21 throttle worked in game: a single moving native body held ~42-48
  fps across a whole cycle (a shallow ~5 fps sag) where per-frame teleport had
  collapsed it to ~18 over 30 seconds. With the decay that much shallower the
  body no longer needs replacing every 45 seconds, so raise the recycle interval
  to 90. Each recycle still costs a synchronous ~0.5 s vehicle load that warming
  behind the visible body cannot hide -- it removes the on-screen gap, not the
  CPU hitch -- so halving how often it runs halves that stutter. The remaining
  dips to ~35 fps in the log were exactly these recycle overlaps, not decay.
- Known trade-off: the ~30 Hz teleport is visibly less smooth than per-frame on
  a native body (the mesh holds a pose for a frame or two, then jumps), the same
  judder the old TSStatic Ghost had. Smoothness and the decay fix pull against
  each other on a live vehicle -- teleporting every frame is smooth but decays,
  throttling holds the frame rate but steps -- so the cadence stays a deliberate
  knob rather than a value pretending to be free.

- The hold/pin/drive probe from 2.15.20 finally ran and named the cause. With a
  single body and the recycle suspended: **hold** (placed once, never teleported)
  held a flat 57.7 -> 55.2 -> 55.0 fps with a flat ~6 MB Ghost-VM heap; **pin**
  (setPositionRotation every frame to one unchanging pose) fell 54.0 -> 38.9 ->
  37.8 with the heap climbing 7 -> 12 MB; **drive** (per-frame teleport plus
  movement) fell 31.7 -> 19.9 -> 17.4 -> 16.2. The decay is not the vehicle
  existing -- an untouched body sleeps and costs a fixed ~5 fps forever -- it is
  the per-frame `setPositionRotation` teleport keeping the soft body awake and
  re-running its simulation and terrain contact. This is why in-place `reset()`
  never helped and only a full teardown did, and why BeamNG's own replay plays
  back recorded node state instead of teleporting a live vehicle.
- Throttle the teleport to a real-time cadence (~30 Hz) instead of once per
  render frame. The body stays where the last teleport left it in between, so it
  is on screen the whole time while the engine repositions it far less often. A
  translucent reference Ghost reads as smooth at 30 Hz, and this directly attacks
  the named cause without an engine API BeamNG does not expose. It is mitigation,
  not elimination -- it slows the accumulation rather than stopping it -- and it
  stacks with the warm-swap recycle. The first placement and the phase probe are
  never throttled, so the probe keeps measuring the raw per-frame cost.
- Pin the cadence in the recycle test: a sub-cadence real frame must not move the
  body even as simulation time advances, and the next frame that crosses the
  cadence catches it up.

## 2.15.20 - 2026-08-29

- The 2.15.19 log settled the mechanism. With a single native body the frame
  rate is a clean sawtooth: ~45 fps on a fresh body, decaying to ~18-21 over
  ~30 seconds, snapping back the moment the 45-second recycle spawns a fresh
  one -- three cycles, each tied to that one body's age. It is not GE heap (flat
  at ~140 MB), not distance (fps and range moved independently), and not lap
  count. The cost grows with how long a single BeamNG vehicle object has existed
  and been teleported every frame, and only a full teardown clears it: the
  in-place `reset()` tried in 2.15.9 did not arrest the decay, and BeamNG has no
  way to stop a vehicle's physics while keeping it rendered (`setActive(0)` stops
  both; confirmed unsolved on the BeamNG forum).
- So the recycle stays, but its gap is closed. Tearing the old body down first
  left a window with no Ghost on screen while the replacement reloaded its
  JBeam/config (~0.5 s), and let the frame rate sag to ~18 for the last stretch
  of every cycle. Now the successor is warmed four seconds ahead of the deadline,
  spawned hidden and above the course, and the old body keeps rendering until the
  successor has finished its own Ghost/freeze handshake -- then a single pose
  call reveals it and the old one is deleted in the same frame. The load lands
  behind a body that is still on screen, so no visible frame pays for it.
- Two per-Ghost slot names alternate each recycle so the successor can coexist
  with the body it replaces, and a successor that never readies simply leaves the
  old body in place rather than reopening the gap. The lead window costs one
  extra live vehicle per recycling Ghost for those four seconds.
- The end-to-end recycle test now pins the new contract: the old body is not
  deleted until its warmed successor completes the handshake.

## 2.15.19 - 2026-08-29

- Undo 2.15.18. Its premise was a misread: an idle frame rate of exactly 30.0,
  with a 33.5 ms worst frame, was taken as the cost of holding one pooled
  vehicle. The same 30.0 and the same 33.5 ms appear with **no** Ghost vehicle in
  the world at all, and lift the moment the player touches anything, so it is
  BeamNG's own idle throttle. Removing prewarming on that basis only restored
  the roughly five-second Start Line stall prewarming existed to prevent.
- Prewarming and the reuse-only playback rule are back, along with the tests
  that pin them.
- The 45-second rebuild stays, and this log is the first evidence that it works:
  the frame rate fell to 21.3 across a replay, and after the rebuild it was
  44.5. It still costs a visible hitch, and the decay resumes afterwards, so it
  remains a stop-gap rather than an answer.

## 2.15.18 - 2026-08-29

- **The leak was not the cause.** With the player parked, nothing playing, and
  the pooled vehicle hidden, frozen and `setActive(0)`, the frame rate went from
  60.0 with no vehicle to 30.0 with one, and held at exactly 30.0 for four
  minutes. Merely having a spawned vehicle in the world is the expensive part.
  During playback the Ghost VM heap also plateaued near 16.5 MB while the frame
  rate kept falling from 38 to 22, so heap growth was a passenger rather than
  the driver — which is exactly the outcome the phase probe was built to detect.
- Stop keeping a vehicle alive between replays. Prewarming was written to avoid
  a spawn stall at the Start Line and has been measured to cost far more than it
  saves; the pool is released when playback stops and `setActive(0)` does not
  avoid the cost.
- Build the body on demand when playback starts instead, paying its half-second
  spawn once rather than holding half the frame rate for the whole session. The
  2.15.2 reuse-only rule and its test are reversed on that evidence.

## 2.15.17 - 2026-08-29

- Fix `shell.health`. `phase=%s` was added to the argument list without its
  placeholder, so the whole line printed a format error and every field in it
  was lost — the second time that exact slip has shipped, because the only test
  was that the probe toggled. There is now a test that asserts the line formats
  and still carries each field, and it fails if either placeholder or argument
  is removed.
- Suspend the 45-second rebuild while the probe runs. Swapping the vehicle
  halfway through a phase resets the heap the phase exists to measure.
- Start phase timing only once a body is actually visible. Counting from the
  moment the probe was switched on spent the entire `hold` phase before the
  Ghost had been created.
- Measure one Ghost while the probe runs. A single shared pinned pose stacked a
  Top 2/3 set in one spot, changing overlap, physics and render load together.
- Correct the TODO, which still described a forced collect that 2.15.16
  removed, and record what remains inference rather than measurement: that
  collection cost is what costs the frames, and that `GHOSTTABLES` only sees
  first-level `_G` tables so it cannot observe growth in nested tables,
  strings, closures or userdata.

## 2.15.16 - 2026-08-29

- Add a three-phase probe that separates what the retention actually responds
  to, instead of narrowing tables by guesswork: `hold` leaves a visible body and
  never calls `setPositionRotation`, `pin` calls it every frame with one
  unchanging pose, `drive` is the normal moving replay. Heap and frame rate are
  already reported every ten seconds, so one run now distinguishes "a live
  vehicle costs this", "the teleport call costs this" and "only real movement
  costs this". Off unless switched on from the Lua console — it deliberately
  shows the Ghost in the wrong place for the first minute.
- Tie the recycle clock to the vehicle rather than to the Ghost showing it. A
  parked vehicle keeps whatever its VM has retained and `setActive(0)` does not
  clear that, so reuse under another Ghost id was restarting the clock on an
  already-bloated VM.
- Stop forcing a full collect in the Ghost VM every ten seconds. That question
  is settled — a collect did not reclaim the growth — and running one on a timer
  is itself a source of the hitches being measured.
- Two claims are downgraded to what the evidence supports: that garbage
  collection cost is what costs the frames is inference, not measurement, and
  the `GHOSTTABLES` probe only counts first-level `_G` tables, so growth in
  nested tables, strings, closures or userdata would not show up in it.

## 2.15.15 - 2026-08-29

- Bound the leak by construction instead of waiting to identify it. The
  retention measured inside the Ghost VM is per vehicle and grows with how long
  that vehicle has been alive, so the body is destroyed and rebuilt every
  45 seconds of playback. A warm respawn costs about half a second and the Ghost
  falls back to its wireframe until the replacement finishes its Ghost/freeze
  handshake — a far better trade than decaying from 50 fps to 18 over the same
  period.
- A failed rebuild is not fatal: that Ghost simply keeps its wireframe until the
  next set change offers a body again.
- Report `recycles` and the interval in the shell diagnostics. The table probe
  added in 2.15.14 stays: naming what BeamNG retains would still turn this from
  a workaround into a fix.

## 2.15.14 - 2026-08-29

- A full collect inside the Ghost VM does not reclaim the growth. The heap
  *after* collecting still climbed 5.5 to 10.5 to 15.4 to 15.5 MB across forty
  seconds, so this is retention rather than collector lag, and the GE heap held
  steady at about 140 MB throughout. This mod runs no persistent code in that
  VM, which puts the retention in BeamNG's own vehicle Lua under a vehicle that
  is teleported every frame.
- Walk that VM's globals every ten seconds and report the largest tables by
  entry count. Whichever climbs is the one retaining, which is answerable
  rather than guessable.

## 2.15.13 - 2026-08-29

- The Ghost vehicle's own Lua heap is what grows: 8.9 MB to 16.9 MB over thirty
  seconds of playback, about a quarter of a megabyte per second. Collection cost
  scales with the live set, which is the frame-rate curve exactly — flat for
  twenty seconds, then compounding.
- Run a full collect inside that VM every ten seconds and log the heap on both
  sides of it. If the figure falls back, this is the fix as well as the answer;
  if it does not, something is genuinely retained in code this mod does not own.
- Fix the `shell.health` format string. An argument was added without its
  placeholder, so the whole line has been printing as a format error since
  2.15.12 rather than reporting anything.

## 2.15.12 - 2026-08-29

- The measured curve rules out a steady per-frame cost. With the player parked
  and one body on screen the frame rate held at 47-51 for the first twenty
  seconds of playback, against a 59.7 baseline, and then fell to 27 and 17.8
  over the next twenty. A single body therefore costs about ten frames; what
  follows is something that compounds.
- Report the Ghost's world position and its distance from the player in
  `shell.health`. Distance is a control variable rather than a suspect: the
  decay happens just as well when the player follows the Ghost.
- Report the Lua heap size of all three VMs — GE in `shell.health`, the player's
  controller in `shell.state`, and the Ghost vehicle's own VM as
  `GhostRacerDiag.GHOSTVM`. Everything that could be a fixed per-frame cost has
  been ruled out, so what remains compounds, and a heap that grows says both
  that something is accumulating and which side is accumulating it.

## 2.15.11 - 2026-08-29

- Report the measured frame rate, the worst frame, and the playback clock in
  `shell.health`, sampled from before a body exists so the log carries its own
  baseline. The decay has so far been the one fact that was never in a log, and
  had to be judged by eye against everything that was.
- Emit `shell.health` while playback is idle too, so the timeline shows whether
  the decay begins when a Ghost body appears or was already under way.

## 2.15.10 - 2026-08-29

- Two candidate causes are now ruled out by the log rather than by argument.
  `shell.state` reports `trail=false`, so the 2.15.7 trail-cursor fix — a real
  bug, but never shown to be on this path — cannot be the cause of the decay.
  `shell.refresh` fired every twenty seconds without arresting it, so
  accumulated soft-body deformation is not the cause either.
- Withdraw the 2.15.9 body refresh. It is disproven, it made the body blink as
  its transparency was re-applied, and a reset that failed to restore Ghost
  collision would have left a solid car on the racing line.
- Ask the Ghost vehicle's own VM which surface-effect entry points it exposes
  and log them once. A Ghost is dragged over the terrain at replay speed with
  its wheels touching, so every frame reads as a maximum-slip skid: accumulating
  skid decals match a decay that continues while the player's car is parked, is
  undone by nothing, and never happens with a wireframe. Naming the real API
  from a log beats guessing at another one.

## 2.15.9 - 2026-08-29

- The `shell.health` counters ruled out leaked vehicles: one spawn, no deletes,
  one live vehicle held steady across a minute while the frame rate fell. The
  2.15.7 trail-cursor fix is real but was never shown to be on the reported
  path, so it is not established as the cause either.
- Restore the native Ghost body every twenty seconds of playback. A body is
  dragged along its replay line by `setPositionRotation` every frame while it is
  still simulated in full, and nothing resets the node velocities a teleport
  implies. 2.15.6 tried this on a lap wrap, which could never fire for a
  660-second recording; elapsed time is what the symptom actually tracks.
- Re-apply Ghost collision immediately after a reset, and skip the reset if that
  cannot be queued. A Ghost that lost its collision mode would be a solid car on
  the racing line.
- Report a damage reading and a refresh count in `shell.health`, and record
  whether the Ghost trail is switched on in the Vehicle-side `shell.state`.
  Between them the log now separates soft-body wear from the trail search
  without another round trip.

## 2.15.8 - 2026-08-29

- Give every Ghost in Top 2 and Top 3 a native body again. The budget was cut to
  one on the strength of three bodies measuring 50 fps down to 19, and that
  measurement is not trustworthy: it was taken while every shelled Ghost froze
  its trail cursor, so most of the loss was a search growing with playback time
  rather than the vehicles. The real per-body cost is now unmeasured.
- Keep the previous-cycle trail window's search incremental as well. It was
  hinted with the last sample index, so a looping replay rescanned backwards
  from the end of the recording on every trail update — the same unbounded
  linear scan as the frozen cursor, in the other direction.

## 2.15.7 - 2026-08-29

- Fix the frame rate decaying the longer a replay runs with a native Ghost body
  on screen. The Ghost trail searches its sample array linearly from a hint, and
  that hint is the cursor the wireframe pass advances. A Ghost drawn as a native
  body skips the wireframe pass, so its cursor froze while playback ran on, and
  every trail update rescanned from that stale index to the current position.
  The cost grows with elapsed playback time, which is why the frame rate was
  fine right after `Ctrl+L`, fell away over laps, did so with a single body, and
  never happened with the wireframe. A long recording makes it far worse: a
  660-second replay holds 66008 samples, rescanned ten times a second.
- Keep the cursor following playback for a shelled Ghost.
- Withdraw the 2.15.6 per-lap body reset. It was written for a hypothesis this
  supersedes, it could not have helped a replay whose loop is 11 minutes long,
  and a reset that failed to restore Ghost collision would have left a solid car
  on the racing line. The vehicle counters it added are kept.
- Report `shell.health` every ten seconds while a body is on screen. The 2.15.6
  counters only existed inside a snapshot nothing queries during play, so they
  never reached a log.
- Stop BeamNG logging `extension unavailable: ghostRacerStart` at error level on
  every teardown: the auto extension is registered under one name and reachable
  under both, so unloading it and then trying the other name always failed.

## 2.15.6 - 2026-08-29

- Restore the native Ghost body to its pristine state on every playback loop.
  `setPositionRotation` drags a soft body that is still simulated in full and
  nothing resets its node velocities, so stress and deformation accumulate lap
  after lap and a deformed vehicle costs more to simulate than a pristine one.
  That matches a frame rate which is fine right after `Ctrl+L` and falls away
  over several laps. Damage cannot be disabled in BeamNG, so the body is reset
  instead. **This is a hypothesis, not a confirmed cause.**
- Re-apply Ghost collision immediately after a reset, and skip the reset
  entirely when that command cannot be queued. A reset re-initialises the
  vehicle's own Lua state, and a Ghost that lost its collision mode would be a
  solid car sitting on the racing line.
- Report `spawns`, `deletes`, `resets` and `liveVehicles` in the shell
  diagnostics, so the next log distinguishes accumulated deformation from
  leaked vehicles: a leak shows spawns climbing without matching deletes.

## 2.15.5 - 2026-08-29

- Render one native Ghost body instead of three. Three measured 50 fps down to
  19. Every visible body costs a fully simulated vehicle and there is no way
  around it: `controller.setFreeze` is documented by BeamNG as "Enables the
  transmission lock", not a physics freeze, so the soft body has been simulated
  in full since 2.15.0 — what actually holds a Ghost on its replay line is the
  per-frame `setPositionRotation`. The one call that does stop the simulation,
  `setActive(0)`, stops rendering with it.
- Separate the display-mode gate from the body budget. Top 2 and Top 3 still
  allow native Ghosts; the Ghosts beyond the budget keep their wireframe, which
  the per-Ghost suppression added in 2.15.3 renders correctly alongside a solid
  body.
- Correct the comment that claimed the spawned vehicles were frozen. It was
  load-bearing: it is why three simultaneous bodies looked affordable.

## 2.15.4 - 2026-08-29

- Stop native Ghost vehicles from running a player controller at all. The 2.15.2
  guard identified them through `getName` and `getJBeamFilename`, and an in-game
  log proved neither is usable that early: all three spawned vehicles still
  reported `controller.init` with `vehicleDirectory=/vehicles/simple_traffic/`.
  The vehicle directory is populated by then, so it is checked first.
- Make the controller itself go dormant when it is loaded into a native Ghost
  vehicle anyway. It does not activate its runtime context, claim the HUD, or do
  any per-frame work, so three of them cannot cost frames while driving.

## 2.15.3 - 2026-08-29

- Reject vehicle-to-GE pushes whose sender is not the player's vehicle. Start
  Line pillars, Ghost trails, best-lap lines and route guides are world state
  owned by the driven vehicle, but a native Ghost vehicle is a real
  `BeamNGVehicle` with its own Lua VM. One of them loading this controller was
  enough to overwrite that state with its own empty set, which is what made the
  pillars and the trail disappear. Ownership is enforced on the GE side, where
  it is actually known, instead of relying on every spawned VM declining to
  load the controller.
- Suppress the wireframe per Ghost rather than for the whole set. GE reports
  exactly which Ghosts have a visible native body. A set whose recordings differ
  in length always has one Ghost past its own end while the others are still
  driving, so an all-or-nothing acknowledgement never arrived and left solid
  bodies and their wireframes drawn on top of each other.
- Deactivate pooled native Ghost vehicles once their Ghost/freeze handshake is
  acknowledged. A parked vehicle is invisible, so losing its rendering costs
  nothing while it leaves the physics and audio budget; prewarm previously kept
  up to three fully simulated vehicles alive for the entire session.

## 2.15.2 - 2026-08-29

- Prewarm optimized native Ghost vehicles while playback is idle and retain
  them in a hidden, frozen pool. Crossing the Start Line is reuse-only: if a
  compatible vehicle is not ready, that lap remains fully wireframe instead of
  synchronously loading a vehicle and stalling the game.
- Stop optimized `simple_traffic` Ghost vehicles from loading the player Ghost
  Racer controller. Their empty controller state could overwrite the global GE
  Saved Start markers and make the Start Line pillars disappear.
- Make Top 5 and Top 10 pure wireframe modes with an immediate UI/controller
  notice. Top 2/3 remain eligible for native vehicles; a displayed set is only
  confirmed after every requested native body is ready.
- Preserve stable pool-slot names across GE Lua reloads, reuse compatible
  vehicles across recordings, and explicitly release the pool when native
  rendering is disabled or an incompatible display mode is selected.

## 2.15.1 - 2026-08-29

- Replace full-detail native Ghost vehicles with BeamNG 0.39's official
  `simple_traffic` variants. They remain real `BeamNGVehicle` objects and retain
  the stable native rendering path, while using simplified JBeam structures,
  meshes and materials to cut spawn stalls and sustained CPU/GPU/memory cost.
- Resolve the closest non-parked simplified config from BeamNG's vehicle catalog
  and virtual filesystem, preferring base/standard variants for the recording's
  source model.
- Refuse to spawn an expensive full-detail vehicle when a recording has no
  matching simplified variant; keep the wireframe and report the limitation.

## 2.15.0 - 2026-08-29

- Replace the experimental DAE/`TSStatic` shell with complete native
  `BeamNGVehicle` Ghosts, spawned as non-player vehicles at the replay pose.
- Keep a spawned vehicle invisible until its own Vehicle Lua VM confirms both
  `obj:setGhostEnabled(true)` and `controller.setFreeze(1)`. The first disables
  collisions with other vehicles; the second prevents gravity, terrain and the
  powertrain from moving the soft body between replay placements.
- Move native Ghosts with `setPositionRotation`, letting BeamNG's vehicle
  renderer own their meshes, materials, LOD and render history instead of
  driving an unsupported static-scene render transform.
- Retain and hide shorter Ghost vehicles at the end of their recording rather
  than reloading their complete JBeam/config on every playback loop.
- Preserve the wireframe until the native vehicle readiness handshake succeeds,
  and delete every spawned Ghost on fallback, mode changes and teardown.

## 2.14.6 - 2026-08-29

- Split shell scene-object creation and transform application into an isolated
  backend, so a future real `BeamNGVehicle` renderer can replace the current
  lightweight DAE proxy without changing replay timing or interpolation.
- Build one pose matrix per GE update and commit that exact matrix to both the
  proxy's object transform and render transform. The old `setPosRot` fallback,
  which could leave the render buffer one pose behind, is no longer used.
- Fall back to the stable wireframe when the running BeamNG build does not
  expose explicit render-transform control, instead of displaying a shell on a
  transform path known to twitch.

## 2.14.5 - 2026-08-29

- Commit persistent shell transforms during the GE update phase instead of
  `onPreRender`. Updating a `TSStatic` after scene submission has begun can make
  the render thread alternate between the previous and current transform; when
  focus is lost, updates stop and the apparent twitch disappears.

## 2.14.4 - 2026-08-29

- Remove named shell scene objects left by an older GE Lua generation before
  creating their replacements. Scene objects can survive Ctrl+L even when the
  renderer's Lua tables do not, leaving two bodies at different replay poses.
- Treat a failed shell object registration as setup failure instead of claiming
  the replacement was created, and expose stale-proxy removal in diagnostics.

## 2.14.3 - 2026-08-29

- Keep shell bodies alive across a playback loop by sending the total playback
  duration and loop state to GE, where the render-frame clock can wrap locally
  instead of waiting for a queued post-loop clock after deleting every proxy.
- Advance shell playback with `dtSim`, matching the Vehicle-side playback clock,
  so pause and slow motion cannot make the shell drift and periodically snap.
- Compare looped clock updates on a cycle, so a delayed pre-loop heartbeat that
  arrives after the local wrap cannot pull the shell back to the lap end.
- Ignore routine clock heartbeats that lag the local render clock; only an
  explicit resync may move it backwards, while a clock ahead can still recover
  simulation time missed by GE.

## 2.14.2 - 2026-08-29

- Stop drawing the wireframe on top of every shell body. The renderer confirmed that a body was rendered only once per session, while the Vehicle controller forgets that confirmation whenever it reloads, so after any reload the wireframe was never suppressed again. Two copies of the same lap were then drawn a short distance apart, which reads as flicker and doubling rather than as two Ghosts.
- Confirm on a body that was drawn rather than on one that was created, and confirm again whenever the Ghost set changes, so a proxy that outlived a controller reload still tells the new controller that the wireframe is no longer needed.
- Log when wireframe suppression starts and stops.

## 2.14.1 - 2026-08-28

- Actually rate limit the shell playback clock. 2.14.0 moved pose resolution onto the render loop so the clock could be sent occasionally, but the resend threshold was smaller than one frame of playback, so the clock still crossed the bridge every frame.
- Stop the renderer correcting towards every arriving clock value. Nudging the local clock towards a value that is always one bridge hop stale, while also advancing it locally, made the playback rate oscillate and the body surge — the same symptom the local clock exists to remove. Only a discontinuity the renderer cannot predict is applied now.

## 2.14.0 - 2026-08-28

- Stop sending shell poses across the VM bridge. The wireframe is smooth because it resolves a pose and draws it in the same frame inside one VM, while a pose pushed over the queued bridge always arrives late and in bursts. Smoothing turned the stepping into surging rather than into steady motion.
- Tell the renderer which Ghosts to show and where their recordings already live, and let it read the samples and resolve poses on its own render frames. Only the playback clock now crosses the bridge, and only when the renderer cannot predict it.
- Advance the playback clock locally between updates and absorb small corrections instead of snapping, so a late clock update cannot show up as a twitch.
- Remove a shell body once the replay clock passes the end of its own recording, and bring it back when the replay loops.

## 2.13.5 - 2026-08-28

- Remove shell bodies from the world when the mode is switched off or playback stops. The clear was swallowed by its own de-duplication: resetting the bridge marked the state as already empty, so the command that drops every body was never sent and the bodies stayed standing on the road.

## 2.13.4 - 2026-08-28

- Reapply the `Vehicle shell Ghost` and `Show manual recordings` settings when the Vehicle controller reconnects. Both were missing from the restore path, so after any controller reload the HUD kept showing the saved value while the controller had silently reverted to its default — which is why an enabled shell produced no shell activity at all.
- Add a structural check that every HUD setting which writes to Vehicle Lua is part of the restore path, so a new setting cannot be added without it.
- Advance shell bodies towards their target pose on the render loop instead of applying each pose as it arrives. Poses travel over the queued Vehicle-to-GE bridge, which does not line up with rendered frames, and applying them directly made the body step.

## 2.13.3 - 2026-08-28

- Look up the shell body mesh under the vehicle's real model directory. A Ghost library stores the sanitised vehicle directory because that is what names its replay folder, so `/vehicles/vivace/` is written as `_vehicles_vivace_`; passing that straight to the mesh lookup searched `/vehicles/_vehicles_vivace_/` and always found nothing.
- Keep drawing the wireframe until the GE side confirms a body was really rendered. The wireframe was suppressed as soon as a pose was resolved, so a shell that could not be created left nothing on screen at all.
- Resolve the player vehicle before reporting shell status, so the fallback actually reaches the Vehicle controller. Without it the report was dropped, no notice appeared, and the Vehicle side kept requesting bodies indefinitely.
- Track the displayed Ghosts rather than the ones currently within their replay clock, so the tracked set stops churning every time a Ghost runs past its own duration and returns on the next loop.
- Expose whether a shell body has been confirmed, and cover the model-name resolution and the confirmation handshake with tests.

## 2.13.2 - 2026-08-28

- Log which body mesh a shell Ghost chose, why it was chosen, and every candidate the vehicle directory offered, so the first in-game attempt can be diagnosed from the log instead of guessed at.
- Log when shell rendering starts, stops, and when a proxy is created or removed, and record the chosen mesh in the GE runtime snapshot.
- Refuse an oversized clipboard share before encoding it, instead of after a full encode, a disk write and a VM round trip.
- Document the shell diagnostics in the maintainer handoff.

## 2.13.1 - 2026-08-28

- Only accept a mesh that is recognisably the assembled vehicle body for a shell Ghost. Falling back to whatever file came first could have rendered an engine or a wheel flying down the track, and it would have looked like a working feature rather than a wrong one.
- Fix a shell Ghost freezing on its final sample once the replay looped: the pose resolver only scans forward and now restarts when the replay clock rewinds.
- Fix shell Ghosts being disabled for the rest of the session after playback stopped and resumed. Removing the bodies also discarded which vehicle each Ghost was recorded in, while the Ghost set is only resent when it changes.
- Mark clipboard-imported recordings as shared in the Ghost list, so they can be told apart from locally recorded ones.
- Show what an import skips and which Saved Start and version it came from in the replacement prompt.
- Report every reason a clipboard import stored nothing instead of only the first, so a mixed package no longer looks like a pure duplicate.
- Delete the prepared clipboard file when the GE bridge is unavailable, instead of leaving it on disk.
- Cover the guarantee that cancelling an import leaves the library untouched, run the share package through a real JSON round trip in tests, and unit-test the shell pose sync.

## 2.13.0 - 2026-08-27

- Add an experimental `Vehicle shell Ghost` mode that renders a Ghost as a semi-transparent exterior vehicle body instead of a beam wireframe. It is off by default.
- Restrict the shell to the display modes that show a bounded set of Ghosts (Dynamic best, Specified ghost, Top N) and to at most three bodies at a time, because each one instantiates real meshes.
- Create the proxies with collision and decal projection disabled, so they are visual only and take no part in physics or decal queries.
- Discover the body mesh under the vehicle's own directory at runtime, since a BeamNG vehicle has no single whole-car mesh and the file names follow no mandatory convention.
- Fall back to the wireframe for the rest of the session, with a notice naming the reason, whenever the running build or the recorded vehicle cannot provide a shell.
- Skip the wireframe pass for a Ghost already drawn as a shell, and remove every proxy on playback stop, start deactivation and all teardown paths.

## 2.12.5 - 2026-08-27

- Import a share code without requiring the recipient to select the sender's Saved Start first. The code already carries the route identity, and expecting the other player to guess which start was used defeated the point of sharing.
- Reuse a matching local Saved Start when one exists, and otherwise create it from the shared geometry, activate it, and name the created start in a notice before importing.
- Adopt a shared Time Trial route under the identity its activity resolves to, so a later Time Trial session on that track picks up the imported Ghosts.
- Keep refusing a share code recorded on a different map, and name that map in the refusal notice.
- Refuse with a clear reason when the map has already reached its Saved Start limit.

## 2.12.4 - 2026-08-27

- Fix a freshly exported share code failing its own importer with a checksum error. The fingerprint was built from the text form of each value, which differs between an integer, an integer-valued float and negative zero; quantization produces all three, and the game's Lua build hit the case the test runtime never could.
- Make the fingerprint independent of numeric representation and keep negative zero out of quantized data, so the same lap always fingerprints identically wherever it is encoded.
- Share codes generated by 2.12.0 through 2.12.3 are no longer accepted and must be exported again.
- Give manual Runs their own storage quota of 20, held separately from the 20 completed laps and the 20 incomplete recordings.
- Stop ranking manual Runs against measured laps: a hand-stopped Run has no lap time, so its elapsed time no longer places it among timed laps or evicts one.
- Carry the manual category through clipboard sharing and record it in the Ghost library manifest, so an imported manual Run stays a manual Run.
- Show the manual quota in the Ghost list footer and in the import replacement prompt.

## 2.12.3 - 2026-08-27

- Fix `Import clipboard` doing nothing at all: the HUD sent the game engine a Lua expression where a statement is required, so the command never compiled and not a single notice was shown whatever the clipboard held.
- Reject a callback-less engine command that is not a Lua statement in the UI test harness, so the same silent failure cannot return.
- Label a manually stopped recording as `MANUAL` in the Ghost list, since it has no start-gate crossing and is neither a timed lap nor a failed attempt at one.
- Add a `Show manual recordings` filter alongside the incomplete filter, with its own hidden-count hint under the Ghost list.
- Enforce both visibility filters after every display mode has chosen its ghosts, so a filtered recording can no longer be displayed through the best, top or fallback selection paths.

## 2.12.2 - 2026-08-27

- Transport clipboard Ghost samples as a base64 varint stream instead of JSON number arrays, cutting a shared lap from roughly 124 KB to 38 KB (about 3.2x smaller) so five laps now fit in under 200 KB.
- Delta-code orientation and speed alongside time and position, keeping almost every quantized value inside a single byte without changing the shared 20 Hz resolution or centimetre accuracy.
- Keep the identity fingerprint computed from the decoded sample values, so duplicate detection still recognises a lap shared before the format change.
- Accept format 1 share codes produced by 2.12.0 and 2.12.1 on import.
- Skip source samples that round into the same millisecond, which previously produced a share code the exporter accepted and every importer rejected as damaged.

## 2.12.1 - 2026-08-27

- Treat the Saved Start that owns the loaded Ghost library as the owner of those recordings even after its live functions are switched off with the HUD `x`, so deactivating a start no longer blocks clipboard sharing of its own laps.
- Keep saved-start lap statistics and the stored start geometry in the library manifest up to date for laps recorded while the start is deactivated, instead of leaving stale counters and silently erasing the recorded start block.
- Continue refusing to share a Ghost library left behind by a finished race or Time Trial, so those recordings cannot borrow an unrelated Saved Start identity.
- Keep the `Share` button clickable with nothing selected and explain the empty selection through a BeamNG notice that names the Ghost row checkbox.
- Distinguish "no Saved Start is active" from "these Ghosts belong to a finished activity" in the share refusal notice.

## 2.12.0 - 2026-08-26

- Replace the dark app icon and UI Apps thumbnail with a brighter, high-contrast orange/cyan Ghost Racer design that remains legible at 96×96 and 250×120.
- Replace the ambiguous legacy Save/Load buttons with an independent per-row share selection, compact `Share selected` clipboard export, and `Import clipboard` workflow.
- Add a versioned 20 Hz transfer codec with centimetre positions, quantized orientation/speed, checksums, a five-Ghost selection cap, and a 16 MB clipboard safety limit.
- Validate imported route identity and samples, skip known duplicate fingerprints, preserve complete/incomplete metadata and source vehicle, and assign fresh local Ghost IDs without accepting paths from clipboard data.
- Keep the existing Top 20 completed laps and newest 20 incomplete attempts: slower imports are skipped, while any import that would evict a stored lap waits for explicit Confirm/Cancel input.
- Report clipboard preparation, copy size, reading, validation, replacement confirmation, duplicate/Top-20 skips, completion, cancellation, and errors through BeamNG notices.

## 2.11.11 - 2026-08-25

- Fix BeamNG hot reloads mixing a new main controller/extension with stale extracted modules from `package.loaded`; each load now invalidates only Ghost Racer's own Vehicle/GE submodules before requiring them.
- Add a defensive migration for pre-incomplete-filter Display state and recognize legacy partial descriptors by source, reason, or `Incomplete` label as well as the `complete=false` marker.
- Protect HUD-to-controller actions and state requests with `pcall`, returning the real Lua exception to the UI instead of losing the callback after an internal controller error.

## 2.11.10 - 2026-08-25

- Normalize the incomplete filter across Boolean, numeric, and string values emitted by BeamNG's CEF/Angular layer, so a visually checked control cannot be submitted as disabled.
- Add correlated `partialFilter-...` and `partialPlay-...` diagnostics across UI and Vehicle Lua, including raw value/type, normalized/controller state, recording ID/file/sample metadata, load outcome, and playback result.
- Replace the misleading catch-all “enable Show incomplete recordings” playback message with distinct errors for a hidden filter, stale record ID, unreadable replay, display-set failure, or insufficient samples.

## 2.11.9 - 2026-08-25

- Make `Show incomplete recordings` the sole UI list filter: partial metadata remains available across controller resets, while disabled partials never render as list rows.
- Pass the current filter state together with a row `PLAY` action, atomically restoring it in a freshly loaded Vehicle controller so every visible partial can be played.
- Derive the Ghost-list visible/displayed counters from the same UI filter, preventing transient controller-state mismatches in the HUD.

## 2.11.8 - 2026-08-25

- Fix `Show incomplete recordings` so the Ghost list refreshes immediately even while gameplay updates are paused, with an additional UI-side filter preventing stale partial rows.
- Add a per-recording `PLAY` action that atomically selects and starts complete or visible partial Ghosts, changing to `VIEW` only while that Ghost is displayed.
- Let Dynamic best fall back to the newest visible partial when no completed lap exists, while continuing to exclude partials from PB, Top N, racing lines, routes, and completed-lap rankings.

## 2.11.7 - 2026-08-25

- Replace the fixed 480/500-segment long-route reduction with spatial sampling: roughly 6 m for the best-lap line and 10 m for the generated route, bounded at 4,000/2,400 retained segments.
- Reproject the denser generated route after smoothing so elevation changes no longer create long chords through or above the surface.
- Cull only the per-frame drawing of static route geometry beyond about 1.2 km from the camera, retaining full data density without scaling render cost with circuit length.

## 2.11.6 - 2026-08-25

- Preserve interrupted recordings as distinctly marked `PARTIAL` Ghosts with their stop reason and captured duration.
- Add a default-off `Show incomplete recordings` filter; visible partials can be selected, replayed, viewed, and deleted, but never affect PB, Dynamic best, Top N, route guidance, best-lap lines, or completed-lap placement.
- Retain 20 completed laps and 20 recent incomplete attempts independently per Saved Start, pruning the oldest partial without evicting a valid lap.

## 2.11.5 - 2026-08-25

- Bump release metadata and the UI/GE/Vehicle runtime version handshake to 2.11.5 without gameplay or persistence changes.

## 2.11.4 - 2026-08-25

- Coalesce delayed HUD settings replays during startup and rapid vehicle resets so only the newest task can restore the Saved Start and resend controller settings.
- Cancel the pending settings replay when the UI is destroyed, preventing stale vehicle or GE commands after Mod deactivation and UI removal.
- Add UI lifecycle regression coverage for superseded reset tasks and unload-time cancellation.

## 2.11.3 - 2026-08-25

- Identify flintt explicitly as the author of the enhanced implementation while preserving Jesus Goose's attribution as the original Ghost Racer Replay author.
- Rename the Saved Start visibility option to `Show saved start line beams`, distinguishing it from generated route checkpoints.
- Add a bilingual AI-assisted development disclosure identifying OpenAI Codex using GPT-5.6 Sol at xhigh reasoning effort, human review responsibility, and the applicable license disclaimer.

## 2.11.2 - 2026-08-24

- Move Saved Start geometry, registry identity, prepared race filenames and route state into an instance-owned runtime-context domain, removing the temporary closure snapshot adapter.
- Move Vehicle HUD timers/messages/trail-sync state and GE UI/mod cleanup flags into context-owned state, make the GE context authoritative for the active vehicle identity, and expose camera/world services as direct state domains.

## 2.11.1 - 2026-08-24

- Introduce separate, generation-scoped Vehicle and GE runtime contexts as the ownership and lifecycle foundation for the remaining state-machine refactor.
- Migrate mutable state one domain at a time while preserving gameplay behavior, UI commands and persistence formats; Saved Start geometry remains behind a temporary snapshot adapter.
- Invalidate stale contexts on controller/extension unload, release live BeamNG object references, and distinguish soft vehicle/UI resets from true runtime destruction.
- Move Vehicle Display/Settings ownership into the runtime context while preserving its public setters, manifest-backed Ghost Display mode, HUD projection and soft-reset behavior.
- Move Ghost playback ownership into the runtime context, including its clock, reference samples, progress cursors, camera state, library entries, IDs, active manifest and PB metadata, while retaining the original replay, ranking, persistence and camera behavior.
- Move recording ownership into the runtime context, including configured and active sample intervals, timing accumulators, current/last buffers and ground offset, while keeping mid-lap Record Rate and compatibility-array behavior unchanged.
- Move race and free-roam Auto Lap session ownership into the runtime context, including lap results, gate-crossing latches, rejection state and first-lap reanchoring, without changing crossing or reset behavior.
- Route Saved Start activation, Auto Lap arming/crossing/completion/discard, race preparation/completion and soft-reset state transitions through a tested session coordinator.
- Move GE Race and Time Trial ownership into runtime-context domains, including countdown/pending state, Quick Race timing, PB data, resolved race files, active profiles and Mission fallback retries.
- Route GE Quick Race/modern Race preparation, countdown, Mission fallback, completion, stop and teardown transitions through a tested lifecycle coordinator while keeping BeamNG hooks as a thin facade.

## 2.11.0 - 2026-08-24

- Split the large vehicle controller and GE extension into focused modules for replay encoding, pose math, Ghost and trail rendering, route guidance, Saved Start persistence, progress matching, UI state construction, world rendering, and Ghost camera control.
- Preserve the existing HUD commands, Lua extension/controller entry points, saved replay/start formats, and gameplay behavior while reducing the size and responsibilities of the two main runtime files.
- Add module-level regression coverage and a refactor inventory documenting ownership boundaries and the unchanged persistence contracts.

## 2.10.8 - 2026-08-23

- Preserve the selected Ghost Display mode when the player resets the vehicle with `R`.
- Split passive Top N quantity synchronization from the interactive Top N selector: HUD settings replay now updates only the remembered count and no longer calls `setGhostDisplayMode("top")`.
- Keep the existing behavior where explicitly choosing a Top N quantity switches the display mode to Top N.
- Add UI and vehicle-controller reset regression coverage for retaining `All ghosts` and its independent Top N quantity.

## 2.10.7 - 2026-08-23

- Clear Quick Race discovery state when its Scenario finishes, unloads, or returns to Freeroam, preventing the previous route from being reported as a current `missionLifecycle` Time Trial.
- Reject a cached `quickraceScenario` profile whenever no live, running Quick Race Scenario exists, and log the decision as `staleQuickraceRejected`.
- Treat finished/post Scenario objects as inactive for HUD Time Trial queries while preserving their final race-result handling.
- Keep manually placed Freeroam starts separate from activity-owned `tt-...` lines even when their position and direction overlap exactly.
- Reset cached race files, active profiles, pending starts, and countdown state on level/activity teardown.

## 2.10.6 - 2026-08-23

- Recognize the home-screen Time Trials mode through its live `scenario_scenarios` Quick Race object instead of incorrectly requiring a foreground Mission.
- Generate a stable `tt-quickrace-...` Saved Start from the official Scenario track identity, including reverse and rolling-start variants.
- Reconstruct the official Quick Race grid pose from `track.startTransform`, so `Ctrl+L` during a lap cannot move the start gate to the car's current position.
- Handle the legacy `onRaceStart`, `onRaceWaypointReached`, and `onRaceResult` events used by Quick Race, recording individual laps and avoiding duplicate final-lap completion.
- Poll the live Scenario briefly after extension reload and react to `onScenarioChange`, restoring the automatic TT gate and recording without restarting BeamNG; discard the first partial finish after a mid-lap reload so it cannot pollute the lap library.
- Expand Time Trial diagnostics with Scenario presence, Quick Race identity, race state, race file, and official-grid-pose availability.

## 2.10.5 - 2026-08-23

- Fix the concrete Rename failure exposed by 2.10.4 diagnostics: BeamNG CEF could display newly typed text while AngularJS still supplied the old `startLineNameDraft` during the button click.
- Treat the visible input DOM value as authoritative for Rename, while retaining the Angular model as a fallback for keyboard submission and test/runtime compatibility.
- Mark editing on focus, mouse-down, and model change, and suppress the 10 Hz controller state refresh while the real input remains focused so typed text cannot be restored to the prior name.
- Log both DOM and Angular model values on every Rename request, making any future input synchronization mismatch explicit.

## 2.10.4 - 2026-08-23

- Add correlated `GhostRacerDiag.UI`, `GhostRacerDiag.GE`, `GhostRacerDiag.BRIDGE`, and `GhostRacerDiag.VE` logs for Saved Start rename and `Set & start` operations.
- Record the loaded UI/controller version, active vehicle/controller identity, action trace ID, Start ID, old/new name, registry path, memory/disk revision, full line-name summary, JSON write result, and immediate disk readback.
- Record the exact Time Trial lookup result and source (`foregroundMission`, `missionLifecycle`, Race hook, or `nil`), plus Mission lifecycle data and the GE-to-vehicle controller loading bridge.
- Log and correlate stale vehicle-controller state rejected by the HUD, making multi-controller or duplicate-mod behavior directly visible from one reproduction.

## 2.10.3 - 2026-08-23

- Persist whether a Saved Start has been user-renamed, so Time Trial preparation and GO recalibration can update gate geometry without silently restoring the generated `TT · ...` label.
- Conservatively migrate every format-2 Time Trial label as user-owned, preserving custom names created before the `userNamed` flag existed.
- Add a revisioned map registry and merge newer disk state before writes, preventing a controller retained by a previously selected vehicle from reverting names or dropping newly created starts.
- Claim HUD state through the currently active vehicle controller and ignore periodic state broadcasts from inactive vehicles.
- Broaden foreground Time Trial discovery across current Mission manager shapes, keep the Race-hook profile available during activity startup, and accept Mission lifecycle payloads as either strings or tables.
- Make GE race commands load the external vehicle controller when needed and retry the Mission fallback longer, closing the startup race where the first automatic `tt-...` request was queued before the controller existed.
- Show each Saved Start's real ID and identity source in the selector, making `tt-...` creation directly verifiable instead of relying on a success message.

## 2.10.2 - 2026-08-23

- Add a foreground-Mission fallback independent of Race hooks: an active `timeTrial` mission now creates its `tt-...` start after a short grace window even when `onRaceStarted` is never published.
- Expose the current Time Trial profile to the HUD so `Set & start` creates or reuses the correct `tt-...` entry instead of falling back to an unrelated `s001` start.
- Keep the authoritative Race suffix path first; the Mission fallback waits briefly and is cancelled as soon as a Race hook identifies the activity.
- Replace the Saved Start Rename button's implicit form submission with an explicit BeamNG-safe click handler, preserve Enter submission, and stop event propagation.
- Confirm a successful rename through both the refreshed list and a BeamNG notice, while retaining explicit failure feedback when the controller or registry write rejects it.

## 2.10.1 - 2026-08-23

- Prepare the automatic TT start when `onRaceStarted` is emitted before `race.started` becomes true, instead of silently discarding the activity's only discovery event.
- Remove the `saveFileSuffix` requirement: identity now falls back through the foreground Mission ID, Race Path identity, and finally the rounded BeamNG grid pose.
- Keep pre-start discovery separate from GO so early preparation creates the gate without launching recording or Ghost playback during the countdown.
- Show the generated `tt-...` identity directly in the HUD and log its identity source under `ghostlapping.timeTrial` for in-game diagnosis.
- Add regression coverage for modern mission Time Trials without `saveFileSuffix` and activities whose `race.started` transition is their only GO signal.
- Place newly created free-roam and automatic TT start gates five metres ahead of the vehicle, then ground-sample the offset position so the car no longer sits on the gate.
- Re-anchor the immediate Lap 1 pre-recording on its first offset-gate crossing, preventing that short departure from being rejected as a completed lap.
- Bind Saved Start rename requests to an explicit start ID, retain the edit through input blur, verify the controller result, and only report success after `startLines.json` is written.

## 2.10.0 - 2026-08-23

- Recognize persistent BeamNG Time Trial activities and automatically create a map-scoped `tt-<race>` start instead of retaining an unrelated free-roam Saved Start.
- Capture the actual player-vehicle grid pose during race preparation and recalibrate it at GO, including ground-height sampling and the activity's forward direction.
- Reuse and update the same TT start on later entries, show its two-pillar gate during the race, and link it to the activity's existing Ghost/PB library.
- Cover both circuit `lastInLap` completion and point-to-point `onRaceComplete` timing paths, with regression tests for start identity, deduplication, placement, and visibility.
- Label the activity-owned start as automatic in the HUD while keeping its gate visibility available and preventing race-time rename, deletion, or manual selection.

## 2.9.9 - 2026-08-23

- Share each Saved Start's PB, Ghost library, replay samples, and generated route across vehicle changes instead of replacing the HUD with an empty vehicle-scoped library.
- Automatically merge valid 2.9.8-and-earlier vehicle-scoped replay sets into the shared map/start directory, retain the old files as recovery copies, and persist import keys so repeated vehicle replacement cannot duplicate laps.
- Preserve the recording vehicle on every replay and show it in the lap list; cross-vehicle playback keeps the saved world-space trajectory while drawing the active vehicle's compatible JBeam wireframe.
- Apply the existing 20-lap capacity policy to the combined library, retaining the fastest laps across all imported vehicles.

## 2.9.8 - 2026-08-23

- Align extension startup with BeamNG's mod loading pass and Realtime Trail's packed-mod pattern: `modScript.lua` now only registers `ghostlapping` through `setExtensionUnloadMode()` and no longer calls `extensions.load()` directly.
- Treat AngularJS `$destroy` as the authoritative UI cleanup hook, stopping the Ghost vehicle runtime, camera, markers, and ribbons without deleting BeamNG's layout-owned outer app container.
- Before unloading on mod deactivation, change the extension from manual to automatic unload mode so a later `Ctrl+L` cannot reload a disabled or deleted mod from the manual-extension registry.
- Refresh BeamNG's available-app data after removing only Ghost Racer entries from saved layouts, and add a mounted-file disappearance fallback for unpacked mods deleted outside the mod manager.
- Make lifecycle cleanup idempotent across UI close, F5, layout changes, mod deactivation, file removal, extension unload, and vehicle-runtime unload paths.

## 2.9.7 - 2026-08-23

- Move Saved Start geometry, direction, names, and active selection from the per-vehicle registry to one map-scoped `ghostReplays/freeRoam/<level>/startLines.json` registry, so changing vehicles keeps the same start gates available.
- Keep PBs, Ghost libraries, replay samples, and generated comparison routes isolated by vehicle and shared start ID; marker labels and the HUD calculate Ghost count/PB for the current vehicle only.
- Migrate each old vehicle-scoped registry when that vehicle first visits the map, resolving conflicting IDs and copying its replay JSON to the assigned shared ID while retaining the old files as recovery copies.
- Make permanent start deletion map-wide, including discovery and cleanup of the shared start's isolated Ghost set under every vehicle directory.

## 2.9.6 - 2026-08-23

- Move GE extension startup from the cached HUD directive to the mod manager's `scripts/bng_ghost/modScript.lua`, so UI reloads and `Ctrl+L` cannot reactivate a disabled mod.
- Handle BeamNG's `onModDeactivated` lifecycle explicitly: stop rendering and Ghost camera state, unload the external vehicle controller and auto-loader, remove the live HUD host, then unload the GE extension.
- Remove only `ghostRacerApp` entries from every affected saved user UI layout through BeamNG's UI Apps service, preventing `Unknown app` placeholders after disabling or deleting the mod while preserving all other HUD apps.
- Add runtime probing so a stale cached directive quietly removes itself when the owning GE extension is unavailable instead of remaining on `Connecting`.

## 2.9.5 - 2026-08-23

- Add permanent saved-start deletion with a five-second `DEL` / `CONFIRM` guard, removing the selected start's primary replay, PB sidecar, Ghost manifest, and owned per-lap sample files.
- Distinguish deactivating a start from deleting it: the `×` control now explicitly keeps the saved profile and Ghost laps, while deletion clears the active route, playback, camera, and registry entry.
- Label Saved Start profiles as vehicle-model scoped and document why changing vehicle models loads a separate set of starts and Ghosts.

## 2.9.4 - 2026-08-23

- Reduce start-line geometry to the two filled side pillars and their bright cores, removing the cross-road ground beam and three-piece direction arrow that could visibly tilt on uneven road edges.
- Keep generated route checkpoints unchanged so their paired columns and width bars still communicate each checkpoint gate's usable span.
- Raise the HUD's smallest labels and secondary text out of the 6–8 px range, brighten muted colors, strengthen typography, and add a hard one-pixel contrast edge for clearer rendering at fractional BeamNG UI scales.

## 2.9.3 - 2026-08-23

- Replace the cached custom vehicle camera mode with BeamNG's native Free Camera path, driving `core_camera.setPosRot()` directly from the interpolated Ghost pose every frame.
- Restore Game Camera, the previously selected vehicle camera mode, Free Camera transform, and FOV when leaving Ghost View.
- Treat the GE-confirmed camera state as authoritative in the HUD, show `ACTIVE / NATIVE FREE` only after actual activation, and log precise failures under `ghostlapping.camera`.
- Remove the obsolete custom `cameraModes/ghostRacer.lua` file and its static-check dependency.

## 2.9.2 - 2026-08-23

- Keep each finished Ghost's telemetry tail alive for the configured 1–5 second trail window, progressively trimming its oldest segments instead of clearing the whole ribbon at the finish.
- Preserve the previous lap's final trail window across loop restart while the new lap's opening trail grows, producing a continuous ribbon through a closed start/finish line.
- Let the same trail-length control govern both the live tail and finish linger without adding another rendering or UI setting.

## 2.9.1 - 2026-08-23

- Make each lap row's `VIEW` control select that displayed Ghost and enable Ghost View in one action; previously it only selected the camera target and left the view on the driving vehicle.
- Keep `VIEW` visible until the virtual camera is actually active, and clarify its tooltip so target selection is no longer mistaken for a completed camera switch.
- Declare the core camera extension dependency and show a one-time `Ctrl+L` recovery hint when a newly installed camera mode has not yet been registered by the running GE Lua VM.

## 2.9.0 - 2026-08-22

- Replace the frame-pair-only free-roam gate test with a latched approach/crossing state machine, retaining the last negative-side pose through the 0.2 m hysteresis zone.
- Replace the fixed 35 m frame-segment cutoff with a speed/time-aware bounded allowance so plausible high-speed or hitch-length crossings count while resets and teleports remain rejected.
- Report cooldown, minimum-lap-time, geometry, direction, speed, and discontinuity rejection reasons through BeamNG notices and an amber `MISS` HUD state.
- Suppress misleading time/speed deltas after a rejected forward finish; the next valid crossing discards the invalid attempt and starts a clean lap instead of storing a two-lap recording.
- Add a virtual Ghost camera backed by interpolated replay poses, with smooth Chase and fixed Onboard modes plus a per-visible-Ghost camera target control.
- Remember and restore the prior driver camera when Ghost View is disabled, playback ends, its target disappears, the vehicle resets, the mission ends, or the mod unloads.
- Add regression coverage for deadband crossings, long graphics frames, rejected-lap recovery, Ghost pose synchronization, both camera modes, camera restoration, and the new HUD controls.

## 2.8.1 - 2026-08-22

- Send each valid completed lap's time, saved-record rank, PB state, and capacity-discard state through BeamNG's notice API so the result remains visible with the HUD minimized.
- Keep current-lap reference progress independent from visual Ghost loop restarts, preventing a slower lap near a closed start/finish line from matching the time-zero sample and jumping to a false full-lap delta.

## 2.8.0 - 2026-08-22

- Show the just-completed lap's rank and comparison count in the HUD for both free-roam Auto Lap and BeamNG race laps; laps discarded by the 20-record limit are marked not saved.
- Add a persisted 1, 2, 3, or 5 second live Ghost-trail length control, with a bounded renderer segment budget for multi-Ghost performance.
- Reject discontinuous hybrid-road snap corrections and apply two conservative smoothing passes to locally consistent route sections, reducing navgraph edge-switch zigzags without blending road/fallback boundaries or cutting hairpins.
- Explain the minimized HUD status dot in its hover text, including gray idle/link, green ready/armed, blue playback, and red recording/error states.

## 2.7.1 - 2026-08-22

- Detect a stale vehicle controller before every HUD action, unload it through BeamNG's external-controller API, load the matching controller, restore the active saved start, and retry the original operation without restarting the game.
- Make Top N changes atomic: applying N now also selects Top N mode, returns an explicit acknowledgement, and fills the requested count past unreadable replay files.
- Return explicit acknowledgements for saved-start activation and lap deletion instead of silently accepting unsupported calls from an older controller.
- Resend enabled generated-path geometry when a saved start activates so the ribbon appears immediately even after GE Lua or controller hot reload.
- Show both UI and active controller versions in the HUD header for direct mismatch diagnosis.

## 2.7.0 - 2026-08-22

- Add a persisted Top N display mode for the fastest 2, 3, 5, or 10 saved Ghosts.
- Rank all visible Ghosts by lap time and render slower live trails progressively dimmer across five alpha tiers, while retaining the global-best halo.
- Show a saved start's generated route immediately on activation and keep it visible through vehicle reset; Ghost playback and recording still wait for the directed start crossing.
- Read the map navgraph once per route rebuild instead of once per route point, and report full, partial, unavailable-navgraph, or Ghost-fallback matching status and coverage in the HUD.
- Remove the remaining vehicle-side line-drawn start band and arrow; draw the active direction marker as three ground-aligned filled prisms alongside the filled 30-metre gate.
- Fix active-marker visibility precedence so Show start gate hides the complete active gate independently of Show saved checkpoint beams.
- Replace the ambiguous lap-delete glyph with a five-second DEL/CONFIRM flow and surface the controller's real success or failure result.
- Expand controller, GE renderer, and UI regression coverage for Top N persistence, trail brightness ranking, route activation/match feedback, filled arrows, gate visibility, and deletion acknowledgement.

## 2.6.2 - 2026-08-22

- Replace the version-sensitive `drawTriSolid` ribbon path with one four-point `drawQuadSolid` call using the required depth-test argument.
- Convert ribbon vertices to `Point3F` when supported by the running BeamNG build.
- Probe the solid binding once under `pcall`; an incompatible build now logs one warning and permanently falls back to horizontal ground lines instead of throwing from `onPreRender` every frame and stalling camera updates.

## 2.6.1 - 2026-08-22

- Add per-lap deletion from the Ghost list with a two-click, three-second confirmation guard.
- Delete removed lap sample files and reconcile the primary PB file, sidecar time, manifest, generated route, best-lap line, and saved-start statistics.
- Change the 20-lap capacity policy to insert first and then discard the longest lap across the full library, while always retaining the fastest lap.
- Remove automatically discarded sample files so repeated capacity pruning does not leave orphaned replays.

## 2.6.0 - 2026-08-22

- Replace direct Ghost-route drawing with hybrid map matching: Ghost samples constrain sequence while valid nearby navgraph edges provide road centers, headings, and checkpoint widths.
- Color road-matched route segments and checkpoints cyan, with amber Ghost-line fallback for missing, vertically invalid, discontinuous, or directionally incompatible road data.
- Replace vertical square-prism route and telemetry strips with ground-plane solid triangles, retaining a horizontal line fallback for older debug drawers.
- Add a persisted Show best lap racing line switch for a full PB line colored by the selected absolute-speed or acceleration/braking telemetry mode.
- Distinguish live trails by lap class: the fastest Ghost uses a wider saturated strip plus halo, while other visible Ghosts use thinner muted strips.
- Bound the full best-lap line to 500 segments and keep route visibility changes separate from geometry/map-matching updates.

## 2.5.1 - 2026-08-22

- Automatically arm Auto Lap when a saved start is restored on a fresh game or selected from the route list.
- Start recording, saved Ghost playback, and the generated route together on the first valid forward crossing without requiring a second Arm click.
- Preserve the armed crossing workflow after vehicle reset while keeping route geometry hidden until the crossing occurs.

## 2.5.0 - 2026-08-22

- Generate a closed, ground-projected route from the active comparison ghost without storing a second route file.
- Automatically show the generated route after Set & Start, an armed forward crossing, or the first completed lap when no history existed.
- Add filled cyan path ribbons plus numbered two-beam checkpoints at configurable target spacing, automatically widening very long routes to retain full-lap coverage within 60 markers.
- Bound route synchronization to 500 path points and 60 checkpoints, rebuilding only when the comparison ghost or spacing changes.
- Add independent route-guide, path-ribbon, and checkpoint visibility controls with persisted UI settings and live route statistics.
- Hide the route after vehicle reset until the next valid start crossing, while preserving the generated data and saved Ghost source.

## 2.4.4 - 2026-08-22

- Made a newly completed first free-roam lap start its ghost automatically on lap 2 after explicitly refreshing the active ghost selection.
- Held auto-lap ghost playback at zero for its first render frame so the ghost is visibly placed on the start line before advancing.
- Added an exported playback clock for runtime diagnostics and regression coverage for the first-lap transition.
- Made the packaging script refuse to build from an uncommitted Git worktree.

## 2.4.3 - 2026-08-22

- Removed the additional `position_marker.dae` scene objects so the start gate contains no thin-pillar silhouette alongside the filled beams.
- Added hot-reload cleanup for any marker scene objects left behind by 2.4.2.
- Changed Set Start into Set & Start: placing or resetting the line now enables Auto Lap, starts lap 1, begins recording immediately, and launches the selected ghost set.
- Kept Arm Auto Lap as the crossing-triggered workflow for restored or manually selected saved starts.

## 2.4.2 - 2026-08-22

- Replaced the vehicle-side wireframe start posts with BeamNG `TSStatic` scene objects using the built-in `art/shapes/interface/position_marker.dae` marker.
- Replaced outlined debug cylinders with filled 30-metre square-prism beams, six-metre bright cores, and a filled ground bar.
- Moved telemetry trail rendering to GE Lua and replaced five parallel `drawLine` calls with 68 cm wide, seven-centimetre-thick filled prisms.
- Limited trail geometry synchronization to 10 Hz while reusing the latest filled geometry every render frame.
- Added explicit cleanup for generated marker scene objects and GE trail geometry on hide, mission end, and mod unload.

## 2.4.1 - 2026-08-22

- Rebuilt every dropdown as a two-line selection card with a drawn chevron, descriptive option rows, radio indicators, and an explicit current-value badge.
- Added versioned template and stylesheet URLs so BeamNG CEF does not keep showing the previous cached dropdown design after an update.

## 2.4.0 - 2026-08-22

- Added solid GE-rendered checkpoint markers: two 30-metre translucent light columns, bright six-metre cores, endpoint glows, and a solid ground beam.
- Converted telemetry trails into 48 cm five-line ribbons and ground-aligned them using a per-recording reference-height offset.
- Moved the synchronized group-loop switch into the main Ghost Display header and clarified that all ghosts restart after the longest visible ghost finishes.
- Restyled custom dropdowns as compact floating menus with a narrow accent, restrained selection highlight, and explicit check mark.
- Added per-map, per-vehicle saved-start registries with up to 20 named start profiles.
- Bound every saved start profile to an independent replay, ghost manifest, PB, and ghost count.
- Added automatic restoration after vehicle replacement/Insert and game restart, while preserving in-memory state on soft reset.
- Added optional saved-checkpoint visualization plus in-world labels containing profile name, ghost count, and PB.
- Added inline start-profile selection and renaming to the HUD.
- Added migration from the previous single `freeRoam/.../ghostracer.save.json` layout.
- Added controller, UI, and GE rendering regression tests for reset persistence, independent start libraries, loop behavior, trail width, and checkpoint primitives.

## 2.3.3 - 2026-08-22

- Raycast the center, both edges, every stripe edge, and the direction-arrow points onto static road geometry when the start line is set.
- Keep the rendered gate only 3.5 cm above the sampled surface to prevent floating while avoiding z-fighting.
- Replace the thin five-line marker with a one-metre-wide, high-contrast ladder start band.
- Alternate white and state-colored lines so the marker remains readable on both light and dark asphalt.
- Increase beacon columns to four metres, enlarge their footprint and cap, and add a white middle ring.
- Added a banked-road regression test that verifies both ends of the start band follow the sampled surface.

## 2.3.2 - 2026-08-22

- Replaced the temporary option grids with compact custom dropdowns that remain reliable in BeamNG CEF.
- Show the current value in the collapsed control with an orange status dot.
- Highlight the active row and add a check mark when a dropdown is open.
- Close custom dropdowns after selection or when clicking elsewhere, and clean up the document listener when the HUD is destroyed.

## 2.3.1 - 2026-08-22

- Replaced all native select menus with always-visible button groups for BeamNG CEF compatibility.
- Rebuilt the free-roam start gate as two tall wireframe beacon posts, five ground stripes, and a thick forward arrow.
- Moved the visible beacon posts closer to the road while retaining the existing crossing tolerance.
- Hid side/offset telemetry while Auto Lap is disabled and rewrote the armed diagnostics in plain directional language.
- Added an inline start-gate visibility button beside the Auto Lap controls.
- Destroy and remove the mounted HUD when the GE extension unloads, preventing a stale control panel after disabling the mod.
- Added regression coverage for all option buttons, gate geometry, and live UI removal.

## 2.3.0 - 2026-08-22

- Added an optional three-second telemetry trail behind every visible ghost.
- Added absolute-speed coloring from low-speed blue through high-speed red.
- Added longitudinal acceleration coloring with red/orange braking, neutral light tones, and green acceleration.
- Decimated trail rendering to approximately ten segments per second per ghost to bound multi-ghost draw cost.
- Added persisted Show ghost trail and Trail telemetry settings plus an inline color legend.
- Rendered legacy ghosts without speed samples in neutral gray instead of false zero-speed telemetry colors.
- Added controller and UI tests for trail visibility, telemetry mode dispatch, state export, and actual draw calls.

## 2.2.2 - 2026-08-22

- Added a low-overhead free-roam start gate made from a ground line, two vertical posts, and a forward direction arrow.
- Added a persisted Show start gate checkbox that affects visualization only, not lap detection.
- Color-coded the gate cyan when ready, orange when armed, and green during an active lap.
- Labeled the orange HUD bar as Ghost playback and clarified that it represents replay time rather than current-car track progress.

## 2.2.1 - 2026-08-22

- Derived free-roam gate speed from world-space signed-distance movement instead of the vehicle velocity vector, preventing valid finish crossings from being rejected by coordinate-frame differences.
- Added live start-line side/offset telemetry and explicit rejection reasons for wrong-direction, out-of-width, vertical, and low-speed crossings.
- Renamed the ambiguous Auto on/off control to Arm auto lap / Auto armed and clarified that the first crossing starts lap 1 while the next crossing completes it.
- Decoupled the ghost-mode dropdown model from the 10 Hz controller state stream and paused synchronization while the select control is focused.
- Added automated forward/reverse free-roam crossing tests and made Lua test failures fail the check script reliably.

## 2.2.0 - 2026-08-21

- Made the main panel fill the BeamNG app height and scroll internally when its content is taller.
- Synchronized minimized dimensions with the BeamNG app host and enforced a 104 px circular gauge footprint.
- Split race preparation from race start: ghosts preload during countdown and play exactly once after `onCountdownEnded`.
- Added idempotent race-start handling plus a short fallback for activities without a countdown.
- Added per-track ghost libraries with dynamic-best, specified, multi-select, and all-ghost display modes.
- Stored each lap in an independent replay file behind a lightweight manifest and lazily loaded only visible ghosts.
- Retained up to 20 laps per library while protecting the fastest timed lap from normal pruning.
- Added a scrollable, color-coded ghost selector with fastest and visible indicators.

## 2.1.0 - 2026-08-21

- Added a direction-aware free-roam start/finish line with automatic lap start,
  finish, PB promotion, persistence, and immediate next-lap ghost playback.
- Added crossing width, vertical, forward-speed, minimum-lap, cooldown, and teleport guards.
- Added Auto Lap setup, arming, lap state, and clear controls to the main HUD.
- Replaced the minimized pill with a circular delta/speed gauge and progress ring.
- Persisted free-roam PBs by level and vehicle and reload them when a nearby line
  is set again in the same direction.

## 2.0.7 - 2026-08-21

- Detect the real registered controller with `controller.getController()`
  instead of mistaking BeamNG's callable `nilController` placeholder for a
  successful connection.
- Remove `nilController` calls from race lifecycle command dispatch.

## 2.0.6 - 2026-08-21

- Return controller load and registration results through BeamNG's active-object
  callback instead of relying only on vehicle-to-UI hooks.
- Distinguish a missing active vehicle response from an external-controller load
  error directly in the HUD.

## 2.0.5 - 2026-08-21

- Register the external vehicle controller with BeamNG's current three-argument
  `loadControllerExternal(path, name, config)` form in both automatic and HUD
  fallback loading paths.

## 2.0.4 - 2026-08-21

- Show the loaded UI code version directly in the HUD.
- Include the vehicle-controller code version in state updates.
- Replace indefinite `Connecting…` with a timeout, an actionable error message,
  and a retry button.
- Report external-controller load failures back to the HUD.

## 2.0.3 - 2026-08-21

- Correctly treat BeamNG's empty safe-controller table as disconnected so the
  HUD fallback actually loads the ghost controller.

## 2.0.2 - 2026-08-21

- Load the vehicle-side ghost controller on demand when the HUD first connects,
  including when the Mod is enabled after the current vehicle has spawned.

## 2.0.1 - 2026-08-21

- Fixed the AngularJS template root so the HUD renders after being added to a layout.

## 2.0.0 - 2026-08-21

- Based the fork on the official Ghost Racer Replay 1.6 repository release.
- Replaced destructive playback queues with an indexed playback cursor.
- Removed full-lap deep copies from recording and playback transitions.
- Added compact, timestamped replay schema version 2 with speed samples.
- Added backward loading for 1.2/1.6 replay arrays and `.time` sidecars.
- Added configurable 20–100 Hz sampling and a 30-minute recording guard.
- Precomputed structural beam and node render caches for ten quality levels.
- Added normalized orientation interpolation with up-vector re-orthogonalization.
- Added 10 Hz UI telemetry, PB display, track-position time delta, and speed delta.
- Scoped automatic race saves by level and race while retaining legacy lookup.
- Exported and hardened point-to-point race completion handling.
- Replaced the original button grid with a stateful, compact HUD and settings panel.
- Replaced the outdated six-button app thumbnail with a 250x120 ghost-car and telemetry graphic.
