class_name MaterialLib
extends RefCounted
## Central material registry. Created once, rebuilt when the quality preset
## changes (texture sizes and variant counts are preset-dependent).

static var _instance: MaterialLib = null

const SH_TERRAIN := "res://shaders/terrain.gdshader"
const SH_VEGETATION := "res://shaders/vegetation.gdshader"
const SH_BUILDING := "res://shaders/building.gdshader"
const SH_WATER := "res://shaders/water.gdshader"
const SH_SKY := "res://shaders/sky.gdshader"
const SH_PROP := "res://shaders/prop_instanced.gdshader"

var terrain: ShaderMaterial
var grass: ShaderMaterial
var foliage: ShaderMaterial
var canopy: ShaderMaterial
var building: ShaderMaterial
var water: ShaderMaterial
var prop: ShaderMaterial
var sky_material: ShaderMaterial

var bark: StandardMaterial3D
var road: StandardMaterial3D
var metal: StandardMaterial3D
var flesh: StandardMaterial3D
var hostile: StandardMaterial3D
var glass_emissive: StandardMaterial3D
var debris: StandardMaterial3D
var pickup: StandardMaterial3D
var vehicle_body: StandardMaterial3D
var vehicle_glass: StandardMaterial3D
var tracer: StandardMaterial3D

## Extra generated textures kept alive purely to raise texture residency at
## high presets. They are real, sampled variants handed to prop batches.
var wall_variants: Array[Texture2D] = []
var surface_variants: Array[Texture2D] = []

## Per-district material instances. Created once and updated in place so that
## chunks realised before a quality change keep working -- replacing the
## objects would leave live MeshInstances pointing at stale materials.
var building_mats: Array[ShaderMaterial] = []
var prop_mats: Array[ShaderMaterial] = []

var _preset: int = -1
var _tex_bytes: int = 0


static func get_instance() -> MaterialLib:
	if _instance == null:
		_instance = MaterialLib.new()
		_instance.rebuild(AdaptiveQualityManagerPresetSafe())
	return _instance


## Reads the current preset without hard-depending on the autoload existing
## (keeps this class usable from unit tests).
static func AdaptiveQualityManagerPresetSafe() -> int:
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		var root: Window = (loop as SceneTree).root
		if root.has_node("AdaptiveQualityManager"):
			return int(root.get_node("AdaptiveQualityManager").get("preset"))
	return 2


static func refresh_for_preset(preset: int) -> void:
	if _instance == null:
		_instance = MaterialLib.new()
	_instance.rebuild(preset)


func estimated_texture_mb() -> float:
	return float(_tex_bytes) / 1048576.0


func rebuild(preset: int) -> void:
	if preset == _preset and terrain != null:
		return

	_preset = preset
	_tex_bytes = 0
	var size: int = TextureLib.size_for_preset(preset)
	var variants: int = TextureLib.variants_for_preset(preset)
	var seed_base: int = GameConfig.world_seed

	var detail: NoiseTexture2D = TextureLib.noise_texture(
		seed_base + 11, size, 0.012, true, false, 4)
	var macro: NoiseTexture2D = TextureLib.noise_texture(
		seed_base + 12, size, 0.004, true, false, 5)
	var wave_n: NoiseTexture2D = TextureLib.noise_texture(
		seed_base + 13, maxi(256, size / 2), 0.02, true, true, 3)
	var ground_n: NoiseTexture2D = TextureLib.noise_texture(
		seed_base + 14, size, 0.045, true, true, 5)
	_count_tex(detail, size)
	_count_tex(macro, size)
	_count_tex(wave_n, maxi(256, size / 2))
	_count_tex(ground_n, size)

	wall_variants.clear()
	surface_variants.clear()
	for i in variants:
		var w: NoiseTexture2D = TextureLib.ramped_noise_texture(
			seed_base + 200 + i, size, 0.02 + 0.006 * float(i),
			Color(0.32, 0.32, 0.34), Color(0.78, 0.77, 0.74), 4)
		var s: NoiseTexture2D = TextureLib.ramped_noise_texture(
			seed_base + 400 + i, size, 0.035 + 0.01 * float(i),
			Color(0.20, 0.19, 0.18), Color(0.72, 0.63, 0.52), 3)
		wall_variants.append(w)
		surface_variants.append(s)
		_count_tex(w, size)
		_count_tex(s, size)

	var grass_mask: ImageTexture = TextureLib.grass_blade_mask(64, 128, seed_base + 7)
	var leaf_mask: ImageTexture = TextureLib.leaf_cluster_mask(128, seed_base + 8)
	_tex_bytes += 64 * 128 * 4 + 128 * 128 * 4

	# --- Terrain -------------------------------------------------------------
	terrain = _shader_mat(SH_TERRAIN, terrain)
	terrain.set_shader_parameter("detail_tex", detail)
	terrain.set_shader_parameter("macro_tex", macro)
	terrain.set_shader_parameter("detail_normal", ground_n)
	terrain.set_shader_parameter("water_level", GameConfig.WATER_LEVEL)
	terrain.set_shader_parameter("normal_strength", 0.5)

	# --- Vegetation ----------------------------------------------------------
	grass = _shader_mat(SH_VEGETATION, grass)
	grass.set_shader_parameter("leaf_mask", grass_mask)
	grass.set_shader_parameter("wind_strength", 0.55)
	grass.set_shader_parameter("wind_speed", 2.1)
	grass.set_shader_parameter("stiffness", 0.15)
	grass.set_shader_parameter("alpha_cut", 0.22)
	grass.set_shader_parameter("translucency", 0.55)
	grass.set_shader_parameter("use_mask", true)

	foliage = _shader_mat(SH_VEGETATION, foliage)
	foliage.set_shader_parameter("leaf_mask", leaf_mask)
	foliage.set_shader_parameter("wind_strength", 0.3)
	foliage.set_shader_parameter("wind_speed", 1.1)
	foliage.set_shader_parameter("stiffness", 0.6)
	foliage.set_shader_parameter("alpha_cut", 0.3)
	foliage.set_shader_parameter("translucency", 0.3)
	foliage.set_shader_parameter("use_mask", true)

	canopy = _shader_mat(SH_VEGETATION, canopy)
	canopy.set_shader_parameter("leaf_mask", leaf_mask)
	canopy.set_shader_parameter("wind_strength", 0.22)
	canopy.set_shader_parameter("wind_speed", 0.9)
	canopy.set_shader_parameter("stiffness", 0.75)
	canopy.set_shader_parameter("translucency", 0.28)
	canopy.set_shader_parameter("use_mask", false)

	# --- Buildings / props ---------------------------------------------------
	building = _shader_mat(SH_BUILDING, building)
	building.set_shader_parameter("wall_tex", wall_variants[0])

	prop = _shader_mat(SH_PROP, prop)
	prop.set_shader_parameter("surface_tex", surface_variants[0])

	# --- Water ---------------------------------------------------------------
	water = _shader_mat(SH_WATER, water)
	water.set_shader_parameter("wave_normal", wave_n)

	# --- Sky -----------------------------------------------------------------
	sky_material = _shader_mat(SH_SKY, sky_material)

	# --- Per-district variants ------------------------------------------------
	_sync_variant_mats()

	# --- Standard materials --------------------------------------------------
	# These meshes carry their colour in the vertex stream, so the material
	# albedo stays white -- tinting here as well multiplies the two together
	# and turns every prop and tree trunk near-black.
	bark = _std(Color(1.0, 1.0, 1.0), 0.92, 0.0, bark)
	road = _std(Color(0.9, 0.9, 0.92), 0.86, 0.0, road)
	metal = _std(Color(1.0, 1.0, 1.0), 0.42, 0.75, metal)
	flesh = _std(Color(1.0, 1.0, 1.0), 0.78, 0.0, flesh)
	hostile = _std(Color(1.0, 1.0, 1.0), 0.6, 0.0, hostile)
	hostile.emission_enabled = true
	hostile.emission = Color(1.0, 0.18, 0.12)
	hostile.emission_energy_multiplier = 1.4
	glass_emissive = _std(Color(0.05, 0.06, 0.08), 0.1, 0.4, glass_emissive)
	glass_emissive.emission_enabled = true
	glass_emissive.emission = Color(1.0, 0.78, 0.45)
	glass_emissive.emission_energy_multiplier = 2.5
	debris = _std(Color(1.0, 1.0, 1.0), 0.9, 0.0, debris)
	pickup = _std(Color(1.0, 1.0, 1.0), 0.35, 0.2, pickup)
	pickup.emission_enabled = true
	pickup.emission = Color(0.35, 1.0, 0.6)
	pickup.emission_energy_multiplier = 1.8
	vehicle_body = _std(Color(1.0, 1.0, 1.0), 0.32, 0.5, vehicle_body)
	vehicle_glass = _std(Color(0.08, 0.1, 0.13), 0.08, 0.3, vehicle_glass)
	tracer = _std(Color(1.0, 1.0, 1.0), 0.4, 0.0, tracer)
	tracer.emission_enabled = true
	tracer.emission = Color(1.0, 0.75, 0.3)
	tracer.emission_energy_multiplier = 6.0
	tracer.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func wall_texture(i: int) -> Texture2D:
	if wall_variants.is_empty():
		return null
	return wall_variants[abs(i) % wall_variants.size()]


func surface_texture(i: int) -> Texture2D:
	if surface_variants.is_empty():
		return null
	return surface_variants[abs(i) % surface_variants.size()]


## Building/prop batches share a small ring of material instances, one per
## generated wall texture: more texture residency, still one draw call per
## batch, and updating a preset mutates these in place so chunks that are
## already in the scene follow along.
func building_variant(i: int) -> ShaderMaterial:
	if building_mats.is_empty():
		return building
	return building_mats[absi(i) % building_mats.size()]


func prop_variant(i: int) -> ShaderMaterial:
	if prop_mats.is_empty():
		return prop
	return prop_mats[absi(i) % prop_mats.size()]


func _sync_variant_mats() -> void:
	var n: int = maxi(1, wall_variants.size())
	while building_mats.size() < n:
		building_mats.append(_shader_mat(SH_BUILDING, null))
	while prop_mats.size() < n:
		prop_mats.append(_shader_mat(SH_PROP, null))
	for i in building_mats.size():
		building_mats[i].set_shader_parameter("wall_tex", wall_texture(i))
	for i in prop_mats.size():
		prop_mats[i].set_shader_parameter("surface_tex", surface_texture(i))


## Reuses the existing material object when there is one. Materials are handed
## out by reference all over the world; swapping the object on a quality change
## would strand every chunk already in the scene.
func _shader_mat(path: String, existing: ShaderMaterial) -> ShaderMaterial:
	var m: ShaderMaterial = existing if existing != null else ShaderMaterial.new()
	if m.shader == null:
		var sh: Shader = load(path) as Shader
		if sh == null:
			push_error("REDLINE: missing shader %s" % path)
		m.shader = sh
	return m


func _std(albedo: Color, rough: float, metal_v: float,
		existing: StandardMaterial3D = null) -> StandardMaterial3D:
	var m: StandardMaterial3D = existing if existing != null else StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = metal_v
	m.vertex_color_use_as_albedo = true
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	return m


func _count_tex(_t: Texture2D, size: int) -> void:
	# RGBA8 + mipmaps (~1.33x).
	_tex_bytes += int(float(size * size * 4) * 1.34)
