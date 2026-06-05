extends Node2D

## Renders a remote player received from the server.
## Position is lerped toward target_pos for smooth movement.

const Boats = preload("res://scripts/Boat.gd")
const SPEED := 200.0   # lerp speed (px/s) — slightly faster than local to catch up

var _facing: float = 1.0

# Set via metadata by NetworkManager
var _username: String  = ""
var _target:   Vector2 = Vector2.ZERO
var _moving:   bool    = false
var _walk_t:   float   = 0.0
var _is_idle:  bool    = false

# Idle-ghost cosmetic AI: walk to real nearby resource nodes and mime gathering
const IDLE_SPEED := 90.0
const IDLE_SEEK_RADIUS := 700.0
const IDLE_GATHER_TYPES := ["tree", "rock", "fish", "herb"]
var _idle_node: Node2D = null
var _idle_gather_t: float = 0.0
var _idle_action: String = ""

func _ready() -> void:
	_username = get_meta("username", "?")
	_is_idle  = bool(get_meta("is_idle", false))
	_target   = global_position
	z_index   = 1
	modulate.a = 0.42 if _is_idle else 1.0
	add_to_group("other_player")
	queue_redraw()

func set_idle(idle: bool) -> void:
	_is_idle   = idle
	modulate.a = 0.42 if idle else 1.0

func _process(delta: float) -> void:
	# Idle ghosts run a local cosmetic AI: seek real resource nodes and mime
	# gathering, rather than following the server's random wander broadcasts.
	if _is_idle:
		_idle_process(delta)
		queue_redraw()
		return

	# Pick up target_pos updates written by NetworkManager
	if has_meta("target_pos"):
		_target = get_meta("target_pos") as Vector2

	var dist := global_position.distance_to(_target)
	if dist > 2.0:
		if absf(_target.x - global_position.x) > 0.5:
			_facing = signf(_target.x - global_position.x)
		global_position = global_position.move_toward(_target, SPEED * delta)
		_moving  = true
		_walk_t += delta
	else:
		if _moving:
			_moving = false
			_walk_t = 0.0
	queue_redraw()

func _idle_process(delta: float) -> void:
	# Mid-gather: stand and swing for a few seconds, then look for a new node.
	if _idle_gather_t > 0.0:
		_idle_gather_t -= delta
		_walk_t += delta
		_moving = false
		if _idle_gather_t <= 0.0:
			_idle_node = null
		return
	if _idle_node == null or not is_instance_valid(_idle_node):
		_idle_node = _find_nearest_node()
	if _idle_node == null:
		_moving = false
		return
	var np := _idle_node.global_position
	if absf(np.x - global_position.x) > 0.5:
		_facing = signf(np.x - global_position.x)
	if global_position.distance_to(np) > 40.0:
		global_position = global_position.move_toward(np, IDLE_SPEED * delta)
		_moving = true
		_walk_t += delta
	else:
		_moving = false
		_idle_action = _action_for(_idle_node)
		_idle_gather_t = 3.5

func _find_nearest_node() -> Node2D:
	var best: Node2D = null
	var best_d := IDLE_SEEK_RADIUS * IDLE_SEEK_RADIUS
	for n: Node in get_tree().get_nodes_in_group("interactable"):
		if str(n.get("interactable_type_str")) in IDLE_GATHER_TYPES:
			var d := global_position.distance_squared_to((n as Node2D).global_position)
			if d < best_d:
				best_d = d
				best = n as Node2D
	return best

func _action_for(node: Node2D) -> String:
	match str(node.get("interactable_type_str")):
		"rock": return "mine"
		"fish": return "fish"
		_:      return "chop"

func _draw() -> void:
	var boat := str(get_meta("boat", ""))
	var boating := Boats.is_boat(boat)
	var gathering := _is_idle and _idle_gather_t > 0.0
	var sw := sin(_walk_t * 9.0) * 3.5 if (_moving and not boating) else 0.0
	var arm_a := sin(_walk_t * 9.0) * 0.3 if (_moving and not boating) else 0.0
	var right := arm_a
	if gathering:
		right = sin(_walk_t * 8.0) * 0.8   # mining/chopping swing
	var appr: Variant = get_meta("appearance", {})
	var equip: Variant = get_meta("equipment", {})
	Appearance.draw_character(self, appr, {
		"walk_sw":      sw,
		"left_arm":     -arm_a,
		"right_arm":    right,
		"acting":       gathering,
		"action_type":  _idle_action if gathering else "",
		"equip":        (equip as Dictionary) if equip is Dictionary else {},
	})
	if boating:
		draw_set_transform(Vector2(0, 6), 0.0, Vector2.ONE)
		Boats.draw_boat(self, boat, _facing)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Username label above head (yellow tint so it's distinct from NPCs)
	if not _username.is_empty():
		var font := ThemeDB.fallback_font
		if font != null:
			var tw    := font.get_string_size(_username, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
			draw_string(font, Vector2(-tw * 0.5, -36), _username,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.95, 0.88, 0.25))
