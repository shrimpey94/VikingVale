extends Node2D
class_name Pet

## ── Pet ─────────────────────────────────────────────────────────────────────
##
## RAM-only follower companion. The player's chosen `pet_type` persists
## on the server (players.pet_type column), but the live entity itself
## is purely client-side — it spawns when the player summons, follows
## around, and despawns on dismiss or logout.
##
## AI is the simplest possible "follow the leader":
##   * If far from player → walk toward them at FOLLOW_SPEED
##   * If close → idle in place with a small bob
##   * If very far (out of leash) → teleport to player to catch up
##
## Per-type cosmetics live in the _draw method. Each pet type has a
## small procedurally-rendered look (wolf pup, raven, fox, drake, boarlet).
## Level-gated emote/aura/glow tiers wire through PlayerMods in a future
## pass — for v1 we ship the cosmetic + follow AI only.

const FOLLOW_DISTANCE := 28.0   # px; closer than this and the pet idles
const CHASE_DISTANCE  := 64.0   # px; further and the pet hustles
const TELEPORT_DISTANCE := 480.0  # px; further and we just snap to player
const FOLLOW_SPEED    := 110.0  # base follow speed in px/s
const SLOW_SPEED      :=  60.0  # walking-distance speed
const BOB_AMP         := 1.5    # idle bob in px

var pet_type: String = "wolf_pup"
var pet_skin: String = ""

var _player: Node2D = null
var _t: float = 0.0
var _facing: float = 1.0


func _ready() -> void:
	z_index = -1   # behind the player visually
	queue_redraw()
	# Spawn on top of player, but offset so it isn't perfectly stacked.
	_player = get_tree().get_first_node_in_group("player") as Node2D
	if _player != null:
		global_position = _player.global_position + Vector2(-20, 8)


func _process(delta: float) -> void:
	_t += delta
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node2D
		if _player == null:
			return
	var to_target: Vector2 = _player.global_position - global_position
	var dist: float = to_target.length()
	# Teleport if we've fallen off the leash (chunk streaming, fast travel).
	if dist > TELEPORT_DISTANCE:
		global_position = _player.global_position + Vector2(-20, 8)
		return
	if dist > CHASE_DISTANCE:
		_walk(to_target.normalized(), FOLLOW_SPEED, delta)
	elif dist > FOLLOW_DISTANCE:
		_walk(to_target.normalized(), SLOW_SPEED, delta)
	# else: idle — _draw applies the bob in render only.
	queue_redraw()


func _walk(dir: Vector2, speed: float, delta: float) -> void:
	global_position += dir * speed * delta
	if abs(dir.x) > 0.05:
		_facing = signf(dir.x)


# ── Drawing ─────────────────────────────────────────────────────────────────
## Tiny per-type procedural look. All sit on the ground at the node origin.
## Bob is added in render only so the underlying position stays clean for
## AI math.
func _draw() -> void:
	var bob: float = sin(_t * 6.0) * BOB_AMP
	draw_set_transform(Vector2(0, bob), 0.0, Vector2(_facing, 1.0))
	match pet_type:
		"wolf_pup":  _draw_wolf_pup()
		"raven":     _draw_raven()
		"fox":       _draw_fox()
		"drake":     _draw_drake()
		"boarlet":   _draw_boarlet()
		_:           _draw_wolf_pup()


func _draw_wolf_pup() -> void:
	# Grey-brown blob with ears + snout + tail
	var body := Color(0.42, 0.36, 0.30)
	var dark := Color(0.20, 0.18, 0.15)
	draw_circle(Vector2(0, 0), 7.0, body)             # body
	draw_circle(Vector2(5, -3), 4.0, body)            # head
	draw_circle(Vector2(7.5, -5), 1.2, dark)          # ear
	draw_circle(Vector2(3.5, -6), 1.2, dark)          # ear
	draw_circle(Vector2(6.8, -2.5), 0.5, Color(0.95, 0.85, 0.50))  # eye
	draw_line(Vector2(-6, 2), Vector2(-12, 0), dark, 1.6)         # tail
	draw_line(Vector2(-3, 5), Vector2(-4, 8), dark, 1.6)          # leg
	draw_line(Vector2(3, 5), Vector2(2, 8), dark, 1.6)            # leg


func _draw_raven() -> void:
	var feather := Color(0.10, 0.08, 0.10)
	var sheen := Color(0.25, 0.20, 0.32)
	draw_circle(Vector2(0, -2), 6.0, feather)        # body
	draw_circle(Vector2(4, -5), 3.5, feather)        # head
	draw_line(Vector2(7, -5), Vector2(11, -4), Color(0.90, 0.80, 0.30), 1.4)  # beak
	draw_circle(Vector2(5.5, -5.5), 0.4, Color(0.95, 0.85, 0.20))             # eye
	draw_line(Vector2(-3, -4), Vector2(-9, -2), sheen, 2.0)                   # wing
	draw_line(Vector2(-2, 3), Vector2(-1, 6), feather, 1.4)                   # leg
	draw_line(Vector2(1, 3), Vector2(2, 6), feather, 1.4)                    # leg


func _draw_fox() -> void:
	var orange := Color(0.85, 0.45, 0.18)
	var white  := Color(0.95, 0.90, 0.78)
	var dark   := Color(0.30, 0.15, 0.05)
	draw_circle(Vector2(0, 0), 7.0, orange)
	draw_circle(Vector2(5, -3), 4.0, orange)
	# Pointy ears
	draw_colored_polygon(PackedVector2Array([Vector2(7, -5), Vector2(9, -9), Vector2(6, -7)]), orange)
	draw_colored_polygon(PackedVector2Array([Vector2(3, -6), Vector2(2, -10), Vector2(5, -8)]), orange)
	draw_circle(Vector2(5, -1), 1.5, white)          # snout
	draw_circle(Vector2(6.5, -2.5), 0.5, dark)       # eye
	# Bushy tail with white tip
	draw_line(Vector2(-6, 2), Vector2(-12, -2), orange, 3.0)
	draw_circle(Vector2(-12, -2), 1.5, white)


func _draw_drake() -> void:
	var green := Color(0.20, 0.55, 0.30)
	var dark  := Color(0.10, 0.30, 0.18)
	var spike := Color(0.85, 0.65, 0.20)
	# Body
	draw_colored_polygon(PackedVector2Array([
		Vector2(-7, 0), Vector2(-2, -3), Vector2(6, -2), Vector2(9, 2), Vector2(4, 5), Vector2(-5, 4)]), green)
	# Head + horn
	draw_circle(Vector2(8, -2), 3.0, green)
	draw_line(Vector2(10, -4), Vector2(13, -7), spike, 1.5)
	draw_circle(Vector2(9, -2), 0.5, Color(0.95, 0.40, 0.20))
	# Wing
	draw_colored_polygon(PackedVector2Array([
		Vector2(-2, -3), Vector2(-2, -10), Vector2(4, -4)]), dark)
	# Tail
	draw_line(Vector2(-7, 1), Vector2(-14, 4), green, 2.0)


func _draw_boarlet() -> void:
	var brown := Color(0.55, 0.40, 0.28)
	var stripe := Color(0.90, 0.80, 0.55)
	draw_circle(Vector2(0, 0), 8.0, brown)
	# Stripes (juvenile boars are striped)
	draw_line(Vector2(-4, -4), Vector2(-4, 4), stripe, 1.2)
	draw_line(Vector2(0, -5), Vector2(0, 5), stripe, 1.2)
	draw_line(Vector2(4, -4), Vector2(4, 4), stripe, 1.2)
	# Snout + ear + eye
	draw_circle(Vector2(6, 1), 2.5, brown.darkened(0.15))
	draw_circle(Vector2(7, 0), 0.7, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(5, -4), 1.3, brown.darkened(0.20))
	draw_circle(Vector2(6.5, -2), 0.5, Color(0.10, 0.10, 0.10))
