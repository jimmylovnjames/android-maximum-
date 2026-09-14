class_name SelfTest
extends RefCounted
## Static checks that run headless, with no display and no gameplay.
##
## The orientation check exists because inverted triangle winding is silent:
## a mesh renders inside out (dark, hollow, flat-looking) and a collision
## surface can only be hit from underneath. Both cost real debugging time, so
## they are asserted here against geometry the engine itself authored.


## Signed volume of a closed triangle soup. The sign encodes which way the
## triangles face; the magnitude is only used to skip open/flat meshes.
static func signed_volume(arrays: Array) -> float:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if verts.is_empty():
		return 0.0
	var centre := Vector3.ZERO
	for v: Vector3 in verts:
		centre += v
	centre /= float(verts.size())
	var total: float = 0.0
	if idx.is_empty():
		for t in verts.size() / 3:
			total += _tet(verts[t * 3] - centre, verts[t * 3 + 1] - centre,
				verts[t * 3 + 2] - centre)
	else:
		for t in idx.size() / 3:
			total += _tet(verts[idx[t * 3]] - centre, verts[idx[t * 3 + 1]] - centre,
				verts[idx[t * 3 + 2]] - centre)
	return total / 6.0


static func _tet(a: Vector3, b: Vector3, c: Vector3) -> float:
	return a.dot(b.cross(c))


## Reference sign taken from meshes Godot generates itself, so the test cannot
## drift with the engine's winding convention.
static func reference_sign() -> float:
	var box := BoxMesh.new()
	var sphere := SphereMesh.new()
	var vb: float = signed_volume(box.surface_get_arrays(0))
	var vs: float = signed_volume(sphere.surface_get_arrays(0))
	if signf(vb) != signf(vs):
		push_warning("SelfTest: engine primitives disagree on winding")
	return signf(vb)


## Every mesh in the procedural library must face the same way as the engine's
## own primitives. Flat meshes (grass cards, road markings) enclose no volume
## and are skipped.
static func check_mesh_orientation() -> Array:
	var failures: Array = []
	var want: float = reference_sign()
	var lib: MeshLib = MeshLib.get_instance()
	for key: String in lib.meshes.keys():
		if lib.open_meshes.has(key):
			continue
		var mesh: Mesh = lib.meshes[key]
		if mesh == null or not (mesh is ArrayMesh):
			continue
		for s in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(s)
			var v: float = signed_volume(arrays)
			var extent: float = mesh.get_aabb().size.length()
			var threshold: float = maxf(0.002, pow(extent, 3.0) * 0.004)
			if absf(v) < threshold:
				continue        # open or flat surface, orientation undefined
			if signf(v) != want:
				failures.append({
					"mesh": key, "surface": s, "signed_volume": v,
					"expected_sign": want,
				})
	return failures


## Collision geometry must be hittable from above. Builds one chunk's faces and
## raycasts them in an isolated physics space.
static func check_collision_orientation(gen: WorldGen) -> Array:
	var failures: Array = []
	var d: ChunkData = ChunkGenerator.generate(gen, Vector2i(0, 0), {
		"veg_step": 3.0, "collision": true, "lod_count": 1, "prop_richness": 0.0,
	})
	if d.collision_faces.is_empty():
		failures.append({"error": "chunk produced no collision faces"})
		return failures
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(d.collision_faces)
	# A one-sided trimesh reports a hit from the front face only, so comparing
	# a downward and an upward ray tells us which way the surface points.
	var mid: float = (d.height_min + d.height_max) * 0.5
	var probe := Vector3(GameConfig.CHUNK_SIZE * 0.5, 0.0, GameConfig.CHUNK_SIZE * 0.5)
	var hits_down: int = 0
	var hits_up: int = 0
	for i in 9:
		var x: float = probe.x + float(i % 3 - 1) * 12.0
		var z: float = probe.z + float(i / 3 - 1) * 12.0
		if _segment_hits(shape, Vector3(x, mid + 200.0, z), Vector3(x, mid - 200.0, z)):
			hits_down += 1
		if _segment_hits(shape, Vector3(x, mid - 200.0, z), Vector3(x, mid + 200.0, z)):
			hits_up += 1
	if hits_down == 0:
		failures.append({"error": "collision surface not hit from above",
			"down": hits_down, "up": hits_up})
	elif hits_up > hits_down:
		failures.append({"error": "collision surface faces downward",
			"down": hits_down, "up": hits_up})
	return failures


static func _segment_hits(shape: Shape3D, from: Vector3, to: Vector3) -> bool:
	# Shape3D has no raycast entry point, so intersect the face list directly.
	var faces: PackedVector3Array = (shape as ConcavePolygonShape3D).get_faces()
	var dir: Vector3 = to - from
	for t in faces.size() / 3:
		var hit: Variant = Geometry3D.ray_intersects_triangle(
			from, dir.normalized(), faces[t * 3], faces[t * 3 + 1], faces[t * 3 + 2])
		if hit != null and from.distance_to(hit) <= dir.length():
			return true
	return false


## Loads every script in the project and reports the ones that fail to compile.
##
## The whole-project import collapses a syntax error anywhere into a single
## "could not parse global class" line, which says nothing about where the
## problem is. Doing it from inside a running instance means the autoloads
## exist, so there are none of the false "identifier not found" failures that
## `--check-only --script` produces -- and it is one process instead of one per
## file.
static func check_scripts(root: String = "res://scripts") -> Array:
	var failures: Array = []
	for path: String in _gd_files(root):
		# Plain load(), not CACHE_MODE_IGNORE: forcing a reload of a script
		# that is currently executing (this one included) recompiles it out
		# from under the running instance and segfaults the engine.
		var res: Resource = load(path)
		if res == null:
			failures.append({"script": path, "error": "failed to load"})
			continue
		if not (res is GDScript):
			failures.append({"script": path, "error": "not a GDScript"})
	return failures


static func _gd_files(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var name: String = d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full: String = dir_path.path_join(name)
		if d.current_is_dir():
			out.append_array(_gd_files(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()
	return out


## Determinism: the same seed and coordinate must produce identical chunks.
static func check_determinism(seed_value: int) -> Array:
	var failures: Array = []
	var a := WorldGen.new(seed_value)
	var b := WorldGen.new(seed_value)
	for i in 64:
		var x: float = float(i) * 37.3 - 900.0
		var z: float = float(i) * -19.7 + 450.0
		if not is_equal_approx(a.height(x, z), b.height(x, z)):
			failures.append({"error": "height not deterministic", "x": x, "z": z})
			break
	var opts: Dictionary = {"veg_step": 2.0, "collision": false, "lod_count": 2,
		"prop_richness": 1.0}
	var c1: ChunkData = ChunkGenerator.generate(a, Vector2i(3, -2), opts)
	var c2: ChunkData = ChunkGenerator.generate(b, Vector2i(3, -2), opts)
	if c1.instance_total() != c2.instance_total():
		failures.append({"error": "instance count not deterministic",
			"a": c1.instance_total(), "b": c2.instance_total()})
	if c1.npc_spawns.size() != c2.npc_spawns.size():
		failures.append({"error": "spawn count not deterministic"})
	if absf(c1.height_max - c2.height_max) > 0.0001:
		failures.append({"error": "terrain extent not deterministic"})
	return failures


## Hard caps must hold no matter what the stress table asks for.
static func check_safety_caps() -> Array:
	var failures: Array = []
	var e: Dictionary = StressDirector.effective
	var caps: Dictionary = {
		"npc_count": GameConfig.MAX_NPCS,
		"npc_full": GameConfig.MAX_FULL_NPCS,
		"npc_reduced": GameConfig.MAX_REDUCED_NPCS,
		"vehicle_count": GameConfig.MAX_VEHICLES,
		"rigid_bodies": GameConfig.MAX_RIGID_BODIES,
		"debris_budget": GameConfig.MAX_DEBRIS,
		"omni_lights": GameConfig.MAX_OMNI_LIGHTS,
		"cache_mb": GameConfig.MAX_CACHE_MB,
		"stream_radius": GameConfig.MAX_STREAM_RADIUS,
	}
	for key: String in caps.keys():
		if int(e.get(key, 0)) > int(caps[key]):
			failures.append({"error": "cap exceeded", "key": key,
				"value": e[key], "cap": caps[key]})
	return failures


static func run_all(seed_value: int) -> Dictionary:
	var results: Dictionary = {}
	results["scripts"] = check_scripts()
	results["script_count"] = _gd_files("res://scripts").size()
	results["mesh_orientation"] = check_mesh_orientation()
	results["collision_orientation"] = check_collision_orientation(WorldGen.new(seed_value))
	results["determinism"] = check_determinism(seed_value)
	var worst: int = StressDirector.LEVEL_NAMES.size() - 1
	StressDirector.set_level(worst, false)
	results["safety_caps"] = check_safety_caps()
	var total: int = 0
	for k: String in results.keys():
		if results[k] is Array:
			total += (results[k] as Array).size()
	results["failures"] = total
	results["ok"] = total == 0
	return results
