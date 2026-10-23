extends Node

## Manages the offline thrall task queue.
## Queue is saved server-side and runs automatically when the player logs out.

const MAX_TASKS := 8

const TASK_TYPES: Array[Dictionary] = [
	{"id": "woodcut", "label": "Woodcutting"},
	{"id": "mine",    "label": "Mining"},
	{"id": "fish",    "label": "Fishing"},
	{"id": "forage",  "label": "Foraging"},
	{"id": "combat",  "label": "Combat"},
]

## Towns a thrall can be SENT to when assigned (V1.5.5). ids mirror the server's
## TOWN_NAMES / _TOWN_CENTER_TILE; the thrall stands + works near this town.
const TOWNS: Array[Dictionary] = [
	{"id": "bjorn",     "label": "Bjorn's Landing"},
	{"id": "kjelvik",   "label": "Kjelvik"},
	{"id": "frostheim", "label": "Frostheim"},
	{"id": "ironwood",  "label": "Ironwood"},
	{"id": "eastmark",  "label": "Eastmark"},
]

## Which task tiers each town offers (V1.5.5 gating): task -> [min_tier, max_tier].
## MUST mirror server.py TOWN_RESOURCES. The assign picker only lists towns whose
## range covers the chosen target's tier, so a low-tier thrall can't be sent to a
## high-tier town and Frostheim (no fishing) never shows for a fishing task.
const TOWN_RESOURCES: Dictionary = {
	"bjorn":     {"fish": [1, 4], "woodcut": [1, 2], "mine": [1, 1], "forage": [1, 2], "combat": [1, 2]},
	"kjelvik":   {"mine": [1, 3], "woodcut": [1, 2], "forage": [1, 2], "combat": [1, 3]},
	"frostheim": {"mine": [4, 6], "woodcut": [4, 5], "combat": [3, 4]},
	"ironwood":  {"woodcut": [2, 5], "forage": [2, 3], "combat": [2, 3]},
	"eastmark":  {"mine": [2, 4], "fish": [2, 3], "combat": [2, 3]},
}

## True if `town` offers `task` at `tier`. Mirrors server _town_offers.
func town_offers(town: String, task: String, tier: int) -> bool:
	var d: Dictionary = TOWN_RESOURCES.get(town, {})
	if not d.has(task):
		return false
	var rng: Array = d[task]
	return tier >= int(rng[0]) and tier <= int(rng[1])

## Each target carries a `tier` (1-6) — a thrall can only be assigned targets
## whose tier ≤ the thrall's tier (server-validated in _handle_thrall_assign).
const TASK_TARGETS: Dictionary = {
	"woodcut": [
		{"id": "oak",      "label": "Oak      (Lv 1)",  "tier": 1},
		{"id": "pine",     "label": "Pine     (Lv 1)",  "tier": 1},
		{"id": "cherry",   "label": "Cherry   (Lv 15)", "tier": 2},
		{"id": "ironwood", "label": "Ironwood (Lv 30)", "tier": 3},
		{"id": "frost",    "label": "Frost    (Lv 50)", "tier": 4},
		{"id": "ancient",  "label": "Ancient  (Lv 70)", "tier": 5},
	],
	"mine": [
		{"id": "copper",  "label": "Copper  (Lv 1)",  "tier": 1},
		{"id": "iron",    "label": "Iron    (Lv 15)", "tier": 2},
		{"id": "gold",    "label": "Gold    (Lv 30)", "tier": 3},
		{"id": "mithril", "label": "Mithril (Lv 50)", "tier": 4},
		{"id": "adamant", "label": "Adamant (Lv 70)", "tier": 5},
		{"id": "runite",  "label": "Runite  (Lv 85)", "tier": 6},
	],
	"fish": [
		{"id": "small",   "label": "Small Fish (Lv 1)",  "tier": 1},
		{"id": "salmon",  "label": "Salmon     (Lv 20)", "tier": 2},
		{"id": "lobster", "label": "Lobster    (Lv 40)", "tier": 3},
		{"id": "shark",   "label": "Shark      (Lv 60)", "tier": 4},
	],
	"forage": [
		{"id": "herb",      "label": "Herbs       (Lv 1)",  "tier": 1},
		{"id": "mushroom",  "label": "Mushrooms   (Lv 1)",  "tier": 1},
		{"id": "berries",   "label": "Berries     (Lv 5)",  "tier": 1},
		{"id": "moonbloom", "label": "Moonbloom   (Lv 15)", "tier": 2},
		{"id": "root",      "label": "Anc. Root   (Lv 30)", "tier": 3},
	],
	"combat": [
		{"id": "rat",      "label": "Rats      (Lv 1)",  "tier": 1},
		{"id": "goblin",   "label": "Goblins   (Lv 5)",  "tier": 1},
		{"id": "skeleton", "label": "Skeletons (Lv 15)", "tier": 2},
		{"id": "draugr",   "label": "Draugr    (Lv 25)", "tier": 3},
		{"id": "dragon",   "label": "Dragons   (Lv 60)", "tier": 4},
	],
}

# ── Thrall roster (Phase 10) — server-owned; refreshed by the "thralls" push.
var roster: Array = []          # each: {id,name,tier,level,xp,job,target,hp,max_hp,backpack}
var slots: int = 2
var max_slots: int = 5

func populate_thralls(thralls: Array, slot_count: int, max_slot: int) -> void:
	roster = thralls
	slots = slot_count
	max_slots = max_slot
	Events.thralls_updated.emit()

## Reasons any owned thrall needs attention before you log out (Phase 10b):
## an idle thrall wastes the offline window, and a COMBAT thrall with no food in
## its bag can starve and permadie. Empty array = everything's squared away.
## Used by the logout button + the window-close guard to warn the player.
func attention_notes() -> Array:
	var out: Array = []
	for t: Variant in roster:
		if not (t is Dictionary):
			continue
		var d := t as Dictionary
		var nm := str(d.get("name", "A thrall"))
		var job := str(d.get("job", ""))
		if job == "":
			out.append("%s is idle" % nm)
		elif job == "combat" and not _bag_has_food(d.get("backpack", []) as Array):
			out.append("%s has no food (could die)" % nm)
	return out

func _bag_has_food(bag: Array) -> bool:
	for it: Variant in bag:
		if it is Dictionary:
			var d := it as Dictionary
			if GameManager.FOOD_HEAL.has(str(d.get("id", ""))) and int(d.get("qty", 0)) > 0:
				return true
	return false

const CONDITIONS: Array[Dictionary] = [
	{"id": "forever",        "label": "Forever",         "has_value": false},
	{"id": "inventory_full", "label": "Until Inv Full",  "has_value": false},
	{"id": "hours",          "label": "For X hours",     "has_value": true},
	{"id": "level",          "label": "Until level X",   "has_value": true},
]

# task: {type, target, condition, condition_value, label}
var tasks: Array[Dictionary] = []

# ── Public API ────────────────────────────────────────────────────────────────
func add_task(task_type: String, target: String,
		condition: String, cond_val: float) -> bool:
	if tasks.size() >= MAX_TASKS:
		Events.chat_message.emit("Task queue full (max %d)." % MAX_TASKS)
		return false

	var type_label  := _find_label(TASK_TYPES, task_type)
	var target_label := _find_label(TASK_TARGETS.get(task_type, []) as Array, target)
	var cond_label  := ""
	match condition:
		"forever":        cond_label = "Forever"
		"inventory_full": cond_label = "Inv Full"
		"hours":          cond_label = "For %dh" % int(cond_val)
		"level":          cond_label = "Until Lv %d" % int(cond_val)

	tasks.append({
		"type":            task_type,
		"target":          target,
		"condition":       condition,
		"condition_value": cond_val,
		"label":           "%s: %s — %s" % [type_label, target_label, cond_label],
	})
	_sync()
	return true

func remove_task(index: int) -> void:
	if index < tasks.size():
		tasks.remove_at(index)
		_sync()

func move_up(index: int) -> void:
	if index > 0:
		var tmp: Dictionary = tasks[index - 1]
		tasks[index - 1]    = tasks[index]
		tasks[index]        = tmp
		_sync()

func move_down(index: int) -> void:
	if index < tasks.size() - 1:
		var tmp: Dictionary = tasks[index + 1]
		tasks[index + 1]    = tasks[index]
		tasks[index]        = tmp
		_sync()

func populate_from_server(data: Dictionary) -> void:
	tasks.clear()
	var task_arr := data.get("task_queue", []) as Array
	for t: Variant in task_arr:
		if t is Dictionary:
			tasks.append(t as Dictionary)

# ── Internal ──────────────────────────────────────────────────────────────────
func _sync() -> void:
	NetworkManager.send_task_queue(tasks)

func _find_label(arr: Array, id: String) -> String:
	for entry: Variant in arr:
		var d := entry as Dictionary
		if d["id"] == id:
			return d["label"] as String
	return id
