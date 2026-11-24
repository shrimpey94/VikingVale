extends Node3D
## 3D connected bridges (1.7.6): the approved bridge kit (v001). Each bridge (a
## BridgeLayout group) is one level deck: every tile gets the kit's base piece +
## rail overlays (BridgeKit.parts), rotated as a whole about +Y for north-south
## bridges, with the kit's deck top (local 0) on the bridge's deck height. Kit
## materials reuse the authored timber/flagstone textures (no new textures).
## Child of World3D; only used when the authored terrain is on
## (--procedural-terrain keeps the old 3D bridges). No shadows.
##
## Visual only: tile ids, passability and collision are untouched. The 3D view
## uses deck_height() so people walk ON the deck, not through it.

const BridgeLayout = preload("res://scripts/terrain/BridgeLayout.gd")
const BridgeKit = preload("res://scripts/terrain/BridgeKit.gd")
const TerrainArt = preload("res://scripts/terrain/TerrainArt.gd")
const DECK_T := 0.14          # dock deck thickness (m)
const PILE_W := 0.16          # dock post width
const MIN_ABOVE_SEA := 0.55   # deck clearance over the water plane

var sea_level := -1.0
var _deck_h: Dictionary = {}      # tile idx (300-wide) -> deck top height
var _layout: Dictionary = {}
var _meshes: Array = []
var _mat: StandardMaterial3D
## Kit piece scenes (style_role -> PackedScene) and materials (GLB material
## name -> StandardMaterial3D), loaded once and shared by every bridge.
static var _scenes: Dictionary = {}
static var _kit_mats: Dictionary = {}

func _init() -> void:
	name = "ConnectedBridges3D"
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.9

## Deck top at tile (tx, ty), or NAN when the tile isn't part of a bridge deck.
func deck_height(tx: int, ty: int, map_n: int) -> float:
	return float(_deck_h.get(ty * map_n + tx, NAN))

func layout() -> Dictionary:
	return _layout

## ids: biome ids (cols x rows, e.g. Ground's lookup bytes). corner_h(cx, cy) ->
## final terrain corner height. Only tiles inside the map_n x map_n 3D extent
## get decks.
func rebuild(ids: PackedByteArray, cols: int, rows: int, map_n: int, corner_h: Callable) -> void:
	for m: Node in _meshes:
		if is_instance_valid(m):
			remove_child(m)   # detach now so the new BridgeN / Docks names don't collide
			m.queue_free()
	_meshes.clear()
	_deck_h.clear()
	_layout = BridgeLayout.classify(ids, cols, rows)
	var tiles: Dictionary = _layout["tiles"]
	for g: Dictionary in _layout["groups"]:
		var members: Array = (g["tiles"] as Array).filter(func(c: int) -> bool:
			return int(tiles[c]["tx"]) < map_n and int(tiles[c]["ty"]) < map_n)
		if members.is_empty():
			continue
		var top := _deck_top(members, tiles, corner_h)
		var group := Node3D.new()
		group.name = "Bridge%d" % int(g["id"])
		for c: int in members:
			var info: Dictionary = tiles[c]
			_add_tile(group, info, top)
			_deck_h[int(info["ty"]) * map_n + int(info["tx"])] = top
		add_child(group)
		_meshes.append(group)
	_add_docks(ids, cols, rows, map_n, corner_h)

## Docks (id 94): a flat plank deck per dock (4-connected group), NO rails,
## with timber posts along the sides that face open water. The deck sits level
## with the lowest land the dock touches (never lower than MIN_ABOVE_SEA over
## the water), like a bridge deck, and people walk on it (deck_height). Visual
## only. One mesh for all docks.
func _add_docks(ids: PackedByteArray, cols: int, rows: int, map_n: int, corner_h: Callable) -> void:
	var docks := BridgeLayout.docks(ids, cols, rows)
	var tops := {}
	for d: Dictionary in docks.values():
		var g := int(d["group"])
		var land := int(d["land"])
		var tx := int(d["tx"])
		var ty := int(d["ty"])
		for side: int in [BridgeLayout.N, BridgeLayout.E, BridgeLayout.S, BridgeLayout.W]:
			if land & side:
				var h := _side_h(tx, ty, side, corner_h)
				tops[g] = minf(float(tops.get(g, INF)), h)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var plank := Color(0.50, 0.36, 0.22)
	var post := Color(0.30, 0.20, 0.11)
	var any := false
	for d: Dictionary in docks.values():
		var tx := int(d["tx"])
		var ty := int(d["ty"])
		if tx >= map_n or ty >= map_n:
			continue
		var lowest := float(tops.get(int(d["group"]), INF))
		var floor_h := sea_level + MIN_ABOVE_SEA
		var top := maxf(floor_h, lowest if lowest != INF else floor_h) + 0.03
		_box(st, Vector3(tx, top - DECK_T, ty), Vector3(tx + 1.0, top, ty + 1.0), plank)
		_deck_h[ty * map_n + tx] = top
		any = true
		var water := int(d["water"])
		for t: float in [0.125, 0.625]:
			var pts: Array = []
			if water & BridgeLayout.N: pts.append(Vector2(t, 0.08))
			if water & BridgeLayout.S: pts.append(Vector2(t, 0.92))
			if water & BridgeLayout.W: pts.append(Vector2(0.08, t))
			if water & BridgeLayout.E: pts.append(Vector2(0.92, t))
			for p: Vector2 in pts:
				var gx := float(tx) + p.x
				var gz := float(ty) + p.y
				_box(st, Vector3(gx - PILE_W * 0.5, sea_level - 0.9, gz - PILE_W * 0.5), Vector3(gx + PILE_W * 0.5, top + 0.25, gz + PILE_W * 0.5), post)
	if not any:
		return
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _mat
	mi.name = "Docks"
	add_child(mi)
	_meshes.append(mi)

## Mean height of a tile's edge on `side` (two corners).
func _side_h(tx: int, ty: int, side: int, corner_h: Callable) -> float:
	var a: Vector2i
	var b: Vector2i
	match side:
		BridgeLayout.N: a = Vector2i(tx, ty); b = Vector2i(tx + 1, ty)
		BridgeLayout.S: a = Vector2i(tx, ty + 1); b = Vector2i(tx + 1, ty + 1)
		BridgeLayout.W: a = Vector2i(tx, ty); b = Vector2i(tx, ty + 1)
		_: a = Vector2i(tx + 1, ty); b = Vector2i(tx + 1, ty + 1)
	return 0.5 * (float(corner_h.call(a.x, a.y)) + float(corner_h.call(b.x, b.y)))

## Deck height: level with the LOWEST bank it lands on (the deck runs into the
## higher bank instead of floating over the lower one), never lower than
## MIN_ABOVE_SEA over the water.
func _deck_top(members: Array, tiles: Dictionary, corner_h: Callable) -> float:
	var floor_h := sea_level + MIN_ABOVE_SEA
	var lowest := INF
	for c: int in members:
		var info: Dictionary = tiles[c]
		var land := int(info["landing"])
		if land == 0:
			continue
		var tx := int(info["tx"])
		var ty := int(info["ty"])
		for side: int in [BridgeLayout.N, BridgeLayout.E, BridgeLayout.S, BridgeLayout.W]:
			if land & side:
				var a: Vector2i
				var b: Vector2i
				match side:
					BridgeLayout.N: a = Vector2i(tx, ty); b = Vector2i(tx + 1, ty)
					BridgeLayout.S: a = Vector2i(tx, ty + 1); b = Vector2i(tx + 1, ty + 1)
					BridgeLayout.W: a = Vector2i(tx, ty); b = Vector2i(tx, ty + 1)
					_: a = Vector2i(tx + 1, ty); b = Vector2i(tx + 1, ty + 1)
				lowest = minf(lowest, 0.5 * (float(corner_h.call(a.x, a.y)) + float(corner_h.call(b.x, b.y))))
	return maxf(floor_h, lowest if lowest != INF else floor_h) + 0.03

## One tile: its base piece, an optional support and its rail overlays, all at
## the tile centre with the kit deck top on `top`; +90 degrees about +Y for a
## north-south bridge (the kit's travel axis is +X).
func _add_tile(group: Node3D, info: Dictionary, top: float) -> void:
	var p := BridgeKit.parts(info)
	var roles: Array = [p["base"]]
	if bool(p["support"]):
		roles.append("support")
	roles.append_array(p["overlays"])
	var pos := Vector3(float(info["tx"]) + 0.5, top, float(info["ty"]) + 0.5)
	var yaw := deg_to_rad(float(BridgeKit.angle(info)))
	for role: String in roles:
		var node := _piece(BridgeKit.style(info) + "_" + str(role))
		if node == null:
			continue
		node.position = pos
		node.rotation.y = yaw
		group.add_child(node)

func _piece(key: String) -> Node3D:
	if not _scenes.has(key):
		_scenes[key] = load(BridgeKit.DIR + key + ".glb") as PackedScene
	var ps := _scenes[key] as PackedScene
	if ps == null:
		return null
	var node := ps.instantiate() as Node3D
	_bind(node)
	return node

## Swap each GLB surface material (by name) for the shared kit material.
static func _bind(node: Node) -> void:
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for i in range(mi.mesh.get_surface_count()):
			var old := mi.mesh.surface_get_material(i)
			if old != null:
				var m := _kit_material(old.resource_name)
				if m != null:
					mi.set_surface_override_material(i, m)
	for c: Node in node.get_children():
		_bind(c)

## Kit material: the approved review binding (albedo/normal/roughness from the
## authored timber or flagstone set, times the kit colour; iron is untextured).
static func _kit_material(mat_name: String) -> StandardMaterial3D:
	if _kit_mats.has(mat_name):
		return _kit_mats[mat_name]
	if not BridgeKit.MATERIALS.has(mat_name):
		return null
	var spec: Array = BridgeKit.MATERIALS[mat_name]
	var m := StandardMaterial3D.new()
	m.resource_name = mat_name
	m.albedo_color = spec[1]
	m.roughness = 0.84
	var set_name := str(spec[0])
	if set_name != "":
		var maps := TerrainArt._texture_params()
		m.albedo_texture = maps[set_name + "_albedo"]
		m.normal_enabled = true
		m.normal_texture = maps[set_name + "_normal"]
		m.normal_scale = 0.45
		m.roughness_texture = maps[set_name + "_orm"]
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	else:
		m.metallic = 0.45
	_kit_mats[mat_name] = m
	return m

## Axis-aligned box (6 faces) between corners a (min) and b (max).
func _box(st: SurfaceTool, a: Vector3, b: Vector3, col: Color) -> void:
	var p := [Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z), Vector3(a.x, a.y, b.z),
		Vector3(a.x, b.y, a.z), Vector3(b.x, b.y, a.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z)]
	for f: Array in [[4, 5, 6, 7], [3, 2, 1, 0], [0, 1, 5, 4], [2, 3, 7, 6], [3, 0, 4, 7], [1, 2, 6, 5]]:
		var q0: Vector3 = p[f[0]]
		var q1: Vector3 = p[f[1]]
		var q2: Vector3 = p[f[2]]
		var q3: Vector3 = p[f[3]]
		for v: Vector3 in [q0, q1, q2, q0, q2, q3]:
			st.set_color(col)
			st.add_vertex(v)
