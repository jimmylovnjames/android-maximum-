class_name PauseMenu
extends Control
## Pause / settings screen. Every control here maps to a live system so the
## effect of a change is visible the moment the menu closes.

signal resume_requested()
signal respawn_requested()
signal quit_requested()
signal benchmark_requested(mode: int)

var _stress_buttons: Array[Button] = []
var _quality_buttons: Array[Button] = []
var _auto_button: Button
var _adaptive_button: Button
var _highmem_button: Button
var _touch_button: Button
var _hud_button: Button
var _invert_button: Button
var _sens_slider: HSlider
var _time_slider: HSlider
var _weather_button: Button
var _info_label: Label
var _world: WorldManager = null


func _ready() -> void:
	name = "PauseMenu"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	var backdrop := _Backdrop.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 40
	scroll.offset_right = -40
	scroll.offset_top = 24
	scroll.offset_bottom = -24
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var center := HBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	scroll.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UITheme.stylebox(UITheme.BG_SOLID, Color(1, 1, 1, 0.13), 10))
	panel.custom_minimum_size = Vector2(700, 0)
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	panel.add_child(col)

	col.add_child(_Title.new())
	_info_label = UITheme.label("", 11, UITheme.TEXT_FAINT)
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_info_label)
	col.add_child(_sep())

	# --- Stress -------------------------------------------------------------
	col.add_child(_Section.new("STRESS LEVEL"))
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 5)
	col.add_child(srow)
	for i in StressDirector.LEVEL_NAMES.size():
		var b: Button = UITheme.button(StressDirector.LEVEL_NAMES[i], 12)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_stress.bind(i))
		srow.add_child(b)
		_stress_buttons.append(b)
	_auto_button = UITheme.button("AUTO RAMP: OFF", 13)
	_auto_button.pressed.connect(_on_auto)
	col.add_child(_auto_button)

	# --- Quality ------------------------------------------------------------
	col.add_child(_sep())
	col.add_child(_Section.new("QUALITY PRESET"))
	var qrow := HBoxContainer.new()
	qrow.add_theme_constant_override("separation", 5)
	col.add_child(qrow)
	for i in AdaptiveQualityManager.PRESET_NAMES.size():
		var qb: Button = UITheme.button(AdaptiveQualityManager.PRESET_NAMES[i], 12)
		qb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		qb.pressed.connect(_on_quality.bind(i))
		qrow.add_child(qb)
		_quality_buttons.append(qb)

	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 5)
	col.add_child(trow)
	_adaptive_button = UITheme.button("ADAPTIVE: ON", 12)
	_adaptive_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_adaptive_button.pressed.connect(_on_adaptive)
	trow.add_child(_adaptive_button)
	_highmem_button = UITheme.button("HIGH MEMORY: OFF", 12)
	_highmem_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_highmem_button.pressed.connect(_on_highmem)
	trow.add_child(_highmem_button)

	# --- Interface ----------------------------------------------------------
	col.add_child(_sep())
	col.add_child(_Section.new("INTERFACE"))
	var irow := HBoxContainer.new()
	irow.add_theme_constant_override("separation", 5)
	col.add_child(irow)
	_hud_button = UITheme.button("HUD: COMPACT", 12)
	_hud_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hud_button.pressed.connect(_on_hud)
	irow.add_child(_hud_button)
	_touch_button = UITheme.button("TOUCH: AUTO", 12)
	_touch_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_touch_button.pressed.connect(_on_touch)
	irow.add_child(_touch_button)
	_invert_button = UITheme.button("INVERT Y: OFF", 12)
	_invert_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_invert_button.pressed.connect(_on_invert)
	irow.add_child(_invert_button)

	col.add_child(UITheme.label("LOOK SENSITIVITY", 11, UITheme.TEXT_FAINT))
	_sens_slider = HSlider.new()
	_sens_slider.min_value = 0.25
	_sens_slider.max_value = 3.0
	_sens_slider.step = 0.05
	_sens_slider.value = float(GameConfig.settings.get("look_sensitivity", 1.0))
	_sens_slider.custom_minimum_size = Vector2(0, 26)
	_sens_slider.value_changed.connect(_on_sens)
	col.add_child(_sens_slider)

	# --- World --------------------------------------------------------------
	col.add_child(_sep())
	col.add_child(_Section.new("WORLD"))
	col.add_child(UITheme.label("TIME OF DAY", 11, UITheme.TEXT_FAINT))
	_time_slider = HSlider.new()
	_time_slider.min_value = 0.0
	_time_slider.max_value = 23.99
	_time_slider.step = 0.25
	_time_slider.value = 9.5
	_time_slider.custom_minimum_size = Vector2(0, 26)
	_time_slider.value_changed.connect(_on_time)
	col.add_child(_time_slider)
	_weather_button = UITheme.button("WEATHER: CLEAR", 12)
	_weather_button.pressed.connect(_on_weather)
	col.add_child(_weather_button)

	# --- Benchmark ----------------------------------------------------------
	col.add_child(_sep())
	col.add_child(_Section.new("BENCHMARK"))
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 5)
	col.add_child(brow)
	var b1: Button = UITheme.button("RUN STANDARD (~2 min)", 13)
	b1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b1.pressed.connect(func() -> void: benchmark_requested.emit(BenchmarkManager.Mode.STANDARD))
	brow.add_child(b1)
	var b2: Button = UITheme.button("ENDURANCE (~7 min)", 13)
	b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b2.pressed.connect(func() -> void: benchmark_requested.emit(BenchmarkManager.Mode.ENDURANCE))
	brow.add_child(b2)

	# --- Session ------------------------------------------------------------
	col.add_child(_sep())
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 5)
	col.add_child(arow)
	var resume: Button = UITheme.button("RESUME", 15)
	resume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resume.pressed.connect(func() -> void: resume_requested.emit())
	arow.add_child(resume)
	var respawn: Button = UITheme.button("RESTART RUN", 15)
	respawn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	respawn.pressed.connect(func() -> void: respawn_requested.emit())
	arow.add_child(respawn)
	var quit: Button = UITheme.button("QUIT", 15)
	quit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quit.pressed.connect(func() -> void: quit_requested.emit())
	arow.add_child(quit)

	col.add_child(UITheme.label(
		"Desktop: WASD move, mouse look, Shift sprint, Ctrl crouch, Space jump, "
		+ "E interact, LMB fire, 1 medkit, 2 ration, F1 HUD, F2 HUD mode, "
		+ "F3 touch UI, F5 benchmark, F6 endurance, [ ] stress, \\ auto, Esc pause.",
		10, UITheme.TEXT_FAINT))


## Backdrop: dimmed, with a faint technical grid so the menu sits on something
## rather than floating over a flat wash.
class _Backdrop extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.016, 0.020, 0.028, 0.90), true)
		var step: float = 44.0
		var col := Color(1, 1, 1, 0.022)
		var x: float = 0.0
		while x < size.x:
			draw_line(Vector2(x, 0), Vector2(x, size.y), col, 1.0)
			x += step
		var y: float = 0.0
		while y < size.y:
			draw_line(Vector2(0, y), Vector2(size.x, y), col, 1.0)
			y += step
		draw_rect(Rect2(0, 0, size.x, 3), Color(1.0, 0.2, 0.16, 0.5), true)
		draw_rect(Rect2(0, size.y - 3, size.x, 3), Color(1.0, 0.2, 0.16, 0.5), true)


class _Title extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(0, 58)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		UITheme.draw_spaced(self, Vector2(0.0, 40.0), "REDLINE", 34,
			Color(0.97, 0.97, 0.98), 10.0)
		var w: float = 260.0
		draw_rect(Rect2(0.0, 48.0, w, 2.0), UITheme.ACCENT, true)
		UITheme.draw_text(self, Vector2(w + 12.0, 40.0), "PAUSED", 13,
			UITheme.TEXT_FAINT)


## Section heading: label plus a rule that runs to the edge of the panel.
class _Section extends Control:
	var title: String = ""

	func _init(t: String) -> void:
		title = t
		custom_minimum_size = Vector2(0, 26)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w: float = UITheme.draw_spaced(self, Vector2(0.0, 18.0), title, 11,
			UITheme.ACCENT_2, 3.0)
		draw_rect(Rect2(w + 14.0, 12.0, maxf(0.0, size.x - w - 14.0), 1.0),
			Color(1, 1, 1, 0.10), true)


func _sep() -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, 8)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s


func bind_world(w: WorldManager) -> void:
	_world = w


func open() -> void:
	visible = true
	refresh()


func close() -> void:
	visible = false


func refresh() -> void:
	for i in _stress_buttons.size():
		_mark_active(_stress_buttons[i], i == StressDirector.level,
			UITheme.level_color(i))
	for i in _quality_buttons.size():
		_mark_active(_quality_buttons[i], i == AdaptiveQualityManager.preset,
			UITheme.ACCENT_2)
	_auto_button.text = "AUTO RAMP: %s" % ("ON" if StressDirector.auto_mode else "OFF")
	_adaptive_button.text = "ADAPTIVE: %s" % (
		"ON" if AdaptiveQualityManager.adaptive_enabled else "OFF")
	_highmem_button.text = "HIGH MEMORY: %s" % (
		"ON" if bool(GameConfig.settings.get("high_memory_mode", false)) else "OFF")
	var hud_mode: int = int(GameConfig.settings.get("hud_mode", 1))
	_hud_button.text = "HUD: %s" % ["OFF", "COMPACT", "EXPANDED"][clampi(hud_mode, 0, 2)]
	var tpref: int = int(GameConfig.settings.get("touch_controls", -1))
	_touch_button.text = "TOUCH: %s" % ["AUTO", "OFF", "ON"][clampi(tpref + 1, 0, 2)]
	_invert_button.text = "INVERT Y: %s" % (
		"ON" if bool(GameConfig.settings.get("invert_look", false)) else "OFF")
	if _world != null and is_instance_valid(_world) and _world.weather != null:
		_weather_button.text = "WEATHER: %s" % _world.weather.state_name()
		_time_slider.set_value_no_signal(_world.day_night.hours)

	var d: Dictionary = PerformanceMonitor.device_info()
	var stress: Dictionary = StressDirector.effective
	_info_label.text = (
		"%s %s | %s | %s | %d cores | RAM %s\n" % [
			d["os"], d["model"], d["processor"], d["video_adapter"],
			int(d["processor_count"]),
			("%.0f MB" % float(d["physical_memory_mb"])) if float(d["physical_memory_mb"]) > 0.0
				else "n/a",
		]
		+ "auto-detected preset: %s (%s)\n" % [
			AdaptiveQualityManager.PRESET_NAMES[AdaptiveQualityManager.preset],
			AdaptiveQualityManager.detect_reason()]
		+ "workload now: %d npc / %d enemies / %d vehicles / %d bodies / "
			% [int(stress.get("npc_count", 0)), int(stress.get("enemy_count", 0)),
				int(stress.get("vehicle_count", 0)), int(stress.get("rigid_bodies", 0))]
		+ "stream r=%d / view %.0f m / cache %d MB" % [
			int(stress.get("stream_radius", 0)), float(stress.get("view_distance", 0.0)),
			int(stress.get("cache_mb", 0))]
	)


## Selected options get a filled, accented box; the rest stay recessive. Using
## modulate for this washes the label out along with the frame.
func _mark_active(b: Button, active: bool, col: Color) -> void:
	if active:
		b.add_theme_stylebox_override("normal",
			UITheme.stylebox(Color(col.r * 0.30, col.g * 0.30, col.b * 0.30, 0.95), col))
		b.add_theme_color_override("font_color", Color.WHITE)
	else:
		b.add_theme_stylebox_override("normal",
			UITheme.stylebox(Color(0.075, 0.088, 0.115, 0.95), Color(1, 1, 1, 0.10)))
		b.add_theme_color_override("font_color", UITheme.TEXT_DIM)


func _on_stress(i: int) -> void:
	StressDirector.set_auto(false)
	StressDirector.set_level(i)
	refresh()


func _on_auto() -> void:
	StressDirector.set_auto(not StressDirector.auto_mode)
	refresh()


func _on_quality(i: int) -> void:
	AdaptiveQualityManager.apply_preset(i)
	refresh()


func _on_adaptive() -> void:
	AdaptiveQualityManager.set_adaptive(not AdaptiveQualityManager.adaptive_enabled)
	refresh()


func _on_highmem() -> void:
	var v: bool = not bool(GameConfig.settings.get("high_memory_mode", false))
	GameConfig.settings["high_memory_mode"] = v
	GameConfig.save_settings()
	StressDirector.set_level(StressDirector.level, false)
	StressDirector._recompute()
	refresh()


func _on_hud() -> void:
	var m: int = wrapi(int(GameConfig.settings.get("hud_mode", 1)) + 1, 0, 3)
	GameConfig.settings["hud_mode"] = m
	GameConfig.save_settings()
	var hud: PerfHUD = get_tree().root.find_child("PerfHUD", true, false) as PerfHUD
	if hud != null:
		hud.set_mode(m)
	refresh()


func _on_touch() -> void:
	var p: int = int(GameConfig.settings.get("touch_controls", -1))
	p = -1 if p == 1 else (p + 1 if p < 1 else -1)
	if p < -1:
		p = -1
	GameConfig.settings["touch_controls"] = p
	GameConfig.save_settings()
	var t: TouchInput = get_tree().root.find_child("TouchInput", true, false) as TouchInput
	if t != null:
		t.set_enabled(t.should_be_enabled())
	refresh()


func _on_invert() -> void:
	var v: bool = not bool(GameConfig.settings.get("invert_look", false))
	GameConfig.settings["invert_look"] = v
	GameConfig.save_settings()
	if _world != null and _world.player != null:
		_world.player.invert_look = v
	refresh()


func _on_sens(v: float) -> void:
	GameConfig.settings["look_sensitivity"] = v
	GameConfig.save_settings()
	if _world != null and _world.player != null:
		_world.player.look_sensitivity = v
	if _world != null and _world.touch != null:
		_world.touch.look_sensitivity = v


func _on_time(v: float) -> void:
	if _world != null and _world.day_night != null:
		_world.day_night.set_time(v)


func _on_weather() -> void:
	if _world != null and _world.weather != null:
		_world.weather.auto_cycle = false
		_world.weather.cycle()
		refresh()
