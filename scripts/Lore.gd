extends RefCounted

## World lore — backstory, town descriptions, Jarl bios. Static, read-only,
## preloaded by NPC dialogue and the main menu. Mirrors the geography that's
## already encoded in Ground.gd; do not invent new towns or rename existing
## ones from here. Adding lore = adding fields, not changing names.

## ── World backstory ─────────────────────────────────────────────────────────
const BACKSTORY: String = """The Allfather's peace ruled Vinland for a thousand winters.

Then Jörmungandr stirred in the Serpent Sea to the west, and Níðhöggr woke beneath Helheim to gnaw the roots of the World Tree. The Old Kings fell. The great longhouses burned. The free roads grew silent.

Five settlements survived the Burning:

— Bjorn's Landing, on the eastern coast, last harbor of the free fishers.
— Kjelvik, the old capital, half its walls fallen, still ruled by Elder Bjarne who remembers the King.
— Frostheim, in the northern snows, where Hunter Ragnhild's wardens keep the goblin hordes from boiling out of the ice.
— Ironwood Keep, in the central dark forest, raised around the last living Ironwood Tree — source of the only steel that can still cut draugr-flesh.
— Eastmark Post, a scouting outpost on the rim of the Ashlands, watching what crawls from the fire.

The five towns barely speak. Each Jarl keeps their own peace. The roads between them are walked only by travelers, traders, and those mad enough to seek the High Banner.

You wash ashore at Bjorn's Landing with no name and no memory of the Burning. The Jarls have no use for you yet — but their problems are larger than their thanes. You will fish, you will hunt, you will smith and forage and gather. And somewhere between the herb-patches and the rat-cellars, you will learn that the world is still bleeding, and somebody must answer for it."""


## ── Per-town descriptions ─────────────────────────────────────────────────
## Keyed by lowercase town id. Each entry: { name, region, jarl, jarl_bio,
## description }. The NPC dialogue's "About this town" button pulls from
## here using the town the giver_npc lives in.
const TOWNS: Dictionary = {
	"bjorn": {
		"name":        "Bjorn's Landing",
		"region":      "Southeast coast",
		"jarl":        "Sea Captain Valdis",
		"jarl_bio":    "Valdis ran salt-runs to the western isles before the Burning. She holds Bjorn's by reputation and by the half-dozen ships she still keeps seaworthy. Says little, watches the horizon.",
		"description": "The last free harbor. Most of the docks survived the fires because the wind ran the wrong way that night. Fishermen, shipwrights, and salt-cured exiles. The Sea Token is said to lie at a hidden shrine somewhere along the eastern cliffs — known only to those who have sailed long enough to be trusted with it.",
	},
	"kjelvik": {
		"name":        "Kjelvik",
		"region":      "Central-west plains",
		"jarl":        "Elder Bjarne",
		"jarl_bio":    "Bjarne served the last Old King as treasurer and lived to see the longhouse burn. He rules from the cracked stone seat in the Great Hall. He is older than the seat is — and the seat is very old.",
		"description": "Once the capital. Half the walls are still rubble; the other half are patched with whatever the masons can salvage from the old buildings. The cellars are deep, and rats now claim what the kings once stored. The Iron Token rests in Bjarne's keeping — but he will not part with it for less than proof you are who the throne needs you to be.",
	},
	"frostheim": {
		"name":        "Frostheim",
		"region":      "Northern snows",
		"jarl":        "Hunter Ragnhild",
		"jarl_bio":    "Ragnhild is not a Jarl by election but by the fact that nobody else in Frostheim has stayed alive as long. She wears no crown. She has put down two would-be warlords and three goblin chieftains since the Burning.",
		"description": "A garrison town built into the lee of the mountain. The wind comes off the glaciers and the goblins come down from the high passes — Ragnhild's wardens hold both back. The Frost Token rides on the chest of the Ice Draugr Captain at the glacier shrine, and Ragnhild has lost three wardens trying to take it.",
	},
	"ironwood": {
		"name":        "Ironwood Keep",
		"region":      "Central dark forest",
		"jarl":        "Blacksmith Ulfr",
		"jarl_bio":    "Ulfr was a master-smith of the Old Kings and the only one to walk out of the Ashlands alive when the Burning came east. He rules a town of smiths and timber-cutters and refuses to be called a Jarl. The title finds him anyway.",
		"description": "The keep was built around the last living Ironwood Tree. Ironwood steel is the only metal that still cuts draugr-flesh cleanly, which makes Ulfr's forge the most strategic patch of ground left in Vinland. The Heart Token lies further west, in the central plains, where the hermit Skade keeps a hermitage that nobody is supposed to be able to find.",
	},
	"eastmark": {
		"name":        "Eastmark Post",
		"region":      "Frontier — Ashlands rim",
		"jarl":        "Scout Halfdan",
		"jarl_bio":    "Halfdan was a junior scout when the Burning broke; he has been senior scout, only scout, and acting commander in rotation ever since. He walks the perimeter twice a day, every day. He has not slept a full night in two years.",
		"description": "A wood-and-stone palisade at the very edge of where the Ashlands cooled enough to walk on. The garrison knows it is too far from the other towns to be saved if the Ashlands wake up again, and they live accordingly. The Fifth Token waits on the shore of Helheim itself — and only Captain Sten knows what kills you on the way there.",
	},
}


## Returns the full backstory text for the main menu / lore reader.
static func backstory() -> String:
	return BACKSTORY

## Returns a town entry, or {} if unknown. Town ids are lowercase short
## names: "bjorn", "kjelvik", "frostheim", "ironwood", "eastmark".
static func town(town_id: String) -> Dictionary:
	return TOWNS.get(town_id.to_lower(), {})

## Reverse lookup: which town does this NPC live in? Used by the NPC
## dialogue's "About this town" button so each NPC pulls the right entry.
## Returns town_id or "" if the NPC isn't a known Jarl.
static func town_of_npc(npc_name: String) -> String:
	for tid: String in TOWNS.keys():
		if str(TOWNS[tid].get("jarl", "")) == npc_name:
			return tid
	# Fallbacks for the known quest-giver NPCs that live in each town.
	match npc_name:
		"Sigrid the Fishmonger", "Merchant Eydis":              return "bjorn"
		"Trader Hroar", "Old Brynjar":                          return "kjelvik"
		"Brynhildr the Apothecary", "Gunnar Coldhand":          return "frostheim"
		"Torsten the Wanderer", "Runa the Herbalist":           return "ironwood"
		"Captain Sten":                                          return "eastmark"
	return ""
