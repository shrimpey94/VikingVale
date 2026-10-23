extends Node

## Spectator RECORDING DIRECTOR (auto_studio). Makes a read-only spectator look
## exactly like a real player at their screen: it feeds the WATCHED player's
## server-pushed state (skills / inventory / worn gear) straight into GameManager
## so the REAL HUD renders it — health globe, minimap, combat UI, bag, the works.
##
## Then it behaves like a person, NOT a bot on a timer:
##   • on sit-down          → minimises the chat log (tidy the screen)
##   • crafted/cooked a new wieldable-or-usable item → opens the Inventory tab
##   • wielded a new item (equipment changed)        → opens the Equipment tab
## Panels close themselves after a short dwell. World.gd spawns this in
## `_enter_spectator_mode` INSTEAD of hiding the HUD. Read-only: a spectator holds
## no session and never sends anything, so driving GameManager here is cosmetic.

const GearDB = preload("res://scripts/Equipment.gd")

const DWELL := 5.5   # seconds a popped-open panel lingers before it auto-closes
const CRAFT_DWELL := 4.0   # the craft window stays up this long (the item "being made")
const CRAFT_VERIFY_GAP := 0.5  # beat between closing the craft window and checking the bag
const COMBAT_END_DWELL := 3.0  # hold on the fight's outcome before tucking the window away

var _hud: Node = null
var _prev_inv: Dictionary = {}   # item_id -> total qty (craft/cook detection)
var _prev_eq: Dictionary = {}
var _prev_bank_count: int = 0    # total qty in the bank (banking detection)
var _close_at: float = 0.0
var _bank_close_at: float = 0.0
var _craft_close_at: float = 0.0
var _craft_verify_at: float = 0.0   # when to open the bag to "check" what was made
var _combat_close_at: float = 0.0   # when to hide the combat window after a fight
var _first := true

func _ready() -> void:
	_hud = get_parent().get_node_or_null("HUD")   # HUD is a sibling under World
	Events.spectate_state_updated.connect(_on_state)
	Events.spectate_mime.connect(_on_mime)        # bank/craft "open the window now"
	Events.spectate_combat_start.connect(_on_combat_start)
	Events.spectate_combat_hit.connect(_on_combat_hit)
	Events.spectate_combat_end.connect(_on_combat_end)
	_apply_to_gamemanager()          # in case a state already arrived
	call_deferred("_sit_down")       # after the HUD finishes building its chat
	set_process(true)

## Deterministic window pops: the watched bot broadcasts a mime the MOMENT it
## banks / crafts, so the right screen opens on camera without waiting on the
## delayed save-state heuristics below.
func _on_mime(action: String) -> void:
	if _hud == null:
		return
	match action:
		"bank":
			_pop_bank()
		"craft", "smith", "cook":
			# Full crafting BEAT (the user wants it to READ like a player making
			# something, not a window that just sits under the combat log):
			#   1) tuck the chat/combat log away so it never overlaps the panel
			#   2) open the crafting window and hold on it while the item is "made"
			#   3) _process then closes it and opens the bag to "check" the result
			if _hud.has_method("spectator_minimize_chat"):
				_hud.spectator_minimize_chat()
			if _hud.has_method("spectator_open_craft"):
				_hud.spectator_open_craft()
				_craft_close_at = _now() + CRAFT_DWELL

func _sit_down() -> void:
	if _hud != null and _hud.has_method("spectator_minimize_chat"):
		_hud.spectator_minimize_chat()

# ── Combat readout (opens the combat window on camera + logs the fight) ────────
func _on_combat_start(monster_name: String, level: int) -> void:
	_combat_close_at = 0.0
	# Tuck the chat/combat log away first so the combat window isn't buried under it.
	if _hud != null and _hud.has_method("spectator_minimize_chat"):
		_hud.spectator_minimize_chat()
	if _hud != null and _hud.has_method("spectator_combat_begin"):
		_hud.spectator_combat_begin(monster_name, level)

func _on_combat_hit(monster_name: String, amount: int, mine: bool) -> void:
	_combat_close_at = 0.0   # a fresh blow — keep the window up
	if _hud != null and _hud.has_method("spectator_combat_log_hit"):
		_hud.spectator_combat_log_hit(monster_name, amount, mine)

func _on_combat_end(monster_name: String, result: String) -> void:
	if _hud != null and _hud.has_method("spectator_combat_end"):
		_hud.spectator_combat_end(monster_name, result)
	# Hold on the outcome a beat, then tuck the combat window away.
	_combat_close_at = _now() + COMBAT_END_DWELL

func _process(_delta: float) -> void:
	if _close_at > 0.0 and _now() >= _close_at:
		_close_at = 0.0
		if _hud != null and _hud.has_method("spectator_close_tab"):
			_hud.spectator_close_tab()
	if _bank_close_at > 0.0 and _now() >= _bank_close_at:
		_bank_close_at = 0.0
		if _hud != null and _hud.has_method("spectator_close_bank"):
			_hud.spectator_close_bank()
	if _craft_close_at > 0.0 and _now() >= _craft_close_at:
		_craft_close_at = 0.0
		if _hud != null and _hud.has_method("spectator_close_craft"):
			_hud.spectator_close_craft()
		# …then, after a short beat, open the bag to "check" what was crafted.
		_craft_verify_at = _now() + CRAFT_VERIFY_GAP
	if _craft_verify_at > 0.0 and _now() >= _craft_verify_at:
		_craft_verify_at = 0.0
		_pop("inv")
	if _combat_close_at > 0.0 and _now() >= _combat_close_at:
		_combat_close_at = 0.0
		if _hud != null and _hud.has_method("spectator_combat_hide"):
			_hud.spectator_combat_hide()

func _on_state() -> void:
	var st: Dictionary = NetworkManager.spectate_state
	# First push just seeds the baseline + paints the HUD — no pop (a player
	# doesn't fling their bag open the instant they log in).
	if _first:
		_first = false
		_seed_prev(st)
		_apply_to_gamemanager()
		return
	var crafted := _has_new_usable(st.get("inventory", []) as Array)
	var wielded := _eq_differs(st.get("equipment", {}) as Dictionary)
	var banked := _bank_total(st.get("bank", []) as Array) > _prev_bank_count
	# XP/level/item toasts now arrive per-action via NetworkManager's
	# `spectate_event` relay (instant, not batched off this state push).
	_seed_prev(st)
	_apply_to_gamemanager()
	# Banked something → open the bank; made something → check the bag; put it on →
	# check the character sheet. Banking wins (it's the current action on screen).
	if banked:
		_pop_bank()
	elif wielded:
		_pop("eqp")
	elif crafted:
		_pop("inv")

func _pop_bank() -> void:
	if _hud != null and _hud.has_method("spectator_open_bank"):
		_hud.spectator_open_bank()
		_bank_close_at = _now() + DWELL

func _bank_total(arr: Array) -> int:
	var t := 0
	for entry: Variant in arr:
		if entry is Dictionary:
			t += int((entry as Dictionary).get("qty", 1))
	return t

func _pop(tab_id: String) -> void:
	if _hud != null and _hud.has_method("spectator_open_tab"):
		_hud.spectator_open_tab(tab_id)
		_close_at = _now() + DWELL

func _apply_to_gamemanager() -> void:
	var st: Dictionary = NetworkManager.spectate_state
	if st.is_empty():
		return
	GameManager.player_skill_xp = (st.get("skill_xp", {}) as Dictionary).duplicate()
	GameManager.inventory = (st.get("inventory", []) as Array).duplicate(true)
	GameManager.equipment = (st.get("equipment", {}) as Dictionary).duplicate()
	var bank_arr: Array[Dictionary] = []   # bank_inventory is typed Array[Dictionary]
	for entry: Variant in (st.get("bank", []) as Array):
		if entry is Dictionary:
			bank_arr.append((entry as Dictionary).duplicate())
	GameManager.bank_inventory = bank_arr
	GameManager.current_hp = GameManager.get_max_hp()
	Events.inventory_changed.emit()
	Events.equipment_changed.emit()
	Events.bank_changed.emit()
	Events.player_hp_changed.emit(GameManager.current_hp, GameManager.get_max_hp())

## True if the inventory gained a NEW wieldable (gear) or usable (food) item —
## i.e. the player just crafted or cooked something worth showing. Raw gathers
## (ore/logs/raw fish) are neither, so hauling wood never triggers a pop.
func _has_new_usable(new_inv: Array) -> bool:
	for entry: Variant in new_inv:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry
		var iid := str(d.get("id", ""))
		if iid == "":
			continue
		if not (GearDB.is_equippable(iid) or GameManager.FOOD_HEAL.has(iid)):
			continue
		if int(d.get("qty", 1)) > int(_prev_inv.get(iid, 0)):
			return true
	return false

func _eq_differs(new_eq: Dictionary) -> bool:
	if new_eq.size() != _prev_eq.size():
		return true
	for slot: Variant in new_eq:
		if str(new_eq[slot]) != str(_prev_eq.get(slot, "")):
			return true
	return false

func _seed_prev(st: Dictionary) -> void:
	_prev_inv.clear()
	for entry: Variant in (st.get("inventory", []) as Array):
		if entry is Dictionary:
			var d: Dictionary = entry
			var iid := str(d.get("id", ""))
			if iid != "":
				_prev_inv[iid] = int(_prev_inv.get(iid, 0)) + int(d.get("qty", 1))
	_prev_bank_count = _bank_total(st.get("bank", []) as Array)
	_prev_eq = (st.get("equipment", {}) as Dictionary).duplicate()

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
