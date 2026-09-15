# REDLINE — engineering handoff

A first-person 3D open-world survival/action game in **Godot 4.5-stable** that
doubles as a real Android hardware stress test. Target device: **OnePlus 12**
(Snapdragon 8 Gen 3, Adreno 750, 24 GB RAM), landscape, touch, Vulkan mobile
renderer.

This file is the working context for anyone — human or AI — picking the project
up. It records what exists, what is known-broken, the traps that have already
cost a day each, and how to actually see a frame.

- Repo: `jimmylovnjames/android-maximum-`
- Working branch: `claude/redline-android-game-b7qj9a` (push only here)
- Engine: Godot 4.5-stable, Mobile renderer, GDScript with static typing
- ~12,000 lines of GDScript + 8 shaders, all assets procedural (no binary art)

---

## 1. Hard rules for this project

These come from the original brief and are not negotiable:

1. **Never fabricate build or test results.** Report actual command output and
   actual failures.
2. **Never invent a measurement.** No temperature sensor claims unless an API
   really provides the value. Unavailable metrics must be *labelled*
   unavailable in the HUD, not filled with a plausible number.
3. **Memory pressure must come from legitimate game resources** — meshes,
   textures, chunk caches, physics bodies. Never allocate useless blocks of
   RAM to move a number.
4. **Safety caps are real and must stay.** Hard instance caps, memory-failure
   handling, automatic stress reduction after sustained very low FPS. No
   deliberate OOM, no deliberate device crash, no unbounded spawning.
5. Do not open a pull request unless explicitly asked.

---

## 2. Layout

```
project.godot            mobile renderer, sensorLandscape, vsync off, 7 autoloads
export_presets.cfg       Android arm64 preset (see §7 for the SDK trap)
scripts/
  autoload/              EventBus, GameConfig, PerformanceMonitor,
                         AdaptiveQualityManager, StressDirector, GameState,
                         BenchmarkManager   (loaded in that order)
  core/                  main.gd (CLI + bootstrap), self_test.gd, mesh_gallery.gd,
                         objective_tracker.gd, ring_buffer.gd
  world/                 world_gen.gd (the deterministic world function),
                         chunk_generator.gd (all placement), chunk.gd (realisation),
                         chunk_streamer.gd (threads + LRU), world_manager.gd,
                         day_night_system.gd, weather_manager.gd, lod_manager.gd,
                         vegetation_manager.gd, instance_batch.gd, chunk_data.gd
  procedural/            mesh_builder.gd, mesh_lib.gd, texture_lib.gd, material_lib.gd
  player/                player_controller.gd, touch_input.gd
  ai/                    npc_manager.gd, npc_body.gd
  vehicles/              traffic_manager.gd
  physics/               physics_stress_manager.gd, prop_body.gd, pickup.gd
  ui/                    ui_theme.gd + 6 custom-drawn Controls (single _draw pass each)
shaders/                 terrain, building, prop_instanced, vegetation, neon,
                         sky, water, postfx
tests/run_tests.sh       46 assertions across 5 headless scenarios
tools/setup_android_export.sh, tools/debug.keystore
```

### Data flow

```
WorldGen (pure function of seed+coord)
   -> ChunkGenerator.generate()          [runs on WorkerThreadPool, PackedArrays only]
      -> ChunkData { terrain_lods, collision_faces, batches, spawns, light_spots }
   -> ChunkStreamer                      [frame-budgeted realisation, byte-budget LRU]
      -> Chunk.realize()                 [MultiMeshInstance3D per batch, staged]
         -> LODManager / VegetationManager set visible_instance_count + ranges
```

`StressDirector` (six levels) x `AdaptiveQualityManager` (five presets) produce
one merged profile dictionary that every manager reads in `apply_profile()`.

---

## 3. Conventions that will bite you

### 3.1 Triangle winding
Godot's front faces are **clockwise**. `MeshBuilder.add_triangle(a,b,c)` takes
indices in *counter-clockwise* order as seen from the front and swaps `b`/`c`
internally. This is the single conversion point — do not "fix" winding anywhere
else. `ConcavePolygonShape3D` is one-sided and uses the same convention; a
collision mesh with the wrong winding is only hittable from below and the
player falls through the world.

`--selftest` checks mesh and collision orientation against Godot's own
`BoxMesh`/`SphereMesh` by signed volume. Run it after touching geometry.

### 3.2 MultiMesh buffer layout
Flat float buffer, **20 floats per instance**: 12 transform + 4 colour +
4 custom. `InstanceBatch` owns this. Density is controlled with
`visible_instance_count`, never by rebuilding the buffer.

### 3.3 `varying` is interpolated — use `varying flat`
**This caused the worst artefact in the project.** A per-instance constant
passed as a plain `varying` is interpolated across the triangle, which
introduces ~1e-5 of float error. `hash21()` squares its input, so that error
came out as a completely different hash on every pixel and every lit window
rendered as crawling white speckle.

Godot's syntax is `varying flat float x;` — **not** `flat varying`, which is a
shader compile error.

Anything derived from `INSTANCE_CUSTOM`, `MODEL_MATRIX[3]`, or `NORMAL` that
feeds a hash or a `step()` threshold must be `varying flat`. Already applied in
`building.gdshader`, `prop_instanced.gdshader`, `neon.gdshader`.

### 3.4 Shadow bias — under-biasing looks exactly like texture aliasing
`shadow_bias` and `shadow_normal_bias` on the sun were set to 0.028 / 1.1,
below Godot's own defaults of 0.1 / 2.0. On a large flat surface seen at a
grazing angle — which is what a road is, most of the time — that produced
shadow acne as radial streaks converging on the camera, over every ground
surface in the game.

It was mistaken for texture-filtering aliasing for a long time. The bisection
that settled it: replace every texture term in `terrain.gdshader` with flat
vertex colour and re-render. The streaks survived, so they were never a
texture problem. Measured horizontal roughness over a patch of road: **3.42
before, 0.43 after** raising the bias to 0.06 / 2.4.

If you see fine regular structure on the ground, measure it before theorising:

```python
px = Image.open(shot).crop(box).convert('L').load()
# mean absolute horizontal neighbour difference
```

### 3.5 Large world-space UVs lose mantissa bits
A world X of ~1450 times a texture scale of 0.18 gives a UV around 260.
float32 has so few bits left at that magnitude that the lookup jitters by a
couple of texels per pixel, which renders as a fixed dither pattern.

Terrain detail UVs are built from the **chunk-local** vertex position
(0..64) instead, and `detail_scale` is 0.25 so the 4 m tiling period divides
the 64 m chunk exactly and stays continuous across seams. Any new rate applied
to `duv` must also be an exact divisor (0.25, 0.5) or it reintroduces a seam.

The prop shader wraps the instance origin to 32 m for the same reason.

### 3.6 Ambient leaks into the sky background
With `background_mode = BG_SKY`, lowering `ambient_light_sky_contribution`
paints `ambient_light_color` over the sky as a flat wash. Measured on one
frame: the night sky went from RGB `4,0,0` at contribution 0.85 to `128,91,49`
at 0.06. Raising `ambient_light_energy` leaks far less but still leaks.

**Therefore:** urban night light pollution is an *emission* term in
`building.gdshader` and `terrain.gdshader`, driven by the global
`redline_urban_night`, not an ambient lift.

### 3.7 Mobile renderer limits
No screen/depth texture reads, no SDFGI/SSAO/SSR/SSIL, no volumetric fog. Post
process is a transparent `CanvasLayer` quad (`postfx.gdshader`). The shoreline
foam is computed from vertex height against the water plane because there is no
depth buffer to intersect.

### 3.8 Runtime gotchas already hit
- `global_shader_parameter_get_list()` is editor-only and logs a performance
  error at runtime. `GameConfig._global_float()` just calls `add` then `set`.
- `ResourceLoader.load(..., CACHE_MODE_IGNORE)` recompiles executing scripts and
  **segfaults**. Use plain `load()`.
- A realtime `Sky` forces a 256 px radiance map. Use
  `Sky.PROCESS_MODE_INCREMENTAL`.
- `Environment.set_glow_level()` is **0-indexed**; the inspector labels the same
  slots 1..7.
- `fract()` does not exist in GDScript. Use `v - floor(v)`.
- `pkill -f "godot --headless"` matches your own shell's command line and kills
  it. Use `pkill -x godot`.
- `godot --check-only --script X.gd` runs without autoloads, so "identifier not
  found" for `GameConfig` etc. is expected noise there.

### 3.9 Shader globals
Registered in `GameConfig`: `redline_night`, `redline_wind`, `redline_wetness`,
`redline_urban_night`. Set each frame by `DayNightSystem` / `WeatherManager`.

---

## 4. How to actually see a frame

There is no GPU on the dev box. Mesa **lavapipe** (software Vulkan) + **Xvfb**
produce real frames. It is slow (~4 FPS at HEAVY) but it is the only thing that
has caught the real bugs — every winding error, the bloom blowout, the window
speckle and the sign orientation were invisible to headless tests.

```bash
xvfb-run -a -s "-screen 0 1280x720x24" \
  env VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
  godot --path . --resolution 1280x720 \
    --test-run=40 --shots=30 --shot-dir=/tmp/shots \
    --stress=2 --quality=2 --start-radius=1760 --time-of-day=20.4 \
    --godmode --no-hostiles --no-ui --look=95 --pitch=6 --safety-off
```

### CLI flags (`scripts/core/main.gd::_parse_cli`)

| Flag | Meaning |
|---|---|
| `--test-run=SEC` | headless smoke run, prints a JSON report and quits |
| `--bench=standard\|endurance` | run the benchmark driver |
| `--seed=N` | world seed |
| `--stress=0..5` | ECO / NORMAL / HEAVY / EXTREME / REDLINE / MELTDOWN |
| `--quality=0..4` | BATTERY / BALANCED / HIGH / ULTRA / INSANE |
| `--start-radius=M` | teleport this far from origin (snaps to the road grid in urban areas) |
| `--time-of-day=H` | 0..24 |
| `--shots=A,B,C` | capture the framebuffer at these seconds |
| `--shot-dir=PATH` | where to write them |
| `--look=DEG` `--pitch=DEG` | fix the camera for a repeatable capture |
| `--hud=0\|1\|2` | performance overlay only |
| `--no-ui` | hide the **whole** interface (captures) |
| `--godmode` `--no-hostiles` | development only |
| `--safety-off` | disable the low-FPS watchdog (needed under lavapipe) |
| `--test-autopilot` `--test-travel` `--test-sweep` | automated movement |
| `--selftest` | scripts / mesh orientation / collision orientation / determinism / safety caps |
| `--probe-chunk=X,Z` | print every batch, count, gen time and KB for one chunk |
| `--mesh-gallery` `--gallery-filter=NAME` | render one asset at a useful size |
| `--show-menu` | start at the main menu instead of in-game |

### Test suite
```bash
bash tests/run_tests.sh        # 46 assertions, 5 scenarios. Currently 46/46.
godot --headless --path . --selftest
godot --headless --path . --import     # always run after editing a shader
```

---

## 5. Current visual state (verified by render, not assumed)

**Good:**
- Night city street: lit window grid with one row per storey, per-window
  brightness spread, readable facades, streetlight poles with lit heads,
  coloured neon signage, dark starfield sky.
- Day city: clean exposure, per-district facade palettes (concrete, sandstone,
  blue curtain wall, dark steel, brick, green glass, pale render), pedestrians,
  props.
- Forest: genuinely dense ground cover and trees at quality 2.
- Streets: kerbs, footways with flag joints, bollards on the pavement,
  centre-line dashes, pedestrians on the footway, traffic in a lane.

**Known-imperfect, in rough priority order:**

1. **`ROAD_SPACING` is 128 m with no secondary streets**, so a "dense city"
   block is a 128 m solid mass of buildings with an inaccessible interior. The
   player can still end up inside a building shell if they walk into one.
   `TrafficManager` and `nearest_road_point()` both assume this spacing, so
   adding secondary streets is a real refactor.
2. **No crossings, traffic signals or road name signage** at intersections.
   The kerb line is deliberately broken through an intersection but nothing
   marks the junction.
3. **Prop scatter ignores the footway**, so crates and barrels pile up on the
   pavement. Reads as litter, which suits the setting, but it is not
   deliberate.
4. Tree trunks read as grey concrete pillars rather than bark.
5. NPC bodies are very simple blocky figures.
6. Low-lying terrain still reads slightly sandy where it sits near
   `WATER_LEVEL = -6.0`; the world function keeps a lot of ground within a few
   metres of the water plane.
7. Anisotropic filtering is requested on the ground samplers but appears to be
   a no-op under lavapipe, so its effect is **unverified**. It costs nothing to
   keep and is correct for real hardware.

---

## 6. Tuning reference (where the numbers live)

| What | Where |
|---|---|
| Hard caps (NPCs, vehicles, bodies, debris, stream radius, cache MB) | `scripts/autoload/game_config.gd` |
| Six stress levels | `scripts/autoload/stress_director.gd` `TABLE` |
| Five quality presets, device cache budget | `scripts/autoload/adaptive_quality_manager.gd` |
| Draw distance per category | `scripts/world/chunk.gd` `CATEGORY_RANGE` / `CATEGORY_RANGE_MAX` |
| `veg_step` ladder per preset | `scripts/world/world_manager.gd` (`[1.3, 0.8, 0.5, 0.38, 0.28]`) |
| Block cell, floor height, module cap, facade palette | `scripts/world/chunk_generator.gd` |
| Road spacing/width, zone radii, density fields, terrain colour | `scripts/world/world_gen.gd` |
| Sun/moon/fog/tonemap/glow, `redline_*` globals | `scripts/world/day_night_system.gd` |
| Window grid, light pollution, shopfronts | `shaders/building.gdshader` |

Current key constants:

```
CHUNK_SIZE            64.0      BLOCK_CELL        16.0
FLOOR_HEIGHT           3.4      ROAD_SPACING     128.0   ROAD_HALF_WIDTH 6.0
WATER_LEVEL           -6.0      MAX_MODULES_PER_CHUNK   900
MAX_NPCS              2200      MAX_VEHICLES      320    MAX_RIGID_BODIES 1200
MAX_OMNI_LIGHTS         96      MAX_STREAM_RADIUS  12    MAX_CACHE_MB    6144
window_w / window_h   2.7 / 3.4 (window_h MUST equal FLOOR_HEIGHT)
```

Meshes whose own materials must survive the batch `material_override` are
listed in `Chunk.SELF_MATERIALED` — currently rocks, boulders, outcrops,
`sign`, `hoarding`, `streetlight`. Anything with a self-lit surface must be
added there or the override wipes it.

---

## 7. Android export

`tools/setup_android_export.sh` downloads the prebuilt export template and
wires up `tools/debug.keystore`. No Gradle build.

**Trap:** with `use_gradle_build=false`, `gradle_build/min_sdk` and
`target_sdk` in `export_presets.cfg` must be **empty strings**. Any value there
fails the export with *"Min SDK / Target SDK can only be overridden when Use
Gradle Build is enabled"*.

Build both, using the **exact** preset name from `export_presets.cfg`:

```bash
godot --headless --path . --export-release \
  "Android arm64 (OnePlus 12 / Snapdragon 8 Gen 3)" build/redline-release.apk
godot --headless --path . --export-debug \
  "Android arm64 (OnePlus 12 / Snapdragon 8 Gen 3)" build/redline.apk
```

**Benchmark the release build, not the debug build.** A debug export carries
Godot's debugger and profiler, so a stress test run on it measures the
debugger. The release preset reuses the debug keystore, so the APK sideloads
but is not Play-distributable — which is correct for a benchmark build.

Verify the artifact, do not trust the build log:
```bash
~/android-sdk/build-tools/34.0.0/apksigner verify --print-certs build/redline-release.apk
~/android-sdk/build-tools/34.0.0/aapt2 dump badging build/redline-release.apk | \
  grep -E "^package|^native-code|^launchable"
```

Last verified export: `com.redline.stresstest` 0.1.0, minSdk 24, compileSdk 35,
`native-code: 'arm64-v8a'`, `screenOrientation=11` (sensorLandscape), no
app-level permissions, ~26 MB release / ~28 MB debug.

The APK builds and signs. It has **not** been run on real hardware — every
performance number in this repo comes from lavapipe software rendering and is
not representative.

---

## 8. Suggested next steps

Roughly in order of visual payoff per unit of risk:

1. **Secondary street grid inside city blocks.** Highest payoff, highest risk —
   `TrafficManager` and `nearest_road_point()` both assume the 128 m spacing.
2. **Intersections**: crossings, stop lines, signal heads on the kerb.
3. Bark material and a second trunk mesh variant for trees.
4. Better NPC silhouettes.
5. Keep prop scatter off the footway.
6. **Run it on the actual OnePlus 12** and replace every performance figure in
   the README with a measured one.

---

## 9. Verification checklist before any commit

```bash
godot --headless --path . --import          # catches shader compile errors
godot --headless --path . --selftest        # orientation, determinism, caps
bash tests/run_tests.sh                     # 46 assertions
# plus at least one lavapipe capture of whatever you changed
```

A change to a shader or a mesh that has not been *rendered* has not been
verified. Headless tests have never once caught a visual bug in this project.
