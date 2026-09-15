class_name ChunkGenerator
extends RefCounted
## Turns a chunk coordinate into a ChunkData. Runs entirely on worker threads:
## it touches no scene nodes and creates no engine resources, only PackedArrays.

const CELL: float = GameConfig.CHUNK_SIZE / float(GameConfig.CHUNK_VERTS_LOD0 - 1)
const LOD_STEPS: PackedInt32Array = [1, 2, 4, 8]
const SKIRT_DEPTH: float = 7.0
const BLOCK_CELL: float = 16.0
const FLOOR_HEIGHT: float = 3.4
const MAX_MODULES_PER_CHUNK: int = 900
const PERM_PRIME: int = 104729
## Sign palette. Deliberately narrow and saturated so a night skyline reads as
## a city rather than a colour-noise field.
## Facade families, chosen per district. Deliberately desaturated: these are
## multiplied by the wall texture and then lit, so anything vivid here reads as
## a toy.
const FACADE_PALETTE: PackedColorArray = [
	Color(0.52, 0.51, 0.50),   # concrete
	Color(0.58, 0.53, 0.44),   # sandstone
	Color(0.34, 0.38, 0.45),   # blue-grey curtain wall
	Color(0.30, 0.29, 0.30),   # dark steel
	Color(0.47, 0.31, 0.26),   # brick
	Color(0.40, 0.45, 0.42),   # green-grey glass
	Color(0.62, 0.59, 0.54),   # pale render
]

const NEON_COLORS: Array[Color] = [
	Color(1.00, 0.24, 0.30), Color(0.25, 0.85, 1.00), Color(1.00, 0.62, 0.15),
	Color(0.60, 0.30, 1.00), Color(0.30, 1.00, 0.55), Color(1.00, 0.85, 0.30),
]


## Bilinear sampler over the chunk's already-computed height grid. Terrain
## height is by far the most expensive function in the world (roughly ten noise
## octaves per call), so scattering reads it from here instead of recomputing
## it thousands of times per chunk.
class ChunkField extends RefCounted:
	var n: int = 0
	var cell: float = 1.0
	var ox: float = 0.0
	var oz: float = 0.0
	var heights: PackedFloat32Array

	func _init(grid: PackedFloat32Array, side: int, cell_size: float,
			origin_x: float, origin_z: float) -> void:
		heights = grid
		n = side
		cell = cell_size
		ox = origin_x
		oz = origin_z

	func h(wx: float, wz: float) -> float:
		var fx: float = clampf((wx - ox) / cell, 0.0, float(n - 1))
		var fz: float = clampf((wz - oz) / cell, 0.0, float(n - 1))
		var i0: int = int(fx)
		var j0: int = int(fz)
		var i1: int = mini(i0 + 1, n - 1)
		var j1: int = mini(j0 + 1, n - 1)
		var tx: float = fx - float(i0)
		var tz: float = fz - float(j0)
		var h00: float = heights[j0 * n + i0]
		var h10: float = heights[j0 * n + i1]
		var h01: float = heights[j1 * n + i0]
		var h11: float = heights[j1 * n + i1]
		return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

	## 0 = flat, 1 = vertical. Derived from the grid, not from extra noise.
	func slope(wx: float, wz: float) -> float:
		var e: float = cell
		var dx: float = h(wx + e, wz) - h(wx - e, wz)
		var dz: float = wz
		dz = h(wx, wz + e) - h(wx, wz - e)
		var nrm := Vector3(-dx, 2.0 * e, -dz).normalized()
		return 1.0 - clampf(nrm.y, 0.0, 1.0)


## Options: veg_step (float), collision (bool), lod_count (int),
## prop_richness (float 0..2), seed_salt (int).
static func generate(gen: WorldGen, coord: Vector2i, opts: Dictionary) -> ChunkData:
	var t0: int = Time.get_ticks_usec()
	var d := ChunkData.new()
	d.coord = coord
	d.origin = Vector3(float(coord.x) * GameConfig.CHUNK_SIZE, 0.0,
		float(coord.y) * GameConfig.CHUNK_SIZE)
	d.center = d.origin + Vector3(GameConfig.CHUNK_SIZE * 0.5, 0.0, GameConfig.CHUNK_SIZE * 0.5)
	d.zone = gen.zone_at(d.center.x, d.center.z)
	d.veg_step = float(opts.get("veg_step", 1.6))

	var n: int = GameConfig.CHUNK_VERTS_LOD0
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var vcolors := PackedColorArray()
	vcolors.resize(n * n)
	var hmin: float = INF
	var hmax: float = -INF

	for j in n:
		var wz: float = d.origin.z + float(j) * CELL
		for i in n:
			var wx: float = d.origin.x + float(i) * CELL
			var u: float = gen.urban_factor(wx, wz)
			var h: float = gen.height_u(wx, wz, u)
			heights[j * n + i] = h
			vcolors[j * n + i] = gen.terrain_color_u(wx, wz, h, u)
			hmin = minf(hmin, h)
			hmax = maxf(hmax, h)

	d.height_min = hmin
	d.height_max = hmax
	d.has_water = hmin < GameConfig.WATER_LEVEL + 0.4

	var lod_count: int = clampi(int(opts.get("lod_count", 4)), 1, LOD_STEPS.size())
	for l in lod_count:
		d.terrain_lods.append(_terrain_surface(heights, vcolors, n, LOD_STEPS[l]))

	if bool(opts.get("collision", false)):
		d.collision_faces = _collision_faces_overlapped(gen, d, heights, n)

	d.heights = heights
	d.height_side = n
	d.height_cell = CELL
	var field := ChunkField.new(heights, n, CELL, d.origin.x, d.origin.z)
	_scatter_vegetation(gen, d, opts, field)
	_build_structures(gen, d, opts, field)
	_scatter_props(gen, d, opts, field)
	_place_spawns(gen, d, opts, field)

	d.gen_msec = float(Time.get_ticks_usec() - t0) / 1000.0
	return d


# -----------------------------------------------------------------------------
# Terrain
# -----------------------------------------------------------------------------
static func _terrain_surface(heights: PackedFloat32Array, vcolors: PackedColorArray,
		n: int, step: int) -> Array:
	var verts_side: int = (n - 1) / step + 1
	var mb := MeshBuilder.new(true)
	var idx := PackedInt32Array()
	idx.resize(verts_side * verts_side)
	var span: float = CELL * float(step)

	for j in verts_side:
		for i in verts_side:
			var si: int = i * step
			var sj: int = j * step
			var h: float = heights[sj * n + si]
			# Normals come straight from the height grid. Accumulating them
			# per-triangle in script was the second-largest cost in chunk
			# generation; central differences give the same result in O(verts).
			var hl: float = heights[sj * n + maxi(si - step, 0)]
			var hr: float = heights[sj * n + mini(si + step, n - 1)]
			var hd: float = heights[maxi(sj - step, 0) * n + si]
			var hu: float = heights[mini(sj + step, n - 1) * n + si]
			var nrm := Vector3(hl - hr, 2.0 * span, hd - hu).normalized()
			var p := Vector3(float(si) * CELL, h, float(sj) * CELL)
			idx[j * verts_side + i] = mb.add_vertex(
				p, nrm,
				Vector2(float(si) / float(n - 1), float(sj) / float(n - 1)),
				vcolors[sj * n + si]
			)

	for j in verts_side - 1:
		for i in verts_side - 1:
			var a: int = idx[j * verts_side + i]
			var b: int = idx[j * verts_side + i + 1]
			var c: int = idx[(j + 1) * verts_side + i + 1]
			var e: int = idx[(j + 1) * verts_side + i]
			mb.add_triangle(a, c, b)
			mb.add_triangle(a, e, c)

	_add_skirt(mb, idx, verts_side)
	return mb.to_arrays()


## Vertical apron around the chunk edge. Hides the seam where a neighbouring
## chunk is rendering a coarser LOD without needing stitched geometry.
static func _add_skirt(mb: MeshBuilder, idx: PackedInt32Array, side: int) -> void:
	var edges: Array = []
	var top: PackedInt32Array = PackedInt32Array()
	for i in side:
		top.push_back(idx[i])
	edges.append(top)
	var bottom: PackedInt32Array = PackedInt32Array()
	for i in range(side - 1, -1, -1):
		bottom.push_back(idx[(side - 1) * side + i])
	edges.append(bottom)
	var left: PackedInt32Array = PackedInt32Array()
	for j in range(side - 1, -1, -1):
		left.push_back(idx[j * side])
	edges.append(left)
	var right: PackedInt32Array = PackedInt32Array()
	for j in side:
		right.push_back(idx[j * side + side - 1])
	edges.append(right)

	for e: PackedInt32Array in edges:
		for k in e.size() - 1:
			var a: int = e[k]
			var b: int = e[k + 1]
			var pa: Vector3 = mb.verts[a]
			var pb: Vector3 = mb.verts[b]
			var ca: Color = mb.colors[a] if mb.colors.size() > a else Color.WHITE
			var da: Vector3 = pa - Vector3(0.0, SKIRT_DEPTH, 0.0)
			var db: Vector3 = pb - Vector3(0.0, SKIRT_DEPTH, 0.0)
			var nrm: Vector3 = (pb - pa).cross(Vector3.DOWN).normalized()
			var i0: int = mb.add_vertex(pa, nrm, Vector2(0, 0), ca * 0.8)
			var i1: int = mb.add_vertex(pb, nrm, Vector2(1, 0), ca * 0.8)
			var i2: int = mb.add_vertex(db, nrm, Vector2(1, 1), ca * 0.55)
			var i3: int = mb.add_vertex(da, nrm, Vector2(0, 1), ca * 0.55)
			# Outward-facing only; the apron is never seen from inside the chunk.
			mb.add_triangle(i0, i1, i2)
			mb.add_triangle(i0, i2, i3)


## Collision surface, built one cell wider than the chunk on every side.
##
## ConcavePolygonShape3D is a triangle soup with no adjacency information, so a
## capsule standing exactly on the outer edge of one chunk's mesh reports the
## perimeter edge normal -- an axis-aligned vertical "wall" -- instead of the
## ground. Overlapping neighbouring chunks by one cell means the capsule is
## always in the interior of at least one mesh. The border ring is sampled from
## the same analytic height function, so the overlapping surfaces coincide
## exactly.
static func _collision_faces_overlapped(gen: WorldGen, d: ChunkData,
		heights: PackedFloat32Array, n: int) -> PackedVector3Array:
	var side: int = n + 2
	var grid := PackedFloat32Array()
	grid.resize(side * side)
	for j in side:
		var lj: int = j - 1
		for i in side:
			var li: int = i - 1
			if li >= 0 and li < n and lj >= 0 and lj < n:
				grid[j * side + i] = heights[lj * n + li]
			else:
				var wx: float = d.origin.x + float(li) * CELL
				var wz: float = d.origin.z + float(lj) * CELL
				grid[j * side + i] = gen.height(wx, wz)

	var faces := PackedVector3Array()
	faces.resize((side - 1) * (side - 1) * 6)
	var w: int = 0
	for j in side - 1:
		var z0: float = float(j - 1) * CELL
		var z1: float = float(j) * CELL
		for i in side - 1:
			var x0: float = float(i - 1) * CELL
			var x1: float = float(i) * CELL
			var h00: float = grid[j * side + i]
			var h10: float = grid[j * side + i + 1]
			var h11: float = grid[(j + 1) * side + i + 1]
			var h01: float = grid[(j + 1) * side + i]
			# Clockwise seen from above: ConcavePolygonShape3D is one-sided and
			# uses the same front-face convention as the renderer, so the
			# reversed order would give a surface you fall through from above
			# and land on from underneath.
			faces[w] = Vector3(x0, h00, z0); w += 1
			faces[w] = Vector3(x1, h10, z0); w += 1
			faces[w] = Vector3(x1, h11, z1); w += 1
			faces[w] = Vector3(x0, h00, z0); w += 1
			faces[w] = Vector3(x1, h11, z1); w += 1
			faces[w] = Vector3(x0, h01, z1); w += 1
	return faces


# -----------------------------------------------------------------------------
# Scatter helpers
# -----------------------------------------------------------------------------
## Spread-out visitation order so that lowering a MultiMesh's
## visible_instance_count thins a batch evenly instead of clipping a rectangle.
static func _permuted(k: int, total: int) -> int:
	if total <= 1:
		return 0
	var p: int = PERM_PRIME
	while p % total == 0:
		p += 2
	return (k * p) % total


static func _batch(d: ChunkData, key: String, lods: PackedStringArray, cat: String,
		shadows: bool = true, variant: int = 0) -> InstanceBatch:
	if not d.batches.has(key):
		d.batches[key] = InstanceBatch.new(lods, cat, shadows, variant)
	return d.batches[key]


# -----------------------------------------------------------------------------
# Vegetation
# -----------------------------------------------------------------------------
static func _scatter_vegetation(gen: WorldGen, d: ChunkData, opts: Dictionary,
		field: ChunkField) -> void:
	var richness: float = float(opts.get("prop_richness", 1.0))
	var ox: float = d.origin.x
	var oz: float = d.origin.z

	# --- Ground cover -------------------------------------------------------
	# Three grass batches plus flowers. Mixing variants per instance is what
	# stops a field reading as one card stamped in a grid.
	var gstep: float = clampf(d.veg_step, 0.25, 4.0)
	var gw: int = maxi(2, int(GameConfig.CHUNK_SIZE / gstep))
	var gtotal: int = gw * gw
	var grass_batches: Array[InstanceBatch] = []
	for v in 3:
		grass_batches.append(_batch(d, "grass%d" % v,
			PackedStringArray(["grass%d_l0" % v, "grass%d_l1" % v]), "grass", false))
		grass_batches[v].reserve(gtotal / 2)
	var flowers: InstanceBatch = _batch(d, "flower",
		PackedStringArray(["flower"]), "grass", false)

	for k in gtotal:
		var pi: int = _permuted(k, gtotal)
		var gi: int = pi % gw
		var gj: int = pi / gw
		var jx: float = WorldGen.hash_range(d.coord.x * 1000 + gi, d.coord.y * 1000 + gj, 11,
			0.0, gstep)
		var jz: float = WorldGen.hash_range(d.coord.x * 1000 + gi, d.coord.y * 1000 + gj, 12,
			0.0, gstep)
		var wx: float = ox + float(gi) * gstep + jx
		var wz: float = oz + float(gj) * gstep + jz
		var gh: float = field.h(wx, wz)
		var dens: float = gen.grass_density_at(wx, wz, gh, field.slope(wx, wz))
		if dens <= 0.02:
			continue
		var roll_g: float = WorldGen.hash_f(int(wx * 8.0), int(wz * 8.0), 13)
		if roll_g > dens:
			continue
		var s: float = WorldGen.hash_range(int(wx * 4.0), int(wz * 4.0), 14, 0.75, 1.5)
		var tint: float = WorldGen.hash_range(int(wx * 4.0), int(wz * 4.0), 15, 0.72, 1.22)
		var moist: float = gen.moisture(wx, wz)
		# Drier ground skews yellow, damper ground skews blue-green.
		var col := Color(
			(0.95 + (0.5 - moist) * 0.4) * tint,
			(1.0 + (moist - 0.5) * 0.12) * tint,
			(0.72 + moist * 0.45) * tint, 1.0)
		var pos := Vector3(wx - ox, gh, wz - oz)
		var yaw: float = WorldGen.hash_range(int(wx), int(wz), 16, 0.0, TAU)
		var custom := Color(WorldGen.hash_f(int(wx), int(wz), 18), 0.0, 0.0, 0.0)
		if roll_g < dens * 0.06 and richness > 0.4:
			flowers.add_simple(pos, yaw, Vector3(s, s, s), col * 1.1, custom)
		else:
			var v2: int = WorldGen.hash_i(int(wx * 3.0), int(wz * 3.0), 19) % 3
			grass_batches[v2].add_simple(pos, yaw,
				Vector3(s, s * WorldGen.hash_range(int(wx), int(wz), 17, 0.85, 1.5), s),
				col, custom)

	# --- Trees --------------------------------------------------------------
	var tstep: float = 4.4
	var tw: int = maxi(2, int(GameConfig.CHUNK_SIZE / tstep))
	var ttotal: int = tw * tw
	var pine: InstanceBatch = _batch(d, "pine",
		PackedStringArray(["pine_l0", "pine_l1", "pine_l2", "pine_l3"]), "tree", true)
	var broad: InstanceBatch = _batch(d, "broad",
		PackedStringArray(["broad_l0", "broad_l1", "broad_l2", "broad_l3"]), "tree", true)
	var birch: InstanceBatch = _batch(d, "birch",
		PackedStringArray(["birch_l0", "birch_l1", "birch_l2", "birch_l2"]), "tree", true)
	var dead: InstanceBatch = _batch(d, "dead_tree",
		PackedStringArray(["dead_tree"]), "tree", true)
	var bush: InstanceBatch = _batch(d, "bush",
		PackedStringArray(["bush", "bush"]), "bush", false)
	var fern: InstanceBatch = _batch(d, "fern",
		PackedStringArray(["fern"]), "bush", false)
	var logs: InstanceBatch = _batch(d, "log",
		PackedStringArray(["log"]), "prop", true)
	var stumps: InstanceBatch = _batch(d, "stump",
		PackedStringArray(["stump"]), "prop", true)

	for k in ttotal:
		var pi2: int = _permuted(k, ttotal)
		var ti: int = pi2 % tw
		var tj: int = pi2 / tw
		var bx: float = ox + float(ti) * tstep + WorldGen.hash_range(
			d.coord.x * 977 + ti, d.coord.y * 977 + tj, 21, 0.25, tstep - 0.25)
		var bz: float = oz + float(tj) * tstep + WorldGen.hash_range(
			d.coord.x * 977 + ti, d.coord.y * 977 + tj, 22, 0.25, tstep - 0.25)
		var bh: float = field.h(bx, bz)
		var td: float = gen.tree_density_at(bx, bz, bh)
		if td <= 0.01:
			continue
		var roll: float = WorldGen.hash_f(int(bx * 2.0), int(bz * 2.0), 23)
		if roll > td:
			continue
		if field.slope(bx, bz) > 0.55:
			continue
		var yaw2: float = WorldGen.hash_range(int(bx), int(bz), 24, 0.0, TAU)
		var sc: float = WorldGen.hash_range(int(bx), int(bz), 25, 0.72, 1.55)
		var wind: float = WorldGen.hash_f(int(bx), int(bz), 26)
		var m: float = gen.moisture(bx, bz)
		var rl: float = gen.redline_factor(bx, bz)
		var lp := Vector3(bx - ox, bh, bz - oz)
		var vscale := Vector3(sc, sc * WorldGen.hash_range(int(bx), int(bz), 27, 0.82, 1.3), sc)
		# Per-instance hue drift so a forest is not one repeated green.
		var hue: float = WorldGen.hash_range(int(bx), int(bz), 34, 0.82, 1.18)
		var leaf_col := Color(hue * 0.95, hue, hue * 0.88, 1.0)

		if rl > 0.45 and WorldGen.hash_f(int(bx), int(bz), 28) < rl:
			dead.add_simple(lp, yaw2, vscale, Color(0.85, 0.8, 0.76), Color(wind, 0, 0, 0))
		elif m > 0.62 and WorldGen.hash_f(int(bx), int(bz), 35) < 0.35:
			birch.add_simple(lp, yaw2, vscale, leaf_col, Color(wind, 0, 0, 0))
		elif m > 0.5:
			broad.add_simple(lp, yaw2, vscale, leaf_col, Color(wind, 0, 0, 0))
		else:
			pine.add_simple(lp, yaw2, vscale,
				leaf_col * Color(0.92, 1.0, 0.9), Color(wind, 0, 0, 0))

		# Forest floor: undergrowth, deadfall and stumps around the trees.
		if td > 0.5 and richness > 0.3:
			for u in 3:
				var ux: float = bx + WorldGen.hash_range(int(bx), int(bz) + u, 29, -2.6, 2.6)
				var uz: float = bz + WorldGen.hash_range(int(bx) + u, int(bz), 30, -2.6, 2.6)
				var up := Vector3(ux - ox, field.h(ux, uz), uz - oz)
				var uyaw: float = WorldGen.hash_range(int(ux), int(uz), 31, 0.0, TAU)
				var usc: float = WorldGen.hash_range(int(ux), int(uz), 32, 0.55, 1.05)
				var ucustom := Color(WorldGen.hash_f(int(ux), int(uz), 33), 0, 0, 0)
				if WorldGen.hash_f(int(ux), int(uz), 36) < 0.45:
					fern.add_simple(up, uyaw, Vector3.ONE * usc,
						Color(0.95, 1.0, 0.9), ucustom)
				else:
					bush.add_simple(up, uyaw, Vector3.ONE * usc, leaf_col, ucustom)
			var deadfall: float = WorldGen.hash_f(int(bx), int(bz), 37)
			if deadfall < 0.08:
				logs.add_simple(lp, yaw2 + 1.1,
					Vector3.ONE * WorldGen.hash_range(int(bx), int(bz), 38, 0.7, 1.3),
					Color(0.9, 0.86, 0.8), Color(0.0, 0.0, 0.95, 0.0))
			elif deadfall < 0.13:
				stumps.add_simple(lp, yaw2,
					Vector3.ONE * WorldGen.hash_range(int(bx), int(bz), 39, 0.8, 1.25),
					Color(0.92, 0.88, 0.82), Color(0.0, 0.0, 0.9, 0.0))


# -----------------------------------------------------------------------------
# Buildings and roads
# -----------------------------------------------------------------------------
static func _build_structures(gen: WorldGen, d: ChunkData, opts: Dictionary,
		field: ChunkField) -> void:
	var ox: float = d.origin.x
	var oz: float = d.origin.z
	var variant: int = int(absi(d.coord.x * 31 + d.coord.y * 17))

	var mods: InstanceBatch = _batch(d, "building",
		PackedStringArray(["building_module"]), "building", true, variant)
	var caps: InstanceBatch = _batch(d, "building_cap",
		PackedStringArray(["building_cap"]), "building", true, variant)
	var roof: InstanceBatch = _batch(d, "roof_prop",
		PackedStringArray(["ac_unit"]), "prop", true, variant)
	var masts: InstanceBatch = _batch(d, "antenna",
		PackedStringArray(["antenna"]), "detail", false, variant)
	var signs: InstanceBatch = _batch(d, "sign",
		PackedStringArray(["sign"]), "prop", false, variant)
	var hoardings: InstanceBatch = _batch(d, "hoarding",
		PackedStringArray(["hoarding"]), "prop", true, variant)

	var cells: int = int(GameConfig.CHUNK_SIZE / BLOCK_CELL)
	var module_count: int = 0

	for cj in cells:
		for ci in cells:
			var cx: float = ox + (float(ci) + 0.5) * BLOCK_CELL
			var cz: float = oz + (float(cj) + 0.5) * BLOCK_CELL
			var chance: float = gen.building_chance(cx, cz)
			if chance <= 0.0:
				continue
			if WorldGen.hash_f(int(cx), int(cz), 41) > chance:
				continue
			# Footprints grow towards the cell edge as the area gets more
			# built-up. At a flat 6..12 m in a 16 m cell every building stood
			# alone in its own yard and the "dense city" read as a business
			# park; a real block is close to contiguous, with the gaps only
			# where the streets are.
			var u_here: float = gen.urban_factor(cx, cz)
			var foot_min: float = lerpf(6.0, 11.0, u_here)
			var foot_max: float = lerpf(BLOCK_CELL - 4.0, BLOCK_CELL - 1.4, u_here)
			var w: float = WorldGen.hash_range(int(cx), int(cz), 42, foot_min, foot_max)
			var dp: float = WorldGen.hash_range(int(cx), int(cz), 43, foot_min, foot_max)
			# Reject footprints that would sit on the carriageway.
			if (gen.on_road(cx - w * 0.5, cz) or gen.on_road(cx + w * 0.5, cz)
					or gen.on_road(cx, cz - dp * 0.5) or gen.on_road(cx, cz + dp * 0.5)):
				continue
			var zone: int = gen.zone_at(cx, cz)
			var rl: float = gen.redline_factor(cx, cz)
			var rng_h: Vector2 = gen.building_height_range(zone, rl)
			var floors: int = int(round(WorldGen.hash_range(
				int(cx), int(cz), 44, rng_h.x, rng_h.y)))
			if zone >= GameConfig.Zone.CITY and WorldGen.hash_f(int(cx), int(cz), 54) > 0.93:
				floors = int(float(floors) * 2.1)
			floors = clampi(floors, 1, 34)
			if module_count + floors + 1 > MAX_MODULES_PER_CHUNK:
				continue

			var base_y: float = field.h(cx, cz) - 0.4
			var seed_f: float = WorldGen.hash_f(int(cx), int(cz), 45)
			# Facade palette. A single grey ramp made every district the same
			# beige; picking a family per district and varying inside it gives
			# the skyline blocks of character without adding a draw call.
			var fam: int = WorldGen.hash_i(
				int(floor(cx / WorldGen.DISTRICT_SIZE)),
				int(floor(cz / WorldGen.DISTRICT_SIZE)), 67) % FACADE_PALETTE.size()
			var fam_col: Color = FACADE_PALETTE[fam]
			var lum: float = WorldGen.hash_range(int(cx), int(cz), 46, 0.74, 1.3)
			var drift: float = WorldGen.hash_range(int(cx), int(cz), 47, -0.05, 0.05)
			var col := Color(
				clampf(fam_col.r * lum + drift, 0.03, 0.95),
				clampf(fam_col.g * lum, 0.03, 0.95),
				clampf(fam_col.b * lum - drift, 0.03, 0.95), 1.0)
			if rl > 0.3:
				col = col.lerp(Color(0.22, 0.14, 0.13), rl * 0.7)

			# Podium: the lowest floors of a tall building step out. Without it
			# every tower is an unbroken extrusion and the street has no base.
			var podium: int = 0
			if floors >= 6:
				podium = 2 if WorldGen.hash_f(int(cx), int(cz), 55) < 0.6 else 3
			var podium_scale: float = WorldGen.hash_range(int(cx), int(cz), 56, 1.12, 1.3)

			for f in floors:
				# Slight setback on tall towers.
				var shrink: float = 1.0 - float(f) / float(maxi(floors, 1)) * 0.18
				if f < podium:
					shrink = podium_scale
				mods.add(
					Transform3D(
						Basis.IDENTITY.scaled(Vector3(w * shrink, FLOOR_HEIGHT, dp * shrink)),
						Vector3(cx - ox, base_y + float(f) * FLOOR_HEIGHT, cz - oz)
					),
					col, Color(seed_f, 0.0, 0.0, 0.0)
				)
				module_count += 1

			# Lit signage. Dense in the city, industrial and REDLINE bands;
			# absent in the settlement, where it would look wrong.
			if zone >= GameConfig.Zone.TOWN:
				var sign_count: int = 2 + int(WorldGen.hash_range(
					int(cx), int(cz), 57, 0.0, 3.4))
				for si in sign_count:
					if WorldGen.hash_f(int(cx) + si * 13, int(cz), 58) > 0.72:
						continue
					var face: int = WorldGen.hash_i(int(cx) + si, int(cz), 59) % 4
					var yaw_s: float = float(face) * PI * 0.5
					# Faces 0 and 2 look along Z, so they stand off by half the
					# footprint's *depth*; faces 1 and 3 by half its width.
					# Getting this the wrong way round buries the sign inside
					# the building whenever the footprint is not square.
					var half_extent: float = (dp if face % 2 == 0 else w) * 0.5
					var out_w: float = half_extent * podium_scale + 0.28
					var off := Vector3(sin(yaw_s) * out_w, 0.0, cos(yaw_s) * out_w)
					# Street level, roughly 3 to 9 m up. High signage reads as
					# texture on a distant skyline; signage the player walks
					# past is what makes a street feel occupied.
					var sy: float = base_y + WorldGen.hash_range(
						int(cx) + si, int(cz), 60, 3.0,
						minf(9.0, float(floors) * FLOOR_HEIGHT - 1.5))
					var neon: Color = NEON_COLORS[
						WorldGen.hash_i(int(cx) + si * 7, int(cz), 61) % NEON_COLORS.size()]
					signs.add_simple(
						Vector3(cx - ox + off.x, sy, cz - oz + off.z), yaw_s,
						Vector3.ONE * WorldGen.hash_range(int(cx) + si, int(cz), 62,
							0.7, 1.35),
						neon,
						# y = emission strength, w = use my own colour.
						Color(0.0, 1.0, 0.25, 1.0))

			if floors >= 7 and WorldGen.hash_f(int(cx), int(cz), 63) < 0.45:
				var hcol: Color = NEON_COLORS[
					WorldGen.hash_i(int(cx), int(cz), 64) % NEON_COLORS.size()]
				hoardings.add_simple(
					Vector3(cx - ox, base_y + float(floors) * FLOOR_HEIGHT + 1.0, cz - oz),
					WorldGen.hash_range(int(cx), int(cz), 65, 0.0, TAU),
					Vector3.ONE * WorldGen.hash_range(int(cx), int(cz), 66, 0.8, 1.4),
					hcol, Color(0.0, 0.9, 0.3, 1.0))

			var top_y: float = base_y + float(floors) * FLOOR_HEIGHT
			var tw: float = w * (1.0 - 0.18 + 0.18 / float(maxi(floors, 1)))
			caps.add(
				Transform3D(Basis.IDENTITY.scaled(Vector3(tw, 1.0, dp * 0.84)),
					Vector3(cx - ox, top_y, cz - oz)),
				col * 0.82, Color(seed_f, 0.0, 0.0, 0.0)
			)
			module_count += 1

			if floors >= 3:
				for a in 2:
					var ax: float = cx + WorldGen.hash_range(int(cx) + a, int(cz), 48,
						-w * 0.3, w * 0.3)
					var az: float = cz + WorldGen.hash_range(int(cx), int(cz) + a, 49,
						-dp * 0.3, dp * 0.3)
					roof.add_simple(Vector3(ax - ox, top_y + 0.5, az - oz),
						WorldGen.hash_range(int(ax), int(az), 50, 0.0, TAU),
						Vector3.ONE * WorldGen.hash_range(int(ax), int(az), 51, 0.7, 1.3),
						Color(0.55, 0.56, 0.58), Color(0.0, 0.0, 0.6, 0.0))
			if floors >= 8 and WorldGen.hash_f(int(cx), int(cz), 52) < 0.5:
				masts.add_simple(Vector3(cx - ox, top_y + 0.5, cz - oz), 0.0,
					Vector3.ONE * WorldGen.hash_range(int(cx), int(cz), 53, 0.7, 1.4),
					Color(0.6, 0.61, 0.63), Color(0.0, 0.35, 0.4, 0.0))

			d.destructible_spots.push_back(Vector3(cx, base_y, cz))

	# --- Road furniture -------------------------------------------------------
	var urban: float = gen.urban_factor(d.center.x, d.center.z)
	if urban < 0.06:
		return
	var lamps: InstanceBatch = _batch(d, "streetlight",
		PackedStringArray(["streetlight"]), "prop", true, variant)
	var marks: InstanceBatch = _batch(d, "road_mark",
		PackedStringArray(["road_mark"]), "detail", false, variant)
	var bollards: InstanceBatch = _batch(d, "bollard",
		PackedStringArray(["bollard"]), "detail", false, variant)
	# Kerb and footway define where the carriageway ends. Without them the road
	# is just a differently tinted patch of the same ground plane and the city
	# reads as boxes standing on an open field.
	var kerbs: InstanceBatch = _batch(d, "kerb",
		PackedStringArray(["kerb"]), "prop", false, variant)
	var footways: InstanceBatch = _batch(d, "footway",
		PackedStringArray(["footway"]), "prop", false, variant)
	var steps: int = int(GameConfig.CHUNK_SIZE / 8.0)
	for s in steps:
		var t: float = (float(s) + 0.5) * 8.0
		for axis in 2:
			var px: float = ox + (t if axis == 0 else 0.0)
			var pz: float = oz + (0.0 if axis == 0 else t)
			var rp: Vector3 = gen.nearest_road_point(
				px if axis == 0 else d.center.x, pz if axis == 1 else d.center.z)
			if axis == 0:
				rp = Vector3(ox + t, 0.0, rp.z)
			else:
				rp = Vector3(rp.x, 0.0, oz + t)
			if rp.x < ox or rp.x >= ox + GameConfig.CHUNK_SIZE:
				continue
			if rp.z < oz or rp.z >= oz + GameConfig.CHUNK_SIZE:
				continue
			if not gen.on_road(rp.x, rp.z):
				continue
			var y: float = field.h(rp.x, rp.z)

			# Kerb line, skipped through an intersection so the two
			# carriageways join instead of being walled off from each other.
			var across: bool = (gen.on_road(rp.x, rp.z + WorldGen.ROAD_HALF_WIDTH + 2.0)
				if axis == 0
				else gen.on_road(rp.x + WorldGen.ROAD_HALF_WIDTH + 2.0, rp.z))
			if not across:
				for ki in 2:
					var ks: float = 1.0 if ki == 0 else -1.0
					var kyaw: float = (0.0 if axis == 0 else PI * 0.5) \
						+ (0.0 if ks > 0.0 else PI)
					var kx: float = rp.x + (0.0 if axis == 0
						else ks * WorldGen.ROAD_HALF_WIDTH)
					var kz: float = rp.z + (ks * WorldGen.ROAD_HALF_WIDTH
						if axis == 0 else 0.0)
					if kx < ox or kx >= ox + GameConfig.CHUNK_SIZE:
						continue
					if kz < oz or kz >= oz + GameConfig.CHUNK_SIZE:
						continue
					var ky: float = field.h(kx, kz)
					kerbs.add_simple(Vector3(kx - ox, ky, kz - oz), kyaw,
						Vector3.ONE, Color(0.78, 0.77, 0.75),
						Color(0.0, 0.0, 0.65, 0.0))
					footways.add_simple(Vector3(kx - ox, ky, kz - oz), kyaw,
						Vector3.ONE, Color(0.74, 0.735, 0.72),
						Color(0.0, 0.0, 0.7, 0.0))

			if s % 3 == 0:
				var side: float = 1.0 if (s % 6 == 0) else -1.0
				var lx: float = rp.x + (0.0 if axis == 0 else side * 7.2)
				var lz: float = rp.z + (side * 7.2 if axis == 0 else 0.0)
				lamps.add_simple(Vector3(lx - ox, field.h(lx, lz), lz - oz),
					(0.0 if axis == 0 else PI * 0.5) + (0.0 if side > 0.0 else PI),
					Vector3.ONE, Color(0.3, 0.31, 0.33), Color(0.0, 0.0, 0.35, 0.0))
				d.light_spots.push_back(Vector3(lx, field.h(lx, lz) + 6.0, lz))
			if true:
				marks.add_simple(Vector3(rp.x - ox, y + 0.04, rp.z - oz),
					0.0 if axis == 0 else PI * 0.5, Vector3.ONE,
					Color(0.85, 0.82, 0.6), Color(0.0, 0.08, 0.7, 0.0))
			if urban > 0.45:
				for side_i in 2:
					var bs: float = 1.0 if side_i == 0 else -1.0
					var bx: float = rp.x + (0.0 if axis == 0 else bs * 7.0)
					var bz: float = rp.z + (bs * 7.0 if axis == 0 else 0.0)
					if bx < ox or bx >= ox + GameConfig.CHUNK_SIZE:
						continue
					if bz < oz or bz >= oz + GameConfig.CHUNK_SIZE:
						continue
					bollards.add_simple(
						Vector3(bx - ox, field.h(bx, bz), bz - oz), 0.0, Vector3.ONE,
						Color(0.34, 0.35, 0.37), Color(0.0, 0.05, 0.55, 0.0))


# -----------------------------------------------------------------------------
# Props
# -----------------------------------------------------------------------------
static func _scatter_props(gen: WorldGen, d: ChunkData, opts: Dictionary,
		field: ChunkField) -> void:
	var richness: float = float(opts.get("prop_richness", 1.0))
	var ox: float = d.origin.x
	var oz: float = d.origin.z
	var variant: int = int(absi(d.coord.x * 13 + d.coord.y * 7))

	var rocks: InstanceBatch = _batch(d, "rock",
		PackedStringArray(["rock_l0", "rock_l1"]), "prop", true, variant)
	var boulders: InstanceBatch = _batch(d, "boulder",
		PackedStringArray(["boulder"]), "prop", true, variant)
	var outcrops: InstanceBatch = _batch(d, "outcrop",
		PackedStringArray(["outcrop0", "outcrop1"]), "prop", true)
	var crates: InstanceBatch = _batch(d, "crate",
		PackedStringArray(["crate"]), "prop", true, variant)
	var barrels: InstanceBatch = _batch(d, "barrel",
		PackedStringArray(["barrel"]), "prop", true, variant)
	var rubble: InstanceBatch = _batch(d, "rubble",
		PackedStringArray(["rubble"]), "prop", false, variant)
	var wrecks: InstanceBatch = _batch(d, "wreck",
		PackedStringArray(["wreck"]), "prop", true, variant)
	var containers: InstanceBatch = _batch(d, "container",
		PackedStringArray(["container"]), "prop", true, variant)
	var tanks: InstanceBatch = _batch(d, "tank",
		PackedStringArray(["tank"]), "prop", true, variant)
	var pipes: InstanceBatch = _batch(d, "pipe",
		PackedStringArray(["pipe"]), "prop", true, variant)
	var fences: InstanceBatch = _batch(d, "fence",
		PackedStringArray(["fence"]), "detail", false, variant)

	var step: float = 6.0
	var side: int = int(GameConfig.CHUNK_SIZE / step)
	var total: int = side * side
	for k in total:
		var pi: int = _permuted(k, total)
		var i: int = pi % side
		var j: int = pi / side
		var wx: float = ox + (float(i) + WorldGen.hash_f(
			d.coord.x * 61 + i, d.coord.y * 61 + j, 61)) * step
		var wz: float = oz + (float(j) + WorldGen.hash_f(
			d.coord.x * 67 + i, d.coord.y * 67 + j, 62)) * step
		var h: float = field.h(wx, wz)
		if h < GameConfig.WATER_LEVEL:
			continue
		var zone: int = gen.zone_at(wx, wz)
		var u: float = gen.urban_factor(wx, wz)
		var rl: float = gen.redline_factor(wx, wz)
		var roll: float = WorldGen.hash_f(int(wx), int(wz), 63)
		var yaw: float = WorldGen.hash_range(int(wx), int(wz), 64, 0.0, TAU)
		var lp := Vector3(wx - ox, h, wz - oz)
		var on_rd: bool = gen.on_road(wx, wz)

		if on_rd:
			continue

		# Steep ground gets rock formations. Trees already refuse slopes above
		# 0.55, so without this the steepest terrain is the emptiest.
		var slope: float = field.slope(wx, wz)
		if slope > 0.34 and zone <= GameConfig.Zone.INDUSTRIAL:
			if WorldGen.hash_f(int(wx), int(wz), 72) < (slope - 0.34) * 1.9 * richness:
				outcrops.add_simple(lp, yaw,
					Vector3.ONE * WorldGen.hash_range(int(wx), int(wz), 73, 0.65, 1.9),
					Color(0.92, 0.94, 0.96), Color(0.0, 0.0, 0.88, 0.0))
				continue

		if zone <= GameConfig.Zone.FOREST:
			if roll < 0.055 * richness:
				rocks.add_simple(lp, yaw,
					Vector3.ONE * WorldGen.hash_range(int(wx), int(wz), 65, 0.5, 1.6),
					Color(0.55, 0.54, 0.52), Color(0.0, 0.0, 0.85, 0.0))
			elif roll < 0.066 * richness:
				boulders.add_simple(lp, yaw,
					Vector3.ONE * WorldGen.hash_range(int(wx), int(wz), 66, 0.7, 1.5),
					Color(0.5, 0.49, 0.48), Color(0.0, 0.0, 0.9, 0.0))
		else:
			if roll < 0.06 * richness * u:
				crates.add_simple(lp, yaw, Vector3.ONE,
					Color(0.62, 0.46, 0.28), Color(0.0, 0.0, 0.75, 0.0))
				d.destructible_spots.push_back(Vector3(wx, h, wz))
			elif roll < 0.10 * richness * u:
				barrels.add_simple(lp, yaw, Vector3.ONE,
					Color(0.6 + rl * 0.3, 0.32, 0.18), Color(0.0, rl * 0.35, 0.6, 0.0))
			elif roll < 0.14 * richness * u and zone >= GameConfig.Zone.TOWN:
				wrecks.add_simple(lp, yaw, Vector3.ONE,
					Color(0.30, 0.26, 0.24), Color(0.0, 0.0, 0.8, 0.0))
			elif roll < 0.20 * richness and rl > 0.2:
				rubble.add_simple(lp, yaw,
					Vector3.ONE * WorldGen.hash_range(int(wx), int(wz), 67, 0.7, 1.7),
					Color(0.36, 0.33, 0.31), Color(0.0, 0.0, 0.95, 0.0))

		if zone == GameConfig.Zone.INDUSTRIAL or (zone == GameConfig.Zone.REDLINE and u > 0.4):
			if roll > 0.86:
				containers.add_simple(lp, yaw, Vector3.ONE,
					Color(WorldGen.hash_range(int(wx), int(wz), 68, 0.2, 0.8),
						WorldGen.hash_range(int(wx), int(wz), 69, 0.2, 0.6),
						WorldGen.hash_range(int(wx), int(wz), 70, 0.2, 0.5), 1.0),
					Color(0.0, 0.0, 0.7, 0.0))
			elif roll > 0.80:
				tanks.add_simple(lp, yaw,
					Vector3.ONE * WorldGen.hash_range(int(wx), int(wz), 71, 0.8, 1.4),
					Color(0.6, 0.58, 0.54), Color(0.0, 0.05, 0.45, 0.0))
			elif roll > 0.72:
				pipes.add_simple(lp, yaw, Vector3.ONE,
					Color(0.46, 0.43, 0.39), Color(0.0, 0.0, 0.55, 0.0))
			elif roll > 0.62:
				fences.add_simple(lp, yaw, Vector3.ONE,
					Color(0.32, 0.33, 0.35), Color(0.0, 0.0, 0.6, 0.0))


# -----------------------------------------------------------------------------
# Gameplay seeds
# -----------------------------------------------------------------------------
static func _place_spawns(gen: WorldGen, d: ChunkData, opts: Dictionary,
		field: ChunkField) -> void:
	var ox: float = d.origin.x
	var oz: float = d.origin.z
	var zone: int = d.zone
	var u: float = gen.urban_factor(d.center.x, d.center.z)

	# NPCs favour streets and settlement edges.
	var npc_target: int = [0, 1, 3, 6, 9, 7, 5][clampi(zone, 0, 6)]
	for i in npc_target:
		var px: float = ox + WorldGen.hash_range(d.coord.x, d.coord.y + i, 81, 4.0,
			GameConfig.CHUNK_SIZE - 4.0)
		var pz: float = oz + WorldGen.hash_range(d.coord.x + i, d.coord.y, 82, 4.0,
			GameConfig.CHUNK_SIZE - 4.0)
		# In a built-up area a free scatter puts most of them inside a building
		# shell, because that is what most of the area is. Put them on the
		# footway instead, which is where a pedestrian would be and where the
		# player will actually see them.
		if u > 0.25:
			var nrp: Vector3 = gen.nearest_road_point(px, pz)
			var side: float = 1.0 if WorldGen.hash_f(
				d.coord.x + i * 5, d.coord.y + i, 91) < 0.5 else -1.0
			var walk: float = side * WorldGen.hash_range(
				d.coord.x + i, d.coord.y + i * 3, 92,
				WorldGen.ROAD_HALF_WIDTH + 0.9, WorldGen.ROAD_HALF_WIDTH + 2.8)
			if absf(nrp.x - px) < absf(nrp.z - pz):
				px = nrp.x + walk           # road runs along Z
			else:
				pz = nrp.z + walk           # road runs along X
		px = clampf(px, ox + 1.0, ox + GameConfig.CHUNK_SIZE - 1.0)
		pz = clampf(pz, oz + 1.0, oz + GameConfig.CHUNK_SIZE - 1.0)
		var h: float = field.h(px, pz)
		if h < GameConfig.WATER_LEVEL + 0.5:
			continue
		d.npc_spawns.push_back(Vector3(px, h, pz))

	# Enemies scale with depth and avoid the immediate spawn area.
	var r: float = Vector2(d.center.x, d.center.z).length()
	if r > 120.0:
		var enemy_target: int = [1, 2, 2, 3, 5, 7, 10][clampi(zone, 0, 6)]
		for i in enemy_target:
			var ex: float = ox + WorldGen.hash_range(d.coord.x + i * 3, d.coord.y, 83, 3.0,
				GameConfig.CHUNK_SIZE - 3.0)
			var ez: float = oz + WorldGen.hash_range(d.coord.x, d.coord.y + i * 3, 84, 3.0,
				GameConfig.CHUNK_SIZE - 3.0)
			var eh: float = field.h(ex, ez)
			if eh < GameConfig.WATER_LEVEL + 0.5:
				continue
			d.enemy_spawns.push_back(Vector3(ex, eh, ez))

	# Vehicles sit on the carriageway.
	if u > 0.12:
		for i in 4:
			var vx: float = ox + WorldGen.hash_range(d.coord.x + i, d.coord.y, 85, 2.0,
				GameConfig.CHUNK_SIZE - 2.0)
			var vz: float = oz + WorldGen.hash_range(d.coord.x, d.coord.y + i, 86, 2.0,
				GameConfig.CHUNK_SIZE - 2.0)
			var rp: Vector3 = gen.nearest_road_point(vx, vz)
			if rp.x < ox or rp.x > ox + GameConfig.CHUNK_SIZE:
				continue
			if rp.z < oz or rp.z > oz + GameConfig.CHUNK_SIZE:
				continue
			# Sit in a lane rather than straddling the centreline.
			var lane: float = (1.0 if WorldGen.hash_f(
				d.coord.x + i * 3, d.coord.y + i, 93) < 0.5 else -1.0) * 2.8
			if absf(rp.x - vx) < absf(rp.z - vz):
				rp.x += lane                # road runs along Z
			else:
				rp.z += lane                # road runs along X
			d.vehicle_spawns.push_back(Vector3(rp.x, field.h(rp.x, rp.z), rp.z))

	# Scavenge.
	var pickup_rolls: int = 3
	for i in pickup_rolls:
		var roll: float = WorldGen.hash_f(d.coord.x * 7 + i, d.coord.y * 11, 87)
		if roll > 0.42:
			continue
		var px2: float = ox + WorldGen.hash_range(d.coord.x + i * 5, d.coord.y, 88, 3.0,
			GameConfig.CHUNK_SIZE - 3.0)
		var pz2: float = oz + WorldGen.hash_range(d.coord.x, d.coord.y + i * 5, 89, 3.0,
			GameConfig.CHUNK_SIZE - 3.0)
		var ph: float = field.h(px2, pz2)
		if ph < GameConfig.WATER_LEVEL + 0.4:
			continue
		var kind: String = "scrap"
		var amount: int = 1
		var pick: float = WorldGen.hash_f(d.coord.x + i, d.coord.y + i, 90)
		if zone >= GameConfig.Zone.CITY and pick > 0.86:
			kind = "core"
		elif pick > 0.72:
			kind = "medkit"
		elif pick > 0.55:
			kind = "ammo"
			amount = 20 + int(pick * 40.0)
		elif pick > 0.38:
			kind = "ration"
		elif pick > 0.2:
			kind = "cell"
		else:
			amount = 2 + int(pick * 12.0)
		d.pickups.append({"pos": Vector3(px2, ph, pz2), "id": kind, "amount": amount})
