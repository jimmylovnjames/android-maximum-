class_name PhysicsStressManager
extends Node3D
## Pooled rigid-body simulation: scatterable props, destructible stacks,
## projectiles, debris bursts, explosions and impact particles.
##
## Everything comes from fixed-size pools with hard caps from GameConfig, so a
## MELTDOWN-level physics storm is bounded no matter what the director asks for.

const BODY_GROUPS: PackedStringArray = ["crate", "barrel", "debris"]
## Parking spot for pooled bodies. A pooled body still has a collision shape,
## so leaving it at the origin would wall the player into their own spawn.
const PARK: Vector3 = Vector3(0.0, -4000.0, 0.0)
const SLEEP_RECLAIM_DISTANCE: float = 130.0
const STACK_SPACING: float = 0.84
const IMPACT_POOL: int = 24

var world_gen: WorldGen = null
var player: Node3D = null
var npc_manager: Node = null

var body_budget: int = 110
var debris_budget: int = 70
var stack_budget: int = 5
var particle_budget: int = 2600
var particle_systems_budget: int = 12

var _bodies: Array[PropBody] = []
var _body_free: Array[int] = []
var _body_active: Array[int] = []
var _body_kind: PackedInt32Array = PackedInt32Array()

var _projectiles: Array[RigidBody3D] = []
var _proj_free: Array[int] = []
var _proj_life: PackedFloat32Array = PackedFloat32Array()
var _proj_damage: PackedFloat32Array = PackedFloat32Array()
var _proj_hostile: PackedInt32Array = PackedInt32Array()
var _proj_active: Array[int] = []

var _pickups: Array[Pickup] = []
var _pickup_free: Array[int] = []

var _impacts: Array[GPUParticles3D] = []
var _impact_cursor: int = 0

var _mesh_lib: MeshLib
var _mat_lib: MaterialLib
var _rng := RandomNumberGenerator.new()
var _stacks_placed: Array[Vector3] = []
var _maintain_cd: float = 0.0
var _storm_cd: float = 0.0
var _explosion_light_pool: Array[OmniLight3D] = []
var _light_cursor: int = 0


func setup(gen: WorldGen, mesh_lib: MeshLib, mat_lib: MaterialLib, p: Node3D) -> void:
	world_gen = gen
	_mesh_lib = mesh_lib
	_mat_lib = mat_lib
	player = p
	_rng.seed = GameConfig.world_seed ^ 0xbeef
	_build_impact_pool()
	_build_light_pool()
	EventBus.explosion.connect(_on_explosion)


func set_npc_manager(n: Node) -> void:
	npc_manager = n


func apply_profile(profile: Dictionary) -> void:
	body_budget = clampi(int(profile.get("rigid_bodies", 110)), 0, GameConfig.MAX_RIGID_BODIES)
	debris_budget = clampi(int(profile.get("debris_budget", 70)), 0, GameConfig.MAX_DEBRIS)
	stack_budget = clampi(int(profile.get("destructible_stacks", 5)), 0, 64)
	particle_budget = int(profile.get("particle_budget", 2600))
	particle_systems_budget = clampi(int(profile.get("particle_systems", 12)), 0,
		GameConfig.MAX_PARTICLE_SYSTEMS)
	_ensure_pools()
	_apply_particle_budget()


# -----------------------------------------------------------------------------
# Pools
# -----------------------------------------------------------------------------
func _ensure_pools() -> void:
	var want_bodies: int = clampi(body_budget + debris_budget, 8,
		GameConfig.MAX_RIGID_BODIES)
	while _bodies.size() < want_bodies:
		var rb := _make_body(_bodies.size())
		_bodies.append(rb)
		_body_kind.push_back(0)
		_body_free.append(_bodies.size() - 1)

	while _projectiles.size() < GameConfig.MAX_PROJECTILES / 2:
		var pr := _make_projectile(_projectiles.size())
		_projectiles.append(pr)
		_proj_life.push_back(0.0)
		_proj_damage.push_back(0.0)
		_proj_hostile.push_back(0)
		_proj_free.append(_projectiles.size() - 1)

	while _pickups.size() < 64:
		var pk := Pickup.new()
		pk.name = "Pickup%d" % _pickups.size()
		add_child(pk)
		pk.collected.connect(_on_pickup_collected)
		_pickups.append(pk)
		_pickup_free.append(_pickups.size() - 1)


func _make_body(i: int) -> PropBody:
	var rb := PropBody.new()
	rb.name = "Prop%d" % i
	rb.manager = self
	rb.pool_index = i
	rb.collision_layer = GameConfig.L_DEBRIS
	rb.collision_mask = (GameConfig.L_WORLD | GameConfig.L_DEBRIS | GameConfig.L_PLAYER
		| GameConfig.L_VEHICLE)
	rb.can_sleep = true
	rb.continuous_cd = false
	rb.freeze = true
	rb.mass = 12.0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 0.8, 0.8)
	cs.shape = box
	cs.position = Vector3(0.0, 0.4, 0.0)
	cs.name = "Shape"
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	rb.add_child(mi)
	add_child(rb)
	rb.visible = false
	rb.position = PARK
	rb.collision_layer = 0
	rb.collision_mask = 0
	return rb


func _make_projectile(i: int) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.name = "Projectile%d" % i
	rb.collision_layer = GameConfig.L_PROJECTILE
	rb.collision_mask = (GameConfig.L_WORLD | GameConfig.L_DEBRIS | GameConfig.L_PLAYER
		| GameConfig.L_ENEMY | GameConfig.L_NPC | GameConfig.L_VEHICLE)
	rb.mass = 1.2
	rb.gravity_scale = 0.55
	rb.continuous_cd = true
	rb.contact_monitor = true
	rb.max_contacts_reported = 2
	rb.freeze = true
	var cs := CollisionShape3D.new()
	var sp := SphereShape3D.new()
	sp.radius = 0.16
	cs.shape = sp
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.16
	sm.height = 0.32
	sm.radial_segments = 6
	sm.rings = 4
	mi.mesh = sm
	mi.material_override = _mat_lib.tracer
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	rb.add_child(mi)
	add_child(rb)
	rb.visible = false
	rb.position = PARK
	rb.collision_layer = 0
	rb.collision_mask = 0
	rb.body_entered.connect(_on_projectile_hit.bind(i))
	return rb


func _build_impact_pool() -> void:
	for i in IMPACT_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.12
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 60.0
		pm.gravity = Vector3(0, -9.0, 0)
		pm.initial_velocity_min = 2.5
		pm.initial_velocity_max = 8.0
		pm.scale_min = 0.4
		pm.scale_max = 1.4
		pm.color = Color(1.0, 0.7, 0.35, 1.0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.72, 0.32)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.6, 0.25)
		mat.emission_energy_multiplier = 4.0
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo = true
		var p := GPUParticles3D.new()
		p.name = "Impact%d" % i
		p.draw_pass_1 = _mesh_lib.get_mesh("spark_quad")
		p.material_override = mat
		p.process_material = pm
		p.amount = 24
		p.lifetime = 0.8
		p.one_shot = true
		p.explosiveness = 0.95
		p.emitting = false
		p.local_coords = false
		p.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
		add_child(p)
		_impacts.append(p)


func _build_light_pool() -> void:
	for i in 6:
		var l := OmniLight3D.new()
		l.name = "BlastLight%d" % i
		l.light_energy = 0.0
		l.omni_range = 26.0
		l.light_color = Color(1.0, 0.66, 0.3)
		l.shadow_enabled = false
		add_child(l)
		_explosion_light_pool.append(l)


func _apply_particle_budget() -> void:
	if _impacts.is_empty():
		return
	var per: int = clampi(particle_budget / maxi(1, _impacts.size()) * 2, 8, 900)
	var enabled: int = clampi(particle_systems_budget, 0, _impacts.size())
	for i in _impacts.size():
		_impacts[i].amount = per
		_impacts[i].visible = i < enabled


# -----------------------------------------------------------------------------
# Props / stacks
# -----------------------------------------------------------------------------
func active_body_count() -> int:
	return _body_active.size()


func _acquire_body(kind: int) -> int:
	if _body_free.is_empty():
		return -1
	var idx: int = _body_free.pop_back()
	var rb: PropBody = _bodies[idx]
	var mi: MeshInstance3D = rb.get_node("Mesh")
	var cs: CollisionShape3D = rb.get_node("Shape")
	match kind:
		0:
			mi.mesh = _mesh_lib.get_mesh("crate")
			(cs.shape as BoxShape3D).size = Vector3(0.8, 0.8, 0.8)
			cs.position = Vector3(0.0, 0.4, 0.0)
			rb.mass = 14.0
		1:
			mi.mesh = _mesh_lib.get_mesh("barrel")
			(cs.shape as BoxShape3D).size = Vector3(0.72, 1.05, 0.72)
			cs.position = Vector3(0.0, 0.52, 0.0)
			rb.mass = 22.0
		_:
			mi.mesh = _mesh_lib.get_mesh("debris")
			(cs.shape as BoxShape3D).size = Vector3(0.44, 0.3, 0.36)
			cs.position = Vector3(0.0, 0.15, 0.0)
			rb.mass = 5.0
	_body_kind[idx] = kind
	rb.arm(kind, idx)
	rb.visible = true
	rb.collision_layer = GameConfig.L_DEBRIS
	rb.collision_mask = (GameConfig.L_WORLD | GameConfig.L_DEBRIS | GameConfig.L_PLAYER
		| GameConfig.L_VEHICLE)
	rb.freeze = false
	rb.sleeping = false
	_body_active.append(idx)
	return idx


func _release_body(idx: int) -> void:
	var rb: PropBody = _bodies[idx]
	rb.destroyed = true
	rb.freeze = true
	rb.visible = false
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO
	rb.collision_layer = 0
	rb.collision_mask = 0
	rb.global_position = PARK
	_body_active.erase(idx)
	_body_free.append(idx)


func spawn_prop(pos: Vector3, kind: int, impulse: Vector3 = Vector3.ZERO) -> int:
	if _body_active.size() >= body_budget + debris_budget:
		_reclaim_one()
	var idx: int = _acquire_body(kind)
	if idx < 0:
		return -1
	var rb: PropBody = _bodies[idx]
	rb.global_position = pos
	rb.rotation = Vector3(0.0, _rng.randf() * TAU, 0.0)
	rb.linear_velocity = impulse
	rb.angular_velocity = Vector3(
		_rng.randf_range(-4, 4), _rng.randf_range(-4, 4), _rng.randf_range(-4, 4))
	return idx


func spawn_stack(base: Vector3, width: int, height: int) -> void:
	for y in height:
		for x in width:
			for z in width:
				var p: Vector3 = base + Vector3(
					(float(x) - float(width - 1) * 0.5) * STACK_SPACING,
					0.42 + float(y) * STACK_SPACING,
					(float(z) - float(width - 1) * 0.5) * STACK_SPACING
				)
				var kind: int = 1 if (_rng.randf() < 0.25) else 0
				if spawn_prop(p, kind) < 0:
					return


func spawn_gib_burst(pos: Vector3, normal: Vector3, hostile: bool) -> void:
	var n: int = clampi(int(float(debris_budget) * 0.06), 2, 10)
	for i in n:
		var dir: Vector3 = (normal + Vector3(
			_rng.randf_range(-0.8, 0.8), _rng.randf_range(0.2, 1.0),
			_rng.randf_range(-0.8, 0.8))).normalized()
		spawn_prop(pos, 2, dir * _rng.randf_range(4.0, 9.0))
	_play_impact(pos, Color(1.0, 0.3, 0.2) if hostile else Color(0.8, 0.7, 0.6))


func drop_pickup(pos: Vector3) -> void:
	if _pickup_free.is_empty():
		return
	var idx: int = _pickup_free.pop_back()
	var pk: Pickup = _pickups[idx]
	var roll: float = _rng.randf()
	var id: String = "scrap"
	var amount: int = 2
	if roll > 0.86:
		id = "medkit"
		amount = 1
	elif roll > 0.62:
		id = "ammo"
		amount = 18 + int(_rng.randf() * 24.0)
	elif roll > 0.44:
		id = "cell"
		amount = 1
	var tint := Color(GameState.ITEM_DEFS.get(id, {}).get("color", "9aa4b2"))
	pk.configure(_mesh_lib.get_mesh("pickup"), id, amount, tint)
	pk.global_position = pos
	pk.set_active(true)


func place_pickup(pos: Vector3, id: String, amount: int) -> bool:
	if _pickup_free.is_empty():
		return false
	var idx: int = _pickup_free.pop_back()
	var pk: Pickup = _pickups[idx]
	var tint := Color(GameState.ITEM_DEFS.get(id, {}).get("color", "9aa4b2"))
	pk.configure(_mesh_lib.get_mesh("core_pickup" if id == "core" else "pickup"),
		id, amount, tint)
	pk.global_position = pos
	pk.set_active(true)
	return true


func _on_pickup_collected(p: Pickup) -> void:
	var idx: int = _pickups.find(p)
	if idx >= 0 and not _pickup_free.has(idx):
		_pickup_free.append(idx)


## Called by PropBody when its health runs out. Barrels chain-detonate, which
## is the point of stacking them next to each other in the REDLINE zones.
func destroy_prop(idx: int) -> void:
	if idx < 0 or idx >= _bodies.size():
		return
	if not _body_active.has(idx):
		return
	var rb: PropBody = _bodies[idx]
	var pos: Vector3 = rb.global_position
	var was_explosive: bool = rb.explosive
	_release_body(idx)
	var shards: int = clampi(int(float(debris_budget) * 0.05), 2, 8)
	for i in shards:
		var dir := Vector3(
			_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.4, 1.2),
			_rng.randf_range(-1.0, 1.0)).normalized()
		spawn_prop(pos, 2, dir * _rng.randf_range(3.0, 8.0))
	if was_explosive:
		# Deferred so a chain reaction unwinds across frames instead of
		# recursing through the whole stack inside one physics step.
		call_deferred("detonate", pos, 11.0, 26.0, 55.0)
	else:
		_play_impact(pos, Color(0.75, 0.65, 0.5))


## Particles actually emitting right now, for the HUD and benchmark counters.
func active_particle_count() -> int:
	var n: int = 0
	for p: GPUParticles3D in _impacts:
		if p.visible and p.emitting:
			n += p.amount
	return n


# -----------------------------------------------------------------------------
# Projectiles
# -----------------------------------------------------------------------------
func launch_projectile(from: Vector3, velocity: Vector3, damage: float,
		hostile: bool) -> void:
	if _proj_free.is_empty():
		return
	var idx: int = _proj_free.pop_back()
	var rb: RigidBody3D = _projectiles[idx]
	rb.global_position = from
	rb.collision_layer = GameConfig.L_PROJECTILE
	rb.collision_mask = (GameConfig.L_WORLD | GameConfig.L_DEBRIS | GameConfig.L_PLAYER
		| GameConfig.L_ENEMY | GameConfig.L_NPC | GameConfig.L_VEHICLE)
	rb.freeze = false
	rb.visible = true
	rb.linear_velocity = velocity
	_proj_life[idx] = 4.0
	_proj_damage[idx] = damage
	_proj_hostile[idx] = 1 if hostile else 0
	_proj_active.append(idx)
	PerformanceMonitor.set_counter("projectiles", _proj_active.size())


func _on_projectile_hit(body: Node, idx: int) -> void:
	if not _proj_active.has(idx):
		return
	var rb: RigidBody3D = _projectiles[idx]
	var pos: Vector3 = rb.global_position
	if _proj_hostile[idx] == 1 and body is PlayerController:
		(body as PlayerController).take_damage(_proj_damage[idx], self, Vector3.UP, pos)
	elif body != null and body.has_method("take_damage"):
		body.call("take_damage", _proj_damage[idx], self, Vector3.UP)
	_play_impact(pos, Color(0.9, 0.4, 1.0) if _proj_hostile[idx] == 1
		else Color(1.0, 0.8, 0.4))
	_retire_projectile(idx)


func _retire_projectile(idx: int) -> void:
	var rb: RigidBody3D = _projectiles[idx]
	rb.freeze = true
	rb.visible = false
	rb.linear_velocity = Vector3.ZERO
	rb.collision_layer = 0
	rb.collision_mask = 0
	rb.global_position = PARK
	_proj_active.erase(idx)
	if not _proj_free.has(idx):
		_proj_free.append(idx)
	PerformanceMonitor.set_counter("projectiles", _proj_active.size())


# -----------------------------------------------------------------------------
# Explosions
# -----------------------------------------------------------------------------
func detonate(center: Vector3, radius: float, force: float, damage: float = 60.0) -> void:
	EventBus.explosion.emit(center, radius, force)
	var r2: float = radius * radius
	var affected: int = 0
	for idx: int in _body_active.duplicate():
		var rb: PropBody = _bodies[idx]
		var d2: float = rb.global_position.distance_squared_to(center)
		if d2 > r2:
			continue
		affected += 1
		if affected > GameConfig.MAX_EXPLOSION_BODIES:
			break
		var dir: Vector3 = (rb.global_position - center)
		var dist: float = maxf(dir.length(), 0.4)
		rb.sleeping = false
		rb.apply_impulse(dir / dist * force * (1.0 - clampf(dist / radius, 0.0, 1.0))
			+ Vector3.UP * force * 0.25)
	if npc_manager != null and npc_manager.has_method("explode"):
		npc_manager.call("explode", center, radius, damage)
	if player != null and is_instance_valid(player):
		var pd: float = player.global_position.distance_to(center)
		if pd < radius and player.has_method("take_damage"):
			player.call("take_damage", damage * (1.0 - pd / radius) * 0.6, self,
				Vector3.UP, center)
	_play_impact(center, Color(1.0, 0.55, 0.2), 2.4)
	_flash(center, radius)


func _on_explosion(_center: Vector3, _radius: float, _force: float) -> void:
	pass


func _flash(pos: Vector3, radius: float) -> void:
	if _explosion_light_pool.is_empty():
		return
	var l: OmniLight3D = _explosion_light_pool[_light_cursor % _explosion_light_pool.size()]
	_light_cursor += 1
	l.global_position = pos
	l.omni_range = radius * 2.0
	l.light_energy = 9.0


func _play_impact(pos: Vector3, tint: Color, scale: float = 1.0) -> void:
	if _impacts.is_empty():
		return
	var tries: int = _impacts.size()
	while tries > 0:
		tries -= 1
		var p: GPUParticles3D = _impacts[_impact_cursor % _impacts.size()]
		_impact_cursor += 1
		if not p.visible:
			continue
		p.global_position = pos
		var pm: ParticleProcessMaterial = p.process_material as ParticleProcessMaterial
		if pm != null:
			pm.color = tint
			pm.scale_max = 1.4 * scale
		p.restart()
		p.emitting = true
		return


# -----------------------------------------------------------------------------
# Upkeep
# -----------------------------------------------------------------------------
func _reclaim_one() -> void:
	if _body_active.is_empty():
		return
	var pp: Vector3 = player.global_position if (player != null and is_instance_valid(player)) \
		else Vector3.ZERO
	var worst: int = -1
	var worst_d: float = -1.0
	for idx: int in _body_active:
		var d: float = _bodies[idx].global_position.distance_squared_to(pp)
		if d > worst_d:
			worst_d = d
			worst = idx
	if worst >= 0:
		_release_body(worst)


func _physics_process(delta: float) -> void:
	for idx: int in _proj_active.duplicate():
		_proj_life[idx] -= delta
		if _proj_life[idx] <= 0.0 or _projectiles[idx].global_position.y < -120.0:
			_retire_projectile(idx)

	_maintain_cd -= delta
	if _maintain_cd <= 0.0:
		_maintain_cd = 0.6
		_maintain()

	PerformanceMonitor.set_counter("rigid_bodies", _body_active.size())
	PerformanceMonitor.set_counter("debris", _body_active.size())


## Keeps the world populated with the number of physics bodies the current
## stress level asks for, and reclaims bodies that have gone to sleep far away.
func _maintain() -> void:
	if player == null or not is_instance_valid(player) or world_gen == null:
		return
	var pp: Vector3 = player.global_position

	for idx: int in _body_active.duplicate():
		var rb: PropBody = _bodies[idx]
		if rb.global_position.y < -140.0:
			_release_body(idx)
			continue

		if rb.sleeping and rb.global_position.distance_to(pp) > SLEEP_RECLAIM_DISTANCE:
			_release_body(idx)

	var want: int = body_budget
	var have: int = _body_active.size()
	if have >= want:
		return
	var to_add: int = clampi(want - have, 0, 24)
	var placed: int = 0
	var attempts: int = 0
	while placed < to_add and attempts < 40:
		attempts += 1
		var ang: float = _rng.randf() * TAU
		var dist: float = _rng.randf_range(12.0, 70.0)
		var p := Vector3(pp.x + cos(ang) * dist, 0.0, pp.z + sin(ang) * dist)
		p.y = world_gen.height(p.x, p.z)
		if p.y < GameConfig.WATER_LEVEL + 0.5:
			continue
		if world_gen.slope_at(p.x, p.z) > 0.35:
			continue
		var zone: int = GameConfig.zone_for_position(p)
		if _stacks_placed.size() < stack_budget and zone >= GameConfig.Zone.SETTLEMENT \
				and _rng.randf() < 0.3:
			var w: int = 2 if _rng.randf() < 0.6 else 3
			var h: int = clampi(2 + int(_rng.randf() * 3.0), 2, 5)
			spawn_stack(p + Vector3(0.0, 0.1, 0.0), w, h)
			_stacks_placed.append(p)
			placed += w * w * h
		else:
			spawn_prop(p + Vector3(0.0, 0.4, 0.0), 1 if _rng.randf() < 0.3 else 0)
			placed += 1

	# Forget stack anchors that have fallen far behind the player.
	for i in range(_stacks_placed.size() - 1, -1, -1):
		if _stacks_placed[i].distance_to(pp) > 220.0:
			_stacks_placed.remove_at(i)


## Large scripted physics event used by REDLINE zones and the benchmark.
func physics_storm(center: Vector3, intensity: float = 1.0) -> void:
	var stacks: int = clampi(int(6.0 * intensity), 1, 20)
	for i in stacks:
		var ang: float = _rng.randf() * TAU
		var dist: float = _rng.randf_range(8.0, 34.0)
		var p := Vector3(center.x + cos(ang) * dist, 0.0, center.z + sin(ang) * dist)
		p.y = world_gen.height(p.x, p.z) + 0.2
		spawn_stack(p, 3, clampi(3 + int(_rng.randf() * 3.0), 3, 6))
	for i in 3:
		var ang2: float = _rng.randf() * TAU
		var p2 := Vector3(center.x + cos(ang2) * 16.0, 0.0, center.z + sin(ang2) * 16.0)
		p2.y = world_gen.height(p2.x, p2.z) + 1.0
		detonate(p2, 16.0, 24.0, 0.0)
	EventBus.notify("PHYSICS STORM", 2.5)


func clear_all() -> void:
	for idx: int in _body_active.duplicate():
		_release_body(idx)
	for idx: int in _proj_active.duplicate():
		_retire_projectile(idx)
	_stacks_placed.clear()
	for i in _pickups.size():
		_pickups[i].set_active(false)
		if not _pickup_free.has(i):
			_pickup_free.append(i)
