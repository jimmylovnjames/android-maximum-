class_name LODManager
extends Node
## Distance-based detail control for streamed chunks.
##
## Rather than polling every instance, this walks a handful of chunks per frame
## and updates whole-batch LOD indices. Per-instance culling and the LOD
## crossover distances themselves are left to the renderer's visibility ranges,
## which cost nothing in script.

const CHUNKS_PER_FRAME: int = 4

var streamer: ChunkStreamer = null
var focus: Node3D = null

var lod_bias: float = 1.0
var view_distance: float = 800.0
var tree_lod1_distance: float = 95.0
var tree_lod2_distance: float = 210.0
## Beyond this the tree becomes a crossed billboard. Set well inside the tree
## draw distance so the swap happens where the silhouette is all that reads.
var tree_lod3_distance: float = 400.0
var rock_lod1_distance: float = 70.0
var grass_lod1_distance: float = 26.0

var _cursor: int = 0
var _keys: Array = []
var _dirty: bool = true
var _chunk_lod_state: Dictionary = {}      ## Vector2i -> PackedInt32Array


func setup(s: ChunkStreamer, f: Node3D) -> void:
	streamer = s
	focus = f
	if streamer != null:
		streamer.chunk_ready.connect(_on_chunk_ready)
	EventBus.chunk_unloaded.connect(_on_chunk_unloaded)


func apply_profile(profile: Dictionary) -> void:
	lod_bias = float(profile.get("lod_bias", 1.0))
	view_distance = float(profile.get("view_distance", 800.0))
	_dirty = true


func _on_chunk_ready(coord: Vector2i) -> void:
	_chunk_lod_state.erase(coord)
	_dirty = true


func _on_chunk_unloaded(coord: Vector2i) -> void:
	_chunk_lod_state.erase(coord)


func _process(_delta: float) -> void:
	if streamer == null or focus == null or not is_instance_valid(focus):
		return
	if _dirty or _keys.size() != streamer.active.size():
		_keys = streamer.active.keys()
		_cursor = 0
		_dirty = false
	if _keys.is_empty():
		return

	var fp: Vector3 = focus.global_position
	var n: int = mini(CHUNKS_PER_FRAME, _keys.size())
	for i in n:
		if _cursor >= _keys.size():
			_cursor = 0
		var coord: Vector2i = _keys[_cursor]
		_cursor += 1
		var chunk: WorldChunk = streamer.active.get(coord, null)
		if chunk == null or not chunk.realized:
			continue
		_update_chunk(chunk, fp)


func _update_chunk(chunk: WorldChunk, fp: Vector3) -> void:
	var center: Vector3 = chunk.global_position + Vector3(
		GameConfig.CHUNK_SIZE * 0.5, 0.0, GameConfig.CHUNK_SIZE * 0.5)
	var d: float = Vector2(center.x - fp.x, center.z - fp.z).length()

	var tree_lod: int = 0
	if d > tree_lod3_distance * lod_bias:
		tree_lod = 3
	elif d > tree_lod2_distance * lod_bias:
		tree_lod = 2
	elif d > tree_lod1_distance * lod_bias:
		tree_lod = 1

	var rock_lod: int = 1 if d > rock_lod1_distance * lod_bias else 0
	var grass_lod: int = 1 if d > grass_lod1_distance * lod_bias else 0

	var prev: PackedInt32Array = _chunk_lod_state.get(chunk.coord,
		PackedInt32Array([-1, -1, -1]))
	if prev[0] != tree_lod:
		chunk.set_category_lod("tree", tree_lod)
	if prev[1] != rock_lod:
		chunk.set_category_lod("prop", rock_lod)
	if prev[2] != grass_lod:
		chunk.set_category_lod("grass", grass_lod)
	_chunk_lod_state[chunk.coord] = PackedInt32Array([tree_lod, rock_lod, grass_lod])
