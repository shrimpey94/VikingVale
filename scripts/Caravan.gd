extends Area2D

## Trade caravan (Phase 5c). A council wagon that runs the road circuit between
## towns. Position, state, and the whole wreck lifecycle are SERVER-owned — this
## node only renders what the `caravans` broadcast tells it and forwards attacks.
##
## States mirror the server: stopped | travel | wreck | dissolving | gone.
## Only `travel` is attackable (a parked caravan is under town protection), so
## ambushes have to happen out on the road.

const WHEEL_C  := Color(0.28, 0.18, 0.08)
const WOOD_C   := Color(0.46, 0.31, 0.14)
const WOOD_LT  := Color(0.58, 0.41, 0.20)
const CANVAS_C := Color(0.86, 0.82, 0.70)
const IRON_C   := Color(0.40, 0.40, 0.44)

var caravan_id: String = ""
var state:      String = "stopped"
var last_town:  String = ""
var next_town:  String = ""
## 1.0 = whole, 0.0 = fully dissolved. Server drives this while `dissolving`.
var decay:      float  = 1.0

# ── Duck-typed combat interface (matches Monster/NPC so the HUD attack path
# ── can target a caravan without special-casing every call site).
var entity_id:   String = ""
var is_alive:    bool   = true
var current_hp:  int    = 140
var max_hp:      int    = 140
var defense:     int    = 6
var level:       int    = 10
var attack:      int    = 0     # wagons don't fight back
var xp_reward:   int    = 0     # raiding is a rep play, not an XP farm
var display_name: String = "Trade Caravan"

const WHEEL_R := 7.0

var _hit_flash: float   = 0.0
# ── Entity interpolation (v1.5.3) ────────────────────────────────────────────
# The server broadcasts positions ~every 0.5s at ~38px/s, so a naive "race to
# the latest point" lurched (move ~19px in 0.2s, then sit still for 0.3s). We
# now LERP linearly from the previous rendered spot to the new one over the
# MEASURED broadcast interval, giving true constant-velocity rolling.
var _from_pos: Vector2 = Vector2.ZERO
var _to_pos:   Vector2 = Vector2.ZERO
var _seg_t:    float   = 1.0     # 0→1 progress through the current segment
var _seg_dur:  float   = 0.5     # measured seconds between the last two updates
var _last_update_t: float = 0.0
var _wheel_angle: float = 0.0    # accumulates with distance travelled → rolling
var _facing: float = 1.0

func _ready() -> void:
	add_to_group("caravan")
	add_to_group("interactable")
	input_pickable  = true
	collision_layer = 4
	collision_mask  = 0
	z_index = 1
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(56, 40)
	cs.shape = rect
	add_child(cs)
	_from_pos = global_position
	_to_pos = global_position

func flash_hit() -> void:
	_hit_flash = 0.18

## Applied from the server's `caravans` broadcast — opens a new interpolation
## segment from where we're rendering NOW to the fresh server position.
func apply_state(d: Dictionary) -> void:
	state      = str(d.get("state", state))
	current_hp = int(d.get("hp", current_hp))
	max_hp     = maxi(1, int(d.get("max_hp", max_hp)))
	last_town  = str(d.get("last_town", last_town))
	next_town  = str(d.get("next_town", next_town))
	decay      = float(d.get("decay", 1.0))
	is_alive   = state == "travel" or state == "stopped"
	visible        = state != "gone"   # `gone` = not in the world at all
	input_pickable = is_alive
	var new_pos := Vector2(float(d.get("x", _to_pos.x)), float(d.get("y", _to_pos.y)))
	var now := float(Time.get_ticks_msec()) / 1000.0
	if _last_update_t > 0.0:
		_seg_dur = clampf(now - _last_update_t, 0.1, 1.5)
	_last_update_t = now
	if global_position.distance_to(new_pos) > 400.0:
		# Respawn / town-hop teleport — snap, don't roll across the map.
		global_position = new_pos
		_from_pos = new_pos
		_to_pos = new_pos
		_seg_t = 1.0
	else:
		_from_pos = global_position
		_to_pos = new_pos
		_seg_t = 0.0

func _process(delta: float) -> void:
	if _hit_flash > 0.0:
		_hit_flash -= delta
	var prev := global_position
	if _seg_t < 1.0 and _seg_dur > 0.0:
		_seg_t = minf(1.0, _seg_t + delta / _seg_dur)
		global_position = _from_pos.lerp(_to_pos, _seg_t)
	# Roll the wheels by the ACTUAL distance moved this frame + face travel dir.
	var moved := global_position - prev
	var dist := moved.length()
	if dist > 0.02:
		_wheel_angle += dist / WHEEL_R
		if absf(moved.x) > 0.05:
			_facing = signf(moved.x)
	queue_redraw()

func _draw() -> void:
	if state == "gone":
		return
	var wrecked := state == "wreck" or state == "dissolving"
	# Dissolving fades the whole wreck out over the server's 10-minute timer.
	var a := 1.0 if not wrecked else clampf(decay, 0.0, 1.0)
	if state == "wreck":
		a = 1.0
	# A tiny bob tied to wheel rotation (so it only bobs while actually rolling).
	var bob := sin(_wheel_angle * 2.0) * 0.9 if state == "travel" else 0.0

	if wrecked:
		_draw_wreck(a)
	else:
		_draw_wagon(bob)

	if _hit_flash > 0.0:
		draw_circle(Vector2(0, -6), 26.0, Color(0.95, 0.15, 0.10, 0.30))
	# HP bar only once damaged, and never on a wreck.
	if not wrecked and current_hp < max_hp:
		var w := 40.0
		var frac := clampf(float(current_hp) / float(max_hp), 0.0, 1.0)
		draw_rect(Rect2(-w * 0.5, -34, w, 4), Color(0.10, 0.08, 0.06, 0.85))
		var col := Color(0.35, 0.80, 0.30)
		if frac < 0.34:
			col = Color(0.90, 0.25, 0.20)
		elif frac < 0.67:
			col = Color(0.90, 0.75, 0.20)
		draw_rect(Rect2(-w * 0.5, -34, w * frac, 4), col)

func _draw_wagon(bob: float) -> void:
	# Mirror the whole wagon by travel direction so the draw-pole leads.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(_facing, 1.0))
	var y := bob
	# Rolling wheels (spokes rotate with _wheel_angle — the actual "roll").
	_draw_wheel(Vector2(-16, 12 + y))
	_draw_wheel(Vector2( 16, 12 + y))
	# Bed
	draw_rect(Rect2(-24, -2 + y, 48, 14), WOOD_C)
	draw_rect(Rect2(-24, -2 + y, 48, 3), WOOD_LT)
	# Canvas tilt-cover — the classic hooped trade wagon
	draw_colored_polygon(PackedVector2Array([
		Vector2(-21, -2 + y), Vector2(-14, -20 + y),
		Vector2( 14, -20 + y), Vector2( 21, -2 + y)]), CANVAS_C)
	for i in range(3):
		var hx := -12.0 + float(i) * 12.0
		draw_line(Vector2(hx, -2 + y), Vector2(hx, -19 + y),
			CANVAS_C.darkened(0.18), 1.5)
	# Iron banding + draw-pole (out the leading/front edge).
	draw_rect(Rect2(-24, 9 + y, 48, 2), IRON_C)
	draw_line(Vector2(24, 6 + y), Vector2(46, 11), WOOD_C, 2.5)   # trace to the animal
	# The donkey pulling it (only steps while rolling).
	_draw_draft_animal()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## A side-view donkey at the front of the traces. Legs stride with wheel
## rotation so it walks while the wagon rolls and stands still when parked.
const DONKEY_C  := Color(0.52, 0.48, 0.44)
const DONKEY_D  := Color(0.38, 0.35, 0.32)
const DONKEY_MZ := Color(0.30, 0.27, 0.25)

func _draw_draft_animal() -> void:
	var ox := 52.0   # ahead of the wagon
	var oy := 6.0
	# Stride — front/back leg pairs swing opposite. Zero when not rolling.
	var moving := state == "travel"
	var sw := sin(_wheel_angle) * 3.0 if moving else 0.0
	# Legs (drawn behind the body).
	draw_line(Vector2(ox - 6, oy + 4), Vector2(ox - 6 - sw, oy + 15), DONKEY_D, 2.2)
	draw_line(Vector2(ox + 6, oy + 4), Vector2(ox + 6 + sw, oy + 15), DONKEY_D, 2.2)
	draw_line(Vector2(ox - 4, oy + 4), Vector2(ox - 4 + sw, oy + 15), DONKEY_C, 2.2)
	draw_line(Vector2(ox + 8, oy + 4), Vector2(ox + 8 - sw, oy + 15), DONKEY_C, 2.2)
	# Body.
	draw_circle(Vector2(ox + 1, oy), 8.5, DONKEY_C)
	draw_rect(Rect2(ox - 6, oy - 5, 14, 10), DONKEY_C)
	# Neck + head reaching forward.
	draw_line(Vector2(ox + 7, oy - 3), Vector2(ox + 14, oy - 8), DONKEY_C, 4.0)
	draw_circle(Vector2(ox + 16, oy - 9), 3.6, DONKEY_C)
	draw_circle(Vector2(ox + 18, oy - 8), 2.0, DONKEY_MZ)   # muzzle
	# Ears (the giveaway it's a donkey).
	draw_line(Vector2(ox + 15, oy - 12), Vector2(ox + 13, oy - 18), DONKEY_D, 2.0)
	draw_line(Vector2(ox + 17, oy - 12), Vector2(ox + 18, oy - 18), DONKEY_D, 2.0)
	# Eye + tufted tail.
	draw_circle(Vector2(ox + 16, oy - 10), 0.7, Color(0.1, 0.1, 0.1))
	draw_line(Vector2(ox - 6, oy - 2), Vector2(ox - 10, oy + 4), DONKEY_D, 1.6)

## A spoked cart wheel rotated by _wheel_angle — the visible rolling.
func _draw_wheel(c: Vector2) -> void:
	draw_circle(c, WHEEL_R, WHEEL_C)               # tyre
	draw_circle(c, WHEEL_R - 1.5, WOOD_C)          # rim inset
	draw_circle(c, 2.2, WOOD_LT)                   # hub
	for s in range(6):
		var ang := _wheel_angle + float(s) * (PI / 3.0)
		draw_line(c, c + Vector2(cos(ang), sin(ang)) * (WHEEL_R - 1.5),
			WOOD_LT.darkened(0.1), 1.2)

func _draw_wreck(a: float) -> void:
	var wood := Color(WOOD_C.r, WOOD_C.g, WOOD_C.b, a)
	var char_c := Color(0.16, 0.13, 0.10, a)
	var ash := Color(0.35, 0.33, 0.30, a * 0.7)
	# Collapsed bed, tilted
	draw_colored_polygon(PackedVector2Array([
		Vector2(-24, 10), Vector2(20, 6), Vector2(22, 14), Vector2(-22, 16)]), char_c)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-20, 6), Vector2(10, 2), Vector2(12, 9), Vector2(-18, 12)]), wood)
	# One wheel still on, one fallen flat
	draw_circle(Vector2(-16, 14), 7.0, char_c)
	draw_arc(Vector2(14, 15), 7.0, 0.0, PI, 8, char_c, 2.0)
	# Broken hoops jutting out of the ash
	draw_line(Vector2(-8, 6), Vector2(-12, -6), char_c, 2.0)
	draw_line(Vector2( 6, 4), Vector2( 11, -5), char_c, 2.0)
	# Ash pile spreading as it dissolves (grows as `a` falls)
	var spread := 18.0 + (1.0 - a) * 14.0
	draw_circle(Vector2(0, 14), spread, ash)
