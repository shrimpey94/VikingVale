extends Node
## In-game validation harness for the authored mining nodes (family 04) and
## forage (family 06). SANDBOX ONLY — run through tools/art/capture_resource_ingame.ps1
## (isolated project copy, offline network stub, redirected user://). Never
## referenced by the game.
##
## Same approach as forest_ingame_harness: loads the REAL world.tscn / world3d.tscn,
## stages one node per asset through the worlds' own spawn paths, drives every
## sheet frame through _hp/_max_hp + the real _deplete/_respawn, saves stills and
## prints `RES_CHECK|name|PASS/FAIL|detail`, `RES_PERF|json` and summary.json.
## Expected frames / 3D masks below are transcribed from the handoff docs, not
## read from the adapter, so the adapter is verified against the contract.
##
## User args: --res-mode=2d|3d|toggle|vram  --res-out=<abs dir>
##            [--procedural-ores] [--procedural-forage] to capture the originals.

const ResourceArt = preload("res://scripts/art/ResourceArt.gd")
const InteractableTscn = preload("res://scenes/Interactable.tscn")
const WORLD_2D := "res://world.tscn"
const WORLD_3D := "res://world3d.tscn"
const KJELVIK_CENTER := Vector2(2672, 3696)
## [key, type, name, skill, level, action, colour] — catalog rows (AdminCatalog / World._resource_data).
const ROWS := [
	["copper_rock",     "rock", "Copper Rock",     "mining",    1, "Mine", Color(0.72, 0.42, 0.22)],
	["iron_rock",       "rock", "Iron Rock",       "mining",   15, "Mine", Color(0.55, 0.55, 0.60)],
	["gold_vein",       "rock", "Gold Vein",       "mining",   30, "Mine", Color(0.88, 0.72, 0.12)],
	["mithril_rock",    "rock", "Mithril Rock",    "mining",   50, "Mine", Color(0.40, 0.65, 0.90)],
	["adamant_rock",    "rock", "Adamant Rock",    "mining",   70, "Mine", Color(0.20, 0.65, 0.30)],
	["runite_rock",     "rock", "Runite Rock",     "mining",   85, "Mine", Color(0.65, 0.20, 0.82)],
	["herb_patch",      "herb", "Herb Patch",      "farming",   1, "Pick", Color(0.62, 0.82, 0.20)],
	["mushroom_patch",  "herb", "Mushroom Patch",  "farming",  10, "Pick", Color(0.72, 0.55, 0.38)],
	["berry_bush",      "herb", "Berry Bush",      "farming",  25, "Pick", Color(0.24, 0.50, 0.20)],
	["moonbloom_patch", "herb", "Moonbloom Patch", "farming",  40, "Pick", Color(0.78, 0.62, 0.95)],
	["ancient_root",    "herb", "Ancient Root",    "farming",  60, "Dig",  Color(0.42, 0.28, 0.12)],
	["wild_bush",       "herb", "Wild Bush",       "farming",   1, "Pick", Color(0.72, 0.22, 0.52)],
]
const PICK_RECT_ROCK := Vector2(32, 26)
## Handoff contract: hp (of 20) → expected 2D frame, per key. Depleted is tested separately.
const HP_FRAMES := {
	"ore":             [[20, 0], [15, 1], [10, 2], [5, 3]],
	"herb_patch":      [[20, 0], [16, 1], [10, 2], [5, 3]],
	"mushroom_patch":  [[20, 0], [12, 1], [6, 2]],
	"berry_bush":      [[20, 0], [14, 1], [12, 2], [10, 3], [8, 4], [6, 5], [4, 6], [2, 7]],
	"moonbloom_patch": [[20, 0], [10, 1], [5, 2]],
	"wild_bush":       [[20, 0], [10, 1], [5, 2]],
	"ancient_root":    [[20, 0], [5, 0]],
}
const DEPLETED_FRAME := {"ore": 4, "herb_patch": 4, "mushroom_patch": 3, "berry_bush": 8,
	"moonbloom_patch": 3, "wild_bush": 3, "ancient_root": 1}
## Handoff 3D visible-node lists per frame (everything else hidden).
const MASKS := {
	"mushroom_patch": [["Soil", "BigMushroom", "SmallMushroom", "TinyMushroom"], ["Soil", "BigMushroom", "SmallMushroom"], ["Soil", "BigMushroom"], ["Soil"]],
	"moonbloom_patch": [["Soil", "Clump0", "Clump1", "Clump2", "Flower"], ["Soil", "Clump0", "Clump1"], ["Soil", "Clump0"], ["Soil"]],
	"wild_bush": [["Soil", "Clump0", "Clump1", "Clump2", "Flower"], ["Soil", "Clump0", "Clump1"], ["Soil", "Clump0"], ["Soil"]],
	"ancient_root": [["Soil", "Root", "Runes"], ["Soil"]],
}

var _mode := "2d"
var _out := ""
var _expect := {"ores": true, "forage": true}
var _checks: Array[Dictionary] = []
var _perf: Array[Dictionary] = []
var _fails := 0
var _stage_origin := Vector2.ZERO
var _spawn_seq := 0

func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--res-mode="): _mode = a.trim_prefix("--res-mode=")
		elif a.begins_with("--res-out="): _out = a.trim_prefix("--res-out=")
	_expect["ores"] = not ("--procedural-ores" in OS.get_cmdline_user_args())
	_expect["forage"] = not ("--procedural-forage" in OS.get_cmdline_user_args())
	DirAccess.make_dir_recursive_absolute(_out)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()

# ── helpers ─────────────────────────────────────────────────────────────────
func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks.append({"name": label, "ok": ok, "detail": detail})
	if not ok: _fails += 1
	print("RES_CHECK|%s|%s|%s" % [label, "PASS" if ok else "FAIL", detail])

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true).timeout

func _frames(n: int) -> void:
	for _i in range(n): await get_tree().process_frame

func _still(label: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null: img.save_png(_out.path_join(label + ".png"))

func _sample_perf(label: String) -> void:
	var p := {"label": label,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"texture_mem_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"buffer_mem_mb": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0,
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"static_mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT)}
	_perf.append(p)
	print("RES_PERF|", JSON.stringify(p))

func _is_2d() -> bool:
	return get_tree().current_scene != null and get_tree().current_scene.scene_file_path == WORLD_2D

func _player() -> Node2D:
	return get_tree().get_first_node_in_group("player") as Node2D

func _park(px: Vector2) -> void:
	var pl := _player()
	if pl == null: return
	pl.global_position = px
	pl.set("_target_pos", px)
	if _is_2d():
		pl.visible = false
		var cam := pl.get_node_or_null("Camera2D") as Camera2D
		if cam != null: cam.reset_smoothing()
	else:
		var spr := get_tree().current_scene.get("_player_spr") as Node3D
		if spr != null and spr.visible: spr.visible = false
	var hud := get_tree().get_first_node_in_group("hud") as CanvasLayer
	if hud != null and hud.visible: hud.visible = false

func _load_world(path: String) -> bool:
	get_tree().change_scene_to_file(path)
	var waited := 0.0
	while waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		var cs := get_tree().current_scene
		if cs == null or cs.scene_file_path != path: continue
		if path == WORLD_3D and not bool(cs.get("_spawned")) and cs.has_method("_on_login_ok"):
			cs.call("_on_login_ok", {})
			var ls := cs.get("_loading") as Node
			if ls != null and is_instance_valid(ls) and ls.has_method("_dismiss"): ls.call("_dismiss")
		if _player() != null: break
	_check("world_loaded:" + path.get_file(), _player() != null, "player after %.1fs" % waited)
	if _player() == null: return false
	await _wait(1.5)
	return true

func _spawn(row: Array, px: Vector2, col: Color = Color(-1, -1, -1)) -> Dictionary:
	var c: Color = row[6] if col.r < 0.0 else col
	_spawn_seq += 1
	var id := "qa:res:%d" % _spawn_seq
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

func _family(key: String) -> String:
	return "ores" if key.ends_with("_rock") or key == "gold_vein" else "forage"

func _frames_key(key: String) -> String:
	return "ore" if _family(key) == "ores" else key

func _authored_3d(v: Node3D) -> bool:
	return v != null and v.has_meta("resource_asset")

func _visible_names(v: Node3D) -> Array:
	var out: Array = []
	for m: Node in v.find_children("*", "MeshInstance3D", true, false):
		if (m as MeshInstance3D).visible: out.append(str(m.name))
	out.sort()
	return out

func _expected_mask(key: String, frame: int) -> Array:
	var out: Array = []
	match key:
		"herb_patch":
			out = ["Soil"]
			for i in range(int([5, 4, 4, 3, 0][frame])): out.append("Frond%d" % i)
			if [true, true, false, false, false][frame]: out.append("Flower")
		"berry_bush":
			if frame >= 8: out = ["Soil"]
			else:
				out = ["Soil", "Canopy"]
				for i in range(9 - frame): out.append("Berry%d" % i)
		_:
			if MASKS.has(key): out = (MASKS[key][frame] as Array).duplicate()
			else:
				if frame >= 4: out = ["Depleted"]
				else:
					out = ["LiveRock"]
					for i in range(1, 4):
						if frame >= i: out.append("Crack%d" % i)
	out.sort()
	return out

func _check_frame(tag: String, n: Node2D, want: int) -> void:
	var got := int(n.get_meta("resource_frame", -1))
	_check(tag + ":2d_frame", got == want, "want %d got %d" % [want, got])

func _check_mask(tag: String, key: String, v: Node3D, frame: int) -> void:
	var want := _expected_mask(key, frame)
	var got := _visible_names(v)
	_check(tag + ":3d_mask", got == want, "frame %d want %s got %s" % [frame, want, got])

# ── scripted run ────────────────────────────────────────────────────────────
func _run() -> void:
	print("RES_HARNESS mode=%s expect=%s out=%s" % [_mode, _expect, _out])
	match _mode:
		"toggle": await _run_toggle()
		"vram":   await _run_vram()
		_:        await _run_states(WORLD_3D if _mode == "3d" else WORLD_2D)
	var summary := {"mode": _mode, "expect": _expect, "fails": _fails, "checks": _checks, "perf": _perf}
	var f := FileAccess.open(_out.path_join("summary.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(summary, "  "))
		f.close()
	print("RES_RESULT|fails=%d|checks=%d" % [_fails, _checks.size()])
	get_tree().quit(1 if _fails > 0 else 0)

func _run_states(path: String) -> void:
	if not await _load_world(path): return
	var two := path == WORLD_2D
	_stage_origin = GameManager.RESPAWN_POS + Vector2(-620, -40)
	_park(_stage_origin)
	await _wait(1.0)
	_sample_perf("settled")
	if not two:
		var cs := get_tree().current_scene
		cs.set("_cam_dist", 7.0)
		cs.set("_cam_pitch", 0.60)
	for row: Array in ROWS: await _asset_states(row, two)
	await _tints_and_fallbacks(two)
	await _group_still(two)
	_sample_perf("end")

func _asset_states(row: Array, two: bool) -> void:
	var key := str(row[0])
	var fam := _family(key)
	var expect: bool = _expect[fam]
	var ent := _spawn(row, _stage_origin)
	var n := ent["n"] as Node2D
	var v := ent["v"] as Node3D
	_park(_stage_origin + Vector2(0, 2))
	await _frames(3)
	_check(key + ":package", ResourceArt.available(key) == expect, "ResourceArt.available=%s" % ResourceArt.available(key))
	if two and expect:
		_check(key + ":2d_mipmap_filter", n.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, "")
	if not two:
		_check(key + ":3d_visual", v != null and _authored_3d(v) == expect,
			"%s visual" % ("authored" if _authored_3d(v) else ("procedural" if v != null else "NO")))
	# Picking area is logic-side and untouched by the art swap.
	var cs2 := n.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var size: Vector2 = (cs2.shape as RectangleShape2D).size if cs2 != null and cs2.shape is RectangleShape2D else Vector2.ZERO
	if row[1] == "rock": _check(key + ":pick_area", size == PICK_RECT_ROCK, "got %s" % size)
	else: _check(key + ":pick_area", size.x > 0.0, "got %s (herb default)" % size)
	# Drive every sheet column with a temporary 20-hp node (play uses max_hp 1).
	n.set("_max_hp", 20)
	var fk := _frames_key(key)
	for pair: Array in HP_FRAMES[fk]:
		n.set("_hp", int(pair[0]))
		n.queue_redraw()
		await _frames(3)
		if expect:
			if two: _check_frame("%s:hp%d" % [key, int(pair[0])], n, int(pair[1]))
			elif v != null: _check_mask("%s:hp%d" % [key, int(pair[0])], key, v, int(pair[1]))
		await _still("%s_hp%02d_f%d" % [key, int(pair[0]), int(pair[1])])
	if key == "ancient_root" and expect and two:
		_check(key + ":2d_rune_overlay", int(n.get_meta("resource_overlay", -1)) == 2, "overlay frame meta")
	n.set("_hp", 1)
	n.call("_deplete")
	n.queue_redraw()
	await _frames(3)
	_check(key + ":depleted_state", int(n.get("_state")) == 2, "state=%s" % n.get("_state"))
	var df := int(DEPLETED_FRAME[fk])
	if expect:
		if two: _check_frame(key + ":depleted", n, df)
		elif v != null: _check_mask(key + ":depleted", key, v, df)
	await _still("%s_depleted" % key)
	n.call("_respawn")
	n.set("_max_hp", 1)
	n.set("_hp", 1)
	n.queue_redraw()
	await _frames(3)
	_check(key + ":respawned", int(n.get("_state")) == 0 and n.visible, "state=%s" % n.get("_state"))
	_park(n.position + Vector2(0, 2))
	await _frames(2)
	if expect:
		if two: _check_frame(key + ":respawned", n, 0)
		elif v != null: _check_mask(key + ":respawned", key, v, 0)
	await _still("%s_respawned" % key)
	if not two and v != null and expect: await _closeup(key, n)
	n.queue_free()
	await _frames(2)

func _closeup(key: String, n: Node2D) -> void:
	var cs := get_tree().current_scene
	for k in range(4):
		cs.set("_cam_yaw", float(k) * PI * 0.5)
		_park(n.position + Vector2(0, 2))
		await _wait(0.4)
		await _still("%s_close_yaw%d" % [key, k * 90])
	cs.set("_cam_yaw", 0.0)

func _tints_and_fallbacks(two: bool) -> void:
	var y := _stage_origin.y
	var x := _stage_origin.x - 120.0
	# Catalog colour → untinted; admin override → relative tint.
	_check("copper_rock:catalog_untinted", ResourceArt.tint_for("copper_rock", ROWS[0][6]).is_equal_approx(Color.WHITE), "")
	_check("herb_patch:catalog_untinted", ResourceArt.tint_for("herb_patch", ROWS[6][6]).is_equal_approx(Color.WHITE), "")
	_check("copper_rock:tint_ratio", not ResourceArt.tint_for("copper_rock", Color(0.3, 0.6, 0.8)).is_equal_approx(Color.WHITE), "")
	# Level-range dispatch for rocks (custom name, level decides).
	_check("rock:dispatch_by_level", ResourceArt.asset_for("rock", "Weird Rock", 55) == "mithril_rock"
		and ResourceArt.asset_for("rock", "Weird Rock", 85) == "runite_rock" and ResourceArt.asset_for("rock", "Weird Rock", 0) == "copper_rock", "")
	# Unknown herb name keeps the procedural draw.
	_check("herb:unknown_name_fallback", ResourceArt.asset_for("herb", "Glowcap", 1) == "", "")
	var tinted := _spawn(ROWS[0], Vector2(x, y), Color(0.30, 0.60, 0.80))
	var plain := _spawn(ROWS[0], Vector2(x + 60.0, y))
	var custom := _spawn(["x", "herb", "Glowcap", "farming", 1, "Pick", Color(0.4, 0.9, 0.9)], Vector2(x + 120.0, y))
	await _frames(3)
	if two and _expect["forage"]:
		_check("herb:unknown_name_procedural_2d", int((custom["n"] as Node2D).get_meta("resource_frame", -1)) == -1, "")
	if not two and _expect["ores"]:
		var tv := tinted["v"] as Node3D
		var pv := plain["v"] as Node3D
		_check("copper_rock:3d_tint_override", tv != null and _has_override(tv) and pv != null and not _has_override(pv), "")
	if not two and _expect["forage"]:
		_check("herb:unknown_name_procedural_3d", not _authored_3d(custom["v"] as Node3D), "")
	_park(Vector2(x + 60.0, y + 2))
	await _frames(2)
	await _still("tint_and_fallback")

func _has_override(v: Node3D) -> bool:
	for m: Node in v.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in range(mi.mesh.get_surface_count()):
			if mi.get_surface_override_material(i) != null: return true
	return false

func _group_still(two: bool) -> void:
	var y := _stage_origin.y + 120.0
	var x := _stage_origin.x - 200.0
	for r: Array in ROWS:
		_spawn(r, Vector2(x, y))
		x += 40.0
	_park(Vector2(_stage_origin.x + 20.0, y + 2))
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
	if not await _load_world(path): return
	_stage_origin = GameManager.RESPAWN_POS + Vector2(-620, -40)
	for n in range(4):
		var pl := _player()
		GameManager.switch_pos = pl.global_position if pl != null else Vector2(-1, -1)
		path = WORLD_3D if path == WORLD_2D else WORLD_2D
		var t0 := Time.get_ticks_msec()
		var ok := await _load_world(path)
		var tag := "toggle_%d_%s" % [n, "3d" if path == WORLD_3D else "2d"]
		_check(tag + ":scene_ready", ok, "%d ms" % (Time.get_ticks_msec() - t0))
		if not ok: return
		_park(_stage_origin)
		var rock := _spawn(ROWS[5], _stage_origin)                      # Runite: halo + runite palette
		var root := _spawn(ROWS[10], _stage_origin + Vector2(48, 20))   # Ancient Root: rune pulse
		await _frames(3)
		var rn := rock["n"] as Node2D
		if path == WORLD_2D:
			_check(tag + ":2d_authored", (rn.get_meta("resource_frame", -1) == 0) == _expect["ores"], "")
		else:
			_check(tag + ":3d_authored", _authored_3d(rock["v"] as Node3D) == _expect["ores"]
				and _authored_3d(root["v"] as Node3D) == _expect["forage"], "")
		rn.call("_deplete")
		rn.queue_redraw()
		(root["n"] as Node2D).call("_deplete")
		(root["n"] as Node2D).queue_redraw()
		await _frames(2)
		_check(tag + ":depleted_in_mode", int(rn.get("_state")) == 2 and int((root["n"] as Node2D).get("_state")) == 2, "")
		await _still(tag)
		_sample_perf(tag)

## Memory in real towns and a synthetic quarry+garden, both renderers.
func _run_vram() -> void:
	for path: String in [WORLD_2D, WORLD_3D]:
		var m := "2d" if path == WORLD_2D else "3d"
		if not await _load_world(path): return
		_park(GameManager.RESPAWN_POS)
		await _wait(3.0)
		_sample_perf(m + ":bjorns_spawn")
		await _still(m + "_bjorns")
		_park(KJELVIK_CENTER)
		await _wait(3.0)
		_sample_perf(m + ":kjelvik")
		await _still(m + "_kjelvik")
		var rng := RandomNumberGenerator.new()
		rng.seed = 1337
		for r: Array in ROWS:
			for _i in range(6):
				_spawn(r, KJELVIK_CENTER + Vector2(rng.randf_range(-260, 260), rng.randf_range(-180, 180)))
		await _wait(2.0)
		_sample_perf(m + ":kjelvik_plus_72")
		await _still(m + "_grove")
		GameManager.switch_pos = KJELVIK_CENTER
