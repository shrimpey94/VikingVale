extends CanvasLayer

## Character Backstory picker. Shown once on first login of any account
## whose `backstory` column is empty (new account, OR a legacy account
## upgraded via v13 migration). Five tiles, click to pick, confirm.
##
## Server enforces single-set: a second pick is rejected. We trust the
## server's rejection to surface the right error, but the UI ALSO won't
## show this screen for an already-set backstory (controlled by World.gd
## checking GameManager.backstory on login).

# Both Backstory and VikingTheme are class_name-declared, so they're
# globally available without preload. Adding explicit preloads here would
# trip strict mode's SHADOWED_GLOBAL_IDENTIFIER warning-as-error.

var _selected: String = ""
var _root: PanelContainer = null
var _confirm_btn: Button = null
var _tile_panels: Dictionary = {}    # id → PanelContainer
var _status_lbl: Label = null


func _ready() -> void:
	layer = 102
	_build()
	# Listen for the server's confirmation, then close.
	NetworkManager.backstory_set.connect(_on_backstory_set)
	NetworkManager.backstory_fail.connect(_on_backstory_fail)


func _build() -> void:
	# Dimmer behind the panel — blocks gameplay clicks while the modal
	# is up. Player can't dismiss; they must pick.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.70)
	dim.anchor_right = 1.0; dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	_root = PanelContainer.new()
	VikingTheme.apply_panel(_root, "primary")
	_root.anchor_left = 0.5; _root.anchor_right = 0.5
	_root.anchor_top  = 0.5; _root.anchor_bottom = 0.5
	_root.offset_left   = -280
	_root.offset_right  =  280
	_root.offset_top    = -210
	_root.offset_bottom =  210
	add_child(_root)

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left", 18)
	outer.add_theme_constant_override("margin_right", 18)
	outer.add_theme_constant_override("margin_top", 16)
	outer.add_theme_constant_override("margin_bottom", 16)
	_root.add_child(outer)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	outer.add_child(body)

	body.add_child(VikingTheme.section_header("Choose your background", 15))
	body.add_child(VikingTheme.caption(
		"A single permanent perk that nudges early progression. You can "
		+ "still train every skill — this just gives you a head start."))
	body.add_child(VikingTheme.divider())

	# 5 tiles in a row. Each: icon + name + small bonus summary.
	var tiles_row := HBoxContainer.new()
	tiles_row.add_theme_constant_override("separation", 6)
	body.add_child(tiles_row)
	for id: String in Backstory.ids():
		var tile := _build_tile(id)
		_tile_panels[id] = tile
		tiles_row.add_child(tile)

	_status_lbl = Label.new()
	_status_lbl.add_theme_color_override("font_color", VikingTheme.DIM)
	_status_lbl.add_theme_font_size_override("font_size", 10)
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_status_lbl)

	# Confirm button
	_confirm_btn = Button.new()
	_confirm_btn.text = "Confirm"
	_confirm_btn.disabled = true
	_confirm_btn.custom_minimum_size = Vector2(0, 32)
	VikingTheme.apply_button(_confirm_btn, true)
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	body.add_child(_confirm_btn)


func _build_tile(id: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel",
		VikingTheme._sb(VikingTheme.BG_CARD, VikingTheme.BORDER_D, 1, 3))
	pc.custom_minimum_size = Vector2(92, 130)
	pc.mouse_filter = Control.MOUSE_FILTER_STOP

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 3)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_child(inner)

	var ico := Label.new()
	ico.text = Backstory.icon_of(id)
	ico.add_theme_font_size_override("font_size", 26)
	ico.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(ico)

	var name_lbl := Label.new()
	name_lbl.text = Backstory.name_of(id)
	name_lbl.add_theme_color_override("font_color", VikingTheme.GOLD)
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(name_lbl)

	var flav := Label.new()
	flav.text = Backstory.flavor(id)
	flav.add_theme_color_override("font_color", VikingTheme.DIM)
	flav.add_theme_font_size_override("font_size", 8)
	flav.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flav.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(flav)

	var summary := Label.new()
	summary.text = Backstory.summary(id)
	summary.add_theme_color_override("font_color", VikingTheme.TEXT)
	summary.add_theme_font_size_override("font_size", 9)
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(summary)

	# Whole tile is clickable via gui_input on the PanelContainer.
	pc.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_on_tile_clicked(id))
	return pc


func _on_tile_clicked(id: String) -> void:
	_selected = id
	for tid: Variant in _tile_panels.keys():
		var tile: PanelContainer = _tile_panels[tid] as PanelContainer
		var is_sel: bool = (str(tid) == id)
		tile.add_theme_stylebox_override("panel",
			VikingTheme._sb(VikingTheme.BG_CARD,
				VikingTheme.GOLD if is_sel else VikingTheme.BORDER_D,
				2 if is_sel else 1, 3))
	_confirm_btn.disabled = false


func _on_confirm_pressed() -> void:
	if _selected.is_empty():
		return
	_confirm_btn.disabled = true
	_status("Saving…", VikingTheme.DIM)
	NetworkManager.send_set_backstory(_selected)


func _on_backstory_set(bs: String) -> void:
	# Apply locally so the perks are live this session without needing
	# a re-login. GameManager.backstory mirrors the server.
	GameManager.backstory = bs
	Backstory.apply(bs, PlayerMods)
	queue_free()


func _on_backstory_fail(reason: String) -> void:
	_status(reason, VikingTheme.RED)
	_confirm_btn.disabled = false


func _status(text: String, col: Color) -> void:
	if _status_lbl == null:
		return
	_status_lbl.text = text
	_status_lbl.add_theme_color_override("font_color", col)
