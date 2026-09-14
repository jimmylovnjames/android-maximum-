class_name MeshBuilder
extends RefCounted
## Minimal indexed-triangle accumulator. Used everywhere geometry is generated
## (terrain, buildings, roads, props, creatures) so that all procedural content
## shares one code path and can be produced on a worker thread.
##
## Only PackedArrays are touched, so an instance of this class is safe to build
## off the main thread; the ArrayMesh itself is created on the main thread.

var verts := PackedVector3Array()
var normals := PackedVector3Array()
var uvs := PackedVector2Array()
var colors := PackedColorArray()
var indices := PackedInt32Array()

var _use_colors: bool = true


func _init(use_colors: bool = true) -> void:
	_use_colors = use_colors


func clear() -> void:
	verts.clear()
	normals.clear()
	uvs.clear()
	colors.clear()
	indices.clear()


func vertex_count() -> int:
	return verts.size()


func triangle_count() -> int:
	return indices.size() / 3


func is_empty() -> bool:
	return indices.is_empty()


func add_vertex(p: Vector3, n: Vector3, uv: Vector2, c: Color) -> int:
	var i: int = verts.size()
	verts.push_back(p)
	normals.push_back(n)
	uvs.push_back(uv)
	if _use_colors:
		colors.push_back(c)
	return i


## Takes indices in counter-clockwise order as seen from the front face -- the
## same order the cross products in this class use to derive normals -- and
## stores them in the clockwise order Godot treats as front-facing. Doing the
## conversion once, here, is why every emitter below can be written in the
## natural mathematical order.
func add_triangle(a: int, b: int, c: int) -> void:
	indices.push_back(a)
	indices.push_back(c)
	indices.push_back(b)


## Adds a flat quad with an outward normal derived from the winding.
func add_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color,
		uv_scale: float = 1.0) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length_squared() < 1e-9:
		return
	n = n.normalized()
	var i0: int = add_vertex(a, n, Vector2(0.0, 0.0), col)
	var i1: int = add_vertex(b, n, Vector2(uv_scale, 0.0), col)
	var i2: int = add_vertex(c, n, Vector2(uv_scale, uv_scale), col)
	var i3: int = add_vertex(d, n, Vector2(0.0, uv_scale), col)
	add_triangle(i0, i1, i2)
	add_triangle(i0, i2, i3)


## Axis-aligned box from `origin` (min corner) with the given size.
func add_box(origin: Vector3, size: Vector3, col: Color, uv_scale: float = 1.0) -> void:
	var x0: float = origin.x
	var y0: float = origin.y
	var z0: float = origin.z
	var x1: float = origin.x + size.x
	var y1: float = origin.y + size.y
	var z1: float = origin.z + size.z
	# +Y
	add_quad(Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1),
		Vector3(x0, y1, z1), col, uv_scale)
	# -Y
	add_quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0),
		Vector3(x0, y0, z0), col * 0.72, uv_scale)
	# +Z
	add_quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1),
		Vector3(x0, y1, z1), col * 0.92, uv_scale)
	# -Z
	add_quad(Vector3(x1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0),
		Vector3(x1, y1, z0), col * 0.88, uv_scale)
	# +X
	add_quad(Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x1, y1, z0),
		Vector3(x1, y1, z1), col * 0.96, uv_scale)
	# -X
	add_quad(Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1),
		Vector3(x0, y1, z0), col * 0.84, uv_scale)


## Transformed box; `xform` is applied to every corner. Useful for rotated props.
func add_box_xform(xform: Transform3D, size: Vector3, col: Color) -> void:
	var h: Vector3 = size * 0.5
	var corners: Array[Vector3] = [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z),
		Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	var p: Array[Vector3] = []
	for c: Vector3 in corners:
		p.append(xform * c)
	add_quad(p[4], p[5], p[6], p[7], col)
	add_quad(p[3], p[2], p[1], p[0], col * 0.72)
	add_quad(p[3], p[2], p[6], p[7], col * 0.92)
	add_quad(p[1], p[0], p[4], p[5], col * 0.88)
	add_quad(p[2], p[1], p[5], p[6], col * 0.96)
	add_quad(p[0], p[3], p[7], p[4], col * 0.84)


## Cylinder / truncated cone along +Y starting at `base`.
func add_cylinder(base: Vector3, height: float, r_bottom: float, r_top: float,
		segments: int, col: Color, cap_top: bool = true, cap_bottom: bool = false) -> void:
	segments = maxi(3, segments)
	var ring_b: PackedInt32Array = PackedInt32Array()
	var ring_t: PackedInt32Array = PackedInt32Array()
	var slope: float = atan2(r_bottom - r_top, height)
	for i in segments + 1:
		var a: float = TAU * float(i) / float(segments)
		var ca: float = cos(a)
		var sa: float = sin(a)
		var n: Vector3 = Vector3(ca * cos(slope), sin(slope), sa * cos(slope)).normalized()
		var u: float = float(i) / float(segments)
		ring_b.push_back(add_vertex(
			base + Vector3(ca * r_bottom, 0.0, sa * r_bottom), n, Vector2(u, 0.0), col * 0.85))
		ring_t.push_back(add_vertex(
			base + Vector3(ca * r_top, height, sa * r_top), n, Vector2(u, 1.0), col))
	for i in segments:
		add_triangle(ring_b[i], ring_b[i + 1], ring_t[i + 1])
		add_triangle(ring_b[i], ring_t[i + 1], ring_t[i])
	if cap_top and r_top > 0.001:
		var ct: int = add_vertex(base + Vector3(0.0, height, 0.0), Vector3.UP,
			Vector2(0.5, 0.5), col)
		for i in segments:
			add_triangle(ct, ring_t[i], ring_t[i + 1])
	if cap_bottom and r_bottom > 0.001:
		var cb: int = add_vertex(base, Vector3.DOWN, Vector2(0.5, 0.5), col * 0.7)
		for i in segments:
			add_triangle(cb, ring_b[i + 1], ring_b[i])


## Cone along +Y (used for conifer canopies and spikes).
func add_cone(base: Vector3, height: float, radius: float, segments: int,
		col: Color, cap: bool = true) -> void:
	add_cylinder(base, height, radius, 0.001, segments, col, false, cap)


## Low-poly icosphere-ish blob built from a subdivided octahedron, jittered by
## `noise_amount` for rocks and organic canopies.
func add_blob(center: Vector3, radius: Vector3, subdiv: int, col: Color,
		rng: RandomNumberGenerator = null, noise_amount: float = 0.0) -> void:
	var base_v: Array[Vector3] = [
		Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT,
		Vector3.FORWARD, Vector3.BACK,
	]
	var base_f: Array = [
		[0, 3, 5], [0, 5, 2], [0, 2, 4], [0, 4, 3],
		[1, 5, 3], [1, 2, 5], [1, 4, 2], [1, 3, 4],
	]
	var pts: Array[Vector3] = base_v.duplicate()
	var faces: Array = base_f.duplicate(true)
	for _s in clampi(subdiv, 0, 3):
		var nf: Array = []
		var mid: Dictionary = {}
		for f: Array in faces:
			var m: PackedInt32Array = PackedInt32Array()
			for e in 3:
				var i0: int = f[e]
				var i1: int = f[(e + 1) % 3]
				var key: String = "%d_%d" % [mini(i0, i1), maxi(i0, i1)]
				if not mid.has(key):
					mid[key] = pts.size()
					pts.append(((pts[i0] + pts[i1]) * 0.5).normalized())
				m.push_back(int(mid[key]))
			nf.append([f[0], m[0], m[2]])
			nf.append([m[0], f[1], m[1]])
			nf.append([m[2], m[1], f[2]])
			nf.append([m[0], m[1], m[2]])
		faces = nf
	var offs: PackedInt32Array = PackedInt32Array()
	for p: Vector3 in pts:
		var jitter: float = 1.0
		if rng != null and noise_amount > 0.0:
			jitter = 1.0 + rng.randf_range(-noise_amount, noise_amount)
		var local: Vector3 = Vector3(p.x * radius.x, p.y * radius.y, p.z * radius.z) * jitter
		offs.push_back(add_vertex(center + local, p,
			Vector2(0.5 + p.x * 0.5, 0.5 + p.z * 0.5), col))
	for f: Array in faces:
		add_triangle(offs[f[0]], offs[f[1]], offs[f[2]])


## Two crossed vertical quads -- the classic cheap foliage/grass card.
func add_cross_card(center: Vector3, width: float, height: float, col_bottom: Color,
		col_top: Color, yaw: float = 0.0) -> void:
	for k in 2:
		var a: float = yaw + (0.0 if k == 0 else PI * 0.5)
		var dir: Vector3 = Vector3(cos(a), 0.0, sin(a)) * width * 0.5
		var n: Vector3 = Vector3(-sin(a), 0.0, cos(a))
		var i0: int = add_vertex(center - dir, n, Vector2(0.0, 1.0), col_bottom)
		var i1: int = add_vertex(center + dir, n, Vector2(1.0, 1.0), col_bottom)
		var i2: int = add_vertex(center + dir + Vector3.UP * height, n, Vector2(1.0, 0.0), col_top)
		var i3: int = add_vertex(center - dir + Vector3.UP * height, n, Vector2(0.0, 0.0), col_top)
		# Single-sided on purpose: the foliage shader renders with cull_disabled,
		# so duplicating the back faces here would double the triangle count for
		# no visual gain.
		add_triangle(i0, i1, i2)
		add_triangle(i0, i2, i3)


## Commits into `target` (creating a new ArrayMesh when null) as one surface.
func commit(target: ArrayMesh = null, material: Material = null) -> ArrayMesh:
	var mesh: ArrayMesh = target if target != null else ArrayMesh.new()
	if indices.is_empty():
		return mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	if _use_colors and colors.size() == verts.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material != null:
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	return mesh


## Raw surface arrays, for handing thread-built geometry back to the main thread.
func to_arrays() -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	if _use_colors and colors.size() == verts.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## Deindexed triangle soup for ConcavePolygonShape3D collision.
func to_collision_faces() -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(indices.size())
	for i in indices.size():
		out[i] = verts[indices[i]]
	return out


## Rough VRAM cost of this surface in bytes, used by the chunk cache budget.
func estimated_bytes() -> int:
	# position(12) + normal(12) + uv(8) + color(16) per vertex, 4 per index.
	return verts.size() * 48 + indices.size() * 4
