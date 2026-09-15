class_name ChunkStreamer
extends Node3D
## Chunk-based world streaming.
##
## * Generation runs on WorkerThreadPool tasks (pure PackedArray work).
## * Realisation into scene nodes is incremental and frame-budgeted.
## * Unloaded chunks are retained in a byte-budgeted LRU cache, so walking back
##   over ground you have already seen costs nothing. The budget is driven by
##   StressDirector/quality, which is where the optional high-memory mode for
##   large-RAM devices comes from -- real world data, not ballast.

signal chunk_ready(coord: Vector2i)

const REALIZE_BUDGET_BASE_USEC: int = 3200
const UNLOAD_HYSTERESIS: int = 1
const MAX_REALIZE_BASE: int = 2

var focus: Node3D = null
var world_gen: WorldGen = null

var stream_radius: int = 4
var collision_radius: int = GameConfig.COLLISION_RADIUS
var cache_budget_bytes: int = 160 * 1048576
var lod_bias: float = 1.0
## How much of a frame realisation may spend, and how many chunks it may
## finish. Both scale with the stress level: at ECO the priority is a steady
## frame, at MELTDOWN the priority is getting the world in front of the player
## as fast as the device can take it.
var realize_budget_usec: int = REALIZE_BUDGET_BASE_USEC
var realize_per_frame: int = MAX_REALIZE_BASE
var view_distance: float = 800.0
var veg_step: float = 1.6
var prop_richness: float = 1.0
var lod_fade: bool = false

var active: Dictionary = {}              ## Vector2i -> WorldChunk
var _pending: Dictionary = {}            ## Vector2i -> int task id
var _results: Dictionary = {}            ## Vector2i -> ChunkData (mutex guarded)
var _realizing: Array[WorldChunk] = []
var _cache: Dictionary = {}              ## Vector2i -> ChunkData
var _cache_lru: Array[Vector2i] = []
var _cache_bytes: int = 0
var _mutex: Mutex = Mutex.new()
var _max_tasks: int = 3
var _mesh_lib: MeshLib = null
var _mat_lib: MaterialLib = null
var _last_focus_coord: Vector2i = Vector2i(999999, 999999)
var _gen_veg_step: float = -1.0
var _census_accum: float = 0.0
var _stats_gen_ms: float = 0.0
var _generated_total: int = 0
var _enabled: bool = true
## Bytes held by chunks that are currently in the scene. The retention cache is
## budgeted separately; active chunks are not, so at a large streaming radius
## this is what would actually run a device out of memory.
var _active_bytes: int = 0
var active_budget_bytes: int = 512 * 1048576
var _radius_penalty: int = 0
var _penalty_cooldown: float = 0.0


func configure(gen: WorldGen, mesh_lib: MeshLib, mat_lib: MaterialLib) -> void:
	world_gen = gen
	_mesh_lib = mesh_lib
	_mat_lib = mat_lib
	_max_tasks = clampi(OS.get_processor_count() - 1, 1, 6)


func set_enabled(v: bool) -> void:
	_enabled = v


func apply_profile(profile: Dictionary) -> void:
	stream_radius = clampi(int(profile.get("stream_radius", 4)), 2,
		GameConfig.MAX_STREAM_RADIUS)
	lod_bias = float(profile.get("lod_bias", 1.0))
	view_distance = float(profile.get("view_distance", 800.0))
	realize_budget_usec = REALIZE_BUDGET_BASE_USEC + int(lod_bias * 1600.0)
	realize_per_frame = MAX_REALIZE_BASE + int(lod_bias)
	cache_budget_bytes = clampi(int(profile.get("cache_mb", 160)), 16,
		GameConfig.MAX_CACHE_MB) * 1048576
	# Live chunks get twice the retention budget. The retained set is data the
	# player has already walked past; the active set is what is on screen, so
	# it is allowed to be the larger of the two.
	active_budget_bytes = cache_budget_bytes * 2
	for c: Vector2i in active.keys():
		(active[c] as WorldChunk).apply_lod(lod_bias, view_distance, lod_fade)
	_trim_cache()


## Vegetation base spacing is a generation-time parameter (it changes how much
## data a chunk contains), so changing it invalidates cached chunks.
func set_generation_detail(new_veg_step: float, richness: float, fade: bool) -> void:
	lod_fade = fade
	prop_richness = richness
	if is_equal_approx(new_veg_step, veg_step):
		return
	veg_step = new_veg_step
	_clear_cache()


func focus_coord() -> Vector2i:
	if focus == null or not is_instance_valid(focus):
		return Vector2i.ZERO
	return world_to_coord(focus.global_position)


static func world_to_coord(p: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(p.x / GameConfig.CHUNK_SIZE)),
		int(floor(p.z / GameConfig.CHUNK_SIZE))
	)


func is_ready_at(p: Vector3) -> bool:
	var c: Vector2i = world_to_coord(p)
	var ch: WorldChunk = active.get(c, null)
	return ch != null and ch.realized


## Ground height from the already-generated chunk grid: four array reads and a
## bilinear blend. The analytic fallback is ~10 FastNoiseLite samples plus a
## domain warp, and agents were paying that once per agent per frame purely to
## stay on the ground -- measured at 2.5 ms of the 3.9 ms the NPC manager spent
## per frame in a forest. Falls back to the world function only for positions
## outside every loaded chunk, where there is no grid to read.
func sample_height(x: float, z: float) -> float:
	var c: Vector2i = world_to_coord(Vector3(x, 0.0, z))
	var d: ChunkData = get_chunk_data(c)
	if d == null or d.height_side <= 1:
		return world_gen.height(x, z) if world_gen != null else 0.0
	var n: int = d.height_side
	var fx: float = clampf((x - d.origin.x) / d.height_cell, 0.0, float(n - 1))
	var fz: float = clampf((z - d.origin.z) / d.height_cell, 0.0, float(n - 1))
	var i0: int = int(fx)
	var j0: int = int(fz)
	var i1: int = mini(i0 + 1, n - 1)
	var j1: int = mini(j0 + 1, n - 1)
	var tx: float = fx - float(i0)
	var tz: float = fz - float(j0)
	var h: PackedFloat32Array = d.heights
	var a: float = lerpf(h[j0 * n + i0], h[j0 * n + i1], tx)
	var b: float = lerpf(h[j1 * n + i0], h[j1 * n + i1], tx)
	return lerpf(a, b, tz)


func get_chunk_data(c: Vector2i) -> ChunkData:
	var ch: WorldChunk = active.get(c, null)
	if ch != null and ch.data != null:
		return ch.data
	return _cache.get(c, null)


func loaded_count() -> int:
	return active.size()


func cached_count() -> int:
	return _cache.size()


func cache_megabytes() -> float:
	return float(_cache_bytes) / 1048576.0


func pending_count() -> int:
	return _pending.size() + _results.size() + _realizing.size()


func last_gen_ms() -> float:
	return _stats_gen_ms


func _process(_delta: float) -> void:
	# Timed so the benchmark can separate this manager's script cost from
	# render and physics time. See PerformanceMonitor.record_subsystem.
	var _t0: int = Time.get_ticks_usec()
	_step_profiled(_delta)
	PerformanceMonitor.record_subsystem("streamer", Time.get_ticks_usec() - _t0)


func _step_profiled(_delta: float) -> void:
	if not _enabled or world_gen == null:
		return
	_update_memory_guard(_delta)
	_collect_results()
	_realize_step()
	var fc: Vector2i = focus_coord()
	if fc != _last_focus_coord:
		_last_focus_coord = fc
		_refresh_desired(fc)
	_dispatch(fc)
	_publish_counters(_delta)


## Cheap counters every frame; the per-chunk geometry census on a timer.
##
## The census walks every batch node of every active chunk and reads two
## MultiMesh properties off each one. At a streaming radius of 10 that is
## ~8,800 property fetches through the Object binding per frame, and it existed
## only to drive HUD numbers that are displayed at 10 Hz. It measured 3.4 ms a
## frame in a forest -- the largest single script cost in the game -- so it now
## runs five times a second instead of sixty.
const CENSUS_INTERVAL: float = 0.2

func _publish_counters(delta: float) -> void:
	PerformanceMonitor.set_counter("chunks_loaded", active.size())
	PerformanceMonitor.set_counter("chunks_cached", _cache.size())
	PerformanceMonitor.set_counter("chunk_cache_mb", cache_megabytes())
	PerformanceMonitor.set_counter("stream_queue", pending_count())
	PerformanceMonitor.set_counter("active_world_mb", active_megabytes())
	PerformanceMonitor.set_counter("stream_radius", effective_radius())

	_census_accum += delta
	if _census_accum < CENSUS_INTERVAL:
		return
	_census_accum = 0.0
	var inst: int = 0
	var by_category: Dictionary = {}
	for c: Vector2i in active.keys():
		inst += (active[c] as WorldChunk).accumulate_counts(by_category)
	PerformanceMonitor.set_counter("multimesh_instances", inst)
	PerformanceMonitor.set_counter("buildings", int(by_category.get("building", 0)))
	PerformanceMonitor.set_counter("grass_instances", int(by_category.get("grass", 0)))
	PerformanceMonitor.set_counter("tree_instances", int(by_category.get("tree", 0)))
	PerformanceMonitor.set_counter("prop_instances", int(by_category.get("prop", 0)))


# -----------------------------------------------------------------------------
# Desired set
# -----------------------------------------------------------------------------
func _refresh_desired(fc: Vector2i) -> void:
	var keep_radius: int = effective_radius() + UNLOAD_HYSTERESIS
	var drop: Array[Vector2i] = []
	for c: Vector2i in active.keys():
		var d: Vector2i = c - fc
		if maxi(absi(d.x), absi(d.y)) > keep_radius:
			drop.append(c)
	for c: Vector2i in drop:
		_unload(c)

	for c: Vector2i in active.keys():
		var d2: Vector2i = c - fc
		var ring: int = maxi(absi(d2.x), absi(d2.y))
		(active[c] as WorldChunk).enable_collision(ring <= collision_radius)


## Streaming radius after the memory guard has had its say.
func effective_radius() -> int:
	return maxi(2, stream_radius - _radius_penalty)


func active_megabytes() -> float:
	return float(_active_bytes) / 1048576.0


func radius_penalty() -> int:
	return _radius_penalty


## Measured, not predicted: the guard reacts to the bytes chunks actually
## turned out to need, which varies enormously between open forest and a
## dense city block.
func _update_memory_guard(delta: float) -> void:
	if _penalty_cooldown > 0.0:
		_penalty_cooldown -= delta
		return
	if _active_bytes > active_budget_bytes and _radius_penalty < stream_radius - 2:
		_radius_penalty += 1
		_penalty_cooldown = 2.5
		EventBus.notify("STREAM: radius trimmed to %d (world data over budget)"
			% effective_radius(), 3.0)
	elif _active_bytes < int(float(active_budget_bytes) * 0.72) and _radius_penalty > 0:
		_radius_penalty -= 1
		_penalty_cooldown = 3.5


func _dispatch(fc: Vector2i) -> void:
	if _pending.size() >= _max_tasks:
		return
	var best: Vector2i = Vector2i.ZERO
	var best_d: int = 1 << 30
	var found: bool = false
	for ring in effective_radius() + 1:
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue
				var c: Vector2i = fc + Vector2i(dx, dz)
				if active.has(c) or _pending.has(c) or _results.has(c):
					continue
				var dist: int = dx * dx + dz * dz
				if dist < best_d:
					best_d = dist
					best = c
					found = true
		if found:
			break
	if not found:
		return

	# Cached chunks skip the worker entirely.
	if _cache.has(c_key(best)):
		var d: ChunkData = _cache[c_key(best)]
		_cache.erase(c_key(best))
		_cache_lru.erase(best)
		_cache_bytes -= d.estimated_bytes()
		_spawn_chunk(d)
		return

	var opts: Dictionary = {
		"veg_step": veg_step,
		"collision": true,
		"lod_count": 4,
		"prop_richness": prop_richness,
	}
	var task: int = WorkerThreadPool.add_task(
		_gen_task.bind(best, opts), false, "redline_chunk")
	_pending[best] = task


func c_key(c: Vector2i) -> Vector2i:
	return c


func _gen_task(c: Vector2i, opts: Dictionary) -> void:
	var d: ChunkData = ChunkGenerator.generate(world_gen, c, opts)
	_mutex.lock()
	_results[c] = d
	_mutex.unlock()


func _collect_results() -> void:
	if _pending.is_empty():
		return
	var done: Array[Vector2i] = []
	for c: Vector2i in _pending.keys():
		if WorkerThreadPool.is_task_completed(int(_pending[c])):
			done.append(c)
	for c: Vector2i in done:
		WorkerThreadPool.wait_for_task_completion(int(_pending[c]))
		_pending.erase(c)
		_mutex.lock()
		var d: ChunkData = _results.get(c, null)
		_results.erase(c)
		_mutex.unlock()
		if d != null:
			_stats_gen_ms = d.gen_msec
			_generated_total += 1
			_spawn_chunk(d)


func _spawn_chunk(d: ChunkData) -> void:
	if active.has(d.coord):
		return
	var ch := WorldChunk.new()
	ch.name = "Chunk_%d_%d" % [d.coord.x, d.coord.y]
	ch.setup(d, _mesh_lib, _mat_lib)
	add_child(ch)
	active[d.coord] = ch
	_active_bytes += d.estimated_bytes()
	_realizing.append(ch)


func _realize_step() -> void:
	if _realizing.is_empty():
		return
	var finished: int = 0
	var t0: int = Time.get_ticks_usec()
	while not _realizing.is_empty() and finished < realize_per_frame:
		if Time.get_ticks_usec() - t0 > realize_budget_usec * realize_per_frame:
			return
		var ch: WorldChunk = _realizing[0]
		if not is_instance_valid(ch) or ch.data == null:
			_realizing.pop_front()
			continue
		if not ch.step(realize_budget_usec):
			return
		_realizing.pop_front()
		finished += 1
		ch.apply_lod(lod_bias, view_distance, lod_fade)
		var fc: Vector2i = _last_focus_coord
		var ring: int = maxi(absi(ch.coord.x - fc.x), absi(ch.coord.y - fc.y))
		ch.enable_collision(ring <= collision_radius)
		GameState.chunks_visited += 1
		chunk_ready.emit(ch.coord)
		EventBus.chunk_loaded.emit(ch.coord)


func _unload(c: Vector2i) -> void:
	var ch: WorldChunk = active.get(c, null)
	if ch == null:
		return
	active.erase(c)
	_realizing.erase(ch)
	var d: ChunkData = ch.data
	if d != null:
		_active_bytes = maxi(0, _active_bytes - d.estimated_bytes())
	ch.release()
	ch.queue_free()
	if d != null:
		_cache_store(c, d)
	EventBus.chunk_unloaded.emit(c)


func _cache_store(c: Vector2i, d: ChunkData) -> void:
	if cache_budget_bytes <= 0:
		return
	var b: int = d.estimated_bytes()
	if b > cache_budget_bytes:
		return
	if _cache.has(c):
		_cache_lru.erase(c)
	else:
		_cache_bytes += b
	_cache[c] = d
	_cache_lru.append(c)
	_trim_cache()


func _trim_cache() -> void:
	while _cache_bytes > cache_budget_bytes and not _cache_lru.is_empty():
		var oldest: Vector2i = _cache_lru.pop_front()
		var d: ChunkData = _cache.get(oldest, null)
		if d != null:
			_cache_bytes -= d.estimated_bytes()
			_cache.erase(oldest)
	if _cache_bytes < 0:
		_cache_bytes = 0


func _clear_cache() -> void:
	_cache.clear()
	_cache_lru.clear()
	_cache_bytes = 0


## Drops everything and re-streams from scratch (benchmark reset / teleport).
func reset() -> void:
	for c: Vector2i in active.keys():
		var ch: WorldChunk = active[c]
		ch.release()
		ch.queue_free()
	active.clear()
	_active_bytes = 0
	_realizing.clear()
	for c: Vector2i in _pending.keys():
		WorkerThreadPool.wait_for_task_completion(int(_pending[c]))
	_pending.clear()
	_mutex.lock()
	_results.clear()
	_mutex.unlock()
	_last_focus_coord = Vector2i(999999, 999999)


func _exit_tree() -> void:
	for c: Vector2i in _pending.keys():
		WorkerThreadPool.wait_for_task_completion(int(_pending[c]))
	_pending.clear()
