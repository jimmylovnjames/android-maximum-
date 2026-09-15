extends Node
## Owns rendering quality: the five presets, capability auto-detection, and an
## optional adaptive safety net that lowers render scale / shadow budget when
## the frame rate collapses. It never *raises* workload -- that is
## StressDirector's job -- it only protects playability.

enum Preset { BATTERY, BALANCED, HIGH, ULTRA, INSANE }

const PRESET_NAMES: PackedStringArray = ["BATTERY", "BALANCED", "HIGH", "ULTRA", "INSANE"]

## Absolute render settings + workload multipliers per preset.
const PRESETS: Array[Dictionary] = [
	{   # BATTERY
		"render_scale": 0.62, "msaa": 0, "shadow_atlas": 1024, "dir_shadow_size": 1024,
		"soft_shadow_quality": 0, "shadow_distance": 42.0, "shadow_splits": 1,
		"positional_shadows": false, "veg_mult": 0.35, "view_mult": 0.55,
		"npc_mult": 0.4, "traffic_mult": 0.35, "physics_mult": 0.35,
		"particle_mult": 0.3, "light_mult": 0.35, "cache_mb": 48, "lod_bias": 0.45,
		"stream_bonus": -1, "glow": false, "fog_detail": 0,
	},
	{   # BALANCED
		"render_scale": 0.8, "msaa": 0, "shadow_atlas": 2048, "dir_shadow_size": 2048,
		"soft_shadow_quality": 1, "shadow_distance": 75.0, "shadow_splits": 2,
		"positional_shadows": false, "veg_mult": 0.65, "view_mult": 0.8,
		"npc_mult": 0.7, "traffic_mult": 0.7, "physics_mult": 0.7,
		"particle_mult": 0.65, "light_mult": 0.7, "cache_mb": 128, "lod_bias": 0.75,
		"stream_bonus": 0, "glow": true, "fog_detail": 1,
	},
	{   # HIGH
		"render_scale": 1.0, "msaa": 1, "shadow_atlas": 2048, "dir_shadow_size": 2048,
		"soft_shadow_quality": 1, "shadow_distance": 110.0, "shadow_splits": 2,
		"positional_shadows": true, "veg_mult": 1.0, "view_mult": 1.0,
		"npc_mult": 1.0, "traffic_mult": 1.0, "physics_mult": 1.0,
		"particle_mult": 1.0, "light_mult": 1.0, "cache_mb": 256, "lod_bias": 1.0,
		"stream_bonus": 0, "glow": true, "fog_detail": 1,
	},
	{   # ULTRA
		"render_scale": 1.0, "msaa": 2, "shadow_atlas": 4096, "dir_shadow_size": 4096,
		"soft_shadow_quality": 2, "shadow_distance": 165.0, "shadow_splits": 3,
		"positional_shadows": true, "veg_mult": 1.5, "view_mult": 1.5,
		"npc_mult": 1.3, "traffic_mult": 1.3, "physics_mult": 1.3,
		"particle_mult": 1.35, "light_mult": 1.35, "cache_mb": 1024, "lod_bias": 1.5,
		"stream_bonus": 2, "glow": true, "fog_detail": 2,
	},
	{   # INSANE -- intended for Snapdragon 8 Gen 3 class hardware
		"render_scale": 1.15, "msaa": 2, "shadow_atlas": 4096, "dir_shadow_size": 4096,
		"soft_shadow_quality": 3, "shadow_distance": 240.0, "shadow_splits": 4,
		"positional_shadows": true, "veg_mult": 2.4, "view_mult": 2.1,
		"npc_mult": 1.9, "traffic_mult": 1.9, "physics_mult": 1.8,
		"particle_mult": 1.9, "light_mult": 1.9, "cache_mb": 3072, "lod_bias": 2.2,
		"stream_bonus": 3, "glow": true, "fog_detail": 2,
	},
]

signal profile_applied(preset: int, profile: Dictionary)

var preset: int = Preset.HIGH
var profile: Dictionary = {}
var adaptive_enabled: bool = true

## Adaptive state: a 0..1 dial that scales render_scale and shadow distance
## down when the frame rate is unplayable, and recovers slowly afterwards.
var adaptive_factor: float = 1.0
var target_fps: float = 45.0
var critical_fps: float = 22.0

var _detected: bool = false
var _detect_reason: String = "not detected"
var _cooldown: float = 0.0
var _headless: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_headless = DisplayServer.get_name() == "headless"
	adaptive_enabled = bool(GameConfig.settings.get("adaptive_quality", true))
	var saved: int = int(GameConfig.settings.get("quality_preset", -1))
	if saved >= 0 and saved < PRESETS.size():
		preset = saved
		_detect_reason = "user selected"
	else:
		preset = detect_preset()
	apply_preset(preset, false)
	EventBus.safety_throttle.connect(_on_safety_throttle)


## Picks a sane default from what the platform actually reports. Deliberately
## conservative: a device that lies about its capabilities still gets a
## playable default, and the user can override it in the pause menu.
func detect_preset() -> int:
	_detected = true
	var cores: int = OS.get_processor_count()
	var mi: Dictionary = OS.get_memory_info()
	var phys_mb: float = float(mi.get("physical", -1)) / 1048576.0
	var adapter: String = RenderingServer.get_video_adapter_name().to_lower()
	var mobile: bool = OS.has_feature("mobile") or OS.get_name() == "Android"

	if _headless:
		_detect_reason = "headless display server"
		return Preset.BALANCED

	if mobile:
		# Flagship Adreno 7xx / recent Mali / Xclipse with plenty of RAM.
		var flagship: bool = (
			adapter.contains("adreno (tm) 7") or adapter.contains("adreno 7")
			or adapter.contains("adreno (tm) 8") or adapter.contains("adreno 8")
			or adapter.contains("immortalis") or adapter.contains("xclipse")
		)
		if flagship and phys_mb >= 11000.0 and cores >= 8:
			_detect_reason = "flagship mobile GPU '%s', %.0f MB RAM" % [adapter, phys_mb]
			return Preset.ULTRA
		if flagship or (phys_mb >= 7000.0 and cores >= 8):
			_detect_reason = "high-end mobile, %.0f MB RAM" % phys_mb
			return Preset.HIGH
		if phys_mb >= 3500.0:
			_detect_reason = "mid-range mobile, %.0f MB RAM" % phys_mb
			return Preset.BALANCED
		_detect_reason = "low-memory mobile (%.0f MB)" % phys_mb
		return Preset.BATTERY

	if cores >= 8 and (phys_mb >= 15000.0 or phys_mb < 0.0):
		_detect_reason = "desktop, %d cores" % cores
		return Preset.HIGH
	if cores >= 4:
		_detect_reason = "desktop, %d cores" % cores
		return Preset.BALANCED
	_detect_reason = "low-core desktop"
	return Preset.BATTERY


func detect_reason() -> String:
	return _detect_reason


## Ceiling on retained world data for *this* device, in MB.
##
## A fixed per-preset number is wrong in both directions: it wastes a 24 GB
## phone and it gets a 4 GB one killed. Android never hands a process the whole
## machine, so this takes a conservative slice of physical RAM and the preset's
## own figure is then clamped to it.
func device_cache_budget_mb() -> int:
	var mi: Dictionary = OS.get_memory_info()
	var phys_mb: float = float(mi.get("physical", -1)) / 1048576.0
	if phys_mb <= 0.0:
		return 256                      # platform will not say; stay modest
	var share: float = 0.20 if OS.has_feature("mobile") else 0.28
	return clampi(int(phys_mb * share), 96, GameConfig.MAX_CACHE_MB)


func cache_budget_note() -> String:
	var mi: Dictionary = OS.get_memory_info()
	var phys_mb: float = float(mi.get("physical", -1)) / 1048576.0
	if phys_mb <= 0.0:
		return "physical RAM not reported; cache held at 256 MB"
	return "%.0f MB physical -> %d MB world cache ceiling" % [
		phys_mb, device_cache_budget_mb()]


func preset_name() -> String:
	return PRESET_NAMES[clampi(preset, 0, PRESET_NAMES.size() - 1)]


func apply_preset(p: int, persist: bool = true) -> void:
	preset = clampi(p, 0, PRESETS.size() - 1)
	profile = PRESETS[preset].duplicate(true)
	adaptive_factor = 1.0
	_apply_render_settings()
	if persist:
		GameConfig.settings["quality_preset"] = preset
		GameConfig.save_settings()
	profile_applied.emit(preset, effective())
	EventBus.quality_preset_changed.emit(preset, preset_name())


func cycle_preset(dir: int) -> void:
	apply_preset(wrapi(preset + dir, 0, PRESETS.size()))


## The profile after the adaptive safety net has been folded in. This is what
## StressDirector and the world managers should read.
func effective() -> Dictionary:
	var e: Dictionary = profile.duplicate(true)
	e["render_scale"] = float(profile["render_scale"]) * lerpf(0.6, 1.0, adaptive_factor)
	e["shadow_distance"] = float(profile["shadow_distance"]) * lerpf(0.45, 1.0, adaptive_factor)
	e["view_mult"] = float(profile["view_mult"]) * lerpf(0.6, 1.0, adaptive_factor)
	e["veg_mult"] = float(profile["veg_mult"]) * lerpf(0.5, 1.0, adaptive_factor)
	e["adaptive_factor"] = adaptive_factor
	e["preset"] = preset
	e["preset_name"] = preset_name()
	return e


func current_render_scale() -> float:
	return float(profile.get("render_scale", 1.0)) * lerpf(0.6, 1.0, adaptive_factor)


func _apply_render_settings() -> void:
	if _headless:
		return
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = clampf(current_render_scale(), 0.4, 2.0)
	vp.msaa_3d = clampi(int(profile.get("msaa", 0)), 0, 3) as Viewport.MSAA
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_debanding = preset >= Preset.HIGH
	vp.positional_shadow_atlas_size = int(profile.get("shadow_atlas", 2048))
	vp.positional_shadow_atlas_16_bits = preset <= Preset.BALANCED

	RenderingServer.directional_shadow_atlas_set_size(
		int(profile.get("dir_shadow_size", 2048)), preset <= Preset.BALANCED
	)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		clampi(int(profile.get("soft_shadow_quality", 1)), 0, 4)
		as RenderingServer.ShadowQuality
	)
	RenderingServer.positional_soft_shadow_filter_set_quality(
		clampi(int(profile.get("soft_shadow_quality", 1)), 0, 4)
		as RenderingServer.ShadowQuality
	)


func _process(delta: float) -> void:
	if not adaptive_enabled or _headless:
		return
	if _cooldown > 0.0:
		_cooldown -= delta
		return
	var f: float = PerformanceMonitor.smoothed_fps
	var before: float = adaptive_factor
	if f < critical_fps:
		adaptive_factor = maxf(0.0, adaptive_factor - delta * 0.55)
	elif f < target_fps:
		adaptive_factor = maxf(0.0, adaptive_factor - delta * 0.14)
	elif f > target_fps + 18.0:
		adaptive_factor = minf(1.0, adaptive_factor + delta * 0.06)
	if absf(adaptive_factor - before) > 0.004:
		_apply_render_settings()
		_cooldown = 0.35
		profile_applied.emit(preset, effective())


func set_adaptive(enabled: bool) -> void:
	adaptive_enabled = enabled
	GameConfig.settings["adaptive_quality"] = enabled
	GameConfig.save_settings()
	if not enabled:
		adaptive_factor = 1.0
		_apply_render_settings()


func _on_safety_throttle(_reason: String) -> void:
	if not adaptive_enabled:
		return
	adaptive_factor = maxf(0.0, adaptive_factor - 0.25)
	_apply_render_settings()
