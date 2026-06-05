extends Node2D

## Live character preview for the creation screen. Draws via the shared
## Appearance routine so it always matches the in-world sprite.

var appr: Dictionary = {}
var equip: Dictionary = {}

func set_appearance(a: Dictionary) -> void:
	appr = a
	queue_redraw()

func set_equipment(e: Dictionary) -> void:
	equip = e
	queue_redraw()

func _draw() -> void:
	Appearance.draw_character(self, appr, {
		"walk_sw":     0.0,
		"left_arm":    0.0,
		"right_arm":   0.0,
		"acting":      false,
		"action_type": "",
		"equip":       equip,
	})
