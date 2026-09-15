extends Node
## Static tunables, hard safety caps, and input action registration.
## Nothing here changes at runtime except `world_seed` and the persisted
## user settings block.

# --- World geometry ----------------------------------------------------------
const CHUNK_SIZE: float = 64.0
const CHUNK_VERTS_LOD0: int = 33      # 32 quads -> 2.0 m resolution
const CHUNK_VERTS_LOD1: int = 17
const CHUNK_VERTS_LOD2: int = 9
const CHUNK_VERTS_LOD3: int = 5
const COLLISION_RADIUS: int = 2       # chunks around player that get trimesh collision
const WATER_LEVEL: float = -6.0
const TERRAIN_AMPLITUDE: float = 46.0

# --- Zone bands (metres from world origin) -----------------------------------
enum Zone { WILDERNESS, FOREST, SETTLEMENT, TOWN, CITY, INDUSTRIAL, REDLINE }

const ZONE_NAMES: PackedStringArray = [
	"WILDERNESS", "DENSE FOREST", "SETTLEMENT", "TOWN", "DENSE CITY",
	"INDUSTRIAL", "REDLINE ZONE",
]
const ZONE_RADII: PackedFloat32Array = [250.0, 600.0, 1000.0, 1500.0, 2100.0, 2800.0]

# --- Hard safety caps (never exceeded regardless of stress level) ------------
const MAX_NPCS: int = 2200
const MAX_FULL_NPCS: int = 160
const MAX_REDUCED_NPCS: int = 620
const MAX_VEHICLES: int = 320
const MAX_RIGID_BODIES: int = 1200
const MAX_DEBRIS: int = 800
const MAX_OMNI_LIGHTS: int = 96
const MAX_PARTICLE_SYSTEMS: int = 64
const MAX_STREAM_RADIUS: int = 12
## Ceiling on retained world data. Android will not hand a process anything
## like the device's full RAM, but a native app on a 12 GB+ phone can hold
## several gigabytes of real geometry; the auto-detected budget below is what
## actually applies on any given device.
const MAX_CACHE_MB: int = 6144
const MAX_PROJECTILES: int = 256
const MAX_EXPLOSION_BODIES: int = 160

# Safety: if smoothed FPS stays under this for this long, force stress down.
const SAFETY_FPS_FLOOR: float = 9.0
const SAFETY_FPS_FLOOR_SECONDS: float = 6.0
const SAFETY_MEMORY_HEADROOM_MB: float = 512.0

# --- Gameplay ----------------------------------------------------------------
const PLAYER_MAX_HEALTH: float = 100.0
const PLAYER_MAX_STAMINA: float = 100.0
const PLAYER_WALK_SPEED: float = 4.4
const PLAYER_SPRINT_SPEED: float = 8.2
const PLAYER_CROUCH_SPEED: float = 2.0
const PLAYER_JUMP_VELOCITY: float = 5.2
const PLAYER_EYE_HEIGHT: float = 1.65
const PLAYER_CROUCH_EYE_HEIGHT: float = 0.95

# --- Physics layers (1-indexed bit positions from project.godot) -------------
const L_WORLD: int = 1 << 0
const L_PLAYER: int = 1 << 1
const L_NPC: int = 1 << 2
const L_ENEMY: int = 1 << 3
const L_DEBRIS: int = 1 << 4
const L_VEHICLE: int = 1 << 5
const L_PROJECTILE: int = 1 << 6
const L_INTERACT: int = 1 << 7

var world_seed: int = 20260914
var settings_path: String = "user://redline_settings.cfg"
var benchmark_dir: String = "user://benchmarks"

## Persisted user settings (written by the pause menu / quality manager).
var settings: Dictionary = {
	"quality_preset": -1,          # -1 = auto-detect
	"stress_level": 1,
	"hud_mode": 1,                 # 0 off, 1 compact, 2 expanded
	"touch_controls": -1,          # -1 auto, 0 off, 1 on
	"look_sensitivity": 1.0,
	"invert_look": false,
	"high_memory_mode": false,
	"adaptive_quality": true,
}


func _enter_tree() -> void:
	_register_input_actions()
	_register_shader_globals()
	_load_settings()
	DirAccess.make_dir_recursive_absolute(benchmark_dir)


## Global shader uniforms shared by terrain, foliage, buildings, props and the
## sky. Registered before any material loads so `global uniform` declarations
## always resolve.
func _register_shader_globals() -> void:
	_global_float("redline_night", 0.0)
	_global_float("redline_wind", 0.25)
	_global_float("redline_wetness", 0.0)


func _global_float(name: String, value: float) -> void:
	# global_shader_parameter_get_list() is editor-only and logs a performance
	# error at runtime. Adding an existing global is harmless, so just add.
	RenderingServer.global_shader_parameter_add(
		name, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, value
	)
	RenderingServer.global_shader_parameter_set(name, value)


static func set_shader_global(name: String, value: Variant) -> void:
	RenderingServer.global_shader_parameter_set(name, value)


func zone_for_radius(r: float) -> int:
	for i in ZONE_RADII.size():
		if r < ZONE_RADII[i]:
			return i
	return Zone.REDLINE


func zone_for_position(p: Vector3) -> int:
	return zone_for_radius(Vector2(p.x, p.z).length())


## 0.0 at the inner edge of the zone, 1.0 at the outer edge. Used to ramp
## density smoothly instead of popping at band boundaries.
func zone_progress(r: float) -> float:
	var z: int = zone_for_radius(r)
	var lo: float = 0.0 if z == 0 else ZONE_RADII[z - 1]
	var hi: float = ZONE_RADII[z] if z < ZONE_RADII.size() else lo + 900.0
	return clampf((r - lo) / maxf(1.0, hi - lo), 0.0, 1.0)


## Continuous 0..1 "how deep into the world am I" value driving global density.
func world_intensity(r: float) -> float:
	var last: float = ZONE_RADII[ZONE_RADII.size() - 1]
	return clampf(r / (last + 700.0), 0.0, 1.0)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for k: String in settings.keys():
		cfg.set_value("redline", k, settings[k])
	var err: int = cfg.save(settings_path)
	if err != OK:
		push_warning("REDLINE: could not save settings (%d)" % err)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(settings_path) != OK:
		return
	for k: String in settings.keys():
		if cfg.has_section_key("redline", k):
			settings[k] = cfg.get_value("redline", k, settings[k])


# -----------------------------------------------------------------------------
# Input actions are registered in code rather than serialised into project.godot
# so the mapping stays readable and cannot be corrupted by a bad merge.
# -----------------------------------------------------------------------------
func _register_input_actions() -> void:
	_action("move_forward", [KEY_W, KEY_UP])
	_action("move_back", [KEY_S, KEY_DOWN])
	_action("move_left", [KEY_A, KEY_LEFT])
	_action("move_right", [KEY_D, KEY_RIGHT])
	_action("jump", [KEY_SPACE])
	_action("sprint", [KEY_SHIFT])
	_action("crouch", [KEY_CTRL, KEY_C])
	_action("interact", [KEY_E, KEY_F])
	_action("reload", [KEY_R])
	_action("pause", [KEY_ESCAPE, KEY_P])
	_action("toggle_hud", [KEY_F1])
	_action("cycle_hud", [KEY_F2])
	_action("stress_up", [KEY_BRACKETRIGHT])
	_action("stress_down", [KEY_BRACKETLEFT])
	_action("toggle_stress_auto", [KEY_BACKSLASH])
	_action("run_benchmark", [KEY_F5])
	_action("run_endurance", [KEY_F6])
	_action("toggle_touch", [KEY_F3])
	_action("free_mouse", [KEY_ALT])
	_action("slot_1", [KEY_1])
	_action("slot_2", [KEY_2])
	_action("slot_3", [KEY_3])

	if not InputMap.has_action("attack"):
		InputMap.add_action("attack")
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("attack", mb)
	if not InputMap.has_action("aim"):
		InputMap.add_action("aim")
		var mb2 := InputEventMouseButton.new()
		mb2.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event("aim", mb2)


func _action(name: String, keys: Array) -> void:
	if InputMap.has_action(name):
		InputMap.erase_action(name)
	InputMap.add_action(name, 0.2)
	for k: int in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(name, ev)
