class_name PropBody
extends RigidBody3D
## Pooled destructible physics prop. Crates break into debris; barrels
## detonate, which is what makes a stack of them a chain reaction rather than a
## pile of boxes.

var manager: Node = null
var pool_index: int = -1
var health: float = 30.0
var explosive: bool = false
var destroyed: bool = false


func arm(kind: int, index: int) -> void:
	pool_index = index
	destroyed = false
	explosive = kind == 1
	health = 46.0 if explosive else (34.0 if kind == 0 else 12.0)


func take_damage(amount: float, _source: Object = null,
		_normal: Vector3 = Vector3.UP) -> void:
	if destroyed:
		return
	health -= amount
	sleeping = false
	if health <= 0.0:
		destroyed = true
		if manager != null and is_instance_valid(manager):
			manager.call("destroy_prop", pool_index)
