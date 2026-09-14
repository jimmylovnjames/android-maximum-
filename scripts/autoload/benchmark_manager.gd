extends Node
## Repeatable benchmark driver.
##
## Every number it reports is measured from real frame timings collected while
## the stages run. Nothing is estimated or back-filled. Metrics the platform
## does not expose are written as null in the JSON and "n/a" on screen.

enum Mode { STANDARD, ENDURANCE }

const RESULT_VERSION: int = 1

## A stage = a fixed world radius (so geometry/population are reproducible)
## plus a stress level, held for a fixed duration.
const STAGES_STANDARD: Array[Dictionary] = [
	{"name": "WARMUP / WILDERNESS", "seconds": 8.0, "stress": 0, "radius": 60.0, "autopilot": true},
	{"name": "FOREST CANOPY", "seconds": 12.0, "stress": 1, "radius": 420.0, "autopilot": true},
	{"name": "SETTLEMENT", "seconds": 12.0, "stress": 2, "radius": 820.0, "autopilot": true},
	{"name": "TOWN TRAFFIC", "seconds": 14.0, "stress": 2, "radius": 1250.0, "autopilot": true},
	{"name": "DENSE CITY", "seconds": 16.0, "stress": 3, "radius": 1800.0, "autopilot": true,
		"weather": 2},
	{"name": "INDUSTRIAL", "seconds": 16.0, "stress": 4, "radius": 2450.0, "autopilot": true,
		"weather": 3},
	{"name": "REDLINE ZONE", "seconds": 18.0, "stress": 4, "radius": 3100.0, "autopilot": true,
		"weather": 4},
	{"name": "MELTDOWN BURST", "seconds": 14.0, "stress": 5, "radius": 3100.0,
		"autopilot": true, "weather": 4},
	{"name": "PHYSICS STORM", "seconds": 12.0, "stress": 5, "radius": 3100.0,
		"autopilot": false, "physics_storm": true},
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

	tick.emit(stage_index, stage_elapsed, float(_stages[stage_index]["seconds"]))

	if stage_elapsed >= float(_stages[stage_index]["seconds"]):
		_close_stage()
		_advance_stage()


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
	StressDirector.locked = true
	_max_stable_level = maxi(_max_stable_level, int(s["stress"]))

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
		"counters": PerformanceMonitor.counters.duplicate(),
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
