extends CanvasLayer

## Fishing Journal (1.6.3) — a modal listing every species you (or anyone) has
## logged, with YOUR personal best beside the WORLD record + holder. Reads the
## caches NetworkManager fills from the server (fishing_journal + fishing_records).
##
##   var fj := preload("res://scripts/ui/FishingJournal.gd").new()
##   get_tree().current_scene.add_child(fj)   # HUD spawns it on Events.open_fishing_journal

const UITheme = preload("res://scripts/ui/UITheme.gd")

var _list: VBoxContainer = null

func _ready() -> void:
	layer = 235
	_build()
	Events.fishing_data_updated.connect(_populate)
	NetworkManager.request_fishing_data()

func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.color = Color(0, 0, 0, 0.5)
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			queue_free())
	add_child(bg)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, UITheme.GOLD, 3))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(420, 0)
	panel.position = Vector2(-210, -220)
	bg.add_child(panel)

	var margin := MarginContainer.new()
	for m: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	margin.add_child(vb)

	var hdr := HBoxContainer.new()
	var title := Label.new()
	title.text = "📓  Fishing Journal"
	title.add_theme_color_override("font_color", UITheme.GOLD)
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(title)
	var close := Button.new()
	close.text = "✕"
	close.pressed.connect(func() -> void: queue_free())
	hdr.add_child(close)
	vb.add_child(hdr)

	var colhdr := HBoxContainer.new()
	colhdr.add_theme_constant_override("separation", 4)
	for c: Array in [["Species", 130], ["Your best", 84], ["World record", 84], ["Holder", 96]]:
		var l := Label.new()
		l.text = str(c[0])
		l.custom_minimum_size = Vector2(int(c[1]), 0)
		l.add_theme_color_override("font_color", UITheme.DIM)
		l.add_theme_font_size_override("font_size", 9)
		colhdr.add_child(l)
	vb.add_child(colhdr)
	vb.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 1)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	_populate()

func _populate() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	for c: Node in _list.get_children():
		c.queue_free()
	# Merge journal (my bests) + records (world bests) by species.
	var rows: Dictionary = {}
	for e: Variant in NetworkManager.fishing_records:
		if e is Dictionary:
			var d: Dictionary = e
			rows[str(d.get("species", ""))] = {
				"name": str(d.get("name", d.get("species", "?"))),
				"mine": 0.0,
				"world": float(d.get("weight", 0.0)),
				"holder": str(d.get("holder", "?")),
			}
	for e: Variant in NetworkManager.fishing_journal:
		if e is Dictionary:
			var d: Dictionary = e
			var sp := str(d.get("species", ""))
			if not rows.has(sp):
				rows[sp] = {"name": str(d.get("name", sp)), "mine": 0.0,
							"world": 0.0, "holder": "—"}
			rows[sp]["mine"] = float(d.get("weight", 0.0))
	if rows.is_empty():
		var l := Label.new()
		l.text = "No catches logged yet — cast a line!"
		l.add_theme_color_override("font_color", UITheme.DIM)
		l.add_theme_font_size_override("font_size", 11)
		_list.add_child(l)
		return
	var me := NetworkManager.my_username
	var species_keys := rows.keys()
	species_keys.sort()
	for sp: Variant in species_keys:
		var r: Dictionary = rows[sp]
		var i_hold := str(r["holder"]) == me
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var mine_txt := "%.1f kg" % float(r["mine"]) if float(r["mine"]) > 0.0 else "—"
		var world_txt := "%.1f kg" % float(r["world"]) if float(r["world"]) > 0.0 else "—"
		var cells: Array = [
			[str(r["name"]), 130, UITheme.TEXT],
			[mine_txt, 84, UITheme.GREEN if float(r["mine"]) > 0.0 else UITheme.DIM],
			[world_txt, 84, UITheme.GOLD],
			[str(r["holder"]), 96, UITheme.GREEN if i_hold else UITheme.TEXT],
		]
		for c: Array in cells:
			var l := Label.new()
			l.text = str(c[0])
			l.custom_minimum_size = Vector2(int(c[1]), 0)
			l.add_theme_font_size_override("font_size", 11)
			l.add_theme_color_override("font_color", c[2])
			row.add_child(l)
		_list.add_child(row)
