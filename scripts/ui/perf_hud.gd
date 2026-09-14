class_name PerfHUD
extends Control
## Real-time benchmark overlay.
##
## Every figure comes from Performance / RenderingServer / OS. Metrics the
## platform does not expose render as "n/a" -- nothing here is synthesised.

enum Mode { OFF, COMPACT, EXPANDED }

const REFRESH_HZ: float = 10.0

var mode: int = Mode.COMPACT

var _root: VBoxContainer
var _compact_panel: PanelContainer
var _expanded_panel: PanelContainer
var _grid: GridContainer
var _values: Dictionary = {}
var _compact_label: RichTextLabel
var _fps_graph: GraphPanel
var _frame_graph: GraphPanel
var _mem_graph: GraphPanel
var _gpu_graph: GraphPanel
var _accum: float = 0.0
var _world: WorldManager = null
var _device_label: Label


func _ready() -> void:
	name = "PerfHUD"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = 14
	offset_top = 14
	process_mode = Node.PROCESS_MODE_ALWAYS

	_root = VBoxContainer.new()
	_root.add_theme_constant_override("separation", 6)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_compact()
	_build_expanded()
	set_mode(int(GameConfig.settings.get("hud_mode", Mode.COMPACT)))


func bind_world(w: WorldManager) -> void:
	_world = w


func _build_compact() -> void:
	_compact_panel = PanelContainer.new()
	_compact_panel.add_theme_stylebox_override("panel", UITheme.panel(6))
	_compact_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compact_label = RichTextLabel.new()
	_compact_label.bbcode_enabled = true
	_compact_label.fit_content = true
	_compact_label.scroll_active = false
	_compact_label.custom_minimum_size = Vector2(260, 0)
	_compact_label.add_theme_font_size_override("normal_font_size", 14)
	_compact_label.add_theme_font_size_override("bold_font_size", 14)
	_compact_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compact_panel.add_child(_compact_label)
	_root.add_child(_compact_panel)


func _build_expanded() -> void:
	_expanded_panel = PanelContainer.new()
	_expanded_panel.add_theme_stylebox_override("panel", UITheme.panel(8))
	_expanded_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 5)
	_expanded_panel.add_child(col)

	col.add_child(UITheme.heading("REDLINE  BENCHMARK TELEMETRY", 14, UITheme.ACCENT))
	_device_label = UITheme.label("", 11, UITheme.TEXT_FAINT)
	_device_label.custom_minimum_size = Vector2(430, 0)
	_device_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_device_label)

	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 2)
	col.add_child(_grid)

	var rows: PackedStringArray = [
		"FPS", "FRAME", "AVG FPS", "MIN FPS",
		"1% LOW", "PROCESS", "PHYSICS", "RENDER CPU",
		"RENDER GPU", "DRAW CALLS", "OBJECTS", "PRIMITIVES",
		"VIDEO MEM", "TEXTURE MEM", "STATIC MEM", "GAME MEM",
		"OS RAM FREE", "NODES", "PHYS BODIES", "PHYS PAIRS",
		"NPC TOTAL", "NPC FULL", "NPC REDUCED", "NPC BG",
		"ENEMIES", "VEHICLES", "RIGID BODIES", "PROJECTILES",
		"MM INSTANCES", "PARTICLES", "OMNI LIGHTS", "STREAM QUEUE",
		"CHUNKS LOAD", "CHUNKS CACHE", "CACHE MB", "CHUNK GEN",
		"STRESS", "QUALITY", "RENDER SCALE", "ZONE",
	]
	for r: String in rows:
		_add_metric(r)

	var graphs := HBoxContainer.new()
	graphs.add_theme_constant_override("separation", 6)
	col.add_child(graphs)

	_fps_graph = GraphPanel.new()
	_fps_graph.title = "FPS"
	_fps_graph.buffer = PerformanceMonitor.fps_history
	_fps_graph.line_color = UITheme.GOOD
	_fps_graph.show_target = true
	_fps_graph.target_value = 60.0
	graphs.add_child(_fps_graph)

	_frame_graph = GraphPanel.new()
	_frame_graph.title = "FRAME ms"
	_frame_graph.buffer = PerformanceMonitor.frame_ms_history
	_frame_graph.line_color = UITheme.WARN
	_frame_graph.decimals = 1
	graphs.add_child(_frame_graph)

	var graphs2 := HBoxContainer.new()
	graphs2.add_theme_constant_override("separation", 6)
	col.add_child(graphs2)

	_mem_graph = GraphPanel.new()
	_mem_graph.title = "GAME MEM MB"
	_mem_graph.buffer = PerformanceMonitor.mem_history
	_mem_graph.line_color = UITheme.ACCENT_2
	_mem_graph.decimals = 0
	graphs2.add_child(_mem_graph)

	_gpu_graph = GraphPanel.new()
	_gpu_graph.title = "GPU ms"
	_gpu_graph.buffer = PerformanceMonitor.gpu_history
	_gpu_graph.line_color = UITheme.ACCENT
	_gpu_graph.decimals = 2
	graphs2.add_child(_gpu_graph)

	_root.add_child(_expanded_panel)
	_expanded_panel.visible = false


func _add_metric(key: String) -> void:
	var name_label: Label = UITheme.label(key, 11, UITheme.TEXT_FAINT)
	name_label.custom_minimum_size = Vector2(92, 0)
	var val_label: Label = UITheme.label("-", 12, UITheme.TEXT)
	val_label.custom_minimum_size = Vector2(78, 0)
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_grid.add_child(name_label)
	_grid.add_child(val_label)
	_values[key] = val_label


func set_mode(m: int) -> void:
	mode = clampi(m, Mode.OFF, Mode.EXPANDED)
	visible = mode != Mode.OFF
	_compact_panel.visible = mode == Mode.COMPACT
	_expanded_panel.visible = mode == Mode.EXPANDED
	GameConfig.settings["hud_mode"] = mode
	GameConfig.save_settings()
	if mode == Mode.EXPANDED and _device_label != null:
		var d: Dictionary = PerformanceMonitor.device_info()
		_device_label.text = "%s / %s / %s | %s | %s | Godot %s" % [
			d["os"], d["model"], d["processor"], d["video_adapter"],
			String(d["rendering_method"]).to_upper(), d["godot_version"],
		]


func cycle() -> void:
	set_mode(wrapi(mode + 1, 0, 3))


func toggle() -> void:
	set_mode(Mode.OFF if mode != Mode.OFF else Mode.COMPACT)


func _process(delta: float) -> void:
	if mode == Mode.OFF:
		return
	_accum += delta
	if _accum < 1.0 / REFRESH_HZ:
		return
	_accum = 0.0
	if mode == Mode.COMPACT:
		_refresh_compact()
	else:
		_refresh_expanded()


func _fps_color(f: float) -> Color:
	return UITheme.value_color(f, 50.0, 24.0)


func _refresh_compact() -> void:
	var p := PerformanceMonitor
	var lv: Color = StressDirector.level_color()
	var c: Color = _fps_color(p.fps)
	var gpu: String = ("%.2f ms" % p.render_gpu_ms) if p.have_gpu_time else "n/a"
	var dc: String = str(p.draw_calls) if p.have_draw_calls else "n/a"
	_compact_label.text = (
		"[b][color=#%s]%3.0f FPS[/color][/b]  [color=#7a8390]%.1f ms[/color]\n" % [
			c.to_html(false), p.fps, p.frame_ms]
		+ "[color=#7a8390]gpu[/color] %s  [color=#7a8390]draws[/color] %s\n" % [gpu, dc]
		+ "[color=#7a8390]mem[/color] %.0f MB  [color=#7a8390]npc[/color] %d  "
			% [p.process_memory_mb(), int(p.counters.get("npc_total", 0))]
		+ "[color=#7a8390]rb[/color] %d\n" % int(p.counters.get("rigid_bodies", 0))
		+ "[b][color=#%s]%s[/color][/b]  [color=#7a8390]%s  x%.2f[/color]" % [
			lv.to_html(false),
			StressDirector.level_name() + (" AUTO" if StressDirector.auto_mode else ""),
			AdaptiveQualityManager.preset_name(),
			AdaptiveQualityManager.current_render_scale()]
	)


func _set_metric(key: String, text: String, color: Color = UITheme.TEXT) -> void:
	var l: Label = _values.get(key, null)
	if l == null:
		return
	l.text = text
	l.add_theme_color_override("font_color", color)


func _refresh_expanded() -> void:
	var p := PerformanceMonitor
	var c := p.counters

	_set_metric("FPS", "%.0f" % p.fps, _fps_color(p.fps))
	_set_metric("FRAME", "%.2f ms" % p.frame_ms)
	_set_metric("AVG FPS", "%.1f" % p.avg_fps, _fps_color(p.avg_fps))
	_set_metric("MIN FPS", "%.0f" % p.min_fps_recent, _fps_color(p.min_fps_recent))
	_set_metric("1% LOW", ("%.1f" % p.low_1pc_fps) if p.low_1pc_fps > 0.0 else "n/a",
		_fps_color(p.low_1pc_fps) if p.low_1pc_fps > 0.0 else UITheme.TEXT_FAINT)
	_set_metric("PROCESS", "%.2f ms" % p.process_ms)
	_set_metric("PHYSICS", "%.2f ms" % p.physics_ms)
	_set_metric("RENDER CPU", p.metric_text(p.render_cpu_ms, p.have_render_cpu_time, " ms", 2))
	_set_metric("RENDER GPU", p.metric_text(p.render_gpu_ms, p.have_gpu_time, " ms", 2))
	_set_metric("DRAW CALLS", str(p.draw_calls) if p.have_draw_calls else "n/a")
	_set_metric("OBJECTS", str(p.objects_in_frame) if p.have_draw_calls else "n/a")
	_set_metric("PRIMITIVES", _short(p.primitives) if p.have_draw_calls else "n/a")
	_set_metric("VIDEO MEM", p.metric_text(p.video_mem_mb, p.have_video_mem, " MB", 0))
	_set_metric("TEXTURE MEM", p.metric_text(p.texture_mem_mb, p.have_video_mem, " MB", 0))
	_set_metric("STATIC MEM", "%.0f MB" % p.static_mem_mb)
	_set_metric("GAME MEM", "%.0f MB" % p.process_memory_mb())
	_set_metric("OS RAM FREE", p.metric_text(p.os_mem_available_mb, p.have_os_memory, " MB", 0))
	_set_metric("NODES", str(p.node_count))
	_set_metric("PHYS BODIES", str(p.physics_active))
	_set_metric("PHYS PAIRS", str(p.physics_pairs))

	_set_metric("NPC TOTAL", str(int(c.get("npc_total", 0))))
	_set_metric("NPC FULL", str(int(c.get("npc_full", 0))))
	_set_metric("NPC REDUCED", str(int(c.get("npc_reduced", 0))))
	_set_metric("NPC BG", str(int(c.get("npc_background", 0))))
	_set_metric("ENEMIES", str(int(c.get("enemies", 0))), UITheme.ACCENT)
	_set_metric("VEHICLES", str(int(c.get("vehicles", 0))))
	_set_metric("RIGID BODIES", str(int(c.get("rigid_bodies", 0))))
	_set_metric("PROJECTILES", str(int(c.get("projectiles", 0))))
	_set_metric("MM INSTANCES", _short(int(c.get("multimesh_instances", 0))))
	_set_metric("PARTICLES", str(int(c.get("particles", 0))))
	_set_metric("OMNI LIGHTS", str(int(c.get("omni_lights", 0))))
	_set_metric("STREAM QUEUE", str(int(c.get("stream_queue", 0))))
	_set_metric("CHUNKS LOAD", str(int(c.get("chunks_loaded", 0))))
	_set_metric("CHUNKS CACHE", str(int(c.get("chunks_cached", 0))))
	_set_metric("CACHE MB", "%.1f" % float(c.get("chunk_cache_mb", 0.0)))

	var ws: Dictionary = _world.world_stats() if (_world != null and is_instance_valid(_world)) \
		else {}
	_set_metric("CHUNK GEN", "%.1f ms" % float(ws.get("chunk_gen_ms", 0.0)))
	_set_metric("STRESS", StressDirector.level_name() + (" A" if StressDirector.auto_mode else ""),
		StressDirector.level_color())
	_set_metric("QUALITY", AdaptiveQualityManager.preset_name(), UITheme.ACCENT_2)
	_set_metric("RENDER SCALE", "x%.2f" % AdaptiveQualityManager.current_render_scale())
	_set_metric("ZONE", String(ws.get("zone", "-")), UITheme.WARN)

	_fps_graph.refresh()
	_frame_graph.refresh()
	_mem_graph.refresh()
	_gpu_graph.refresh()


static func _short(v: int) -> String:
	if v >= 1000000:
		return "%.2fM" % (float(v) / 1000000.0)
	if v >= 1000:
		return "%.1fk" % (float(v) / 1000.0)
	return str(v)
