extends Node

## v1.6 P7 — the 2D/3D TOGGLE entry point. The game's main_scene is boot.tscn; this
## reads the player's renderer choice from user://graphics.cfg and loads EITHER the
## 2D client (world.tscn) or the 3D client (world3d.tscn). Both reuse the same
## autoloads + LoginScreen, so the fork is clean and the default (no file / false)
## is the unchanged 2D client — nothing ships broken.

const GRAPHICS_CFG := "user://graphics.cfg"

func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(GRAPHICS_CFG)   # missing file is fine — get_value falls back to the default
	var use_3d := bool(cfg.get_value("graphics", "renderer_3d", false))
	# Deferred — change_scene can't run while the tree is mid-_ready (busy adding us).
	get_tree().change_scene_to_file.call_deferred("res://world3d.tscn" if use_3d else "res://world.tscn")
