extends Node3D
## Mirrors a mining-node / forage logic node's state onto the GLB's named
## pieces (handoff masks). Reads existing state only; the wrapper's own
## visibility belongs to World3D, so a server depletion-hide stays immediate.
## Ancient Root also drives its rune emission from the node's existing pulse.
var asset_key := ""
var logic_ref: WeakRef
var _last_frame := -1
var _rune_mat: StandardMaterial3D = null
var _rune_checked := false

const _ORE_PIECES := ["LiveRock", "Crack1", "Crack2", "Crack3", "Depleted"]
const _HERB_FRONDS := [5, 4, 4, 3, 0]
const _HERB_FLOWER := [true, true, false, false, false]
const _MUSHROOM := [["Soil", "BigMushroom", "SmallMushroom", "TinyMushroom"],
	["Soil", "BigMushroom", "SmallMushroom"], ["Soil", "BigMushroom"], ["Soil"]]
const _CLUMPS := [["Soil", "Clump0", "Clump1", "Clump2", "Flower"],
	["Soil", "Clump0", "Clump1"], ["Soil", "Clump0"], ["Soil"]]

func _ready() -> void:
	refresh()

func _process(_delta: float) -> void:
	refresh()

## Same per-key frame rules as ResourceArt.state_frame (not preloaded here to
## avoid a cycle).
static func frame_for(key: String, logic: Node) -> int:
	var depleted := int(logic.get("_state")) == 2
	var ratio := float(logic.get("_hp")) / maxf(1.0, float(logic.get("_max_hp")))
	match key:
		"herb_patch":
			if depleted: return 4
			return 0 if ratio >= 1.0 else (1 if ratio > 0.75 else (2 if ratio >= 0.5 else 3))
		"mushroom_patch":
			if depleted: return 3
			return 0 if ratio > 0.8 else (1 if ratio > 0.4 else 2)
		"berry_bush":
			if depleted: return 8
			return 9 - clampi(int(ratio * 9.0) + 2, 2, 9)
		"moonbloom_patch", "wild_bush":
			if depleted: return 3
			return 3 - clampi(int(ratio * 2.0) + 1, 1, 3)
		"ancient_root":
			return 1 if depleted else 0
		_:
			if depleted: return 4
			return clampi(4 - int(ratio * 4.0 + 0.99), 0, 3)

## Visible piece names for a key + frame (everything else in the GLB hides).
static func visible_pieces(key: String, frame: int) -> Array:
	match key:
		"herb_patch":
			var out := ["Soil"]
			for i in range(int(_HERB_FRONDS[frame])): out.append("Frond%d" % i)
			if _HERB_FLOWER[frame]: out.append("Flower")
			return out
		"mushroom_patch": return _MUSHROOM[frame]
		"berry_bush":
			if frame >= 8: return ["Soil"]
			var out := ["Soil", "Canopy"]
			for i in range(9 - frame): out.append("Berry%d" % i)
			return out
		"moonbloom_patch", "wild_bush": return _CLUMPS[frame]
		"ancient_root": return ["Soil"] if frame == 1 else ["Soil", "Root", "Runes"]
		_:
			if frame >= 4: return ["Depleted"]
			var out := ["LiveRock"]
			for i in range(1, 4):
				if frame >= i: out.append("Crack%d" % i)
			return out

func refresh() -> void:
	var logic := logic_ref.get_ref() as Node2D if logic_ref != null else null
	var frame := frame_for(asset_key, logic) if logic != null else 0
	if asset_key == "ancient_root" and logic != null and frame == 0:
		_pulse_runes(0.65 + sin(float(logic.get("_time_elapsed")) * 2.4) * 0.30)
	if frame == _last_frame:
		return
	_last_frame = frame
	var show := visible_pieces(asset_key, frame)
	for m: Node in find_children("*", "MeshInstance3D", true, false):
		m.visible = m.name in show

## Per-instance copy of the rune material so each root pulses on its own timer.
## Imported baseline energy is 1 with the 0.65 encoded in the emission colour.
func _pulse_runes(pulse: float) -> void:
	if not _rune_checked:
		_rune_checked = true
		var runes := find_child("Runes", true, false) as MeshInstance3D
		if runes != null and runes.mesh != null:
			for i in runes.mesh.get_surface_count():
				var src := runes.get_active_material(i) as StandardMaterial3D
				if src != null and src.emission_enabled:
					_rune_mat = src.duplicate() as StandardMaterial3D
					runes.set_surface_override_material(i, _rune_mat)
					break
	if _rune_mat != null:
		_rune_mat.emission_energy_multiplier = pulse / 0.65
