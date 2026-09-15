class_name ChunkData
extends RefCounted
## The complete, engine-object-free description of one world chunk. Produced on
## a worker thread, consumed on the main thread by WorldChunk. Holding only
## PackedArrays means an unloaded chunk can sit in the streamer's cache at a
## known, measurable byte cost.

var coord: Vector2i = Vector2i.ZERO
var zone: int = 0
var origin: Vector3 = Vector3.ZERO
var center: Vector3 = Vector3.ZERO
var height_min: float = 0.0
var height_max: float = 0.0
var has_water: bool = false

## The generator's height grid, kept rather than discarded. Anything that needs
## to know where the ground is -- agents, traffic, spawn placement -- can then
## do four array reads instead of re-evaluating the analytic world function,
## which costs about ten FastNoiseLite samples plus a domain warp every call.
## At 33x33 floats this is ~4.4 KB per chunk, and it is legitimate cached world
## data, so it also counts honestly towards the memory budget.
var heights: PackedFloat32Array = PackedFloat32Array()
var height_side: int = 0
var height_cell: float = 1.0

## Surface arrays for each terrain LOD, nearest first.
var terrain_lods: Array = []
var collision_faces: PackedVector3Array = PackedVector3Array()

## category/key -> InstanceBatch
var batches: Dictionary = {}

## Gameplay seeding points, consumed by NPCManager / TrafficManager / pickups.
var npc_spawns: PackedVector3Array = PackedVector3Array()
var enemy_spawns: PackedVector3Array = PackedVector3Array()
var vehicle_spawns: PackedVector3Array = PackedVector3Array()
var light_spots: PackedVector3Array = PackedVector3Array()
var pickups: Array = []            ## [{pos: Vector3, id: String, amount: int}]
var destructible_spots: PackedVector3Array = PackedVector3Array()

var gen_msec: float = 0.0
var veg_step: float = 1.6
var _bytes: int = -1


func estimated_bytes() -> int:
	if _bytes >= 0:
		return _bytes
	var b: int = 0
	for lod: Array in terrain_lods:
		if lod.is_empty():
			continue
		var v: PackedVector3Array = lod[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = lod[Mesh.ARRAY_INDEX]
		b += v.size() * 48 + idx.size() * 4
	b += collision_faces.size() * 12
	b += heights.size() * 4
	for k: String in batches.keys():
		b += (batches[k] as InstanceBatch).bytes()
	b += (npc_spawns.size() + enemy_spawns.size() + vehicle_spawns.size()
		+ light_spots.size() + destructible_spots.size()) * 12
	_bytes = b
	return b


func instance_total() -> int:
	var n: int = 0
	for k: String in batches.keys():
		n += (batches[k] as InstanceBatch).count
	return n
