class_name WorldGen
extends RefCounted
## Deterministic procedural world function. Everything about a location -- its
## height, biome, road coverage, building footprints, vegetation density --
## derives from the world seed and the coordinate alone, so any chunk can be
## regenerated identically at any time, on any thread, in any order.
##
## Sampling only reads the FastNoiseLite instances, so one WorldGen may be
## shared by every streaming worker thread.

const ROAD_SPACING: float = 128.0
const ROAD_HALF_WIDTH: float = 6.0
const ROAD_SHOULDER: float = 4.0
const DISTRICT_SIZE: float = 128.0

var world_seed: int = 0

var n_base: FastNoiseLite
var n_hill: FastNoiseLite
var n_ridge: FastNoiseLite
var n_warp: FastNoiseLite
var n_moist: FastNoiseLite
var n_district: FastNoiseLite
var n_scatter: FastNoiseLite
var n_bump: FastNoiseLite


func _init(seed_value: int) -> void:
	world_seed = seed_value
	n_base = _mk(seed_value + 1, 0.0016, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 4, 0.5, 2.1)
	n_hill = _mk(seed_value + 2, 0.0062, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 3, 0.48, 2.2)
	n_ridge = _mk(seed_value + 3, 0.0031, FastNoiseLite.TYPE_SIMPLEX, 3, 0.55, 2.3)
	n_warp = _mk(seed_value + 4, 0.0009, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 1, 0.5, 2.0)
	n_moist = _mk(seed_value + 5, 0.0021, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 3, 0.5, 2.0)
	n_district = _mk(seed_value + 6, 0.0035, FastNoiseLite.TYPE_CELLULAR, 1, 0.5, 2.0)
	n_district.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	n_district.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	n_scatter = _mk(seed_value + 7, 0.045, FastNoiseLite.TYPE_SIMPLEX, 2, 0.5, 2.0)
	# Metre-scale relief. Without it the terrain is a set of smooth domes and
	# nothing in the near field has any shape.
	n_bump = _mk(seed_value + 8, 0.021, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 3, 0.45, 2.4)


func _mk(s: int, freq: float, t: int, oct: int, gain: float, lac: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = s
	n.frequency = freq
	n.noise_type = t as FastNoiseLite.NoiseType
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = oct
	n.fractal_gain = gain
	n.fractal_lacunarity = lac
	return n


# -----------------------------------------------------------------------------
# Deterministic hashing (no RNG state, safe from any thread)
# -----------------------------------------------------------------------------
static func hash_i(a: int, b: int, salt: int) -> int:
	var h: int = a * 374761393 + b * 668265263 + salt * 2147483647
	h = (h ^ (h >> 13)) * 1274126177
	return absi(h ^ (h >> 16))


static func hash_f(a: int, b: int, salt: int) -> float:
	return float(hash_i(a, b, salt) % 1000000) / 1000000.0


static func hash_range(a: int, b: int, salt: int, lo: float, hi: float) -> float:
	return lo + (hi - lo) * hash_f(a, b, salt)


# -----------------------------------------------------------------------------
# Zones
# -----------------------------------------------------------------------------
func radius_at(x: float, z: float) -> float:
	return sqrt(x * x + z * z)


func zone_at(x: float, z: float) -> int:
	return GameConfig.zone_for_radius(radius_at(x, z))


## 0 in wilderness, 1 in fully built-up zones. Drives flattening, roads and
## building placement.
func urban_factor(x: float, z: float) -> float:
	var r: float = radius_at(x, z)
	var start: float = GameConfig.ZONE_RADII[1]          # end of forest
	var full: float = GameConfig.ZONE_RADII[3]           # end of town
	var t: float = clampf((r - start) / maxf(1.0, full - start), 0.0, 1.0)
	# Irregular district edges so the city does not look like a perfect ring.
	var jitter: float = n_warp.get_noise_2d(x * 0.35, z * 0.35) * 0.22
	return clampf(t + jitter, 0.0, 1.0)


func redline_factor(x: float, z: float) -> float:
	var r: float = radius_at(x, z)
	var start: float = GameConfig.ZONE_RADII[4]
	return clampf((r - start) / 900.0, 0.0, 1.0)


# -----------------------------------------------------------------------------
# Terrain
# -----------------------------------------------------------------------------
## Large-scale plateau the urban grid is built on. Sampled at district centres
## so roads and foundations sit on a common level, then blended between
## neighbouring districts.
##
## This *must* stay continuous: a hard `floor()` quantisation puts a vertical
## step in the terrain at every district boundary, which shows up as a seam in
## the mesh and as an unclimbable wall in the collision trimesh.
func district_height(x: float, z: float) -> float:
	var fx: float = x / DISTRICT_SIZE - 0.5
	var fz: float = z / DISTRICT_SIZE - 0.5
	var i0: float = floor(fx)
	var j0: float = floor(fz)
	var tx: float = smoothstep(0.0, 1.0, fx - i0)
	var tz: float = smoothstep(0.0, 1.0, fz - j0)
	var h00: float = _district_sample(i0, j0)
	var h10: float = _district_sample(i0 + 1.0, j0)
	var h01: float = _district_sample(i0, j0 + 1.0)
	var h11: float = _district_sample(i0 + 1.0, j0 + 1.0)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func _district_sample(i: float, j: float) -> float:
	var cx: float = (i + 0.5) * DISTRICT_SIZE
	var cz: float = (j + 0.5) * DISTRICT_SIZE
	return n_base.get_noise_2d(cx, cz) * 16.0 + 4.0


func height(x: float, z: float) -> float:
	return height_u(x, z, urban_factor(x, z))


## Height with the urbanisation factor supplied by the caller. Chunk generation
## samples `urban_factor` once per vertex and reuses it for both the height and
## the biome tint, which removes several noise evaluations per vertex.
func height_u(x: float, z: float, u: float) -> float:
	var wx: float = x + n_warp.get_noise_2d(x, z) * 60.0
	var wz: float = z + n_warp.get_noise_2d(x + 917.0, z - 311.0) * 60.0

	var base: float = n_base.get_noise_2d(wx, wz)
	var hill: float = n_hill.get_noise_2d(wx, wz)
	var ridge: float = 1.0 - absf(n_ridge.get_noise_2d(wx, wz))
	ridge = ridge * ridge

	var r: float = radius_at(x, z)
	# Mountains belong to the outer wilderness/forest rim, not the city.
	var relief: float = 1.0 - u
	var h: float = base * GameConfig.TERRAIN_AMPLITUDE
	h += hill * 11.0 * relief
	h += ridge * 26.0 * relief * clampf(r / 800.0, 0.15, 1.0)
	h += n_bump.get_noise_2d(x, z) * 2.6 * relief

	if u > 0.001:
		var plateau: float = district_height(x, z)
		h = lerpf(h, plateau, smoothstep(0.0, 1.0, u) * 0.92)
		# Roads carve a flat shoulder through whatever is left.
		var rm: float = road_proximity(x, z)
		if rm > 0.0 and u > 0.05:
			h = lerpf(h, plateau + 0.15, rm * u)

	return h


func height_normal(x: float, z: float, e: float = 1.0) -> Vector3:
	var hl: float = height(x - e, z)
	var hr: float = height(x + e, z)
	var hd: float = height(x, z - e)
	var hu: float = height(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


func slope_at(x: float, z: float) -> float:
	return 1.0 - clampf(height_normal(x, z).y, 0.0, 1.0)


# -----------------------------------------------------------------------------
# Roads
# -----------------------------------------------------------------------------
## 1.0 on the carriageway, falling to 0 across the shoulder.
func road_proximity(x: float, z: float) -> float:
	var dx: float = absf(fposmod(x + ROAD_SPACING * 0.5, ROAD_SPACING) - ROAD_SPACING * 0.5)
	var dz: float = absf(fposmod(z + ROAD_SPACING * 0.5, ROAD_SPACING) - ROAD_SPACING * 0.5)
	var d: float = minf(dx, dz)
	var edge: float = ROAD_HALF_WIDTH + ROAD_SHOULDER
	return 1.0 - smoothstep(ROAD_HALF_WIDTH, edge, d)


func on_road(x: float, z: float) -> bool:
	var dx: float = absf(fposmod(x + ROAD_SPACING * 0.5, ROAD_SPACING) - ROAD_SPACING * 0.5)
	var dz: float = absf(fposmod(z + ROAD_SPACING * 0.5, ROAD_SPACING) - ROAD_SPACING * 0.5)
	return minf(dx, dz) <= ROAD_HALF_WIDTH


## Snaps a world position onto the nearest road centreline. Used by traffic.
func nearest_road_point(x: float, z: float) -> Vector3:
	var gx: float = round(x / ROAD_SPACING) * ROAD_SPACING
	var gz: float = round(z / ROAD_SPACING) * ROAD_SPACING
	if absf(x - gx) < absf(z - gz):
		return Vector3(gx, height(gx, z), z)
	return Vector3(x, height(x, gz), gz)


# -----------------------------------------------------------------------------
# Biome / colour
# -----------------------------------------------------------------------------
func moisture(x: float, z: float) -> float:
	return n_moist.get_noise_2d(x, z) * 0.5 + 0.5


## Vertex tint handed to the terrain shader. Keeping biome colour in the mesh
## means one terrain material covers the whole world.
func terrain_color(x: float, z: float, h: float) -> Color:
	return terrain_color_u(x, z, h, urban_factor(x, z))


func terrain_color_u(x: float, z: float, h: float, u: float) -> Color:
	var m: float = moisture(x, z)
	var rl: float = redline_factor(x, z)

	var dry := Color(0.33, 0.29, 0.15)
	var lush := Color(0.09, 0.23, 0.08)
	var alpine := Color(0.28, 0.29, 0.27)
	var c: Color = dry.lerp(lush, smoothstep(0.15, 0.85, m))
	# Metre-scale patchiness: bare earth showing through the sward.
	var patch: float = n_bump.get_noise_2d(x * 0.5, z * 0.5) * 0.5 + 0.5
	c = c.lerp(Color(0.26, 0.20, 0.13), clampf((patch - 0.62) * 2.2, 0.0, 1.0) * 0.5)

	if h > 30.0:
		c = c.lerp(alpine, clampf((h - 30.0) / 28.0, 0.0, 1.0))
	if h < GameConfig.WATER_LEVEL + 2.0:
		c = c.lerp(Color(0.36, 0.32, 0.22), 0.6)

	# Urban ground: concrete and asphalt.
	var urban := Color(0.17, 0.17, 0.185)
	c = c.lerp(urban, u * 0.8)
	if on_road(x, z) and u > 0.15:
		c = c.lerp(Color(0.095, 0.095, 0.105), u)

	# REDLINE zones are scorched.
	c = c.lerp(Color(0.15, 0.08, 0.07), rl * 0.75)
	return c


# -----------------------------------------------------------------------------
# Density fields
# -----------------------------------------------------------------------------
## Trees per hectare-ish factor, 0..1.
func tree_density(x: float, z: float) -> float:
	return tree_density_at(x, z, height(x, z))


## Height-provided variant. Chunk generation samples the height once into a
## grid and reuses it here, which removes the dominant cost of world building.
func tree_density_at(x: float, z: float, h: float) -> float:
	var zone: int = zone_at(x, z)
	var m: float = moisture(x, z)
	var u: float = urban_factor(x, z)
	if h < GameConfig.WATER_LEVEL + 0.5:
		return 0.0
	var base: float = 0.0
	match zone:
		GameConfig.Zone.WILDERNESS:
			base = 0.26 + m * 0.42
		GameConfig.Zone.FOREST:
			base = 1.25 + m * 0.85
		GameConfig.Zone.SETTLEMENT:
			base = 0.45 + m * 0.3
		GameConfig.Zone.TOWN:
			base = 0.16
		GameConfig.Zone.CITY:
			base = 0.07
		GameConfig.Zone.INDUSTRIAL:
			base = 0.04
		_:
			base = 0.02
	var clumping: float = n_scatter.get_noise_2d(x * 0.25, z * 0.25) * 0.5 + 0.5
	return clampf(base * (0.45 + clumping) * (1.0 - u * 0.85), 0.0, 1.6)


func grass_density(x: float, z: float) -> float:
	return grass_density_at(x, z, height(x, z), slope_at(x, z))


func grass_density_at(x: float, z: float, h: float, s: float) -> float:
	if h < GameConfig.WATER_LEVEL + 0.3:
		return 0.0
	var u: float = urban_factor(x, z)
	var m: float = moisture(x, z)
	return clampf((0.35 + m * 0.8) * (1.0 - u * 0.9) * (1.0 - s * 1.4), 0.0, 1.4)


## Probability that a given block cell holds a building.
func building_chance(x: float, z: float) -> float:
	var zone: int = zone_at(x, z)
	var u: float = urban_factor(x, z)
	if u < 0.08:
		return 0.0
	match zone:
		GameConfig.Zone.SETTLEMENT:
			return 0.28 * u
		GameConfig.Zone.TOWN:
			return 0.58 * u
		GameConfig.Zone.CITY:
			return 0.88
		GameConfig.Zone.INDUSTRIAL:
			return 0.74
		GameConfig.Zone.REDLINE:
			return 0.80
		_:
			return 0.0


func building_height_range(zone: int, rl: float) -> Vector2:
	match zone:
		GameConfig.Zone.SETTLEMENT:
			return Vector2(1.0, 2.0)
		GameConfig.Zone.TOWN:
			return Vector2(2.0, 6.0)
		GameConfig.Zone.CITY:
			# 16 m block cells cannot carry 75 m towers without turning every
			# street into an unlit canyon.
			return Vector2(3.0, 15.0 + rl * 7.0)
		GameConfig.Zone.INDUSTRIAL:
			return Vector2(2.0, 9.0)
		GameConfig.Zone.REDLINE:
			return Vector2(2.0, 13.0)
		_:
			return Vector2(1.0, 1.0)
