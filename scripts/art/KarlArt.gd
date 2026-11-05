extends RefCounted
## Karl v011 — authored 2D sheets + skeletal 3D model, for Karl ONLY (npc.karl,
## seeded n:4, worker "Karl", Kjelvik). Never applied to other NPCs or players.
##
## Reversible: launch with `--procedural-karl` (Karl only) or `--procedural-village`
## (every village prototype), or set VillagePrototypeArt.enabled = false, and the
## original procedural drawing / rig is used. Any missing v011 file also falls back.
##
## Reads existing NPC state only. Movement, timers, hp, damage timing, death and
## networking stay authoritative in NPC.gd / the server; clips are resampled to fit
## the NPC's own windows rather than extending them.
##
## Values mirror assets/authored/characters/karl/v011/karl.sprites.json (the
## authority). They are embedded because exported builds don't pack *.json.

const VERSION := "v011"
const DIR := "res://assets/authored/characters/karl/v011/"
## Visual scale on the drawn sprite; the usual game zoom multiplies on top.
## For every clip (pivot + draw_offset) * DISPLAY_SCALE = (0, 14), the original
## procedural foot anchor.
const DISPLAY_SCALE := 0.25
## Pick the sheet row (front / screen-left / back / screen-right) from movement.
## Purely visual — derived from position deltas, no facing state is added to the
## NPC. false = always the front row, like the original 2D drawing.
const DIRECTIONAL := true
## When standing (idle, head turn, arms crossed, hit) show the front row so his
## face — his identity in the original 2D — stays readable. false = keep the last
## walking direction while standing.
const IDLE_FACES_FRONT := true
## clip -> [sheet, frames_per_direction, duration_s, loop, cell_w, cell_h, off_x, off_y]
## Rows in every sheet: 0 front, 1 screen-left, 2 back, 3 screen-right.
const CLIPS := {
	"idle":         ["karl_idle_crisp.png",         24, 2.0, true,  84, 168, -42, -102],
	"walk":         ["karl_walk_crisp.png",         12, 1.0, true,  94, 171, -47, -100],
	"look_left":    ["karl_look_left_crisp.png",    15, 1.2, false, 84, 168, -42, -102],
	"look_right":   ["karl_look_right_crisp.png",   15, 1.2, false, 84, 168, -42, -102],
	"arms_crossed": ["karl_arms_crossed_crisp.png", 20, 1.6, false, 96, 168, -48, -102],
	"hit":          ["karl_hit_crisp.png",           4, 0.3, false, 84, 169, -42, -103],
}
# The `death` sheet/clip is deliberately never loaded or played: the server hides
# a dead NPC immediately and that transition must not wait for a presentation clip.

## NPC.flash_hit() window — the 0.3 s hit clip is resampled into it so the reaction
## never outlasts the original 0.18 s damage flash.
const HIT_FLASH := 0.18
## NPC idle-variation hold (`_iv_end_t = _time + 1.2` in NPC._process).
const IDLE_VARIATION := 1.2
## Crossfade between 3D clips. The hit reaction lasts only HIT_FLASH (0.18 s), so
## it gets a much shorter blend or the crossfade would swallow it.
const BLEND_3D := 0.15
const BLEND_HIT := 0.04

static var _status := 0                  # 0 untried · 1 package present · -1 missing
static var _sheets: Dictionary = {}      # clip -> Texture2D (loaded on first 2D draw)
static var _scene: PackedScene = null    # loaded on first 3D instance

## True when every v011 runtime file is present. Only checks existence — the 2D
## sheets and the 3D GLB load lazily and independently, so the 2D client never
## holds the GLB's textures and the 3D client never holds the sprite sheets.
static func available() -> bool:
	if "--procedural-karl" in OS.get_cmdline_user_args():
		return false
	if _status == 0:
		_status = 1 if ResourceLoader.exists(DIR + "karl.glb") else -1
		for clip: String in CLIPS:
			if not ResourceLoader.exists(DIR + str((CLIPS[clip] as Array)[0])):
				_status = -1
	return _status == 1

## The skeletal model (3D). Null → caller uses the procedural rig.
## Each client mode holds only its own art: instancing the 3D model releases the
## 2D sheets (~23.6 MB), and drawing 2D releases the GLB (~16 MB) — otherwise a
## 2D<->3D toggle would keep both sets resident for the rest of the session.
static func scene() -> PackedScene:
	if not available():
		return null
	_sheets = {}
	if _scene == null:
		_scene = load(DIR + "karl.glb") as PackedScene
	return _scene

## The six runtime sheets (2D). False → caller draws the procedural Karl.
static func _load_sheets() -> bool:
	_scene = null
	if not _sheets.is_empty():
		return true
	var sheets: Dictionary = {}
	for clip: String in CLIPS:
		var tex := load(DIR + str((CLIPS[clip] as Array)[0])) as Texture2D
		if tex == null:
			return false
		sheets[clip] = tex
	_sheets = sheets
	return true

## Which clip to show and where in it, derived purely from the NPC's own timers.
## Priority: hit > walk > idle variation (head turn / arms crossed) > idle.
## Returns {clip, speed} plus either `progress` (0..1, one-shot clips) or `time`
## (seconds, looping clips). `speed` is the 3D playback rate that makes the clip
## fit the NPC's window.
static func state(logic: Node) -> Dictionary:
	var t := float(logic.get("_time"))
	var hit := float(logic.get("_hit_flash"))
	if hit > 0.0:
		return {"clip": "hit", "progress": clampf(1.0 - hit / HIT_FLASH, 0.0, 1.0),
				"speed": 0.3 / HIT_FLASH}
	if float(logic.get("_idle_timer")) <= 0.0:
		return {"clip": "walk", "time": t, "speed": 1.0}
	var kind := int(logic.get("_iv_kind"))
	if kind != 0:
		var clip := "arms_crossed"
		if kind == 1:
			clip = "look_left" if float(logic.get("_iv_dir")) < 0.0 else "look_right"
		var left := float(logic.get("_iv_end_t")) - t
		return {"clip": clip, "progress": clampf(1.0 - left / IDLE_VARIATION, 0.0, 1.0),
				"speed": float((CLIPS[clip] as Array)[2]) / IDLE_VARIATION}
	return {"clip": "idle", "time": t, "speed": 1.0}

## Sheet column for a state: one-shots sample by progress, loops by
## frames_per_direction / duration (not a blanket 12 fps).
static func frame_of(st: Dictionary) -> int:
	var c: Array = CLIPS[str(st["clip"])]
	var n := int(c[1])
	if st.has("progress"):
		return clampi(int(float(st["progress"]) * float(n)), 0, n - 1)
	return int(float(st["time"]) * float(n) / float(c[2])) % n

## Sheet row from the NPC's own movement. Remembers the last facing between
## steps (stored as meta on the logic node — no NPC state is added).
static func row_for(logic: Node2D, walking: bool) -> int:
	if not DIRECTIONAL:
		return 0
	var row := int(logic.get_meta("karl_row", 0))
	var prev: Vector2 = logic.get_meta("karl_prev", logic.position)
	var m := logic.position - prev
	logic.set_meta("karl_prev", logic.position)
	if walking and m.length() > 0.01 and m.length() < 128.0:   # ignore respawn/admin jumps
		if absf(m.x) > absf(m.y):
			row = 3 if m.x > 0.0 else 1
		else:
			row = 0 if m.y > 0.0 else 2
		logic.set_meta("karl_row", row)
	if not walking and IDLE_FACES_FRONT:
		return 0
	return row

## Draw Karl into the NPC's own canvas item (keeps its sorting, picking, hover
## modulate and combat overlays). Returns false → caller draws the original.
static func draw_2d(logic: Node2D) -> bool:
	if not available() or not _load_sheets():
		return false
	var st := state(logic)
	var clip := str(st["clip"])
	var c: Array = CLIPS[clip]
	var cell := Vector2(float(c[4]), float(c[5]))
	var row := row_for(logic, clip == "walk")
	var src := Rect2(Vector2(float(frame_of(st)) * cell.x, float(row) * cell.y), cell)
	var dst := Rect2(Vector2(float(c[6]), float(c[7])) * DISPLAY_SCALE, cell * DISPLAY_SCALE)
	# The project's default canvas filter is NEAREST (pixel art). These sheets are
	# rendered at 4x and shown at 0.25, so they need linear filtering to stay crisp.
	# NPC has no text children, so this affects only Karl's own textures.
	if logic.texture_filter != CanvasItem.TEXTURE_FILTER_LINEAR:
		logic.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# Same ground shadow every procedural villager gets (NPC._draw_ground_shadow).
	if logic.has_method("_draw_ground_shadow"):
		logic.call("_draw_ground_shadow")
	logic.draw_texture_rect_region(_sheets[clip] as Texture2D, dst, src)
	return true
