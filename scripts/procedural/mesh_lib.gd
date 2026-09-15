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
## Meshes built from crossed cards. They enclose no volume, so the geometry
## orientation self-test has nothing meaningful to measure on them; the
## foliage shader renders them with cull_disabled anyway.
var open_meshes: PackedStringArray = PackedStringArray([
	"grass_l0", "grass_l1", "grass0_l0", "grass0_l1", "grass1_l0", "grass1_l1",
	"grass2_l0", "grass2_l1", "fern", "flower",
])
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
	# --- Conifer ------------------------------------------------------------
	# Trunk with a root flare, a ring of dead lower branches, and a stack of
	# canopy tiers whose undersides are darkened in the vertex stream. The
	# silhouette is what reads at distance; the flare and branches are what
	# stop it looking like a cone on a stick up close.
	for lod in 3:
		var seg: int = [9, 6, 4][lod]
		var trunk := MeshBuilder.new()
		trunk.add_cylinder(Vector3.ZERO, 0.55, 0.72, 0.46, seg,
			Color(0.34, 0.25, 0.17), false, false, 0.55)
		trunk.add_cylinder(Vector3(0.0, 0.5, 0.0), 8.6, 0.46, 0.14, seg,
			Color(0.44, 0.33, 0.22), true, false, 0.72)
		if lod == 0:
			for k in 7:
				var a: float = TAU * float(k) / 7.0 + 0.4
				var y: float = 2.0 + float(k) * 0.42
				var xf := Transform3D(
					Basis(Vector3(0, 1, 0), a) * Basis(Vector3(0, 0, 1), 2.05),
					Vector3(cos(a) * 0.3, y, sin(a) * 0.3))
				trunk.add_cylinder_xform(xf, 1.1 - float(k) * 0.06, 0.075, 0.03, 4,
					Color(0.30, 0.23, 0.16), false, false)
		var mesh: ArrayMesh = trunk.commit(null, _mat.bark)

		var can := MeshBuilder.new()
		var tiers: int = [7, 4, 2][lod]
		for i in tiers:
			var f: float = float(i) / float(maxi(tiers - 1, 1))
			var y2: float = 2.1 + f * 6.2
			var r: float = 2.85 * (1.0 - f * 0.82) + 0.25
			var hgt: float = 2.3 * (1.0 - f * 0.4)
			var tint: Color = Color(0.13, 0.30, 0.15).lerp(Color(0.26, 0.46, 0.22), f)
			can.add_cone(Vector3(0.0, y2, 0.0), hgt, r, seg + 3, tint, true, 0.5)
		can.commit(mesh, _mat.canopy)
		meshes["pine_l%d" % lod] = mesh

	# --- Broadleaf ----------------------------------------------------------
	for lod in 3:
		var seg2: int = [9, 6, 4][lod]
		var sub: int = [2, 1, 0][lod]
		var rng := RandomNumberGenerator.new()
		rng.seed = 1000 + lod
		var t2 := MeshBuilder.new()
		t2.add_cylinder(Vector3.ZERO, 0.6, 0.82, 0.54, seg2,
			Color(0.32, 0.24, 0.17), false, false, 0.5)
		t2.add_cylinder(Vector3(0.0, 0.55, 0.0), 3.2, 0.54, 0.34, seg2,
			Color(0.46, 0.35, 0.24), false, false, 0.7)
		var tips: Array[Vector3] = []
		var limbs: int = 5 if lod == 0 else 3
		for b in limbs:
			var a2: float = TAU * float(b) / float(limbs) + 0.7
			var lean: float = 0.78 + float(b % 2) * 0.16
			var len_b: float = 2.5 + float(b % 3) * 0.4
			var base_p := Vector3(cos(a2) * 0.28, 3.3, sin(a2) * 0.28)
			var xf2 := Transform3D(
				Basis(Vector3(0, 1, 0), a2) * Basis(Vector3(0, 0, 1), lean), base_p)
			t2.add_cylinder_xform(xf2, len_b, 0.24, 0.11, maxi(4, seg2 - 3),
				Color(0.43, 0.33, 0.23), false, false)
			var dir := Vector3(cos(a2) * sin(lean), cos(lean), sin(a2) * sin(lean))
			tips.append(base_p + dir * len_b)
		var m2: ArrayMesh = t2.commit(null, _mat.bark)

		var c2 := MeshBuilder.new()
		var leaf := Color(0.21, 0.42, 0.18)
		c2.add_blob(Vector3(0.0, 5.1, 0.0), Vector3(2.5, 2.0, 2.5), sub,
			leaf, rng, 0.26, 0.55)
		for p: Vector3 in tips:
			c2.add_blob(p + Vector3(0.0, 0.55, 0.0),
				Vector3(1.55, 1.25, 1.55), maxi(sub - 1, 0),
				leaf.lerp(Color(0.30, 0.52, 0.22), rng.randf()), rng, 0.3, 0.6)
		c2.commit(m2, _mat.canopy)
		meshes["broad_l%d" % lod] = m2

	# --- Birch: pale trunk, sparse crown ------------------------------------
	for lod in 2:
		var seg3: int = [8, 5][lod]
		var b3 := MeshBuilder.new()
		b3.add_cylinder(Vector3.ZERO, 7.4, 0.3, 0.13, seg3,
			Color(0.86, 0.86, 0.82), true, false, 0.8)
		if lod == 0:
			for k in 6:
				var a3: float = float(k) * 1.13
				var y3: float = 0.8 + float(k) * 1.0
				b3.add_box(Vector3(-0.31, y3, -0.31 + sin(a3) * 0.1),
					Vector3(0.62, 0.09, 0.12), Color(0.20, 0.19, 0.18))
		var m3: ArrayMesh = b3.commit(null, _mat.bark)
		var c3 := MeshBuilder.new()
		var rng3 := RandomNumberGenerator.new()
		rng3.seed = 2200 + lod
		for k in (4 if lod == 0 else 2):
			var a4: float = TAU * float(k) / 4.0
			c3.add_blob(Vector3(cos(a4) * 0.9, 6.0 + float(k % 2) * 0.7, sin(a4) * 0.9),
				Vector3(1.5, 1.1, 1.5), 1 - lod,
				Color(0.36, 0.52, 0.20), rng3, 0.3, 0.5)
		c3.commit(m3, _mat.canopy)
		meshes["birch_l%d" % lod] = m3

	# --- Dead / burnt -------------------------------------------------------
	var dead := MeshBuilder.new()
	dead.add_cylinder(Vector3.ZERO, 0.5, 0.62, 0.42, 6,
		Color(0.22, 0.19, 0.17), false, false, 0.5)
	dead.add_cylinder(Vector3(0.0, 0.45, 0.0), 5.6, 0.4, 0.09, 6,
		Color(0.31, 0.27, 0.24), true, false, 0.65)
	for b in 6:
		var a5: float = TAU * float(b) / 6.0 + 0.35
		var xf3 := Transform3D(
			Basis(Vector3(0, 1, 0), a5) * Basis(Vector3(0, 0, 1), 1.0 + float(b % 3) * 0.25),
			Vector3(cos(a5) * 0.3, 2.6 + float(b) * 0.45, sin(a5) * 0.3))
		dead.add_cylinder_xform(xf3, 1.6 + float(b % 2) * 0.6, 0.11, 0.03, 4,
			Color(0.27, 0.23, 0.2), false, false)
	meshes["dead_tree"] = dead.commit(null, _mat.bark)

	# --- Distant impostors ---------------------------------------------------
	# Two crossed cards wearing a generated silhouette. Four triangles each, so
	# the outer half of the tree draw distance costs almost nothing, and the
	# upward normal makes them take the same light as the canopies they replace.
	var impostors: Array = [
		# Card dimensions match the close-range mesh they stand in for: the
		# conifer is 5.7 m across and 10.4 m tall at LOD0, the broadleaf is a
		# squat 7.2 m crown, the birch is a narrow 3.6 m.
		# Colours are roughly 55% of the close-range canopy's. An upward normal
		# is what keeps a billboard from flickering as the camera turns, but it
		# also means the card takes the full overhead light term where a real
		# canopy is largely self-shaded, so the tone has to come down to match.
		["pine_l3", 6.2, 10.4, Color(0.10, 0.19, 0.10), Color(0.17, 0.28, 0.14),
			_mat.impostor_conifer],
		["broad_l3", 7.2, 7.8, Color(0.12, 0.21, 0.11), Color(0.19, 0.31, 0.14),
			_mat.impostor_broadleaf],
		["birch_l2", 3.6, 7.6, Color(0.19, 0.26, 0.14), Color(0.27, 0.34, 0.17),
			_mat.impostor_birch],
	]
	for spec: Array in impostors:
		var card := MeshBuilder.new()
		card.add_cross_card(Vector3.ZERO, float(spec[1]), float(spec[2]),
			spec[3], spec[4], 0.0, Vector3(0.0, 1.0, 0.0))
		meshes[String(spec[0])] = card.commit(null, spec[5])
		open_meshes.append(String(spec[0]))

	# --- Forest floor debris ------------------------------------------------
	var log_mesh := MeshBuilder.new()
	var lxf := Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3(0.0, 0.42, 0.0))
	log_mesh.add_cylinder_xform(lxf, 4.2, 0.42, 0.34, 8, Color(0.36, 0.28, 0.2), true, true)
	meshes["log"] = log_mesh.commit(null, _mat.bark)

	var stump := MeshBuilder.new()
	stump.add_cylinder(Vector3.ZERO, 0.32, 0.78, 0.62, 8,
		Color(0.30, 0.23, 0.16), false, false, 0.5)
	stump.add_cylinder(Vector3(0.0, 0.3, 0.0), 0.75, 0.6, 0.55, 8,
		Color(0.42, 0.32, 0.22), true, false, 0.7)
	meshes["stump"] = stump.commit(null, _mat.bark)


func _build_ground_cover() -> void:
	# Three tuft species of different height and hue. Each blade is real
	# geometry that tapers to a point, so the material needs no alpha test --
	# see shaders/grass_solid.gdshader for why that matters at this instance
	# count. A tuft is ~5 blades x 5 triangles; the l1 variant drops to two
	# blades for everything past the near LOD band.
	var variants: Array[Dictionary] = [
		{"blades": 6, "w": 0.085, "h": 0.46, "lean": 0.10,
			"bottom": Color(0.13, 0.20, 0.07), "top": Color(0.56, 0.72, 0.28)},
		{"blades": 5, "w": 0.075, "h": 0.68, "lean": 0.16,
			"bottom": Color(0.11, 0.18, 0.06), "top": Color(0.46, 0.63, 0.22)},
		{"blades": 7, "w": 0.095, "h": 0.34, "lean": 0.07,
			"bottom": Color(0.16, 0.23, 0.09), "top": Color(0.63, 0.76, 0.34)},
	]
	for v in variants.size():
		var cfg: Dictionary = variants[v]
		for lod in 2:
			var b := MeshBuilder.new()
			var blades: int = int(cfg["blades"]) if lod == 0 else 2
			var segs: int = 4 if lod == 0 else 2
			for i in blades:
				# Golden-angle spread so no two blades in a tuft line up and no
				# two tufts share a silhouette once the instance yaw varies.
				var ang: float = float(i) * 2.39996 + float(v) * 0.7
				var rad: float = 0.045 * sqrt(float(i) / float(maxi(blades, 1)))
				var off := Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
				var hs: float = 1.0 - float(i) * 0.06
				b.add_blade(off, ang, float(cfg["w"]),
					float(cfg["h"]) * hs, float(cfg["lean"]),
					cfg["bottom"], cfg["top"], segs)
			meshes["grass%d_l%d" % [v, lod]] = b.commit(null, _mat.grass)
	# Legacy keys, so any batch still asking for "grass_l*" resolves.
	meshes["grass_l0"] = meshes["grass0_l0"]
	meshes["grass_l1"] = meshes["grass0_l1"]

	var flower := MeshBuilder.new()
	for i in 3:
		var a: float = float(i) * 2.1
		flower.add_cross_card(Vector3(cos(a) * 0.14, 0.0, sin(a) * 0.14), 0.3, 0.42,
			Color(0.20, 0.30, 0.12), Color(0.86, 0.82, 0.42), a)
	meshes["flower"] = flower.commit(null, _mat.grass)

	var bush := MeshBuilder.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	bush.add_blob(Vector3(0.0, 0.48, 0.0), Vector3(0.85, 0.62, 0.85), 1,
		Color(0.20, 0.38, 0.17), rng, 0.32, 0.6)
	bush.add_blob(Vector3(0.42, 0.36, -0.28), Vector3(0.5, 0.4, 0.5), 1,
		Color(0.24, 0.42, 0.19), rng, 0.32, 0.6)
	meshes["bush"] = bush.commit(null, _mat.canopy)

	var fern := MeshBuilder.new()
	for i in 6:
		fern.add_cross_card(Vector3(cos(float(i) * 1.1) * 0.22, 0.0,
			sin(float(i) * 1.1) * 0.22), 1.15, 0.66,
			Color(0.13, 0.24, 0.10), Color(0.32, 0.50, 0.20), float(i) * 0.62)
	meshes["fern"] = fern.commit(null, _mat.grass)


func _build_rocks() -> void:
	for lod in 2:
		var b := MeshBuilder.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 777 + lod
		# Centred at half its own height so the rock rests on the ground
		# instead of being buried to its waist.
		b.add_blob(Vector3(0.0, 0.62, 0.0), Vector3(1.0, 0.66, 0.95),
			2 - lod, Color(0.34, 0.33, 0.31), rng, 0.38)
		meshes["rock_l%d" % lod] = b.commit(null, _mat.prop)
	# Outcrops: stacked, tilted slabs rather than one smooth lump. These go on
	# steep ground, where the terrain is otherwise a featureless slope, and
	# they are the main thing breaking up a horizon of rounded hills.
	for variant in 2:
		var out := MeshBuilder.new()
		var orng := RandomNumberGenerator.new()
		orng.seed = 6100 + variant
		var slabs: int = 5 + variant * 2
		var height: float = 0.0
		for i in slabs:
			var t: float = float(i) / float(slabs)
			var w: float = (3.4 - t * 2.1) * (0.85 + orng.randf() * 0.3)
			var dp: float = (3.0 - t * 1.8) * (0.85 + orng.randf() * 0.3)
			var th: float = orng.randf_range(0.55, 1.15) * (1.0 - t * 0.35)
			var xf := Transform3D(
				Basis(Vector3(0, 1, 0), orng.randf() * TAU)
					* Basis(Vector3(0, 0, 1), orng.randf_range(-0.16, 0.16))
					* Basis(Vector3(1, 0, 0), orng.randf_range(-0.14, 0.14)),
				Vector3(orng.randf_range(-0.5, 0.5), height + th * 0.5,
					orng.randf_range(-0.5, 0.5)))
			var grey: float = orng.randf_range(0.28, 0.42)
			out.add_box_xform(xf, Vector3(w, th, dp),
				Color(grey * 1.04, grey, grey * 0.94))
			height += th * orng.randf_range(0.72, 0.95)
		meshes["outcrop%d" % variant] = out.commit(null, _mat.prop)

	var boulder := MeshBuilder.new()
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 991
	boulder.add_blob(Vector3(0.0, 1.7, 0.0), Vector3(2.3, 1.8, 2.2), 2,
		Color(0.31, 0.30, 0.29), rng2, 0.32)
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

	# Facade sign: a lit panel in a dark frame. The instance is placed standing
	# off the wall along its own +Z, so every lit surface here has to sit at
	# POSITIVE z, proud of the frame. Putting the panel behind the frame -- at
	# negative z, where it started -- pushes it into the brickwork and the sign
	# renders as an unlit black slab from the street.
	var sign := MeshBuilder.new()
	sign.add_box(Vector3(-2.1, -0.95, -0.14), Vector3(4.2, 1.9, 0.18),
		Color(0.09, 0.09, 0.11))
	sign.add_box(Vector3(-1.88, -0.74, 0.03), Vector3(3.76, 1.48, 0.12), Color.WHITE)
	# Blade sign projecting out from the wall, hung below the panel. It starts
	# at the wall face and reaches outwards rather than straddling it.
	sign.add_box(Vector3(-0.17, -2.7, 0.02), Vector3(0.34, 1.7, 1.15),
		Color(0.09, 0.09, 0.11))
	sign.add_box(Vector3(-0.09, -2.55, 0.12), Vector3(0.18, 1.4, 0.95), Color.WHITE)
	meshes["sign"] = sign.commit(null, _mat.neon)

	# Rooftop hoarding: taller, on a visible gantry. Lit face on +Z for the
	# same reason as the facade sign; the back stays a dark board.
	var hoarding := MeshBuilder.new()
	hoarding.add_box(Vector3(-0.12, 0.0, -0.12), Vector3(0.24, 2.2, 0.24),
		Color(0.16, 0.16, 0.18))
	hoarding.add_box(Vector3(-3.0, 2.0, -0.16), Vector3(6.0, 2.6, 0.24),
		Color(0.10, 0.10, 0.12))
	var hoarding_frame: ArrayMesh = hoarding.commit(null, _mat.prop)
	var hoarding_face := MeshBuilder.new()
	hoarding_face.add_box(Vector3(-2.8, 2.2, 0.06), Vector3(5.6, 2.2, 0.12), Color.WHITE)
	hoarding_face.commit(hoarding_frame, _mat.neon)
	meshes["hoarding"] = hoarding_frame

	# Street furniture that reads at ground level.
	var bollard := MeshBuilder.new()
	bollard.add_cylinder(Vector3.ZERO, 0.95, 0.11, 0.09, 6, Color(0.30, 0.31, 0.33), true)
	bollard.add_cylinder(Vector3(0.0, 0.8, 0.0), 0.06, 0.13, 0.13, 6,
		Color(0.85, 0.72, 0.25), true)
	meshes["bollard"] = bollard.commit(null, _mat.prop)

	var road_mark := MeshBuilder.new()
	road_mark.add_box(Vector3(-1.8, 0.0, -0.15), Vector3(3.6, 0.03, 0.30),
		Color(0.82, 0.80, 0.62))
	meshes["road_mark"] = road_mark.commit(null, _mat.prop)

	# Kerb and footway. Both are 8 m long to match the road furniture step, so
	# consecutive instances tile into a continuous edge rather than a dashed
	# one. Local +X runs along the carriageway and local +Z points away from
	# it, which is the convention the placement yaw assumes.
	var kerb := MeshBuilder.new()
	kerb.add_box(Vector3(-4.0, 0.0, -0.02), Vector3(8.0, 0.155, 0.34),
		Color(0.56, 0.55, 0.53))
	# A darker face on the carriageway side reads as the shadowed edge even
	# with no local light on it.
	kerb.add_box(Vector3(-4.0, 0.0, -0.06), Vector3(8.0, 0.12, 0.05),
		Color(0.34, 0.335, 0.33))
	meshes["kerb"] = kerb.commit(null, _mat.prop)

	var footway := MeshBuilder.new()
	footway.add_box(Vector3(-4.0, 0.0, 0.3), Vector3(8.0, 0.14, 3.1),
		Color(0.50, 0.495, 0.485))
	# Flag joints: two shallow grooves, enough to break up 8 m of flat slab.
	for gi in 3:
		footway.add_box(Vector3(-4.0 + float(gi + 1) * 2.0 - 0.04, 0.14, 0.32),
			Vector3(0.08, 0.008, 3.06), Color(0.40, 0.40, 0.39))
	meshes["footway"] = footway.commit(null, _mat.prop)


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
	for sx: float in [-1.35, 1.35]:
		for sz: float in [-0.9, 0.9]:
			# Rotate about Z so the cylinder axis runs across the vehicle.
			var xf := Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5),
				Vector3(sx, 0.36, sz))
			wheels.add_cylinder_xform(xf, 0.22, 0.36, 0.36, 10,
				Color(0.09, 0.09, 0.10), true, true)
	wheels.commit(carm, _mat.metal)
	meshes["car"] = carm

	var truck := MeshBuilder.new()
	truck.add_box(Vector3(-3.6, 0.6, -1.15), Vector3(7.2, 0.5, 2.3), Color(0.45, 0.47, 0.5))
	truck.add_box(Vector3(-3.4, 1.1, -1.1), Vector3(2.2, 1.5, 2.2), Color(0.55, 0.35, 0.25))
	truck.add_box(Vector3(-0.9, 1.1, -1.12), Vector3(4.4, 2.0, 2.24), Color(0.62, 0.63, 0.66))
	var truckm: ArrayMesh = truck.commit(null, _mat.vehicle_body)
	var tw := MeshBuilder.new()
	for sx: float in [-2.6, 1.0, 2.3]:
		for sz: float in [-1.16, 1.16]:
			var xf2 := Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5),
				Vector3(sx, 0.5, sz))
			tw.add_cylinder_xform(xf2, 0.26, 0.5, 0.5, 10,
				Color(0.09, 0.09, 0.10), true, true)
	tw.commit(truckm, _mat.metal)
	meshes["truck"] = truckm

	var wreck := MeshBuilder.new()
	wreck.add_box(Vector3(-2.0, 0.34, -0.82), Vector3(4.0, 0.6, 1.64), Color(0.34, 0.28, 0.25))
	wreck.add_box(Vector3(-1.0, 0.94, -0.72), Vector3(1.9, 0.62, 1.44), Color(0.27, 0.22, 0.2))
	wreck.add_box(Vector3(1.0, 0.5, -0.86), Vector3(0.9, 0.5, 1.72), Color(0.22, 0.17, 0.15))
	for sx: float in [-1.3, 1.25]:
		for sz: float in [-0.86, 0.86]:
			var wxf := Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5),
				Vector3(sx, 0.34, sz))
			wreck.add_cylinder_xform(wxf, 0.2, 0.34, 0.34, 8,
				Color(0.12, 0.11, 0.11), true, true)
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
