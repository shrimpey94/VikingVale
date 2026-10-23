extends VBoxContainer

## Hiscores tab (Phase 3 #4) — LIVE leaderboard over real accounts. Requests
## the rankings from the server on show, renders rank / name / character level
## (combat-weighted, matching nameplates + the skills tab) with the raw skill
## total as a secondary column.

const UITheme = preload("res://scripts/ui/UITheme.gd")

var _list: VBoxContainer = null
var _fish_list: VBoxContainer = null

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(UITheme.title("Hiscores"))
	add_child(HSeparator.new())

	# Column header.
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 4)
	for col: Array in [["#", 24], ["Player", 120], ["Lv", 34], ["Total", 44]]:
		var l := Label.new()
		l.text = str(col[0])
		l.custom_minimum_size = Vector2(int(col[1]), 0)
		l.add_theme_color_override("font_color", UITheme.DIM)
		l.add_theme_font_size_override("font_size", 9)
		hdr.add_child(l)
	add_child(hdr)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size   = Vector2(0, 250)
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 1)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	# ── Biggest Catch (fishing leaderboard, 1.6.3) ──────────────────────────
	add_child(HSeparator.new())
	var fhdr := HBoxContainer.new()
	var ftitle := Label.new()
	ftitle.text = "🎣  Biggest Catch"
	ftitle.add_theme_color_override("font_color", UITheme.GOLD)
	ftitle.add_theme_font_size_override("font_size", 12)
	ftitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fhdr.add_child(ftitle)
	var jbtn := Button.new()
	jbtn.text = "📓 My Journal"
	jbtn.add_theme_font_size_override("font_size", 10)
	jbtn.pressed.connect(func() -> void: Events.open_fishing_journal.emit())
	fhdr.add_child(jbtn)
	add_child(fhdr)

	var fscroll := ScrollContainer.new()
	fscroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fscroll.custom_minimum_size = Vector2(0, 140)
	fscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(fscroll)
	_fish_list = VBoxContainer.new()
	_fish_list.add_theme_constant_override("separation", 1)
	_fish_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fscroll.add_child(_fish_list)

	Events.rankings_updated.connect(_on_rankings_updated)
	Events.fishing_data_updated.connect(_on_fishing_data)
	# Refresh whenever the tab is shown (+ once now if already visible).
	visibility_changed.connect(func() -> void:
		if visible:
			NetworkManager.send_rankings_request()
			NetworkManager.request_fishing_data())
	NetworkManager.send_rankings_request()
	NetworkManager.request_fishing_data()
	_set_placeholder("Loading…")
	_on_fishing_data()

func _on_fishing_data() -> void:
	if _fish_list == null or not is_instance_valid(_fish_list):
		return
	for c: Node in _fish_list.get_children():
		c.queue_free()
	var recs: Array = NetworkManager.fishing_records
	if recs.is_empty():
		var l := Label.new()
		l.text = "No catches recorded yet — be the first!"
		l.add_theme_color_override("font_color", UITheme.DIM)
		l.add_theme_font_size_override("font_size", 10)
		_fish_list.add_child(l)
		return
	var me := NetworkManager.my_username
	for e: Variant in recs:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e as Dictionary
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var mine := str(d.get("holder", "")) == me
		var cells: Array = [
			[str(d.get("name", d.get("species", "?"))), 108],
			["%.1f kg" % float(d.get("weight", 0.0)), 56],
			[str(d.get("holder", "?")), 96],
		]
		for c: Array in cells:
			var l := Label.new()
			l.text = str(c[0])
			l.custom_minimum_size = Vector2(int(c[1]), 0)
			l.add_theme_font_size_override("font_size", 10)
			l.add_theme_color_override("font_color",
				UITheme.GREEN if mine else UITheme.TEXT)
			row.add_child(l)
		_fish_list.add_child(row)

func _set_placeholder(text: String) -> void:
	if _list == null:
		return
	for c: Node in _list.get_children():
		c.queue_free()
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.DIM)
	l.add_theme_font_size_override("font_size", 10)
	_list.add_child(l)

func _on_rankings_updated(entries: Array) -> void:
	if _list == null or not is_instance_valid(_list):
		return
	if entries.is_empty():
		_set_placeholder("No ranked players yet.")
		return
	for c: Node in _list.get_children():
		c.queue_free()
	var me := NetworkManager.my_username
	var rank := 0
	for e: Variant in entries:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e as Dictionary
		rank += 1
		var uname := str(d.get("username", "?"))
		var is_me := uname == me
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var cells: Array = [
			["%d." % rank, 24],
			[uname, 120],
			[str(int(d.get("level", 0))), 34],
			[str(int(d.get("total", 0))), 44],
		]
		for i in range(cells.size()):
			var l := Label.new()
			l.text = str((cells[i] as Array)[0])
			l.custom_minimum_size = Vector2(int((cells[i] as Array)[1]), 0)
			l.add_theme_font_size_override("font_size", 11)
			var col := UITheme.GOLD if rank <= 3 else UITheme.TEXT
			if is_me:
				col = UITheme.GREEN
			l.add_theme_color_override("font_color", col)
			row.add_child(l)
		_list.add_child(row)
