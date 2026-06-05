extends RefCounted

## Per-rune spell table — each rune type IS its own spell. Player toggles the
## active rune in the HUD; casting consumes 1 of that rune, deals damage scaled
## by Magic level + rune tier, grants magic XP per hit. `req_lv` matches the
## rune-smithing recipe levels in HUD.gd._RUNE_RECIPES so a rune the player
## CAN craft is also a rune they CAN cast.
##
## Damage formula: `base_dmg + int(magic_lv * per_mlv)` — air is fast and weak
## (effective ~5 at lv 10, ~32 at lv 99), blood is slow and brutal (~28 at
## lv 50, ~97 at lv 99). XP per hit scales similarly so high-tier casters
## level magic faster than low-tier spam.
const SPELLS: Dictionary = {
	"air_rune": {
		"name": "Air Bolt",    "req_lv": 1,
		"base_dmg": 2,  "per_mlv": 0.30, "xp": 4,
		"color": Color(0.92, 0.94, 0.98),
	},
	"mind_rune": {
		"name": "Mind Spike",  "req_lv": 5,
		"base_dmg": 3,  "per_mlv": 0.35, "xp": 6,
		"color": Color(0.72, 0.74, 0.82),
	},
	"water_rune": {
		"name": "Water Surge", "req_lv": 10,
		"base_dmg": 4,  "per_mlv": 0.40, "xp": 9,
		"color": Color(0.30, 0.55, 0.95),
	},
	"earth_rune": {
		"name": "Earth Crush", "req_lv": 15,
		"base_dmg": 5,  "per_mlv": 0.42, "xp": 12,
		"color": Color(0.55, 0.42, 0.20),
	},
	"fire_rune": {
		"name": "Fire Bolt",   "req_lv": 20,
		"base_dmg": 6,  "per_mlv": 0.48, "xp": 16,
		"color": Color(0.95, 0.42, 0.18),
	},
	"ice_rune": {
		"name": "Ice Lance",   "req_lv": 22,
		"base_dmg": 7,  "per_mlv": 0.50, "xp": 18,
		"color": Color(0.60, 0.85, 0.95),
	},
	"body_rune": {
		"name": "Body Bind",   "req_lv": 25,
		"base_dmg": 8,  "per_mlv": 0.52, "xp": 22,
		"color": Color(0.55, 0.88, 0.55),
	},
	"cosmic_rune": {
		"name": "Cosmic Ray",  "req_lv": 35,
		"base_dmg": 10, "per_mlv": 0.58, "xp": 28,
		"color": Color(0.78, 0.62, 1.00),
	},
	"chaos_rune": {
		"name": "Chaos Strike","req_lv": 45,
		"base_dmg": 12, "per_mlv": 0.62, "xp": 36,
		"color": Color(0.98, 0.62, 0.20),
	},
	"nature_rune": {
		"name": "Nature Lash", "req_lv": 55,
		"base_dmg": 13, "per_mlv": 0.68, "xp": 46,
		"color": Color(0.42, 0.78, 0.18),
	},
	"law_rune": {
		"name": "Law Smite",   "req_lv": 65,
		"base_dmg": 15, "per_mlv": 0.72, "xp": 58,
		"color": Color(0.92, 0.78, 0.18),
	},
	"death_rune": {
		"name": "Death Burst", "req_lv": 75,
		"base_dmg": 16, "per_mlv": 0.76, "xp": 70,
		"color": Color(0.45, 0.40, 0.55),
	},
	"blood_rune": {
		"name": "Blood Lash",  "req_lv": 85,
		"base_dmg": 18, "per_mlv": 0.80, "xp": 84,
		"color": Color(0.92, 0.18, 0.22),
	},
}

## Returns the spell data dict for the rune, or {} if not a known rune.
static func data(rune_id: String) -> Dictionary:
	if rune_id == "" or not SPELLS.has(rune_id):
		return {}
	return SPELLS[rune_id]

## Final cast damage = base + int(magic_lv * per_mlv). Returns 0 for unknown
## runes so the caller can detect "no spell selected" without crashing.
static func damage_for(rune_id: String, magic_lv: int) -> int:
	var d := data(rune_id)
	if d.is_empty():
		return 0
	var base: int = int(d.get("base_dmg", 0))
	var per: float = float(d.get("per_mlv", 0.0))
	return base + int(float(magic_lv) * per)

static func xp_per_hit(rune_id: String) -> int:
	var d := data(rune_id)
	return int(d.get("xp", 0)) if not d.is_empty() else 0

static func color_for(rune_id: String) -> Color:
	var d := data(rune_id)
	if d.is_empty():
		return Color(0.55, 0.45, 0.95)   # default purple from the old magic projectile
	return d.get("color", Color(0.55, 0.45, 0.95))

static func name_for(rune_id: String) -> String:
	var d := data(rune_id)
	return str(d.get("name", "")) if not d.is_empty() else ""

static func req_lv(rune_id: String) -> int:
	var d := data(rune_id)
	return int(d.get("req_lv", 1)) if not d.is_empty() else 99

## Returns every rune_id the player meets the magic-level for. Used by the
## HUD rune sub-row to filter the icon set down to "what I can cast right
## now." Admins (GameManager.is_admin) get the full list regardless of level.
static func usable_runes_for(player_lv: int, admin: bool = false) -> Array:
	var out: Array = []
	# Iterate in declared dict order so the row reads air → blood, low → high.
	for rune_id in SPELLS.keys():
		var rlv := int((SPELLS[rune_id] as Dictionary).get("req_lv", 99))
		if admin or player_lv >= rlv:
			out.append(rune_id)
	return out
