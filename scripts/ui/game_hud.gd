class_name GameHUD
extends Control
## Gameplay overlay: vitals, ammo, objective, crosshair, notices and the zone
## banner. Deliberately anchored well inside the edges so it stays readable on
## a phone in landscape with rounded corners and a camera cutout.

const SAFE: float = 26.0

var _health_bar: ProgressBar
var _stamina_bar: ProgressBar
var _integrity_bar: ProgressBar
var _ammo_label: Label
var _items_label: Label
var _objective_label: Label
var _zone_label: Label
var _notice_label: Label
var _prompt_label: Label
var _damage_flash: ColorRect
var _crosshair: Control
var _notice_time: float = 0.0
var _flash: float = 0.0
var _zone_time: float = 0.0
var _stats_label: Label


func _ready() -> void:
	name = "GameHUD"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_PAUSABLE

	_damage_flash = ColorRect.new()
	_damage_flash.color = Color(0.8, 0.05, 0.05, 0.0)
	_damage_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_damage_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_damage_flash)

	_build_vitals()
	_build_center()
	_build_top()

	GameState.vitals_changed.connect(_refresh_vitals)
	GameState.inventory_changed.connect(_refresh_inventory)
	GameState.stats_changed.connect(_refresh_stats)
	EventBus.notice.connect(_on_notice)
	EventBus.objective_updated.connect(_on_objective)
	EventBus.zone_changed.connect(_on_zone)
	EventBus.player_damaged.connect(_on_damaged)
	EventBus.interact_prompt.connect(_on_prompt)
	_refresh_vitals()
	_refresh_inventory()
	_refresh_stats()


func _make_bar(color: Color, width: float) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(width, 9)
	b.show_percentage = false
	b.max_value = 100.0
	b.value = 100.0
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.55)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	fg.set_corner_radius_all(3)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	return b


func _build_vitals() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel(7))
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = SAFE
	panel.offset_top = -108.0
	panel.offset_bottom = -SAFE
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	panel.add_child(col)

	_health_bar = _make_bar(UITheme.HEALTH, 208)
	_stamina_bar = _make_bar(UITheme.STAMINA, 208)
	_integrity_bar = _make_bar(UITheme.INTEGRITY, 208)

	col.add_child(UITheme.label("VITALS", 10, UITheme.TEXT_FAINT))
	col.add_child(_health_bar)
	col.add_child(_stamina_bar)
	col.add_child(_integrity_bar)
	_items_label = UITheme.label("", 11, UITheme.TEXT_DIM)
	col.add_child(_items_label)


func _build_center() -> void:
	_crosshair = Control.new()
	_crosshair.name = "Crosshair"
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.draw.connect(_draw_crosshair)
	add_child(_crosshair)

	_prompt_label = UITheme.label("", 15, UITheme.ACCENT_2)
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER)
	_prompt_label.offset_top = 42.0
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_prompt_label)

	_notice_label = UITheme.label("", 17, UITheme.TEXT)
	_notice_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_notice_label.offset_top = 96.0
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_notice_label)

	_zone_label = UITheme.label("", 30, UITheme.ACCENT)
	_zone_label.set_anchors_preset(Control.PRESET_CENTER)
	_zone_label.offset_top = -70.0
	_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zone_label.modulate.a = 0.0
	_zone_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_zone_label)


func _build_top() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel(7))
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.offset_top = SAFE
	panel.offset_left = -190.0
	panel.offset_right = 190.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	panel.add_child(col)
	_objective_label = UITheme.label("", 13, UITheme.TEXT)
	_objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_objective_label.custom_minimum_size = Vector2(360, 0)
	_objective_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_objective_label)
	_stats_label = UITheme.label("", 11, UITheme.TEXT_FAINT)
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_stats_label)

	var right := PanelContainer.new()
	right.add_theme_stylebox_override("panel", UITheme.panel(7))
	right.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	right.offset_right = -SAFE
	right.offset_bottom = -SAFE
	right.offset_left = -180.0
	right.offset_top = -56.0
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(right)
	_ammo_label = UITheme.label("", 22, UITheme.TEXT)
	_ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(_ammo_label)


func _draw_crosshair() -> void:
	var c: Vector2 = size * 0.5
	var col := Color(1, 1, 1, 0.72)
	var gap: float = 5.0
	var len_v: float = 7.0
	_crosshair.draw_line(c + Vector2(-gap - len_v, 0), c + Vector2(-gap, 0), col, 1.6)
	_crosshair.draw_line(c + Vector2(gap, 0), c + Vector2(gap + len_v, 0), col, 1.6)
	_crosshair.draw_line(c + Vector2(0, -gap - len_v), c + Vector2(0, -gap), col, 1.6)
	_crosshair.draw_line(c + Vector2(0, gap), c + Vector2(0, gap + len_v), col, 1.6)
	_crosshair.draw_circle(c, 1.1, col)


func _refresh_vitals() -> void:
	_health_bar.value = GameState.health / GameState.max_health * 100.0
	_stamina_bar.value = GameState.stamina / GameState.max_stamina * 100.0
	_integrity_bar.value = GameState.integrity


func _refresh_inventory() -> void:
	_ammo_label.text = "%d" % GameState.ammo
	var inv: Dictionary = GameState.inventory
	_items_label.text = "SCRAP %d   MED %d   RAT %d   CORE %d" % [
		int(inv.get("scrap", 0)), int(inv.get("medkit", 0)),
		int(inv.get("ration", 0)), int(inv.get("core", 0)),
	]


func _refresh_stats() -> void:
	_stats_label.text = "KILLS %d    TRAVELLED %.0f m    DEEPEST %.0f m" % [
		GameState.kills, GameState.distance_travelled, GameState.deepest_radius,
	]


func _on_notice(text: String, seconds: float) -> void:
	_notice_label.text = text
	_notice_time = seconds


func _on_objective(text: String, progress: float) -> void:
	_objective_label.text = "%s  [%d%%]" % [text, int(progress * 100.0)]


func _on_zone(_zone_id: int, zone_name: String) -> void:
	_zone_label.text = zone_name
	_zone_time = 3.2


func _on_damaged(amount: float, _source: String) -> void:
	_flash = clampf(_flash + amount * 0.014, 0.0, 0.55)


func _on_prompt(text: String) -> void:
	_prompt_label.text = ("[ USE ]  " + text) if text != "" else ""


func _process(delta: float) -> void:
	if _notice_time > 0.0:
		_notice_time -= delta
		_notice_label.modulate.a = clampf(_notice_time, 0.0, 1.0)
	elif _notice_label.text != "":
		_notice_label.text = ""

	if _zone_time > 0.0:
		_zone_time -= delta
		_zone_label.modulate.a = clampf(_zone_time * 0.7, 0.0, 1.0)
	elif _zone_label.modulate.a > 0.0:
		_zone_label.modulate.a = 0.0

	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 0.9)
		_damage_flash.color.a = _flash

	# Low health vignette pulse.
	var hp: float = GameState.health / GameState.max_health
	if hp < 0.3 and GameState.phase == GameState.Phase.PLAYING:
		_damage_flash.color.a = maxf(_damage_flash.color.a,
			(0.3 - hp) * 0.6 * (0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.005)))
