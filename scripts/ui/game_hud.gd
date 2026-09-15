class_name GameHUD
extends Control
## Gameplay interface, drawn rather than assembled from stock Controls.
##
## Everything lives in one _draw() pass: vitals cluster, ammo block, objective
## card, compass ribbon, dynamic reticle, damage arcs, zone banner and toasts.
## Doing it this way keeps the whole HUD to a handful of draw calls and makes
## the layout resolution-independent, which matters on a phone in landscape.

const SAFE: float = 26.0
const TOAST_MAX: int = 4

var player: PlayerController = null
var world: WorldManager = null
var touch: TouchInput = null
var perf_hud: PerfHUD = null

# --- Animated state --------------------------------------------------------
var _hp: float = 1.0
var _stam: float = 1.0
var _integ: float = 1.0
var _flash: float = 0.0
var _hit_marker: float = 0.0
var _kill_marker: float = 0.0
var _spread: float = 0.0
var _zone_timer: float = 0.0
var _zone_name: String = ""
var _prompt: String = ""
var _objective: String = ""
var _objective_progress: float = 0.0
var _objective_anim: float = 0.0
var _toasts: Array[Dictionary] = []
var _damage_marks: Array[Dictionary] = []
var _pulse: float = 0.0
var _aim_hostile: bool = false
var _aim_scan: float = 0.0


func _ready() -> void:
	name = "GameHUD"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_PAUSABLE

	EventBus.notice.connect(_on_notice)
	EventBus.objective_updated.connect(_on_objective)
	EventBus.zone_changed.connect(_on_zone)
	EventBus.player_damaged.connect(_on_damaged)
	EventBus.interact_prompt.connect(func(t: String) -> void: _prompt = t)
	EventBus.enemy_killed.connect(_on_kill)
	EventBus.item_collected.connect(_on_item)
	_objective = GameState.objective_text
	_objective_progress = GameState.objective_progress


func bind(p: PlayerController, w: WorldManager, t: TouchInput = null,
		perf: PerfHUD = null) -> void:
	player = p
	world = w
	touch = t
	perf_hud = perf
	if p != null:
		p.fired.connect(_on_fired)


## Touch pushes the vitals and ammo blocks inward, clear of the joystick and
## the action cluster; on desktop they sit in the corners.
func _touch_mode() -> bool:
	return touch != null and is_instance_valid(touch) and touch.is_enabled()


## The expanded telemetry panel owns the top-left quarter of the screen, so the
## navigation furniture stands down while it is up.
func _telemetry_expanded() -> bool:
	return perf_hud != null and is_instance_valid(perf_hud) \
		and perf_hud.mode == PerfHUD.Mode.EXPANDED


# --- Signals ---------------------------------------------------------------
func _on_notice(text: String, seconds: float) -> void:
	_toasts.push_back({"text": text, "life": seconds, "max": seconds, "age": 0.0,
		"color": UITheme.TEXT})
	while _toasts.size() > TOAST_MAX:
		_toasts.pop_front()


func _on_item(id: String, amount: int) -> void:
	var def: Dictionary = GameState.ITEM_DEFS.get(id, {})
	_toasts.push_back({
		"text": "+%d  %s" % [amount, String(def.get("name", id)).to_upper()],
		"life": 1.8, "max": 1.8, "age": 0.0,
		"color": Color(String(def.get("color", "9aa4b2"))),
	})
	while _toasts.size() > TOAST_MAX:
		_toasts.pop_front()


func _on_objective(text: String, progress: float) -> void:
	if text != _objective:
		_objective_anim = 1.0
	_objective = text
	_objective_progress = progress


func _on_zone(_id: int, zone_name: String) -> void:
	_zone_name = zone_name
	_zone_timer = 3.6


func _on_damaged(amount: float, _source: String, from_position: Vector3) -> void:
	_flash = clampf(_flash + amount * 0.016, 0.0, 0.6)
	if from_position == Vector3.INF or player == null or not is_instance_valid(player):
		return      # No direction to show -- falling, or integrity running out.
	# Screen-space bearing from the camera to whatever dealt the damage.
	var cam: Camera3D = player.camera
	if cam == null:
		return
	var local: Vector3 = cam.global_transform.affine_inverse() * from_position
	if absf(local.x) < 0.0001 and absf(local.z) < 0.0001:
		return
	# Camera space is -Z forward, +X right; screen angle 0 points up.
	var angle: float = atan2(local.x, -local.z) - PI * 0.5
	_damage_marks.push_back({
		"angle": angle, "life": 1.4, "power": clampf(amount / 30.0, 0.2, 1.0),
	})


func _on_fired(_from: Vector3, _to: Vector3, hit: bool) -> void:
	_spread = minf(_spread + 0.45, 1.0)
	if hit:
		_hit_marker = 1.0


func _on_kill(_kind: String, _pos: Vector3) -> void:
	_kill_marker = 1.0


# --- Update ----------------------------------------------------------------
func _process(delta: float) -> void:
	# Timed so the benchmark can separate this manager's script cost from
	# render and physics time. See PerformanceMonitor.record_subsystem.
	var _t0: int = Time.get_ticks_usec()
	_step_profiled(delta)
	PerformanceMonitor.record_subsystem("hud_game", Time.get_ticks_usec() - _t0)


func _step_profiled(delta: float) -> void:
	_pulse += delta
	var k: float = clampf(delta * 7.0, 0.0, 1.0)
	_hp = lerpf(_hp, GameState.health / maxf(1.0, GameState.max_health), k)
	_stam = lerpf(_stam, GameState.stamina / maxf(1.0, GameState.max_stamina), k)
	_integ = lerpf(_integ, GameState.integrity * 0.01, k)

	_flash = maxf(0.0, _flash - delta * 0.85)
	_hit_marker = maxf(0.0, _hit_marker - delta * 3.2)
	_kill_marker = maxf(0.0, _kill_marker - delta * 1.6)
	_spread = maxf(0.0, _spread - delta * 2.4)
	_zone_timer = maxf(0.0, _zone_timer - delta)
	_objective_anim = maxf(0.0, _objective_anim - delta * 0.8)

	for i in range(_toasts.size() - 1, -1, -1):
		_toasts[i]["age"] = float(_toasts[i]["age"]) + delta
		_toasts[i]["life"] = float(_toasts[i]["life"]) - delta
		if float(_toasts[i]["life"]) <= 0.0:
			_toasts.remove_at(i)

	for i in range(_damage_marks.size() - 1, -1, -1):
		_damage_marks[i]["life"] = float(_damage_marks[i]["life"]) - delta
		if float(_damage_marks[i]["life"]) <= 0.0:
			_damage_marks.remove_at(i)

	_aim_scan -= delta
	if _aim_scan <= 0.0:
		_aim_scan = 0.1
		_aim_hostile = _probe_target()

	queue_redraw()


## Is the reticle on something hostile? Drives the reticle colour, which is the
## only aim feedback a touch player gets.
func _probe_target() -> bool:
	if player == null or not is_instance_valid(player) or player.camera == null:
		return false
	var cam: Camera3D = player.camera
	var from: Vector3 = cam.global_position
	var to: Vector3 = from - cam.global_transform.basis.z * 120.0
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = GameConfig.L_ENEMY
	q.exclude = [player.get_rid()]
	return not space.intersect_ray(q).is_empty()


# --- Draw ------------------------------------------------------------------
func _draw() -> void:
	var vs: Vector2 = size
	# During a benchmark the player is on autopilot and invulnerable, and the
	# telemetry is the point, so the gameplay furniture stands down and leaves
	# the screen to the measurement overlay.
	if GameState.phase == GameState.Phase.BENCHMARK:
		_draw_reticle(vs)
		return
	_draw_damage_overlay(vs)
	_draw_vitals(vs)
	_draw_ammo(vs)
	_draw_objective(vs)
	_draw_compass(vs)
	_draw_reticle(vs)
	_draw_damage_arcs(vs)
	_draw_toasts(vs)
	_draw_prompt(vs)
	_draw_zone_banner(vs)


func _draw_damage_overlay(vs: Vector2) -> void:
	var hp_low: float = clampf((0.32 - _hp) / 0.32, 0.0, 1.0)
	var a: float = _flash + hp_low * (0.16 + 0.10 * sin(_pulse * 5.5))
	if a <= 0.002:
		return
	# Edge-weighted, so the centre of the screen stays readable while taking
	# hits. Four bands rather than a full-screen wash.
	var band: float = minf(vs.x, vs.y) * 0.22
	var col := Color(0.85, 0.08, 0.07, clampf(a, 0.0, 0.75))
	var fade := Color(0.85, 0.08, 0.07, 0.0)
	draw_rect(Rect2(0, 0, vs.x, band), col, true)
	draw_rect(Rect2(0, vs.y - band, vs.x, band), col, true)
	draw_rect(Rect2(0, 0, band, vs.y), col, true)
	draw_rect(Rect2(vs.x - band, 0, band, vs.y), col, true)
	# Soften the inner edge by overdrawing a slightly smaller transparent rect.
	draw_rect(Rect2(band * 0.55, band * 0.55,
		vs.x - band * 1.1, vs.y - band * 1.1), fade, true)


func _draw_vitals(vs: Vector2) -> void:
	var w: float = 268.0
	var h: float = 112.0
	var left: float = SAFE
	if _touch_mode():
		left = vs.x * 0.5 - w - 16.0
	var r := Rect2(left, vs.y - SAFE - h, w, h)
	UITheme.draw_panel(self, r, UITheme.BG, UITheme.EDGE)

	var x: float = r.position.x + 14.0
	var y: float = r.position.y + 20.0
	UITheme.draw_spaced(self, Vector2(x, y), "VITALS", 10, UITheme.TEXT_FAINT, 2.5)

	var low: bool = _hp < 0.32
	var hp_col: Color = UITheme.HEALTH
	if low:
		hp_col = UITheme.HEALTH.lerp(Color.WHITE, 0.35 + 0.35 * sin(_pulse * 6.0))

	var rows: Array = [
		["HP", _hp, hp_col, GameState.health],
		["STA", _stam, UITheme.STAMINA, GameState.stamina],
		["INT", _integ, UITheme.INTEGRITY, GameState.integrity],
	]
	var row_y: float = r.position.y + 30.0
	for row: Array in rows:
		UITheme.draw_text(self, Vector2(x, row_y + 9.0), String(row[0]), 11,
			UITheme.TEXT_DIM)
		var bar := Rect2(x + 34.0, row_y + 1.0, w - 100.0, 8.0)
		UITheme.draw_segmented_bar(self, bar, float(row[1]), row[2], 20, 2.0)
		UITheme.draw_text(self, Vector2(r.position.x + w - 14.0, row_y + 9.0),
			"%3d" % int(round(float(row[3]))), 11, row[2], 2)
		row_y += 15.0

	# Inventory strip
	var inv: Dictionary = GameState.inventory
	var items: Array = [["SCR", "scrap"], ["MED", "medkit"], ["RAT", "ration"],
		["CORE", "core"]]
	var ix: float = x
	var iy: float = r.position.y + h - 12.0
	for item: Array in items:
		var id: String = item[1]
		var count: int = int(inv.get(id, 0))
		var col := Color(String(GameState.ITEM_DEFS.get(id, {}).get("color", "9aa4b2")))
		if count <= 0:
			col = UITheme.TEXT_FAINT
		draw_rect(Rect2(ix, iy - 7.0, 3.0, 8.0), col, true)
		ix += 7.0
		ix += UITheme.draw_text(self, Vector2(ix, iy), String(item[0]), 10,
			UITheme.TEXT_FAINT) + 4.0
		ix += UITheme.draw_text(self, Vector2(ix, iy), str(count), 11,
			col if count > 0 else UITheme.TEXT_FAINT) + 11.0


func _draw_ammo(vs: Vector2) -> void:
	var w: float = 186.0
	var h: float = 84.0
	var left: float = vs.x - SAFE - w
	if _touch_mode():
		left = vs.x * 0.5 + 16.0
	var r := Rect2(left, vs.y - SAFE - h, w, h)
	UITheme.draw_panel(self, r, UITheme.BG, UITheme.EDGE)

	var right: float = r.position.x + w - 14.0
	UITheme.draw_spaced(self, Vector2(right, r.position.y + 20.0), "MK-IV PULSE", 10,
		UITheme.TEXT_FAINT, 2.0, 2)

	var ammo: int = GameState.ammo
	var col: Color = UITheme.TEXT if ammo > 20 else (
		UITheme.WARN if ammo > 0 else UITheme.ACCENT)
	UITheme.draw_text(self, Vector2(right, r.position.y + 58.0), str(ammo), 34, col, 2)
	UITheme.draw_text(self, Vector2(right - UITheme.text_width(str(ammo), 34) - 10.0,
		r.position.y + 58.0), "RDS", 10, UITheme.TEXT_FAINT, 2)

	# Magazine ticks: a quick read of how much is left without parsing a number.
	# Ticks show the next magazine's worth, which is the number that matters in
	# a fight; the raw total is already printed above.
	var ticks: int = 24
	var mag: float = 48.0
	var lit: int = clampi(int(ceil(minf(float(ammo), mag) / mag * float(ticks))), 0, ticks)
	var tx: float = r.position.x + 14.0
	var ty: float = r.position.y + h - 16.0
	for i in ticks:
		var c: Color = col if i < lit else Color(1, 1, 1, 0.10)
		draw_rect(Rect2(tx + float(i) * 6.4, ty, 4.0, 6.0), c, true)


func _draw_objective(vs: Vector2) -> void:
	if _objective == "" or _telemetry_expanded():
		return
	var w: float = 430.0
	var h: float = 50.0
	var r := Rect2((vs.x - w) * 0.5, SAFE, w, h)
	var glow: float = _objective_anim
	UITheme.draw_panel(self, r, UITheme.BG,
		UITheme.EDGE.lerp(UITheme.ACCENT_2, glow))

	# Accent flag on the leading edge.
	draw_rect(Rect2(r.position.x, r.position.y + 8.0, 3.0, h - 16.0),
		UITheme.ACCENT_2.lerp(Color.WHITE, glow * 0.6), true)

	UITheme.draw_text(self, Vector2(r.position.x + 14.0, r.position.y + 20.0),
		"OBJECTIVE", 9, UITheme.TEXT_FAINT)
	UITheme.draw_text(self, Vector2(r.position.x + 14.0, r.position.y + 34.0),
		_objective, 13, UITheme.TEXT)

	var pct: String = "%d%%" % int(round(_objective_progress * 100.0))
	UITheme.draw_text(self, Vector2(r.position.x + w - 14.0, r.position.y + 24.0),
		pct, 15, UITheme.ACCENT_2, 2)

	var track := Rect2(r.position.x + 14.0, r.position.y + h - 10.0, w - 28.0, 2.0)
	draw_rect(track, Color(1, 1, 1, 0.09), true)
	draw_rect(Rect2(track.position, Vector2(track.size.x * _objective_progress, 2.0)),
		UITheme.ACCENT_2, true)


## Heading ribbon with the cardinal marks, the outward bearing and how deep the
## player has pushed. In an open world where everything is "further out", the
## radius is the single most useful number on screen.
func _draw_compass(vs: Vector2) -> void:
	if player == null or not is_instance_valid(player) or _telemetry_expanded():
		return
	var w: float = 360.0
	var h: float = 22.0
	var r := Rect2((vs.x - w) * 0.5, SAFE + 64.0, w, h)

	var yaw: float = wrapf(-player.rotation.y, 0.0, TAU)
	var deg: float = rad_to_deg(yaw)
	var span: float = 140.0          # degrees visible across the ribbon

	draw_rect(r, Color(0.02, 0.025, 0.035, 0.72), true)
	draw_line(r.position, r.position + Vector2(r.size.x, 0.0), UITheme.EDGE, 1.0)
	draw_line(r.position + Vector2(0.0, h), r.position + Vector2(r.size.x, h),
		UITheme.EDGE, 1.0)

	var marks: Dictionary = {0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S",
		225: "SW", 270: "W", 315: "NW"}
	for d: int in marks.keys():
		var delta: float = wrapf(float(d) - deg + 180.0, 0.0, 360.0) - 180.0
		if absf(delta) > span * 0.5:
			continue
		var x: float = r.position.x + r.size.x * (0.5 + delta / span)
		var major: bool = int(d) % 90 == 0
		draw_line(Vector2(x, r.position.y + (4.0 if major else 8.0)),
			Vector2(x, r.position.y + h - 4.0),
			UITheme.TEXT if major else UITheme.TEXT_DIM, 1.0)
		if major:
			UITheme.draw_text(self, Vector2(x, r.position.y + h - 6.0),
				String(marks[d]), 10, UITheme.TEXT, 1)

	# Centre index
	draw_line(Vector2(r.position.x + r.size.x * 0.5, r.position.y),
		Vector2(r.position.x + r.size.x * 0.5, r.position.y + h), UITheme.ACCENT, 1.5)

	var radius: float = Vector2(player.global_position.x, player.global_position.z).length()
	var zone: int = GameConfig.zone_for_radius(radius)
	UITheme.draw_text(self, Vector2(r.position.x - 10.0, r.position.y + 15.0),
		"%03d" % int(deg), 12, UITheme.TEXT_DIM, 2)
	UITheme.draw_text(self, Vector2(r.position.x + r.size.x + 10.0, r.position.y + 15.0),
		"%.0f m  %s" % [radius, GameConfig.ZONE_NAMES[zone]], 11,
		UITheme.level_color(zone))


func _draw_reticle(vs: Vector2) -> void:
	var c: Vector2 = vs * 0.5
	var moving: float = 0.0
	if player != null and is_instance_valid(player):
		moving = clampf(Vector2(player.velocity.x, player.velocity.z).length() / 8.0,
			0.0, 1.0)
	var gap: float = 5.0 + moving * 6.0 + _spread * 9.0
	var arm: float = 7.0
	var col: Color = UITheme.ACCENT if _aim_hostile else Color(1, 1, 1, 0.8)

	var arms: Array[Vector2] = [
		Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]
	for dir: Vector2 in arms:
		draw_line(c + dir * gap, c + dir * (gap + arm), col, 1.7)
	draw_circle(c, 1.2, col)

	# Outer ring only when aiming at something hostile.
	if _aim_hostile:
		draw_arc(c, gap + arm + 6.0, 0.0, TAU, 32, Color(col.r, col.g, col.b, 0.45), 1.2)

	if _hit_marker > 0.0:
		var s: float = 9.0 + (1.0 - _hit_marker) * 7.0
		var hc := Color(1, 1, 1, _hit_marker)
		var corners: Array[Vector2] = [
			Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]
		for d: Vector2 in corners:
			draw_line(c + d * s, c + d * (s + 6.0), hc, 2.0)
	if _kill_marker > 0.0:
		var kc := Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b,
			_kill_marker)
		draw_arc(c, 18.0 + (1.0 - _kill_marker) * 10.0, 0.0, TAU, 24, kc, 2.0)


func _draw_damage_arcs(vs: Vector2) -> void:
	if _damage_marks.is_empty():
		return
	var c: Vector2 = vs * 0.5
	var radius: float = minf(vs.x, vs.y) * 0.31
	for m: Dictionary in _damage_marks:
		var a: float = float(m["angle"])
		var life: float = clampf(float(m["life"]) / 1.4, 0.0, 1.0)
		var col := Color(1.0, 0.22, 0.16, life * float(m["power"]))
		draw_arc(c, radius, a - 0.26, a + 0.26, 18, col, 5.0)


func _draw_toasts(vs: Vector2) -> void:
	var y: float = vs.y * 0.72
	for i in _toasts.size():
		var t: Dictionary = _toasts[i]
		var life: float = float(t["life"])
		var age: float = float(t["age"])
		var alpha: float = clampf(minf(life * 2.5, age * 5.0), 0.0, 1.0)
		var slide: float = (1.0 - clampf(age * 5.0, 0.0, 1.0)) * 18.0
		var txt: String = String(t["text"])
		var col: Color = t["color"]
		var w: float = UITheme.text_width(txt, 14) + 34.0
		var r := Rect2(vs.x * 0.5 - w * 0.5 + slide, y, w, 26.0)
		UITheme.draw_panel(self, r, Color(UITheme.BG.r, UITheme.BG.g, UITheme.BG.b,
			UITheme.BG.a * alpha), Color(1, 1, 1, 0.08 * alpha), 6.0)
		draw_rect(Rect2(r.position.x, r.position.y + 5.0, 2.5, 16.0),
			Color(col.r, col.g, col.b, alpha), true)
		UITheme.draw_text(self, Vector2(r.position.x + 12.0, r.position.y + 18.0),
			txt, 14, Color(UITheme.TEXT.r, UITheme.TEXT.g, UITheme.TEXT.b, alpha))
		y += 31.0


func _draw_prompt(vs: Vector2) -> void:
	if _prompt == "":
		return
	var c: Vector2 = Vector2(vs.x * 0.5, vs.y * 0.5 + 54.0)
	var w: float = UITheme.text_width(_prompt, 14) + 66.0
	var r := Rect2(c.x - w * 0.5, c.y - 15.0, w, 30.0)
	UITheme.draw_panel(self, r, UITheme.BG_DEEP, UITheme.EDGE_BRIGHT, 6.0)
	var key_r := Rect2(r.position.x + 8.0, r.position.y + 7.0, 34.0, 16.0)
	draw_rect(key_r, Color(1, 1, 1, 0.12), true)
	UITheme.draw_text(self, Vector2(key_r.position.x + 17.0, key_r.position.y + 12.0),
		"USE", 9, UITheme.TEXT, 1)
	UITheme.draw_text(self, Vector2(r.position.x + 50.0, r.position.y + 20.0),
		_prompt, 14, UITheme.TEXT)


func _draw_zone_banner(vs: Vector2) -> void:
	if _zone_timer <= 0.0 or _zone_name == "":
		return
	var t: float = _zone_timer / 3.6
	var alpha: float = clampf(minf(t * 3.0, (1.0 - t) * 6.0 + 0.2), 0.0, 1.0)
	var c := Vector2(vs.x * 0.5, vs.y * 0.34)
	var col := Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, alpha)

	# Rules wipe outward as the banner appears.
	var wipe: float = clampf((1.0 - t) * 2.6, 0.0, 1.0) * 210.0
	draw_line(Vector2(c.x - wipe, c.y - 26.0), Vector2(c.x + wipe, c.y - 26.0),
		Color(1, 1, 1, 0.22 * alpha), 1.0)
	draw_line(Vector2(c.x - wipe, c.y + 12.0), Vector2(c.x + wipe, c.y + 12.0),
		Color(1, 1, 1, 0.22 * alpha), 1.0)

	# Backing plate keeps the title legible over bright terrain.
	var tw: float = UITheme.text_width(_zone_name, 26) + float(_zone_name.length()) * 9.0
	draw_rect(Rect2(c.x - tw * 0.5 - 18.0, c.y - 22.0, tw + 36.0, 34.0),
		Color(0.02, 0.025, 0.035, 0.5 * alpha), true)
	UITheme.draw_spaced(self, Vector2(c.x, c.y + 4.0), _zone_name, 26, col, 9.0, 1)
	UITheme.draw_spaced(self, Vector2(c.x, c.y + 30.0), "ZONE ENTERED", 10,
		Color(UITheme.TEXT_DIM.r, UITheme.TEXT_DIM.g, UITheme.TEXT_DIM.b, alpha),
		4.0, 1)
