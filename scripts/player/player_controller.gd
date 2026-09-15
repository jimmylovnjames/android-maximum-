class_name PlayerController
extends CharacterBody3D
## First-person player: movement, look, vitals coupling, hitscan weapon,
## interaction and the scripted autopilot the benchmark uses.
##
## Input comes from either the keyboard/mouse path or the TouchInput layer;
## both write into the same intent variables so gameplay code has one path.

signal fired(from: Vector3, to: Vector3, hit: bool)
signal interacted(target: Node)
signal stuck_recovered()

const MOUSE_SENS: float = 0.0022
const MAX_PITCH: float = 1.45
const ACCEL_GROUND: float = 12.0
const ACCEL_AIR: float = 2.6
const FRICTION: float = 11.0
const COYOTE_TIME: float = 0.14
const INTERACT_RANGE: float = 3.4
const WEAPON_RANGE: float = 220.0
const FIRE_INTERVAL: float = 0.12
const MELEE_INTERVAL: float = 0.55
const BOB_FREQ: float = 9.0
const TERMINAL_VELOCITY: float = 55.0
const STUCK_SECONDS: float = 0.7

var camera: Camera3D
var head: Node3D
var touch: TouchInput = null

var look_sensitivity: float = 1.0
var invert_look: bool = false
var autopilot: bool = false
var autopilot_speed: float = 6.0
var autopilot_radius: float = 60.0
var autopilot_angle: float = 0.0
## Marches radially outward instead of arcing at a fixed radius. The benchmark
## wants the fixed arc (reproducible geometry); the streaming smoke test wants
## the march, because only travelling across chunk boundaries exercises unload
## and cache reuse.
var autopilot_outward: bool = false
var _autopilot_dodge: float = 0.0

var _pitch: float = 0.0
var _yaw: float = 0.0
var _coyote: float = 0.0
var _crouching: bool = false
var _fire_cd: float = 0.0
var _bob_t: float = 0.0
var _base_fov: float = 78.0
var _recoil: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _interact_target: Node = null
var _interact_scan: float = 0.0
var _mouse_captured: bool = false
var _ray: RayCast3D
var _pickup_area: Area3D
var _muzzle: OmniLight3D
var _muzzle_timer: float = 0.0
var _sprinting: bool = false
var _view_distance: float = 900.0
var _spawn_protect: float = 1.5
## Held in place until the chunk underneath has streamed in and has collision.
## Without this the player free-falls through a world that does not exist yet.
var frozen: bool = true
var _stuck_timer: float = 0.0


func _ready() -> void:
	collision_layer = GameConfig.L_PLAYER
	collision_mask = GameConfig.L_WORLD | GameConfig.L_DEBRIS | GameConfig.L_VEHICLE
	floor_max_angle = deg_to_rad(60.0)
	floor_snap_length = 0.4
	slide_on_ceiling = true

	var caps := CapsuleShape3D.new()
	caps.radius = 0.38
	caps.height = 1.8
	var cs := CollisionShape3D.new()
	cs.shape = caps
	cs.position = Vector3(0.0, 0.9, 0.0)
	add_child(cs)

	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0.0, GameConfig.PLAYER_EYE_HEIGHT, 0.0)
	add_child(head)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = _base_fov
	camera.near = 0.08
	camera.far = 1200.0
	camera.current = true
	head.add_child(camera)

	_ray = RayCast3D.new()
	_ray.name = "AimRay"
	_ray.target_position = Vector3(0.0, 0.0, -WEAPON_RANGE)
	_ray.collision_mask = (GameConfig.L_WORLD | GameConfig.L_ENEMY | GameConfig.L_NPC
		| GameConfig.L_DEBRIS | GameConfig.L_VEHICLE | GameConfig.L_INTERACT)
	_ray.collide_with_areas = true
	_ray.enabled = true
	camera.add_child(_ray)

	_muzzle = OmniLight3D.new()
	_muzzle.name = "MuzzleFlash"
	_muzzle.light_color = Color(1.0, 0.82, 0.45)
	_muzzle.light_energy = 0.0
	_muzzle.omni_range = 10.0
	_muzzle.shadow_enabled = false
	camera.add_child(_muzzle)

	var pshape := SphereShape3D.new()
	pshape.radius = 2.1
	var pcs := CollisionShape3D.new()
	pcs.shape = pshape
	pcs.position = Vector3(0.0, 0.9, 0.0)
	_pickup_area = Area3D.new()
	_pickup_area.name = "PickupMagnet"
	_pickup_area.collision_layer = 0
	_pickup_area.collision_mask = GameConfig.L_INTERACT
	_pickup_area.monitoring = true
	_pickup_area.add_child(pcs)
	add_child(_pickup_area)

	look_sensitivity = float(GameConfig.settings.get("look_sensitivity", 1.0))
	invert_look = bool(GameConfig.settings.get("invert_look", false))
	_last_pos = global_position
	EventBus.player_spawned.emit(self)


func bind_touch(t: TouchInput) -> void:
	touch = t
	if t == null:
		return
	t.jump_pressed.connect(_touch_jump)
	t.interact_pressed.connect(try_interact)


func set_view_distance(v: float) -> void:
	_view_distance = v
	if camera != null:
		camera.far = clampf(v * 1.15, 200.0, 4000.0)


func capture_mouse(v: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if TouchInput.has_touchscreen() and not OS.has_feature("pc"):
		return
	_mouse_captured = v
	Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if v else Input.MOUSE_MODE_VISIBLE)


func _unhandled_input(event: InputEvent) -> void:
	if GameState.phase != GameState.Phase.PLAYING and not autopilot:
		return
	if event is InputEventMouseMotion and _mouse_captured:
		var mm: InputEventMouseMotion = event
		_apply_look(mm.relative * MOUSE_SENS * look_sensitivity * 57.2958 * 0.02)


func _apply_look(delta_deg: Vector2) -> void:
	_yaw -= deg_to_rad(delta_deg.x)
	var p: float = deg_to_rad(delta_deg.y) * (1.0 if invert_look else -1.0)
	_pitch = clampf(_pitch + p, -MAX_PITCH, MAX_PITCH)


func _physics_process(delta: float) -> void:
	if frozen:
		velocity = Vector3.ZERO
		_last_pos = global_position
		return
	if _spawn_protect > 0.0:
		_spawn_protect -= delta

	if autopilot:
		_autopilot_step(delta)
	else:
		_gather_look(delta)

	var on_floor: bool = is_on_floor()
	if on_floor:
		_coyote = COYOTE_TIME
	else:
		_coyote = maxf(0.0, _coyote - delta)
		# Terminal velocity matters here: without it a player wedged against a
		# steep collision face accumulates hundreds of m/s of downward motion,
		# and the resulting per-step sweep gets large enough that the solver
		# reports "stuck" and stops moving them at all.
		velocity.y = maxf(velocity.y - 22.0 * delta, -TERMINAL_VELOCITY)

	var intent: Vector2 = _movement_intent()
	var wants_sprint: bool = _wants_sprint() and intent.length_squared() > 0.05
	_sprinting = wants_sprint and GameState.stamina > 1.0 and not _crouching

	if not autopilot:
		_crouching = Input.is_action_pressed("crouch")

	var speed: float = GameConfig.PLAYER_WALK_SPEED
	if _crouching:
		speed = GameConfig.PLAYER_CROUCH_SPEED
	elif _sprinting:
		speed = GameConfig.PLAYER_SPRINT_SPEED

	var basis_yaw := Basis(Vector3.UP, _yaw)
	var dir: Vector3 = (basis_yaw * Vector3(intent.x, 0.0, -intent.y))
	if dir.length_squared() > 1.0:
		dir = dir.normalized()

	var target: Vector3 = dir * speed
	var accel: float = ACCEL_GROUND if on_floor else ACCEL_AIR
	velocity.x = move_toward(velocity.x, target.x, accel * speed * delta)
	velocity.z = move_toward(velocity.z, target.z, accel * speed * delta)
	if on_floor and dir.length_squared() < 0.01:
		velocity.x = move_toward(velocity.x, 0.0, FRICTION * delta * speed)
		velocity.z = move_toward(velocity.z, 0.0, FRICTION * delta * speed)

	if not autopilot and Input.is_action_just_pressed("jump"):
		_try_jump()

	rotation.y = _yaw
	move_and_slide()

	head.position.y = lerpf(head.position.y,
		GameConfig.PLAYER_CROUCH_EYE_HEIGHT if _crouching else GameConfig.PLAYER_EYE_HEIGHT,
		clampf(delta * 12.0, 0.0, 1.0))

	_check_stuck(delta, on_floor, intent)
	_update_view(delta, on_floor)
	_update_vitals(delta)
	_update_combat(delta)

	# Horizontal only: vertical settling against a streamed trimesh would
	# otherwise inflate the distance statistic by hundreds of metres.
	var moved: float = Vector2(
		global_position.x - _last_pos.x, global_position.z - _last_pos.z).length()
	if moved > 0.004:
		GameState.register_travel(moved, global_position)
	_last_pos = global_position


## A streamed procedural world can always produce a pocket the character
## controller cannot resolve. If the player is airborne, pressing into a
## surface and going nowhere, lift them back out instead of leaving them
## wedged there for the rest of the run.
func _check_stuck(delta: float, on_floor: bool, intent: Vector2) -> void:
	var horizontal: float = Vector2(velocity.x, velocity.z).length()
	var moved: float = Vector2(
		global_position.x - _last_pos.x, global_position.z - _last_pos.z).length()
	if on_floor or (moved > 0.008 and horizontal > 0.2) or intent.length_squared() < 0.01:
		_stuck_timer = 0.0
		return
	_stuck_timer += delta
	if _stuck_timer < STUCK_SECONDS:
		return
	_stuck_timer = 0.0
	velocity.y = 0.0
	global_position.y += 1.2
	stuck_recovered.emit()


func _gather_look(delta: float) -> void:
	if touch != null and touch.is_enabled():
		var d: Vector2 = touch.take_look_delta()
		if d != Vector2.ZERO:
			_apply_look(d * 0.42)
	var pad := Vector2(
		Input.get_axis("move_left", "move_right") * 0.0,
		0.0
	)
	if pad != Vector2.ZERO:
		_apply_look(pad * delta * 120.0)


func _movement_intent() -> Vector2:
	if autopilot:
		return Vector2(0.0, 1.0)
	var kb := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_back", "move_forward")
	)
	if touch != null and touch.is_enabled() and touch.move_vector.length_squared() > 0.0:
		kb += touch.move_vector
	return kb.limit_length(1.0)


func _wants_sprint() -> bool:
	if autopilot:
		return true
	if Input.is_action_pressed("sprint"):
		return true
	return touch != null and touch.is_enabled() and touch.sprint_held


func _try_jump() -> void:
	if _coyote > 0.0 and GameState.consume_stamina(6.0):
		velocity.y = GameConfig.PLAYER_JUMP_VELOCITY
		_coyote = 0.0


func _touch_jump() -> void:
	if GameState.phase == GameState.Phase.PLAYING:
		_try_jump()


func _update_view(delta: float, on_floor: bool) -> void:
	var planar: float = Vector2(velocity.x, velocity.z).length()
	if on_floor and planar > 0.6:
		_bob_t += delta * BOB_FREQ * clampf(planar / GameConfig.PLAYER_WALK_SPEED, 0.4, 2.2)
	else:
		_bob_t = lerpf(_bob_t, 0.0, clampf(delta * 6.0, 0.0, 1.0))
	var bob_amount: float = clampf(planar / GameConfig.PLAYER_SPRINT_SPEED, 0.0, 1.0) * 0.045
	var bob := Vector3(
		cos(_bob_t * 0.5) * bob_amount * 1.2,
		absf(sin(_bob_t)) * bob_amount,
		0.0
	)
	_recoil = move_toward(_recoil, 0.0, delta * 5.0)
	camera.position = bob
	camera.rotation.x = _pitch + _recoil
	camera.rotation.z = lerpf(camera.rotation.z,
		-Vector2(velocity.x, velocity.z).rotated(_yaw).x * 0.004, clampf(delta * 6.0, 0.0, 1.0))

	var want_fov: float = _base_fov + (9.0 if _sprinting else 0.0)
	camera.fov = lerpf(camera.fov, want_fov, clampf(delta * 6.0, 0.0, 1.0))

	if _muzzle_timer > 0.0:
		_muzzle_timer -= delta
		_muzzle.light_energy = maxf(0.0, _muzzle_timer * 26.0)
	elif _muzzle.light_energy != 0.0:
		_muzzle.light_energy = 0.0


func _update_vitals(delta: float) -> void:
	var zone: int = GameConfig.zone_for_position(global_position)
	GameState.regen(delta, _sprinting and Vector2(velocity.x, velocity.z).length() > 1.0, zone)
	if _sprinting and GameState.stamina <= 0.5:
		_sprinting = false

	# Falling damage.
	if is_on_floor() and velocity.y < -18.0 and _spawn_protect <= 0.0:
		GameState.damage((absf(velocity.y) - 18.0) * 3.2, "fall")


func _update_combat(delta: float) -> void:
	_fire_cd = maxf(0.0, _fire_cd - delta)
	_interact_scan -= delta
	if _interact_scan <= 0.0:
		_interact_scan = 0.12
		_scan_interact()

	if GameState.phase != GameState.Phase.PLAYING:
		return
	var want_fire: bool = Input.is_action_pressed("attack")
	if touch != null and touch.is_enabled() and touch.attack_held:
		want_fire = true
	if want_fire and _fire_cd <= 0.0:
		fire()

	if Input.is_action_just_pressed("interact"):
		try_interact()
	if Input.is_action_just_pressed("slot_1"):
		GameState.use_medkit()
	if Input.is_action_just_pressed("slot_2"):
		GameState.use_ration()


func fire() -> void:
	if GameState.ammo <= 0:
		_melee()
		return
	if not GameState.spend_ammo(1):
		_melee()
		return
	_fire_cd = FIRE_INTERVAL
	_recoil = minf(_recoil + 0.022, 0.12)
	_muzzle_timer = 0.055

	var from: Vector3 = camera.global_position
	var spread: float = 0.004 + (0.012 if _sprinting else 0.0)
	var dir: Vector3 = -camera.global_transform.basis.z
	dir = (dir + Vector3(
		randf_range(-spread, spread), randf_range(-spread, spread),
		randf_range(-spread, spread))).normalized()

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * WEAPON_RANGE)
	q.collision_mask = (GameConfig.L_WORLD | GameConfig.L_ENEMY | GameConfig.L_NPC
		| GameConfig.L_DEBRIS | GameConfig.L_VEHICLE)
	q.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(q)

	var to: Vector3 = from + dir * WEAPON_RANGE
	var did_hit: bool = not hit.is_empty()
	if did_hit:
		to = hit["position"]
		var collider: Object = hit.get("collider", null)
		if collider != null and collider.has_method("take_damage"):
			collider.call("take_damage", 28.0, self, hit.get("normal", Vector3.UP))
		elif collider is RigidBody3D:
			var rb: RigidBody3D = collider
			rb.apply_impulse(dir * 3.4, hit["position"] - rb.global_position)
	EventBus.shot_fired.emit(from, to)
	fired.emit(from, to, did_hit)


func _melee() -> void:
	if _fire_cd > 0.0:
		return
	_fire_cd = MELEE_INTERVAL
	_recoil = 0.05
	var from: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 2.6)
	q.collision_mask = GameConfig.L_ENEMY | GameConfig.L_NPC | GameConfig.L_DEBRIS
	q.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return
	var collider: Object = hit.get("collider", null)
	if collider != null and collider.has_method("take_damage"):
		collider.call("take_damage", 34.0, self, hit.get("normal", Vector3.UP))
	elif collider is RigidBody3D:
		(collider as RigidBody3D).apply_impulse(dir * 6.0)


func _scan_interact() -> void:
	_interact_target = null
	if _ray == null:
		return
	_ray.target_position = Vector3(0.0, 0.0, -INTERACT_RANGE)
	_ray.force_raycast_update()
	if _ray.is_colliding():
		var c: Object = _ray.get_collider()
		if c is Node and (c as Node).has_method("interact"):
			_interact_target = c as Node
			EventBus.interact_prompt.emit(
				String((c as Node).call("interact_prompt")) if
				(c as Node).has_method("interact_prompt") else "USE")
			_ray.target_position = Vector3(0.0, 0.0, -WEAPON_RANGE)
			return
	_ray.target_position = Vector3(0.0, 0.0, -WEAPON_RANGE)
	EventBus.interact_prompt.emit("")

	# Proximity magnet for loose pickups.
	for a: Area3D in _pickup_area.get_overlapping_areas():
		if a.has_method("collect"):
			a.call("collect", self)
			break


func try_interact() -> void:
	if _interact_target != null and is_instance_valid(_interact_target):
		_interact_target.call("interact", self)
		interacted.emit(_interact_target)
		return
	for a: Area3D in _pickup_area.get_overlapping_areas():
		if a.has_method("collect"):
			a.call("collect", self)
			return


func take_damage(amount: float, source: Object = null, _normal: Vector3 = Vector3.UP,
		from_position: Vector3 = Vector3.INF) -> void:
	if _spawn_protect > 0.0:
		return
	# Fall back to the source node's position so the HUD can point at whatever
	# hit the player rather than inventing a direction.
	var origin_pos: Vector3 = from_position
	if origin_pos == Vector3.INF and source is Node3D:
		origin_pos = (source as Node3D).global_position
	GameState.damage(amount, "combat", origin_pos)


## Points the camera without moving the player. Used by the capture flags and
## by anything that needs to frame a view.
func set_yaw(radians: float) -> void:
	_yaw = radians
	rotation.y = _yaw


## Camera pitch, for framing a capture. Gameplay drives this from look input.
func set_pitch(radians: float) -> void:
	_pitch = clampf(radians, -MAX_PITCH, MAX_PITCH)


func teleport(pos: Vector3, face_yaw: float = 0.0) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	_yaw = face_yaw
	rotation.y = _yaw
	_last_pos = pos
	_spawn_protect = 1.5
	frozen = true


## Safety net for a streamed world: if the player ends up well below the
## procedural surface (tunnelling, or a chunk arriving late), put them back on
## top of it rather than letting them fall out of the world.
func ground_snap(ground_y: float, clearance: float = 1.2) -> void:
	global_position.y = ground_y + clearance
	velocity = Vector3.ZERO
	_last_pos = global_position


# -----------------------------------------------------------------------------
# Benchmark autopilot: a deterministic arc walk so every run covers comparable
# geometry instead of depending on how the tester happened to move.
# -----------------------------------------------------------------------------
func set_autopilot(on: bool, radius: float = 60.0) -> void:
	autopilot = on
	autopilot_radius = maxf(20.0, radius)
	if on:
		autopilot_angle = atan2(global_position.z, global_position.x)


func _autopilot_step(delta: float) -> void:
	var r: float = maxf(20.0, Vector2(global_position.x, global_position.z).length())
	var heading: Vector3
	if autopilot_outward:
		# Steer around anything the outward heading cannot climb. Without this
		# the march walks into the first ridge it meets and stays there, which
		# tells you nothing about streaming.
		var planar: float = Vector2(velocity.x, velocity.z).length()
		if planar < 1.2:
			_autopilot_dodge += delta * 1.3
		else:
			_autopilot_dodge = move_toward(_autopilot_dodge, 0.0, delta * 0.6)
		var out := Vector2(global_position.x, global_position.z)
		if out.length_squared() < 1.0:
			out = Vector2(1.0, 0.35)
		out = out.normalized().rotated(sin(_autopilot_dodge) * 1.15)
		heading = Vector3(out.x, 0.0, out.y)
	else:
		autopilot_angle += (autopilot_speed / r) * delta
		heading = Vector3(-sin(autopilot_angle), 0.0, cos(autopilot_angle))
	_yaw = atan2(-heading.x, -heading.z)
	_pitch = lerpf(_pitch, sin(Time.get_ticks_msec() * 0.0004) * 0.16, clampf(delta, 0.0, 1.0))
