class_name UITheme
extends RefCounted
## Shared palette and drawing primitives.
##
## REDLINE's interface is drawn rather than assembled from default Controls:
## chamfered panels, corner brackets, segmented bars and letter-spaced titles.
## Everything here takes a CanvasItem so panels can be composed inside a single
## _draw() pass instead of a tree of nested containers.

# --- Palette ---------------------------------------------------------------
const BG := Color(0.035, 0.042, 0.055, 0.80)
const BG_SOLID := Color(0.031, 0.037, 0.049, 0.985)
const BG_DEEP := Color(0.016, 0.020, 0.028, 0.95)
const EDGE := Color(1.0, 1.0, 1.0, 0.10)
const EDGE_BRIGHT := Color(1.0, 1.0, 1.0, 0.22)

const TEXT := Color(0.90, 0.93, 0.97)
const TEXT_DIM := Color(0.56, 0.62, 0.70)
const TEXT_FAINT := Color(0.34, 0.39, 0.47)

const ACCENT := Color(1.0, 0.20, 0.16)
const ACCENT_SOFT := Color(1.0, 0.35, 0.28)
const ACCENT_2 := Color(0.33, 0.78, 0.96)
const GOOD := Color(0.22, 0.86, 0.51)
const WARN := Color(0.98, 0.76, 0.24)
const BAD := Color(1.0, 0.32, 0.22)
const VIOLET := Color(0.78, 0.35, 1.0)

const HEALTH := Color(1.0, 0.28, 0.30)
const STAMINA := Color(0.32, 0.80, 0.96)
const INTEGRITY := Color(0.97, 0.74, 0.30)

const CHAMFER: float = 9.0


static func font() -> Font:
	return ThemeDB.fallback_font


# --- Panels ----------------------------------------------------------------
## Chamfered panel: the top-right and bottom-left corners are cut, which is
## what separates this from a rounded StyleBoxFlat at a glance.
static func panel_points(r: Rect2, cut: float = CHAMFER) -> PackedVector2Array:
	var c: float = minf(cut, minf(r.size.x, r.size.y) * 0.45)
	return PackedVector2Array([
		Vector2(r.position.x, r.position.y),
		Vector2(r.position.x + r.size.x - c, r.position.y),
		Vector2(r.position.x + r.size.x, r.position.y + c),
		Vector2(r.position.x + r.size.x, r.position.y + r.size.y),
		Vector2(r.position.x + c, r.position.y + r.size.y),
		Vector2(r.position.x, r.position.y + r.size.y - c),
	])


static func draw_panel(ci: CanvasItem, r: Rect2, bg: Color = BG,
		edge: Color = EDGE, cut: float = CHAMFER) -> void:
	var pts: PackedVector2Array = panel_points(r, cut)
	ci.draw_colored_polygon(pts, bg)
	var loop: PackedVector2Array = pts.duplicate()
	loop.append(pts[0])
	ci.draw_polyline(loop, edge, 1.0, true)


## Corner brackets. Used on live readouts to mark them as instruments rather
## than chrome.
static func draw_brackets(ci: CanvasItem, r: Rect2, col: Color,
		length: float = 12.0, width: float = 2.0) -> void:
	var l: float = minf(length, minf(r.size.x, r.size.y) * 0.4)
	var p0: Vector2 = r.position
	var p1: Vector2 = r.position + r.size
	ci.draw_line(Vector2(p0.x, p0.y), Vector2(p0.x + l, p0.y), col, width)
	ci.draw_line(Vector2(p0.x, p0.y), Vector2(p0.x, p0.y + l), col, width)
	ci.draw_line(Vector2(p1.x - l, p0.y), Vector2(p1.x, p0.y), col, width)
	ci.draw_line(Vector2(p1.x, p0.y), Vector2(p1.x, p0.y + l), col, width)
	ci.draw_line(Vector2(p0.x, p1.y - l), Vector2(p0.x, p1.y), col, width)
	ci.draw_line(Vector2(p0.x, p1.y), Vector2(p0.x + l, p1.y), col, width)
	ci.draw_line(Vector2(p1.x - l, p1.y), Vector2(p1.x, p1.y), col, width)
	ci.draw_line(Vector2(p1.x, p1.y - l), Vector2(p1.x, p1.y), col, width)


## Thin accent rule with a brighter leading cap.
static func draw_rule(ci: CanvasItem, from: Vector2, length: float, col: Color,
		cap: float = 10.0, width: float = 2.0) -> void:
	ci.draw_line(from, from + Vector2(length, 0.0), Color(col.r, col.g, col.b, 0.28), width)
	ci.draw_line(from, from + Vector2(cap, 0.0), col, width)


# --- Bars ------------------------------------------------------------------
## Segmented meter. Segments read as a quantity at a glance in a way a smooth
## fill does not, and they hide the low-resolution end of a phone screen.
static func draw_segmented_bar(ci: CanvasItem, r: Rect2, value: float,
		col: Color, segments: int = 22, gap: float = 2.0,
		bg: Color = Color(1, 1, 1, 0.07)) -> void:
	var v: float = clampf(value, 0.0, 1.0)
	var seg_w: float = (r.size.x - gap * float(segments - 1)) / float(segments)
	var lit: float = v * float(segments)
	for i in segments:
		var x: float = r.position.x + float(i) * (seg_w + gap)
		var cell := Rect2(Vector2(x, r.position.y), Vector2(seg_w, r.size.y))
		var fill: float = clampf(lit - float(i), 0.0, 1.0)
		ci.draw_rect(cell, bg, true)
		if fill > 0.0:
			var lit_cell := Rect2(cell.position, Vector2(seg_w * fill, cell.size.y))
			# The leading segment is brighter, so the meter has a visible head.
			var c: Color = col if fill >= 1.0 else col.lightened(0.35)
			ci.draw_rect(lit_cell, c, true)


## Continuous bar with a chamfered end and a soft glow behind the fill.
static func draw_bar(ci: CanvasItem, r: Rect2, value: float, col: Color,
		bg: Color = Color(0, 0, 0, 0.5)) -> void:
	var v: float = clampf(value, 0.0, 1.0)
	ci.draw_rect(r, bg, true)
	if v <= 0.0:
		return
	var fill := Rect2(r.position, Vector2(r.size.x * v, r.size.y))
	ci.draw_rect(fill.grow(1.5), Color(col.r, col.g, col.b, 0.18), true)
	ci.draw_rect(fill, col, true)


# --- Text ------------------------------------------------------------------
static func text_width(s: String, size: int) -> float:
	return font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


static func draw_text(ci: CanvasItem, pos: Vector2, s: String, size: int,
		col: Color, align: int = 0) -> float:
	var w: float = text_width(s, size)
	var x: float = pos.x
	if align == 1:
		x -= w * 0.5
	elif align == 2:
		x -= w
	ci.draw_string(font(), Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
	return w


## Letter-spaced text, for titles and zone banners.
static func draw_spaced(ci: CanvasItem, pos: Vector2, s: String, size: int,
		col: Color, spacing: float = 6.0, align: int = 0) -> float:
	var total: float = 0.0
	for i in s.length():
		total += text_width(s[i], size) + spacing
	total -= spacing
	var x: float = pos.x
	if align == 1:
		x -= total * 0.5
	elif align == 2:
		x -= total
	for i in s.length():
		var ch: String = s[i]
		ci.draw_string(font(), Vector2(x, pos.y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1,
			size, col)
		x += text_width(ch, size) + spacing
	return total


# --- Control factories (menus still use real Controls for input) -----------
static func stylebox(bg: Color, edge: Color, radius: int = 4) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = edge
	s.set_border_width_all(1)
	s.corner_radius_top_left = radius
	s.corner_radius_bottom_right = radius
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s


static func panel(radius: int = 8, bg: Color = BG, edge: Color = EDGE) -> StyleBoxFlat:
	return stylebox(bg, edge, radius)


static func label(text: String, size: int = 14, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func heading(text: String, size: int = 15, color: Color = ACCENT_2) -> Label:
	return label(text, size, color)


static func button(text: String, size: int = 15) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size = Vector2(0, 46)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal",
		stylebox(Color(0.075, 0.088, 0.115, 0.95), Color(1, 1, 1, 0.10)))
	b.add_theme_stylebox_override("hover",
		stylebox(Color(0.13, 0.15, 0.19, 0.97), ACCENT_2))
	b.add_theme_stylebox_override("pressed",
		stylebox(Color(0.24, 0.07, 0.06, 0.98), ACCENT))
	b.add_theme_stylebox_override("focus",
		stylebox(Color(0.075, 0.088, 0.115, 0.95), Color(1, 1, 1, 0.10)))
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	return b


static func level_color(level: int) -> Color:
	var names: PackedStringArray = [
		"3ad17c", "5ec8f0", "f0c04a", "ff8c2d", "ff3a2d", "d02bff",
	]
	return Color(names[clampi(level, 0, names.size() - 1)])


## Green above `good`, amber between, red below `bad`.
static func value_color(v: float, good: float, bad: float) -> Color:
	if v >= good:
		return GOOD
	if v <= bad:
		return BAD
	return WARN
