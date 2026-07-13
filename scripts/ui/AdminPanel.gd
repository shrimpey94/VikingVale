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
	"snow", "helheim", "ashlands", "town", "road",
	# Interior floors + walls (walls auto-impassable via Ground._is_impassable_bid).
	"wood_floor", "stone_floor", "red_carpet", "hearth_stone",
	"wall_wood", "wall_stone",
	# Exterior additions.
	"sand", "dirt_path", "shallow_water", "farm_crops",
	# Hills (grass-family + non-grass).
	"plains_hills", "oak_hills", "pine_hills", "snow_hills",
	"ashlands_hills", "helheim_hills", "rocky_hills", "sand_hills",
	# Transitions.
	"forest_edge", "swamp_edge", "shore_grass", "snow_line", "cliff_scree",
	# Terrain variety.
	"meadow", "tundra", "clearing", "moss_rock", "volcanic_glass",
	# Water / beach extras.
	"reef", "tidepool", "wet_sand", "driftwood_shore",
	# Bridges — walkable over water.
	"wood_bridge", "stone_bridge",
	"(erase)",
]

# Category-ordered swatch layout for the Tiles tab. Each entry: category
# header string + the biome names to place under it in the swatch grid.
# Kept as a nested Array so a designer can reorder without touching the
# picker logic. Tiles tab renders one Label row per category then a
# GridContainer with one Button per biome.
const _TILE_CATEGORIES: Array = [
	["Grass",       ["plains", "meadow", "tundra", "clearing"]],
	["Forest",      ["oak_forest", "pine_forest", "dark_forest"]],
	["Wetlands",    ["swamp", "farm_crops"]],
	["Rock/Mtn",    ["mountain", "rocky", "cliff"]],
	["Water",       ["coast", "ocean", "shallow_water", "reef", "tidepool"]],
	["Path/Town",   ["town", "road", "dirt_path"]],
	["Snow/Fire",   ["snow", "helheim", "ashlands"]],
	["Beach",       ["sand", "wet_sand", "driftwood_shore"]],
	["Hills",       ["plains_hills", "oak_hills", "pine_hills", "snow_hills",
					 "ashlands_hills", "helheim_hills", "rocky_hills", "sand_hills"]],
	["Transitions", ["forest_edge", "swamp_edge", "shore_grass", "snow_line", "cliff_scree"]],
	["Variety",     ["moss_rock", "volcanic_glass"]],
	["Bridges",     ["wood_bridge", "stone_bridge"]],
	["Interior",    ["wood_floor", "stone_floor", "red_carpet", "hearth_stone",
					 "wall_wood", "wall_stone"]],
]

enum Mode { OFF, PLACE, DELETE, MOVE, TILE, FLOOD, TINT, PASSABILITY, STRUCTURE }

## Category-grouped roster of all 18 Construction buildables. Same shape as
## _TILE_CATEGORIES — the Structures tab renders one Label per category
## then the buildables underneath in an OptionButton (or grid). Kinds map
## to interactable_type_str values that Interactable.gd knows how to draw.
const _STRUCTURE_CATEGORIES: Array = [
	["Defensive", ["wall", "fortified_wall", "fence", "gate",
		"watchtower", "guard_tower"]],
	["Housing",   ["house_frame", "large_house", "grand_hall", "clan_hall"]],
	["Civic",     ["well", "altar", "dock", "market_stall",
		"site_marker", "portal_shrine"]],
	["Utility",   ["workbench", "smith_station", "bank_chest",
		"armory_rack", "plant_bed"]],
]

## Human-readable labels for the structures picker. Keys match kind strings
## in _STRUCTURE_CATEGORIES.
const _STRUCTURE_LABELS: Dictionary = {
	"wall": "Wall", "fortified_wall": "Fortified Wall",
	"fence": "Fence", "gate": "Gate",
	"watchtower": "Watchtower", "guard_tower": "Guard Tower",
	"house_frame": "House Frame", "large_house": "Large House",
	"grand_hall": "Grand Hall", "clan_hall": "Clan Hall",
	"well": "Well", "altar": "Altar", "dock": "Dock",
	"market_stall": "Market Stall", "site_marker": "Site Marker",
	"portal_shrine": "Portal Shrine",
	"workbench": "Workbench", "smith_station": "Smith Station",
	"bank_chest": "Bank Chest", "armory_rack": "Armory Rack",
	"plant_bed": "Plant Bed",
}

## Which buildables consume bars (metal tier picker becomes visible).
const _STRUCTURE_USES_BAR: Dictionary = {
	"smith_station": true, "bank_chest": true, "armory_rack": true,
	"fortified_wall": true, "clan_hall": true, "grand_hall": true,
}

## Wood tier options + display colors — mirrors HUD.gd _CONSTR_WOOD.
const _WOOD_TIERS: Array = [
	["oak",      "Oak",      Color(0.55, 0.36, 0.18)],
	["pine",     "Pine",     Color(0.42, 0.30, 0.14)],
	["cherry",   "Cherry",   Color(0.72, 0.38, 0.42)],
	["ironwood", "Ironwood", Color(0.30, 0.18, 0.08)],
	["frost",    "Frost",    Color(0.72, 0.90, 0.98)],
	["ancient",  "Ancient",  Color(0.55, 0.40, 0.12)],
]

## Metal tier options for buildables that consume bars.
const _BAR_TIERS: Array = [
	["copper_bar",  "Copper",  Color(0.72, 0.42, 0.22)],
	["iron_bar",    "Iron",    Color(0.55, 0.55, 0.60)],
	["gold_bar",    "Gold",    Color(0.88, 0.72, 0.12)],
	["mithril_bar", "Mithril", Color(0.40, 0.65, 0.90)],
	["adamant_bar", "Adamant", Color(0.20, 0.65, 0.30)],
	["runite_bar",  "Runite",  Color(0.65, 0.20, 0.82)],
]

# Brush sizes for TILE / TINT / PASSABILITY modes. 1 = single click.
# 3/5/7 paint odd-sized squares centered on the cursor tile. The FLOOD
# pseudo-mode replaces all brush-size options.
const BRUSH_SIZES := [1, 3, 5, 7]

var _mode: int = Mode.OFF
var _entries: Array = []

var _panel:     PanelContainer = null
var _overlay:   Control        = null
var _toggle:    Button         = null
var _type_opt:  OptionButton   = null
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
var _accounts_section: VBoxContainer = null
# Tiles tab — swatch grid picker + moved tile-editing controls + how-to help.
var _tiles_section: VBoxContainer = null
var _tab_world_btn: Button        = null
var _tab_items_btn: Button        = null
var _tab_accounts_btn: Button     = null
var _tab_tiles_btn:  Button        = null
var _tab_structures_btn: Button    = null
var _structures_section: VBoxContainer = null
# Structures tab state — the kind + wood/bar tier the admin has picked.
var _selected_structure_kind: String = "wall"
var _selected_wood_tier: String = "oak"
var _selected_bar_tier: String = "iron_bar"
var _structure_kind_opt: OptionButton = null
var _structure_wood_opt: OptionButton = null
var _structure_bar_opt:  OptionButton = null
var _structure_bar_row:  HBoxContainer = null
# Selected biome (drives paint). Replaces the old `_biome_opt` selected id
# — swatch grid buttons set this directly. `(erase)` still uses the special
# button at the bottom of the grid.
var _selected_biome: String = "plains"
# Container for the swatch Button widgets — used to re-tint the selected
# swatch's border when the pick changes.
var _swatch_buttons: Dictionary = {}   # biome name → Button
var _help_body: VBoxContainer = null
var _help_toggle_btn: Button = null
# Tint editor widgets — numeric readouts + preview swatch.
var _tint_h_label: Label = null
var _tint_v_label: Label = null
var _tint_preview: ColorRect = null
# Accounts tab state
var _accounts_search: LineEdit    = null
var _accounts_list_root: VBoxContainer = null

# Tile editor v2 state — brush size, flood mode, tint sliders, brush preview
var _brush_size: int = 1
var _flood_mode: bool = false
var _tint_h_slider: HSlider = null
var _tint_v_slider: HSlider = null
var _brush_size_opt: OptionButton = null
# Live preview rectangle drawn under the cursor when a brush larger than 1×1
# is active. A child of the overlay so it inherits the same hit-test mask.
var _brush_preview: ColorRect = null
var _last_mouse_world: Vector2 = Vector2.ZERO

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
	_tab_world_btn      = _tab_button("World", true)
	_tab_tiles_btn      = _tab_button("Tiles", false)
	_tab_structures_btn = _tab_button("Structures", false)
	_tab_items_btn      = _tab_button("Items", false)
	_tab_accounts_btn   = _tab_button("Accounts", false)
	_tab_world_btn.pressed.connect(func() -> void: _show_tab("world"))
	_tab_tiles_btn.pressed.connect(func() -> void: _show_tab("tiles"))
	_tab_structures_btn.pressed.connect(func() -> void: _show_tab("structures"))
	_tab_items_btn.pressed.connect(func() -> void: _show_tab("items"))
	_tab_accounts_btn.pressed.connect(func() -> void: _show_tab("accounts"))
	tab_row.add_child(_tab_world_btn)
	tab_row.add_child(_tab_tiles_btn)
	tab_row.add_child(_tab_structures_btn)
	tab_row.add_child(_tab_items_btn)
	tab_row.add_child(_tab_accounts_btn)

	_world_section      = _build_world_section()
	_tiles_section      = _build_tiles_section()
	_structures_section = _build_structures_section()
	_items_section      = _build_items_section()
	_accounts_section   = _build_accounts_section()
	vb.add_child(_world_section)
	vb.add_child(_tiles_section)
	vb.add_child(_structures_section)
	vb.add_child(_items_section)
	vb.add_child(_accounts_section)
	_tiles_section.visible = false
	_structures_section.visible = false
	_items_section.visible = false
	_accounts_section.visible = false
	# Wire the account-list response signal once.
	Events.admin_account_list_received.connect(_on_account_list_received)

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

	# World tab handles entity placement modes only. Tile / Tint / Passability
	# / Flood + biome swatch grid + tint sliders all live in the Tiles tab.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	vb.add_child(row)
	row.add_child(_mode_button("Place",  Mode.PLACE))
	row.add_child(_mode_button("Delete", Mode.DELETE))
	row.add_child(_mode_button("Move",   Mode.MOVE))
	row.add_child(_mode_button("Off",    Mode.OFF))

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

	# Tile / tint / passability widgets live in the Tiles tab now.

	var save_btn := Button.new()
	save_btn.text = "💾  Save Map / Refresh Minimap"
	save_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_A, UITheme.GOLD, 2))
	save_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 2))
	save_btn.add_theme_color_override("font_color", UITheme.GOLD)
	save_btn.pressed.connect(_on_save_map)
	vb.add_child(save_btn)

	var bake_btn := Button.new()
	bake_btn.text = "🌊  Bake Terrain Bitmap (server)"
	bake_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	bake_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	bake_btn.add_theme_color_override("font_color", UITheme.TEXT)
	bake_btn.tooltip_text = ("Bake the 300×300 passability bitmap from "
		+ "Ground.biome_at_world and upload it. Server uses it to block "
		+ "monster movement into water/coast tiles. Run once whenever "
		+ "biome generation changes. Owner-only.")
	bake_btn.pressed.connect(_on_bake_terrain)
	vb.add_child(bake_btn)

	var hint := Label.new()
	hint.add_theme_color_override("font_color", UITheme.DIM)
	hint.add_theme_font_size_override("font_size", 11)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(240, 0)
	hint.text = "Tile mode: drag to paint. Chat: /gold <name> <amt>, /spawn <type> <lvl>"
	vb.add_child(hint)
	return vb

## Builds the Tiles tab — swatch grid picker grouped by category, tile-edit
## mode row (Tile / Flood / Tint / Passability), brush size, tint sliders,
## and a collapsible "How to edit tiles" help panel. Everything reads the
## same NetworkManager RPCs the old World tab controls used; the only new
## piece is `_selected_biome` replacing the old `_biome_opt.selected` lookup.
func _build_tiles_section() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)

	# ── Mode row — Tile / Flood / Tint / Passability. ──
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 4)
	vb.add_child(mode_row)
	mode_row.add_child(_mode_button("Tile", Mode.TILE))
	mode_row.add_child(_mode_button("Flood", Mode.FLOOD))
	mode_row.add_child(_mode_button("Tint", Mode.TINT))
	mode_row.add_child(_mode_button("Pass", Mode.PASSABILITY))

	# ── Biome swatch grid, category-grouped. ──
	var swatch_lbl := Label.new()
	swatch_lbl.text = "Biome (click a swatch to select):"
	swatch_lbl.add_theme_color_override("font_color", UITheme.DIM)
	swatch_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(swatch_lbl)

	var ground := get_tree().get_first_node_in_group("ground")
	for cat: Array in _TILE_CATEGORIES:
		var cat_name: String = str(cat[0])
		var biomes: Array = cat[1] as Array
		# Category header row.
		var header := Label.new()
		header.text = cat_name
		header.add_theme_color_override("font_color", UITheme.GOLD)
		header.add_theme_font_size_override("font_size", 11)
		vb.add_child(header)
		# Grid of Buttons — one row per category, 8 swatches per row.
		var grid := GridContainer.new()
		grid.columns = 8
		grid.add_theme_constant_override("h_separation", 3)
		grid.add_theme_constant_override("v_separation", 3)
		vb.add_child(grid)
		for biome_name in biomes:
			var name_str: String = str(biome_name)
			var b := _make_swatch_button(name_str, cat_name, ground)
			b.pressed.connect(func() -> void: _on_swatch_picked(name_str))
			grid.add_child(b)
			_swatch_buttons[name_str] = b
	# If the atlas isn't ready yet (rare — bake takes ~2 frames), listen
	# for atlas_ready and swap the color-chip swatches for real tile
	# thumbnails when it fires.
	if ground != null and ground.has_signal("atlas_ready"):
		var already_ready: bool = bool(ground.get("_atlas_ready"))
		if not already_ready:
			ground.atlas_ready.connect(_refresh_swatches_with_atlas, CONNECT_ONE_SHOT)

	# ── Erase button — dedicated row below the grid. ──
	var erase_row := HBoxContainer.new()
	erase_row.add_theme_constant_override("separation", 4)
	vb.add_child(erase_row)
	var erase_btn := Button.new()
	erase_btn.text = "🧹  Erase (clears paint)"
	erase_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	erase_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	erase_btn.pressed.connect(func() -> void: _on_swatch_picked("(erase)"))
	erase_row.add_child(erase_btn)

	# ── Brush size — reused from the old World-tab widget. ──
	var brush_lbl := Label.new()
	brush_lbl.text = "Brush:"
	brush_lbl.add_theme_color_override("font_color", UITheme.DIM)
	brush_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(brush_lbl)
	_brush_size_opt = OptionButton.new()
	for s: int in BRUSH_SIZES:
		_brush_size_opt.add_item("%d×%d" % [s, s])
	_brush_size_opt.add_item("Flood fill")
	_brush_size_opt.item_selected.connect(_on_brush_size_selected)
	vb.add_child(_brush_size_opt)

	# ── Tint editor — live numeric readouts + preview swatch + reset. ──
	# The old sliders were bare and mysteriously "did nothing" because there
	# was no feedback: user moved a slider, saw no readout, saw no preview,
	# then clicked a tile and couldn't tell whether the effect landed.
	# Now: sliders show `Hue: +0` / `Bright: +0` labels that update live;
	# a small swatch to the right previews what a mid-grey tile would look
	# like with the current tint. Click a tile in Tint mode to apply.
	var tint_lbl := Label.new()
	tint_lbl.text = "Tile tint (Tint mode — click to apply):"
	tint_lbl.add_theme_color_override("font_color", UITheme.DIM)
	tint_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(tint_lbl)
	# Hue row.
	var hue_row := HBoxContainer.new()
	hue_row.add_theme_constant_override("separation", 6)
	vb.add_child(hue_row)
	_tint_h_label = Label.new()
	_tint_h_label.text = "Hue: +0"
	_tint_h_label.add_theme_font_size_override("font_size", 11)
	_tint_h_label.custom_minimum_size = Vector2(66, 0)
	hue_row.add_child(_tint_h_label)
	_tint_h_slider = _make_tint_slider("Hue ±  (cool ← 0 → warm)")
	_tint_h_slider.value_changed.connect(_on_tint_h_changed)
	hue_row.add_child(_tint_h_slider)
	# Brightness row.
	var br_row := HBoxContainer.new()
	br_row.add_theme_constant_override("separation", 6)
	vb.add_child(br_row)
	_tint_v_label = Label.new()
	_tint_v_label.text = "Bright: +0"
	_tint_v_label.add_theme_font_size_override("font_size", 11)
	_tint_v_label.custom_minimum_size = Vector2(66, 0)
	br_row.add_child(_tint_v_label)
	_tint_v_slider = _make_tint_slider("Bright ±  (dark ← 0 → light)")
	_tint_v_slider.value_changed.connect(_on_tint_v_changed)
	br_row.add_child(_tint_v_slider)
	# Preview swatch + reset. Shows the tint math applied to a mid-grey
	# reference tile so the admin knows what to expect BEFORE clicking.
	var preview_row := HBoxContainer.new()
	preview_row.add_theme_constant_override("separation", 6)
	vb.add_child(preview_row)
	var pv_lbl := Label.new()
	pv_lbl.text = "Preview:"
	pv_lbl.add_theme_color_override("font_color", UITheme.DIM)
	pv_lbl.add_theme_font_size_override("font_size", 11)
	preview_row.add_child(pv_lbl)
	_tint_preview = ColorRect.new()
	_tint_preview.custom_minimum_size = Vector2(28, 20)
	_tint_preview.color = Color(0.5, 0.5, 0.5)
	preview_row.add_child(_tint_preview)
	var reset_btn := Button.new()
	reset_btn.text = "Reset tint"
	reset_btn.tooltip_text = "Set sliders back to (0, 0) — click on a tile after to CLEAR its tint."
	reset_btn.pressed.connect(_on_tint_reset)
	preview_row.add_child(reset_btn)

	# ── Collapsible How-To. ──
	_help_toggle_btn = Button.new()
	_help_toggle_btn.text = "▸ How to edit tiles"
	_help_toggle_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	_help_toggle_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	_help_toggle_btn.pressed.connect(_on_help_toggle)
	vb.add_child(_help_toggle_btn)
	_help_body = VBoxContainer.new()
	_help_body.add_theme_constant_override("separation", 3)
	_help_body.visible = false   # collapsed by default
	vb.add_child(_help_body)
	for line: String in [
			"Tile — click/drag to paint the selected biome.",
			"Flood — single click floods all connected tiles of the same biome.",
			"Tint — paints hue/brightness shifts (see sliders) onto tiles.",
			"Pass — toggles walkability of a tile (impassable = blocked).",
			"Brush — 1/3/5/7 = odd-side square stamp centered on the cursor.",
			"Walls (wall_wood/wall_stone) auto-block; no need to toggle Pass.",
		]:
		var l := Label.new()
		l.text = "• " + line
		l.add_theme_color_override("font_color", UITheme.DIM)
		l.add_theme_font_size_override("font_size", 11)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(240, 0)
		_help_body.add_child(l)

	# Highlight the initial selection.
	_apply_swatch_highlight(_selected_biome)
	return vb

func _on_swatch_picked(name_str: String) -> void:
	_selected_biome = name_str
	_apply_swatch_highlight(name_str)


## Builds one swatch Button. Prefers the real baked atlas thumbnail when
## available (`Ground.get_biome_thumbnail`) — the button carries a child
## TextureRect showing the actual tile art. Falls back to a flat color
## chip via _biome_base_color if the atlas hasn't finished baking yet;
## _refresh_swatches_with_atlas() swaps the fallbacks for thumbnails
## when the atlas_ready signal fires.
func _make_swatch_button(name_str: String, cat_name: String,
		ground: Node) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(28, 28)
	b.tooltip_text = "%s\n(%s)" % [name_str, cat_name]
	_populate_swatch_visual(b, name_str, ground)
	return b


## Applies either the atlas thumbnail (as a child TextureRect) or the
## flat-color stylebox to a swatch. Extracted so the fallback swap
## on atlas_ready can reuse the same code path.
func _populate_swatch_visual(b: Button, name_str: String, ground: Node) -> void:
	# Try the real thumbnail first.
	var thumb: Texture2D = null
	if ground != null and ground.has_method("get_biome_thumbnail"):
		var v: Variant = ground.call("get_biome_thumbnail", name_str)
		if v is Texture2D:
			thumb = v
	if thumb != null:
		# Clear any color stylebox from the fallback path.
		b.remove_theme_stylebox_override("normal")
		b.remove_theme_stylebox_override("hover")
		b.remove_theme_stylebox_override("pressed")
		# Remove old thumbnail child if we're re-populating.
		for child in b.get_children():
			if child is TextureRect:
				child.queue_free()
		var trect := TextureRect.new()
		trect.texture = thumb
		trect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		trect.stretch_mode = TextureRect.STRETCH_SCALE
		trect.custom_minimum_size = Vector2(28, 28)
		trect.set_anchors_preset(Control.PRESET_FULL_RECT)
		trect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(trect)
		return
	# Fallback: flat color chip.
	var col := Color(0.5, 0.5, 0.5)
	if ground != null and ground.has_method("_biome_base_color"):
		var bv: Variant = ground.call("_biome_base_color", name_str)
		if typeof(bv) == TYPE_COLOR:
			col = bv
	b.add_theme_stylebox_override("normal", UITheme.sb(col, UITheme.BORDER, 1))
	b.add_theme_stylebox_override("hover",  UITheme.sb(col.lightened(0.15), UITheme.GOLD, 2))
	b.add_theme_stylebox_override("pressed",UITheme.sb(col.darkened(0.10), UITheme.GOLD, 2))


## Called once via CONNECT_ONE_SHOT when Ground's atlas bake completes.
## Walks the swatch registry and swaps every flat-color chip for its real
## baked-atlas thumbnail. Selected highlight is reapplied after so the
## gold border still shows on the currently picked biome.
func _refresh_swatches_with_atlas() -> void:
	var ground := get_tree().get_first_node_in_group("ground")
	if ground == null:
		return
	for name_v in _swatch_buttons.keys():
		var name_str: String = str(name_v)
		var b: Button = _swatch_buttons[name_v]
		if b == null or not is_instance_valid(b):
			continue
		_populate_swatch_visual(b, name_str, ground)
	_apply_swatch_highlight(_selected_biome)

## Redraws the swatch borders so the currently-picked biome stands out.
## Non-selected swatches revert to a thin BORDER-color outline; the selected
## one gets a gold 2-px border.
func _apply_swatch_highlight(pick: String) -> void:
	for name_v in _swatch_buttons.keys():
		var name_str: String = str(name_v)
		var b: Button = _swatch_buttons[name_v]
		if b == null:
			continue
		var col := Color(0.5, 0.5, 0.5)
		var ground := get_tree().get_first_node_in_group("ground")
		if ground != null and ground.has_method("_biome_base_color"):
			var v: Variant = ground.call("_biome_base_color", name_str)
			if typeof(v) == TYPE_COLOR:
				col = v
		var border_col: Color = UITheme.GOLD if name_str == pick else UITheme.BORDER
		var border_w: int = 2 if name_str == pick else 1
		b.add_theme_stylebox_override("normal", UITheme.sb(col, border_col, border_w))

func _on_help_toggle() -> void:
	if _help_body == null or _help_toggle_btn == null:
		return
	_help_body.visible = not _help_body.visible
	_help_toggle_btn.text = ("▾ How to edit tiles" if _help_body.visible
			else "▸ How to edit tiles")


func _on_tint_h_changed(v: float) -> void:
	if _tint_h_label != null:
		var iv: int = int(v)
		_tint_h_label.text = "Hue: %+d" % iv
	_refresh_tint_preview()

func _on_tint_v_changed(v: float) -> void:
	if _tint_v_label != null:
		var iv: int = int(v)
		_tint_v_label.text = "Bright: %+d" % iv
	_refresh_tint_preview()

func _on_tint_reset() -> void:
	if _tint_h_slider != null: _tint_h_slider.value = 0
	if _tint_v_slider != null: _tint_v_slider.value = 0
	# value_changed callbacks refresh the labels + preview.

## Mirrors the shader's tint math (terrain_blend.gdshader:315-333) on a
## mid-grey reference color so the preview matches what an actual tile
## painted with the current sliders will end up looking like.
func _refresh_tint_preview() -> void:
	if _tint_preview == null:
		return
	var h: int = int(_tint_h_slider.value) if _tint_h_slider != null else 0
	var v: int = int(_tint_v_slider.value) if _tint_v_slider != null else 0
	var warm: float = (float(h) / 100.0) * 0.2
	var bright: float = (float(v) / 100.0) * 0.2
	var col := Color(0.5, 0.5, 0.5)
	col.r = clampf(col.r * (1.0 + warm * 0.30), 0.0, 1.0)
	col.g = clampf(col.g * (1.0 + warm * 0.05), 0.0, 1.0)
	col.b = clampf(col.b * (1.0 - warm * 0.30), 0.0, 1.0)
	col.r = clampf(col.r * (1.0 + bright), 0.0, 1.0)
	col.g = clampf(col.g * (1.0 + bright), 0.0, 1.0)
	col.b = clampf(col.b * (1.0 + bright), 0.0, 1.0)
	_tint_preview.color = col

## Builds the Structures tab — categorized picker for all 18 Construction
## buildables + wood/metal tier selectors. Click STRUCTURE mode button →
## click in the world to place. Reuses the existing admin_place plumbing
## from AdminCatalog walls (kind="resource" + type_str=<kind>).
func _build_structures_section() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)

	# ── Mode row — only STRUCTURE + OFF here. ──
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 4)
	vb.add_child(mode_row)
	mode_row.add_child(_mode_button("Structure", Mode.STRUCTURE))
	mode_row.add_child(_mode_button("Off", Mode.OFF))

	# ── Kind picker: categorized OptionButton. ──
	var kind_lbl := Label.new()
	kind_lbl.text = "Structure:"
	kind_lbl.add_theme_color_override("font_color", UITheme.DIM)
	kind_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(kind_lbl)
	_structure_kind_opt = OptionButton.new()
	_structure_kind_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Populate as flat list with category markers. First entry per category
	# is the category header (disabled), then the buildables underneath.
	var opt_idx: int = 0
	for cat: Array in _STRUCTURE_CATEGORIES:
		var cat_name: String = str(cat[0])
		# Disabled header entry (visual only).
		_structure_kind_opt.add_item("── %s ──" % cat_name)
		_structure_kind_opt.set_item_disabled(opt_idx, true)
		opt_idx += 1
		for kind_v in cat[1]:
			var kind_str: String = str(kind_v)
			var label: String = str(_STRUCTURE_LABELS.get(kind_str, kind_str))
			_structure_kind_opt.add_item(label)
			_structure_kind_opt.set_item_metadata(opt_idx, kind_str)
			opt_idx += 1
	_structure_kind_opt.item_selected.connect(_on_structure_kind_picked)
	vb.add_child(_structure_kind_opt)
	# Skip the first disabled header on init so the picker starts on a real
	# buildable (the "wall" entry).
	if _structure_kind_opt.item_count > 1:
		_structure_kind_opt.select(1)
		_on_structure_kind_picked(1)

	# ── Wood tier picker. ──
	var wood_lbl := Label.new()
	wood_lbl.text = "Wood tier:"
	wood_lbl.add_theme_color_override("font_color", UITheme.DIM)
	wood_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(wood_lbl)
	_structure_wood_opt = OptionButton.new()
	for wt: Array in _WOOD_TIERS:
		_structure_wood_opt.add_item(str(wt[1]))
	_structure_wood_opt.item_selected.connect(_on_wood_tier_picked)
	vb.add_child(_structure_wood_opt)

	# ── Metal (bar) tier picker — only visible for bar-consuming kinds. ──
	_structure_bar_row = HBoxContainer.new()
	_structure_bar_row.add_theme_constant_override("separation", 4)
	vb.add_child(_structure_bar_row)
	var bar_lbl := Label.new()
	bar_lbl.text = "Metal:"
	bar_lbl.add_theme_color_override("font_color", UITheme.DIM)
	bar_lbl.add_theme_font_size_override("font_size", 11)
	_structure_bar_row.add_child(bar_lbl)
	_structure_bar_opt = OptionButton.new()
	for bt: Array in _BAR_TIERS:
		_structure_bar_opt.add_item(str(bt[1]))
	_structure_bar_opt.item_selected.connect(_on_bar_tier_picked)
	_structure_bar_row.add_child(_structure_bar_opt)
	# Visibility updates whenever the kind changes (see _on_structure_kind_picked).
	_structure_bar_row.visible = false

	var hint := Label.new()
	hint.text = "STRUCTURE mode + click in world → place. Persists server-side."
	hint.add_theme_color_override("font_color", UITheme.DIM)
	hint.add_theme_font_size_override("font_size", 11)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(240, 0)
	vb.add_child(hint)
	return vb


func _on_structure_kind_picked(idx: int) -> void:
	if _structure_kind_opt == null:
		return
	var meta: Variant = _structure_kind_opt.get_item_metadata(idx)
	if meta == null:
		return
	var kind_str: String = str(meta)
	_selected_structure_kind = kind_str
	# Show or hide the bar-tier picker based on whether this kind consumes bars.
	if _structure_bar_row != null:
		_structure_bar_row.visible = bool(_STRUCTURE_USES_BAR.get(kind_str, false))

func _on_wood_tier_picked(idx: int) -> void:
	if idx < 0 or idx >= _WOOD_TIERS.size():
		return
	_selected_wood_tier = str((_WOOD_TIERS[idx] as Array)[0])

func _on_bar_tier_picked(idx: int) -> void:
	if idx < 0 or idx >= _BAR_TIERS.size():
		return
	_selected_bar_tier = str((_BAR_TIERS[idx] as Array)[0])


## Called by _on_overlay_input when in Mode.STRUCTURE and the admin
## left-clicks in the world. Composes the entity data dict and sends
## admin_place with kind="resource" (walls' existing pattern).
func _place_structure_at(wpos: Vector2) -> void:
	# Look up the wood color for the picked tier — used as the entity's
	# `color` for downstream Interactable draws.
	var wood_color := Color(0.55, 0.36, 0.18)
	for wt: Array in _WOOD_TIERS:
		if str(wt[0]) == _selected_wood_tier:
			wood_color = wt[2] as Color
			break
	var label: String = str(_STRUCTURE_LABELS.get(_selected_structure_kind,
			_selected_structure_kind))
	var data := {
		"type_str":     _selected_structure_kind,
		"display_name": "%s %s" % [_selected_wood_tier.capitalize(), label],
		"skill":        "construction",
		"level":        1,
		"action":       "Inspect",
		"color":        [wood_color.r, wood_color.g, wood_color.b, wood_color.a],
		"wood":         _selected_wood_tier,
	}
	if bool(_STRUCTURE_USES_BAR.get(_selected_structure_kind, false)):
		data["bar"] = _selected_bar_tier
	NetworkManager.send_admin_place("resource", _selected_structure_kind,
		wpos.x, wpos.y, data)


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
	if _world_section != null:      _world_section.visible      = which == "world"
	if _tiles_section != null:      _tiles_section.visible      = which == "tiles"
	if _structures_section != null: _structures_section.visible = which == "structures"
	if _items_section != null:      _items_section.visible      = which == "items"
	if _accounts_section != null:   _accounts_section.visible   = which == "accounts"
	_paint_tab(_tab_world_btn,      which == "world")
	_paint_tab(_tab_tiles_btn,      which == "tiles")
	_paint_tab(_tab_structures_btn, which == "structures")
	_paint_tab(_tab_items_btn,      which == "items")
	_paint_tab(_tab_accounts_btn,   which == "accounts")
	# Lazy first-fetches per tab so the admin doesn't have to hit a manual
	# refresh after opening it.
	if which == "items" and _items_player_opt != null \
			and _items_player_opt.item_count <= 1:
		_on_refresh_players()
	if which == "accounts" and _accounts_list_root != null \
			and _accounts_list_root.get_child_count() == 0:
		NetworkManager.send_admin_list_accounts("")

func _paint_tab(btn: Button, active: bool) -> void:
	if btn == null:
		return
	btn.add_theme_stylebox_override("normal",
		UITheme.sb(UITheme.BTN_A if active else UITheme.BTN_N,
			UITheme.GOLD if active else UITheme.BORDER, 2))

# ── Accounts tab ────────────────────────────────────────────────────────────
## Search-driven account list. Each row shows username, email + verified
## status, last-login timestamp, lockout indicator, with three actions:
## Reset (mail a token), Unlock, Verify-email. All routes are gated by
## _is_admin on the server side; the client just sends.
func _build_accounts_section() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)

	# Search row.
	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 4)
	vb.add_child(search_row)
	_accounts_search = LineEdit.new()
	_accounts_search.placeholder_text = "search username or email"
	_accounts_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_accounts_search.add_theme_stylebox_override("normal",
		UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	_accounts_search.add_theme_color_override("font_color", UITheme.TEXT)
	_accounts_search.add_theme_font_size_override("font_size", 11)
	_accounts_search.text_submitted.connect(func(_t: String) -> void:
		NetworkManager.send_admin_list_accounts(_accounts_search.text))
	search_row.add_child(_accounts_search)
	var go_btn := Button.new()
	go_btn.text = "Go"
	go_btn.custom_minimum_size = Vector2(40, 0)
	go_btn.add_theme_stylebox_override("normal",
		UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	go_btn.add_theme_color_override("font_color", UITheme.TEXT)
	go_btn.add_theme_font_size_override("font_size", 11)
	go_btn.pressed.connect(func() -> void:
		NetworkManager.send_admin_list_accounts(_accounts_search.text))
	search_row.add_child(go_btn)

	# Scrollable list.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 280)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_accounts_list_root = VBoxContainer.new()
	_accounts_list_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_accounts_list_root.add_theme_constant_override("separation", 3)
	scroll.add_child(_accounts_list_root)

	return vb

func _on_account_list_received(accounts: Array) -> void:
	if _accounts_list_root == null:
		return
	for c: Node in _accounts_list_root.get_children():
		c.queue_free()
	if accounts.is_empty():
		var none := Label.new()
		none.text = "(no accounts match)"
		none.add_theme_color_override("font_color", UITheme.DIM)
		none.add_theme_font_size_override("font_size", 10)
		_accounts_list_root.add_child(none)
		return
	for entry: Variant in accounts:
		if not (entry is Dictionary):
			continue
		_accounts_list_root.add_child(_build_account_row(entry as Dictionary))

func _build_account_row(a: Dictionary) -> PanelContainer:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel",
		UITheme.sb(UITheme.BG.lightened(0.04), UITheme.BORDER.darkened(0.4), 1))
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 2)
	row.add_child(inner)

	var username := str(a.get("username", "?"))

	# Header: username + lock badge
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	inner.add_child(head)
	var name_lbl := Label.new()
	name_lbl.text = username
	name_lbl.add_theme_color_override("font_color", UITheme.GOLD)
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_lbl)
	var locked_until := float(a.get("locked_until", 0.0))
	if locked_until > Time.get_unix_time_from_system():
		var lock_lbl := Label.new()
		lock_lbl.text = "LOCKED"
		lock_lbl.add_theme_color_override("font_color", Color(0.95, 0.40, 0.30))
		lock_lbl.add_theme_font_size_override("font_size", 10)
		head.add_child(lock_lbl)

	# Email row
	var email := str(a.get("email", ""))
	var verified := bool(a.get("email_verified", false))
	var email_lbl := Label.new()
	if email.is_empty():
		email_lbl.text = "(no email)"
		email_lbl.add_theme_color_override("font_color", UITheme.DIM)
	else:
		email_lbl.text = "%s%s" % [email, "  ✓" if verified else ""]
		email_lbl.add_theme_color_override("font_color",
			UITheme.TEXT if verified else UITheme.DIM)
	email_lbl.add_theme_font_size_override("font_size", 10)
	inner.add_child(email_lbl)

	# Last login + failed-count line
	var ll := Label.new()
	var ll_ts := float(a.get("last_login_at", 0.0))
	var ll_text := "never"
	if ll_ts > 0.0:
		var dt := Time.get_datetime_dict_from_unix_time(int(ll_ts))
		ll_text = "%04d-%02d-%02d %02d:%02d" % [
			dt.year, dt.month, dt.day, dt.hour, dt.minute]
	var fails := int(a.get("failed_login_count", 0))
	ll.text = "last login: %s   fails: %d" % [ll_text, fails]
	ll.add_theme_color_override("font_color", UITheme.DIM)
	ll.add_theme_font_size_override("font_size", 9)
	inner.add_child(ll)

	# Action buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	inner.add_child(btn_row)
	var reset_btn := _account_action_btn("Reset PW")
	reset_btn.pressed.connect(func() -> void:
		NetworkManager.send_admin_reset_password(username))
	btn_row.add_child(reset_btn)
	var unlock_btn := _account_action_btn("Unlock")
	unlock_btn.pressed.connect(func() -> void:
		NetworkManager.send_admin_unlock_account(username)
		# Refresh after a short delay so the lock badge updates.
		get_tree().create_timer(0.3).timeout.connect(func() -> void:
			NetworkManager.send_admin_list_accounts(_accounts_search.text)))
	btn_row.add_child(unlock_btn)
	var verify_btn := _account_action_btn("Verify ✓")
	verify_btn.pressed.connect(func() -> void:
		NetworkManager.send_admin_verify_email(username)
		get_tree().create_timer(0.3).timeout.connect(func() -> void:
			NetworkManager.send_admin_list_accounts(_accounts_search.text)))
	btn_row.add_child(verify_btn)

	return row

func _account_action_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Touch-target — was 22 px tall. 32 px is comfortable for a thumb.
	b.custom_minimum_size = Vector2(0, 32)
	b.add_theme_stylebox_override("normal",
		UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	b.add_theme_stylebox_override("hover",
		UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	b.add_theme_color_override("font_color", UITheme.TEXT)
	b.add_theme_font_size_override("font_size", 11)
	return b

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

## Bake the server-side passability bitmap from Ground.biome_at_world and
## upload it. Server gates monster movement against the bitmap, blocking
## chase paths across water/coast. Owner-only — server rejects non-owner.
func _on_bake_terrain() -> void:
	var ground := get_tree().get_first_node_in_group("ground")
	if ground == null:
		Events.chat_message.emit("[Terrain] Ground node not found.")
		return
	Events.chat_message.emit("[Terrain] Baking 300×300 bitmap…")
	var baker_script := load("res://scripts/TerrainBaker.gd")
	var payload: String = baker_script.bake(ground) as String
	if payload.is_empty():
		Events.chat_message.emit("[Terrain] Bake failed.")
		return
	NetworkManager.send_admin_upload_terrain(payload)
	Events.chat_message.emit("[Terrain] Uploaded %d chars to server." % payload.length())
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
	_update_brush_preview()
	# Tell World to show/hide the red impassable overlay — only visible
	# while the admin is in PASSABILITY edit mode.
	var w := _world()
	if w != null and w.has_method("set_passability_overlay_visible"):
		w.call("set_passability_overlay_visible", mode == Mode.PASSABILITY)

func _update_mode_label() -> void:
	if _mode_lbl == null:
		return
	match _mode:
		Mode.PLACE:        _mode_lbl.text = "Mode: PLACE — click map"
		Mode.DELETE:       _mode_lbl.text = "Mode: DELETE — click entity"
		Mode.MOVE:         _mode_lbl.text = "Mode: MOVE — drag entity"
		Mode.TILE:         _mode_lbl.text = "Mode: TILE — drag to paint"
		Mode.STRUCTURE:    _mode_lbl.text = "Mode: STRUCTURE — click to place"
		Mode.TINT:         _mode_lbl.text = "Mode: TINT — drag to color"
		Mode.PASSABILITY:  _mode_lbl.text = "Mode: PASS — drag to block / unblock"
		_:                 _mode_lbl.text = "Mode: off"

func _toggle_panel() -> void:
	var show_now := not _panel.visible
	_panel.visible   = show_now
	_overlay.visible = show_now
	if not show_now:
		_set_mode(Mode.OFF)
		if _brush_preview != null and is_instance_valid(_brush_preview):
			_brush_preview.visible = false

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
			Mode.TILE, Mode.TINT, Mode.PASSABILITY:
				_painting = mb.pressed
				if mb.pressed:
					_last_tile = Vector2i(-9999, -9999)
					_paint_at(wpos)
			Mode.STRUCTURE:
				if mb.pressed: _place_structure_at(wpos)
		_overlay.accept_event()
	elif event is InputEventMouseMotion:
		var wpos := _screen_to_world((event as InputEventMouseMotion).position)
		_last_mouse_world = wpos
		if _mode == Mode.MOVE and _drag_id != "":
			_drag_pos = wpos
		elif _mode in [Mode.TILE, Mode.TINT, Mode.PASSABILITY] and _painting:
			_paint_at(wpos)
		_update_brush_preview()

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

# ── Brush + tint + passability UI helpers ──────────────────────────────────
func _on_brush_size_selected(idx: int) -> void:
	# Last entry is the special "Flood fill" pseudo-size; the BRUSH_SIZES
	# array carries the real sizes 1/3/5/7.
	if idx >= 0 and idx < BRUSH_SIZES.size():
		_brush_size = int(BRUSH_SIZES[idx])
		_flood_mode = false
	else:
		_brush_size = 1
		_flood_mode = true
	_update_brush_preview()

func _make_tint_slider(label_text: String) -> HSlider:
	# Slider rides ±100; 0 = no shift, ±100 = ±20% (the shader maps it).
	# Label-on-the-side gets baked into the HBox so we don't smuggle
	# Tools-into-a-Slider — return the HBox masquerading as HSlider via
	# size_flags. Simpler: just an HSlider, mouseover tooltip carries the
	# label text since the brush+tint section already has its own header.
	var s := HSlider.new()
	s.min_value = -100
	s.max_value =  100
	s.step      =    1
	s.value     =    0
	s.custom_minimum_size = Vector2(0, 18)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.tooltip_text = label_text + "  (-100 cool / cooler  →  +100 warm / brighter)"
	return s

## Build the translucent preview rect that follows the cursor. Lives on the
## overlay so its coordinate space matches what _on_overlay_input uses.
func _ensure_brush_preview() -> void:
	if _brush_preview != null and is_instance_valid(_brush_preview):
		return
	if _overlay == null:
		return
	_brush_preview = ColorRect.new()
	_brush_preview.color = Color(0.95, 0.78, 0.18, 0.20)
	_brush_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_brush_preview.visible = false
	# Pinned at the top of the overlay so it draws above the world but below
	# any future on-overlay UI.
	_overlay.add_child(_brush_preview)

func _update_brush_preview() -> void:
	_ensure_brush_preview()
	if _brush_preview == null:
		return
	# Structure mode — show the pending structure's actual footprint under
	# the cursor. Green when placement is valid; red when it would overlap
	# an existing structure (client-side hint; server still enforces).
	if _mode == Mode.STRUCTURE:
		_update_structure_preview()
		return
	var painting_mode := _mode in [Mode.TILE, Mode.TINT, Mode.PASSABILITY]
	if not painting_mode or _brush_size <= 1 or _flood_mode:
		_brush_preview.visible = false
		return
	# Convert _last_mouse_world to the tile origin, then back to screen.
	var t := Vector2i(int(floor(_last_mouse_world.x / TILE)),
		int(floor(_last_mouse_world.y / TILE)))
	@warning_ignore("integer_division") var half := _brush_size / 2
	var origin_world := Vector2(float(t.x - half) * TILE, float(t.y - half) * TILE)
	var px_size := float(_brush_size) * TILE
	# overlay is anchored full-rect at the screen, so we paint in screen px.
	var xform := get_viewport().get_canvas_transform()
	var screen_pos := xform * origin_world
	var screen_size := Vector2(px_size, px_size) * xform.get_scale()
	# Pick a color hint per mode so the preview reads at a glance.
	match _mode:
		Mode.TINT:
			_brush_preview.color = Color(0.40, 0.65, 0.95, 0.25)
		Mode.PASSABILITY:
			_brush_preview.color = Color(0.95, 0.20, 0.20, 0.30)
		_:
			_brush_preview.color = Color(0.95, 0.78, 0.18, 0.22)
	_brush_preview.position = screen_pos
	_brush_preview.size = screen_size
	_brush_preview.visible = true


## Draws a footprint-sized rect at the cursor for STRUCTURE mode. Green
## when placement is valid, red when it would overlap another structure.
## Client-side check only — server enforces authoritatively — but this
## gives instant feedback so the admin doesn't spam-click into rejections.
func _update_structure_preview() -> void:
	if _brush_preview == null:
		return
	var size := _structure_size_for_kind(_selected_structure_kind)
	if size == Vector2.ZERO:
		_brush_preview.visible = false
		return
	# Convert cursor world pos → footprint origin (top-left corner).
	var origin_world: Vector2 = _last_mouse_world - size * 0.5
	var xform := get_viewport().get_canvas_transform()
	var screen_pos := xform * origin_world
	var screen_size := size * xform.get_scale()
	# Overlap check — walk the world's admin_registry (if reachable) and
	# AABB against each existing structure.
	var overlap := _placement_would_overlap_client(size, _last_mouse_world)
	_brush_preview.color = (Color(0.95, 0.25, 0.25, 0.35)
			if overlap else Color(0.30, 0.85, 0.35, 0.30))
	_brush_preview.position = screen_pos
	_brush_preview.size = screen_size
	_brush_preview.visible = true


## Look up the structure size table on the World-scoped Interactable
## script. Falls back to Vector2(32, 32) for unknown kinds.
func _structure_size_for_kind(kind: String) -> Vector2:
	# Match server-side _STRUCTURE_SIZES exactly (walls small, stations
	# medium, towers/houses large).
	match kind:
		"wall", "fortified_wall", "fence", "gate":
			return Vector2(32, 32)
		"workbench", "smith_station", "bank_chest", "armory_rack", \
		"well", "altar", "market_stall", "site_marker", "plant_bed", \
		"portal_shrine":
			return Vector2(64, 64)
		"watchtower", "guard_tower", "house_frame", "large_house", \
		"grand_hall", "clan_hall", "dock":
			return Vector2(128, 128)
	return Vector2.ZERO


## Client-side AABB pre-check. Walks every Interactable in the world's
## "interactable" group whose type is a structure and tests footprint
## intersection against the pending placement. Not authoritative — the
## server re-checks and rejects on any race.
func _placement_would_overlap_client(new_size: Vector2, wpos: Vector2) -> bool:
	var new_min := wpos - new_size * 0.5
	var new_max := wpos + new_size * 0.5
	for node in get_tree().get_nodes_in_group("interactable"):
		if not is_instance_valid(node):
			continue
		var n := node as Node2D
		if n == null:
			continue
		var kind := str(n.get("interactable_type_str"))
		var other_size := _structure_size_for_kind(kind)
		if other_size == Vector2.ZERO:
			continue
		var other_pos: Vector2 = n.global_position
		var other_min := other_pos - other_size * 0.5
		var other_max := other_pos + other_size * 0.5
		if (new_min.x < other_max.x and new_max.x > other_min.x
				and new_min.y < other_max.y and new_max.y > other_min.y):
			return true
	return false


## Compute the brush footprint as an Array of Vector2i tile coordinates,
## centered on `t`. Out-of-bounds tiles are clipped.
func _brush_footprint(t: Vector2i) -> Array:
	var out: Array = []
	@warning_ignore("integer_division") var half := _brush_size / 2
	for dy in range(-half, half + 1):
		for dx in range(-half, half + 1):
			var tx := t.x + dx
			var ty := t.y + dy
			if tx < 0 or ty < 0 or tx >= 300 or ty >= 300:
				continue
			out.append(Vector2i(tx, ty))
	return out

func _tiles_array_for_wire(coords: Array) -> Array:
	# Build a network-friendly list of {tx, ty} dicts.
	var out: Array = []
	for c: Variant in coords:
		var v: Vector2i = c
		out.append({"tx": v.x, "ty": v.y})
	return out

func _paint_at(wpos: Vector2) -> void:
	var t := Vector2i(int(floor(wpos.x / TILE)), int(floor(wpos.y / TILE)))
	if t == _last_tile:
		return
	_last_tile = t

	# ── Passability mode ──
	if _mode == Mode.PASSABILITY:
		var coords := _brush_footprint(t)
		if coords.is_empty():
			return
		# Toggle based on the centre tile's CURRENT state so a single click
		# either blocks or unblocks the brush footprint as a group.
		var g := get_tree().get_first_node_in_group("ground")
		var was_blocked := false
		if g != null and g.has_method("is_tile_impassable"):
			was_blocked = bool(g.call("is_tile_impassable", t.x, t.y))
		var new_passable := was_blocked   # if it was blocked, make passable
		NetworkManager.send_admin_tile_passability(
			_tiles_array_for_wire(coords), new_passable)
		return

	# ── Tint mode ──
	if _mode == Mode.TINT:
		var coords2 := _brush_footprint(t)
		if coords2.is_empty():
			return
		var h := int(_tint_h_slider.value) if _tint_h_slider != null else 0
		var v := int(_tint_v_slider.value) if _tint_v_slider != null else 0
		NetworkManager.send_admin_tile_tint(
			_tiles_array_for_wire(coords2), h, v)
		return

	# ── Tile (biome) paint ──
	# Reads the swatch grid's current selection (Tiles tab). The old
	# `_biome_opt` OptionButton was retired when the tab was split.
	var biome := _selected_biome
	# Flood fill is a single-seed action regardless of brush size.
	if _flood_mode:
		if biome == "(erase)":
			# Treat flood-erase as flood-paint with the procedural-baseline
			# biome at the click — server doesn't know procedural, so we
			# just send "plains" as a safe fallback. Or admin can run the
			# Bake Terrain Bitmap afterward to refresh.
			NetworkManager.send_admin_tile_clear(t.x, t.y)
			return
		NetworkManager.send_admin_tile_flood_fill(t.x, t.y, biome)
		return

	# 1×1 brush — fast path: keep the existing single-tile message so we
	# don't pay the bulk overhead for the most common case.
	if _brush_size <= 1:
		if biome == "(erase)":
			NetworkManager.send_admin_tile_clear(t.x, t.y)
		else:
			NetworkManager.send_admin_tile_set(t.x, t.y, biome)
		return

	# N×N brush — build the footprint and send one bulk message.
	var coords3 := _brush_footprint(t)
	if coords3.is_empty():
		return
	var bulk: Array = []
	var biome_or_null: Variant
	if biome == "(erase)":
		biome_or_null = null
	else:
		biome_or_null = biome
	for c: Variant in coords3:
		var v: Vector2i = c
		bulk.append({"tx": v.x, "ty": v.y, "biome": biome_or_null})
	NetworkManager.send_admin_tile_set_bulk(bulk)
