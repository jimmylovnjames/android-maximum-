extends Node
## The workload conductor. Owns the six stress levels, resolves them against
## the active quality preset and the player's world position, clamps everything
## to GameConfig's hard caps, and publishes a single effective profile that
## every world manager reads.
##
## AUTO mode ramps the workload up while the frame rate holds, and backs off
## when it does not. It never removes the caps and never targets a crash.

enum Level { ECO, NORMAL, HEAVY, EXTREME, REDLINE, MELTDOWN }

const LEVEL_NAMES: PackedStringArray = [
	"ECO", "NORMAL", "HEAVY", "EXTREME", "REDLINE", "MELTDOWN",
]
const LEVEL_COLORS: PackedStringArray = [
	"3ad17c", "5ec8f0", "f0c04a", "ff8c2d", "ff3a2d", "d02bff",
]

## Base workload per level, before quality multipliers and zone scaling.
const TABLE: Array[Dictionary] = [
	{   # 0 ECO
		"npc_count": 26, "enemy_count": 6, "vehicle_count": 6, "rigid_bodies": 40,
		"veg_density": 0.35, "particle_budget": 900, "omni_lights": 8,
		"shadow_distance": 55.0, "stream_radius": 3, "lod_bias": 0.7,
		"cache_mb": 64, "ai_hz": 8.0, "debris_budget": 24, "weather_complexity": 0,
		"view_distance": 420.0, "full_npc_ratio": 0.22, "building_detail": 0.45,
		"destructible_stacks": 2, "particle_systems": 6, "grass_multiplier": 0.5,
	},
	{   # 1 NORMAL
		"npc_count": 70, "enemy_count": 16, "vehicle_count": 16, "rigid_bodies": 110,
		"veg_density": 0.7, "particle_budget": 2600, "omni_lights": 18,
		"shadow_distance": 90.0, "stream_radius": 4, "lod_bias": 1.0,
		"cache_mb": 160, "ai_hz": 10.0, "debris_budget": 70, "weather_complexity": 1,
		"view_distance": 700.0, "full_npc_ratio": 0.3, "building_detail": 0.7,
		"destructible_stacks": 5, "particle_systems": 12, "grass_multiplier": 1.0,
	},
	{   # 2 HEAVY
		"npc_count": 190, "enemy_count": 42, "vehicle_count": 40, "rigid_bodies": 230,
		"veg_density": 1.15, "particle_budget": 6500, "omni_lights": 34,
		"shadow_distance": 130.0, "stream_radius": 5, "lod_bias": 1.3,
		"cache_mb": 320, "ai_hz": 13.0, "debris_budget": 150, "weather_complexity": 2,
		"view_distance": 1000.0, "full_npc_ratio": 0.36, "building_detail": 1.0,
		"destructible_stacks": 10, "particle_systems": 22, "grass_multiplier": 1.5,
	},
	{   # 3 EXTREME
		"npc_count": 420, "enemy_count": 90, "vehicle_count": 78, "rigid_bodies": 400,
		"veg_density": 1.7, "particle_budget": 13000, "omni_lights": 52,
		"shadow_distance": 175.0, "stream_radius": 6, "lod_bias": 1.6,
		"cache_mb": 640, "ai_hz": 16.0, "debris_budget": 260, "weather_complexity": 3,
		"view_distance": 1400.0, "full_npc_ratio": 0.4, "building_detail": 1.3,
		"destructible_stacks": 18, "particle_systems": 34, "grass_multiplier": 2.1,
	},
	{   # 4 REDLINE
		"npc_count": 1050, "enemy_count": 220, "vehicle_count": 175, "rigid_bodies": 780,
		"veg_density": 2.5, "particle_budget": 30000, "omni_lights": 84,
		"shadow_distance": 250.0, "stream_radius": 8, "lod_bias": 2.3,
		"cache_mb": 2400, "ai_hz": 20.0, "debris_budget": 500, "weather_complexity": 4,
		"view_distance": 2300.0, "full_npc_ratio": 0.44, "building_detail": 1.6,
		"destructible_stacks": 28, "particle_systems": 48, "grass_multiplier": 2.8,
	},
	{   # 5 MELTDOWN
		"npc_count": 1800, "enemy_count": 340, "vehicle_count": 280, "rigid_bodies": 1100,
		"veg_density": 3.2, "particle_budget": 52000, "omni_lights": 96,
		"shadow_distance": 320.0, "stream_radius": 10, "lod_bias": 2.8,
		"cache_mb": 4096, "ai_hz": 24.0, "debris_budget": 760, "weather_complexity": 4,
		"view_distance": 3200.0, "full_npc_ratio": 0.5, "building_detail": 2.2,
		"destructible_stacks": 40, "particle_systems": 62, "grass_multiplier": 3.6,
	},
]

signal level_changed(level: int, profile: Dictionary)
signal auto_state_changed(active: bool)

var level: int = Level.NORMAL
var auto_mode: bool = false
var effective: Dictionary = {}
var locked: bool = false          ## benchmark holds the level steady

## World intensity (0..1) contributed by how deep the player has travelled.
## Only ever *adds* density inside the caps -- it does not reduce the
## level the player selected.
var zone_intensity: float = 0.0

# Auto-mode state
var auto_target_fps: float = 50.0
var auto_floor_fps: float = 28.0
var _auto_timer: float = 0.0
var _auto_hold: float = 0.0
var _auto_peak_level: int = 0
var _auto_backoffs: int = 0

const AUTO_STEP_UP_SECONDS: float = 9.0
const AUTO_STEP_DOWN_SECONDS: float = 3.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	level = clampi(int(GameConfig.settings.get("stress_level", Level.NORMAL)), 0, TABLE.size() - 1)
	AdaptiveQualityManager.profile_applied.connect(_on_quality_changed)
	EventBus.safety_throttle.connect(_on_safety_throttle)
	_recompute()


func level_name() -> String:
	return LEVEL_NAMES[clampi(level, 0, LEVEL_NAMES.size() - 1)]


func level_color() -> Color:
	return Color(LEVEL_COLORS[clampi(level, 0, LEVEL_COLORS.size() - 1)])


func set_level(l: int, persist: bool = true) -> void:
	var nl: int = clampi(l, 0, TABLE.size() - 1)
	if nl == level:
		return
	level = nl
	_auto_peak_level = maxi(_auto_peak_level, level)
	if persist:
		GameConfig.settings["stress_level"] = level
		GameConfig.save_settings()
	_recompute()
	EventBus.notify("STRESS: %s" % level_name(), 2.0)


func step(dir: int) -> void:
	if auto_mode:
		set_auto(false)
	set_level(level + dir)


func set_auto(active: bool) -> void:
	if auto_mode == active:
		return
	auto_mode = active
	_auto_timer = 0.0
	_auto_hold = 0.0
	_auto_backoffs = 0
	_auto_peak_level = level
	auto_state_changed.emit(auto_mode)
	EventBus.notify("AUTO STRESS %s" % ("ON" if active else "OFF"), 2.0)


func set_zone_intensity(v: float) -> void:
	var nv: float = clampf(v, 0.0, 1.0)
	if absf(nv - zone_intensity) < 0.02:
		return
	zone_intensity = nv
	_recompute()


func max_stable_level() -> int:
	return _auto_peak_level


func auto_backoff_count() -> int:
	return _auto_backoffs


func _on_quality_changed(_p: int, _prof: Dictionary) -> void:
	_recompute()


func _on_safety_throttle(reason: String) -> void:
	if locked:
		# Benchmarks abort rather than silently changing the workload they
		# claim to be measuring.
		EventBus.benchmark_aborted.emit("safety throttle: " + reason)
		return
	if level > 0:
		level -= 1
		_auto_backoffs += 1
		_recompute()
		EventBus.notify("SAFETY: stress reduced to %s (%s)" % [level_name(), reason], 4.0)
	if auto_mode:
		_auto_hold = 25.0


## Resolves base table + quality multipliers + zone intensity into the single
## dictionary the world reads, clamped to the hard caps.
## Benchmark-only per-subsystem multipliers, applied on top of the level table.
## A stage that wants to load the AI alone sets {"npc": 4.0, "veg": 0.15,
## "physics": 0.1}; everything else stays where the level put it. Empty during
## normal play, so nothing here changes the shipped balance.
var bench_overrides: Dictionary = {}


func set_bench_overrides(o: Dictionary) -> void:
	bench_overrides = o.duplicate()
	_recompute()


func _ov(key: String) -> float:
	return float(bench_overrides.get(key, 1.0))


func _recompute() -> void:
	var base: Dictionary = TABLE[clampi(level, 0, TABLE.size() - 1)]
	var q: Dictionary = AdaptiveQualityManager.effective()

	# Zone intensity adds up to +85% population/geometry as the player pushes
	# deeper into the world. Vegetation is deliberately not scaled up by zone,
	# because the outer zones are urban.
	var zi: float = 1.0 + zone_intensity * 0.85

	var e: Dictionary = {}
	e["npc_count"] = _capi(base["npc_count"] * q["npc_mult"] * zi * _ov("npc"), GameConfig.MAX_NPCS)
	e["enemy_count"] = _capi(base["enemy_count"] * q["npc_mult"] * zi * _ov("npc"), GameConfig.MAX_NPCS / 3)
	e["vehicle_count"] = _capi(
		base["vehicle_count"] * q["traffic_mult"] * zi * _ov("traffic"), GameConfig.MAX_VEHICLES
	)
	e["rigid_bodies"] = _capi(
		base["rigid_bodies"] * q["physics_mult"] * zi * _ov("physics"), GameConfig.MAX_RIGID_BODIES
	)
	e["debris_budget"] = _capi(base["debris_budget"] * q["physics_mult"] * _ov("physics"), GameConfig.MAX_DEBRIS)
	e["destructible_stacks"] = _capi(base["destructible_stacks"] * q["physics_mult"] * zi * _ov("physics"), 64)
	e["veg_density"] = clampf(float(base["veg_density"]) * float(q["veg_mult"]) * _ov("veg"), 0.0, 6.0)
	e["grass_multiplier"] = clampf(
		float(base["grass_multiplier"]) * float(q["veg_mult"]) * _ov("veg"), 0.0, 8.0
	)
	e["particle_budget"] = _capi(base["particle_budget"] * q["particle_mult"] * zi, 90000)
	e["particle_systems"] = _capi(
		base["particle_systems"] * q["particle_mult"], GameConfig.MAX_PARTICLE_SYSTEMS
	)
	e["omni_lights"] = _capi(
		base["omni_lights"] * q["light_mult"] * zi, GameConfig.MAX_OMNI_LIGHTS
	)
	e["shadow_distance"] = minf(
		float(base["shadow_distance"]), float(q["shadow_distance"])
	)
	e["positional_shadows"] = bool(q.get("positional_shadows", true))
	e["shadow_splits"] = int(q.get("shadow_splits", 2))
	e["stream_radius"] = clampi(
		int(base["stream_radius"]) + int(q.get("stream_bonus", 0))
			+ int(bench_overrides.get("stream_bonus", 0)),
		2, GameConfig.MAX_STREAM_RADIUS
	)
	e["lod_bias"] = clampf(float(base["lod_bias"]) * float(q["lod_bias"]), 0.2, 6.0)
	e["view_distance"] = clampf(
		float(base["view_distance"]) * float(q["view_mult"]) * _ov("view"), 120.0, 4000.0
	)
	var cache_target: float = minf(float(base["cache_mb"]), float(q.get("cache_mb", 256))) * _ov("cache")
	if bool(GameConfig.settings.get("high_memory_mode", false)):
		cache_target *= 2.5
	# Whatever the table asks for, never exceed what this device should hold.
	e["cache_mb"] = _capi(cache_target,
		AdaptiveQualityManager.device_cache_budget_mb())
	e["ai_hz"] = clampf(float(base["ai_hz"]), 2.0, 40.0)
	e["weather_complexity"] = int(base["weather_complexity"])
	e["full_npc_ratio"] = clampf(float(base["full_npc_ratio"]), 0.05, 1.0)
	e["building_detail"] = clampf(
		float(base["building_detail"]) * float(q["lod_bias"]) * _ov("geometry"), 0.2, 4.0
	)
	e["render_scale"] = float(q["render_scale"])
	e["glow"] = bool(q.get("glow", true))
	e["fog_detail"] = int(q.get("fog_detail", 1))

	# Derived NPC tier budgets.
	e["npc_full"] = clampi(
		int(round(float(e["npc_count"]) * float(e["full_npc_ratio"]))),
		2, GameConfig.MAX_FULL_NPCS
	)
	e["npc_reduced"] = clampi(
		int(round(float(e["npc_count"]) * 0.38)), 4, GameConfig.MAX_REDUCED_NPCS
	)

	e["level"] = level
	e["level_name"] = level_name()
	e["quality_preset"] = q.get("preset_name", "?")

	effective = e
	level_changed.emit(level, effective)
	EventBus.stress_level_changed.emit(level, effective)


func _capi(v: float, cap: int) -> int:
	return clampi(int(round(v)), 0, cap)


func get_param(key: String, fallback: Variant = 0) -> Variant:
	return effective.get(key, fallback)


# -----------------------------------------------------------------------------
# AUTO mode
# -----------------------------------------------------------------------------
func _process(delta: float) -> void:
	if not auto_mode or locked:
		return
	if _auto_hold > 0.0:
		_auto_hold -= delta
		return

	var f: float = PerformanceMonitor.smoothed_fps
	if PerformanceMonitor.fps_history.size() < 40:
		return

	if f < auto_floor_fps:
		_auto_timer -= delta * 3.0
		if _auto_timer <= -AUTO_STEP_DOWN_SECONDS:
			_auto_timer = 0.0
			if level > 0:
				_auto_backoffs += 1
				level -= 1
				_recompute()
				EventBus.notify(
					"AUTO: backing off to %s (%.0f fps)" % [level_name(), f], 3.0
				)
				_auto_hold = 6.0
			else:
				set_auto(false)
				EventBus.notify("AUTO: already at ECO, stopping", 3.0)
	elif f > auto_target_fps:
		_auto_timer += delta
		if _auto_timer >= AUTO_STEP_UP_SECONDS:
			_auto_timer = 0.0
			if level < TABLE.size() - 1:
				level += 1
				_auto_peak_level = maxi(_auto_peak_level, level)
				_recompute()
				EventBus.notify("AUTO: climbing to %s" % level_name(), 3.0)
				_auto_hold = 5.0
			else:
				_auto_hold = 10.0
	else:
		_auto_timer = move_toward(_auto_timer, 0.0, delta)
