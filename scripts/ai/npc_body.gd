class_name NPCBody
extends CharacterBody3D
## Pooled physical representation for a FULL-tier agent. Owns no AI: the
## NPCManager writes desired velocity into it and reads its resolved position
## back, so promotion/demotion between tiers never changes behaviour.

var agent_index: int = -1
var manager: Node = null

var _mesh: MeshInstance3D
var _shape: CollisionShape3D
var _anim_t: float = 0.0
var _hit_flash: float = 0.0
var _base_scale: Vector3 = Vector3.ONE


func _ready() -> void:
	floor_max_angle = deg_to_rad(60.0)
	floor_snap_length = 0.5
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED

	var caps := CapsuleShape3D.new()
	caps.radius = 0.34
	caps.height = 1.7
	_shape = CollisionShape3D.new()
	_shape.shape = caps
	_shape.position = Vector3(0.0, 0.85, 0.0)
	add_child(_shape)

	_mesh = MeshInstance3D.new()
	_mesh.name = "Body"
	_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_mesh)


func configure(mesh: Mesh, hostile: bool, scale_v: float, tint: Color) -> void:
	_mesh.mesh = mesh
	_base_scale = Vector3.ONE * scale_v
	_mesh.scale = _base_scale
	collision_layer = GameConfig.L_ENEMY if hostile else GameConfig.L_NPC
	collision_mask = GameConfig.L_WORLD | GameConfig.L_VEHICLE
	var mat: StandardMaterial3D = (_mesh.get_active_material(0) as StandardMaterial3D)
	if mat != null:
		var inst: StandardMaterial3D = mat.duplicate() as StandardMaterial3D
		inst.albedo_color = tint
		_mesh.material_override = inst


func set_visible_body(v: bool) -> void:
	visible = v
	_shape.disabled = not v
	if not v:
		# Parked out of the world so a disabled-but-present body can never
		# interact with anything while it waits in the pool.
		position = Vector3(0.0, -4000.0, 0.0)
		velocity = Vector3.ZERO


func drive(desired: Vector3, delta: float, gravity: float = 22.0) -> void:
	velocity.x = desired.x
	velocity.z = desired.z
	if is_on_floor():
		velocity.y = maxf(velocity.y, -0.1)
	else:
		velocity.y -= gravity * delta
	move_and_slide()

	var speed: float = Vector2(velocity.x, velocity.z).length()
	if speed > 0.15:
		var target_yaw: float = atan2(velocity.x, velocity.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(delta * 8.0, 0.0, 1.0))
	# Procedural gait: vertical bob plus a squash/stretch that reads as steps.
	_anim_t += delta * (3.0 + speed * 1.8)
	var bob: float = absf(sin(_anim_t)) * clampf(speed * 0.045, 0.0, 0.13)
	var squash: float = 1.0 + sin(_anim_t * 2.0) * clampf(speed * 0.012, 0.0, 0.05)
	_mesh.position.y = bob
	_mesh.scale = Vector3(_base_scale.x / squash, _base_scale.y * squash,
		_base_scale.z / squash)
	_mesh.rotation.z = sin(_anim_t) * clampf(speed * 0.02, 0.0, 0.12)

	if _hit_flash > 0.0:
		_hit_flash = maxf(0.0, _hit_flash - delta * 3.0)
		var m: StandardMaterial3D = _mesh.material_override as StandardMaterial3D
		if m != null:
			m.emission_enabled = true
			m.emission = Color(1.0, 0.3, 0.2)
			m.emission_energy_multiplier = _hit_flash * 5.0


func flash_hit() -> void:
	_hit_flash = 1.0


func take_damage(amount: float, source: Object = null, normal: Vector3 = Vector3.UP) -> void:
	flash_hit()
	if manager != null and is_instance_valid(manager):
		manager.call("damage_agent", agent_index, amount, source, normal)
