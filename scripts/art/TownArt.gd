extends RefCounted
## Families 08–11/16/17 (town buildings, civic halls, forge, bank, well/market/
## armory, walls/fence/gate), authored exports. Visual-only and reversible, one
## kill switch per family:
##   --procedural-buildings (08)  --procedural-civic (09)  --procedural-forge (10)
##   --procedural-bank (11)  --procedural-townprops (16)  --procedural-walls (17)
## Picking, collision, HP bars, actions and placement stay in Interactable/World3D.
## House/Oak/Karl keep their own adapter (VillagePrototypeArt).
const Visual = preload("res://scripts/art/TownVisual.gd")
## Sheets are 2x and display at 0.5; `frame`/`offset` are sheet pixels (halved on
## draw), copied from each package manifest. `base` = the catalog colour the art
## was painted for. `tint`: relative = colour / base (default colour → untinted),
## fixed = never tinted (Bank's stone keeps fixed colours, like its old draw),
## direct = the supplied wood colour multiplies the neutral art (Fence/Gate).
const ASSETS := {
	"chapel": {"family": "buildings", "version": "v001", "frame": Vector2(320, 320), "columns": 1, "offset": Vector2(-160, -216), "base": Color(0.75, 0.72, 0.66), "tint": "relative"},
	"great_hall_building": {"family": "buildings", "version": "v001", "frame": Vector2(352, 352), "columns": 1, "offset": Vector2(-176, -226), "base": Color(0.35, 0.22, 0.12), "tint": "relative"},
	"tavern": {"family": "buildings", "version": "v001", "frame": Vector2(320, 320), "columns": 1, "offset": Vector2(-160, -211), "base": Color(0.7, 0.48, 0.22), "tint": "relative"},
	"town_building": {"family": "buildings", "version": "v001", "frame": Vector2(320, 320), "columns": 1, "offset": Vector2(-160, -213), "base": Color(0.55, 0.45, 0.32), "tint": "relative"},
	"warehouse": {"family": "buildings", "version": "v001", "frame": Vector2(320, 320), "columns": 1, "offset": Vector2(-160, -202), "base": Color(0.5, 0.44, 0.32), "tint": "relative"},
	"large_house": {"family": "civic", "version": "v001", "frame": Vector2(512, 512), "columns": 1, "offset": Vector2(-256, -281), "base": Color(0.52, 0.42, 0.3), "tint": "relative"},
	"grand_hall": {"family": "civic", "version": "v001", "frame": Vector2(512, 512), "columns": 1, "offset": Vector2(-256, -281), "base": Color(0.42, 0.4, 0.46), "tint": "relative"},
	"clan_hall": {"family": "civic", "version": "v001", "frame": Vector2(512, 512), "columns": 1, "offset": Vector2(-256, -281), "base": Color(0.4, 0.34, 0.44), "tint": "relative"},
	"auction_house": {"family": "civic", "version": "v001", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-64, -87), "base": Color(0.45, 0.6, 0.85), "tint": "relative"},
	"forge": {"family": "forge", "version": "v001", "frame": Vector2(96, 96), "columns": 1, "offset": Vector2(-48, -57), "base": Color(0.8, 0.35, 0.12), "tint": "relative"},
	"bank": {"family": "bank", "version": "v001", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-64, -69), "base": Color(0.75, 0.65, 0.2), "tint": "fixed"},
	"well": {"family": "townprops", "version": "v001", "frame": Vector2(192, 192), "columns": 1, "offset": Vector2(-96, -107.4), "base": Color(0.58, 0.6, 0.64), "tint": "relative"},
	"market_stall": {"family": "townprops", "version": "v001", "frame": Vector2(192, 192), "columns": 1, "offset": Vector2(-96, -101.2), "base": Color(0.72, 0.5, 0.28), "tint": "relative"},
	"armory_rack": {"family": "townprops", "version": "v001", "frame": Vector2(192, 192), "columns": 1, "offset": Vector2(-96, -96.2), "base": Color(0.6, 0.55, 0.4), "tint": "relative"},
	"wall_ancient": {"family": "walls", "version": "v002", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-60, -70), "base": Color(0.55, 0.4, 0.12), "tint": "relative"},
	"wall_cherry": {"family": "walls", "version": "v002", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-60, -70), "base": Color(0.72, 0.38, 0.42), "tint": "relative"},
	"wall_frost": {"family": "walls", "version": "v002", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-60, -70), "base": Color(0.72, 0.9, 0.98), "tint": "relative"},
	"wall_ironwood": {"family": "walls", "version": "v002", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-60, -70), "base": Color(0.3, 0.18, 0.08), "tint": "relative"},
	"wall_oak": {"family": "walls", "version": "v002", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-60, -70), "base": Color(0.55, 0.36, 0.18), "tint": "relative"},
	"wall_pine": {"family": "walls", "version": "v002", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-60, -70), "base": Color(0.42, 0.3, 0.14), "tint": "relative"},
	"fence": {"family": "walls", "version": "v001", "frame": Vector2(128, 128), "columns": 1, "offset": Vector2(-64, -62), "base": Color(0.55, 0.36, 0.18), "tint": "direct"},
	"gate": {"family": "walls", "version": "v001", "frame": Vector2(128, 128), "columns": 2, "offset": Vector2(-64, -64), "base": Color(0.55, 0.36, 0.18), "tint": "direct"},
}
## type_str → key for the types matched regardless of display name.
const BY_TYPE := {
	"large_house": "large_house", "grand_hall": "grand_hall", "clan_hall": "clan_hall",
	"auction_house": "auction_house", "forge": "forge", "bank": "bank", "well": "well",
	"market_stall": "market_stall", "armory_rack": "armory_rack", "fence": "fence", "gate": "gate",
}
## "building" by exact name ("" = an unnamed default building). House stays with
## VillagePrototypeArt; any other/custom name keeps the procedural draw.
const BUILDINGS := {
	"Chapel": "chapel", "Great Hall": "great_hall_building", "Tavern": "tavern",
	"Warehouse": "warehouse", "Town Building": "town_building", "": "town_building",
}
## Walls match by wall TYPE, never by name (owner decision 2026-11-17): town
## walls ("Kjelvik Wall"), warband walls ("<Clan> Wall") and player-built walls
## all get the art. Every wood tier has its own default colour, the same in
## AdminCatalog, AdminPanel._WOOD_TIERS and HUD._CONSTR_WOOD. That colour IS the
## type: a wall at one of these colours gets that wood's art, and a custom-coloured
## wall keeps the procedural draw. Fortified walls are a separate type (no art).
const WALLS := ["wall_oak", "wall_pine", "wall_cherry", "wall_ironwood", "wall_frost", "wall_ancient"]
## 3D pieces hidden in the default (closed) state.
const HIDDEN_3D := {"gate": ["OpenGate"]}
const COLOR_EPS := 0.02

static var enabled := true
static var _cache: Dictionary = {}

static func asset_for(type_str: String, display_name: String, color := Color.WHITE) -> String:
	if BY_TYPE.has(type_str): return str(BY_TYPE[type_str])
	if type_str == "building": return str(BUILDINGS.get(display_name, ""))
	if type_str == "wall":
		for key: String in WALLS:
			if _same_color(color, ASSETS[key]["base"]): return key
	return ""

## Key for an Interactable's own type/name/colour.
static func key_of(logic: Node) -> String:
	return asset_for(str(logic.get("interactable_type_str")), str(logic.get("display_name")),
		logic.get("color") as Color)

static func _same_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= COLOR_EPS and absf(a.g - b.g) <= COLOR_EPS and absf(a.b - b.b) <= COLOR_EPS

static func available(key: String) -> bool:
	if key == "" or not enabled or not ASSETS.has(key): return false
	if ("--procedural-" + str(ASSETS[key]["family"])) in OS.get_cmdline_user_args(): return false
	if not _cache.has(key):
		_cache[key] = {}
		var base := "res://assets/authored/village/%s/%s/%s" % [key, ASSETS[key]["version"], key]
		# Paired export: missing either half falls back in both modes.
		if ResourceLoader.exists(base + ".glb") and ResourceLoader.exists(base + ".png"):
			var scene := load(base + ".glb") as PackedScene
			var texture := load(base + ".png") as Texture2D
			if scene != null and texture != null:
				_cache[key] = {"scene": scene, "texture": texture}
	return not (_cache[key] as Dictionary).is_empty()

static func tint_for(key: String, color: Color) -> Color:
	match str(ASSETS[key]["tint"]):
		"fixed": return Color.WHITE
		"direct": return Color(color.r, color.g, color.b, color.a)
	var base: Color = ASSETS[key]["base"]
	if _same_color(color, base): return Color(1, 1, 1, color.a)
	return Color(color.r / base.r, color.g / base.g, color.b / base.b, color.a)

## The old rectangular depth shading is skipped under authored art, except the
## Forge, whose flame compositing relies on it.
static func skips_depth_overlay(logic: Node) -> bool:
	var key := key_of(logic)
	return key != "" and key != "forge" and available(key)

## Family 17 eight-direction sheets (`<key>_directions.png`, directions_v003
## contract): 128x128 sheet-px cells rendered with each main sprite's own camera,
## drawn with that asset's main `offset` (no universal pivot),
## column = posmod(round(yaw / 45°), 8) with Godot +Y yaw (0 spans east-west,
## 90° north-south), rows = states (Gate: closed, open).
const DIRECTIONAL := ["wall_ancient", "wall_cherry", "wall_frost", "wall_ironwood",
	"wall_oak", "wall_pine", "fence", "gate"]
const DIR_CELL := Vector2(128, 128)
## v003 zero columns are pixel-identical to the approved main frames, so the
## direction sheet is used at every angle (owner decision 2026-11-18).
const DIRECTIONS_AT_ZERO := true
static var _dir_cache: Dictionary = {}

static func direction_column(rot: float) -> int:
	return posmod(roundi(rot / (PI / 4.0)), 8)

static func _directions(key: String) -> Texture2D:
	if not _dir_cache.has(key):
		var path := "res://assets/authored/village/%s/%s/%s_directions.png" % [key, ASSETS[key]["version"], key]
		_dir_cache[key] = load(path) as Texture2D if ResourceLoader.exists(path) else null
	return _dir_cache[key] as Texture2D

## Sheet state (Gate: 0 closed, 1 open — main-sheet column / directions row).
static func state_index(logic: Node, key: String) -> int:
	return 1 if key == "gate" and logic != null and bool(logic.get("gate_open")) else 0

## Draws inside the caller's shake transform and hover modulate. Call BEFORE any
## size-class draw_set_transform: the sprites already bake the 2.2x/4.5x
## silhouettes. Records the drawn rect (admin hover/pick bounds).
static func draw_2d(logic: Node2D, key: String) -> bool:
	if not available(key): return false
	var data: Dictionary = ASSETS[key]
	var state := state_index(logic, key)
	var tint := tint_for(key, logic.get("color"))
	# 2x sheets shown at 0.5 and zoomed: sample the BC7 mip chain (canvas default
	# is NEAREST). Interactable has no textured children.
	if logic.texture_filter != CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
		logic.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var col := direction_column(float(logic.get("admin_rot"))) if key in DIRECTIONAL else 0
	var dirs := _directions(key) if key in DIRECTIONAL and (col != 0 or DIRECTIONS_AT_ZERO) else null
	var dst: Rect2
	if dirs != null:
		dst = Rect2(Vector2(data["offset"]) * 0.5, DIR_CELL * 0.5)
		logic.draw_texture_rect_region(dirs, dst,
			Rect2(Vector2(col * DIR_CELL.x, state * DIR_CELL.y), DIR_CELL), tint)
	else:
		var frame: Vector2 = data["frame"]
		dst = Rect2(Vector2(data["offset"]) * 0.5, frame * 0.5)
		logic.draw_texture_rect_region(_cache[key]["texture"], dst,
			Rect2(Vector2(mini(state, int(data["columns"]) - 1) * frame.x, 0), frame), tint)
	logic.set_meta("town_asset", key)   # QA harness only
	logic.set_meta("town_dir", col if dirs != null else -1)
	logic.set_meta("art_rect", dst)
	return true

## Unit scale, zero yaw (no tree-style jitter): admin rotation is applied by World3D.
static func instantiate_visual(key: String, logic: Node2D = null, color := Color.WHITE) -> Node3D:
	if not available(key): return null
	var wrapper := Visual.new()
	wrapper.asset_key = key
	wrapper.hidden_pieces = HIDDEN_3D.get(key, [])
	wrapper.set_meta("town_asset", key)
	wrapper.add_child((_cache[key]["scene"] as PackedScene).instantiate())
	if logic != null: wrapper.logic_ref = weakref(logic)
	var tint := tint_for(key, color)
	if str(ASSETS[key]["tint"]) == "direct": _tint(wrapper, tint, {}, true)
	elif not tint.is_equal_approx(Color.WHITE): _tint(wrapper, tint, {}, false)
	wrapper.refresh()
	return wrapper

## Per-instance material copies: never mutate the shared imported material.
## `direct` sets albedo to the wood colour (neutral art); otherwise multiplies.
static func _tint(node: Node, tint: Color, materials: Dictionary, direct: bool) -> void:
	if node is MeshInstance3D:
		for i in node.mesh.get_surface_count():
			var original: Material = node.mesh.surface_get_material(i)
			if original is StandardMaterial3D:
				if not materials.has(original):
					var copy := original.duplicate() as StandardMaterial3D
					copy.albedo_color = tint if direct else copy.albedo_color * tint
					materials[original] = copy
				node.set_surface_override_material(i, materials[original])
	for child in node.get_children(): _tint(child, tint, materials, direct)
