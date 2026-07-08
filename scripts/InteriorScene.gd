extends Node2D
class_name InteriorScene

## ── Interior Scene ──────────────────────────────────────────────────────────
##
## Pokémon-style building interior. Spawned by World.gd on Events.interior_entered,
## freed on Events.interior_exited. Draws a floor, walls with StaticBody2D
## collision, a door mat, and per-interior-id decorations. The player is
## teleported to the interior's spawn point on entry; walking onto the
## door mat sends `exit_interior` back to the server (or the player can
## right-click and choose Exit).
##
## Coordinate frame: the interior is drawn in its own local space centered
## on Vector2.ZERO. Player is teleported to (0, HEIGHT * 0.4) — near the
## door — on entry, then can move freely inside the bounded room. On exit
## the server tells them where to return in the exterior.
##
## Themes are keyed by `interior_id` (from the door's data.interior_id).
## Adding new interiors = new match arm in `_apply_theme`. Everything else
## is procedural.

const WALL_THICKNESS := 12.0

# Default room dimensions. Larger interior_ids can override in _apply_theme.
var width:  float = 480.0
var height: float = 360.0
# Theme colors — set per interior via _apply_theme.
var floor_color: Color = Color(0.42, 0.30, 0.16)
var wall_color:  Color = Color(0.32, 0.22, 0.10)
var trim_color:  Color = Color(0.55, 0.42, 0.20)
var accent_color: Color = Color(0.85, 0.65, 0.20)   # torch/lantern warmth
var interior_id: String = ""

# Bookkeeping.
var _walls: StaticBody2D = null
var _door_area: Area2D = null
var _decorations: Array = []


## Set by World.gd from the biome at the exterior return coord. Colors the
## thin border around the room so players see "you are inside a building
## AT this real location", not a disconnected black room. `apply_exterior_backdrop`
## queues a redraw once World has assigned this.
var exterior_biome: String = "plains"

func apply_exterior_backdrop() -> void:
	queue_redraw()

func _ready() -> void:
	# InteriorScene draws walls, exit door, and decor at z=50 so it's above
	# the Ground tile grid (default z=0) but BELOW the player (bumped to
	# z=100 in World._on_interior_entered). Interior floor tiles still come
	# from Ground (admin-paintable), visible through the "hole" left in the
	# backdrop layer.
	z_index = 50
	set_meta("is_interior_scene", true)


func setup(id: String) -> void:
	interior_id = id
	_apply_theme(id)
	_build_walls()
	_build_door_area()
	_build_decorations()
	queue_redraw()


# ── Theming per interior_id ────────────────────────────────────────────────
func _apply_theme(id: String) -> void:
	# Every interior has a size + palette. Add more as new door interiors ship.
	match id:
		"great_hall":
			width  = 700.0
			height = 480.0
			floor_color  = Color(0.36, 0.24, 0.12)
			wall_color   = Color(0.22, 0.16, 0.08)
			trim_color   = Color(0.60, 0.42, 0.14)
			accent_color = Color(0.95, 0.72, 0.24)
		"tavern":
			width  = 520.0
			height = 380.0
			floor_color  = Color(0.44, 0.30, 0.16)
			wall_color   = Color(0.30, 0.20, 0.10)
			trim_color   = Color(0.62, 0.44, 0.18)
			accent_color = Color(0.90, 0.60, 0.20)
		"chapel":
			width  = 420.0
			height = 480.0
			floor_color  = Color(0.55, 0.55, 0.55)     # stone floor
			wall_color   = Color(0.68, 0.66, 0.62)     # white plaster
			trim_color   = Color(0.85, 0.83, 0.78)
			accent_color = Color(0.62, 0.72, 0.88)
		"warehouse":
			width  = 620.0
			height = 400.0
			floor_color  = Color(0.38, 0.28, 0.16)
			wall_color   = Color(0.28, 0.20, 0.10)
			trim_color   = Color(0.50, 0.38, 0.16)
			accent_color = Color(0.80, 0.60, 0.15)
		_:  # generic house
			width  = 400.0
			height = 300.0
			floor_color  = Color(0.42, 0.30, 0.16)
			wall_color   = Color(0.32, 0.22, 0.10)
			trim_color   = Color(0.55, 0.42, 0.20)
			accent_color = Color(0.85, 0.65, 0.20)


# ── Wall StaticBody2D — four rects around the room's edges ────────────────
func _build_walls() -> void:
	_walls = StaticBody2D.new()
	_walls.collision_layer = 2   # world layer, same as Ground's impassable collision
	_walls.collision_mask  = 0
	add_child(_walls)
	var half_w := width * 0.5
	var half_h := height * 0.5
	# North wall.
	var top := CollisionShape2D.new()
	var top_rect := RectangleShape2D.new()
	top_rect.size = Vector2(width, WALL_THICKNESS)
	top.shape = top_rect
	top.position = Vector2(0, -half_h + WALL_THICKNESS * 0.5)
	_walls.add_child(top)
	# South wall — split around the door gap so the player can walk out
	# via the door mat instead of colliding straight into the wall.
	var door_w := 40.0
	var south_seg_w := (width - door_w) * 0.5
	if south_seg_w > 0:
		var sl := CollisionShape2D.new()
		var sl_rect := RectangleShape2D.new()
		sl_rect.size = Vector2(south_seg_w, WALL_THICKNESS)
		sl.shape = sl_rect
		sl.position = Vector2(-half_w + south_seg_w * 0.5,
			half_h - WALL_THICKNESS * 0.5)
		_walls.add_child(sl)
		var sr := CollisionShape2D.new()
		var sr_rect := RectangleShape2D.new()
		sr_rect.size = Vector2(south_seg_w, WALL_THICKNESS)
		sr.shape = sr_rect
		sr.position = Vector2(half_w - south_seg_w * 0.5,
			half_h - WALL_THICKNESS * 0.5)
		_walls.add_child(sr)
	# East wall.
	var east := CollisionShape2D.new()
	var east_rect := RectangleShape2D.new()
	east_rect.size = Vector2(WALL_THICKNESS, height)
	east.shape = east_rect
	east.position = Vector2(half_w - WALL_THICKNESS * 0.5, 0)
	_walls.add_child(east)
	# West wall.
	var west := CollisionShape2D.new()
	var west_rect := RectangleShape2D.new()
	west_rect.size = Vector2(WALL_THICKNESS, height)
	west.shape = west_rect
	west.position = Vector2(-half_w + WALL_THICKNESS * 0.5, 0)
	_walls.add_child(west)


# ── Exit door — dual mode: walking onto the mat OR left-clicking the door.
# Both fire NetworkManager.send_exit_interior(). Belt-and-suspenders because
# players expect a door to be clickable (matches the outside entry flow)
# AND intuitive walk-through has been common since roguelikes.
func _build_door_area() -> void:
	_door_area = Area2D.new()
	# Layer 4 (interactable) + input_pickable so left-click hits it and
	# the standard mouse targeting works.
	_door_area.collision_layer = 4
	_door_area.collision_mask  = 1   # detect player body for walk-through
	_door_area.input_pickable  = true
	_door_area.add_to_group("interactable")
	add_child(_door_area)
	# Two shapes:
	#   - `mat_shape` (Area2D collision) covers the walk-through zone
	#     just inside the south wall
	#   - the door frame is drawn in _draw; click detection uses the same
	#     Area2D via input_event handler below
	var mat := CollisionShape2D.new()
	var mat_rect := RectangleShape2D.new()
	mat_rect.size = Vector2(64, 44)     # bigger so a stray tap hits it
	mat.shape = mat_rect
	# Center on the door gap, straddling the wall so click + walk both hit.
	mat.position = Vector2(0, height * 0.5 - WALL_THICKNESS - 12)
	_door_area.add_child(mat)
	_door_area.body_entered.connect(_on_door_body_entered)
	_door_area.input_event.connect(_on_door_input_event)


func _on_door_body_entered(body: Node) -> void:
	if body == null or not body.is_in_group("player"):
		return
	_exit_once()


func _on_door_input_event(_viewport: Viewport, event: InputEvent,
		_shape_idx: int) -> void:
	# Left-click on the door frame fires exit. Same one-shot guard as the
	# walk-through path so you can't spam-click during the RPC round-trip.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_exit_once()


func _exit_once() -> void:
	# Disconnect both triggers so a fast walk-through-and-click doesn't
	# double-fire before the server acks.
	if _door_area.body_entered.is_connected(_on_door_body_entered):
		_door_area.body_entered.disconnect(_on_door_body_entered)
	if _door_area.input_event.is_connected(_on_door_input_event):
		_door_area.input_event.disconnect(_on_door_input_event)
	NetworkManager.send_exit_interior()


# ── Decorations (visual only) — themed per interior ───────────────────────
func _build_decorations() -> void:
	# Decorations are drawn in _draw for simplicity — no separate nodes.
	# Add named coords here that _draw reads.
	pass


# ── Rendering ─────────────────────────────────────────────────────────────
func _draw() -> void:
	var half_w := width * 0.5
	var half_h := height * 0.5

	# Floor is drawn by the Ground tile grid (interior band). We skip our
	# own procedural floor so admin-painted tiles are what the player sees.

	# ── Backdrop: hide the sprawling wood_floor tiles the Ground grid draws
	# across the entire interior band. Draw four solid rects covering the
	# area OUTSIDE the room + a 2-tile border. The inner border is tinted
	# with the exterior biome color so the player sees "you are inside a
	# building AT this location" — beyond that border the backdrop fades to
	# near-black void. Rects are big enough that any zoom level the camera
	# reaches inside the room is covered.
	_draw_backdrop(half_w, half_h)

	# ── Walls: darker inner strip + trim band. ──
	# Full wall footprint.
	draw_rect(Rect2(-half_w, -half_h, width, WALL_THICKNESS), wall_color)
	# Trim at the top of the north wall.
	draw_rect(Rect2(-half_w, -half_h + WALL_THICKNESS, width, 3.0), trim_color)
	# Left + right walls.
	draw_rect(Rect2(-half_w, -half_h, WALL_THICKNESS, height), wall_color)
	draw_rect(Rect2(half_w - WALL_THICKNESS, -half_h, WALL_THICKNESS, height), wall_color)
	# South wall segments.
	var door_w := 40.0
	var south_seg_w := (width - door_w) * 0.5
	draw_rect(Rect2(-half_w, half_h - WALL_THICKNESS,
		south_seg_w, WALL_THICKNESS), wall_color)
	draw_rect(Rect2(half_w - south_seg_w, half_h - WALL_THICKNESS,
		south_seg_w, WALL_THICKNESS), wall_color)

	# ── Exit door (drawn on top of the wall gap). ──
	# Beefy frame, contrast-drenched, with a pulsing gold arrow + EXIT
	# label above so it reads clearly against any theme.
	var frame_x := -door_w * 0.5
	# Dark exterior-facing plank showing through the gap.
	draw_rect(Rect2(frame_x - 4, half_h - WALL_THICKNESS - 6,
		door_w + 8, WALL_THICKNESS + 12),
		Color(0.14, 0.08, 0.03))
	# Door frame (bright trim).
	draw_rect(Rect2(frame_x - 4, half_h - WALL_THICKNESS - 6,
		door_w + 8, 4), trim_color)
	# Door slab.
	draw_rect(Rect2(frame_x + 2, half_h - WALL_THICKNESS - 2,
		door_w - 4, WALL_THICKNESS + 4),
		Color(0.40, 0.25, 0.10))
	# Door handle.
	draw_circle(Vector2(door_w * 0.35, half_h - WALL_THICKNESS + 4),
		2.5, accent_color)
	# Pulsing arrow — sinusoidal alpha for a glowing "exit here" cue.
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var pulse: float = 0.6 + 0.4 * abs(sin(t * 2.0))
	var arrow_col := Color(accent_color.r, accent_color.g, accent_color.b, pulse)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-14, half_h - WALL_THICKNESS - 34),
		Vector2( 14, half_h - WALL_THICKNESS - 34),
		Vector2(  0, half_h - WALL_THICKNESS - 16)]), arrow_col)
	# EXIT label above the arrow.
	var font := ThemeDB.fallback_font
	if font != null:
		var label := "EXIT"
		var fsize := 14
		var lw: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER,
			-1, fsize).x
		draw_string(font, Vector2(-lw * 0.5, half_h - WALL_THICKNESS - 42),
			label, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize,
			Color(0.95, 0.85, 0.30))

	# ── Per-theme decorations ──
	match interior_id:
		"great_hall": _draw_great_hall_decor(half_w, half_h)
		"tavern":     _draw_tavern_decor(half_w, half_h)
		"chapel":     _draw_chapel_decor(half_w, half_h)
		"warehouse":  _draw_warehouse_decor(half_w, half_h)
		_:            _draw_house_decor(half_w, half_h)


## Draws four rects covering everything OUTSIDE the room + a 2-tile border.
## The 2-tile band adjacent to the walls is tinted with the exterior biome
## color (from Ground.biome_at_world at the return coord) so the interior
## reads as "inside a building sitting on THIS terrain". Beyond that border
## the backdrop is near-black void that hides the interior band's default
## wood_floor tiles.
func _draw_backdrop(half_w: float, half_h: float) -> void:
	var border: float = 64.0    # 2 tiles of exterior-biome color show at edges
	var reach: float = 6000.0   # far enough to cover any zoom-out
	var void_col := Color(0.05, 0.04, 0.06, 1.0)
	# Exterior-biome color — look up on the parent Ground node's palette.
	var biome_col := void_col
	var ground := get_tree().get_first_node_in_group("ground")
	if ground != null and ground.has_method("_biome_base_color"):
		var v: Variant = ground.call("_biome_base_color", exterior_biome)
		if typeof(v) == TYPE_COLOR:
			biome_col = (v as Color).darkened(0.35)  # dim vs full-sun exterior
	# Inner 2-tile border of exterior biome color, drawn as four strips
	# around the room walls (north / south / east / west).
	draw_rect(Rect2(-half_w - border, -half_h - border,
			(half_w + border) * 2, border), biome_col)     # north
	draw_rect(Rect2(-half_w - border, half_h,
			(half_w + border) * 2, border), biome_col)     # south
	draw_rect(Rect2(-half_w - border, -half_h,
			border, half_h * 2), biome_col)                # west
	draw_rect(Rect2(half_w, -half_h,
			border, half_h * 2), biome_col)                # east
	# Outer void — four huge rects filling the rest of the camera view. Sit
	# outside the biome band so the transition reads as "one strip of the
	# outside is visible, then void".
	draw_rect(Rect2(-reach, -reach,
			reach * 2, reach - half_h - border), void_col)   # north
	draw_rect(Rect2(-reach, half_h + border,
			reach * 2, reach - half_h - border), void_col)   # south
	draw_rect(Rect2(-reach, -half_h - border,
			reach - half_w - border, (half_h + border) * 2), void_col)   # west
	draw_rect(Rect2(half_w + border, -half_h - border,
			reach - half_w - border, (half_h + border) * 2), void_col)   # east


func _draw_plank_floor(half_w: float, half_h: float) -> void:
	# Base floor.
	draw_rect(Rect2(-half_w, -half_h, half_w * 2, half_h * 2), floor_color)
	# Horizontal plank lines every 32 px.
	var plank_col := floor_color.darkened(0.25)
	var y: float = -half_h + 32
	while y < half_h:
		draw_line(Vector2(-half_w, y), Vector2(half_w, y), plank_col, 1.0)
		y += 32.0
	# Random vertical plank breaks — deterministic per interior.
	var rng := RandomNumberGenerator.new()
	rng.seed = interior_id.hash()
	for row: int in range(int(2 * half_h / 32)):
		var start_y: float = -half_h + float(row) * 32.0
		var xoff: float = rng.randf_range(0, 48)
		var x: float = -half_w + xoff
		while x < half_w:
			draw_line(Vector2(x, start_y), Vector2(x, start_y + 32),
				plank_col, 0.8)
			x += rng.randf_range(40, 90)


func _draw_flagstone_floor(half_w: float, half_h: float) -> void:
	draw_rect(Rect2(-half_w, -half_h, half_w * 2, half_h * 2), floor_color)
	# Grid of stone tiles.
	var mortar := floor_color.darkened(0.30)
	var s := 40.0
	var x: float = -half_w
	while x < half_w:
		draw_line(Vector2(x, -half_h), Vector2(x, half_h), mortar, 1.0)
		x += s
	var y: float = -half_h
	while y < half_h:
		draw_line(Vector2(-half_w, y), Vector2(half_w, y), mortar, 1.0)
		y += s


# ── Per-theme decoration passes ───────────────────────────────────────────
func _draw_great_hall_decor(half_w: float, half_h: float) -> void:
	# Long central table + benches, throne at the far north wall, banners on
	# the sides, and hearth pits in the corners.
	# Throne.
	draw_rect(Rect2(-30, -half_h + WALL_THICKNESS + 8, 60, 40),
		Color(0.35, 0.20, 0.10))
	draw_rect(Rect2(-25, -half_h + WALL_THICKNESS + 12, 50, 6),
		accent_color.darkened(0.15))
	# Long central table.
	draw_rect(Rect2(-100, -20, 200, 40),
		Color(0.42, 0.28, 0.14))
	draw_rect(Rect2(-100, -22, 200, 4),
		trim_color.darkened(0.15))
	# Benches.
	draw_rect(Rect2(-100, 24, 200, 10),
		Color(0.36, 0.22, 0.10))
	draw_rect(Rect2(-100, -34, 200, 10),
		Color(0.36, 0.22, 0.10))
	# Wall banners — 4 hanging strips on each side.
	for i: int in range(3):
		var bx: float = -half_w + WALL_THICKNESS + 8 + float(i) * 60.0
		_draw_banner(Vector2(bx, -half_h + WALL_THICKNESS + 4), accent_color)
	for i: int in range(3):
		var bx: float = half_w - WALL_THICKNESS - 16 - float(i) * 60.0
		_draw_banner(Vector2(bx, -half_h + WALL_THICKNESS + 4), accent_color)
	# Hearth in the SE corner.
	_draw_hearth(Vector2(half_w - 60, half_h - 80))


func _draw_tavern_decor(half_w: float, half_h: float) -> void:
	# Bar counter along the north wall, kegs behind it, round tables with
	# stools in the main area.
	draw_rect(Rect2(-half_w + WALL_THICKNESS + 20, -half_h + WALL_THICKNESS + 8,
		half_w * 2 - WALL_THICKNESS * 2 - 40, 26),
		Color(0.44, 0.28, 0.14))
	draw_rect(Rect2(-half_w + WALL_THICKNESS + 20, -half_h + WALL_THICKNESS + 6,
		half_w * 2 - WALL_THICKNESS * 2 - 40, 4),
		trim_color)
	# Kegs behind bar.
	for i: int in range(4):
		var kx: float = -100 + float(i) * 60
		_draw_keg(Vector2(kx, -half_h + WALL_THICKNESS + 22))
	# Two round tables in the middle.
	_draw_round_table(Vector2(-80, 30))
	_draw_round_table(Vector2( 80, 30))
	# Hearth on the west wall.
	_draw_hearth(Vector2(-half_w + WALL_THICKNESS + 50, 20))


func _draw_chapel_decor(half_w: float, half_h: float) -> void:
	# Altar at the north wall, pews down the center aisle, candles on the
	# altar. Chapel skips the hearth (torches instead).
	draw_rect(Rect2(-40, -half_h + WALL_THICKNESS + 10, 80, 26),
		Color(0.62, 0.60, 0.55))
	draw_rect(Rect2(-40, -half_h + WALL_THICKNESS + 8, 80, 4),
		accent_color)
	# Two candles on the altar.
	draw_circle(Vector2(-24, -half_h + WALL_THICKNESS + 4), 3, accent_color)
	draw_circle(Vector2( 24, -half_h + WALL_THICKNESS + 4), 3, accent_color)
	# Pews down both sides of a center aisle.
	for row: int in range(3):
		var y: float = -30 + float(row) * 60
		draw_rect(Rect2(-half_w + WALL_THICKNESS + 30, y, 80, 18),
			Color(0.50, 0.40, 0.30))
		draw_rect(Rect2(half_w - WALL_THICKNESS - 110, y, 80, 18),
			Color(0.50, 0.40, 0.30))


func _draw_warehouse_decor(half_w: float, half_h: float) -> void:
	# Stacks of crates, sacks along the walls.
	for i: int in range(5):
		var cx: float = -half_w + WALL_THICKNESS + 40 + float(i) * 60
		_draw_crate(Vector2(cx, -half_h + WALL_THICKNESS + 30))
	for i: int in range(4):
		var cx: float = -half_w + WALL_THICKNESS + 60 + float(i) * 80
		_draw_crate(Vector2(cx, -20))
	# Sacks along east wall.
	for i: int in range(3):
		var y: float = -60 + float(i) * 50
		_draw_sack(Vector2(half_w - WALL_THICKNESS - 30, y))


func _draw_house_decor(half_w: float, half_h: float) -> void:
	# Bed in NE corner, chest, table with stool, small hearth on west wall.
	# Bed.
	draw_rect(Rect2(half_w - 90, -half_h + WALL_THICKNESS + 12, 60, 34),
		Color(0.50, 0.30, 0.16))
	draw_rect(Rect2(half_w - 88, -half_h + WALL_THICKNESS + 14, 56, 12),
		Color(0.88, 0.80, 0.62))
	draw_rect(Rect2(half_w - 88, -half_h + WALL_THICKNESS + 24, 56, 22),
		Color(0.72, 0.32, 0.20))
	# Table + stool.
	draw_rect(Rect2(-40, 20, 60, 26), Color(0.42, 0.28, 0.14))
	draw_circle(Vector2(30, 40), 8, Color(0.36, 0.22, 0.12))
	# Chest.
	draw_rect(Rect2(-half_w + WALL_THICKNESS + 20, -60, 30, 20),
		Color(0.35, 0.22, 0.10))
	draw_rect(Rect2(-half_w + WALL_THICKNESS + 20, -62, 30, 4), trim_color)
	# Hearth on west wall.
	_draw_hearth(Vector2(-half_w + WALL_THICKNESS + 40, 50))


# ── Reusable decoration primitives ─────────────────────────────────────────
func _draw_banner(top: Vector2, col: Color) -> void:
	draw_rect(Rect2(top.x - 6, top.y, 12, 44), col.darkened(0.10))
	draw_colored_polygon(PackedVector2Array([
		Vector2(top.x - 6, top.y + 44),
		Vector2(top.x + 6, top.y + 44),
		Vector2(top.x,     top.y + 52)]), col.darkened(0.10))


func _draw_hearth(center: Vector2) -> void:
	# Stone circle with orange flames.
	draw_circle(center, 22, Color(0.30, 0.25, 0.22))
	draw_circle(center, 18, Color(0.20, 0.15, 0.12))
	# Flame flicker — sinusoidal on _time.
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var flame_r: float = 10.0 + sin(t * 4.0) * 1.5
	draw_circle(center, flame_r, Color(0.95, 0.55, 0.15))
	draw_circle(center, flame_r * 0.6, Color(0.95, 0.85, 0.25))


func _draw_round_table(center: Vector2) -> void:
	draw_circle(center, 20, Color(0.42, 0.28, 0.14))
	draw_circle(center, 18, Color(0.55, 0.38, 0.18))
	# Two stools nearby.
	draw_circle(center + Vector2(-28, 0), 6, Color(0.36, 0.22, 0.10))
	draw_circle(center + Vector2(28,  0), 6, Color(0.36, 0.22, 0.10))


func _draw_keg(base: Vector2) -> void:
	draw_rect(Rect2(base.x - 10, base.y - 18, 20, 22),
		Color(0.42, 0.28, 0.14))
	draw_rect(Rect2(base.x - 10, base.y - 14, 20, 3), trim_color)
	draw_rect(Rect2(base.x - 10, base.y - 4, 20, 3), trim_color)


func _draw_crate(base: Vector2) -> void:
	draw_rect(Rect2(base.x - 14, base.y - 14, 28, 28),
		Color(0.50, 0.35, 0.18))
	draw_line(Vector2(base.x - 14, base.y), Vector2(base.x + 14, base.y),
		Color(0.30, 0.20, 0.08), 1.5)
	draw_line(Vector2(base.x, base.y - 14), Vector2(base.x, base.y + 14),
		Color(0.30, 0.20, 0.08), 1.5)


func _draw_sack(base: Vector2) -> void:
	draw_circle(base, 12, Color(0.72, 0.58, 0.30))
	draw_circle(base + Vector2(0, -8), 6, Color(0.72, 0.58, 0.30))


func _process(_delta: float) -> void:
	# Redraw for animated hearth flames. Cheap — only decorations tick.
	queue_redraw()
