extends Node3D

## 1.5.6 "3D Immersion" — billboard 2.5D prototype, ITERATION 2 (sandbox).
##
## Now rebuilds YOUR REAL 300×300 map in 3D: the deterministic biome geography
## from Ground.gd (mountains, Serpent Sea, Frostheim snow, forests, towns) plus
## your live admin tile-paints (exported via the in-game /exportmap command to
## user://map_export.json). Terrain is CHUNKED so you can SCULPT height with a
## brush; edits persist to user://proto_heightmap.json.
##
## Run:  double-click "Run 3D Prototype.lnk", or run_proto.bat, or
##       godot --path . res://proto/Billboard3D.tscn
##
## Controls:
##   WASD/arrows = pan · Q/E = orbit · R/F = tilt · wheel = zoom
##   LMB = raise terrain · RMB = lower terrain · [ ] = brush size · - = strength
##   Ctrl+S = save heightmap · Esc = save & quit

const GroundScript       := preload("res://scripts/Ground.gd")
const CharPreviewScript  := preload("res://scripts/CharPreview.gd")
const MonsterScript      := preload("res://scripts/Monster.gd")
const InteractableScript := preload("res://scripts/Interactable.gd")

const MAP_N := 300           # exterior tiles per side (ty/tx 0..299)
const CELL  := 1.0           # 3D units per tile → 300×300 unit map
const CHUNK := 30            # tiles per terrain chunk → 10×10 = 100 chunks
const SEA_LEVEL := -1.0
const N1 := MAP_N + 1        # corner grid dimension

# Terrain data
var _tile_h: PackedFloat32Array          # base height per TILE (biome)
var _tile_col: PackedColorArray          # colour per TILE (biome)
var _base_h: PackedFloat32Array          # base height per CORNER (N1×N1)
var _sculpt_h: PackedFloat32Array        # sculpt delta per CORNER (N1×N1)
var _chunks: Dictionary = {}             # "cx,cy" → MeshInstance3D
var _terrain_mat: StandardMaterial3D

# Camera (free-fly RTS)
var _cam: Camera3D
var _cam_target: Vector3 = Vector3.ZERO
var _cam_yaw := 0.0
var _cam_pitch := 0.9
var _cam_dist := 90.0

# Sculpt brush
var _brush_radius := 8.0
var _brush_strength := 14.0

var _billboards: Array[Sprite3D] = []
var _hud_lbl: Label

func _ready() -> void:
	print(">>> BILLBOARD3D PROTO (v2 — real map) RUNNING <<<")
	_build_environment()
	_import_map()
	_precompute_base_h()
	_load_sculpt()
	_build_all_chunks()
	_build_water()
	_build_camera()
	_populate_demo()
	_build_hud()

# ── Map import (real biomes + admin paints) ──────────────────────────────────
func _import_map() -> void:
	var ground: Object = GroundScript.new()
	ground.call("_build_cache")
	var ov := _load_map_export()
	if not ov.is_empty():
		ground.set("_overrides", ov)
	_tile_h = PackedFloat32Array(); _tile_h.resize(MAP_N * MAP_N)
	_tile_col = PackedColorArray(); _tile_col.resize(MAP_N * MAP_N)
	for ty in range(MAP_N):
		for tx in range(MAP_N):
			var nm: String = ground.call("_biome_at", tx, ty)
			var idx := ty * MAP_N + tx
			_tile_h[idx] = _biome_height(nm)
			_tile_col[idx] = _biome_color(nm)
	if ground is Node:
		(ground as Node).free()
	else:
		ground.free()

func _load_map_export() -> Dictionary:
	var out: Dictionary = {}
	if not FileAccess.file_exists("user://map_export.json"):
		return out
	var f := FileAccess.open("user://map_export.json", FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).has("overrides"):
		for k: Variant in (parsed as Dictionary)["overrides"].keys():
			out[int(str(k))] = int((parsed as Dictionary)["overrides"][k])
	return out

func _biome_height(nm: String) -> float:
	if "mountain" in nm or "cliff" in nm or "granite" in nm or "alpine" in nm or "scree" in nm:
		return 20.0
	if "rocky" in nm or "basalt" in nm or "obsidian" in nm:
		return 10.0
	if "_hills" in nm or "mound" in nm or "dune" in nm:
		return 5.0
	if "ocean" in nm:
		return -5.0
	if "coast" in nm or "shallow" in nm or "reef" in nm or "tidepool" in nm or "kelp" in nm or "wet_sand" in nm or "lily" in nm:
		return -2.0
	return 0.0

func _biome_color(nm: String) -> Color:
	if "ocean" in nm: return Color(0.13, 0.30, 0.52)
	if "coast" in nm or "shallow" in nm or "tidepool" in nm or "reef" in nm or "kelp" in nm: return Color(0.26, 0.50, 0.66)
	if "wet_sand" in nm or "sand" in nm or "shore" in nm or "driftwood" in nm: return Color(0.78, 0.72, 0.50)
	if "snow" in nm or "tundra" in nm or "ice" in nm: return Color(0.86, 0.90, 0.96)
	if "mountain" in nm or "cliff" in nm or "rocky" in nm or "granite" in nm or "alpine" in nm or "scree" in nm or "moss_rock" in nm: return Color(0.50, 0.50, 0.53)
	if "basalt" in nm or "obsidian" in nm or "volcanic" in nm or "lava" in nm or "ash" in nm or "scorched" in nm or "geothermal" in nm: return Color(0.26, 0.18, 0.16)
	if "helheim" in nm: return Color(0.36, 0.22, 0.44)
	if "pine" in nm or "dark_forest" in nm or "dark_root" in nm or "dark_mush" in nm: return Color(0.16, 0.32, 0.20)
	if "oak" in nm or "forest" in nm or "birch" in nm or "bamboo" in nm or "clearing" in nm or "meadow" in nm: return Color(0.24, 0.44, 0.24)
	if "swamp" in nm or "reeds" in nm or "lily" in nm or "mud" in nm: return Color(0.30, 0.36, 0.24)
	if "town" in nm or "floor" in nm or "carpet" in nm or "hearth" in nm or "wall" in nm or "longhouse" in nm or "fur_rug" in nm or "fire_pit" in nm: return Color(0.62, 0.50, 0.36)
	if "road" in nm or "path" in nm or "dirt" in nm or "bridge" in nm: return Color(0.50, 0.42, 0.30)
	if "farm" in nm or "wheat" in nm or "tilled" in nm or "pasture" in nm or "vineyard" in nm or "orchard" in nm or "crops" in nm: return Color(0.60, 0.55, 0.25)
	if "rubble" in nm or "broken" in nm or "cracked" in nm or "ruins" in nm or "cemetery" in nm or "grave" in nm or "rune" in nm: return Color(0.45, 0.43, 0.40)
	return Color(0.30, 0.52, 0.26)   # grass family + default

# ── Corner heights ───────────────────────────────────────────────────────────
func _precompute_base_h() -> void:
	_base_h = PackedFloat32Array(); _base_h.resize(N1 * N1)
	_sculpt_h = PackedFloat32Array(); _sculpt_h.resize(N1 * N1)   # zero-filled
	for cy in range(N1):
		for cx in range(N1):
			var sum := 0.0
			var cnt := 0
			for oy: int in [-1, 0]:
				for ox: int in [-1, 0]:
					var tx := cx + ox
					var ty := cy + oy
					if tx >= 0 and tx < MAP_N and ty >= 0 and ty < MAP_N:
						sum += _tile_h[ty * MAP_N + tx]
					cnt += 1
			var h := sum / float(cnt)
			h += sin(float(cx) * 0.7) * cos(float(cy) * 0.6) * 0.35   # organic wobble
			_base_h[cy * N1 + cx] = h

func _corner_h(cx: int, cy: int) -> float:
	var i := cy * N1 + cx
	return _base_h[i] + _sculpt_h[i]

func _height_at_world(wx: float, wz: float) -> float:
	var fx := wx / CELL
	var fy := wz / CELL
	var x0 := clampi(int(floor(fx)), 0, MAP_N)
	var y0 := clampi(int(floor(fy)), 0, MAP_N)
	var x1 := mini(x0 + 1, MAP_N)
	var y1 := mini(y0 + 1, MAP_N)
	var tx := clampf(fx - float(x0), 0.0, 1.0)
	var ty := clampf(fy - float(y0), 0.0, 1.0)
	var a := lerpf(_corner_h(x0, y0), _corner_h(x1, y0), tx)
	var b := lerpf(_corner_h(x0, y1), _corner_h(x1, y1), tx)
	return lerpf(a, b, ty)

# ── Chunked terrain mesh ─────────────────────────────────────────────────────
func _build_all_chunks() -> void:
	_terrain_mat = StandardMaterial3D.new()
	_terrain_mat.vertex_color_use_as_albedo = true
	_terrain_mat.roughness = 1.0
	_terrain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var nchunks := int(ceil(float(MAP_N) / float(CHUNK)))
	for ccy in range(nchunks):
		for ccx in range(nchunks):
			_build_chunk(ccx, ccy)

func _build_chunk(ccx: int, ccy: int) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tx0 := ccx * CHUNK
	var ty0 := ccy * CHUNK
	var any := false
	for ty in range(ty0, mini(ty0 + CHUNK, MAP_N)):
		for tx in range(tx0, mini(tx0 + CHUNK, MAP_N)):
			any = true
			var col := _tile_col[ty * MAP_N + tx]
			var x0 := float(tx) * CELL
			var x1 := float(tx + 1) * CELL
			var z0 := float(ty) * CELL
			var z1 := float(ty + 1) * CELL
			var p00 := Vector3(x0, _corner_h(tx, ty), z0)
			var p10 := Vector3(x1, _corner_h(tx + 1, ty), z0)
			var p11 := Vector3(x1, _corner_h(tx + 1, ty + 1), z1)
			var p01 := Vector3(x0, _corner_h(tx, ty + 1), z1)
			_tri(st, col, p00, p01, p11)
			_tri(st, col, p00, p11, p10)
	if not any:
		return
	st.generate_normals()
	var key := "%d,%d" % [ccx, ccy]
	var mi: MeshInstance3D = _chunks.get(key)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = _terrain_mat
		add_child(mi)
		_chunks[key] = mi
	mi.mesh = st.commit()

func _tri(st: SurfaceTool, col: Color, a: Vector3, b: Vector3, c: Vector3) -> void:
	for v: Vector3 in [a, b, c]:
		st.set_color(col)
		st.add_vertex(v)

# ── Environment / water ──────────────────────────────────────────────────────
func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-52), deg_to_rad(-40), 0)
	sun.light_energy = 1.15
	add_child(sun)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.53, 0.68, 0.83)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.68)
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.60, 0.72, 0.85)
	env.fog_density = 0.0025
	we.environment = env
	add_child(we)

func _build_water() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(MAP_N * CELL * 1.4, MAP_N * CELL * 1.4)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.position = Vector3(MAP_N * CELL * 0.5, SEA_LEVEL, MAP_N * CELL * 0.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.42, 0.66, 0.66)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.12
	mi.material_override = mat
	add_child(mi)

# ── Billboards (reused art) ──────────────────────────────────────────────────
func _sprite_ground_y(x: float, z: float, vp_h: int, pixel: float) -> float:
	return _height_at_world(x, z) + float(vp_h) * pixel * 0.5

func _billboard(drawer: Node2D, vp_size: Vector2i, animated: bool,
		x: float, z: float, pixel := 0.05, art_bottom := 20.0) -> Sprite3D:
	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.size = vp_size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if animated else SubViewport.UPDATE_ONCE
	vp.disable_3d = true
	drawer.position = Vector2(vp_size.x * 0.5, float(vp_size.y) - 4.0 - art_bottom)
	vp.add_child(drawer)
	add_child(vp)
	var spr := Sprite3D.new()
	spr.texture = vp.get_texture()
	spr.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	spr.shaded = false
	spr.transparent = true
	spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	spr.pixel_size = pixel
	spr.position = Vector3(x, _sprite_ground_y(x, z, vp_size.y, pixel), z)
	add_child(spr)
	_billboards.append(spr)
	return spr

func _make_char(rng: int) -> Node2D:
	var cp := CharPreviewScript.new() as Node2D
	cp.call("set_appearance", {
		"skin": rng % 8, "hair_style": (rng >> 3) % 12, "hair_color": (rng >> 6) % 14,
		"beard": (rng >> 9) % 10, "body": (rng >> 12) % 3, "tunic": (rng >> 14) % 6,
	})
	return cp

func _make_monster(mtype: String) -> Node2D:
	var m := MonsterScript.new() as Node2D
	m.set("monster_type", mtype)
	return m

func _make_interactable(type_str: String, col: Color) -> Node2D:
	var it := InteractableScript.new() as Node2D
	it.set("interactable_type_str", type_str)
	it.set("color", col)
	return it

## A few reused-art billboards near Bjorn's Landing (tile 246,138) for scale/life.
func _populate_demo() -> void:
	var bx := 246.0 * CELL
	var bz := 138.0 * CELL
	_billboard(_make_char(42),   Vector2i(56, 76), true, bx, bz, 0.06, 22.0)
	_billboard(_make_char(88),   Vector2i(56, 76), true, bx + 3, bz + 2, 0.06, 22.0)
	_billboard(_make_monster("wolf"), Vector2i(72, 64), true, bx - 4, bz + 4, 0.06, 14.0)
	_billboard(_make_interactable("tree", Color(0.30, 0.55, 0.25)), Vector2i(64, 72), false, bx + 5, bz - 3, 0.07, 18.0)
	_billboard(_make_interactable("tree", Color(0.30, 0.55, 0.25)), Vector2i(64, 72), false, bx - 6, bz - 2, 0.07, 18.0)

# ── Camera ───────────────────────────────────────────────────────────────────
func _build_camera() -> void:
	_cam = Camera3D.new()
	_cam.current = true
	_cam.far = 4000.0
	add_child(_cam)
	_cam_target = Vector3(246.0 * CELL, 0.0, 138.0 * CELL)   # over Bjorn's Landing
	_cam_target.y = _height_at_world(_cam_target.x, _cam_target.z)
	_update_camera()

func _update_camera() -> void:
	var dir := Vector3(0.0, sin(_cam_pitch), cos(_cam_pitch)).rotated(Vector3.UP, _cam_yaw)
	_cam.position = _cam_target + dir * _cam_dist
	_cam.look_at(_cam_target, Vector3.UP)

# ── Loop / input ─────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	# Pan (WASD, yaw-relative), scaled by zoom so it feels consistent.
	var pan := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):    pan.z -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):  pan.z += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):  pan.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): pan.x += 1.0
	if pan != Vector3.ZERO:
		pan = pan.rotated(Vector3.UP, _cam_yaw).normalized() * (_cam_dist * 0.9) * delta
		_cam_target += pan
		var lim := MAP_N * CELL
		_cam_target.x = clampf(_cam_target.x, 0.0, lim)
		_cam_target.z = clampf(_cam_target.z, 0.0, lim)
		_cam_target.y = _height_at_world(_cam_target.x, _cam_target.z)
	if Input.is_key_pressed(KEY_Q): _cam_yaw += 1.1 * delta
	if Input.is_key_pressed(KEY_E): _cam_yaw -= 1.1 * delta
	if Input.is_key_pressed(KEY_R): _cam_pitch = clampf(_cam_pitch + 0.8 * delta, 0.25, 1.45)
	if Input.is_key_pressed(KEY_F): _cam_pitch = clampf(_cam_pitch - 0.8 * delta, 0.25, 1.45)
	_update_camera()
	# Sculpt (mouse held).
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_do_sculpt(1.0, delta)
	elif Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_do_sculpt(-1.0, delta)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var b := (event as InputEventMouseButton).button_index
		if b == MOUSE_BUTTON_WHEEL_UP:   _cam_dist = maxf(6.0, _cam_dist - _cam_dist * 0.1)
		elif b == MOUSE_BUTTON_WHEEL_DOWN: _cam_dist = minf(400.0, _cam_dist + _cam_dist * 0.1)
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		if k == KEY_BRACKETLEFT:    _brush_radius = maxf(2.0, _brush_radius - 2.0)
		elif k == KEY_BRACKETRIGHT: _brush_radius = minf(40.0, _brush_radius + 2.0)
		elif k == KEY_MINUS:        _brush_strength = maxf(2.0, _brush_strength - 3.0)
		elif k == KEY_EQUAL:        _brush_strength = minf(60.0, _brush_strength + 3.0)
		elif k == KEY_S and Input.is_key_pressed(KEY_CTRL): _save_sculpt()
		elif k == KEY_ESCAPE:
			_save_sculpt()
			get_tree().quit()
		_update_hud()

# ── Sculpting ────────────────────────────────────────────────────────────────
func _ray_to_tile() -> Vector2:
	var mp := get_viewport().get_mouse_position()
	var o := _cam.project_ray_origin(mp)
	var dn := _cam.project_ray_normal(mp)
	var lim := MAP_N * CELL
	var t := 0.0
	for i in range(700):
		t += 1.5
		var p := o + dn * t
		if p.x < 0.0 or p.x > lim or p.z < 0.0 or p.z > lim:
			if t > 2500.0:
				break
			continue
		if p.y <= _height_at_world(p.x, p.z):
			return Vector2(p.x / CELL, p.z / CELL)
	return Vector2(INF, INF)

func _do_sculpt(s: float, delta: float) -> void:
	var hit := _ray_to_tile()
	if hit.x == INF:
		return
	var r := _brush_radius
	var cx0 := clampi(int(hit.x - r), 0, MAP_N)
	var cx1 := clampi(int(hit.x + r) + 1, 0, MAP_N)
	var cy0 := clampi(int(hit.y - r), 0, MAP_N)
	var cy1 := clampi(int(hit.y + r) + 1, 0, MAP_N)
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var d := Vector2(float(cx), float(cy)).distance_to(hit)
			if d <= r:
				var fall := smoothstep(1.0, 0.0, d / r)
				_sculpt_h[cy * N1 + cx] += s * _brush_strength * fall * delta
	_rebuild_chunks_over_tiles(cx0 - 1, cy0 - 1, cx1 + 1, cy1 + 1)

func _rebuild_chunks_over_tiles(tx0: int, ty0: int, tx1: int, ty1: int) -> void:
	var maxc := floori(float(MAP_N - 1) / float(CHUNK))
	var ccx0 := clampi(floori(float(tx0) / float(CHUNK)), 0, maxc)
	var ccx1 := clampi(floori(float(tx1) / float(CHUNK)), 0, maxc)
	var ccy0 := clampi(floori(float(ty0) / float(CHUNK)), 0, maxc)
	var ccy1 := clampi(floori(float(ty1) / float(CHUNK)), 0, maxc)
	for ccy in range(ccy0, ccy1 + 1):
		for ccx in range(ccx0, ccx1 + 1):
			_build_chunk(ccx, ccy)

func _save_sculpt() -> void:
	var sparse: Dictionary = {}
	for i in range(_sculpt_h.size()):
		if absf(_sculpt_h[i]) > 0.001:
			sparse[str(i)] = _sculpt_h[i]
	var f := FileAccess.open("user://proto_heightmap.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"n": MAP_N, "sculpt": sparse}))
		f.close()
		if _hud_lbl != null:
			_hud_lbl.text = "[saved %d edited corners]" % sparse.size()

func _load_sculpt() -> void:
	if not FileAccess.file_exists("user://proto_heightmap.json"):
		return
	var f := FileAccess.open("user://proto_heightmap.json", FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).has("sculpt"):
		for k: Variant in (parsed as Dictionary)["sculpt"].keys():
			var i := int(str(k))
			if i >= 0 and i < _sculpt_h.size():
				_sculpt_h[i] = float((parsed as Dictionary)["sculpt"][k])

# ── HUD ──────────────────────────────────────────────────────────────────────
func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	_hud_lbl = Label.new()
	_hud_lbl.position = Vector2(12, 10)
	_hud_lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	_hud_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hud_lbl.add_theme_constant_override("outline_size", 4)
	cl.add_child(_hud_lbl)
	_update_hud()

func _update_hud() -> void:
	if _hud_lbl == null:
		return
	_hud_lbl.text = "WASD pan · Q/E orbit · R/F tilt · wheel zoom | LMB raise · RMB lower  (brush %d, strength %d, [ ] - =) | Ctrl+S save · Esc quit" % [int(_brush_radius), int(_brush_strength)]
