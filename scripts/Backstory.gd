extends RefCounted
class_name Backstory

## ── Backstory catalog ───────────────────────────────────────────────────────
##
## Five small "background perks" the player picks at character creation.
## Each is a small passive bonus that nudges early progression without
## locking the player into a class — anyone can still train any skill.
##
## A backstory is stored as a single string id on the player ("viking",
## "fisher", "craftsman", "mage", "archer", or ""). On login the client
## applies the chosen backstory's modifiers via PlayerMods.add(), and
## the existing add_xp / damage-roll paths pick them up automatically.

const IDS := ["viking", "fisher", "craftsman", "mage", "archer"]

## Catalog. Each entry:
##   {
##     "id":       String       — stored value
##     "name":     String       — display name
##     "icon":     String       — single-glyph for UI
##     "flavor":   String       — character-sheet line
##     "summary":  String       — bullet list of bonuses
##     "mods":     Array[Dict]  — PlayerMods.add inputs:
##                                   {"field": "<X>_xp"|"<X>_dmg"|..., "mult": float}
##   }
const CATALOG := {
	"viking": {
		"id": "viking",
		"name": "Viking",
		"icon": "⚔",
		"flavor": "Raised in the shieldwall.",
		"summary": "+2% melee damage  ·  +5% Combat XP",
		"mods": [
			{"field": "melee_dmg", "mult": 1.02},
			{"field": "melee_xp",  "mult": 1.05},
			{"field": "defense_xp", "mult": 1.05},
		],
	},
	"fisher": {
		"id": "fisher",
		"name": "Fisher",
		"icon": "🎣",
		"flavor": "The sea taught you patience.",
		"summary": "+10% Fishing XP  ·  +5% Cooking XP",
		"mods": [
			{"field": "fishing_xp", "mult": 1.10},
			{"field": "cooking_xp", "mult": 1.05},
		],
	},
	"craftsman": {
		"id": "craftsman",
		"name": "Craftsman",
		"icon": "🔨",
		"flavor": "Your hands know the weight of tools.",
		"summary": "+10% Crafting XP  ·  +10% Construction XP",
		"mods": [
			{"field": "crafting_xp",     "mult": 1.10},
			{"field": "construction_xp", "mult": 1.10},
			{"field": "smithing_xp",     "mult": 1.05},
		],
	},
	"mage": {
		"id": "mage",
		"name": "Mage",
		"icon": "✨",
		"flavor": "You studied the hidden runes.",
		"summary": "+10% Magic XP  ·  +2% spell potency",
		"mods": [
			{"field": "magic_xp",       "mult": 1.10},
			{"field": "magic_dmg",      "mult": 1.02},
			{"field": "spell_potency",  "mult": 1.02},
		],
	},
	"archer": {
		"id": "archer",
		"name": "Archer",
		"icon": "🏹",
		"flavor": "Your eye never misses the wind.",
		"summary": "+10% Ranged XP  ·  +2% bow accuracy",
		"mods": [
			{"field": "ranged_xp",      "mult": 1.10},
			{"field": "ranged_dmg",     "mult": 1.02},
			{"field": "bow_accuracy",   "mult": 1.02},
		],
	},
}


static func ids() -> Array:
	return IDS.duplicate()


static func data(id: String) -> Dictionary:
	return CATALOG.get(id, {}) if CATALOG.has(id) else {}


## Register all of `id`'s modifiers with PlayerMods. Idempotent —
## remove_source("backstory") first so re-applying doesn't double-stack.
static func apply(id: String, mods_node: Node) -> void:
	if mods_node == null:
		return
	mods_node.remove_source("backstory")
	if id.is_empty() or not CATALOG.has(id):
		return
	for m: Variant in (CATALOG[id]["mods"] as Array):
		var md: Dictionary = m as Dictionary
		mods_node.add("backstory", str(md.get("field", "")),
			float(md.get("mult", 1.0)))


## Short display description for the character sheet / profile card.
static func flavor(id: String) -> String:
	if not CATALOG.has(id):
		return ""
	return str(CATALOG[id].get("flavor", ""))


static func summary(id: String) -> String:
	if not CATALOG.has(id):
		return ""
	return str(CATALOG[id].get("summary", ""))


static func name_of(id: String) -> String:
	if not CATALOG.has(id):
		return ""
	return str(CATALOG[id].get("name", ""))


static func icon_of(id: String) -> String:
	if not CATALOG.has(id):
		return ""
	return str(CATALOG[id].get("icon", ""))
