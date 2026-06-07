extends Area2D

@export var npc_type:      String = "worker"  # "worker" | "quest" | "shopkeeper" | ...
@export var npc_name_str:  String = "Villager"
@export var quest_text:    String = ""
@export var wander_radius: float  = 96.0
## Phase 4 of the gold economy — when `npc_type == "shopkeeper"` AND this
## field is a valid ShopCatalog id, clicking the NPC emits Events.open_shop
## instead of running the dialogue path. Empty for non-shopkeeper NPCs.
@export var shop_id:       String = ""

var _home:       Vector2 = Vector2.ZERO
var _target:     Vector2 = Vector2.ZERO
var _idle_timer: float   = 0.0
var _is_hovered: bool    = false
var _time:       float   = 0.0

const SPEED := 28.0

const _IDLE_LINES := [
	"Busy working, traveller.",
	"Fine weather today.",
	"Watch yer step out there.",
	"Need anything?",
	"Long road ahead.",
]

func _ready() -> void:
	add_to_group("interactable")
	input_pickable  = true
	collision_layer = 4
	collision_mask  = 0
	_home           = position
	_target         = position
	_pick_target()
	var cs     := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 12.0
	cs.shape = circle
	add_child(cs)
	mouse_entered.connect(_on_hover_enter)
	mouse_exited.connect(_on_hover_exit)
	Events.player_interacted.connect(_on_player_interacted)

func _process(delta: float) -> void:
	_time       += delta
	_idle_timer -= delta
	if _idle_timer > 0.0:
		queue_redraw()
		return
	var diff := _target - position
	if diff.length() < 4.0:
		_idle_timer = randf_range(1.5, 4.5)
		_pick_target()
	else:
		position += diff.normalized() * SPEED * delta
	queue_redraw()

func _pick_target() -> void:
	var angle := randf() * TAU
	var dist  := randf_range(16.0, wander_radius)
	_target = _home + Vector2(cos(angle) * dist, sin(angle) * dist)

func _on_hover_enter() -> void:
	_is_hovered = true
	self_modulate = Color(1.20, 1.20, 1.20)
	queue_redraw()
	var nodes := get_tree().get_nodes_in_group("hud")
	if nodes.size() > 0:
		var label := "[Talk]  %s" % npc_name_str if npc_type != "quest" else "[!]  %s" % npc_name_str
		nodes[0].show_hover(label)

func _on_hover_exit() -> void:
	_is_hovered = false
	self_modulate = Color.WHITE
	queue_redraw()
	var nodes := get_tree().get_nodes_in_group("hud")
	if nodes.size() > 0:
		nodes[0].hide_hover()

const QuestData = preload("res://scripts/QuestData.gd")

func _on_player_interacted(node: Node) -> void:
	if node != self:
		return
	# Talk-objective auto-fire. Server filters by active quests, so this is
	# safe to send for every NPC click — non-matching NPC names are a no-op
	# server-side.
	if npc_name_str != "":
		NetworkManager.send_quest_talk(npc_name_str)
	# Quest dispatcher runs FIRST — turn-in / offer / reminder priority. The
	# shop check has been demoted: if this NPC is also a shopkeeper but has a
	# quest interaction available, the quest dialogue wins. Players who want
	# to shop after viewing the quest can close the modal and re-click.
	var dlg: Dictionary = QuestData.dialogue_for_npc(
		npc_name_str,
		GameManager.server_active_quests,
		GameManager.server_completed_ids,
		_player_skill_levels())
	if str(dlg.get("mode", "")) != "":
		Events.show_quest_dialogue.emit(
			str(dlg["quest_id"]), str(dlg["mode"]), npc_name_str)
		return
	# No quest interaction — fall back to shop / dialogue paths.
	if npc_type == "shopkeeper" and shop_id != "":
		var eid := ""
		if has_meta("edit_id"):
			eid = str(get_meta("edit_id"))
		Events.open_shop.emit(eid, shop_id)
		return
	if npc_type == "quest" and quest_text != "":
		# Legacy quest-type NPC dialogue — preserved for any admin-placed NPC
		# still flagged "quest" with a custom `quest_text` blurb. The real
		# quest system runs through QuestData and the dialogue dispatcher
		# above; this path just chats the legacy text without side effects.
		Events.npc_dialogue.emit(npc_name_str, quest_text)
	else:
		var text: String = _IDLE_LINES[randi() % _IDLE_LINES.size()]
		Events.npc_dialogue.emit(npc_name_str, text)

## Build the {skill: level} map this NPC's caller needs for the quest
## availability check. Reads GameManager.player_skill_xp + get_skill_level.
func _player_skill_levels() -> Dictionary:
	var out: Dictionary = {}
	for skill: Variant in GameManager.player_skill_xp.keys():
		out[str(skill)] = GameManager.get_skill_level(str(skill))
	return out

func _draw() -> void:
	var body_c: Color
	match npc_type:
		"shopkeeper": body_c = Color(0.22, 0.52, 0.28)   # green merchant
		"banker":     body_c = Color(0.20, 0.28, 0.60)   # dark blue formal
		"tutor":      body_c = Color(0.50, 0.30, 0.10)   # brown leather
		"trainer":    body_c = Color(0.55, 0.12, 0.10)   # red armour
		"quest":      body_c = Color(0.28, 0.48, 0.62)
		_:            body_c = Color(0.60, 0.45, 0.30)   # worker brown
	var skin_c := Color(0.88, 0.74, 0.58)
	var is_moving := _idle_timer <= 0.0
	# Walking animation — both bob and arm swing only fire when actually
	# moving. An idle NPC stays planted instead of swaying on the spot.
	var swing := sin(_time * 7.0) * 0.30 if is_moving else 0.0
	var bob   := sin(_time * 9.0) * 1.6  if is_moving else 0.0
	var sway  := sin(_time * 4.5) * 0.8  if is_moving else 0.0

	# Ground shadow (stays fixed, no bob)
	draw_circle(Vector2(2.0, 15.0), 7.0, Color(0.02, 0.02, 0.04, 0.25))

	draw_set_transform(Vector2(sway, bob), 0.0, Vector2.ONE)

	# Dark outline backing
	var dark := Color(0.04, 0.04, 0.06, 0.82)
	draw_rect(Rect2(-6, 3, 5, 11), dark)
	draw_rect(Rect2(1, 3, 5, 11), dark)
	draw_rect(Rect2(-7, -7, 14, 13), dark)
	draw_circle(Vector2(0, -11), 8.5, dark)
	if npc_type in ["trainer", "banker"]:
		draw_rect(Rect2(-8, -26, 16, 14), dark)  # taller hat outline
	elif npc_type == "worker" or npc_type == "tutor":
		draw_rect(Rect2(-7, -21, 13, 9), dark)
	else:
		draw_rect(Rect2(-8, -22, 15, 11), dark)

	# Legs
	draw_rect(Rect2(-5, 4, 4, 9), body_c.darkened(0.2))
	draw_rect(Rect2(1,  4, 4, 9), body_c.darkened(0.2))

	# Body
	draw_rect(Rect2(-6, -6, 12, 11), body_c)

	# Arms (swing when walking)
	draw_line(Vector2(-6, -4), Vector2(-10.0 + swing * 8.0, 4.0), body_c.darkened(0.1), 3.0)
	draw_line(Vector2( 6, -4), Vector2( 10.0 - swing * 8.0, 4.0), body_c.darkened(0.1), 3.0)

	# Head
	draw_circle(Vector2(0, -11), 7, skin_c)

	# Hat / hood — distinct per type
	match npc_type:
		"worker":
			draw_rect(Rect2(-6, -20, 12, 8), Color(0.48, 0.30, 0.10))
		"shopkeeper":
			# Wide merchant brim hat
			draw_rect(Rect2(-8, -20, 16, 6), Color(0.18, 0.40, 0.18))
			draw_rect(Rect2(-10, -17, 20, 2), Color(0.14, 0.30, 0.14))
		"banker":
			# Tall formal hat
			draw_rect(Rect2(-5, -25, 10, 12), Color(0.15, 0.20, 0.48))
			draw_rect(Rect2(-8, -17, 16, 2), Color(0.10, 0.15, 0.38))
		"tutor":
			# Craftsman's cap
			draw_rect(Rect2(-6, -20, 12, 7), Color(0.38, 0.22, 0.08))
			draw_rect(Rect2(-7, -15, 14, 2), Color(0.28, 0.14, 0.04))
		"trainer":
			# Steel helm
			draw_rect(Rect2(-7, -22, 14, 11), Color(0.50, 0.52, 0.54))
			draw_rect(Rect2(-6, -21, 12, 3), Color(0.68, 0.70, 0.72))
		_:  # quest
			draw_rect(Rect2(-7, -21, 14, 10), Color(0.20, 0.38, 0.55))
			draw_rect(Rect2(-5, -21, 10, 3),  Color(0.28, 0.50, 0.70))

	# "!" quest marker
	if npc_type == "quest":
		draw_circle(Vector2(0, -28), 6, Color(1.0, 0.85, 0.10))
		draw_rect(Rect2(-1.5, -32, 3, 7), Color(0.08, 0.08, 0.08))
		draw_circle(Vector2(0, -26), 1.5, Color(0.08, 0.08, 0.08))

	# Hover indication is delivered via self_modulate (see _on_hover_enter)
	# rather than a yellow outline rect — same visual language across every
	# clickable entity in the world.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
