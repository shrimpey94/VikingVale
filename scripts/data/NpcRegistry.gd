extends RefCounted

## ONE source of truth for named NPCs, shared by the client AND the server.
##   town — gameplay town ("kjelvik" | "frostheim" | "ironwood" | "eastmark" |
##          "bjorn" | ""). Drives quest reputation, the shop pledge-tax skim, the
##          "murdered townsfolk" penalty and the quest dialog's "About <town>"
##          page. "" = no town effects (most workers/bankers/trainers).
##   seed — row index in World._NPCS (the NPC's id is "n:<seed>"); omitted for
##          admin-placed NPCs. World._NPCS is append-only, so indices never move.
##   shop — ShopCatalog id a SEEDED shopkeeper trades from (admin-placed NPCs
##          carry their shop_id in their own entity data instead).
## Quest giver / talk-target names in QuestData + server _QUESTS_PY must exist
## here; the server warns at startup and the admin NPC roster flags any that don't.
##
## ⚠ server/server.py parses the block between the two marker lines as JSON —
## keep it strict JSON: double quotes, no trailing commas, no comments inside.

# BEGIN_NPC_REGISTRY_JSON
const NPCS: Dictionary = {
	"Elder Bjarne":              {"town": "kjelvik",   "seed": 0},
	"Castellan Halvdan":         {"town": "kjelvik",   "seed": 1},
	"Quartermaster Ase":         {"town": "kjelvik",   "seed": 2,  "shop": "kjelvik_garrison"},
	"Shieldmaster Ulf":          {"town": "",          "seed": 3},
	"Karl":                      {"town": "",          "seed": 4},
	"Sigrid":                    {"town": "",          "seed": 5},
	"Trader Hroar":              {"town": "kjelvik",   "seed": 6,  "shop": "kjelvik_provisions"},
	"Gunhild the Treasurer":     {"town": "",          "seed": 7},
	"Valgerd the Craftswoman":   {"town": "",          "seed": 8},
	"Eirik Ironarm":             {"town": "",          "seed": 9},
	"Torsten the Wanderer":      {"town": "ironwood",  "seed": 10},
	"Merchant Dalla":            {"town": "kjelvik",   "seed": 11, "shop": "kjelvik_curios"},
	"Hakon the Farmer":          {"town": "",          "seed": 12},
	"Hunter Ragnhild":           {"town": "frostheim", "seed": 13},
	"Leif":                      {"town": "",          "seed": 14},
	"Astrid":                    {"town": "",          "seed": 15},
	"Sigvard the Frost Keeper":  {"town": "",          "seed": 16},
	"Merchant Bera":             {"town": "frostheim", "seed": 17, "shop": "frostheim_furs"},
	"Gunnar Coldhand":           {"town": "frostheim", "seed": 18},
	"Blacksmith Ulfr":           {"town": "ironwood",  "seed": 19},
	"Gorm":                      {"town": "",          "seed": 20},
	"Brynja":                    {"town": "",          "seed": 21},
	"Armgard the Treasurer":     {"town": "",          "seed": 22},
	"Trader Thorvald":           {"town": "ironwood",  "seed": 23, "shop": "ironwood_outfitter"},
	"Runa the Herbalist":        {"town": "ironwood",  "seed": 24},
	"Scout Halfdan":             {"town": "eastmark",  "seed": 25},
	"Vigdis":                    {"town": "",          "seed": 26},
	"Olaf":                      {"town": "",          "seed": 27},
	"Outpost Treasurer Hrodgar": {"town": "",          "seed": 28},
	"Wandering Merchant Freyja": {"town": "eastmark",  "seed": 29, "shop": "eastmark_wagon"},
	"Merchant Eydis":            {"town": "bjorn",     "seed": 30},
	"Sturla":                    {"town": "",          "seed": 31},
	"Hallgerd":                  {"town": "",          "seed": 32},
	"Harbor Master Ingolf":      {"town": "",          "seed": 33},
	"Fish Trader Knud":          {"town": "bjorn",     "seed": 34, "shop": "bjorn_catch"},
	"Sea Captain Valdis":        {"town": "bjorn",     "seed": 35},
	"Mountain Pass Guard Bjork": {"town": "",          "seed": 36},
	"Ironwood Hermit Skade":     {"town": "ironwood",  "seed": 37},
	"Coastal Scout Hafi":        {"town": "",          "seed": 38},
	"Captain Sten":              {"town": "eastmark",  "seed": 39},
	"Old Brynjar":               {"town": "kjelvik",   "seed": 40},
	"Brynhildr the Apothecary":  {"town": "frostheim", "seed": 41, "shop": "apothecary"},
	"Oddny the Ledger-Keeper":   {"town": "kjelvik",   "seed": 42},
	"Tree-Warden Eyvind":        {"town": "ironwood",  "seed": 43},
	"Sigrid the Fishmonger":     {"town": "bjorn"}
}
# END_NPC_REGISTRY_JSON

## Gameplay town id for an NPC name, or "".
static func town_of(npc_name: String) -> String:
	return str((NPCS.get(npc_name, {}) as Dictionary).get("town", ""))

## ShopCatalog id for a seeded shopkeeper, or "".
static func shop_of(npc_name: String) -> String:
	return str((NPCS.get(npc_name, {}) as Dictionary).get("shop", ""))

static func has(npc_name: String) -> bool:
	return NPCS.has(npc_name)
