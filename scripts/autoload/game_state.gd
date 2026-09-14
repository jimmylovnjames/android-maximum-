extends Node
## Authoritative gameplay state: vitals, survival pressure, inventory,
## objectives, run statistics. Managers mutate it through methods so every
## change emits the right signal exactly once.

enum Phase { MENU, PLAYING, PAUSED, DEAD, BENCHMARK }

const ITEM_DEFS: Dictionary = {
	"scrap":    {"name": "Scrap",      "stack": 999, "color": "9aa4b2"},
	"cell":     {"name": "Power Cell", "stack": 99,  "color": "5ec8f0"},
	"medkit":   {"name": "Medkit",     "stack": 12,  "color": "3ad17c"},
	"ration":   {"name": "Ration",     "stack": 24,  "color": "f0c04a"},
	"ammo":     {"name": "Ammo",       "stack": 600, "color": "ff8c2d"},
	"core":     {"name": "Redline Core", "stack": 16, "color": "d02bff"},
}

signal vitals_changed()
signal inventory_changed()
signal phase_changed(phase: int)
signal stats_changed()

var phase: int = Phase.MENU

# --- Vitals ------------------------------------------------------------------
var health: float = GameConfig.PLAYER_MAX_HEALTH
var max_health: float = GameConfig.PLAYER_MAX_HEALTH
var stamina: float = GameConfig.PLAYER_MAX_STAMINA
var max_stamina: float = GameConfig.PLAYER_MAX_STAMINA
## Survival pressure. Drains slowly, faster in hostile zones; at zero it
## chews through health.
var integrity: float = 100.0
var ammo: int = 120

# --- Inventory ---------------------------------------------------------------
var inventory: Dictionary = {"scrap": 0, "cell": 0, "medkit": 1, "ration": 2, "ammo": 120, "core": 0}

# --- Run statistics ----------------------------------------------------------
var kills: int = 0
var distance_travelled: float = 0.0
var deepest_radius: float = 0.0
var deepest_zone: int = 0
var chunks_visited: int = 0
var play_seconds: float = 0.0
var objective_text: String = "Head away from the origin. The world gets heavier."
var objective_progress: float = 0.0

var _invulnerable: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func reset_run() -> void:
	health = max_health
	stamina = max_stamina
	integrity = 100.0
	inventory = {"scrap": 0, "cell": 0, "medkit": 1, "ration": 2, "ammo": 120, "core": 0}
	ammo = 120
	kills = 0
	distance_travelled = 0.0
	deepest_radius = 0.0
	deepest_zone = 0
	chunks_visited = 0
	play_seconds = 0.0
	objective_progress = 0.0
	objective_text = "Head away from the origin. The world gets heavier."
	vitals_changed.emit()
	inventory_changed.emit()
	stats_changed.emit()


func set_phase(p: int) -> void:
	if phase == p:
		return
	phase = p
	phase_changed.emit(phase)


func set_invulnerable(v: bool) -> void:
	_invulnerable = v


func is_invulnerable() -> bool:
	return _invulnerable


func damage(amount: float, source: String = "") -> void:
	if phase != Phase.PLAYING or _invulnerable or amount <= 0.0:
		return
	health = maxf(0.0, health - amount)
	EventBus.player_damaged.emit(amount, source)
	vitals_changed.emit()
	if health <= 0.0:
		set_phase(Phase.DEAD)
		EventBus.player_died.emit()


func heal(amount: float) -> void:
	if amount <= 0.0:
		return
	var before: float = health
	health = minf(max_health, health + amount)
	if health > before:
		EventBus.player_healed.emit(health - before)
		vitals_changed.emit()


func consume_stamina(amount: float) -> bool:
	if stamina < amount:
		return false
	stamina -= amount
	vitals_changed.emit()
	return true


func regen(delta: float, sprinting: bool, zone: int) -> void:
	if phase != Phase.PLAYING:
		return
	play_seconds += delta
	if sprinting:
		stamina = maxf(0.0, stamina - delta * 18.0)
	else:
		stamina = minf(max_stamina, stamina + delta * 13.0)

	# Deeper zones bleed integrity faster -- that is the survival pressure.
	var drain: float = 0.28 + float(zone) * 0.22
	integrity = maxf(0.0, integrity - delta * drain * 0.12)
	if integrity <= 0.0:
		health = maxf(0.0, health - delta * 2.4)
		if health <= 0.0 and phase == Phase.PLAYING:
			set_phase(Phase.DEAD)
			EventBus.player_died.emit()
	vitals_changed.emit()


func add_item(id: String, amount: int = 1) -> void:
	if not ITEM_DEFS.has(id) or amount <= 0:
		return
	var cap: int = int(ITEM_DEFS[id]["stack"])
	inventory[id] = clampi(int(inventory.get(id, 0)) + amount, 0, cap)
	if id == "ammo":
		ammo = int(inventory["ammo"])
	EventBus.item_collected.emit(id, amount)
	inventory_changed.emit()


func consume_item(id: String, amount: int = 1) -> bool:
	if int(inventory.get(id, 0)) < amount:
		return false
	inventory[id] = int(inventory[id]) - amount
	if id == "ammo":
		ammo = int(inventory["ammo"])
	inventory_changed.emit()
	return true


func use_medkit() -> bool:
	if not consume_item("medkit", 1):
		return false
	heal(45.0)
	return true


func use_ration() -> bool:
	if not consume_item("ration", 1):
		return false
	integrity = minf(100.0, integrity + 40.0)
	vitals_changed.emit()
	return true


func spend_ammo(n: int = 1) -> bool:
	if int(inventory.get("ammo", 0)) < n:
		return false
	inventory["ammo"] = int(inventory["ammo"]) - n
	ammo = int(inventory["ammo"])
	inventory_changed.emit()
	return true


func register_kill(kind: String, pos: Vector3) -> void:
	kills += 1
	EventBus.enemy_killed.emit(kind, pos)
	stats_changed.emit()


func register_travel(distance: float, pos: Vector3) -> void:
	distance_travelled += distance
	var r: float = Vector2(pos.x, pos.z).length()
	if r > deepest_radius:
		deepest_radius = r
		var z: int = GameConfig.zone_for_radius(r)
		if z > deepest_zone:
			deepest_zone = z
			set_objective(
				"Reached %s. Push further." % GameConfig.ZONE_NAMES[z],
				float(z) / float(GameConfig.ZONE_NAMES.size() - 1)
			)
		stats_changed.emit()


func set_objective(text: String, progress: float) -> void:
	objective_text = text
	objective_progress = clampf(progress, 0.0, 1.0)
	EventBus.objective_updated.emit(text, objective_progress)


func summary() -> Dictionary:
	return {
		"kills": kills,
		"distance_m": distance_travelled,
		"deepest_radius_m": deepest_radius,
		"deepest_zone": GameConfig.ZONE_NAMES[clampi(deepest_zone, 0, 6)],
		"chunks_visited": chunks_visited,
		"play_seconds": play_seconds,
		"inventory": inventory.duplicate(),
	}
