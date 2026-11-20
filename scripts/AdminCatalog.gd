extends RefCounted

## Catalog of entities the admin (Busterrdust) can place in the world.
## Each entry: {id, kind, label, data}. `data` is JSON-serialisable and carries
## everything World needs to reconstruct the node, so placed entities survive a
## server restart without depending on this catalog.
##
## kind == "resource" → data: {type_str, display_name, skill, level, action, color:[r,g,b,a]}
## kind == "monster"  → data: {monster_type, level}
## kind == "npc"      → data: {npc_type, npc_name, quest_text, wander_radius}

const NpcRoster = preload("res://scripts/admin/NpcRoster.gd")
const ShopCat   = preload("res://scripts/ShopCatalog.gd")

static func _res(type_str: String, name: String, skill: String, level: int,
		action: String, c: Color) -> Dictionary:
	return {
		"id": "res_" + name.to_lower().replace(" ", "_"),
		"kind": "resource", "label": name,
		"data": {
			"type_str": type_str, "display_name": name, "skill": skill,
			"level": level, "action": action,
			"color": [c.r, c.g, c.b, c.a],
		},
	}

## 1.7.5 (V): a tree template with a fixed shape (Pine/Cherry rows 0..2).
static func _tree_shape(name: String, skill: String, level: int, c: Color, v: int) -> Dictionary:
	var e := _res("tree", name, skill, level, "Chop", c)
	e["id"] = "%s_shape_%d" % [e["id"], v + 1]
	e["label"] = "%s (shape %d)" % [name, v + 1]
	(e["data"] as Dictionary)["variant_id"] = v
	return e

static func _mon(monster_type: String, label: String, level: int) -> Dictionary:
	return {
		"id": "mon_" + monster_type, "kind": "monster", "label": label,
		"data": {"monster_type": monster_type, "level": level},
	}

static func _npc(npc_type: String, label: String) -> Dictionary:
	return {
		"id": "npc_" + npc_type, "kind": "npc", "label": label,
		"data": {"npc_type": npc_type, "npc_name": label,
				 "quest_text": "", "wander_radius": 32.0, "shop_id": ""},
	}

## Phase 4 — explicit shopkeeper factory. `shop_id` must match a key in
## ShopCatalog.SHOPS or clicking the placed NPC does nothing.
static func _shopkeeper(shop_id: String, label: String) -> Dictionary:
	return {
		"id": "npc_shop_" + shop_id, "kind": "npc", "label": label,
		"data": {"npc_type": "shopkeeper", "npc_name": label,
				 "quest_text": "", "wander_radius": 0.0, "shop_id": shop_id},
	}

## Phase 6 — door interactable factory. `interior_id` must later match a key
## in InteriorCatalog (Phase 8). Click sends enter_interior to the server.
static func _door(interior_id: String, label: String) -> Dictionary:
	return {
		"id": "door_" + interior_id, "kind": "resource", "label": label,
		"data": {
			"type_str":     "door",
			"display_name": label,
			"skill":        "",
			"level":        1,
			"action":       "Enter",
			"color":        [0.45, 0.30, 0.15, 1.0],
			"interior_id":  interior_id,
		},
	}

## `roster` = NpcRoster.build(...) result; NPC templates are derived from it.
static func entries(roster: Dictionary = {}) -> Array:
	return [
		# ── Trees ───────────────────────────────────────────────────────────────
		_res("tree", "Oak Tree",     "woodcutting",  1, "Chop", Color(0.18, 0.55, 0.15)),
		_res("tree", "Pine Tree",    "woodcutting",  5, "Chop", Color(0.10, 0.42, 0.20)),
		_res("tree", "Cherry Tree",  "woodcutting", 20, "Chop", Color(0.98, 0.72, 0.80)),
		_res("tree", "Ironwood Tree","woodcutting", 30, "Chop", Color(0.30, 0.18, 0.08)),
		_res("tree", "Frost Tree",   "woodcutting", 50, "Chop", Color(0.72, 0.90, 0.98)),
		_res("tree", "Ancient Tree", "woodcutting", 70, "Chop", Color(0.35, 0.20, 0.08)),
		# 1.7.5 — each Pine/Cherry shape as its own pick (stored variant_id; the plain
		# entries above store the shape their spot gives). Name stays the tree's own.
		_tree_shape("Pine Tree",   "woodcutting",  5, Color(0.10, 0.42, 0.20), 0),
		_tree_shape("Pine Tree",   "woodcutting",  5, Color(0.10, 0.42, 0.20), 1),
		_tree_shape("Pine Tree",   "woodcutting",  5, Color(0.10, 0.42, 0.20), 2),
		_tree_shape("Cherry Tree", "woodcutting", 20, Color(0.98, 0.72, 0.80), 0),
		_tree_shape("Cherry Tree", "woodcutting", 20, Color(0.98, 0.72, 0.80), 1),
		_tree_shape("Cherry Tree", "woodcutting", 20, Color(0.98, 0.72, 0.80), 2),
		# ── Rocks ───────────────────────────────────────────────────────────────
		_res("rock", "Copper Rock",  "mining",  1, "Mine", Color(0.72, 0.42, 0.22)),
		_res("rock", "Iron Rock",    "mining", 15, "Mine", Color(0.55, 0.55, 0.60)),
		_res("rock", "Gold Vein",    "mining", 30, "Mine", Color(0.88, 0.72, 0.12)),
		_res("rock", "Mithril Rock", "mining", 50, "Mine", Color(0.40, 0.65, 0.90)),
		_res("rock", "Adamant Rock", "mining", 70, "Mine", Color(0.20, 0.65, 0.30)),
		_res("rock", "Runite Rock",  "mining", 85, "Mine", Color(0.65, 0.20, 0.82)),
		# ── Rune Essence (admin-placed only — no procedural spawn) ─────────────
		# Distinct crystalline visual + server-wide single-lock + 7s respawn.
		# Mining-skill primary + magic-level secondary XP bonus (in Interactable._deplete).
		_res("essence", "Rune Essence Node", "mining", 1, "Mine", Color(0.55, 0.35, 0.85)),
		# ── Fishing ─────────────────────────────────────────────────────────────
		_res("fish", "Fishing Spot", "fishing",  1, "Fish", Color(0.18, 0.52, 0.82)),
		_res("fish", "Salmon Spot",  "fishing", 20, "Fish", Color(0.95, 0.55, 0.30)),
		_res("fish", "Lobster Pot",  "fishing", 40, "Fish", Color(0.90, 0.30, 0.20)),
		_res("fish", "Shark Waters", "fishing", 60, "Fish", Color(0.55, 0.58, 0.62)),
		# ── Foraging ────────────────────────────────────────────────────────────
		_res("herb", "Herb Patch",      "foraging",  1, "Pick", Color(0.62, 0.82, 0.20)),
		_res("herb", "Mushroom Patch",  "foraging", 10, "Pick", Color(0.72, 0.55, 0.38)),
		_res("herb", "Moonbloom Patch", "foraging", 40, "Pick", Color(0.78, 0.62, 0.95)),
		_res("herb", "Berry Bush",      "foraging", 25, "Pick", Color(0.24, 0.50, 0.20)),
		_res("herb", "Ancient Root",    "foraging", 65, "Pick", Color(0.42, 0.28, 0.12)),
		# ── Stations / structures (admin-placeable; town-only by default) ─────
		# Forge / Auction House use the seeded colour: the authored art (1.7.5)
		# is painted for it, and any other colour tints the whole building.
		_res("forge",        "Forge",          "smithing",     1, "Use",     Color(0.80, 0.35, 0.12)),
		_res("fire",         "Campfire",       "cooking",      1, "Cook",    Color(0.95, 0.55, 0.10)),
		_res("bank",         "Bank",           "",             1, "Bank",    Color(0.30, 0.60, 0.85)),
		_res("building",     "Town Building",  "",             1, "Enter",   Color(0.55, 0.45, 0.32)),
		_res("crafting",     "Crafting Bench", "crafting",     1, "Craft",   Color(0.70, 0.50, 0.20)),
		_res("archery",      "Archery Range",  "ranged",       1, "Train",   Color(0.50, 0.35, 0.20)),
		_res("training_dummy","Training Dummy", "melee",        1, "Spar",    Color(0.55, 0.42, 0.24)),
		_res("runestone",    "Runestone",      "magic",        1, "Inscribe",Color(0.50, 0.20, 0.75)),
		_res("construction", "Workbench",      "construction", 1, "Build",   Color(0.55, 0.40, 0.20)),
		_res("farm_plot",    "Farm Plot",      "farming",      1, "Use",     Color(0.55, 0.42, 0.20)),
		# ── Walls (Construction skill wall recipes; admin can spawn freely) ─
		# Tiered by wood color — mirrors HUD.gd _CONSTR_WOOD entries. Player
		# path via Construction recipe deducts materials + XP; admin path
		# via admin_place bypasses all gates.
		_res("wall", "Oak Wall",       "construction",  1, "Inspect", Color(0.55, 0.36, 0.18)),
		_res("wall", "Pine Wall",      "construction",  1, "Inspect", Color(0.42, 0.30, 0.14)),
		_res("wall", "Cherry Wall",    "construction",  1, "Inspect", Color(0.72, 0.38, 0.42)),
		_res("wall", "Ironwood Wall",  "construction",  1, "Inspect", Color(0.30, 0.18, 0.08)),
		_res("wall", "Frost Wall",     "construction",  1, "Inspect", Color(0.72, 0.90, 0.98)),
		_res("wall", "Ancient Wall",   "construction",  1, "Inspect", Color(0.55, 0.40, 0.12)),
		_res("fortified_wall", "Fortified Wall (Iron)",    "construction", 70, "Inspect", Color(0.55, 0.55, 0.60)),
		_res("fortified_wall", "Fortified Wall (Mithril)", "construction", 70, "Inspect", Color(0.40, 0.65, 0.90)),
		_res("fortified_wall", "Fortified Wall (Runite)",  "construction", 70, "Inspect", Color(0.65, 0.20, 0.82)),
		_res("auction_house","Auction House",  "",             1, "Browse",  Color(0.45, 0.60, 0.85)),
		# ── Named town buildings (1.7.5) — exact seeded type/name/colour, so a
		# placed one gets its authored art without hand-renaming. Renaming a
		# "building" later reverts it to the procedural draw (art is per name).
		_res("building",     "Chapel",           "soul", 1, "Inspect", Color(0.75, 0.72, 0.66)),
		_res("building",     "Great Hall",       "soul", 1, "Inspect", Color(0.35, 0.22, 0.12)),
		_res("building",     "Tavern",           "soul", 1, "Inspect", Color(0.70, 0.48, 0.22)),
		_res("building",     "Warehouse",        "soul", 1, "Inspect", Color(0.50, 0.44, 0.32)),
		_res("large_house",  "Barracks",         "soul", 1, "Inspect", Color(0.52, 0.42, 0.30)),
		_res("grand_hall",   "Kjelvik Keep",     "soul", 1, "Inspect", Color(0.42, 0.40, 0.46)),
		_res("clan_hall",    "Hall of Warbands", "soul", 1, "Inspect", Color(0.40, 0.34, 0.44)),
		_res("well",         "Castle Well",      "soul", 1, "Inspect", Color(0.58, 0.60, 0.64)),
		_res("armory_rack",  "Armory",           "soul", 1, "Inspect", Color(0.60, 0.55, 0.40)),
		_res("market_stall", "Market Stall",     "soul", 1, "Browse",  Color(0.72, 0.50, 0.28)),
		_res("stick",        "Stick Pickup",   "foraging",     1, "Pick",    Color(0.55, 0.36, 0.18)),
		_res("stone",        "Stone Pickup",   "foraging",     1, "Pick",    Color(0.58, 0.56, 0.52)),
		# ── Monsters ────────────────────────────────────────────────────────────
		_mon("chicken",   "Chicken",        1),
		_mon("rat",       "Giant Rat",      2),
		_mon("plague_rat","Plague Rat",    10),
		_mon("goblin",    "Goblin",         5),
		_mon("wolf",      "Wolf",          10),
		_mon("bandit",    "Bandit",        15),
		_mon("skeleton",  "Skeleton",      18),
		_mon("bear",      "Bear",          25),
		_mon("troll",     "Troll",         35),
		_mon("ice_wolf",  "Ice Wolf",      30),
		_mon("frost_giant","Frost Giant",  45),
		_mon("draugr",    "Draugr",        40),
		_mon("nidhogg",   "Níðhöggr Boss", 60),
		# Phase-N expansion: previously-missing types so all 26 monsters in
		# Monster.gd._apply_type_stats are reachable from the panel. Default
		# levels match each type's intrinsic stats in _apply_type_stats so the
		# SpinBox's catalog-default value lines up with the no-scale baseline.
		_mon("dire_wolf",        "Dire Wolf",         15),
		_mon("spider",           "Spider",            24),
		_mon("elder_bear",       "Elder Bear",        29),
		_mon("forest_spirit",    "Forest Spirit",     30),
		_mon("ancient_troll",    "Ancient Troll",     44),
		_mon("swamp_troll",      "Swamp Troll",       30),
		_mon("ice_troll",        "Ice Troll",         40),
		_mon("cave_troll",       "Cave Troll",        45),
		_mon("fire_imp",         "Fire Imp",          55),
		_mon("lava_crawler",     "Lava Crawler",      60),
		_mon("frost_wyrm",       "Frost Wyrm",        62),
		_mon("fire_giant",       "Fire Giant",        45),
		_mon("shadow_draugr",    "Shadow Draugr",     68),
		_mon("death_knight",     "Death Knight",      75),
		_mon("magma_elemental",  "Magma Elemental",   76),
		_mon("spectral_warrior", "Spectral Warrior",  80),
		# Slim dragon family (V1.5.4) — lean cousins of Níðhöggr.
		_mon("drake",            "Bronze Drake",      48),
		_mon("wyvern",           "Venom Wyvern",      58),
		# Water — water-only pathing, semi-transparent, targets boats.
		_mon("shark",            "Shark",             30),
		# ── Doors (Phase 6) — each leads to an interior defined in Phase 8.
		_door("kjelvik_general_store",     "General Store Door"),
		_door("frostheim_smith",           "Frostheim Smith Door"),
		_door("bjorns_fishmonger",         "Fishmonger Door"),
		_door("eastmark_apothecary",       "Apothecary Door"),
		_door("ironwood_magic_vendor",     "Magic Vendor Door"),
	] + npc_entries(roster)

## Preferred keeper name per ShopCatalog shop (the names these shops shipped with).
const SHOP_KEEPERS: Dictionary = {
	"general_store": "Bjorn the Trader",
	"weapons_smith": "Blacksmith Ulfr",
	"fishmonger":    "Sigrid the Fishmonger",
	"apothecary":    "Brynhildr the Apothecary",
	"magic_vendor":  "Eirik the Rune-Master",
}

## NPC templates for the Place tab, DERIVED from live data (NpcRoster.build) so
## they can't go stale. Seeded NPCs are never offered here — a deleted seed is
## brought back with Restore in the NPC roster instead (home spot, original name,
## quests intact), which avoids duplicate quest givers. Contents:
##   • generic types (Villager, Banker, …)
##   • one shopkeeper per ShopCatalog shop; a quest-bound keeper name that is
##     already seeded/placed falls back to "<Shop name> Keeper"
##   • every quest NPC that is neither seeded nor placed (exact quest name)
## An empty roster (no world yet) falls back to the seed names alone.
static func npc_entries(roster: Dictionary = {}) -> Array:
	var out: Array = [
		_npc("worker",     "Villager"),
		_npc("shopkeeper", "Merchant"),      # generic — no shop_id, opens no shop
		_npc("banker",     "Banker"),
		_npc("quest",      "Quest Giver"),   # custom dialogue only — no quests bind to it
		_npc("tutor",      "Tutor"),
		_npc("trainer",    "Trainer"),
	]
	var taken: Dictionary = roster.get("taken_names", {}) as Dictionary
	if taken.is_empty():
		for d_v: Variant in NpcRoster.seed_rows():
			taken[str((d_v as Array)[2])] = true
	var quest_names: Dictionary = NpcRoster.quest_npcs()
	var keeper_by_name: Dictionary = {}
	for sid_v: Variant in ShopCat.SHOPS.keys():
		var sid := str(sid_v)
		var keeper := str(SHOP_KEEPERS.get(sid, ""))
		keeper_by_name[keeper] = sid
		if keeper == "" or (quest_names.has(keeper) and taken.has(keeper)):
			keeper = "%s Keeper" % str((ShopCat.SHOPS[sid] as Dictionary).get("name", sid))
		out.append(_shopkeeper(sid, keeper))
	var missing: Array = roster.get("missing_quest_names", []) as Array
	if roster.is_empty():
		for q_v: Variant in quest_names.keys():
			if not taken.has(str(q_v)):
				missing.append(str(q_v))
	for m_v: Variant in missing:
		var nm := str(m_v)
		if keeper_by_name.has(nm) and quest_names.has(nm) and not taken.has(nm):
			continue   # the shop template above already carries this exact name
		var e := _npc("quest", nm)
		e["id"] = "npc_missing_" + nm.to_lower().replace(" ", "_")
		out.append(e)
	return out

static func monster_types() -> Array:
	var out: Array = []
	for e: Dictionary in entries():
		if e["kind"] == "monster":
			out.append(str((e["data"] as Dictionary)["monster_type"]))
	return out
