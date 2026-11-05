extends Node
## In-game validation harness for Karl's authored art. SANDBOX ONLY — run through
## tools/art/capture_karl_ingame.ps1, which builds an isolated project copy with the
## offline network stub and a redirected user:// dir. Never referenced by the game.
##
## Lives on the tree root so it survives 2D<->3D scene switches. Loads the REAL
## world.tscn / world3d.tscn, frames Karl at the normal gameplay camera, drives him
## through each state via his own code paths (his timers, flash_hit(), the
## Events.npc_died / npc_respawned signals the server path emits), saves stills and
## prints `KARL_CHECK|name|PASS/FAIL|detail` lines plus a JSON summary.
##
## User args (after `--`): --karl-mode=2d|3d|toggle  --karl-out=<abs dir>
##                         [--procedural-karl] to capture the original for comparison.

const KarlArt = preload("res://scripts/art/KarlArt.gd")
const WORLD_2D := "res://world.tscn"
const WORLD_3D := "res://world3d.tscn"
const KARL_ID := "n:4"

var _mode := "2d"
var _out := ""
var _expect_authored := true
var _karl: Node2D = null
var _visual: Node3D = null
var _force := "none"           # none | idle | walk
var _walk_target := Vector2.ZERO
var _dialogue_seen := ""
var _checks: Array[Dictionary] = []
var _perf: Array[Dictionary] = []
var _fails := 0

func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--karl-mode="): _mode = a.trim_prefix("--karl-mode=")
		elif a.begins_with("--karl-out="): _out = a.trim_prefix("--karl-out=")
	_expect_authored = not ("--procedural-karl" in OS.get_cmdline_user_args())
	DirAccess.make_dir_recursive_absolute(_out)
	Events.npc_dialogue.connect(_on_dialogue)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()

func _on_dialogue(npc_name: String, _text: String) -> void:
	_dialogue_seen = npc_name

# ── per-frame: keep Karl in the phase's state + keep the camera on him ──────
func _process(_d: float) -> void:
	if _karl == null or not is_instance_valid(_karl):
		return
	match _force:
		"idle":
			_karl.set("_idle_timer", 99.0)
			_karl.set("_iv_next_t", float(_karl.get("_time")) + 99.0)
		"walk":
			_karl.set("_idle_timer", -1.0)
			_karl.set("_target", _walk_target)
	_frame_player()

func _frame_player() -> void:
	var pl := get_tree().get_first_node_in_group("player") as Node2D
	if pl == null or _karl == null or not is_instance_valid(_karl):
		return
	pl.global_position = _karl.global_position + Vector2(0, 2)   # camera centres on Karl
	pl.set("_target_pos", pl.global_position)                   # player stays put
	if _is_2d():
		pl.visible = false                                       # don't stand in front of him
	else:
		var spr := get_tree().current_scene.get("_player_spr") as Node3D
		if spr != null and spr.visible:
			spr.visible = false                                  # 3D player mesh, same reason
	# The default-open Chat/Combat panels sit exactly over screen centre (Karl).
	# Hide the HUD for review captures only; Karl's flash/HP bar draw in NPC._draw.
	var hud := get_tree().get_first_node_in_group("hud") as CanvasLayer
	if hud != null and hud.visible:
		hud.visible = false

func _is_2d() -> bool:
	return get_tree().current_scene != null and get_tree().current_scene.scene_file_path == WORLD_2D

## 3D: is Karl's visual the authored wrapper (vs the procedural rig)?
func _authored_3d() -> bool:
	return _visual != null and _visual.has_meta("village_asset")

# ── helpers ─────────────────────────────────────────────────────────────────
func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks.append({"name": label, "ok": ok, "detail": detail})
	if not ok:
		_fails += 1
	print("KARL_CHECK|%s|%s|%s" % [label, "PASS" if ok else "FAIL", detail])

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true).timeout

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
		"static_mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
	}
	_perf.append(p)
	print("KARL_PERF|", JSON.stringify(p))

func _load_world(path: String) -> bool:
	_karl = null
	_visual = null
	get_tree().change_scene_to_file(path)
	var waited := 0.0
	while waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		var cs := get_tree().current_scene
		if cs == null or cs.scene_file_path != path:
			continue
		# 3D: put World3D into its real post-login state — the same _on_login_ok a
		# live 2D->3D switch runs. Without it _spawned stays false and the per-frame
		# entity sync (position + `v.visible = n.visible`) never runs offline.
		if path == WORLD_3D and not bool(cs.get("_spawned")) and cs.has_method("_on_login_ok"):
			cs.call("_on_login_ok", {})
			# ...which shows the post-login loading page; press its Continue like a player.
			var ls := cs.get("_loading") as Node
			if ls != null and is_instance_valid(ls) and ls.has_method("_dismiss"):
				ls.call("_dismiss")
		if _karl == null:
			for n: Node in cs.find_children("*", "", true, false):
				if str(n.get("npc_name_str")) == "Karl" and str(n.get("npc_type")) == "worker":
					_karl = n as Node2D
					break
		if _karl != null and path == WORLD_3D and _visual == null:
			# World3D's own entity table → Karl's visual, authored OR procedural.
			var ent: Variant = cs.get("_ent")
			if ent is Dictionary and (ent as Dictionary).has(KARL_ID):
				_visual = ((ent as Dictionary)[KARL_ID] as Dictionary).get("v") as Node3D
		if _karl != null and (path == WORLD_2D or _visual != null):
			break
	_check("world_loaded:" + path.get_file(), _karl != null, "Karl found after %.1fs" % waited)
	if _karl == null:
		return false
	_force = "idle"
	_frame_player()
	var cam := get_tree().get_first_node_in_group("player").get_node_or_null("Camera2D") as Camera2D
	if cam != null:
		cam.reset_smoothing()
	await _wait(1.5)
	return true

## The clip the CURRENT mode is actually showing (2D: KarlArt.state; 3D: the
## AnimationPlayer's current animation).
func _shown_clip() -> String:
	if _is_2d():
		return str(KarlArt.state(_karl)["clip"])
	if _visual == null:
		return "<no visual>"
	var players := _visual.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		return "<no AnimationPlayer>"
	return (players[0] as AnimationPlayer).current_animation

func _expect_clip(tag: String, want: String) -> void:
	if not _expect_authored:
		return
	var got := _shown_clip()
	_check(tag + ":clip", got == want, "want %s got %s" % [want, got])

# ── scripted run ────────────────────────────────────────────────────────────
func _run() -> void:
	print("KARL_HARNESS mode=%s authored=%s out=%s" % [_mode, _expect_authored, _out])
	if _mode == "toggle":
		await _run_toggle()
	else:
		await _run_states(WORLD_3D if _mode == "3d" else WORLD_2D)
	var summary := {"mode": _mode, "authored_expected": _expect_authored,
		"fails": _fails, "checks": _checks, "perf": _perf}
	var f := FileAccess.open(_out.path_join("summary.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(summary, "  "))
		f.close()
	print("KARL_RESULT|fails=%d|checks=%d" % [_fails, _checks.size()])
	get_tree().quit(1 if _fails > 0 else 0)

func _run_states(path: String) -> void:
	if not await _load_world(path):
		return
	var two := path == WORLD_2D
	_check("package_available", KarlArt.available() == _expect_authored,
		"KarlArt.available()=%s" % KarlArt.available())
	if two and _expect_authored:
		_check("2d_linear_filter", _karl.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
			"authored draw path ran")
	if not two:
		_check("3d_visual", _visual != null and _authored_3d() == _expect_authored,
			"%s visual" % ("authored" if _authored_3d() else ("procedural" if _visual != null else "NO")))
	_sample_perf("settled")
	var home := _karl.position

	_force = "idle"
	await _wait(1.0)
	_expect_clip("idle", "idle")
	await _still("01_idle")

	# Walking in four directions (exercises sheet rows in 2D, facing in 3D).
	var dirs := [["walk_left", Vector2(-1, 0), 1], ["walk_right", Vector2(1, 0), 3],
		["walk_front", Vector2(0, 1), 0], ["walk_back", Vector2(0, -1), 2]]
	var i := 2
	for d: Array in dirs:
		_walk_target = _karl.position + (d[1] as Vector2) * 120.0
		_force = "walk"
		await _wait(1.3)
		_expect_clip(str(d[0]), "walk")
		if two and _expect_authored:
			var row := int(_karl.get_meta("karl_row", -1))
			_check(str(d[0]) + ":row", row == int(d[2]), "want row %d got %d" % [int(d[2]), row])
		await _still("%02d_%s" % [i, str(d[0])])
		i += 1
	_force = "idle"
	await _wait(0.8)

	# Idle variations through the NPC's own 1.2 s timer.
	var variations := [["look_left", 1, -1.0], ["look_right", 1, 1.0], ["arms_crossed", 2, 1.0]]
	for v: Array in variations:
		var t := float(_karl.get("_time"))
		_karl.set("_iv_kind", int(v[1]))
		_karl.set("_iv_dir", float(v[2]))
		_karl.set("_iv_end_t", t + 1.2)
		await _wait(0.55)
		_expect_clip(str(v[0]), str(v[0]))
		await _still("%02d_%s" % [i, str(v[0])])
		i += 1
		await _wait(0.9)
		_check(str(v[0]) + ":ends_on_npc_timer", int(_karl.get("_iv_kind")) == 0,
			"variation released by NPC timer")

	# Hit: real flash_hit(); reaction must not outlast the original 0.18 s flash.
	_karl.call("flash_hit")
	await get_tree().process_frame
	await get_tree().process_frame   # 3D: let the visual's _process pick the hit up
	_expect_clip("hit", "hit")
	await _still("%02d_hit" % i)
	i += 1
	await _wait(0.25)
	_check("hit:flash_window_unchanged", float(_karl.get("_hit_flash")) <= 0.0,
		"flash cleared within 0.25 s (orig 0.18 s)")
	_expect_clip("after_hit", "idle")

	# Dialogue via the real interaction handler.
	_dialogue_seen = ""
	_karl.call("_on_player_interacted", _karl)
	await get_tree().process_frame
	_check("dialogue", _dialogue_seen == "Karl", "npc_dialogue from '%s'" % _dialogue_seen)

	# Picking / collision: logic-side shapes are untouched by the art swap.
	var shapes := _karl.find_children("*", "CollisionShape2D", true, false)
	_check("collision_shape_present", not shapes.is_empty(), "%d shape(s)" % shapes.size())
	if not two and _visual != null:
		var want := Vector3(_karl.position.x / 32.0, _visual.position.y, _karl.position.y / 32.0)
		_check("3d_visual_tracks_logic", _visual.position.distance_to(want) < 0.05,
			"visual %s vs logic %s" % [_visual.position, want])

	# Death: the server path hides immediately — never waits for a clip.
	Events.npc_died.emit(str(_karl.get("entity_id")))
	_check("death:2d_logic_hidden_same_frame", not _karl.visible and not bool(_karl.get("is_alive")),
		"visible=%s alive=%s" % [_karl.visible, _karl.get("is_alive")])
	if not two and _visual != null:
		var frames := 0
		while _visual.visible and frames < 10:
			await get_tree().process_frame
			frames += 1
		_check("death:3d_hidden_within_1_frame", not _visual.visible and frames <= 1,
			"hidden after %d frame(s)" % frames)
		var shown := _shown_clip()
		_check("death:clip_not_played", shown != "death", "current=%s" % shown)
	await _still("%02d_dead" % i)
	i += 1
	await _wait(0.4)
	Events.npc_respawned.emit(str(_karl.get("entity_id")))
	await _wait(0.6)
	_check("respawn:visible_at_home", _karl.visible and _karl.position.distance_to(home) < 200.0,
		"visible=%s pos=%s" % [_karl.visible, _karl.position])
	if not two and _visual != null:
		_check("respawn:3d_visible", _visual.visible, "")
	_expect_clip("respawned", "idle")
	await _still("%02d_respawned" % i)
	if not two:
		await _closeups()
	else:
		await _zoom_stills()
	_sample_perf("end")

func _run_toggle() -> void:
	var path := WORLD_2D
	if not await _load_world(path):
		return
	_sample_perf("start_2d")
	for n in range(6):
		var moving := n % 2 == 1
		var pl := get_tree().get_first_node_in_group("player") as Node2D
		if moving:
			_walk_target = _karl.position + Vector2(100, 40)
			_force = "walk"
			await _wait(0.5)
		var carry := pl.global_position if pl != null else Vector2(-1, -1)
		GameManager.switch_pos = carry
		path = WORLD_3D if path == WORLD_2D else WORLD_2D
		var t0 := Time.get_ticks_msec()
		var ok := await _load_world(path)
		var tag := "toggle_%d_%s_%s" % [n, "3d" if path == WORLD_3D else "2d",
			"moving" if moving else "still"]
		_check(tag + ":karl_present", ok, "scene ready in %d ms" % (Time.get_ticks_msec() - t0))
		if not ok:
			return
		if path == WORLD_2D:
			_check(tag + ":2d_authored", (_karl.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR) == _expect_authored,
				"authored draw active=%s" % (_karl.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR))
		else:
			_check(tag + ":3d_authored", _visual != null and _authored_3d() == _expect_authored, "")
			if _visual != null:
				_check(tag + ":3d_visible", _visual.visible, "")
		_force = "walk" if moving else "idle"
		if moving:
			_walk_target = _karl.position + Vector2(-100, 30)
		await _wait(0.6)
		_expect_clip(tag, "walk" if moving else "idle")
		await _still(tag)
		_sample_perf(tag)
		_force = "idle"

## 3D detail review: the default camera (dist 24) leaves Karl ~20 px tall, so also
## capture a few states with the orbit pulled in close and lowered.
func _closeups() -> void:
	var cs := get_tree().current_scene
	cs.set("_cam_dist", 7.0)
	cs.set("_cam_pitch", 0.62)          # high enough to see over Kjelvik's roofs
	_force = "idle"
	# 360-degree turnaround of the model at rest.
	var yaws := [0.0, PI * 0.5, PI, PI * 1.5]
	for k in range(yaws.size()):
		cs.set("_cam_yaw", float(yaws[k]))
		await _wait(0.6)
		await _still("close_idle_yaw%d" % (k * 90))
	cs.set("_cam_yaw", PI * 0.5)        # side-on for the action states
	var t := float(_karl.get("_time"))
	_karl.set("_iv_kind", 2)
	_karl.set("_iv_end_t", t + 1.2)
	await _wait(0.6)
	await _still("close_arms_crossed")
	await _wait(0.8)
	_karl.call("flash_hit")
	await get_tree().process_frame
	await get_tree().process_frame
	await _still("close_hit")
	await _wait(0.4)
	_walk_target = _karl.position + Vector2(0, 120)
	_force = "walk"
	await _wait(1.0)
	await _still("close_walk")
	_force = "idle"
	cs.set("_cam_dist", 24.0)
	cs.set("_cam_pitch", 0.82)
	cs.set("_cam_yaw", 0.0)

## 2D: players can zoom out (Player clamps zoom to 0.5..3.0). The sheets are
## imported without mipmaps, so check how Karl holds up when minified hard.
func _zoom_stills() -> void:
	var cam := get_tree().get_first_node_in_group("player").get_node_or_null("Camera2D") as Camera2D
	if cam == null:
		return
	_force = "idle"
	for z: float in [1.2, 0.6]:
		cam.zoom = Vector2(z, z)
		await _wait(0.5)
		await _still("zoom_%s" % str(z).replace(".", "_"))
	cam.zoom = Vector2(2.5, 2.5)
