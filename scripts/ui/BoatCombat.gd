extends CanvasLayer

## Phase 3 of the fishing rework. Modal that runs a single sea-monster
## encounter against the player's current boat. Spawn shape:
##
##   var bc := preload("res://scripts/ui/BoatCombat.gd").new()
##   bc.setup(monster_type)
##   get_tree().current_scene.add_child(bc)
##
## Lifecycle: input is captured by the modal for as long as it lives. Real-time
## with per-action cooldowns — the player picks Harpoon / Cannon / Flee, each
## with its own grey-out timer; the monster auto-attacks on its own cooldown.
## Combat ends in one of three outcomes which propagate via `sea_combat_ended`:
##   "win"   — monster hp reached zero. Caller grants loot + xp.
##   "flee"  — player escape roll succeeded. Caller does nothing.
##   "lose"  — boat hp reached zero. Caller damages the player + clears boat.

const UITheme      = preload("res://scripts/ui/UITheme.gd")
const SeaMonsters  = preload("res://scripts/SeaMonsters.gd")
const Boats        = preload("res://scripts/Boat.gd")

# Tuning. Cooldowns in seconds. Damages are pre-armor / pre-randomization.
const HARPOON_COOLDOWN := 1.5
const HARPOON_BASE_DMG := 6
const HARPOON_PER_MELEE_LV := 0.40
const CANNON_COOLDOWN  := 4.0
const MONSTER_COOLDOWN := 2.5
const FLEE_BASE_CHANCE := 0.50
const FLEE_PER_SPEED   := 0.30   # added per (boat_speed - 1.0) point
const OUTRO_SECS       := 1.2
const DMG_RANDOM_RANGE := 0.20   # ±20% on every damage roll

# State
var _monster_type: String = ""
var _monster:      Dictionary = {}
var _boat_id:      String = ""
var _boat:         Dictionary = {}

var _boat_max_hp:    int = 30
var _boat_hp:        int = 30
var _boat_armor:     int = 0
var _monster_max_hp: int = 30
var _monster_hp:     int = 30
var _melee_lv:       int = 1

var _harpoon_cd: float = 0.0
var _cannon_cd:  float = 0.0
var _monster_cd: float = MONSTER_COOLDOWN
var _done:       bool  = false

# Phase 4 multi-stage boss support. `_phases` is the cloned list of phase
# trigger entries from the monster table (so we can pop already-fired ones
# without mutating the const SEA_MONSTERS dict). `_phase_idx` advances when
# a trigger fires.
var _phases:    Array = []
var _phase_idx: int   = 0

# UI
var _boat_bar:    ProgressBar = null
var _monster_bar: ProgressBar = null
var _harpoon_btn: Button      = null
var _cannon_btn:  Button      = null
var _flee_btn:    Button      = null
var _log:         RichTextLabel = null
var _log_lines:   Array = []

## Call before adding to the tree. Sets the monster + reads the player's
## current boat from GameManager.
func setup(monster_type: String) -> void:
	_monster_type = monster_type
	# `SeaMonsters.data()` returns a reference to the const table. Clone it
	# so phase-trigger stat shifts (atk_mult / def_mult) don't permanently
	# mutate the table — otherwise every subsequent encounter would inherit
	# the previous boss's enrage stats.
	_monster = (SeaMonsters.data(monster_type) as Dictionary).duplicate(true)
	_phases = (_monster.get("phases", []) as Array).duplicate()
	_phase_idx = 0
	_boat_id = GameManager.current_boat
	_boat = Boats.data(_boat_id)
	_melee_lv = GameManager.get_skill_level("melee")

	_boat_max_hp = int(_boat.get("hp", 30))
	# Persisted HP survives between encounters within a sailing session.
	# Fall back to max if it's unset (first encounter) or invalid (would only
	# happen if a launch path forgot to seed it — defensive).
	var persisted: int = GameManager.current_boat_hp
	_boat_hp = persisted if persisted > 0 and persisted <= _boat_max_hp else _boat_max_hp
	GameManager.current_boat_max_hp = _boat_max_hp
	GameManager.current_boat_hp     = _boat_hp
	_boat_armor  = int(_boat.get("armor", 0))

	_monster_max_hp = int(_monster.get("max_hp", 30))
	_monster_hp     = _monster_max_hp

func _ready() -> void:
	layer = 240
	_build_ui()
	_append_log("[color=#888]A %s rises from the depths![/color]"
		% str(_monster.get("name", "creature")))
	set_process(true)

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.color = Color(0, 0, 0, 0.45)
	add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UITheme.sb(UITheme.BG, UITheme.GOLD, 3))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(420, 0)
	panel.position = Vector2(-210, -160)
	bg.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "⚔  Sea Encounter — %s  (Lv %d)" % [
		str(_monster.get("name", "?")), int(_monster.get("level", 0))]
	title.add_theme_color_override("font_color", UITheme.GOLD)
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	vb.add_child(_label_dim("Your boat — %s" % str(_boat.get("name", _boat_id))))
	_boat_bar = ProgressBar.new()
	_boat_bar.max_value = _boat_max_hp
	_boat_bar.value     = _boat_hp
	_boat_bar.show_percentage = false
	_boat_bar.custom_minimum_size = Vector2(400, 18)
	_boat_bar.add_theme_stylebox_override("fill",
		_bar_fill(Color(0.70, 0.55, 0.30)))   # hull = wood
	_boat_bar.add_theme_stylebox_override("background", _bar_bg())
	vb.add_child(_boat_bar)

	vb.add_child(_label_dim("Monster"))
	_monster_bar = ProgressBar.new()
	_monster_bar.max_value = _monster_max_hp
	_monster_bar.value     = _monster_hp
	_monster_bar.show_percentage = false
	_monster_bar.custom_minimum_size = Vector2(400, 18)
	_monster_bar.add_theme_stylebox_override("fill",
		_bar_fill(Color(0.65, 0.20, 0.25)))   # blood
	_monster_bar.add_theme_stylebox_override("background", _bar_bg())
	vb.add_child(_monster_bar)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	vb.add_child(btn_row)
	_harpoon_btn = _action_button("Harpoon")
	_harpoon_btn.pressed.connect(_on_harpoon)
	btn_row.add_child(_harpoon_btn)
	_cannon_btn = _action_button("Cannon")
	_cannon_btn.pressed.connect(_on_cannon)
	if int(_boat.get("cannon_dmg", 0)) <= 0:
		_cannon_btn.disabled = true
		_cannon_btn.tooltip_text = "%s has no cannons." % str(_boat.get("name", _boat_id))
	btn_row.add_child(_cannon_btn)
	_flee_btn = _action_button("Flee")
	_flee_btn.pressed.connect(_on_flee)
	btn_row.add_child(_flee_btn)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.fit_content = true
	_log.scroll_active = true
	_log.custom_minimum_size = Vector2(400, 84)
	_log.add_theme_color_override("default_color", Color(0.85, 0.82, 0.70))
	vb.add_child(_log)

func _label_dim(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.DIM)
	l.add_theme_font_size_override("font_size", 11)
	return l

func _action_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 28)
	b.add_theme_stylebox_override("normal",
		UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 2))
	b.add_theme_stylebox_override("hover",
		UITheme.sb(UITheme.BTN_H, UITheme.BORDER, 2))
	b.add_theme_stylebox_override("pressed",
		UITheme.sb(UITheme.BTN_A, UITheme.GOLD, 2))
	b.add_theme_stylebox_override("disabled",
		UITheme.sb(UITheme.BTN_N, UITheme.DIM, 1))
	b.add_theme_color_override("font_color", UITheme.GOLD)
	return b

func _bar_fill(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.corner_radius_top_left     = 2
	sb.corner_radius_top_right    = 2
	sb.corner_radius_bottom_left  = 2
	sb.corner_radius_bottom_right = 2
	return sb

func _bar_bg() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.BTN_N
	sb.border_color = UITheme.BORDER
	sb.set_border_width_all(1)
	return sb

func _append_log(line: String) -> void:
	_log_lines.append(line)
	# Keep the last 5 lines so the panel doesn't grow unbounded.
	while _log_lines.size() > 5:
		_log_lines.pop_front()
	if _log != null:
		_log.text = "\n".join(_log_lines)

func _process(delta: float) -> void:
	if _done:
		return
	# Player cooldowns tick down; button enabled state mirrors the timer.
	if _harpoon_cd > 0.0:
		_harpoon_cd = maxf(0.0, _harpoon_cd - delta)
	if _cannon_cd > 0.0:
		_cannon_cd = maxf(0.0, _cannon_cd - delta)
	_refresh_buttons()

	# Monster auto-attacks on its own cooldown.
	_monster_cd -= delta
	if _monster_cd <= 0.0:
		_monster_cd = MONSTER_COOLDOWN
		_monster_attacks()

func _refresh_buttons() -> void:
	if _harpoon_btn != null:
		var hcool := _harpoon_cd > 0.0
		_harpoon_btn.disabled = hcool
		_harpoon_btn.text = ("Harpoon  (%.1fs)" % _harpoon_cd) if hcool else "Harpoon"
	if _cannon_btn != null and int(_boat.get("cannon_dmg", 0)) > 0:
		var ccool := _cannon_cd > 0.0
		_cannon_btn.disabled = ccool
		_cannon_btn.text = ("Cannon  (%.1fs)" % _cannon_cd) if ccool else "Cannon"

func _on_harpoon() -> void:
	if _done or _harpoon_cd > 0.0:
		return
	var base: float = float(HARPOON_BASE_DMG) + float(_melee_lv) * HARPOON_PER_MELEE_LV
	var dmg := _apply_random(base)
	var raw_def := int(_monster.get("defense", 0))
	dmg = maxi(1, dmg - raw_def)
	_apply_monster_damage(dmg, "harpoon")
	_harpoon_cd = HARPOON_COOLDOWN

func _on_cannon() -> void:
	if _done or _cannon_cd > 0.0:
		return
	var cd := int(_boat.get("cannon_dmg", 0))
	if cd <= 0:
		return
	var dmg := _apply_random(float(cd))
	var raw_def := int(_monster.get("defense", 0))
	dmg = maxi(1, dmg - raw_def)
	_apply_monster_damage(dmg, "cannon")
	_cannon_cd = CANNON_COOLDOWN

func _on_flee() -> void:
	if _done:
		return
	var boat_speed := float(_boat.get("speed", 1.0))
	# Bosses are committed encounters — base flee chance drops to 0.10 and
	# the speed bonus is halved. A dragonship (speed 2.0) caps at 0.25
	# instead of the random-encounter 0.95. Don't pick the fight if you
	# don't intend to finish it.
	var is_boss := bool(_monster.get("boss", false))
	var chance: float
	if is_boss:
		chance = clampf(0.10 + (boat_speed - 1.0) * 0.15, 0.05, 0.50)
	else:
		chance = clampf(FLEE_BASE_CHANCE + (boat_speed - 1.0) * FLEE_PER_SPEED,
			0.10, 0.95)
	if randf() < chance:
		_append_log("[color=#7ad874]You break away from the encounter![/color]")
		_end("flee")
	else:
		_append_log("[color=#d87a7a]You fail to escape![/color]")
		# Failed flee gives the monster an immediate free attack.
		_monster_attacks()

func _apply_monster_damage(dmg: int, label: String) -> void:
	_monster_hp = maxi(0, _monster_hp - dmg)
	if _monster_bar != null:
		_monster_bar.value = _monster_hp
	_append_log("You %s the %s for [color=#ffe066]%d[/color]." % [
		label, str(_monster.get("name", "creature")), dmg])
	_check_phase_triggers()
	if _monster_hp <= 0:
		_append_log("[color=#7ad874]You defeat the %s![/color]"
			% str(_monster.get("name", "creature")))
		_end("win")

## Phase 4 boss support — fire every queued phase whose `trigger_pct` the
## monster has dropped below. Apply the multiplier to the cloned `_monster`
## stats (so cannon defense math sees the new value next swing) and post the
## phase's flavor message to the combat log. Multipliers compound if multiple
## triggers fire in the same hit (only realistic with one-shot megahits).
func _check_phase_triggers() -> void:
	if _monster_max_hp <= 0:
		return
	while _phase_idx < _phases.size():
		var p: Dictionary = _phases[_phase_idx]
		var threshold := float(p.get("trigger_pct", 0.0))
		var current := float(_monster_hp) / float(_monster_max_hp)
		if current > threshold:
			break
		var atk_mult: float = float(p.get("atk_mult", 1.0))
		var def_mult: float = float(p.get("def_mult", 1.0))
		_monster["attack"]  = int(round(float(_monster.get("attack",  1)) * atk_mult))
		_monster["defense"] = int(round(float(_monster.get("defense", 0)) * def_mult))
		_append_log("[color=#ffa040]%s[/color]" % str(p.get("msg", "Phase change!")))
		_phase_idx += 1

func _monster_attacks() -> void:
	if _done:
		return
	var raw := int(_monster.get("attack", 1))
	var dmg := _apply_random(float(raw))
	dmg = maxi(1, dmg - _boat_armor)
	_boat_hp = maxi(0, _boat_hp - dmg)
	if _boat_bar != null:
		_boat_bar.value = _boat_hp
	# Push the new hull state out so Player.gd's floating HP bar reflects the
	# hit in real-time (queue_redraw happens via the regular sailing-physics
	# loop, but the signal keeps the bar honest if that loop ever skips).
	GameManager.current_boat_hp = _boat_hp
	Events.boat_hp_changed.emit(_boat_hp, _boat_max_hp)
	_append_log("[color=#d87a7a]%s strikes your hull for %d.[/color]" % [
		str(_monster.get("name", "creature")), dmg])
	if _boat_hp <= 0:
		_append_log("[color=#d87a7a]Your boat is sinking![/color]")
		_end("lose")

func _apply_random(base: float) -> int:
	var lo := base * (1.0 - DMG_RANDOM_RANGE)
	var hi := base * (1.0 + DMG_RANDOM_RANGE)
	return int(round(randf_range(lo, hi)))

func _end(outcome: String) -> void:
	_done = true
	if _harpoon_btn != null: _harpoon_btn.disabled = true
	if _cannon_btn  != null: _cannon_btn.disabled  = true
	if _flee_btn    != null: _flee_btn.disabled    = true
	await get_tree().create_timer(OUTRO_SECS).timeout
	Events.sea_combat_ended.emit(_monster_type, outcome)
	queue_free()
