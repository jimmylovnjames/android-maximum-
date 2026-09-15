class_name PerfHUD
extends Control
## Real-time benchmark overlay, drawn in one pass.
##
## Every figure comes from Performance / RenderingServer / OS. Metrics the
## platform does not expose render as "n/a" -- nothing here is synthesised.
## Drawing it rather than building a tree of Labels keeps the expanded panel
## (40+ live values and four graphs) off the UI update path entirely.

enum Mode { OFF, COMPACT, EXPANDED }

const REFRESH_HZ: float = 12.0
const PAD: float = 14.0
const ROW_H: float = 15.0

var mode: int = Mode.COMPACT

var _world: WorldManager = null
var _accum: float = 0.0
var _device_line: String = ""
var _pulse: float = 0.0


func _ready() -> void:
	name = "PerfHUD"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_mode(int(GameConfig.settings.get("hud_mode", Mode.COMPACT)))


func bind_world(w: WorldManager) -> void:
	_world = w


func set_mode(m: int) -> void:
	mode = clampi(m, Mode.OFF, Mode.EXPANDED)
	visible = mode != Mode.OFF
	GameConfig.settings["hud_mode"] = mode
	GameConfig.save_settings()
	var d: Dictionary = PerformanceMonitor.device_info()
	_device_line = "%s / %s / %s / %s / %s / GODOT %s" % [
		String(d["os"]).to_upper(), d["model"], d["processor"],
		String(d["video_adapter"]) if String(d["video_adapter"]) != "" else "no adapter",
		String(d["rendering_method"]).to_upper(), d["godot_version"],
	]
	queue_redraw()


func cycle() -> void:
	set_mode(wrapi(mode + 1, 0, 3))


func toggle() -> void:
	set_mode(Mode.OFF if mode != Mode.OFF else Mode.COMPACT)


func _process(delta: float) -> void:
	# Timed so the benchmark can separate this manager's script cost from
	# render and physics time. See PerformanceMonitor.record_subsystem.
	var _t0: int = Time.get_ticks_usec()
	_step_profiled(delta)
	PerformanceMonitor.record_subsystem("hud_perf", Time.get_ticks_usec() - _t0)


func _step_profiled(delta: float) -> void:
	if mode == Mode.OFF:
		return
	_pulse += delta
	_accum += delta
	if _accum < 1.0 / REFRESH_HZ:
		return
	_accum = 0.0
	queue_redraw()


func _fps_color(f: float) -> Color:
	return UITheme.value_color(f, 50.0, 24.0)


func _draw() -> void:
	if mode == Mode.COMPACT:
		_draw_compact()
	elif mode == Mode.EXPANDED:
		_draw_expanded()


# -----------------------------------------------------------------------------
# Compact
# -----------------------------------------------------------------------------
func _draw_compact() -> void:
	var p := PerformanceMonitor
	var w: float = 250.0
	var h: float = 96.0
	var r := Rect2(PAD, PAD, w, h)
	UITheme.draw_panel(self, r, UITheme.BG, UITheme.EDGE)

	var fc: Color = _fps_color(p.fps)
	UITheme.draw_text(self, Vector2(r.position.x + 12.0, r.position.y + 34.0),
		"%.0f" % p.fps, 30, fc)
	var fw: float = UITheme.text_width("%.0f" % p.fps, 30)
	UITheme.draw_text(self, Vector2(r.position.x + 16.0 + fw, r.position.y + 34.0),
		"FPS", 11, UITheme.TEXT_FAINT)
	UITheme.draw_text(self, Vector2(r.position.x + 16.0 + fw, r.position.y + 22.0),
		"%.1f ms" % p.frame_ms, 11, UITheme.TEXT_DIM)

	# Inline FPS sparkline.
	_draw_spark(Rect2(r.position.x + w - 96.0, r.position.y + 12.0, 84.0, 26.0),
		p.fps_history, fc)

	var y: float = r.position.y + 56.0
	var cells: Array = [
		["GPU", ("%.1f" % p.render_gpu_ms) if p.have_gpu_time else "n/a"],
		["DRAW", str(p.draw_calls) if p.have_draw_calls else "n/a"],
		["MEM", "%.0f" % p.process_memory_mb()],
		["NPC", str(int(p.counters.get("npc_total", 0)))],
	]
	var cw: float = (w - 24.0) / float(cells.size())
	for i in cells.size():
		var cx: float = r.position.x + 12.0 + float(i) * cw
		UITheme.draw_text(self, Vector2(cx, y), String(cells[i][0]), 9,
			UITheme.TEXT_FAINT)
		UITheme.draw_text(self, Vector2(cx, y + 13.0), String(cells[i][1]), 12,
			UITheme.TEXT)

	# Stress / quality chips.
	var chip_y: float = r.position.y + h - 12.0
	var lv: Color = StressDirector.level_color()
	var label: String = StressDirector.level_name() + (
		"  AUTO" if StressDirector.auto_mode else "")
	var lw: float = UITheme.text_width(label, 11) + 14.0
	draw_rect(Rect2(r.position.x + 12.0, chip_y - 11.0, lw, 15.0),
		Color(lv.r, lv.g, lv.b, 0.22), true)
	draw_rect(Rect2(r.position.x + 12.0, chip_y - 11.0, 2.0, 15.0), lv, true)
	UITheme.draw_text(self, Vector2(r.position.x + 19.0, chip_y), label, 11, lv)
	UITheme.draw_text(self, Vector2(r.position.x + w - 12.0, chip_y),
		"%s  x%.2f" % [AdaptiveQualityManager.preset_name(),
			AdaptiveQualityManager.current_render_scale()], 11, UITheme.TEXT_DIM, 2)


func _draw_spark(r: Rect2, buf: RingBuffer, col: Color) -> void:
	if buf == null or buf.size() < 2:
		return
	var n: int = buf.size()
	var hi: float = maxf(buf.maximum(), 0.001)
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		pts[i] = Vector2(
			r.position.x + float(i) / float(n - 1) * r.size.x,
			r.position.y + r.size.y - clampf(buf.get_at(i) / hi, 0.0, 1.0) * r.size.y)
	draw_polyline(pts, Color(col.r, col.g, col.b, 0.8), 1.2, true)


# -----------------------------------------------------------------------------
# Expanded
# -----------------------------------------------------------------------------
func _draw_expanded() -> void:
	var p := PerformanceMonitor
	var c: Dictionary = p.counters
	var ws: Dictionary = _world.world_stats() if (_world != null and is_instance_valid(_world)) \
		else {}

	# Three columns keeps the panel short enough to leave the bottom of a
	# landscape phone screen free for the gameplay HUD.
	var w: float = 690.0
	var cols: int = 3
	var col_w: float = (w - PAD * 2.0) / float(cols)
	var groups: Array = [
		["FRAME", [
			["FPS", "%.0f" % p.fps, _fps_color(p.fps)],
			["FRAME TIME", "%.2f ms" % p.frame_ms, UITheme.TEXT],
			["AVG FPS", "%.1f" % p.avg_fps, _fps_color(p.avg_fps)],
			["MIN FPS", "%.0f" % p.min_fps_recent, _fps_color(p.min_fps_recent)],
			["1% LOW", ("%.1f" % p.low_1pc_fps) if p.low_1pc_fps > 0.0 else "n/a",
				_fps_color(p.low_1pc_fps) if p.low_1pc_fps > 0.0 else UITheme.TEXT_FAINT],
			["PROCESS", "%.2f ms" % p.process_ms, UITheme.TEXT],
			["PHYSICS", "%.2f ms" % p.physics_ms, UITheme.TEXT],
		]],
		["RENDER", [
			["RENDER CPU", p.metric_text(p.render_cpu_ms, p.have_render_cpu_time, " ms", 2),
				UITheme.TEXT],
			["RENDER GPU", p.metric_text(p.render_gpu_ms, p.have_gpu_time, " ms", 2),
				UITheme.ACCENT_2],
			["DRAW CALLS", str(p.draw_calls) if p.have_draw_calls else "n/a", UITheme.TEXT],
			["OBJECTS", str(p.objects_in_frame) if p.have_draw_calls else "n/a",
				UITheme.TEXT],
			["PRIMITIVES", _short(p.primitives) if p.have_draw_calls else "n/a",
				UITheme.TEXT],
			["RENDER SCALE", "x%.2f" % AdaptiveQualityManager.current_render_scale(),
				UITheme.TEXT_DIM],
			["QUALITY", AdaptiveQualityManager.preset_name(), UITheme.ACCENT_2],
		]],
		["MEMORY", [
			["VIDEO", p.metric_text(p.video_mem_mb, p.have_video_mem, " MB", 0), UITheme.TEXT],
			["TEXTURE", p.metric_text(p.texture_mem_mb, p.have_video_mem, " MB", 0),
				UITheme.TEXT],
			["STATIC", "%.0f MB" % p.static_mem_mb, UITheme.TEXT],
			["GAME TOTAL", "%.0f MB" % p.process_memory_mb(), UITheme.ACCENT_2],
			["OS FREE", p.metric_text(p.os_mem_available_mb, p.have_os_memory, " MB", 0),
				UITheme.TEXT_DIM],
			["CHUNK CACHE", "%.1f MB" % float(c.get("chunk_cache_mb", 0.0)), UITheme.TEXT],
			["NODES", str(p.node_count), UITheme.TEXT_DIM],
		]],
		["WORLD", [
			["NPC  F/R/B", "%d / %d / %d" % [int(c.get("npc_full", 0)),
				int(c.get("npc_reduced", 0)), int(c.get("npc_background", 0))],
				UITheme.TEXT],
			["NPC TOTAL", str(int(c.get("npc_total", 0))), UITheme.TEXT],
			["ENEMIES", str(int(c.get("enemies", 0))), UITheme.ACCENT],
			["VEHICLES", str(int(c.get("vehicles", 0))), UITheme.TEXT],
			["RIGID BODIES", "%d  (%d pairs)" % [int(c.get("rigid_bodies", 0)),
				p.physics_pairs], UITheme.TEXT],
			["GRASS / TREES", "%s / %s" % [_short(int(c.get("grass_instances", 0))),
				_short(int(c.get("tree_instances", 0)))], UITheme.TEXT],
			["BUILDINGS", _short(int(c.get("buildings", 0))), UITheme.TEXT],
			["MM INSTANCES", _short(int(c.get("multimesh_instances", 0))),
				UITheme.ACCENT_2],
			["PARTICLES", str(int(c.get("particles", 0))), UITheme.TEXT],
			["OMNI LIGHTS", str(int(c.get("omni_lights", 0))), UITheme.TEXT],
			["CHUNKS L/C/Q", "%d / %d / %d" % [int(c.get("chunks_loaded", 0)),
				int(c.get("chunks_cached", 0)), int(c.get("stream_queue", 0))],
				UITheme.TEXT],
			["CHUNK GEN", "%.1f ms" % float(ws.get("chunk_gen_ms", 0.0)), UITheme.TEXT_DIM],
			["ZONE", String(ws.get("zone", "-")), UITheme.WARN],
			["TIME / WX", "%s  %s" % [ws.get("time", "--:--"), ws.get("weather", "-")],
				UITheme.TEXT_DIM],
		]],
	]

	# Measure so the panel fits its content exactly: FRAME+MEMORY, RENDER,
	# then WORLD on its own since it is the longest group.
	var per_col: Array[int] = [
		int(groups[0][1].size()) + int(groups[2][1].size()),
		int(groups[1][1].size()),
		int(groups[3][1].size()),
	]
	var rows: int = per_col[0]
	for n2: int in per_col:
		rows = maxi(rows, n2)
	var body_h: float = float(rows) * ROW_H + 2.0 * 22.0
	var h: float = 58.0 + body_h + 78.0

	var r := Rect2(PAD, PAD, w, h)
	UITheme.draw_panel(self, r, UITheme.BG_SOLID, UITheme.EDGE)
	UITheme.draw_brackets(self, r.grow(3.0), Color(1.0, 0.22, 0.18, 0.35), 16.0, 1.5)

	# Title bar
	draw_rect(Rect2(r.position.x, r.position.y, w, 26.0), Color(1.0, 0.2, 0.16, 0.10), true)
	draw_rect(Rect2(r.position.x, r.position.y + 25.0, w, 1.0),
		Color(1.0, 0.22, 0.18, 0.45), true)
	UITheme.draw_spaced(self, Vector2(r.position.x + 12.0, r.position.y + 18.0),
		"BENCHMARK TELEMETRY", 11, UITheme.ACCENT, 3.0)
	var lv: Color = StressDirector.level_color()
	UITheme.draw_text(self, Vector2(r.position.x + w - 12.0, r.position.y + 18.0),
		StressDirector.level_name() + ("  AUTO" if StressDirector.auto_mode else ""),
		11, lv, 2)
	UITheme.draw_text(self, Vector2(r.position.x + 12.0, r.position.y + 42.0),
		_device_line, 9, UITheme.TEXT_FAINT)

	# FRAME and MEMORY stack in column 0; RENDER takes 1; WORLD takes 2.
	var column_of: Array[int] = [0, 1, 0, 2]
	var col_y: Array[float] = [r.position.y + 58.0, r.position.y + 58.0,
		r.position.y + 58.0]
	for gi in groups.size():
		var side: int = column_of[gi]
		var g: Array = groups[gi]
		col_y[side] = _draw_group(
			Vector2(r.position.x + PAD + float(side) * col_w, col_y[side]),
			col_w - 14.0, String(g[0]), g[1])

	# Graphs: one row of four.
	var gy: float = r.position.y + h - 72.0
	var gw: float = (w - PAD * 2.0 - 18.0) * 0.25
	var specs: Array = [
		[PerformanceMonitor.fps_history, "FPS", "", UITheme.GOOD, 0, 60.0],
		[PerformanceMonitor.frame_ms_history, "FRAME", " ms", UITheme.WARN, 1, 16.7],
		[PerformanceMonitor.mem_history, "GAME MEM", " MB", UITheme.ACCENT_2, 0, 0.0],
		[PerformanceMonitor.gpu_history, "GPU", " ms", UITheme.ACCENT, 2, 0.0],
	]
	for i in specs.size():
		var sp: Array = specs[i]
		_draw_graph(Rect2(r.position.x + PAD + float(i) * (gw + 6.0), gy, gw, 62.0),
			sp[0], String(sp[1]), String(sp[2]), sp[3], int(sp[4]), float(sp[5]))


func _draw_group(pos: Vector2, w: float, title: String, rows: Array) -> float:
	var y: float = pos.y
	UITheme.draw_spaced(self, Vector2(pos.x, y + 8.0), title, 9, UITheme.ACCENT_2, 2.5)
	var tw: float = UITheme.text_width(title, 9) + float(title.length()) * 2.5 + 8.0
	draw_rect(Rect2(pos.x + tw, y + 3.0, maxf(0.0, w - tw), 1.0),
		Color(1, 1, 1, 0.10), true)
	y += 16.0
	for row: Array in rows:
		UITheme.draw_text(self, Vector2(pos.x, y + 9.0), String(row[0]), 10,
			UITheme.TEXT_FAINT)
		UITheme.draw_text(self, Vector2(pos.x + w, y + 9.0), String(row[1]), 11,
			row[2], 2)
		y += ROW_H
	return y + 6.0


## Filled history graph with a grid, an auto-ranged axis and an optional
## target line.
func _draw_graph(r: Rect2, buf: RingBuffer, title: String, unit: String,
		col: Color, decimals: int, target: float) -> void:
	draw_rect(r, Color(0.012, 0.016, 0.024, 0.85), true)
	draw_rect(r, Color(1, 1, 1, 0.07), false, 1.0)

	for i in range(1, 4):
		var gy: float = r.position.y + r.size.y * float(i) / 4.0
		draw_line(Vector2(r.position.x, gy), Vector2(r.position.x + r.size.x, gy),
			Color(1, 1, 1, 0.04), 1.0)

	if buf == null or buf.size() < 2:
		UITheme.draw_text(self, Vector2(r.position.x + 7.0, r.position.y + 15.0),
			"%s  collecting" % title, 10, UITheme.TEXT_FAINT)
		return

	var n: int = buf.size()
	var hi: float = maxf(buf.maximum() * 1.1, 0.0001)
	var lo: float = 0.0
	var top_pad: float = 15.0
	var gh: float = r.size.y - top_pad - 3.0

	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var t: float = clampf((buf.get_at(i) - lo) / (hi - lo), 0.0, 1.0)
		pts[i] = Vector2(r.position.x + float(i) / float(n - 1) * r.size.x,
			r.position.y + top_pad + gh - t * gh)

	var poly := PackedVector2Array()
	poly.append(Vector2(pts[0].x, r.position.y + r.size.y))
	poly.append_array(pts)
	poly.append(Vector2(pts[n - 1].x, r.position.y + r.size.y))
	draw_colored_polygon(poly, Color(col.r, col.g, col.b, 0.16))
	draw_polyline(pts, col, 1.5, true)

	if target > 0.0 and target < hi:
		var ty: float = r.position.y + top_pad + gh - (target - lo) / (hi - lo) * gh
		draw_line(Vector2(r.position.x, ty), Vector2(r.position.x + r.size.x, ty),
			Color(1, 1, 1, 0.20), 1.0)

	UITheme.draw_text(self, Vector2(r.position.x + 7.0, r.position.y + 12.0),
		title, 9, UITheme.TEXT_FAINT)
	UITheme.draw_text(self, Vector2(r.position.x + r.size.x - 7.0, r.position.y + 12.0),
		String.num(buf.last(), decimals) + unit, 11, col, 2)


static func _short(v: int) -> String:
	if v >= 1000000:
		return "%.2fM" % (float(v) / 1000000.0)
	if v >= 1000:
		return "%.1fk" % (float(v) / 1000.0)
	return str(v)
