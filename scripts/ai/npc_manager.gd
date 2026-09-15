class_name NPCManager
extends Node3D
## Scalable agent simulation.
##
## Agents live in parallel PackedArrays, not nodes. Distance decides how much
## of each agent is actually simulated:
##
##   FULL       physics body, collision, per-frame steering and combat
##   REDUCED    per-frame kinematic motion drawn from a MultiMesh, light AI
##   BACKGROUND coarse integration a few times a second, drawn from a MultiMesh
##   DORMANT    position only, refreshed rarely, not drawn
##
## AI work is round-robined at a configurable rate, so raising the population
## raises total work smoothly instead of multiplying per-frame cost by N.

enum Tier { DORMANT, BACKGROUND, REDUCED, FULL }
enum Kind { CIVILIAN, SCAVENGER, STALKER, SPITTER }
enum AIState { IDLE, WANDER, CHASE, ATTACK, FLEE, DEAD }

const TIER_FULL_DISTANCE: float = 46.0
const TIER_REDUCED_DISTANCE: float = 115.0
const TIER_BACKGROUND_DISTANCE: float = 320.0
const DESPAWN_DISTANCE: float = 620.0
const BACKGROUND_INTERVAL: float = 0.28
const DORMANT_INTERVAL: float = 2.2
const ATTACK_RANGE_MELEE: float = 2.3
const ATTACK_RANGE_RANGED: float = 26.0

var world_gen: WorldGen = null
var streamer: ChunkStreamer = null
var player: Node3D = null
var physics_stress: Node = null

# --- Agent arrays ------------------------------------------------------------
var _pos: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _home: PackedVector3Array = PackedVector3Array()
var _goal: PackedVector3Array = PackedVector3Array()
var _health: PackedFloat32Array = PackedFloat32Array()
var _timer: PackedFloat32Array = PackedFloat32Array()
var _cooldown: PackedFloat32Array = PackedFloat32Array()
var _scale: PackedFloat32Array = PackedFloat32Array()
var _kind: PackedInt32Array = PackedInt32Array()
var _tier: PackedInt32Array = PackedInt32Array()
var _state: PackedInt32Array = PackedInt32Array()
var _body_slot: PackedInt32Array = PackedInt32Array()
var _alive: PackedInt32Array = PackedInt32Array()
var _free_slots: Array[int] = []
var _live_indices: Array[int] = []

# --- Full-tier body pool -----------------------------------------------------
var _body_pool: Array[NPCBody] = []
var _body_free: Array[int] = []
var _body_agent: PackedInt32Array = PackedInt32Array()

# --- Instanced rendering -----------------------------------------------------
var _mm_civ: MultiMeshInstance3D
var _mm_enemy: MultiMeshInstance3D
var _mm_far: MultiMeshInstance3D

# --- Budgets ----------------------------------------------------------------
var budget_total: int = 70
var budget_enemy: int = 16
var budget_full: int = 20
var budget_reduced: int = 26
var ai_hz: float = 10.0

var _spawn_queue: Array[Dictionary] = []
var _ai_cursor: int = 0
var _bg_accum: float = 0.0
var _dormant_accum: float = 0.0
var _mesh_lib: MeshLib
var _counts: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _spawn_cd: float = 0.0
## Development switch (see main.gd --no-hostiles). Shipped builds leave this on.
var hostiles_enabled: bool = true


func setup(gen: WorldGen, s: ChunkStreamer, mesh_lib: MeshLib, p: Node3D,
		physics: Node) -> void:
	world_gen = gen
	streamer = s
	player = p
	_mesh_lib = mesh_lib
	physics_stress = physics
	_rng.seed = GameConfig.world_seed ^ 0x5eed
	_build_multimeshes()
	if streamer != null:
		streamer.chunk_ready.connect(_on_chunk_ready)


func _build_multimeshes() -> void:
	_mm_civ = _make_mm("NPCReduced", _mesh_lib.get_mesh("npc_l0"), GameConfig.MAX_REDUCED_NPCS)
	_mm_enemy = _make_mm("EnemyReduced", _mesh_lib.get_mesh("enemy_l0"),
		GameConfig.MAX_REDUCED_NPCS)
	_mm_far = _make_mm("NPCBackground", _mesh_lib.get_mesh("npc_l1"), GameConfig.MAX_NPCS)


func _make_mm(nm: String, mesh: Mesh, capacity: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = capacity
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# Agents move over the whole streamed area; a generous custom AABB keeps the
	# renderer from culling the batch when the origin instance is off-screen.
	mmi.custom_aabb = AABB(Vector3(-600, -200, -600), Vector3(1200, 400, 1200))
	add_child(mmi)
	return mmi


func apply_profile(profile: Dictionary) -> void:
	budget_total = clampi(int(profile.get("npc_count", 70)), 0, GameConfig.MAX_NPCS)
	budget_enemy = clampi(int(profile.get("enemy_count", 16)), 0, GameConfig.MAX_NPCS / 3)
	budget_full = clampi(int(profile.get("npc_full", 20)), 0, GameConfig.MAX_FULL_NPCS)
	budget_reduced = clampi(int(profile.get("npc_reduced", 26)), 0,
		GameConfig.MAX_REDUCED_NPCS)
	ai_hz = clampf(float(profile.get("ai_hz", 10.0)), 1.0, 40.0)
	_ensure_body_pool(budget_full)
	_trim_population()


func _ensure_body_pool(n: int) -> void:
	while _body_pool.size() < n and _body_pool.size() < GameConfig.MAX_FULL_NPCS:
		var b := NPCBody.new()
		b.manager = self
		b.name = "FullNPC%d" % _body_pool.size()
		add_child(b)
		b.set_visible_body(false)
		_body_pool.append(b)
		_body_agent.push_back(-1)
		_body_free.append(_body_pool.size() - 1)


# -----------------------------------------------------------------------------
# Spawning
# -----------------------------------------------------------------------------
func _on_chunk_ready(coord: Vector2i) -> void:
	var d: ChunkData = streamer.get_chunk_data(coord)
	if d == null:
		return
	for p: Vector3 in d.npc_spawns:
		_spawn_queue.append({"pos": p, "hostile": false})
	for p: Vector3 in d.enemy_spawns:
		_spawn_queue.append({"pos": p, "hostile": true})
	if _spawn_queue.size() > 4000:
		_spawn_queue = _spawn_queue.slice(_spawn_queue.size() - 4000)


func agent_count() -> int:
	return _live_indices.size()


func enemy_count() -> int:
	return int(_counts.get("enemies", 0))


func _alloc_slot() -> int:
	if not _free_slots.is_empty():
		return _free_slots.pop_back()
	_pos.push_back(Vector3.ZERO)
	_vel.push_back(Vector3.ZERO)
	_home.push_back(Vector3.ZERO)
	_goal.push_back(Vector3.ZERO)
	_health.push_back(0.0)
	_timer.push_back(0.0)
	_cooldown.push_back(0.0)
	_scale.push_back(1.0)
	_kind.push_back(0)
	_tier.push_back(Tier.DORMANT)
	_state.push_back(AIState.IDLE)
	_body_slot.push_back(-1)
	_alive.push_back(0)
	return _pos.size() - 1


func spawn_agent(pos: Vector3, hostile: bool) -> int:
	if _live_indices.size() >= budget_total:
		return -1
	if hostile and not hostiles_enabled:
		return -1
	var i: int = _alloc_slot()
	var zone: int = GameConfig.zone_for_position(pos)
	var kind: int = Kind.CIVILIAN
	if hostile:
		kind = Kind.SPITTER if (zone >= GameConfig.Zone.CITY and _rng.randf() < 0.35) \
			else Kind.STALKER
	else:
		kind = Kind.SCAVENGER if _rng.randf() < 0.3 else Kind.CIVILIAN

	_pos[i] = pos
	_vel[i] = Vector3.ZERO
	_home[i] = pos
	_goal[i] = pos
	_health[i] = (52.0 + float(zone) * 13.0) if hostile else 46.0
	_timer[i] = _rng.randf_range(0.0, 3.0)
	_cooldown[i] = 0.0
	_scale[i] = _rng.randf_range(0.88, 1.16) * (1.0 + float(zone) * 0.03 if hostile else 1.0)
	_kind[i] = kind
	_tier[i] = Tier.DORMANT
	_state[i] = AIState.WANDER
	_body_slot[i] = -1
	_alive[i] = 1
	_live_indices.append(i)
	return i


func _despawn(i: int) -> void:
	if _alive[i] == 0:
		return
	_release_body(i)
	_alive[i] = 0
	_live_indices.erase(i)
	_free_slots.append(i)


func _trim_population() -> void:
	while _live_indices.size() > budget_total:
		var worst: int = -1
		var worst_d: float = -1.0
		var pp: Vector3 = _player_pos()
		for i: int in _live_indices:
			var d: float = _pos[i].distance_squared_to(pp)
			if d > worst_d:
				worst_d = d
				worst = i
		if worst < 0:
			break
		_despawn(worst)


func _player_pos() -> Vector3:
	if player != null and is_instance_valid(player):
		return player.global_position
	return Vector3.ZERO


# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if world_gen == null:
		return
	var pp: Vector3 = _player_pos()

	_spawn_cd -= delta
	if _spawn_cd <= 0.0:
		_spawn_cd = 0.25
		_drain_spawn_queue(pp)

	_assign_tiers(pp)
	_run_ai(delta, pp)
	_integrate(delta, pp)
	_update_instances(pp)
	_publish_counters()


func _drain_spawn_queue(pp: Vector3) -> void:
	var enemies: int = int(_counts.get("enemies", 0))
	var guard: int = 0
	while not _spawn_queue.is_empty() and _live_indices.size() < budget_total and guard < 64:
		guard += 1
		var entry: Dictionary = _spawn_queue.pop_front()
		var p: Vector3 = entry["pos"]
		var hostile: bool = bool(entry["hostile"])
		if hostile and enemies >= budget_enemy:
			continue
		var d: float = p.distance_to(pp)
		if d > DESPAWN_DISTANCE or d < 14.0:
			continue
		if spawn_agent(p, hostile) >= 0 and hostile:
			enemies += 1

	# Top the population up around the player when the queue runs dry, so a
	# stress-level jump takes effect immediately rather than waiting for
	# new chunks.
	var attempts: int = 0
	while _live_indices.size() < budget_total and attempts < 24:
		attempts += 1
		var ang: float = _rng.randf() * TAU
		var dist: float = _rng.randf_range(60.0, 260.0)
		var sp := Vector3(pp.x + cos(ang) * dist, 0.0, pp.z + sin(ang) * dist)
		sp.y = world_gen.height(sp.x, sp.z)
		if sp.y < GameConfig.WATER_LEVEL + 0.4:
			continue
		var want_enemy: bool = enemies < budget_enemy and _rng.randf() < 0.45
		if spawn_agent(sp, want_enemy) >= 0 and want_enemy:
			enemies += 1


func _assign_tiers(pp: Vector3) -> void:
	var full_used: int = 0
	var reduced_used: int = 0
	# Sorting every agent by distance each frame would be the naive approach;
	# instead we take a single pass and fill the tier budgets greedily by
	# distance band, which is stable enough because agents move slowly relative
	# to the band widths.
	for i: int in _live_indices:
		var d: float = _pos[i].distance_to(pp)
		var want: int = Tier.DORMANT
		if d < TIER_FULL_DISTANCE and full_used < budget_full:
			want = Tier.FULL
			full_used += 1
		elif d < TIER_REDUCED_DISTANCE and reduced_used < budget_reduced:
			want = Tier.REDUCED
			reduced_used += 1
		elif d < TIER_BACKGROUND_DISTANCE:
			want = Tier.BACKGROUND
		if want != Tier.FULL and _body_slot[i] >= 0:
			_release_body(i)
		elif want == Tier.FULL and _body_slot[i] < 0:
			if not _acquire_body(i):
				want = Tier.REDUCED
		_tier[i] = want


func _acquire_body(i: int) -> bool:
	if _body_free.is_empty():
		return false
	var slot: int = _body_free.pop_back()
	var b: NPCBody = _body_pool[slot]
	var hostile: bool = _kind[i] >= Kind.STALKER
	b.agent_index = i
	b.configure(
		_mesh_lib.get_mesh("enemy_l0" if hostile else "npc_l0"),
		hostile, _scale[i],
		_tint_for(i)
	)
	b.global_position = _pos[i]
	b.set_visible_body(true)
	_body_agent[slot] = i
	_body_slot[i] = slot
	return true


func _release_body(i: int) -> void:
	var slot: int = _body_slot[i]
	if slot < 0:
		return
	var b: NPCBody = _body_pool[slot]
	_pos[i] = b.global_position
	b.set_visible_body(false)
	b.agent_index = -1
	_body_agent[slot] = -1
	_body_free.append(slot)
	_body_slot[i] = -1


func _tint_for(i: int) -> Color:
	match _kind[i]:
		Kind.CIVILIAN:
			return Color(0.45, 0.48, 0.56)
		Kind.SCAVENGER:
			return Color(0.52, 0.44, 0.30)
		Kind.STALKER:
			return Color(0.42, 0.12, 0.12)
		_:
			return Color(0.30, 0.12, 0.34)


# -----------------------------------------------------------------------------
# AI
# -----------------------------------------------------------------------------
func _run_ai(delta: float, pp: Vector3) -> void:
	var n: int = _live_indices.size()
	if n == 0:
		return
	# How many agents get a decision this frame.
	var per_frame: int = clampi(int(ceil(float(n) * ai_hz * delta)), 1, n)
	for k in per_frame:
		if _ai_cursor >= _live_indices.size():
			_ai_cursor = 0
		var i: int = _live_indices[_ai_cursor]
		_ai_cursor += 1
		_decide(i, pp, delta * float(n) / float(per_frame))


func _decide(i: int, pp: Vector3, dt: float) -> void:
	if _alive[i] == 0:
		return
	_timer[i] -= dt
	_cooldown[i] = maxf(0.0, _cooldown[i] - dt)
	var hostile: bool = _kind[i] >= Kind.STALKER
	var d: float = _pos[i].distance_to(pp)

	if hostile:
		var aggro: float = 34.0 + float(GameConfig.zone_for_position(_pos[i])) * 6.0
		if d < aggro and GameState.phase == GameState.Phase.PLAYING:
			var range_needed: float = (ATTACK_RANGE_RANGED if _kind[i] == Kind.SPITTER
				else ATTACK_RANGE_MELEE)
			_state[i] = AIState.ATTACK if d <= range_needed else AIState.CHASE
			_goal[i] = pp
		elif _timer[i] <= 0.0:
			_state[i] = AIState.WANDER
			_timer[i] = _rng.randf_range(3.0, 7.0)
			_goal[i] = _wander_point(_home[i], 22.0)
	else:
		# Civilians flee hostiles and gunfire, otherwise patrol.
		if d < 9.0 and GameState.phase == GameState.Phase.PLAYING and _state[i] == AIState.FLEE:
			_goal[i] = _pos[i] + (_pos[i] - pp).normalized() * 22.0
		elif _timer[i] <= 0.0:
			_state[i] = AIState.WANDER
			_timer[i] = _rng.randf_range(4.0, 11.0)
			_goal[i] = _wander_point(_home[i], 30.0)


func _wander_point(origin: Vector3, radius: float) -> Vector3:
	var a: float = _rng.randf() * TAU
	var r: float = _rng.randf_range(radius * 0.25, radius)
	var p := Vector3(origin.x + cos(a) * r, 0.0, origin.z + sin(a) * r)
	p.y = world_gen.height(p.x, p.z)
	return p


func alert_near(pos: Vector3, radius: float) -> void:
	var r2: float = radius * radius
	for i: int in _live_indices:
		if _pos[i].distance_squared_to(pos) > r2:
			continue
		if _kind[i] >= Kind.STALKER:
			_state[i] = AIState.CHASE
			_goal[i] = pos
			_timer[i] = 6.0
		else:
			_state[i] = AIState.FLEE
			_timer[i] = 4.0


# -----------------------------------------------------------------------------
# Motion
# -----------------------------------------------------------------------------
func _integrate(delta: float, pp: Vector3) -> void:
	_bg_accum += delta
	_dormant_accum += delta
	var do_bg: bool = _bg_accum >= BACKGROUND_INTERVAL
	var do_dormant: bool = _dormant_accum >= DORMANT_INTERVAL
	if do_bg:
		_bg_accum = 0.0
	if do_dormant:
		_dormant_accum = 0.0

	var despawn: Array[int] = []
	for i: int in _live_indices:
		var d: float = _pos[i].distance_to(pp)
		if d > DESPAWN_DISTANCE:
			despawn.append(i)
			continue
		match _tier[i]:
			Tier.FULL:
				_step_full(i, delta, pp)
			Tier.REDUCED:
				_step_kinematic(i, delta, 1.0)
			Tier.BACKGROUND:
				if do_bg:
					_step_kinematic(i, BACKGROUND_INTERVAL, 0.7)
			_:
				if do_dormant:
					_step_kinematic(i, DORMANT_INTERVAL, 0.35)
	for i: int in despawn:
		_despawn(i)


func _speed_for(i: int) -> float:
	var base: float = 2.1
	match _kind[i]:
		Kind.STALKER:
			base = 4.5
		Kind.SPITTER:
			base = 3.1
		Kind.SCAVENGER:
			base = 2.6
	if _state[i] == AIState.CHASE:
		base *= 1.25
	elif _state[i] == AIState.FLEE:
		base *= 1.4
	return base


func _step_full(i: int, delta: float, pp: Vector3) -> void:
	var slot: int = _body_slot[i]
	if slot < 0:
		_step_kinematic(i, delta, 1.0)
		return
	var b: NPCBody = _body_pool[slot]
	var to_goal: Vector3 = _goal[i] - b.global_position
	to_goal.y = 0.0
	var desired: Vector3 = Vector3.ZERO
	if to_goal.length() > 0.8:
		desired = to_goal.normalized() * _speed_for(i)
	b.drive(desired, delta)
	_pos[i] = b.global_position
	_vel[i] = b.velocity

	if _state[i] == AIState.ATTACK and _kind[i] >= Kind.STALKER and _cooldown[i] <= 0.0:
		_attack(i, pp)


func _step_kinematic(i: int, dt: float, speed_scale: float) -> void:
	var p: Vector3 = _pos[i]
	var to_goal: Vector3 = _goal[i] - p
	to_goal.y = 0.0
	var dist: float = to_goal.length()
	if dist > 0.7:
		var step: Vector3 = to_goal / dist * _speed_for(i) * speed_scale * dt
		p += step
		_vel[i] = step / maxf(dt, 0.0001)
	else:
		_vel[i] = Vector3.ZERO
	p.y = world_gen.height(p.x, p.z)
	_pos[i] = p

	if _state[i] == AIState.ATTACK and _kind[i] >= Kind.STALKER and _cooldown[i] <= 0.0:
		_attack(i, _player_pos())


func _attack(i: int, pp: Vector3) -> void:
	var d: float = _pos[i].distance_to(pp)
	if _kind[i] == Kind.SPITTER:
		if d > ATTACK_RANGE_RANGED:
			return
		_cooldown[i] = 1.6
		if physics_stress != null and physics_stress.has_method("launch_projectile"):
			var from: Vector3 = _pos[i] + Vector3(0.0, 1.1, 0.0)
			var dir: Vector3 = (pp + Vector3(0.0, 1.0, 0.0) - from).normalized()
			physics_stress.call("launch_projectile", from, dir * 34.0, 9.0, true)
	else:
		if d > ATTACK_RANGE_MELEE + 0.6:
			return
		_cooldown[i] = 1.1
		if player != null and player.has_method("take_damage"):
			player.call("take_damage", 7.0 + float(
				GameConfig.zone_for_position(_pos[i])) * 1.6, self, Vector3.UP,
				_pos[i])


# -----------------------------------------------------------------------------
# Damage
# -----------------------------------------------------------------------------
func damage_agent(i: int, amount: float, source: Object = null,
		normal: Vector3 = Vector3.UP) -> void:
	if i < 0 or i >= _alive.size() or _alive[i] == 0:
		return
	_health[i] -= amount
	var hostile: bool = _kind[i] >= Kind.STALKER
	if hostile:
		_state[i] = AIState.CHASE
		_goal[i] = _player_pos()
	else:
		_state[i] = AIState.FLEE
		_timer[i] = 6.0
	if _health[i] > 0.0:
		return

	var p: Vector3 = _pos[i]
	if physics_stress != null and physics_stress.has_method("spawn_gib_burst"):
		physics_stress.call("spawn_gib_burst", p + Vector3(0.0, 0.8, 0.0), normal, hostile)
	if hostile:
		GameState.register_kill(
			NPCManager.Kind.keys()[clampi(_kind[i], 0, 3)], p)
		if _rng.randf() < 0.35 and physics_stress != null \
				and physics_stress.has_method("drop_pickup"):
			physics_stress.call("drop_pickup", p + Vector3(0.0, 0.6, 0.0))
	_despawn(i)
	alert_near(p, 24.0)


## Applies an explosion to every agent inside `radius`.
func explode(center: Vector3, radius: float, damage: float) -> void:
	var r2: float = radius * radius
	var hit: Array[int] = []
	for i: int in _live_indices:
		if _pos[i].distance_squared_to(center) <= r2:
			hit.append(i)
	for i: int in hit:
		var d: float = _pos[i].distance_to(center)
		damage_agent(i, damage * (1.0 - clampf(d / radius, 0.0, 1.0)), null,
			(_pos[i] - center).normalized())


# -----------------------------------------------------------------------------
# Rendering
# -----------------------------------------------------------------------------
func _update_instances(pp: Vector3) -> void:
	var civ: int = 0
	var enemy: int = 0
	var far: int = 0
	var full: int = 0
	var reduced: int = 0
	var background: int = 0
	var dormant: int = 0
	var enemies_total: int = 0

	var mm_civ: MultiMesh = _mm_civ.multimesh
	var mm_en: MultiMesh = _mm_enemy.multimesh
	var mm_far: MultiMesh = _mm_far.multimesh

	for i: int in _live_indices:
		var hostile: bool = _kind[i] >= Kind.STALKER
		if hostile:
			enemies_total += 1
		match _tier[i]:
			Tier.FULL:
				full += 1
				continue
			Tier.REDUCED:
				reduced += 1
			Tier.BACKGROUND:
				background += 1
			_:
				dormant += 1
				continue

		var yaw: float = atan2(_vel[i].x, _vel[i].z)
		var basis: Basis = Basis(Vector3.UP, yaw).scaled(Vector3.ONE * _scale[i])
		var xf := Transform3D(basis, _pos[i])
		if _tier[i] == Tier.REDUCED:
			if hostile:
				if enemy < mm_en.instance_count:
					mm_en.set_instance_transform(enemy, xf)
					mm_en.set_instance_color(enemy, _tint_for(i))
					enemy += 1
			else:
				if civ < mm_civ.instance_count:
					mm_civ.set_instance_transform(civ, xf)
					mm_civ.set_instance_color(civ, _tint_for(i))
					civ += 1
		else:
			if far < mm_far.instance_count:
				mm_far.set_instance_transform(far, xf)
				mm_far.set_instance_color(far, _tint_for(i))
				far += 1

	mm_civ.visible_instance_count = civ
	mm_en.visible_instance_count = enemy
	mm_far.visible_instance_count = far

	_counts = {
		"npc_total": _live_indices.size(),
		"npc_full": full,
		"npc_reduced": reduced,
		"npc_background": background,
		"npc_dormant": dormant,
		"enemies": enemies_total,
	}


func _publish_counters() -> void:
	for k: String in _counts.keys():
		PerformanceMonitor.set_counter(k, _counts[k])


func clear_all() -> void:
	for i: int in _live_indices.duplicate():
		_despawn(i)
	_spawn_queue.clear()
	_live_indices.clear()
