class_name TrafficManager
extends Node3D
## Traffic on the procedural road grid.
##
## Vehicles are data, not nodes: each one is a lane index plus a distance along
## that lane. Only vehicles close to the player are given a physical body that
## can shove the player around; everything else is drawn from a MultiMesh and
## integrated arithmetically.

const NEAR_DISTANCE: float = 72.0
const DESPAWN_DISTANCE: float = 420.0
const LANE_OFFSET: float = 3.1
const SPAWN_INTERVAL: float = 0.35
const VEHICLE_LENGTH: float = 5.0

var world_gen: WorldGen = null
var player: Node3D = null

var budget: int = 16

# Vehicle arrays
var _axis: PackedInt32Array = PackedInt32Array()      ## 0 = runs along X, 1 = along Z
var _line: PackedInt32Array = PackedInt32Array()      ## which road line
var _dir: PackedInt32Array = PackedInt32Array()       ## +1 / -1
var _s: PackedFloat32Array = PackedFloat32Array()     ## distance along the lane
var _speed: PackedFloat32Array = PackedFloat32Array()
var _target_speed: PackedFloat32Array = PackedFloat32Array()
var _kind: PackedInt32Array = PackedInt32Array()      ## 0 car, 1 truck
var _tint: PackedColorArray = PackedColorArray()
var _body_slot: PackedInt32Array = PackedInt32Array()
var _alive: PackedInt32Array = PackedInt32Array()
var _free: Array[int] = []
var _live: Array[int] = []

var _bodies: Array[AnimatableBody3D] = []
var _body_free: Array[int] = []
var _mm_car: MultiMeshInstance3D
var _mm_truck: MultiMeshInstance3D
var _headlights: Array[OmniLight3D] = []

var _mesh_lib: MeshLib
var _rng := RandomNumberGenerator.new()
var _spawn_cd: float = 0.0
var _lane_ahead: Dictionary = {}
var _night: float = 0.0
var _headlight_budget: int = 6


func setup(gen: WorldGen, mesh_lib: MeshLib, p: Node3D) -> void:
	world_gen = gen
	_mesh_lib = mesh_lib
	player = p
	_rng.seed = GameConfig.world_seed ^ 0xcafe
	_mm_car = _make_mm("TrafficCars", _mesh_lib.get_mesh("car"), GameConfig.MAX_VEHICLES)
	_mm_truck = _make_mm("TrafficTrucks", _mesh_lib.get_mesh("truck"),
		GameConfig.MAX_VEHICLES / 2)
	for i in 8:
		var l := OmniLight3D.new()
		l.name = "Headlight%d" % i
		l.light_color = Color(1.0, 0.94, 0.82)
		l.omni_range = 22.0
		l.light_energy = 0.0
		l.shadow_enabled = false
		add_child(l)
		_headlights.append(l)


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
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mmi.custom_aabb = AABB(Vector3(-500, -150, -500), Vector3(1000, 300, 1000))
	add_child(mmi)
	return mmi


func apply_profile(profile: Dictionary) -> void:
	budget = clampi(int(profile.get("vehicle_count", 16)), 0, GameConfig.MAX_VEHICLES)
	_headlight_budget = clampi(int(float(profile.get("omni_lights", 18)) * 0.35), 0,
		_headlights.size())
	_ensure_bodies(clampi(budget / 3, 2, 24))
	while _live.size() > budget:
		_despawn(_live[_live.size() - 1])


func set_night(v: float) -> void:
	_night = clampf(v, 0.0, 1.0)


func _ensure_bodies(n: int) -> void:
	while _bodies.size() < n:
		var b := AnimatableBody3D.new()
		b.name = "Vehicle%d" % _bodies.size()
		b.collision_layer = GameConfig.L_VEHICLE
		b.collision_mask = 0
		b.sync_to_physics = false
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2.0, 1.7, 4.6)
		cs.shape = box
		cs.position = Vector3(0.0, 0.85, 0.0)
		b.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		b.add_child(mi)
		add_child(b)
		b.visible = false
		# Parked well outside the world; a pooled body keeps its collision
		# shape, and leaving it at the origin would trap the player on spawn.
		b.position = Vector3(0.0, -4000.0, 0.0)
		b.collision_layer = 0
		_bodies.append(b)
		_body_free.append(_bodies.size() - 1)


func vehicle_count() -> int:
	return _live.size()


# -----------------------------------------------------------------------------
# Spawning
# -----------------------------------------------------------------------------
func _alloc() -> int:
	if not _free.is_empty():
		return _free.pop_back()
	_axis.push_back(0)
	_line.push_back(0)
	_dir.push_back(1)
	_s.push_back(0.0)
	_speed.push_back(0.0)
	_target_speed.push_back(0.0)
	_kind.push_back(0)
	_tint.push_back(Color.WHITE)
	_body_slot.push_back(-1)
	_alive.push_back(0)
	return _axis.size() - 1


func _despawn(i: int) -> void:
	if _alive[i] == 0:
		return
	_release_body(i)
	_alive[i] = 0
	_live.erase(i)
	_free.append(i)


func _spawn_near(pp: Vector3) -> bool:
	var sp: float = WorldGen.ROAD_SPACING
	# Choose a road line within a few hundred metres of the player.
	var axis: int = 0 if _rng.randf() < 0.5 else 1
	var centre: float = pp.z if axis == 0 else pp.x
	var k: int = int(round(centre / sp)) + _rng.randi_range(-2, 2)
	var line_coord: float = float(k) * sp

	var along_centre: float = pp.x if axis == 0 else pp.z
	var s: float = along_centre + _rng.randf_range(-260.0, 260.0)

	var test := Vector3(s, 0.0, line_coord) if axis == 0 else Vector3(line_coord, 0.0, s)
	if world_gen.urban_factor(test.x, test.z) < 0.1:
		return false
	if world_gen.height(test.x, test.z) < GameConfig.WATER_LEVEL + 0.5:
		return false
	var d: float = Vector2(test.x - pp.x, test.z - pp.z).length()
	if d < 22.0 or d > DESPAWN_DISTANCE * 0.8:
		return false

	var i: int = _alloc()
	_axis[i] = axis
	_line[i] = k
	_dir[i] = 1 if _rng.randf() < 0.5 else -1
	_s[i] = s
	_kind[i] = 1 if _rng.randf() < 0.22 else 0
	_target_speed[i] = _rng.randf_range(9.0, 17.0) * (0.75 if _kind[i] == 1 else 1.0)
	_speed[i] = _target_speed[i]
	_tint[i] = Color(
		_rng.randf_range(0.2, 0.9), _rng.randf_range(0.2, 0.9), _rng.randf_range(0.2, 0.9))
	_body_slot[i] = -1
	_alive[i] = 1
	_live.append(i)
	return true


func _acquire_body(i: int) -> bool:
	if _body_free.is_empty():
		return false
	var slot: int = _body_free.pop_back()
	var b: AnimatableBody3D = _bodies[slot]
	var mi: MeshInstance3D = b.get_node("Mesh")
	mi.mesh = _mesh_lib.get_mesh("truck" if _kind[i] == 1 else "car")
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _tint[i]
	mat.metallic = 0.5
	mat.roughness = 0.35
	mat.vertex_color_use_as_albedo = true
	mi.material_override = mat
	b.visible = true
	b.collision_layer = GameConfig.L_VEHICLE
	_body_slot[i] = slot
	return true


func _release_body(i: int) -> void:
	var slot: int = _body_slot[i]
	if slot < 0:
		return
	_bodies[slot].visible = false
	_bodies[slot].collision_layer = 0
	_bodies[slot].global_position = Vector3(0.0, -4000.0, 0.0)
	_body_free.append(slot)
	_body_slot[i] = -1


# -----------------------------------------------------------------------------
# Simulation
# -----------------------------------------------------------------------------
func _position_of(i: int) -> Vector3:
	var sp: float = WorldGen.ROAD_SPACING
	var lane: float = LANE_OFFSET * float(_dir[i])
	var p: Vector3
	if _axis[i] == 0:
		p = Vector3(_s[i], 0.0, float(_line[i]) * sp + lane)
	else:
		p = Vector3(float(_line[i]) * sp - lane, 0.0, _s[i])
	p.y = world_gen.height(p.x, p.z) + 0.06
	return p


func _yaw_of(i: int) -> float:
	if _axis[i] == 0:
		return PI * 0.5 if _dir[i] > 0 else -PI * 0.5
	return 0.0 if _dir[i] > 0 else PI


func _physics_process(delta: float) -> void:
	# Timed so the benchmark can separate this manager's script cost from
	# render and physics time. See PerformanceMonitor.record_subsystem.
	var _t0: int = Time.get_ticks_usec()
	_step_profiled(delta)
	PerformanceMonitor.record_subsystem("traffic", Time.get_ticks_usec() - _t0)


func _step_profiled(delta: float) -> void:
	if world_gen == null or player == null or not is_instance_valid(player):
		return
	var pp: Vector3 = player.global_position

	_spawn_cd -= delta
	if _spawn_cd <= 0.0:
		_spawn_cd = SPAWN_INTERVAL
		var tries: int = 0
		while _live.size() < budget and tries < 20:
			tries += 1
			_spawn_near(pp)

	_build_lane_map()

	var near_used: int = 0
	var car_n: int = 0
	var truck_n: int = 0
	var mm_car: MultiMesh = _mm_car.multimesh
	var mm_truck: MultiMesh = _mm_truck.multimesh
	var light_i: int = 0
	var despawn: Array[int] = []

	for i: int in _live:
		# Simple car-following: slow for the nearest vehicle ahead in the lane.
		var gap: float = _gap_ahead(i)
		var want: float = _target_speed[i]
		if gap < 9.0:
			want *= clampf((gap - 3.0) / 6.0, 0.0, 1.0)
		_speed[i] = move_toward(_speed[i], want, delta * 7.0)
		_s[i] += _speed[i] * float(_dir[i]) * delta

		var pos: Vector3 = _position_of(i)
		var d: float = Vector2(pos.x - pp.x, pos.z - pp.z).length()
		if d > DESPAWN_DISTANCE:
			despawn.append(i)
			continue

		var yaw: float = _yaw_of(i)
		if d < NEAR_DISTANCE and (_body_slot[i] >= 0 or near_used < _bodies.size()):
			if _body_slot[i] < 0:
				_acquire_body(i)
			if _body_slot[i] >= 0:
				near_used += 1
				var b: AnimatableBody3D = _bodies[_body_slot[i]]
				b.global_position = pos
				b.rotation.y = yaw
				if _night > 0.35 and light_i < _headlight_budget:
					var l: OmniLight3D = _headlights[light_i]
					light_i += 1
					var fwd: Vector3 = Vector3(sin(yaw), 0.0, cos(yaw))
					l.global_position = pos + fwd * 2.6 + Vector3(0.0, 0.7, 0.0)
					l.light_energy = 3.0 * _night
				continue
		if _body_slot[i] >= 0:
			_release_body(i)

		var xf := Transform3D(Basis(Vector3.UP, yaw), pos)
		if _kind[i] == 1:
			if truck_n < mm_truck.instance_count:
				mm_truck.set_instance_transform(truck_n, xf)
				mm_truck.set_instance_color(truck_n, _tint[i])
				truck_n += 1
		else:
			if car_n < mm_car.instance_count:
				mm_car.set_instance_transform(car_n, xf)
				mm_car.set_instance_color(car_n, _tint[i])
				car_n += 1

	for i: int in despawn:
		_despawn(i)

	while light_i < _headlights.size():
		_headlights[light_i].light_energy = 0.0
		light_i += 1

	mm_car.visible_instance_count = car_n
	mm_truck.visible_instance_count = truck_n
	PerformanceMonitor.set_counter("vehicles", _live.size())


## Buckets live vehicles by lane so car-following is O(n) instead of O(n^2).
func _build_lane_map() -> void:
	_lane_ahead.clear()
	for i: int in _live:
		var key: int = _axis[i] * 1000003 + _line[i] * 7 + (1 if _dir[i] > 0 else 0)
		if not _lane_ahead.has(key):
			_lane_ahead[key] = PackedInt32Array()
		var arr: PackedInt32Array = _lane_ahead[key]
		arr.push_back(i)
		_lane_ahead[key] = arr


func _gap_ahead(i: int) -> float:
	var key: int = _axis[i] * 1000003 + _line[i] * 7 + (1 if _dir[i] > 0 else 0)
	var arr: PackedInt32Array = _lane_ahead.get(key, PackedInt32Array())
	var best: float = 1000.0
	for j: int in arr:
		if j == i:
			continue
		var ds: float = (_s[j] - _s[i]) * float(_dir[i])
		if ds > 0.0:
			best = minf(best, ds - VEHICLE_LENGTH)
	return maxf(best, 0.0)


func clear_all() -> void:
	for i: int in _live.duplicate():
		_despawn(i)
	_live.clear()
