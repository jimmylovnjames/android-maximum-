class_name WeatherManager
extends Node3D
## Wind, rain and storm state. Weather complexity is one of the StressDirector
## parameters: higher levels add more particles, heavier fog and stronger wind
## response in the vegetation and water shaders.

enum Weather { CLEAR, BREEZE, OVERCAST, RAIN, STORM }

const WEATHER_NAMES: PackedStringArray = ["CLEAR", "BREEZE", "OVERCAST", "RAIN", "STORM"]

signal weather_changed(state: int, name: String)

var state: int = Weather.CLEAR
var wind: float = 0.25
var wetness: float = 0.0
var complexity: int = 1
var auto_cycle: bool = true
var cycle_seconds: float = 95.0

var _timer: float = 0.0
var _rain: GPUParticles3D = null
var _splash: GPUParticles3D = null
var _target_wetness: float = 0.0
var _target_wind: float = 0.25
var _follow: Node3D = null
var _mat: MaterialLib
var _day_night: DayNightSystem = null
var _particle_budget: int = 2000
var _lightning_cd: float = 6.0
var _flash: OmniLight3D = null


func setup(mat: MaterialLib, follow: Node3D, day_night: DayNightSystem) -> void:
	_mat = mat
	_follow = follow
	_day_night = day_night
	_build_rain()


func _build_rain() -> void:
	var mesh_lib: MeshLib = MeshLib.get_instance()

	var rain_mat := StandardMaterial3D.new()
	rain_mat.albedo_color = Color(0.68, 0.76, 0.88, 0.45)
	rain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rain_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	rain_mat.billboard_keep_scale = true
	rain_mat.vertex_color_use_as_albedo = true
	rain_mat.no_depth_test = false

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(26.0, 1.0, 26.0)
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = 4.0
	pm.gravity = Vector3(0.0, -34.0, 0.0)
	pm.initial_velocity_min = 12.0
	pm.initial_velocity_max = 18.0
	pm.scale_min = 0.7
	pm.scale_max = 1.6
	pm.color = Color(0.7, 0.78, 0.9, 0.5)

	_rain = GPUParticles3D.new()
	_rain.name = "Rain"
	_rain.draw_pass_1 = mesh_lib.get_mesh("rain_quad")
	_rain.material_override = rain_mat
	_rain.process_material = pm
	_rain.amount = 2000
	_rain.lifetime = 1.4
	_rain.preprocess = 0.8
	_rain.local_coords = false
	_rain.visibility_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 60, 60))
	_rain.emitting = false
	add_child(_rain)

	_flash = OmniLight3D.new()
	_flash.name = "LightningFlash"
	_flash.light_energy = 0.0
	_flash.omni_range = 220.0
	_flash.light_color = Color(0.82, 0.88, 1.0)
	_flash.shadow_enabled = false
	add_child(_flash)


func apply_profile(profile: Dictionary) -> void:
	complexity = int(profile.get("weather_complexity", 1))
	_particle_budget = int(profile.get("particle_budget", 2000))
	_refresh_particles()


func _refresh_particles() -> void:
	if _rain == null:
		return
	var want: int = 0
	match state:
		Weather.RAIN:
			want = int(float(_particle_budget) * 0.45)
		Weather.STORM:
			want = int(float(_particle_budget) * 0.85)
		_:
			want = 0
	want = clampi(want, 0, 45000)
	_rain.emitting = want > 0 and complexity > 0
	if want > 0:
		_rain.amount = maxi(64, want)
		var pm: ParticleProcessMaterial = _rain.process_material as ParticleProcessMaterial
		if pm != null:
			var extent: float = 26.0 + float(complexity) * 5.0
			pm.emission_box_extents = Vector3(extent, 1.0, extent)
			pm.direction = Vector3(wind * 0.8, -1.0, wind * 0.3).normalized()


func set_weather(s: int, announce: bool = true) -> void:
	state = clampi(s, 0, WEATHER_NAMES.size() - 1)
	match state:
		Weather.CLEAR:
			_target_wind = 0.18
			_target_wetness = 0.0
		Weather.BREEZE:
			_target_wind = 0.55
			_target_wetness = 0.0
		Weather.OVERCAST:
			_target_wind = 0.35
			_target_wetness = 0.08
		Weather.RAIN:
			_target_wind = 0.7
			_target_wetness = 0.85
		Weather.STORM:
			_target_wind = 1.3
			_target_wetness = 1.0
	_refresh_particles()
	if _day_night != null:
		_day_night.set_storm_blend(
			0.0 if state <= Weather.BREEZE else (0.45 if state == Weather.OVERCAST
				else (0.8 if state == Weather.RAIN else 1.0))
		)
	if _mat != null and _mat.sky_material != null:
		_mat.sky_material.set_shader_parameter("overcast",
			0.0 if state <= Weather.BREEZE else (0.55 if state == Weather.OVERCAST
				else (0.8 if state == Weather.RAIN else 0.95)))
	weather_changed.emit(state, WEATHER_NAMES[state])
	if announce:
		EventBus.notify("WEATHER: %s" % WEATHER_NAMES[state], 2.5)


func cycle() -> void:
	set_weather(wrapi(state + 1, 0, WEATHER_NAMES.size()))


func _process(delta: float) -> void:
	wind = move_toward(wind, _target_wind, delta * 0.45)
	wetness = move_toward(wetness, _target_wetness, delta * 0.25)
	GameConfig.set_shader_global("redline_wind", wind)
	GameConfig.set_shader_global("redline_wetness", wetness)

	if _follow != null and is_instance_valid(_follow) and _rain != null:
		var p: Vector3 = _follow.global_position
		_rain.global_position = p + Vector3(0.0, 16.0, 0.0)
		if _flash != null:
			_flash.global_position = p + Vector3(0.0, 60.0, 0.0)

	if state == Weather.STORM and complexity >= 3:
		_lightning_cd -= delta
		if _lightning_cd <= 0.0:
			_lightning_cd = randf_range(3.5, 11.0)
			_strike()
	if _flash != null and _flash.light_energy > 0.0:
		_flash.light_energy = maxf(0.0, _flash.light_energy - delta * 14.0)

	if auto_cycle and GameState.phase == GameState.Phase.PLAYING:
		_timer += delta
		if _timer >= cycle_seconds:
			_timer = 0.0
			_pick_weather()


func _strike() -> void:
	if _flash == null:
		return
	_flash.light_energy = 6.0


## Weather gets harsher the deeper the player is, which is both flavour and a
## deliberate late-world workload increase.
func _pick_weather() -> void:
	var depth: float = GameConfig.world_intensity(GameState.deepest_radius)
	var r: float = randf()
	var s: int = Weather.CLEAR
	if r < 0.32 - depth * 0.2:
		s = Weather.CLEAR
	elif r < 0.55:
		s = Weather.BREEZE
	elif r < 0.72:
		s = Weather.OVERCAST
	elif r < 0.9 - depth * 0.1:
		s = Weather.RAIN
	else:
		s = Weather.STORM
	if complexity <= 0:
		s = mini(s, Weather.BREEZE)
	elif complexity == 1:
		s = mini(s, Weather.OVERCAST)
	set_weather(s, false)


func state_name() -> String:
	return WEATHER_NAMES[clampi(state, 0, WEATHER_NAMES.size() - 1)]


func particle_count() -> int:
	if _rain == null or not _rain.emitting:
		return 0
	return _rain.amount
