extends RefCounted

## Catalog of entities the admin (Busterrdust) can place in the world.
## Each entry: {id, kind, label, data}. `data` is JSON-serialisable and carries
## everything World needs to reconstruct the node, so placed entities survive a
## server restart without depending on this catalog.
##
## kind == "resource" → data: {type_str, display_name, skill, level, action, color:[r,g,b,a]}
## kind == "monster"  → data: {monster_type, level}
## kind == "npc"      → data: {npc_type, npc_name, quest_text, wander_radius}

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

static func entries() -> Array:
	return [
		# ── Trees ───────────────────────────────────────────────────────────────
		_res("tree", "Oak Tree",     "woodcutting",  1, "Chop", Color(0.18, 0.55, 0.15)),
		_res("tree", "Pine Tree",    "woodcutting",  5, "Chop", Color(0.10, 0.42, 0.20)),
		_res("tree", "Cherry Tree",  "woodcutting", 20, "Chop", Color(0.98, 0.72, 0.80)),
		_res("tree", "Frost Tree",   "woodcutting", 50, "Chop", Color(0.72, 0.90, 0.98)),
		_res("tree", "Ancient Tree", "woodcutting", 70, "Chop", Color(0.35, 0.20, 0.08)),
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
		_res("forge",        "Forge",          "smithing",     1, "Use",     Color(0.60, 0.45, 0.20)),
		_res("fire",         "Campfire",       "cooking",      1, "Cook",    Color(0.95, 0.55, 0.10)),
		_res("bank",         "Bank",           "",             1, "Bank",    Color(0.30, 0.60, 0.85)),
		_res("building",     "Town Building",  "",             1, "Enter",   Color(0.55, 0.45, 0.32)),
		_res("crafting",     "Crafting Bench", "crafting",     1, "Craft",   Color(0.70, 0.50, 0.20)),
		_res("archery",      "Archery Range",  "ranged",       1, "Train",   Color(0.50, 0.35, 0.20)),
		_res("runestone",    "Runestone",      "magic",        1, "Inscribe",Color(0.50, 0.20, 0.75)),
		_res("construction", "Workbench",      "construction", 1, "Build",   Color(0.55, 0.40, 0.20)),
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
		_res("auction_house","Auction House",  "",             1, "Browse",  Color(0.85, 0.70, 0.25)),
		_res("stick",        "Stick Pickup",   "foraging",     1, "Pick",    Color(0.55, 0.36, 0.18)),
		_res("stone",        "Stone Pickup",   "foraging",     1, "Pick",    Color(0.58, 0.56, 0.52)),
		# ── Monsters ────────────────────────────────────────────────────────────
		_mon("chicken",   "Chicken",        1),
		_mon("rat",       "Giant Rat",      2),
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
		_mon("fire_imp",         "Fire Imp",          55),
		_mon("lava_crawler",     "Lava Crawler",      60),
		_mon("frost_wyrm",       "Frost Wyrm",        62),
		_mon("fire_giant",       "Fire Giant",        65),
		_mon("shadow_draugr",    "Shadow Draugr",     68),
		_mon("death_knight",     "Death Knight",      75),
		_mon("magma_elemental",  "Magma Elemental",   76),
		_mon("spectral_warrior", "Spectral Warrior",  80),
		# Water — water-only pathing, semi-transparent, targets boats.
		_mon("shark",            "Shark",             30),
		# ── NPCs ────────────────────────────────────────────────────────────────
		_npc("worker",     "Villager"),
		_npc("shopkeeper", "Merchant"),      # generic — no shop_id, opens no shop
		_npc("banker",     "Banker"),
		_npc("quest",      "Quest Giver"),
		_npc("tutor",      "Tutor"),
		_npc("trainer",    "Trainer"),
		# ── Shopkeepers (Phase 4) — each binds a ShopCatalog template ─────────
		_shopkeeper("general_store", "Bjorn the Trader"),
		_shopkeeper("weapons_smith", "Ulfr the Smith"),
		_shopkeeper("fishmonger",    "Sigrid the Fishmonger"),
		_shopkeeper("apothecary",    "Brynhildr the Apothecary"),
		_shopkeeper("magic_vendor",  "Eirik the Rune-Master"),
		# ── Doors (Phase 6) — each leads to an interior defined in Phase 8.
		_door("kjelvik_general_store",     "General Store Door"),
		_door("frostheim_smith",           "Frostheim Smith Door"),
		_door("bjorns_fishmonger",         "Fishmonger Door"),
		_door("eastmark_apothecary",       "Apothecary Door"),
		_door("ironwood_magic_vendor",     "Magic Vendor Door"),
	]

static func monster_types() -> Array:
	var out: Array = []
	for e: Dictionary in entries():
		if e["kind"] == "monster":
			out.append(str((e["data"] as Dictionary)["monster_type"]))
	return out
