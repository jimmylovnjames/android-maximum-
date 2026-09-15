class_name MeshBuilder
extends RefCounted
## Minimal indexed-triangle accumulator. Used everywhere geometry is generated
## (terrain, buildings, roads, props, creatures) so that all procedural content
## shares one code path and can be produced on a worker thread.
##
## Only PackedArrays are touched, so an instance of this class is safe to build
## off the main thread; the ArrayMesh itself is created on the main thread.
##
## Winding convention: every emitter here supplies vertices counter-clockwise
## as seen from the front face, matching the cross products used to derive
## normals. add_triangle() converts to the clockwise order Godot treats as
## front-facing. Getting this wrong is silent -- meshes render inside out and
## collision surfaces can only be hit from underneath -- so tests/ has a
## geometry orientation check that runs over every generated mesh.

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
	add_quad(Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0),
		Vector3(x0, y1, z0), col, uv_scale)
	# -Y
	add_quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1),
		Vector3(x0, y0, z1), col * 0.72, uv_scale)
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
	add_quad(p[7], p[6], p[5], p[4], col)
	add_quad(p[0], p[1], p[2], p[3], col * 0.72)
	add_quad(p[3], p[2], p[6], p[7], col * 0.92)
	add_quad(p[1], p[0], p[4], p[5], col * 0.88)
	add_quad(p[2], p[1], p[5], p[6], col * 0.96)
	add_quad(p[0], p[3], p[7], p[4], col * 0.84)


## Cylinder / truncated cone along +Y starting at `base`.
func add_cylinder(base: Vector3, height: float, r_bottom: float, r_top: float,
		segments: int, col: Color, cap_top: bool = true, cap_bottom: bool = false,
		bottom_shade: float = 0.85) -> void:
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
			base + Vector3(ca * r_bottom, 0.0, sa * r_bottom), n, Vector2(u, 0.0),
			col * bottom_shade))
		ring_t.push_back(add_vertex(
			base + Vector3(ca * r_top, height, sa * r_top), n, Vector2(u, 1.0), col))
	for i in segments:
		add_triangle(ring_b[i], ring_t[i + 1], ring_b[i + 1])
		add_triangle(ring_b[i], ring_t[i], ring_t[i + 1])
	if cap_top and r_top > 0.001:
		var ct: int = add_vertex(base + Vector3(0.0, height, 0.0), Vector3.UP,
			Vector2(0.5, 0.5), col)
		for i in segments:
			add_triangle(ct, ring_t[i + 1], ring_t[i])
	if cap_bottom and r_bottom > 0.001:
		var cb: int = add_vertex(base, Vector3.DOWN, Vector2(0.5, 0.5), col * 0.7)
		for i in segments:
			add_triangle(cb, ring_b[i], ring_b[i + 1])


## Cylinder along an arbitrary axis. Wheels, pipes and struts need this;
## building them along +Y and hoping was leaving every vehicle on four upright
## drums instead of four wheels.
func add_cylinder_xform(xform: Transform3D, height: float, r_bottom: float,
		r_top: float, segments: int, col: Color, cap_top: bool = true,
		cap_bottom: bool = true) -> void:
	var start: int = verts.size()
	add_cylinder(Vector3.ZERO, height, r_bottom, r_top, segments, col,
		cap_top, cap_bottom)
	var basis: Basis = xform.basis
	var nrm_basis: Basis = basis.inverse().transposed()
	for i in range(start, verts.size()):
		verts[i] = xform * verts[i]
		normals[i] = (nrm_basis * normals[i]).normalized()


## Conifer bough tier: a cone whose rim is pushed in and out per segment and
## whose tips droop. A smooth cone reads as a plastic Christmas tree at any
## distance; the ragged rim is what makes a conifer silhouette. Costs the same
## number of triangles as the cone it replaces, so a forest of these is no more
## expensive to draw -- the variety is in the vertex positions, not in extra
## instances.
func add_bough_tier(base: Vector3, height: float, radius: float, segments: int,
		col: Color, seed_value: int, droop: float = 0.30,
		ragged: float = 0.32) -> void:
	segments = maxi(5, segments)
	var apex: int = add_vertex(base + Vector3(0.0, height, 0.0), Vector3.UP,
		Vector2(0.5, 0.0), col)
	var rim: PackedInt32Array = PackedInt32Array()
	for i in segments + 1:
		var idx: int = i % segments
		var a: float = TAU * float(idx) / float(segments)
		# Deterministic per-segment jitter: same tree mesh every run, but no
		# two segments of the rim at the same radius.
		var h1: float = fmod(sin(float(idx) * 12.9898 + float(seed_value) * 78.233)
			* 43758.5453, 1.0)
		h1 = absf(h1)
		var r: float = radius * (1.0 - ragged * h1)
		var dy: float = -droop * radius * (0.45 + 0.55 * h1)
		var p: Vector3 = base + Vector3(cos(a) * r, dy, sin(a) * r)
		# Underside darkening baked into the vertex stream: the mobile renderer
		# has no ambient occlusion to do it for us.
		var shade: Color = col * (0.55 + 0.25 * h1)
		var n: Vector3 = Vector3(cos(a) * 0.55, 0.8, sin(a) * 0.55).normalized()
		rim.push_back(add_vertex(p, n, Vector2(float(idx) / float(segments), 1.0), shade))
	for i in segments:
		add_triangle(apex, rim[i + 1], rim[i])


## Cone along +Y (used for conifer canopies and spikes).
func add_cone(base: Vector3, height: float, radius: float, segments: int,
		col: Color, cap: bool = true, bottom_shade: float = 0.85) -> void:
	add_cylinder(base, height, radius, 0.001, segments, col, false, cap, bottom_shade)


## Low-poly icosphere-ish blob built from a subdivided octahedron, jittered by
## `noise_amount` for rocks and organic canopies.
## `ao` bakes a vertical ambient-occlusion gradient into the vertex colours:
## the underside of a canopy is darker than the top. Godot's mobile renderer
## has no SSAO, so baking it here is what stops foliage reading as flat blobs.
func add_blob(center: Vector3, radius: Vector3, subdiv: int, col: Color,
		rng: RandomNumberGenerator = null, noise_amount: float = 0.0,
		ao: float = 0.0) -> void:
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
		var shade: float = 1.0 - ao * (0.5 - p.y * 0.5)
		offs.push_back(add_vertex(center + local, p,
			Vector2(0.5 + p.x * 0.5, 0.5 + p.z * 0.5), col * shade))
	for f: Array in faces:
		add_triangle(offs[f[0]], offs[f[2]], offs[f[1]])


## Two crossed vertical quads -- the classic cheap foliage/grass card.
## `normal_override` replaces the card's own facing normal. Billboard impostors
## want an upward normal so they take the same ambient and sun term as the
## canopy they stand in for, instead of lighting like a vertical wall.
func add_cross_card(center: Vector3, width: float, height: float, col_bottom: Color,
		col_top: Color, yaw: float = 0.0,
		normal_override: Vector3 = Vector3.ZERO) -> void:
	for k in 2:
		var a: float = yaw + (0.0 if k == 0 else PI * 0.5)
		var dir: Vector3 = Vector3(cos(a), 0.0, sin(a)) * width * 0.5
		var n: Vector3 = Vector3(-sin(a), 0.0, cos(a))
		if normal_override != Vector3.ZERO:
			n = normal_override.normalized()
		var i0: int = add_vertex(center - dir, n, Vector2(0.0, 1.0), col_bottom)
		var i1: int = add_vertex(center + dir, n, Vector2(1.0, 1.0), col_bottom)
		var i2: int = add_vertex(center + dir + Vector3.UP * height, n, Vector2(1.0, 0.0), col_top)
		var i3: int = add_vertex(center - dir + Vector3.UP * height, n, Vector2(0.0, 0.0), col_top)
		# Single-sided on purpose: the foliage shader renders with cull_disabled,
		# so duplicating the back faces here would double the triangle count for
		# no visual gain.
		add_triangle(i0, i1, i2)
		add_triangle(i0, i2, i3)


## A single tapered grass blade: a narrow strip that narrows to a point and
## leans over, built as real geometry so the material needs no alpha test.
## Four segments is enough for the curve to read without the vertex count
## getting silly -- these are instanced hundreds of thousands of times.
func add_blade(base: Vector3, yaw: float, width: float, height: float,
		lean: float, col_bottom: Color, col_top: Color,
		segments: int = 4) -> void:
	var dir := Vector3(cos(yaw), 0.0, sin(yaw))
	var side := Vector3(-sin(yaw), 0.0, cos(yaw)) * width * 0.5
	var n: Vector3 = dir.cross(Vector3.UP).normalized()
	if n.length_squared() < 0.5:
		n = Vector3.FORWARD
	var prev_l: int = -1
	var prev_r: int = -1
	for si in segments + 1:
		var t: float = float(si) / float(segments)
		# Taper to a point, and bend further over towards the tip.
		var w: float = (1.0 - t * t) 
		var bend: float = lean * t * t
		var p: Vector3 = base + Vector3.UP * (height * t) + dir * bend
		var col: Color = col_bottom.lerp(col_top, t)
		var uv_y: float = 1.0 - t
		if si == segments:
			var tip: int = add_vertex(p, n, Vector2(0.5, uv_y), col)
			if prev_l >= 0:
				add_triangle(prev_l, prev_r, tip)
			return
		var l: int = add_vertex(p - side * w, n, Vector2(0.0, uv_y), col)
		var r: int = add_vertex(p + side * w, n, Vector2(1.0, uv_y), col)
		if prev_l >= 0:
			add_triangle(prev_l, prev_r, r)
			add_triangle(prev_l, r, l)
		prev_l = l
		prev_r = r


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
