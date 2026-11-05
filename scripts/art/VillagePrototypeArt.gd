extends RefCounted
## Paired, visual-only prototypes. --procedural-village restores all three.
const Visual = preload("res://scripts/art/VillagePrototypeVisual.gd")
## Karl v011 lives in its own adapter (per-clip sheets + skeletal clips);
## --procedural-karl reverts just him.
const KarlArt = preload("res://scripts/art/KarlArt.gd")
const VERSIONS := {"oak_tree": "v002", "timber_house": "v002", "karl": KarlArt.VERSION}
# Runtime values are explicit so packaged builds do not need JSON export filters.
# Export metadata remains beside the GLB for production/verification tools.
# (Karl's per-clip cells/offsets are in KarlArt.CLIPS — the old 64x64 Karl
# frame data is retired.)
const FRAMES := {
	"oak_tree": {"frame_size": [96, 96], "draw_offset": [-48, -49]},
	"timber_house": {"frame_size": [128, 128], "draw_offset": [-64, -75]},
}
static var enabled := true
static var _cache: Dictionary = {}

static func asset_for(type_str: String, display_name: String) -> String:
	if type_str == "tree" and display_name == "Oak Tree": return "oak_tree"
	if type_str == "building" and display_name == "House": return "timber_house"
	if type_str == "worker" and display_name == "Karl": return "karl"
	return ""

static func available(key: String) -> bool:
	if not enabled or not VERSIONS.has(key) or "--procedural-village" in OS.get_cmdline_user_args(): return false
	if key == "karl": return KarlArt.available()
	if not _cache.has(key):
		_cache[key] = {}
		var base := "res://assets/authored/village/%s/%s/%s" % [key, VERSIONS[key], key]
		if ResourceLoader.exists(base + ".glb") and ResourceLoader.exists(base + ".png"):
			var scene := load(base + ".glb") as PackedScene
			var texture := load(base + ".png") as Texture2D
			if scene != null and texture != null:
				_cache[key] = {"scene": scene, "texture": texture, "data": FRAMES[key]}
	return not (_cache[key] as Dictionary).is_empty()

static func state_frame(key: String, logic: Node) -> int:
	if key == "oak_tree":
		if int(logic.get("_state")) == 2: return 4
		var ratio := float(logic.get("_hp")) / maxf(1.0, float(logic.get("_max_hp")))
		if ratio > .75: return 0
		if ratio > .5: return 1
		if ratio > .25: return 2
		return 3
	return 0

static func draw_asset(logic: Node2D, key: String) -> bool:
	if not available(key): return false
	if key == "karl": return KarlArt.draw_2d(logic)
	var entry: Dictionary = _cache[key]
	var data: Dictionary = entry["data"]
	var size := Vector2(data["frame_size"][0], data["frame_size"][1])
	var offset := Vector2(data["draw_offset"][0], data["draw_offset"][1])
	var frame := state_frame(key, logic)
	var tint := Color.WHITE
	if key != "karl":
		var base := Color(.18, .55, .15) if key == "oak_tree" else Color(.65, .52, .35)
		var color: Color = logic.get("color")
		tint = Color(color.r / base.r, color.g / base.g, color.b / base.b, color.a)
	logic.draw_texture_rect_region(entry["texture"], Rect2(offset, size), Rect2(Vector2(frame * size.x, 0), size), tint)
	return true

static func instantiate_visual(key: String, logic: Node2D = null, color := Color.WHITE) -> Node3D:
	if not available(key): return null
	var scene: PackedScene = KarlArt.scene() if key == "karl" else _cache[key]["scene"] as PackedScene
	if scene == null: return null   # package present but GLB failed to load → procedural rig
	var wrapper := Visual.new()
	wrapper.asset_key = key
	wrapper.set_meta("village_asset", key)
	wrapper.add_child(scene.instantiate())
	if logic != null: wrapper.logic_ref = weakref(logic)
	if key != "karl" and color != Color.WHITE:
		var base := Color(.18, .55, .15) if key == "oak_tree" else Color(.65, .52, .35)
		var tint := Color(color.r / base.r, color.g / base.g, color.b / base.b, color.a)
		if not tint.is_equal_approx(Color.WHITE): _tint(wrapper, tint, {})
	wrapper.refresh()
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
