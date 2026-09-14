class_name TouchInput
extends Control
## Landscape-first touch layer: a left analogue stick, a right-hand look area
## with its own action buttons, and a top-left system row. Multi-touch is
## tracked per finger index so movement and look never fight each other.
##
## On desktop the layer hides itself unless forced on, and the keyboard/mouse
## path in PlayerController takes over.

signal jump_pressed()
signal interact_pressed()
signal attack_changed(down: bool)
signal sprint_changed(down: bool)
signal pause_pressed()
signal hud_pressed()
signal stress_pressed(direction: int)

const STICK_RADIUS: float = 120.0
const STICK_DEAD: float = 0.12
const BUTTON_SIZE: float = 92.0

var move_vector: Vector2 = Vector2.ZERO
var look_delta: Vector2 = Vector2.ZERO
var sprint_held: bool = false
var attack_held: bool = false
var look_sensitivity: float = 1.0

var _stick_finger: int = -1
var _stick_origin: Vector2 = Vector2.ZERO
var _stick_pos: Vector2 = Vector2.ZERO
var _look_finger: int = -1
var _look_last: Vector2 = Vector2.ZERO
var _stick_area: Rect2
var _buttons: Array[Dictionary] = []
var _pressed_buttons: Dictionary = {}      ## finger -> button index
var _enabled: bool = true
var _look_hint: float = 5.0


func _ready() -> void:
	name = "TouchInput"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_rebuild_layout()
	get_viewport().size_changed.connect(_rebuild_layout)
	_enabled = should_be_enabled()
	visible = _enabled


static func has_touchscreen() -> bool:
	return DisplayServer.is_touchscreen_available() or OS.has_feature("mobile")


func should_be_enabled() -> bool:
	var pref: int = int(GameConfig.settings.get("touch_controls", -1))
	if pref == 0:
		return false
	if pref == 1:
		return true
	return has_touchscreen()


func set_enabled(v: bool) -> void:
	_enabled = v
	visible = v
	if not v:
		move_vector = Vector2.ZERO
		look_delta = Vector2.ZERO
		sprint_held = false
		if attack_held:
			attack_held = false
			attack_changed.emit(false)
		_stick_finger = -1
		_look_finger = -1


func toggle() -> void:
	set_enabled(not _enabled)
	GameConfig.settings["touch_controls"] = 1 if _enabled else 0
	GameConfig.save_settings()


func is_enabled() -> bool:
	return _enabled


func _rebuild_layout() -> void:
	var vs: Vector2 = get_viewport_rect().size
	_stick_area = Rect2(Vector2(0.0, vs.y * 0.3), Vector2(vs.x * 0.42, vs.y * 0.7))
	_stick_origin = Vector2(STICK_RADIUS + 46.0, vs.y - STICK_RADIUS - 46.0)
	_stick_pos = _stick_origin

	var right: float = vs.x - 52.0
	var bottom: float = vs.y - 52.0
	_buttons = [
		{"id": "attack", "label": "FIRE", "pos": Vector2(right - BUTTON_SIZE * 0.5,
			bottom - BUTTON_SIZE * 0.5), "r": BUTTON_SIZE * 0.62,
			"color": Color("ff4d3a")},
		{"id": "jump", "label": "JUMP", "pos": Vector2(right - BUTTON_SIZE * 1.75,
			bottom - BUTTON_SIZE * 0.75), "r": BUTTON_SIZE * 0.5,
			"color": Color("5ec8f0")},
		{"id": "sprint", "label": "RUN", "pos": Vector2(right - BUTTON_SIZE * 0.7,
			bottom - BUTTON_SIZE * 1.65), "r": BUTTON_SIZE * 0.46,
			"color": Color("f0c04a")},
		{"id": "interact", "label": "USE", "pos": Vector2(right - BUTTON_SIZE * 2.1,
			bottom - BUTTON_SIZE * 1.75), "r": BUTTON_SIZE * 0.44,
			"color": Color("3ad17c")},
		{"id": "pause", "label": "II", "pos": Vector2(vs.x - 44.0, 44.0), "r": 30.0,
			"color": Color("9aa4b2")},
		{"id": "hud", "label": "HUD", "pos": Vector2(vs.x - 116.0, 44.0), "r": 30.0,
			"color": Color("9aa4b2")},
		{"id": "stress_down", "label": "-", "pos": Vector2(vs.x - 188.0, 44.0), "r": 26.0,
			"color": Color("6f7684")},
		{"id": "stress_up", "label": "+", "pos": Vector2(vs.x - 248.0, 44.0), "r": 26.0,
			"color": Color("6f7684")},
	]
	queue_redraw()


func _process(delta: float) -> void:
	if _look_hint > 0.0:
		_look_hint -= delta
		queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not _enabled:
		return
	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)


func _handle_touch(t: InputEventScreenTouch) -> void:
	if t.pressed:
		var bi: int = _button_at(t.position)
		if bi >= 0:
			_pressed_buttons[t.index] = bi
			_on_button_down(String(_buttons[bi]["id"]))
			queue_redraw()
			get_viewport().set_input_as_handled()
			return
		if _stick_finger < 0 and _stick_area.has_point(t.position):
			_stick_finger = t.index
			_stick_origin = t.position
			_stick_pos = t.position
			queue_redraw()
			get_viewport().set_input_as_handled()
			return
		if _look_finger < 0:
			_look_finger = t.index
			_look_last = t.position
			_look_hint = 0.0
			get_viewport().set_input_as_handled()
	else:
		if _pressed_buttons.has(t.index):
			var bi2: int = int(_pressed_buttons[t.index])
			_pressed_buttons.erase(t.index)
			_on_button_up(String(_buttons[bi2]["id"]))
			queue_redraw()
			return
		if t.index == _stick_finger:
			_stick_finger = -1
			move_vector = Vector2.ZERO
			_stick_pos = _stick_origin
			queue_redraw()
		elif t.index == _look_finger:
			_look_finger = -1


func _handle_drag(d: InputEventScreenDrag) -> void:
	if d.index == _stick_finger:
		_stick_pos = d.position
		var v: Vector2 = (_stick_pos - _stick_origin) / STICK_RADIUS
		if v.length() > 1.0:
			v = v.normalized()
		if v.length() < STICK_DEAD:
			v = Vector2.ZERO
		move_vector = Vector2(v.x, -v.y)
		queue_redraw()
	elif d.index == _look_finger:
		look_delta += (d.position - _look_last) * 0.16 * look_sensitivity
		_look_last = d.position


func _button_at(p: Vector2) -> int:
	for i in _buttons.size():
		var b: Dictionary = _buttons[i]
		if p.distance_to(b["pos"]) <= float(b["r"]) * 1.15:
			return i
	return -1


func _on_button_down(id: String) -> void:
	match id:
		"attack":
			attack_held = true
			attack_changed.emit(true)
		"jump":
			jump_pressed.emit()
		"sprint":
			sprint_held = not sprint_held
			sprint_changed.emit(sprint_held)
		"interact":
			interact_pressed.emit()
		"pause":
			pause_pressed.emit()
		"hud":
			hud_pressed.emit()
		"stress_up":
			stress_pressed.emit(1)
		"stress_down":
			stress_pressed.emit(-1)


func _on_button_up(id: String) -> void:
	if id == "attack":
		attack_held = false
		attack_changed.emit(false)


## Consumed once per frame by PlayerController.
func take_look_delta() -> Vector2:
	var d: Vector2 = look_delta
	look_delta = Vector2.ZERO
	return d


func _draw() -> void:
	if not _enabled:
		return
	var active: bool = _stick_finger >= 0

	# Stick: outer ring, a dead-zone marker, and a lead line to the knob so the
	# current direction is readable at a glance with a thumb over the control.
	draw_circle(_stick_origin, STICK_RADIUS, Color(0, 0, 0, 0.20))
	draw_arc(_stick_origin, STICK_RADIUS, 0.0, TAU, 48,
		Color(1, 1, 1, 0.24 if active else 0.14), 2.0, true)
	draw_arc(_stick_origin, STICK_RADIUS * STICK_DEAD, 0.0, TAU, 20,
		Color(1, 1, 1, 0.10), 1.0, true)
	for i in 4:
		var a: float = TAU * float(i) / 4.0
		var d := Vector2(cos(a), sin(a))
		draw_line(_stick_origin + d * (STICK_RADIUS - 10.0),
			_stick_origin + d * STICK_RADIUS, Color(1, 1, 1, 0.18), 1.5)

	var knob: Vector2 = _stick_origin + (_stick_pos - _stick_origin).limit_length(
		STICK_RADIUS)
	if active:
		draw_line(_stick_origin, knob, Color(0.33, 0.78, 0.96, 0.35), 2.0)
	draw_circle(knob, 38.0, Color(0.04, 0.05, 0.07, 0.55))
	draw_arc(knob, 38.0, 0.0, TAU, 28,
		Color(0.33, 0.78, 0.96, 0.9) if active else Color(1, 1, 1, 0.3), 2.0, true)
	draw_circle(knob, 4.0, Color(1, 1, 1, 0.55 if active else 0.3))

	var held_ids: Array = []
	for f: int in _pressed_buttons.keys():
		held_ids.append(String(_buttons[int(_pressed_buttons[f])]["id"]))

	var font: Font = ThemeDB.fallback_font
	for b: Dictionary in _buttons:
		var c: Color = b["color"]
		var id: String = b["id"]
		var down: bool = held_ids.has(id) or (id == "sprint" and sprint_held)
		var r: float = float(b["r"])
		var pos: Vector2 = b["pos"]
		draw_circle(pos, r, Color(0.03, 0.04, 0.055, 0.55 if down else 0.38))
		draw_circle(pos, r, Color(c.r, c.g, c.b, 0.22 if down else 0.08))
		# Two-arc ring: a full faint ring plus a bright arc that closes when
		# the control is active, so state reads without colour alone.
		draw_arc(pos, r, 0.0, TAU, 36, Color(c.r, c.g, c.b, 0.3), 1.5, true)
		draw_arc(pos, r, -PI * 0.5, -PI * 0.5 + (TAU if down else TAU * 0.28), 32,
			Color(c.r, c.g, c.b, 0.95 if down else 0.55), 2.5, true)
		var label: String = b["label"]
		var fs: int = 15 if r > 34.0 else 13
		var sz: Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(font, pos - Vector2(sz.x * 0.5, -5.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			Color(1, 1, 1, 0.95 if down else 0.8))

	# Look-area hint on first use, so the right half of the screen is
	# discoverable without a tutorial.
	if _look_hint > 0.0:
		var vs: Vector2 = get_viewport_rect().size
		var a: float = clampf(_look_hint, 0.0, 1.0) * 0.5
		var centre := Vector2(vs.x * 0.74, vs.y * 0.42)
		draw_arc(centre, 46.0, 0.0, TAU, 40, Color(1, 1, 1, a * 0.4), 1.5, true)
		draw_string(font, centre - Vector2(38.0, -4.0), "DRAG TO LOOK",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, a))
