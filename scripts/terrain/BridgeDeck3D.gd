extends Node3D
## 3D connected bridges (1.7.6): one continuous raised deck per bridge (a
## BridgeLayout group), with rails on the outer edges and pilings at intervals,
## instead of per-tile ground sheets. Child of World3D; only used when the
## authored terrain is on (--procedural-terrain keeps the old 3D bridges).
##
## PLACEHOLDER GEOMETRY: plain boxes in wood/stone colours until the connected
## bridge kit is approved; the kit's pieces replace _add_* calls, the layout
## stays. Visual only: tile ids, passability and collision are untouched. The
## 3D view uses deck_height() so people walk ON the deck, not through it.

const BridgeLayout = preload("res://scripts/terrain/BridgeLayout.gd")
const DECK_T := 0.14          # deck thickness (m)
const RAIL_H := 0.38
const RAIL_W := 0.07
const RAIL_IN := 0.06         # rail inset from the outer edge
const PILE_W := 0.16
const PILE_STEP := 3          # a piling pair every N tiles along the run (+ ends)
const MIN_ABOVE_SEA := 0.55   # deck clearance over the water plane

var sea_level := -1.0
var _deck_h: Dictionary = {}      # tile idx (300-wide) -> deck top height
var _layout: Dictionary = {}
var _meshes: Array = []
var _mat: StandardMaterial3D

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
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for c: int in members:
			var info: Dictionary = tiles[c]
			_add_tile(st, info, top)
			_deck_h[int(info["ty"]) * map_n + int(info["tx"])] = top
		st.generate_normals()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = _mat
		mi.name = "Bridge%d" % int(g["id"])
		add_child(mi)
		_meshes.append(mi)
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

func _add_tile(st: SurfaceTool, info: Dictionary, top: float) -> void:
	var stone := int(info["id"]) == BridgeLayout.STONE
	var deck := Color(0.58, 0.57, 0.53) if stone else Color(0.52, 0.36, 0.21)
	var rail := Color(0.42, 0.42, 0.40) if stone else Color(0.32, 0.21, 0.11)
	var pile := Color(0.36, 0.36, 0.35) if stone else Color(0.26, 0.18, 0.10)
	var x0 := float(info["tx"])
	var z0 := float(info["ty"])
	var rails := int(info["rails"])
	var ends := int(info["ends"])
	# Deck slab: the whole tile, so joined tiles form one continuous surface.
	_box(st, Vector3(x0, top - DECK_T, z0), Vector3(x0 + 1.0, top, z0 + 1.0), deck)
	# Rails on outer edges only.
	if rails & BridgeLayout.N: _box(st, Vector3(x0, top, z0 + RAIL_IN), Vector3(x0 + 1.0, top + RAIL_H, z0 + RAIL_IN + RAIL_W), rail)
	if rails & BridgeLayout.S: _box(st, Vector3(x0, top, z0 + 1.0 - RAIL_IN - RAIL_W), Vector3(x0 + 1.0, top + RAIL_H, z0 + 1.0 - RAIL_IN), rail)
	if rails & BridgeLayout.W: _box(st, Vector3(x0 + RAIL_IN, top, z0), Vector3(x0 + RAIL_IN + RAIL_W, top + RAIL_H, z0 + 1.0), rail)
	if rails & BridgeLayout.E: _box(st, Vector3(x0 + 1.0 - RAIL_IN - RAIL_W, top, z0), Vector3(x0 + 1.0 - RAIL_IN, top + RAIL_H, z0 + 1.0), rail)
	# Pilings: at the outer corners of every PILE_STEP-th tile along the run, and
	# at each open end, down into the water.
	if int(info["along"]) % PILE_STEP != 0 and ends == 0:
		return
	var bottom := sea_level - 0.9
	for corner: Vector2 in _pile_corners(rails, ends, int(info["axis"])):
		var cx := x0 + corner.x
		var cz := z0 + corner.y
		_box(st, Vector3(cx - PILE_W * 0.5, bottom, cz - PILE_W * 0.5), Vector3(cx + PILE_W * 0.5, top - DECK_T, cz + PILE_W * 0.5), pile)

## Piling positions (tile-local, 0..1) on the outer rail sides.
func _pile_corners(rails: int, _ends: int, axis: int) -> Array:
	var out: Array = []
	var m := 0.12
	if axis == BridgeLayout.AXIS_H:
		if rails & BridgeLayout.N: out.append(Vector2(m, m))
		if rails & BridgeLayout.S: out.append(Vector2(m, 1.0 - m))
	else:
		if rails & BridgeLayout.W: out.append(Vector2(m, m))
		if rails & BridgeLayout.E: out.append(Vector2(1.0 - m, m))
	return out

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
