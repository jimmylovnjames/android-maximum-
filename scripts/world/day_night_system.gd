class_name DayNightSystem
extends Node3D
## Drives the sun, moon, sky and environment through a 24-hour cycle and
## publishes the night factor every shader reads.

signal time_changed(hours: float)

const DAY_LENGTH_DEFAULT: float = 900.0     ## seconds for a full 24 h cycle

@export var hours: float = 9.5
var day_length: float = DAY_LENGTH_DEFAULT
var paused: bool = false

var sun: DirectionalLight3D
var moon: DirectionalLight3D
var env_node: WorldEnvironment
var environment: Environment
var sky: Sky

var night_factor: float = 0.0
var _mat: MaterialLib
var _shadow_distance: float = 110.0
var _shadow_splits: int = 2
var _fog_detail: int = 1
var _glow: bool = true
var _storm_blend: float = 0.0
## How built-up the player's surroundings are, 0..1. Drives the night ambient
## floor so a city is not as dark as open wilderness.
var _urban: float = 0.0


func setup(mat: MaterialLib) -> void:
	_mat = mat

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.05
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = _shadow_distance
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.16
	sun.directional_shadow_split_3 = 0.42
	# Both of these were below Godot's own defaults (0.1 / 2.0). On a large
	# flat surface seen at a grazing angle -- which is what a road is, most of
	# the time -- that under-biasing produced shadow acne as radial streaks
	# converging on the camera. Verified by bisection: with every texture term
	# in the terrain shader replaced by flat vertex colour the streaks were
	# still there, so they were never a texture-filtering problem.
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 2.4
	# A non-zero angular diameter softens shadow edges with distance, which is
	# most of what sells outdoor lighting and costs nothing extra.
	sun.light_angular_distance = 0.65
	sun.light_specular = 0.8
	add_child(sun)

	moon = DirectionalLight3D.new()
	moon.name = "Moon"
	moon.light_energy = 0.24
	moon.light_color = Color(0.6, 0.72, 1.0)
	moon.shadow_enabled = false
	add_child(moon)

	sky = Sky.new()
	sky.sky_material = _mat.sky_material
	# Incremental rather than realtime: the sky has animated clouds and a
	# moving sun, so the radiance map does need to update, but rebuilding it
	# every frame is a cost a phone should not pay. Realtime also forces a
	# 256px radiance map regardless of what is requested.
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL

	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 0.85
	environment.ambient_light_color = Color(0.58, 0.60, 0.66)
	environment.ambient_light_energy = 0.58
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	# 3.2 left almost nothing for the highlight shoulder to do, so full
	# daylight pushed every albedo towards white and the world looked
	# bleached. 2.6 plus a daytime exposure pull gives the midtones back.
	environment.tonemap_white = 2.6
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_light_color = Color(0.62, 0.68, 0.76)
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = 0.14
	environment.fog_density = 0.0011
	environment.fog_aerial_perspective = 0.22
	environment.fog_sky_affect = 0.12
	environment.fog_depth_begin = 60.0
	environment.fog_depth_end = 1600.0
	environment.fog_depth_curve = 1.35
	# Ground mist. Depth fog alone makes distance hazy; height fog is what puts
	# a layer in the valleys and between the trees.
	environment.fog_height = 6.0
	environment.fog_height_density = 0.055
	environment.glow_enabled = true
	environment.glow_intensity = 0.55
	environment.glow_strength = 1.0
	environment.glow_bloom = 0.12
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	# Threshold well above the lit-window value: at 0.95 with a 2.0 scale every
	# window bloomed into its neighbours and the city read as floating lights
	# over a black void.
	environment.glow_hdr_threshold = 1.7
	environment.glow_hdr_scale = 0.9
	# Weight the wider blur levels so bloom is a soft halo, not a hard ring.
	# set_glow_level is zero-indexed; the inspector labels the same slots 1..7.
	for i in 7:
		environment.set_glow_level(i, [0.15, 0.4, 0.85, 1.0, 0.6, 0.3, 0.12][i])

	# Film-style grade. Supported by the mobile renderer because it happens in
	# the tonemap pass rather than as a separate screen-space effect.
	environment.adjustment_enabled = true
	environment.adjustment_brightness = 1.0
	environment.adjustment_contrast = 1.14
	environment.adjustment_saturation = 1.12

	env_node = WorldEnvironment.new()
	env_node.name = "WorldEnvironment"
	env_node.environment = environment
	add_child(env_node)


func apply_profile(profile: Dictionary) -> void:
	_shadow_distance = float(profile.get("shadow_distance", 110.0))
	_shadow_splits = int(profile.get("shadow_splits", 2))
	_glow = bool(profile.get("glow", true))
	_fog_detail = int(profile.get("fog_detail", 1))
	if sun == null:
		return
	sun.directional_shadow_max_distance = _shadow_distance
	match clampi(_shadow_splits, 1, 4):
		1:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		2:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		3:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		_:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	if environment != null:
		environment.glow_enabled = _glow
		environment.fog_enabled = _fog_detail > 0
		environment.fog_aerial_perspective = 0.12 + 0.1 * float(_fog_detail)
		environment.fog_depth_end = maxf(600.0,
			float(profile.get("view_distance", 900.0)) * 1.1)


func set_time(h: float) -> void:
	hours = fposmod(h, 24.0)
	_update(true)


func advance(delta: float) -> void:
	if paused:
		return
	hours = fposmod(hours + delta * (24.0 / maxf(1.0, day_length)), 24.0)


func set_urban_factor(v: float) -> void:
	_urban = clampf(v, 0.0, 1.0)


func set_storm_blend(v: float) -> void:
	_storm_blend = clampf(v, 0.0, 1.0)
	if _mat != null and _mat.sky_material != null:
		_mat.sky_material.set_shader_parameter("cloud_cover",
			lerpf(0.38, 0.95, _storm_blend))
		_mat.sky_material.set_shader_parameter("cloud_sharpness",
			lerpf(4.5, 2.2, _storm_blend))


func _process(delta: float) -> void:
	# Timed so the benchmark can separate this manager's script cost from
	# render and physics time. See PerformanceMonitor.record_subsystem.
	var _t0: int = Time.get_ticks_usec()
	_step_profiled(delta)
	PerformanceMonitor.record_subsystem("daynight", Time.get_ticks_usec() - _t0)


func _step_profiled(delta: float) -> void:
	advance(delta)
	_update(false)


func _update(_force: bool) -> void:
	# Sun elevation: 0h = midnight (below horizon), 12h = noon (overhead).
	var t: float = (hours / 24.0) * TAU - PI * 0.5
	var elev: float = sin(t)
	var azim: float = hours / 24.0 * TAU

	var sun_dir: Vector3 = Vector3(
		cos(azim) * 0.55, -elev, sin(azim) * 0.55
	).normalized()
	sun.look_at_from_position(Vector3.ZERO, sun_dir, Vector3.UP)
	moon.look_at_from_position(Vector3.ZERO, -sun_dir, Vector3.UP)

	night_factor = clampf(smoothstep(0.08, -0.18, elev), 0.0, 1.0)

	var dusk: float = clampf(1.0 - absf(elev) * 3.4, 0.0, 1.0)
	var warm := Color(1.0, 0.62, 0.34)
	var noon := Color(1.0, 0.97, 0.9)
	sun.light_color = noon.lerp(warm, dusk)
	sun.light_energy = clampf(elev * 1.35 + 0.06, 0.0, 1.15) * (1.0 - _storm_blend * 0.6)
	sun.visible = sun.light_energy > 0.005
	moon.light_energy = 0.26 * night_factor
	moon.visible = moon.light_energy > 0.005

	if environment != null:
		var day_fog := Color(0.55, 0.64, 0.76)
		var dusk_fog := Color(0.72, 0.42, 0.26)
		var night_fog := Color(0.05, 0.06, 0.10)
		var fc: Color = day_fog.lerp(dusk_fog, dusk * 0.8).lerp(night_fog, night_factor)
		environment.fog_light_color = fc.lerp(Color(0.42, 0.44, 0.48), _storm_blend * 0.7)
		environment.fog_density = lerpf(0.0010, 0.0042, _storm_blend) * (1.0 + night_factor * 0.4)
		# Light pollution: a built-up area never goes as dark as open country,
		# and without this the facades between the windows are pure black.
		#
		# Ambient is a blend of the sky radiance map and the explicit colour,
		# weighted by ambient_light_sky_contribution, so at 0.85 only ~15% of
		# the floor below reaches a wall. Do NOT lower that weight to
		# compensate: with BG_SKY the reduced contribution leaks the ambient
		# colour into the sky background as a flat wash (measured -- the night
		# sky went from RGB 4,0,0 to 128,91,49 on the same frame). Raising the
		# energy instead leaves the background alone, which is why the night
		# figures here look large.
		var night_floor: float = lerpf(0.52, 1.05, _urban)
		environment.ambient_light_energy = lerpf(0.58, night_floor, night_factor)
		environment.ambient_light_color = Color(0.58, 0.60, 0.66).lerp(
			Color(0.42, 0.48, 0.66), night_factor).lerp(
			Color(0.95, 0.72, 0.46), _urban * night_factor)
		# Ground mist belongs in the valleys and between the trees. Left at
		# full strength over a built-up area it sat at eye level down every
		# street and turned the city into milk, so it thins out as the
		# surroundings get more urban.
		environment.fog_height_density = lerpf(0.05, 0.16, _storm_blend) \
			* lerpf(1.0, 2.1, night_factor) * lerpf(1.0, 0.16, _urban)
		environment.fog_height = lerpf(7.0, 2.5, _storm_blend)
		environment.fog_depth_begin = lerpf(60.0, 170.0, _urban)
		# Night needs the sensitivity; daylight does not.
		environment.tonemap_exposure = lerpf(0.80, 1.0, night_factor)
		environment.adjustment_saturation = lerpf(1.12, 0.95, night_factor)
		environment.adjustment_contrast = lerpf(1.14, 1.08, night_factor)
		environment.glow_intensity = lerpf(0.38, 0.46, night_factor) if _glow else 0.0

	GameConfig.set_shader_global("redline_night", night_factor)
	# Ambient cannot carry the urban night lift on its own without washing the
	# sky (see the note above), so the facades and streets take it from here.
	GameConfig.set_shader_global("redline_urban_night", _urban * night_factor)
	time_changed.emit(hours)


func time_string() -> String:
	var h: int = int(hours)
	var m: int = int((hours - float(h)) * 60.0)
	return "%02d:%02d" % [h, m]
