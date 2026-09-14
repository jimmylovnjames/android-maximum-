class_name BenchmarkOverlay
extends Control
## Live benchmark banner plus the results screen.
##
## The results screen prints exactly what was measured, including which metrics
## the platform did not provide.

signal closed()
signal rerun_requested(mode: int)

var _banner: _Banner
var _abort_button: Button

var _results_panel: Control
var _results_text: RichTextLabel
var _results_title: Label
var _headline: _Headline
var _saved_label: Label
var _last_mode: int = BenchmarkManager.Mode.STANDARD


func _ready() -> void:
	name = "BenchmarkOverlay"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_banner()
	_build_results()
	EventBus.benchmark_started.connect(_on_started)
	EventBus.benchmark_stage_changed.connect(_on_stage)
	EventBus.benchmark_finished.connect(_on_finished)
	EventBus.benchmark_aborted.connect(_on_aborted)


func _build_banner() -> void:
	_banner = _Banner.new()
	_banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	add_child(_banner)

	_abort_button = UITheme.button("ABORT BENCHMARK", 12)
	_abort_button.anchor_left = 0.5
	_abort_button.anchor_right = 0.5
	_abort_button.anchor_top = 0.0
	_abort_button.anchor_bottom = 0.0
	_abort_button.offset_left = -90.0
	_abort_button.offset_right = 90.0
	_abort_button.offset_top = 96.0
	_abort_button.offset_bottom = 130.0
	_abort_button.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_abort_button.visible = false
	_abort_button.pressed.connect(func() -> void: BenchmarkManager.abort("user aborted"))
	add_child(_abort_button)


## Progress strip drawn across the top of the screen: stage name, a pip per
## stage, the overall bar and a live figure row.
class _Banner extends Control:
	var stage_name: String = ""
	var stage_index: int = 0
	var stage_count: int = 0
	var progress: float = 0.0

	func _draw() -> void:
		var w: float = minf(size.x - 80.0, 620.0)
		var r := Rect2((size.x - w) * 0.5, 14.0, w, 76.0)
		UITheme.draw_panel(self, r, UITheme.BG_SOLID, UITheme.EDGE)
		UITheme.draw_brackets(self, r.grow(3.0), Color(1.0, 0.22, 0.18, 0.5), 16.0, 1.5)

		UITheme.draw_spaced(self, Vector2(r.position.x + 14.0, r.position.y + 20.0),
			"BENCHMARK RUNNING", 10, UITheme.ACCENT, 3.0)
		UITheme.draw_text(self, Vector2(r.position.x + w - 14.0, r.position.y + 20.0),
			"STAGE %d / %d" % [stage_index + 1, maxi(stage_count, 1)], 11,
			UITheme.TEXT_DIM, 2)
		UITheme.draw_text(self, Vector2(r.position.x + 14.0, r.position.y + 40.0),
			stage_name, 15, UITheme.TEXT)

		# Stage pips
		var px: float = r.position.x + 14.0
		var pw: float = (w - 28.0) / float(maxi(stage_count, 1))
		for i in maxi(stage_count, 1):
			var col: Color = UITheme.ACCENT if i < stage_index else (
				UITheme.ACCENT_SOFT if i == stage_index else Color(1, 1, 1, 0.14))
			draw_rect(Rect2(px + float(i) * pw, r.position.y + 50.0, pw - 3.0, 3.0),
				col, true)

		var track := Rect2(r.position.x + 14.0, r.position.y + 58.0, w - 28.0, 4.0)
		draw_rect(track, Color(1, 1, 1, 0.09), true)
		draw_rect(Rect2(track.position, Vector2(track.size.x * progress, 4.0)),
			UITheme.ACCENT, true)

		var p := PerformanceMonitor
		var line: String = "%.0f fps   %.1f ms   %s   %d npc   %d bodies   %.0f MB" % [
			p.fps, p.frame_ms, StressDirector.level_name(),
			int(p.counters.get("npc_total", 0)),
			int(p.counters.get("rigid_bodies", 0)), p.process_memory_mb()]
		UITheme.draw_text(self, Vector2(r.position.x + w * 0.5, r.position.y + 72.0),
			line, 11, UITheme.TEXT_DIM, 1)


func _build_results() -> void:
	_results_panel = Control.new()
	_results_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_results_panel.visible = false
	add_child(_results_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.025, 0.035, 0.9)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_results_panel.add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel(12, UITheme.BG_SOLID))
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 40
	panel.offset_right = -40
	panel.offset_top = 24
	panel.offset_bottom = -24
	_results_panel.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	_results_title = UITheme.heading("BENCHMARK RESULTS", 24, UITheme.ACCENT)
	col.add_child(_results_title)

	_headline = _Headline.new()
	col.add_child(_headline)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	_results_text = RichTextLabel.new()
	_results_text.bbcode_enabled = true
	_results_text.fit_content = true
	_results_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results_text.add_theme_font_size_override("normal_font_size", 13)
	_results_text.add_theme_font_size_override("bold_font_size", 13)
	scroll.add_child(_results_text)

	_saved_label = UITheme.label("", 11, UITheme.TEXT_FAINT)
	_saved_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_saved_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	var close_b: Button = UITheme.button("CLOSE", 15)
	close_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_b.pressed.connect(_close)
	row.add_child(close_b)
	var rerun: Button = UITheme.button("RUN AGAIN", 15)
	rerun.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rerun.pressed.connect(func() -> void:
		_results_panel.visible = false
		rerun_requested.emit(_last_mode))
	row.add_child(rerun)


func _close() -> void:
	_results_panel.visible = false
	closed.emit()


func _on_started(mode_name: String) -> void:
	_last_mode = (BenchmarkManager.Mode.ENDURANCE if mode_name == "ENDURANCE"
		else BenchmarkManager.Mode.STANDARD)
	_banner.visible = true
	_abort_button.visible = true
	_banner.progress = 0.0
	_banner.stage_count = (BenchmarkManager.STAGES_ENDURANCE.size()
		if _last_mode == BenchmarkManager.Mode.ENDURANCE
		else BenchmarkManager.STAGES_STANDARD.size())
	_results_panel.visible = false


func _on_stage(index: int, stage_name: String) -> void:
	_banner.stage_index = index
	_banner.stage_name = stage_name


func _on_aborted(reason: String) -> void:
	_banner.visible = false
	_abort_button.visible = false
	EventBus.notify("Benchmark aborted (%s)" % reason, 4.0)


func _process(_delta: float) -> void:
	if not BenchmarkManager.running:
		if _banner.visible:
			_banner.visible = false
			_abort_button.visible = false
		return
	_banner.progress = BenchmarkManager.progress()
	_banner.queue_redraw()


func _on_finished(r: Dictionary) -> void:
	_banner.visible = false
	_abort_button.visible = false
	_results_panel.visible = true
	_headline.set_results(r)
	_results_title.text = "REDLINE  %s BENCHMARK" % r.get("mode", "")

	var t: String = ""
	t += _kv("Device", "%s %s" % [r["device"]["os"], r["device"]["model"]])
	t += _kv("GPU", "%s (%s)" % [r["device"]["video_adapter"], r["device"]["video_api"]])
	t += _kv("CPU", "%s x%d" % [r["device"]["processor"], int(r["device"]["processor_count"])])
	t += _kv("Renderer", String(r["device"]["rendering_method"]).to_upper())
	t += _kv("Quality preset", "%s (render scale x%.2f)" % [
		r["quality_preset"], float(r["final_render_scale"])])
	t += _kv("World seed", str(r["world_seed"]))
	t += "\n[b][color=#ff3a2d]HEADLINE[/color][/b]\n"
	t += _kv("Duration", "%.1f s (%d frames)" % [
		float(r["duration_seconds"]), int(r["total_frames"])])
	t += _kv("Average FPS", "%.2f" % float(r["avg_fps"]))
	t += _kv("Minimum FPS", "%.2f" % float(r["min_fps"]))
	t += _kv("1% low FPS", ("%.2f" % float(r["low_1pc_fps"])) if bool(r["low_1pc_valid"])
		else "n/a (too few samples)")
	t += _kv("Average frame time", "%.2f ms" % float(r["avg_frame_ms"]))
	t += _kv("Worst frame time", "%.2f ms" % float(r["worst_frame_ms"]))
	t += _kv("Peak measured memory", "%.0f MB" % float(r["peak_measured_memory_mb"]))
	t += _kv("Max stress level", "%s (%d)" % [
		r["max_stress_name"], int(r["max_stress_level"])])

	t += "\n[b][color=#ff8c2d]BURST vs SUSTAINED[/color][/b]\n"
	t += _kv("First 25 s", "%.2f fps" % float(r["burst_fps_first_25s"]))
	t += _kv("Last 25 s", "%.2f fps" % float(r["sustained_fps_last_25s"]))
	t += _kv("Degradation", "%.1f %%" % float(r["sustained_degradation_percent"]))
	t += "[color=#6f7684]%s[/color]\n" % r["degradation_note"]

	t += "\n[b][color=#5ec8f0]GPU / DRAW[/color][/b]\n"
	if bool(r["gpu_time_available"]):
		t += _kv("Average GPU time", "%.2f ms" % float(r["avg_gpu_ms"]))
		t += _kv("Worst GPU time", "%.2f ms" % float(r["worst_gpu_ms"]))
	else:
		t += _kv("GPU timing", "n/a (not reported by this platform)")
	var fs: Dictionary = r["final_snapshot"]
	if bool(r["draw_call_metrics_available"]):
		t += _kv("Draw calls (final)", str(int(fs.get("draw_calls", -1))))
		t += _kv("Objects (final)", str(int(fs.get("objects_in_frame", -1))))
		t += _kv("Primitives (final)", str(int(fs.get("primitives", -1))))
	else:
		t += _kv("Draw call metrics", "n/a")

	t += "\n[b][color=#f0c04a]PEAK WORLD LOAD[/color][/b]\n"
	var pc: Dictionary = r["peak_counters"]
	for key: String in ["npc_total", "npc_full", "npc_reduced", "enemies", "vehicles",
			"rigid_bodies", "multimesh_instances", "omni_lights", "particles",
			"chunks_loaded", "chunks_cached", "chunk_cache_mb"]:
		if pc.has(key):
			t += _kv(key.replace("_", " "), "%.0f" % float(pc[key]))

	t += "\n[b][color=#3ad17c]STAGES[/color][/b]\n"
	for s: Dictionary in r["stages"]:
		t += "[color=#c8ccd4]%-24s[/color] %5.1f fps avg | %5.1f min | %5.1f 1%% low | %6.2f ms worst | %s\n" % [
			String(s["name"]), float(s["avg_fps"]), float(s["min_fps"]),
			float(s["low_1pc_fps"]), float(s["worst_frame_ms"]), String(s["stress_name"]),
		]

	t += "\n[color=#6f7684]%s[/color]\n" % r["memory_note"]
	_results_text.text = t

	var saved: String = String(r.get("saved_to", ""))
	_saved_label.text = ("Results JSON written to: " + saved) if saved != "" else \
		"Results could not be written to disk on this platform."


func _kv(k: String, v: String) -> String:
	return "[color=#7a8390]%s:[/color] [b]%s[/b]\n" % [k, v]


## The five figures that answer "how did this device do". Everything else is
## detail below the fold.
class _Headline extends Control:
	var tiles: Array[Dictionary] = []

	func _init() -> void:
		custom_minimum_size = Vector2(0, 96)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_results(r: Dictionary) -> void:
		var low: String = ("%.1f" % float(r["low_1pc_fps"])) if bool(r["low_1pc_valid"]) \
			else "n/a"
		tiles = [
			{"label": "AVERAGE FPS", "value": "%.1f" % float(r["avg_fps"]),
				"color": UITheme.value_color(float(r["avg_fps"]), 50.0, 24.0)},
			{"label": "1% LOW", "value": low, "color": UITheme.ACCENT_2},
			{"label": "MINIMUM FPS", "value": "%.1f" % float(r["min_fps"]),
				"color": UITheme.value_color(float(r["min_fps"]), 40.0, 15.0)},
			{"label": "PEAK MEMORY", "value": "%.0f MB" % float(
				r["peak_measured_memory_mb"]), "color": UITheme.TEXT},
			{"label": "MAX STRESS", "value": String(r["max_stress_name"]),
				"color": UITheme.level_color(int(r["max_stress_level"]))},
			{"label": "SUSTAINED DROP", "value": "%.1f %%" % float(
				r["sustained_degradation_percent"]), "color": UITheme.WARN},
		]
		queue_redraw()

	func _draw() -> void:
		if tiles.is_empty():
			return
		var n: int = tiles.size()
		var gap: float = 8.0
		var w: float = (size.x - gap * float(n - 1)) / float(n)
		for i in n:
			var t: Dictionary = tiles[i]
			var r := Rect2(float(i) * (w + gap), 0.0, w, 88.0)
			UITheme.draw_panel(self, r, UITheme.BG, UITheme.EDGE, 8.0)
			var col: Color = t["color"]
			draw_rect(Rect2(r.position.x, r.position.y, w, 3.0), col, true)
			UITheme.draw_spaced(self, Vector2(r.position.x + 12.0, r.position.y + 26.0),
				String(t["label"]), 9, UITheme.TEXT_FAINT, 2.0)
			UITheme.draw_text(self, Vector2(r.position.x + 12.0, r.position.y + 62.0),
				String(t["value"]), 26, col)
