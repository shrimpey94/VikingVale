extends Control

## Quest marker renderer. Paints a purple `!` above any world target that
## advances an active quest objective (matching monster / interactable /
## NPC) and a purple `+` above the giver NPC when all objectives are
## complete and ready to turn in. Hosted on its own CanvasLayer at a
## layer index above world content so markers are never occluded by it.
##
## Targets are rebuilt only when quest state changes (Events.quest_state_changed).
## On every frame, we cull by viewport rect — markers are only painted for
## targets currently visible. Pulse animation is a sine on _time at 1.5s
## cycle, scale 0.9× → 1.1×.

const QuestData = preload("res://scripts/QuestData.gd")

# ── Palette ──────────────────────────────────────────────────────────────────
const COLOR_PURPLE      := Color(0.78, 0.42, 0.95)
const COLOR_PURPLE_LT   := Color(0.92, 0.72, 1.00)
const COLOR_GLOW_INNER  := Color(0.85, 0.55, 1.00, 0.32)
const COLOR_GLOW_OUTER  := Color(0.70, 0.35, 0.95, 0.16)

# ── Layout ───────────────────────────────────────────────────────────────────
const MARKER_Y_OFFSET   := -42.0   # px above the target's world position
const PULSE_CYCLE_SEC   := 1.5
const SCREEN_MARGIN     := 64.0    # px culling margin around viewport rect

# ── State (rebuilt on quest_state_changed) ───────────────────────────────────
var _time:        float      = 0.0
var _kill_set:    Dictionary = {}    # monster_type → true
var _gather_set:  Dictionary = {}    # item_id → true
var _talk_set:    Dictionary = {}    # npc_name → true
var _turnin_set:  Dictionary = {}    # npc_name → true (quest ready to turn in)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Events.quest_state_changed.connect(_rebuild_targets)
	_rebuild_targets()


func _process(delta: float) -> void:
	_time += delta
	# Cheap to redraw; the iteration is gated by the visible viewport.
	queue_redraw()


# ── Target set construction ──────────────────────────────────────────────────
## Walks active quests and groups every UNFINISHED objective into the right
## bucket. A quest with ALL objectives complete contributes its giver NPC
## to `_turnin_set` instead (the `+` marker takes over from the `!`s).
func _rebuild_targets() -> void:
	_kill_set.clear()
	_gather_set.clear()
	_talk_set.clear()
	_turnin_set.clear()
	for row: Variant in GameManager.server_active_quests:
		if not (row is Dictionary):
			continue
		var qid: String = str((row as Dictionary).get("quest_id", ""))
		var def: Dictionary = QuestData.data(qid)
		if def.is_empty():
			continue
		var is_ready: bool = GameManager.is_quest_ready_for_turnin(qid, QuestData)
		if is_ready:
			var giver: String = str(def.get("giver_npc", ""))
			if giver != "":
				_turnin_set[giver] = true
			continue   # don't show ! on individual targets once ready
		var objs: Array = def.get("objectives", [])
		for i in range(objs.size()):
			var obj: Dictionary = objs[i]
			var need: int = int(obj.get("quantity", 1))
			var have: int = GameManager.quest_objective_progress(qid, i)
			if have >= need:
				continue
			var t: String   = str(obj.get("type", ""))
			var tid: String = str(obj.get("target_id", ""))
			if tid == "":
				continue
			match t:
				"kill":   _kill_set[tid] = true
				"gather": _gather_set[tid] = true
				"talk":   _talk_set[tid] = true


# ── Drawing ──────────────────────────────────────────────────────────────────
func _draw() -> void:
	# Short-circuit when there's nothing to mark.
	if _kill_set.is_empty() and _gather_set.is_empty() \
			and _talk_set.is_empty() and _turnin_set.is_empty():
		return

	var ct := get_viewport().get_canvas_transform()
	var vp := get_viewport_rect().size
	var screen_rect := Rect2(
		Vector2(-SCREEN_MARGIN, -SCREEN_MARGIN),
		vp + Vector2(SCREEN_MARGIN * 2.0, SCREEN_MARGIN * 2.0))
	var pulse := 1.0 + 0.1 * sin(_time * (TAU / PULSE_CYCLE_SEC))

	# Monsters (kill objectives only — and only if still alive).
	if not _kill_set.is_empty():
		for m: Variant in get_tree().get_nodes_in_group("monster"):
			if not (m is Node2D):
				continue
			var node := m as Node2D
			var mtype := str(node.get("monster_type"))
			if not _kill_set.has(mtype):
				continue
			if not bool(node.get("is_alive")):
				continue
			var screen_pos: Vector2 = ct * node.global_position
			screen_pos.y += MARKER_Y_OFFSET
			if not screen_rect.has_point(screen_pos):
				continue
			_draw_exclamation(screen_pos, pulse)

	# Interactables — covers both NPCs (talk + turn-in) and resource nodes
	# (gather). Single iteration so we touch the "interactable" group once.
	if not _gather_set.is_empty() or not _talk_set.is_empty() \
			or not _turnin_set.is_empty():
		for n: Variant in get_tree().get_nodes_in_group("interactable"):
			if not (n is Node2D):
				continue
			var node := n as Node2D
			var screen_pos: Vector2 = ct * node.global_position
			screen_pos.y += MARKER_Y_OFFSET
			if not screen_rect.has_point(screen_pos):
				continue
			# NPC has the `npc_name_str` property; Interactable has
			# `interactable_type_str`. Use property presence as the
			# discriminator — no class_name imports needed.
			if "npc_name_str" in node:
				var nm := str(node.get("npc_name_str"))
				if _turnin_set.has(nm):
					_draw_plus(screen_pos, pulse)
				elif _talk_set.has(nm):
					_draw_exclamation(screen_pos, pulse)
				continue
			if "interactable_type_str" in node and not _gather_set.is_empty():
				# Match by the node's actual loot drop id. _loot_data is
				# private by convention but freely callable; the result
				# is just a {id, name, color, xp} dict.
				var loot: Dictionary = {}
				if node.has_method("_loot_data"):
					loot = node.call("_loot_data") as Dictionary
				if loot.is_empty():
					continue
				if _gather_set.has(str(loot.get("id", ""))):
					_draw_exclamation(screen_pos, pulse)


## Purple exclamation mark with a soft halo. Stem rect + dot below it.
## All sizes scale uniformly with `pulse` so the breathing is consistent.
func _draw_exclamation(pos: Vector2, pulse: float) -> void:
	# Outer + inner glow halos.
	draw_circle(pos, 16.0 * pulse, COLOR_GLOW_OUTER)
	draw_circle(pos, 10.0 * pulse, COLOR_GLOW_INNER)
	# Stem — 5×18, centered horizontally, dot is 6px below the stem.
	var stem_w := 5.0 * pulse
	var stem_h := 18.0 * pulse
	var stem_top := pos.y - 12.0 * pulse
	# Dark outline (one pass of slightly larger black underneath).
	draw_rect(Rect2(pos.x - stem_w * 0.5 - 1.0, stem_top - 1.0,
		stem_w + 2.0, stem_h + 2.0), Color(0.05, 0.02, 0.08, 0.80))
	draw_rect(Rect2(pos.x - stem_w * 0.5, stem_top,
		stem_w, stem_h), COLOR_PURPLE)
	# Stem highlight.
	draw_rect(Rect2(pos.x - stem_w * 0.5, stem_top,
		1.5 * pulse, stem_h), COLOR_PURPLE_LT)
	# Dot.
	var dot_y := pos.y + 12.0 * pulse
	var dot_r := 3.0 * pulse
	draw_circle(Vector2(pos.x, dot_y), dot_r + 1.0, Color(0.05, 0.02, 0.08, 0.80))
	draw_circle(Vector2(pos.x, dot_y), dot_r, COLOR_PURPLE)
	draw_circle(Vector2(pos.x - 0.8 * pulse, dot_y - 0.8 * pulse),
		0.8 * pulse, COLOR_PURPLE_LT)


## Purple plus sign for ready-to-turn-in NPCs. Two perpendicular rects.
func _draw_plus(pos: Vector2, pulse: float) -> void:
	draw_circle(pos, 18.0 * pulse, COLOR_GLOW_OUTER)
	draw_circle(pos, 12.0 * pulse, COLOR_GLOW_INNER)
	var bar_long := 22.0 * pulse
	var bar_thick := 6.0 * pulse
	# Horizontal bar.
	draw_rect(Rect2(pos.x - bar_long * 0.5 - 1.0,
		pos.y - bar_thick * 0.5 - 1.0,
		bar_long + 2.0, bar_thick + 2.0),
		Color(0.05, 0.02, 0.08, 0.80))
	draw_rect(Rect2(pos.x - bar_long * 0.5, pos.y - bar_thick * 0.5,
		bar_long, bar_thick), COLOR_PURPLE)
	# Vertical bar.
	draw_rect(Rect2(pos.x - bar_thick * 0.5 - 1.0,
		pos.y - bar_long * 0.5 - 1.0,
		bar_thick + 2.0, bar_long + 2.0),
		Color(0.05, 0.02, 0.08, 0.80))
	draw_rect(Rect2(pos.x - bar_thick * 0.5, pos.y - bar_long * 0.5,
		bar_thick, bar_long), COLOR_PURPLE)
	# Center highlight pixel.
	draw_circle(pos, 1.6 * pulse, COLOR_PURPLE_LT)
