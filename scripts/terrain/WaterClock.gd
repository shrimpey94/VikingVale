extends Node
## Drives the shared 8 s water loop (caustics + kelp sway) on one material each
## frame. Added only when authored terrain is on (never under --procedural-terrain).
## The clock is shared game time (TerrainArt), so 2D and 3D stay in phase across
## the view toggle.

const TerrainArt = preload("res://scripts/terrain/TerrainArt.gd")

## The CanvasItem (2D ground: `material`) or GeometryInstance3D (3D water plane:
## `material_override`) whose ShaderMaterial gets the clock.
var target: Node = null

func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	var mat: Material = null
	if target is GeometryInstance3D:
		mat = (target as GeometryInstance3D).material_override
	elif target is CanvasItem:
		mat = (target as CanvasItem).material
	TerrainArt.tick_water(mat, delta)
