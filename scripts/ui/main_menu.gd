class_name MainMenu
extends Control
## Title screen. Draws its own backdrop and wordmark; the buttons are real
## Controls because they need input, but everything behind them is a single
## _draw() pass.

signal play_requested()
signal benchmark_requested(mode: int)
signal settings_requested()
signal quit_requested()

var _buttons: VBoxContainer
var _t: float = 0.0
var _device_lines: PackedStringArray = PackedStringArray()


func _ready() -> void:
	name = "MainMenu"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP

	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 8)
	_buttons.anchor_left = 0.5
	_buttons.anchor_right = 0.5
	_buttons.anchor_top = 0.5
	_buttons.anchor_bottom = 0.5
	_buttons.offset_left = -180.0
	_buttons.offset_right = 180.0
	_buttons.offset_top = -40.0
	_buttons.offset_bottom = 200.0
	_buttons.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(_buttons)

	_add_button("ENTER THE WORLD", 17, func() -> void: play_requested.emit(), true)
	_add_button("STANDARD BENCHMARK  ~2 MIN", 13,
		func() -> void: benchmark_requested.emit(BenchmarkManager.Mode.STANDARD))
	_add_button("ENDURANCE BENCHMARK  ~6 MIN", 13,
		func() -> void: benchmark_requested.emit(BenchmarkManager.Mode.ENDURANCE))
	_add_button("SETTINGS", 13, func() -> void: settings_requested.emit())
	_add_button("QUIT", 13, func() -> void: quit_requested.emit())
	refresh()


func _add_button(text: String, size: int, cb: Callable, primary: bool = false) -> void:
	var b: Button = UITheme.button(text, size)
	if primary:
		b.custom_minimum_size = Vector2(0, 56)
		b.add_theme_stylebox_override("normal",
			UITheme.stylebox(Color(0.20, 0.055, 0.05, 0.95), UITheme.ACCENT))
		b.add_theme_stylebox_override("hover",
			UITheme.stylebox(Color(0.34, 0.08, 0.07, 0.98), Color(1, 0.45, 0.35)))
	b.pressed.connect(cb)
	_buttons.add_child(b)


func refresh() -> void:
	var d: Dictionary = PerformanceMonitor.device_info()
	var ram: String = ("%.0f MB" % float(d["physical_memory_mb"])
		if float(d["physical_memory_mb"]) > 0.0 else "n/a")
	_device_lines = PackedStringArray([
		"%s  %s" % [String(d["os"]).to_upper(), String(d["model"]).to_upper()],
		"%s   %d CORES   %s" % [d["processor"], int(d["processor_count"]), ram],
		"%s   %s" % [String(d["video_adapter"]) if String(d["video_adapter"]) != ""
			else "no adapter reported", String(d["rendering_method"]).to_upper()],
		"PRESET %s  (%s)" % [AdaptiveQualityManager.preset_name(),
			AdaptiveQualityManager.detect_reason()],
		"STRESS %s   SEED %d   GODOT %s" % [StressDirector.level_name(),
			GameConfig.world_seed, d["godot_version"]],
	])
	queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	queue_redraw()


func _draw() -> void:
	var vs: Vector2 = size
	# Backdrop: deep vertical gradient plus a faint horizon band.
	draw_rect(Rect2(Vector2.ZERO, vs), Color(0.024, 0.028, 0.038), true)
	var bands: int = 40
	for i in bands:
		var f: float = float(i) / float(bands - 1)
		var a: float = pow(1.0 - absf(f - 0.62) * 2.4, 3.0)
		if a <= 0.0:
			continue
		draw_rect(Rect2(0.0, vs.y * f, vs.x, vs.y / float(bands) + 1.0),
			Color(0.10, 0.03, 0.03, clampf(a, 0.0, 1.0) * 0.5), true)

	# Slow scanline sweep.
	var sweep: float = fposmod(_t * 0.08, 1.4) - 0.2
	draw_rect(Rect2(0.0, vs.y * sweep, vs.x, 2.0), Color(1.0, 0.25, 0.2, 0.05), true)

	var cx: float = vs.x * 0.5
	var top: float = vs.y * 0.5 - 150.0

	# Rev-limiter trace under the wordmark: a needle climbing into the red.
	var trace: PackedVector2Array = PackedVector2Array()
	var w: float = 330.0
	var base_y: float = top + 104.0
	var pts: Array[Vector2] = [
		Vector2(-1.00, 0.06), Vector2(-0.74, -0.10), Vector2(-0.56, 0.14),
		Vector2(-0.34, -0.28), Vector2(-0.12, 0.10), Vector2(0.08, -0.46),
		Vector2(0.28, 0.04), Vector2(0.46, -0.72), Vector2(0.64, -0.20),
		Vector2(0.80, -1.00), Vector2(1.00, -0.34)]
	for p: Vector2 in pts:
		trace.append(Vector2(cx + p.x * w, base_y + p.y * 46.0))
	# Baseline the trace sits on, then the trace itself.
	draw_line(Vector2(cx - w, base_y + 6.0), Vector2(cx + w, base_y + 6.0),
		Color(1, 1, 1, 0.10), 1.0)
	draw_polyline(trace, Color(1.0, 0.22, 0.18, 0.55), 2.5, true)
	# Redline marker at the right-hand end.
	draw_rect(Rect2(cx + w * 0.68, base_y - 52.0, w * 0.34, 58.0),
		Color(1.0, 0.18, 0.14, 0.07), true)
	draw_line(Vector2(cx + w * 0.68, base_y - 52.0),
		Vector2(cx + w * 0.68, base_y + 6.0), Color(1.0, 0.22, 0.18, 0.45), 1.5)

	UITheme.draw_spaced(self, Vector2(cx, top + 26.0), "REDLINE", 58,
		Color(0.97, 0.97, 0.98), 16.0, 1)
	draw_rect(Rect2(cx - 210.0, top + 40.0, 420.0, 2.0), UITheme.ACCENT, true)
	UITheme.draw_spaced(self, Vector2(cx, top + 64.0),
		"OPEN WORLD SURVIVAL / MOBILE HARDWARE TORTURE TEST", 11,
		UITheme.TEXT_DIM, 2.4, 1)

	# Device readout, bottom-left, framed like an instrument.
	var box := Rect2(30.0, vs.y - 126.0, 400.0, 100.0)
	UITheme.draw_panel(self, box, UITheme.BG, UITheme.EDGE)
	UITheme.draw_brackets(self, box.grow(3.0), Color(1, 0.25, 0.2, 0.35), 14.0, 1.5)
	UITheme.draw_spaced(self, Vector2(box.position.x + 14.0, box.position.y + 20.0),
		"DETECTED HARDWARE", 9, UITheme.ACCENT_2, 2.5)
	var y: float = box.position.y + 38.0
	for line: String in _device_lines:
		UITheme.draw_text(self, Vector2(box.position.x + 14.0, y), line, 11,
			UITheme.TEXT_DIM)
		y += 14.0

	# Level ladder, bottom-right: shows what the stress levels actually are.
	var lx: float = vs.x - 40.0
	var ly: float = vs.y - 126.0
	UITheme.draw_spaced(self, Vector2(lx, ly), "STRESS LEVELS", 9,
		UITheme.ACCENT_2, 2.5, 2)
	for i in StressDirector.LEVEL_NAMES.size():
		var col: Color = UITheme.level_color(i)
		var yy: float = ly + 18.0 + float(i) * 15.0
		UITheme.draw_text(self, Vector2(lx, yy), StressDirector.LEVEL_NAMES[i], 11,
			col if i == StressDirector.level else Color(col.r, col.g, col.b, 0.45), 2)
		draw_rect(Rect2(lx + 6.0, yy - 8.0, 4.0 + float(i) * 5.0, 8.0),
			Color(col.r, col.g, col.b, 0.75), true)
