extends "res://tools/art/devlog_capture_harness.gd"
## Devlog capture for the 1.7.5 town families (08 buildings, 09 civic, 10 forge,
## 11 bank, 16 townprops, 17 walls). SANDBOX ONLY: run through
## tools/art/capture_devlog_town.ps1. Never referenced by the game.
##
## Adds --devlog-mode=townscout --devlog-family=<family>: walk every village on the
## real (snapshot-replayed) map, find where that family's assets actually stand and
## pick 2-3 camera spots (different villages first) with the most of them in frame
## -> <out>/spots.json. Recording reuses the base harness unchanged; "old" = the
## family's own kill switch (--procedural-<family>).

const TownArt = preload("res://scripts/art/TownArt.gd")
const MAX_SPOTS := 3
const MIN_SPACING := 900.0          # world px between chosen spots
const SCAN_STEP := 384.0

var _family := ""

func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--devlog-family="): _family = a.trim_prefix("--devlog-family=")
	super._ready()
	# Base harness only knows --procedural-forest; any family switch means "old".
	_procedural = Array(OS.get_cmdline_user_args()).any(func(a: String) -> bool: return a.begins_with("--procedural-"))

func _run() -> void:
	if _mode != "townscout":
		await super._run()
		return
	print("DEVLOG_HARNESS mode=townscout family=%s" % _family)
	await _townscout()
	get_tree().quit(0)

func _townscout() -> void:
	if not await _load_world(WORLD_2D):
		return
	await _wait(2.0)
	var members: Array = []          # {id, key, pos, town}
	var seen := {}
	for town: String in TOWNS.keys():
		if town == "bjorns_landing_north": continue
		var area: Rect2 = (TOWNS[town] as Rect2).grow(-TOWN_MARGIN + 320.0)
		var x := area.position.x
		while x <= area.end.x:
			var y := area.position.y
			while y <= area.end.y:
				_park(Vector2(x, y))
				for i in range(12): await get_tree().process_frame
				for n: Node in get_tree().get_nodes_in_group("interactable"):
					if not (n is Node2D) or not is_instance_valid(n): continue
					if not (n.get("color") is Color): continue   # non-structure interactables
					var key := TownArt.key_of(n)
					if key == "" or str(TownArt.ASSETS[key]["family"]) != _family: continue
					var id := str(n.get("entity_id")) if str(n.get("entity_id")) != "" else str(n.get_path())
					if seen.has(id): continue
					seen[id] = true
					members.append({"id": id, "key": key, "pos": (n as Node2D).global_position, "town": _nearest_town((n as Node2D).global_position)})
				y += SCAN_STEP
			x += SCAN_STEP
	print("DEVLOG_TOWNSCOUT|%s|members=%d" % [_family, members.size()])
	for m: Dictionary in members:
		print("DEVLOG_MEMBER|%s|%s|%.0f,%.0f|%s" % [_family, m["key"], (m["pos"] as Vector2).x, (m["pos"] as Vector2).y, m["town"]])
	var chosen: Array = []
	var used_towns := {}
	# Families that only stand in one small area: fall back to closer spacing so the
	# devlog still gets the 2-spot minimum.
	var spacing := MIN_SPACING
	while chosen.size() < MAX_SPOTS:
		var best := {"score": 0.0}
		for m: Variant in members:
			var s := _frame_score((m as Dictionary)["pos"], members)
			var cand: Vector2 = s["center"]
			if chosen.any(func(o: Dictionary) -> bool: return cand.distance_to(Vector2(o["x"], o["y"])) < spacing):
				continue
			var sc: float = s["score"] * (0.6 if used_towns.has(str((m as Dictionary)["town"])) else 1.0)
			if float(s["score"]) >= 1.0 and sc > float(best["score"]):   # threshold before the same-town penalty
				best = s
				best["score"] = sc
				best["town"] = str((m as Dictionary)["town"])
		if float(best["score"]) <= 0.0:
			if chosen.size() < 2 and spacing > 300.0:
				spacing = 300.0
				continue
			break
		used_towns[best["town"]] = int(used_towns.get(best["town"], 0)) + 1
		var c: Vector2 = best["center"]
		chosen.append({"x": roundf(c.x), "y": roundf(c.y), "look_x": 0.0, "look_y": 0.0,
			"town": best["town"], "members": best["keys"], "in_frame": best["count"],
			"location": best["town"] if int(used_towns[best["town"]]) == 1 else "%s_%d" % [best["town"], used_towns[best["town"]]]})
	var spots := {}
	for s: Dictionary in chosen:
		spots[s["location"]] = s
		print("DEVLOG_SPOT|%s|%s|%.0f|%.0f|in_frame=%d|%s" % [_family, s["location"], s["x"], s["y"], int(s["in_frame"]), JSON.stringify(s["members"])])
	var f := FileAccess.open(_out.path_join("spots.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"family": _family, "zoom": ZOOM, "footprint": [FOOT.x, FOOT.y], "spots": spots}, "  "))
		f.close()

## Frame centred on the family members around `at` (their centroid), scored by
## how many sit in frame (middle weighted) plus a little for variety.
func _frame_score(at: Vector2, members: Array) -> Dictionary:
	var near: Array = members.filter(func(m: Dictionary) -> bool: return Rect2(at - FOOT * 0.5, FOOT).has_point(m["pos"]))
	var c := Vector2.ZERO
	for m: Dictionary in near: c += m["pos"]
	c = c / float(maxi(near.size(), 1)) if not near.is_empty() else at
	var keys := {}
	var score := 0.0
	var count := 0
	for m: Variant in members:
		var p: Vector2 = (m as Dictionary)["pos"]
		if not Rect2(c - FOOT * 0.5, FOOT).has_point(p): continue
		count += 1
		score += 1.0 if Rect2(c - FOOT * 0.35, FOOT * 0.7).has_point(p) else 0.6
		var k := str((m as Dictionary)["key"])
		keys[k] = int(keys.get(k, 0)) + 1
	return {"center": c, "score": score + 0.3 * float(keys.size()), "keys": keys, "count": count}

func _nearest_town(p: Vector2) -> String:
	var best := ""
	var bd := INF
	for t: String in TOWNS.keys():
		if t == "bjorns_landing_north": continue
		var d := (TOWNS[t] as Rect2).get_center().distance_to(p)
		if d < bd:
			bd = d
			best = t
	return best
