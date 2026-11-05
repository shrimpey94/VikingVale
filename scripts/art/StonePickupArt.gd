extends RefCounted
## Visual-only, versioned prototype. No IDs, physics, rewards or networking.
## Launch with -- --procedural-stone to restore both original render paths.
const SPRITE_PATH := "res://assets/authored/props/stone_pickup/v001/stone_pickup.png"
const MODEL_PATH := "res://assets/authored/props/stone_pickup/v001/stone_pickup.glb"
const DRAW_OFFSET := Vector2(-16, -14)

static var enabled := true
static var _checked := false
static var _texture: Texture2D
static var _scene: PackedScene
static var _tints: Dictionary = {}

static func available() -> bool:
	if not enabled or "--procedural-stone" in OS.get_cmdline_user_args():
		return false
	if not _checked:
		_checked = true
		# Treat the paired export as one asset: missing either falls back in both modes.
		if ResourceLoader.exists(SPRITE_PATH) and ResourceLoader.exists(MODEL_PATH):
			_texture = load(SPRITE_PATH) as Texture2D
			_scene = load(MODEL_PATH) as PackedScene
	return _texture != null and _scene != null

static func texture() -> Texture2D:
	return _texture if available() else null

static func instantiate_visual(color := Color(0.58, 0.56, 0.52)) -> Node3D:
	if not available():
		return null
	var instance := _scene.instantiate() as Node3D
	if instance != null:
		instance.set_meta("stone_pickup_art", "v001")
		if not color.is_equal_approx(Color(0.58, 0.56, 0.52)):
			_apply_tint(instance, color)
	return instance

static func _apply_tint(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var visual := node as MeshInstance3D
		for surface in range(visual.mesh.get_surface_count()):
			var original := visual.mesh.surface_get_material(surface) as StandardMaterial3D
			if original == null:
				continue
			var key := str(original.get_instance_id()) + ":" + str(color)
			if not _tints.has(key):
				var tinted := original.duplicate() as StandardMaterial3D
				tinted.albedo_color *= Color(color.r / 0.58, color.g / 0.56, color.b / 0.52, color.a)
				_tints[key] = tinted
			visual.set_surface_override_material(surface, _tints[key])
	for child in node.get_children():
		_apply_tint(child, color)
