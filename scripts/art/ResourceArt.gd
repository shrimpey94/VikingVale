extends RefCounted
## Family 04 mining nodes (Copper/Iron/Gold/Mithril/Adamant/Runite) + family 06
## forage (Herb/Mushroom/Berry/Moonbloom/Ancient Root/Wild Bush), authored v001.
## Visual-only and reversible: --procedural-ores restores the original rock draws
## and Mesh3D.rock; --procedural-forage restores the herb draws and Mesh3D.bush.
## Stone/stick/tree/village adapters are untouched. Ground stain, magic halo,
## hover and gathering shake stay in Interactable around the authored sprite.
const Visual = preload("res://scripts/art/ResourceVisual.gd")
const VERSION := "v001"
## Sheets are 2x and display at 0.5; `cell`/`offset` are sheet pixels (halved on
## draw). `frames` = sheet columns; `base` = catalog colour the art was painted
## for (nodes with another colour are tinted relative to it).
const ASSETS := {
	"copper_rock":     {"family": "ores",   "frames": 5, "offset": Vector2(-48, -46), "base": Color(0.72, 0.42, 0.22)},
	"iron_rock":       {"family": "ores",   "frames": 5, "offset": Vector2(-48, -46), "base": Color(0.55, 0.55, 0.60)},
	"gold_vein":       {"family": "ores",   "frames": 5, "offset": Vector2(-48, -46), "base": Color(0.88, 0.72, 0.12)},
	"mithril_rock":    {"family": "ores",   "frames": 5, "offset": Vector2(-48, -46), "base": Color(0.40, 0.65, 0.90)},
	"adamant_rock":    {"family": "ores",   "frames": 5, "offset": Vector2(-48, -46), "base": Color(0.20, 0.65, 0.30)},
	"runite_rock":     {"family": "ores",   "frames": 5, "offset": Vector2(-48, -46), "base": Color(0.65, 0.20, 0.82)},
	"herb_patch":      {"family": "forage", "frames": 5, "offset": Vector2(-48, -62), "base": Color(0.62, 0.82, 0.20)},
	"mushroom_patch":  {"family": "forage", "frames": 4, "offset": Vector2(-48, -62), "base": Color(0.72, 0.55, 0.38)},
	"berry_bush":      {"family": "forage", "frames": 9, "offset": Vector2(-48, -62), "base": Color(0.24, 0.50, 0.20)},
	"moonbloom_patch": {"family": "forage", "frames": 4, "offset": Vector2(-48, -62), "base": Color(0.78, 0.62, 0.95)},
	"ancient_root":    {"family": "forage", "frames": 3, "offset": Vector2(-48, -62), "base": Color(0.42, 0.28, 0.12)},
	"wild_bush":       {"family": "forage", "frames": 4, "offset": Vector2(-48, -62), "base": Color(0.72, 0.22, 0.52)},
}
const CELL := 96
const HERB_KEYS := {
	"Herb Patch": "herb_patch", "Mushroom Patch": "mushroom_patch", "Berry Bush": "berry_bush",
	"Moonbloom Patch": "moonbloom_patch", "Ancient Root": "ancient_root", "Wild Bush": "wild_bush",
}
## Only used when no logic node (and so no level) is at hand: the 3D path keyed
## by display name. Play dispatch stays level-ranged like the procedural draw.
const ORE_KEYS := {
	"Copper Rock": "copper_rock", "Iron Rock": "iron_rock", "Gold Vein": "gold_vein",
	"Mithril Rock": "mithril_rock", "Adamant Rock": "adamant_rock", "Runite Rock": "runite_rock",
}
## Ancient Root: frame 2 is a rune overlay composited over the live frame with
## the existing rune pulse; it is never a state.
const ROOT_OVERLAY_FRAME := 2

static var enabled := true
static var _cache: Dictionary = {}

## Rocks dispatch by required-level range exactly like Interactable._draw_rock;
## herbs by exact display name. Anything else keeps the procedural draw.
static func asset_for(type_str: String, display_name: String, level: int = -1) -> String:
	if type_str == "rock":
		if level < 0: return str(ORE_KEYS.get(display_name, ""))
		if level < 15: return "copper_rock"
		if level < 30: return "iron_rock"
		if level < 50: return "gold_vein"
		if level < 70: return "mithril_rock"
		if level < 85: return "adamant_rock"
		return "runite_rock"
	if type_str == "herb": return str(HERB_KEYS.get(display_name, ""))
	return ""

static func available(key: String) -> bool:
	if key == "" or not enabled or not ASSETS.has(key): return false
	var flag := "--procedural-" + str(ASSETS[key]["family"])
	if flag in OS.get_cmdline_user_args(): return false
	if not _cache.has(key):
		_cache[key] = {}
		var base := "res://assets/authored/resources/%s/%s/%s" % [key, VERSION, key]
		# Paired export: missing either half falls back in both modes.
		if ResourceLoader.exists(base + ".glb") and ResourceLoader.exists(base + ".png"):
			var scene := load(base + ".glb") as PackedScene
			var texture := load(base + ".png") as Texture2D
			if scene != null and texture != null:
				_cache[key] = {"scene": scene, "texture": texture}
	return not (_cache[key] as Dictionary).is_empty()

## Sheet column for the node's state. Every rule is the one the procedural draw
## used for that node (handoff contract), so partial-HP frames line up with the
## dormant crack / leaf-count code even though play uses max_hp 1 (only the
## first and the depleted column ever show).
static func state_frame(key: String, logic: Node) -> int:
	var depleted := int(logic.get("_state")) == 2
	var ratio := float(logic.get("_hp")) / maxf(1.0, float(logic.get("_max_hp")))
	match key:
		"herb_patch":
			if depleted: return 4
			if ratio >= 1.0: return 0
			if ratio > 0.75: return 1
			if ratio >= 0.5: return 2
			return 3
		"mushroom_patch":
			if depleted: return 3
			if ratio > 0.8: return 0
			if ratio > 0.4: return 1
			return 2
		"berry_bush":
			if depleted: return 8
			return 9 - clampi(int(ratio * 9.0) + 2, 2, 9)
		"moonbloom_patch", "wild_bush":
			if depleted: return 3
			return 3 - clampi(int(ratio * 2.0) + 1, 1, 3)
		"ancient_root":
			return 1 if depleted else 0
		_:   # ores: dormant crack formula 4 - int(ratio*4 + .99)
			if depleted: return 4
			return clampi(4 - int(ratio * 4.0 + 0.99), 0, 3)

static func tint_for(key: String, color: Color) -> Color:
	var base: Color = ASSETS[key]["base"]
	if color.is_equal_approx(base): return Color(1, 1, 1, color.a)
	return Color(color.r / base.r, color.g / base.g, color.b / base.b, color.a)

## The existing Ancient Root rune pulse (Interactable._draw_ancient_root), read
## from the node's own timer so no new clock is introduced.
static func root_pulse(logic: Node) -> float:
	return 0.65 + sin(float(logic.get("_time_elapsed")) * 2.4) * 0.30

## Draws inside the caller's shake transform and hover self_modulate.
static func draw_2d(logic: Node2D, key: String) -> bool:
	if not available(key): return false
	var data: Dictionary = ASSETS[key]
	var frame := state_frame(key, logic)
	var offset: Vector2 = data["offset"]
	var tint := tint_for(key, logic.get("color"))
	# Canvas default is NEAREST (pixel art); these 2x sheets show at 0.5 and get
	# zoomed, so sample the BC7 mip chain. Interactable has no textured children.
	if logic.texture_filter != CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
		logic.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var dst := Rect2(offset * 0.5, Vector2(CELL, CELL) * 0.5)
	var tex: Texture2D = _cache[key]["texture"]
	logic.draw_texture_rect_region(tex, dst, Rect2(frame * CELL, 0, CELL, CELL), tint)
	var overlay := -1
	if key == "ancient_root" and frame == 0:
		overlay = ROOT_OVERLAY_FRAME
		var pulse := root_pulse(logic)
		logic.draw_texture_rect_region(tex, dst, Rect2(overlay * CELL, 0, CELL, CELL),
			Color(tint.r, tint.g, tint.b, tint.a * pulse))
	logic.set_meta("resource_frame", frame)     # QA harness only
	logic.set_meta("resource_overlay", overlay)
	return true

static func instantiate_visual(key: String, logic: Node2D = null, color := Color.WHITE) -> Node3D:
	if not available(key): return null
	var scene: PackedScene = _cache[key]["scene"]
	var wrapper := Visual.new()
	wrapper.asset_key = key
	wrapper.set_meta("resource_asset", key)
	wrapper.add_child(scene.instantiate())
	if logic != null: wrapper.logic_ref = weakref(logic)
	var tint := tint_for(key, color)
	if not tint.is_equal_approx(Color.WHITE): _tint(wrapper, tint, {})
	wrapper.refresh()   # full-state mask applied before the first frame shows
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
