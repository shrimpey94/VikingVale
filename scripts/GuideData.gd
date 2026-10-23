extends RefCounted

## Player-facing how-to guides shown in the Guides overlay (Settings → Guides).
## Pure DATA — add or edit entries freely; the overlay lists every one. Each:
##   {id, icon, title, body}   (body: plain text, "\n" for line breaks, "• " bullets)
## Keep the wording in step with the actual mechanics as systems change.

const GUIDES: Array = [
	{
		"id": "start", "icon": "⭐", "title": "Getting Started",
		"body": "Welcome to VikingVale — a Norse survival MMO.\n\n"
			+ "• Click the ground to move. Click a resource (tree, rock, fishing spot, herb) to gather it, or a monster to fight it.\n"
			+ "• Gather Sticks and Stones first, then open Crafting (💎) to make your starter tools.\n"
			+ "• Skills level by doing them: Woodcutting, Mining, Fishing, Foraging, Combat, Crafting, Smithing, Cooking, Construction and Magic.\n"
			+ "• Visit the five towns — Bjorn's Landing, Kjelvik, Frostheim, Ironwood and Eastmark — to trade, bank, train and take quests.\n"
			+ "• You can replay the intro tutorial and reopen these Guides anytime from Settings.",
	},
	{
		"id": "combat", "icon": "⚔", "title": "Combat & PvP",
		"body": "There are three combat styles — swap them in the combat panel.\n\n"
			+ "• Melee (⚔) strikes up close with your weapon.\n"
			+ "• Ranged (🏹) fires arrows from a distance.\n"
			+ "• Magic (🔮) casts the runes you inscribe (see the Runes guide).\n\n"
			+ "• Criticals deal bonus damage, shields can BLOCK and halve a hit, and Defence is split into melee/ranged/magic — gear for the fight you expect.\n"
			+ "• PvP is TOGGLE-ONLY: you can only fight players who are flagged, and attacking someone flags you. Watch what you're carrying — you drop loot on death.\n"
			+ "• The Kjelvik castle is the single no-PvP safe zone. Attack townsfolk there and the city watch answers in escalating waves.",
	},
	{
		"id": "thralls", "icon": "⛓", "title": "How to Use Thralls",
		"body": "Thralls are captured workers who gather and fight for you while you're logged out.\n\n"
			+ "• GET one: thralls have a small chance (4%) to drop from monster kills when you have a free roster slot. Buy more slots in the Thralls tab.\n"
			+ "• ASSIGN: open the Thralls tab, pick a thrall, choose a job (Woodcutting / Mining / Fishing / Foraging / Combat), a target resource, and the TOWN to send it to.\n"
			+ "• GATING: a thrall can only do tasks up to its TIER, and each town only offers certain resources at certain tiers — high-tier resources need a high-tier thrall in the right town (e.g. Frostheim has no fishing). The town picker only lists towns that fit.\n"
			+ "• SEE THEM WORK: an assigned thrall stands near its town and actively walks to nearby resources, gathers, then moves to the next.\n"
			+ "• OFFLINE: thralls work up to a 12-hour shift while you're away, then rest. On login you get a report — their haul is banked in the thrall's backpack and you gain the skill XP.\n"
			+ "• COMBAT thralls: put FOOD in their backpack — they auto-eat to heal, and can PERMANENTLY DIE if they run out mid-fight.\n"
			+ "• Re-set your thralls each session to send them back out.",
	},
	{
		"id": "boat", "icon": "⛵", "title": "How to Build a Boat",
		"body": "Boats carry you across deep water to fish the open sea and battle sea monsters.\n\n"
			+ "• BUILD one at a Construction bench: open Construction (🔨) and craft a boat. Boats need logs and bars, and sturdier hulls want a higher Construction level.\n"
			+ "• LAUNCH from the water's edge to set sail.\n"
			+ "• At sea you can DEEP-SEA FISH for bigger, rarer catches — but sea monsters will attack. Win the boat-combat encounter to survive and keep sailing.\n"
			+ "• Level Construction to unlock better, tougher boats.",
	},
	{
		"id": "warband", "icon": "🛡", "title": "How to Create a Warband",
		"body": "A warband is your clan — for shared banking, territory and war.\n\n"
			+ "• OPEN the Warband tab (Social). Create a new warband and name it to become its leader, or accept an invite to join one.\n"
			+ "• Members share a tiled CLAN BANK (a gold pool plus item tabs with per-member withdraw permissions) and appear on the live rankings.\n"
			+ "• LEADERS can invite and kick members, set bank permissions, hire trade caravans, pledge the warband to a town, and build warband structures.\n"
			+ "• Form ONE alliance with another warband using /ally.\n"
			+ "• Together, claim land and raise a settlement — see the Warband Settlement guide.",
	},
	{
		"id": "settlement", "icon": "🏰", "title": "Build & Upgrade a Warband Settlement",
		"body": "Warband structures let your clan claim and hold territory. Build them from the Construction (🔨) menu; they're placed at your feet on free or claimed land.\n\n"
			+ "• BANNER — Construction 25 (15 Oak Logs + 5 Iron Bars). Planting a banner CLAIMS the land around it for your warband. This is the heart of a settlement. Up to 12 per warband.\n"
			+ "• OUTPOST — Construction 20 (20 Pine Logs + 3 Iron Bars). A forward structure inside your claim; up to 3 per banner.\n"
			+ "• STRONGHOLD — Construction 50 (40 Ironwood Logs + 20 Mithril Bars + 15 Frost Logs). Your warband's keep. One per warband.\n\n"
			+ "• UPGRADE PATH: start with an Outpost/Banner, then raise Construction and gather the higher-tier mats (ironwood, mithril, frost) to build the Stronghold.\n"
			+ "• Rivals can RAID your structures — repair them with gold from the clan pool.",
	},
	{
		"id": "runes", "icon": "🔮", "title": "How to Create Magic Runes",
		"body": "Runes are the ammo for the Magic combat style — you inscribe them yourself.\n\n"
			+ "• FIND a Runestone (a purple magic node) out in the world and right-click it → INSCRIBE to open the rune-smithing menu.\n"
			+ "• Each recipe consumes magic ESSENCE (and rune dust at higher tiers) and produces a stack of runes. Higher-tier runes need a higher Magic level — recipes climb in 10-level steps.\n"
			+ "• Equip the MAGIC style, then pick a rune in the rune row to cast with it. Better runes hit harder and reach further.\n"
			+ "• You spend runes as you cast, so inscribe a good stock before a big fight.",
	},
	{
		"id": "reputation", "icon": "📜", "title": "Reputation & Towns",
		"body": "Every town tracks your standing, from Hated up to Exalted.\n\n"
			+ "• RAISE it with town quests and good deeds.\n"
			+ "• LOSE it by attacking townsfolk, smashing town walls, or raiding a town's trade caravan (the loss lands on the town the caravan just left).\n"
			+ "• The Kjelvik city watch answers attacks in escalating waves.\n"
			+ "• Warbands have their OWN town standing too, shown alongside yours in the Reputation tab.",
	},
	{
		"id": "travel", "icon": "🗺", "title": "Fast Travel",
		"body": "Fast travel hops you between places you've already found.\n\n"
			+ "• First DISCOVER a destination by visiting it on foot.\n"
			+ "• After that you can pay a gold fee (roughly 50–300g by distance) to travel there instantly from the travel menu.",
	},
	{
		"id": "fishing", "icon": "🎣", "title": "Fishing & Cooking",
		"body": "Fishing feeds Cooking, and cooked food is your main healing in a fight.\n\n"
			+ "• Click a fishing spot with a fishing pole equipped. Higher Fishing level unlocks salmon, lobster and shark.\n"
			+ "• Take a BOAT out for deep-sea fishing — bigger catches, at the risk of sea monsters.\n"
			+ "• COOK your catch (and other ingredients) to make food that heals you — and your combat thralls.",
	},
]

## Per-topic INTERACTIVE tutorials — a stepped walkthrough for each guide, keyed by
## its `id`. Pressing "▶ Start Tutorial" on a guide page runs these one step at a
## time (Next ▶ to advance, ✕ Stop to quit early). Keep steps short + imperative;
## the "start" topic instead runs the hands-on gather→craft first-run tutorial.
## Add/edit freely — a topic with no entry just hides its Start Tutorial button.
const TUTORIALS: Dictionary = {
	"combat": [
		"Open the Combat panel (beside the minimap) to see your three styles: Melee, Ranged and Magic.",
		"Pick a style that matches your gear — Melee needs a weapon, Ranged a bow + arrows, Magic runes.",
		"Right-click a monster and choose Attack (or left-click it) to walk up and start fighting.",
		"Watch your HP bar — eat cooked food to heal. Retreat if you drop low; you drop loot if you die.",
		"PvP is opt-in: you can only fight flagged players, and attacking one flags YOU. The Kjelvik castle is a no-PvP safe zone.",
	],
	"thralls": [
		"Open the Thralls tab. Thralls are workers who gather and fight for you while you're offline.",
		"You get thralls as a rare (4%) drop from monster kills when you have a free roster slot — buy more slots in this tab.",
		"Select a thrall, choose a job (Woodcutting / Mining / Fishing / Foraging / Combat) and a target resource.",
		"Pick the TOWN to send it to — only towns that offer that resource at the thrall's tier will show.",
		"For Combat thralls, put FOOD in their backpack so they heal — they can permanently die without it.",
		"Assign and log out: thralls work up to a 12-hour shift, then bank their haul. Re-assign each session.",
	],
	"boat": [
		"Open Construction. Boats are built at a Construction bench and need logs + bars.",
		"Craft a boat you have the Construction level for — sturdier hulls need a higher level.",
		"Walk to the water's edge and launch to set sail across deep water.",
		"At sea, click a deep-sea fishing spot for bigger, rarer catches — but sea monsters will attack.",
		"Win the boat-combat encounter to keep sailing. Level Construction for tougher boats.",
	],
	"warband": [
		"Open the Social - Warband tab. A warband is your clan for shared banking, territory and war.",
		"Create a warband and name it to become its leader — or accept an invite to join one.",
		"Use the shared CLAN BANK: a gold pool plus item tabs with per-member withdraw permissions.",
		"As a leader you can invite/kick, set bank permissions, hire caravans, pledge to a town and build structures.",
		"Form ONE alliance with /ally, then raise a settlement — see the Warband Settlement guide.",
	],
	"settlement": [
		"Warband structures claim and hold territory. Open Construction to build them at your feet.",
		"Start with a BANNER (Construction 25: 15 Oak Logs + 5 Iron Bars) — it claims the land around it.",
		"Add OUTPOSTS (Construction 20) inside your claim — up to 3 per banner.",
		"Raise Construction to 50 and gather ironwood, mithril and frost mats to build your STRONGHOLD (one per warband).",
		"Rivals can raid your structures — repair them with gold from the clan pool.",
	],
	"runes": [
		"Runes are the ammo for the Magic style — you inscribe them yourself.",
		"Find a Runestone (a purple magic node) out in the world.",
		"Right-click the Runestone and choose Inscribe to open the rune-smithing menu.",
		"Each recipe spends magic essence (and rune dust at higher tiers); higher runes need a higher Magic level.",
		"Equip the Magic style, pick a rune in the rune row, and cast. Inscribe a good stock before a big fight.",
	],
	"reputation": [
		"Open the Reputation tab. Every town tracks your standing from Hated up to Exalted.",
		"RAISE it with town quests and good deeds.",
		"LOSE it by attacking townsfolk, smashing town walls, or raiding a town's trade caravan.",
		"Attack Kjelvik and the city watch answers in escalating waves.",
		"Your warband has its own town standing too, shown alongside yours here.",
	],
	"travel": [
		"Fast travel hops you between places you've already found.",
		"First DISCOVER a destination by visiting it on foot — this unlocks it permanently.",
		"Open the travel/map menu to see your discovered destinations.",
		"Pay the gold fee (roughly 50-300g by distance) to travel there instantly.",
	],
	"fishing": [
		"Equip a fishing pole, then click a fishing spot to start fishing.",
		"Level Fishing to unlock salmon, lobster and shark.",
		"Take a boat out for deep-sea fishing — bigger catches, at the risk of sea monsters.",
		"Open Cooking to turn your catch into food.",
		"Cooked food heals you in a fight — and feeds your combat thralls.",
	],
}
