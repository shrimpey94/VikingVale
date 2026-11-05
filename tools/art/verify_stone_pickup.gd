extends Node
## Offline integration checks. Never starts a world scene or connects/logs in.
const Art = preload("res://scripts/art/StonePickupArt.gd")
const WorldVisual = preload("res://scripts/World3D.gd")
const MeshFactory = preload("res://scripts/Mesh3D.gd")
const Interactable = preload("res://scenes/Interactable.tscn")
var results: Array = []
var failures := 0

func _ready() -> void:
	_run.call_deferred()

func check(condition: bool, label: String) -> void:
	results.append({"check": label, "passed": condition})
	if not condition:
		failures += 1
		push_error("FAIL: " + label)

func _meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out

func _run() -> void:
	check(get_tree().root.get_node("NetworkManager").state == 0, "Offline; no server connection")
	Art.enabled = true
	var force_fallback := "--procedural-stone" in OS.get_cmdline_user_args()
	check(Art.available() != force_fallback, "Paired asset availability / command-line fallback")
	if not force_fallback:
		var texture := Art.texture()
		check(texture.get_size() == Vector2(32, 32), "Sprite is 32x32")
		var image := texture.get_image()
		check(image.get_pixel(0, 0).a == 0.0, "Sprite background is transparent")
		check(image.get_used_rect().size.x >= 16 and image.get_used_rect().size.x <= 20, "Sprite silhouette width is 16-20 pixels")
		var a := Art.instantiate_visual()
		var b := Art.instantiate_visual()
		var meshes := _meshes(a)
		check(meshes.size() == 1, "GLB has one mesh")
		var mi := meshes[0] as MeshInstance3D
		check(mi.mesh.get_aabb().size.is_equal_approx(Vector3(.55, .30, .40)), "Imported dimensions and Y-up conversion")
		check(absf(mi.mesh.get_aabb().position.y) < .0001, "Model base at local Y=0")
		check(mi.transform.is_equal_approx(Transform3D.IDENTITY), "Mesh local transform is identity")
		check(mi.mesh == (_meshes(b)[0] as MeshInstance3D).mesh, "Instances share mesh resource")
		check(mi.material_override == null and mi.mesh.surface_get_material(0) is StandardMaterial3D, "Authored material preserved")
		check(a.find_children("*", "CollisionObject3D", true, false).is_empty(), "No imported physics bodies")
		var tinted := Art.instantiate_visual(Color(.4, .5, .6))
		check((_meshes(tinted)[0] as MeshInstance3D).get_surface_override_material(0) != null, "Custom node tint preserves textured material")
		a.free(); b.free(); tinted.free()

	var world := WorldVisual.new()
	# Do not add World3D to the tree: avoids real world startup/login/cache work.
	var factory := MeshFactory.new()
	world.set("_mesh", factory)
	world.set("_mesh_mat", factory.mat)
	world.set("_in_interior", true)
	var logic := Node2D.new()
	add_child(logic)
	world.set("_ent_container", logic)
	for enabled in [false, true]:
		Art.enabled = enabled
		var stone := world._interactable_node("stone", Color(.58, .56, .52))
		check(stone.has_meta("stone_pickup_art") == (enabled and not force_fallback), "Exact stone route; enabled=" + str(enabled))
		check(stone.scale.x >= .86 and stone.scale.x <= 1.16, "Original random scale retained")
		for type_str in ["rock", "essence", "unrecognized_type"]:
			var other := world._interactable_node(type_str, Color.GRAY)
			check(other is MeshInstance3D and not other.has_meta("stone_pickup_art"), "Unrelated route unchanged: " + type_str)
			other.free()
		var node := Interactable.instantiate()
		node.interactable_type_str = "stone"
		node.required_skill = "foraging"
		node.entity_id = "test:stone"
		world._pair("test:stone", node, stone, Vector2(320, 640))
		node.set_process(false)
		check(node.get_node("CollisionShape2D").shape.size == Vector2(16, 12), "Existing runtime stone pick shape is 16x12")
		check(node.collision_layer == 4 and node.collision_mask == 0 and node.input_pickable, "Original picking/layers retained")
		check(node.get_node_or_null("StructureBody") == null, "Stone adds no movement blocker")
		check(stone.position == Vector3(10, 0, 20) and stone.get_meta("epx") == Vector2(320, 640), "Coordinate conversion and epx retained")
		check(world._pick_entity(Vector2(320, 640), 20) == node, "World picking resolves original logic node")
		world._on_node_remote_locked("test:stone", "test_observer")
		check(node.get("_remote_gathering"), "Remote gathering lock feedback retained")
		world._on_node_remote_unlocked("test:stone")
		check(not node.get("_remote_gathering"), "Remote gathering unlock retained")
		var heights := PackedFloat32Array()
		heights.resize(301 * 301)
		heights.fill(2.0)
		world.set("_corner", heights)
		world.set("_in_interior", false)
		world._sync_entity_meshes()
		check(stone.position.is_equal_approx(Vector3(10, 2.15, 20)), "Exterior terrain height plus original 0.15 lift")
		for z in range(301):
			for x in range(301):
				heights[z * 301 + x] = float(x) * .1 + float(z) * .2
		world.set("_corner", heights)
		world._sync_entity_meshes()
		check(stone.position.is_equal_approx(Vector3(10, 5.15, 20)), "Terrain-height reseating on slope")
		world.set("_in_interior", true)
		node._on_hover_enter()
		check(node.self_modulate == Color(1.2, 1.2, 1.2), "Existing hover feedback")
		node._on_hover_exit()
		node.apply_depleted(45)
		world._sync_entity_meshes()
		check(not node.visible and not stone.visible and not node.input_pickable and node.collision_layer == 0, "Remote depletion hides both and disables picking")
		check(world._pick_entity(Vector2(320, 640), 20) == null, "Depleted stone excluded from world picking")
		node.apply_respawn()
		world._sync_entity_meshes()
		check(node.visible and stone.visible and node.input_pickable and node.collision_layer == 4, "Respawn restores both and picking")
		world._on_node_remote_respawned("test:stone", 352, 672)
		world._sync_entity_meshes()
		# Existing apply_respawn resets _origin_pos after the handler relocates.
		# Assert baseline parity; report this separately as a pre-existing issue.
		check(node.global_position == Vector2(320, 640) and stone.position == Vector3(10, 0, 20), "Respawn relocation matches baseline origin-reset behavior")
		# Repeated visual reconstruction uses the same existing logical node/state.
		for repeat in range(4):
			var replacement := world._interactable_node("stone", node.color)
			world.add_child(replacement)
			world.get("_ent")["test:stone"]["v"] = replacement
			stone.free()
			stone = replacement
			world._sync_entity_meshes()
		check(node.entity_id == "test:stone" and stone.position == Vector3(10, 0, 20), "Repeated visual rebuild preserves ID and position")
		world.get("_ent").clear()
		stone.free()
		node.free()
	logic.free()
	world.free()
	factory.free()
	Art.enabled = true
	var suffix := "fallback" if force_fallback else "authored"
	var path := OS.get_environment("VIKINGVALE_TEST_OUTPUT").path_join("checks_" + suffix + ".json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"failures": failures, "checks": results,
		"existing_issue": "Respawn relocation is reset to _origin_pos in both procedural and authored paths."}, "\t") + "\n")
	file.close()
	print("STONE_CHECKS: ", results.size(), " checks, ", failures, " failures; ", suffix)
	get_tree().quit(0 if failures == 0 else 1)
