extends Area2D

const VillageArt = preload("res://scripts/art/VillagePrototypeArt.gd")

@export var npc_type:      String = "worker"  # "worker" | "quest" | "shopkeeper" | ...
@export var npc_name_str:  String = "Villager"
@export var quest_text:    String = ""
@export var wander_radius: float  = 96.0
## Phase 4 of the gold economy — when `npc_type == "shopkeeper"` AND this
## field is a valid ShopCatalog id, clicking the NPC emits Events.open_shop
## instead of running the dialogue path. Empty for non-shopkeeper NPCs.
@export var shop_id:       String = ""
## Home town id ("bjorn" | "frostheim" | "kjelvik" | "ironwood" | "eastmark" |
## ""). Set by World._spawn_npcs from the NPC's position. Drives the regional
## wardrobe in _draw so a town's people read as belonging to it (Bjorn's =
## fishermen, Frostheim = furs/heavy coats, Kjelvik = city colours flown).
@export var region:        String = ""

var _home:       Vector2 = Vector2.ZERO
var _target:     Vector2 = Vector2.ZERO
var _idle_timer: float   = 0.0
var _is_hovered: bool    = false
var _time:       float   = 0.0
## Idle variance — tiny random poses so an idle NPC doesn't feel like a
## statue. `_iv_kind`: 0 = none, 1 = head turn (offset head sideways),
## 2 = arms crossed (arms drawn folded across the chest instead of at
## the sides). `_iv_end_t` is when the current pose relaxes; `_iv_next_t`
## is when the next variance beat fires.
var _iv_kind:  int   = 0
var _iv_dir:   float = 1.0   # -1 or +1 for head turn direction
var _iv_end_t: float = 0.0
var _iv_next_t: float = 4.0

const SPEED := 28.0

# ── Combat (Phase 5b) ────────────────────────────────────────────────────────
# Town NPCs are killable. The SERVER owns hp/death/respawn and the reputation
# penalty — these fields are a display mirror plus the duck-typed interface the
# HUD combat path expects of a target (is_alive / current_hp / max_hp / defense
# / level / display_name / xp_reward / entity_id / flash_hit).
const NPC_MAX_HP := 60

var entity_id:   String = ""      # mirrors the "n:N" edit_id
var is_alive:    bool   = true
var current_hp:  int    = NPC_MAX_HP
var max_hp:      int    = NPC_MAX_HP
var defense:     int    = 4
var level:       int    = 5
var xp_reward:   int    = 0       # murdering townsfolk earns no XP, by design
## Townsfolk never fight back — the city watch answers for them. Declared so
## the shared combat loop reading `attack` gets a real 0 rather than null.
var attack:      int    = 0
var _hit_flash:  float  = 0.0

## The combat UI reads `display_name`; NPCs carry their name in npc_name_str.
var display_name: String:
	get: return npc_name_str

## HUD calls this on a landed hit for feedback. Real hp comes back from the
## server via Events.npc_hit, so this is purely the flash.
func flash_hit() -> void:
	_hit_flash = 0.18
	queue_redraw()

# Server broadcasts are global, so every client filters on its own entity_id.
func _on_npc_hit(id: String, hp: int, mhp: int) -> void:
	if id != entity_id or entity_id == "":
		return
	current_hp = hp
	max_hp = maxi(1, mhp)
	_hit_flash = 0.18
	queue_redraw()

func _on_npc_died(id: String) -> void:
	if id != entity_id or entity_id == "":
		return
	is_alive = false
	current_hp = 0
	# Drop out of the world entirely: no sprite, no clicks, no dialogue.
	visible = false
	input_pickable = false
	queue_redraw()

func _on_npc_respawned(id: String) -> void:
	if id != entity_id or entity_id == "":
		return
	is_alive = true
	current_hp = max_hp
	visible = true
	input_pickable = true
	# Return to the spawn point so a corpse doesn't reappear mid-wander.
	position = _home
	_target = _home
	queue_redraw()

const _IDLE_LINES := [
	"Busy working, traveller.",
	"Fine weather today.",
	"Watch yer step out there.",
	"Need anything?",
	"Long road ahead.",
]

## Admin move — reposition AND re-anchor the wander home + current target so the
## NPC stays where it was placed instead of drifting back to its spawn point.
func admin_set_position(gpos: Vector2) -> void:
	global_position = gpos
	_home   = position
	_target = position

func _ready() -> void:
	add_to_group("interactable")
	# Own group so HUD._action_menu_options can offer Talk/Attack without
	# guessing from interactable_type_str (NPCs don't have one).
	add_to_group("npc")
	if has_meta("edit_id"):
		entity_id = str(get_meta("edit_id"))
	Events.npc_hit.connect(_on_npc_hit)
	Events.npc_died.connect(_on_npc_died)
	Events.npc_respawned.connect(_on_npc_respawned)
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
	# Dead NPCs hold still until the server revives them.
	if not is_alive:
		return
	if _hit_flash > 0.0:
		_hit_flash -= delta
		if _hit_flash <= 0.0:
			queue_redraw()
	_time       += delta
	_idle_timer -= delta
	if _idle_timer > 0.0:
		# Idle variance beats — fire a small pose (head turn or arms
		# crossed) every 4-8 s while stationary, hold for 1.2 s, then
		# relax. Keeps villagers from looking like posed mannequins.
		if _iv_kind != 0 and _time >= _iv_end_t:
			_iv_kind = 0
		elif _iv_kind == 0 and _time >= _iv_next_t:
			_iv_kind = 1 if randi() % 2 == 0 else 2
			_iv_dir = 1.0 if randi() % 2 == 0 else -1.0
			_iv_end_t = _time + 1.2
			_iv_next_t = _time + randf_range(4.0, 8.0)
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
		if npc_type == "shopkeeper" and shop_id != "":
			label = "[Trade]  %s" % npc_name_str   # right-click also offers Trade
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
	if node != self or not is_alive:
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

## Per-NPC visual characteristics — playtest ask that villagers/shopkeepers
## stop reading as clones. Derived from `npc_name_str.hash()` so the same
## NPC always looks identical across sessions without a server field.
## Returns (skin, hair, tunic_shift, beard_kind, girth) where:
##   skin        — palette pick (5 tones), hair — palette pick (6 tones),
##   tunic_shift — small HSV shift on the type body color (varies palette),
##   beard_kind  — 0=none, 1=stubble, 2=short beard, 3=long viking beard,
##   girth       — 0 slim, 1 average, 2 broad (widens torso + head)
func _characteristics() -> Dictionary:
	var h: int = npc_name_str.hash()
	var skins: Array = [
		Color(0.98, 0.80, 0.65), Color(0.88, 0.72, 0.55),
		Color(0.72, 0.55, 0.38), Color(0.58, 0.42, 0.28),
		Color(0.42, 0.30, 0.20),
	]
	var hairs: Array = [
		Color(0.20, 0.14, 0.08), Color(0.55, 0.35, 0.15),   # black, brown
		Color(0.85, 0.62, 0.25), Color(0.92, 0.85, 0.60),   # blond, pale
		Color(0.70, 0.20, 0.10), Color(0.60, 0.60, 0.60),   # red, grey
	]
	var beard_kind: int = (h >> 3) & 3
	# Younger/quest NPCs stay beardless more often — most villagers aren't
	# grizzled. Trainers/tutors/bankers skew older.
	if npc_type == "quest" and beard_kind > 1:
		beard_kind = 0
	if npc_type in ["trainer", "tutor", "banker"] and beard_kind == 0:
		beard_kind = 2
	return {
		"skin":       skins[h % skins.size()],
		"hair":       hairs[(h >> 5) % hairs.size()],
		"tunic_hue":  float(((h >> 7) & 0xFF)) / 255.0 * 0.20 - 0.10,
		"beard":      beard_kind,
		"girth":      (h >> 11) % 3,
	}

# ── Regional wardrobe (Phase 5c — NPC regional look) ─────────────────────────
# Kjelvik's flown colours — reused by the city guards in Monster.gd (kept in
# sync there by value, not import, since they're separate scripts).
const KJELVIK_BLUE := Color(0.20, 0.34, 0.62)
const KJELVIK_GOLD := Color(0.82, 0.66, 0.20)

## Coat / tabard drawn over the torso. `gw` is the girth offset so it matches
## the body width.
func _draw_region_body(body_c: Color, gw: float) -> void:
	match region:
		"bjorn":
			# Fisherman's oilskin smock — teal waterproof + gold suspender straps.
			var oil := Color(0.16, 0.42, 0.46)
			draw_rect(Rect2(-6.0 - gw, -5, 12.0 + gw * 2.0, 11), oil)
			draw_rect(Rect2(-6.0 - gw, -5, 12.0 + gw * 2.0, 2), oil.lightened(0.18))
			draw_line(Vector2(-3, -5), Vector2(-3, 6), Color(0.75, 0.62, 0.20), 1.4)
			draw_line(Vector2( 3, -5), Vector2( 3, 6), Color(0.75, 0.62, 0.20), 1.4)
		"frostheim":
			# Heavy fur coat — dark coat panel + thick cream fur collar and hem.
			var fur := Color(0.87, 0.85, 0.79)
			var coat := body_c.darkened(0.35)
			draw_rect(Rect2(-6.5 - gw, -5, 13.0 + gw * 2.0, 11), coat)
			draw_circle(Vector2(-4.0 - gw * 0.5, -5), 3.2, fur)
			draw_circle(Vector2( 4.0 + gw * 0.5, -5), 3.2, fur)
			draw_circle(Vector2(0, -6), 3.0, fur)
			draw_rect(Rect2(-6.5 - gw, 3.4, 13.0 + gw * 2.0, 2.2), fur)
		"kjelvik":
			# City heraldry — a blue tabard with gold trim, gold belt + emblem.
			draw_rect(Rect2(-3.5, -6, 7, 12), KJELVIK_BLUE)
			draw_rect(Rect2(-3.5, -6, 7, 1.6), KJELVIK_GOLD)
			draw_rect(Rect2(-6.0 - gw, 3, 12.0 + gw * 2.0, 1.6), KJELVIK_GOLD)
			draw_circle(Vector2(0, -1), 1.6, KJELVIK_GOLD)

## Regional headwear layered over the role hat.
func _draw_region_head(hs: float, _hr: float) -> void:
	match region:
		"bjorn":
			# Sou'wester rain hat — brim flares over the neck at the back.
			var hat := Color(0.80, 0.66, 0.18)
			draw_rect(Rect2(hs - 8, -19, 16, 5), hat)
			draw_rect(Rect2(hs - 9, -15, 18, 2.4), hat.darkened(0.12))
			draw_rect(Rect2(hs - 6, -13, 12, 3), hat.darkened(0.22))
		"frostheim":
			# Fur-lined hood ringing the head.
			var fur := Color(0.88, 0.86, 0.80)
			draw_rect(Rect2(hs - 7, -20, 14, 5), Color(0.30, 0.26, 0.22))
			draw_arc(Vector2(hs, -18), 8.5, PI, TAU, 12, fur, 2.6)
			draw_arc(Vector2(hs, -11), _hr + 2.0, PI + 0.35, TAU - 0.35, 12, fur, 3.2)
		"kjelvik":
			# City-blue cap band with a gold stripe.
			draw_rect(Rect2(hs - 7, -20, 14, 4), KJELVIK_BLUE)
			draw_rect(Rect2(hs - 7, -17, 14, 1.4), KJELVIK_GOLD)

func _draw() -> void:
	if not is_alive:
		return
	if npc_type == "worker" and npc_name_str == "Karl" and VillageArt.draw_asset(self, "karl"):
		_draw_combat_overlays()
		return
	var chars := _characteristics()
	var body_c: Color
	match npc_type:
		"shopkeeper": body_c = Color(0.22, 0.52, 0.28)   # green merchant
		"banker":     body_c = Color(0.20, 0.28, 0.60)   # dark blue formal
		"tutor":      body_c = Color(0.50, 0.30, 0.10)   # brown leather
		"trainer":    body_c = Color(0.55, 0.12, 0.10)   # red armour
		"quest":      body_c = Color(0.28, 0.48, 0.62)
		_:            body_c = Color(0.60, 0.45, 0.30)   # worker brown
	# Nudge each NPC's tunic hue so two "worker" villagers don't look
	# identical. Manual HSV shift — Color has no .rotated().
	var col_h: float = body_c.h + (chars["tunic_hue"] as float) * 0.1
	body_c = Color.from_hsv(fposmod(col_h, 1.0),
		body_c.s * 0.95, body_c.v * (0.92 + (chars["tunic_hue"] as float) * 0.1))
	var skin_c: Color = chars["skin"]
	var hair_c: Color = chars["hair"]
	var beard_kind: int = chars["beard"]
	var girth: int = chars["girth"]
	var is_moving := _idle_timer <= 0.0
	# Walking animation — both bob and arm swing only fire when actually
	# moving. An idle NPC stays planted instead of swaying on the spot.
	var swing := sin(_time * 7.0) * 0.30 if is_moving else 0.0
	var bob   := sin(_time * 9.0) * 1.6  if is_moving else 0.0
	var sway  := sin(_time * 4.5) * 0.8  if is_moving else 0.0

	# Ground shadow (stays fixed, no bob)
	_draw_ground_shadow()

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

	# Girth widens torso + head so a "broad" NPC reads as a big villager
	# vs a slim one. Signed offset so slim = -1, average = 0, broad = +1.
	var gw: float = float(girth) - 1.0

	# Legs
	draw_rect(Rect2(-5, 4, 4, 9), body_c.darkened(0.2))
	draw_rect(Rect2(1,  4, 4, 9), body_c.darkened(0.2))

	# Body — width scales with girth
	draw_rect(Rect2(-6.0 - gw, -6, 12.0 + gw * 2.0, 11), body_c)

	# Arms — either walking swing OR idle-variance pose (crossed).
	if _iv_kind == 2 and not is_moving:
		# Arms crossed across the chest — draw each arm bending inward.
		draw_line(Vector2(-6.0 - gw, -4),
			Vector2(2.0, -1.0), body_c.darkened(0.1), 3.0)
		draw_line(Vector2( 6.0 + gw, -4),
			Vector2(-2.0, -1.0), body_c.darkened(0.1), 3.0)
	else:
		draw_line(Vector2(-6.0 - gw, -4),
			Vector2(-10.0 - gw + swing * 8.0, 4.0), body_c.darkened(0.1), 3.0)
		draw_line(Vector2( 6.0 + gw, -4),
			Vector2( 10.0 + gw - swing * 8.0, 4.0), body_c.darkened(0.1), 3.0)

	# Regional coat/tabard over the torso (Phase 5c — NPC regional look). Drawn
	# after the arms so it layers on the body, before the head so the collar
	# tucks under the chin.
	_draw_region_body(body_c, gw)

	# Head — radius scales with girth; head-turn variance shifts it slightly.
	var head_shift: float = _iv_dir * 1.5 if (_iv_kind == 1 and not is_moving) else 0.0
	var head_r: float = 7.0 + gw * 0.5
	draw_circle(Vector2(head_shift, -11), head_r, skin_c)
	# Hair — rendered under the hat so hair color pokes out around the brim.
	# A simple crescent above the head reads at this scale. Head-turn
	# variance shifts hair with the head.
	draw_circle(Vector2(head_shift, -13.5), head_r * 0.85, hair_c)

	# ── Facial features ──────────────────────────────────────────────────────
	# Drawn ON TOP of the hair so eyes read on the small head. Eyes sit in the
	# mid-face band (~y -11.5): below every hat brim, above the beard line, so
	# they stay visible on hatted + bearded NPCs alike. The mouth is drawn
	# here but the beard (below) overlays it for bearded types — which is the
	# correct look. Pupils drift with the head-turn idle variance.
	var eye_y := -11.5
	var eye_dx := 2.4
	var pupil_shift := _iv_dir * 0.4 if (_iv_kind == 1 and not is_moving) else 0.0
	var eye_white := Color(0.96, 0.95, 0.90)
	var eye_dark  := Color(0.10, 0.08, 0.08)
	# Sclera
	draw_circle(Vector2(head_shift - eye_dx, eye_y), 1.3, eye_white)
	draw_circle(Vector2(head_shift + eye_dx, eye_y), 1.3, eye_white)
	# Pupils
	draw_circle(Vector2(head_shift - eye_dx + pupil_shift, eye_y), 0.75, eye_dark)
	draw_circle(Vector2(head_shift + eye_dx + pupil_shift, eye_y), 0.75, eye_dark)
	# Brows — short strokes just above the eyes, tinted from hair.
	var brow_c := hair_c.darkened(0.2)
	draw_line(Vector2(head_shift - eye_dx - 1.2, eye_y - 2.2),
		Vector2(head_shift - eye_dx + 1.2, eye_y - 2.5), brow_c, 1.0)
	draw_line(Vector2(head_shift + eye_dx - 1.2, eye_y - 2.5),
		Vector2(head_shift + eye_dx + 1.2, eye_y - 2.2), brow_c, 1.0)
	# Nose — a small vertical skin-shadow below the eyes.
	draw_line(Vector2(head_shift, eye_y + 1.2),
		Vector2(head_shift, eye_y + 3.0), skin_c.darkened(0.25), 1.0)
	# Mouth — a small line ~y -7.5. Beardless/stubble show it; short/long
	# beards (drawn next) cover it, which is the intended layering.
	if beard_kind <= 1:
		draw_line(Vector2(head_shift - 2.0, eye_y + 4.5),
			Vector2(head_shift + 2.0, eye_y + 4.5), Color(0.52, 0.26, 0.22), 1.0)

	# Beard variations. `beard_kind`: 0 none, 1 stubble, 2 short, 3 long.
	match beard_kind:
		1:
			draw_rect(Rect2(-4, -9, 8, 3), hair_c.darkened(0.15))
		2:
			draw_rect(Rect2(-5, -9, 10, 5), hair_c)
			draw_rect(Rect2(-4, -4, 8, 2), hair_c.darkened(0.1))
		3:
			draw_rect(Rect2(-5, -9, 10, 4), hair_c)
			draw_rect(Rect2(-6, -5, 12, 6), hair_c)
			draw_rect(Rect2(-4,  1, 8,  3), hair_c.darkened(0.1))

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

	# Regional headwear over the role hat — only for the "common" folk (workers
	# and generic villagers) so bankers/trainers/shopkeepers keep the hats that
	# read their trade. Most town NPCs are workers, so a town still reads
	# strongly regional ("mostly fishermen" at Bjorn's, etc.).
	if npc_type in ["worker", "quest"] or npc_type == "":
		_draw_region_head(head_shift, head_r)

	# Shop-specific accessory — the item the merchant sells, held in front
	# of the body. Reads their trade at a glance so a player can spot
	# "the smith" vs "the fishmonger" from across a plaza.
	if npc_type == "shopkeeper":
		match shop_id:
			"weapons_smith":
				# Smith's hammer — grey head + brown haft
				draw_rect(Rect2( 4, -3, 5, 6), Color(0.55, 0.55, 0.58))
				draw_rect(Rect2( 5,  3, 3, 5), Color(0.42, 0.28, 0.14))
			"fishmonger":
				# Silver fish — flat ellipse + fin + eye
				draw_colored_polygon(PackedVector2Array([
					Vector2(4, 0), Vector2(10, -2), Vector2(12, 0),
					Vector2(10, 2)]), Color(0.72, 0.78, 0.85))
				draw_colored_polygon(PackedVector2Array([
					Vector2(11, -2), Vector2(14, -4), Vector2(14, 4),
					Vector2(11, 2)]), Color(0.62, 0.68, 0.75))
				draw_circle(Vector2(6, -0.5), 0.8, Color.BLACK)
			"apothecary":
				# Green potion — bottle + neck + cork
				draw_rect(Rect2( 4, -3, 5, 6), Color(0.35, 0.62, 0.28))
				draw_rect(Rect2( 5, -5, 3, 2), Color(0.72, 0.78, 0.85, 0.55))
				draw_rect(Rect2( 5, -6, 3, 1), Color(0.45, 0.28, 0.14))
			"magic_vendor":
				# Wizard staff with rune orb
				draw_line(Vector2( 6, 6), Vector2(10, -12),
					Color(0.42, 0.28, 0.14), 2.0)
				draw_circle(Vector2(10, -12), 3.0, Color(0.55, 0.30, 0.85))
				draw_circle(Vector2(10, -12), 1.5, Color(0.85, 0.65, 1.0, 0.85))
			"general_store":
				# Coin pouch
				draw_colored_polygon(PackedVector2Array([
					Vector2(4, 1), Vector2(10, 1), Vector2(11, 5),
					Vector2(8, 8), Vector2(6, 8), Vector2(3, 5)]),
					Color(0.55, 0.36, 0.18))
				draw_rect(Rect2( 5, 0, 5, 1), Color(0.28, 0.18, 0.08))
			_:
				# Generic shopkeeper — small sack
				draw_circle(Vector2( 7, 3), 3.0, Color(0.55, 0.36, 0.18))

	# "!" quest marker
	if npc_type == "quest":
		draw_circle(Vector2(0, -28), 6, Color(1.0, 0.85, 0.10))
		draw_rect(Rect2(-1.5, -32, 3, 7), Color(0.08, 0.08, 0.08))
		draw_circle(Vector2(0, -26), 1.5, Color(0.08, 0.08, 0.08))

	# Hover indication is delivered via self_modulate (see _on_hover_enter)
	# rather than a yellow outline rect — same visual language across every
	# clickable entity in the world.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# ── Combat overlays (Phase 5b) ──
	_draw_combat_overlays()

## Soft ground shadow under the feet (no bob). Shared by the procedural drawing
## and authored art (KarlArt) so every villager stays grounded the same way.
func _draw_ground_shadow() -> void:
	draw_circle(Vector2(2.0, 15.0), 7.0, Color(0.02, 0.02, 0.04, 0.25))

func _draw_combat_overlays() -> void:
	# Red wash on a landed hit, and an HP bar that only appears once the NPC
	# has actually been wounded (an untouched villager shows nothing).
	if _hit_flash > 0.0:
		draw_circle(Vector2(0, -6), 14.0, Color(0.95, 0.15, 0.10, 0.35))
	if current_hp < max_hp:
		var w := 26.0
		var frac := clampf(float(current_hp) / float(maxi(1, max_hp)), 0.0, 1.0)
		draw_rect(Rect2(-w * 0.5, -34, w, 4), Color(0.10, 0.08, 0.06, 0.85))
		var bar_col := Color(0.35, 0.80, 0.30)
		if frac < 0.34:
			bar_col = Color(0.90, 0.25, 0.20)
		elif frac < 0.67:
			bar_col = Color(0.90, 0.75, 0.20)
		draw_rect(Rect2(-w * 0.5, -34, w * frac, 4), bar_col)
