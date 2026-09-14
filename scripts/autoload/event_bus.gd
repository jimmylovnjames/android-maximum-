extends Node
## Global signal hub. Keeps managers decoupled: nothing needs a direct reference
## to anything else just to broadcast a fact about the world.

# --- World / streaming -------------------------------------------------------
signal chunk_loaded(coord: Vector2i)
signal chunk_unloaded(coord: Vector2i)
signal world_ready()
signal zone_changed(zone_id: int, zone_name: String)

# --- Player ------------------------------------------------------------------
signal player_spawned(player: Node3D)
signal player_damaged(amount: float, source: String)
signal player_died()
signal player_healed(amount: float)
signal item_collected(item_id: String, amount: int)
signal objective_updated(text: String, progress: float)
signal interact_prompt(text: String)

# --- Combat ------------------------------------------------------------------
signal shot_fired(from: Vector3, to: Vector3)
signal enemy_killed(kind: String, position: Vector3)
signal explosion(position: Vector3, radius: float, force: float)

# --- Systems -----------------------------------------------------------------
signal stress_level_changed(level: int, profile: Dictionary)
signal quality_preset_changed(preset: int, name: String)
signal benchmark_started(mode: String)
signal benchmark_stage_changed(index: int, name: String)
signal benchmark_finished(results: Dictionary)
signal benchmark_aborted(reason: String)
signal notice(text: String, seconds: float)

# --- Debug / safety ----------------------------------------------------------
signal safety_throttle(reason: String)


func notify(text: String, seconds: float = 2.5) -> void:
	notice.emit(text, seconds)
