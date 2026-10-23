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

# ── Free-hand face paint (V1.5.4) ─────────────────────────────────────────────
var _paint_surface: Control = null
var _paint_region: int = -1        # -1 full (no paint) · 0 face · 1 L arm · 2 R arm
var _ink_color: int = 0            # index into Appearance.FACE_MARK_COLORS
var _ink_width: float = 0.6
var _active: Dictionary = {}       # the stroke currently being dragged ({} = none)
var _last_fp: Vector2 = Vector2.ZERO
var _swatch_btns: Array = []
var _width_btns: Array = []
var _view_btns: Array = []
const _WIDTHS: Array = [["Fine", 0.2], ["Med", 0.6], ["Bold", 3.0]]

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
	panel.offset_left = -270; panel.offset_right = 270
	panel.offset_top  = -244; panel.offset_bottom = 244
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

	# Transparent capture layer over the preview — drag on the face to paint.
	_paint_surface = Control.new()
	_paint_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_paint_surface.mouse_filter = Control.MOUSE_FILTER_STOP
	_paint_surface.tooltip_text = "Drag on the face to paint war paint / scars / tattoos"
	_paint_surface.gui_input.connect(_on_paint_input)
	pv_holder.add_child(_paint_surface)

	# ── Option rows (right) — scrollable so the paint tools never overflow ──────
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)

	var opts := VBoxContainer.new()
	opts.add_theme_constant_override("separation", 8)
	opts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(opts)

	_add_option(opts, "Skin Tone",  "skin",       Appearance.SKIN_TONES.size())
	_add_option(opts, "Hair Style", "hair_style", Appearance.HAIR_STYLE_NAMES.size())
	_add_option(opts, "Hair Color", "hair_color", Appearance.HAIR_COLORS.size())
	_add_option(opts, "Eye Color",  "eye_color",  Appearance.EYE_COLORS.size())
	_add_option(opts, "Beard",      "beard",      Appearance.BEARD_NAMES.size())
	_add_option(opts, "Body Type",  "body",       Appearance.BODY_HALF_W.size())
	_add_option(opts, "Tunic",      "tunic",      Appearance.TUNIC_COLORS.size())

	_build_paint_controls(opts)

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
	_appr["eye_color"]  = randi() % Appearance.EYE_COLORS.size()
	_appr["beard"]      = randi() % Appearance.BEARD_NAMES.size()
	_appr["body"]       = randi() % Appearance.BODY_HALF_W.size()
	_appr["tunic"]      = randi() % Appearance.TUNIC_COLORS.size()
	_refresh_preview()

# ── Free-hand face paint ──────────────────────────────────────────────────────
func _build_paint_controls(parent: VBoxContainer) -> void:
	parent.add_child(HSeparator.new())

	var head := Label.new()
	head.text = "Body Ink  —  pick a view, drag on the skin"
	head.add_theme_color_override("font_color", RS_GOLD)
	head.add_theme_font_size_override("font_size", 13)
	parent.add_child(head)

	# View selector (zooms the preview + picks the paint region).
	var view_row := HBoxContainer.new()
	view_row.add_theme_constant_override("separation", 3)
	parent.add_child(view_row)
	_view_btns.clear()
	for spec: Array in [["Full", -1], ["Face", 0], ["L Arm", 1], ["R Arm", 2]]:
		var vb := _btn(str(spec[0]), false)
		vb.custom_minimum_size = Vector2(56, 26)
		vb.pressed.connect(_set_view.bind(int(spec[1])))
		view_row.add_child(vb)
		_view_btns.append(vb)

	# Ink swatches (war paint colours + scar tones).
	var swatch_row := HBoxContainer.new()
	swatch_row.add_theme_constant_override("separation", 3)
	parent.add_child(swatch_row)
	_swatch_btns.clear()
	for i in range(Appearance.FACE_MARK_COLORS.size()):
		var col: Color = Appearance.FACE_MARK_COLORS[i]
		var sw := Button.new()
		sw.custom_minimum_size = Vector2(24, 20)
		sw.tooltip_text = Appearance.FACE_MARK_COLOR_NAMES[i]
		sw.add_theme_stylebox_override("hover",   _rs(col, RS_GOLD, 2))
		sw.add_theme_stylebox_override("pressed", _rs(col, RS_GOLD, 2))
		sw.add_theme_stylebox_override("focus",   _rs(col, RS_BORDER.darkened(0.3), 1))
		sw.pressed.connect(_on_ink_picked.bind(i))
		swatch_row.add_child(sw)
		_swatch_btns.append(sw)

	# Brush width + undo/clear.
	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 4)
	parent.add_child(tool_row)
	_width_btns.clear()
	for wi in range(_WIDTHS.size()):
		var wb := _btn(str(_WIDTHS[wi][0]), false)
		wb.custom_minimum_size = Vector2(40, 24)
		wb.pressed.connect(_on_width_picked.bind(float(_WIDTHS[wi][1])))
		tool_row.add_child(wb)
		_width_btns.append(wb)
	var undo := _btn("Undo", false)
	undo.custom_minimum_size = Vector2(48, 24)
	undo.pressed.connect(_on_paint_undo)
	tool_row.add_child(undo)
	var clr := _btn("Clear", false)
	clr.custom_minimum_size = Vector2(48, 24)
	clr.pressed.connect(_on_paint_clear)
	tool_row.add_child(clr)

	# Preset stamps (tattoos + scars) are DISABLED for now — not visually ready.
	# The data + generators (`Appearance.preset_strokes`, `_stamp_picker`,
	# `_on_stamp_selected`) are kept for when they're re-enabled. See backlog.

	_update_ink_highlight()
	_update_view_highlight()

## An OptionButton whose first row is a label; selecting a design stamps it.
func _stamp_picker(label: String, names: Array, kind: String) -> OptionButton:
	var ob := OptionButton.new()
	ob.add_theme_font_size_override("font_size", 12)
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.add_item(label + "  ▾")
	ob.set_item_disabled(0, true)
	for n: String in names:
		ob.add_item(str(n))
	ob.selected = 0
	ob.item_selected.connect(_on_stamp_selected.bind(kind, ob))
	return ob

func _on_stamp_selected(index: int, kind: String, ob: OptionButton) -> void:
	if index <= 0:
		return
	var reg: int = _paint_region if _paint_region >= 0 else 0
	if _paint_region < 0:
		_set_view(0)   # jump to the face so the stamp is visible
	var strokes := Appearance.preset_strokes(kind, index - 1, reg, _ink_color)
	var marks: Array = _appr["face_marks"]
	for s: Dictionary in strokes:
		if marks.size() >= Appearance.FACE_MARK_MAX_STROKES:
			break
		marks.append(s)
	ob.selected = 0   # reset so the same design can be picked again
	_refresh_preview()

func _on_ink_picked(idx: int) -> void:
	_ink_color = idx
	_update_ink_highlight()

func _on_width_picked(w: float) -> void:
	_ink_width = w
	_update_ink_highlight()

## Zoom the preview to a region and arm painting there (-1 = full, no paint).
func _set_view(region: int) -> void:
	_paint_region = region
	_active = {}
	match region:
		0:  _apply_zoom(6.5, Vector2(0, -16))
		1:  _apply_zoom(7.0, Appearance.region_anchor(1, _bw()))
		2:  _apply_zoom(7.0, Appearance.region_anchor(2, _bw()))
		_:  # Full
			_preview.scale = Vector2(3.6, 3.6)
			_preview.position = Vector2(90, 200)
	_update_view_highlight()

func _apply_zoom(zoom: float, center: Vector2) -> void:
	_preview.scale = Vector2(zoom, zoom)
	_preview.position = Vector2(90, 128) - center * zoom   # frame `center` in the box

func _bw() -> int:
	return Appearance.BODY_HALF_W[clampi(int(_appr.get("body", 1)), 0, Appearance.BODY_HALF_W.size() - 1)]

func _update_view_highlight() -> void:
	var idx := clampi(_paint_region + 1, 0, _view_btns.size() - 1)
	for i in range(_view_btns.size()):
		(_view_btns[i] as Button).add_theme_color_override("font_color",
			RS_GOLD if i == idx else RS_TEXT)

## Highlight the selected swatch + width so the current ink is obvious.
func _update_ink_highlight() -> void:
	for i in range(_swatch_btns.size()):
		var col: Color = Appearance.FACE_MARK_COLORS[i]
		var border: Color = RS_GOLD if i == _ink_color else RS_BORDER.darkened(0.3)
		var bw: int = 3 if i == _ink_color else 1
		(_swatch_btns[i] as Button).add_theme_stylebox_override("normal", _rs(col, border, bw))
	for wi in range(_width_btns.size()):
		var sel: bool = is_equal_approx(float(_WIDTHS[wi][1]), _ink_width)
		(_width_btns[wi] as Button).add_theme_color_override("font_color",
			RS_GOLD if sel else RS_TEXT)

func _on_paint_input(event: InputEvent) -> void:
	if _paint_region < 0:
		return   # Full view — nothing to paint
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_stroke(mb.position)
			else:
				_active = {}
	elif event is InputEventMouseMotion and not _active.is_empty():
		_extend_stroke((event as InputEventMouseMotion).position)

## Paint-surface point → region-local, clamped onto that region's SKIN.
## Returns Vector2.INF when the point is off the skin.
func _to_region(pos: Vector2) -> Vector2:
	var cl := (pos - _preview.position) / _preview.scale.x
	var rl := cl - Appearance.region_anchor(_paint_region, _bw())
	if _paint_region == 0:            # face disc
		if rl.length() > 15.0:
			return Vector2.INF
		if rl.length() > 8.0:
			rl = rl.normalized() * 8.0
	else:                             # thin upper-arm strip
		if absf(rl.x) > 6.0 or rl.y < -9.0 or rl.y > 9.0:
			return Vector2.INF
		rl.x = clampf(rl.x, -2.6, 2.6)
		rl.y = clampf(rl.y, -7.0, 7.0)
	return rl

func _begin_stroke(pos: Vector2) -> void:
	var marks: Array = _appr["face_marks"]
	if marks.size() >= Appearance.FACE_MARK_MAX_STROKES:
		return
	var rl := _to_region(pos)
	if rl == Vector2.INF:
		return
	_active = {"r": _paint_region, "c": _ink_color, "w": _ink_width, "pts": [rl.x, rl.y]}
	_last_fp = rl
	marks.append(_active)
	_refresh_preview()

func _extend_stroke(pos: Vector2) -> void:
	var rl := _to_region(pos)
	if rl == Vector2.INF:
		return
	if rl.distance_to(_last_fp) < 0.4:
		return   # thin out dense samples so a stroke stays JSON-light
	var pts: Array = _active["pts"]
	if pts.size() >= Appearance.FACE_MARK_MAX_PTS:
		return
	pts.append(rl.x)
	pts.append(rl.y)
	_last_fp = rl
	_refresh_preview()

func _on_paint_undo() -> void:
	var marks: Array = _appr["face_marks"]
	if not marks.is_empty():
		marks.pop_back()
		_active = {}
		_refresh_preview()

func _on_paint_clear() -> void:
	(_appr["face_marks"] as Array).clear()
	_active = {}
	_refresh_preview()

func _refresh_preview() -> void:
	if _preview != null:
		_preview.call("set_appearance", _appr)
	_value_lbls["skin"].text       = "Tone %d" % (int(_appr["skin"]) + 1)
	_value_lbls["hair_style"].text = Appearance.HAIR_STYLE_NAMES[int(_appr["hair_style"])]
	_value_lbls["hair_color"].text = Appearance.HAIR_COLOR_NAMES[int(_appr["hair_color"])]
	_value_lbls["eye_color"].text  = Appearance.EYE_COLOR_NAMES[int(_appr["eye_color"])]
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
