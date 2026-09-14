class_name VegetationManager
extends Node
## Owns how much of each chunk's generated vegetation is actually drawn.
##
## Chunks always generate their maximum instance set. This manager lowers
## MultiMesh.visible_instance_count instead of regenerating, so changing the
## stress level is instant and allocation-free.

const CHUNKS_PER_FRAME: int = 6

var streamer: ChunkStreamer = null

var grass_fraction: float = 0.4
var tree_fraction: float = 0.5
var bush_fraction: float = 0.45
var prop_fraction: float = 0.7
var detail_fraction: float = 0.7

var _pending: Array[Vector2i] = []
var _applied: Dictionary = {}
var _version: int = 0


func setup(s: ChunkStreamer) -> void:
	streamer = s
	if streamer != null:
		streamer.chunk_ready.connect(_on_chunk_ready)
	EventBus.chunk_unloaded.connect(_on_chunk_unloaded)


func apply_profile(profile: Dictionary) -> void:
	# The divisors are the MELTDOWN table values, so the top stress level with
	# the INSANE preset saturates at 100% of generated instances.
	grass_fraction = clampf(float(profile.get("grass_multiplier", 1.0)) / 3.6, 0.02, 1.0)
	tree_fraction = clampf(float(profile.get("veg_density", 1.0)) / 2.6, 0.05, 1.0)
	bush_fraction = clampf(tree_fraction * 0.85, 0.02, 1.0)
	prop_fraction = clampf(float(profile.get("building_detail", 1.0)) / 1.7, 0.15, 1.0)
	detail_fraction = clampf(prop_fraction * 0.9, 0.1, 1.0)
	_version += 1
	_pending = []
	if streamer != null:
		for c: Vector2i in streamer.active.keys():
			_pending.append(c)


func _on_chunk_ready(coord: Vector2i) -> void:
	if not _pending.has(coord):
		_pending.append(coord)


func _on_chunk_unloaded(coord: Vector2i) -> void:
	_pending.erase(coord)
	_applied.erase(coord)


func _process(_delta: float) -> void:
	if streamer == null or _pending.is_empty():
		return
	var n: int = mini(CHUNKS_PER_FRAME, _pending.size())
	for i in n:
		var coord: Vector2i = _pending.pop_front()
		var chunk: WorldChunk = streamer.active.get(coord, null)
		if chunk == null or not chunk.realized:
			continue
		chunk.set_category_density("grass", grass_fraction)
		chunk.set_category_density("tree", tree_fraction)
		chunk.set_category_density("bush", bush_fraction)
		chunk.set_category_density("prop", prop_fraction)
		chunk.set_category_density("detail", detail_fraction)
		_applied[coord] = _version
