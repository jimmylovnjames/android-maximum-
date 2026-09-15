extends Node
## Repeatable benchmark driver.
##
## Every number it reports is measured from real frame timings collected while
## the stages run. Nothing is estimated or back-filled. Metrics the platform
## does not expose are written as null in the JSON and "n/a" on screen.

enum Mode { STANDARD, ENDURANCE }

const RESULT_VERSION: int = 2

## Auto-advance: a stage that has held below this for this long is recorded as
## it stands and abandoned, rather than leaving the device stuck on it.
const ADVANCE_FPS_FLOOR: float = 10.0
const ADVANCE_FPS_SECONDS: float = 4.0
## Settling time after a stage's teleport before the floor is armed.
const ADVANCE_GRACE_SECONDS: float = 6.0

## RAM TORTURE ramp. Each step raises the retained-chunk ceiling by this much
## and records what the process actually used afterwards.
const RAM_STEP_SECONDS: float = 2.5
const RAM_STEP_MB: int = 512

## A stage = a fixed world radius (so geometry/population are reproducible)
## plus a stress level, held for a fixed duration.
## Stages are ordered so each subsystem is loaded on its own before anything
## is combined. A stage that moves every dial at once cannot tell you which
## dial cost you the frame, which is exactly the position the FOREST CANOPY
## result left us in: 8-9 fps, and the counters ruled out RAM, draw calls and
## physics without pointing at what was left.
##
## "overrides" are per-subsystem multipliers applied on top of the stress
## level (see StressDirector.set_bench_overrides), so a stage can hold
## geometry flat while tripling the agent count.
const STAGES_STANDARD: Array[Dictionary] = [
	{"name": "WARMUP", "seconds": 8.0, "stress": 0, "radius": 60.0,
		"autopilot": true, "focus": "baseline"},

	{"name": "CPU / AI SWARM", "seconds": 14.0, "stress": 3, "radius": 900.0,
		"autopilot": true, "focus": "ai",
		"overrides": {"npc": 3.2, "veg": 0.2, "physics": 0.15, "traffic": 0.4,
			"geometry": 0.5, "view": 0.55}},

	{"name": "PHYSICS STORM", "seconds": 14.0, "stress": 3, "radius": 1250.0,
		"autopilot": false, "physics_storm": true, "focus": "physics",
		"overrides": {"npc": 0.2, "veg": 0.2, "physics": 3.0, "traffic": 0.3,
			"geometry": 0.5, "view": 0.55}},

	{"name": "GEOMETRY / DRAW CALLS", "seconds": 14.0, "stress": 3, "radius": 1800.0,
		"autopilot": true, "focus": "geometry",
		"overrides": {"npc": 0.15, "physics": 0.1, "traffic": 0.2,
			"geometry": 2.2, "view": 2.0, "veg": 0.35}},

	{"name": "GPU FILL + SHADOWS", "seconds": 14.0, "stress": 2, "radius": 1800.0,
		"autopilot": true, "focus": "gpu", "gpu_load": 1.0,
		"overrides": {"npc": 0.15, "physics": 0.1, "traffic": 0.2,
			"geometry": 0.8, "veg": 0.8}},

	{"name": "FOREST CANOPY", "seconds": 14.0, "stress": 3, "radius": 420.0,
		"autopilot": true, "focus": "vegetation",
		"overrides": {"veg": 2.0, "npc": 0.5, "physics": 0.2, "traffic": 0.1}},

	{"name": "STREAMING SPRINT", "seconds": 18.0, "stress": 3, "radius": 2450.0,
		"autopilot": true, "focus": "streaming", "hop_seconds": 3.0,
		"overrides": {"stream_bonus": 2, "npc": 0.4, "physics": 0.2, "veg": 0.6}},

	{"name": "RAM TORTURE", "seconds": 32.0, "stress": 3, "radius": 2450.0,
		"autopilot": true, "focus": "memory", "ram_torture": true,
		"hop_seconds": 2.5,
		"overrides": {"npc": 0.5, "physics": 0.3, "veg": 0.8,
			"cache": 40.0, "stream_bonus": 3}},

	{"name": "COMBINED REDLINE", "seconds": 18.0, "stress": 4, "radius": 3100.0,
		"autopilot": true, "weather": 4, "focus": "combined"},

	{"name": "MELTDOWN BURST", "seconds": 14.0, "stress": 5, "radius": 3100.0,
		"autopilot": true, "weather": 4, "focus": "combined"},
]

const STAGES_ENDURANCE: Array[Dictionary] = [
	{"name": "WARMUP", "seconds": 15.0, "stress": 1, "radius": 300.0, "autopilot": true},
	{"name": "SUSTAIN A / TOWN", "seconds": 75.0, "stress": 3, "radius": 1250.0, "autopilot": true},
	{"name": "SUSTAIN B / CITY", "seconds": 90.0, "stress": 3, "radius": 1800.0, "autopilot": true},
	{"name": "SUSTAIN C / INDUSTRIAL", "seconds": 90.0, "stress": 4, "radius": 2450.0,
		"autopilot": true},
	{"name": "SUSTAIN D / REDLINE", "seconds": 90.0, "stress": 4, "radius": 3100.0,
		"autopilot": true, "weather": 4},
	{"name": "COOLDOWN CHECK", "seconds": 40.0, "stress": 1, "radius": 300.0, "autopilot": true},
]

signal tick(stage_index: int, stage_elapsed: float, stage_total: float)

var running: bool = false
var mode: int = Mode.STANDARD
var stage_index: int = -1
var stage_elapsed: float = 0.0
var total_elapsed: float = 0.0
var results: Dictionary = {}

## Node supplying world control during a benchmark. Must implement:
##   bench_prepare(seed: int) -> void
##   bench_teleport(radius: float) -> void
##   bench_set_autopilot(on: bool) -> void
##   bench_physics_storm() -> void
##   bench_finish() -> void
var driver: Node = null

var _stages: Array[Dictionary] = []
var _stage_frames: RingBuffer
var _all_frames: RingBuffer
var _stage_records: Array[Dictionary] = []
var _peak_mem_mb: float = 0.0
var _peak_counters: Dictionary = {}
var _max_stable_level: int = 0
var _start_unix: int = 0
var _prev_stress_level: int = 1
var _prev_auto: bool = false
var _gpu_samples: RingBuffer
var _early_window: PackedFloat32Array = PackedFloat32Array()
var _late_window: PackedFloat32Array = PackedFloat32Array()
var _sustain_probe_t: float = 0.0
var _aborted_reason: String = ""
var _ram_torture: bool = false
var _ram_step: int = 0
var _ram_accum: float = 0.0
var _ram_samples: Array[Dictionary] = []
var _hop_seconds: float = 0.0
var _hop_accum: float = 0.0
var _hop_index: int = 0
var _low_fps_seconds: float = 0.0
var _stage_advanced_early: bool = false
## Development switch (main.gd --safety-off), so the full length of a stage can
## be observed on hardware too slow to hold the floor -- a software rasteriser
## trips it on every stage. Shipped builds leave this on.
var auto_advance_enabled: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_stage_frames = RingBuffer.new(20000)
	_all_frames = RingBuffer.new(60000)
	_gpu_samples = RingBuffer.new(8000)
	EventBus.benchmark_aborted.connect(_on_abort_request)


func start(m: int = Mode.STANDARD) -> bool:
	if running:
		return false
	if driver == null or not is_instance_valid(driver):
		EventBus.notify("Benchmark needs an active world", 3.0)
		return false

	mode = m
	_stages = (STAGES_ENDURANCE if mode == Mode.ENDURANCE else STAGES_STANDARD).duplicate(true)
	running = true
	stage_index = -1
	stage_elapsed = 0.0
	total_elapsed = 0.0
	_stage_records.clear()
	_all_frames.clear()
	_gpu_samples.clear()
	_peak_mem_mb = 0.0
	_peak_counters = {}
	_max_stable_level = 0
	_aborted_reason = ""
	_early_window = PackedFloat32Array()
	_late_window = PackedFloat32Array()
	_start_unix = int(Time.get_unix_time_from_system())

	_prev_stress_level = StressDirector.level
	_prev_auto = StressDirector.auto_mode
	StressDirector.set_auto(false)
	StressDirector.locked = false

	GameState.set_phase(GameState.Phase.BENCHMARK)
	GameState.set_invulnerable(true)
	PerformanceMonitor.reset_history()

	if driver.has_method("bench_prepare"):
		driver.call("bench_prepare", GameConfig.world_seed)

	EventBus.benchmark_started.emit(mode_name())
	_advance_stage()
	return true


func mode_name() -> String:
	return "ENDURANCE" if mode == Mode.ENDURANCE else "STANDARD"


func abort(reason: String = "user aborted") -> void:
	if not running:
		return
	_aborted_reason = reason
	_teardown()
	running = false
	EventBus.notify("Benchmark aborted: " + reason, 4.0)
	EventBus.benchmark_aborted.emit(reason)


func _on_abort_request(reason: String) -> void:
	# Emitted by the safety watchdog while a benchmark holds the stress level.
	if running and _aborted_reason == "":
		_aborted_reason = reason
		_teardown()
		running = false
		EventBus.notify("Benchmark aborted: " + reason, 4.0)


func total_duration() -> float:
	var t: float = 0.0
	for s: Dictionary in _stages:
		t += float(s["seconds"])
	return t


func _process(delta: float) -> void:
	if not running:
		return
	stage_elapsed += delta
	total_elapsed += delta

	var ms: float = delta * 1000.0
	_stage_frames.push(ms)
	_all_frames.push(ms)
	if PerformanceMonitor.have_gpu_time:
		_gpu_samples.push(PerformanceMonitor.render_gpu_ms)

	_peak_mem_mb = maxf(_peak_mem_mb, PerformanceMonitor.process_memory_mb())
	_track_peak_counters()

	# Burst vs sustained: keep the first and last 25 s of frame times.
	if total_elapsed <= 25.0:
		_early_window.append(ms)
	_late_window.append(ms)
	if _late_window.size() > 2600:
		_late_window = _late_window.slice(_late_window.size() - 2600)

	_run_stage_behaviour(delta)

	tick.emit(stage_index, stage_elapsed, float(_stages[stage_index]["seconds"]))

	# Auto-advance. A device that has fallen over on one stage should not sit
	# there for the rest of the run: record what it managed and move on.
	# The grace period matters: every stage begins with a teleport, and the
	# chunk load that follows always spikes the frame time. Without it the
	# watchdog fires on the load rather than on the workload, and a stage is
	# abandoned before it has measured anything.
	if auto_advance_enabled and stage_elapsed >= ADVANCE_GRACE_SECONDS:
		if PerformanceMonitor.smoothed_fps < ADVANCE_FPS_FLOOR:
			_low_fps_seconds += delta
		else:
			_low_fps_seconds = 0.0
	var bail: bool = _low_fps_seconds >= ADVANCE_FPS_SECONDS

	if bail or stage_elapsed >= float(_stages[stage_index]["seconds"]):
		_stage_advanced_early = bail
		_close_stage()
		_advance_stage()


## Behaviour that only some stages run: the memory ramp and the teleport hops
## that force the streamer to do real work.
func _run_stage_behaviour(delta: float) -> void:
	var s: Dictionary = _stages[stage_index]

	if _hop_seconds > 0.0:
		_hop_accum += delta
		if _hop_accum >= _hop_seconds:
			_hop_accum = 0.0
			_hop_index += 1
			if driver != null and is_instance_valid(driver) \
					and driver.has_method("bench_teleport"):
				# Walk outwards and back so the run covers fresh chunks in both
				# directions rather than re-treading a cached corridor.
				var span: float = float(s["radius"]) * 0.35
				var off: float = span * float((_hop_index % 5) - 2)
				# Golden angle around the origin: successive hops land in
				# previously unvisited chunks instead of retracing one ray.
				var ang: float = 0.6 + float(_hop_index) * 2.39996
				driver.call("bench_teleport",
					maxf(120.0, float(s["radius"]) + off), ang)

	if not _ram_torture:
		return
	_ram_accum += delta
	if _ram_accum < RAM_STEP_SECONDS:
		return
	_ram_accum = 0.0
	_ram_step += 1
	# Raise the retained-chunk ceiling a step at a time and record what the
	# process actually ended up using. The ceiling is a request, not a
	# guarantee: AdaptiveQualityManager still refuses to go past a safe share
	# of the memory the OS reports as available, so this cannot be used to
	# drive the device into the OOM killer.
	var want_mb: int = RAM_STEP_MB * _ram_step
	AdaptiveQualityManager.set_bench_cache_ceiling(want_mb)
	_ram_samples.append({
		"step": _ram_step,
		"requested_cache_mb": want_mb,
		"granted_cache_mb": AdaptiveQualityManager.device_cache_budget_mb(),
		"chunk_cache_mb": float(PerformanceMonitor.counters.get("chunk_cache_mb", 0.0)),
		"chunks_cached": int(PerformanceMonitor.counters.get("chunks_cached", 0)),
		"static_mem_mb": PerformanceMonitor.static_mem_mb,
		"video_mem_mb": (PerformanceMonitor.video_mem_mb
			if PerformanceMonitor.have_video_mem else null),
		"process_mem_mb": PerformanceMonitor.process_memory_mb(),
		"os_available_mb": (PerformanceMonitor.os_mem_available_mb
			if PerformanceMonitor.have_os_memory else null),
		"fps": PerformanceMonitor.smoothed_fps,
	})


func _track_peak_counters() -> void:
	for k: String in PerformanceMonitor.counters.keys():
		var v: Variant = PerformanceMonitor.counters[k]
		if v is int or v is float:
			var f: float = float(v)
			if f > float(_peak_counters.get(k, -INF)):
				_peak_counters[k] = f


func _advance_stage() -> void:
	stage_index += 1
	if stage_index >= _stages.size():
		_finish()
		return
	stage_elapsed = 0.0
	_stage_frames.clear()

	var s: Dictionary = _stages[stage_index]
	StressDirector.locked = false
	StressDirector.set_level(int(s["stress"]), false)
	StressDirector.set_bench_overrides(s.get("overrides", {}))
	StressDirector.locked = true
	_max_stable_level = maxi(_max_stable_level, int(s["stress"]))

	# Pure-GPU knobs (render scale, MSAA, shadow map and splits) are only
	# raised by the stage that exists to measure them.
	AdaptiveQualityManager.push_gpu_load(float(s.get("gpu_load", 0.0)))

	_ram_torture = bool(s.get("ram_torture", false))
	_ram_step = 0
	_ram_accum = 0.0
	_ram_samples.clear()
	if not _ram_torture:
		AdaptiveQualityManager.set_bench_cache_ceiling(0)
	_hop_seconds = float(s.get("hop_seconds", 0.0))
	_hop_accum = 0.0
	_hop_index = 0
	_low_fps_seconds = 0.0
	_stage_advanced_early = false

	if driver != null and is_instance_valid(driver):
		if driver.has_method("bench_teleport"):
			driver.call("bench_teleport", float(s["radius"]))
		if driver.has_method("bench_set_autopilot"):
			driver.call("bench_set_autopilot", bool(s.get("autopilot", true)))
		if driver.has_method("bench_set_weather"):
			driver.call("bench_set_weather", int(s.get("weather", 2)))
		if bool(s.get("physics_storm", false)) and driver.has_method("bench_physics_storm"):
			driver.call("bench_physics_storm")

	EventBus.benchmark_stage_changed.emit(stage_index, String(s["name"]))


func _close_stage() -> void:
	var s: Dictionary = _stages[stage_index]
	_stage_records.append({
		"index": stage_index,
		"name": s["name"],
		"stress_level": int(s["stress"]),
		"stress_name": StressDirector.LEVEL_NAMES[int(s["stress"])],
		"radius_m": float(s["radius"]),
		"seconds": stage_elapsed,
		"frames": _stage_frames.size(),
		"avg_fps": _fps_from_mean(_stage_frames),
		"min_fps": _min_fps(_stage_frames),
		"low_1pc_fps": _low_1pc(_stage_frames),
		"avg_frame_ms": _stage_frames.mean(),
		"worst_frame_ms": _stage_frames.maximum(),
		"focus": String(s.get("focus", "combined")),
		"overrides": s.get("overrides", {}),
		"gpu_load": float(s.get("gpu_load", 0.0)),
		"advanced_early": _stage_advanced_early,
		"counters": PerformanceMonitor.counters.duplicate(),
		"telemetry": PerformanceMonitor.telemetry(),
		"ram_steps": _ram_samples.duplicate(true) if _ram_torture else [],
	})


func _fps_from_mean(rb: RingBuffer) -> float:
	var m: float = rb.mean()
	return 0.0 if m <= 0.0 else 1000.0 / m


func _min_fps(rb: RingBuffer) -> float:
	var worst: float = rb.maximum()
	return 0.0 if worst <= 0.0 else 1000.0 / worst


func _low_1pc(rb: RingBuffer) -> float:
	if rb.size() < 100:
		return 0.0
	var p: float = rb.percentile(0.99)
	return 0.0 if p <= 0.0 else 1000.0 / p


func _window_fps(w: PackedFloat32Array) -> float:
	if w.is_empty():
		return 0.0
	var s: float = 0.0
	for v: float in w:
		s += v
	var m: float = s / float(w.size())
	return 0.0 if m <= 0.0 else 1000.0 / m


func _finish() -> void:
	var burst_fps: float = _window_fps(_early_window)
	var sustained_fps: float = _window_fps(_late_window)
	var degradation: float = 0.0
	if burst_fps > 0.0:
		degradation = (burst_fps - sustained_fps) / burst_fps * 100.0

	results = {
		"result_version": RESULT_VERSION,
		"title": "REDLINE",
		"mode": mode_name(),
		"aborted": false,
		"timestamp_unix": _start_unix,
		"timestamp_iso": Time.get_datetime_string_from_unix_time(_start_unix, true),
		"world_seed": GameConfig.world_seed,
		"quality_preset": AdaptiveQualityManager.preset_name(),
		"quality_auto_detect_reason": AdaptiveQualityManager.detect_reason(),
		"adaptive_quality_enabled": AdaptiveQualityManager.adaptive_enabled,
		"final_render_scale": AdaptiveQualityManager.current_render_scale(),
		"duration_seconds": total_elapsed,
		"total_frames": _all_frames.size(),
		"avg_fps": _fps_from_mean(_all_frames),
		"min_fps": _min_fps(_all_frames),
		"low_1pc_fps": _low_1pc(_all_frames),
		"low_1pc_valid": _all_frames.size() >= 100,
		"avg_frame_ms": _all_frames.mean(),
		"worst_frame_ms": _all_frames.maximum(),
		"burst_fps_first_25s": burst_fps,
		"sustained_fps_last_25s": sustained_fps,
		"sustained_degradation_percent": degradation,
		"degradation_note":
			"Derived from frame timing only. No thermal sensor is read; this is "
			+ "not a temperature measurement.",
		"peak_measured_memory_mb": _peak_mem_mb,
		"memory_note":
			"Godot static allocation + tracked video memory + world cache estimate. "
			+ "Not OS RSS.",
		"max_stress_level": _max_stable_level,
		"max_stress_name": StressDirector.LEVEL_NAMES[clampi(_max_stable_level, 0, 5)],
		"gpu_time_available": PerformanceMonitor.have_gpu_time,
		"avg_gpu_ms": _gpu_samples.mean() if PerformanceMonitor.have_gpu_time else null,
		"worst_gpu_ms": _gpu_samples.maximum() if PerformanceMonitor.have_gpu_time else null,
		"draw_call_metrics_available": PerformanceMonitor.have_draw_calls,
		"peak_counters": _peak_counters.duplicate(),
		"final_snapshot": PerformanceMonitor.snapshot(),
		"device": PerformanceMonitor.device_info(),
		"stages": _stage_records.duplicate(true),
		"gameplay": GameState.summary(),
	}

	_teardown()
	running = false
	var path: String = save_results(results)
	results["saved_to"] = path
	EventBus.benchmark_finished.emit(results)


func _teardown() -> void:
	StressDirector.locked = false
	StressDirector.set_bench_overrides({})
	AdaptiveQualityManager.push_gpu_load(0.0)
	AdaptiveQualityManager.set_bench_cache_ceiling(0)
	StressDirector.set_level(_prev_stress_level, false)
	if _prev_auto:
		StressDirector.set_auto(true)
	GameState.set_invulnerable(false)
	if GameState.phase == GameState.Phase.BENCHMARK:
		GameState.set_phase(GameState.Phase.PLAYING)
	if driver != null and is_instance_valid(driver):
		if driver.has_method("bench_set_autopilot"):
			driver.call("bench_set_autopilot", false)
		if driver.has_method("bench_finish"):
			driver.call("bench_finish")


## Writes the run to user://benchmarks/. Returns "" when the platform refuses
## the write rather than pretending it succeeded.
func save_results(r: Dictionary) -> String:
	var dir_err: int = DirAccess.make_dir_recursive_absolute(GameConfig.benchmark_dir)
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("REDLINE: benchmark dir unavailable (%d)" % dir_err)
		return ""
	var fname: String = "%s/redline_%s_%d.json" % [
		GameConfig.benchmark_dir, r.get("mode", "RUN"), int(r.get("timestamp_unix", 0)),
	]
	var f: FileAccess = FileAccess.open(fname, FileAccess.WRITE)
	if f == null:
		push_warning("REDLINE: could not write benchmark results (%d)" % FileAccess.get_open_error())
		return ""
	f.store_string(JSON.stringify(r, "  "))
	f.close()
	return ProjectSettings.globalize_path(fname)


func list_saved_results() -> PackedStringArray:
	var out := PackedStringArray()
	var d: DirAccess = DirAccess.open(GameConfig.benchmark_dir)
	if d == null:
		return out
	for f: String in d.get_files():
		if f.ends_with(".json"):
			out.append(GameConfig.benchmark_dir + "/" + f)
	return out


func current_stage_name() -> String:
	if not running or stage_index < 0 or stage_index >= _stages.size():
		return ""
	return String(_stages[stage_index]["name"])


func progress() -> float:
	var total: float = total_duration()
	return 0.0 if total <= 0.0 else clampf(total_elapsed / total, 0.0, 1.0)
