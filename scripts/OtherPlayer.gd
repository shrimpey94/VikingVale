extends Node2D

## Renders a remote player received from the server.
## Position is lerped toward target_pos for smooth movement.

const Boats = preload("res://scripts/Boat.gd")
const SPEED := 200.0   # legacy move-toward speed (kept for reference)
# Exponential position smoothing: higher = snappier (less lag), lower = smoother.
# ~14 keeps up with the ~10Hz move stream while gliding evenly between packets.
const MOVE_SMOOTH := 14.0
# Distance past which we treat an incoming position as a TELEPORT (respawn / warp /
# director staging) and snap, instead of smoothing a long slide across the map.
const TELEPORT_SNAP := 320.0

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
	# Seed the PvP flag from the join payload so a player who was already
	# flagged before we spawned this node still renders red (Phase 8).
	_pvp_flagged = bool(get_meta("pvp_flagged", false))
	add_to_group("other_player")
	queue_redraw()

func set_idle(idle: bool) -> void:
	_is_idle   = idle
	modulate.a = 0.42 if idle else 1.0

## PvP flag mirror — HUD dispatches `pvp_flag_changed` and iterates the
## other_player group to call this. Flagged players render their username
## label in red so both parties know the fight is legal.
var _pvp_flagged: bool = false
func set_pvp_flagged(flagged: bool) -> void:
	_pvp_flagged = flagged
	queue_redraw()

func is_pvp_flagged() -> bool:
	return _pvp_flagged

## Melee swing animation (Phase 8) — HUD calls this on the attacker's node so a
## DEFENDER sees the remote player visibly swing at them, not a silent ghost.
const SWING_DUR := 0.32
var _swing_t: float = 0.0
func play_swing(target_x: float) -> void:
	_swing_t = SWING_DUR
	if absf(target_x - global_position.x) > 1.0:
		_facing = signf(target_x - global_position.x)
	queue_redraw()

## Gather mime for a LIVE player (v1.6.4). The server broadcasts `player_action`
## on gather-start; we swing repeatedly at the node for a few seconds so a
## spectated bot visibly chops/mines instead of standing motionless. Each fresh
## broadcast refreshes the window.
const GATHER_MIME_DUR := 3.0
const GATHER_SWING_EVERY := 0.7
# If the gather target jumps more than this from where the avatar stands, the bot
# has walked to a new node — drop the gather hold and follow (no sit-then-snap).
const GATHER_HOLD_RANGE := 48.0
var _gather_t: float = 0.0
var _gather_cd: float = 0.0
# Which tool the swing draws: "chop" (axe) / "mine" (pick) / "fish" (rod) /
# "forage" (bare hand). Derived from the node being worked so a spectated bot
# chops with an axe, mines with a pick, and picks herbs/sticks/stones bare-handed.
var _gather_action: String = "chop"
var _gather_tool: String = ""     # tiered tool id from the gatherer (axe/pick)
func play_gather(target_x: float, target_y: float = -1.0e9, tool: String = "") -> void:
	_gather_t = GATHER_MIME_DUR
	if absf(target_x - global_position.x) > 1.0:
		_facing = signf(target_x - global_position.x)
	var ty: float = global_position.y if target_y <= -1.0e8 else target_y
	_gather_action = _action_near(Vector2(target_x, ty))
	_gather_tool = tool
	queue_redraw()

## Combat swing — a watched bot's blow. Faces the target (the monster's x) and
## triggers the melee swing arc (drawn from _swing_t with the equipped weapon), so
## a spectated fight actually LOOKS like fighting instead of standing still.
func play_attack(face_x: float = -1.0e9) -> void:
	if face_x > -1.0e8 and absf(face_x - global_position.x) > 1.0:
		_facing = signf(face_x - global_position.x)
	_swing_t = SWING_DUR
	queue_redraw()

## Map a nearby resource node to its swing action via its required_skill, so the
## tool matches the job (not a one-size hand). Falls back to "chop" if no node is
## found near the gather point (woodcutting is the most common gather).
func _action_for_node(node: Node) -> String:
	match str(node.get("required_skill")):
		"woodcutting": return "chop"
		"mining":      return "mine"
		"fishing":     return "fish"
		_:             return "forage"   # foraging herbs/sticks/stones = bare hand

func _action_near(pos: Vector2) -> String:
	var best: Node2D = null
	var best_d := 90.0 * 90.0
	for n: Node in get_tree().get_nodes_in_group("interactable"):
		var d := pos.distance_squared_to((n as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = n as Node2D
	return "chop" if best == null else _action_for_node(best)

## The combat-style marker shown above a flagged player. Style rides in the
## appearance blob (combat_style), updated by player_appearance broadcasts.
func _pvp_style_glyph() -> String:
	var appr: Variant = get_meta("appearance", {})
	var style := ""
	if appr is Dictionary:
		style = str((appr as Dictionary).get("combat_style", "melee"))
	match style:
		"ranged": return "➹"   # arrow — ranged
		"magic":  return "✦"   # star  — magic
		_:        return "⚔"   # crossed swords — melee

func _process(delta: float) -> void:
	if _swing_t > 0.0:
		_swing_t -= delta
		queue_redraw()
	# Idle ghosts run a local cosmetic AI: seek real resource nodes and mime
	# gathering, rather than following the server's random wander broadcasts.
	if _is_idle:
		_idle_process(delta)
		queue_redraw()
		return

	# Live gather mime — repeated swings while a gather broadcast is fresh, so a
	# spectated bot visibly works the node instead of standing motionless.
	# Gathering is a STAND-STILL action: swing and RETURN, never fall through to
	# the walk logic below (which had the avatar swinging AND drifting toward its
	# target at the same time — "doing multiple things at once").
	if _gather_t > 0.0:
		if has_meta("target_pos"):
			_target = get_meta("target_pos") as Vector2
		# If the bot has moved OFF the node (its position jumped away), it walked to
		# the next node — cancel the gather hold at once and resume walking, so the
		# avatar follows instead of sitting here for ~3s then snapping to catch up.
		if global_position.distance_to(_target) > GATHER_HOLD_RANGE:
			_gather_t = 0.0
		else:
			_gather_t -= delta
			_gather_cd -= delta
			if _gather_cd <= 0.0:
				_gather_cd = GATHER_SWING_EVERY
				_swing_t = SWING_DUR   # reuse the swing visual as a chop/mine
			_moving = false
			# Settle onto the node once (catch up any smoothing lag), then hold.
			if global_position.distance_to(_target) > 1.0:
				global_position = global_position.lerp(_target, 1.0 - exp(-MOVE_SMOOTH * delta))
			queue_redraw()
			return

	# Pick up target_pos updates written by NetworkManager
	if has_meta("target_pos"):
		_target = get_meta("target_pos") as Vector2

	var dist := global_position.distance_to(_target)
	if dist > TELEPORT_SNAP:
		# A real jump (respawn / director staging / warp) — snap there instead of
		# gliding across the whole map, which read as a slow slide.
		global_position = _target
		_moving = false
		_walk_t = 0.0
	elif dist > 1.0:
		if absf(_target.x - global_position.x) > 0.5:
			_facing = signf(_target.x - global_position.x)
		# Continuous EXPONENTIAL smoothing toward the latest target, so the avatar
		# glides evenly between position packets instead of move-toward-and-WAIT
		# (which darted 2 frames then froze 4, the "glitchy walking"). Frame-rate
		# independent; keeps up with the ~10Hz move stream while reading smooth.
		global_position = global_position.lerp(_target, 1.0 - exp(-MOVE_SMOOTH * delta))
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
	# Skill-based so an idle ghost also swings the right tool (herbs = bare hand,
	# not an axe). Mirrors the live-gather mapping.
	return _action_for_node(node)

func _draw() -> void:
	var boat := str(get_meta("boat", ""))
	var boating := Boats.is_boat(boat)
	# Gathering = an idle ghost miming, OR a LIVE player mid gather-broadcast
	# (spectated bots). Both draw the correct tool for the job.
	var live_gather := _gather_t > 0.0
	var gathering := (_is_idle and _idle_gather_t > 0.0) or live_gather
	var action := _gather_action if live_gather else _idle_action
	var sw := sin(_walk_t * 9.0) * 3.5 if (_moving and not boating) else 0.0
	var arm_a := sin(_walk_t * 9.0) * 0.3 if (_moving and not boating) else 0.0
	var right := arm_a
	if gathering:
		right = sin(_walk_t * 8.0) * 0.8   # mining/chopping swing
	# PvP melee swing arc (Phase 8) — a strong forward sweep, mirrors Player.gd.
	if _swing_t > 0.0:
		right += sin((1.0 - _swing_t / SWING_DUR) * PI) * 1.7
	var appr: Variant = get_meta("appearance", {})
	var equip: Variant = get_meta("equipment", {})
	Appearance.draw_character(self, appr, {
		"walk_sw":      sw,
		"left_arm":     -arm_a,
		"right_arm":    right,
		"acting":       gathering,
		"action_type":  action if gathering else "",
		"tool":         _gather_tool if live_gather else "",
		"equip":        (equip as Dictionary) if equip is Dictionary else {},
	})
	if boating:
		draw_set_transform(Vector2(0, 6), 0.0, Vector2.ONE)
		Boats.draw_boat(self, boat, _facing)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Username label above head. Yellow normally; red when PvP-flagged so
	# both parties can see who's fair game before a fight starts.
	if not _username.is_empty():
		var font := ThemeDB.fallback_font
		if font != null:
			var name_col := Color(1.00, 0.30, 0.25) if _pvp_flagged \
				else Color(0.95, 0.88, 0.25)
			# Append the overall character level (server-computed) when known.
			var lvl := int(get_meta("level", 0))
			var name_text := _username if lvl <= 0 else "%s  Lv %d" % [_username, lvl]
			var tw    := font.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
			draw_string(font, Vector2(-tw * 0.5, -36), name_text,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9, name_col)
			# Style marker above a flagged player so everyone sees who's fair
			# game AND what they fight with: crossed swords (melee), arrow
			# (ranged), star (magic). Drawn centered just above the name.
			if _pvp_flagged:
				var glyph := _pvp_style_glyph()
				var gw := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
				draw_string(font, Vector2(-gw * 0.5, -47), glyph,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 12, name_col)
