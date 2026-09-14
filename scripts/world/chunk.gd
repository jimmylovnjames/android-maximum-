class_name WorldChunk
extends Node3D
## Scene-side realisation of one ChunkData.
##
## Realisation is incremental: the streamer gives each chunk a microsecond
## budget per frame so that pulling in a new ring of terrain never produces a
## single 40 ms hitch. Terrain LOD selection is delegated to the renderer via
## visibility ranges rather than being polled in _process.

## Base draw distances per batch category, before the LOD bias is applied.
const CATEGORY_RANGE: Dictionary = {
	"grass": 58.0,
	"bush": 95.0,
	"tree": 280.0,
	"prop": 190.0,
	"detail": 130.0,
	"building": 1200.0,
}
const TERRAIN_LOD_RANGES: PackedFloat32Array = [96.0, 240.0, 520.0, 1400.0]

var data: ChunkData = null
var coord: Vector2i = Vector2i.ZERO
var realized: bool = false
var has_collision: bool = false

var _terrain_nodes: Array[MeshInstance3D] = []
var _batch_nodes: Dictionary = {}        ## key -> MultiMeshInstance3D
var _batch_counts: Dictionary = {}       ## key -> full instance count
var _body: StaticBody3D = null
var _stage: int = 0
var _batch_keys: PackedStringArray = PackedStringArray()
var _batch_i: int = 0
var _mesh_lib: MeshLib = null
var _mat_lib: MaterialLib = null
var _lod_bias: float = 1.0
var _view_distance: float = 800.0
var _fade: bool = false


func setup(d: ChunkData, mesh_lib: MeshLib, mat_lib: MaterialLib) -> void:
	data = d
	coord = d.coord
	_mesh_lib = mesh_lib
	_mat_lib = mat_lib
	position = d.origin
	_batch_keys = PackedStringArray(d.batches.keys())
	_stage = 0
	_batch_i = 0
	realized = false


## Returns true when the chunk is fully realised. `budget_usec` bounds the work
## done in this call.
func step(budget_usec: int) -> bool:
	if realized:
		return true
	var t0: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < budget_usec:
		match _stage:
			0:
				_build_terrain()
				_stage = 1
			1:
				if _batch_i >= _batch_keys.size():
					_stage = 2
				else:
					_build_batch(_batch_keys[_batch_i])
					_batch_i += 1
			_:
				realized = true
				apply_lod(_lod_bias, _view_distance, _fade)
				return true
	return false


func _build_terrain() -> void:
	for i in data.terrain_lods.size():
		var arrays: Array = data.terrain_lods[i]
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.name = "Terrain%d" % i
		mi.mesh = mesh
		mi.material_override = _mat_lib.terrain
		mi.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if i <= 1
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mi)
		_terrain_nodes.append(mi)


func _build_batch(key: String) -> void:
	var batch: InstanceBatch = data.batches[key]
	if batch == null or batch.count <= 0:
		return
	var mesh: Mesh = _mesh_lib.get_mesh(batch.meshes[0])
	if mesh == null:
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = batch.count
	mm.buffer = batch.buffer

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "B_" + key
	mmi.multimesh = mm
	mmi.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if batch.cast_shadow
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

	# Per-district material variants keep one draw call per batch while still
	# raising texture residency across the world.
	if batch.category == "building":
		mmi.material_override = _mat_lib.building_variant(batch.material_variant)
	elif batch.category == "prop" or batch.category == "detail":
		if not batch.meshes[0].begins_with("rock") and batch.meshes[0] != "boulder":
			mmi.material_override = _mat_lib.prop_variant(batch.material_variant)

	add_child(mmi)
	_batch_nodes[key] = mmi
	_batch_counts[key] = batch.count


## Applies distance thresholds. Cheap: it only writes properties the renderer
## already evaluates during culling.
func apply_lod(lod_bias: float, view_distance: float, fade: bool) -> void:
	_lod_bias = lod_bias
	_view_distance = view_distance
	_fade = fade
	if not realized:
		return

	var fade_mode: int = (GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF if fade
		else GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED)

	for i in _terrain_nodes.size():
		var mi: MeshInstance3D = _terrain_nodes[i]
		var begin: float = 0.0 if i == 0 else TERRAIN_LOD_RANGES[i - 1] * lod_bias
		var end: float = TERRAIN_LOD_RANGES[i] * lod_bias
		if i == _terrain_nodes.size() - 1:
			end = maxf(end, view_distance)
		mi.visibility_range_begin = begin
		mi.visibility_range_end = end
		mi.visibility_range_fade_mode = (
			fade_mode as GeometryInstance3D.VisibilityRangeFadeMode)

	for key: String in _batch_nodes.keys():
		var mmi: MultiMeshInstance3D = _batch_nodes[key]
		var batch: InstanceBatch = data.batches[key]
		var base: float = float(CATEGORY_RANGE.get(batch.category, 180.0))
		var end2: float = base * lod_bias
		if batch.category == "building":
			end2 = maxf(base, view_distance)
		mmi.visibility_range_begin = 0.0
		mmi.visibility_range_end = end2
		mmi.visibility_range_fade_mode = (
			fade_mode as GeometryInstance3D.VisibilityRangeFadeMode)


## Swaps every batch of `category` onto the given LOD mesh index.
func set_category_lod(category: String, lod_index: int) -> void:
	if not realized:
		return
	for key: String in _batch_nodes.keys():
		var batch: InstanceBatch = data.batches[key]
		if batch.category != category:
			continue
		var idx: int = clampi(lod_index, 0, batch.meshes.size() - 1)
		var m: Mesh = _mesh_lib.get_mesh(batch.meshes[idx])
		if m != null:
			(_batch_nodes[key] as MultiMeshInstance3D).multimesh.mesh = m


## Density control. Uses visible_instance_count so the instance buffer is never
## reallocated when the stress level changes.
func set_category_density(category: String, fraction: float) -> void:
	if not realized:
		return
	for key: String in _batch_nodes.keys():
		var batch: InstanceBatch = data.batches[key]
		if batch.category != category:
			continue
		var full: int = int(_batch_counts.get(key, 0))
		var n: int = clampi(int(round(float(full) * clampf(fraction, 0.0, 1.0))), 0, full)
		(_batch_nodes[key] as MultiMeshInstance3D).multimesh.visible_instance_count = n


func visible_instances() -> int:
	var n: int = 0
	for key: String in _batch_nodes.keys():
		var mm: MultiMesh = (_batch_nodes[key] as MultiMeshInstance3D).multimesh
		n += (mm.visible_instance_count if mm.visible_instance_count >= 0
			else mm.instance_count)
	return n


## Building floor modules currently drawn, reported to the HUD so the urban
## geometry load is visible as a number rather than a vibe.
func visible_building_modules() -> int:
	var n: int = 0
	for key: String in _batch_nodes.keys():
		if (data.batches[key] as InstanceBatch).category != "building":
			continue
		var mm: MultiMesh = (_batch_nodes[key] as MultiMeshInstance3D).multimesh
		n += (mm.visible_instance_count if mm.visible_instance_count >= 0
			else mm.instance_count)
	return n


func enable_collision(on: bool) -> void:
	if on == has_collision:
		return
	if on:
		if data.collision_faces.is_empty():
			return
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(data.collision_faces)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		_body = StaticBody3D.new()
		_body.name = "TerrainBody"
		_body.collision_layer = GameConfig.L_WORLD
		_body.collision_mask = 0
		_body.add_child(cs)
		add_child(_body)
		has_collision = true
	else:
		if _body != null and is_instance_valid(_body):
			_body.queue_free()
		_body = null
		has_collision = false


func release() -> void:
	realized = false
	_terrain_nodes.clear()
	_batch_nodes.clear()
	_batch_counts.clear()
	_body = null
	data = null
	for c in get_children():
		c.queue_free()
