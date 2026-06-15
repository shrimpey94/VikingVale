extends Node

## ── PetManager ──────────────────────────────────────────────────────────────
##
## Owns the live Pet node when summoned. Tracks the chosen pet_type for
## the session (synced with the server on login). Provides a thin API:
##
##   PetManager.set_pet_type("wolf_pup")  — change which pet would summon
##   PetManager.summon()                  — instantiate the live Pet node
##   PetManager.dismiss()                 — free it
##   PetManager.is_summoned()             — bool
##
## The actual Pet node is RAM-only — no SQLite write happens at any of
## the summon/dismiss boundaries. Only set_pet_type triggers a server
## persistence call.

const PET_TYPES := ["wolf_pup", "raven", "fox", "drake", "boarlet"]

# Pet.gd uses `class_name Pet` so the global symbol works; we instantiate
# via `Pet.new()` rather than holding a preload const to avoid the
# strict-mode SHADOWED_GLOBAL_IDENTIFIER warning.

var pet_type: String = ""    # "" = not chosen
var _pet_node: Node2D = null


func _ready() -> void:
	# Despawn the live pet on logout so a re-login doesn't carry the
	# stale instance.
	NetworkManager.disconnected_from_server.connect(_on_logout)


# ── Public API ──────────────────────────────────────────────────────────────
func set_pet_type(new_type: String) -> void:
	if not (new_type in PET_TYPES) and new_type != "":
		return
	pet_type = new_type
	# Persist on the server. The handler updates players.pet_type.
	NetworkManager.send_set_pet_type(new_type)
	# If the live node was already up, re-summon to reflect the new look.
	if _pet_node != null:
		dismiss()
		summon()


func summon() -> void:
	if pet_type == "" or _pet_node != null:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	_pet_node = Pet.new() as Node2D
	(_pet_node as Object).set("pet_type", pet_type)
	scene.add_child(_pet_node)


func dismiss() -> void:
	if _pet_node != null and is_instance_valid(_pet_node):
		_pet_node.queue_free()
	_pet_node = null


func is_summoned() -> bool:
	return _pet_node != null and is_instance_valid(_pet_node)


# ── Login + logout integration ──────────────────────────────────────────────
## Called from GameManager.apply_login after the login payload arrives.
## Restores the saved pet_type from the server and (optionally) auto-
## summons if the player had one out at their last logout. v1 always
## starts dismissed; player taps Summon when ready.
func apply_login_pet(saved_type: String) -> void:
	pet_type = saved_type if (saved_type in PET_TYPES) else ""


func _on_logout() -> void:
	dismiss()
	pet_type = ""
