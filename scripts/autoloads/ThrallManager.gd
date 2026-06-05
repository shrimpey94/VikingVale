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

const TASK_TARGETS: Dictionary = {
	"woodcut": [
		{"id": "oak",      "label": "Oak      (Lv 1)"},
		{"id": "pine",     "label": "Pine     (Lv 1)"},
		{"id": "cherry",   "label": "Cherry   (Lv 15)"},
		{"id": "ironwood", "label": "Ironwood (Lv 30)"},
		{"id": "frost",    "label": "Frost    (Lv 50)"},
		{"id": "ancient",  "label": "Ancient  (Lv 70)"},
	],
	"mine": [
		{"id": "copper",  "label": "Copper  (Lv 1)"},
		{"id": "iron",    "label": "Iron    (Lv 15)"},
		{"id": "gold",    "label": "Gold    (Lv 30)"},
		{"id": "mithril", "label": "Mithril (Lv 50)"},
		{"id": "adamant", "label": "Adamant (Lv 70)"},
		{"id": "runite",  "label": "Runite  (Lv 85)"},
	],
	"fish": [
		{"id": "small",   "label": "Small Fish (Lv 1)"},
		{"id": "salmon",  "label": "Salmon     (Lv 20)"},
		{"id": "lobster", "label": "Lobster    (Lv 40)"},
		{"id": "shark",   "label": "Shark      (Lv 60)"},
	],
	"forage": [
		{"id": "herb",      "label": "Herbs       (Lv 1)"},
		{"id": "mushroom",  "label": "Mushrooms   (Lv 1)"},
		{"id": "berries",   "label": "Berries     (Lv 5)"},
		{"id": "moonbloom", "label": "Moonbloom   (Lv 15)"},
		{"id": "root",      "label": "Anc. Root   (Lv 30)"},
	],
	"combat": [
		{"id": "rat",      "label": "Rats      (Lv 1)"},
		{"id": "goblin",   "label": "Goblins   (Lv 5)"},
		{"id": "skeleton", "label": "Skeletons (Lv 15)"},
		{"id": "draugr",   "label": "Draugr    (Lv 25)"},
		{"id": "dragon",   "label": "Dragons   (Lv 60)"},
	],
}

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
