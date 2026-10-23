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
const Fishing      = preload("res://scripts/Fishing.gd")

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
# Sea-combat consumable actions (1.6.3) — each needs a CRAFTED item; out of
# stock → toast + null (no effect, no cooldown burn).
const REPAIR_ITEM := "hull_patch"
const REPAIR_HP   := 10
const REPAIR_CD   := 6.0
const NET_ITEM    := "fishing_net"
const NET_CD      := 8.0
const BAIT_ITEM   := "chum_bucket"
const BAIT_CD     := 10.0
const BAIT_DISTRACT_SECS := 6.0
const BAIT_DMG_MULT      := 0.60   # monster deals 60% while distracted
# Weak-point / telegraph reaction layer.
const WEAK_INTERVAL  := 8.0    # a weak point opens this often
const WEAK_DURATION  := 2.5    # ...and stays exposed this long
const WEAK_MULT      := 2.0    # harpoon/cannon during it deal 2x
const TELEGRAPH_LEAD := 1.0    # wind-up warning this long before the monster hits

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
# 1.6.3 reaction layer + consumable-action state.
var _repair_cd:  float = 0.0
var _net_cd:     float = 0.0
var _bait_cd:    float = 0.0
var _weak_timer:  float = WEAK_INTERVAL   # counts down to the next weak point
var _weak_window: float = 0.0             # >0 = weak point currently exposed
var _distract:    float = 0.0             # >0 = monster damage reduced (bait)
var _monster_stunned: bool = false        # net cancels the monster's next attack
var _telegraphed: bool = false            # posted this cycle's wind-up warning
var _tackle_note: String = ""             # flavor line if equipped tackle softened the monster

# Phase 4 multi-stage boss support. `_phases` is the cloned list of phase
# trigger entries from the monster table (so we can pop already-fired ones
# without mutating the const SEA_MONSTERS dict). `_phase_idx` advances when
# a trigger fires.
var _phases:    Array = []
var _phase_idx: int   = 0

# UI
var _panel:       PanelContainer = null
var _panel_home:  Vector2 = Vector2.ZERO
var _shake:       float = 0.0   # decaying panel jitter when the hull is struck
var _boat_bar:    ProgressBar = null
var _monster_bar: ProgressBar = null
var _harpoon_btn: Button      = null
var _cannon_btn:  Button      = null
var _flee_btn:    Button      = null
var _repair_btn:  Button      = null
var _net_btn:     Button      = null
var _bait_btn:    Button      = null
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

	# 1.6.3 — a serpent-hunter lure equipped at the strike softens the monster:
	# reduce its attack by `monster_weaken` for the whole encounter.
	var td: Dictionary = Fishing.tackle_data(GameManager.equipped_bait())
	var weaken := float(td.get("monster_weaken", 0.0))
	if weaken > 0.0:
		_monster["attack"] = maxi(1, int(round(
			float(_monster.get("attack", 1)) * (1.0 - weaken))))
		_tackle_note = "Your %s cows the beast — it strikes weaker." % str(td.get("name", "lure"))

func _ready() -> void:
	layer = 240
	_build_ui()
	_append_log("[color=#888]A %s rises from the depths![/color]"
		% str(_monster.get("name", "creature")))
	if _tackle_note != "":
		_append_log("[color=#7ad874]%s[/color]" % _tackle_note)
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
	_panel = panel
	_panel_home = panel.position

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

	# Consumable actions (1.6.3) — each needs a crafted item.
	var btn_row2 := HBoxContainer.new()
	btn_row2.add_theme_constant_override("separation", 6)
	vb.add_child(btn_row2)
	_repair_btn = _action_button("🔨 Repair")
	_repair_btn.pressed.connect(_on_repair)
	btn_row2.add_child(_repair_btn)
	_net_btn = _action_button("🕸 Net")
	_net_btn.pressed.connect(_on_net)
	btn_row2.add_child(_net_btn)
	_bait_btn = _action_button("🦞 Chum")
	_bait_btn.pressed.connect(_on_bait)
	btn_row2.add_child(_bait_btn)

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
	_harpoon_cd = maxf(0.0, _harpoon_cd - delta)
	_cannon_cd  = maxf(0.0, _cannon_cd  - delta)
	_repair_cd  = maxf(0.0, _repair_cd  - delta)
	_net_cd     = maxf(0.0, _net_cd     - delta)
	_bait_cd    = maxf(0.0, _bait_cd    - delta)
	_distract   = maxf(0.0, _distract   - delta)
	# Weak-point window opens periodically and stays exposed a short while.
	if _weak_window > 0.0:
		_weak_window = maxf(0.0, _weak_window - delta)
	else:
		_weak_timer -= delta
		if _weak_timer <= 0.0:
			_weak_timer = WEAK_INTERVAL
			_weak_window = WEAK_DURATION
			_append_log("[color=#8fe0ff]✨ Weak point exposed — strike now![/color]")
	# Decaying hull-hit shake.
	if _panel != null:
		if _shake > 0.0:
			_shake = maxf(0.0, _shake - delta)
			var mag := _shake * 20.0
			_panel.position = _panel_home + Vector2(
				randf_range(-mag, mag), randf_range(-mag, mag))
		elif _panel.position != _panel_home:
			_panel.position = _panel_home
	_refresh_buttons()

	# Monster telegraphs its wind-up, then strikes (unless netted).
	_monster_cd -= delta
	if _monster_cd <= TELEGRAPH_LEAD and not _telegraphed and not _monster_stunned:
		_telegraphed = true
		_append_log("[color=#ffb060]⚠ %s rears back to strike![/color]"
			% str(_monster.get("name", "creature")))
	if _monster_cd <= 0.0:
		_monster_cd = MONSTER_COOLDOWN
		_telegraphed = false
		if _monster_stunned:
			_monster_stunned = false
			_append_log("[color=#8fe0ff]The snared %s can't strike![/color]"
				% str(_monster.get("name", "creature")))
		else:
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
	_refresh_consumable(_repair_btn, _repair_cd, "🔨 Repair", REPAIR_ITEM)
	_refresh_consumable(_net_btn, _net_cd, "🕸 Net", NET_ITEM)
	_refresh_consumable(_bait_btn, _bait_cd, "🦞 Chum", BAIT_ITEM)

## Consumable-action button: shows the cooldown while ticking, else the crafted
## stock count. Left clickable at 0 stock so the click can toast "craft more".
func _refresh_consumable(btn: Button, cd: float, label: String, item_id: String) -> void:
	if btn == null:
		return
	if cd > 0.0:
		btn.disabled = true
		btn.text = "%s (%.1fs)" % [label, cd]
	else:
		btn.disabled = false
		btn.text = "%s ×%d" % [label, GameManager.get_item_qty(item_id)]

func _on_harpoon() -> void:
	if _done or _harpoon_cd > 0.0:
		return
	var base: float = float(HARPOON_BASE_DMG) + float(_melee_lv) * HARPOON_PER_MELEE_LV
	var dmg := _apply_random(base)
	var raw_def := int(_monster.get("defense", 0))
	dmg = maxi(1, dmg - raw_def)
	dmg = _weakpoint_bonus(dmg)
	AudioManager.play_sfx("arrow_impact", 0.3)
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
	dmg = _weakpoint_bonus(dmg)
	AudioManager.play_sfx("magic_hit", 0.2)
	_apply_monster_damage(dmg, "cannon")
	_cannon_cd = CANNON_COOLDOWN

## Double damage + consume the weak-point window if one is currently exposed.
func _weakpoint_bonus(dmg: int) -> int:
	if _weak_window <= 0.0:
		return dmg
	_weak_window = 0.0
	AudioManager.play_ui("craft_success")
	_append_log("[color=#8fe0ff]Weak point struck — double damage![/color]")
	return int(round(float(dmg) * WEAK_MULT))

## Consume one crafted item for an action; false (with a toast) if none held.
func _consume(item_id: String, plural_label: String) -> bool:
	if GameManager.get_item_qty(item_id) <= 0:
		Events.top_toast.emit("Out of %s — craft more!" % plural_label)
		return false
	GameManager.remove_item_qty(item_id, 1)
	return true

func _on_repair() -> void:
	if _done or _repair_cd > 0.0:
		return
	if not _consume(REPAIR_ITEM, "Hull Patches"):
		return
	_boat_hp = mini(_boat_max_hp, _boat_hp + REPAIR_HP)
	if _boat_bar != null:
		_boat_bar.value = _boat_hp
	GameManager.current_boat_hp = _boat_hp
	Events.boat_hp_changed.emit(_boat_hp, _boat_max_hp)
	AudioManager.play_sfx("wood_chop", 0.3)
	_append_log("[color=#7ad874]🔨 You patch the hull (+%d).[/color]" % REPAIR_HP)
	_repair_cd = REPAIR_CD

func _on_net() -> void:
	if _done or _net_cd > 0.0:
		return
	if not _consume(NET_ITEM, "Fishing Nets"):
		return
	_monster_stunned = true
	AudioManager.play_sfx("fishing_cast", 0.2)
	_append_log("[color=#8fe0ff]🕸 You cast the net — the beast is snared![/color]")
	_net_cd = NET_CD

func _on_bait() -> void:
	if _done or _bait_cd > 0.0:
		return
	if not _consume(BAIT_ITEM, "Chum Buckets"):
		return
	_distract = BAIT_DISTRACT_SECS
	AudioManager.play_sfx("fishing_cast", -0.2)
	_append_log("[color=#8fe0ff]🦞 You chum the water — the %s is distracted![/color]"
		% str(_monster.get("name", "creature")))
	_bait_cd = BAIT_CD

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
	if _distract > 0.0:   # chummed water — the monster's blow is weaker
		dmg = maxi(1, int(round(float(dmg) * BAIT_DMG_MULT)))
	_boat_hp = maxi(0, _boat_hp - dmg)
	if _boat_bar != null:
		_boat_bar.value = _boat_hp
	# Push the new hull state out so Player.gd's floating HP bar reflects the
	# hit in real-time (queue_redraw happens via the regular sailing-physics
	# loop, but the signal keeps the bar honest if that loop ever skips).
	GameManager.current_boat_hp = _boat_hp
	Events.boat_hp_changed.emit(_boat_hp, _boat_max_hp)
	AudioManager.play_sfx("melee_hit", 0.2)
	_shake = 0.3   # jolt the modal when the hull takes a hit
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
	if outcome == "win":
		AudioManager.play_ui("quest_complete")
	elif outcome == "lose":
		AudioManager.play_sfx("melee_hit", -0.3, 2.0)
	if _harpoon_btn != null: _harpoon_btn.disabled = true
	if _cannon_btn  != null: _cannon_btn.disabled  = true
	if _flee_btn    != null: _flee_btn.disabled    = true
	if _repair_btn  != null: _repair_btn.disabled  = true
	if _net_btn     != null: _net_btn.disabled     = true
	if _bait_btn    != null: _bait_btn.disabled    = true
	await get_tree().create_timer(OUTRO_SECS).timeout
	Events.sea_combat_ended.emit(_monster_type, outcome)
	queue_free()
