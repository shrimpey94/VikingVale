extends Node3D
## Reads existing logic state; never changes movement, physics, hp or networking.
const KarlArt = preload("res://scripts/art/KarlArt.gd")
var asset_key := ""
var logic_ref: WeakRef
var _player: AnimationPlayer
var _clip := ""
var _previous := Vector2(INF, INF)
var _last_frame := -1
var _hit_progress := 1.0

func _ready() -> void:
	refresh()

func _process(_delta: float) -> void:
	refresh()

func refresh() -> void:
	if asset_key == "karl":
		_refresh_karl()
		return
	var logic := logic_ref.get_ref() as Node2D if logic_ref != null else null
	var frame := 0
	if asset_key == "oak_tree":
		if logic != null:
			var ratio := float(logic.get("_hp")) / maxf(1.0, float(logic.get("_max_hp")))
			frame = 0 if ratio > .75 else (1 if ratio > .5 else (2 if ratio > .25 else 3))
			if int(logic.get("_state")) == 2: frame = 4
		if frame != _last_frame:
			find_child("LiveTrunk", true, false).visible = frame != 4
			find_child("Stump", true, false).visible = frame == 4
			for i in range(4): find_child("Canopy" + str(i), true, false).visible = i < [4, 3, 1, 0, 0][frame]
	_last_frame = frame

## Karl v011: plays the GLB's named clips from the NPC's own timers (KarlArt.state).
## Visibility is never touched here — World3D mirrors the logic node's visibility,
## so a server death-hide stays immediate. The death clip is never played.
func _refresh_karl() -> void:
	if _player == null:
		var players := find_children("*", "AnimationPlayer", true, false)
		if players.is_empty():
			return
		_player = players[0] as AnimationPlayer
		# glTF carries no game-loop contract — apply the manifest's loop modes.
		for clip: String in KarlArt.CLIPS:
			if _player.has_animation(clip):
				_player.get_animation(clip).loop_mode = (Animation.LOOP_LINEAR
						if bool((KarlArt.CLIPS[clip] as Array)[3]) else Animation.LOOP_NONE)
	var logic := logic_ref.get_ref() as Node2D if logic_ref != null else null
	if logic == null or not is_inside_tree():
		return
	var p := logic.position
	if _previous.x != INF:
		var movement := p - _previous
		if movement.length() > .01 and movement.length() < 128:
			rotation.y = atan2(movement.x, movement.y) # master faces Godot +Z
	_previous = p
	var st := KarlArt.state(logic)
	var clip := str(st["clip"])
	# A fresh hit while one is still showing restarts the reaction.
	var rehit := clip == "hit" and _clip == "hit" and float(st["progress"]) < _hit_progress
	_hit_progress = float(st["progress"]) if clip == "hit" else 1.0
	if (clip != _clip or rehit) and _player.has_animation(clip):
		var blend := KarlArt.BLEND_HIT if clip == "hit" or _clip == "hit" else KarlArt.BLEND_3D
		_player.play(clip, blend, float(st["speed"]))
		if rehit:
			_player.seek(0.0, true)
		_clip = clip
