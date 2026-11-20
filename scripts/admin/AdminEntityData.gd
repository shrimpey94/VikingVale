extends RefCounted
## 1.7.5 (S): shared by World (2D) and World3D. Inspect data for seeded
## resources/structures (Interactables), and applying an accepted edit to one.
## Visual + label fields only: the gameplay subtype (type_str) never changes.

## Fields an edit may change that alter how the entity looks (3D rebuilds its model).
const VISUAL_KEYS := ["display_name", "color", "variant_id"]

static func resource_info_of(node: Node, id: String) -> Dictionary:
	if node == null or not ("interactable_type_str" in node):
		return {}
	var c: Color = node.get("color")
	var d := {"type_str": str(node.get("interactable_type_str")),
		"display_name": str(node.get("display_name")), "skill": str(node.get("required_skill")),
		"level": int(node.get("required_level")), "action": str(node.get("action_label")),
		"color": [c.r, c.g, c.b, c.a]}
	if node.has_method("current_variant") and int(node.call("current_variant")) >= 0:
		d["variant_id"] = int(node.call("current_variant"))
	if "admin_rot" in node:
		d["rot"] = float(node.get("admin_rot"))
	return {"id": id, "kind": "resource", "subtype": d["type_str"], "data": d}

## Returns true if a visual field changed (callers rebuild/redraw the art).
static func apply_resource_data(node: Node, data: Dictionary) -> bool:
	if node == null or not ("interactable_type_str" in node):
		return false
	var visual := false
	if data.has("display_name") and str(node.get("display_name")) != str(data["display_name"]):
		node.set("display_name", str(data["display_name"]))
		visual = true
	if data.has("level"):
		node.set("required_level", int(data["level"]))
	if data.has("action"):
		node.set("action_label", str(data["action"]))
	if data.has("color") and data["color"] is Array and (data["color"] as Array).size() >= 3:
		var a: Array = data["color"]
		var c := Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
		if not (node.get("color") as Color).is_equal_approx(c):
			node.set("color", c)
			visual = true
	if data.has("variant_id") and int(node.get("variant_id")) != int(data["variant_id"]):
		node.set("variant_id", int(data["variant_id"]))
		visual = true
	if visual and node is CanvasItem:
		(node as CanvasItem).queue_redraw()
	return visual
