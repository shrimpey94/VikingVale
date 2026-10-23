extends Node2D

## Owner-only visual of an assigned thrall (V1.5.5). Cosmetic — the server owns
## all thrall LOGIC (offline sim, loot, xp). This node makes the thrall ACTIVELY
## walk to real resource/monster nodes near its town, "work" one, then move to the
## next. If the town has no matching nodes loaded (player away, or the admin
## hasn't placed any yet) it idles near its work spot. Driven by the roster push
## via World._on_thralls_updated.

const MOVE_SPEED    := 62.0
const WORK_TIME     := 2.6
const SEARCH_RADIUS := 34.0 * 32.0     # keep the thrall near its assigned town
const ARRIVE_DIST   := 22.0

var appr: Dictionary = {}
var thrall_name: String = ""
var skill: String = ""            # woodcutting/mining/fishing/foraging/melee
var _anchor: Vector2 = Vector2.ZERO
var _spawned: bool = false

enum State { SEEK, WALK, WORK }
var _state: int = State.SEEK
var _target: Node2D = null
var _last_target: Node2D = null
var _work_timer: float = 0.0
var _seek_cd: float = 0.0
var _t: float = 0.0
var _moving: bool = false
var _face: float = 1.0
var _prev_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	z_index = 3
	_t = float(absi(str(get_instance_id()).hash()) % 1000) * 0.01

func apply_state(d: Dictionary) -> void:
	var raw := d.get("appearance", {}) as Dictionary
	thrall_name = str(d.get("name", ""))
	skill = str(d.get("skill", ""))
	appr = raw if not raw.is_empty() else _appr_from_id(str(d.get("id", "")))
	var spot: Variant = d.get("work_spot", null)
	if spot is Array and (spot as Array).size() >= 2:
		_anchor = Vector2(float((spot as Array)[0]), float((spot as Array)[1]))
		if not _spawned:
			position = _anchor
			_prev_pos = _anchor
			_spawned = true
	queue_redraw()

## Deterministic pseudo-appearance from the id, used only if the server sent no
## stored appearance (bit-shifts dodge the integer-division warning-as-error).
func _appr_from_id(id: String) -> Dictionary:
	var h := absi(id.hash())
	return {
		"skin":       h % 8,
		"hair_style": (h >> 3) % 6,
		"hair_color": (h >> 6) % 8,
		"beard":      (h >> 9) % 5,
		"body":       (h >> 12) % 3,
		"tunic":      (h >> 15) % 6,
	}

func _process(delta: float) -> void:
	_t += delta
	_seek_cd -= delta
	_moving = false
	match _state:
		State.SEEK:
			if _seek_cd <= 0.0:
				_seek_cd = 0.8
				_target = _find_work_node()
				if _target != null:
					_last_target = _target
					_state = State.WALK
			if position.distance_to(_anchor) > 6.0:
				position = position.move_toward(_anchor, MOVE_SPEED * 0.4 * delta)
				_moving = true
		State.WALK:
			if not is_instance_valid(_target):
				_state = State.SEEK
				_seek_cd = 0.0
			else:
				var dest: Vector2 = (_target as Node2D).global_position
				position = position.move_toward(dest, MOVE_SPEED * delta)
				_moving = true
				if position.distance_to(dest) <= ARRIVE_DIST:
					_state = State.WORK
					_work_timer = WORK_TIME
		State.WORK:
			_work_timer -= delta
			if _work_timer <= 0.0:
				_state = State.SEEK
				_seek_cd = 0.3
	# Face the direction of travel (flip only the character, not the name tag).
	var moved := position - _prev_pos
	if absf(moved.x) > 0.05:
		_face = signf(moved.x)
	_prev_pos = position
	queue_redraw()

## Nearest matching work node within SEARCH_RADIUS of the anchor. Prefers a node
## other than the one just worked, but falls back to it if it's the only one.
func _find_work_node() -> Node2D:
	var best: Node2D = null
	var best_d := SEARCH_RADIUS
	var fb: Node2D = null
	var fb_d := SEARCH_RADIUS
	var group := "monster" if skill == "melee" else "interactable"
	for it: Node in get_tree().get_nodes_in_group(group):
		var n := it as Node2D
		if n == null or not is_instance_valid(n):
			continue
		if skill == "melee":
			if not bool(n.get("is_alive")):
				continue
		elif str(n.get("required_skill")) != skill:
			continue
		var dd := _anchor.distance_to(n.global_position)
		if dd >= SEARCH_RADIUS:
			continue
		if dd < fb_d:
			fb_d = dd
			fb = n
		if n != _last_target and dd < best_d:
			best_d = dd
			best = n
	return best if best != null else fb

func _draw() -> void:
	var working := _state == State.WORK
	var bob: float = (-absf(sin(_t * 11.0)) * 1.5) if _moving else (sin(_t * 2.0) * 1.0)
	var legsw: float = sin(_t * 11.0) * 3.5 if _moving else 0.0
	var armsw: float = 0.0
	if working:
		armsw = sin(_t * 7.0) * 0.75     # gathering swing
	elif _moving:
		armsw = sin(_t * 11.0) * 0.35
	draw_set_transform(Vector2(0, bob), 0.0, Vector2(_face, 1.0))
	Appearance.draw_character(self, appr, {
		"walk_sw":     legsw,
		"left_arm":    -armsw,
		"right_arm":   armsw,
		"acting":      false,
		"action_type": "",
		"equip":       {},
	})
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var font := ThemeDB.fallback_font
	if font != null and thrall_name != "":
		draw_string(font, Vector2(-26, -42), thrall_name,
			HORIZONTAL_ALIGNMENT_CENTER, 52, 9, Color(0.90, 0.84, 0.55))
