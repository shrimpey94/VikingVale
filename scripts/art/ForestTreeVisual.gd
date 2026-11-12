extends Node3D
## Mirrors the logic node's tree state onto the GLB's named pieces (LiveTrunk,
## Canopy0..3, Stump). Reads existing state only; the wrapper's own visibility
## belongs to World3D, so a server depletion-hide stays immediate.
var asset_key := ""
var logic_ref: WeakRef
var _last_frame := -1

## Same mask as ForestArt.state_frame (not preloaded here to avoid a cycle).
const _CANOPY_COUNT := [4, 3, 2, 1, 0]

func _ready() -> void:
	refresh()

func _process(_delta: float) -> void:
	refresh()

func refresh() -> void:
	if asset_key == "stick_pickup":
		return   # one Pickup node; collection hides the whole wrapper
	var logic := logic_ref.get_ref() as Node2D if logic_ref != null else null
	var frame := 0
	if logic != null:
		if int(logic.get("_state")) == 2:
			frame = 4
		else:
			var ratio := float(logic.get("_hp")) / maxf(1.0, float(logic.get("_max_hp")))
			frame = 0 if ratio > .75 else (1 if ratio > .5 else (2 if ratio > .25 else 3))
	if frame == _last_frame:
		return
	_last_frame = frame
	_set_visible("LiveTrunk", frame != 4)
	_set_visible("Stump", frame == 4)
	for i in range(4):
		_set_visible("Canopy" + str(i), i < int(_CANOPY_COUNT[frame]))

func _set_visible(piece: String, on: bool) -> void:
	var node := find_child(piece, true, false)
	if node != null:
		node.visible = on
