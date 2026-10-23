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
const ShopCat = preload("res://scripts/ShopCatalog.gd")
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
	# ── Expansion #4 (44 biomes) ─────────────────────────────────────
	# Grass-family intra-biome variants.
	"plains_wildflower", "plains_dry",
	"oak_dense", "oak_autumn",
	"dark_root_tangle", "dark_mushroom_ring",
	"swamp_deep_mud",
	# Water variants.
	"ocean_kelp", "ocean_deep",
	# Farming.
	"wheat_field", "tilled_soil", "pasture", "vineyard", "orchard",
	# Ruins / damage.
	"rubble", "broken_wall", "cracked_earth", "scorched_earth",
	"cemetery", "ancient_ruins",
	# Volcanic / fire.
	"lava_flow", "basalt", "ash_dune", "geothermal_vent", "obsidian_shard",
	# Vegetation variety.
	"tall_grass", "reeds", "lily_pads", "dead_grass", "burnt_grass",
	"birch_forest", "bamboo_stand",
	# Norse cultural.
	"rune_stone_ground", "grave_mound", "longhouse_floor",
	"fire_pit_indoor", "fur_rug",
	# Remaining intra-biome variants.
	"pine_snow_dust", "pine_needle_bed", "swamp_bubbling",
	"mountain_alpine", "mountain_granite",
	"snow_pristine", "snow_tracks",
	"(erase)",
]

# Category-ordered swatch layout for the Tiles tab. Each entry: category
# header string + the biome names to place under it in the swatch grid.
# Kept as a nested Array so a designer can reorder without touching the
# picker logic. Tiles tab renders one Label row per category then a
# GridContainer with one Button per biome.
const _TILE_CATEGORIES: Array = [
	["Grass",       ["plains", "plains_wildflower", "plains_dry",
					 "meadow", "tundra", "clearing",
					 "tall_grass", "dead_grass", "burnt_grass"]],
	["Forest",      ["oak_forest", "oak_dense", "oak_autumn",
					 "pine_forest", "pine_snow_dust", "pine_needle_bed",
					 "dark_forest", "dark_root_tangle", "dark_mushroom_ring",
					 "birch_forest", "bamboo_stand"]],
	["Wetlands",    ["swamp", "swamp_deep_mud", "swamp_bubbling",
					 "reeds", "lily_pads", "farm_crops"]],
	["Rock/Mtn",    ["mountain", "mountain_alpine", "mountain_granite",
					 "rocky", "cliff",
					 "basalt", "obsidian_shard"]],
	["Water",       ["coast", "ocean", "ocean_kelp", "ocean_deep",
					 "shallow_water", "reef", "tidepool"]],
	["Path/Town",   ["town", "road", "dirt_path"]],
	["Snow/Fire",   ["snow", "snow_pristine", "snow_tracks",
					 "helheim", "ashlands",
					 "lava_flow", "ash_dune", "geothermal_vent"]],
	["Beach",       ["sand", "wet_sand", "driftwood_shore"]],
	["Hills",       ["plains_hills", "oak_hills", "pine_hills", "snow_hills",
					 "ashlands_hills", "helheim_hills", "rocky_hills", "sand_hills"]],
	["Transitions", ["forest_edge", "swamp_edge", "shore_grass", "snow_line", "cliff_scree"]],
	["Variety",     ["moss_rock", "volcanic_glass"]],
	["Farming",     ["wheat_field", "tilled_soil", "pasture", "vineyard", "orchard"]],
	["Ruins",       ["rubble", "broken_wall", "cracked_earth", "scorched_earth",
					 "cemetery", "ancient_ruins"]],
	["Norse",       ["rune_stone_ground", "grave_mound", "longhouse_floor",
					 "fire_pit_indoor"]],
	["Bridges",     ["wood_bridge", "stone_bridge"]],
	["Interior",    ["wood_floor", "stone_floor", "red_carpet", "hearth_stone",
					 "wall_wood", "wall_stone", "fur_rug"]],
]

enum Mode { OFF, PLACE, DELETE, MOVE, ROTATE, TILE, FLOOD, TINT, PASSABILITY, STRUCTURE, SCULPT_RAISE, SCULPT_LOWER,
	ROAD_ADD, ROAD_MOVE, ROAD_LINK, ROAD_DELETE, INSPECT }

## Roads tab — how close (world px) a click must be to a node to hit it.
const ROAD_HIT_RADIUS := 40.0

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

## Category tabs above the Place-Entity dropdown. Same pattern the recipe
## window uses: "All" always exists and lists every entry; a specific tab
## narrows the dropdown to only entries whose `_entity_category_for()`
## returns that tab name. Categories in the order they render.
const _ENTITY_TAB_NAMES: Array = [
	"All", "Trees", "Rocks", "Fishing", "Foraging",
	"Stations", "Walls", "Doors", "Monsters", "NPCs",
]

var _mode: int = Mode.OFF
var _entries: Array = []
## Active entity category tab. Rebuilds the OptionButton's items on change.
var _active_entity_tab: String = "All"
## Tab buttons keyed by name so radio-toggling doesn't need to walk children.
var _entity_tab_btns: Dictionary = {}

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
# Height tab — raise/lower terrain sculpt (3D client only; inert in 2D).
var _tab_height_btn: Button        = null
var _height_section: VBoxContainer = null
# Roads tab — admin-drawn road/path network (dots + edges) the bot travels.
var _tab_roads_btn: Button        = null
var _roads_section: VBoxContainer = null
var _roads_status_lbl: Label      = null
## The node the editor currently has selected (-1 = none). ROAD_ADD chains new
## nodes off it; ROAD_LINK toggles an edge between two picked nodes.
var _road_selected: int = -1
## Node being dragged in ROAD_MOVE (-1 = none).
var _road_drag: int = -1
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
## Persistent expand/collapse state for the Tiles-tab category groups.
## Keys are category names; values are bool "expanded". Missing key =
## collapsed. Defaults seeded in _build_tiles_section — Grass/Forest/
## Water/Hills expanded by default; everything else collapsed.
var _tile_categories_expanded: Dictionary = {}
## Category header buttons keyed by category name — so a category
## rebuild (e.g. after atlas_ready) can refresh the arrow glyph without
## walking children.
var _tile_category_headers: Dictionary = {}
## Category swatch grids keyed by category name — used to toggle
## visibility on header click.
var _tile_category_grids: Dictionary = {}
var _help_body: VBoxContainer = null
var _help_toggle_btn: Button = null
# Tint editor widgets — numeric readouts + preview swatch.
var _tint_h_label: Label = null
var _tint_v_label: Label = null
var _tint_preview: ColorRect = null
# Accounts tab state
var _accounts_search: LineEdit    = null
var _accounts_list_root: VBoxContainer = null
## Season-reset field checkboxes (owner-only). field key → CheckBox.
var _reset_checks: Dictionary = {}
## Resettable player fields — [key, label]. Server maps each to a wipe.
const _SEASON_RESET_FIELDS: Array = [
	["skill_xp", "Levels (all skills)"], ["inventory", "Backpack"],
	["bank", "Bank items"], ["equipment", "Equipment"],
	["gold", "Gold"], ["bank_gold", "Bank gold"], ["pvp_tokens", "PvP tokens"],
	["position", "Position → spawn"], ["recipe_counts", "Recipe practice"],
	["discovered_towns", "Map discovery"], ["quests", "Quest progress"],
	["reputation", "Reputation"], ["thralls", "Thralls"],
]

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

# ── Undo stack ───────────────────────────────────────────────────────────────
## LIFO of reverse-ops for entity edits (place/delete/move/rotate/edit). Each
## entry is a Dictionary {"op": String, ...}. Tile paints are NOT tracked (yet).
var _undo_stack: Array = []
const _UNDO_MAX := 40
## True while replaying an undo, so the reverse-op's own echoes don't push new
## entries (e.g. undo-delete re-places → we must not record that as undoable).
var _undoing: bool = false
## Count of admin_placed echoes to ignore when pushing a place→delete undo entry
## (an undo-delete triggers a place whose echo must NOT become a new undo step).
var _suppress_placed_undo: int = 0
var _undo_btn: Button = null
## World-px of the entity when a Move drag started (source for the move undo).
var _drag_old_pos: Vector2 = Vector2.ZERO

## SEPARATE undo for tile PAINTING (biome only). Each entry is one paint stroke =
## an Array of {tx, ty, prior} (prior "" means the tile had no override → re-clear
## to undo). Flood / tint / passability are NOT tracked. Its own button so a bad
## paint drag never disturbs the entity-edit undo above.
var _tile_undo_stack: Array = []
const _TILE_UNDO_MAX := 25
## Tiles touched in the current in-progress paint drag (committed on mouse-up).
var _tile_stroke: Array = []
## "tx,ty" → true for tiles already captured this stroke, so a re-touched tile
## keeps its ORIGINAL prior biome (not the freshly-painted one).
var _tile_stroke_seen: Dictionary = {}
var _tile_undo_btn: Button = null

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
	Events.admin_entity_placed.connect(_on_admin_entity_placed)

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
	# Restricted mapper role — sees only World (entity placement) + Tiles
	# (paint/save/bake). Structures / Items / Accounts stay full-admin-only.
	# `is_full_admin()` returns false for the mapper rank; owner + admin
	# both pass and see every tab.
	var full_admin: bool = GameManager.is_full_admin()
	_tab_world_btn      = _tab_button("World", true)
	_tab_tiles_btn      = _tab_button("Tiles", false)
	_tab_height_btn     = _tab_button("Height", false)
	_tab_roads_btn      = _tab_button("Roads", false)
	_tab_structures_btn = _tab_button("Structures", false)
	_tab_items_btn      = _tab_button("Items", false)
	_tab_accounts_btn   = _tab_button("Accounts", false)
	_tab_world_btn.pressed.connect(func() -> void: _show_tab("world"))
	_tab_tiles_btn.pressed.connect(func() -> void: _show_tab("tiles"))
	_tab_height_btn.pressed.connect(func() -> void: _show_tab("height"))
	_tab_roads_btn.pressed.connect(func() -> void: _show_tab("roads"))
	_tab_structures_btn.pressed.connect(func() -> void: _show_tab("structures"))
	_tab_items_btn.pressed.connect(func() -> void: _show_tab("items"))
	_tab_accounts_btn.pressed.connect(func() -> void: _show_tab("accounts"))
	tab_row.add_child(_tab_world_btn)
	tab_row.add_child(_tab_tiles_btn)
	tab_row.add_child(_tab_height_btn)
	tab_row.add_child(_tab_roads_btn)   # map-editing tool — mappers get it too
	if full_admin:
		tab_row.add_child(_tab_structures_btn)
		tab_row.add_child(_tab_items_btn)
		tab_row.add_child(_tab_accounts_btn)

	_world_section      = _build_world_section()
	_tiles_section      = _build_tiles_section()
	_height_section     = _build_height_section()
	_roads_section      = _build_roads_section()
	_structures_section = _build_structures_section()
	_items_section      = _build_items_section()
	_accounts_section   = _build_accounts_section()
	vb.add_child(_world_section)
	vb.add_child(_tiles_section)
	vb.add_child(_height_section)
	vb.add_child(_roads_section)
	_height_section.visible = false
	_roads_section.visible = false
	# Full-admin-only sections still get built (so the tab buttons above
	# have targets if a rank changes mid-session) but stay invisible and
	# uninstantiated in the tab row when the local player is only a mapper.
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
	row.add_child(_mode_button("Rotate", Mode.ROTATE))
	# Inspect — click a placed entity to edit its properties live (v1.6.x).
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	vb.add_child(row2)
	row2.add_child(_mode_button("Inspect / Edit", Mode.INSPECT))
	row2.add_child(_mode_button("Off",    Mode.OFF))

	# Undo — reverses the last place/delete/move/rotate/edit (Ctrl+Z too).
	_undo_btn = Button.new()
	_undo_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 2))
	_undo_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 2))
	_undo_btn.add_theme_color_override("font_color", UITheme.TEXT)
	_undo_btn.tooltip_text = "Reverse the last entity edit (place / delete / move / rotate / property change). Ctrl+Z."
	_undo_btn.pressed.connect(_do_undo)
	vb.add_child(_undo_btn)
	_refresh_undo_btn()

	# Browser — searchable list of loaded entities; jump to or edit any of them.
	var browse_btn := Button.new()
	browse_btn.text = "🔍  Find / Browse entities"
	browse_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	browse_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	browse_btn.add_theme_color_override("font_color", UITheme.TEXT)
	browse_btn.pressed.connect(_open_entity_browser)
	vb.add_child(browse_btn)

	# Validator — scans loaded entities for broken references (bad shop, door to
	# nowhere, out-of-bounds, blank names) and lists them with jump-to.
	var validate_btn := Button.new()
	validate_btn.text = "🩺  Validate world"
	validate_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	validate_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	validate_btn.add_theme_color_override("font_color", UITheme.TEXT)
	validate_btn.pressed.connect(_open_validator)
	vb.add_child(validate_btn)

	var el := Label.new()
	el.text = "Entity:"
	el.add_theme_color_override("font_color", UITheme.DIM)
	el.add_theme_font_size_override("font_size", 11)
	vb.add_child(el)
	# Category tab row. Small buttons above the entity dropdown that filter
	# which _entries appear inside it. Same pattern as the Tiles + Crafting
	# tabs; Place/Delete/Move behavior + the Level SpinBox are untouched.
	_entity_tab_btns = {}
	var tab_wrap := VBoxContainer.new()
	tab_wrap.add_theme_constant_override("separation", 3)
	vb.add_child(tab_wrap)
	var tab_row_a := HBoxContainer.new()
	tab_row_a.add_theme_constant_override("separation", 3)
	tab_wrap.add_child(tab_row_a)
	var tab_row_b := HBoxContainer.new()
	tab_row_b.add_theme_constant_override("separation", 3)
	tab_wrap.add_child(tab_row_b)
	# Compute per-tab counts once so tab labels can show "(N)" without
	# rebuilding the dropdown each time.
	var counts: Dictionary = {}
	for tab_name: String in _ENTITY_TAB_NAMES:
		counts[tab_name] = 0
	counts["All"] = _entries.size()
	for entry_v: Variant in _entries:
		var cat: String = _entity_category_for(entry_v as Dictionary)
		if counts.has(cat):
			counts[cat] = int(counts[cat]) + 1
	# Split tabs across two rows so the panel stays narrow (5 per row).
	for i: int in range(_ENTITY_TAB_NAMES.size()):
		var tab: String = _ENTITY_TAB_NAMES[i]
		var b := Button.new()
		b.text = "%s (%d)" % [tab, int(counts[tab])]
		b.add_theme_font_size_override("font_size", 10)
		b.toggle_mode = true
		b.button_pressed = (tab == _active_entity_tab)
		# Radio-style: on press, deactivate other tabs and refilter.
		b.pressed.connect(func() -> void:
			_active_entity_tab = tab
			for other_v in _entity_tab_btns.keys():
				var other: String = other_v
				(_entity_tab_btns[other] as Button).button_pressed = (other == tab)
			_populate_entity_dropdown())
		if i < 5:
			tab_row_a.add_child(b)
		else:
			tab_row_b.add_child(b)
		_entity_tab_btns[tab] = b
	_type_opt = OptionButton.new()
	_populate_entity_dropdown()
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
	# item_selected signal already wired inside _populate_entity_dropdown.
	# Seed the initial visibility + level for whatever id the dropdown is
	# starting on (first entry of the currently active tab).
	if _type_opt.selected >= 0:
		# Pass the visual index — _on_entity_picked resolves to the entry id.
		_on_entity_picked(_type_opt.selected)

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

	# v1.7 B2a — bake the node→drop map so the server grants gather loot itself.
	var bake_nodes_btn := Button.new()
	bake_nodes_btn.text = "⛏  Bake: nodes + loot + recipes + fish"
	bake_nodes_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	bake_nodes_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	bake_nodes_btn.add_theme_color_override("font_color", UITheme.TEXT)
	bake_nodes_btn.tooltip_text = ("Snapshot every gatherable node's drop, every monster's loot, "
		+ "and every craft recipe, then upload them. The server then grants gather loot, rolls kill "
		+ "loot, and crafts items authoritatively (anti-cheat). Re-run whenever drops/loot/recipes "
		+ "change. Owner-only.")
	bake_nodes_btn.pressed.connect(_on_bake_nodes)
	vb.add_child(bake_nodes_btn)

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

	# ── Biome swatch grid — categorized, collapsible, and inside a
	# ScrollContainer so a 90+ biome catalog doesn't push the tint editor
	# off-screen. Grass / Forest / Water / Hills expand by default; the
	# rest collapse so a fresh open of the panel is compact. ──
	var swatch_lbl := Label.new()
	swatch_lbl.text = "Biome (click a swatch to select):"
	swatch_lbl.add_theme_color_override("font_color", UITheme.DIM)
	swatch_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(swatch_lbl)

	# Seed the default expand state on first build.
	if _tile_categories_expanded.is_empty():
		for tc: Array in _TILE_CATEGORIES:
			var tc_name: String = str(tc[0])
			_tile_categories_expanded[tc_name] = tc_name in \
					["Grass", "Forest", "Water", "Hills"]

	var swatch_scroll := ScrollContainer.new()
	swatch_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	swatch_scroll.custom_minimum_size = Vector2(0, 260)
	swatch_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Cap the vertical growth so mode row + tint editor stay above the
	# fold. If the panel gains vertical space, the scroll can grow into it.
	swatch_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(swatch_scroll)
	var swatch_inner := VBoxContainer.new()
	swatch_inner.add_theme_constant_override("separation", 4)
	swatch_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	swatch_scroll.add_child(swatch_inner)

	var ground := get_tree().get_first_node_in_group("ground")
	for cat: Array in _TILE_CATEGORIES:
		var cat_name: String = str(cat[0])
		var biomes: Array = cat[1] as Array
		var is_expanded: bool = bool(_tile_categories_expanded.get(cat_name, false))
		# Category header — clickable toggle. Arrow glyph reflects state.
		var header := Button.new()
		header.text = "%s  %s  (%d)" % [
			("▾" if is_expanded else "▸"), cat_name, biomes.size()]
		header.add_theme_color_override("font_color", UITheme.GOLD)
		header.add_theme_font_size_override("font_size", 11)
		header.alignment = HORIZONTAL_ALIGNMENT_LEFT
		header.flat = true
		swatch_inner.add_child(header)
		_tile_category_headers[cat_name] = header
		# Grid of Buttons — 8 swatches per row.
		var grid := GridContainer.new()
		grid.columns = 8
		grid.add_theme_constant_override("h_separation", 3)
		grid.add_theme_constant_override("v_separation", 3)
		grid.visible = is_expanded
		swatch_inner.add_child(grid)
		_tile_category_grids[cat_name] = grid
		for biome_name in biomes:
			var name_str: String = str(biome_name)
			var b := _make_swatch_button(name_str, cat_name, ground)
			b.pressed.connect(func() -> void: _on_swatch_picked(name_str))
			grid.add_child(b)
			_swatch_buttons[name_str] = b
		# Wire header toggle after the grid exists so the lambda captures
		# both. Bind cat_name so all headers share the same handler shape.
		header.pressed.connect(func() -> void:
			_toggle_tile_category(cat_name))
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
	# Tile paint's OWN undo (biome strokes only) — kept separate from the World
	# tab's entity undo so the two never step on each other.
	_tile_undo_btn = Button.new()
	_tile_undo_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	_tile_undo_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	_tile_undo_btn.tooltip_text = "Undo the last biome paint stroke (flood / tint / passability aren't tracked)."
	_tile_undo_btn.pressed.connect(_do_tile_undo)
	erase_row.add_child(_tile_undo_btn)
	_refresh_tile_undo_btn()

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


## Flip the expand/collapse state for one Tiles-tab category. Rewrites the
## header's arrow glyph + toggles the grid's visibility. State persists on
## the panel so the same categories stay open across panel opens.
func _toggle_tile_category(cat_name: String) -> void:
	var is_expanded: bool = bool(_tile_categories_expanded.get(cat_name, false))
	is_expanded = not is_expanded
	_tile_categories_expanded[cat_name] = is_expanded
	var grid: Node = _tile_category_grids.get(cat_name, null)
	if grid != null and grid is Control:
		(grid as Control).visible = is_expanded
	var header: Node = _tile_category_headers.get(cat_name, null)
	if header != null and header is Button:
		# Find the biome count from _TILE_CATEGORIES so the label stays
		# consistent with the seed at build time.
		var count: int = 0
		for cat: Array in _TILE_CATEGORIES:
			if str(cat[0]) == cat_name:
				count = (cat[1] as Array).size()
				break
		(header as Button).text = "%s  %s  (%d)" % [
			("▾" if is_expanded else "▸"), cat_name, count]


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

## Builds the Height tab — raise/lower terrain sculpt. Only meaningful in the 3D
## client (World3D.sculpt_at); in the 2D client the mode is inert (no height).
## Uses the Tiles-tab brush size. Drag with LMB to sculpt.
func _build_height_section() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 4)
	mode_row.add_child(_mode_button("Raise",  Mode.SCULPT_RAISE))
	mode_row.add_child(_mode_button("Lower",  Mode.SCULPT_LOWER))
	mode_row.add_child(_mode_button("Off",    Mode.OFF))
	vb.add_child(mode_row)
	var hint := Label.new()
	hint.text = "Pick Raise or Lower, then LMB-drag the ground to sculpt. Brush = the Tiles-tab brush size. Edits blend into the biome base and save automatically (3D client only)."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(240, 0)
	hint.add_theme_color_override("font_color", UITheme.DIM)
	hint.add_theme_font_size_override("font_size", 11)
	vb.add_child(hint)
	return vb

## Builds the Roads tab — an in-world editor for the admin-drawn road/path
## network the autoplay bot follows. Modes:
##   Add    — click empty ground to drop a node; if a node is selected it also
##            links selected→new + selects the new one (so successive clicks
##            draw a connected line). Click ON a node instead just selects it.
##   Move   — drag a node to reposition it.
##   Link   — click node A then node B to toggle the road between them.
##   Delete — click a node to remove it (and every road touching it).
## The graph draws as gold thick lines + amber dots over the world; every edit
## pushes the whole doc to the server (persisted + synced to all clients).
func _build_roads_section() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 4)
	vb.add_child(mode_row)
	mode_row.add_child(_mode_button("Add",    Mode.ROAD_ADD))
	mode_row.add_child(_mode_button("Move",   Mode.ROAD_MOVE))
	mode_row.add_child(_mode_button("Link",   Mode.ROAD_LINK))
	mode_row.add_child(_mode_button("Delete", Mode.ROAD_DELETE))
	mode_row.add_child(_mode_button("Off",    Mode.OFF))

	_roads_status_lbl = Label.new()
	_roads_status_lbl.add_theme_color_override("font_color", UITheme.GOLD)
	_roads_status_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(_roads_status_lbl)

	var deselect_btn := Button.new()
	deselect_btn.text = "Deselect node"
	deselect_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 1))
	deselect_btn.add_theme_stylebox_override("hover",  UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 1))
	deselect_btn.pressed.connect(func() -> void: _road_select(-1))
	vb.add_child(deselect_btn)

	var hint := Label.new()
	hint.text = ("Add: click ground to drop a dot; with a dot selected each new "
		+ "click links to it (draws a line). Click a dot to select it. "
		+ "Move: drag a dot. Link: click two dots to join/split. Delete: click a "
		+ "dot to remove it. Saved server-side; the auto-player follows these roads.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(240, 0)
	hint.add_theme_color_override("font_color", UITheme.DIM)
	hint.add_theme_font_size_override("font_size", 11)
	vb.add_child(hint)

	_update_roads_status()
	return vb

## Refreshes the Roads-tab status line (node/edge count + current selection).
func _update_roads_status() -> void:
	if _roads_status_lbl == null:
		return
	var sel_txt := ("none" if _road_selected < 0 else ("#%d" % _road_selected))
	_roads_status_lbl.text = "Nodes: %d   Roads: %d   Selected: %s" % [
		GameManager.road_nodes.size(), GameManager.road_edges.size(), sel_txt]

## Set the selected node + mirror it to the world overlay's gold ring.
func _road_select(node_id: int) -> void:
	_road_selected = node_id
	var w := _world()
	if w != null and w.has_method("set_road_selected_node"):
		w.call("set_road_selected_node", node_id)
	_update_roads_status()

## Node id nearest to a world position within ROAD_HIT_RADIUS, else -1.
func _road_node_at(wpos: Vector2) -> int:
	var best_id: int = -1
	var best_d: float = ROAD_HIT_RADIUS
	for n: Variant in GameManager.road_nodes:
		var d := n as Dictionary
		var p := Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		var dist := wpos.distance_to(p)
		if dist <= best_d:
			best_d = dist
			best_id = int(d.get("id", -1))
	return best_id

## Persist + broadcast the whole graph, then redraw the overlay. Called after
## every mutation (the graph is small, so a full push each edit is cheap).
func _road_push() -> void:
	NetworkManager.send_admin_road_set(GameManager.road_nodes, GameManager.road_edges)
	var w := _world()
	if w != null and w.has_method("set_road_selected_node"):
		# Force an overlay redraw (selection unchanged) so local edits show
		# instantly, before the server's echo comes back.
		w.call("set_road_selected_node", _road_selected)
	_update_roads_status()

## Add a node at a world position; returns its new id. Optionally link it to the
## currently-selected node so successive Add clicks draw a connected path.
func _road_add_node(wpos: Vector2, link_from_selected: bool) -> int:
	var nid := GameManager.road_next_node_id()
	GameManager.road_nodes.append({"id": nid, "x": wpos.x, "y": wpos.y})
	if link_from_selected and _road_selected >= 0 and _road_selected != nid:
		_road_add_edge(_road_selected, nid)
	return nid

## Toggle the undirected edge a-b (add if absent, remove if present).
func _road_toggle_edge(a: int, b: int) -> void:
	if a == b:
		return
	if not _road_add_edge(a, b):
		_road_remove_edge(a, b)

## Add edge a-b if it isn't already there. Returns true if one was added.
func _road_add_edge(a: int, b: int) -> bool:
	for e: Variant in GameManager.road_edges:
		if not (e is Array) or (e as Array).size() != 2:
			continue
		var x := int((e as Array)[0]); var y := int((e as Array)[1])
		if (x == a and y == b) or (x == b and y == a):
			return false
	GameManager.road_edges.append([a, b])
	return true

func _road_remove_edge(a: int, b: int) -> void:
	for i in range(GameManager.road_edges.size() - 1, -1, -1):
		var e: Variant = GameManager.road_edges[i]
		if not (e is Array) or (e as Array).size() != 2:
			continue
		var x := int((e as Array)[0]); var y := int((e as Array)[1])
		if (x == a and y == b) or (x == b and y == a):
			GameManager.road_edges.remove_at(i)

## Remove a node + every road touching it.
func _road_delete_node(nid: int) -> void:
	for i in range(GameManager.road_nodes.size() - 1, -1, -1):
		if int((GameManager.road_nodes[i] as Dictionary).get("id", -1)) == nid:
			GameManager.road_nodes.remove_at(i)
	for i in range(GameManager.road_edges.size() - 1, -1, -1):
		var e: Variant = GameManager.road_edges[i]
		if not (e is Array) or (e as Array).size() != 2:
			continue
		if int((e as Array)[0]) == nid or int((e as Array)[1]) == nid:
			GameManager.road_edges.remove_at(i)

func _road_move_node(nid: int, wpos: Vector2) -> void:
	for n: Variant in GameManager.road_nodes:
		var d := n as Dictionary
		if int(d.get("id", -1)) == nid:
			d["x"] = wpos.x
			d["y"] = wpos.y
			return

# ── Roads-tab click handlers ────────────────────────────────────────────────
## ROAD_ADD: clicking an existing dot just selects it; clicking empty ground
## drops a new dot (linked to the selected one, if any) and selects it — so
## successive clicks paint a connected line.
func _road_click_add(wpos: Vector2) -> void:
	var hit := _road_node_at(wpos)
	if hit >= 0:
		_road_select(hit)
		return
	var nid := _road_add_node(wpos, true)
	_road_select(nid)
	_road_push()

## ROAD_LINK: first click selects a dot; second click on a different dot toggles
## the road between them (kept selected so you can chain links).
func _road_click_link(wpos: Vector2) -> void:
	var hit := _road_node_at(wpos)
	if hit < 0:
		return
	if _road_selected < 0 or _road_selected == hit:
		_road_select(hit)
		return
	_road_toggle_edge(_road_selected, hit)
	_road_select(hit)
	_road_push()

## ROAD_DELETE: click a dot to remove it and every road touching it.
func _road_click_delete(wpos: Vector2) -> void:
	var hit := _road_node_at(wpos)
	if hit < 0:
		return
	_road_delete_node(hit)
	if _road_selected == hit:
		_road_select(-1)
	_road_push()

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
	if _height_section != null:     _height_section.visible     = which == "height"
	if _roads_section != null:      _roads_section.visible      = which == "roads"
	if _structures_section != null: _structures_section.visible = which == "structures"
	if _items_section != null:      _items_section.visible      = which == "items"
	if _accounts_section != null:   _accounts_section.visible   = which == "accounts"
	_paint_tab(_tab_world_btn,      which == "world")
	_paint_tab(_tab_tiles_btn,      which == "tiles")
	_paint_tab(_tab_height_btn,     which == "height")
	_paint_tab(_tab_roads_btn,      which == "roads")
	_paint_tab(_tab_structures_btn, which == "structures")
	_paint_tab(_tab_items_btn,      which == "items")
	_paint_tab(_tab_accounts_btn,   which == "accounts")
	# Show the road overlay only while the Roads tab is open; leaving it hides
	# the dev lines and drops any active road edit mode.
	var w := _world()
	if w != null and w.has_method("set_road_overlay_visible"):
		w.call("set_road_overlay_visible", which == "roads")
	if which != "roads" and _mode in [Mode.ROAD_ADD, Mode.ROAD_MOVE,
			Mode.ROAD_LINK, Mode.ROAD_DELETE]:
		_set_mode(Mode.OFF)
	if which == "roads":
		_update_roads_status()
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
## Owner-only "seasonal reset" — checkboxes (preset ALL on) for which player
## fields to wipe across every account. Destructive → type-to-confirm. The server
## backs the DB up + kicks everyone. Great for major updates / season resets, and
## it's the clean-slate that lets B3 (server inventory) flip without item risk.
func _build_season_reset() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UITheme.sb(Color(0.10, 0.03, 0.03, 0.94), Color(0.90, 0.35, 0.30), 2))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "⚠ Season Reset (owner)"
	title.add_theme_color_override("font_color", Color(0.95, 0.55, 0.45))
	title.add_theme_font_size_override("font_size", 11)
	vb.add_child(title)
	# Checkboxes in a 2-wide grid, all preset ON.
	var grid := GridContainer.new()
	grid.columns = 2
	vb.add_child(grid)
	_reset_checks = {}
	for entry: Array in _SEASON_RESET_FIELDS:
		var cb := CheckBox.new()
		cb.text = str(entry[1])
		cb.button_pressed = true          # preset all on; uncheck to preserve
		cb.add_theme_font_size_override("font_size", 10)
		grid.add_child(cb)
		_reset_checks[str(entry[0])] = cb
	var btn := Button.new()
	btn.text = "🔄  Reset Season (ALL players)"
	btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_A, Color(0.90, 0.35, 0.30), 2))
	btn.add_theme_color_override("font_color", Color(0.98, 0.75, 0.70))
	btn.pressed.connect(_on_season_reset_pressed)
	vb.add_child(btn)
	return panel

func _on_season_reset_pressed() -> void:
	var fields: Array = []
	for k_v: Variant in _reset_checks.keys():
		if (_reset_checks[k_v] as CheckBox).button_pressed:
			fields.append(str(k_v))
	if fields.is_empty():
		Events.chat_message.emit("[Reset] Nothing checked.")
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "Season Reset — ALL PLAYERS"
	dlg.dialog_text = ("Wipe %d field(s) on EVERY account:\n  %s\n\nThe server backs up "
		+ "first, then kicks everyone. This cannot be undone in-game.") % [
			fields.size(), ", ".join(fields)]
	dlg.ok_button_text = "Reset the Season"
	dlg.confirmed.connect(func() -> void:
		NetworkManager.send_admin_season_reset(fields)
		Events.chat_message.emit("[Reset] Sent — the server will apply it + kick everyone.")
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	dlg.close_requested.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered(Vector2i(420, 200))

func _build_accounts_section() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)

	# ── Season Reset (owner-only) — collapsible so it doesn't dominate the tab. ──
	if NetworkManager.my_admin_rank == "owner":
		vb.add_child(_build_season_reset())

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
	# Rank chip — owner / admin / mapper / blank. Small colored label to
	# the right of the username so the owner sees at a glance who's
	# already elevated before deciding whether to grant mapper.
	var rank_str := str(a.get("admin_rank", ""))
	if rank_str != "":
		var rank_lbl := Label.new()
		rank_lbl.text = rank_str.to_upper()
		rank_lbl.add_theme_font_size_override("font_size", 9)
		var rank_col: Color = Color(0.55, 0.85, 0.55)
		match rank_str:
			"owner":  rank_col = Color(0.95, 0.40, 0.15)
			"admin":  rank_col = Color(0.95, 0.75, 0.20)
			"mapper": rank_col = Color(0.55, 0.75, 1.00)
		rank_lbl.add_theme_color_override("font_color", rank_col)
		head.add_child(rank_lbl)
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

	# Mapper rank management — owner-only (server enforces). Button label
	# swaps to Revoke when the account already has mapper rank, and the
	# row hides both buttons entirely for owner + admin (mapper is a
	# down-grade path, not lateral).
	var rank_now := str(a.get("admin_rank", ""))
	if rank_now == "":
		var grant_btn := _account_action_btn("Grant Mapper")
		grant_btn.pressed.connect(func() -> void:
			NetworkManager.send_admin_grant_mapper(username)
			get_tree().create_timer(0.3).timeout.connect(func() -> void:
				NetworkManager.send_admin_list_accounts(_accounts_search.text)))
		btn_row.add_child(grant_btn)
	elif rank_now == "mapper":
		var revoke_btn := _account_action_btn("Revoke Mapper")
		revoke_btn.pressed.connect(func() -> void:
			NetworkManager.send_admin_revoke_mapper(username)
			get_tree().create_timer(0.3).timeout.connect(func() -> void:
				NetworkManager.send_admin_list_accounts(_accounts_search.text)))
		btn_row.add_child(revoke_btn)

	# Delete — OWNER ONLY (server also enforces _is_owner), never for the owner
	# account itself. Destructive, so it goes through a type-the-name confirm.
	if NetworkManager.my_admin_rank == "owner" and rank_now != "owner":
		var del_btn := _account_action_btn("Delete")
		del_btn.add_theme_color_override("font_color", Color(0.95, 0.35, 0.30))
		del_btn.pressed.connect(func() -> void: _confirm_delete_account(username))
		btn_row.add_child(del_btn)

	return row

## Destructive account deletion (owner only). A plain confirm — the server
## re-checks _is_owner and refuses the owner/self, so a clear Delete/Cancel is
## enough. (An earlier type-to-confirm LineEdit added straight to the dialog
## laid out badly and left the OK button stuck disabled, so it never sent.)
func _confirm_delete_account(username: String) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete Account"
	dlg.dialog_text = ("Permanently delete \"%s\" and ALL its data?\n"
		+ "This cannot be undone.") % username
	dlg.ok_button_text = "Delete Permanently"
	dlg.confirmed.connect(func() -> void:
		NetworkManager.send_admin_delete_account(username)
		# Re-fetch the list shortly after so the row disappears on success.
		get_tree().create_timer(0.4).timeout.connect(func() -> void:
			NetworkManager.send_admin_list_accounts(_accounts_search.text))
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	# Free the dialog if it's closed with the [X] too, so it doesn't leak.
	dlg.close_requested.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered(Vector2i(380, 150))

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
## v1.7 B2a — bake the node→drop map on the World node + upload it. The server
## then grants gather loot authoritatively. One-time (re-run on generation change).
func _on_bake_nodes() -> void:
	var w := _world() as Object
	if not w.has_method("bake_node_map"):
		Events.chat_message.emit("[Bake] Node bake not available in this client (2D only).")
		return
	Events.chat_message.emit("[Bake] Snapshotting node drops…")
	var node_map: Dictionary = w.call("bake_node_map")
	if node_map.is_empty():
		Events.chat_message.emit("[Bake] No nodes found — is the world loaded?")
		return
	NetworkManager.send_admin_upload_node_map(node_map)
	Events.chat_message.emit("[Bake] Uploaded %d node drops to the server." % node_map.size())
	# B3 — also bake + upload the monster-loot table (server rolls kill loot).
	if w.has_method("bake_monster_loot"):
		var loot_map: Dictionary = w.call("bake_monster_loot")
		if not loot_map.is_empty():
			NetworkManager.send_admin_upload_monster_loot(loot_map)
			Events.chat_message.emit("[Bake] Uploaded monster loot for %d monsters." % [
				loot_map.size() - 1])   # minus the universal _soul entry
	# ⑤ — also bake + upload the craft-recipe table (server crafts from it).
	# Lives on the HUD (recipe consts), so reach it via the "hud" group.
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("bake_recipes"):
		var recipe_map: Dictionary = hud.call("bake_recipes")
		if not recipe_map.is_empty():
			NetworkManager.send_admin_upload_recipes(recipe_map)
			Events.chat_message.emit("[Bake] Uploaded %d craft recipes to the server." % recipe_map.size())
	# ⑥ — also bake + upload the fishing species table (server grants catches).
	if hud != null and hud.has_method("bake_fishing"):
		var fish_map: Dictionary = hud.call("bake_fishing")
		if not fish_map.is_empty():
			NetworkManager.send_admin_upload_fish(fish_map)
			Events.chat_message.emit("[Bake] Uploaded %d fish species to the server." % fish_map.size())
	# ⑥ — also bake + upload the sea-monster loot table (server grants boat-fight wins).
	if hud != null and hud.has_method("bake_sea_loot"):
		var sea_map: Dictionary = hud.call("bake_sea_loot")
		if not sea_map.is_empty():
			NetworkManager.send_admin_upload_sea_loot(sea_map)
			Events.chat_message.emit("[Bake] Uploaded sea loot for %d monsters." % sea_map.size())

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
	_road_drag = -1
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
		Mode.ROTATE:       _mode_lbl.text = "Mode: ROTATE — L-click +45°, R-click -45°"
		Mode.INSPECT:      _mode_lbl.text = "Mode: INSPECT — click an entity to edit"
		Mode.TILE:         _mode_lbl.text = "Mode: TILE — drag to paint"
		Mode.STRUCTURE:    _mode_lbl.text = "Mode: STRUCTURE — click to place"
		Mode.TINT:         _mode_lbl.text = "Mode: TINT — drag to color"
		Mode.PASSABILITY:  _mode_lbl.text = "Mode: PASS — drag to block / unblock"
		Mode.SCULPT_RAISE: _mode_lbl.text = "Mode: RAISE — drag to raise ground"
		Mode.SCULPT_LOWER: _mode_lbl.text = "Mode: LOWER — drag to lower ground"
		Mode.ROAD_ADD:     _mode_lbl.text = "Mode: ROAD ADD — click to drop/link a dot"
		Mode.ROAD_MOVE:    _mode_lbl.text = "Mode: ROAD MOVE — drag a dot"
		Mode.ROAD_LINK:    _mode_lbl.text = "Mode: ROAD LINK — click two dots"
		Mode.ROAD_DELETE:  _mode_lbl.text = "Mode: ROAD DELETE — click a dot"
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
			and not (event as InputEventKey).echo:
		var k := event as InputEventKey
		if k.keycode == KEY_F10:
			_toggle_panel()
			get_viewport().set_input_as_handled()
		elif k.keycode == KEY_Z and k.ctrl_pressed and _panel != null and _panel.visible:
			_do_undo()
			get_viewport().set_input_as_handled()

func _screen_to_world(screen_pos: Vector2) -> Vector2:
	# 3D client (World3D) converts the screen click to a world px via a ground ray;
	# the 2D World has no such method so it falls back to the canvas transform.
	var w := _world()
	if w != null and w.has_method("world_pos_from_screen"):
		return w.call("world_pos_from_screen", screen_pos)
	return get_viewport().get_canvas_transform().affine_inverse() * screen_pos

func _world() -> Node:
	return get_parent()

func _on_overlay_input(event: InputEvent) -> void:
	if _mode == Mode.OFF:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# ROTATE uses BOTH buttons (L = +45°, R = -45°); everything else is L only.
		var rotate_rmb := _mode == Mode.ROTATE and mb.button_index == MOUSE_BUTTON_RIGHT
		if mb.button_index != MOUSE_BUTTON_LEFT and not rotate_rmb:
			return
		var wpos := _screen_to_world(mb.position)
		if mb.pressed and NetworkManager.state != NetworkManager.NetState.LOGGED_IN:
			Events.chat_message.emit("[Admin] Not connected to the server — action ignored.")
		match _mode:
			Mode.PLACE:
				if mb.pressed: _place_at(wpos)
			Mode.DELETE:
				if mb.pressed: _delete_at(wpos)
			Mode.INSPECT:
				if mb.pressed: _inspect_at(wpos)
			Mode.MOVE:
				if mb.pressed:
					_drag_id = str((_world() as Object).call("admin_entity_at", wpos, 44.0))
					if _drag_id != "" and (_world() as Object).has_method("admin_entity_pos"):
						_drag_old_pos = (_world() as Object).call("admin_entity_pos", _drag_id)
				elif _drag_id != "":
					if _drag_id.begins_with("a:"):
						_push_undo({"op": "move", "id": _drag_id,
							"x": _drag_old_pos.x, "y": _drag_old_pos.y})
					NetworkManager.send_admin_move(_drag_id, _drag_pos.x, _drag_pos.y)
					_drag_id = ""
			Mode.ROTATE:
				# Click an entity to rotate it a step; server persists + syncs it.
				if mb.pressed:
					var rid := str((_world() as Object).call("admin_entity_at", wpos, 44.0))
					if rid != "":
						var step := (PI / 4.0) if mb.button_index == MOUSE_BUTTON_LEFT else -(PI / 4.0)
						var cur := 0.0
						if (_world() as Object).has_method("admin_entity_rot"):
							cur = float((_world() as Object).call("admin_entity_rot", rid))
						if rid.begins_with("a:"):
							_push_undo({"op": "rotate", "id": rid, "rot": cur})
						NetworkManager.send_admin_rotate(rid, cur + step)
			Mode.TILE, Mode.TINT, Mode.PASSABILITY:
				_painting = mb.pressed
				if mb.pressed:
					_last_tile = Vector2i(-9999, -9999)
					_tile_stroke = []          # start capturing this stroke
					_tile_stroke_seen = {}
					_paint_at(wpos)
				else:
					_commit_tile_stroke()      # mouse-up → bank the stroke for undo
			Mode.SCULPT_RAISE, Mode.SCULPT_LOWER:
				_painting = mb.pressed
				if mb.pressed:
					_sculpt_at(wpos, _mode == Mode.SCULPT_RAISE)
			Mode.STRUCTURE:
				if mb.pressed: _place_structure_at(wpos)
			Mode.ROAD_ADD:
				if mb.pressed: _road_click_add(wpos)
			Mode.ROAD_LINK:
				if mb.pressed: _road_click_link(wpos)
			Mode.ROAD_DELETE:
				if mb.pressed: _road_click_delete(wpos)
			Mode.ROAD_MOVE:
				if mb.pressed:
					_road_drag = _road_node_at(wpos)
					if _road_drag >= 0:
						_road_select(_road_drag)
				elif _road_drag >= 0:
					_road_move_node(_road_drag, wpos)
					_road_push()      # commit the final position
					_road_drag = -1
		_overlay.accept_event()
	elif event is InputEventMouseMotion:
		var wpos := _screen_to_world((event as InputEventMouseMotion).position)
		_last_mouse_world = wpos
		if _mode == Mode.MOVE and _drag_id != "":
			_drag_pos = wpos
		elif _mode == Mode.ROAD_MOVE and _road_drag >= 0:
			# Live-follow the cursor (local only — the push happens on release).
			_road_move_node(_road_drag, wpos)
			var w := _world()
			if w != null and w.has_method("set_road_selected_node"):
				w.call("set_road_selected_node", _road_selected)
		elif _mode in [Mode.TILE, Mode.TINT, Mode.PASSABILITY] and _painting:
			_paint_at(wpos)
		elif _mode in [Mode.SCULPT_RAISE, Mode.SCULPT_LOWER] and _painting:
			_sculpt_at(wpos, _mode == Mode.SCULPT_RAISE)
		_update_brush_preview()

## Sculpt terrain height at a world px (3D client only; inert in 2D).
func _sculpt_at(wpos: Vector2, raise: bool) -> void:
	var w := _world()
	if w != null and w.has_method("sculpt_at"):
		w.call("sculpt_at", wpos, raise, _brush_size)

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
## Category classifier for the Place-Entity dropdown. Mirrors the Tiles
## tab's tab pattern: reads the entry's `kind` + `data.type_str` and
## returns the tab it belongs under. Any unclassified entry falls into
## "Stations" so the picker never silently drops an entry.
func _entity_category_for(entry: Dictionary) -> String:
	var kind: String = str(entry.get("kind", ""))
	if kind == "monster":
		return "Monsters"
	if kind == "npc":
		return "NPCs"
	# kind == "resource" — split by type_str.
	var data: Dictionary = entry.get("data", {}) as Dictionary
	var t: String = str(data.get("type_str", ""))
	match t:
		"tree":
			return "Trees"
		"rock", "essence":
			return "Rocks"
		"fish":
			return "Fishing"
		"herb", "stick", "stone":
			return "Foraging"
		"wall", "fortified_wall":
			return "Walls"
		"door":
			return "Doors"
		"forge", "fire", "bank", "building", "crafting", "archery", \
		"runestone", "construction", "auction_house":
			return "Stations"
	return "Stations"


## Rebuild _type_opt's items to only include entries whose category matches
## the active tab. Each `add_item` uses the entry's original `_entries`
## index as the item id so `_place_at` + `_on_entity_picked` keep reading
## from `_entries[id]` unchanged. The selection is reset to the first
## matching entry so the Level SpinBox visibility + seed stays coherent.
func _populate_entity_dropdown() -> void:
	if _type_opt == null:
		return
	_type_opt.clear()
	# Track whether we've already wired the selection signal — clear() drops
	# item widgets but not the signal connection.
	if not _type_opt.item_selected.is_connected(_on_entity_picked):
		_type_opt.item_selected.connect(_on_entity_picked)
	var first_id: int = -1
	for i in range(_entries.size()):
		var e: Dictionary = _entries[i]
		if _active_entity_tab != "All" \
				and _entity_category_for(e) != _active_entity_tab:
			continue
		# Kind suffix only shown on the "All" tab so the tab-specific views
		# stay clean — you already picked "Monsters", no need to repeat it.
		var label: String
		if _active_entity_tab == "All":
			label = "%s  (%s)" % [str(e["label"]), str(e["kind"])]
		else:
			label = str(e["label"])
		_type_opt.add_item(label, i)
		if first_id < 0:
			first_id = i
	if first_id >= 0:
		# Find the item index whose id == first_id and select it.
		for k in range(_type_opt.item_count):
			if _type_opt.get_item_id(k) == first_id:
				_type_opt.select(k)
				# Pass the VISUAL index — _on_entity_picked resolves back
				# to the entries id via get_item_id.
				_on_entity_picked(k)
				break


func _on_entity_picked(idx: int) -> void:
	# The OptionButton's `item_selected` signal reports the item's VISUAL
	# index inside the popup, not the id we stashed at add_item time. On
	# filtered tabs (Monsters/NPCs/etc.) the visual index no longer matches
	# the `_entries` position, so we always resolve via `get_item_id` first.
	# Bug before the fix: selecting anything past index 0 on the Monsters
	# tab could land on a chicken (id 0) or a completely different `_entries`
	# row whose kind wasn't "monster", hiding the Level SpinBox.
	if _type_opt == null or _level_row == null:
		return
	if idx < 0 or idx >= _type_opt.item_count:
		return
	var entry_id: int = _type_opt.get_item_id(idx)
	if entry_id < 0 or entry_id >= _entries.size():
		return
	var e: Dictionary = _entries[entry_id]
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
	if id == "":
		return
	# Capture the entity so the delete is undoable (a: entities only — we can
	# re-place them from their cached data; procedural deletes aren't reversible).
	if id.begins_with("a:") and (_world() as Object).has_method("admin_entity_info"):
		var info: Dictionary = (_world() as Object).call("admin_entity_info", id)
		if not info.is_empty():
			_push_undo({"op": "place",
				"kind": str(info.get("kind", "")),
				"subtype": str(info.get("subtype", "")),
				"x": float(info.get("x", 0.0)), "y": float(info.get("y", 0.0)),
				"data": (info.get("data", {}) as Dictionary).duplicate(true)})
	NetworkManager.send_admin_delete(id)

# ── Undo stack ───────────────────────────────────────────────────────────────
## Record a reverse-op unless we're mid-undo. `entry.op` is the operation that
## REVERSES what the admin just did (a place is undone by a delete, etc.).
func _push_undo(entry: Dictionary) -> void:
	if _undoing:
		return
	_undo_stack.append(entry)
	if _undo_stack.size() > _UNDO_MAX:
		_undo_stack.pop_front()
	_refresh_undo_btn()

## Echo of a successful place — records the delete that would reverse it. The
## suppress counter skips the echo produced BY an undo-delete's re-place.
func _on_admin_entity_placed(id: String, _kind: String, _subtype: String,
		_x: float, _y: float) -> void:
	if id.is_empty():
		return
	if _suppress_placed_undo > 0:
		_suppress_placed_undo -= 1
		return
	_push_undo({"op": "delete", "id": id})

## Pop and replay the last reverse-op.
func _do_undo() -> void:
	if _undo_stack.is_empty():
		Events.chat_message.emit("[Admin] Nothing to undo.")
		return
	var entry: Dictionary = _undo_stack.pop_back()
	_undoing = true
	match str(entry.get("op", "")):
		"delete":
			NetworkManager.send_admin_delete(str(entry["id"]))
		"place":
			# Re-placing produces an admin_placed echo we must not re-record.
			_suppress_placed_undo += 1
			NetworkManager.send_admin_place(str(entry["kind"]), str(entry["subtype"]),
				float(entry["x"]), float(entry["y"]), entry.get("data", {}))
		"move":
			NetworkManager.send_admin_move(str(entry["id"]),
				float(entry["x"]), float(entry["y"]))
		"rotate":
			NetworkManager.send_admin_rotate(str(entry["id"]), float(entry["rot"]))
		"edit":
			NetworkManager.send_admin_edit_entity(str(entry["id"]),
				entry.get("patch", {}) as Dictionary)
	_undoing = false
	_refresh_undo_btn()
	Events.chat_message.emit("[Admin] Undid last edit  (%d left)." % _undo_stack.size())

func _refresh_undo_btn() -> void:
	if _undo_btn == null:
		return
	var n := _undo_stack.size()
	_undo_btn.text = "↶  Undo  (%d)" % n
	_undo_btn.disabled = n == 0

# ── Tile-paint undo (separate stack, biome strokes only) ─────────────────────
## Record a tile's pre-paint override biome once per stroke (dedup by coord).
func _capture_tile_prior(tx: int, ty: int) -> void:
	var key := "%d,%d" % [tx, ty]
	if _tile_stroke_seen.has(key):
		return
	_tile_stroke_seen[key] = true
	var prior := ""
	var g := get_tree().get_first_node_in_group("ground")
	if g != null and g.has_method("override_biome_at"):
		prior = str(g.call("override_biome_at", tx, ty))
	_tile_stroke.append({"tx": tx, "ty": ty, "prior": prior})

## Mouse-up on a paint drag — bank the captured stroke onto the tile-undo stack.
func _commit_tile_stroke() -> void:
	if _tile_stroke.is_empty():
		return
	_tile_undo_stack.append(_tile_stroke)
	if _tile_undo_stack.size() > _TILE_UNDO_MAX:
		_tile_undo_stack.pop_front()
	_tile_stroke = []
	_tile_stroke_seen = {}
	_refresh_tile_undo_btn()

## Replay the last stroke's priors — restore each tile to what it was ("" → clear).
func _do_tile_undo() -> void:
	if _tile_undo_stack.is_empty():
		Events.chat_message.emit("[Admin] No tile paint to undo.")
		return
	var stroke: Array = _tile_undo_stack.pop_back()
	for entry_v: Variant in stroke:
		var e: Dictionary = entry_v
		var tx := int(e["tx"]); var ty := int(e["ty"])
		var prior := str(e["prior"])
		if prior == "":
			NetworkManager.send_admin_tile_clear(tx, ty)
		else:
			NetworkManager.send_admin_tile_set(tx, ty, prior)
	_refresh_tile_undo_btn()
	Events.chat_message.emit("[Admin] Undid tile paint  (%d strokes left)." % _tile_undo_stack.size())

func _refresh_tile_undo_btn() -> void:
	if _tile_undo_btn == null:
		return
	var n := _tile_undo_stack.size()
	_tile_undo_btn.text = "↶ Undo paint (%d)" % n
	_tile_undo_btn.disabled = n == 0

# ── Entity browser ───────────────────────────────────────────────────────────
## Searchable list of loaded editable entities. Each row: name → Go (teleport)
## + Edit (Inspect popup). a:-entities can be edited; others can only be jumped to.
func _open_entity_browser() -> void:
	var w := _world() as Object
	if not w.has_method("admin_entity_list"):
		Events.chat_message.emit("[Admin] Browser not available in this client.")
		return

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, UITheme.GOLD, 2))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(360, 460)
	dim.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "🔍  Entity Browser"
	title.add_theme_color_override("font_color", UITheme.GOLD)
	vb.add_child(title)

	var search := LineEdit.new()
	search.placeholder_text = "filter by name…"
	search.add_theme_font_size_override("font_size", 12)
	vb.add_child(search)

	var count_lbl := Label.new()
	count_lbl.add_theme_color_override("font_color", UITheme.DIM)
	count_lbl.add_theme_font_size_override("font_size", 10)
	vb.add_child(count_lbl)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 360)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	var list_root := VBoxContainer.new()
	list_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_root.add_theme_constant_override("separation", 2)
	scroll.add_child(list_root)

	search.text_changed.connect(func(_t: String) -> void:
		_fill_browser(list_root, count_lbl, search.text, dim))
	_fill_browser(list_root, count_lbl, "", dim)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func() -> void: dim.queue_free())
	vb.add_child(close_btn)

## (Re)build the browser rows filtered by `filter`. `dim` is the popup root so a
## Go/Edit action can close it.
func _fill_browser(list_root: VBoxContainer, count_lbl: Label,
		filter: String, dim: Control) -> void:
	for c: Node in list_root.get_children():
		c.queue_free()
	var w := _world() as Object
	var entities: Array = w.call("admin_entity_list") if w.has_method("admin_entity_list") else []
	var needle := filter.strip_edges().to_lower()
	var shown := 0
	for e_v: Variant in entities:
		if not (e_v is Dictionary):
			continue
		var e: Dictionary = e_v
		var nm := str(e.get("name", "?"))
		var id := str(e.get("id", ""))
		if needle != "" and not nm.to_lower().contains(needle):
			continue
		shown += 1
		if shown > 300:   # keep the list bounded
			break
		list_root.add_child(_browser_row(nm, id, e.get("pos", Vector2.ZERO), dim))
	count_lbl.text = "%d shown (of %d loaded)" % [shown, entities.size()]

func _browser_row(nm: String, id: String, pos: Variant, dim: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var editable := id.begins_with("a:")
	var name_lbl := Label.new()
	name_lbl.text = nm
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.add_theme_color_override("font_color",
		UITheme.GOLD if editable else UITheme.TEXT)
	name_lbl.tooltip_text = id
	row.add_child(name_lbl)
	var go_btn := Button.new()
	go_btn.text = "Go"
	go_btn.tooltip_text = "Teleport to this entity."
	go_btn.add_theme_font_size_override("font_size", 10)
	go_btn.pressed.connect(func() -> void:
		var w := _world() as Object
		if w.has_method("admin_teleport") and pos is Vector2:
			w.call("admin_teleport", pos)
		dim.queue_free())
	row.add_child(go_btn)
	var edit_btn := Button.new()
	edit_btn.text = "Edit"
	edit_btn.add_theme_font_size_override("font_size", 10)
	edit_btn.tooltip_text = "Edit properties."
	edit_btn.pressed.connect(func() -> void:
		var w := _world() as Object
		if w.has_method("admin_entity_info"):
			var info: Dictionary = w.call("admin_entity_info", id)
			if not info.is_empty():
				dim.queue_free()
				_open_entity_editor(id, info))
	row.add_child(edit_btn)
	return row

# ── World validator ──────────────────────────────────────────────────────────
## Scan every LOADED editable entity for broken references. Client-side + read-only.
## Returns [{id, name, pos, issue}]. Checks: out-of-bounds, shopkeeper with an
## invalid/empty shop_id, a: door with no interior_id, blank NPC name.
func _run_validation() -> Array:
	var problems: Array = []
	var w := _world() as Object
	var wmax := 300.0 * TILE
	var seen: Dictionary = {}
	for grp: String in ["interactable", "monster"]:
		for n: Node in get_tree().get_nodes_in_group(grp):
			if not (n is Node2D) or not n.has_meta("edit_id"):
				continue
			var id := str(n.get_meta("edit_id"))
			if seen.has(id):
				continue
			seen[id] = true
			var pos: Vector2 = (n as Node2D).global_position
			var nm := _validator_name(n)
			if pos.x < 0.0 or pos.y < 0.0 or pos.x > wmax or pos.y > wmax:
				problems.append({"id": id, "name": nm, "pos": pos, "issue": "outside world bounds"})
			var ntype: Variant = n.get("npc_type")
			if ntype is String and str(ntype) != "":
				var shop_id := str(n.get("shop_id"))
				if str(ntype) == "shopkeeper" or shop_id != "":
					if shop_id == "" or not ShopCat.SHOPS.has(shop_id):
						problems.append({"id": id, "name": nm, "pos": pos,
							"issue": "shopkeeper — invalid shop_id '%s'" % shop_id})
				if str(n.get("npc_name_str")).strip_edges() == "":
					problems.append({"id": id, "name": nm, "pos": pos, "issue": "blank NPC name"})
			# a: door → interior must be set (needs the stored data dict).
			if id.begins_with("a:") and w.has_method("admin_entity_info"):
				var info: Dictionary = w.call("admin_entity_info", id)
				var data: Dictionary = (info.get("data", {}) as Dictionary) \
					if info.get("data") is Dictionary else {}
				if str(data.get("type_str", "")) == "door" \
						and str(data.get("interior_id", "")) == "":
					problems.append({"id": id, "name": nm, "pos": pos, "issue": "door leads nowhere (no interior)"})
	return problems

func _validator_name(n: Node) -> String:
	for prop: String in ["npc_name_str", "display_name"]:
		var v: Variant = n.get(prop)
		if v is String and not (v as String).is_empty():
			return v as String
	var mt: Variant = n.get("monster_type")
	if mt is String and not (mt as String).is_empty():
		return (mt as String).capitalize()
	return str(n.get_meta("edit_id"))

func _open_validator() -> void:
	var problems := _run_validation()

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, UITheme.GOLD, 2))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(380, 440)
	dim.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "🩺  World Validator"
	title.add_theme_color_override("font_color", UITheme.GOLD)
	vb.add_child(title)

	var summary := Label.new()
	summary.add_theme_font_size_override("font_size", 11)
	if problems.is_empty():
		summary.text = "No problems found in loaded entities. ✔"
		summary.add_theme_color_override("font_color", Color(0.55, 0.85, 0.55))
	else:
		summary.text = "%d issue(s) found (loaded entities only):" % problems.size()
		summary.add_theme_color_override("font_color", Color(0.95, 0.65, 0.30))
	vb.add_child(summary)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 340)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	var list_root := VBoxContainer.new()
	list_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_root.add_theme_constant_override("separation", 3)
	scroll.add_child(list_root)
	for p_v: Variant in problems:
		list_root.add_child(_problem_row(p_v as Dictionary, dim))

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func() -> void: dim.queue_free())
	vb.add_child(close_btn)

func _problem_row(p: Dictionary, dim: Control) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	box.add_child(top)
	var nm_lbl := Label.new()
	nm_lbl.text = str(p.get("name", "?"))
	nm_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm_lbl.add_theme_font_size_override("font_size", 11)
	nm_lbl.add_theme_color_override("font_color", UITheme.GOLD)
	top.add_child(nm_lbl)
	var id := str(p.get("id", ""))
	var pos: Variant = p.get("pos", Vector2.ZERO)
	var go_btn := Button.new()
	go_btn.text = "Go"
	go_btn.add_theme_font_size_override("font_size", 10)
	go_btn.pressed.connect(func() -> void:
		var w := _world() as Object
		if w.has_method("admin_teleport") and pos is Vector2:
			w.call("admin_teleport", pos)
		dim.queue_free())
	top.add_child(go_btn)
	if id.begins_with("a:"):
		var edit_btn := Button.new()
		edit_btn.text = "Edit"
		edit_btn.add_theme_font_size_override("font_size", 10)
		edit_btn.pressed.connect(func() -> void:
			var w := _world() as Object
			if w.has_method("admin_entity_info"):
				var info: Dictionary = w.call("admin_entity_info", id)
				if not info.is_empty():
					dim.queue_free()
					_open_entity_editor(id, info))
		top.add_child(edit_btn)
	var issue := Label.new()
	issue.text = "⚠ " + str(p.get("issue", ""))
	issue.add_theme_font_size_override("font_size", 10)
	issue.add_theme_color_override("font_color", Color(0.95, 0.60, 0.30))
	box.add_child(issue)
	return box

# ── Inspect / edit a placed entity ──────────────────────────────────────────
## INSPECT click: find the entity under the cursor, read its cached wire data
## from World, and open the property editor. Only admin-placed (a:) entities are
## editable — procedural entities have no per-field override on the server.
func _inspect_at(wpos: Vector2) -> void:
	var id := str((_world() as Object).call("admin_entity_at", wpos, 44.0))
	if id == "":
		return
	# Admin-placed (a:) AND pre-existing NPCs/bosses (n:/b:) are editable — the
	# world synthesizes editable info for the latter.
	var info: Dictionary = {}
	if (_world() as Object).has_method("admin_entity_info"):
		var v: Variant = (_world() as Object).call("admin_entity_info", id)
		if v is Dictionary:
			info = v
	if info.is_empty():
		Events.chat_message.emit("[Admin] Nothing editable here.")
		return
	_open_entity_editor(id, info)

## Popup property editor. Fields are chosen by entity kind; on Apply only the
## CHANGED fields are sent to the server as a patch (admin_edit_entity).
func _open_entity_editor(id: String, info: Dictionary) -> void:
	var kind := str(info.get("kind", ""))
	var subtype := str(info.get("subtype", ""))
	var data: Dictionary = (info.get("data", {}) as Dictionary) \
		if info.get("data") is Dictionary else {}

	# Dimmer that eats clicks behind the panel.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, UITheme.GOLD, 2))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(320, 0)
	dim.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "✎ Edit  %s  (%s)" % [
		subtype.capitalize().replace("_", " "), kind]
	title.add_theme_color_override("font_color", UITheme.GOLD)
	vb.add_child(title)

	# data-key → {"ctrl": Control, "type": String, "orig": Variant}
	var fields: Dictionary = {}
	match kind:
		"monster":
			_add_ro_row(vb, "Type", subtype)
			fields["level"] = _add_int_row(vb, "Level", int(data.get("level", 1)), 1, 99)
		"npc":
			fields["npc_name"]      = _add_str_row(vb, "Name", str(data.get("npc_name", "")))
			fields["quest_text"]    = _add_text_row(vb, "Dialogue", str(data.get("quest_text", "")))
			fields["shop_id"]       = _add_str_row(vb, "Shop id", str(data.get("shop_id", "")))
			fields["wander_radius"] = _add_float_row(vb, "Wander px",
				float(data.get("wander_radius", 32.0)), 0.0, 256.0)
		_:
			# resource / station / wall / farm_plot — generic props.
			fields["display_name"] = _add_str_row(vb, "Name", str(data.get("display_name", "")))
			fields["level"]        = _add_int_row(vb, "Req level", int(data.get("level", 1)), 1, 99)
			fields["action"]       = _add_str_row(vb, "Action", str(data.get("action", "Interact")))

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vb.add_child(btn_row)
	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_A, UITheme.GOLD, 2))
	apply_btn.add_theme_color_override("font_color", UITheme.GOLD)
	btn_row.add_child(apply_btn)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(cancel_btn)

	cancel_btn.pressed.connect(func() -> void: dim.queue_free())
	apply_btn.pressed.connect(func() -> void:
		var patch := _collect_patch(fields)
		if patch.is_empty():
			Events.chat_message.emit("[Admin] No changes.")
		else:
			# Reverse patch = the OLD value of each changed field, so Undo restores it.
			var rev: Dictionary = {}
			for k_v: Variant in patch.keys():
				rev[str(k_v)] = (fields[str(k_v)] as Dictionary)["orig"]
			_push_undo({"op": "edit", "id": id, "patch": rev})
			NetworkManager.send_admin_edit_entity(id, patch)
		dim.queue_free())

## Reads each field control, returning only the values that CHANGED from orig.
func _collect_patch(fields: Dictionary) -> Dictionary:
	var patch: Dictionary = {}
	for key_v: Variant in fields.keys():
		var key := str(key_v)
		var f: Dictionary = fields[key]
		var ctrl: Variant = f["ctrl"]
		var new_val: Variant
		match str(f["type"]):
			"int":   new_val = int((ctrl as SpinBox).value)
			"float": new_val = float((ctrl as SpinBox).value)
			"str":   new_val = (ctrl as LineEdit).text
			"text":  new_val = (ctrl as TextEdit).text
			_:       continue
		if new_val != f["orig"]:
			patch[key] = new_val
	return patch

## ── Editor row builders (each returns the field descriptor for _collect_patch) ──
func _editor_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(90, 0)
	l.add_theme_color_override("font_color", UITheme.DIM)
	l.add_theme_font_size_override("font_size", 11)
	return l

func _add_ro_row(vb: VBoxContainer, label: String, value: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vb.add_child(row)
	row.add_child(_editor_label(label))
	var l := Label.new()
	l.text = value
	l.add_theme_color_override("font_color", UITheme.TEXT)
	l.add_theme_font_size_override("font_size", 11)
	row.add_child(l)

func _add_str_row(vb: VBoxContainer, label: String, value: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vb.add_child(row)
	row.add_child(_editor_label(label))
	var le := LineEdit.new()
	le.text = value
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.add_theme_font_size_override("font_size", 11)
	row.add_child(le)
	return {"ctrl": le, "type": "str", "orig": value}

func _add_text_row(vb: VBoxContainer, label: String, value: String) -> Dictionary:
	vb.add_child(_editor_label(label))
	var te := TextEdit.new()
	te.text = value
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.custom_minimum_size = Vector2(300, 64)
	te.add_theme_font_size_override("font_size", 11)
	vb.add_child(te)
	return {"ctrl": te, "type": "text", "orig": value}

func _add_int_row(vb: VBoxContainer, label: String, value: int, lo: int, hi: int) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vb.add_child(row)
	row.add_child(_editor_label(label))
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = 1
	sb.value = clampi(value, lo, hi)
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sb)
	return {"ctrl": sb, "type": "int", "orig": int(sb.value)}

func _add_float_row(vb: VBoxContainer, label: String, value: float, lo: float, hi: float) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vb.add_child(row)
	row.add_child(_editor_label(label))
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = 1
	sb.value = clampf(value, lo, hi)
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sb)
	return {"ctrl": sb, "type": "float", "orig": float(sb.value)}

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
		_capture_tile_prior(t.x, t.y)
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
		_capture_tile_prior(v.x, v.y)
		bulk.append({"tx": v.x, "ty": v.y, "biome": biome_or_null})
	NetworkManager.send_admin_tile_set_bulk(bulk)
