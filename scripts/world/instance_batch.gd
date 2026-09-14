class_name InstanceBatch
extends RefCounted
## Accumulates MultiMesh instance data directly into the flat float buffer
## Godot expects (12 transform floats, 4 colour floats, 4 custom floats per
## instance). Building the buffer instead of calling set_instance_transform()
## keeps chunk realisation off the critical path and is thread-safe.

const FLOATS_PER_INSTANCE: int = 20

var meshes: PackedStringArray = PackedStringArray()   ## LOD chain, nearest first
var category: String = "prop"
var buffer: PackedFloat32Array = PackedFloat32Array()
var count: int = 0
var cast_shadow: bool = true
var material_variant: int = 0


func _init(mesh_lods: PackedStringArray, cat: String = "prop",
		shadows: bool = true, variant: int = 0) -> void:
	meshes = mesh_lods
	category = cat
	cast_shadow = shadows
	material_variant = variant


func reserve(n: int) -> void:
	buffer.resize(n * FLOATS_PER_INSTANCE)
	buffer.resize(0)


func add(xform: Transform3D, color: Color, custom: Color) -> void:
	var b: Basis = xform.basis
	var o: Vector3 = xform.origin
	buffer.push_back(b.x.x); buffer.push_back(b.y.x); buffer.push_back(b.z.x); buffer.push_back(o.x)
	buffer.push_back(b.x.y); buffer.push_back(b.y.y); buffer.push_back(b.z.y); buffer.push_back(o.y)
	buffer.push_back(b.x.z); buffer.push_back(b.y.z); buffer.push_back(b.z.z); buffer.push_back(o.z)
	buffer.push_back(color.r); buffer.push_back(color.g)
	buffer.push_back(color.b); buffer.push_back(color.a)
	buffer.push_back(custom.r); buffer.push_back(custom.g)
	buffer.push_back(custom.b); buffer.push_back(custom.a)
	count += 1


func add_simple(pos: Vector3, yaw: float, scale: Vector3, color: Color, custom: Color) -> void:
	var basis: Basis = Basis(Vector3.UP, yaw).scaled(scale)
	add(Transform3D(basis, pos), color, custom)


func is_empty() -> bool:
	return count == 0


func bytes() -> int:
	return buffer.size() * 4
