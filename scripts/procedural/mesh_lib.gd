class_name MeshLib
extends RefCounted
## Every mesh in REDLINE is generated here at startup. Meshes are shared by
## reference across all MultiMesh batches and pooled nodes, so the world can
## contain a hundred thousand instances of a few dozen unique meshes.
##
## Replacing procedural placeholders later means swapping the bodies of these
## builders for loaded resources -- nothing else in the codebase needs to change.

static var _instance: MeshLib = null

var meshes: Dictionary = {}
var _mat: MaterialLib


static func get_instance() -> MeshLib:
	if _instance == null:
		_instance = MeshLib.new()
		_instance.build(MaterialLib.get_instance())
	return _instance


static func reset() -> void:
	_instance = null


func get_mesh(key: String) -> Mesh:
	return meshes.get(key, null) as Mesh


func has_mesh(key: String) -> bool:
	return meshes.has(key)


func build(mat: MaterialLib) -> void:
	_mat = mat
	meshes.clear()
	_build_trees()
	_build_ground_cover()
	_build_rocks()
	_build_urban()
	_build_props()
	_build_vehicles()
	_build_characters()
	_build_effects()


# -----------------------------------------------------------------------------
# Vegetation
# -----------------------------------------------------------------------------
func _build_trees() -> void:
	# Conifer: tapered trunk plus three stacked canopy cones.
	for lod in 3:
		var seg: int = [7, 5, 4][lod]
		var trunk := MeshBuilder.new()
		trunk.add_cylinder(Vector3.ZERO, 6.4, 0.42, 0.18, seg, Color(0.30, 0.22, 0.15), true)
		var mesh: ArrayMesh = trunk.commit(null, _mat.bark)
		var can := MeshBuilder.new()
		var tiers: int = [3, 2, 1][lod]
		for i in tiers:
			var y: float = 2.4 + float(i) * 1.9
			var r: float = 2.6 - float(i) * 0.55
			var hgt: float = 3.4 - float(i) * 0.5
			can.add_cone(Vector3(0.0, y, 0.0), hgt, r, seg + 1,
				Color(0.11, 0.26 + 0.04 * float(i), 0.12), true)
		can.commit(mesh, _mat.foliage)
		meshes["pine_l%d" % lod] = mesh

	# Broadleaf: short trunk, blob canopy.
	for lod in 3:
		var seg2: int = [7, 5, 4][lod]
		var sub: int = [2, 1, 0][lod]
		var t2 := MeshBuilder.new()
		t2.add_cylinder(Vector3.ZERO, 3.1, 0.38, 0.26, seg2, Color(0.33, 0.25, 0.18), true)
		if lod == 0:
			for b in 3:
				var a: float = TAU * float(b) / 3.0
				var xf := Transform3D(
					Basis(Vector3(0, 1, 0), a) * Basis(Vector3(0, 0, 1), 0.6),
					Vector3(cos(a) * 0.5, 2.7, sin(a) * 0.5)
				)
				t2.add_box_xform(xf, Vector3(0.18, 1.7, 0.18), Color(0.32, 0.24, 0.17))
		var m2: ArrayMesh = t2.commit(null, _mat.bark)
		var c2 := MeshBuilder.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 1000 + lod
		c2.add_blob(Vector3(0.0, 4.5, 0.0), Vector3(2.7, 2.1, 2.7), sub,
			Color(0.17, 0.34, 0.14), rng, 0.22)
		if lod == 0:
			c2.add_blob(Vector3(1.5, 3.6, -0.8), Vector3(1.5, 1.2, 1.5), 1,
				Color(0.14, 0.30, 0.12), rng, 0.26)
			c2.add_blob(Vector3(-1.3, 3.9, 1.1), Vector3(1.4, 1.1, 1.4), 1,
				Color(0.19, 0.37, 0.16), rng, 0.26)
		c2.commit(m2, _mat.foliage)
		meshes["broad_l%d" % lod] = m2

	# Dead / burnt tree for REDLINE zones.
	var dead := MeshBuilder.new()
	dead.add_cylinder(Vector3.ZERO, 5.2, 0.36, 0.1, 5, Color(0.14, 0.12, 0.11), true)
	for b in 4:
		var a: float = TAU * float(b) / 4.0 + 0.4
		var xf2 := Transform3D(
			Basis(Vector3(0, 1, 0), a) * Basis(Vector3(0, 0, 1), 0.9),
			Vector3(cos(a) * 0.8, 3.4 + float(b) * 0.35, sin(a) * 0.8)
		)
		dead.add_box_xform(xf2, Vector3(0.13, 2.2, 0.13), Color(0.12, 0.1, 0.09))
	meshes["dead_tree"] = dead.commit(null, _mat.bark)


func _build_ground_cover() -> void:
	# Grass cluster: three crossed cards at LOD0, one at LOD1.
	for lod in 2:
		var b := MeshBuilder.new()
		var clumps: int = 3 if lod == 0 else 1
		for i in clumps:
			var ang: float = float(i) * 1.9
			var off := Vector3(cos(ang) * 0.28, 0.0, sin(ang) * 0.28)
			b.add_cross_card(off, 0.9, 0.85 - float(i) * 0.08,
				Color(0.13, 0.21, 0.09), Color(0.34, 0.50, 0.18), ang)
		meshes["grass_l%d" % lod] = b.commit(null, _mat.grass)

	var bush := MeshBuilder.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	bush.add_blob(Vector3(0.0, 0.55, 0.0), Vector3(0.95, 0.7, 0.95), 1,
		Color(0.15, 0.30, 0.13), rng, 0.3)
	meshes["bush"] = bush.commit(null, _mat.foliage)

	var fern := MeshBuilder.new()
	for i in 5:
		fern.add_cross_card(Vector3(cos(float(i) * 1.3) * 0.2, 0.0, sin(float(i) * 1.3) * 0.2),
			1.3, 0.75, Color(0.10, 0.23, 0.10), Color(0.22, 0.42, 0.16), float(i) * 0.7)
	meshes["fern"] = fern.commit(null, _mat.grass)


func _build_rocks() -> void:
	for lod in 2:
		var b := MeshBuilder.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 777 + lod
		b.add_blob(Vector3(0.0, 0.5, 0.0), Vector3(1.1, 0.8, 1.0),
			2 - lod, Color(0.30, 0.29, 0.28), rng, 0.34)
		meshes["rock_l%d" % lod] = b.commit(null, _mat.prop)
	var boulder := MeshBuilder.new()
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 991
	boulder.add_blob(Vector3(0.0, 1.6, 0.0), Vector3(2.6, 2.0, 2.4), 2,
		Color(0.27, 0.26, 0.26), rng2, 0.3)
	meshes["boulder"] = boulder.commit(null, _mat.prop)


# -----------------------------------------------------------------------------
# Urban
# -----------------------------------------------------------------------------
func _build_urban() -> void:
	# Unit floor module: 1x1x1 with the origin at the centre of its base.
	var mod := MeshBuilder.new()
	mod.add_box(Vector3(-0.5, 0.0, -0.5), Vector3.ONE, Color.WHITE, 1.0)
	meshes["building_module"] = mod.commit(null, _mat.building)

	# Roof cap with a lip, so towers do not end in a bare box.
	var cap := MeshBuilder.new()
	cap.add_box(Vector3(-0.54, 0.0, -0.54), Vector3(1.08, 0.12, 1.08), Color.WHITE)
	cap.add_box(Vector3(-0.54, 0.12, -0.54), Vector3(1.08, 0.32, 0.06), Color.WHITE)
	cap.add_box(Vector3(-0.54, 0.12, 0.48), Vector3(1.08, 0.32, 0.06), Color.WHITE)
	cap.add_box(Vector3(-0.54, 0.12, -0.54), Vector3(0.06, 0.32, 1.08), Color.WHITE)
	cap.add_box(Vector3(0.48, 0.12, -0.54), Vector3(0.06, 0.32, 1.08), Color.WHITE)
	meshes["building_cap"] = cap.commit(null, _mat.building)

	var lamp := MeshBuilder.new()
	lamp.add_cylinder(Vector3.ZERO, 6.2, 0.14, 0.1, 6, Color(0.24, 0.25, 0.27), true)
	lamp.add_box(Vector3(-0.1, 6.1, -0.1), Vector3(1.5, 0.14, 0.2), Color(0.24, 0.25, 0.27))
	var head: ArrayMesh = lamp.commit(null, _mat.prop)
	var glow := MeshBuilder.new()
	glow.add_box(Vector3(1.15, 5.92, -0.16), Vector3(0.42, 0.2, 0.32), Color(1.0, 0.86, 0.6))
	glow.commit(head, _mat.glass_emissive)
	meshes["streetlight"] = head

	var barrier := MeshBuilder.new()
	barrier.add_box(Vector3(-1.1, 0.0, -0.28), Vector3(2.2, 0.18, 0.56), Color(0.66, 0.64, 0.6))
	barrier.add_box(Vector3(-0.95, 0.18, -0.2), Vector3(1.9, 0.62, 0.4), Color(0.72, 0.70, 0.66))
	meshes["barrier"] = barrier.commit(null, _mat.prop)

	var fence := MeshBuilder.new()
	fence.add_box(Vector3(-0.06, 0.0, -0.06), Vector3(0.12, 2.2, 0.12), Color(0.3, 0.31, 0.33))
	fence.add_box(Vector3(0.0, 0.4, -0.03), Vector3(3.0, 0.06, 0.06), Color(0.34, 0.35, 0.37))
	fence.add_box(Vector3(0.0, 1.2, -0.03), Vector3(3.0, 0.06, 0.06), Color(0.34, 0.35, 0.37))
	fence.add_box(Vector3(0.0, 2.0, -0.03), Vector3(3.0, 0.06, 0.06), Color(0.34, 0.35, 0.37))
	meshes["fence"] = fence.commit(null, _mat.prop)

	var ac := MeshBuilder.new()
	ac.add_box(Vector3(-0.7, 0.0, -0.7), Vector3(1.4, 0.9, 1.4), Color(0.55, 0.56, 0.58))
	ac.add_cylinder(Vector3(0.0, 0.9, 0.0), 0.18, 0.5, 0.5, 8, Color(0.4, 0.41, 0.43), true)
	meshes["ac_unit"] = ac.commit(null, _mat.prop)

	var antenna := MeshBuilder.new()
	antenna.add_cylinder(Vector3.ZERO, 7.5, 0.1, 0.04, 5, Color(0.5, 0.51, 0.53), true)
	antenna.add_box(Vector3(-0.5, 2.2, -0.05), Vector3(1.0, 0.06, 0.1), Color(0.5, 0.5, 0.52))
	antenna.add_box(Vector3(-0.4, 4.0, -0.05), Vector3(0.8, 0.06, 0.1), Color(0.5, 0.5, 0.52))
	meshes["antenna"] = antenna.commit(null, _mat.prop)

	var container := MeshBuilder.new()
	container.add_box(Vector3(-3.0, 0.0, -1.2), Vector3(6.0, 2.6, 2.4), Color.WHITE)
	for i in 11:
		container.add_box(Vector3(-2.9 + float(i) * 0.52, 0.06, -1.24),
			Vector3(0.12, 2.48, 0.06), Color(0.85, 0.85, 0.85))
		container.add_box(Vector3(-2.9 + float(i) * 0.52, 0.06, 1.18),
			Vector3(0.12, 2.48, 0.06), Color(0.85, 0.85, 0.85))
	meshes["container"] = container.commit(null, _mat.prop)

	var tank := MeshBuilder.new()
	tank.add_cylinder(Vector3.ZERO, 7.0, 3.0, 3.0, 12, Color(0.62, 0.60, 0.56), true, true)
	tank.add_cylinder(Vector3(0.0, 7.0, 0.0), 0.9, 3.1, 2.2, 12, Color(0.55, 0.53, 0.5), true)
	meshes["tank"] = tank.commit(null, _mat.prop)

	var pipe := MeshBuilder.new()
	pipe.add_cylinder(Vector3(0.0, 1.4, 0.0), 0.001, 0.0, 0.0, 3, Color.WHITE, false)
	pipe.clear()
	pipe.add_box(Vector3(-6.0, 1.2, -0.35), Vector3(12.0, 0.7, 0.7), Color(0.48, 0.45, 0.40))
	pipe.add_box(Vector3(-4.0, 0.0, -0.25), Vector3(0.5, 1.2, 0.5), Color(0.38, 0.36, 0.34))
	pipe.add_box(Vector3(3.5, 0.0, -0.25), Vector3(0.5, 1.2, 0.5), Color(0.38, 0.36, 0.34))
	meshes["pipe"] = pipe.commit(null, _mat.prop)

	var rubble := MeshBuilder.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337
	for i in 9:
		var xf := Transform3D(
			Basis(Vector3(0, 1, 0), rng.randf() * TAU) * Basis(Vector3(1, 0, 0), rng.randf()),
			Vector3(rng.randf_range(-1.6, 1.6), rng.randf_range(0.1, 0.6),
				rng.randf_range(-1.6, 1.6))
		)
		rubble.add_box_xform(xf, Vector3(rng.randf_range(0.3, 0.9), rng.randf_range(0.2, 0.5),
			rng.randf_range(0.3, 0.9)), Color(0.34, 0.33, 0.32))
	meshes["rubble"] = rubble.commit(null, _mat.prop)

	var road_mark := MeshBuilder.new()
	road_mark.add_box(Vector3(-1.5, 0.0, -0.14), Vector3(3.0, 0.03, 0.28),
		Color(0.82, 0.80, 0.62))
	meshes["road_mark"] = road_mark.commit(null, _mat.prop)


func _build_props() -> void:
	var crate := MeshBuilder.new()
	crate.add_box(Vector3(-0.4, 0.0, -0.4), Vector3(0.8, 0.8, 0.8), Color(0.52, 0.38, 0.22))
	crate.add_box(Vector3(-0.42, 0.34, -0.42), Vector3(0.84, 0.12, 0.84), Color(0.42, 0.30, 0.17))
	meshes["crate"] = crate.commit(null, _mat.prop)

	var barrel := MeshBuilder.new()
	barrel.add_cylinder(Vector3.ZERO, 1.05, 0.36, 0.36, 10, Color(0.55, 0.28, 0.16), true, true)
	barrel.add_cylinder(Vector3(0.0, 0.3, 0.0), 0.08, 0.39, 0.39, 10, Color(0.4, 0.2, 0.12), true)
	barrel.add_cylinder(Vector3(0.0, 0.7, 0.0), 0.08, 0.39, 0.39, 10, Color(0.4, 0.2, 0.12), true)
	meshes["barrel"] = barrel.commit(null, _mat.prop)

	var dbr := MeshBuilder.new()
	dbr.add_box(Vector3(-0.22, 0.0, -0.18), Vector3(0.44, 0.3, 0.36), Color(0.4, 0.39, 0.37))
	meshes["debris"] = dbr.commit(null, _mat.debris)

	var pick := MeshBuilder.new()
	pick.add_box(Vector3(-0.22, 0.0, -0.22), Vector3(0.44, 0.44, 0.44), Color(0.35, 0.85, 0.55))
	pick.add_box(Vector3(-0.26, 0.16, -0.26), Vector3(0.52, 0.1, 0.52), Color(0.6, 1.0, 0.8))
	meshes["pickup"] = pick.commit(null, _mat.pickup)

	var core := MeshBuilder.new()
	var rngc := RandomNumberGenerator.new()
	rngc.seed = 5150
	core.add_blob(Vector3(0.0, 0.35, 0.0), Vector3(0.3, 0.42, 0.3), 1,
		Color(0.85, 0.25, 1.0), rngc, 0.18)
	meshes["core_pickup"] = core.commit(null, _mat.pickup)


func _build_vehicles() -> void:
	var car := MeshBuilder.new()
	car.add_box(Vector3(-2.1, 0.45, -0.88), Vector3(4.2, 0.62, 1.76), Color(0.6, 0.62, 0.66))
	car.add_box(Vector3(-1.1, 1.05, -0.78), Vector3(2.1, 0.6, 1.56), Color(0.5, 0.52, 0.56))
	var carm: ArrayMesh = car.commit(null, _mat.vehicle_body)
	var glass := MeshBuilder.new()
	glass.add_box(Vector3(-1.05, 1.1, -0.74), Vector3(2.0, 0.5, 1.48), Color(0.1, 0.12, 0.16))
	glass.commit(carm, _mat.vehicle_glass)
	var wheels := MeshBuilder.new()
	for sx in [-1.35, 1.35]:
		for sz in [-0.92, 0.92]:
			var xf := Transform3D(Basis(Vector3(1, 0, 0), PI * 0.5),
				Vector3(sx, 0.36, sz))
			wheels.add_cylinder(xf.origin + Vector3(0, 0, -0.1), 0.2, 0.36, 0.36, 8,
				Color(0.08, 0.08, 0.09), true, true)
	wheels.commit(carm, _mat.metal)
	meshes["car"] = carm

	var truck := MeshBuilder.new()
	truck.add_box(Vector3(-3.6, 0.6, -1.15), Vector3(7.2, 0.5, 2.3), Color(0.45, 0.47, 0.5))
	truck.add_box(Vector3(-3.4, 1.1, -1.1), Vector3(2.2, 1.5, 2.2), Color(0.55, 0.35, 0.25))
	truck.add_box(Vector3(-0.9, 1.1, -1.12), Vector3(4.4, 2.0, 2.24), Color(0.62, 0.63, 0.66))
	var truckm: ArrayMesh = truck.commit(null, _mat.vehicle_body)
	var tw := MeshBuilder.new()
	for sx in [-2.6, 1.0, 2.3]:
		for sz in [-1.2, 1.2]:
			tw.add_cylinder(Vector3(sx, 0.5, sz - 0.12), 0.24, 0.5, 0.5, 8,
				Color(0.08, 0.08, 0.09), true, true)
	tw.commit(truckm, _mat.metal)
	meshes["truck"] = truckm

	var wreck := MeshBuilder.new()
	wreck.add_box(Vector3(-2.0, 0.3, -0.85), Vector3(4.0, 0.5, 1.7), Color(0.28, 0.24, 0.22))
	wreck.add_box(Vector3(-0.9, 0.8, -0.7), Vector3(1.6, 0.4, 1.4), Color(0.22, 0.19, 0.18))
	meshes["wreck"] = wreck.commit(null, _mat.debris)


func _build_characters() -> void:
	meshes["npc_l0"] = _humanoid(true, Color(0.42, 0.45, 0.52), Color(0.62, 0.5, 0.42))
	meshes["npc_l1"] = _humanoid(false, Color(0.42, 0.45, 0.52), Color(0.62, 0.5, 0.42))
	meshes["enemy_l0"] = _creature(true)
	meshes["enemy_l1"] = _creature(false)


func _humanoid(detailed: bool, cloth: Color, skin: Color) -> ArrayMesh:
	var b := MeshBuilder.new()
	# Torso
	b.add_box(Vector3(-0.22, 0.78, -0.13), Vector3(0.44, 0.62, 0.26), cloth)
	# Head
	b.add_box(Vector3(-0.12, 1.42, -0.11), Vector3(0.24, 0.26, 0.22), skin)
	# Hips
	b.add_box(Vector3(-0.2, 0.62, -0.12), Vector3(0.4, 0.18, 0.24), cloth * 0.85)
	# Legs
	b.add_box(Vector3(-0.19, 0.0, -0.1), Vector3(0.17, 0.64, 0.2), cloth * 0.7)
	b.add_box(Vector3(0.02, 0.0, -0.1), Vector3(0.17, 0.64, 0.2), cloth * 0.7)
	if detailed:
		# Arms
		b.add_box(Vector3(-0.34, 0.8, -0.09), Vector3(0.12, 0.56, 0.18), cloth * 0.9)
		b.add_box(Vector3(0.22, 0.8, -0.09), Vector3(0.12, 0.56, 0.18), cloth * 0.9)
		# Pack
		b.add_box(Vector3(-0.17, 0.9, 0.12), Vector3(0.34, 0.4, 0.14), cloth * 0.6)
		# Feet
		b.add_box(Vector3(-0.2, 0.0, -0.14), Vector3(0.18, 0.09, 0.28), Color(0.14, 0.13, 0.12))
		b.add_box(Vector3(0.02, 0.0, -0.14), Vector3(0.18, 0.09, 0.28), Color(0.14, 0.13, 0.12))
	return b.commit(null, _mat.flesh)


func _creature(detailed: bool) -> ArrayMesh:
	var b := MeshBuilder.new()
	var body := Color(0.30, 0.11, 0.11)
	var rng := RandomNumberGenerator.new()
	rng.seed = 8675309
	b.add_blob(Vector3(0.0, 0.72, 0.0), Vector3(0.44, 0.42, 0.72), 1 if detailed else 0,
		body, rng, 0.16)
	b.add_box(Vector3(-0.17, 0.72, -0.86), Vector3(0.34, 0.34, 0.36), body * 1.1)
	for sx in [-0.26, 0.26]:
		for sz in [-0.4, 0.36]:
			b.add_box(Vector3(sx - 0.06, 0.0, sz - 0.06), Vector3(0.13, 0.74, 0.13),
				body * 0.8)
	if detailed:
		for i in 5:
			var t: float = float(i) / 4.0
			b.add_cone(Vector3(0.0, 1.08, -0.5 + t * 1.0), 0.34 - t * 0.12, 0.1, 4,
				Color(0.5, 0.12, 0.1), false)
	var m: ArrayMesh = b.commit(null, _mat.hostile)
	var eyes := MeshBuilder.new()
	eyes.add_box(Vector3(-0.13, 0.86, -0.9), Vector3(0.08, 0.06, 0.05), Color(1.0, 0.3, 0.15))
	eyes.add_box(Vector3(0.05, 0.86, -0.9), Vector3(0.08, 0.06, 0.05), Color(1.0, 0.3, 0.15))
	eyes.commit(m, _mat.tracer)
	return m


func _build_effects() -> void:
	var tracer := MeshBuilder.new()
	tracer.add_box(Vector3(-0.04, -0.04, -0.9), Vector3(0.08, 0.08, 1.8), Color(1, 0.9, 0.5))
	meshes["tracer"] = tracer.commit(null, _mat.tracer)

	var spark := QuadMesh.new()
	spark.size = Vector2(0.12, 0.12)
	meshes["spark_quad"] = spark

	var rain := QuadMesh.new()
	rain.size = Vector2(0.03, 0.55)
	meshes["rain_quad"] = rain

	var dust := QuadMesh.new()
	dust.size = Vector2(0.9, 0.9)
	meshes["dust_quad"] = dust
