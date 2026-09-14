class_name ObjectiveTracker
extends Node
## Sequential objective chain. Gives the run a shape beyond "walk outward",
## and each objective deliberately pushes the player into a heavier part of the
## world, so progressing the game and escalating the workload are the same act.

class Objective extends RefCounted:
	var text: String = ""
	var goal: float = 1.0
	var reward_id: String = ""
	var reward_amount: int = 0
	var probe: Callable

	func _init(t: String, g: float, p: Callable, rid: String = "", ra: int = 0) -> void:
		text = t
		goal = g
		probe = p
		reward_id = rid
		reward_amount = ra

	func value() -> float:
		return float(probe.call())


var _objectives: Array[Objective] = []
var _index: int = 0
var _check_cd: float = 0.0
var _redline_seconds: float = 0.0
var _world: WorldManager = null


func setup(world: WorldManager) -> void:
	_world = world
	_objectives = [
		Objective.new("Leave the wilderness -- reach 250 m out", 250.0,
			func() -> float: return GameState.deepest_radius, "ammo", 40),
		Objective.new("Scavenge 8 scrap from the forest", 8.0,
			func() -> float: return float(GameState.inventory.get("scrap", 0)), "medkit", 1),
		Objective.new("Find the settlement -- reach 650 m", 650.0,
			func() -> float: return GameState.deepest_radius, "ration", 2),
		Objective.new("Clear 12 hostiles", 12.0,
			func() -> float: return float(GameState.kills), "ammo", 80),
		Objective.new("Push into the dense city -- reach 1600 m", 1600.0,
			func() -> float: return GameState.deepest_radius, "medkit", 2),
		Objective.new("Recover 2 Redline Cores", 2.0,
			func() -> float: return float(GameState.inventory.get("core", 0)), "ammo", 120),
		Objective.new("Enter the REDLINE zone -- reach 2850 m", 2850.0,
			func() -> float: return GameState.deepest_radius, "medkit", 3),
		Objective.new("Survive 180 s inside the REDLINE zone", 180.0,
			func() -> float: return _redline_seconds, "core", 1),
	]
	_index = 0
	_push()


func reset() -> void:
	_index = 0
	_redline_seconds = 0.0
	_push()


func _process(delta: float) -> void:
	if GameState.phase != GameState.Phase.PLAYING:
		return
	if _world != null and is_instance_valid(_world) and _world.player != null:
		if GameConfig.zone_for_position(_world.player.global_position) >= GameConfig.Zone.REDLINE:
			_redline_seconds += delta

	_check_cd -= delta
	if _check_cd > 0.0:
		return
	_check_cd = 0.5
	_evaluate()


func _evaluate() -> void:
	if _index >= _objectives.size():
		return
	var o: Objective = _objectives[_index]
	var v: float = o.value()
	if v < o.goal:
		GameState.set_objective(o.text, clampf(v / o.goal, 0.0, 1.0))
		return
	if o.reward_id != "" and o.reward_amount > 0:
		GameState.add_item(o.reward_id, o.reward_amount)
	EventBus.notify("OBJECTIVE COMPLETE: %s" % o.text, 4.0)
	_index += 1
	_push()


func _push() -> void:
	if _index >= _objectives.size():
		GameState.set_objective("All objectives complete -- survive as long as you can", 1.0)
		return
	var o: Objective = _objectives[_index]
	GameState.set_objective(o.text, clampf(o.value() / o.goal, 0.0, 1.0))


func progress_fraction() -> float:
	return float(_index) / float(maxi(1, _objectives.size()))
