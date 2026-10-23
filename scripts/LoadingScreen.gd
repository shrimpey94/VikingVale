extends CanvasLayer

## v1.6 P7 — a fullscreen loading page shown after login and across a 2D↔3D switch,
## so the world (terrain rebuild, admin paints, entities) settles in the background
## before the player sees it. A single "Enter World" button, centred bottom, is
## disabled until the world reports ready (or a safety timeout). Click it to dismiss.

var _btn: Button
var _status: Label
var _dots := 0.0
var _ready_now := false

func _ready() -> void:
	layer = 200
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.09, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var title := _label("VIKINGVALE", 44, Color(0.85, 0.72, 0.35), 0.32)
	add_child(title)
	_status = _label("Loading the world", 16, Color(0.70, 0.75, 0.82), 0.45)
	add_child(_status)

	_btn = Button.new()
	_btn.text = "Loading…"
	_btn.disabled = true
	_btn.add_theme_font_size_override("font_size", 18)
	_btn.anchor_left = 0.5; _btn.anchor_right = 0.5
	_btn.anchor_top = 1.0;  _btn.anchor_bottom = 1.0
	_btn.offset_left = -120; _btn.offset_right = 120
	_btn.offset_top = -112;  _btn.offset_bottom = -60
	_btn.pressed.connect(_dismiss)
	add_child(_btn)

	# Safety net — never trap the player behind the screen even if a signal is missed.
	get_tree().create_timer(12.0).timeout.connect(set_ready)

func _label(text: String, size: int, col: Color, y_anchor: float) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.anchor_left = 0.0; l.anchor_right = 1.0
	l.anchor_top = y_anchor; l.anchor_bottom = y_anchor
	l.offset_bottom = 48.0
	return l

func _process(delta: float) -> void:
	if _ready_now:
		return
	_dots += delta * 2.0
	if _status != null:
		_status.text = "Loading the world" + ".".repeat(int(_dots) % 4)

func set_ready() -> void:
	if _ready_now:
		return
	_ready_now = true
	if _status != null:
		_status.text = "Ready."
	if _btn != null:
		_btn.text = "Enter World"
		_btn.disabled = false

func _dismiss() -> void:
	queue_free()
