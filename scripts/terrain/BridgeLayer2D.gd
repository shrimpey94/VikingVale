extends Node2D
## 2D connected bridges (1.7.6): draws one piece per bridge tile, chosen by
## BridgeLayout from its neighbours, over the ground. Child of Ground (so it
## draws right above the terrain, under everything else) and only used when the
## authored terrain is on; --procedural-terrain keeps the old per-tile bridges.
##
## PLACEHOLDER PIECES: plain planks/flagstones, rails and posts drawn with
## rectangles until the connected bridge kit is approved. Swap _draw_piece for
## the kit's sprites; the layout (pieces, axis, rails, ends) stays the same.
##
## Visual only — tile ids, passability and collision are untouched. Rebuilds on
## Ground.tile_changed (admin paint / clear / bulk / login burst), so a bridge
## tile and its neighbours update live on every client.

const BridgeLayout = preload("res://scripts/terrain/BridgeLayout.gd")
const TILE := 32.0
const BAND := 4.0          # water left visible outside a rail (the old bridge look)
const RAIL := 3.0
const POST := 4.0
const POST_STEP := 8.0     # world px between rail posts (world-aligned → continuous)

var _ground: Node = null
var _tiles: Dictionary = {}
var _docks: Dictionary = {}
var _dirty := false

func setup(ground: Node) -> void:
	_ground = ground
	name = "ConnectedBridges"
	if ground.has_signal("tile_changed"):
		ground.connect("tile_changed", func(_tx: int, _ty: int, _id: int) -> void: _mark_dirty())
	rebuild()

func _mark_dirty() -> void:
	if _dirty:
		return
	_dirty = true
	# Throttle: a paint drag / bulk ingest reclassifies once, a moment later.
	get_tree().create_timer(0.1).timeout.connect(rebuild)

## Reclassify every bridge from the ground's current biome lookup and redraw.
func rebuild() -> void:
	_dirty = false
	var img := _ground.get("_biome_lookup_img") as Image
	if img == null:
		return
	_tiles = BridgeLayout.classify(img.get_data(), img.get_width(), img.get_height())["tiles"]
	_docks = BridgeLayout.docks(img.get_data(), img.get_width(), img.get_height())
	queue_redraw()

## Layout info for tests/editor: {idx: info} (see BridgeLayout.classify).
func layout() -> Dictionary:
	return _tiles

func _draw() -> void:
	for info: Dictionary in _tiles.values():
		_draw_piece(info)
	for d: Dictionary in _docks.values():
		_draw_dock_posts(d)

## Dock posts: round-ish timber heads along each side that faces open water,
## world-aligned every 16 px so a long pier edge reads as one row. No rails.
func _draw_dock_posts(d: Dictionary) -> void:
	var water := int(d["water"])
	if water == 0:
		return
	var o := Vector2(float(d["tx"]), float(d["ty"])) * TILE
	var post := Color(0.30, 0.20, 0.11)
	var cap := post.lightened(0.25)
	var pts: Array = []
	for k in range(2):
		var t := 4.0 + 16.0 * float(k)
		if water & BridgeLayout.N: pts.append(o + Vector2(t, 2.5))
		if water & BridgeLayout.S: pts.append(o + Vector2(t, TILE - 2.5))
		if water & BridgeLayout.W: pts.append(o + Vector2(2.5, t))
		if water & BridgeLayout.E: pts.append(o + Vector2(TILE - 2.5, t))
	for pt: Vector2 in pts:
		draw_circle(pt, 2.5, post)
		draw_circle(pt + Vector2(-0.5, -0.5), 1.2, cap)

func _draw_piece(info: Dictionary) -> void:
	var o := Vector2(float(info["tx"]), float(info["ty"])) * TILE
	var stone := int(info["id"]) == BridgeLayout.STONE
	var deck := Color(0.58, 0.57, 0.53) if stone else Color(0.55, 0.38, 0.22)
	var seam := deck.darkened(0.22)
	var rail := Color(0.40, 0.40, 0.38) if stone else Color(0.33, 0.21, 0.11)
	var landing_col := deck.lightened(0.12)
	var rails := int(info["rails"])
	var horizontal := int(info["axis"]) == BridgeLayout.AXIS_H
	# Deck: the whole tile, minus the water band outside each outer rail.
	var r := Rect2(o, Vector2(TILE, TILE))
	if rails & BridgeLayout.N: r = r.grow_side(SIDE_TOP, -BAND)
	if rails & BridgeLayout.S: r = r.grow_side(SIDE_BOTTOM, -BAND)
	if rails & BridgeLayout.W: r = r.grow_side(SIDE_LEFT, -BAND)
	if rails & BridgeLayout.E: r = r.grow_side(SIDE_RIGHT, -BAND)
	draw_rect(r, deck)
	# Seams across the run, world-aligned so neighbouring tiles line up.
	var step := 8.0 if stone else 4.0
	if horizontal:
		var x := ceilf(r.position.x / step) * step
		while x < r.end.x:
			draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), seam, 1.0)
			x += step
	else:
		var y := ceilf(r.position.y / step) * step
		while y < r.end.y:
			draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), seam, 1.0)
			y += step
	# Landings: a lighter threshold where the bridge meets land.
	var landing := int(info["landing"])
	if landing & BridgeLayout.N: draw_rect(Rect2(r.position, Vector2(r.size.x, 3.0)), landing_col)
	if landing & BridgeLayout.S: draw_rect(Rect2(Vector2(r.position.x, r.end.y - 3.0), Vector2(r.size.x, 3.0)), landing_col)
	if landing & BridgeLayout.W: draw_rect(Rect2(r.position, Vector2(3.0, r.size.y)), landing_col)
	if landing & BridgeLayout.E: draw_rect(Rect2(Vector2(r.end.x - 3.0, r.position.y), Vector2(3.0, r.size.y)), landing_col)
	# Rails + posts on the outer edges only.
	if rails & BridgeLayout.N: _rail_h(r.position.x, r.end.x, r.position.y, rail)
	if rails & BridgeLayout.S: _rail_h(r.position.x, r.end.x, r.end.y - RAIL, rail)
	if rails & BridgeLayout.W: _rail_v(r.position.y, r.end.y, r.position.x, rail)
	if rails & BridgeLayout.E: _rail_v(r.position.y, r.end.y, r.end.x - RAIL, rail)

func _rail_h(x0: float, x1: float, y: float, col: Color) -> void:
	draw_rect(Rect2(Vector2(x0, y), Vector2(x1 - x0, RAIL)), col)
	var x := ceilf(x0 / POST_STEP) * POST_STEP
	while x < x1 - 0.5:
		draw_rect(Rect2(Vector2(x, y - 0.5), Vector2(POST * 0.5, RAIL + 1.0)), col.darkened(0.25))
		x += POST_STEP

func _rail_v(y0: float, y1: float, x: float, col: Color) -> void:
	draw_rect(Rect2(Vector2(x, y0), Vector2(RAIL, y1 - y0)), col)
	var y := ceilf(y0 / POST_STEP) * POST_STEP
	while y < y1 - 0.5:
		draw_rect(Rect2(Vector2(x - 0.5, y), Vector2(RAIL + 1.0, POST * 0.5)), col.darkened(0.25))
		y += POST_STEP
