extends CanvasLayer

## Idle minigame overlay — spawned when a timed batch craft starts. Picks
## a variant per round (rhythm-tap OR puzzle-maze) so play stays varied,
## and rewards each completed round by trimming 20% off the current
## `_active_craft.tick_left` + granting 5 bonus XP in the active skill.
## Fully skippable via the ✕ button; the craft timer runs regardless.
##
## Reward is delivered through `Events.craft_minigame_completed(frac, xp)`
## so HUD's active-craft state is the single owner of the tick + XP hook.
## No direct coupling — the overlay never touches `_active_craft` itself.

const REWARD_FRAC := 0.20
const REWARD_XP := 5

@onready var _root: PanelContainer = null
@onready var _round_container: Control = null
@onready var _status_lbl: Label = null

var _skill_hint: String = ""
var _variant: String = ""     # "rhythm" | "maze"
var _round_active: bool = false

# Rhythm state
var _notes: Array = []        # [{"pos": float, "hit": bool}]
var _rhythm_scroll: float = 0.0
var _RHYTHM_SPEED := 120.0    # px/s
var _RHYTHM_BAR_W := 260.0
var _RHYTHM_ZONE_X := 200.0
var _RHYTHM_ZONE_W := 32.0

# Maze state — 5×5 grid, drag from START to END avoiding walls.
var _maze: Array = []                     # [[bool]] — true = wall
var _maze_pos: Vector2i = Vector2i.ZERO
var _maze_start: Vector2i = Vector2i.ZERO
var _maze_end: Vector2i = Vector2i.ZERO
var _MAZE_N := 5
var _MAZE_CELL := 40.0

func _ready() -> void:
	layer = 60   # above HUD panels
	_build_root()
	_start_new_round()

func set_skill(skill: String) -> void:
	_skill_hint = skill

func _build_root() -> void:
	_root = PanelContainer.new()
	_root.add_theme_stylebox_override("panel", _sb(Color(0.06, 0.04, 0.02, 0.95),
		Color(0.85, 0.45, 0.10), 3))
	_root.anchor_left  = 1.0; _root.anchor_right  = 1.0
	_root.anchor_top   = 1.0; _root.anchor_bottom = 1.0
	_root.offset_left  = -320; _root.offset_right  = -20
	_root.offset_top   = -260; _root.offset_bottom = -20
	add_child(_root)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_root.add_child(v)

	var hdr := HBoxContainer.new()
	v.add_child(hdr)
	var title := Label.new()
	title.text = "🎯  Bonus Round"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color(1.00, 0.75, 0.20))
	title.add_theme_font_size_override("font_size", 14)
	hdr.add_child(title)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(28, 24)
	close.tooltip_text = "Close (craft continues)"
	close.pressed.connect(func() -> void: queue_free())
	hdr.add_child(close)

	_status_lbl = Label.new()
	_status_lbl.text = "Complete a round to speed up the current craft."
	_status_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.72))
	_status_lbl.add_theme_font_size_override("font_size", 10)
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status_lbl)

	_round_container = Control.new()
	_round_container.custom_minimum_size = Vector2(280, 200)
	_round_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_round_container.draw.connect(_draw_round)
	_round_container.gui_input.connect(_on_round_input)
	_round_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_round_container.focus_mode = Control.FOCUS_ALL
	v.add_child(_round_container)

func _sb(bg: Color, border: Color, w: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(w)
	s.set_corner_radius_all(3)
	return s

## Pick a random variant, reset state, redraw. Called on _ready + after
## every completion.
func _start_new_round() -> void:
	_variant = "rhythm" if randi() % 2 == 0 else "maze"
	_round_active = true
	match _variant:
		"rhythm":
			_notes.clear()
			for i in range(5):
				_notes.append({"pos": -float(i) * 80.0, "hit": false})
			_rhythm_scroll = 0.0
			_status_lbl.text = "Press SPACE when a note is in the target zone."
		"maze":
			_build_maze()
			_status_lbl.text = "Drag the pointer from GREEN to GOLD, avoiding walls."
	_round_container.grab_focus()
	_round_container.queue_redraw()

func _build_maze() -> void:
	# Random-walls layout with a guaranteed clear diagonal so it's always
	# solvable. ~25% wall density; start top-left, end bottom-right.
	_maze.clear()
	for y in range(_MAZE_N):
		var row: Array = []
		for x in range(_MAZE_N):
			var is_wall: bool = randf() < 0.25
			# Clear the diagonal path so the maze is always solvable.
			if x == y or abs(x - y) <= 1:
				is_wall = false
			row.append(is_wall)
		_maze.append(row)
	_maze_start = Vector2i(0, 0)
	_maze_end = Vector2i(_MAZE_N - 1, _MAZE_N - 1)
	_maze[_maze_start.y][_maze_start.x] = false
	_maze[_maze_end.y][_maze_end.x] = false
	_maze_pos = _maze_start

func _process(delta: float) -> void:
	if not _round_active:
		return
	if _variant == "rhythm":
		_rhythm_scroll += _RHYTHM_SPEED * delta
		# Fail if any un-hit note has scrolled past the zone.
		for note_v: Variant in _notes:
			var note: Dictionary = note_v as Dictionary
			var x: float = float(note["pos"]) + _rhythm_scroll
			if x > _RHYTHM_ZONE_X + _RHYTHM_ZONE_W + 20.0 and not bool(note["hit"]):
				_fail_round("Missed a note.")
				return
		# All hit? End round.
		var all_hit := true
		for note_v: Variant in _notes:
			if not bool((note_v as Dictionary)["hit"]):
				all_hit = false
				break
		if all_hit:
			_complete_round()
			return
	_round_container.queue_redraw()

func _on_round_input(event: InputEvent) -> void:
	if not _round_active:
		return
	if _variant == "rhythm":
		if event is InputEventKey:
			var kev := event as InputEventKey
			if kev.pressed and not kev.echo and kev.keycode == KEY_SPACE:
				_rhythm_hit()
	elif _variant == "maze":
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				_maze_click(mb.position)
		elif event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT != 0:
			_maze_click((event as InputEventMouseMotion).position)

func _rhythm_hit() -> void:
	# Find the nearest un-hit note in the target zone.
	for note_v: Variant in _notes:
		var note: Dictionary = note_v as Dictionary
		if bool(note["hit"]):
			continue
		var x: float = float(note["pos"]) + _rhythm_scroll
		if x >= _RHYTHM_ZONE_X - 8.0 and x <= _RHYTHM_ZONE_X + _RHYTHM_ZONE_W + 8.0:
			note["hit"] = true
			return
	# Missed the zone entirely — small penalty: fail the round.
	_fail_round("Off-beat.")

func _maze_click(pos: Vector2) -> void:
	# Map mouse pos to grid cell using the maze render offset.
	var origin_x: float = (_round_container.size.x - _MAZE_N * _MAZE_CELL) * 0.5
	var origin_y: float = 20.0
	var gx: int = int((pos.x - origin_x) / _MAZE_CELL)
	var gy: int = int((pos.y - origin_y) / _MAZE_CELL)
	if gx < 0 or gx >= _MAZE_N or gy < 0 or gy >= _MAZE_N:
		return
	if (_maze[gy][gx] as bool):
		return
	# Must be adjacent (or same) to current pos to prevent teleport-solves.
	var dx := absi(gx - _maze_pos.x)
	var dy := absi(gy - _maze_pos.y)
	if dx + dy > 1:
		return
	_maze_pos = Vector2i(gx, gy)
	_round_container.queue_redraw()
	if _maze_pos == _maze_end:
		_complete_round()

func _complete_round() -> void:
	_round_active = false
	_status_lbl.text = "Nice! +%d %s XP, %d%% faster." % [REWARD_XP,
		_skill_hint.capitalize() if _skill_hint != "" else "Craft",
		int(REWARD_FRAC * 100.0)]
	Events.craft_minigame_completed.emit(REWARD_FRAC, REWARD_XP)
	# Auto-start the next round after a short beat so a player can grind
	# rounds for the whole batch.
	get_tree().create_timer(0.9).timeout.connect(func() -> void:
		if is_instance_valid(self):
			_start_new_round())

func _fail_round(reason: String) -> void:
	_round_active = false
	_status_lbl.text = "%s No boost. Next round in a moment…" % reason
	get_tree().create_timer(1.2).timeout.connect(func() -> void:
		if is_instance_valid(self):
			_start_new_round())

func _draw_round() -> void:
	var w: float = _round_container.size.x
	var h: float = _round_container.size.y
	if w < 4.0 or h < 4.0:
		return
	match _variant:
		"rhythm":
			# Track outline
			var track_y := h * 0.5
			_round_container.draw_rect(Rect2(10.0, track_y - 12.0,
				_RHYTHM_BAR_W, 24.0),
				Color(0.10, 0.06, 0.04), true)
			# Target zone
			_round_container.draw_rect(Rect2(_RHYTHM_ZONE_X, track_y - 14.0,
				_RHYTHM_ZONE_W, 28.0),
				Color(0.20, 0.75, 0.30, 0.55), true)
			_round_container.draw_rect(Rect2(_RHYTHM_ZONE_X, track_y - 14.0,
				_RHYTHM_ZONE_W, 28.0),
				Color(0.30, 0.95, 0.40), false, 1.5)
			# Notes
			for note_v: Variant in _notes:
				var note: Dictionary = note_v as Dictionary
				var x: float = float(note["pos"]) + _rhythm_scroll
				if x < -20.0 or x > _RHYTHM_BAR_W + 20.0:
					continue
				var col := Color(0.35, 0.75, 1.00) if not bool(note["hit"]) \
					else Color(0.30, 0.30, 0.35, 0.5)
				_round_container.draw_circle(Vector2(10.0 + x, track_y), 8.0, col)
		"maze":
			var origin_x: float = (w - _MAZE_N * _MAZE_CELL) * 0.5
			var origin_y: float = 20.0
			for y in range(_MAZE_N):
				for x in range(_MAZE_N):
					var cell := Rect2(origin_x + x * _MAZE_CELL,
						origin_y + y * _MAZE_CELL, _MAZE_CELL - 2.0, _MAZE_CELL - 2.0)
					var is_wall: bool = _maze[y][x] as bool
					var col: Color = Color(0.20, 0.14, 0.08) if is_wall \
						else Color(0.32, 0.22, 0.14)
					_round_container.draw_rect(cell, col, true)
			# Start (green), end (gold), pointer (blue).
			var sx := origin_x + _maze_start.x * _MAZE_CELL + _MAZE_CELL * 0.5
			var sy := origin_y + _maze_start.y * _MAZE_CELL + _MAZE_CELL * 0.5
			_round_container.draw_circle(Vector2(sx, sy), 8.0,
				Color(0.30, 0.85, 0.30))
			var ex := origin_x + _maze_end.x * _MAZE_CELL + _MAZE_CELL * 0.5
			var ey := origin_y + _maze_end.y * _MAZE_CELL + _MAZE_CELL * 0.5
			_round_container.draw_circle(Vector2(ex, ey), 8.0,
				Color(1.00, 0.80, 0.20))
			var px := origin_x + _maze_pos.x * _MAZE_CELL + _MAZE_CELL * 0.5
			var py := origin_y + _maze_pos.y * _MAZE_CELL + _MAZE_CELL * 0.5
			_round_container.draw_circle(Vector2(px, py), 6.0,
				Color(0.55, 0.75, 1.00))
			_round_container.draw_arc(Vector2(px, py), 6.0, 0.0, TAU, 24,
				Color(0.15, 0.30, 0.55), 1.5)
