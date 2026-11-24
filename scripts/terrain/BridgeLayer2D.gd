extends Node2D
## 2D connected bridges (1.7.6): the approved bridge kit (v001), one assembly per
## bridge tile chosen by BridgeLayout from its neighbours (see BridgeKit for the
## rules). Child of Ground and only used when the authored terrain is on;
## --procedural-terrain keeps the old per-tile bridges.
##
## Two layers so actors sort correctly:
##   * deck bases + supports draw here, right above the terrain and under every
##     actor (in the kit's reference order: screen y, then x, base before
##     support), and their opaque backing hides the old bridge tile under them;
##   * rail / corner overlays are Sprite2Ds in a y-sorted sibling layer of the
##     world, each sorted at the rail's own ground line, so a rail on the near
##     (south) side hides an actor standing behind it.
## No shadows (owner rule: none until the day/night cycle).
##
## Visual only — tile ids, passability and collision are untouched. Rebuilds on
## Ground.tile_changed (admin paint / clear / bulk / login burst), so a bridge
## tile and its neighbours update live on every client.

const BridgeLayout = preload("res://scripts/terrain/BridgeLayout.gd")
const BridgeKit = preload("res://scripts/terrain/BridgeKit.gd")
const TILE := 32.0

var _ground: Node = null
var _tiles: Dictionary = {}
var _docks: Dictionary = {}
var _draw_list: Array = []        # [{key, centre, layer}] bases + supports, in draw order
var _dirty := false
var _atlas: Texture2D = null
var _rails: Node2D = null
var _frame_tex: Dictionary = {}   # frame key -> AtlasTexture (shared by sprites)

func setup(ground: Node) -> void:
	_ground = ground
	name = "ConnectedBridges"
	_atlas = load(BridgeKit.ATLAS) as Texture2D
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_rails = Node2D.new()
	_rails.name = "BridgeRails"
	_rails.y_sort_enabled = true
	_rails.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var world := ground.get_parent()
	if world != null:
		world.add_child.call_deferred(_rails)
	else:
		add_child(_rails)
	if ground.has_signal("tile_changed"):
		ground.connect("tile_changed", func(_tx: int, _ty: int, _id: int) -> void: _mark_dirty())
	rebuild()

func _exit_tree() -> void:
	if _rails != null and is_instance_valid(_rails) and _rails.get_parent() != self:
		_rails.queue_free()

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
	_build_kit()
	queue_redraw()

## Layout info for tests/editor: {idx: info} (see BridgeLayout.classify).
func layout() -> Dictionary:
	return _tiles

## Rail sprites currently placed (tests).
func rail_sprites() -> Array:
	return _rails.get_children() if _rails != null else []

## Base/support frame keys in draw order (tests).
func draw_keys() -> Array:
	return _draw_list.map(func(d: Dictionary) -> String: return str(d["key"]))

func _build_kit() -> void:
	_draw_list.clear()
	if _rails != null:
		for c: Node in _rails.get_children():
			_rails.remove_child(c)
			c.queue_free()
	for info: Dictionary in _tiles.values():
		var centre := (Vector2(float(info["tx"]), float(info["ty"])) + Vector2(0.5, 0.5)) * TILE
		var p := BridgeKit.parts(info)
		var prefix := BridgeKit.style(info) + "_"
		var suffix := "_%d" % BridgeKit.angle(info)
		_draw_list.append({"key": prefix + str(p["base"]) + suffix, "centre": centre, "layer": 0})
		if bool(p["support"]):
			_draw_list.append({"key": prefix + "support" + suffix, "centre": centre, "layer": 1})
		var sd := BridgeKit.sides(info)
		for role: String in p["overlays"]:
			var side := int(sd["left"] if role.ends_with("left") else sd["right"])
			_add_rail(prefix + role + suffix, centre, side)
	_draw_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector2 = a["centre"]
		var pb: Vector2 = b["centre"]
		if pa.y != pb.y: return pa.y < pb.y
		if pa.x != pb.x: return pa.x < pb.x
		return int(a["layer"]) < int(b["layer"]))

## One rail/corner overlay. The sprite sits at the rail's ground line (the
## tile's edge on `side`) so y-sorting puts it in front of actors north of that
## line; its texture offset keeps the art pivot on the tile centre.
func _add_rail(key: String, centre: Vector2, side: int) -> void:
	if _rails == null or not BridgeKit.FRAMES.has(key):
		return
	var sort := centre
	match side:
		BridgeLayout.N: sort.y -= TILE * 0.5
		BridgeLayout.S: sort.y += TILE * 0.5
	var f: Array = BridgeKit.FRAMES[key]
	var s := Sprite2D.new()
	s.texture = _frame(key)
	s.centered = false
	s.scale = Vector2.ONE * BridgeKit.SPRITE_SCALE
	s.position = sort
	s.offset = -Vector2(float(f[4]), float(f[5])) + (centre - sort) / BridgeKit.SPRITE_SCALE
	s.name = key
	_rails.add_child(s)

func _frame(key: String) -> AtlasTexture:
	if not _frame_tex.has(key):
		var f: Array = BridgeKit.FRAMES[key]
		var t := AtlasTexture.new()
		t.atlas = _atlas
		t.region = Rect2(float(f[0]), float(f[1]), float(f[2]), float(f[3]))
		t.filter_clip = true
		_frame_tex[key] = t
	return _frame_tex[key]

func _draw() -> void:
	for d: Dictionary in _draw_list:
		var key := str(d["key"])
		if not BridgeKit.FRAMES.has(key):
			continue
		var f: Array = BridgeKit.FRAMES[key]
		var src := Rect2(float(f[0]), float(f[1]), float(f[2]), float(f[3]))
		var centre: Vector2 = d["centre"]
		var dst := Rect2(centre - Vector2(float(f[4]), float(f[5])) * BridgeKit.SPRITE_SCALE, src.size * BridgeKit.SPRITE_SCALE)
		draw_texture_rect_region(_atlas, dst, src)
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
