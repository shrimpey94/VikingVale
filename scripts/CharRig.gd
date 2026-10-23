extends Node3D

## v1.6 P-ANIM — a low-poly character RIG that animates itself procedurally. Built
## by Mesh3D.build_char_rig as a small joint hierarchy (torso/head/2 arms/2 legs/
## weapon), each limb pivoting at its joint. This node reads its OWN world-position
## change each frame to drive a walk cycle + facing, breathes when idle, and plays
## action swings (chop/mine/fish/attack) on request. No imported clips — transforms
## only, so it's cheap enough for every actor on screen.

var lleg: Node3D
var rleg: Node3D
var larm: Node3D
var rarm: Node3D
var torso: Node3D

var _torso_y := 0.85
var _phase := 0.0
var _prev := Vector3(INF, INF, INF)
var _yaw := 0.0
var _t := 0.0
var _action := ""
var _action_t := 0.0
const _ACTION_DUR := {"chop": 0.6, "mine": 0.7, "fish": 1.4, "attack": 0.42}

func setup(p: Dictionary) -> void:
	lleg = p.get("lleg") as Node3D
	rleg = p.get("rleg") as Node3D
	larm = p.get("larm") as Node3D
	rarm = p.get("rarm") as Node3D
	torso = p.get("torso") as Node3D
	if torso != null:
		_torso_y = torso.position.y
	_t = randf() * 6.0   # desync idle breathing between actors
	set_process(true)

## Trigger a one-shot action swing (loops until told to stop for gather actions).
func play_action(a: String) -> void:
	_action = a
	_action_t = 0.0

func stop_action() -> void:
	_action = ""

func _process(delta: float) -> void:
	_t += delta
	var pos := global_position
	var mv := Vector3.ZERO
	if _prev.x != INF:
		mv = pos - _prev
		mv.y = 0.0
	_prev = pos
	# Ignore teleports (respawn / boat snap) so we don't spin or sprint-animate.
	if mv.length() > 4.0:
		mv = Vector3.ZERO
	var speed := mv.length() / maxf(delta, 0.001)
	var moving := speed > 0.4

	# Face the movement direction (rig models face -Z). Eased so turns are smooth.
	if moving:
		_yaw = lerp_angle(_yaw, atan2(mv.x, mv.z), minf(1.0, delta * 10.0))
	rotation.y = _yaw

	if _action != "":
		_action_t += delta
		var dur: float = _ACTION_DUR.get(_action, 0.6)
		# A repeating overhead swing for gather; a single lunge for attack.
		var sw := sin(_action_t / dur * TAU)
		if rarm != null: rarm.rotation.x = -1.35 + sw * 1.0
		if larm != null: larm.rotation.x = -0.35 + sw * 0.3
		_ease(lleg, 0.0, delta); _ease(rleg, 0.0, delta)
		if torso != null: torso.position.y = _torso_y
		if _action == "attack" and _action_t >= dur:
			_action = ""
		return

	if moving:
		_phase += delta * clampf(speed * 0.35, 5.0, 12.0)
		var s := sin(_phase) * 0.6
		if lleg != null: lleg.rotation.x = s
		if rleg != null: rleg.rotation.x = -s
		if larm != null: larm.rotation.x = -s * 0.7
		if rarm != null: rarm.rotation.x = s * 0.7
		if torso != null: torso.position.y = _torso_y + absf(sin(_phase)) * 0.045
	else:
		_ease(lleg, 0.0, delta); _ease(rleg, 0.0, delta)
		_ease(larm, 0.0, delta); _ease(rarm, 0.0, delta)
		if torso != null: torso.position.y = _torso_y + sin(_t * 2.0) * 0.02   # breathe

func _ease(n: Node3D, to: float, delta: float) -> void:
	if n != null:
		n.rotation.x = lerp(n.rotation.x, to, minf(1.0, delta * 9.0))
