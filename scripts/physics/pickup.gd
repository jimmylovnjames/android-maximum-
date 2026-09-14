class_name Pickup
extends Area3D
## Collectable scavenge item. Pooled by PhysicsStressManager so scavenging in a
## dense zone never allocates.

var item_id: String = "scrap"
var amount: int = 1
var _mesh: MeshInstance3D
var _spin: float = 0.0
var _life: float = 0.0
var _active: bool = false

signal collected(p: Pickup)


func _ready() -> void:
	collision_layer = GameConfig.L_INTERACT
	collision_mask = 0
	monitoring = false
	monitorable = true
	var s := SphereShape3D.new()
	s.radius = 0.5
	var cs := CollisionShape3D.new()
	cs.shape = s
	cs.position = Vector3(0.0, 0.35, 0.0)
	add_child(cs)
	_mesh = MeshInstance3D.new()
	_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
	set_active(false)


func configure(mesh: Mesh, id: String, n: int, tint: Color) -> void:
	_mesh.mesh = mesh
	item_id = id
	amount = n
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 1.6
	mat.vertex_color_use_as_albedo = false
	_mesh.material_override = mat
	_life = 0.0


func set_active(v: bool) -> void:
	_active = v
	visible = v
	monitorable = v
	set_process(v)


func is_active() -> bool:
	return _active


func interact_prompt() -> String:
	var def: Dictionary = GameState.ITEM_DEFS.get(item_id, {})
	return "TAKE %s x%d" % [String(def.get("name", item_id)).to_upper(), amount]


func interact(p: Node) -> void:
	collect(p)


func collect(_p: Node) -> void:
	if not _active:
		return
	GameState.add_item(item_id, amount)
	EventBus.notify("+%d %s" % [amount,
		String(GameState.ITEM_DEFS.get(item_id, {}).get("name", item_id))], 1.6)
	set_active(false)
	collected.emit(self)


func _process(delta: float) -> void:
	_spin += delta * 1.7
	_life += delta
	_mesh.rotation.y = _spin
	_mesh.position.y = 0.35 + sin(_life * 2.2) * 0.09
