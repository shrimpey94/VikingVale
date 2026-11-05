extends RefCounted
class_name Changelog

## Player-facing version history for the login-screen changelog panel.
##
## The AUTHORITATIVE current version is still version.txt (read at runtime by
## LoginScreen._read_version) — this is just the human-readable notes. Newest
## entry goes FIRST. Keep `version` as the bare "1.5.3" (no "v"); the panel adds
## the prefix. When you cut a release, add an entry here and bump version.txt.

const ENTRIES: Array = [
	{
		"version": "1.7.1",
		"date": "2026-11",
		"title": "Fresh Timber",
		"notes": [
			"The first new 3D-modelled art is here! Oak trees, timber houses and the loose stones you pick up off the ground have been rebuilt as real modelled art, in both 2D and 3D view. Oaks still show the damage as you chop them, right down to the stump. More of the world will get the same treatment over the coming updates.",
			"New server connection — the game now connects through a faster, secure (encrypted) route at play.busterrdust.com. Nothing to do on your end: it's automatic, and if that route is ever down the game quietly falls back to the old one.",
			"If you'd typed in the old server address yourself, you're moved onto the new one automatically.",
		],
	},
	{
		"version": "1.7.0",
		"date": "2026-09",
		"title": "Fair Play — A Fresh Season",
		"notes": [
			"FRESH SEASON — everyone starts clean. As part of a major security update, all accounts have been reset to a new-character slate: levels, items, gold, and bank. Everyone's back on a level playing field from day one.",
			"The whole world now runs on the server. Your gold, items, and skill XP are handled and checked server-side, so cheated gold, injected items, and hand-edited levels no longer stick — anything you didn't actually earn is stripped when the game saves. A fair economy and honest leaderboards for everyone.",
			"Monster loot now drops straight into the backpack of whoever dealt the most damage — no more racing rivals to a pile on the ground, and no more kill-stealing the loot with a last-second hit.",
			"Trading with another player? Use the Trade window. Items you drop on the ground are only recoverable by you now.",
			"Most of this update is behind-the-scenes anti-cheat work across combat, gathering, crafting, fishing, and farming — you shouldn't notice it at all unless you were trying to cheat.",
		],
	},
	{
		"version": "1.6.8",
		"date": "2026-08",
		"title": "Stay Logged In",
		"notes": [
			"Auto-login — sign in once and the game logs you straight back in every launch after that. Switch it off (or switch accounts) any time under Settings › Log Out, and there's an Auto-login toggle in Settings to turn it off for good.",
			"Quest markers now sit UNDER your interface — the ! and + on your objectives no longer cover the minimap or your open panels.",
		],
	},
	{
		"version": "1.6.6",
		"date": "2026-08",
		"title": "Train Like a Warrior",
		"notes": [
			"The Archery Range is now a real mini-game — line up the sweeping crosshair and loose a 5-shot volley. Nail the bullseye and you earn far more XP than the old flat training; graze the edge and you earn little. Bring a bow and arrows (one arrow per shot).",
			"Runestones work the same way for Magic — channel a volley with a staff and rune essence, and your accuracy sets the XP.",
			"NEW sparring dummies in every town — train Melee with the same aim-and-strike mini-game (just bring a melee weapon).",
		],
	},
	{
		"version": "1.6.5",
		"date": "2026-08",
		"title": "Monsters Mind the Walls",
		"notes": [
			"Monsters no longer stroll through town and warband walls — they're blocked by walls, cliffs and water like everyone else, and a mob cornered against a wall will hammer on it instead of phasing through. Your defences actually defend now.",
			"When you gather, you swing the right tool for the job: an axe on trees, a pickaxe on ore, and bare hands for herbs, sticks and stones — and it's the best axe/pickaxe you're carrying, so a runite hatchet looks the part.",
			"Right-click a shopkeeper for a quick Trade option — no need to talk through them first.",
			"Restored two daily-bounty givers who'd gone missing — Old Brynjar in Kjelvik and Brynhildr the Apothecary in Frostheim — so their dailies can be picked up again.",
		],
	},
	{
		"version": "1.6.4",
		"date": "2026-08",
		"title": "The Watch Has Your Back",
		"notes": [
			"Town guards now defend YOU. If a monster attacks you inside a town's walls, the watch rushes in, cuts it down, and stands back down once you're safe — towns are proper safe havens now.",
			"You'll now see other players actually swing as they chop, mine and forage at nearby resources, instead of standing still.",
		],
	},
	{
		"version": "1.6.3",
		"date": "2026-08",
		"title": "The Deep — Fishing Overhaul",
		"notes": [
			"Reeling in a fighting fish is now an interactive duel — hit the button prompts as the marker sweeps into the green to wear it down, and nail the centre for a PERFECT.",
			"Every fish you land now has a WEIGHT. Bigger catches are rarer, worth more gold and XP — and a heavier fish cooked into a meal heals more.",
			"TROPHY catches: land a record-size fish for a big bonus, then either MOUNT it as a keepsake for your collection or cook it — either way your best is recorded forever.",
			"NEW Biggest Catch leaderboard and a personal Fishing Journal — see your best against the world record for every species. Land a new record and the whole realm hears about it.",
			"Sea-monster battles run deeper: patch your hull, cast a net to stun the beast, or chum the water to weaken it — all from craftable supplies — and hit the exposed weak points for double damage. Watch for its wind-up before it strikes.",
			"New bait and lures at Bjorn's Fishmonger: chase bigger fish and better trophy odds, calm the waters for safe fishing, or bait out sea monsters — some lures even leave them weaker for the fight.",
			"Feeling brave? Botch a cast out on the water on purpose and you'll almost always drag a monster up — start a fight whenever you please.",
			"New sounds throughout casting, reeling, landing a catch and sea combat.",
		],
	},
	{
		"version": "1.6.2",
		"date": "2026-08",
		"title": "Wall Names & Farming",
		"notes": [
			"NEW SKILL — FARMING! Grow your own crops from wheat and carrots all the way up to grapes and moonwheat. Plant a seed in a Farm Plot, water it every few minutes to speed it along, and harvest the crop when it's ripe.",
			"Farm Plots are dotted around several towns — and each one is YOURS: you only ever see your own crop, so a plot is never taken and you can always farm.",
			"Seeds come from foraging herbs (rarer seeds for higher-tier crops), and the common starter seeds are stocked in the Kjelvik general store.",
			"Cook your harvest into new dishes — bread, stews, salads, pies, cobblers, a fruit bowl, ale and even fine wine — to heal in a fight.",
			"Town walls are now named after their town, and you can attack (and the townsfolk repair) them — including Kjelvik's castle walls. Warband-built walls are named after the warband that raised them.",
			"Fast Travel now stays unlocked for good once you've discovered a destination.",
			"Guides now double as tutorials — open a Guide and hit \"Start Tutorial\" for a step-by-step walkthrough, stoppable anytime.",
			"Fixes: typing in chat no longer moves your character, and scrolling a menu no longer zooms the camera. The Combat and Chat panels moved next to the minimap and HP bar.",
		],
	},
	{
		"version": "1.6.1",
		"date": "2026-08",
		"title": "3D Visual Overhaul & Caravan Fix",
		"notes": [
			"Big visual pass on 3D mode: far more detailed characters, monsters and dragons, plus your equipped weapon AND armour now show on your character (and everyone else's) — helmets, plate, shields and all.",
			"Caravans now properly follow the roads and steer around walls and obstacles instead of cutting straight across the map.",
			"3D mode polish: hover an object to see its name, a proper cave-mouth marks dungeon entrances, and the minimap rotates with your camera.",
			"Join our Discord straight from the login screen.",
		],
	},
	{
		"version": "1.6.0",
		"date": "2026-08",
		"title": "NEW: 3D Mode (beta)",
		"notes": [
			"You can now play VikingVale in full 3D! Flip it on under Settings → Graphics → \"World: 3D (beta)\". Off by default — the classic 2D game is untouched.",
			"The whole world is rebuilt in rounded low-poly 3D: rolling terrain with real elevation, distinct buildings, trees and ore, and every monster, NPC and player as a walking 3D character that turns to face where it moves.",
			"Behold Níðhöggr and the dragons in full 3D — spined backs, membrane wings, glowing eyes and lashing tails.",
			"Switch between 2D and 3D anytime from Settings — you keep your spot in the world (step outside first if you're inside a building), and a quick loading screen lets everything settle before you jump back in.",
			"Everyone shares one world: 2D and 3D players see each other move, fight and chat in real time, both directions, always.",
			"Combat, gathering, banking, admin tools, interiors and dungeons all work in 3D — it's the same game, seen from inside it.",
			"This is an early beta — finer art detail, hand-painted terrain and full animations are coming in later updates. Prefer the classic look? Just leave 3D off.",
		],
	},
	{
		"version": "1.5.5",
		"date": "2026-07",
		"title": "Thrall Rebalance & Fixes",
		"notes": [
			"Thralls no longer explode overnight — they work a single 12-hour shift then rest in town, and each shift yields far less. They're a helper now, not an auto-farm.",
			"The Frostmaw Hollow cave mouth moved out of the town square to its proper home in the cliffs west of Bjorn's Landing.",
		],
	},
	{
		"version": "1.5.4",
		"date": "2026-07",
		"title": "Character Customization & Visual Overhaul",
		"notes": [
			"Character creation reworked: far more hairstyles and beards, all HD-redrawn with real volume, highlights and strand detail.",
			"New eye colours — no more flat black stare.",
			"NEW free-hand BODY INK: zoom to the face or either shoulder and drag right on the skin to lay down war paint in any ink colour and brush width — the paint stays on skin and never covers your hair, eyes or gear. Undo/clear as you go.",
			"Buildings, walls and towers now stand with real depth, shading and drop shadows instead of flat tiles.",
			"Weapons read distinctly by TYPE and by TIER — a dragon blade no longer looks like a copper one.",
			"Gathered materials (ores, bars, logs, pelts, bones, raw fish) finally have their own proper icons.",
			"Monsters across the world are rebuilt on multi-part skeletons — they now stride, scuttle, shamble and breathe instead of sliding. Níðhöggr the ancient wyrm gets a full HD overhaul.",
			"Two new dragons now prowl the wilds: the Bronze Drake and the Venom Wyvern.",
			"Fixed cooking/smithing quantity boxes that could get stuck at 1 after another recipe finished — you can queue big batches again.",
			"Crafting minigames now only appear for jobs worth the effort (5+ items or a 30s+ wait), so quick one-offs don't get interrupted.",
		],
	},
	{
		"version": "1.5.3",
		"date": "2026-07",
		"title": "Capital City & the City Watch",
		"notes": [
			"Kjelvik is now a walled CASTLE CAPITAL — wall ring, watchtowers, a keep, barracks, armoury and a market quarter.",
			"City guards patrol the capital: attack a townsperson, walk in PvP-flagged, or fall out of favour and the watch answers in escalating waves — melee, then rangers, then battle-magi.",
			"The castle is the one safe haven: no PvP inside the walls (everywhere else stays your own toggle).",
			"Every town NPC can now be fought — but they respawn fast, and the watch takes it personally.",
			"Warband caravans: hire your own trade wagons from the clan pool; each safe delivery pays gold, standing and sometimes rare goods to the vault.",
			"Raiding a warband's caravan now earns you their enmity — a new player↔warband standing shown in the Reputation tab.",
			"Townsfolk finally dress for home: fishermen's oilskins at Bjorn's Landing, furs at Frostheim, and Kjelvik's blue-and-gold flown by its people and guards alike.",
		],
	},
	{
		"version": "1.5.2",
		"date": "2026-07",
		"title": "Caravans & Reputation",
		"notes": [
			"Trade caravans run the roads between towns — ambush them for loot, at the cost of the town's goodwill.",
			"New Reputation tab: your standing with each of the five towns, personal and warband.",
			"The road network now connects all five towns.",
		],
	},
	{
		"version": "1.5.1",
		"date": "2026-07",
		"title": "Thrall Polish",
		"notes": [
			"Fixes and follow-ups for the thrall worker system.",
		],
	},
	{
		"version": "1.5.0",
		"date": "2026-07",
		"title": "Chat, Rankings & Thralls",
		"notes": [
			"Collectible thralls — offline workers that gather and fight while you're away, and can be lost if you don't feed them.",
			"Live rankings built from real accounts.",
			"World-space chat bubbles and a cleaner chat window.",
		],
	},
	{
		"version": "1.4.2",
		"date": "2026-07",
		"title": "PvP Completion",
		"notes": [
			"PvP flagging, indicators and right-click Attack all work end to end.",
			"Crit, block, and split melee/ranged/magic defences.",
		],
	},
	{
		"version": "1.4",
		"date": "2026-06",
		"title": "The PvP Update",
		"notes": [
			"First pass at open-world PvP, token upgrades, and a pile of fixes.",
		],
	},
]

## The most recent entry (top of the list).
static func latest() -> Dictionary:
	return ENTRIES[0] if not ENTRIES.is_empty() else {}
