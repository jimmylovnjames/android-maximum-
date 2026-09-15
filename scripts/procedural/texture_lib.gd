class_name TextureLib
extends RefCounted
## Generates every texture the game uses at runtime. No asset packs, no
## downloads. Resolution and variant count scale with the quality preset, so
## higher presets genuinely increase texture residency instead of faking it.

const BASE_SIZES: PackedInt32Array = [128, 256, 512, 1024, 1024]
const VARIANTS: PackedInt32Array = [1, 2, 3, 5, 8]


static func size_for_preset(preset: int) -> int:
	return BASE_SIZES[clampi(preset, 0, BASE_SIZES.size() - 1)]


static func variants_for_preset(preset: int) -> int:
	return VARIANTS[clampi(preset, 0, VARIANTS.size() - 1)]


static func make_noise(seed_value: int, frequency: float, type: int,
		fractal_octaves: int = 4) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.frequency = frequency
	n.noise_type = type as FastNoiseLite.NoiseType
	n.fractal_octaves = clampi(fractal_octaves, 1, 8)
	return n


static func noise_texture(seed_value: int, size: int, frequency: float,
		seamless: bool = true, normal_map: bool = false,
		octaves: int = 4) -> NoiseTexture2D:
	var t := NoiseTexture2D.new()
	t.width = size
	t.height = size
	t.seamless = seamless
	t.generate_mipmaps = true
	t.as_normal_map = normal_map
	if normal_map:
		t.bump_strength = 2.2
	t.noise = make_noise(seed_value, frequency, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, octaves)
	return t


## Colour-ramped noise: cheap way to get "concrete", "rust", "bark" etc.
static func ramped_noise_texture(seed_value: int, size: int, frequency: float,
		c0: Color, c1: Color, octaves: int = 4) -> NoiseTexture2D:
	var t: NoiseTexture2D = noise_texture(seed_value, size, frequency, true, false, octaves)
	var g := Gradient.new()
	g.set_color(0, c0)
	g.set_color(1, c1)
	t.color_ramp = g
	return t


## Small hand-generated alpha masks. These loops are intentionally tiny
## (<= 16k pixels) so generation stays under a millisecond on mobile.
static func grass_blade_mask(size_x: int = 64, size_y: int = 128,
		seed_value: int = 1) -> ImageTexture:
	var img: Image = Image.create(size_x, size_y, true, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	# Coverage matters more than blade count: an alpha-tested card whose mask
	# is mostly transparent loses its remaining alpha to mipmapping and simply
	# disappears a few metres from the camera.
	var blades: int = 13
	for b in blades:
		var cx: float = rng.randf_range(0.06, 0.94) * float(size_x)
		var w: float = rng.randf_range(0.07, 0.13) * float(size_x)
		var lean: float = rng.randf_range(-0.26, 0.26) * float(size_x)
		var top: float = rng.randf_range(0.02, 0.34) * float(size_y)
		var shade: float = rng.randf_range(0.68, 1.0)
		for y in range(int(top), size_y):
			var t: float = float(y - top) / maxf(1.0, float(size_y) - top)
			var cw: float = w * (0.3 + 0.7 * t)
			var cxx: float = cx + lean * (1.0 - t)
			var x0: int = int(floor(cxx - cw))
			var x1: int = int(ceil(cxx + cw))
			for x in range(maxi(0, x0), mini(size_x, x1 + 1)):
				var v: float = shade * (0.6 + 0.4 * t)
				img.set_pixel(x, y, Color(v, v, v, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Silhouette used by the furthest tree LOD. Two crossed cards wearing this
## mask cost four triangles and read as a tree at a few hundred metres, which
## is what lets the forest reach the horizon instead of stopping at 300 m.
##
## `kind`: 0 conifer, 1 broadleaf, 2 bare/birch.
static func tree_impostor_mask(kind: int, size: int = 128,
		seed_value: int = 3) -> ImageTexture:
	var img: Image = Image.create(size, size, true, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 31 + kind
	var fs: float = float(size)
	var trunk_top: float = [0.80, 0.66, 0.55][clampi(kind, 0, 2)]
	var trunk_w: float = [0.035, 0.045, 0.030][clampi(kind, 0, 2)]

	# Canopy
	for y in size:
		var v: float = float(y) / fs                    # 0 top, 1 bottom
		if v > trunk_top:
			continue
		var half: float = 0.0
		if kind == 0:
			# Conifer: widening downward with a sawtooth edge per tier. The
			# proportions match the seven-tier LOD0 cone stack, so the swap at
			# 400 m does not change the tree's outline.
			var tiers: float = 7.0
			var tier_f: float = v * tiers - floor(v * tiers)
			half = pow(v / trunk_top, 0.72) * 0.48
			half *= 0.93 + 0.07 * tier_f                # jagged branch tips
		elif kind == 1:
			# Broadleaf: overlapping lobes around a round crown.
			var t2: float = (v / trunk_top - 0.48) * 2.0
			half = sqrt(maxf(0.0, 1.0 - t2 * t2)) * 0.49
			half *= 0.90 + 0.10 * sin(v * 26.0)
		else:
			# Birch: narrow, sparse, open crown.
			var t3: float = (v / trunk_top - 0.42) * 2.0
			half = sqrt(maxf(0.0, 1.0 - t3 * t3)) * 0.40
			half *= 0.84 + 0.16 * sin(v * 34.0 + 1.1)
		if half <= 0.002:
			continue
		var cx: float = 0.5 * fs
		var x0: int = int(floor(cx - half * fs))
		var x1: int = int(ceil(cx + half * fs))
		for x in range(maxi(0, x0), mini(size, x1 + 1)):
			var dx: float = absf((float(x) + 0.5 - cx) / maxf(half * fs, 0.001))
			if dx > 1.0:
				continue
			# Ragged rim so the silhouette does not read as a solid cutout.
			# Kept to the outermost tenth: any more and the whole tree thins
			# out under mipmapping and disappears at range.
			if dx > 0.90 and rng.randf() < (dx - 0.90) * 5.0:
				continue
			# Darker at the base and toward the centre: matches the ambient
			# occlusion baked into the close-range canopies.
			var shade: float = (0.55 + 0.45 * (1.0 - v / trunk_top)) * (0.82 + 0.18 * dx)
			img.set_pixel(x, y, Color(shade, shade, shade, 1.0))

	# Trunk
	var tw: int = maxi(1, int(trunk_w * fs))
	for y in range(int(trunk_top * fs * 0.72), size):
		var cx2: int = size / 2
		for x in range(cx2 - tw, cx2 + tw + 1):
			if x < 0 or x >= size:
				continue
			var sh: float = 0.30 if kind != 2 else 0.72
			img.set_pixel(x, y, Color(sh, sh, sh, 1.0))

	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func leaf_cluster_mask(size: int = 128, seed_value: int = 2) -> ImageTexture:
	var img: Image = Image.create(size, size, true, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var blobs: int = 14
	var centers: Array[Vector3] = []
	for i in blobs:
		centers.append(Vector3(
			rng.randf_range(0.18, 0.82) * size,
			rng.randf_range(0.18, 0.82) * size,
			rng.randf_range(0.09, 0.2) * size
		))
	for y in size:
		for x in size:
			var a: float = 0.0
			var shade: float = 1.0
			for c: Vector3 in centers:
				var d: float = Vector2(float(x) - c.x, float(y) - c.y).length()
				if d < c.z:
					a = 1.0
					shade = minf(shade, 0.6 + 0.4 * (d / c.z))
			if a > 0.0:
				img.set_pixel(x, y, Color(shade, shade, shade, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## 1xN vertical gradient used for sky-free fog ramps and UI accents.
static func gradient_texture(colors: PackedColorArray, width: int = 64) -> GradientTexture1D:
	var g := Gradient.new()
	if colors.size() >= 2:
		g.offsets = PackedFloat32Array()
		g.colors = PackedColorArray()
		for i in colors.size():
			g.add_point(float(i) / float(colors.size() - 1), colors[i])
		# add_point appends to the default two points; strip them.
		while g.get_point_count() > colors.size():
			g.remove_point(0)
	var t := GradientTexture1D.new()
	t.gradient = g
	t.width = width
	return t
