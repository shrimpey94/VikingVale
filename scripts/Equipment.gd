extends RefCounted

## Equipment slot model + stat lookup. Accessed via `const GearDB = preload(...)`
## in consumers (static methods) so it resolves at compile time by path — no
## dependence on autoload registration or the global class-name cache.

const Fishing = preload("res://scripts/Fishing.gd")

## Equipment slot model + stat lookup. Stats are derived from the item id by
## naming convention ("{tier}_{piece}", e.g. "iron_helm", "mithril_sword") so the
## craftable tier sets in the crafting system get bonuses automatically. A few
## hand-named items (existing boots, amulet, bow) are listed explicitly in DEFS.

# Paper-doll slots, in a rough top→bottom order. ring1..ring8 are the finger slots.
# `bait` is the fishing tackle slot (Phase 5 of the fishing rework) — accepts
# either bait or lure items per `Fishing.is_bait/is_lure`. Treated specially
# in is_equippable / target_slot / def_for below so it doesn't try to match
# the "{tier}_{piece}" naming convention.
const SLOTS: Array[String] = [
	"head", "neck", "body", "arms", "hands", "legs", "boots", "weapon", "offhand",
	"ring1", "ring2", "ring3", "ring4", "ring5", "ring6", "ring7", "ring8",
	"bait",
]

const SLOT_LABELS: Dictionary = {
	"head": "Helm", "neck": "Amulet", "body": "Body", "arms": "Bracers",
	"hands": "Gloves", "legs": "Legs", "boots": "Boots", "weapon": "Weapon",
	"offhand": "Off-hand",
	"ring1": "Ring", "ring2": "Ring", "ring3": "Ring", "ring4": "Ring",
	"ring5": "Ring", "ring6": "Ring", "ring7": "Ring", "ring8": "Ring",
	"bait": "Bait",
}

const RING_SLOTS: Array[String] = ["ring1", "ring2", "ring3", "ring4",
	"ring5", "ring6", "ring7", "ring8"]

# Tier → power index. Higher = stronger. Gold sits low for combat by design.
const TIER_INDEX: Dictionary = {
	"leather": 0, "copper": 1, "bronze": 1, "iron": 2, "gold": 1,
	"mithril": 4, "adamant": 5, "runite": 6, "dragon": 7,
}

# Piece keyword → slot
const PIECE_SLOT: Dictionary = {
	"helm": "head", "helmet": "head",
	"amulet": "neck", "necklace": "neck",
	"body": "body", "platebody": "body", "chestplate": "body",
	"bracers": "arms", "vambraces": "arms", "arms": "arms",
	"gloves": "hands", "gauntlets": "hands", "glove": "hands",
	"legs": "legs", "platelegs": "legs", "leg": "legs",
	"boots": "boots", "boot": "boots",
	"shield": "offhand", "quiver": "offhand",
	"sword": "weapon", "axe": "weapon", "battleaxe": "weapon", "mace": "weapon",
	"bow": "weapon", "staff": "weapon",
	"ring": "ring",
}

# Base armour defence by piece (scaled up by tier).
const _DEF_BASE: Dictionary = {
	"head": 3, "body": 6, "legs": 5, "boots": 2, "hands": 2, "arms": 2, "offhand": 4,
}
# Base attack by weapon keyword (scaled up by tier).
const _ATK_BASE: Dictionary = {
	"sword": 6, "axe": 7, "battleaxe": 8, "mace": 5, "bow": 5, "staff": 4,
}

# Explicit overrides for hand-named / pre-existing items.
const DEFS: Dictionary = {
	"leather_boots": {"slot": "boots", "name": "Leather Boots", "def": 2, "speed": 0.10},
	"iron_boots":    {"slot": "boots", "name": "Iron Boots",    "def": 5, "speed": 0.20},
	"mithril_boots": {"slot": "boots", "name": "Mithril Boots", "def": 9, "speed": 0.30},
	"dragon_boots":  {"slot": "boots", "name": "Dragon Boots",  "def": 14, "speed": 0.40},
	"gold_amulet":   {"slot": "neck",  "name": "Gold Amulet",   "hp": 10, "acc": 2},
	"ironwood_bow":  {"slot": "weapon","name": "Ironwood Bow",  "atk": 9, "acc": 3, "style": "ranged"},
	"mithril_sword": {"slot": "weapon","name": "Mithril Sword", "atk": 18, "acc": 4, "style": "melee"},
}

## Returns a stat dict for an item, or {} if it isn't equippable.
static func def_for(item_id: String) -> Dictionary:
	if DEFS.has(item_id):
		return DEFS[item_id]
	# Fishing tackle (bait + lures) — the slot is fixed and the "stats" the UI
	# cares about are the bonus fields on the Fishing entry itself. Return a
	# slot-stub so equip_item / target_slot / unequip just work; consumers
	# that need the bonus fields (Player.gd) call Fishing.tackle_data() to
	# read catch_bonus / rare_bonus / monster_bonus directly.
	if Fishing.is_bait(item_id) or Fishing.is_lure(item_id):
		var td: Dictionary = Fishing.tackle_data(item_id)
		return {"slot": "bait", "name": str(td.get("name", item_id))}
	var parts := item_id.split("_", false)
	if parts.size() < 2:
		return {}
	var tier: String = parts[0]
	if not TIER_INDEX.has(tier):
		return {}
	var piece: String = parts[parts.size() - 1]
	if not PIECE_SLOT.has(piece):
		return {}
	var slot: String = PIECE_SLOT[piece]
	var ti: int = TIER_INDEX[tier]
	var pretty: String = item_id.replace("_", " ").capitalize()
	var d: Dictionary = {"slot": ("ring" if slot == "ring" else slot), "name": pretty}
	if slot == "weapon":
		var base: int = _ATK_BASE.get(piece, 5)
		d["atk"] = int(round(base * (1.0 + ti * 0.7)))
		d["acc"] = 2 + ti
		d["style"] = "ranged" if piece == "bow" else ("magic" if piece == "staff" else "melee")
	elif slot == "ring":
		d["atk"] = 1 + int(ti / 2.0)
		d["def"] = 1 + int(ti / 2.0)
		d["hp"]  = 2 + ti
	elif slot == "neck":
		d["hp"]  = 5 + ti * 3
		d["acc"] = 1 + ti
	else:
		var base: int = _DEF_BASE.get(slot, 2)
		d["def"] = int(round(base * (1.0 + ti * 0.6)))
		# Gold trades defence for a vitality bump (its "luck/xp" flavour, simplified).
		if tier == "gold":
			d["def"] = maxi(1, int(d["def"] * 0.6))
			d["hp"]  = 6 + base
	return d

static func is_equippable(item_id: String) -> bool:
	return not def_for(item_id).is_empty()

## Which concrete slot an item should go into. Rings resolve to the first free
## finger slot (falling back to ring1) given the current loadout.
static func target_slot(item_id: String, equipment: Dictionary) -> String:
	var d := def_for(item_id)
	if d.is_empty():
		return ""
	var slot: String = d["slot"]
	if slot == "ring":
		for r: String in RING_SLOTS:
			if not equipment.has(r) or str(equipment.get(r, "")) == "":
				return r
		return "ring1"
	return slot

static func stat_total(equipment: Dictionary, stat: String) -> int:
	var total := 0
	for slot: String in equipment.keys():
		var iid := str(equipment[slot])
		if iid == "":
			continue
		total += int(def_for(iid).get(stat, 0))
	return total
