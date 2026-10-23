extends CanvasLayer
## OpeningPrologue — the first-login storybook: "VikingVale's History".
##
## A Viking-themed book opens; pages 1–6 turn (parchment + an illustration slot +
## the skald's narration + a per-page VO slot). After page 6 the page goes WHITE,
## the white dissolves to the real shore at Bjorn's Landing, and a slow camera pan
## up-and-out settles into the normal gameplay camera as control hands over.
##
## SELF-CONTAINED + drop-in later:
##   • Page art  — drop `res://assets/prologue/page_1.png … page_6.png` (any size);
##                 until then a labelled parchment placeholder is drawn.
##   • Narration VO — drop `res://assets/vo/narrator/opening_p1.ogg … opening_p7.ogg`;
##                 until then the pages are silent and self-paced.
## Both are optional — the prologue plays correctly with neither.
##
## Renders identically in 2D and 3D (it's a CanvasLayer). The camera pan needs a
## Camera2D (2D client); in 3D it gracefully degrades to the white→shore dissolve
## with no pan. Skippable (Esc / the Skip button). Shown once per account — World
## gates it on a `user://prologue.cfg` flag keyed by username.

signal finished

const UITheme := preload("res://scripts/ui/UITheme.gd")

# Storybook palette (parchment + leather + ink), gold accents borrowed from UITheme.
const _PARCH    := Color(0.90, 0.83, 0.65)
const _PARCH_DK := Color(0.80, 0.71, 0.52)
const _INK      := Color(0.19, 0.13, 0.07)
const _INK_DIM  := Color(0.40, 0.31, 0.20)
const _LEATHER  := Color(0.22, 0.13, 0.06)
# The shore reveal's CAMERA work is owned by whichever world plays the prologue —
# World.play_shore_cinematic (2D Camera2D pan) or World3D.play_shore_cinematic (3D
# flythrough). The book, the white dissolve, and the closing caption live here; the
# world calls `cinematic_done()` back when its camera settles (unless it switches
# scenes, e.g. the 3D intro handing off to the 2D client).

const _STATE_COVER  := 0
const _STATE_PAGE   := 1
const _STATE_REVEAL := 2
const _STATE_DONE    := 3

const _ROMAN := ["I", "II", "III", "IV", "V", "VI"]

# Exact narration (VO_SCRIPT.md §0). bbcode for the emphasised words.
const _PAGES: Array[String] = [
	"The land was old before the first Viking drew breath. The dragons remember its true age. We remember only what we were told — and even that, we have begun to forget.",
	"Five hundred winters ago, a king took a crown by the blade. He conquered every hold, bent all the Vikings to one will, and named himself lord of the whole world.",
	"But a world held whole is a world that wakes what should sleep. The deep earth opened beneath him — and [b]Ginnungr, the World-Maw[/b], rose to swallow all he had taken. His kingdom lasted a single, screaming season.",
	"When it ended, the truth went into the ground with him. Broken and afraid, the Vikings needed something to hate — and blamed the trolls and the dragons for a doom their own king had earned. So began the long war.",
	"Only a hundred and twenty winters past did the fighting cool to an uneasy quiet. The dragons are feared still; the trolls, less so. And the true enemy sleeps on, forgotten, in the deep.",
	"The High Seat has stood empty ever since — the throne no one dares take. For the land learned its lesson: it does not need a king to [i]rule[/i] it. It waits for one to [i]lead[/i] it.",
]

# The closing line, read over the white → shore dissolve (page 7).
const _FINAL_LINE := "And now the tide brings a stranger to these shores — no name in the sagas, no crown, no claim. Only a chance: to gather what was scattered, to earn what cannot be seized. Rise, outlander. The Seat is waiting.  [b]Only time will show what you have.[/b]"

# One-line hint per page — tells whoever draws the art what belongs in the frame.
const _ART_HINT: Array[String] = [
	"the old world at dawn, wreathed in mist",
	"a crown taken by the blade — five banners, one throne",
	"the earth splits; the World-Maw rises in fire",
	"ash settles; spears turned on troll and dragon",
	"a frozen battlefield; a dragon's shadow passing",
	"the cracked High Seat, empty, in a shaft of light",
]

var _state: int = _STATE_COVER
var _page: int = 0

var _cover_panel: PanelContainer = null
var _page_panel: PanelContainer = null
var _num_lbl: Label = null
var _art_frame: Panel = null
var _art_tex: TextureRect = null
var _art_ph: VBoxContainer = null
var _art_ph_num: Label = null
var _art_ph_cap: Label = null
var _text_lbl: RichTextLabel = null
var _hint_lbl: Label = null
var _skip_btn: Button = null
var _backdrop: ColorRect = null
var _white: ColorRect = null
var _final: PanelContainer = null
var _final_txt: RichTextLabel = null
var _vo: AudioStreamPlayer = null

var _hud: CanvasLayer = null
var _page_tween: Tween = null

# Intro/DIRECTOR mode: when World starts the first-login intro it adds this prologue to
# the tree ROOT (not to a world) and calls start_intro(), so it survives the scene
# switches and can mask each load behind the book / white. It drives 2D→3D (load behind
# the book) → 3D flythrough → 3D→2D (load behind white) → backstory → play. Replay mode
# (_intro_mode=false, added to a world) just plays in place with no scene switching.
var _intro_mode: bool = false
var _intro_player_pos: Vector2 = Vector2.ZERO
var _pref_3d: bool = false
var _uname: String = "_offline"
var _reached_reveal: bool = false
var _world_3d_ready: bool = false
var _awaiting: int = 0   # 0 none · 1 waiting for the 3D build · 2 waiting for the 2D build

func _ready() -> void:
	layer = 250
	set_process_input(true)
	_build()
	# Hide the game HUD for the whole prologue (the book covers it anyway; this keeps
	# the health globe / minimap / a replay's Settings tab off the shore cinematic).
	_hud = get_tree().get_first_node_in_group("hud") as CanvasLayer
	if _hud != null:
		_hud.visible = false
	_show_cover()

# ── UI construction ──────────────────────────────────────────────────────────
func _build() -> void:
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.02, 0.015, 0.01, 1.0)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_build_cover(center)
	_build_page(center)

	# Skip — top-right.
	_skip_btn = Button.new()
	_skip_btn.text = "Skip  ⏭"
	_skip_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_N, UITheme.BORDER, 2))
	_skip_btn.add_theme_stylebox_override("hover", UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 2))
	_skip_btn.add_theme_stylebox_override("pressed", UITheme.sb(UITheme.BTN_A, UITheme.GOLD, 2))
	_skip_btn.add_theme_color_override("font_color", UITheme.TEXT)
	_skip_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_skip_btn.offset_left = -128.0
	_skip_btn.offset_top = 16.0
	_skip_btn.offset_right = -16.0
	_skip_btn.offset_bottom = 48.0
	_skip_btn.pressed.connect(_on_skip)
	add_child(_skip_btn)

	# White dissolve layer (above the book, below the final caption).
	_white = ColorRect.new()
	_white.set_anchors_preset(Control.PRESET_FULL_RECT)
	_white.color = Color(1, 1, 1, 1)
	_white.modulate.a = 0.0
	_white.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_white)

	_build_final()

	_vo = AudioStreamPlayer.new()
	_vo.bus = "Master"
	add_child(_vo)

func _build_cover(parent: Node) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(_LEATHER, UITheme.GOLD, 5))
	panel.custom_minimum_size = Vector2(560, 380)
	parent.add_child(panel)
	_cover_panel = panel

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 18)
	panel.add_child(vb)

	var knot := Label.new()
	knot.text = "❦"
	knot.add_theme_color_override("font_color", UITheme.GOLD)
	knot.add_theme_font_size_override("font_size", 34)
	knot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(knot)

	var title := Label.new()
	title.text = "VikingVale's History"
	title.add_theme_color_override("font_color", UITheme.GOLD)
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var sub := Label.new()
	sub.text = "— a saga half the world has forgotten —"
	sub.add_theme_color_override("font_color", Color(0.78, 0.66, 0.40))
	sub.add_theme_font_size_override("font_size", 15)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 18)
	vb.add_child(spacer)

	var open_btn := Button.new()
	open_btn.text = "Open the book  ❯"
	open_btn.add_theme_stylebox_override("normal", UITheme.sb(UITheme.BTN_A, UITheme.GOLD, 2))
	open_btn.add_theme_stylebox_override("hover", UITheme.sb(UITheme.BTN_H, UITheme.GOLD, 3))
	open_btn.add_theme_stylebox_override("pressed", UITheme.sb(UITheme.BTN_N, UITheme.GOLD, 2))
	open_btn.add_theme_color_override("font_color", UITheme.GOLD)
	open_btn.add_theme_font_size_override("font_size", 18)
	open_btn.custom_minimum_size = Vector2(220, 44)
	open_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	open_btn.pressed.connect(_advance)
	vb.add_child(open_btn)

	var hint := Label.new()
	hint.text = "click  ·  space"
	hint.add_theme_color_override("font_color", Color(0.60, 0.50, 0.30))
	hint.add_theme_font_size_override("font_size", 12)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)

func _build_page(parent: Node) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(_PARCH, _LEATHER, 4))
	panel.custom_minimum_size = Vector2(640, 560)
	panel.visible = false
	parent.add_child(panel)
	_page_panel = panel

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	margin.add_child(vb)

	var header := Label.new()
	header.text = "❦   The Saga of VikingVale   ❦"
	header.add_theme_color_override("font_color", _INK_DIM)
	header.add_theme_font_size_override("font_size", 14)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(header)

	# Illustration slot: a bordered parchment frame; texture if present, else a hint.
	_art_frame = Panel.new()
	_art_frame.add_theme_stylebox_override("panel", UITheme.sb(_PARCH_DK, _INK_DIM, 2))
	_art_frame.custom_minimum_size = Vector2(560, 300)
	vb.add_child(_art_frame)

	_art_tex = TextureRect.new()
	_art_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	_art_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_art_tex.visible = false
	_art_frame.add_child(_art_tex)

	_art_ph = VBoxContainer.new()
	_art_ph.set_anchors_preset(Control.PRESET_FULL_RECT)
	_art_ph.alignment = BoxContainer.ALIGNMENT_CENTER
	_art_ph.add_theme_constant_override("separation", 6)
	_art_ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art_frame.add_child(_art_ph)

	_art_ph_num = Label.new()
	_art_ph_num.add_theme_color_override("font_color", Color(_INK_DIM.r, _INK_DIM.g, _INK_DIM.b, 0.55))
	_art_ph_num.add_theme_font_size_override("font_size", 88)
	_art_ph_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_art_ph.add_child(_art_ph_num)

	_art_ph_cap = Label.new()
	_art_ph_cap.add_theme_color_override("font_color", _INK_DIM)
	_art_ph_cap.add_theme_font_size_override("font_size", 14)
	_art_ph_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_art_ph_cap.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_art_ph_cap.custom_minimum_size = Vector2(500, 0)
	_art_ph.add_child(_art_ph_cap)

	_num_lbl = Label.new()
	_num_lbl.add_theme_color_override("font_color", _INK_DIM)
	_num_lbl.add_theme_font_size_override("font_size", 15)
	_num_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_num_lbl)

	_text_lbl = RichTextLabel.new()
	_text_lbl.bbcode_enabled = true
	_text_lbl.fit_content = true
	_text_lbl.scroll_active = false
	_text_lbl.custom_minimum_size = Vector2(560, 120)
	_text_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text_lbl.add_theme_color_override("default_color", _INK)
	_text_lbl.add_theme_font_size_override("normal_font_size", 18)
	_text_lbl.add_theme_font_size_override("bold_font_size", 18)
	_text_lbl.add_theme_font_size_override("italics_font_size", 18)
	vb.add_child(_text_lbl)

	_hint_lbl = Label.new()
	_hint_lbl.text = "click / space to turn the page   ·   Esc to skip"
	_hint_lbl.add_theme_color_override("font_color", Color(0.50, 0.41, 0.26))
	_hint_lbl.add_theme_font_size_override("font_size", 12)
	_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_hint_lbl)

func _build_final() -> void:
	_final = PanelContainer.new()
	_final.add_theme_stylebox_override("panel", UITheme.sb(Color(0.03, 0.02, 0.01, 0.62), Color(0.64, 0.49, 0.14, 0.55), 2))
	_final.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_final.offset_left = 60.0
	_final.offset_right = -60.0
	_final.offset_top = -190.0
	_final.offset_bottom = -54.0
	_final.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_final.modulate.a = 0.0
	_final.visible = false
	add_child(_final)

	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 22)
	m.add_theme_constant_override("margin_right", 22)
	m.add_theme_constant_override("margin_top", 14)
	m.add_theme_constant_override("margin_bottom", 14)
	_final.add_child(m)

	_final_txt = RichTextLabel.new()
	_final_txt.bbcode_enabled = true
	_final_txt.fit_content = true
	_final_txt.scroll_active = false
	_final_txt.add_theme_color_override("default_color", Color(0.96, 0.90, 0.70))
	_final_txt.add_theme_font_size_override("normal_font_size", 18)
	_final_txt.add_theme_font_size_override("bold_font_size", 19)
	_final_txt.text = "[center]" + _FINAL_LINE + "[/center]"
	m.add_child(_final_txt)

# ── Flow ───────────────────────────────────────────────────────────────────
func _show_cover() -> void:
	_state = _STATE_COVER
	_cover_panel.visible = true
	_page_panel.visible = false
	_fade_in(_cover_panel, 0.6)

func _advance() -> void:
	if _state == _STATE_COVER:
		_cover_panel.visible = false
		_page_panel.visible = true
		_state = _STATE_PAGE
		_page = 1
		_show_page()
	elif _state == _STATE_PAGE:
		if _page >= _PAGES.size():
			_begin_reveal()
		else:
			_page += 1
			_show_page()

func _show_page() -> void:
	var idx := _page - 1
	_num_lbl.text = "~  %s  ~" % _ROMAN[idx]
	_text_lbl.text = "[center]" + _PAGES[idx] + "[/center]"

	var tex_path := "res://assets/prologue/page_%d.png" % _page
	if ResourceLoader.exists(tex_path):
		var tex := load(tex_path) as Texture2D
		_art_tex.texture = tex
		_art_tex.visible = true
		_art_ph.visible = false
	else:
		_art_tex.visible = false
		_art_ph.visible = true
		_art_ph_num.text = _ROMAN[idx]
		_art_ph_cap.text = _ART_HINT[idx]

	_fade_in(_page_panel, 0.4)
	_play_vo(_page)

func _begin_reveal() -> void:
	if _state == _STATE_REVEAL or _state == _STATE_DONE:
		return
	_state = _STATE_REVEAL
	_skip_btn.visible = false
	_hint_lbl.visible = false
	if _page_tween != null and _page_tween.is_valid():
		_page_tween.kill()
	var t := create_tween()
	t.tween_property(_white, "modulate:a", 1.0, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _intro_mode:
		t.tween_callback(_on_reveal_reached)   # wait for the 3D world (loaded behind the book)
	else:
		t.tween_callback(_do_shore)

func _do_shore() -> void:
	# Book + backdrop hidden UNDER the opaque white; the world now shows through.
	_backdrop.visible = false
	_cover_panel.visible = false
	_page_panel.visible = false
	_final.visible = true
	_final.modulate.a = 0.0
	_play_vo(7)

	# The shore reveal's CAMERA is the world's job (2D pan / 3D flythrough). Reveal the
	# scene + fade the closing line up; the world drives its camera and calls
	# cinematic_done() when it settles — OR switches scenes and frees us (3D intro → 2D).
	var world := get_tree().current_scene
	if world != null and world.has_method("play_shore_cinematic"):
		var t := create_tween()
		t.tween_property(_white, "modulate:a", 0.0, 1.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		t.parallel().tween_property(_final, "modulate:a", 1.0, 1.2)
		world.call("play_shore_cinematic", self)
	else:
		_simple_settle()

# ── Intro director (first login) — persistent on the tree root ────────────────
## Entry point (World adds us to the tree ROOT, then calls this). Reads the player's
## renderer preference and starts loading the 3D world NOW, behind the opaque book.
func start_intro(player_pos: Vector2) -> void:
	_intro_mode = true
	_intro_player_pos = player_pos
	_uname = NetworkManager.my_username
	if _uname.is_empty():
		_uname = "_offline"
	var gcfg := ConfigFile.new()
	gcfg.load("user://graphics.cfg")
	_pref_3d = bool(gcfg.get_value("graphics", "renderer_3d", false))
	# Mark seen NOW (at start), not just on finish — so the book is strictly ONCE per
	# account even if the player quits mid-intro. Settings → Replay Opening is then the
	# only way to see it again.
	var scfg := ConfigFile.new()
	scfg.load("user://prologue.cfg")
	scfg.set_value("seen", _uname, true)
	scfg.save("user://prologue.cfg")
	if not Events.world_build_ready.is_connected(_on_world_build_ready):
		Events.world_build_ready.connect(_on_world_build_ready)
	_load_world("res://world3d.tscn", 1)   # 3D loads while they read the book

## Switch scenes for the intro, remembering which build to wait for (1=3D, 2=2D). If
## we're already in that scene, mark it ready. A timer guards a missed ready signal.
func _load_world(path: String, awaiting: int) -> void:
	var cur := get_tree().current_scene
	if cur != null and cur.scene_file_path == path:
		if awaiting == 1:
			_world_3d_ready = true
			_try_start_flythrough()
		else:
			_reveal_2d_gameplay()
		return
	_awaiting = awaiting
	GameManager.switch_pos = _intro_player_pos
	get_tree().change_scene_to_file(path)
	get_tree().create_timer(7.0).timeout.connect(_on_load_timeout.bind(awaiting))

func _on_load_timeout(which: int) -> void:
	if _awaiting == which and _state != _STATE_DONE:
		_on_world_build_ready(which == 1)

func _on_world_build_ready(is_3d: bool) -> void:
	if _awaiting == 1 and is_3d:
		_awaiting = 0
		_world_3d_ready = true
		_try_start_flythrough()
	elif _awaiting == 2 and not is_3d:
		_awaiting = 0
		_reveal_2d_gameplay()

func _on_reveal_reached() -> void:
	_reached_reveal = true
	_try_start_flythrough()

## Fire the 3D flythrough once BOTH the last page was turned and the 3D world is built.
func _try_start_flythrough() -> void:
	if _state == _STATE_DONE or not (_reached_reveal and _world_3d_ready):
		return
	_backdrop.visible = false
	_cover_panel.visible = false
	_page_panel.visible = false
	_final.visible = true
	_final.modulate.a = 0.0
	_play_vo(7)
	_hide_current_hud()   # the fresh 3D HUD → off for the flythrough
	var world := get_tree().current_scene
	if world != null and world.has_method("play_shore_cinematic"):
		var t := create_tween()
		t.tween_property(_white, "modulate:a", 0.0, 1.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		t.parallel().tween_property(_final, "modulate:a", 1.0, 1.2)
		world.call("play_shore_cinematic", self)
	else:
		_simple_settle()

## After the 2D world is built behind the white, dissolve it away onto gameplay.
func _reveal_2d_gameplay() -> void:
	var t := create_tween()
	t.tween_property(_white, "modulate:a", 0.0, 1.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_callback(_finish_intro)

## End of the whole intro: show character creation (deferred to here), persist the seen
## flag, release the guard, and free ourselves.
func _finish_intro() -> void:
	if _state == _STATE_DONE:
		return
	_state = _STATE_DONE
	if GameManager.intro_need_backstory:
		GameManager.intro_need_backstory = false
		_show_backstory()
	var cfg := ConfigFile.new()
	cfg.load("user://prologue.cfg")
	cfg.set_value("seen", _uname, true)
	cfg.save("user://prologue.cfg")
	GameManager.intro_active = false
	if Events.world_build_ready.is_connected(_on_world_build_ready):
		Events.world_build_ready.disconnect(_on_world_build_ready)
	finished.emit()
	queue_free()

## Character creation, AFTER the cinematic, in whatever scene we ended in.
func _show_backstory() -> void:
	var scn := get_tree().current_scene
	if scn == null or scn.get_node_or_null("BackstorySelectScreen") != null:
		return
	var script := load("res://scripts/BackstorySelectScreen.gd")
	if script == null:
		return
	var screen: Node = script.new()
	screen.name = "BackstorySelectScreen"
	scn.add_child(screen)

func _hide_current_hud() -> void:
	var h := get_tree().get_first_node_in_group("hud") as CanvasLayer
	if h != null:
		h.visible = false

## Called back by the world when its shore cinematic settles. In INTRO mode: hand off to
## the 2D client for play (behind the white), unless the player prefers 3D (stay). In
## REPLAY mode: let the closing line breathe, then finish in place.
func cinematic_done() -> void:
	if _state == _STATE_DONE:
		return
	if _intro_mode:
		if _pref_3d:
			_finish_intro()   # already in the player's renderer — no switch
			return
		var pl := get_tree().get_first_node_in_group("player") as Node2D
		if pl != null:
			_intro_player_pos = pl.global_position
		var t := create_tween()
		t.tween_property(_final, "modulate:a", 0.0, 0.6)
		t.parallel().tween_property(_white, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		t.tween_callback(_load_world.bind("res://world.tscn", 2))
		return
	var t2 := create_tween()
	t2.tween_interval(0.8)
	t2.tween_property(_final, "modulate:a", 0.0, 1.0)
	t2.tween_callback(_finish)

## Fallback for a world with no shore cinematic — a plain white → game dissolve.
func _simple_settle() -> void:
	var t := create_tween()
	t.tween_property(_white, "modulate:a", 0.0, 1.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(_final, "modulate:a", 1.0, 1.2)
	t.tween_interval(2.2)
	t.tween_property(_final, "modulate:a", 0.0, 1.0)
	t.tween_callback(_finish)

func _finish() -> void:
	if _state == _STATE_DONE:
		return
	_state = _STATE_DONE
	_restore_hud()
	finished.emit()
	queue_free()

func _restore_hud() -> void:
	if _hud != null and is_instance_valid(_hud):
		_hud.visible = true

func _exit_tree() -> void:
	# Safety net — never leave the HUD hidden or the intro guard stuck (which would
	# freeze world input) if we're freed by any other path.
	_restore_hud()
	if _intro_mode:
		GameManager.intro_active = false

# ── Helpers ──────────────────────────────────────────────────────────────────
func _fade_in(ctrl: Control, dur: float) -> void:
	if _page_tween != null and _page_tween.is_valid():
		_page_tween.kill()
	ctrl.modulate.a = 0.0
	_page_tween = create_tween()
	_page_tween.tween_property(ctrl, "modulate:a", 1.0, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _play_vo(n: int) -> void:
	if _vo.playing:
		_vo.stop()
	var path := "res://assets/vo/narrator/opening_p%d.ogg" % n
	if not ResourceLoader.exists(path):
		return
	var stream := load(path) as AudioStream
	if stream == null:
		return
	_vo.stream = stream
	_vo.play()

func _on_skip() -> void:
	if _state == _STATE_COVER or _state == _STATE_PAGE:
		_begin_reveal()

func _on_backdrop_input(event: InputEvent) -> void:
	if _state != _STATE_COVER and _state != _STATE_PAGE:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_advance()

func _input(event: InputEvent) -> void:
	if _state != _STATE_COVER and _state != _STATE_PAGE:
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		if k.keycode == KEY_ESCAPE:
			_on_skip()
			get_viewport().set_input_as_handled()
		elif k.keycode == KEY_SPACE or k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			_advance()
			get_viewport().set_input_as_handled()
