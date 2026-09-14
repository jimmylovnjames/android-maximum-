class_name GraphPanel
extends Control
## Draws a RingBuffer as a filled line graph with an auto-ranged vertical axis
## and an optional target line. Redraws at the HUD's sample rate, not per frame.

var buffer: RingBuffer = null
var line_color: Color = UITheme.ACCENT_2
var fill_alpha: float = 0.16
var title: String = ""
var unit: String = ""
var target_value: float = 0.0
var show_target: bool = false
var invert_quality: bool = false     ## true when lower is better (frame time)
var fixed_max: float = 0.0
var decimals: int = 0

var _cached_max: float = 1.0
var _cached_min: float = 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(210, 62)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	var r: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0.02, 0.03, 0.04, 0.55), true)
	draw_rect(r, Color(1, 1, 1, 0.07), false, 1.0)

	var font: Font = ThemeDB.fallback_font
	if buffer == null or buffer.size() < 2:
		draw_string(font, Vector2(8, size.y * 0.5 + 5), "%s  collecting..." % title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UITheme.TEXT_FAINT)
		return

	var n: int = buffer.size()
	var vmax: float = fixed_max if fixed_max > 0.0 else buffer.maximum()
	var vmin: float = 0.0 if fixed_max > 0.0 else buffer.minimum()
	vmax = maxf(vmax, vmin + 0.0001)
	# Smooth the axis so the graph does not jitter every sample.
	_cached_max = lerpf(_cached_max if _cached_max > 0.0 else vmax, vmax * 1.08, 0.25)
	_cached_min = lerpf(_cached_min, maxf(0.0, vmin * 0.92), 0.25)
	var hi: float = maxf(_cached_max, _cached_min + 0.001)
	var lo: float = _cached_min

	var pad_top: float = 16.0
	var h: float = size.y - pad_top - 4.0
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var v: float = buffer.get_at(i)
		var t: float = clampf((v - lo) / (hi - lo), 0.0, 1.0)
		pts[i] = Vector2(
			float(i) / float(n - 1) * size.x,
			pad_top + h - t * h
		)

	# Fill
	var poly := PackedVector2Array()
	poly.append(Vector2(pts[0].x, size.y))
	poly.append_array(pts)
	poly.append(Vector2(pts[n - 1].x, size.y))
	draw_colored_polygon(poly, Color(line_color.r, line_color.g, line_color.b, fill_alpha))
	draw_polyline(pts, line_color, 1.6, true)

	if show_target and target_value > lo and target_value < hi:
		var ty: float = pad_top + h - (target_value - lo) / (hi - lo) * h
		draw_line(Vector2(0, ty), Vector2(size.x, ty), Color(1, 1, 1, 0.18), 1.0)

	var last: float = buffer.last()
	var label: String = "%s  %s%s" % [title, String.num(last, decimals), unit]
	draw_string(font, Vector2(6, 13), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		UITheme.TEXT)
	var range_label: String = "%s-%s" % [String.num(lo, decimals), String.num(hi, decimals)]
	var sz: Vector2 = font.get_string_size(range_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
	draw_string(font, Vector2(size.x - sz.x - 6, 13), range_label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.TEXT_FAINT)
