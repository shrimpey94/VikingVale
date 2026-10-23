extends RefCounted

## Quest catalog — DEFINITION layer only. Per-player progress and status are
## SQLite-resident on the server (see `quests` table). This file is the
## single source of truth for what a quest IS — title, giver, objectives,
## rewards. Server and client both preload it; the entire dict ships at
## boot, never via the wire.
##
## Schema rules locked by design:
##   1. `required` is a flat skill→level dict. Each entry checked
##      independently — NO combining or max-of-skills. {"melee": 20}
##      checks melee only.
##   2. Reward rule for repeatable boss quests: `gold` and `items` are
##      first-completion-only when BOTH `boss:true` AND `repeatable:true`.
##      `xp` is always granted on every completion. Non-boss quests grant
##      full rewards every completion regardless of repeat / daily.
##   3. Quests cannot fail — the SQLite 'failed' column is future-proof,
##      no code path sets it.
##   4. Abandon = delete the active row server-side. Player re-accepts
##      from scratch (progress resets to 0).
##   5. `chain_next` unlocks the named quest at its own giver NPC when
##      THIS quest completes. Empty string = standalone or chain tail.
##      Predecessor lookup is derived from chain_next (no chain_prereq).

const QUESTS: Dictionary = {

	# ──────────────────────────────────────────────────────────────────────────
	# Starter combat quests (no skill prereqs — anyone can pick them up)
	# ──────────────────────────────────────────────────────────────────────────

	"q_rats": {
		"title":       "Rat Infestation",
		"description": "Kill 5 Giant Rats near the walls of Kjelvik.",
		"giver_npc":   "Elder Bjarne",
		"required":    {},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "kill", "target_id": "rat", "quantity": 5,
			 "display": "Slay Giant Rats"},
		],
		"rewards": {
			"xp":    {"melee": 100, "vitality": 25},
			"gold":  50,
			"items": [],
		},
	},

	"q_wolves": {
		"title":       "Goblin Hunt",
		"description": "Drive off 4 Goblins terrorising the Frostheim hunting grounds.",
		"giver_npc":   "Hunter Ragnhild",
		"required":    {},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "kill", "target_id": "goblin", "quantity": 4,
			 "display": "Slay Goblins"},
		],
		"rewards": {
			"xp":    {"melee": 120},
			"gold":  80,
			"items": [],
		},
	},

	# ──────────────────────────────────────────────────────────────────────────
	# Mid-tier combat (per-skill gates exercise the {"skill": lv} rule)
	# ──────────────────────────────────────────────────────────────────────────

	"q_ironwood": {
		"title":       "Into the Ironwood",
		"description": "Venture east and slay 3 Skeletons haunting the Ironwood.",
		"giver_npc":   "Torsten the Wanderer",
		"required":    {"melee": 5},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "kill", "target_id": "skeleton", "quantity": 3,
			 "display": "Slay Skeletons"},
		],
		"rewards": {
			"xp":    {"melee": 150, "vitality": 25},
			"gold":  100,
			"items": [],
		},
	},

	"q_ashlands": {
		"title":       "Ashlands Menace",
		"description": "Investigate the ashlands by slaying 5 Draugr.",
		"giver_npc":   "Scout Halfdan",
		"required":    {"melee": 25},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "kill", "target_id": "draugr", "quantity": 5,
			 "display": "Slay Draugr"},
		],
		"rewards": {
			"xp":    {"melee": 350, "vitality": 50},
			"gold":  250,
			"items": [],
		},
	},

	# ──────────────────────────────────────────────────────────────────────────
	# Gathering quests — woodcutting / mining / foraging / fishing skills
	# ──────────────────────────────────────────────────────────────────────────

	"q_oak_logs": {
		"title":       "Fresh Lumber",
		"description": "Bring Ulfr 10 Oak Logs for the workshop. He always needs more.",
		"giver_npc":   "Blacksmith Ulfr",
		"required":    {},
		"repeatable":  true,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "gather", "target_id": "oak_log", "quantity": 10,
			 "display": "Gather Oak Logs"},
		],
		"rewards": {
			"xp":    {"woodcutting": 80},
			"gold":  30,
			"items": [],
		},
	},

	"q_logs": {
		"title":       "Ironwood Timber",
		"description": "Gather 3 Ironwood Logs for Ulfr's legendary blade.",
		"giver_npc":   "Blacksmith Ulfr",
		"required":    {"woodcutting": 35},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "gather", "target_id": "ironwood_log", "quantity": 3,
			 "display": "Gather Ironwood Logs"},
		],
		"rewards": {
			"xp":    {"woodcutting": 200},
			"gold":  150,
			"items": [{"id": "iron_axe", "name": "Iron Axe",
					   "qty": 1, "color": [0.55, 0.55, 0.60, 1.0]}],
		},
	},

	"q_copper": {
		"title":       "Copper Strike",
		"description": "Old Brynjar's forge is cold — bring him 5 Copper Ore.",
		"giver_npc":   "Old Brynjar",
		"required":    {},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "gather", "target_id": "copper_ore", "quantity": 5,
			 "display": "Mine Copper Ore"},
		],
		"rewards": {
			"xp":    {"mining": 90},
			"gold":  40,
			"items": [],
		},
	},

	"q_herbs": {
		"title":       "Apothecary's Need",
		"description": "Brynhildr the Apothecary's stocks run low. Bring 8 Herbs daily.",
		"giver_npc":   "Brynhildr the Apothecary",
		"required":    {},
		"repeatable":  false,
		"daily":       true,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "gather", "target_id": "herbs", "quantity": 8,
			 "display": "Forage Herbs"},
		],
		"rewards": {
			"xp":    {"farming": 70},   # foraging merged into farming (Phase 1)
			"gold":  35,
			"items": [],
		},
	},

	# ──────────────────────────────────────────────────────────────────────────
	# Fishing chain — q_first_fish unlocks q_fish on completion
	# ──────────────────────────────────────────────────────────────────────────

	"q_first_fish": {
		"title":       "First Catch",
		"description": "Sigrid wants to see a fresh fish — bring her a Raw Fish, then speak with her again.",
		"giver_npc":   "Sigrid the Fishmonger",
		"required":    {},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_fish",
		"objectives": [
			{"type": "gather", "target_id": "raw_fish", "quantity": 1,
			 "display": "Catch a Raw Fish"},
			{"type": "talk",   "target_id": "Sigrid the Fishmonger", "quantity": 1,
			 "display": "Show Sigrid your catch"},
		],
		"rewards": {
			"xp":    {"fishing": 40},
			"gold":  20,
			"items": [{"id": "fishing_pole", "name": "Fishing Pole",
					   "qty": 1, "color": [0.48, 0.30, 0.08, 1.0]}],
		},
	},

	"q_fish": {
		"title":       "Eastern Waters",
		"description": "Bring back 3 Lobsters from the coastal waters east of Bjorn's Landing.",
		"giver_npc":   "Merchant Eydis",
		"required":    {"fishing": 40},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "gather", "target_id": "lobster", "quantity": 3,
			 "display": "Catch Lobsters"},
		],
		"rewards": {
			"xp":    {"fishing": 180},
			"gold":  75,
			"items": [],
		},
	},

	# ──────────────────────────────────────────────────────────────────────────
	# Repeatable boss quest — exercises the boss-repeat reward rule
	# ──────────────────────────────────────────────────────────────────────────

	"q_kill_nidhogg": {
		"title":       "Slayer of Níðhöggr",
		"description": "The serpent stirs again. Find Níðhöggr and bring him down.",
		"giver_npc":   "Captain Sten",
		"required":    {"melee": 50, "vitality": 30},
		"repeatable":  true,
		"daily":       false,
		"boss":        true,
		"chain_next":  "",
		"objectives": [
			{"type": "kill", "target_id": "nidhogg", "quantity": 1,
			 "display": "Slay Níðhöggr"},
		],
		"rewards": {
			# XP granted on EVERY completion (boss-repeat rule keeps xp).
			"xp":    {"melee": 5000, "vitality": 500},
			# Gold + items granted only on FIRST completion (boss-repeat rule
			# strips these on subsequent kills). Player still gets the boss's
			# normal loot drop separately — that path is unaffected.
			"gold":  10000,
			"items": [{"id": "dragon_scale", "name": "Dragon Scale",
					   "qty": 3, "color": [0.20, 0.75, 0.35, 1.0]}],
		},
	},

	# ──────────────────────────────────────────────────────────────────────────
	# Act 1 → Act 2 hand-off
	# ──────────────────────────────────────────────────────────────────────────

	"q_old_bjarnes_letter": {
		"title":       "Old Bjarne's Letter",
		"description": "Bjarne has pressed a sealed letter into your hand. He told you to find the Ironwood Hermit Skade — somewhere west of Ironwood Keep, in the central plains nobody walks anymore. \"Read nothing,\" he said. \"Just put it in her hand.\"",
		"giver_npc":   "Elder Bjarne",
		# Light gate so this only offers after the player has done a bit of work.
		"required":    {"melee": 10, "woodcutting": 10},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_token_iron",
		"objectives": [
			{"type": "talk", "target_id": "Ironwood Hermit Skade", "quantity": 1,
			 "display": "Deliver Bjarne's letter to Skade"},
		],
		"rewards": {
			"xp":    {"melee": 200, "vitality": 50},
			"gold":  150,
			"items": [],
		},
	},

	# ──────────────────────────────────────────────────────────────────────────
	# Act 2 — The Five Tokens of the High Seat
	# Reworked into a 5-town world tour: iron, frost, grove, sea, ash Tokens,
	# unlocks warband creation server-side.
	# ──────────────────────────────────────────────────────────────────────────

	"q_token_iron": {
		"title":       "The Iron Token",
		"description": "Skade has told you what Bjarne could not write: the High Seat is real, and it cannot be sat without the Five Tokens — one kept by each of the five holds. Return to Bjarne. The Iron Token has rested in Kjelvik for two hundred years, and he will yield it only once you have forged for the wall and cleared the dead from beneath the Great Hall.",
		"giver_npc":   "Elder Bjarne",
		"required":    {"melee": 10, "smithing": 5},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_token_frost",
		"objectives": [
			{"type": "gather", "target_id": "iron_bar", "quantity": 5,
			"display": "Forge Iron Bars for the wall"},
			{"type": "kill", "target_id": "skeleton", "quantity": 8,
			"display": "Clear skeletons from the Great Hall cellars"},
		],
		"rewards": {
			"xp":    {"smithing": 400, "melee": 300},
			"gold":  300,
			"items": [{"id": "iron_token", "name": "Iron Token",
					   "qty": 1, "color": [0.62, 0.62, 0.68, 1.0]}],
		},
	},

	"q_token_frost": {
		"title":       "The Frost Token",
		"description": "One Token won. The second lies at Frostheim's glacier shrine, guarded by the great white pack — ice wolves that have killed three of Ragnhild's hunters. She will not lose a fourth easily. Break the pack and take what they guard — and she'd not go up there without a warband at her back, nor should you.",
		"giver_npc":   "Hunter Ragnhild",
		"required":    {"melee": 18},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_token_grove",
		"objectives": [
			{"type": "kill", "target_id": "ice_wolf", "quantity": 6,
			"display": "Break the ice-wolf pack at the glacier shrine"},
		],
		"rewards": {
			"xp":    {"melee": 600, "defense": 150, "vitality": 100},
			"gold":  500,
			"items": [{"id": "frost_token", "name": "Frost Token",
					   "qty": 1, "color": [0.72, 0.90, 0.98, 1.0]}],
		},
	},

	"q_token_grove": {
		"title":       "The Grove Token",
		"description": "The third Token hangs in the deepest dark of the Ironwood, where the last true trees still stand — and something old guards it. Ulfr calls it the Grove Guardian. Cut the ancient timber he needs, then face the thing in the grove and take the Token from its keeping.",
		"giver_npc":   "Blacksmith Ulfr",
		"required":    {"melee": 25, "woodcutting": 30},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_token_sea",
		"objectives": [
			{"type": "gather", "target_id": "ironwood_log", "quantity": 5,
			"display": "Fell Ironwood in the dark grove"},
			{"type": "kill", "target_id": "ancient_troll", "quantity": 1,
			"display": "Slay the Grove Guardian"},
		],
		"rewards": {
			"xp":    {"woodcutting": 700, "melee": 400},
			"gold":  700,
			"items": [{"id": "grove_token", "name": "Grove Token",
					   "qty": 1, "color": [0.35, 0.62, 0.28, 1.0]}],
		},
	},

	"q_token_sea": {
		"title":       "The Sea Token",
		"description": "The fourth Token rests at a shrine on the eastern cliffs, and Valdis will sail you there only once you have proven yourself a true deep-water hand. Land a shark from the cold eastern waters — and put down the beast that comes for you when you do.",
		"giver_npc":   "Sea Captain Valdis",
		"required":    {"fishing": 32},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_token_ash",
		"objectives": [
			{"type": "gather", "target_id": "raw_shark", "quantity": 1,
			"display": "Land a Shark from the eastern waters"},
			{"type": "kill", "target_id": "shark", "quantity": 1,
			"display": "Slay the shark that hunts the shrine"},
		],
		"rewards": {
			"xp":    {"fishing": 900, "melee": 300},
			"gold":  900,
			"items": [{"id": "sea_token", "name": "Sea Token",
					   "qty": 1, "color": [0.20, 0.55, 0.92, 1.0]}],
		},
	},

	"q_token_ash": {
		"title":       "The Ash Token",
		"description": "Four Tokens. The fifth waits beyond the rim of the Ashlands, where the fire-things nest and the Emberlord walks the burning ground. Halfdan will not send his own out there again. Clear the imps, break the Emberlord, and carry the last Token off the ash.",
		"giver_npc":   "Scout Halfdan",
		"required":    {"melee": 40, "vitality": 25},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_warrant",
		"objectives": [
			{"type": "kill", "target_id": "fire_imp", "quantity": 6,
			"display": "Slay Fire Imps beyond the rim"},
			{"type": "kill", "target_id": "fire_giant", "quantity": 1,
			"display": "Break the Emberlord"},
		],
		"rewards": {
			"xp":    {"melee": 1200, "vitality": 400},
			"gold":  1200,
			"items": [{"id": "ash_token", "name": "Ash Token",
					   "qty": 1, "color": [0.85, 0.35, 0.15, 1.0]}],
		},
	},

	"q_warrant": {
		"title":       "The Warrant of the High Seat",
		"description": "Five Tokens — Iron, Frost, Grove, Sea, and Ash — carried at last to Captain Sten on the Helheim shore. He is the only man living who knows what they are worth. Lay them before him, and he will name you a claimant of the High Seat.",
		"giver_npc":   "Captain Sten",
		"required":    {"melee": 45},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_pledge_kjelvik",
		"objectives": [
			{"type": "talk", "target_id": "Captain Sten", "quantity": 1,
			"display": "Lay the five Tokens before Sten"},
		],
		"rewards": {
			"xp":    {"melee": 2000, "vitality": 500, "magic": 400},
			"gold":  2000,
			"items": [
				# Marker item — the server checks for this id to unlock warband
				# creation. Soulbound-equivalent: don't drop on death.
				{"id": "high_seat_warrant", "name": "Warrant of the High Seat",
				 "qty": 1, "color": [0.95, 0.85, 0.30, 1.0]},
			],
		},
	},

	# ──────────────────────────────────────────────────────────────────────────
	# Act 3 — Town Pledges (warband endgame). A STAGGERED LADDER: the Warrant
	# chains into Kjelvik, and each pledge unlocks the next, gates ramping
	# 45→50→53→56→60. Warband creation (via the Warrant item) is still required
	# server-side to actually hold a town. Requirements rebalanced per town.
	# ──────────────────────────────────────────────────────────────────────────

	"q_pledge_kjelvik": {
		"title":       "Pledge of Kjelvik",
		"description": "The Warrant is yours. To pledge Kjelvik to your warband, rebuild the wall Bjarne has guarded so long — forge 15 iron bars — and clear 10 skeletons from the Great Hall cellars. Then swear the oath at the cracked stone seat.",
		"giver_npc":   "Elder Bjarne",
		"required":    {"melee": 45, "smithing": 40},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_pledge_frostheim",
		"objectives": [
			{"type": "gather", "target_id": "iron_bar", "quantity": 15,
			"display": "Forge Iron Bars for Kjelvik's wall"},
			{"type": "kill", "target_id": "skeleton", "quantity": 10,
			"display": "Clear the Great Hall cellars"},
			{"type": "talk", "target_id": "Elder Bjarne", "quantity": 1,
			"display": "Swear the oath at the stone seat"},
		],
		"rewards": {
			"xp":    {"melee": 1500, "smithing": 800, "defense": 400},
			"gold":  3000,
			"items": [{"id": "pledge_kjelvik", "name": "Pledge of Kjelvik",
					   "qty": 1, "color": [0.62, 0.62, 0.68, 1.0]}],
		},
	},

	"q_pledge_frostheim": {
		"title":       "Pledge of Frostheim",
		"description": "Frostheim pledges when the goblin push is broken at the high passes. Slay 12 Goblins and 5 Ice Wolves, and bring Ragnhild 10 Frost Logs for the new palisade. Then swear the oath at the mountain shrine.",
		"giver_npc":   "Hunter Ragnhild",
		"required":    {"melee": 50, "woodcutting": 50},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_pledge_ironwood",
		"objectives": [
			{"type": "kill", "target_id": "goblin", "quantity": 12,
			"display": "Slay Goblins at the high passes"},
			{"type": "kill", "target_id": "ice_wolf", "quantity": 5,
			"display": "Slay Ice Wolves"},
			{"type": "gather", "target_id": "frost_log", "quantity": 10,
			"display": "Gather Frost Logs for the palisade"},
			{"type": "talk", "target_id": "Hunter Ragnhild", "quantity": 1,
			"display": "Swear the oath at the mountain shrine"},
		],
		"rewards": {
			"xp":    {"melee": 1600, "woodcutting": 800, "defense": 450},
			"gold":  3200,
			"items": [{"id": "pledge_frostheim", "name": "Pledge of Frostheim",
					   "qty": 1, "color": [0.72, 0.90, 0.98, 1.0]}],
		},
	},

	"q_pledge_ironwood": {
		"title":       "Pledge of Ironwood Keep",
		"description": "Ironwood pledges when Ulfr's forge is stocked for the long winter and his grove holds. Bring him 12 Ironwood Logs and clear 10 Wolves from the dark grove. Then swear the oath at the foot of the last Ironwood Tree.",
		"giver_npc":   "Blacksmith Ulfr",
		"required":    {"melee": 53, "smithing": 50, "woodcutting": 45},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_pledge_bjorn",
		"objectives": [
			{"type": "gather", "target_id": "ironwood_log", "quantity": 12,
			"display": "Gather Ironwood Logs"},
			{"type": "kill", "target_id": "wolf", "quantity": 10,
			"display": "Clear wolves from the dark grove"},
			{"type": "talk", "target_id": "Blacksmith Ulfr", "quantity": 1,
			"display": "Swear the oath at the Ironwood Tree"},
		],
		"rewards": {
			"xp":    {"smithing": 1600, "woodcutting": 900, "melee": 700},
			"gold":  3400,
			"items": [{"id": "pledge_ironwood", "name": "Pledge of Ironwood Keep",
					   "qty": 1, "color": [0.28, 0.14, 0.08, 1.0]}],
		},
	},

	"q_pledge_bjorn": {
		"title":       "Pledge of Bjorn's Landing",
		"description": "The harbor pledges when the eastern lane is safe again. Bring Valdis 5 Raw Sharks and scatter 8 Bandits from the coast road. Then swear the oath at the dock-end shrine.",
		"giver_npc":   "Sea Captain Valdis",
		"required":    {"melee": 45, "fishing": 56},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "q_pledge_eastmark",
		"objectives": [
			{"type": "gather", "target_id": "raw_shark", "quantity": 5,
			"display": "Bring Valdis Raw Sharks"},
			{"type": "kill", "target_id": "bandit", "quantity": 8,
			"display": "Clear the coast-road bandits"},
			{"type": "talk", "target_id": "Sea Captain Valdis", "quantity": 1,
			"display": "Swear the oath at the dock-end shrine"},
		],
		"rewards": {
			"xp":    {"fishing": 1400, "melee": 1100, "defense": 450},
			"gold":  3600,
			"items": [{"id": "pledge_bjorn", "name": "Pledge of Bjorn's Landing",
					   "qty": 1, "color": [0.20, 0.55, 0.92, 1.0]}],
		},
	},

	"q_pledge_eastmark": {
		"title":       "Pledge of Eastmark Post",
		"description": "The last pledge, and the hardest. Eastmark swears to your warband when the Ashlands road is walkable again — clear 10 Draugr on the patrol route and 5 Fire Imps beyond the rim. Then swear the oath at the perimeter watchstone, and the High Seat is within your reach.",
		"giver_npc":   "Scout Halfdan",
		"required":    {"melee": 60, "vitality": 35},
		"repeatable":  false,
		"daily":       false,
		"boss":        false,
		"chain_next":  "",
		"objectives": [
			{"type": "kill", "target_id": "draugr", "quantity": 10,
			"display": "Clear Draugr on the Ashlands patrol"},
			{"type": "kill", "target_id": "fire_imp", "quantity": 5,
			"display": "Slay Fire Imps beyond the rim"},
			{"type": "talk", "target_id": "Scout Halfdan", "quantity": 1,
			"display": "Swear the oath at the perimeter watchstone"},
		],
		"rewards": {
			"xp":    {"melee": 1900, "vitality": 550, "defense": 550},
			"gold":  4000,
			"items": [{"id": "pledge_eastmark", "name": "Pledge of Eastmark Post",
					   "qty": 1, "color": [0.85, 0.30, 0.18, 1.0]}],
		},
	},

	# ── Repeatable field bounties — re-doable kill/gather jobs the town captains
	#    post. NEEDS target monsters placed near each town (see placement list).
	#    Keep in sync with server.py.
	"q_daily_eastmark_trolls": {
		"title":       "Trolls at the Pass",
		"description": "Two trolls have blocked the mountain pass above Eastmark Post. Clear them out.",
		"giver_npc":   "Scout Halfdan",
		"required":    {"melee": 15},
		"repeatable":  true, "daily": false, "boss": false, "chain_next": "",
		"objectives": [
			{"type": "kill", "target_id": "troll", "quantity": 2,
			 "display": "Slay Trolls at the mountain pass"},
		],
		"rewards": {"xp": {"melee": 260, "defense": 60}, "gold": 120, "items": []},
	},
	"q_daily_bjorn_wolves": {
		"title":       "Wolves in the Hills",
		"description": "The Bjorn Mountains are thick with wolves this season. Thin the pack — five should do.",
		"giver_npc":   "Merchant Eydis",
		"required":    {},
		"repeatable":  true, "daily": false, "boss": false, "chain_next": "",
		"objectives": [
			{"type": "kill", "target_id": "wolf", "quantity": 5,
			 "display": "Slay Wolves in the Bjorn Mountains"},
		],
		"rewards": {"xp": {"melee": 130, "vitality": 30}, "gold": 60, "items": []},
	},
	"q_daily_kjelvik_skeletons": {
		"title":       "Cellar Sweep",
		"description": "Skeletons keep crawling up from the Kjelvik cellars. Put six back down.",
		"giver_npc":   "Elder Bjarne",
		"required":    {"melee": 5},
		"repeatable":  true, "daily": false, "boss": false, "chain_next": "",
		"objectives": [
			{"type": "kill", "target_id": "skeleton", "quantity": 6,
			 "display": "Clear Skeletons from the cellars"},
		],
		"rewards": {"xp": {"melee": 170}, "gold": 80, "items": []},
	},
	"q_daily_frostheim_icewolves": {
		"title":       "White Fangs",
		"description": "Ice wolves are stalking the Frostheim high passes. Drive four off.",
		"giver_npc":   "Hunter Ragnhild",
		"required":    {"melee": 10},
		"repeatable":  true, "daily": false, "boss": false, "chain_next": "",
		"objectives": [
			{"type": "kill", "target_id": "ice_wolf", "quantity": 4,
			 "display": "Slay Ice Wolves on the high passes"},
		],
		"rewards": {"xp": {"melee": 190, "defense": 40}, "gold": 90, "items": []},
	},
	"q_daily_ironwood_bears": {
		"title":       "Grove Guardians",
		"description": "Bears have turned the Ironwood dark grove into a den. Cull three.",
		"giver_npc":   "Blacksmith Ulfr",
		"required":    {"melee": 12},
		"repeatable":  true, "daily": false, "boss": false, "chain_next": "",
		"objectives": [
			{"type": "kill", "target_id": "bear", "quantity": 3,
			 "display": "Slay Bears in the dark grove"},
		],
		"rewards": {"xp": {"melee": 210, "vitality": 40}, "gold": 110, "items": []},
	},
	"q_daily_bjorn_bandits": {
		"title":       "Coast Road Toll",
		"description": "Bandits are shaking down travellers on the Bjorn coast road. Scatter five.",
		"giver_npc":   "Sea Captain Valdis",
		"required":    {"melee": 8},
		"repeatable":  true, "daily": false, "boss": false, "chain_next": "",
		"objectives": [
			{"type": "kill", "target_id": "bandit", "quantity": 5,
			 "display": "Clear Bandits from the coast road"},
		],
		"rewards": {"xp": {"melee": 170, "ranged": 40}, "gold": 90, "items": []},
	},
	"q_daily_palisade_logs": {
		"title":       "Timber for the Walls",
		"description": "The Kjelvik palisade needs shoring up. Bring Halvdan 20 Oak Logs.",
		"giver_npc":   "Castellan Halvdan",
		"required":    {},
		"repeatable":  true, "daily": false, "boss": false, "chain_next": "",
		"objectives": [
			{"type": "gather", "target_id": "oak_log", "quantity": 20,
			 "display": "Gather Oak Logs for the palisade"},
		],
		"rewards": {"xp": {"construction": 150, "woodcutting": 60}, "gold": 50, "items": []},
	},
}


# ── Static accessors ─────────────────────────────────────────────────────────
## Returns the quest dict for `quest_id`, or {} if unknown.
static func data(quest_id: String) -> Dictionary:
	if not QUESTS.has(quest_id):
		return {}
	return QUESTS[quest_id]


static func exists(quest_id: String) -> bool:
	return QUESTS.has(quest_id)


## Walks the catalog once to find any quest whose `chain_next` points at
## `quest_id`. Returns the predecessor's id, or "" if this quest is
## standalone or the head of a chain. Used by the availability check —
## a chained quest is acceptable only after its predecessor completes.
static func prereq_of(quest_id: String) -> String:
	for qid: String in QUESTS.keys():
		var q: Dictionary = QUESTS[qid]
		if str(q.get("chain_next", "")) == quest_id:
			return qid
	return ""


## True if `quest_id` can be accepted by a player with these skill levels
## and completed-quest set. Server is authoritative; client uses this to
## grey out unavailable quests in the QuestLog. Pass empty `completed`
## when checking a player who has no completion history.
##
## Admins should bypass this check at the call site — this helper has no
## NetworkManager access and stays purely data-side.
static func is_available_to(quest_id: String, completed: Array,
		player_skill_levels: Dictionary) -> bool:
	if not QUESTS.has(quest_id):
		return false
	var q: Dictionary = QUESTS[quest_id]
	# Chain prereq must be in the completed set (if there is one).
	var prereq: String = prereq_of(quest_id)
	if prereq != "" and not completed.has(prereq):
		return false
	# Per-skill required levels — each checked independently, no combining.
	var req: Dictionary = q.get("required", {})
	for skill: String in req.keys():
		var need: int = int(req[skill])
		var have: int = int(player_skill_levels.get(skill, 0))
		if have < need:
			return false
	return true


## Quests offered by a given NPC name, sliced down to those the player can
## currently accept. The QuestLog uses this to populate the NPC dialogue's
## "Accept this quest?" rows.
static func quests_offered_by(npc_name: String, completed: Array,
		active: Array, player_skill_levels: Dictionary) -> Array:
	var out: Array = []
	for qid: String in QUESTS.keys():
		var q: Dictionary = QUESTS[qid]
		if str(q.get("giver_npc", "")) != npc_name:
			continue
		if active.has(qid):
			continue   # already in progress
		if not is_available_to(qid, completed, player_skill_levels):
			continue
		# Non-repeatable, non-daily quests can't be re-offered post-completion.
		if completed.has(qid):
			var repeatable: bool = bool(q.get("repeatable", false))
			var daily:      bool = bool(q.get("daily", false))
			if not repeatable and not daily:
				continue
			# Daily availability is gated by completed_at being on a different
			# UTC date — the server enforces that. Client returns true here
			# so the dialogue shows; server may still reject the accept.
		out.append(qid)
	return out


## Returns true if the boss-repeat rule should strip gold+items from this
## completion. Used by the server's completion handler.
##   - Not a boss quest → false (always grant full rewards)
##   - Not repeatable → false (one-shot, only one completion ever happens)
##   - First completion → false (full rewards)
##   - Subsequent boss-repeat completion → true (xp only)
static func is_boss_repeat_diminished(quest_id: String,
		prior_completion_count: int) -> bool:
	var q: Dictionary = data(quest_id)
	if q.is_empty():
		return false
	if not bool(q.get("boss", false)):
		return false
	if not bool(q.get("repeatable", false)):
		return false
	return prior_completion_count >= 1


## Single dispatcher for "what dialogue should this NPC show?" Used by
## NPC._on_player_interacted to pick between turn-in, offer, and reminder
## modes. Priority order: turn-in > offer > reminder > none.
##
## Returns `{"mode": "turnin"|"offer"|"reminder"|"", "quest_id": "..."}`.
## An empty `mode` means this NPC has no quest interaction available and the
## caller should fall through to shop / idle-line dialogue.
static func dialogue_for_npc(npc_name: String, active_quests: Array,
		completed_ids: Array, player_skill_levels: Dictionary) -> Dictionary:
	if npc_name == "":
		return {"mode": "", "quest_id": ""}
	# 1. Turn-in: any active quest with giver_npc=npc AND every objective met.
	for row: Variant in active_quests:
		if not (row is Dictionary):
			continue
		var aq := row as Dictionary
		var qid: String = str(aq.get("quest_id", ""))
		var def: Dictionary = data(qid)
		if def.is_empty():
			continue
		if str(def.get("giver_npc", "")) != npc_name:
			continue
		var progress: Dictionary = aq.get("progress", {}) as Dictionary if aq.get("progress") is Dictionary else {}
		var objs: Array = def.get("objectives", [])
		var all_done := true
		for i in range(objs.size()):
			var need: int = int((objs[i] as Dictionary).get("quantity", 1))
			var have: int = int(progress.get(str(i), 0))
			if have < need:
				all_done = false
				break
		if all_done:
			return {"mode": "turnin", "quest_id": qid}
	# 2. Offer: any quest gated by `quests_offered_by` (covers skill prereqs,
	#    chain prereqs, daily/repeat rules, and the active-set exclusion).
	var active_ids: Array = []
	for row: Variant in active_quests:
		if row is Dictionary:
			active_ids.append(str((row as Dictionary).get("quest_id", "")))
	var offered: Array = quests_offered_by(npc_name, completed_ids,
		active_ids, player_skill_levels)
	if not offered.is_empty():
		return {"mode": "offer", "quest_id": str(offered[0])}
	# 3. Reminder: any in-progress quest from this NPC (incomplete objectives).
	for row: Variant in active_quests:
		if not (row is Dictionary):
			continue
		var qid2: String = str((row as Dictionary).get("quest_id", ""))
		var def2: Dictionary = data(qid2)
		if def2.is_empty():
			continue
		if str(def2.get("giver_npc", "")) == npc_name:
			return {"mode": "reminder", "quest_id": qid2}
	return {"mode": "", "quest_id": ""}
