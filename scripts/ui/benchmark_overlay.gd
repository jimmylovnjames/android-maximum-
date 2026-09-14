class_name BenchmarkOverlay
extends Control
## Live benchmark banner plus the results screen.
##
## The results screen prints exactly what was measured, including which metrics
## the platform did not provide.

signal closed()
signal rerun_requested(mode: int)

var _banner: PanelContainer
var _stage_label: Label
var _progress: ProgressBar
var _live_label: Label
var _abort_button: Button

var _results_panel: Control
var _results_text: RichTextLabel
var _results_title: Label
var _saved_label: Label
var _last_mode: int = BenchmarkManager.Mode.STANDARD


func _ready() -> void:
	name = "BenchmarkOverlay"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_banner()
	_build_results()
	EventBus.benchmark_started.connect(_on_started)
	EventBus.benchmark_stage_changed.connect(_on_stage)
	EventBus.benchmark_finished.connect(_on_finished)
	EventBus.benchmark_aborted.connect(_on_aborted)


func _build_banner() -> void:
	_banner = PanelContainer.new()
	_banner.add_theme_stylebox_override("panel", UITheme.panel(8))
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.offset_top = 16
	_banner.offset_left = -270
	_banner.offset_right = 270
	_banner.visible = false
	add_child(_banner)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_banner.add_child(col)

	_stage_label = UITheme.label("", 16, UITheme.ACCENT)
	_stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_stage_label)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(510, 10)
	_progress.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.5)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = UITheme.ACCENT
	fg.set_corner_radius_all(3)
	_progress.add_theme_stylebox_override("background", bg)
	_progress.add_theme_stylebox_override("fill", fg)
	col.add_child(_progress)

	_live_label = UITheme.label("", 12, UITheme.TEXT_DIM)
	_live_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_live_label)

	_abort_button = UITheme.button("ABORT BENCHMARK", 12)
	_abort_button.pressed.connect(func() -> void: BenchmarkManager.abort("user aborted"))
	col.add_child(_abort_button)


func _build_results() -> void:
	_results_panel = Control.new()
	_results_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_results_panel.visible = false
	add_child(_results_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.025, 0.035, 0.9)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_results_panel.add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel(12, UITheme.BG_SOLID))
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
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
	_results_panel.visible = false
	_progress.value = 0.0


func _on_stage(index: int, stage_name: String) -> void:
	_stage_label.text = "STAGE %d  %s" % [index + 1, stage_name]


func _on_aborted(reason: String) -> void:
	_banner.visible = false
	EventBus.notify("Benchmark aborted (%s)" % reason, 4.0)


func _process(_delta: float) -> void:
	if not BenchmarkManager.running:
		if _banner.visible:
			_banner.visible = false
		return
	_progress.value = BenchmarkManager.progress() * 100.0
	var p := PerformanceMonitor
	_live_label.text = "%.0f fps   %.1f ms   %s   %d npc   %d bodies   %.0f MB" % [
		p.fps, p.frame_ms, StressDirector.level_name(),
		int(p.counters.get("npc_total", 0)), int(p.counters.get("rigid_bodies", 0)),
		p.process_memory_mb(),
	]


func _on_finished(r: Dictionary) -> void:
	_banner.visible = false
	_results_panel.visible = true
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
