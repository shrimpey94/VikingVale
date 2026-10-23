extends RefCounted

## Equipment slot model + stat lookup. Accessed via `const GearDB = preload(...)`
## in consumers (static methods) so it resolves at compile time by path — no
## dependence on autoload registration or the global class-name cache.

const Fishing = preload("res://scripts/Fishing.gd")

## Stat categories a gear def may carry (all optional except `slot` + `name`):
##   atk      universal attack bonus (weapon)
##   str      strength — extra melee damage per swing (mace, shield)
##   ratk     ranged-only attack bonus (bow, quiver)
##   matk     magic-only attack bonus (staff)
##   acc      accuracy — feeds hit-chance roll in combat
##   def      armour defence — feeds incoming-hit reduction
##   hp       max-HP bonus (body armor, jewelry)
##   speed    move-speed bonus (boots only)
##   atk_spd  swing-interval multiplier; <1.0 = faster, >1.0 = slower
##   min_lv   skill level required to equip
##   req_skill  which skill min_lv checks (melee/ranged/magic/defense)
##   style    for weapons: melee | ranged | magic
##
## Consumers: GameManager.get_attack_power (atk + str/ratk/matk),
## GameManager.get_attack_speed_mult (atk_spd), GameManager.equip_gate
## (min_lv / req_skill), GameManager.get_max_hp (hp), HUD hit-chance roll
## (acc), HUD._gear_stat_block (display everything present).

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

## Level BANDS per tier (Phase 1 rescale). A piece's min_lv scales WITHIN its
## band by slot (per _SLOT_BAND_FRAC) so gear unlocks gradually across a tier
## instead of jumping in flat 15-level cliffs. `[lo, hi]` inclusive. Gold has
## no combat band — it's jewelry/utility only. Weapons check the style skill;
## armor checks defense.
##   leather 1-1 (no gate) · copper 1-15 · iron 15-30 · mithril 30-50
##   adamant 50-70 · runite 70-85 · dragon 85-99
const _TIER_BAND: Dictionary = {
	"leather": [1, 1],
	"copper":  [1, 15],
	"bronze":  [1, 15],
	"iron":    [15, 30],
	"mithril": [30, 50],
	"adamant": [50, 70],
	"runite":  [70, 85],
	"dragon":  [85, 99],
}
## Where a slot sits within its tier band (0 = band floor, 1 = band ceiling).
## Lighter pieces gate low, heavier pieces high — so inside one tier you unlock
## boots/gloves first and body/shield last, giving a smooth within-tier ramp.
const _SLOT_BAND_FRAC: Dictionary = {
	"boots": 0.0, "hands": 0.12, "arms": 0.25, "head": 0.38,
	"weapon": 0.5, "legs": 0.62, "offhand": 0.75, "body": 0.9,
}

## min_lv for a (tier, slot) derived from the band + slot fraction. Leather
## (band [1,1]) always returns 1 → effectively ungated starter gear.
static func _tier_slot_min_lv(tier: String, slot: String) -> int:
	if not _TIER_BAND.has(tier):
		return 1
	var band: Array = _TIER_BAND[tier]
	var lo: int = int(band[0])
	var hi: int = int(band[1])
	if hi <= lo:
		return lo
	var frac: float = float(_SLOT_BAND_FRAC.get(slot, 0.5))
	return lo + int(round(frac * float(hi - lo)))

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

## Boots speed by tier — displayed "Move +X%" stat. Kept in lockstep with
## GameManager.boot_speed_bonus (8% base, +8% per tier step) so the tooltip
## never contradicts the actual movement effect. Gold sits at the iron step.
const _BOOT_SPEED: Dictionary = {
	"leather": 0.08, "copper": 0.16, "iron": 0.24, "gold": 0.24,
	"mithril": 0.32, "adamant": 0.40, "runite": 0.48, "dragon": 0.56,
}

# Explicit overrides for hand-named / pre-existing items. Everything here
# short-circuits the derivation in def_for — useful when a specific piece
# should NOT follow the tier formula (dragon_boots is a rare drop with a
# custom stat block, mithril_sword is a hero recipe with tuned numbers).
const DEFS: Dictionary = {
	"leather_boots": {"slot": "boots", "name": "Leather Boots",
		"def": 2, "speed": 0.08, "min_lv": 1, "req_skill": "defense"},
	"iron_boots":    {"slot": "boots", "name": "Iron Boots",
		"def": 5, "speed": 0.24, "min_lv": 15, "req_skill": "defense"},
	"mithril_boots": {"slot": "boots", "name": "Mithril Boots",
		"def": 9, "speed": 0.32, "min_lv": 30, "req_skill": "defense"},
	"dragon_boots":  {"slot": "boots", "name": "Dragon Boots",
		"def": 14, "hp": 6, "speed": 0.56, "min_lv": 85, "req_skill": "defense"},
	"gold_amulet":   {"slot": "neck",  "name": "Gold Amulet",
		"hp": 10, "acc": 2},
	"ironwood_bow":  {"slot": "weapon","name": "Ironwood Bow",
		"atk": 9, "ratk": 4, "acc": 4, "atk_spd": 0.85,
		"style": "ranged", "min_lv": 35, "req_skill": "ranged"},
	"mithril_sword": {"slot": "weapon","name": "Mithril Sword",
		"atk": 18, "str": 3, "acc": 5, "atk_spd": 1.00,
		"style": "melee", "min_lv": 30, "req_skill": "melee"},
	# ── Jewelcrafting gem jewelry (Phase 1) — opal < amethyst < diamond.
	# Wearing is ungated (no min_lv); crafting is gated by jewelcrafting
	# level in the recipe. Rings favor offense/def, amulets favor hp/acc.
	"opal_ring":       {"slot": "ring", "name": "Opal Ring",       "atk": 2, "def": 2, "hp": 4},
	"amethyst_ring":   {"slot": "ring", "name": "Amethyst Ring",   "atk": 5, "def": 5, "hp": 10},
	"diamond_ring":    {"slot": "ring", "name": "Diamond Ring",    "atk": 9, "def": 9, "hp": 18},
	"opal_amulet":     {"slot": "neck", "name": "Opal Amulet",     "hp": 8,  "acc": 2},
	"amethyst_amulet": {"slot": "neck", "name": "Amethyst Amulet", "hp": 18, "acc": 4},
	"diamond_amulet":  {"slot": "neck", "name": "Diamond Amulet",  "hp": 32, "acc": 7},
}

## ── Token upgrades (Phase 1d) ──────────────────────────────────────────────
## A gear piece upgraded at the PvP-Token NPC carries a suffix on its item id:
##   "{base}~u{level}"            for levels 1-3
##   "{base}~u4~{trait}"          for the max level (trait = the chosen bonus)
## The server is the ONLY minter of these ids (it deducts server-owned tokens
## first), so a normal client can't fabricate a boost. `~` never appears in a
## normal item id, so parsing is unambiguous. Trait ∈ hp | def | atk | ratk |
## matk. def_for strips the suffix, derives the base stats, then applies the
## cumulative percentage boost + (at L4) the flat trait bonus.
const UPGRADE_MAX_LEVEL: int = 4
## Cumulative stat multiplier by level (index = level). L1 +4%, L2 +10%,
## L3 +15%, L4 +30% — an accelerating curve with a big payoff at max.
const _UP_MULT: Array = [0.0, 0.04, 0.10, 0.15, 0.30]
## Token cost to REACH each level (single step, current+1). Reaching L4 the
## normal way therefore costs 10+20+30+100 = 160 total.
const UPGRADE_COST: Dictionary = {1: 10, 2: 20, 3: 30, 4: 100}
## Flat bonus the L4 trait pick adds to the chosen stat.
const UPGRADE_TRAIT_BONUS: Dictionary = {"hp": 30, "def": 10, "atk": 6, "ratk": 6, "matk": 6}
## Stats that scale with the percentage boost (name/slot/gate/speed are left alone).
const _UP_SCALABLE: Array = ["atk", "str", "ratk", "matk", "acc", "def", "hp"]

## Split an item id into {base, level, trait}. level 0 + "" trait if not upgraded.
static func split_upgrade(item_id: String) -> Dictionary:
	var i := item_id.find("~u")
	if i < 0:
		return {"base": item_id, "level": 0, "trait": ""}
	var base := item_id.substr(0, i)
	var rest := item_id.substr(i + 2)        # after "~u": "3" or "4~hp"
	var lvl := 0
	var trt := ""
	var t := rest.find("~")
	if t < 0:
		lvl = int(rest)
	else:
		lvl = int(rest.substr(0, t))
		trt = rest.substr(t + 1)
	return {"base": base, "level": clampi(lvl, 0, UPGRADE_MAX_LEVEL), "trait": trt}

static func base_id(item_id: String) -> String:
	var i := item_id.find("~u")
	return item_id if i < 0 else item_id.substr(0, i)

static func upgrade_level(item_id: String) -> int:
	return int(split_upgrade(item_id)["level"])

## Compose an upgraded item id. trait only encoded at UPGRADE_MAX_LEVEL.
static func make_upgraded_id(base: String, level: int, trt: String = "") -> String:
	if level <= 0:
		return base
	if level >= UPGRADE_MAX_LEVEL and trt != "":
		return "%s~u%d~%s" % [base, UPGRADE_MAX_LEVEL, trt]
	return "%s~u%d" % [base, level]

## Apply the upgrade boost onto an already-derived base stat dict (mutates+returns).
static func _apply_upgrade(d: Dictionary, level: int, trt: String) -> Dictionary:
	if d.is_empty() or level <= 0:
		return d
	var mult: float = float(_UP_MULT[clampi(level, 0, UPGRADE_MAX_LEVEL)])
	for k: String in _UP_SCALABLE:
		if d.has(k):
			d[k] = int(round(float(d[k]) * (1.0 + mult)))
	if level >= UPGRADE_MAX_LEVEL and UPGRADE_TRAIT_BONUS.has(trt):
		d[trt] = int(d.get(trt, 0)) + int(UPGRADE_TRAIT_BONUS[trt])
	d["name"] = "%s +%d" % [str(d.get("name", "")), level]
	d["upgrade_level"] = level
	if trt != "":
		d["upgrade_trait"] = trt
	return d

## Returns a stat dict for an item, or {} if it isn't equippable.
## Lookup order: 0) strip + apply any ~u upgrade suffix, 1) DEFS (hand-tuned
## overrides), 2) fishing tackle slot-stub, 3) tier/piece derivation.
static func def_for(item_id: String) -> Dictionary:
	var up := split_upgrade(item_id)
	if int(up["level"]) > 0:
		var base_def := def_for(str(up["base"]))
		if base_def.is_empty():
			return {}
		return _apply_upgrade(base_def.duplicate(true), int(up["level"]), str(up["trait"]))
	if DEFS.has(item_id):
		return DEFS[item_id]
	# Fishing tackle (bait + lures) — the slot is fixed and the "stats" the UI
	# cares about are the bonus fields on the Fishing entry itself. Return a
	# slot-stub so equip_item / target_slot / unequip just work; consumers
	# that need the bonus fields (Player.gd) call Fishing.tackle_data() to
	# read catch_bonus / rare_bonus / monster_bonus directly.
	if Fishing.is_bait(item_id) or Fishing.is_lure(item_id):
		var td: Dictionary = Fishing.tackle_data(item_id)
		return {"slot": "bait", "name": str(td.get("name", item_id)),
			"desc": Fishing.tackle_desc(item_id),
			"min_lv": int(td.get("min_fishing", 1)), "req_skill": "fishing"}
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
	# Band-derived per-slot requirement (Phase 1 rescale). Leather → 1.
	var tier_lv: int = _tier_slot_min_lv(tier, slot)
	var pretty: String = item_id.replace("_", " ").capitalize()
	var d: Dictionary = {"slot": ("ring" if slot == "ring" else slot), "name": pretty}
	if slot == "weapon":
		var wbase: int = int(_ATK_BASE.get(piece, 5))
		var scaled: int = int(round(wbase * (1.0 + ti * 0.7)))
		# Per-shape flavor — swords balanced, battleaxes hit hard/miss more,
		# maces crush with a strength kicker, bows swing fast + accurate,
		# staves swing slow-ish but add magic damage on top.
		match piece:
			"sword":
				d["atk"] = scaled
				d["acc"] = 3 + ti
				d["str"] = 1 + ti
				d["atk_spd"] = 1.00
				d["style"] = "melee"
			"battleaxe":
				d["atk"] = int(round(scaled * 1.35))
				d["acc"] = 1 + ti
				d["str"] = 2 + ti * 2
				d["atk_spd"] = 1.15
				d["style"] = "melee"
			"mace":
				d["atk"] = int(round(scaled * 1.10))
				d["acc"] = 2 + ti
				d["str"] = 4 + ti * 3   # crusher — big vs armored targets
				d["atk_spd"] = 1.00
				d["style"] = "melee"
			"bow":
				d["atk"] = int(round(scaled * 0.85))
				d["ratk"] = scaled
				d["acc"] = 4 + ti
				d["atk_spd"] = 0.85     # fastest — 15% faster than base
				d["style"] = "ranged"
			"staff":
				d["atk"] = int(round(scaled * 0.75))
				d["matk"] = scaled
				d["acc"] = 4 + ti
				d["atk_spd"] = 0.90
				d["style"] = "magic"
			"axe":
				# Woodcutting/skinning tool — not a combat weapon but the
				# recipe generator produces `{tier}_axe` for tools. Give
				# it minimal combat stats so it can be swung in a pinch.
				d["atk"] = int(round(scaled * 0.7))
				d["acc"] = 1 + ti
				d["str"] = 1 + ti
				d["atk_spd"] = 1.10
				d["style"] = "melee"
			_:
				d["atk"] = scaled
				d["acc"] = 2 + ti
				d["atk_spd"] = 1.00
				d["style"] = "melee"
		# Crit chance (%) scales with tier (Phase 4) — the attacker rolls it on
		# outgoing hits for 1.5× damage.
		d["crit"] = 2 + ti
		# Weapon level gate — by style skill (melee/ranged/magic).
		if tier_lv > 1:
			d["min_lv"] = tier_lv
			d["req_skill"] = str(d["style"])
	elif slot == "ring":
		# Jewelry — small all-around bumps, no gate.
		d["atk"] = 1 + int(ti / 2.0)
		d["def"] = 1 + int(ti / 2.0)
		d["hp"]  = 2 + ti
	elif slot == "neck":
		d["hp"]  = 5 + ti * 3
		d["acc"] = 1 + ti
	else:
		# Armor — def is the base, plus slot-specific flavor:
		# body → +hp (bulk plate is a health buffer)
		# helm → +acc (better sight lines)
		# shield → +acc + tiny +str (blocking sets up counter-swings)
		# gloves → tiny +atk (grip)
		# boots → speed by tier
		# legs → def only (mobility restricted → no other bonus)
		var abase: int = int(_DEF_BASE.get(slot, 2))
		d["def"] = int(round(abase * (1.0 + ti * 0.6)))
		# Gold trades defence for a vitality bump (its "luck/xp" flavour, simplified).
		if tier == "gold":
			d["def"] = maxi(1, int(d["def"] * 0.6))
			d["hp"]  = 6 + abase
		match slot:
			"body":
				d["hp"] = int(d.get("hp", 0)) + 4 + ti * 2
				# Plate specializes vs blades (Phase 4 split defense).
				d["def_melee"] = 1 + int(ti / 2.0)
			"head":
				d["acc"] = 1 + int(ti / 2.0)
				# Helms ward a little against spells.
				d["def_magic"] = 1 + int(ti / 2.0)
			"offhand":
				d["acc"] = 2 + int(ti / 2.0)
				d["str"] = 1 + int(ti / 2.0)
				# Shields block (chance %) + specialize vs physical attacks.
				d["block"]      = 5 + ti * 2
				d["def_melee"]  = 2 + ti
				d["def_ranged"] = 2 + ti
			"hands":
				d["atk"] = 1 + int(ti / 2.0)
			"boots":
				if _BOOT_SPEED.has(tier):
					d["speed"] = float(_BOOT_SPEED[tier])
			"legs":
				pass  # def only
		# Armor level gate — always checks Defense skill.
		if tier_lv > 1:
			d["min_lv"] = tier_lv
			d["req_skill"] = "defense"
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

## Full-set bonus registry — awarded when every listed piece is equipped
## with the matching tier prefix. Each entry: `required` piece keywords
## (matched as id suffix so a tier prefix + underscore + piece keyword
## resolves), `bonus` stat dict (all keys optional, follow the same names
## as `def_for` returns: atk, str, ratk, matk, acc, def, hp, atk_spd),
## and a `name` for the paperdoll display. Seed with mithril + runite so
## the machinery works end-to-end; future tiers are a data-only add.
## bonus keys follow def_for's stat names (atk/str/ratk/matk/acc/def/hp/atk_spd)
## plus the Phase 4 combat-depth keys: crit, block, def_melee/ranged/magic.
const SET_BONUSES: Dictionary = {
	"iron": {
		"required": ["helm", "body", "legs", "gloves", "boots", "shield"],
		"bonus":    {"hp": 8, "def": 3},
		"name":     "Iron Warplate Set",
	},
	"mithril": {
		"required": ["helm", "body", "legs", "gloves", "boots", "shield"],
		"bonus":    {"atk_spd": 0.95, "hp": 15, "block": 3},
		"name":     "Mithril Warplate Set",
	},
	"adamant": {
		"required": ["helm", "body", "legs", "gloves", "boots", "shield"],
		"bonus":    {"hp": 22, "def": 6, "def_melee": 4, "block": 4},
		"name":     "Adamant Warplate Set",
	},
	"runite": {
		"required": ["helm", "body", "legs", "gloves", "boots", "shield"],
		"bonus":    {"atk_spd": 0.90, "hp": 30, "def": 8, "block": 5, "crit": 3},
		"name":     "Runite Warplate Set",
	},
	"dragon": {
		"required": ["helm", "body", "legs", "gloves", "boots", "shield"],
		"bonus":    {"atk_spd": 0.88, "hp": 45, "def": 12, "def_melee": 6,
					 "def_ranged": 6, "def_magic": 6, "block": 7, "crit": 6},
		"name":     "Dragon Warplate Set",
	},
}

## Detect the currently-active set bonus. Returns `{"name", "bonus"}` if
## every required piece for one of the SET_BONUSES tiers is equipped as
## `<tier>_<piece>`, otherwise `{}`. Iterates equipment values once per
## tier — cheap enough to call from stat totals + paperdoll refresh.
static func equipped_set_bonus(equipment: Dictionary) -> Dictionary:
	for tier: String in SET_BONUSES.keys():
		var entry: Dictionary = SET_BONUSES[tier]
		var required: Array = entry["required"]
		var found := 0
		for piece: String in required:
			var wanted: String = "%s_%s" % [tier, piece]
			for slot: String in equipment.keys():
				if base_id(str(equipment[slot])) == wanted:
					found += 1
					break
		if found == required.size():
			return {"name": str(entry["name"]), "bonus": entry["bonus"]}
	return {}

static func stat_total(equipment: Dictionary, stat: String) -> int:
	var total := 0
	for slot: String in equipment.keys():
		var iid := str(equipment[slot])
		if iid == "":
			continue
		total += int(def_for(iid).get(stat, 0))
	# Layer any full-set bonus on top. `atk_spd` is a multiplier, not an
	# additive int — stat_speed_mult handles it separately, so we skip it
	# here even if a set declares it.
	if stat != "atk_spd":
		var sb := equipped_set_bonus(equipment)
		if not sb.is_empty():
			var b: Dictionary = sb["bonus"]
			total += int(b.get(stat, 0))
	return total

## Product of every equipped piece's `atk_spd`. Default 1.0 (no change). A
## fully bow-kitted player might see ~0.80 — 20% faster swings. Full-set
## bonuses multiply on top so a Runite Warplate set (0.90) stacks with
## an equipped bow (0.85) → 0.765× base cadence.
static func stat_speed_mult(equipment: Dictionary) -> float:
	var mult := 1.0
	for slot: String in equipment.keys():
		var iid := str(equipment[slot])
		if iid == "":
			continue
		var s: float = float(def_for(iid).get("atk_spd", 1.0))
		if s > 0.0:
			mult *= s
	var sb := equipped_set_bonus(equipment)
	if not sb.is_empty():
		var b: Dictionary = sb["bonus"]
		var set_spd: float = float(b.get("atk_spd", 1.0))
		if set_spd > 0.0:
			mult *= set_spd
	return mult
