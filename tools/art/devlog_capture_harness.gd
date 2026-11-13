extends Node
## Devlog before/after capture on the REAL map. SANDBOX ONLY — run through
## tools/art/capture_devlog_forest.ps1 (isolated project copy, offline network stub,
## redirected user://). Never referenced by the game.
##
## The real admin map is rebuilt offline by replaying a DB-snapshot JSON (made by
## export_db_snapshot.py from a COPY of a server backup) into NetworkManager's
## login-burst caches BEFORE the world scene loads; World/World3D then rebuild the
## painted tiles, admin entities, edits and sculpted heights exactly as after a
## 2D<->3D switch.
##
## Modes (user args after `--`):
##   --devlog-mode=scout   pick one camera spot just outside each village with the
##                         densest cluster of the batch's trees -> spots.json
##   --devlog-mode=record  --devlog-town=<key> --devlog-spot=x,y --devlog-renderer=2d|3d
##                         park the camera, settle, save CLIP_FRAMES PNG frames.
##   --devlog-out=<abs dir>  --devlog-snapshot=<abs json>  [--procedural-forest] (= "old")

const WORLD_2D := "res://world.tscn"
const WORLD_3D := "res://world3d.tscn"
const CHUNK_PX := 512
const TILE := 32
const COLS := 300
const ROWS := 520
## Safe-zone rects from World._SAFE_ZONES (town bounds + 15-tile margin).
const TOWNS := {
	"kjelvik":        Rect2(1984, 3008, 1376, 1376),
	"frostheim":      Rect2( 704,  256, 1376, 1376),
	"ironwood_keep":  Rect2(2880, 4288, 1376, 1376),
	"eastmark_post":  Rect2(5248, 5184, 1376, 1376),
	"bjorns_landing": Rect2(7200, 3744, 1376, 1376),
	"bjorns_landing_north": Rect2(7200, 3744, 1376, 1376),   # same town, north side only
}
## Optional side constraint: the camera centre must lie on that side of the town bounds.
const SCOUT_SIDE := {"bjorns_landing_north": "north"}
const TOWN_MARGIN := 480.0          # safe zone = town bounds grown by this
## How far outside the town bounds the scout may look (world px). Bjorn's Landing
## sits in plains/oak country, so its batch trees are further out.
const SCOUT_BAND := {"default": 760.0, "bjorns_landing_north": 1100.0}   # (1500 all-round for bjorns only finds far-off mountain pines)
## Default family (1.7.2 forest). --devlog-species=<comma names> and
## --devlog-types=<comma type_strs> override these for other families.
const BATCH_TREES := ["Pine Tree", "Cherry Tree", "Ironwood Tree", "Frost Tree", "Ancient Tree"]
const BATCH_TYPES_DEFAULT := ["tree"]
const MINOR_TYPE_DEFAULT := "stick"   # half-weight extra of the default family
const ZOOM := 2.0                   # 2D camera zoom for the clips (gameplay range 0.5-3.0)
const FOOT := Vector2(540, 480)     # world px visible at 1080x960 / ZOOM
const CLIP_FRAMES := 150            # 5 s at 30 fps
const SETTLE_SEC := 3.0
const CAM3D := {"dist": 15.0, "pitch": 0.62, "yaw": 0.35}

var _mode := "scout"
var _out := ""
var _snapshot := ""
var _town := ""
var _spot := Vector2(-1, -1)
var _renderer := "2d"
var _procedural := false
var _look := Vector2.ZERO           # tree-cluster centroid relative to the spot (from scout)
var _towns_filter: PackedStringArray = []   # scout only these keys (empty = all)
var _species: Array = BATCH_TREES           # display names that count as the batch
var _types: Array = BATCH_TYPES_DEFAULT     # type_strs the species belong to
var _minor_type := MINOR_TYPE_DEFAULT       # half-weight pickup type ("" = none)

func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--devlog-mode="): _mode = a.trim_prefix("--devlog-mode=")
		elif a.begins_with("--devlog-out="): _out = a.trim_prefix("--devlog-out=")
		elif a.begins_with("--devlog-snapshot="): _snapshot = a.trim_prefix("--devlog-snapshot=")
		elif a.begins_with("--devlog-town="): _town = a.trim_prefix("--devlog-town=")
		elif a.begins_with("--devlog-renderer="): _renderer = a.trim_prefix("--devlog-renderer=")
		elif a.begins_with("--devlog-species="):
			_species = Array(a.trim_prefix("--devlog-species=").split(",", false))
			_minor_type = ""
		elif a.begins_with("--devlog-types="):
			_types = Array(a.trim_prefix("--devlog-types=").split(",", false))
		elif a.begins_with("--devlog-towns="):
			_towns_filter = a.trim_prefix("--devlog-towns=").split(",", false)
		elif a.begins_with("--devlog-look="):
			var l := a.trim_prefix("--devlog-look=").split(",")
			if l.size() == 2:
				_look = Vector2(float(l[0]), float(l[1]))
		elif a.begins_with("--devlog-spot="):
			var p := a.trim_prefix("--devlog-spot=").split(",")
			if p.size() == 2:
				_spot = Vector2(float(p[0]), float(p[1]))
	_procedural = "--procedural-forest" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(_out)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_replay_snapshot()
	_run.call_deferred()

## Feed the DB snapshot through NetworkManager's own dispatcher so every cache
## (world_entities / tile_overrides / entity_edits / terrain_heights / road graph)
## is populated exactly as after a real login burst.
func _replay_snapshot() -> void:
	if _snapshot.is_empty() or not FileAccess.file_exists(_snapshot):
		push_error("DEVLOG: snapshot missing: " + _snapshot)
		return
	var txt := FileAccess.get_file_as_string(_snapshot)
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_error("DEVLOG: snapshot unreadable")
		return
	var msgs: Array = (parsed as Dictionary).get("messages", [])
	for m: Variant in msgs:
		if m is Dictionary:
			NetworkManager.call("_handle", m as Dictionary)
	print("DEVLOG_SNAPSHOT|", JSON.stringify((parsed as Dictionary).get("counts", {})))

# ── helpers (same approach as forest_ingame_harness) ─────────────────────────
func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true).timeout

func _is_2d() -> bool:
	return get_tree().current_scene != null and get_tree().current_scene.scene_file_path == WORLD_2D

func _player() -> Node2D:
	return get_tree().get_first_node_in_group("player") as Node2D

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
			cam.zoom = Vector2(ZOOM, ZOOM)
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
	while waited < 30.0:
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
	print("DEVLOG_WORLD|%s|%s|%.1fs" % [path.get_file(), "ok" if _player() != null else "FAIL", waited])
	return _player() != null

func _run() -> void:
	print("DEVLOG_HARNESS mode=%s renderer=%s procedural=%s town=%s spot=%s" % [_mode, _renderer, _procedural, _town, _spot])
	if _mode == "scout":
		await _scout()
	else:
		await _record()
	get_tree().quit(0)

# ── scout ────────────────────────────────────────────────────────────────────
## Replicates World._spawn_chunk_resources' deterministic RNG stream (same seed,
## same attempt loop, the real _resource_data + Ground.biome_at_world) so every
## seeded resource position is known without streaming the chunks in. Admin
## deletions/moves (entity_edits) and admin-placed trees (world_entities) are
## applied on top — the result is the real map's resource layout.
func _seeded_resources(region: Rect2, cs: Node, ground: Node) -> Array:
	var out: Array = []
	var deleted: Dictionary = cs.get("_deleted_ids")
	var moved: Dictionary = cs.get("_moved")
	var attempts := 8   # World.RES_ATTEMPTS (resource spawn attempts per chunk)
	var c0 := Vector2i(floori(region.position.x / CHUNK_PX), floori(region.position.y / CHUNK_PX))
	var c1 := Vector2i(floori(region.end.x / CHUNK_PX), floori(region.end.y / CHUNK_PX))
	for cx in range(c0.x, c1.x + 1):
		for cy in range(c0.y, c1.y + 1):
			var rng := RandomNumberGenerator.new()
			rng.seed = (cx * 7919 + cy * 6271) ^ 0xA3C5F1
			var ox := float(cx * CHUNK_PX)
			var oy := float(cy * CHUNK_PX)
			for i in range(attempts):
				var pos := Vector2(
					clampf(ox + rng.randf() * CHUNK_PX, 64, COLS * TILE - 64),
					clampf(oy + rng.randf() * CHUNK_PX, 64, ROWS * TILE - 64))
				var biome: String = ground.call("biome_at_world", pos)
				var d: Array = cs.call("_resource_data", biome, pos, rng, ground)
				if d.size() == 0:
					continue
				var id := "r:%d:%d:%d" % [cx, cy, i]
				if deleted.has(id):
					continue
				if moved.has(id):
					pos = moved[id]
				out.append({"id": id, "type": str(d[0]), "name": str(d[1]), "pos": pos, "biome": biome})
	for e: Variant in NetworkManager.world_entities_cache:
		if not (e is Dictionary):
			continue
		var ent := e as Dictionary
		if str(ent.get("kind", "")) != "resource":
			continue
		var data: Dictionary = ent.get("data", {}) if ent.get("data") is Dictionary else {}
		var pos := Vector2(float(ent.get("x", 0)), float(ent.get("y", 0)))
		if region.has_point(pos):
			out.append({"id": str(ent.get("id", "")), "type": str(data.get("type_str", ent.get("subtype", ""))),
				"name": str(data.get("display_name", "")), "pos": pos, "biome": "admin"})
	return out

func _score_at(center: Vector2, res: Array) -> Dictionary:
	var view := Rect2(center - FOOT * 0.5, FOOT)
	var inner := Rect2(center - FOOT * 0.35, FOOT * 0.7)   # weight the middle of frame
	var batch := 0
	var sticks := 0
	var oaks := 0
	var score := 0.0
	var names := {}
	var centroid := Vector2.ZERO
	for r: Variant in res:
		var rd := r as Dictionary
		var p: Vector2 = rd["pos"]
		if not view.has_point(p):
			continue
		var w := 1.0 if inner.has_point(p) else 0.6
		if rd["type"] in _types:
			if rd["name"] in _species:
				batch += 1
				score += 1.0 * w
				centroid += p - center
				names[rd["name"]] = int(names.get(rd["name"], 0)) + 1
			else:
				oaks += 1              # same type, not in the batch (e.g. Oak)
				score += 0.15 * w
		elif _minor_type != "" and rd["type"] == _minor_type:
			sticks += 1
			score += 0.5 * w
	if batch > 0:
		centroid /= float(batch)
	return {"score": score, "batch_trees": batch, "sticks": sticks, "oaks": oaks, "species": names,
		"look_x": centroid.x, "look_y": centroid.y}

func _scout() -> void:
	if not await _load_world(WORLD_2D):
		return
	await _wait(2.0)
	var cs := get_tree().current_scene
	var ground := cs.get_node("Ground")
	# Merge into an existing spots.json so a single-town re-scout keeps the others.
	var spots := {}
	var prev_path := _out.path_join("spots.json")
	if FileAccess.file_exists(prev_path):
		var prev: Variant = JSON.parse_string(FileAccess.get_file_as_string(prev_path))
		if prev is Dictionary and (prev as Dictionary).get("spots") is Dictionary:
			spots = (prev as Dictionary)["spots"]
	for key: String in TOWNS.keys():
		if not _towns_filter.is_empty() and not (key in _towns_filter):
			continue
		var safe: Rect2 = TOWNS[key]
		var side := str(SCOUT_SIDE.get(key, ""))
		var core := safe.grow(-TOWN_MARGIN)              # the town bounds proper
		var band_out := core.grow(float(SCOUT_BAND.get(key, SCOUT_BAND["default"])))
		var res := _seeded_resources(band_out.grow(FOOT.x), cs, ground)
		var best := {"score": -1.0}
		var best_pos := core.get_center()
		var step := 32.0
		var x := band_out.position.x
		while x <= band_out.end.x:
			var y := band_out.position.y
			while y <= band_out.end.y:
				var c := Vector2(x, y)
				var view := Rect2(c - FOOT * 0.5, FOOT)
				# "Just outside": the frame must sit outside the town bounds, but may
				# touch them so a wall/edge gives context. Keep the centre off-town and
				# the overlap with the town small.
				var inter := view.intersection(core)
				var overlap := (inter.get_area() / view.get_area()) if inter.has_area() else 0.0
				var outside_core := not core.has_point(c)
				if side == "north" and c.y + FOOT.y * 0.5 > core.position.y:
					outside_core = false            # whole frame must sit north of the town
				if outside_core and overlap <= 0.2 and view.intersects(core.grow(band_out.size.x * 0.5 - core.size.x * 0.5 - 120.0)):
					var s := _score_at(c, res)
					# prefer variety and a stick in frame; tie-break towards the town
					var sc: float = s["score"] + 0.4 * float((s["species"] as Dictionary).size())
					sc -= 0.0004 * c.distance_to(core.get_center())
					if sc > float(best["score"]):
						best = s.duplicate()
						best["score"] = sc
						best_pos = c
				y += step
			x += step
		best["x"] = best_pos.x
		best["y"] = best_pos.y
		best["biome"] = ground.call("biome_at_world", best_pos)
		spots[key] = best
		print("DEVLOG_SPOT|%s|%.0f|%.0f|score=%.2f|batch=%d sticks=%d oaks=%d species=%s biome=%s" % [
			key, best_pos.x, best_pos.y, float(best["score"]), int(best["batch_trees"]),
			int(best["sticks"]), int(best["oaks"]), JSON.stringify(best["species"]), str(best["biome"])])
	var f := FileAccess.open(_out.path_join("spots.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"zoom": ZOOM, "footprint": [FOOT.x, FOOT.y], "spots": spots}, "  "))
		f.close()

# ── record ───────────────────────────────────────────────────────────────────
func _record() -> void:
	if _spot.x < 0.0:
		push_error("DEVLOG: --devlog-spot missing")
		return
	seed(4242)                            # stable 3D jitter / ambient picks per run
	GameManager.switch_pos = _spot        # world streams around the spot from frame 0
	var path := WORLD_3D if _renderer == "3d" else WORLD_2D
	if not await _load_world(path):
		return
	# 2D: the camera centre IS the scouted spot. 3D: the perspective camera shows
	# much less ground around its target, so centre it on the tree cluster
	# (scout centroid) instead and orbit in from the opposite side. Both are
	# deterministic per spot, so old/new always get the identical camera.
	var center := _spot if _renderer == "2d" else _spot + _look * 0.7
	_park(center)
	var cam3d := CAM3D.duplicate()
	if _renderer == "3d":
		await _wait(0.5)            # terrain heights applied → pick a yaw that clears the hills
		_park(center)
		cam3d = _pick_cam3d(get_tree().current_scene)
	await _wait(SETTLE_SEC)
	_park(center)
	await get_tree().process_frame
	var frames_dir := _out.path_join("frames")
	DirAccess.make_dir_recursive_absolute(frames_dir)
	var size := Vector2i.ZERO
	for i in range(CLIP_FRAMES):
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if img == null:
			continue
		size = img.get_size()
		img.save_png(frames_dir.path_join("%04d.png" % i))
	var meta := {
		"town": _town, "spot": [_spot.x, _spot.y], "camera_center": [center.x, center.y], "renderer": _renderer,
		"variant": "old_procedural" if _procedural else "new_authored",
		"kill_switches": Array(OS.get_cmdline_user_args()).filter(func(a: String) -> bool: return a.begins_with("--procedural-")),
		"camera": ({"zoom": ZOOM} if _renderer == "2d" else cam3d),
		"frames": CLIP_FRAMES, "fps": 30, "resolution": [size.x, size.y],
		"settle_sec": SETTLE_SEC, "hud": false,
	}
	var f := FileAccess.open(_out.path_join("meta.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(meta, "  "))
		f.close()
	print("DEVLOG_DONE|%s|%s|%s|%dx%d|%d frames" % [_town, _renderer, meta["variant"], size.x, size.y, CLIP_FRAMES])

## Orbit camera that clears the 3D terrain. World3D places the camera at
## target + (0, sin(pitch), cos(pitch)).rotated(UP, yaw) * dist, so try yaws (and,
## failing that, higher/further presets) and keep the first whose camera position
## AND the ray back to the target stay above the terrain mesh. Deterministic per
## spot, so "old" and "new" get the identical camera.
func _pick_cam3d(cs: Node) -> Dictionary:
	var tgt: Vector3 = cs.call("_player_3d") + Vector3(0, 1.5, 0)
	var presets := [CAM3D, {"dist": 20.0, "pitch": 0.82, "yaw": 0.35}, {"dist": 26.0, "pitch": 1.0, "yaw": 0.35}]
	# Yaw order: camera on the side OPPOSITE the tree cluster, so it looks across
	# the trees (2D x,y maps to 3D x,z). No cluster info -> start at the preset yaw.
	var look3 := Vector2(_look.x, _look.y).normalized()
	for p: Dictionary in presets:
		var yaws: Array = []
		for k in range(12):
			var yaw := float(p["yaw"]) + float(k) * TAU / 12.0
			var d := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, yaw)
			var facing := Vector2(d.x, d.z).dot(look3) if look3 != Vector2.ZERO else float(k)
			yaws.append([facing, yaw])
		yaws.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		for entry: Array in yaws:
			var yaw := float(entry[1])
			var dir := Vector3(0.0, sin(float(p["pitch"])), cos(float(p["pitch"]))).rotated(Vector3.UP, yaw)
			var clear := true
			for f: float in [1.0, 0.8, 0.6, 0.4, 0.2]:
				var pos := tgt + dir * float(p["dist"]) * f
				var h: float = cs.call("_height_at_world", pos.x, pos.z)
				if pos.y < h + 2.5:
					clear = false
					break
			if clear:
				var chosen := {"dist": float(p["dist"]), "pitch": float(p["pitch"]), "yaw": yaw}
				cs.set("_cam_dist", chosen["dist"])
				cs.set("_cam_pitch", chosen["pitch"])
				cs.set("_cam_yaw", chosen["yaw"])
				print("DEVLOG_CAM3D|%s|dist=%.1f pitch=%.2f yaw=%.2f" % [_town, chosen["dist"], chosen["pitch"], yaw])
				return chosen
	push_warning("DEVLOG: no terrain-clear camera found; using default")
	cs.set("_cam_dist", CAM3D["dist"])
	cs.set("_cam_pitch", CAM3D["pitch"])
	cs.set("_cam_yaw", CAM3D["yaw"])
	return CAM3D.duplicate()
