extends Node

## Global player state. Persists across scenes.

const GearDB  = preload("res://scripts/Equipment.gd")
const Fishing = preload("res://scripts/Fishing.gd")

var player_skill_xp: Dictionary = {
	"woodcutting":  0,
	"mining":        0,
	"fishing":       0,
	"foraging":      0,
	"smithing":      0,
	"cooking":       0,
	"crafting":      0,
	"construction":  0,
	"farming":       0,
	"melee":         0,
	"ranged":        0,
	"magic":         0,
	"defense":       0,
	"vitality":      1154,  # starts at level 10 on the RS-style curve
	"soul":          0,
}

const RESPAWN_POS := Vector2(7823, 4488)  # Bjorn's Landing coastal spawn — matches server-side INSERT default for new accounts

const BONE_XP: Dictionary = {
	"rat_bone":     5,
	"bone":         15,
	"goblin_ear":   10,
	"draugr_shard": 30,
	"dragon_scale": 50,
}

## Cooked foods → HP healed when eaten (left-click in inventory). Higher cooking
## tiers heal more. Used by eat_food(); cook recipes live in HUD._COOK_RECIPES.
const FOOD_HEAL: Dictionary = {
	# Existing dishes
	"cooked_fish": 5, "herb_tea": 4, "cooked_salmon": 9, "cooked_lobster": 16,
	"cooked_shark": 22, "eel_stew": 30,
	# Lv 1–50 tiers
	"cooked_rat_meat": 3, "roasted_chicken": 4,
	"grilled_trout": 6, "baked_potato": 5,
	"vegetable_stew": 8,
	"meat_pie": 12, "fish_soup": 11,
	"hearty_stew": 15,
	"shark_steak": 20, "honey_glazed_ham": 19,
	"stuffed_boar": 24, "spiced_fish": 22,
	"dragon_fin_soup": 28, "mead_braised_ribs": 27,
	"frost_trout_fillet": 33, "venison_roast": 31,
	"magma_prawn": 37, "smoked_bear": 36,
	"elder_fish_platter": 42, "giants_feast": 46,
	# Lv 55–80 tiers (rarer ingredients, big heals)
	"leviathan_stew": 55, "kraken_platter": 66, "feast_of_valhalla": 80,
}

## Inventory items: Array of { "id", "name", "qty", "color" }
var inventory: Array[Dictionary] = []
var bank_inventory: Array[Dictionary] = []
var gold: int = 0

## Quest definitions ── type: "kill" | "collect"
const QUESTS: Array = [
	{"id":"q_rats",     "npc":"Elder Bjarne",      "title":"Rat Infestation",
	 "desc":"Kill 5 Giant Rats near the walls of Kjelvik.",
	 "type":"kill",    "target":"rat",          "qty":5,  "reward_xp":100, "skill":"combat"},
	{"id":"q_ironwood", "npc":"Torsten the Wanderer","title":"Into the Ironwood",
	 "desc":"Venture east and slay 3 Skeletons haunting the Ironwood.",
	 "type":"kill",    "target":"skeleton",     "qty":3,  "reward_xp":150, "skill":"combat"},
	{"id":"q_wolves",   "npc":"Hunter Ragnhild",    "title":"Goblin Hunt",
	 "desc":"Drive off 4 Goblins terrorising the Frostheim hunting grounds.",
	 "type":"kill",    "target":"goblin",       "qty":4,  "reward_xp":120, "skill":"combat"},
	{"id":"q_logs",     "npc":"Blacksmith Ulfr",    "title":"Ironwood Timber",
	 "desc":"Gather 3 Ironwood Logs for Ulfr's legendary blade.",
	 "type":"collect", "target":"ironwood_log", "qty":3,  "reward_xp":200, "skill":"woodcutting"},
	{"id":"q_ashlands", "npc":"Scout Halfdan",       "title":"Ashlands Menace",
	 "desc":"Investigate by slaying 5 Draugr in the ashlands.",
	 "type":"kill",    "target":"draugr",       "qty":5,  "reward_xp":350, "skill":"combat"},
	{"id":"q_fish",     "npc":"Merchant Eydis",      "title":"Eastern Waters",
	 "desc":"Bring back 3 Lobsters from the coastal waters east of Bjorn's Landing.",
	 "type":"collect", "target":"lobster",      "qty":3,  "reward_xp":180, "skill":"fishing"},
]

## Active quests: quest_id → {progress: int, completed: bool}
var active_quests: Dictionary = {}

## Post-quest-system server snapshot — mirrors what _handle_quest_*
## returned. The QuestLog + marker renderer drive entirely off this.
##   server_active_quests:    Array[Dictionary]  — [{quest_id, progress, accepted_at}]
##   server_completed_ids:    Array[String]      — distinct completed quest_ids
##   server_completion_counts: Dictionary        — {quest_id: count}
## Mutated only by `apply_quest_state` from the server push; never reconstructed
## locally so the client can't drift from the SQLite source of truth.
var server_active_quests: Array       = []
var server_completed_ids: Array       = []
var server_completion_counts: Dictionary = {}

var current_hp: int = 0
var equipped_boots: String = ""

## Character appearance (see Appearance.gd). Populated from server on login.
var appearance: Dictionary = {"skin": 2, "hair_style": 0, "hair_color": 1, "beard": 1, "body": 1, "tunic": 0}
## Equipped gear by slot id → item_id (e.g. {"head":"iron_helm"}). Server stores it.
var equipment: Dictionary = {}
## Combat-style preference — set via the persistent HUD toggle and consumed
## by HUD._launch_player_attack. Survives logout via the appearance JSON blob.
## Values: "melee" / "ranged" / "magic".
var combat_style: String = "melee"
## When combat_style == "magic", the rune id this player is currently casting.
## Each cast consumes 1 of this item from inventory. Empty string until the
## player picks a rune in the magic sub-row. Persists with appearance.
var active_rune: String = ""
## Boat currently being sailed (Boat.gd id), or "" when on foot. In-memory only.
var current_boat: String = ""
## Current hull HP + max for the boat being sailed. Tracked here so it
## persists between Phase 3 sea-combat encounters within a single sailing
## session (`_launch_boat` sets both to max, `_dock_boat` and the "lose"
## outcome clear them to 0). Not server-persisted — surviving HP is intra-
## session only, by design. Player.gd reads these to draw the floating HP
## bar below the hull when current < max.
var current_boat_hp:     int = 0
var current_boat_max_hp: int = 0

const BOOT_SPEED_BONUS: Dictionary = {
	"leather_boots": 0.10,
	"iron_boots":    0.20,
	"mithril_boots": 0.30,
	"dragon_boots":  0.40,
}

func get_move_speed(base: float) -> float:
	var bonus := BOOT_SPEED_BONUS.get(equipped_boots, 0.0) as float
	return base * (1.0 + bonus)

func equip_boots(item_id: String) -> void:
	equipped_boots = item_id
	Events.inventory_changed.emit()

func _ready() -> void:
	_build_xp_table()
	current_hp = get_max_hp()

# ── HP ───────────────────────────────────────────────────────────────────────
func get_max_hp() -> int:
	return get_skill_level("vitality") * 10 + get_equipment_bonus("hp")

func take_damage(amount: int) -> void:
	current_hp = maxi(0, current_hp - amount)
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	if current_hp <= 0:
		Events.player_died.emit()
		_on_player_death()

func heal(amount: int) -> void:
	current_hp = mini(get_max_hp(), current_hp + amount)
	Events.player_hp_changed.emit(current_hp, get_max_hp())

## Eat one of a cooked food item, healing its FOOD_HEAL value. Returns false if
## not edible or already at full HP.
func eat_food(item_id: String) -> bool:
	if not FOOD_HEAL.has(item_id):
		return false
	if current_hp >= get_max_hp():
		Events.chat_message.emit("You're already at full health.")
		return false
	if not remove_item_qty(item_id, 1):
		return false
	var amount := FOOD_HEAL[item_id] as int
	heal(amount)
	Events.chat_message.emit("You eat the %s. (+%d HP)" % [item_id.replace("_", " ").capitalize(), amount])
	return true

func _on_player_death() -> void:
	# Death-drop economics: tell the server we died at our current world
	# position BEFORE the respawn moves us. The server is authoritative
	# for the drop — it sorts inventory by ItemPrices.price_for, keeps
	# the top 4, drops the rest as world LootDrops, and spawns a gold
	# pile holding 25% of our current gold. Our inventory + gold get
	# pushed back via admin_inventory_set / gold_set after.
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		var p := players[0] as Node2D
		NetworkManager.send_player_died(p.global_position.x, p.global_position.y)
	current_hp = get_max_hp()
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	Events.combat_ended.emit()
	Events.player_respawned.emit(RESPAWN_POS)

func bury_bone(id: String) -> void:
	if not BONE_XP.has(id):
		return
	if not remove_item_qty(id, 1):
		return
	var xp := BONE_XP[id] as int
	add_xp("soul", xp)

# ── XP / Levels (RuneScape-style exponential curve) ──────────────────────────
# Cumulative XP to REACH each level. Built once in _ready(). Index = level (1..99);
# index 0 unused. Early levels are quick, 50+ ramps hard, 90-99 is a serious grind.
var _xp_table: Array[int] = []

func _build_xp_table() -> void:
	_xp_table.resize(100)
	_xp_table[0] = 0
	_xp_table[1] = 0
	var points := 0.0
	for lv in range(1, 99):
		points += floor(float(lv) + 300.0 * pow(2.0, float(lv) / 7.0))
		_xp_table[lv + 1] = int(floor(points / 4.0))

## XP threshold to reach a given level (clamped 1..99).
func xp_for_level(level: int) -> int:
	if _xp_table.is_empty():
		_build_xp_table()
	return _xp_table[clampi(level, 1, 99)]

func get_skill_level(skill: String) -> int:
	if _xp_table.is_empty():
		_build_xp_table()
	var xp := player_skill_xp.get(skill, 0) as int
	var lv := 1
	while lv < 99 and xp >= _xp_table[lv + 1]:
		lv += 1
	return lv

func get_skill_xp(skill: String) -> int:
	return player_skill_xp.get(skill, 0)

func add_xp(skill: String, amount: int) -> void:
	if player_skill_xp.has(skill):
		player_skill_xp[skill] += amount
		Events.xp_gained.emit(skill, amount)

func get_level_progress(skill: String) -> float:
	var xp := player_skill_xp.get(skill, 0) as int
	var lv := get_skill_level(skill)
	if lv >= 99:
		return 1.0
	var cur := xp_for_level(lv)
	var nxt := xp_for_level(lv + 1)
	return clampf(float(xp - cur) / float(maxi(1, nxt - cur)), 0.0, 1.0)

func get_xp_to_next_level(skill: String) -> int:
	var xp := player_skill_xp.get(skill, 0) as int
	var lv := get_skill_level(skill)
	if lv >= 99:
		return 0
	return xp_for_level(lv + 1) - xp

# ── Tools ────────────────────────────────────────────────────────────────────
func has_tool_for_skill(skill: String) -> bool:
	var keyword := ""
	match skill:
		"woodcutting": keyword = "axe"
		"mining":      keyword = "pickaxe"
		"fishing":     keyword = "fishing_pole"
		_: return true
	for item: Dictionary in inventory:
		if (item["id"] as String).contains(keyword):
			return true
	return false

func tool_name_for_skill(skill: String) -> String:
	match skill:
		"woodcutting": return "an Axe"
		"mining":      return "a Pickaxe"
		"fishing":     return "a Fishing Pole"
	return ""

# ── Combat stats ─────────────────────────────────────────────────────────────
func get_attack_power(style: String) -> int:
	var eq := get_equipment_bonus("atk")
	match style:
		"melee":  return maxi(1, floori(get_skill_level("melee")  / 3.0) + 5 + eq)
		"ranged": return maxi(1, floori(get_skill_level("ranged") / 3.0) + 4 + eq)
		"magic":  return maxi(1, floori(get_skill_level("magic")  / 3.0) + 3 + eq)
	return 1

func get_defense_power() -> int:
	return maxi(0, floori(get_skill_level("defense") / 4.0)) + get_equipment_bonus("def")

# ── Equipment ──────────────────────────────────────────────────────────────────
func get_equipment_bonus(stat: String) -> int:
	return GearDB.stat_total(equipment, stat)

func equip_item(inv_index: int) -> void:
	if inv_index < 0 or inv_index >= inventory.size():
		return
	var item_id := inventory[inv_index]["id"] as String
	if not GearDB.is_equippable(item_id):
		return
	var slot := GearDB.target_slot(item_id, equipment)
	if slot == "":
		return
	if not remove_item_qty(item_id, 1):
		return
	var old_id := str(equipment.get(slot, ""))
	if old_id != "":
		var od := GearDB.def_for(old_id)
		add_item(old_id, str(od.get("name", old_id)), 1,
			_swap_color_for(old_id))
	equipment[slot] = item_id
	if slot == "boots":
		equipped_boots = item_id
	_after_equipment_change()
	Events.chat_message.emit("Equipped %s." % str(GearDB.def_for(item_id).get("name", item_id)))

func unequip_slot(slot: String) -> void:
	var iid := str(equipment.get(slot, ""))
	if iid == "":
		return
	if inventory.size() >= 28:
		Events.chat_message.emit("Inventory full — make room first.")
		return
	var d := GearDB.def_for(iid)
	add_item(iid, str(d.get("name", iid)), 1, _swap_color_for(iid))
	equipment.erase(slot)
	if slot == "boots":
		equipped_boots = ""
	_after_equipment_change()

## Picks the inventory tint to use when an equipped item returns to the bag.
## Gear is gray (matching the long-standing UI convention); bait/lures keep
## their real Fishing-table color so the inventory entry stays recognizable
## after a swap or unequip. Add cases here if new typed equipment categories
## need their own color preservation.
func _swap_color_for(item_id: String) -> Color:
	if Fishing.is_bait(item_id) or Fishing.is_lure(item_id):
		var td: Dictionary = Fishing.tackle_data(item_id)
		return td.get("color", Color.GRAY) as Color
	return Color.GRAY

## Phase 5 — id of the currently-equipped fishing tackle (bait OR lure), or
## "" if the bait slot is empty. Reads through `equipment` so it stays in
## sync with the existing equip / unequip / server-save path.
func equipped_bait() -> String:
	return str(equipment.get("bait", ""))

func _after_equipment_change() -> void:
	current_hp = mini(current_hp, get_max_hp())
	Events.equipment_changed.emit()
	Events.inventory_changed.emit()

## Single source of truth for admin gating. Combines hardcoded owner check
## (NetworkManager.my_admin_rank == "owner") with DB-promoted admins (rank
## "admin"). Any non-empty rank bypasses every level/material check.
func is_admin() -> bool:
	return NetworkManager.my_admin_rank != ""

## Persist the combat-style toggle and the active rune. Called from the
## HUD's persistent style strip and rune sub-row. The save round-trips
## through send_set_appearance — server stores both values inside the
## appearance JSON blob, populate_from_server reads them back before
## Appearance.sanitize strips them off.
func set_combat_style(style: String, rune_id: String = "") -> void:
	if style != "melee" and style != "ranged" and style != "magic":
		return
	combat_style = style
	if style == "magic":
		active_rune = rune_id
	else:
		active_rune = ""
	Events.combat_style_changed.emit(combat_style, active_rune)
	# Persist via the appearance save path. The two prefs ride along inside
	# the appearance dict so the existing set_appearance handler stores them
	# without needing a new message type.
	var to_send := appearance.duplicate()
	to_send["combat_style"] = combat_style
	to_send["active_rune"]  = active_rune
	NetworkManager.send_set_appearance(to_send, equipment)
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	NetworkManager.send_set_appearance(appearance, equipment)
	for pl in get_tree().get_nodes_in_group("player"):
		(pl as Node2D).queue_redraw()

const INV_CAP := 28
# Only ammo / consumable-type items stack into one slot. Everything else (logs,
# ores, bars, fish, food, armour, weapons, tools) takes one slot per item.
const STACKABLE: Dictionary = {
	"arrows": true, "feather": true, "herbs": true, "stick": true,
	"stone": true, "magic_dust": true, "rune_essence": true,
}

const CROPS: Dictionary = {
	"barley": true, "cabbage": true, "onion": true, "wheat": true, "tomato": true,
}

func is_stackable(id: String) -> bool:
	return STACKABLE.has(id) or id.ends_with("_rune") \
		or id.ends_with("_seed") or CROPS.has(id)

# ── Inventory ─────────────────────────────────────────────────────────────────
func get_item_qty(id: String) -> int:
	var total := 0
	for item: Dictionary in inventory:
		if item["id"] == id:
			total += item["qty"] as int
	return total

func free_slots() -> int:
	return maxi(0, INV_CAP - inventory.size())

## Remove `qty` of an item, spanning multiple (non-stacked) slots if needed.
func remove_item_qty(id: String, qty: int) -> bool:
	if get_item_qty(id) < qty:
		return false
	var remaining := qty
	var i := 0
	while i < inventory.size() and remaining > 0:
		var item: Dictionary = inventory[i]
		if item["id"] == id:
			var take := mini(remaining, item["qty"] as int)
			item["qty"] = (item["qty"] as int) - take
			remaining -= take
			if (item["qty"] as int) <= 0:
				inventory.remove_at(i)
				continue
		i += 1
	Events.inventory_changed.emit()
	return true

func add_item(id: String, item_name: String, qty: int, color: Color) -> void:
	var added := 0
	if is_stackable(id):
		for item in inventory:
			if item["id"] == id:
				item["qty"] = (item["qty"] as int) + qty
				added = qty
				break
		if added == 0 and free_slots() > 0:
			inventory.append({"id": id, "name": item_name, "qty": qty, "color": color})
			added = qty
	else:
		# One slot per item; add as many separate stacks of 1 as fit.
		for _n in range(qty):
			if free_slots() <= 0:
				break
			inventory.append({"id": id, "name": item_name, "qty": 1, "color": color})
			added += 1
	if added <= 0:
		Events.chat_message.emit("Your inventory is full.")
		return
	Events.inventory_changed.emit()
	Events.item_gained.emit(item_name, added)
	_check_collect_quests(id)

# ── Quest system ──────────────────────────────────────────────────────────────
func accept_quest(quest_id: String) -> void:
	if active_quests.has(quest_id):
		return
	active_quests[quest_id] = {"progress": 0, "completed": false}
	Events.quest_accepted.emit(quest_id)


# ── Server-pushed quest snapshot ─────────────────────────────────────────────
## Wholesale replace the cached state with whatever the server just pushed.
## `payload` is the `quest_state` message body (already arrived as a dict).
## Single signal emit so listeners refresh idempotently.
func apply_quest_state(payload: Dictionary) -> void:
	var a: Variant = payload.get("active", [])
	server_active_quests = a if a is Array else []
	var c: Variant = payload.get("completed_ids", [])
	server_completed_ids = c if c is Array else []
	var k: Variant = payload.get("completion_counts", {})
	server_completion_counts = k if k is Dictionary else {}
	Events.quest_state_changed.emit()

## Returns the active row for `quest_id` or {} if not active.
func get_active_quest(quest_id: String) -> Dictionary:
	for row: Variant in server_active_quests:
		if row is Dictionary and str((row as Dictionary).get("quest_id", "")) == quest_id:
			return row
	return {}

## Progress count for objective `obj_idx` of `quest_id`. Returns 0 for any
## unknown quest / objective so callers don't have to null-check.
func quest_objective_progress(quest_id: String, obj_idx: int) -> int:
	var row := get_active_quest(quest_id)
	if row.is_empty():
		return 0
	var prog: Variant = row.get("progress", {})
	if not (prog is Dictionary):
		return 0
	return int((prog as Dictionary).get(str(obj_idx), 0))

## True if every objective in `quest_id` has progress >= its quantity.
## Used by the QuestLog to show the ready-to-turn-in state and by the
## marker renderer to swap `!` → `+` on the giver NPC.
func is_quest_ready_for_turnin(quest_id: String, QuestData: GDScript) -> bool:
	var row := get_active_quest(quest_id)
	if row.is_empty():
		return false
	var def: Dictionary = QuestData.data(quest_id)
	if def.is_empty():
		return false
	var objs: Array = def.get("objectives", [])
	for i in range(objs.size()):
		var need := int((objs[i] as Dictionary).get("quantity", 1))
		if quest_objective_progress(quest_id, i) < need:
			return false
	return true

func on_monster_killed(mtype: String) -> void:
	for q: Dictionary in QUESTS:
		var qid: String = q["id"] as String
		if not active_quests.has(qid):
			continue
		var aq: Dictionary = active_quests[qid]
		if (aq["completed"] as bool):
			continue
		if (q["type"] as String) == "kill" and (q["target"] as String) == mtype:
			aq["progress"] = mini((aq["progress"] as int) + 1, q["qty"] as int)
			if (aq["progress"] as int) >= (q["qty"] as int):
				aq["completed"] = true
				add_xp(q["skill"] as String, q["reward_xp"] as int)
				Events.chat_message.emit("Quest complete: %s! +%d XP" % [q["title"], q["reward_xp"]])
			Events.quest_updated.emit(qid)

func _check_collect_quests(item_id: String) -> void:
	for q: Dictionary in QUESTS:
		var qid: String = q["id"] as String
		if not active_quests.has(qid):
			continue
		var aq: Dictionary = active_quests[qid]
		if (aq["completed"] as bool):
			continue
		if (q["type"] as String) == "collect" and (q["target"] as String) == item_id:
			var have := get_item_qty(item_id)
			aq["progress"] = mini(have, q["qty"] as int)
			if (aq["progress"] as int) >= (q["qty"] as int):
				aq["completed"] = true
				add_xp(q["skill"] as String, q["reward_xp"] as int)
				Events.chat_message.emit("Quest complete: %s! +%d XP" % [q["title"], q["reward_xp"]])
			Events.quest_updated.emit(qid)

# ── Bank ──────────────────────────────────────────────────────────────────────
func deposit_item(inv_index: int) -> void:
	if inv_index >= inventory.size():
		return
	var item: Dictionary = inventory[inv_index].duplicate()
	for b in bank_inventory:
		if b["id"] == item["id"]:
			b["qty"] = (b["qty"] as int) + (item["qty"] as int)
			inventory.remove_at(inv_index)
			Events.inventory_changed.emit()
			Events.bank_changed.emit()
			return
	bank_inventory.append(item)
	inventory.remove_at(inv_index)
	Events.inventory_changed.emit()
	Events.bank_changed.emit()

func _bank_merge(item: Dictionary) -> void:
	for b in bank_inventory:
		if b["id"] == item["id"]:
			b["qty"] = (b["qty"] as int) + (item["qty"] as int)
			return
	bank_inventory.append(item)

## Move every inventory item into the bank in one action.
func deposit_all() -> void:
	if inventory.is_empty():
		return
	for item: Dictionary in inventory:
		_bank_merge(item.duplicate())
	inventory.clear()
	Events.inventory_changed.emit()
	Events.bank_changed.emit()

## Move every inventory item matching `item_id` into the bank.
func deposit_all_of(item_id: String) -> void:
	var moved := false
	for i in range(inventory.size() - 1, -1, -1):
		if str(inventory[i]["id"]) == item_id:
			_bank_merge(inventory[i].duplicate())
			inventory.remove_at(i)
			moved = true
	if moved:
		Events.inventory_changed.emit()
		Events.bank_changed.emit()

# ── Server data sync ──────────────────────────────────────────────────────────
## Called by LoginScreen after a successful server login.
## Overwrites local state with the server's saved data.
func populate_from_server_data(data: Dictionary) -> void:
	# Skill XP
	var srv_xp: Dictionary = data.get("skill_xp", {})
	for skill: String in player_skill_xp.keys():
		if srv_xp.has(skill):
			player_skill_xp[skill] = int(srv_xp[skill])

	# Inventory
	inventory.clear()
	var inv_arr := data.get("inventory", []) as Array
	for item: Variant in inv_arr:
		if item is Dictionary:
			inventory.append(item as Dictionary)

	# Bank
	bank_inventory.clear()
	var bank_arr := data.get("bank", []) as Array
	for item: Variant in bank_arr:
		if item is Dictionary:
			bank_inventory.append(item as Dictionary)

	# Gold
	gold = int(data.get("gold", 0))

	# Appearance + equipped loadout. Read the raw appearance dict BEFORE
	# Appearance.sanitize discards non-cosmetic keys — combat_style and
	# active_rune ride along in the blob to survive logout.
	var raw_appr: Dictionary = data.get("appearance", {}) as Dictionary if data.get("appearance") is Dictionary else {}
	combat_style = str(raw_appr.get("combat_style", "melee"))
	if combat_style != "melee" and combat_style != "ranged" and combat_style != "magic":
		combat_style = "melee"
	active_rune  = str(raw_appr.get("active_rune", ""))
	appearance = Appearance.sanitize(raw_appr)
	var eq: Variant = data.get("equipment", {})
	equipment = (eq as Dictionary) if eq is Dictionary else {}
	equipped_boots = str(equipment.get("boots", equipped_boots))
	Events.equipment_changed.emit()

	# Server-pushed quest state — full snapshot in the login burst per the
	# "client never assumes" rule. Empty payload on a fresh account is fine
	# (apply_quest_state handles missing keys defensively).
	var qs: Variant = data.get("quest_state", {})
	if qs is Dictionary:
		apply_quest_state(qs as Dictionary)

	# Restore HP
	current_hp = get_max_hp()
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	Events.inventory_changed.emit()

	# Teleport player to saved position
	var sx := float(data.get("x", RESPAWN_POS.x))
	var sy := float(data.get("y", RESPAWN_POS.y))
	Events.player_respawned.emit(Vector2(sx, sy))

func withdraw_item(bank_index: int) -> void:
	if bank_index >= bank_inventory.size():
		return
	if free_slots() <= 0:
		Events.chat_message.emit("Inventory full — make room first.")
		return
	var item: Dictionary = bank_inventory[bank_index]
	var iid := str(item["id"])
	if is_stackable(iid):
		# Move the whole stack, merging with an existing inventory stack if any.
		var qty := item["qty"] as int
		for inv in inventory:
			if inv["id"] == iid:
				inv["qty"] = (inv["qty"] as int) + qty
				bank_inventory.remove_at(bank_index)
				Events.inventory_changed.emit()
				Events.bank_changed.emit()
				return
		inventory.append(item.duplicate())
		bank_inventory.remove_at(bank_index)
	else:
		# One unit per click — keeps non-stackable items at one slot each.
		var one := item.duplicate()
		one["qty"] = 1
		inventory.append(one)
		item["qty"] = (item["qty"] as int) - 1
		if (item["qty"] as int) <= 0:
			bank_inventory.remove_at(bank_index)
	Events.inventory_changed.emit()
	Events.bank_changed.emit()
