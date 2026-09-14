class_name MainMenu
extends Control
## Title screen. Also the only place the world is not yet streaming, so it
## doubles as the "cold start" state.

signal play_requested()
signal benchmark_requested(mode: int)
signal settings_requested()
signal quit_requested()

var _info: Label


func _ready() -> void:
	name = "MainMenu"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.035, 0.04, 0.05, 1.0)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel(14, UITheme.BG_SOLID))
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	var title: Label = UITheme.heading("R E D L I N E", 46, UITheme.ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	var sub: Label = UITheme.label(
		"open-world survival  /  mobile hardware torture test", 13, UITheme.TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(sub)

	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 10)
	col.add_child(sep)

	var play: Button = UITheme.button("ENTER THE WORLD", 18)
	play.pressed.connect(func() -> void: play_requested.emit())
	col.add_child(play)

	var bench: Button = UITheme.button("RUN STANDARD BENCHMARK", 15)
	bench.pressed.connect(func() -> void:
		benchmark_requested.emit(BenchmarkManager.Mode.STANDARD))
	col.add_child(bench)

	var endur: Button = UITheme.button("RUN ENDURANCE BENCHMARK", 15)
	endur.pressed.connect(func() -> void:
		benchmark_requested.emit(BenchmarkManager.Mode.ENDURANCE))
	col.add_child(endur)

	var settings: Button = UITheme.button("SETTINGS", 15)
	settings.pressed.connect(func() -> void: settings_requested.emit())
	col.add_child(settings)

	var quit: Button = UITheme.button("QUIT", 15)
	quit.pressed.connect(func() -> void: quit_requested.emit())
	col.add_child(quit)

	_info = UITheme.label("", 11, UITheme.TEXT_FAINT)
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_info)
	refresh()


func refresh() -> void:
	var d: Dictionary = PerformanceMonitor.device_info()
	_info.text = "%s %s | %s | %s\ndetected preset %s (%s) | stress %s | seed %d" % [
		d["os"], d["model"], d["processor"], d["video_adapter"],
		AdaptiveQualityManager.preset_name(), AdaptiveQualityManager.detect_reason(),
		StressDirector.level_name(), GameConfig.world_seed,
	]
