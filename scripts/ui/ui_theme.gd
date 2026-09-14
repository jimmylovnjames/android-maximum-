class_name UITheme
extends RefCounted
## Shared colours and style factories so every panel in REDLINE looks like part
## of the same instrument cluster.

const BG := Color(0.043, 0.051, 0.067, 0.86)
const BG_SOLID := Color(0.043, 0.051, 0.067, 0.97)
const PANEL_EDGE := Color(1.0, 1.0, 1.0, 0.09)
const TEXT := Color(0.88, 0.91, 0.95)
const TEXT_DIM := Color(0.55, 0.60, 0.68)
const TEXT_FAINT := Color(0.38, 0.42, 0.50)
const ACCENT := Color(1.0, 0.22, 0.18)
const ACCENT_2 := Color(0.37, 0.78, 0.94)
const GOOD := Color(0.23, 0.82, 0.49)
const WARN := Color(0.94, 0.75, 0.29)
const BAD := Color(1.0, 0.35, 0.25)
const HEALTH := Color(0.95, 0.30, 0.30)
const STAMINA := Color(0.35, 0.80, 0.95)
const INTEGRITY := Color(0.95, 0.75, 0.35)


static func panel(radius: int = 8, bg: Color = BG, edge: Color = PANEL_EDGE) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	s.border_color = edge
	s.set_border_width_all(1)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 9
	s.content_margin_bottom = 9
	return s


static func label(text: String, size: int = 14, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func heading(text: String, size: int = 15, color: Color = ACCENT_2) -> Label:
	var l: Label = label(text, size, color)
	l.add_theme_constant_override("outline_size", 0)
	return l


static func button(text: String, size: int = 15) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size = Vector2(0, 44)
	b.focus_mode = Control.FOCUS_NONE
	var normal: StyleBoxFlat = panel(6, Color(0.10, 0.12, 0.16, 0.95))
	var hover: StyleBoxFlat = panel(6, Color(0.16, 0.19, 0.25, 0.97), Color(1, 1, 1, 0.2))
	var pressed: StyleBoxFlat = panel(6, Color(0.26, 0.10, 0.09, 0.98), ACCENT)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", normal)
	b.add_theme_color_override("font_color", TEXT)
	return b


static func level_color(level: int) -> Color:
	var names: PackedStringArray = [
		"3ad17c", "5ec8f0", "f0c04a", "ff8c2d", "ff3a2d", "d02bff",
	]
	return Color(names[clampi(level, 0, names.size() - 1)])


## Green above `good`, amber in between, red below `bad`.
static func value_color(v: float, good: float, bad: float) -> Color:
	if v >= good:
		return GOOD
	if v <= bad:
		return BAD
	return WARN
