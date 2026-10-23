extends Node2D

## A designed multi-room dungeon, instanced into the far interior band (v1.5.3).
##
## The SERVER owns the canonical layout and pushes it on entry (see
## _handle_dungeon_enter); this scene builds the walkable map from that payload —
## one source of truth, no duplicated map data. It reuses the interior enter/exit
## machinery (World anchors it, un-clamps the camera, teleports the player), and
## the monsters + ore inside are ordinary world_entities the server seeded, so
## combat / gather / respawn all come for free.
##
## Layout model: fill a grid with WALL, carve each room rect to FLOOR, then carve
## a 3-wide L-corridor between each CONSECUTIVE room's centre — connectivity from
## the entry room to the boss chamber is guaranteed by construction.

const TILE := 32.0
const FLOOR := 1
const WALL  := 0

# Cave palette.
const VOID_C      := Color(0.03, 0.03, 0.05)
const FLOOR_C     := Color(0.20, 0.18, 0.17)
const FLOOR_C2    := Color(0.24, 0.21, 0.19)
const WALL_C      := Color(0.11, 0.10, 0.12)
const WALL_EDGE_C := Color(0.32, 0.28, 0.26)   # lit rim where wall meets floor
const PORTAL_C    := Color(0.45, 0.75, 0.95)

var dungeon_id: String = ""
var region_tx: int = 0
var region_ty: int = 0
var gw: int = 0
var gh: int = 0
var entry_cell: Vector2i = Vector2i.ZERO
var _grid: Array = []           # _grid[cy][cx] = FLOOR | WALL
var _walls: StaticBody2D = null
var _exit_area: Area2D = null
var _exit_busy: bool = false
var _exit_armed: bool = false   # grace so spawning near the portal doesn't exit

func setup(layout: Dictionary) -> void:
	dungeon_id = str(layout.get("name", "Dungeon"))
	region_tx = int(layout.get("region_tx", 0))
	region_ty = int(layout.get("region_ty", 0))
	gw = maxi(4, int(layout.get("w", 40)))
	gh = maxi(4, int(layout.get("h", 30)))
	var ec: Array = layout.get("entry_cell", [1, 1]) as Array
	entry_cell = Vector2i(int(ec[0]), int(ec[1]))
	_carve(layout.get("rooms", []) as Array)
	_build_collision()
	_build_exit()
	z_index = -5   # render under the player + monsters + ore
	# Arm the exit portal after a short grace so the arrival spawn (a couple
	# tiles from the portal) can't immediately re-trigger it.
	get_tree().create_timer(1.2).timeout.connect(func() -> void: _exit_armed = true)
	queue_redraw()

# ── Grid carving ──────────────────────────────────────────────────────────────
func _carve(rooms: Array) -> void:
	_grid.clear()
	for _y in range(gh):
		var row: Array = []
		row.resize(gw)
		row.fill(WALL)
		_grid.append(row)
	var centers: Array[Vector2i] = []
	for r: Variant in rooms:
		var rr := r as Array
		var cx := int(rr[0]); var cy := int(rr[1])
		var w := int(rr[2]);  var h := int(rr[3])
		for y in range(cy, cy + h):
			for x in range(cx, cx + w):
				_set_floor(x, y)
		centers.append(Vector2i(cx + int(w * 0.5), cy + int(h * 0.5)))
	# Connect consecutive room centres with 3-wide L-corridors.
	for i in range(centers.size() - 1):
		_carve_corridor(centers[i], centers[i + 1])

func _set_floor(x: int, y: int) -> void:
	if x >= 0 and x < gw and y >= 0 and y < gh:
		_grid[y][x] = FLOOR

func _carve_corridor(a: Vector2i, b: Vector2i) -> void:
	# Horizontal strip at a.y, then vertical strip at b.x — both 3 wide.
	var x0 := mini(a.x, b.x)
	var x1 := maxi(a.x, b.x)
	for x in range(x0, x1 + 1):
		for dy in range(-1, 2):
			_set_floor(x, a.y + dy)
	var y0 := mini(a.y, b.y)
	var y1 := maxi(a.y, b.y)
	for y in range(y0, y1 + 1):
		for dx in range(-1, 2):
			_set_floor(b.x + dx, y)

func is_floor(x: int, y: int) -> bool:
	if x < 0 or x >= gw or y < 0 or y >= gh:
		return false
	return _grid[y][x] == FLOOR

# ── Collision — one StaticBody2D, greedy per-row wall runs ─────────────────────
func _build_collision() -> void:
	_walls = StaticBody2D.new()
	_walls.collision_layer = 2   # world layer, same as Ground's impassable tiles
	_walls.collision_mask  = 0
	add_child(_walls)
	for y in range(gh):
		var x := 0
		while x < gw:
			if _grid[y][x] == WALL:
				var start := x
				while x < gw and _grid[y][x] == WALL:
					x += 1
				var run := x - start
				var cs := CollisionShape2D.new()
				var rect := RectangleShape2D.new()
				rect.size = Vector2(run * TILE, TILE)
				cs.shape = rect
				cs.position = Vector2((start + run * 0.5) * TILE, (y + 0.5) * TILE)
				_walls.add_child(cs)
			else:
				x += 1

# ── Exit portal at the entry room — walk onto it OR click to leave ────────────
func _build_exit() -> void:
	_exit_area = Area2D.new()
	_exit_area.collision_layer = 4
	_exit_area.collision_mask  = 1
	_exit_area.input_pickable  = true
	_exit_area.add_to_group("interactable")
	_exit_area.position = Vector2((entry_cell.x + 0.5) * TILE, (entry_cell.y + 0.5) * TILE)
	add_child(_exit_area)
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(48, 48)
	cs.shape = rect
	_exit_area.add_child(cs)
	_exit_area.body_entered.connect(func(body: Node) -> void:
		if body != null and body.is_in_group("player"):
			_do_exit())
	_exit_area.input_event.connect(func(_vp: Viewport, e: InputEvent, _i: int) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_do_exit())

func _do_exit() -> void:
	if _exit_busy or not _exit_armed:
		return
	_exit_busy = true
	NetworkManager.send_exit_interior()

# ── Rendering (static — drawn once on setup) ──────────────────────────────────
func _draw() -> void:
	# Void backdrop generously beyond the grid so the far band never shows.
	draw_rect(Rect2(-600, -600, gw * TILE + 1200, gh * TILE + 1200), VOID_C)
	for y in range(gh):
		for x in range(gw):
			var p := Vector2(x * TILE, y * TILE)
			if _grid[y][x] == FLOOR:
				var tint := FLOOR_C if ((x + y) & 1) == 0 else FLOOR_C2
				draw_rect(Rect2(p, Vector2(TILE, TILE)), tint)
			else:
				# Only draw wall cells that border floor — the lit cave rim.
				if _borders_floor(x, y):
					draw_rect(Rect2(p, Vector2(TILE, TILE)), WALL_C)
					draw_rect(Rect2(p + Vector2(2, 2), Vector2(TILE - 4, 3)), WALL_EDGE_C)
	# Exit portal glyph at the entry cell.
	var ep := Vector2((entry_cell.x + 0.5) * TILE, (entry_cell.y + 0.5) * TILE)
	draw_circle(ep, 13.0, Color(PORTAL_C, 0.30))
	draw_arc(ep, 12.0, 0.0, TAU, 20, PORTAL_C, 2.0)
	draw_arc(ep, 7.0, 0.0, TAU, 16, Color(PORTAL_C, 0.7), 1.5)

func _borders_floor(x: int, y: int) -> bool:
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
		if is_floor(x + d.x, y + d.y):
			return true
	return false
