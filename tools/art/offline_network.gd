extends "res://scripts/autoloads/NetworkManager.gd"
## Used ONLY by the isolated validation project. Inherit protocol/data definitions
## needed by the real logic nodes, but never open a login screen or socket.
func _ready() -> void:
	pass

func _process(_delta: float) -> void:
	pass
