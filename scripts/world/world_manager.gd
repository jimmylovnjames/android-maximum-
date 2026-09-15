class_name WorldManager
extends Node3D
## Composition root for the live world. Creates the procedural asset libraries
## and every subsystem, wires them to the stress profile, and implements the
## driver interface the benchmark uses to move the player deterministically.

signal world_built()

const LIGHT_REFRESH: float = 0.25
const WATER_SIZE: float = 1800.0
const WATER_SNAP: float = 64.0

var world_gen: WorldGen
var mesh_lib: MeshLib
var mat_lib: MaterialLib

var streamer: ChunkStreamer
var vegetation: VegetationManager
var lod: LODManager
var day_night: DayNightSystem
var weather: WeatherManager
var npcs: NPCManager
var traffic: TrafficManager
var physics_stress: PhysicsStressManager
var objectives: ObjectiveTracker
var player: PlayerController
var touch: TouchInput = null

var _water: MeshInstance3D
var _light_pool: Array[OmniLight3D] = []
var _light_cd: float = 0.0
var _light_budget: int = 18
var _zone_cd: float = 0.0
var _current_zone: int = -1
var _placed_pickup_chunks: Dictionary = {}
var _built: bool = false
var _pending_teleport: Vector3 = Vector3.ZERO
var _has_pending_teleport: bool = false
var _shadow_positional: bool = true


func build(touch_layer: TouchInput) -> void:
	touch = touch_layer
	world_gen = WorldGen.new(GameConfig.world_seed)
	MaterialLib.refresh_for_preset(AdaptiveQualityManager.preset)
	mat_lib = MaterialLib.get_instance()
	MeshLib.reset()
	mesh_lib = MeshLib.get_instance()

	day_night = DayNightSystem.new()
	day_night.name = "DayNightSystem"
	add_child(day_night)
	day_night.setup(mat_lib)

	streamer = ChunkStreamer.new()
	streamer.name = "ChunkStreamer"
	add_child(streamer)
	streamer.configure(world_gen, mesh_lib, mat_lib)

	player = PlayerController.new()
	player.name = "Player"
	add_child(player)
	var start := Vector3(0.0, 0.0, 0.0)
	start.y = world_gen.height(start.x, start.z) + 2.0
	player.global_position = start
	player.bind_touch(touch)
	streamer.focus = player

	physics_stress = PhysicsStressManager.new()
	physics_stress.name = "PhysicsStressManager"
	add_child(physics_stress)
	physics_stress.setup(world_gen, mesh_lib, mat_lib, player)

	npcs = NPCManager.new()
	npcs.name = "NPCManager"
	add_child(npcs)
	npcs.setup(world_gen, streamer, mesh_lib, player, physics_stress)
	physics_stress.set_npc_manager(npcs)

	traffic = TrafficManager.new()
	traffic.name = "TrafficManager"
	add_child(traffic)
	traffic.setup(world_gen, mesh_lib, player)

	vegetation = VegetationManager.new()
	vegetation.name = "VegetationManager"
	add_child(vegetation)
	vegetation.setup(streamer)

	lod = LODManager.new()
	lod.name = "LODManager"
	add_child(lod)
	lod.setup(streamer, player)

	weather = WeatherManager.new()
	weather.name = "WeatherManager"
	add_child(weather)
	weather.setup(mat_lib, player, day_night)

	objectives = ObjectiveTracker.new()
	objectives.name = "ObjectiveTracker"
	add_child(objectives)
	objectives.setup(self)

	_build_water()
	_build_light_pool()

	streamer.chunk_ready.connect(_on_chunk_ready)
	StressDirector.level_changed.connect(_on_stress_changed)
	AdaptiveQualityManager.profile_applied.connect(_on_quality_changed)
	EventBus.player_died.connect(_on_player_died)
	EventBus.shot_fired.connect(_on_shot_fired)

	BenchmarkManager.driver = self
	_apply_profile(StressDirector.effective)
	_built = true
	EventBus.world_ready.emit()
	world_built.emit()


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(WATER_SIZE, WATER_SIZE)
	plane.subdivide_width = 48
	plane.subdivide_depth = 48
	_water = MeshInstance3D.new()
	_water.name = "Water"
	_water.mesh = plane
	_water.material_override = mat_lib.water
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_water.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_water.position = Vector3(0.0, GameConfig.WATER_LEVEL, 0.0)
	add_child(_water)


func _build_light_pool() -> void:
	for i in GameConfig.MAX_OMNI_LIGHTS:
		var l := OmniLight3D.new()
		l.name = "CityLight%d" % i
		l.light_color = Color(1.0, 0.82, 0.56)
		l.omni_range = 24.0
		l.omni_attenuation = 1.4
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.visible = false
		# Fading at 60 m meant the city had no ground-level glow from anywhere
		# you would actually look at it from -- the skyline was windows over a
		# black void. These are the cheapest lights in the scene (no shadow,
		# small range), so carrying them out to the edge of the street grid is
		# affordable and it is what gives the city a lit floor.
		l.distance_fade_enabled = true
		l.distance_fade_begin = 170.0
		l.distance_fade_length = 70.0
		add_child(l)
		_light_pool.append(l)


# -----------------------------------------------------------------------------
# Profile plumbing
# -----------------------------------------------------------------------------
func _on_stress_changed(_level: int, profile: Dictionary) -> void:
	_apply_profile(profile)


func _on_quality_changed(preset: int, _profile: Dictionary) -> void:
	# Texture size and variant count are preset-dependent; rebuilding keeps the
	# world's residency honest instead of leaving stale textures behind.
	if mat_lib != null and not _built:
		return
	MaterialLib.refresh_for_preset(preset)
	_apply_profile(StressDirector.effective)


func _apply_profile(profile: Dictionary) -> void:
	if profile.is_empty():
		return
	_light_budget = clampi(int(profile.get("omni_lights", 18)), 0,
		GameConfig.MAX_OMNI_LIGHTS)
	_shadow_positional = bool(profile.get("positional_shadows", true))

	var preset: int = AdaptiveQualityManager.preset
	# Grass spacing is a generation-time parameter: it decides how many
	# instances exist at all, which is where the preset's real memory and
	# geometry cost comes from.
	var veg_step: float = [2.0, 1.3, 0.8, 0.6, 0.45][clampi(preset, 0, 4)]
	var richness: float = clampf(float(profile.get("building_detail", 1.0)), 0.3, 2.0)
	var fade: bool = preset >= AdaptiveQualityManager.Preset.ULTRA

	if streamer != null:
		streamer.set_generation_detail(veg_step, richness, fade)
		streamer.apply_profile(profile)
	if vegetation != null:
		vegetation.apply_profile(profile)
	if lod != null:
		lod.apply_profile(profile)
	if day_night != null:
		day_night.apply_profile(profile)
	if weather != null:
		weather.apply_profile(profile)
	if npcs != null:
		npcs.apply_profile(profile)
	if traffic != null:
		traffic.apply_profile(profile)
	if physics_stress != null:
		physics_stress.apply_profile(profile)
	if player != null:
		player.set_view_distance(float(profile.get("view_distance", 900.0)))


# -----------------------------------------------------------------------------
# Per-frame upkeep
# -----------------------------------------------------------------------------
func _process(delta: float) -> void:
	if not _built or player == null or not is_instance_valid(player):
		return
	var pp: Vector3 = player.global_position

	if _water != null:
		_water.global_position = Vector3(
			snappedf(pp.x, WATER_SNAP), GameConfig.WATER_LEVEL, snappedf(pp.z, WATER_SNAP))

	_keep_player_on_ground(pp)

	if traffic != null and day_night != null:
		traffic.set_night(day_night.night_factor)
	if day_night != null:
		day_night.set_urban_factor(world_gen.urban_factor(pp.x, pp.z))

	_light_cd -= delta
	if _light_cd <= 0.0:
		_light_cd = LIGHT_REFRESH
		_refresh_lights(pp)

	_zone_cd -= delta
	if _zone_cd <= 0.0:
		_zone_cd = 0.5
		_update_zone(pp)

	var particles: int = weather.particle_count() if weather != null else 0
	if physics_stress != null:
		particles += physics_stress.active_particle_count()
	PerformanceMonitor.set_counter("particles", particles)


## Releases the player once the ground beneath them exists, and catches the
## case where they end up under the terrain anyway.
func _keep_player_on_ground(pp: Vector3) -> void:
	var gh: float = world_gen.height(pp.x, pp.z)
	if player.frozen:
		var c: Vector2i = ChunkStreamer.world_to_coord(pp)
		var ch: WorldChunk = streamer.active.get(c, null)
		if ch != null and ch.realized and ch.has_collision:
			player.ground_snap(gh, 1.4)
			player.frozen = false
		return
	if pp.y < gh - 6.0:
		player.ground_snap(gh, 1.4)


func _update_zone(pp: Vector3) -> void:
	var r: float = Vector2(pp.x, pp.z).length()
	StressDirector.set_zone_intensity(GameConfig.world_intensity(r))
	var z: int = GameConfig.zone_for_radius(r)
	if z != _current_zone:
		_current_zone = z
		EventBus.zone_changed.emit(z, GameConfig.ZONE_NAMES[z])
		if GameState.phase == GameState.Phase.PLAYING:
			EventBus.notify("ENTERING %s" % GameConfig.ZONE_NAMES[z], 3.0)


## Streetlights near the player get a real OmniLight3D from the pool. Budget
## comes from the stress profile, so REDLINE nights are genuinely light-heavy.
func _refresh_lights(pp: Vector3) -> void:
	if day_night == null:
		return
	var night: float = day_night.night_factor
	var energy: float = clampf(night * 2.6, 0.0, 2.6)
	if energy <= 0.02:
		for l: OmniLight3D in _light_pool:
			if l.visible:
				l.visible = false
		PerformanceMonitor.set_counter("omni_lights", 0)
		return

	var candidates: Array[Vector3] = []
	var fc: Vector2i = ChunkStreamer.world_to_coord(pp)
	# Radius 3 and a 240 m cut-off: a large budget on a dense night needs more
	# spots to choose from than a 2-chunk ring holds, or most of the pool sits
	# idle while the street two blocks over stays dark.
	const LIGHT_REACH_SQ: float = 57600.0
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			var d: ChunkData = streamer.get_chunk_data(fc + Vector2i(dx, dz))
			if d == null:
				continue
			for p: Vector3 in d.light_spots:
				if p.distance_squared_to(pp) < LIGHT_REACH_SQ:
					candidates.append(p)
			if candidates.size() >= _light_budget * 3:
				break

	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return a.distance_squared_to(pp) < b.distance_squared_to(pp))

	var used: int = 0
	var shadow_left: int = 4 if _shadow_positional else 0
	for i in _light_pool.size():
		var l: OmniLight3D = _light_pool[i]
		if i < mini(_light_budget, candidates.size()):
			l.global_position = candidates[i]
			l.light_energy = energy
			l.visible = true
			l.shadow_enabled = shadow_left > 0
			if shadow_left > 0:
				shadow_left -= 1
			used += 1
		elif l.visible:
			l.visible = false
			l.shadow_enabled = false
	PerformanceMonitor.set_counter("omni_lights", used)


func _on_chunk_ready(coord: Vector2i) -> void:
	if _placed_pickup_chunks.has(coord):
		return
	_placed_pickup_chunks[coord] = true
	var d: ChunkData = streamer.get_chunk_data(coord)
	if d == null or physics_stress == null:
		return
	for entry: Dictionary in d.pickups:
		var p: Vector3 = entry["pos"]
		if player != null and p.distance_to(player.global_position) > 240.0:
			continue
		physics_stress.place_pickup(p + Vector3(0.0, 0.35, 0.0), String(entry["id"]),
			int(entry["amount"]))
	if _placed_pickup_chunks.size() > 900:
		_placed_pickup_chunks.clear()


func _on_shot_fired(from: Vector3, to: Vector3) -> void:
	if npcs != null:
		npcs.alert_near(to, 16.0)
		npcs.alert_near(from, 24.0)


func _on_player_died() -> void:
	EventBus.notify("YOU DIED", 4.0)


# -----------------------------------------------------------------------------
# Travel helpers
# -----------------------------------------------------------------------------
func ground_height(x: float, z: float) -> float:
	return world_gen.height(x, z)


func teleport_player(pos: Vector3) -> void:
	var p: Vector3 = pos
	p.y = world_gen.height(p.x, p.z) + 2.2
	player.teleport(p, atan2(-p.x, -p.z))
	streamer.reset()
	if npcs != null:
		npcs.clear_all()
	if traffic != null:
		traffic.clear_all()
	if physics_stress != null:
		physics_stress.clear_all()
	_placed_pickup_chunks.clear()
	_update_zone(p)


func respawn() -> void:
	GameState.reset_run()
	GameState.set_phase(GameState.Phase.PLAYING)
	teleport_player(Vector3(0.0, 0.0, 0.0))
	if objectives != null:
		objectives.reset()
	EventBus.notify("RESPAWNED AT ORIGIN", 3.0)


# -----------------------------------------------------------------------------
# Benchmark driver interface
# -----------------------------------------------------------------------------
func bench_prepare(seed_value: int) -> void:
	if seed_value != GameConfig.world_seed:
		GameConfig.world_seed = seed_value
		world_gen = WorldGen.new(seed_value)
		streamer.configure(world_gen, mesh_lib, mat_lib)
	if weather != null:
		weather.auto_cycle = false
		weather.set_weather(WeatherManager.Weather.OVERCAST, false)
	if day_night != null:
		day_night.paused = true
		day_night.set_time(18.5)
	teleport_player(Vector3(0.0, 0.0, 0.0))


func bench_teleport(radius: float) -> void:
	var ang: float = 0.6
	var p := Vector3(cos(ang) * radius, 0.0, sin(ang) * radius)
	# Land on the carriageway once there is one. City blocks are close to
	# contiguous, so an arbitrary point at a given radius usually lands inside
	# a building shell -- which makes a benchmark run measure the inside of a
	# box and makes a capture look like a bug.
	if world_gen != null and world_gen.urban_factor(p.x, p.z) > 0.2:
		var road: Vector3 = world_gen.nearest_road_point(p.x, p.z)
		p = Vector3(road.x, 0.0, road.z)
	teleport_player(p)


func bench_set_weather(state: int) -> void:
	if weather != null:
		weather.set_weather(state, false)


func bench_set_autopilot(on: bool) -> void:
	if player != null:
		player.set_autopilot(on)


func bench_physics_storm() -> void:
	if physics_stress != null and player != null:
		physics_stress.physics_storm(player.global_position, 1.4)


func bench_finish() -> void:
	if weather != null:
		weather.auto_cycle = true
	if day_night != null:
		day_night.paused = false
	if player != null:
		player.set_autopilot(false)


## Diagnostic used by the headless smoke test: confirms the streamed collision
## surface is actually present and correctly oriented under the player.
func debug_probe() -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {}
	var pp: Vector3 = player.global_position
	var c: Vector2i = ChunkStreamer.world_to_coord(pp)
	var ch: WorldChunk = streamer.active.get(c, null)
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		pp + Vector3(0, 12, 0), pp + Vector3(0, -40, 0))
	q.collision_mask = GameConfig.L_WORLD
	q.exclude = [player.get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	# A hit from below but not above means the collision trimesh is wound
	# inside out, which is silent until the player falls through the world.
	var q2 := PhysicsRayQueryParameters3D.create(
		pp + Vector3(0, -40, 0), pp + Vector3(0, 12, 0))
	q2.collision_mask = GameConfig.L_WORLD
	q2.exclude = [player.get_rid()]
	var hit_up: Dictionary = space.intersect_ray(q2)
	return {
		"ray_from_above_hits": not hit.is_empty(),
		"ray_from_below_hits": not hit_up.is_empty(),
		"on_floor": player.is_on_floor(),
		"ground_analytic": world_gen.height(pp.x, pp.z),
		"player_y": pp.y,
		"chunk": [c.x, c.y],
		"chunk_present": ch != null,
		"chunk_realized": ch.realized if ch != null else false,
		"chunk_has_collision": ch.has_collision if ch != null else false,
		"faces": ch.data.collision_faces.size() if (ch != null and ch.data != null) else -1,
		"ray_hit": [hit["position"].x, hit["position"].y, hit["position"].z]
			if not hit.is_empty() else [],
		"ray_normal": [hit["normal"].x, hit["normal"].y, hit["normal"].z]
			if not hit.is_empty() else [],
		"ray_collider": str(hit.get("collider", "")) if not hit.is_empty() else "",
	}


func world_stats() -> Dictionary:
	return {
		"player_pos": [player.global_position.x, player.global_position.y,
			player.global_position.z] if player != null else [],
		"ground_here": world_gen.height(player.global_position.x, player.global_position.z)
			if player != null else 0.0,
		"on_floor": player.is_on_floor() if player != null else false,
		"velocity_h": Vector2(player.velocity.x, player.velocity.z).length()
			if player != null else 0.0,
		"zone": GameConfig.ZONE_NAMES[clampi(_current_zone, 0, 6)],
		"radius": Vector2(player.global_position.x, player.global_position.z).length()
			if player != null else 0.0,
		"time": day_night.time_string() if day_night != null else "--:--",
		"weather": weather.state_name() if weather != null else "-",
		"chunk_gen_ms": streamer.last_gen_ms() if streamer != null else 0.0,
	}
