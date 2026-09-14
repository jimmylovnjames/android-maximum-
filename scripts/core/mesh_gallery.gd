class_name MeshGallery
extends Node3D
## Debug scene that lays every mesh in the procedural library out on a grid
## with neutral lighting, so each asset can be inspected on its own instead of
## being judged from across a landscape.
##
## Built for screenshot verification during development; never instantiated by
## the game.

const SPACING: float = 7.0
const COLUMNS: int = 6


func build() -> void:
	var mat_lib: MaterialLib = MaterialLib.get_instance()
	var lib: MeshLib = MeshLib.get_instance()

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.12, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.70)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 3.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var key_light := DirectionalLight3D.new()
	key_light.light_energy = 1.1
	key_light.shadow_enabled = true
	key_light.rotation_degrees = Vector3(-42.0, -38.0, 0.0)
	add_child(key_light)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.3
	fill.light_color = Color(0.7, 0.8, 1.0)
	fill.rotation_degrees = Vector3(-18.0, 140.0, 0.0)
	add_child(fill)

	var keys: Array = lib.meshes.keys()
	keys.sort()
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(COLUMNS * SPACING + 20.0,
		ceil(float(keys.size()) / float(COLUMNS)) * SPACING + 20.0)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.22, 0.23, 0.25)
	gm.roughness = 0.95
	ground.mesh.surface_set_material(0, gm)
	ground.position = Vector3(plane.size.x * 0.5 - SPACING, 0.0, plane.size.y * 0.5 - SPACING)
	add_child(ground)

	var font: Font = ThemeDB.fallback_font
	for i in keys.size():
		var key: String = keys[i]
		var mesh: Mesh = lib.meshes[key]
		if mesh == null:
			continue
		var col: int = i % COLUMNS
		var row: int = i / COLUMNS
		var pos := Vector3(float(col) * SPACING, 0.0, float(row) * SPACING)

		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = pos
		# Normalise size so a 7 m tank and a 0.4 m crate are both legible.
		var aabb: AABB = mesh.get_aabb()
		var extent: float = maxf(0.001, maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)))
		var scale_v: float = clampf(3.6 / extent, 0.05, 6.0)
		mi.scale = Vector3.ONE * scale_v
		mi.position.y = -aabb.position.y * scale_v
		add_child(mi)

		var label := Label3D.new()
		label.text = key
		label.font_size = 48
		label.pixel_size = 0.006
		label.position = pos + Vector3(0.0, -0.35, 2.6)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color(0.85, 0.9, 1.0)
		label.no_depth_test = true
		add_child(label)

	var rows: int = int(ceil(float(keys.size()) / float(COLUMNS)))
	var cx: float = float(COLUMNS - 1) * SPACING * 0.5
	var cz: float = float(rows - 1) * SPACING * 0.5
	var span: float = maxf(float(COLUMNS) * SPACING, float(rows) * SPACING)

	var cam := Camera3D.new()
	cam.far = 600.0
	cam.fov = 55.0
	cam.current = true
	# Parent first: look_at needs a global transform, which a detached node
	# does not have.
	add_child(cam)
	cam.global_position = Vector3(cx, span * 0.62, cz + span * 0.78)
	cam.look_at(Vector3(cx, 1.4, cz), Vector3.UP)
