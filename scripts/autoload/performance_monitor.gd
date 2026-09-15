extends Node
## Collects only measurements the engine actually provides. Anything the
## platform does not report is flagged unavailable and rendered as "n/a"
## rather than being invented.

const HISTORY: int = 300              # ~5 s of frames at 60 fps for graphs
const LONG_HISTORY: int = 3600        # up to 60 s of frames for 1% lows

signal sampled()

# --- Live values -------------------------------------------------------------
var fps: float = 0.0
var frame_ms: float = 0.0
var smoothed_fps: float = 60.0
var avg_fps: float = 0.0
var min_fps_recent: float = 0.0
var low_1pc_fps: float = 0.0
var process_ms: float = 0.0
var physics_ms: float = 0.0
var render_cpu_ms: float = 0.0
var render_gpu_ms: float = 0.0
var draw_calls: int = 0
var objects_in_frame: int = 0
var primitives: int = 0
var video_mem_mb: float = 0.0
var texture_mem_mb: float = 0.0
var buffer_mem_mb: float = 0.0
var static_mem_mb: float = 0.0
var node_count: int = 0
var orphan_nodes: int = 0
var physics_active: int = 0
var physics_pairs: int = 0
var os_mem_physical_mb: float = -1.0
var os_mem_available_mb: float = -1.0

# --- Availability flags ------------------------------------------------------
var have_gpu_time: bool = false
var have_render_cpu_time: bool = false
var have_draw_calls: bool = false
var have_video_mem: bool = false
var have_os_memory: bool = false

# --- Histories ---------------------------------------------------------------
var fps_history: RingBuffer = RingBuffer.new(HISTORY)
var frame_ms_history: RingBuffer = RingBuffer.new(HISTORY)
var mem_history: RingBuffer = RingBuffer.new(HISTORY)
var gpu_history: RingBuffer = RingBuffer.new(HISTORY)
var frame_ms_long: RingBuffer = RingBuffer.new(LONG_HISTORY)

var _viewport_rid: RID
var _measure_enabled: bool = false
var _accum: float = 0.0
var _sample_interval: float = 0.1
var _low_fps_timer: float = 0.0
var _headless: bool = false
## Development escape hatch (see main.gd --safety-off). The watchdog is what
## forces a stress reduction after sustained single-digit frame rates; it is
## on in every shipped configuration.
var watchdog_enabled: bool = true

## Counters published by the gameplay managers each frame. PerformanceMonitor
## does not compute these, it only aggregates them for the HUD/benchmark.
var counters: Dictionary = {
	"npc_total": 0,
	"npc_full": 0,
	"npc_reduced": 0,
	"npc_background": 0,
	"npc_dormant": 0,
	"enemies": 0,
	"vehicles": 0,
	"rigid_bodies": 0,
	"debris": 0,
	"projectiles": 0,
	"particles": 0,
	"omni_lights": 0,
	"chunks_loaded": 0,
	"chunks_cached": 0,
	"chunk_cache_mb": 0.0,
	"active_world_mb": 0.0,
	"stream_radius": 0,
	"multimesh_instances": 0,
	"grass_instances": 0,
	"tree_instances": 0,
	"prop_instances": 0,
	"buildings": 0,
	"stream_queue": 0,
}


func _ready() -> void:
	process_priority = -100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_headless = DisplayServer.get_name() == "headless"
	call_deferred("_enable_render_timing")


func _enable_render_timing() -> void:
	if _headless:
		return
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	_viewport_rid = vp.get_viewport_rid()
	if _viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
		_measure_enabled = true


func _process(delta: float) -> void:
	fps = Performance.get_monitor(Performance.TIME_FPS)
	frame_ms = delta * 1000.0
	smoothed_fps = lerpf(smoothed_fps, maxf(fps, 1.0), clampf(delta * 4.0, 0.0, 1.0))

	fps_history.push(fps)
	frame_ms_history.push(frame_ms)
	frame_ms_long.push(frame_ms)

	# Safety watchdog: sustained single-digit framerate forces a de-escalation.
	if watchdog_enabled and smoothed_fps < GameConfig.SAFETY_FPS_FLOOR:
		_low_fps_timer += delta
		if _low_fps_timer >= GameConfig.SAFETY_FPS_FLOOR_SECONDS:
			_low_fps_timer = 0.0
			EventBus.safety_throttle.emit(
				"sustained <%.0f fps" % GameConfig.SAFETY_FPS_FLOOR
			)
	else:
		_low_fps_timer = 0.0

	_accum += delta
	if _accum < _sample_interval:
		return
	_accum = 0.0
	_sample_slow()


func _sample_slow() -> void:
	process_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	physics_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0

	draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	objects_in_frame = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	primitives = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	if draw_calls > 0 or objects_in_frame > 0:
		have_draw_calls = true

	video_mem_mb = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	texture_mem_mb = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	buffer_mem_mb = Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0
	if video_mem_mb > 0.0:
		have_video_mem = true

	static_mem_mb = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	node_count = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	orphan_nodes = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	physics_active = int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	physics_pairs = int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))

	if _measure_enabled and _viewport_rid.is_valid():
		render_cpu_ms = RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
		render_gpu_ms = RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		if render_gpu_ms > 0.0:
			have_gpu_time = true
		if render_cpu_ms > 0.0:
			have_render_cpu_time = true

	var mi: Dictionary = OS.get_memory_info()
	var phys: int = int(mi.get("physical", -1))
	var avail: int = int(mi.get("available", -1))
	if phys > 0:
		os_mem_physical_mb = float(phys) / 1048576.0
		have_os_memory = true
	if avail > 0:
		os_mem_available_mb = float(avail) / 1048576.0
		have_os_memory = true

	mem_history.push(process_memory_mb())
	gpu_history.push(render_gpu_ms)

	avg_fps = fps_history.mean()
	min_fps_recent = fps_history.minimum()
	low_1pc_fps = compute_low_1pc()
	sampled.emit()


## Best available estimate of the game's own memory footprint, in MB.
## On desktop/Android this is Godot's tracked static allocation plus GPU-side
## buffers; it is NOT the OS RSS figure and is labelled as such in the HUD.
func process_memory_mb() -> float:
	var m: float = static_mem_mb
	if have_video_mem:
		m += video_mem_mb
	m += float(counters.get("chunk_cache_mb", 0.0))
	return m


## 1% low derived from the worst 1% of frame times over the long window.
## Returns 0.0 when there are too few samples to be meaningful.
func compute_low_1pc() -> float:
	if frame_ms_long.size() < 100:
		return 0.0
	var worst_ms: float = frame_ms_long.percentile(0.99)
	if worst_ms <= 0.0:
		return 0.0
	return 1000.0 / worst_ms


func reset_history() -> void:
	fps_history.clear()
	frame_ms_history.clear()
	mem_history.clear()
	gpu_history.clear()
	frame_ms_long.clear()
	_low_fps_timer = 0.0


func set_counter(key: String, value: Variant) -> void:
	counters[key] = value


func add_counter(key: String, value: int) -> void:
	counters[key] = int(counters.get(key, 0)) + value


func metric_text(value: float, available: bool, suffix: String, decimals: int = 1) -> String:
	if not available:
		return "n/a"
	return String.num(value, decimals) + suffix


func snapshot() -> Dictionary:
	return {
		"fps": fps,
		"avg_fps": avg_fps,
		"min_fps_recent": min_fps_recent,
		"low_1pc_fps": low_1pc_fps,
		"frame_ms": frame_ms,
		"process_ms": process_ms,
		"physics_ms": physics_ms,
		"render_cpu_ms": render_cpu_ms if have_render_cpu_time else -1.0,
		"render_gpu_ms": render_gpu_ms if have_gpu_time else -1.0,
		"draw_calls": draw_calls if have_draw_calls else -1,
		"objects_in_frame": objects_in_frame if have_draw_calls else -1,
		"primitives": primitives if have_draw_calls else -1,
		"video_mem_mb": video_mem_mb if have_video_mem else -1.0,
		"texture_mem_mb": texture_mem_mb if have_video_mem else -1.0,
		"static_mem_mb": static_mem_mb,
		"process_mem_mb": process_memory_mb(),
		"os_mem_physical_mb": os_mem_physical_mb,
		"os_mem_available_mb": os_mem_available_mb,
		"node_count": node_count,
		"physics_active": physics_active,
		"physics_pairs": physics_pairs,
		"counters": counters.duplicate(),
	}


## Static description of the machine actually running the build.
func device_info() -> Dictionary:
	var mi: Dictionary = OS.get_memory_info()
	return {
		"os": OS.get_name(),
		"model": OS.get_model_name(),
		"distribution": OS.get_distribution_name(),
		"processor": OS.get_processor_name(),
		"processor_count": OS.get_processor_count(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"video_vendor": RenderingServer.get_video_adapter_vendor(),
		"video_api": RenderingServer.get_video_adapter_api_version(),
		"rendering_method": ProjectSettings.get_setting(
			"rendering/renderer/rendering_method", "unknown"
		),
		"display_server": DisplayServer.get_name(),
		"physical_memory_mb": (float(mi.get("physical", -1)) / 1048576.0
			if int(mi.get("physical", -1)) > 0 else -1.0),
		"godot_version": Engine.get_version_info().get("string", "unknown"),
	}
