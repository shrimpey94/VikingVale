extends Node3D

## v1.6.1 P-ANIM — a self-animating MONSTER rig (the CharRig equivalent for mobs).
## Built by Mesh3D.build_monster_rig as a part hierarchy (body / head / legs / tail /
## wings) whose pivots this script animates procedurally: it reads its OWN world-
## position change each frame to face + walk, breathes/flaps/sways when idle, plays a
## flinch on hit and a lunge on attack, and topples on death. Transforms only — no
## imported clips — so every mob on screen animates cheaply. Models are built facing
## +Z (forward), matching the CharRig convention.

var _legs: Array = []        # [{node:Node3D, phase:float}] — swung about the hip
var _wings: Array = []       # [{node:Node3D, side:float}] — flapped about local Z
var _head: Node3D = null
var _tail: Node3D = null
var _body: Node3D = null
var _arche := "quad"

var _body_y := 0.0
var _phase := 0.0
var _prev := Vector3(INF, INF, INF)
var _yaw := 0.0
var _t := 0.0
var _wing_phase := 0.0        # independent, smoother wing clock
var _wing_timer := 0.0        # counts down between flap bursts / glides
var _wing_flapping := false
var _dead := false
var _hit_t := 0.0
var _action := ""
var _action_t := 0.0
const _ATTACK_DUR := 0.5

func setup(p: Dictionary) -> void:
	_legs  = p.get("legs", [])
	_wings = p.get("wings", [])
	_head  = p.get("head", null)
	_tail  = p.get("tail", null)
	_body  = p.get("body", null)
	_arche = str(p.get("arche", "quad"))
	if _body != null:
		_body_y = _body.position.y
	_t = randf() * 6.0            # desync idle between same-type mobs
	_phase = randf() * TAU
	_wing_phase = randf() * TAU
	_wing_timer = randf_range(0.6, 2.4)   # first flap burst comes at a random time
	set_process(true)

func play_action(a: String) -> void:
	_action = a
	_action_t = 0.0

func play_hit() -> void:
	_hit_t = 0.22

## Death — topple onto the side + sink, then hold. World3D stops syncing dead mobs,
## so the tween owns the transform until respawn.
func play_death() -> void:
	if _dead:
		return
	_dead = true
	set_process(false)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "rotation:z", rotation.z + PI * 0.5, 0.55).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "position:y", position.y - 0.25, 0.65).set_delay(0.1)

func play_respawn() -> void:
	_dead = false
	rotation = Vector3(0.0, _yaw, 0.0)   # un-topple (yaw kept)
	set_process(true)

func _process(delta: float) -> void:
	if _dead:
		return
	_t += delta
	var pos := global_position
	var mv := Vector3.ZERO
	if _prev.x != INF:
		mv = pos - _prev
		mv.y = 0.0
	_prev = pos
	if mv.length() > 4.0:        # ignore teleports (respawn / boat snaps)
		mv = Vector3.ZERO
	var speed := mv.length() / maxf(delta, 0.001)
	var moving := speed > 0.4

	if moving:
		_yaw = lerp_angle(_yaw, atan2(mv.x, mv.z), minf(1.0, delta * 10.0))
	rotation.y = _yaw

	var flinch := 0.0
	if _hit_t > 0.0:
		_hit_t -= delta
		flinch = sin(_hit_t / 0.22 * PI) * 0.14

	# Gait cadence: brisk when moving, a slow idle beat otherwise (drives wings/tail).
	_phase += delta * (clampf(speed * 0.4, 6.0, 13.0) if moving else 2.4)

	var leg_amt := 0.55 if moving else 0.05
	for L: Variant in _legs:
		var ln: Node3D = (L as Dictionary)["node"]
		if is_instance_valid(ln):
			ln.rotation.x = sin(_phase + float((L as Dictionary)["phase"])) * leg_amt

	# Wings flap in randomly-timed BURSTS then glide (not a constant metronome).
	# Smaller amplitude + smoothed so it reads as gliding, not frantic.
	if _wings.size() > 0:
		_wing_timer -= delta
		if _wing_timer <= 0.0:
			_wing_flapping = not _wing_flapping
			_wing_timer = randf_range(0.5, 1.1) if _wing_flapping else randf_range(1.4, 3.6)
		for w: Variant in _wings:
			var wn: Node3D = (w as Dictionary)["node"]
			if not is_instance_valid(wn):
				continue
			var side := float((w as Dictionary)["side"])
			if _wing_flapping or moving:
				_wing_phase += delta * 5.0
				wn.rotation.z = sin(_wing_phase) * 0.24 * side       # gentle flap
			else:
				wn.rotation.z = lerp(wn.rotation.z, 0.05 * side, minf(1.0, delta * 3.5))  # ease to glide

	# Tail — slower + smaller + eased so it sways smoothly instead of whipping.
	if _tail != null:
		_tail.rotation.y = lerp(_tail.rotation.y, sin(_t * 1.6) * 0.2, minf(1.0, delta * 5.0))

	var lunge := 0.0
	var head_dip := 0.0
	if _action == "attack":
		_action_t += delta
		var k := sin(clampf(_action_t / _ATTACK_DUR, 0.0, 1.0) * PI)
		lunge = -k * 0.18          # forward (-Z) snap
		head_dip = k * 0.5
		if _action_t >= _ATTACK_DUR:
			_action = ""

	if _head != null:
		_head.rotation.x = head_dip + flinch * 1.4 + sin(_t * 1.6) * 0.03

	if _body != null:
		var bob := (absf(sin(_phase)) * 0.03 if moving else sin(_t * 2.0) * 0.02)
		_body.position.y = _body_y + bob
		_body.position.z = lunge + flinch * 0.6
