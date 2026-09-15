# REDLINE

A first-person open-world survival/action game that doubles as a real
hardware stress test for high-end Android phones.

The world is a single continuous procedural map. Near the origin it is quiet
wilderness. The further out you travel, the heavier it gets — forest, then a
settlement, a town, a dense city, an industrial belt, and finally the REDLINE
zones. Geometry density, vegetation, NPC and enemy population, traffic, physics
bodies, particles, dynamic lights, shadow distance, streaming radius and draw
distance all climb with distance from the origin *and* with the selected stress
level. Playing the game and loading the GPU are the same act.

Everything is generated at runtime from a seed: meshes, materials, textures,
terrain, buildings, roads, props and creatures. There are no asset packs to
download and nothing to import.

**Engine:** Godot **4.5** (stable), Mobile renderer (Vulkan), forward-compatible
with Godot 4.4.

**Primary target:** OnePlus 12 — Snapdragon 8 Gen 3 / Adreno 750 / 24 GB,
landscape, touch.

---

## Running it on desktop

```bash
godot --path .                 # play
godot --path . --bench=standard   # boot straight into a benchmark
```

Headless validation and the automated tests need no display:

```bash
godot --headless --path . --import     # parse + resource check
tests/run_tests.sh /path/to/godot      # full suite
```

Useful command line flags:

| Flag | Effect |
| --- | --- |
| `--seed=N` | Override the world seed |
| `--stress=N` | Start at stress level 0–5 |
| `--bench=standard` \| `--bench=endurance` | Run a benchmark and print JSON |
| `--test-run=SECONDS` | Headless smoke run, prints a JSON report, exits |
| `--test-autopilot` | Walk the player on a fixed arc |
| `--test-travel` | March the player outward across chunk boundaries |
| `--test-sweep` | Cycle every quality preset and stress level while running |
| `--selftest` | Geometry orientation, determinism and safety-cap checks; prints JSON, exits |
| `--quality=0..4` | Force a quality preset |
| `--start-radius=N` | Spawn at N metres from the origin (skip the walk to the city) |
| `--time-of-day=H` | Freeze the clock at hour H |
| `--hud=0\|1\|2` | HUD off / compact / expanded telemetry |
| `--force-touch` | Show the touch layer on desktop |
| `--godmode` | Invulnerable, for screenshots and long captures |
| `--show-menu` | Boot to the title screen instead of straight into the world |
| `--safety-off` | Development only: disables the low-FPS watchdog so the UI can be captured under a software renderer. Never set in a shipped build |
| `--no-hostiles` | Development only: stops creatures spawning, so captures are not filled by something chewing on the camera |
| `--look=DEG` | Initial camera bearing |
| `--gallery-filter=SUBSTR` | Restrict `--mesh-gallery` to matching mesh keys, so one asset can be inspected at a useful size |
| `--mesh-gallery` | Lay every procedural mesh out on a grid for inspection |
| `--shots=a,b,c --shot-dir=DIR` | Save the framebuffer at those elapsed seconds |

## Building the Android APK

The project is configured for Android (landscape, Vulkan/mobile renderer,
arm64-v8a only, min SDK 24, target SDK 34, no extra permissions). Two large
third-party downloads are **not** in the repo:

1. Godot's Android **export templates** (~1 GB)
2. Android SDK **platform-tools** and **build-tools** (~200 MB), for
   `apksigner` / `zipalign`

One command installs both, wires up the debug keystore and editor settings,
and builds the APK:

```bash
tools/setup_android_export.sh /path/to/godot
adb install -r export/redline-arm64.apk
```

The default preset uses Godot's prebuilt Android template, so Android Studio
and the Gradle build path are not required. (That path is also why
`gradle_build/min_sdk` and `target_sdk` are left empty in the preset — Godot
refuses to export if they are set without Gradle enabled.)

### What the build produces

Verified with `apksigner` and `aapt2` against the artifact, not assumed:

| | |
| --- | --- |
| Size | ~27 MB |
| Package | `com.redline.stresstest` 0.1.0 |
| Native code | `arm64-v8a` only |
| minSdk / targetSdk | 24 / 35 |
| Signature | APK Signature Scheme v2 + v3, RSA 3072 |
| Orientation | `sensorLandscape` |
| Permissions | **none** |
| Declared features | `android.hardware.vulkan.level`, `android.hardware.vulkan.version` |
| Scripts | shipped as compiled bytecode (`.gdc`) |

### Looking at it without a GPU

This project was built and verified on a headless machine. Godot renders under
Xvfb with Mesa's `lavapipe` software Vulkan driver, which is slow (single-digit
FPS) but pixel-accurate — enough to catch inverted winding, broken shaders and
HUD layout collisions that no headless test can see:

```bash
apt-get install -y mesa-vulkan-drivers xvfb
xvfb-run -a -s "-screen 0 1280x720x24" \
  env VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
  godot --path . --resolution 1280x720 \
  --test-run=24 --shots=18 --shot-dir=/tmp/shots \
  --start-radius=1750 --time-of-day=20.5 --godmode --hud=2
```

`--mesh-gallery` renders every generated mesh side by side on a neutral
backdrop, which is the fastest way to check a procedural asset in isolation.

## Controls

**Touch (landscape).** Left half of the screen is a floating analogue stick —
put your thumb down anywhere and drag. Right half is look. Buttons sit under
the right thumb: FIRE, JUMP, RUN (toggle), USE. Top right: pause, HUD mode,
and stress level `+` / `-`.

**Keyboard and mouse** (for development, always available):

| Action | Key |
| --- | --- |
| Move | `WASD` / arrows |
| Look | Mouse |
| Sprint / Crouch / Jump | `Shift` / `Ctrl` / `Space` |
| Fire / Interact | `LMB` / `E` |
| Medkit / Ration | `1` / `2` |
| HUD on-off / HUD mode | `F1` / `F2` |
| Touch UI on-off | `F3` |
| Stress level down / up | `[` / `]` |
| Auto stress ramp | `\` |
| Standard / endurance benchmark | `F5` / `F6` |
| Release mouse / Pause | `Alt` / `Esc` |

## Benchmarking

`F5` runs the **standard** benchmark (~2 minutes). It teleports the player to a
fixed set of world radii with a fixed seed, holds a defined stress level at
each, walks a scripted arc so every run covers comparable geometry, and ends
with a physics storm. `F6` runs the **endurance** benchmark (~5.5 minutes),
which holds heavy stages long enough for sustained-clock behaviour to show up.

Results are written to `user://benchmarks/redline_<mode>_<unix>.json` — on
Android that is
`/storage/emulated/0/Android/data/com.redline.stresstest/files/benchmarks/`.

Recorded: duration, frame count, average / minimum / 1% low FPS, average and
worst frame time, peak measured memory, maximum stress level reached, GPU time
where the driver reports it, draw calls / objects / primitives where available,
peak world counters, and per-stage breakdowns.

**Burst vs sustained** is reported separately: the average FPS over the first
25 seconds against the last 25 seconds, plus the percentage drop. That number
is derived purely from frame timings — REDLINE reads no thermal sensor and
does not claim to measure temperature.

Any metric the platform does not expose is written as `null` in the JSON and
shown as `n/a` on screen. Nothing is estimated to fill a gap.

## Interface

The HUD is drawn rather than assembled from stock Controls — chamfered panels,
corner brackets, segmented meters and letter-spaced titles, all in a single
`_draw()` pass per layer. That keeps a 40-value telemetry panel with four live
graphs off the UI update path entirely, and makes the layout
resolution-independent, which matters on a phone in landscape.

In play you get a segmented vitals cluster, a magazine readout, an objective
card with a progress track, a heading ribbon showing your bearing, distance
from the origin and current zone, a reticle that spreads with movement and
turns red on a hostile, damage arcs pointing at what hit you, and a toast
stack. The layout moves itself: with touch controls up, the vitals and ammo
blocks slide inward clear of the stick and the action cluster, and the
navigation furniture stands down while the expanded telemetry panel is open.

`F2` cycles HUD off → compact → expanded. Compact is a corner readout with an
inline FPS sparkline. Expanded is the benchmark view: FRAME, RENDER, MEMORY and
WORLD groups plus FPS, frame time, memory and GPU graphs.

## Memory and world density

The retention cache target is **derived from the device**, not hard-coded per
preset: `AdaptiveQualityManager.device_cache_budget_mb()` takes a conservative
slice of the physical RAM the platform reports (20% on mobile, 28% on desktop)
and clamps it to a 6 GB ceiling. The preset's own figure is then clamped to
that. A fixed number is wrong in both directions — it wastes a 24 GB phone and
gets a 4 GB one killed.

Active chunks are budgeted separately from the retained ones. The retained set
is ground the player has already walked past; the active set is what is on
screen, so it gets twice the allowance. `ChunkStreamer` tracks the bytes the
chunks *actually* turned out to need — a dense city block costs far more than
open forest — and trims the streaming radius when it goes over, rather than
predicting from the radius alone.

On a 24 GB device at MELTDOWN + INSANE this resolves to roughly:

| | |
| --- | --- |
| Drawn MultiMesh instances | ~900k |
| Agents / hostiles | 2200 / 646 |
| Rigid bodies | 1200 |
| Vehicles | 320 |
| Streaming radius | 12 chunks (625 × 64 m) |
| View distance | 4000 m |
| Cache ceiling | 3 GB, ×2.5 in high-memory mode |

None of that is ballast. Every megabyte is generated terrain, instance buffers,
collision meshes and procedural textures that the renderer is reading.

## Stress levels and quality presets

Six stress levels — **ECO, NORMAL, HEAVY, EXTREME, REDLINE, MELTDOWN** — each
scale NPC and enemy counts, vehicles, rigid bodies, vegetation and grass
density, particle budget, active lights, shadow distance, streaming radius,
LOD bias, resource cache target, AI update rate, debris budget, weather
complexity and view distance. **AUTO** mode climbs a level whenever the frame
rate holds above target for nine seconds and backs off when it does not.

Five quality presets — **BATTERY, BALANCED, HIGH, ULTRA, INSANE** — set render
scale, MSAA, shadow map size and filtering, procedural texture resolution and
variant count, and multipliers over every stress parameter. The preset is
auto-detected from the reported GPU, core count and physical RAM; INSANE is
meant for flagship hardware. An adaptive safety net lowers render scale and
shadow distance if the frame rate collapses, and can be switched off.

Hard caps in `GameConfig` bound everything. A sustained sub-10 FPS reading
forces a stress reduction, and an in-progress benchmark aborts rather than
quietly changing the workload it claims to be measuring. REDLINE never
allocates memory it does not use, and never tries to destabilise the device.

## Architecture

Autoload services (`scripts/autoload/`):

| | |
| --- | --- |
| `EventBus` | Global signal hub; keeps managers decoupled |
| `GameConfig` | Tunables, hard safety caps, input map, shader globals |
| `PerformanceMonitor` | Real measurements + availability flags, ring-buffer history |
| `AdaptiveQualityManager` | Quality presets, capability detection, adaptive fallback |
| `StressDirector` | Six stress levels, AUTO ramp, resolves the effective profile |
| `GameState` | Vitals, survival pressure, inventory, objectives, run stats |
| `BenchmarkManager` | Stage driver, statistics, JSON export |

Scene-side systems (`scripts/world/`, `ai/`, `vehicles/`, `physics/`, `player/`):

`WorldManager` composes everything. `ChunkStreamer` loads and unloads 64 m
chunks around the player, generating them on `WorkerThreadPool` tasks that
touch only `PackedArrays`, realising them into scene nodes under a per-frame
microsecond budget, and retaining unloaded chunks in a byte-budgeted LRU cache
(this is the optional high-memory mode — real world data, not ballast).
`WorldGen` is the deterministic world function: height, biome, roads, density
fields, all from the seed and the coordinate alone.

`VegetationManager` and `LODManager` control how much of each chunk is drawn
via `MultiMesh.visible_instance_count` and renderer visibility ranges, so a
stress change is instant and allocation-free. `NPCManager` keeps agents in
parallel arrays and gives them four simulation tiers — full physics body,
kinematic MultiMesh, coarse background integration, dormant — with AI work
round-robined at a configurable rate. `TrafficManager` drives vehicles as lane
positions, promoting only the nearby ones to physical bodies.
`PhysicsStressManager` pools destructible props, projectiles, debris bursts,
explosions and impact particles behind hard caps. `DayNightSystem` and
`WeatherManager` drive the sun, sky, fog and the global shader uniforms every
material reads.

Procedural content (`scripts/procedural/`): `MeshBuilder` is the shared
indexed-triangle accumulator, thread-safe by construction; `MeshLib` builds
every mesh once at startup; `TextureLib` and `MaterialLib` generate all
textures and materials at a resolution and variant count that scale with the
quality preset. Replacing procedural placeholders with authored assets means
changing the bodies of those builders and nothing else.

Shaders (`shaders/`) are written for Godot's mobile renderer: no screen or
depth texture reads, no SDFGI, no SSAO/SSR/SSIL, no volumetric fog.

* **terrain** blends the biome tint with slope-selected rock across two detail
  scales, perturbs the normal from two crossed lookups (one tiles visibly), and
  reads how built-up the ground is from the vertex alpha so that organic hue
  variation applies to soil but not to concrete.
* **vegetation** sways per instance from `INSTANCE_CUSTOM`, with a vertical
  ambient-occlusion gradient baked into the vertex colours — the mobile
  renderer has no SSAO, and without it foliage reads as flat blobs.
* **building** derives a window grid from each instance's world-space scale so
  modules of different sizes line up, adds a spandrel band between floors, and
  lights a stable per-instance subset of windows after dark.
* **sky** is fully analytic: a day/dusk/night gradient, stars, a sun disc, and a
  domain-warped FBM cloud deck evaluated at reduced octave count during the
  cubemap and half-resolution passes.
* **water** is Gerstner-ish vertex motion with a scrolling normal map and a
  fresnel ramp.
* **postfx** is a transparent full-screen quad in its own CanvasLayer —
  vignette, shadow tint and grain — because the mobile renderer cannot read the
  screen buffer for a real post-process pass.

```
scenes/            main.tscn (everything else is built in code)
scripts/
  autoload/        service singletons
  core/            main, objective tracker, ring buffer
  world/           world gen, streaming, chunks, LOD, vegetation, weather, day/night
  player/          player controller, touch input
  ai/              NPC manager and pooled bodies
  vehicles/        traffic
  physics/         pooled props, pickups, destruction
  ui/              HUDs, menus, graphs, benchmark results
  procedural/      mesh builder, mesh/texture/material libraries
shaders/           terrain, vegetation, building, water, sky, instanced props
assets/icons/      generated launcher icons
tests/             headless test suite
tools/             Android export setup, debug keystore
```

## Tests

`tests/run_tests.sh` runs the whole suite headless:

1. The project imports with no parser or autoload errors.
2. `--selftest`, in one engine run with the autoloads live:
   * every script in `scripts/` compiles — the whole-project import otherwise
     collapses a syntax error anywhere into one "could not parse global class"
     line that names no file;
   * every generated mesh faces the same way as Godot's own primitives;
   * the chunk collision surface is hit from above and not from below;
   * the same seed produces identical chunks;
   * no stress level exceeds a `GameConfig` cap.
3. The world boots and streams.
4. Travelling across chunk boundaries fills the retention cache.
5. Sweeping every quality preset and stress level at runtime stays clean.
6. A high stress level genuinely produces more work than a low one.

Every assertion is made against JSON the engine itself produced.

The mesh-orientation and collision-orientation checks exist because inverted
triangle winding is silent: meshes render inside out — dark, hollow, oddly
flat — and a collision surface can only be hit from underneath, so the player
falls through the world and lands on it from below. Both cost real debugging
time here before the checks existed.
