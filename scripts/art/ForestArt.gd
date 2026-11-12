extends RefCounted
## Family 03 trees (Pine/Cherry/Ironwood/Frost/Ancient) + family 02 Stick Pickup,
## authored v001. Visual-only and reversible: --procedural-forest restores the
## original 2D draws and Mesh3D meshes for all six. Oak/House/Stone/Karl keep
## their own adapters (VillagePrototypeArt / StonePickupArt) untouched.
const Visual = preload("res://scripts/art/ForestTreeVisual.gd")
const VERSION := "v001"
# Runtime values are embedded (authoring JSON is not packed). Sheets are 2x and
# display at 0.5: `cell` and `offset` are sheet pixels, halved on draw. `base` is
# the catalog colour the art was painted for — a node whose colour differs is
# tinted relative to it so admin overrides survive without double-tinting.
const ASSETS := {
	"pine_tree":     {"dir": "forest",    "cell": 192, "rows": 3, "offset": Vector2(-96, -101),  "base": Color(0.10, 0.42, 0.20)},
	"cherry_tree":   {"dir": "forest",    "cell": 192, "rows": 3, "offset": Vector2(-96, -98),   "base": Color(0.98, 0.72, 0.80)},
	"ironwood_tree": {"dir": "forest",    "cell": 192, "rows": 1, "offset": Vector2(-96, -98),   "base": Color(0.30, 0.18, 0.08)},
	"frost_tree":    {"dir": "forest",    "cell": 192, "rows": 1, "offset": Vector2(-96, -101),  "base": Color(0.72, 0.90, 0.98)},
	"ancient_tree":  {"dir": "forest",    "cell": 256, "rows": 1, "offset": Vector2(-128, -139), "base": Color(0.35, 0.20, 0.08)},
	"stick_pickup":  {"dir": "resources", "cell": 64,  "rows": 1, "offset": Vector2(-32, -32),   "base": Color(0.55, 0.36, 0.14)},
}
## Ancient's stump sits lower than its live feet (logical y 14 vs 36), so the
## depleted column carries its own offset.
const ANCIENT_STUMP_OFFSET := Vector2(-128, -183)
## The stick is seeded with two colours (wild .14 blue, catalog/editor .18);
## both are the authored wood and draw untinted.
const STICK_CATALOG_BASE := Color(0.55, 0.36, 0.18)
const TREE_KEYS := {
	"Pine Tree": "pine_tree", "Cherry Tree": "cherry_tree", "Ironwood Tree": "ironwood_tree",
	"Frost Tree": "frost_tree", "Ancient Tree": "ancient_tree",
}
## Canopy pieces visible per state (full → stump). Oak's approved mask differs
## and stays in VillagePrototypeVisual.
const CANOPY_COUNT := [4, 3, 2, 1, 0]

static var enabled := true
static var _cache: Dictionary = {}

static func asset_for(type_str: String, display_name: String) -> String:
	if type_str == "tree": return str(TREE_KEYS.get(display_name, ""))
	if type_str == "stick": return "stick_pickup"
	return ""

static func available(key: String) -> bool:
	if key == "" or not enabled or not ASSETS.has(key) or "--procedural-forest" in OS.get_cmdline_user_args(): return false
	if not _cache.has(key):
		_cache[key] = {}
		var base := "res://assets/authored/%s/%s/%s/%s" % [ASSETS[key]["dir"], key, VERSION, key]
		# Paired export: missing either half falls back in both modes.
		if ResourceLoader.exists(base + ".glb") and ResourceLoader.exists(base + ".png"):
			var scene := load(base + ".glb") as PackedScene
			var texture := load(base + ".png") as Texture2D
			if scene != null and texture != null:
				_cache[key] = {"scene": scene, "texture": texture}
	return not (_cache[key] as Dictionary).is_empty()

## Sheet column: depleted → stump, otherwise HP quarters (live trees have
## max_hp 1, so play only ever shows 0 and 4; the middle columns are ready for
## multi-swing nodes). Mirrored in ForestTreeVisual for the GLB pieces.
static func state_frame(logic: Node) -> int:
	if int(logic.get("_state")) == 2: return 4
	var ratio := float(logic.get("_hp")) / maxf(1.0, float(logic.get("_max_hp")))
	if ratio > .75: return 0
	if ratio > .5: return 1
	if ratio > .25: return 2
	return 3

## Pine/Cherry rows are the three position-picked variants the procedural draw
## used (Interactable._tree_variant_index). Scale is baked into the row.
static func variant_row(key: String, logic: Node2D) -> int:
	var rows := int(ASSETS[key]["rows"])
	if rows <= 1: return 0
	var p := logic.position
	return int(abs(p.x * 73.0 + p.y * 31.0)) % rows

static func tint_for(key: String, color: Color) -> Color:
	var base: Color = ASSETS[key]["base"]
	if color.is_equal_approx(base) or (key == "stick_pickup" and color.is_equal_approx(STICK_CATALOG_BASE)):
		return Color(1, 1, 1, color.a)
	return Color(color.r / base.r, color.g / base.g, color.b / base.b, color.a)

## Draws inside the caller's shake transform and hover self_modulate.
static func draw_2d(logic: Node2D, key: String) -> bool:
	if not available(key): return false
	var data: Dictionary = ASSETS[key]
	var cell := float(data["cell"])
	var frame := 0 if key == "stick_pickup" else state_frame(logic)
	var row := variant_row(key, logic)
	var offset: Vector2 = data["offset"]
	if key == "ancient_tree" and frame == 4: offset = ANCIENT_STUMP_OFFSET
	# The project's canvas default is NEAREST (pixel art). These 2x sheets show at
	# 0.5 and get zoomed, so sample the BC7 mip chain. Interactable has no textured
	# children, so this affects only its own draws.
	if logic.texture_filter != CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
		logic.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	logic.draw_texture_rect_region(_cache[key]["texture"], Rect2(offset * 0.5, Vector2(cell, cell) * 0.5),
		Rect2(frame * cell, row * cell, cell, cell), tint_for(key, logic.get("color")))
	logic.set_meta("forest_frame", frame)   # QA harness only
	logic.set_meta("forest_row", row)
	return true

static func instantiate_visual(key: String, logic: Node2D = null, color := Color.WHITE) -> Node3D:
	if not available(key): return null
	var scene: PackedScene = _cache[key]["scene"]
	var wrapper := Visual.new()
	wrapper.asset_key = key
	wrapper.set_meta("forest_asset", key)
	wrapper.add_child(scene.instantiate())
	if logic != null: wrapper.logic_ref = weakref(logic)
	var tint := tint_for(key, color)
	if not tint.is_equal_approx(Color.WHITE): _tint(wrapper, tint, {})
	wrapper.refresh()   # state mask applied before the first frame shows
	return wrapper

static func _tint(node: Node, tint: Color, materials: Dictionary) -> void:
	if node is MeshInstance3D:
		for i in node.mesh.get_surface_count():
			var original: Material = node.mesh.surface_get_material(i)
			if original is StandardMaterial3D:
				if not materials.has(original):
					var copy := original.duplicate() as StandardMaterial3D
					copy.albedo_color *= tint
					materials[original] = copy
				node.set_surface_override_material(i, materials[original])
	for child in node.get_children(): _tint(child, tint, materials)
