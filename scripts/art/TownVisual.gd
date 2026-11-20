extends Node3D
## 3D wrapper for a TownArt model. Shows every GLB piece except the ones hidden in
## the current state (Gate: OpenGate while closed). The wrapper's own visibility
## belongs to World3D, so a server destroy-hide stays immediate.
var asset_key := ""
var hidden_pieces: Array = []
var logic_ref: WeakRef

func _ready() -> void:
	refresh()

func refresh() -> void:
	var hide := hidden_pieces
	# 1.7.5: the gate's pieces follow its logic node's server state.
	if asset_key == "gate" and logic_ref != null:
		var logic: Object = logic_ref.get_ref()
		if logic != null and bool(logic.get("gate_open")):
			hide = ["ClosedGate"]
	for m: Node in find_children("*", "MeshInstance3D", true, false):
		m.visible = not _under_hidden(m, hide)
	if has_meta("admin_aabb"):
		remove_meta("admin_aabb")   # admin hover bounds change with the leaf

func _under_hidden(n: Node, hide: Array) -> bool:
	while n != null and n != self:
		if n.name in hide:
			return true
		n = n.get_parent()
	return false
