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
			"xp":    {"foraging": 70},
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
