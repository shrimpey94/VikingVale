extends Node
## Full scene switch through the existing SettingsPanel signal, with a disabled
## network transport and a synthetic in-memory resource feed. No real account.
const Settings = preload("res://scripts/ui/SettingsPanel.gd")
const Art = preload("res://scripts/art/StonePickupArt.gd")
const ID := "a:stone-prototype-test"
const START := Vector2(8336, 4944) # tile center; beach-edge fixture overlaps terrain collision
var results: Array = []
var failures := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, description: String) -> void:
	results.append({"check": description, "passed": ok})
	if not ok:
		failures += 1
		push_error(description)

func settle() -> void:
	for frame in range(30):
		await get_tree().process_frame

func _run() -> void:
	seed(41723)
	# Keep this test driver alive as a root sibling when current_scene changes.
	get_tree().current_scene = null
	GameManager.intro_active = true
	GameManager.switch_pos = START
	NetworkManager.state = NetworkManager.NetState.LOGGED_IN
	NetworkManager.world_entities_cache = [{"id": ID, "kind": "resource",
		"x": 8376.0, "y": 5008.0, "data": {"type_str": "stone",
		"display_name": "Stone Pickup", "skill": "foraging", "level": 1,
		"action": "Pick", "color": [.58, .56, .52, 1.0]}}]
	get_tree().change_scene_to_file("res://world.tscn")
	await settle()
	# Select a genuinely passable 3x3 patch; the original beach fixture had
	# intersected blocked terrain and correctly triggered collision recovery.
	var ground := get_tree().current_scene.get_node("Ground")
	var anchor := START
	var found := false
	for ty in range(135, 160):
		for tx in range(240, 265):
			var clear := true
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if ground.is_tile_impassable(tx + dx, ty + dy):
						clear = false
			if clear:
				anchor = Vector2(tx * 32 + 16, ty * 32 + 16)
				found = true
				break
		if found:
			break
	check(found, "Passable 3x3 terrain patch found for at-rest toggle")
	var initial_player := get_tree().get_first_node_in_group("player") as Node2D
	initial_player._on_player_respawned(anchor)
	await settle()
	for target_3d in [true, false, true, false]:
		var previous_player := get_tree().get_first_node_in_group("player") as Node2D
		var before := previous_player.global_position
		var panel := Settings.new()
		add_child(panel)
		var toggle: CheckButton
		for candidate in panel.find_children("*", "CheckButton", true, false):
			if candidate.text == "3D (beta)":
				toggle = candidate
		check(toggle != null, "Existing SettingsPanel toggle found")
		if toggle == null:
			break
		toggle.button_pressed = target_3d
		await settle()
		panel.queue_free()
		var current := get_tree().current_scene
		var expected := "res://world3d.tscn" if target_3d else "res://world.tscn"
		check(current.scene_file_path == expected, "Actual scene switch to " + expected)
		var player := get_tree().get_first_node_in_group("player") as Node2D
		print("TOGGLE_POSITION: ", before, " -> ", player.global_position, " mode3d=", target_3d)
		check(player.global_position.distance_to(before) < .01, "Player position survives toggle at open-ground anchor")
		var node: Node2D
		if target_3d:
			var entry: Dictionary = current.get("_ent").get(ID, {})
			node = entry.get("n") as Node2D
			if not entry.is_empty():
				check(entry["v"].has_meta("stone_pickup_art") == Art.available(), "3D stone uses selected visual after scene rebuild")
		else:
			node = current.get("_admin_registry").get(ID) as Node2D
			check(Art.available() == not ("--procedural-stone" in OS.get_cmdline_user_args()), "2D selected art remains available after scene rebuild")
		check(node != null, "Same resource ID restored from entity cache")
		if node != null:
			check(node.entity_id == ID and node.global_position == Vector2(8376, 5008), "Stone logical identity/position retained")
			Events.node_remote_depleted.emit(ID, 45.0)
			await get_tree().process_frame
			check(not node.visible and not node.input_pickable, "Existing depletion signal after toggle")
			Events.node_remote_respawned.emit(ID, -1.0, -1.0)
			await get_tree().process_frame
			check(node.visible and node.input_pickable, "Existing respawn signal after toggle")
	var suffix := "fallback" if "--procedural-stone" in OS.get_cmdline_user_args() else "authored"
	var output := OS.get_environment("VIKINGVALE_TEST_OUTPUT").path_join("checks_toggle_" + suffix + ".json")
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify({"failures": failures, "checks": results,
		"scope": "Actual SettingsPanel scene switches; synthetic offline entity feed, no multiplayer server."}, "\t") + "\n")
	file.close()
	print("STONE_TOGGLE_CHECKS: ", results.size(), " checks, ", failures, " failures")
	get_tree().quit(0 if failures == 0 else 1)
