extends Node
## In-game validation harness for the authored forest art (family 03 trees +
## Stick Pickup). SANDBOX ONLY — run through tools/art/capture_forest_ingame.ps1,
## which builds an isolated project copy with the offline network stub and a
## redirected user:// dir. Never referenced by the game.
##
## Lives on the tree root so it survives 2D<->3D scene switches. Loads the REAL
## world.tscn / world3d.tscn, stages one node per asset through the worlds' own
## spawn paths, drives states through Interactable's own _deplete/_respawn,
## saves stills and prints `FOREST_CHECK|name|PASS/FAIL|detail` lines plus a
## JSON summary. `vram` mode samples texture/video memory in the real towns
## (Bjorn's Landing spawn, Kjelvik) and in a synthetic 70-node grove.
##
## User args (after `--`): --forest-mode=2d|3d|toggle|vram  --forest-out=<abs dir>
##                         [--procedural-forest] to capture the originals.

const ForestArt = preload("res://scripts/art/ForestArt.gd")
const InteractableTscn = preload("res://scenes/Interactable.tscn")
const WORLD_2D := "res://world.tscn"
const WORLD_3D := "res://world3d.tscn"
const KJELVIK_CENTER := Vector2(2672, 3696)
## [key, type, name, skill, level, action, colour] — the catalog rows.
const ROWS := [
	["pine_tree",     "tree",  "Pine Tree",     "woodcutting",  5, "Chop", Color(0.10, 0.42, 0.20)],
	["cherry_tree",   "tree",  "Cherry Tree",   "woodcutting", 20, "Chop", Color(0.98, 0.72, 0.80)],
	["ironwood_tree", "tree",  "Ironwood Tree", "woodcutting", 30, "Chop", Color(0.30, 0.18, 0.08)],
	["frost_tree",    "tree",  "Frost Tree",    "woodcutting", 50, "Chop", Color(0.72, 0.90, 0.98)],
	["ancient_tree",  "tree",  "Ancient Tree",  "woodcutting", 70, "Chop", Color(0.35, 0.20, 0.08)],
	["stick_pickup",  "stick", "Stick",         "woodcutting",  1, "Pick", Color(0.55, 0.36, 0.14)],
]
const PICK_SIZES := {"pine_tree": Vector2(24, 34), "cherry_tree": Vector2(24, 34),
	"ironwood_tree": Vector2(24, 34), "frost_tree": Vector2(24, 34),
	"ancient_tree": Vector2(56, 68), "stick_pickup": Vector2(18, 10)}

var _mode := "2d"
var _out := ""
var _expect_authored := true
var _checks: Array[Dictionary] = []
var _perf: Array[Dictionary] = []
var _fails := 0
var _stage_origin := Vector2.ZERO
var _spawn_seq := 0

func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--forest-mode="): _mode = a.trim_prefix("--forest-mode=")
		elif a.begins_with("--forest-out="): _out = a.trim_prefix("--forest-out=")
	_expect_authored = not ("--procedural-forest" in OS.get_cmdline_user_args())
	DirAccess.make_dir_recursive_absolute(_out)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()

# ── helpers ─────────────────────────────────────────────────────────────────
func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks.append({"name": label, "ok": ok, "detail": detail})
	if not ok:
		_fails += 1
	print("FOREST_CHECK|%s|%s|%s" % [label, "PASS" if ok else "FAIL", detail])

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true).timeout

func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame

func _still(label: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(_out.path_join(label + ".png"))

func _sample_perf(label: String) -> void:
	var p := {
		"label": label,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"texture_mem_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"buffer_mem_mb": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0,
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"static_mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
	}
	_perf.append(p)
	print("FOREST_PERF|", JSON.stringify(p))

func _is_2d() -> bool:
	return get_tree().current_scene != null and get_tree().current_scene.scene_file_path == WORLD_2D

func _player() -> Node2D:
	return get_tree().get_first_node_in_group("player") as Node2D

## Park the camera rig (the player) on a world point; hide player + HUD.
func _park(px: Vector2) -> void:
	var pl := _player()
	if pl == null:
		return
	pl.global_position = px
	pl.set("_target_pos", px)
	if _is_2d():
		pl.visible = false
		var cam := pl.get_node_or_null("Camera2D") as Camera2D
		if cam != null:
			cam.reset_smoothing()
	else:
		var spr := get_tree().current_scene.get("_player_spr") as Node3D
		if spr != null and spr.visible:
			spr.visible = false
	var hud := get_tree().get_first_node_in_group("hud") as CanvasLayer
	if hud != null and hud.visible:
		hud.visible = false

func _load_world(path: String) -> bool:
	get_tree().change_scene_to_file(path)
	var waited := 0.0
	while waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		var cs := get_tree().current_scene
		if cs == null or cs.scene_file_path != path:
			continue
		if path == WORLD_3D and not bool(cs.get("_spawned")) and cs.has_method("_on_login_ok"):
			cs.call("_on_login_ok", {})
			var ls := cs.get("_loading") as Node
			if ls != null and is_instance_valid(ls) and ls.has_method("_dismiss"):
				ls.call("_dismiss")
		if _player() != null:
			break
	_check("world_loaded:" + path.get_file(), _player() != null, "player after %.1fs" % waited)
	if _player() == null:
		return false
	await _wait(1.5)
	return true

## Spawn one staged node through the current world's own path. Returns
## {"n": logic Node2D, "v": Node3D or null}.
func _spawn(row: Array, px: Vector2, col: Color = Color(-1, -1, -1)) -> Dictionary:
	var c: Color = row[6] if col.r < 0.0 else col
	_spawn_seq += 1
	var id := "qa:forest:%d" % _spawn_seq
	var cs := get_tree().current_scene
	if _is_2d():
		var it: Node2D = InteractableTscn.instantiate()
		it.set("interactable_type_str", row[1])
		it.set("display_name", row[2])
		it.set("required_skill", row[3])
		it.set("required_level", row[4])
		it.set("action_label", row[5])
		it.set("color", c)
		it.position = px
		cs.get_node("Interactables").add_child(it)
		return {"n": it, "v": null}
	cs.call("_spawn_interactable", id, row[1], row[2], row[3], row[4], row[5], c, px)
	var ent: Dictionary = cs.get("_ent")
	var d: Dictionary = ent.get(id, {})
	return {"n": d.get("n"), "v": d.get("v")}

func _authored_3d(v: Node3D) -> bool:
	return v != null and v.has_meta("forest_asset")

func _piece_visible(v: Node3D, piece: String) -> bool:
	var n := v.find_child(piece, true, false) as Node3D
	return n != null and n.visible

## 3D state mask check: LiveTrunk/Stump + canopy count for a frame.
func _check_mask(tag: String, v: Node3D, frame: int) -> void:
	var want: Array = ForestArt.CANOPY_COUNT
	var ok := _piece_visible(v, "LiveTrunk") == (frame != 4) and _piece_visible(v, "Stump") == (frame == 4)
	var shown := 0
	for i in range(4):
		if _piece_visible(v, "Canopy%d" % i):
			shown += 1
	ok = ok and shown == int(want[frame])
	_check(tag + ":3d_mask", ok, "frame %d canopies %d trunk=%s stump=%s" % [frame, shown,
		_piece_visible(v, "LiveTrunk"), _piece_visible(v, "Stump")])

## 2D frame check via the adapter's QA meta (only set on the authored path).
func _check_frame(tag: String, n: Node2D, frame: int) -> void:
	var got := int(n.get_meta("forest_frame", -1))
	_check(tag + ":2d_frame", got == frame, "want %d got %d" % [frame, got])

## A world x whose Pine/Cherry variant row equals `want` (y fixed).
func _x_for_row(x0: float, y: float, want: int) -> float:
	var x := x0
	for _i in range(32):
		if int(abs(x * 73.0 + y * 31.0)) % 3 == want:
			return x
		x += 1.0
	return x0

# ── scripted run ────────────────────────────────────────────────────────────
func _run() -> void:
	print("FOREST_HARNESS mode=%s authored=%s out=%s" % [_mode, _expect_authored, _out])
	match _mode:
		"toggle": await _run_toggle()
		"vram":   await _run_vram()
		_:        await _run_states(WORLD_3D if _mode == "3d" else WORLD_2D)
	var summary := {"mode": _mode, "authored_expected": _expect_authored,
		"fails": _fails, "checks": _checks, "perf": _perf}
	var f := FileAccess.open(_out.path_join("summary.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(summary, "  "))
		f.close()
	print("FOREST_RESULT|fails=%d|checks=%d" % [_fails, _checks.size()])
	get_tree().quit(1 if _fails > 0 else 0)

func _run_states(path: String) -> void:
	if not await _load_world(path):
		return
	var two := path == WORLD_2D
	# Stage just west of the Bjorn's Landing spawn, outside the buildings.
	_stage_origin = GameManager.RESPAWN_POS + Vector2(-620, -40)
	_park(_stage_origin)
	await _wait(1.0)
	_sample_perf("settled")
	if not two:
		var cs := get_tree().current_scene
		cs.set("_cam_dist", 9.0)
		cs.set("_cam_pitch", 0.55)
	for row: Array in ROWS:
		await _asset_states(row, two)
	await _variants_and_tints(two)
	await _group_still(two)
	_sample_perf("end")

func _asset_states(row: Array, two: bool) -> void:
	var key := str(row[0])
	var px := _stage_origin
	var ent := _spawn(row, px)
	var n := ent["n"] as Node2D
	var v := ent["v"] as Node3D
	_park(px + Vector2(0, 2))
	await _frames(3)
	_check(key + ":package", ForestArt.available(key) == _expect_authored,
		"ForestArt.available=%s" % ForestArt.available(key))
	if two and _expect_authored:
		_check(key + ":2d_mipmap_filter", n.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS,
			"authored draw path ran")
	if not two:
		_check(key + ":3d_visual", v != null and _authored_3d(v) == _expect_authored,
			"%s visual" % ("authored" if _authored_3d(v) else ("procedural" if v != null else "NO")))
	# Picking area is logic-side and untouched by the art swap.
	var cs := n.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var size: Vector2 = (cs.shape as RectangleShape2D).size if cs != null and cs.shape is RectangleShape2D else Vector2.ZERO
	_check(key + ":pick_area", size == PICK_SIZES[key], "got %s" % size)
	if key == "stick_pickup":
		await _still(key + "_available")
		n.call("_deplete")
		_check(key + ":hidden_on_collect", not n.visible, "visible=%s" % n.visible)
		if not two and v != null:
			var frames := 0
			while v.visible and frames < 10:
				await get_tree().process_frame
				frames += 1
			_check(key + ":3d_hidden_within_1_frame", not v.visible and frames <= 1, "after %d frame(s)" % frames)
		await _still(key + "_collected")
		n.call("_respawn")
		await _frames(2)
		_check(key + ":respawn_visible", n.visible and (two or v == null or v.visible), "")
		_park(n.position + Vector2(0, 2))
		await _frames(2)
		await _still(key + "_respawned")
		return
	# Live trees have max_hp 1 (one swing): columns 1-3 never show in play. Exercise
	# them anyway with a temporary 4-hp node so every sheet column / mask is verified.
	n.set("_max_hp", 4)
	var names := ["full", "three_quarters", "half", "sparse"]
	for frame in range(4):
		n.set("_hp", 4 - frame)
		n.queue_redraw()
		await _frames(3)
		if _expect_authored:
			if two:
				_check_frame(key + ":" + names[frame], n, frame)
			elif v != null:
				_check_mask(key + ":" + names[frame], v, frame)
		await _still("%s_%d_%s" % [key, frame, names[frame]])
	n.set("_hp", 1)
	n.call("_deplete")   # the real path: state DEPLETED, collision off, loot locally
	n.queue_redraw()     # the hit loop / apply_depleted redraw right after; mirror that
	await _frames(3)
	_check(key + ":depleted_state", int(n.get("_state")) == 2, "state=%s" % n.get("_state"))
	if _expect_authored:
		if two:
			_check_frame(key + ":stump", n, 4)
		elif v != null:
			_check_mask(key + ":stump", v, 4)
	await _still("%s_4_stump" % key)
	n.call("_respawn")   # relocates 2-5 tiles away, state IDLE
	n.set("_max_hp", 1)
	n.set("_hp", 1)
	n.queue_redraw()
	await _frames(3)
	_check(key + ":respawned", int(n.get("_state")) == 0 and n.visible, "state=%s" % n.get("_state"))
	_park(n.position + Vector2(0, 2))
	await _frames(2)
	if _expect_authored:
		if two:
			_check_frame(key + ":respawned", n, 0)
		elif v != null:
			_check_mask(key + ":respawned", v, 0)
	await _still("%s_respawned" % key)
	if not two and v != null:
		await _closeup(key, n)
	n.queue_free()
	await _frames(2)

## 3D turnaround at the close camera.
func _closeup(key: String, n: Node2D) -> void:
	var cs := get_tree().current_scene
	for k in range(4):
		cs.set("_cam_yaw", float(k) * PI * 0.5)
		_park(n.position + Vector2(0, 2))
		await _wait(0.4)
		await _still("%s_close_yaw%d" % [key, k * 90])
	cs.set("_cam_yaw", 0.0)

func _variants_and_tints(two: bool) -> void:
	# Pine + Cherry: three position-picked rows each, side by side.
	var y := _stage_origin.y
	var x := _stage_origin.x - 100.0
	for r: Array in [ROWS[0], ROWS[1]]:
		var key := str(r[0])
		for want in range(3):
			var vx := _x_for_row(x, y, want)
			var ent := _spawn(r, Vector2(vx, y))
			var n := ent["n"] as Node2D
			await _frames(3)
			if two and _expect_authored:
				var got := int(n.get_meta("forest_row", -1))
				_check("%s:variant_row_%d" % [key, want], got == want, "want %d got %d" % [want, got])
			x += 100.0
		_park(Vector2(x - 150.0, y + 2))
		await _frames(2)
		await _still(key + "_variants")
		if not two:
			_check(key + ":3d_variants_present", true, "3 instances with jitter only (rows are a 2D-only concept)")
	# Custom tint: a Pine with an admin colour override vs the catalog pine.
	var tinted := _spawn(ROWS[0], Vector2(x, y), Color(0.45, 0.30, 0.55))
	var plain := _spawn(ROWS[0], Vector2(x + 80.0, y))
	await _frames(3)
	var t := ForestArt.tint_for("pine_tree", Color(0.45, 0.30, 0.55))
	_check("pine_tree:tint_ratio", not t.is_equal_approx(Color.WHITE), "tint=%s" % t)
	_check("pine_tree:catalog_untinted", ForestArt.tint_for("pine_tree", ROWS[0][6]).is_equal_approx(Color.WHITE), "")
	_check("stick_pickup:both_bases_untinted",
		ForestArt.tint_for("stick_pickup", Color(0.55, 0.36, 0.14)).is_equal_approx(Color.WHITE)
		and ForestArt.tint_for("stick_pickup", Color(0.55, 0.36, 0.18)).is_equal_approx(Color.WHITE), "")
	if not two and _expect_authored:
		var tv := tinted["v"] as Node3D
		var pv := plain["v"] as Node3D
		_check("pine_tree:3d_tint_override", tv != null and _has_override(tv) and pv != null and not _has_override(pv),
			"tinted=%s plain=%s" % [tv != null and _has_override(tv), pv != null and _has_override(pv)])
	_park(Vector2(x + 40.0, y + 2))
	await _frames(2)
	await _still("pine_tree_tint_override")

func _has_override(v: Node3D) -> bool:
	for m: Node in v.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in range(mi.mesh.get_surface_count()):
			if mi.get_surface_override_material(i) != null:
				return true
	return false

## Everything at once at the gameplay zoom and zoomed out (mip filtering check).
func _group_still(two: bool) -> void:
	var y := _stage_origin.y + 120.0
	var x := _stage_origin.x - 160.0
	for r: Array in ROWS:
		_spawn(r, Vector2(x, y))
		x += 64.0
	_park(Vector2(_stage_origin.x, y + 2))
	await _wait(0.5)
	await _still("group_default")
	if two:
		var cam := _player().get_node_or_null("Camera2D") as Camera2D
		if cam != null:
			for z: float in [1.2, 0.6]:
				cam.zoom = Vector2(z, z)
				await _wait(0.4)
				await _still("group_zoom_%s" % str(z).replace(".", "_"))
			cam.zoom = Vector2(2.5, 2.5)
	else:
		var cs := get_tree().current_scene
		cs.set("_cam_dist", 24.0)
		cs.set("_cam_pitch", 0.82)
		await _wait(0.5)
		await _still("group_default_camera")

func _run_toggle() -> void:
	var path := WORLD_2D
	if not await _load_world(path):
		return
	_stage_origin = GameManager.RESPAWN_POS + Vector2(-620, -40)
	for n in range(4):
		var pl := _player()
		var carry := pl.global_position if pl != null else Vector2(-1, -1)
		GameManager.switch_pos = carry
		path = WORLD_3D if path == WORLD_2D else WORLD_2D
		var t0 := Time.get_ticks_msec()
		var ok := await _load_world(path)
		var tag := "toggle_%d_%s" % [n, "3d" if path == WORLD_3D else "2d"]
		_check(tag + ":scene_ready", ok, "%d ms" % (Time.get_ticks_msec() - t0))
		if not ok:
			return
		_park(_stage_origin)
		var ent := _spawn(ROWS[4], _stage_origin)          # Ancient: heaviest sheet + aura overlay
		var stick := _spawn(ROWS[5], _stage_origin + Vector2(48, 20))
		await _frames(3)
		var tn := ent["n"] as Node2D
		if path == WORLD_2D:
			_check(tag + ":2d_authored", (tn.get_meta("forest_frame", -1) == 0) == _expect_authored, "")
		else:
			_check(tag + ":3d_authored", _authored_3d(ent["v"] as Node3D) == _expect_authored, "")
		tn.call("_deplete")
		tn.queue_redraw()
		(stick["n"] as Node2D).call("_deplete")
		await _frames(2)
		_check(tag + ":depleted_in_mode", int(tn.get("_state")) == 2 and not (stick["n"] as Node2D).visible, "")
		await _still(tag)
		_sample_perf(tag)

## Memory in real towns and a synthetic grove, both renderers.
func _run_vram() -> void:
	for path: String in [WORLD_2D, WORLD_3D]:
		var m := "2d" if path == WORLD_2D else "3d"
		if not await _load_world(path):
			return
		_park(GameManager.RESPAWN_POS)
		await _wait(3.0)
		_sample_perf(m + ":bjorns_spawn")
		await _still(m + "_bjorns")
		_park(KJELVIK_CENTER)
		await _wait(3.0)
		_sample_perf(m + ":kjelvik")
		await _still(m + "_kjelvik")
		# Synthetic grove: 12 of each tree + 10 sticks around the player, inside Kjelvik.
		var rng := RandomNumberGenerator.new()
		rng.seed = 1337
		for r: Array in ROWS:
			var count := 10 if r[1] == "stick" else 12
			for _i in range(count):
				_spawn(r, KJELVIK_CENTER + Vector2(rng.randf_range(-260, 260), rng.randf_range(-180, 180)))
		await _wait(2.0)
		_sample_perf(m + ":kjelvik_plus_grove70")
		await _still(m + "_grove")
		GameManager.switch_pos = KJELVIK_CENTER
