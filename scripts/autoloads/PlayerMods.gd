extends Node

## ── PlayerMods ──────────────────────────────────────────────────────────────
##
## Central registry of stat / XP multipliers that buffs from various sources
## stack into. Backstory perks register a fixed set at login. Pet auras
## register/unregister on summon/dismiss. Future buffs (potions, equipment
## procs, ritual effects) plug in the same way.
##
## A "modifier" is a small dict:
##   { "source": String,   # who put this here — "backstory", "pet", "potion"
##     "field":  String,   # what's modified — see FIELDS below
##     "mult":   float }   # multiplicative factor; 1.05 = +5%
##
## Get_mult("melee_dmg") composes all matching modifiers as a product. So
## +2% from backstory and +1% from a pet stack to 1.02 * 1.01 = 1.0302.
##
## Call sites (read-only):
##   * GameManager.add_xp (XP grants)            — `<skill>_xp`
##   * HUD._launch_player_attack (damage rolls)  — `melee_dmg`, `ranged_dmg`, `magic_dmg`
##   * Ranged hit check                          — `bow_accuracy`
##   * Magic spell potency                       — `spell_potency`
##   * GameManager defense / dodge               — `dodge`
##   * Vitality regen                            — `stamina_regen`
##
## Adding a new field: just start using it. The hook is permissive — an
## unknown field returns 1.0 (no-op) so call-site code is safe regardless
## of whether any source has registered for it.

# Catalog of well-known fields. Not enforced — just documents the contract.
const FIELDS := [
	"melee_dmg", "ranged_dmg", "magic_dmg",
	"melee_xp", "ranged_xp", "magic_xp",
	"fishing_xp", "cooking_xp", "crafting_xp", "construction_xp",
	"woodcutting_xp", "mining_xp", "smithing_xp",
	"farming_xp", "vitality_xp", "defense_xp",
	"bow_accuracy", "spell_potency", "dodge", "stamina_regen",
]

# All currently-active modifiers, regardless of source. Iterated on read.
# Could be split per-source if mod counts grow, but at v1 scale (≤20 mods)
# linear scan is fine.
var _mods: Array[Dictionary] = []


# ── Public API ──────────────────────────────────────────────────────────────

## Add a modifier. Returns a token (the modifier dict) the caller stores so
## it can remove() the same one later. Multiple calls with the same source
## accumulate — each adds an entry.
func add(source: String, field: String, mult: float) -> Dictionary:
	var m := {"source": source, "field": field, "mult": mult}
	_mods.append(m)
	return m

## Remove ONE specific modifier previously returned by add(). Idempotent —
## removing the same token twice is harmless.
func remove(m: Dictionary) -> void:
	_mods.erase(m)

## Remove ALL modifiers from `source`. Convenient for "the pet was
## dismissed, drop all its auras" cleanup.
func remove_source(source: String) -> void:
	_mods = _mods.filter(func(m: Dictionary) -> bool:
		return str(m.get("source", "")) != source)

## Composed multiplier for `field`. Returns 1.0 when nothing matches —
## call-site code can multiply unconditionally without checking.
func get_mult(field: String) -> float:
	var result: float = 1.0
	for m: Dictionary in _mods:
		if str(m.get("field", "")) == field:
			result *= float(m.get("mult", 1.0))
	return result

## All modifiers for `field`. Used by UI tooltips that want to attribute
## the bonus to its source ("+5% Combat XP from Viking backstory").
func list_for(field: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m: Dictionary in _mods:
		if str(m.get("field", "")) == field:
			out.append(m)
	return out

## Clear everything. Called on logout so a fresh login doesn't carry old
## modifiers across accounts.
func clear_all() -> void:
	_mods.clear()


# ── Convenience integrations ────────────────────────────────────────────────

## XP-grant multiplier helper. Skill name uses the standard skill ids
## ("melee", "fishing", etc.). Returns 1.0 for unknown skills so the
## existing GameManager.add_xp loop stays safe.
func xp_mult(skill: String) -> float:
	return get_mult("%s_xp" % skill)

## Damage multiplier helper. Style is "melee" / "ranged" / "magic".
func dmg_mult(style: String) -> float:
	return get_mult("%s_dmg" % style)
