extends RefCounted

## Admin NPC roster — REBUILT FROM LIVE DATA every time it is read, never from a
## hand-kept list, so it cannot drift from the world:
##   • seeded NPCs  = World._NPCS (ids "n:<row>"), status from entity_edits
##   • admin NPCs   = world_entities rows with kind "npc" (ids "a:…")
##   • server NPCs  = server-spawned helpers such as the Wall-Keeper ("wr:<town>")
##   • quest names  = every giver_npc / talk target in QuestData.QUESTS
## Pure + static (no scene tree), so the admin panel and headless checks share it.

const QuestData = preload("res://scripts/QuestData.gd")
const ShopCat   = preload("res://scripts/ShopCatalog.gd")
const NpcRegistry = preload("res://scripts/data/NpcRegistry.gd")

## Default names the generic catalog templates give a placed NPC.
const GENERIC_NAMES: Array = ["Villager", "Merchant", "Banker", "Quest Giver", "Tutor", "Trainer"]

## Title words ignored when matching a misspelt/renamed quest giver
## ("Ulfr the Smith" vs "Blacksmith Ulfr" share the proper name "Ulfr").
const _TITLE_WORDS: Array = [
	"Blacksmith", "Merchant", "Captain", "Scout", "Elder", "Hunter", "Old", "Sea",
	"Ironwood", "Hermit", "Castellan", "Wanderer", "Apothecary", "Fishmonger",
	"Trader", "The", "Master", "Keeper", "Smith",
]

## World._NPCS rows ([pos, type, name, dialogue, wander]), read from
## the script constant at call time so new seed rows show up automatically.
static func seed_rows() -> Array:
	var scr := load("res://scripts/World.gd") as GDScript
	if scr == null:
		return []
	var v: Variant = scr.get_script_constant_map().get("_NPCS", [])
	return v as Array if v is Array else []

## name → {"quests": giver count, "talk": true if a talk objective targets it}.
static func quest_npcs() -> Dictionary:
	var out: Dictionary = {}
	for qid_v: Variant in QuestData.QUESTS.keys():
		var q: Dictionary = QuestData.QUESTS[qid_v]
		var giver := str(q.get("giver_npc", ""))
		if giver != "":
			var g: Dictionary = out.get(giver, {"quests": 0, "talk": false})
			g["quests"] = int(g["quests"]) + 1
			out[giver] = g
		for o_v: Variant in q.get("objectives", []):
			if o_v is Dictionary and str((o_v as Dictionary).get("type", "")) == "talk":
				var t := str((o_v as Dictionary).get("target_id", ""))
				if t != "":
					var tg: Dictionary = out.get(t, {"quests": 0, "talk": false})
					tg["talk"] = true
					out[t] = tg
	return out

## Build the roster. `edits` = NetworkManager.entity_edits_cache,
## `world_entities` = NetworkManager.world_entities_cache (both kept live).
## Returns {rows, deleted, problems, taken_names, missing_quest_names}.
static func build(seeds: Array, edits: Array, world_entities: Array) -> Dictionary:
	var qn := quest_npcs()
	var edit_by_id: Dictionary = {}
	for e_v: Variant in edits:
		if e_v is Dictionary:
			edit_by_id[str((e_v as Dictionary).get("id", ""))] = e_v
	var rows: Array = []
	var deleted: Array = []
	var problems: Array = []
	var taken: Dictionary = {}      # every seeded or live NPC name (blocks duplicate templates)

	for i in range(seeds.size()):
		var d: Array = seeds[i]
		var id := "n:%d" % i
		var seed_name := str(d[2])
		taken[seed_name] = true
		var home: Vector2 = d[0]
		var row := {
			"id": id, "name": seed_name, "seed_name": seed_name, "type": str(d[1]),
			"source": "seed", "status": "ok", "pos": home, "home": home,
			"shop_id": NpcRegistry.shop_of(seed_name),
			"quests": int((qn.get(seed_name, {}) as Dictionary).get("quests", 0)),
			"talk": bool((qn.get(seed_name, {}) as Dictionary).get("talk", false)),
		}
		var ed: Dictionary = edit_by_id.get(id, {})
		if not ed.is_empty():
			if ed.get("data") is Dictionary:
				var dd: Dictionary = ed["data"]
				if dd.has("npc_name"):
					row["name"] = str(dd["npc_name"])
				if dd.has("shop_id"):
					row["shop_id"] = str(dd["shop_id"])
				if dd.has("npc_type"):
					row["type"] = str(dd["npc_type"])
			if bool(ed.get("deleted", false)):
				row["status"] = "deleted"
			elif ed.get("x") != null and ed.get("y") != null:
				row["status"] = "moved"
				row["pos"] = Vector2(float(ed["x"]), float(ed["y"]))
		rows.append(row)
		if row["status"] == "deleted":
			deleted.append(row)

	for w_v: Variant in world_entities:
		if not (w_v is Dictionary):
			continue
		var w: Dictionary = w_v
		if str(w.get("kind", "")) != "npc":
			continue
		var data: Dictionary = w.get("data", {}) as Dictionary if w.get("data") is Dictionary else {}
		var id := str(w.get("id", ""))
		var nm := str(data.get("npc_name", ""))
		var row := {
			"id": id, "name": nm, "seed_name": "",
			"type": str(data.get("npc_type", w.get("subtype", ""))),
			"source": "server" if not id.begins_with("a:") else "admin", "status": "ok",
			"pos": Vector2(float(w.get("x", 0.0)), float(w.get("y", 0.0))),
			"home": Vector2(float(w.get("x", 0.0)), float(w.get("y", 0.0))),
			"shop_id": str(data.get("shop_id", "")),
			"quests": int((qn.get(nm, {}) as Dictionary).get("quests", 0)),
			"talk": bool((qn.get(nm, {}) as Dictionary).get("talk", false)),
		}
		rows.append(row)
		if row["source"] == "admin":
			taken[nm] = true

	# ── Problems ─────────────────────────────────────────────────────────────
	var live_count: Dictionary = {}     # name → [ids] of NPCs that exist right now
	for r_v: Variant in rows:
		var r: Dictionary = r_v
		if r["status"] == "deleted" or r["source"] == "server":
			continue
		var ids: Array = live_count.get(r["name"], [])
		ids.append(r["id"])
		live_count[r["name"]] = ids
	for r_v: Variant in rows:
		var r: Dictionary = r_v
		var nm := str(r["name"])
		var nq := int(r["quests"])
		if r["status"] == "deleted":
			if nq > 0 or bool(r["talk"]):
				problems.append(_problem(r, "high",
					"deleted quest NPC — %s unavailable until restored" % _quest_phrase(nq, bool(r["talk"]))))
			continue
		if r["source"] == "server":
			continue
		if r["source"] == "seed" and nm != str(r["seed_name"]):
			var sq := (qn.get(str(r["seed_name"]), {}) as Dictionary)
			if not sq.is_empty():
				problems.append(_problem(r, "high", "renamed from '%s' — its %s no longer bind" % [
					r["seed_name"], _quest_phrase(int(sq.get("quests", 0)), bool(sq.get("talk", false)))]))
		if r["source"] == "admin" and GENERIC_NAMES.has(nm):
			if nm == "Quest Giver":
				problems.append(_problem(r, "medium", "placeholder quest giver — no quest uses this name"))
			else:
				problems.append(_problem(r, "low", "generic placeholder name"))
		var same: Array = live_count.get(nm, [])
		if same.size() > 1 and not GENERIC_NAMES.has(nm):
			var others: Array = same.filter(func(x: Variant) -> bool: return str(x) != str(r["id"]))
			var sev := "high" if (nq > 0 or bool(r["talk"])) else "medium"
			problems.append(_problem(r, sev, "duplicate name (also %s)%s" % [
				", ".join(PackedStringArray(others.map(func(x: Variant) -> String: return str(x)))),
				" — quests offered twice" if sev == "high" else ""]))
		if r["source"] == "admin" and not qn.has(nm) and not GENERIC_NAMES.has(nm):
			var look := _lookalike(nm, qn)
			if look != "":
				var lq: Dictionary = qn[look]
				problems.append(_problem(r, "medium", "looks like '%s' but the name differs — gets none of its %s" % [
					look, _quest_phrase(int(lq.get("quests", 0)), bool(lq.get("talk", false)))]))
		var stype := str(r["type"])
		var sid := str(r["shop_id"])
		if (stype == "shopkeeper" or sid != "") and (sid == "" or not ShopCat.SHOPS.has(sid)):
			problems.append(_problem(r, "medium", "shopkeeper with invalid shop_id '%s'" % sid))

	var missing: Array = []
	for q_v: Variant in qn.keys():
		var qname := str(q_v)
		if live_count.has(qname):
			continue
		var seeded := false
		for d_v: Variant in deleted:
			if str((d_v as Dictionary)["seed_name"]) == qname:
				seeded = true
		if seeded:
			continue   # already reported as a deleted seed with a Restore button
		missing.append(qname)
		var q: Dictionary = qn[qname]
		problems.append({"id": "", "name": qname, "pos": null, "severity": "high",
			"issue": "missing quest NPC (not seeded) — place it from the NPCs tab; %s blocked" % _quest_phrase(
				int(q.get("quests", 0)), bool(q.get("talk", false)))})

	for q_v: Variant in qn.keys():
		if not NpcRegistry.has(str(q_v)):
			problems.append({"id": "", "name": str(q_v), "pos": null, "severity": "medium",
				"issue": "quest NPC missing from NpcRegistry — its quests give no town standing"})

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	var rank := {"high": 0, "medium": 1, "low": 2}
	problems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := int(rank.get(a["severity"], 3))
		var rb := int(rank.get(b["severity"], 3))
		if ra != rb:
			return ra < rb
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return {"rows": rows, "deleted": deleted, "problems": problems,
		"taken_names": taken, "missing_quest_names": missing}

static func _problem(r: Dictionary, severity: String, issue: String) -> Dictionary:
	return {"id": str(r["id"]), "name": str(r["name"]), "pos": r["pos"],
		"severity": severity, "issue": issue}

static func _quest_phrase(n: int, talk: bool) -> String:
	var bits: Array = []
	if n > 0:
		bits.append("%d quest%s" % [n, "" if n == 1 else "s"])
	if talk:
		bits.append("a talk objective")
	return " + ".join(PackedStringArray(bits)) if not bits.is_empty() else "nothing"

## Quest-bound name that shares a proper-name word with `nm`, or "".
static func _lookalike(nm: String, qn: Dictionary) -> String:
	var mine := _proper_words(nm)
	if mine.is_empty():
		return ""
	for q_v: Variant in qn.keys():
		for w: String in _proper_words(str(q_v)):
			if mine.has(w):
				return str(q_v)
	return ""

static func _proper_words(nm: String) -> Array:
	var out: Array = []
	for w: String in nm.replace("-", " ").split(" ", false):
		if w.length() >= 3 and w[0] == w[0].to_upper() and w[0] != w[0].to_lower() \
				and not _TITLE_WORDS.has(w):
			out.append(w)
	return out
