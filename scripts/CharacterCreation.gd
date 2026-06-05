extends CanvasLayer

## Shown once, right after a new account is registered (before first entering the
## world). Lets the player customise their Viking; saves the choice to the server
## via NetworkManager.send_set_appearance, then frees itself into the live world.

const RS_BG      := Color(0.11, 0.07, 0.03)
const RS_BG_DEEP := Color(0.06, 0.04, 0.02)
const RS_BORDER  := Color(0.64, 0.49, 0.14)
const RS_BTN_N   := Color(0.08, 0.05, 0.02)
const RS_BTN_H   := Color(0.20, 0.13, 0.05)
const RS_TEXT    := Color(0.92, 0.85, 0.62)
const RS_DIM     := Color(0.60, 0.55, 0.38)
const RS_GOLD    := Color(1.00, 0.85, 0.25)

var _appr: Dictionary = {}
var _preview: Node2D = null
var _value_lbls: Dictionary = {}   # key → Label

func _ready() -> void:
	layer = 101
	_appr = Appearance.default()
	_build_ui()

func _build_ui() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = RS_BG_DEEP
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 2))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -260; panel.offset_right = 260
	panel.offset_top  = -220; panel.offset_bottom = 220
	add_child(panel)

	var margin := MarginContainer.new()
	for m: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 22)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var title := Label.new()
	title.text = "Create Your Viking"
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	# ── Preview box (left) ────────────────────────────────────────────────────
	var pv_panel := PanelContainer.new()
	pv_panel.add_theme_stylebox_override("panel", _rs(RS_BG_DEEP, RS_BORDER.darkened(0.3), 1))
	pv_panel.custom_minimum_size = Vector2(180, 280)
	body.add_child(pv_panel)
	var pv_holder := Control.new()
	pv_panel.add_child(pv_holder)
	_preview = (load("res://scripts/CharPreview.gd") as GDScript).new() as Node2D
	_preview.scale = Vector2(3.6, 3.6)
	_preview.position = Vector2(90, 200)
	pv_holder.add_child(_preview)

	# ── Option rows (right) ─────────────────────────────────────────────────────
	var opts := VBoxContainer.new()
	opts.add_theme_constant_override("separation", 8)
	opts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(opts)

	_add_option(opts, "Skin Tone",  "skin",       Appearance.SKIN_TONES.size())
	_add_option(opts, "Hair Style", "hair_style", Appearance.HAIR_STYLE_NAMES.size())
	_add_option(opts, "Hair Color", "hair_color", Appearance.HAIR_COLORS.size())
	_add_option(opts, "Beard",      "beard",      Appearance.BEARD_NAMES.size())
	_add_option(opts, "Body Type",  "body",       Appearance.BODY_HALF_W.size())
	_add_option(opts, "Tunic",      "tunic",      Appearance.TUNIC_COLORS.size())

	var rnd := _btn("Randomize", false)
	rnd.pressed.connect(_on_randomize)
	opts.add_child(rnd)

	root.add_child(HSeparator.new())

	var enter := _btn("Enter the Realm", true)
	enter.pressed.connect(_on_enter)
	root.add_child(enter)

	_refresh_preview()

func _add_option(parent: VBoxContainer, title: String, key: String, count: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var name_lbl := Label.new()
	name_lbl.text = title
	name_lbl.add_theme_color_override("font_color", RS_DIM)
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.custom_minimum_size = Vector2(90, 0)
	row.add_child(name_lbl)

	var prev := _btn("<", false)
	prev.custom_minimum_size = Vector2(34, 30)
	prev.pressed.connect(_cycle.bind(key, count, -1))
	row.add_child(prev)

	var val := Label.new()
	val.add_theme_color_override("font_color", RS_TEXT)
	val.add_theme_font_size_override("font_size", 13)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(val)
	_value_lbls[key] = val

	var nxt := _btn(">", false)
	nxt.custom_minimum_size = Vector2(34, 30)
	nxt.pressed.connect(_cycle.bind(key, count, 1))
	row.add_child(nxt)

func _cycle(key: String, count: int, dir: int) -> void:
	var cur := int(_appr.get(key, 0))
	_appr[key] = (cur + dir + count) % count
	_refresh_preview()

func _on_randomize() -> void:
	_appr["skin"]       = randi() % Appearance.SKIN_TONES.size()
	_appr["hair_style"] = randi() % Appearance.HAIR_STYLE_NAMES.size()
	_appr["hair_color"] = randi() % Appearance.HAIR_COLORS.size()
	_appr["beard"]      = randi() % Appearance.BEARD_NAMES.size()
	_appr["body"]       = randi() % Appearance.BODY_HALF_W.size()
	_appr["tunic"]      = randi() % Appearance.TUNIC_COLORS.size()
	_refresh_preview()

func _refresh_preview() -> void:
	if _preview != null:
		_preview.call("set_appearance", _appr)
	_value_lbls["skin"].text       = "Tone %d" % (int(_appr["skin"]) + 1)
	_value_lbls["hair_style"].text = Appearance.HAIR_STYLE_NAMES[int(_appr["hair_style"])]
	_value_lbls["hair_color"].text = Appearance.HAIR_COLOR_NAMES[int(_appr["hair_color"])]
	_value_lbls["beard"].text      = Appearance.BEARD_NAMES[int(_appr["beard"])]
	_value_lbls["body"].text       = Appearance.BODY_NAMES[int(_appr["body"])]
	_value_lbls["tunic"].text      = "Color %d" % (int(_appr["tunic"]) + 1)

func _on_enter() -> void:
	GameManager.appearance = _appr.duplicate()
	NetworkManager.send_set_appearance(_appr, GameManager.equipment)
	for pl in get_tree().get_nodes_in_group("player"):
		(pl as Node2D).queue_redraw()
	queue_free()

# ── Styling helpers ──────────────────────────────────────────────────────────
func _rs(bg: Color, border: Color, bw: int = 2) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_border_width_all(bw)
	s.border_color = border
	s.set_corner_radius_all(2)
	return s

func _btn(label: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = label
	var border := RS_GOLD if primary else RS_BORDER.darkened(0.3)
	b.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, border, 2))
	b.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_GOLD, 2))
	b.add_theme_stylebox_override("pressed", _rs(Color(0.20, 0.13, 0.05), RS_GOLD, 2))
	b.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, border, 2))
	b.add_theme_color_override("font_color",       RS_GOLD if primary else RS_TEXT)
	b.add_theme_color_override("font_hover_color", RS_GOLD)
	b.add_theme_font_size_override("font_size", 13)
	b.custom_minimum_size = Vector2(0, 32)
	return b
