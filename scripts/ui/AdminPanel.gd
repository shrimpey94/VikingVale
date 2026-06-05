extends CanvasLayer

## In-world admin toolbox — only spawned for the "Busterrdust" account
## (World creates it on login). Toggle with F10 or the on-screen ⚙ button.
## Modes:
##   Place  — click the map to place the selected entity (saved server-side).
##   Delete — click an existing admin entity to remove it permanently.
##   Move   — drag an existing admin entity to reposition it.
##   Tile   — paint terrain tiles (incl. cliffs) with the selected biome; drag to
##            paint, pick "(erase)" to revert a tile. All persisted forever.
## Gold/spawn commands are typed in chat (/gold, /spawn) and handled by the HUD.

const Catalog = preload("res://scripts/AdminCatalog.gd")
const UITheme = preload("res://scripts/ui/UITheme.gd")
const Boats   = preload("res://scripts/Boat.gd")
const TILE := 32.0

const PAINT_BIOMES: Array = [
	"plains", "oak_forest", "pine_forest", "dark_forest", "swamp",
	"mountain", "cliff", "rocky", "coast", "ocean",
	"snow", "helheim", "ashlands", "town", "road", "(erase)",
]

enum Mode { OFF, PLACE, DELETE, MOVE, TILE }

var _mode: int = Mode.OFF
var _entries: Array = []

var _panel:     PanelContainer = null
var _overlay:   Control        = null
var _toggle:    Button         = null
var _type_opt:  OptionButton   = null
var _biome_opt: OptionButton   = null
var _mode_lbl:  Label          = null

# Level adjuster shown only when the picked entity is a monster. SpinBox
# defaults to the catalog's intrinsic level for the selected type (so
# choosing Goblin starts at 5, Níðhöggr at 60) but the admin can override
# 1..99 before placing; that value flows through into the data dict sent
# to the server and ultimately Monster.scale_to_level(lv).
var _level_row:  HBoxContainer  = null
var _level_spin: SpinBox        = null

# Tab structure — the panel splits into "World" (existing place/delete/move/
# tile controls) and "Items" (admin item give/take/view/restore).
var _world_section: VBoxContainer = null
var _items_section: VBoxContainer = null
var _tab_world_btn: Button        = null
var _tab_items_btn: Button        = null

# Items-tab widgets.
var _items_player_opt: OptionButton    = null
var _items_id_edit:    LineEdit        = null
var _items_qty_spin:   SpinBox         = null
var _items_boat_opt:   OptionButton    = null
var _items_inv_text:   RichTextLabel   = null

# Move-mode drag state
var _drag_id:  String  = ""
var _drag_pos: Vector2 = Vector2.ZERO
# Tile-paint state
var _painting: bool      = false
var _last_tile: Vector2i = Vector2i(-9999, -9999)

func _ready() -> void:
	layer = 250
	_entries = Catalog.entries()
	_build_overlay()
	_build_toggle()
	_build_panel()
	_panel.visible = false
	_overlay.visible = false
	# Server replies for the items tab — populate the player dropdown and the
	# inventory-view RichTextLabel when the server responds to our requests.
	Events.admin_player_list_received.connect(_on_admin_player_list_received)
	Events.admin_inventory_view_received.connect(_on_admin_inventory_view_received)

# ── UI construction ────────────────────────────────────────────────────────────
func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.gui_input.connect(_on_overlay_input)
	add_child(_overlay)

func _build_toggle() -> void:
	_toggle = Button.new()
	_toggle.text = "⚙ ADMIN"
	_toggle.position = Vector2(16, 64)
	_toggle.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 2))
	_toggle.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.BORDER, 2))
	_toggle.add_theme_stylebox_override("pressed",UITheme.sb(UITheme.BTN_A, UITheme.BORDER, 2))
	_toggle.add_theme_color_override("font_color", UITheme.GOLD)
	_toggle.add_theme_font_size_override("font_size", 12)
	_toggle.pressed.connect(_toggle_panel)
	add_child(_toggle)

func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, UITheme.BORDER))
	_panel.position = Vector2(16, 96)
	_panel.custom_minimum_size = Vector2(260, 0)
	add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_panel.add_child(vb)

	vb.add_child(UITheme.title("ADMIN  (F10)"))

	# Tab toggle row — two buttons swap which section is visible.
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	vb.add_child(tab_row)
	_tab_world_btn = _tab_button("World", true)
	_tab_items_btn = _tab_button("Items", false)
	_tab_world_btn.pressed.connect(func() -> void: _show_tab("world"))
	_tab_items_btn.pressed.connect(func() -> void: _show_tab("items"))
	tab_row.add_child(_tab_world_btn)
	tab_row.add_child(_tab_items_btn)

	_world_section = _build_world_section()
	_items_section = _build_items_section()
	vb.add_child(_world_section)
	vb.add_child(_items_section)
	_items_section.visible = false

	_update_mode_label()

## Builds the existing world-edit controls (place/delete/move/tile + entity and
## biome pickers + save-map button). Returned as a self-contained VBoxContainer
## so the tab system can toggle its visibility.
func _build_world_section() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)

	_mode_lbl = Label.new()
	_mode_lbl.add_theme_color_override("font_color", UITheme.GOLD)
	vb.add_child(_mode_lbl)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	vb.add_child(row)
	row.add_child(_mode_button("Place",  Mode.PLACE))
	row.add_child(_mode_button("Delete", Mode.DELETE))
	row.add_child(_mode_button("Move",   Mode.MOVE))

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	vb.add_child(row2)
	row2.add_child(_mode_button("Tile",  Mode.TILE))
	row2.add_child(_mode_button("Off",   Mode.OFF))

	var el := Label.new()
	el.text = "Entity:"
	el.add_theme_color_override("font_color", UITheme.DIM)
	el.add_theme_font_size_override("font_size", 11)
	vb.add_child(el)
	_type_opt = OptionButton.new()
	for i in range(_entries.size()):
		var e: Dictionary = _entries[i]
		_type_opt.add_item("%s  (%s)" % [str(e["label"]), str(e["kind"])], i)
	vb.add_child(_type_opt)

	# Level adjuster — visible only when the picked entity is a monster.
	# Defaults sync to the catalog's hardcoded level for the type so a
	# fresh pick mirrors the no-scale baseline; admin can override 1..99
	# before clicking-to-place. SpinBox value rides through _place_at
	# into data.level and flows to Monster.scale_to_level on spawn.
	_level_row = HBoxContainer.new()
	_level_row.add_theme_constant_override("separation", 4)
	vb.add_child(_level_row)
	var ll := Label.new()
	ll.text = "Level:"
	ll.add_theme_color_override("font_color", UITheme.DIM)
	ll.add_theme_font_size_override("font_size", 11)
	_level_row.add_child(ll)
	_level_spin = SpinBox.new()
	_level_spin.min_value = 1
	_level_spin.max_value = 99
	_level_spin.value     = 1
	_level_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_row.add_child(_level_spin)
	_type_opt.item_selected.connect(_on_entity_picked)
	# Seed the initial visibility + level for whatever index the dropdown
	# is starting on (defaults to 0).
	_on_entity_picked(_type_opt.selected if _type_opt.selected >= 0 else 0)

	var bl := Label.new()
	bl.text = "Tile biome:"
	bl.add_theme_color_override("font_color", UITheme.DIM)
	bl.add_theme_font_size_override("font_size", 11)
	vb.add_child(bl)
	_biome_opt = OptionButton.new()
	for i in range(PAINT_BIOMES.size()):
		_biome_opt.add_item(str(PAINT_BIOMES[i]), i)
	vb.add_child(_biome_opt)

	var save_btn := Button.new()
	save_btn.text = "💾  Save Map / Refresh Minimap"
	save_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_A, UITheme.GOLD, 2))
	save_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 2))
	save_btn.add_theme_color_override("font_color", UITheme.GOLD)
	save_btn.pressed.connect(_on_save_map)
	vb.add_child(save_btn)

	var hint := Label.new()
	hint.add_theme_color_override("font_color", UITheme.DIM)
	hint.add_theme_font_size_override("font_size", 11)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(240, 0)
	hint.text = "Tile mode: drag to paint. Chat: /gold <name> <amt>, /spawn <type> <lvl>"
	vb.add_child(hint)
	return vb

## Builds the new Items tab: player dropdown + refresh, give-by-id form, boat
## dropdown + give-boat button, take form, view-inventory + restore-last-loss.
## Every action funnels through NetworkManager.send_admin_* and the server's
## _is_admin gate (so a non-admin tab spawn would be a no-op anyway).
func _build_items_section() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)

	# ── Player dropdown ──
	var pl := Label.new()
	pl.text = "Online player:"
	pl.add_theme_color_override("font_color", UITheme.DIM)
	pl.add_theme_font_size_override("font_size", 11)
	vb.add_child(pl)

	var player_row := HBoxContainer.new()
	player_row.add_theme_constant_override("separation", 4)
	vb.add_child(player_row)
	_items_player_opt = OptionButton.new()
	_items_player_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_items_player_opt.add_item("— (click ↻) —", 0)
	player_row.add_child(_items_player_opt)
	var refresh_btn := Button.new()
	refresh_btn.text = "↻"
	refresh_btn.tooltip_text = "Re-fetch the online player list from the server."
	refresh_btn.pressed.connect(_on_refresh_players)
	player_row.add_child(refresh_btn)

	# ── Give item by id + qty ──
	vb.add_child(_section_label("Give item"))
	_items_id_edit = LineEdit.new()
	_items_id_edit.placeholder_text = "item_id (e.g. oak_log)"
	vb.add_child(_items_id_edit)

	var give_row := HBoxContainer.new()
	give_row.add_theme_constant_override("separation", 4)
	vb.add_child(give_row)
	_items_qty_spin = SpinBox.new()
	_items_qty_spin.min_value = 1
	_items_qty_spin.max_value = 28
	_items_qty_spin.value     = 1
	_items_qty_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	give_row.add_child(_items_qty_spin)
	var give_btn := Button.new()
	give_btn.text = "Give"
	give_btn.pressed.connect(_on_give_item)
	give_row.add_child(give_btn)
	var take_btn := Button.new()
	take_btn.text = "Take"
	take_btn.tooltip_text = "Remove the same id + qty from the player's inventory."
	take_btn.pressed.connect(_on_take_item)
	give_row.add_child(take_btn)

	# ── Boat give ──
	vb.add_child(_section_label("Give boat"))
	_items_boat_opt = OptionButton.new()
	_items_boat_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var idx := 0
	for bid: Variant in Boats.BOATS.keys():
		var bdata: Dictionary = Boats.BOATS[bid]
		_items_boat_opt.add_item("%s  (T%d)" % [str(bdata.get("name", bid)),
			int(bdata.get("tier", 0))], idx)
		_items_boat_opt.set_item_metadata(idx, str(bid))
		idx += 1
	vb.add_child(_items_boat_opt)
	var boat_btn := Button.new()
	boat_btn.text = "Give selected boat"
	boat_btn.pressed.connect(_on_give_boat)
	vb.add_child(boat_btn)

	# ── View inventory + restore last loss ──
	vb.add_child(_section_label("Inventory"))
	var view_row := HBoxContainer.new()
	view_row.add_theme_constant_override("separation", 4)
	vb.add_child(view_row)
	var view_btn := Button.new()
	view_btn.text = "View"
	view_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_btn.pressed.connect(_on_view_inventory)
	view_row.add_child(view_btn)
	var restore_btn := Button.new()
	restore_btn.text = "Restore last loss"
	restore_btn.tooltip_text = "Re-grant the most recent item that disappeared from this player's inventory."
	restore_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restore_btn.pressed.connect(_on_restore_last_loss)
	view_row.add_child(restore_btn)

	_items_inv_text = RichTextLabel.new()
	_items_inv_text.bbcode_enabled = true
	_items_inv_text.fit_content = true
	_items_inv_text.scroll_active = true
	_items_inv_text.custom_minimum_size = Vector2(240, 110)
	_items_inv_text.add_theme_color_override("default_color", UITheme.DIM)
	_items_inv_text.text = "[i]No inventory loaded.[/i]"
	vb.add_child(_items_inv_text)
	return vb

func _tab_button(text: String, active: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bg := UITheme.BTN_A if active else UITheme.BTN_N
	b.add_theme_stylebox_override("normal", UITheme.sb(bg, UITheme.GOLD if active else UITheme.BORDER, 2))
	b.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.BORDER, 2))
	b.add_theme_color_override("font_color", UITheme.GOLD)
	return b

func _show_tab(which: String) -> void:
	var world := which == "world"
	if _world_section != null: _world_section.visible = world
	if _items_section != null: _items_section.visible = not world
	if _tab_world_btn != null:
		_tab_world_btn.add_theme_stylebox_override("normal",
			UITheme.sb(UITheme.BTN_A if world else UITheme.BTN_N,
				UITheme.GOLD if world else UITheme.BORDER, 2))
	if _tab_items_btn != null:
		_tab_items_btn.add_theme_stylebox_override("normal",
			UITheme.sb(UITheme.BTN_A if not world else UITheme.BTN_N,
				UITheme.GOLD if not world else UITheme.BORDER, 2))
	# Auto-fetch the player list the first time the Items tab is opened
	# (saves the admin a manual ↻ click when they switch tabs).
	if not world and _items_player_opt != null and _items_player_opt.item_count <= 1:
		_on_refresh_players()

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.GOLD)
	l.add_theme_font_size_override("font_size", 11)
	return l

## Returns the username currently selected in the player dropdown, or "" if
## nothing real is selected (e.g. the placeholder entry).
func _selected_target() -> String:
	if _items_player_opt == null or _items_player_opt.selected < 0:
		return ""
	var idx := _items_player_opt.selected
	var md: Variant = _items_player_opt.get_item_metadata(idx)
	return str(md) if md != null else ""

func _on_refresh_players() -> void:
	NetworkManager.send_admin_list_players()

func _on_admin_player_list_received(usernames: Array) -> void:
	if _items_player_opt == null:
		return
	var keep := _selected_target()
	_items_player_opt.clear()
	if usernames.is_empty():
		_items_player_opt.add_item("— no players online —", 0)
		return
	for i in range(usernames.size()):
		var uname: String = str(usernames[i])
		_items_player_opt.add_item(uname, i)
		_items_player_opt.set_item_metadata(i, uname)
		if uname == keep:
			_items_player_opt.select(i)

func _on_admin_inventory_view_received(target: String, online: bool, inventory: Array) -> void:
	if _items_inv_text == null:
		return
	var status := "online" if online else "offline (DB read)"
	var lines: Array = []
	lines.append("[b]%s[/b]  [color=#888](%s)[/color]" % [target, status])
	if inventory.is_empty():
		lines.append("[i](empty)[/i]")
	else:
		for it: Variant in inventory:
			if it is Dictionary:
				var d: Dictionary = it
				lines.append("• %s × %d  [color=#888](%s)[/color]" % [
					str(d.get("name", d.get("id", "?"))),
					int(d.get("qty", 1)),
					str(d.get("id", "?"))])
	_items_inv_text.text = "\n".join(lines)

func _on_give_item() -> void:
	var target := _selected_target()
	var iid := _items_id_edit.text.strip_edges() if _items_id_edit != null else ""
	var qty := int(_items_qty_spin.value) if _items_qty_spin != null else 1
	if target == "" or iid == "" or qty <= 0:
		Events.chat_message.emit("[Admin] Need player + item id + qty.")
		return
	NetworkManager.send_admin_give_item(target, iid,
		iid.replace("_", " ").capitalize(), qty, Color(0.7, 0.7, 0.7, 1.0))

func _on_take_item() -> void:
	var target := _selected_target()
	var iid := _items_id_edit.text.strip_edges() if _items_id_edit != null else ""
	var qty := int(_items_qty_spin.value) if _items_qty_spin != null else 1
	if target == "" or iid == "" or qty <= 0:
		Events.chat_message.emit("[Admin] Need player + item id + qty.")
		return
	NetworkManager.send_admin_take_item(target, iid, qty)

func _on_give_boat() -> void:
	var target := _selected_target()
	if target == "" or _items_boat_opt == null:
		return
	var bid := str(_items_boat_opt.get_item_metadata(_items_boat_opt.selected))
	var bdata: Dictionary = Boats.data(bid)
	if bdata.is_empty():
		return
	NetworkManager.send_admin_give_item(target, bid,
		str(bdata.get("name", bid)), 1,
		bdata.get("wood", Color(0.55, 0.36, 0.18)))

func _on_view_inventory() -> void:
	var target := _selected_target()
	if target == "":
		return
	NetworkManager.send_admin_view_inventory(target)

func _on_restore_last_loss() -> void:
	var target := _selected_target()
	if target == "":
		return
	NetworkManager.send_admin_restore_last_loss(target)

## Tile edits live in the server's in-memory dict and autosave every 30 s when
## dirty. This button forces an immediate disk flush AND refreshes the minimap
## so painted terrain shows. The server replies with its own confirmation chat.
func _on_save_map() -> void:
	NetworkManager.send_admin_save_map()
	Events.minimap_refresh.emit()

func _mode_button(text: String, mode: int) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 2))
	b.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.BORDER, 2))
	b.add_theme_stylebox_override("pressed",UITheme.sb(UITheme.BTN_A, UITheme.BORDER, 2))
	b.pressed.connect(func() -> void: _set_mode(mode))
	return b

func _set_mode(mode: int) -> void:
	_mode = mode
	_drag_id = ""
	_painting = false
	_overlay.mouse_filter = (Control.MOUSE_FILTER_IGNORE if mode == Mode.OFF
							 else Control.MOUSE_FILTER_STOP)
	_update_mode_label()

func _update_mode_label() -> void:
	if _mode_lbl == null:
		return
	match _mode:
		Mode.PLACE:  _mode_lbl.text = "Mode: PLACE — click map"
		Mode.DELETE: _mode_lbl.text = "Mode: DELETE — click entity"
		Mode.MOVE:   _mode_lbl.text = "Mode: MOVE — drag entity"
		Mode.TILE:   _mode_lbl.text = "Mode: TILE — drag to paint"
		_:           _mode_lbl.text = "Mode: off"

func _toggle_panel() -> void:
	var show_now := not _panel.visible
	_panel.visible   = show_now
	_overlay.visible = show_now
	if not show_now:
		_set_mode(Mode.OFF)

# ── Input ──────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo \
			and (event as InputEventKey).keycode == KEY_F10:
		_toggle_panel()
		get_viewport().set_input_as_handled()

func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_pos

func _world() -> Node:
	return get_parent()

func _on_overlay_input(event: InputEvent) -> void:
	if _mode == Mode.OFF:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		var wpos := _screen_to_world(mb.position)
		if mb.pressed and NetworkManager.state != NetworkManager.NetState.LOGGED_IN:
			Events.chat_message.emit("[Admin] Not connected to the server — action ignored.")
		match _mode:
			Mode.PLACE:
				if mb.pressed: _place_at(wpos)
			Mode.DELETE:
				if mb.pressed: _delete_at(wpos)
			Mode.MOVE:
				if mb.pressed:
					_drag_id = str((_world() as Object).call("admin_entity_at", wpos, 44.0))
				elif _drag_id != "":
					NetworkManager.send_admin_move(_drag_id, _drag_pos.x, _drag_pos.y)
					_drag_id = ""
			Mode.TILE:
				_painting = mb.pressed
				if mb.pressed:
					_last_tile = Vector2i(-9999, -9999)
					_paint_at(wpos)
		_overlay.accept_event()
	elif event is InputEventMouseMotion:
		var wpos := _screen_to_world((event as InputEventMouseMotion).position)
		if _mode == Mode.MOVE and _drag_id != "":
			_drag_pos = wpos
		elif _mode == Mode.TILE and _painting:
			_paint_at(wpos)

func _place_at(wpos: Vector2) -> void:
	var idx := _type_opt.get_selected_id()
	if idx < 0 or idx >= _entries.size():
		return
	var e: Dictionary = _entries[idx]
	# Duplicate the catalog's data dict before mutating — without this, a
	# placed monster would permanently overwrite the catalog's intrinsic
	# level for the rest of the session.
	var data: Dictionary = (e["data"] as Dictionary).duplicate()
	if str(e.get("kind", "")) == "monster" and _level_spin != null:
		data["level"] = int(_level_spin.value)
	NetworkManager.send_admin_place(str(e["kind"]), _subtype_of(e),
		wpos.x, wpos.y, data)

## Show the level row + seed the SpinBox when a monster is picked; hide it
## for resources and NPCs. Wired to OptionButton.item_selected and also
## called once during _build_world_section so the initial selection's
## visibility is correct.
func _on_entity_picked(idx: int) -> void:
	if idx < 0 or idx >= _entries.size() or _level_row == null:
		return
	var e: Dictionary = _entries[idx]
	var is_monster := str(e.get("kind", "")) == "monster"
	_level_row.visible = is_monster
	if is_monster and _level_spin != null:
		_level_spin.value = int((e["data"] as Dictionary).get("level", 1))

func _subtype_of(e: Dictionary) -> String:
	var d: Dictionary = e["data"] as Dictionary
	match str(e["kind"]):
		"resource": return str(d.get("type_str", ""))
		"monster":  return str(d.get("monster_type", ""))
		"npc":      return str(d.get("npc_type", ""))
	return ""

func _delete_at(wpos: Vector2) -> void:
	var id := str((_world() as Object).call("admin_entity_at", wpos, 44.0))
	if id != "":
		NetworkManager.send_admin_delete(id)

func _paint_at(wpos: Vector2) -> void:
	var t := Vector2i(int(floor(wpos.x / TILE)), int(floor(wpos.y / TILE)))
	if t == _last_tile:
		return
	_last_tile = t
	var biome := str(PAINT_BIOMES[_biome_opt.get_selected_id()])
	if biome == "(erase)":
		NetworkManager.send_admin_tile_clear(t.x, t.y)
	else:
		NetworkManager.send_admin_tile_set(t.x, t.y, biome)
