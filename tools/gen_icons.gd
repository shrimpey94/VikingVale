## Run this script once from the Godot editor:
##   Script Editor → File → Run (Ctrl+Shift+X)
## It writes res://assets/icons/<id>.png  (24×24 inventory)
##         and  res://assets/icons/drop_<id>.png (16×16 ground drop)
@tool
extends EditorScript

const SZ  := 24
const DIR := "res://assets/icons/"

const BLACK := Color(0.0,  0.0,  0.0,  1.0)
const WHITE := Color(1.0,  1.0,  1.0,  1.0)
const TRANS := Color(0.0,  0.0,  0.0,  0.0)

# ── Wood palettes ────────────────────────────────────────────────────────────
const OAK_DK  := Color(0.24, 0.12, 0.03); const OAK_MD  := Color(0.55, 0.30, 0.10); const OAK_LT  := Color(0.78, 0.52, 0.25)
const PINE_DK := Color(0.18, 0.10, 0.03); const PINE_MD := Color(0.42, 0.24, 0.08); const PINE_LT := Color(0.62, 0.40, 0.18)
const CHR_DK  := Color(0.30, 0.08, 0.05); const CHR_MD  := Color(0.62, 0.22, 0.15); const CHR_LT  := Color(0.88, 0.48, 0.35)
const IRW_DK  := Color(0.08, 0.04, 0.02); const IRW_MD  := Color(0.22, 0.12, 0.06); const IRW_LT  := Color(0.38, 0.22, 0.10)
const FRS_DK  := Color(0.45, 0.65, 0.82); const FRS_MD  := Color(0.72, 0.88, 0.98); const FRS_LT  := Color(0.93, 0.97, 1.00)
const ANC_DK  := Color(0.30, 0.18, 0.04); const ANC_MD  := Color(0.58, 0.38, 0.08); const ANC_LT  := Color(0.90, 0.72, 0.20)
# ── Tool handle ──────────────────────────────────────────────────────────────
const HDL_DK  := Color(0.30, 0.18, 0.06); const HDL_MD  := Color(0.52, 0.32, 0.12); const HDL_LT  := Color(0.72, 0.50, 0.22)
# ── Stone / rock ─────────────────────────────────────────────────────────────
const RK_DK   := Color(0.25, 0.25, 0.25); const RK_MD   := Color(0.50, 0.50, 0.50); const RK_LT   := Color(0.75, 0.75, 0.75)
# ── Food / organic ───────────────────────────────────────────────────────────
const GRN_DK  := Color(0.12, 0.38, 0.08); const GRN_MD  := Color(0.28, 0.68, 0.15); const GRN_LT  := Color(0.52, 0.88, 0.32)
const BRN_DK  := Color(0.28, 0.14, 0.04); const BRN_MD  := Color(0.52, 0.30, 0.10); const BRN_LT  := Color(0.78, 0.56, 0.26)

# ══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════
func _run() -> void:
	var da := DirAccess.open("res://")
	da.make_dir_recursive("assets/icons")
	_gen_all()
	print("gen_icons: all 80 icons + 80 drop variants written to ", DIR)

func _gen_all() -> void:
	# ── Cat A: Raw resources ──────────────────────────────────────────────────
	_gen_stick();        _gen_stone()
	_make_log("oak_log",      OAK_DK,  OAK_MD,  OAK_LT,  "")
	_make_log("pine_log",     PINE_DK, PINE_MD, PINE_LT, "knot")
	_make_log("cherry_log",   CHR_DK,  CHR_MD,  CHR_LT,  "")
	_make_log("ironwood_log", IRW_DK,  IRW_MD,  IRW_LT,  "")
	_make_log("frost_log",    FRS_DK,  FRS_MD,  FRS_LT,  "frost")
	_make_log("ancient_log",  ANC_DK,  ANC_MD,  ANC_LT,  "glow")
	_make_ore("copper_ore",  Color(0.78, 0.45, 0.18))
	_make_ore("iron_ore",    Color(0.62, 0.62, 0.68))
	_make_ore("gold_ore",    Color(0.95, 0.82, 0.15), true)
	_make_ore("mithril_ore", Color(0.45, 0.72, 0.92))
	_make_ore("adamant_ore", Color(0.22, 0.68, 0.35))
	_make_ore("runite_ore",  Color(0.68, 0.22, 0.85), true)
	_make_fish("raw_fish",   Color(0.42, 0.72, 0.82), Color(0.78, 0.94, 0.98), Color(0.30, 0.55, 0.72))
	_make_fish("raw_salmon", Color(0.70, 0.35, 0.18), Color(0.92, 0.65, 0.45), Color(0.55, 0.25, 0.12), true)
	_gen_lobster();      _gen_raw_shark();  _gen_abyssal_eel()
	# Rare deep-sea fish (boat fishing only)
	_make_fish("silverfin",     Color(0.50, 0.58, 0.70), Color(0.78, 0.86, 0.95), Color(0.36, 0.44, 0.58), true)
	_make_fish("anglerfish",    Color(0.16, 0.20, 0.14), Color(0.32, 0.38, 0.26), Color(0.10, 0.13, 0.08), true)
	_make_fish("leviathan_eel", Color(0.12, 0.34, 0.30), Color(0.24, 0.52, 0.46), Color(0.08, 0.24, 0.20))
	_gen_herbs();        _gen_mushrooms();  _gen_berries()
	_gen_moonbloom();    _gen_ancient_root()
	# ── Cat B: Special drops ──────────────────────────────────────────────────
	_gen_craft_kit();    _gen_arrow_bundle(); _gen_magic_dust(); _gen_timber()
	# ── Cat C: Bars ───────────────────────────────────────────────────────────
	# Bars are now drawn by the audit-fill dedicated functions (each with a
	# distinct silhouette, not a color-swapped rectangle) — see
	# _gen_audit_icons() below.
	# ── Cat D: Tools & weapons ────────────────────────────────────────────────
	_make_axe("wooden_axe",   OAK_LT,  OAK_MD)
	_make_axe("copper_axe",   Color(0.82, 0.52, 0.22), Color(0.98, 0.72, 0.42))
	_make_axe("iron_axe",     Color(0.55, 0.55, 0.62), Color(0.80, 0.80, 0.88))
	_make_axe("adamant_axe",  Color(0.22, 0.68, 0.35), Color(0.42, 0.92, 0.55))
	_make_pick("wooden_pickaxe",  OAK_LT,  OAK_MD)
	_make_pick("copper_pickaxe",  Color(0.82, 0.52, 0.22), Color(0.98, 0.72, 0.42))
	_make_pick("iron_pickaxe",    Color(0.55, 0.55, 0.62), Color(0.80, 0.80, 0.88))
	_make_pick("runite_pickaxe",  Color(0.72, 0.22, 0.90), Color(0.90, 0.55, 1.00))
	_gen_wooden_fishing_pole(); _gen_fishing_pole()
	_gen_ironwood_bow();        _gen_gold_amulet();  _gen_mithril_sword()
	# ── Cat E: Cooked food ────────────────────────────────────────────────────
	_gen_cooked_fish();    _gen_herb_tea();      _gen_cooked_salmon()
	_gen_cooked_lobster(); _gen_cooked_shark();  _gen_eel_stew()
	# ── Cat F: Construction ───────────────────────────────────────────────────
	_gen_wooden_chair();   _gen_wooden_table();  _gen_pine_bookshelf()
	_gen_cherry_chest();   _gen_ironwood_gate(); _gen_frost_cabin()
	# ── Cat G: Monster drops ──────────────────────────────────────────────────
	_gen_rat_bone();       _gen_bone();          _gen_goblin_ear()
	_gen_draugr_shard();   _gen_dragon_scale();  _gen_feather()
	_gen_wolf_pelt();      _gen_bandit_hood();   _gen_bear_claw()
	_gen_troll_hide();     _gen_spirit_essence(); _gen_spider_silk()
	_gen_ice_fang();       _gen_frost_crystal(); _gen_ice_shard()
	_gen_imp_horn();       _gen_lava_carapace(); _gen_giant_ember()
	_gen_shadow_essence(); _gen_death_rune();    _gen_spectral_essence()
	# ── Cat H: Craftable armour / weapon / jewellery tiers ────────────────────
	_gen_gear_tiers()
	# ── Cat I: Boats ──────────────────────────────────────────────────────────
	_gen_boats()
	# ── Cat J: Cooked foods + raw meats ───────────────────────────────────────
	_gen_foods()
	# ── Cat K: Sidebar tab icons ──────────────────────────────────────────────
	_gen_tab_icons()
	# ── Cat L: Farming (plot, seeds, crops) ───────────────────────────────────
	_gen_farming()
	# ── Cat M: Construction buildables (all wood tiers) ───────────────────────
	_gen_construction_buildables()
	# ── Cat N: Icon-audit fills (runes, distinct bars, sea-monster drops,
	#         essence, bait, dragon boots, crafting absorbed-from-construction).
	_gen_audit_icons()

# ══════════════════════════════════════════════════════════════════════════════
# PRIMITIVES
# ══════════════════════════════════════════════════════════════════════════════
func _img() -> Image:
	var i := Image.create(SZ, SZ, false, Image.FORMAT_RGBA8)
	i.fill(TRANS)
	return i

func _px(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and x < SZ and y >= 0 and y < SZ:
		img.set_pixel(x, y, c)

func _rect(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for ry in range(h):
		for rx in range(w):
			_px(img, x + rx, y + ry, c)

func _circle(img: Image, cx: int, cy: int, r: float, c: Color) -> void:
	var ri := int(ceil(r))
	for ry in range(-ri, ri + 1):
		for rx in range(-ri, ri + 1):
			if float(rx * rx + ry * ry) <= r * r + 0.5:
				_px(img, cx + rx, cy + ry, c)

func _ellipse(img: Image, cx: int, cy: int, rx: int, ry: int, c: Color) -> void:
	for dy in range(-ry, ry + 1):
		for dx in range(-rx, rx + 1):
			var v := float(dx * dx) / float(rx * rx) + float(dy * dy) / float(ry * ry)
			if v <= 1.0:
				_px(img, cx + dx, cy + dy, c)

# Bresenham single-pixel line
func _bline(img: Image, x0: int, y0: int, x1: int, y1: int, c: Color) -> void:
	var dx: int = abs(x1 - x0); var dy: int = abs(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1; var sy: int = 1 if y0 < y1 else -1
	var err: int = dx - dy
	var lx: int = x0; var ly: int = y0
	while true:
		_px(img, lx, ly, c)
		if lx == x1 and ly == y1: break
		var e2: int = 2 * err
		if e2 > -dy: err -= dy; lx += sx
		if e2 < dx:  err += dx; ly += sy

func _line(img: Image, x0: int, y0: int, x1: int, y1: int, c: Color, thick: int = 1) -> void:
	_bline(img, x0, y0, x1, y1, c)
	if thick >= 2: _bline(img, x0, y0 + 1, x1, y1 + 1, c)
	if thick >= 3: _bline(img, x0 + 1, y0, x1 + 1, y1, c); _bline(img, x0, y0 - 1, x1, y1 - 1, c)
	if thick >= 4: _bline(img, x0 - 1, y0, x1 - 1, y1, c); _bline(img, x0, y0 + 2, x1, y1 + 2, c)

func _outline(img: Image) -> void:
	var copy := img.duplicate() as Image
	for y in range(SZ):
		for x in range(SZ):
			if copy.get_pixel(x, y).a < 0.5:
				for d: Vector2i in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
					var nx := x + d.x; var ny := y + d.y
					if nx >= 0 and nx < SZ and ny >= 0 and ny < SZ:
						if copy.get_pixel(nx, ny).a > 0.5:
							img.set_pixel(x, y, BLACK)
							break

func _save(img: Image, item_id: String) -> void:
	img.save_png(ProjectSettings.globalize_path(DIR + item_id + ".png"))
	var small := img.duplicate() as Image
	small.resize(16, 16, Image.INTERPOLATE_NEAREST)
	small.save_png(ProjectSettings.globalize_path(DIR + "drop_" + item_id + ".png"))

# ── Farming: tilled plot, seed pouches, harvested crops ───────────────────────
func _gen_farming() -> void:
	_make_farm_plot()
	_make_seed("barley_seed",  Color(0.85, 0.78, 0.35))
	_make_seed("cabbage_seed", Color(0.45, 0.78, 0.36))
	_make_seed("onion_seed",   Color(0.86, 0.74, 0.45))
	_make_seed("wheat_seed",   Color(0.90, 0.80, 0.30))
	_make_seed("tomato_seed",  Color(0.88, 0.26, 0.18))
	_make_crop("barley",  Color(0.85, 0.78, 0.35), "grain")
	_make_crop("wheat",   Color(0.90, 0.80, 0.30), "grain")
	_make_crop("cabbage", Color(0.45, 0.78, 0.36), "round")
	_make_crop("onion",   Color(0.86, 0.74, 0.45), "round")
	_make_crop("tomato",  Color(0.88, 0.26, 0.18), "round")

func _make_farm_plot() -> void:
	var img := _img()
	var soil := Color(0.40, 0.26, 0.13)
	_rect(img, 3, 7, 18, 13, soil)
	_rect(img, 3, 7, 18, 2, soil.lightened(0.18))
	_rect(img, 3, 18, 18, 2, soil.darkened(0.30))
	for fx in range(5, 21, 5):
		_line(img, fx, 9, fx, 18, soil.darkened(0.22), 1)
	# corner posts
	for p: Vector2i in [Vector2i(2, 6), Vector2i(20, 6), Vector2i(2, 19), Vector2i(20, 19)]:
		_rect(img, p.x, p.y, 2, 2, BRN_MD)
	# sprouts
	_line(img, 7, 17, 7, 12, GRN_MD, 1);  _circle(img, 7, 11, 1.4, GRN_LT)
	_line(img, 12, 17, 12, 11, GRN_MD, 1); _circle(img, 12, 10, 1.6, GRN_LT)
	_line(img, 17, 17, 17, 13, GRN_MD, 1); _circle(img, 17, 12, 1.4, GRN_LT)
	_outline(img)
	_save(img, "farm_plot")

func _make_seed(id: String, c: Color) -> void:
	var img := _img()
	# little burlap pouch
	_ellipse(img, 12, 15, 6, 5, BRN_MD)
	_ellipse(img, 12, 15, 5, 4, BRN_LT)
	_rect(img, 9, 7, 6, 3, BRN_DK)        # tied neck
	_rect(img, 10, 9, 4, 2, BRN_MD)
	# seeds spilling
	_circle(img, 10, 14, 1.2, c)
	_circle(img, 13, 16, 1.2, c.darkened(0.1))
	_circle(img, 12, 13, 1.0, c.lightened(0.15))
	_outline(img)
	_save(img, id)

## Construction buildables — one icon per (wood tier, building). Each is drawn in
## the tier's wood colour with a simple archetype shape so every construction
## recipe has a programmatic icon in the game's pixel style.
func _gen_construction_buildables() -> void:
	var woods: Array = [
		["oak",      Color(0.55, 0.36, 0.18)],
		["pine",     Color(0.42, 0.30, 0.14)],
		["cherry",   Color(0.72, 0.38, 0.42)],
		["ironwood", Color(0.30, 0.18, 0.08)],
		["frost",    Color(0.72, 0.90, 0.98)],
		["ancient",  Color(0.55, 0.40, 0.12)],
	]
	var arch: Dictionary = {
		"campfire": "fire", "wall": "wall", "crate": "box", "workbench": "table",
		"fence": "wall", "gate": "post", "torch_post": "post", "smith_station": "table",
		"house_frame": "house", "bookshelf": "shelf", "site_marker": "post", "well": "well",
		"market_stall": "house", "bank_chest": "box", "plant_bed": "bed", "altar": "table",
		"watchtower": "post", "large_house": "house", "dock": "plank", "clan_hall": "house",
		"armory_rack": "shelf", "fortified_wall": "wall", "guard_tower": "post",
		"grand_hall": "house", "portal_shrine": "arch",
	}
	for key: String in arch:
		for w: Array in woods:
			_make_building("%s_%s" % [w[0] as String, key], arch[key] as String, w[1] as Color)

func _make_building(id: String, a: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.35)
	var lt := c.lightened(0.25)
	match a:
		"box":
			_rect(img, 5, 9, 14, 12, c); _rect(img, 5, 9, 14, 2, lt); _rect(img, 5, 19, 14, 2, dk)
			_line(img, 5, 14, 18, 14, dk, 1); _circle(img, 12, 15, 1.2, Color(0.88, 0.72, 0.18))
		"wall":
			for px in range(5, 20, 4):
				_rect(img, px, 5, 3, 16, c); _rect(img, px, 5, 3, 2, lt)
		"post":
			_rect(img, 10, 4, 4, 18, c); _rect(img, 8, 3, 8, 3, lt); _rect(img, 9, 20, 6, 2, dk)
		"house":
			for r in range(8):
				_rect(img, 11 - r, 12 - r, (r + 1) * 2, 1, dk if r % 2 == 0 else c)
			_rect(img, 6, 12, 12, 9, c); _rect(img, 6, 12, 12, 1, lt)
			_rect(img, 10, 16, 4, 5, dk)
		"table":
			_rect(img, 4, 10, 16, 3, c); _rect(img, 4, 10, 16, 1, lt)
			_rect(img, 5, 13, 2, 8, dk); _rect(img, 17, 13, 2, 8, dk)
		"shelf":
			_rect(img, 5, 5, 14, 16, c); _rect(img, 5, 5, 14, 1, lt)
			_line(img, 5, 10, 18, 10, dk, 1); _line(img, 5, 15, 18, 15, dk, 1)
		"well":
			_rect(img, 6, 12, 12, 8, c); _rect(img, 5, 11, 14, 2, dk)
			_rect(img, 6, 5, 2, 7, dk); _rect(img, 16, 5, 2, 7, dk); _rect(img, 5, 4, 14, 2, lt)
		"bed":
			_rect(img, 4, 12, 16, 8, Color(0.40, 0.26, 0.13))
			_rect(img, 4, 12, 16, 2, Color(0.30, 0.20, 0.10))
			_line(img, 8, 18, 8, 13, GRN_MD, 1); _circle(img, 8, 12, 1.4, GRN_LT)
			_line(img, 13, 18, 13, 13, GRN_MD, 1); _circle(img, 13, 12, 1.4, GRN_LT)
		"plank":
			_rect(img, 3, 13, 18, 4, c); _rect(img, 3, 13, 18, 1, lt)
			_rect(img, 6, 17, 2, 4, dk); _rect(img, 16, 17, 2, 4, dk)
		"fire":
			_line(img, 6, 19, 17, 15, c, 2); _line(img, 6, 15, 17, 19, c, 2)
			_circle(img, 12, 11, 4, Color(0.95, 0.45, 0.08))
			_circle(img, 12, 10, 2, Color(1.0, 0.80, 0.20))
		"arch":
			_rect(img, 5, 6, 3, 15, c); _rect(img, 16, 6, 3, 15, c); _rect(img, 5, 5, 14, 3, c)
			_circle(img, 12, 14, 4, Color(0.55, 0.45, 0.95, 0.7))
		_:
			_rect(img, 6, 8, 12, 12, c); _rect(img, 6, 8, 12, 2, lt)
	_outline(img)
	_save(img, id)

func _make_crop(id: String, c: Color, shape: String) -> void:
	var img := _img()
	if shape == "grain":
		_line(img, 12, 21, 12, 7, Color(0.55, 0.42, 0.16), 2)
		for gy in range(8, 18, 3):
			_circle(img, 10, gy, 1.4, c)
			_circle(img, 14, gy, 1.4, c)
		_circle(img, 12, 6, 1.6, c.lightened(0.1))
	else:
		_circle(img, 12, 14, 7, c)
		_circle(img, 10, 12, 3, c.lightened(0.22))
		_line(img, 12, 7, 12, 4, GRN_MD, 2)
		_circle(img, 12, 4, 1.4, GRN_LT)
	_outline(img)
	_save(img, id)

# ══════════════════════════════════════════════════════════════════════════════
# FAMILY TEMPLATES
# ══════════════════════════════════════════════════════════════════════════════

# Log: horizontal cylinder, oval cut-end on left, optional extra detail
func _make_log(id: String, c_dk: Color, c_md: Color, c_lt: Color, extra: String) -> void:
	var img := _img()
	# Body side
	_rect(img, 6, 9, 16, 9, c_md)
	# Top highlight strip
	_rect(img, 6, 9, 16, 2, c_lt)
	# Bottom shadow strip
	_rect(img, 6, 16, 16, 2, c_dk)
	# Left cut-end oval face
	_ellipse(img, 5, 13, 3, 5, c_dk)
	_ellipse(img, 5, 13, 2, 3, c_md)
	_circle(img,  5, 13, 1,    c_lt)
	match extra:
		"knot":   _circle(img, 15, 15, 1, c_dk); _px(img, 16, 14, c_dk)
		"frost":  _px(img, 18, 9, FRS_LT); _px(img, 14, 11, WHITE); _px(img, 20, 14, FRS_LT)
		"glow":   _px(img, 13, 13, ANC_LT.lightened(0.5)); _px(img, 14, 13, ANC_LT.lightened(0.5))
	_outline(img)
	_save(img, id)

# Ore: jagged rock chunk with colored vein diagonal
func _make_ore(id: String, c_vein: Color, glow: bool = false) -> void:
	var img := _img()
	_circle(img, 12, 13, 9,   RK_MD)
	_circle(img,  8, 15, 6,   RK_DK)
	_circle(img, 17,  9, 4.5, RK_LT)
	_line(img, 5, 19, 19, 6, c_vein, 2)
	_line(img, 7, 17, 17, 8, c_vein.lightened(0.25), 1)
	if glow:
		_px(img, 12, 12, c_vein.lightened(0.7))
		_px(img, 13, 11, c_vein.lightened(0.7))
	_outline(img)
	_save(img, id)

# Fish: oval body, V-tail, small fins, colored by type
func _make_fish(id: String, c_back: Color, c_belly: Color, c_fin: Color, spots: bool = false) -> void:
	var img := _img()
	_ellipse(img, 14, 12, 8, 5, c_belly)
	_ellipse(img, 14, 10, 8, 3, c_back)
	# Tail V
	_line(img, 4, 7,  9, 12, c_fin, 2)
	_line(img, 4, 17, 9, 12, c_fin, 2)
	# Dorsal fin
	_line(img, 12, 7, 16, 9, c_back, 1)
	_line(img, 16, 7, 16, 9, c_back, 1)
	# Pectoral fin bump
	_circle(img, 11, 14, 2, c_fin)
	# Eye
	_circle(img, 19, 10, 2, Color(0.95, 0.95, 0.95))
	_px(img, 19, 10, Color(0.08, 0.08, 0.08))
	if spots:
		_px(img, 15, 13, c_back); _px(img, 17, 12, c_back); _px(img, 13, 14, c_back)
	_outline(img)
	_save(img, id)

# Bar/ingot: top face + front face forming isometric ingot
func _make_bar(id: String, c_top: Color, c_front: Color) -> void:
	var img := _img()
	# Top face (lighter)
	_rect(img, 4, 7, 16, 5, c_top)
	_rect(img, 4, 7, 16, 1, c_top.lightened(0.35))  # top shine
	# Angled top-right edge
	_bline(img, 19, 7, 21, 10, c_top.darkened(0.2))
	_bline(img, 19, 11, 21, 10, c_front.lightened(0.1))
	# Front face (darker)
	_rect(img, 4, 12, 16, 6, c_front)
	_rect(img, 4, 17, 16, 1, c_front.darkened(0.35))  # bottom shadow
	# Right side face
	_bline(img, 20, 7,  22, 10, c_front.lightened(0.15))
	_bline(img, 20, 12, 22, 10, c_front.darkened(0.05))
	_rect(img, 20, 10, 2, 7, c_front.darkened(0.1))
	if id == "runite_bar":
		_px(img, 11, 9, WHITE); _px(img, 14, 9, WHITE)  # runite glow specks
	_outline(img)
	_save(img, id)

# Axe: diagonal handle + fan-shaped head at top-right
func _make_axe(id: String, c_head: Color, c_head_lt: Color) -> void:
	var img := _img()
	# Handle diagonal
	_line(img, 3, 21, 15, 9, HDL_MD, 3)
	_line(img, 4, 20, 14, 9, HDL_LT, 1)  # highlight
	# Axe head
	_ellipse(img, 17, 9, 5, 7, c_head)
	_rect(img, 12, 5, 4, 9, c_head)       # tang connecting handle
	_ellipse(img, 17, 9, 3, 5, c_head_lt) # highlight face
	# Cutting-edge curve
	_bline(img, 21, 3, 23, 9,  c_head.darkened(0.25))
	_bline(img, 23, 9, 21, 15, c_head.darkened(0.25))
	if id == "runite_pickaxe":  # reused for glow hint (won't be called here)
		_px(img, 22, 9, Color(0.90, 0.55, 1.00))
	_outline(img)
	_save(img, id)

# Pickaxe: diagonal handle + horizontal pick head
func _make_pick(id: String, c_head: Color, c_head_lt: Color) -> void:
	var img := _img()
	# Handle
	_line(img, 5, 21, 18, 13, HDL_MD, 3)
	_line(img, 6, 20, 17, 13, HDL_LT, 1)
	# Horizontal head bar
	_rect(img, 6, 7, 13, 4, c_head)
	_rect(img, 6, 7, 13, 1, c_head_lt)  # top shine
	# Front spike (pointing right-down)
	_line(img, 19, 9, 22, 14, c_head, 2)
	_px(img, 22, 14, c_head.darkened(0.2))
	# Back spike (pointing left)
	_line(img, 6, 9, 2, 13, c_head.darkened(0.15), 2)
	if id == "runite_pickaxe":
		_px(img, 10, 8, Color(0.90, 0.55, 1.00))
		_px(img, 16, 8, Color(0.90, 0.55, 1.00))
	_outline(img)
	_save(img, id)

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY A — individual icons
# ══════════════════════════════════════════════════════════════════════════════
func _gen_stick() -> void:
	var img := _img()
	_line(img,  2, 21, 21, 3,  OAK_MD, 3)
	_line(img,  3, 20, 20, 4,  OAK_LT, 1)  # highlight top edge
	_line(img,  3,  4, 19, 21, OAK_DK, 2)  # crossing stick
	_outline(img); _save(img, "stick")

func _gen_stone() -> void:
	var img := _img()
	_circle(img, 12, 14, 9,   RK_MD)
	_circle(img,  8, 16, 6,   RK_DK)   # shadow left
	_circle(img, 16, 9,  4,   RK_LT)   # highlight upper-right
	_px(img, 17,  8, WHITE)             # specular pixel
	_outline(img); _save(img, "stone")

func _gen_lobster() -> void:
	var img := _img()
	var c_dk := Color(0.60, 0.12, 0.06); var c_md := Color(0.88, 0.28, 0.14); var c_lt := Color(1.00, 0.52, 0.38)
	# Body segments
	_ellipse(img, 12, 14, 6, 4, c_md)
	_ellipse(img, 12, 11, 4, 3, c_md)
	_ellipse(img, 12,  8, 3, 2, c_dk)  # head
	# Left claw
	_ellipse(img, 5, 11, 4, 3, c_md)
	_ellipse(img, 5, 11, 2, 1, c_lt)
	# Right claw
	_ellipse(img, 19, 11, 4, 3, c_md)
	_ellipse(img, 19, 11, 2, 1, c_lt)
	# Antennae
	_bline(img, 10,  7, 4,  2, c_dk)
	_bline(img, 14,  7, 20, 2, c_dk)
	# Tail fan
	_ellipse(img, 12, 18, 5, 3, c_dk)
	_ellipse(img, 12, 18, 3, 1, c_md)
	# Eyes
	_px(img, 9, 7, Color(0.1, 0.1, 0.1)); _px(img, 15, 7, Color(0.1, 0.1, 0.1))
	_outline(img); _save(img, "lobster")

func _gen_raw_shark() -> void:
	var img := _img()
	var c_bk := Color(0.40, 0.42, 0.52); var c_bd := Color(0.58, 0.60, 0.68); var c_bl := Color(0.88, 0.90, 0.92)
	# Body
	_ellipse(img, 13, 13, 10, 5, c_bd)
	# White belly (lower half)
	_ellipse(img, 13, 15, 9, 3, c_bl)
	# Back (darker upper strip)
	_ellipse(img, 13, 10, 10, 3, c_bk)
	# Tail fin (right)
	_line(img, 21, 9,  23, 6,  c_bk, 2)
	_line(img, 21, 15, 23, 18, c_bk, 2)
	# Dorsal fin (large, top)
	_line(img, 12, 8, 10, 3, c_bk, 2)
	_line(img, 10, 3, 15, 8, c_bk, 2)
	# Pectoral fin (bottom)
	_line(img, 10, 16, 8, 20, c_bd, 2)
	# Eye
	_circle(img, 4, 12, 1, Color(0.1, 0.1, 0.1))
	_outline(img); _save(img, "raw_shark")

func _gen_abyssal_eel() -> void:
	var img := _img()
	var c_dk := Color(0.12, 0.25, 0.22); var c_md := Color(0.20, 0.42, 0.38); var c_lt := Color(0.32, 0.62, 0.55)
	var c_ey := Color(0.65, 0.25, 0.90)
	# S-curve body (3 segments)
	_ellipse(img, 16,  6, 5, 3, c_md)  # head end
	_ellipse(img, 11, 12, 5, 3, c_md)  # mid
	_ellipse(img,  7, 18, 4, 3, c_dk)  # tail end
	# Connecting links
	_bline(img, 13, 7, 14, 11, c_md)
	_bline(img, 9, 13, 9, 17,  c_md)
	# Glowing eye
	_circle(img, 18, 5, 2, c_ey)
	_px(img, 18, 5, Color(0.9, 0.7, 1.0))
	# Fin line
	_bline(img, 19, 8, 8, 21, c_lt)
	_outline(img); _save(img, "abyssal_eel")

func _gen_herbs() -> void:
	var img := _img()
	# Stem
	_line(img, 12, 22, 12, 10, GRN_DK, 1)
	# Left branch
	_bline(img, 12, 16, 7, 12, GRN_DK)
	# Right branch
	_bline(img, 12, 14, 17, 10, GRN_DK)
	# Three leaf ovals
	_ellipse(img,  6, 11, 4, 3, GRN_MD)
	_ellipse(img, 16,  9, 4, 3, GRN_MD)
	_ellipse(img, 12,  8, 3, 4, GRN_LT)  # top leaf lighter
	# Leaf veins
	_bline(img,  6, 11,  4, 10, GRN_DK)
	_bline(img, 16,  9, 18,  8, GRN_DK)
	_bline(img, 12,  8, 12,  5, GRN_DK)
	_outline(img); _save(img, "herbs")

func _gen_mushrooms() -> void:
	var img := _img()
	var c_cap_dk := Color(0.48, 0.28, 0.08); var c_cap_md := Color(0.72, 0.48, 0.22)
	var c_stem    := Color(0.88, 0.86, 0.78); var c_spot   := Color(0.96, 0.92, 0.82)
	# Main cap
	_ellipse(img, 12,  9, 9, 6, c_cap_dk)
	_ellipse(img, 12,  8, 8, 5, c_cap_md)
	_ellipse(img, 12,  7, 5, 3, c_cap_md.lightened(0.2))  # highlight
	# Main stem
	_rect(img, 9, 13, 6, 8, c_stem)
	_rect(img, 9, 13, 2, 8, c_stem.lightened(0.15))  # highlight
	# Spots on cap
	_circle(img,  9,  9, 1, c_spot); _circle(img, 15, 8, 1, c_spot); _circle(img, 12, 6, 1, c_spot)
	# Small second mushroom (right)
	_ellipse(img, 19, 14, 4, 3, c_cap_dk.lightened(0.1))
	_rect(img, 18, 17, 3, 4, c_stem)
	_outline(img); _save(img, "mushrooms")

func _gen_berries() -> void:
	var img := _img()
	var c_b1 := Color(0.72, 0.18, 0.50); var c_b2 := Color(0.90, 0.32, 0.65); var c_b3 := Color(0.50, 0.10, 0.35)
	# Three berries in triangle
	_circle(img, 10, 15, 4, c_b3); _circle(img, 10, 15, 3, c_b1)
	_circle(img, 16, 15, 4, c_b3); _circle(img, 16, 15, 3, c_b1)
	_circle(img, 13, 10, 4, c_b3); _circle(img, 13, 10, 3, c_b2)
	# Shine pixels
	_px(img,  9, 14, c_b2); _px(img, 15, 14, c_b2); _px(img, 12,  9, Color(1.0, 0.75, 0.85))
	# Stems
	_bline(img, 10, 11, 13, 10, GRN_DK)
	_bline(img, 16, 11, 13, 10, GRN_DK)
	_bline(img, 13, 10, 13, 7,  GRN_DK)
	# Leaf
	_ellipse(img, 17, 7, 3, 2, GRN_MD)
	_outline(img); _save(img, "berries")

func _gen_moonbloom() -> void:
	var img := _img()
	var c_pet := Color(0.92, 0.92, 0.98); var c_ctr := Color(0.72, 0.55, 0.92); var c_glo := Color(0.88, 0.78, 1.00)
	# Six petals arranged around center
	for i in range(6):
		var angle := float(i) * TAU / 6.0
		var px2 := 12 + int(round(cos(angle) * 6))
		var py2 := 12 + int(round(sin(angle) * 6))
		_ellipse(img, px2, py2, 3, 2, c_pet)
	# Center
	_circle(img, 12, 12, 3, c_ctr)
	_circle(img, 12, 12, 1, c_glo)
	# Glow pixels
	_px(img, 12,  8, c_glo); _px(img, 16, 12, c_glo)
	_px(img, 12, 16, c_glo); _px(img,  8, 12, c_glo)
	_outline(img); _save(img, "moonbloom")

func _gen_ancient_root() -> void:
	var img := _img()
	var c_dk := Color(0.28, 0.15, 0.04); var c_md := Color(0.52, 0.32, 0.10); var c_lt := Color(0.72, 0.52, 0.24)
	# Main root S-curve
	_line(img,  4, 20, 10, 14, c_md, 3)
	_line(img, 10, 14, 16, 10, c_md, 3)
	_line(img, 16, 10, 20,  5, c_md, 2)
	# Side roots branching off
	_line(img,  8, 17,  4, 13, c_dk, 2)
	_line(img, 14, 11, 10,  6, c_dk, 2)
	_line(img, 17,  8, 22,  6, c_dk, 1)
	# Root tip tendrils
	_bline(img, 19, 5, 22, 4,  c_md)
	_bline(img,  4, 13, 2, 11, c_dk)
	# Highlight top edge
	_line(img, 5, 19, 19, 6, c_lt, 1)
	_outline(img); _save(img, "ancient_root")

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY B — Special drops
# ══════════════════════════════════════════════════════════════════════════════
func _gen_craft_kit() -> void:
	var img := _img()
	var c_bg := Color(0.55, 0.38, 0.16); var c_lt := Color(0.78, 0.58, 0.28); var c_dk := Color(0.28, 0.16, 0.05)
	# Pouch body
	_ellipse(img, 12, 15, 8, 6, c_bg)
	_ellipse(img, 12, 15, 6, 4, c_lt)  # highlight
	# Pouch top (neck)
	_rect(img, 9, 8, 6, 5, c_bg)
	_rect(img, 9, 8, 2, 5, c_lt)
	# Tie string
	_rect(img, 8, 12, 8, 2, c_dk)
	# Hammer silhouette on pouch
	_rect(img, 10, 16, 4, 2, Color(0.22, 0.12, 0.04))  # handle
	_rect(img,  9, 14, 6, 2, Color(0.55, 0.55, 0.60))  # head
	_outline(img); _save(img, "craft_kit")

func _gen_arrow_bundle() -> void:
	var img := _img()
	var c_sh := Color(0.52, 0.32, 0.12); var c_tp := Color(0.65, 0.65, 0.68); var c_fc := Color(0.92, 0.78, 0.55)
	# Three diagonal arrows
	for offset: int in [-3, 0, 3]:
		_line(img, 3 + offset, 21, 17 + offset, 5, c_sh, 1)  # shaft
		_px(img, 17 + offset, 5, c_tp)  # tip
		_px(img, 16 + offset, 5, c_tp)
		_px(img, 17 + offset, 6, c_tp)
		_px(img,  3 + offset, 21, c_fc)  # fletching top
		_px(img,  4 + offset, 20, c_fc)
	# Bundle wrap
	_rect(img, 7, 14, 9, 2, Color(0.38, 0.22, 0.08))
	_outline(img); _save(img, "arrow_bundle")

func _gen_magic_dust() -> void:
	var img := _img()
	var c_bg := Color(0.42, 0.26, 0.10); var c_dk := Color(0.25, 0.14, 0.04)
	var c_sp := Color(0.72, 0.38, 0.90); var c_glo := Color(0.90, 0.70, 1.00)
	# Open pouch body (lower)
	_ellipse(img, 12, 16, 7, 5, c_bg)
	_ellipse(img, 12, 16, 5, 3, c_bg.lightened(0.25))
	_rect(img, 8, 10, 8, 5, c_bg)
	_rect(img, 8, 10, 2, 5, c_bg.lightened(0.2))
	# Tie/opening
	_rect(img, 7, 14, 10, 2, c_dk)
	# Spilling sparkle particles
	_px(img, 14,  8, c_sp); _px(img, 16,  6, c_glo); _px(img, 10,  7, c_sp)
	_px(img, 18, 10, c_glo); _px(img, 7,  9, c_sp);  _px(img, 12,  5, c_glo)
	_px(img, 19,  7, c_sp); _px(img,  5, 12, c_glo)
	_outline(img); _save(img, "magic_dust")

func _gen_timber() -> void:
	var img := _img()
	var c_lt := Color(0.82, 0.68, 0.42); var c_md := Color(0.62, 0.48, 0.25); var c_dk := Color(0.38, 0.25, 0.10)
	# Two stacked planks (top plank slightly lighter)
	_rect(img, 2, 7, 20, 5, c_lt)
	_rect(img, 2, 7, 20, 1, c_lt.lightened(0.3))   # top shine
	_rect(img, 2, 12, 1, 5, c_md)                   # left side of plank 1
	# Second plank below (darker)
	_rect(img, 2, 14, 20, 5, c_md)
	_rect(img, 2, 14, 20, 1, c_md.lightened(0.2))
	_rect(img, 2, 19, 1, 4, c_dk)
	# Nail heads (small dots)
	_px(img,  5,  9, c_dk); _px(img, 18,  9, c_dk)
	_px(img,  5, 16, c_dk); _px(img, 18, 16, c_dk)
	_outline(img); _save(img, "timber")

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY D — individual tools / weapons
# ══════════════════════════════════════════════════════════════════════════════
func _gen_wooden_fishing_pole() -> void:
	var img := _img()
	# Long thin diagonal pole
	_line(img, 2, 22, 21, 3, OAK_MD, 2)
	_line(img, 3, 21, 20, 4, OAK_LT, 1)   # highlight
	# Fishing line
	_bline(img, 21, 3, 23, 14, Color(0.70, 0.70, 0.70))
	# Float
	_circle(img, 22, 16, 2, Color(0.92, 0.25, 0.18))
	_outline(img); _save(img, "wooden_fishing_pole")

func _gen_fishing_pole() -> void:
	var img := _img()
	# Oak pole (slightly thicker, darker)
	_line(img, 2, 22, 21, 3, OAK_DK, 3)
	_line(img, 3, 21, 20, 4, OAK_MD, 1)
	# Reel bump (small circle on handle)
	_circle(img, 6, 18, 3, OAK_DK.lightened(0.1))
	# Line + float
	_bline(img, 21, 3, 23, 13, Color(0.65, 0.65, 0.68))
	_circle(img, 23, 15, 2, Color(0.20, 0.55, 0.92))
	_outline(img); _save(img, "fishing_pole")

func _gen_ironwood_bow() -> void:
	var img := _img()
	var c_dk := IRW_DK; var c_md := IRW_MD; var c_lt := IRW_LT
	# Bow arc (left side curve)
	_bline(img,  9,  2, 4,  7, c_md)
	_bline(img,  4,  7, 3, 12, c_md)
	_bline(img,  3, 12, 4, 17, c_md)
	_bline(img,  4, 17, 9, 22, c_md)
	# Bow thickness (right side of stave)
	_bline(img, 11,  2, 6,  7, c_lt)
	_bline(img,  6,  7, 5, 12, c_lt)
	_bline(img,  5, 12, 6, 17, c_lt)
	_bline(img,  6, 17, 11, 22, c_lt)
	_bline(img,  8,  2, 5,  7, c_dk)
	_bline(img,  5, 17, 8, 22, c_dk)
	# Bowstring
	_bline(img, 10, 2, 10, 22, Color(0.82, 0.78, 0.68))
	# Nocks
	_circle(img, 10, 2,  2, c_dk); _circle(img, 10, 22, 2, c_dk)
	_outline(img); _save(img, "ironwood_bow")

func _gen_gold_amulet() -> void:
	var img := _img()
	var c_gd := Color(0.95, 0.82, 0.15); var c_dg := Color(0.65, 0.52, 0.05); var c_sh := Color(1.0, 0.96, 0.55)
	# Chain loop top
	_bline(img, 10, 4, 14, 4, Color(0.75, 0.65, 0.12))
	_bline(img,  8, 5, 10, 4, Color(0.75, 0.65, 0.12))
	_bline(img, 14, 4, 16, 5, Color(0.75, 0.65, 0.12))
	# Pendant disk
	_circle(img, 12, 14, 7,   c_dg)
	_circle(img, 12, 14, 6,   c_gd)
	_circle(img, 12, 14, 4,   c_dg)  # inner ring
	_circle(img, 12, 14, 2.5, c_gd)  # center
	# Engraved rune lines on pendant
	_bline(img,  9, 14, 15, 14, c_dg)  # horizontal line
	_bline(img, 12, 11, 12, 17, c_dg)  # vertical line
	# Shine pixel
	_px(img, 15, 11, c_sh)
	_outline(img); _save(img, "gold_amulet")

func _gen_mithril_sword() -> void:
	var img := _img()
	var c_bl := Color(0.42, 0.68, 0.92); var c_lt := Color(0.72, 0.88, 0.98); var c_dk := Color(0.22, 0.42, 0.68)
	var c_gd := Color(0.82, 0.70, 0.18)
	# Blade (diamond cross-section, tapering to point)
	_line(img, 12, 2, 12, 18, c_dk, 3)    # blade centerline
	_bline(img, 10, 6, 12, 2,  c_bl)      # left edge
	_bline(img, 14, 6, 12, 2,  c_bl)      # right edge
	_line(img, 11, 6, 11, 18,  c_bl, 1)   # left face
	_line(img, 13, 6, 13, 18,  c_lt, 1)   # right face (highlight)
	# Guard (crossguard)
	_rect(img, 7, 17, 10, 3, c_gd)
	_rect(img, 7, 17, 10, 1, c_gd.lightened(0.3))
	# Grip
	_rect(img, 10, 20, 4, 3, OAK_DK)
	_rect(img, 11, 20, 1, 3, OAK_LT)     # grip highlight
	# Pommel
	_circle(img, 12, 23, 2, c_gd)
	# Rune glow on blade
	_px(img, 12,  9, c_lt); _px(img, 12, 13, c_lt)
	_outline(img); _save(img, "mithril_sword")

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY E — Cooked food
# ══════════════════════════════════════════════════════════════════════════════
func _gen_cooked_fish() -> void:
	var img := _img()
	var c_bk := Color(0.45, 0.28, 0.08); var c_bd := Color(0.80, 0.55, 0.22); var c_lt := Color(0.98, 0.80, 0.45)
	# Reuse fish shape, warm browned colors
	_ellipse(img, 14, 12, 8, 5, c_bd)
	_ellipse(img, 14, 10, 8, 3, c_bk)
	_line(img, 4,  7, 9, 12, c_bk, 2)
	_line(img, 4, 17, 9, 12, c_bk, 2)
	_line(img, 12, 7, 16, 9, c_bk, 1)
	_circle(img, 19, 10, 2, WHITE); _px(img, 19, 10, Color(0.1,0.1,0.1))
	# Cooked highlight on top
	_ellipse(img, 12, 10, 4, 2, c_lt)
	# Steam (3 small white wavy pixels above)
	_px(img, 10, 5, WHITE); _px(img, 11, 4, WHITE); _px(img, 12, 5, WHITE)
	_px(img, 14, 4, WHITE); _px(img, 15, 5, WHITE)
	_outline(img); _save(img, "cooked_fish")

func _gen_herb_tea() -> void:
	var img := _img()
	var c_cup := Color(0.55, 0.38, 0.18); var c_lt  := Color(0.78, 0.58, 0.28)
	var c_liq := Color(0.42, 0.78, 0.32); var c_ldk := Color(0.18, 0.50, 0.10)
	# Cup body
	_rect(img, 6, 13, 12, 8, c_cup)
	_rect(img, 6, 13, 12, 1, c_lt)   # rim
	_rect(img, 7, 13, 2, 8, c_lt)    # highlight
	# Handle
	_bline(img, 18, 14, 21, 15, c_cup)
	_bline(img, 21, 15, 21, 18, c_cup)
	_bline(img, 18, 20, 21, 18, c_cup)
	# Tea surface in cup
	_rect(img, 7, 14, 10, 3, c_liq)
	_rect(img, 7, 14, 3,  3, c_ldk)   # darker depth
	# Steam
	_px(img,  9, 10, WHITE); _px(img,  8, 9, WHITE); _px(img,  9, 8, WHITE)
	_px(img, 13, 10, WHITE); _px(img, 14, 9, WHITE); _px(img, 13, 8, WHITE)
	_outline(img); _save(img, "herb_tea")

func _gen_cooked_salmon() -> void:
	var img := _img()
	var c_bk := Color(0.55, 0.20, 0.08); var c_bd := Color(0.88, 0.48, 0.22); var c_lt := Color(1.00, 0.72, 0.48)
	_ellipse(img, 14, 12, 8, 5, c_bd)
	_ellipse(img, 14, 10, 8, 3, c_bk)
	_line(img, 4,  7, 9, 12, c_bk, 2)
	_line(img, 4, 17, 9, 12, c_bk, 2)
	_ellipse(img, 12, 10, 4, 2, c_lt)   # cooked highlight
	_circle(img, 19, 10, 2, WHITE); _px(img, 19, 10, Color(0.1,0.1,0.1))
	# Charred grill stripe
	_line(img, 8, 14, 18, 10, Color(0.25, 0.12, 0.04), 1)
	# Steam
	_px(img, 10, 5, WHITE); _px(img, 13, 4, WHITE); _px(img, 16, 5, WHITE)
	_outline(img); _save(img, "cooked_salmon")

func _gen_cooked_lobster() -> void:
	var img := _img()
	var c_dk := Color(0.48, 0.08, 0.04); var c_md := Color(0.75, 0.18, 0.08); var c_lt := Color(0.92, 0.42, 0.28)
	_ellipse(img, 12, 14, 6, 4, c_md); _ellipse(img, 12, 11, 4, 3, c_md); _ellipse(img, 12, 8, 3, 2, c_dk)
	_ellipse(img, 5, 11, 4, 3, c_md); _ellipse(img, 5, 11, 2, 1, c_lt)
	_ellipse(img, 19, 11, 4, 3, c_md); _ellipse(img, 19, 11, 2, 1, c_lt)
	_bline(img, 10, 7, 4, 2, c_dk); _bline(img, 14, 7, 20, 2, c_dk)
	_ellipse(img, 12, 18, 5, 3, c_dk); _ellipse(img, 12, 18, 3, 1, c_md)
	# Cooked darkening + shine
	_ellipse(img, 12, 11, 2, 1, c_lt)
	_px(img, 9, 7, Color(0.1,0.1,0.1)); _px(img, 15, 7, Color(0.1,0.1,0.1))
	_outline(img); _save(img, "cooked_lobster")

func _gen_cooked_shark() -> void:
	var img := _img()
	var c_dk := Color(0.25, 0.26, 0.30); var c_md := Color(0.42, 0.44, 0.50); var c_lt := Color(0.65, 0.68, 0.72)
	# Fillet rectangle shape (not full shark)
	_rect(img, 3, 9, 18, 8, c_md)
	_rect(img, 3, 9, 18, 2, c_lt)    # top cooked highlight
	_rect(img, 3, 15, 18, 2, c_dk)   # bottom shadow
	# Grill lines
	for gx: int in [6, 10, 14, 18]:
		_bline(img, gx, 9, gx - 2, 17, Color(0.18, 0.18, 0.20))
	# Skin strip on top
	_rect(img, 3, 8, 18, 2, c_dk)
	# Steam
	_px(img, 7, 6, WHITE); _px(img, 12, 5, WHITE); _px(img, 17, 6, WHITE)
	_outline(img); _save(img, "cooked_shark")

func _gen_eel_stew() -> void:
	var img := _img()
	var c_bowl := Color(0.42, 0.28, 0.10); var c_blt  := Color(0.65, 0.48, 0.22)
	var c_stew := Color(0.18, 0.38, 0.28); var c_slt  := Color(0.28, 0.55, 0.40)
	# Bowl body
	_ellipse(img, 12, 17, 9, 6, c_bowl)
	_ellipse(img, 12, 17, 7, 4, c_bowl.lightened(0.1))
	# Bowl rim
	_rect(img, 4, 12, 16, 2, c_blt)
	# Stew surface
	_ellipse(img, 12, 12, 7, 3, c_stew)
	_ellipse(img, 10, 11, 3, 2, c_slt)   # lighter bit
	# Eel chunk poking out
	_ellipse(img, 15, 11, 3, 2, Color(0.15, 0.30, 0.25))
	# Steam
	_px(img, 9,  8, WHITE); _px(img, 12, 7, WHITE); _px(img, 15, 8, WHITE)
	_outline(img); _save(img, "eel_stew")

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY F — Construction outputs
# ══════════════════════════════════════════════════════════════════════════════
func _gen_wooden_chair() -> void:
	var img := _img()
	var c_dk := OAK_DK; var c_md := OAK_MD; var c_lt := OAK_LT
	# Back vertical
	_rect(img,  4,  4, 4, 16, c_md)
	_rect(img,  4,  4, 1, 16, c_lt)
	# Back rail (horizontal bar)
	_rect(img,  4,  6, 12, 2, c_md); _rect(img, 4, 6, 12, 1, c_lt)
	# Seat
	_rect(img,  4, 14, 14, 4, c_md); _rect(img, 4, 14, 14, 1, c_lt)
	# Front right leg
	_rect(img, 15, 18, 4, 5, c_dk)
	_rect(img, 15, 18, 1, 5, c_md)
	# Seat underside detail
	_rect(img, 5, 18, 12, 1, c_dk)
	_outline(img); _save(img, "wooden_chair")

func _gen_wooden_table() -> void:
	var img := _img()
	var c_dk := OAK_DK; var c_md := OAK_MD; var c_lt := OAK_LT
	# Table top
	_rect(img, 2, 7, 20, 5, c_md)
	_rect(img, 2, 7, 20, 1, c_lt)   # top shine
	_rect(img, 2, 11, 20, 1, c_dk)  # underside shadow
	# Left leg
	_rect(img,  4, 12, 3, 10, c_dk); _rect(img, 4, 12, 1, 10, c_md)
	# Right leg
	_rect(img, 17, 12, 3, 10, c_dk); _rect(img, 17, 12, 1, 10, c_md)
	# Cross brace
	_rect(img, 7, 17, 10, 2, c_dk)
	_outline(img); _save(img, "wooden_table")

func _gen_pine_bookshelf() -> void:
	var img := _img()
	var c_dk := PINE_DK; var c_md := PINE_MD; var c_lt := PINE_LT
	# Frame
	_rect(img, 2, 2, 3, 21, c_md);   _rect(img, 2, 2, 1, 21, c_lt)   # left side
	_rect(img, 19, 2, 3, 21, c_md)                                     # right side
	_rect(img, 2, 2, 20, 3, c_md);   _rect(img, 2, 2, 20, 1, c_lt)   # top shelf
	_rect(img, 2, 12, 20, 2, c_md)                                     # mid shelf
	_rect(img, 2, 21, 20, 2, c_dk)                                     # bottom
	# Book spines (top shelf)
	var book_cols: Array[Color] = [Color(0.85,0.15,0.15), Color(0.15,0.35,0.85),
		Color(0.85,0.75,0.15), Color(0.15,0.65,0.25)]
	for i in range(4):
		_rect(img, 5 + i * 3, 4, 3, 7, book_cols[i])
	# Book spines (bottom shelf)
	var book_cols2: Array[Color] = [Color(0.55,0.25,0.75), Color(0.85,0.42,0.12), Color(0.15,0.68,0.68)]
	for i in range(3):
		_rect(img, 5 + i * 4, 14, 3, 7, book_cols2[i])
	_outline(img); _save(img, "pine_bookshelf")

func _gen_cherry_chest() -> void:
	var img := _img()
	var c_dk := CHR_DK; var c_md := CHR_MD; var c_lt := CHR_LT
	var c_mt := Color(0.65, 0.60, 0.22)   # metal clasp color
	# Chest body
	_rect(img, 2, 13, 20, 9, c_md)
	_rect(img, 2, 13, 20, 2, c_lt)   # front face top highlight
	_rect(img, 2, 20, 20, 2, c_dk)   # bottom shadow
	# Lid (rounded top)
	_rect(img, 2, 6, 20, 7, c_md)
	_rect(img, 2, 6, 20, 2, c_lt)
	_ellipse(img, 12, 7, 10, 4, c_md)  # dome top of lid
	_ellipse(img, 12, 6, 9, 2, c_lt)   # dome highlight
	# Hinge line
	_rect(img, 2, 12, 20, 2, c_dk)
	# Metal clasp
	_rect(img, 10, 12, 4, 4, c_mt)
	_circle(img, 12, 14, 1, c_mt.lightened(0.5))
	# Corner studs
	_circle(img,  4,  8, 1, c_mt); _circle(img, 20,  8, 1, c_mt)
	_circle(img,  4, 18, 1, c_mt); _circle(img, 20, 18, 1, c_mt)
	_outline(img); _save(img, "cherry_chest")

func _gen_ironwood_gate() -> void:
	var img := _img()
	var c_dk := IRW_DK; var c_md := IRW_MD; var c_lt := IRW_LT
	var c_ir := Color(0.30, 0.30, 0.32)   # iron hinges
	# Three vertical planks
	for px3: int in [3, 9, 15]:
		_rect(img, px3, 2, 5, 21, c_md)
		_rect(img, px3, 2, 1, 21, c_lt)
		_rect(img, px3 + 4, 2, 1, 21, c_dk)
	# Horizontal cross-bar
	_rect(img, 2, 9, 20, 3, c_dk)
	_rect(img, 2, 9, 20, 1, c_md)   # cross-bar highlight
	# Iron hinges (left side)
	_circle(img, 3, 5,  2, c_ir); _circle(img, 3, 18, 2, c_ir)
	_outline(img); _save(img, "ironwood_gate")

func _gen_frost_cabin() -> void:
	var img := _img()
	var c_wall := Color(0.78, 0.88, 0.96); var c_roof := Color(0.92, 0.96, 1.00)
	var c_dk   := Color(0.45, 0.62, 0.80); var c_dr   := Color(0.38, 0.22, 0.10)
	# Cabin walls
	_rect(img, 3, 12, 18, 10, c_wall)
	_rect(img, 3, 12,  2, 10, c_dk)       # left wall shadow
	_rect(img, 3, 21, 18,  1, c_dk)       # ground shadow
	# Roof (triangle using lines)
	_bline(img,  2, 12, 12,  3, c_dk)     # left roof edge
	_bline(img, 22, 12, 12,  3, c_dk)     # right roof edge
	_bline(img,  3, 12, 12,  4, c_roof)   # left roof fill line
	_bline(img, 21, 12, 12,  4, c_roof)
	for row in range(9):
		var left  := 12 - row
		var right := 12 + row
		_bline(img, left, 12 - row + row, right, 12 - row + row, c_roof)
	# Fill roof area more cleanly with triangular sweep
	for row2 in range(9):
		var rl := 3 + row2; var rr := 21 - row2; var ry := 11 - row2
		_rect(img, rl, ry, rr - rl + 1, 1, c_roof)
	# Door
	_rect(img, 10, 16, 5, 6, c_dr)
	_rect(img, 11, 16, 1, 6, c_dr.lightened(0.25))
	# Window
	_rect(img, 5, 14, 4, 4, Color(0.70, 0.88, 0.98)); _rect(img, 5, 14, 4, 1, WHITE)
	# Snow on roof peak
	_circle(img, 12, 4, 2, WHITE)
	_outline(img); _save(img, "frost_cabin")

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY G — Monster drops
# ══════════════════════════════════════════════════════════════════════════════
func _gen_rat_bone() -> void:
	var img := _img()
	var c_bn := Color(0.92, 0.90, 0.80); var c_sh := Color(0.70, 0.68, 0.58)
	# Horizontal shaft
	_rect(img, 5, 11, 14, 3, c_bn); _rect(img, 5, 11, 14, 1, WHITE)
	# Knob ends (left and right)
	_circle(img,  5, 12, 3, c_bn); _circle(img, 18, 12, 3, c_bn)
	_px(img,  4, 11, WHITE); _px(img, 17, 11, WHITE)
	# Vertical shaft (short, going down)
	_rect(img, 10, 14, 3, 8, c_bn); _rect(img, 10, 14, 1, 8, WHITE)
	_circle(img, 11, 22, 3, c_bn); _circle(img, 11, 22, 1, c_sh)
	_outline(img); _save(img, "rat_bone")

func _gen_bone() -> void:
	var img := _img()
	var c_bn := Color(0.92, 0.90, 0.80); var c_sh := Color(0.68, 0.66, 0.55)
	# Diagonal bone
	_line(img, 5, 19, 19, 5, c_bn, 3)
	_line(img, 6, 18, 18, 6, WHITE, 1)   # highlight
	# Four rounded knobs at ends
	_circle(img,  4, 20, 4, c_bn); _circle(img,  4, 20, 2, c_sh)
	_circle(img,  8, 16, 3, c_bn); _circle(img,  8, 16, 1, c_sh)
	_circle(img, 20, 4,  4, c_bn); _circle(img, 20, 4,  2, c_sh)
	_circle(img, 16, 8,  3, c_bn); _circle(img, 16, 8,  1, c_sh)
	_outline(img); _save(img, "bone")

func _gen_goblin_ear() -> void:
	var img := _img()
	var c_dk := Color(0.12, 0.35, 0.05); var c_md := Color(0.22, 0.58, 0.10); var c_lt := Color(0.42, 0.80, 0.25)
	var c_in := Color(0.50, 0.20, 0.18)  # inner ear pink
	# Pointed ear shape (left-facing)
	_bline(img, 7, 20, 7,  5, c_md)    # left edge vertical
	_bline(img, 7,  5, 18, 2, c_md)    # diagonal to point
	_bline(img, 7, 20, 18, 2, c_dk)    # right edge diagonal
	# Fill the ear triangle
	for y in range(5, 21):
		var t := float(y - 5) / 15.0
		var left_x  := 7
		var right_x := int(7.0 + t * 11.0)  # expands as we go down
		_rect(img, left_x, y, right_x - left_x + 1, 1, c_md if y < 13 else c_lt)
	# Inner ear
	_bline(img, 8, 18, 15, 8, c_in)
	_bline(img, 9, 18, 14, 9, c_in)
	_outline(img); _save(img, "goblin_ear")

func _gen_draugr_shard() -> void:
	var img := _img()
	var c_dk := Color(0.22, 0.28, 0.38); var c_md := Color(0.38, 0.48, 0.62); var c_lt := Color(0.60, 0.72, 0.88)
	# Jagged crystal shard (hexagonal-ish)
	_bline(img, 12,  2, 20, 8,  c_md)   # right top edge
	_bline(img, 20,  8, 18, 20, c_dk)   # right bottom edge
	_bline(img, 18, 20,  4, 16, c_dk)   # bottom edge
	_bline(img,  4, 16,  6,  6, c_md)   # left bottom edge
	_bline(img,  6,  6, 12,  2, c_md)   # left top edge
	# Fill interior
	for y2 in range(3, 20):
		var prog := float(y2 - 2) / 17.0
		var xl: int = int(6.0 + prog * 2.0) if y2 < 10 else int(5.0 + (1.0 - prog) * 13.0)
		var xr: int = int(12.0 + prog * 8.0) if y2 < 10 else int(20.0 - (prog - 0.5) * 4.0)
		if xr > xl: _rect(img, xl, y2, xr - xl, 1, c_md)
	# Face highlight
	_line(img, 12, 3, 16, 10, c_lt, 1)
	# Rune scratch
	_bline(img, 9, 12, 15, 8, c_dk)
	_outline(img); _save(img, "draugr_shard")

func _gen_dragon_scale() -> void:
	var img := _img()
	var c_dk := Color(0.08, 0.28, 0.22); var c_md := Color(0.15, 0.52, 0.40); var c_lt := Color(0.28, 0.78, 0.58)
	var c_sh := Color(0.42, 0.92, 0.70)
	# Teardrop / scale shape — wide at top, pointed at bottom
	_ellipse(img, 12, 10, 9, 8, c_dk)
	_ellipse(img, 12, 10, 7, 6, c_md)
	_bline(img, 7, 16, 12, 22, c_dk)   # left taper to point
	_bline(img, 17, 16, 12, 22, c_dk)  # right taper
	# Fill tapered area
	for y3 in range(16, 22):
		var prog3 := float(y3 - 16) / 6.0
		var w3 := int((1.0 - prog3) * 9.0)
		if w3 > 0: _rect(img, 12 - w3 / 2, y3, w3, 1, c_md)
	# Iridescent sheen
	_ellipse(img, 10, 8, 4, 3, c_lt)
	_px(img, 9, 7, c_sh); _px(img, 11, 6, c_sh)
	_outline(img); _save(img, "dragon_scale")

func _gen_feather() -> void:
	var img := _img()
	var c_sh := Color(0.85, 0.82, 0.70); var c_vn := Color(0.40, 0.28, 0.10)
	# Central rachis (quill spine)
	_line(img, 12, 2, 12, 22, c_vn, 1)
	# Barb strokes on left side
	for i in range(10):
		var y4 := 4 + i * 2
		_bline(img, 12, y4, 12 - 5 + i / 2, y4 + 1, c_sh)
		_bline(img, 12 - 5 + i / 2, y4 + 1, 4 + i / 3, y4 + 2, c_sh)
	# Barb strokes on right side
	for j in range(10):
		var y5 := 4 + j * 2
		_bline(img, 12, y5, 12 + 5 - j / 2, y5 + 1, c_sh)
		_bline(img, 12 + 5 - j / 2, y5 + 1, 20 - j / 3, y5 + 2, c_sh)
	# Quill tip (bottom)
	_line(img, 12, 20, 12, 23, c_vn, 1)
	_px(img, 12, 2, c_sh)  # tip shine
	_outline(img); _save(img, "feather")

func _gen_wolf_pelt() -> void:
	var img := _img()
	var c_dk := Color(0.28, 0.25, 0.20); var c_md := Color(0.52, 0.48, 0.40); var c_lt := Color(0.72, 0.68, 0.58)
	# Irregular fur patch shape
	_ellipse(img, 12, 12, 9, 8, c_md)
	# Fur edges (irregular bumps at outline)
	_circle(img,  4,  8, 3, c_md); _circle(img, 20, 7, 3, c_md)
	_circle(img,  3, 14, 3, c_md); _circle(img, 21, 15, 3, c_md)
	_circle(img,  5, 20, 3, c_md); _circle(img, 18, 20, 3, c_md)
	_circle(img, 12,  3, 3, c_md); _circle(img, 12, 21, 3, c_md)
	# Inner dark patch (shadow center)
	_ellipse(img, 12, 13, 5, 4, c_dk)
	# Highlight tufts
	_px(img, 10, 9, c_lt); _px(img, 14, 7, c_lt); _px(img, 16, 12, c_lt)
	_px(img,  8, 14, c_lt); _px(img, 15, 17, c_lt)
	_outline(img); _save(img, "wolf_pelt")

func _gen_bandit_hood() -> void:
	var img := _img()
	var c_dk := Color(0.08, 0.06, 0.05); var c_md := Color(0.18, 0.14, 0.12); var c_lt := Color(0.32, 0.26, 0.22)
	# Hood outer shape
	_ellipse(img, 12, 10, 10, 10, c_md)
	_rect(img, 2, 10, 20, 12, c_md)    # face opening bottom
	# Hood shadow / depth
	_ellipse(img, 12, 10, 8, 8, c_dk)
	# Face cut-out (opening)
	_ellipse(img, 12, 13, 7, 5, TRANS) # erase face area → transparent
	# But since we can't easily "erase" with set_pixel in this flow, we'll redraw:
	# Just draw the face opening as a very dark gap
	_ellipse(img, 12, 13, 6, 4, Color(0.04, 0.03, 0.03))
	# Two glinting eyes
	_px(img,  9, 12, Color(0.88, 0.78, 0.22)); _px(img, 10, 12, Color(0.88, 0.78, 0.22))
	_px(img, 14, 12, Color(0.88, 0.78, 0.22)); _px(img, 15, 12, Color(0.88, 0.78, 0.22))
	# Edge highlight on hood brow
	_bline(img, 4, 6, 20, 6, c_lt)
	_outline(img); _save(img, "bandit_hood")

func _gen_bear_claw() -> void:
	var img := _img()
	var c_dk := Color(0.32, 0.20, 0.06); var c_md := Color(0.62, 0.42, 0.18); var c_lt := Color(0.88, 0.72, 0.48)
	var c_tp := Color(0.95, 0.92, 0.85)  # tip
	# Curved claw shape — arc from top-right to bottom-center
	_bline(img, 16, 3, 20, 8,  c_md)
	_bline(img, 20, 8, 20, 15, c_md)
	_bline(img, 20, 15, 16, 20, c_md)
	_bline(img, 16, 20, 10, 22, c_md)
	_bline(img, 10, 22, 6, 21,  c_md)
	# Inner curve
	_bline(img, 14, 4, 17, 9,  c_lt)
	_bline(img, 17, 9, 17, 16, c_lt)
	_bline(img, 17, 16, 14, 20, c_lt)
	# Fill with a sweeping rect
	_rect(img, 13, 4, 8, 17, c_md)
	_rect(img, 13, 4, 3, 17, c_lt)   # inner face lighter
	_rect(img, 13, 4, 8,  2, c_lt)   # top face
	# Base (where it was attached)
	_ellipse(img, 10, 5, 6, 4, c_dk)
	_ellipse(img, 10, 5, 4, 2, c_md)
	# Pointed tip
	_circle(img, 7, 21, 2, c_tp)
	_outline(img); _save(img, "bear_claw")

func _gen_troll_hide() -> void:
	var img := _img()
	var c_dk := Color(0.18, 0.22, 0.08); var c_md := Color(0.32, 0.42, 0.14); var c_lt := Color(0.48, 0.58, 0.24)
	# Rough hide patch shape
	_ellipse(img, 12, 12, 10, 9, c_md)
	_circle(img,  4, 8,  3, c_md); _circle(img, 20, 8, 3, c_md)
	_circle(img,  3, 15, 3, c_md); _circle(img, 21, 16, 3, c_md)
	_circle(img, 12, 21, 3, c_md)
	# Texture — darker warts/bumps
	for wx: int in [6, 10, 16, 14, 8]:
		for wy: int in [7, 11, 15, 9, 18]:
			if wx + wy < 30: _circle(img, wx, wy, 1, c_dk)
	# Highlight area
	_ellipse(img, 10, 9, 3, 2, c_lt)
	_outline(img); _save(img, "troll_hide")

func _gen_spirit_essence() -> void:
	var img := _img()
	var c_dk := Color(0.05, 0.30, 0.08); var c_md := Color(0.18, 0.62, 0.22); var c_lt := Color(0.45, 0.92, 0.50)
	var c_wh := Color(0.85, 1.00, 0.88)
	# Orb core
	_circle(img, 12, 12, 7, c_md)
	_circle(img, 12, 12, 5, c_lt)
	_circle(img, 12, 12, 3, c_wh)
	# Wisp trails (3 curved tendrils)
	_bline(img, 12, 5, 8, 2, c_md); _bline(img, 8, 2, 5, 4, c_md)
	_bline(img, 18, 9, 22, 6, c_md); _bline(img, 22, 6, 21, 3, c_md)
	_bline(img, 12, 19, 8, 22, c_md)
	# Glow pixels at tips
	_px(img,  5, 4, c_lt); _px(img, 21, 3, c_lt); _px(img, 8, 22, c_lt)
	_outline(img); _save(img, "spirit_essence")

func _gen_spider_silk() -> void:
	var img := _img()
	var c_sl := Color(0.88, 0.88, 0.92); var c_dk := Color(0.55, 0.55, 0.62)
	# Silk spool (rolled thread)
	_ellipse(img, 12, 12, 8, 6, c_dk)   # spool body
	_ellipse(img, 12, 12, 6, 4, c_sl)   # silk wrapped on spool
	_ellipse(img, 12, 12, 3, 2, c_dk)   # inner spool center
	# Spool flanges (left and right caps)
	_ellipse(img,  5, 12, 3, 6, c_dk)
	_ellipse(img, 19, 12, 3, 6, c_dk)
	_ellipse(img,  5, 12, 2, 5, c_sl)
	_ellipse(img, 19, 12, 2, 5, c_sl)
	# Strands of silk coming off
	_bline(img, 12, 6, 18, 2, c_sl); _bline(img, 12, 6, 6, 2, c_sl)
	_px(img, 13, 10, WHITE); _px(img, 11, 14, WHITE)  # shine pixels
	_outline(img); _save(img, "spider_silk")

func _gen_ice_fang() -> void:
	var img := _img()
	var c_dk := Color(0.38, 0.58, 0.78); var c_md := Color(0.65, 0.82, 0.96); var c_lt := Color(0.88, 0.95, 1.00)
	# Fang tooth shape — wide at base, tapers to point at bottom
	_ellipse(img, 12, 8,  6, 6, c_md)   # base bulge
	# Tapering shaft
	for y6 in range(10, 22):
		var w6 := int((1.0 - float(y6 - 10) / 12.0) * 8.0)
		if w6 > 0: _rect(img, 12 - w6 / 2, y6, w6, 1, c_md)
	# Translucent inner (lighter blue)
	_ellipse(img, 12, 9,  4, 4, c_lt)
	for y7 in range(10, 18):
		var w7 := int((1.0 - float(y7 - 10) / 9.0) * 4.0)
		if w7 > 0: _rect(img, 12 - w7 / 2, y7, w7, 1, c_lt)
	# Root (base) darkened
	_ellipse(img, 12, 7, 6, 3, c_dk)
	_px(img, 12, 21, c_lt)   # needle tip gleam
	_outline(img); _save(img, "ice_fang")

func _gen_frost_crystal() -> void:
	var img := _img()
	var c_dk := Color(0.38, 0.60, 0.82); var c_md := Color(0.62, 0.82, 0.96); var c_lt := Color(0.88, 0.95, 1.00)
	# Six-pointed snowflake — 3 crossing lines through center
	_line(img,  2, 12, 22, 12, c_md, 2)     # horizontal
	_line(img, 12,  2, 12, 22, c_md, 2)     # vertical
	_line(img,  4,  4, 20, 20, c_md, 2)     # diagonal NW-SE
	_line(img, 20,  4,  4, 20, c_md, 2)     # diagonal NE-SW
	# Arm tips
	for tip: Vector2i in [Vector2i(2,12),Vector2i(22,12),Vector2i(12,2),Vector2i(12,22),
						   Vector2i(4,4),Vector2i(20,20),Vector2i(20,4),Vector2i(4,20)]:
		_circle(img, tip.x, tip.y, 2, c_dk)
		_px(img, tip.x, tip.y, c_lt)
	# Center highlight
	_circle(img, 12, 12, 3, c_lt)
	_px(img, 12, 12, WHITE)
	_outline(img); _save(img, "frost_crystal")

func _gen_ice_shard() -> void:
	var img := _img()
	var c_dk := Color(0.42, 0.62, 0.82); var c_md := Color(0.65, 0.82, 0.96); var c_lt := Color(0.88, 0.96, 1.00)
	# Jagged polygon shard
	_bline(img, 10,  2, 20,  6, c_md)
	_bline(img, 20,  6, 22, 16, c_md)
	_bline(img, 22, 16, 14, 22, c_dk)
	_bline(img, 14, 22,  4, 18, c_dk)
	_bline(img,  4, 18,  2, 10, c_dk)
	_bline(img,  2, 10, 10,  2, c_md)
	# Fill interior
	_circle(img, 13, 12, 9, c_md)
	# Crack line
	_bline(img, 12, 4, 8, 18, c_dk)
	# Face highlight (right side, lighter)
	_bline(img, 16, 6, 20, 14, c_lt)
	_bline(img, 17, 6, 21, 14, c_lt)
	_outline(img); _save(img, "ice_shard")

func _gen_imp_horn() -> void:
	var img := _img()
	var c_dk := Color(0.45, 0.05, 0.03); var c_md := Color(0.82, 0.15, 0.08); var c_lt := Color(1.00, 0.42, 0.30)
	var c_tp := Color(0.20, 0.08, 0.04)  # dark tip
	# Curved horn — wide base, curves to pointed tip at top-right
	# Base (thick)
	_ellipse(img, 8, 18, 6, 4, c_dk)
	_ellipse(img, 8, 18, 4, 2, c_md)
	# Curving shaft
	_bline(img,  8, 14, 12, 8, c_md)
	_bline(img, 12,  8, 18, 4, c_md)
	_bline(img,  9, 14, 13, 8, c_lt)
	_bline(img, 13,  8, 19, 4, c_lt)
	# Thickness (parallel lines)
	_bline(img, 8, 17, 12, 11, c_md)
	_bline(img, 12, 11, 17, 6, c_md)
	# Fill body
	_line(img, 8, 16, 16, 6, c_md, 3)
	_line(img, 9, 15, 15, 7, c_lt, 1)
	# Tip
	_circle(img, 19, 4, 2, c_tp)
	_outline(img); _save(img, "imp_horn")

func _gen_lava_carapace() -> void:
	var img := _img()
	var c_pl := Color(0.22, 0.22, 0.24); var c_md := Color(0.38, 0.38, 0.40); var c_lv := Color(0.90, 0.42, 0.05)
	# Three segmented plates stacked
	for seg in range(3):
		var sy := 4 + seg * 6
		_rect(img, 3, sy, 18, 5, c_md)
		_rect(img, 3, sy, 18, 1, c_md.lightened(0.3))   # top edge shine
		_rect(img, 3, sy + 4, 18, 1, c_pl)               # bottom shadow
		# Lava seam between segments (glowing orange line)
		if seg < 2:
			_rect(img, 3, sy + 5, 18, 1, c_lv)
			_px(img,  6, sy + 5, c_lv.lightened(0.4))
			_px(img, 12, sy + 5, c_lv.lightened(0.5))
			_px(img, 18, sy + 5, c_lv.lightened(0.4))
	# Side claws (left and right)
	_line(img, 2,  7, 0, 11, c_pl, 1); _line(img, 2, 13, 0, 17, c_pl, 1)
	_line(img, 21, 7, 23, 11, c_pl, 1); _line(img, 21, 13, 23, 17, c_pl, 1)
	_outline(img); _save(img, "lava_carapace")

func _gen_giant_ember() -> void:
	var img := _img()
	var c_dk := Color(0.18, 0.08, 0.02); var c_md := Color(0.55, 0.22, 0.04); var c_or := Color(0.90, 0.48, 0.08)
	var c_yw := Color(1.00, 0.82, 0.20)
	# Irregular coal chunk
	_circle(img, 12, 13, 9, c_dk)
	_circle(img, 10, 11, 7, c_md)
	_circle(img, 15,  9, 5, c_md)
	# Glowing interior
	_circle(img, 12, 13, 5, c_or)
	_circle(img, 12, 13, 2, c_yw)
	# Ember sparks / heat pixels
	_px(img, 10,  4, c_or); _px(img, 14,  3, c_yw); _px(img, 17,  5, c_or)
	_px(img,  8,  6, c_yw); _px(img, 19,  8, c_or); _px(img, 16,  2, c_yw)
	# Surface crack lines showing glowing interior
	_bline(img, 8, 10, 12, 14, c_or); _bline(img, 15, 8, 12, 14, c_or)
	_outline(img); _save(img, "giant_ember")

func _gen_shadow_essence() -> void:
	var img := _img()
	var c_bg := Color(0.05, 0.02, 0.08); var c_rim := Color(0.55, 0.15, 0.82); var c_glo := Color(0.72, 0.35, 0.95)
	# Near-black core orb
	_circle(img, 12, 12, 9,   c_bg)
	_circle(img, 12, 12, 7,   Color(0.08, 0.04, 0.12))
	_circle(img, 12, 12, 4,   c_bg)    # deep void center
	# Purple glow rim
	_bline(img, 3, 12, 12, 3,  c_rim)
	_bline(img, 12, 3, 21, 12, c_rim)
	_bline(img, 21, 12, 12, 21, c_rim)
	_bline(img, 12, 21, 3, 12,  c_rim)
	# Glow arc highlights
	_px(img,  4,  8, c_glo); _px(img,  7,  4, c_glo)
	_px(img, 20,  8, c_glo); _px(img, 17,  4, c_glo)
	_px(img,  4, 16, c_glo); _px(img,  7, 20, c_glo)
	_outline(img); _save(img, "shadow_essence")

func _gen_death_rune() -> void:
	var img := _img()
	var c_st := Color(0.18, 0.15, 0.15); var c_lt := Color(0.30, 0.26, 0.26)
	var c_rn := Color(0.15, 0.90, 0.42); var c_gl := Color(0.55, 1.00, 0.72)
	# Stone tablet (rectangular with slightly rounded bottom)
	_rect(img, 4, 3, 16, 19, c_st)
	_rect(img, 4, 3, 16,  2, c_lt)    # top lighter edge
	_rect(img, 4, 3,  2, 19, c_lt)    # left edge highlight
	_rect(img, 4, 20, 16,  2, Color(0.10, 0.08, 0.08))  # bottom shadow
	# Rounded bottom corners
	_px(img,  4, 21, TRANS); _px(img, 19, 21, TRANS)
	# Rune carving — glowing green (simplified elder futhark rune)
	# Vertical staff
	_line(img, 12, 6, 12, 18, c_rn, 1)
	# Two diagonal branches right
	_bline(img, 12, 8,  17, 11, c_rn)
	_bline(img, 12, 14, 17, 11, c_rn)
	# Two diagonal branches left
	_bline(img, 12, 8,  7, 11, c_rn)
	_bline(img, 12, 14, 7, 11, c_rn)
	# Glow pixels around rune
	_px(img, 10,  7, c_gl); _px(img, 14,  7, c_gl)
	_px(img,  8, 11, c_gl); _px(img, 16, 11, c_gl)
	_px(img, 10, 17, c_gl); _px(img, 14, 17, c_gl)
	_outline(img); _save(img, "death_rune")

func _gen_spectral_essence() -> void:
	var img := _img()
	var c_dk := Color(0.28, 0.42, 0.65); var c_md := Color(0.55, 0.75, 0.95); var c_lt := Color(0.85, 0.92, 1.00)
	var c_wh := Color(0.96, 0.98, 1.00, 0.95)
	# Blue-white translucent orb
	_circle(img, 12, 12, 9, c_dk)
	_circle(img, 12, 12, 7, c_md)
	_circle(img, 12, 12, 4, c_lt)
	_circle(img, 12, 12, 2, c_wh)
	# Ghostly wisp streaks trailing outward
	_bline(img, 17, 7, 22, 4, c_md);  _px(img, 22, 4, c_lt)
	_bline(img, 7, 17, 2, 20, c_md);  _px(img, 2, 20, c_lt)
	_bline(img, 17, 17, 21, 21, c_md); _px(img, 21, 21, c_lt)
	_bline(img, 7, 7, 3, 3, c_md);    _px(img, 3, 3, c_lt)
	# Orbiting particles
	_px(img, 19,  5, WHITE); _px(img, 5, 19, WHITE)
	_px(img, 19, 19, c_lt);  _px(img, 5,  5, c_lt)
	_outline(img); _save(img, "spectral_essence")

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY H — Craftable gear tiers (parametrised by colour)
# ══════════════════════════════════════════════════════════════════════════════
func _gen_gear_tiers() -> void:
	var tiers: Dictionary = {
		"leather": Color(0.52, 0.34, 0.16),
		"copper":  Color(0.82, 0.52, 0.22),
		"iron":    Color(0.62, 0.62, 0.68),
		"gold":    Color(0.95, 0.82, 0.18),
		"mithril": Color(0.45, 0.72, 0.92),
		"adamant": Color(0.24, 0.70, 0.38),
		"runite":  Color(0.72, 0.28, 0.90),
	}
	var metal: Array[String] = ["copper", "iron", "gold", "mithril", "adamant", "runite"]
	for t: String in tiers:
		var c: Color = tiers[t]
		_make_helm("%s_helm" % t, c)
		_make_body("%s_body" % t, c)
		_make_legs("%s_legs" % t, c)
		_make_gloves("%s_gloves" % t, c)
		_make_boots("%s_boots" % t, c)
		_make_shield("%s_shield" % t, c)
	for t: String in metal:
		var c: Color = tiers[t]
		_make_sword("%s_sword" % t, c)
		_make_axe("%s_battleaxe" % t, c, c.lightened(0.3))
		_make_mace("%s_mace" % t, c)
		_make_bow("%s_bow" % t, c)
		_make_staff("%s_staff" % t, c)
		_make_ring("%s_ring" % t, c)
		_make_amulet("%s_amulet" % t, c)
	_make_arrows("arrows")

func _make_helm(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.25)
	_ellipse(img, 12, 10, 8, 7, dk)
	_ellipse(img, 12, 10, 7, 6, c)
	_rect(img, 4, 10, 16, 7, c)
	_rect(img, 4, 10, 16, 2, lt)
	_rect(img, 11, 12, 2, 8, dk)        # nose guard
	_rect(img, 4, 16, 16, 1, dk)
	_outline(img); _save(img, id)

func _make_body(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.25)
	_circle(img, 5, 7, 2, lt); _circle(img, 19, 7, 2, lt)   # shoulders
	_rect(img, 5, 5, 14, 15, c)
	_rect(img, 5, 5, 14, 3, lt)
	_rect(img, 5, 17, 14, 3, dk)
	_ellipse(img, 12, 6, 4, 2, dk)      # neckline
	_line(img, 12, 8, 12, 19, dk, 1)
	_outline(img); _save(img, id)

func _make_legs(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.25)
	_rect(img, 4, 3, 16, 3, dk)         # belt
	_rect(img, 5, 6, 5, 15, c);  _rect(img, 14, 6, 5, 15, c)
	_rect(img, 5, 6, 5, 2, lt);  _rect(img, 14, 6, 5, 2, lt)
	_rect(img, 5, 19, 5, 2, dk); _rect(img, 14, 19, 5, 2, dk)
	_outline(img); _save(img, id)

func _make_gloves(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.25)
	for fx: int in [7, 10, 13, 16]:
		_rect(img, fx, 5, 2, 5, c)
	_rect(img, 7, 9, 10, 8, c)
	_rect(img, 7, 9, 10, 2, lt)
	_rect(img, 5, 12, 3, 5, dk)         # thumb
	_rect(img, 7, 16, 10, 2, dk)        # cuff
	_outline(img); _save(img, id)

func _make_boots(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.25)
	_rect(img, 7, 5, 7, 11, c)
	_rect(img, 7, 5, 7, 2, lt)
	_rect(img, 7, 14, 13, 5, c)
	_rect(img, 7, 18, 14, 2, dk)        # sole
	_outline(img); _save(img, id)

func _make_shield(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.3)
	_ellipse(img, 12, 10, 8, 8, dk)
	_ellipse(img, 12, 10, 7, 7, c)
	_line(img, 5, 14, 12, 22, dk, 2); _line(img, 19, 14, 12, 22, dk, 2)
	_rect(img, 4, 9, 16, 2, lt)         # cross band
	_rect(img, 11, 3, 2, 16, lt)
	_circle(img, 12, 10, 2, lt)         # boss
	_outline(img); _save(img, id)

func _make_sword(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.3)
	_line(img, 12, 2, 12, 16, dk, 3)
	_line(img, 11, 5, 11, 16, c, 1); _line(img, 13, 5, 13, 16, lt, 1)
	_bline(img, 10, 5, 12, 2, c); _bline(img, 14, 5, 12, 2, c)
	_rect(img, 7, 16, 10, 2, HDL_DK)    # guard
	_rect(img, 10, 18, 4, 4, HDL_MD)    # grip
	_circle(img, 12, 22, 2, lt)         # pommel
	_outline(img); _save(img, id)

func _make_mace(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.3)
	_rect(img, 11, 9, 2, 13, HDL_MD)    # handle
	_circle(img, 12, 7, 5, dk)
	_circle(img, 12, 7, 4, c)
	_circle(img, 12, 7, 2, lt)
	_px(img, 12, 1, dk); _px(img, 6, 7, dk); _px(img, 18, 7, dk)   # spikes
	_px(img, 8, 3, dk);  _px(img, 16, 3, dk)
	_outline(img); _save(img, id)

func _make_bow(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.3)
	_bline(img, 9, 2, 4, 7, c);  _bline(img, 4, 7, 3, 12, c)
	_bline(img, 3, 12, 4, 17, c); _bline(img, 4, 17, 9, 22, c)
	_bline(img, 10, 3, 5, 7, lt); _bline(img, 5, 17, 10, 21, lt)
	_bline(img, 8, 2, 4, 6, dk);  _bline(img, 4, 18, 8, 22, dk)
	_bline(img, 10, 2, 10, 22, Color(0.82, 0.78, 0.68))   # string
	_circle(img, 10, 2, 2, dk); _circle(img, 10, 22, 2, dk)
	_outline(img); _save(img, id)

func _make_staff(id: String, c: Color) -> void:
	var img := _img()
	var lt := c.lightened(0.4)
	_line(img, 7, 22, 16, 5, HDL_MD, 3)
	_line(img, 8, 21, 16, 6, HDL_LT, 1)
	_circle(img, 17, 5, 4, c)
	_circle(img, 17, 5, 2, lt)
	_px(img, 17, 1, lt); _px(img, 21, 5, lt); _px(img, 13, 5, lt)   # glow
	_outline(img); _save(img, id)

func _make_ring(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.4)
	_circle(img, 12, 15, 6, dk)
	_circle(img, 12, 15, 5, c)
	_circle(img, 12, 15, 3, TRANS)      # hole
	_circle(img, 12, 7, 3, lt)          # gem
	_px(img, 12, 6, WHITE)
	_outline(img); _save(img, id)

func _make_amulet(id: String, c: Color) -> void:
	var img := _img()
	var dk := c.darkened(0.3); var lt := c.lightened(0.4)
	_bline(img, 8, 5, 12, 4, dk); _bline(img, 12, 4, 16, 5, dk)   # chain
	_circle(img, 12, 14, 7, dk)
	_circle(img, 12, 14, 6, c)
	_circle(img, 12, 14, 3, lt)
	_px(img, 12, 11, WHITE)
	_outline(img); _save(img, id)

func _gen_boats() -> void:
	# id → [wood colour, tier]
	var boats: Dictionary = {
		"oak_rowboat":        [Color(0.55, 0.36, 0.18), 0],
		"pine_canoe":         [Color(0.42, 0.26, 0.10), 1],
		"cherry_sailboat":    [Color(0.62, 0.30, 0.22), 2],
		"ironwood_longship":  [Color(0.26, 0.15, 0.07), 3],
		"frost_warship":      [Color(0.60, 0.78, 0.92), 4],
		"ancient_dragonship": [Color(0.55, 0.40, 0.12), 5],
	}
	for id: String in boats:
		var info: Array = boats[id]
		_make_boat_icon(id, info[0] as Color, info[1] as int)

func _make_boat_icon(id: String, wood: Color, tier: int) -> void:
	var img := _img()
	var dk := wood.darkened(0.3); var lt := wood.lightened(0.25)
	# Hull crescent (side view)
	for col in range(2, 22):
		var t := float(col - 12) / 10.0
		var depth := int(6.0 * (1.0 - t * t))   # parabola → boat hull
		if depth > 0:
			_rect(img, col, 15, 1, depth, wood)
			_px(img, col, 15, lt)
			_px(img, col, 15 + depth - 1, dk)
	# Rim line
	_line(img, 2, 14, 21, 14, dk, 1)
	# Mast + sail for tier ≥ 2
	if tier >= 2:
		_line(img, 11, 14, 11, 3, Color(0.30, 0.20, 0.10), 1)
		var sail := Color(0.92, 0.90, 0.82) if tier < 5 else Color(0.85, 0.20, 0.18)
		for ry in range(4, 13):
			var sw := int((ry - 3) * 0.8)
			_rect(img, 12, ry, sw, 1, sail)
	if tier == 5:
		_circle(img, 21, 11, 2, Color(0.20, 0.55, 0.30))   # dragon prow
		_px(img, 22, 10, Color(0.95, 0.85, 0.10))
	_outline(img); _save(img, id)

func _make_arrows(id: String) -> void:
	var img := _img()
	var c_sh := Color(0.52, 0.32, 0.12); var c_tp := Color(0.65, 0.65, 0.68); var c_fc := Color(0.92, 0.78, 0.55)
	for offset: int in [-3, 0, 3]:
		_line(img, 3 + offset, 21, 17 + offset, 5, c_sh, 1)
		_px(img, 17 + offset, 5, c_tp); _px(img, 16 + offset, 5, c_tp); _px(img, 17 + offset, 6, c_tp)
		_px(img, 3 + offset, 21, c_fc); _px(img, 4 + offset, 20, c_fc)
	_rect(img, 7, 14, 9, 2, Color(0.38, 0.22, 0.08))
	_outline(img); _save(img, id)

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY J — Cooked foods + raw meats (template per shape, tinted)
# ══════════════════════════════════════════════════════════════════════════════
func _gen_foods() -> void:
	# id → [shape, colour]   shape: "meat" | "stew" | "dish" | "fish"
	var foods: Dictionary = {
		"raw_meat":            ["meat", Color(0.78, 0.30, 0.28)],
		"raw_chicken":         ["meat", Color(0.92, 0.80, 0.62)],
		"cooked_rat_meat":     ["meat", Color(0.62, 0.40, 0.28)],
		"roasted_chicken":     ["meat", Color(0.86, 0.66, 0.40)],
		"grilled_trout":       ["fish", Color(0.80, 0.58, 0.40)],
		"baked_potato":        ["dish", Color(0.74, 0.58, 0.34)],
		"vegetable_stew":      ["stew", Color(0.40, 0.62, 0.30)],
		"meat_pie":            ["dish", Color(0.72, 0.50, 0.26)],
		"fish_soup":           ["stew", Color(0.55, 0.70, 0.78)],
		"hearty_stew":         ["stew", Color(0.60, 0.42, 0.24)],
		"shark_steak":         ["meat", Color(0.55, 0.58, 0.62)],
		"honey_glazed_ham":    ["meat", Color(0.82, 0.50, 0.22)],
		"stuffed_boar":        ["meat", Color(0.58, 0.38, 0.22)],
		"spiced_fish":         ["fish", Color(0.92, 0.58, 0.34)],
		"dragon_fin_soup":     ["stew", Color(0.45, 0.66, 0.55)],
		"mead_braised_ribs":   ["meat", Color(0.66, 0.34, 0.18)],
		"frost_trout_fillet":  ["fish", Color(0.62, 0.78, 0.90)],
		"venison_roast":       ["meat", Color(0.56, 0.32, 0.20)],
		"magma_prawn":         ["dish", Color(0.95, 0.42, 0.18)],
		"smoked_bear":         ["meat", Color(0.48, 0.32, 0.20)],
		"elder_fish_platter":  ["dish", Color(0.40, 0.50, 0.40)],
		"giants_feast":        ["dish", Color(0.70, 0.46, 0.24)],
		"leviathan_stew":      ["stew", Color(0.20, 0.46, 0.42)],
		"kraken_platter":      ["dish", Color(0.45, 0.30, 0.55)],
		"feast_of_valhalla":   ["dish", Color(0.95, 0.82, 0.30)],
	}
	for id: String in foods:
		var info: Array = foods[id]
		var shape := info[0] as String
		var col := info[1] as Color
		match shape:
			"meat": _make_meat(id, col)
			"stew": _make_stew(id, col)
			"fish": _make_fish(id, col, col.lightened(0.25), col.darkened(0.3))
			_:      _make_dish(id, col)

func _make_meat(id: String, c: Color) -> void:
	var img := _img()
	var lt := c.lightened(0.25)
	_ellipse(img, 11, 12, 7, 6, c)
	_ellipse(img, 10, 11, 5, 4, lt)
	_rect(img, 15, 14, 6, 3, Color(0.92, 0.90, 0.80))   # bone
	_circle(img, 21, 15, 2, Color(0.96, 0.94, 0.86))    # bone knob
	_px(img, 8, 9, c.lightened(0.45))
	_outline(img); _save(img, id)

func _make_stew(id: String, c: Color) -> void:
	var img := _img()
	var bowl := Color(0.42, 0.28, 0.10); var blt := Color(0.65, 0.48, 0.22)
	_ellipse(img, 12, 17, 9, 6, bowl)
	_ellipse(img, 12, 17, 7, 4, bowl.lightened(0.1))
	_rect(img, 4, 12, 16, 2, blt)
	_ellipse(img, 12, 12, 7, 3, c)
	_ellipse(img, 10, 11, 3, 2, c.lightened(0.25))
	_px(img, 9, 8, WHITE); _px(img, 12, 7, WHITE); _px(img, 15, 8, WHITE)
	_outline(img); _save(img, id)

func _make_dish(id: String, c: Color) -> void:
	var img := _img()
	_ellipse(img, 12, 18, 10, 4, Color(0.80, 0.80, 0.85))   # plate
	_ellipse(img, 12, 17, 8, 3, Color(0.92, 0.92, 0.96))
	_ellipse(img, 12, 13, 6, 4, c)                           # food mound
	_ellipse(img, 11, 12, 3, 2, c.lightened(0.25))
	_px(img, 9, 7, WHITE); _px(img, 13, 6, WHITE)
	_outline(img); _save(img, id)

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY K — Sidebar tab icons (24×24, gold/parchment to read on dark buttons)
# ══════════════════════════════════════════════════════════════════════════════
func _gen_tab_icons() -> void:
	_gen_tab_skills()
	_gen_tab_inv()
	_gen_tab_equip()
	_gen_tab_thrall()
	_gen_tab_rank()
	_gen_tab_craft()

func _gen_tab_skills() -> void:
	# Open book
	var img := _img()
	var cover := Color(0.55, 0.14, 0.10); var page := Color(0.92, 0.88, 0.74)
	var spine := Color(0.75, 0.60, 0.18); var lines := Color(0.58, 0.52, 0.38)
	_rect(img, 3, 6, 18, 13, page)
	_rect(img, 3, 5, 20, 2, cover); _rect(img, 3, 18, 20, 2, cover)
	_rect(img, 2, 5, 2, 15, cover); _rect(img, 20, 5, 2, 15, cover)
	_line(img, 12, 6, 12, 18, spine, 2)
	for ly: int in [9, 12, 15]:
		_line(img, 5, ly, 10, ly, lines, 1)
		_line(img, 14, ly, 19, ly, lines, 1)
	_outline(img); _save(img, "tab_skills")

func _gen_tab_inv() -> void:
	# Backpack
	var img := _img()
	var bag := Color(0.50, 0.34, 0.18); var lt := bag.lightened(0.22); var dk := bag.darkened(0.3)
	_rect(img, 7, 4, 2, 5, dk); _rect(img, 15, 4, 2, 5, dk)   # straps
	_rect(img, 4, 8, 16, 13, bag)
	_rect(img, 4, 8, 16, 6, lt)                              # flap
	_rect(img, 9, 13, 6, 4, dk)                              # front pocket
	_px(img, 12, 15, Color(0.85, 0.72, 0.30))               # buckle
	_outline(img); _save(img, "tab_inv")

func _gen_tab_equip() -> void:
	# Crossed swords over a shield
	var img := _img()
	var sh := Color(0.60, 0.62, 0.70); var blade := Color(0.85, 0.88, 0.94); var gold := Color(0.85, 0.70, 0.20)
	_ellipse(img, 12, 11, 7, 8, sh.darkened(0.25))
	_ellipse(img, 12, 11, 6, 7, sh)
	_line(img, 5, 14, 12, 21, sh.darkened(0.25), 1); _line(img, 19, 14, 12, 21, sh.darkened(0.25), 1)
	_line(img, 4, 4, 20, 19, blade, 2); _line(img, 20, 4, 4, 19, blade, 2)   # crossed swords
	_rect(img, 3, 18, 4, 2, gold); _rect(img, 17, 18, 4, 2, gold)            # hilts
	_outline(img); _save(img, "tab_equip")

func _gen_tab_thrall() -> void:
	# Person silhouette
	var img := _img()
	var c := Color(0.85, 0.80, 0.62)
	_circle(img, 12, 7, 4, c)                                # head
	_ellipse(img, 12, 18, 7, 5, c)                           # body
	_rect(img, 5, 14, 14, 4, c)                              # shoulders
	_outline(img); _save(img, "tab_thrall")

func _gen_tab_rank() -> void:
	# Five rising bars, each a different colour
	var img := _img()
	var cols: Array[Color] = [
		Color(0.85, 0.30, 0.30), Color(0.92, 0.60, 0.20), Color(0.92, 0.85, 0.25),
		Color(0.40, 0.80, 0.35), Color(0.35, 0.62, 0.92),
	]
	for i in range(5):
		var bx := 2 + i * 4
		var bh := 4 + i * 4
		_rect(img, bx, 21 - bh, 3, bh, cols[i])
	_outline(img); _save(img, "tab_rank")

func _gen_tab_craft() -> void:
	# Hammer + chisel
	var img := _img()
	var metal := Color(0.62, 0.64, 0.70); var wood := Color(0.52, 0.34, 0.14)
	_line(img, 6, 20, 14, 8, wood, 3)            # hammer handle
	_rect(img, 11, 4, 9, 5, metal)               # hammer head
	_rect(img, 11, 4, 9, 1, metal.lightened(0.3))
	_line(img, 4, 8, 9, 18, metal, 2)            # chisel
	_outline(img); _save(img, "tab_craft")

# ══════════════════════════════════════════════════════════════════════════════
# ICON AUDIT FILLS — 37 missing icons from ICON_AUDIT.md.
# Runes share a glowing-orb base shape with unique inner symbols. Bars are
# re-authored with distinct silhouettes (squat / tall / wide / wedged / hex /
# jagged) instead of color-swap rectangles. Sea-drop / bait / crafting /
# essence / dragon-boot icons get bespoke shapes. Every function ends with
# `_outline(img); _save(img, id)` so both the inventory PNG and the 16×16
# drop variant are written. Call from _gen_all via _gen_audit_icons().
# ══════════════════════════════════════════════════════════════════════════════

func _gen_audit_icons() -> void:
	# Runes — orb + symbol
	_make_rune("air_rune",    Color(0.92, 0.94, 0.98), Color(0.62, 0.68, 0.78), "swirl")
	_make_rune("mind_rune",   Color(0.72, 0.74, 0.82), Color(0.42, 0.45, 0.55), "eye")
	_make_rune("water_rune",  Color(0.22, 0.42, 0.92), Color(0.55, 0.78, 1.00), "drop")
	_make_rune("earth_rune",  Color(0.42, 0.32, 0.16), Color(0.68, 0.58, 0.32), "diamond")
	_make_rune("fire_rune",   Color(0.88, 0.28, 0.12), Color(1.00, 0.62, 0.20), "flame")
	_make_rune("ice_rune",    Color(0.42, 0.78, 0.92), Color(0.82, 0.95, 1.00), "snow")
	_make_rune("body_rune",   Color(0.22, 0.62, 0.32), Color(0.55, 0.88, 0.55), "body")
	_make_rune("cosmic_rune", Color(0.32, 0.18, 0.55), Color(0.78, 0.62, 1.00), "star")
	_make_rune("chaos_rune",  Color(0.58, 0.22, 0.08), Color(0.98, 0.62, 0.20), "bolt")
	_make_rune("nature_rune", Color(0.42, 0.78, 0.18), Color(0.72, 0.95, 0.42), "leaf")
	_make_rune("law_rune",    Color(0.92, 0.78, 0.18), Color(1.00, 0.96, 0.62), "scale")
	_make_rune("blood_rune",  Color(0.55, 0.05, 0.08), Color(0.92, 0.18, 0.22), "blood")
	# Distinct bar shapes (override the earlier _make_bar calls)
	_gen_copper_bar(); _gen_iron_bar(); _gen_gold_bar()
	_gen_mithril_bar(); _gen_adamant_bar(); _gen_runite_bar()
	# Mining
	_gen_rune_essence()
	# Sea-monster drops
	_gen_crab_claw();        _gen_eel_skin();        _gen_serpent_scrap()
	_gen_serpent_fang();     _gen_seagull_feather(); _gen_barnacle_shard()
	_gen_squid_ink();        _gen_void_tentacle();   _gen_witch_pearl()
	_gen_siren_scale();      _gen_razor_tooth();     _gen_frost_heart()
	_gen_ember_lantern();    _gen_world_serpent_scale()
	_gen_drowned_crown();    _gen_drowned_god();     _gen_jormungandr_spawn()
	# Bait
	_gen_earthworm(); _gen_fatty_lard()
	# Equipment
	_gen_dragon_boots()
	# Crafting (absorbed from construction)
	_gen_campfire(); _gen_storage_crate(); _gen_torch_post(); _gen_bookshelf()

# ── Rune base + per-symbol inner glyph ────────────────────────────────────────
## Glass-orb shell with a centered symbol. Outer ring darkest, fill mid-tone,
## inner highlight + top-left specular dot for the wet-glass look. Symbol
## drawn in `lt` on top so it reads against the glow.
func _make_rune(id: String, md: Color, lt: Color, sym: String) -> void:
	var img := _img()
	var dk := md.darkened(0.50)
	var glow := lt.lightened(0.20)
	# Outer ring
	_circle(img, 12, 12, 9.0, dk)
	# Main orb fill
	_circle(img, 12, 12, 7.5, md)
	# Inner glow gradient
	_circle(img, 11, 11, 5.0, md.lightened(0.18))
	_circle(img, 11, 11, 3.0, lt)
	# Top-left specular highlight
	_circle(img, 9, 9, 1.6, Color(1.0, 1.0, 1.0, 0.85))
	_px(img, 8, 8, WHITE)
	# Per-rune symbol overlay
	match sym:
		"swirl":
			# Spiral of three short arcs
			_line(img, 9, 14, 12, 11, glow, 1)
			_line(img, 12, 11, 14, 13, glow, 1)
			_line(img, 14, 13, 13, 15, glow, 1)
			_px(img, 13, 15, WHITE)
		"eye":
			# Almond eye with pupil
			_ellipse(img, 12, 13, 4, 2, WHITE)
			_circle(img, 12, 13, 1.6, Color(0.10, 0.10, 0.18))
			_px(img, 11, 12, WHITE)
		"drop":
			# Teardrop pointing up
			_circle(img, 12, 14, 2.2, glow)
			_line(img, 12, 14, 12, 9, glow, 2)
			_px(img, 12, 8, WHITE)
		"diamond":
			# Diamond facets
			_line(img,  9, 13, 12, 10, glow, 1)
			_line(img, 12, 10, 15, 13, glow, 1)
			_line(img,  9, 13, 12, 16, glow, 1)
			_line(img, 15, 13, 12, 16, glow, 1)
			_line(img, 10, 13, 14, 13, glow, 1)
		"flame":
			# Teardrop flame shape (pointing up)
			_circle(img, 12, 14, 2.4, glow)
			_line(img, 11, 13, 11,  9, glow, 1)
			_line(img, 13, 13, 13, 10, glow, 1)
			_line(img, 12, 12, 12,  8, glow, 1)
			_px(img, 12, 7, WHITE)
		"snow":
			# Six-spoke snowflake
			_line(img,  8, 12, 16, 12, glow, 1)
			_line(img, 12,  8, 12, 16, glow, 1)
			_line(img,  9,  9, 15, 15, glow, 1)
			_line(img,  9, 15, 15,  9, glow, 1)
			_px(img, 12, 12, WHITE)
		"body":
			# Stick-figure silhouette
			_circle(img, 12, 10, 1.4, glow)         # head
			_rect(img, 11, 12, 2, 4, glow)          # torso
			_line(img,  9, 13, 11, 13, glow, 1)     # arm L
			_line(img, 13, 13, 15, 13, glow, 1)     # arm R
			_line(img, 11, 16, 10, 18, glow, 1)     # leg L
			_line(img, 13, 16, 14, 18, glow, 1)     # leg R
		"star":
			# Five-point star (centered)
			_line(img, 12,  8, 13, 11, glow, 1)
			_line(img, 13, 11, 16, 11, glow, 1)
			_line(img, 16, 11, 14, 13, glow, 1)
			_line(img, 14, 13, 15, 16, glow, 1)
			_line(img, 15, 16, 12, 14, glow, 1)
			_line(img, 12, 14,  9, 16, glow, 1)
			_line(img,  9, 16, 10, 13, glow, 1)
			_line(img, 10, 13,  8, 11, glow, 1)
			_line(img,  8, 11, 11, 11, glow, 1)
			_line(img, 11, 11, 12,  8, glow, 1)
		"bolt":
			# Lightning bolt zig-zag
			_line(img, 13,  8, 10, 12, glow, 1)
			_line(img, 10, 12, 13, 13, glow, 1)
			_line(img, 13, 13, 10, 17, glow, 1)
			_px(img, 11, 14, WHITE)
		"leaf":
			# Pointed leaf with vein
			_ellipse(img, 12, 13, 2, 4, glow)
			_line(img, 12,  9, 12, 16, glow.darkened(0.25), 1)
			_line(img, 11, 12, 13, 12, glow.darkened(0.25), 1)
		"scale":
			# Balanced scale (beam + two pans)
			_line(img,  8, 11, 16, 11, glow, 1)        # beam
			_line(img, 12,  8, 12, 11, glow, 1)        # post
			_circle(img,  8, 14, 2, glow)              # left pan
			_circle(img, 16, 14, 2, glow)              # right pan
			_line(img,  8, 11,  8, 13, glow, 1)
			_line(img, 16, 11, 16, 13, glow, 1)
		"blood":
			# Big teardrop, deeper crimson
			_circle(img, 12, 14, 2.6, lt)
			_line(img, 12, 14, 12,  8, lt, 2)
			_circle(img, 12, 14, 1.4, glow)
			_px(img, 12, 7, WHITE)
	_outline(img); _save(img, id)

# ── Bars (distinct silhouettes per the rebalance spec) ────────────────────────

## Copper Bar — short squat ingot, hammered/dented top edge, warm tones.
func _gen_copper_bar() -> void:
	var img := _img()
	var dk := Color(0.45, 0.20, 0.06)
	var md := Color(0.82, 0.45, 0.18)
	var lt := Color(1.00, 0.68, 0.38)
	# Short squat body (wider than tall)
	_rect(img, 4, 12, 16, 7, md)
	_rect(img, 4, 12, 16, 1, lt)              # top shine
	_rect(img, 4, 18, 16, 1, dk)              # bottom shadow
	# Hammered-edge dents along the top
	_px(img, 6, 12, dk); _px(img, 10, 12, dk)
	_px(img, 14, 12, dk); _px(img, 18, 12, dk)
	# Side bevels
	_rect(img, 4, 12, 1, 7, lt.darkened(0.2))
	_rect(img, 19, 12, 1, 7, dk)
	# Two small hammer texture marks on the face
	_line(img, 7, 15, 9, 15, dk.lightened(0.1), 1)
	_line(img, 13, 16, 15, 16, dk.lightened(0.1), 1)
	_outline(img); _save(img, "copper_bar")

## Iron Bar — taller, flatter, two grooves cut across the front face.
func _gen_iron_bar() -> void:
	var img := _img()
	var dk := Color(0.20, 0.22, 0.28)
	var md := Color(0.48, 0.52, 0.58)
	var lt := Color(0.78, 0.82, 0.88)
	# Taller rectangle (a hair narrower)
	_rect(img, 5, 6, 14, 13, md)
	_rect(img, 5, 6, 14, 2, lt)               # flat top shine
	_rect(img, 5, 18, 14, 1, dk)
	_rect(img, 5, 6, 1, 13, lt.darkened(0.15))
	_rect(img, 18, 6, 1, 13, dk)
	# Two parallel groove lines across the face
	_line(img, 6, 11, 17, 11, dk, 1)
	_line(img, 6, 14, 17, 14, dk, 1)
	# Stamp dot
	_px(img, 17, 8, lt)
	_outline(img); _save(img, "iron_bar")

## Gold Bar — wide flat ingot (wider than tall), bright yellow + shine line.
func _gen_gold_bar() -> void:
	var img := _img()
	var dk := Color(0.62, 0.42, 0.05)
	var md := Color(0.98, 0.82, 0.18)
	var lt := Color(1.00, 0.96, 0.55)
	# Trapezoidal top face
	_rect(img, 3, 9, 18, 4, md)
	_bline(img, 2, 13, 5, 9, md)
	_bline(img, 21, 13, 18, 9, md)
	# Front face (wider, shorter)
	_rect(img, 2, 13, 20, 5, md.darkened(0.10))
	_rect(img, 2, 17, 20, 1, dk)
	# Continuous shine line along the top edge
	_rect(img, 4, 10, 16, 1, lt)
	# Sparkle pixels
	_px(img, 7, 9, lt); _px(img, 14, 9, lt)
	# Right side bevel
	_rect(img, 21, 13, 1, 5, dk)
	_outline(img); _save(img, "gold_bar")

## Mithril Bar — tall narrow, pointed/wedged top, cool blue-silver.
func _gen_mithril_bar() -> void:
	var img := _img()
	var dk := Color(0.18, 0.32, 0.58)
	var md := Color(0.42, 0.62, 0.92)
	var lt := Color(0.78, 0.92, 1.00)
	# Wedge-point top
	for i in range(5):
		_rect(img, 10 - i, 4 + i, 4 + i * 2, 1, md.lightened(float(i) * 0.04))
	# Tall narrow body
	_rect(img, 6, 9, 12, 12, md)
	_rect(img, 6, 9, 12, 1, lt)
	_rect(img, 6, 20, 12, 1, dk)
	_rect(img, 6, 9, 1, 12, lt.darkened(0.12))
	_rect(img, 17, 9, 1, 12, dk)
	# Central vertical highlight (catches light along the wedge)
	_rect(img, 11, 6, 2, 14, lt.lightened(0.1))
	_outline(img); _save(img, "mithril_bar")

## Adamant Bar — hexagonal ingot with visible facets.
func _gen_adamant_bar() -> void:
	var img := _img()
	var dk := Color(0.06, 0.32, 0.14)
	var md := Color(0.20, 0.62, 0.32)
	var lt := Color(0.55, 0.92, 0.55)
	# Hexagon outline (top, sides, bottom)
	# Top triangle
	_rect(img,  8,  5, 8, 1, md.lightened(0.2))
	_rect(img,  6,  6, 12, 1, md)
	_rect(img,  5,  7, 14, 1, md)
	# Body
	_rect(img,  4,  8, 16, 9, md)
	# Bottom triangle
	_rect(img,  5, 17, 14, 1, md.darkened(0.1))
	_rect(img,  6, 18, 12, 1, dk)
	_rect(img,  8, 19, 8, 1, dk)
	# Top-left facet highlight
	_bline(img,  5,  7,  8,  5, lt)
	_bline(img,  4,  8,  4, 12, lt)
	# Bottom-right facet shadow
	_bline(img, 19, 12, 19, 17, dk)
	_bline(img, 18, 18, 15, 19, dk)
	# Center stamp
	_px(img, 11, 12, lt); _px(img, 12, 12, lt); _px(img, 11, 13, lt); _px(img, 12, 13, lt)
	_outline(img); _save(img, "adamant_bar")

## Runite Bar — jagged crystalline silhouette, blade-blank like, red edges.
func _gen_runite_bar() -> void:
	var img := _img()
	var dk := Color(0.05, 0.06, 0.18)
	var md := Color(0.18, 0.22, 0.45)
	var lt := Color(0.55, 0.62, 0.92)
	var red := Color(0.95, 0.18, 0.22)
	# Jagged irregular body (asymmetric)
	# Top spike
	_line(img, 11, 3, 14, 7, md, 1)
	_line(img, 14, 7, 12, 8, md, 1)
	# Main body — irregular polygon roughed out by stacked rows
	_rect(img,  7,  8,  9, 3, md)
	_rect(img,  5, 11, 13, 4, md)
	_rect(img,  6, 15, 12, 3, md)
	_rect(img,  8, 18,  9, 2, md)
	_rect(img, 10, 20,  5, 1, md)
	# Crystal facet highlights
	_line(img,  6, 12, 17, 12, lt, 1)
	_line(img,  7, 15, 16, 15, lt.darkened(0.15), 1)
	_bline(img,  7, 11,  9,  8, lt)
	_bline(img, 14,  8, 16, 11, dk)
	# Red edge glow
	_px(img,  5, 13, red); _px(img, 18, 13, red)
	_px(img,  6, 16, red); _px(img, 17, 16, red)
	_px(img,  9, 20, red); _px(img, 14, 20, red)
	_px(img, 13, 3, red)
	# Top specular
	_px(img, 13, 6, WHITE)
	_outline(img); _save(img, "runite_bar")

# ── Rune Essence (irregular crystal chunk) ────────────────────────────────────
## Distinct from any ore — no round rock outline. Three irregular crystal
## faces stacked, inner glowing core, sparkle dots around edges. Purple-blue
## gradient drawn as a manual two-tone fill.
func _gen_rune_essence() -> void:
	var img := _img()
	var deep := Color(0.18, 0.10, 0.32)
	var violet := Color(0.45, 0.30, 0.85)
	var ice := Color(0.30, 0.55, 0.95)
	var core := Color(0.85, 0.75, 1.00)
	# Outer chunk shadow
	_rect(img,  6, 16, 12, 4, deep)
	_rect(img,  5, 13, 14, 4, deep)
	_rect(img,  7,  9, 10, 5, deep)
	_rect(img,  8,  5,  7, 5, deep)
	# Main violet body
	_rect(img,  7, 16, 10, 3, violet)
	_rect(img,  6, 12, 12, 4, violet)
	_rect(img,  8,  8,  8, 5, violet)
	_rect(img,  9,  5,  5, 4, violet)
	# Blue-tinted facet on the right (gradient effect)
	_rect(img, 13, 12, 5, 5, ice.darkened(0.08))
	_rect(img, 12,  8,  4, 4, ice.darkened(0.18))
	# Inner glow core
	_circle(img, 12, 12, 2.6, core.darkened(0.10))
	_circle(img, 11, 11, 1.4, WHITE)
	# Top crystal-edge highlights
	_bline(img, 9,  5, 13,  5, core)
	_bline(img, 9,  5, 7,  9, violet.lightened(0.2))
	_bline(img, 14, 5, 16, 9, ice.lightened(0.15))
	# Sparkle dots around the edges
	_px(img,  4, 14, WHITE); _px(img, 19, 14, WHITE)
	_px(img, 11,  3, WHITE); _px(img, 16,  7, WHITE)
	_px(img,  7, 20, core);  _px(img, 17, 19, core)
	_outline(img); _save(img, "rune_essence")

# ── Sea-monster drops ────────────────────────────────────────────────────────

func _gen_crab_claw() -> void:
	var img := _img()
	var dk := Color(0.55, 0.18, 0.04)
	var md := Color(0.92, 0.42, 0.12)
	var lt := Color(1.00, 0.68, 0.32)
	# Two-segment curved claw — base segment + opened pincer
	_ellipse(img, 9, 16, 4, 5, md)            # base
	_ellipse(img, 9, 16, 3, 3, lt)            # base highlight
	# Upper pincer
	_line(img, 12, 14, 18,  7, md, 3)
	_line(img, 13, 13, 18,  8, lt, 1)
	# Lower pincer (slightly shorter, opens to a gap)
	_line(img, 12, 17, 19, 14, md, 3)
	_line(img, 13, 17, 18, 14, lt, 1)
	# Dark pincer tips
	_circle(img, 18,  7, 1.4, dk)
	_circle(img, 19, 14, 1.2, dk)
	# Segment crease at the joint
	_line(img, 11, 13, 12, 18, dk, 1)
	_outline(img); _save(img, "crab_claw")

func _gen_eel_skin() -> void:
	var img := _img()
	var dk := Color(0.08, 0.22, 0.14)
	var md := Color(0.18, 0.42, 0.25)
	var lt := Color(0.35, 0.68, 0.45)
	# Long wavy strip — bezier-ish via stacked rects with offset
	for i in range(20):
		var sy := 4 + i
		var sx := 8 + int(round(sin(float(i) * 0.5) * 4.0))
		_rect(img, sx, sy, 5, 1, md)
		_px(img, sx + 2, sy, lt)
		_px(img, sx, sy, dk)
		_px(img, sx + 4, sy, dk)
	_outline(img); _save(img, "eel_skin")

func _gen_serpent_scrap() -> void:
	var img := _img()
	var dk := Color(0.05, 0.22, 0.12)
	var md := Color(0.18, 0.52, 0.28)
	var lt := Color(0.55, 0.88, 0.62)
	# Irregular scale shape (curved teardrop)
	_ellipse(img, 12, 14, 7, 5, dk)
	_ellipse(img, 12, 13, 6, 4, md)
	_ellipse(img, 11, 11, 3, 2, lt)
	# Iridescent highlight arc
	_bline(img,  8, 11, 14,  9, WHITE)
	_px(img, 15, 9, lt)
	# Bottom shadow
	_bline(img,  7, 17, 17, 17, dk)
	_outline(img); _save(img, "serpent_scrap")

func _gen_serpent_fang() -> void:
	var img := _img()
	var dk := Color(0.55, 0.50, 0.32)
	var md := Color(0.85, 0.82, 0.68)
	var lt := Color(0.98, 0.96, 0.88)
	# Curved fang — base wider, taper to point
	_rect(img, 9, 17, 7, 3, dk)              # yellowed base
	_line(img, 10, 17, 12,  4, md, 3)        # main fang body
	_line(img, 11, 17, 13,  5, lt, 1)        # highlight stripe
	_px(img, 12, 4, dk); _px(img, 13, 5, dk) # sharp tip
	# Subtle base curve
	_px(img, 9, 18, dk.lightened(0.1))
	_outline(img); _save(img, "serpent_fang")

func _gen_seagull_feather() -> void:
	var img := _img()
	var qd := Color(0.55, 0.55, 0.58)
	var bd := Color(0.90, 0.92, 0.95)
	var sh := Color(0.72, 0.74, 0.78)
	# Quill line
	_line(img, 12, 21, 12, 3, qd, 1)
	# Vane on each side — short diagonal strokes
	for i in range(15):
		var y := 5 + i
		var lx := 12 - 3 - int(float(i) * 0.15)
		var rx := 12 + 3 + int(float(i) * 0.15)
		_line(img, lx, y + 1, 12, y, bd, 1)
		_line(img, rx, y + 1, 12, y, bd, 1)
	# Slight shadow on right vane
	for i in range(12):
		_px(img, 13 + i / 6, 8 + i, sh)
	_outline(img); _save(img, "seagull_feather")

func _gen_barnacle_shard() -> void:
	var img := _img()
	var dk := Color(0.32, 0.32, 0.35)
	var md := Color(0.58, 0.58, 0.62)
	var lt := Color(0.85, 0.85, 0.88)
	# Irregular jagged shard
	_rect(img,  5, 16, 14, 4, md)
	_rect(img,  6, 13, 12, 4, md)
	_rect(img,  8, 10, 9, 4, md)
	_rect(img, 10,  7, 6, 4, md)
	# Top angular edges
	_bline(img,  5, 16,  10,  7, lt)
	_bline(img, 16,  7, 19, 16, dk)
	# White barnacle dots scattered across face
	_circle(img,  8, 14, 1.4, lt)
	_circle(img, 13, 11, 1.3, lt)
	_circle(img, 15, 17, 1.4, lt)
	_circle(img, 10, 18, 1.0, lt)
	_circle(img, 12, 12, 0.8, WHITE)
	_outline(img); _save(img, "barnacle_shard")

func _gen_squid_ink() -> void:
	var img := _img()
	var dk := Color(0.04, 0.02, 0.10)
	var md := Color(0.18, 0.08, 0.32)
	var lt := Color(0.55, 0.32, 0.72)
	# Vial body
	_ellipse(img, 12, 16, 6, 5, dk)
	_ellipse(img, 12, 15, 5, 4, md)
	# Vial highlight on left side
	_ellipse(img, 10, 14, 1.5, 3, lt)
	# Specular dot
	_px(img,  9, 13, WHITE)
	# Stopper / neck
	_rect(img, 10,  7, 4, 4, BRN_DK)
	_rect(img, 10,  7, 4, 1, BRN_MD)
	# Drip
	_circle(img, 18,  9, 1.2, md)
	_px(img, 18, 8, lt)
	_outline(img); _save(img, "squid_ink")

func _gen_void_tentacle() -> void:
	var img := _img()
	var dk := Color(0.08, 0.04, 0.18)
	var md := Color(0.32, 0.18, 0.55)
	var lt := Color(0.62, 0.42, 0.85)
	# Curved tentacle — tapering from thick base to thin tip
	for i in range(18):
		var y := 4 + i
		var th := maxi(2, 6 - i / 3)
		var cx := 14 - int(round(sin(float(i) * 0.35) * 5.0))
		_rect(img, cx - th / 2, y, th, 1, md)
		if th >= 4:
			_px(img, cx - th / 2, y, dk)
			_px(img, cx + th / 2 - 1, y, dk)
	# Sucker dots along the inside curve
	_circle(img, 10,  7, 1.0, dk)
	_circle(img, 8, 11, 1.2, dk)
	_circle(img, 11, 15, 1.2, dk)
	_circle(img, 14, 19, 1.0, dk)
	# Sucker highlights
	_px(img, 10, 7, lt); _px(img, 8, 11, lt); _px(img, 11, 15, lt)
	_outline(img); _save(img, "void_tentacle")

func _gen_witch_pearl() -> void:
	var img := _img()
	var dk := Color(0.02, 0.02, 0.08)
	var md := Color(0.12, 0.04, 0.22)
	var lt := Color(0.62, 0.32, 0.92)
	# Perfect sphere
	_circle(img, 12, 13, 8.0, dk)
	_circle(img, 12, 13, 7.0, md)
	# Inner purple glow
	_circle(img, 11, 12, 3.0, lt)
	_circle(img, 11, 12, 1.4, Color(0.92, 0.78, 1.00))
	# Top-left highlight
	_circle(img,  9, 10, 1.6, WHITE)
	_px(img,  8,  9, WHITE)
	# Bottom rim shadow
	_circle(img, 14, 17, 3.0, dk)
	_outline(img); _save(img, "witch_pearl")

func _gen_siren_scale() -> void:
	var img := _img()
	var dk := Color(0.05, 0.32, 0.42)
	var md := Color(0.22, 0.62, 0.78)
	var lt := Color(0.55, 0.92, 1.00)
	# Wide flat fish-scale (semi-circle with flat base)
	_ellipse(img, 12, 14, 9, 7, dk)
	_ellipse(img, 12, 14, 8, 6, md)
	_rect(img, 3, 18, 18, 3, TRANS)          # clip bottom
	# Re-paint solid scale region
	for ry in range(7, 18):
		for rx in range(4, 20):
			var dx := rx - 12
			var dy := ry - 14
			if dx * dx + dy * dy <= 49 and ry <= 17:
				img.set_pixel(rx, ry, md)
	# Arc highlight lines (iridescent rings)
	_line(img,  6, 12, 18, 12, lt.darkened(0.15), 1)
	_line(img,  8, 10, 16, 10, lt, 1)
	_line(img, 10,  9, 14,  9, WHITE, 1)
	# Bottom edge shadow
	_line(img, 4, 17, 20, 17, dk, 1)
	_outline(img); _save(img, "siren_scale")

func _gen_razor_tooth() -> void:
	var img := _img()
	var dk := Color(0.42, 0.42, 0.48)
	var md := Color(0.85, 0.85, 0.88)
	var lt := Color(1.00, 1.00, 1.00)
	# Flat triangular tooth, point up
	_bline(img, 12, 3, 5, 20, md)
	_bline(img, 12, 3, 19, 20, md)
	_bline(img, 5, 20, 19, 20, dk)
	# Fill interior
	for ry in range(4, 20):
		var halfw := (ry - 3) * 7 / 17
		for rx in range(12 - halfw, 12 + halfw + 1):
			img.set_pixel(rx, ry, md)
	# Left edge highlight (long shine)
	_bline(img, 11, 5, 6, 19, lt)
	# Right edge shadow
	_bline(img, 13, 5, 18, 19, dk.lightened(0.1))
	# Serrated bottom
	for sx in range(6, 20, 2):
		_px(img, sx, 20, dk)
	_outline(img); _save(img, "razor_tooth")

func _gen_frost_heart() -> void:
	var img := _img()
	var dk := Color(0.32, 0.55, 0.72)
	var md := Color(0.65, 0.85, 0.95)
	var lt := Color(0.92, 0.98, 1.00)
	# Heart shape — two top circles + triangle bottom
	_circle(img, 8,  9, 4.5, dk)
	_circle(img, 16, 9, 4.5, dk)
	_circle(img, 8,  9, 3.5, md)
	_circle(img, 16, 9, 3.5, md)
	# Bottom triangle
	for ry in range(9, 21):
		var halfw := (20 - ry) * 8 / 11
		for rx in range(12 - halfw, 12 + halfw + 1):
			img.set_pixel(rx, ry, md)
	# Frozen crack lines
	_line(img, 12, 8, 12, 18, dk.darkened(0.15), 1)
	_line(img, 10, 11, 14, 14, dk.darkened(0.15), 1)
	_line(img,  9, 13, 7, 16, dk, 1)
	_line(img, 15, 13, 17, 15, dk, 1)
	# Top highlight
	_circle(img, 7, 7, 1.4, lt)
	_circle(img, 15, 7, 1.4, lt)
	_outline(img); _save(img, "frost_heart")

func _gen_ember_lantern() -> void:
	var img := _img()
	var dk := Color(0.20, 0.14, 0.06)
	var md := Color(0.42, 0.32, 0.18)
	var glow := Color(1.00, 0.62, 0.10)
	var hot := Color(1.00, 0.90, 0.45)
	# Top loop
	_circle(img, 12, 4, 2.0, dk)
	# Chain bar
	_rect(img, 11, 6, 2, 2, dk)
	# Lantern frame top
	_rect(img, 7, 8, 10, 2, dk)
	_rect(img, 7, 8, 10, 1, md)
	# Frame uprights
	_rect(img, 7, 10, 2, 9, dk)
	_rect(img, 15, 10, 2, 9, dk)
	# Glow body
	_rect(img, 9, 10, 6, 9, glow.darkened(0.2))
	# Inner hot glow
	_circle(img, 12, 14, 2.6, hot)
	_circle(img, 12, 14, 1.4, WHITE)
	# Frame bottom
	_rect(img, 7, 19, 10, 2, dk)
	_rect(img, 7, 20, 10, 1, md)
	# Glow halo outside frame (right side leak)
	_px(img,  6, 13, glow); _px(img, 18, 13, glow)
	_px(img,  6, 16, glow); _px(img, 18, 16, glow)
	_outline(img); _save(img, "ember_lantern")

func _gen_world_serpent_scale() -> void:
	var img := _img()
	var dk := Color(0.04, 0.12, 0.08)
	var md := Color(0.18, 0.32, 0.20)
	var lt := Color(0.42, 0.62, 0.42)
	var gd := Color(0.92, 0.78, 0.18)
	# Large hexagonal scale outline
	var pts := PackedVector2Array([
		Vector2(12, 3), Vector2(20, 8), Vector2(20, 16),
		Vector2(12, 21), Vector2(4, 16), Vector2(4, 8)
	])
	# Fill manually
	for ry in range(3, 22):
		var halfw: int
		if ry <= 8:
			halfw = (ry - 3) * 8 / 5
		elif ry >= 16:
			halfw = (21 - ry) * 8 / 5
		else:
			halfw = 8
		for rx in range(12 - halfw, 12 + halfw + 1):
			img.set_pixel(rx, ry, md)
	# Gold edge trim along the outline
	for i in range(pts.size()):
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		_bline(img, int(a.x), int(a.y), int(b.x), int(b.y), gd)
	# Inner highlight near top
	_line(img,  6, 9, 18, 9, lt, 1)
	_line(img,  8, 7, 16, 7, lt.lightened(0.2), 1)
	# Dark center spot
	_circle(img, 12, 13, 2.0, dk)
	_px(img, 11, 12, gd)
	_outline(img); _save(img, "world_serpent_scale")

func _gen_drowned_crown() -> void:
	var img := _img()
	var dk := Color(0.05, 0.18, 0.20)
	var md := Color(0.18, 0.42, 0.45)
	var coral := Color(0.62, 0.32, 0.45)
	var seaweed := Color(0.18, 0.55, 0.28)
	# Crown band
	_rect(img, 5, 14, 14, 4, dk)
	_rect(img, 5, 14, 14, 1, md)
	# Three spikes
	for spike: int in [6, 11, 16]:
		_rect(img, spike, 9, 2, 5, md)
		_circle(img, spike + 1, 8, 1.4, coral)
	# Mid spike taller
	_rect(img, 11, 6, 2, 8, md)
	_circle(img, 12, 5, 1.6, coral)
	# Barnacle dots on band
	_circle(img,  7, 16, 1.0, md.lightened(0.3))
	_circle(img, 12, 16, 1.0, md.lightened(0.3))
	_circle(img, 17, 16, 1.0, md.lightened(0.3))
	# Seaweed draping off sides
	_line(img,  5, 18, 3, 22, seaweed, 1)
	_line(img,  4, 19, 4, 22, seaweed.darkened(0.1), 1)
	_line(img, 19, 18, 21, 22, seaweed, 1)
	_line(img, 20, 19, 20, 22, seaweed.darkened(0.1), 1)
	_outline(img); _save(img, "drowned_crown")

func _gen_drowned_god() -> void:
	var img := _img()
	var dk := Color(0.02, 0.02, 0.10)
	var md := Color(0.12, 0.08, 0.28)
	var lt := Color(0.42, 0.22, 0.62)
	var gd := Color(0.65, 0.55, 0.18)
	# Void orb
	_circle(img, 12, 13, 8.0, dk)
	_circle(img, 12, 13, 6.5, md)
	# Inner glow tendrils
	_circle(img, 11, 12, 2.5, lt)
	_circle(img, 11, 12, 1.0, WHITE)
	# Tendrils extending off the orb
	for ang: float in [0.2, 1.0, 1.8, 2.6, 3.4, 4.2, 5.0, 5.8]:
		var ex := 12 + int(round(cos(ang) * 10.0))
		var ey := 13 + int(round(sin(ang) * 10.0))
		_bline(img, 12 + int(cos(ang) * 7), 13 + int(sin(ang) * 7), ex, ey, lt)
	# Crown embedded — small gold band across the top
	_rect(img, 9, 7, 6, 2, gd.darkened(0.2))
	_px(img,  9, 6, gd); _px(img, 12, 5, gd); _px(img, 15, 6, gd)
	_outline(img); _save(img, "drowned_god")

func _gen_jormungandr_spawn() -> void:
	var img := _img()
	var dk := Color(0.04, 0.18, 0.10)
	var md := Color(0.18, 0.42, 0.22)
	var lt := Color(0.42, 0.72, 0.42)
	var gd := Color(0.95, 0.82, 0.20)
	# Coiled serpent — concentric rings (top-down view)
	_circle(img, 12, 13, 9.0, dk)
	_circle(img, 12, 13, 8.0, md)
	_circle(img, 12, 13, 6.5, dk)
	_circle(img, 12, 13, 5.5, md)
	_circle(img, 12, 13, 4.0, dk)
	_circle(img, 12, 13, 3.0, md)
	# Scales — segmentation dots along the coils
	for ang: float in [0.0, 0.78, 1.56, 2.35, 3.14, 3.92, 4.71, 5.49]:
		_px(img, 12 + int(round(cos(ang) * 7)), 13 + int(round(sin(ang) * 7)), lt)
		_px(img, 12 + int(round(cos(ang) * 5)), 13 + int(round(sin(ang) * 5)), lt)
	# Head bump on top with a gold eye
	_ellipse(img, 12, 5, 3, 2, md.lightened(0.15))
	_circle(img, 12, 5, 1.0, gd)
	_px(img, 12, 5, dk)
	_outline(img); _save(img, "jormungandr_spawn")

# ── Bait ─────────────────────────────────────────────────────────────────────

func _gen_earthworm() -> void:
	var img := _img()
	var dk := Color(0.45, 0.18, 0.22)
	var md := Color(0.78, 0.32, 0.42)
	var lt := Color(0.95, 0.55, 0.62)
	# Squiggly worm body — sine wave
	for i in range(18):
		var sy := 5 + i
		var sx := 11 + int(round(sin(float(i) * 0.7) * 4.0))
		_rect(img, sx - 1, sy, 3, 1, md)
	# Segmentation lines every few rows
	for sy in range(7, 21, 3):
		var sx := 11 + int(round(sin(float(sy - 5) * 0.7) * 4.0))
		_px(img, sx, sy, dk)
		_px(img, sx + 1, sy, dk)
	# Darker head on top
	_circle(img, 11 + int(round(sin(0.0) * 4.0)), 5, 2.0, dk)
	# Highlight stripe
	for i in range(16):
		var sy := 6 + i
		var sx := 11 + int(round(sin(float(i) * 0.7) * 4.0))
		_px(img, sx, sy, lt)
	_outline(img); _save(img, "earthworm")

func _gen_fatty_lard() -> void:
	var img := _img()
	var dk := Color(0.72, 0.65, 0.45)
	var md := Color(0.95, 0.92, 0.82)
	var lt := Color(1.00, 0.98, 0.92)
	# Irregular blob
	_ellipse(img, 12, 14, 8, 6, dk)
	_ellipse(img, 12, 14, 7, 5, md)
	_ellipse(img, 10, 12, 4, 3, lt)
	# Slight bumps on the silhouette
	_circle(img,  6, 13, 2.0, md)
	_circle(img, 18, 15, 2.0, md)
	_circle(img, 13, 19, 2.0, md)
	_circle(img, 11,  9, 2.0, md)
	# Grease shine spot
	_circle(img, 10, 11, 1.2, WHITE)
	_px(img,  9, 10, WHITE)
	# Subtle darker pock
	_px(img, 14, 16, dk)
	_outline(img); _save(img, "fatty_lard")

# ── Equipment ────────────────────────────────────────────────────────────────

func _gen_dragon_boots() -> void:
	var img := _img()
	var dk := Color(0.22, 0.05, 0.06)
	var md := Color(0.55, 0.10, 0.12)
	var lt := Color(0.85, 0.32, 0.32)
	var gd := Color(0.92, 0.78, 0.18)
	# Boot silhouette — shaft + foot
	# Shaft
	_rect(img,  8, 4, 8, 11, md)
	_rect(img,  8, 4, 8, 2, lt)              # top opening
	_rect(img,  8, 4, 1, 11, lt.darkened(0.15))
	_rect(img, 15, 4, 1, 11, dk)
	# Foot
	_rect(img,  4, 15, 16, 5, md)
	_rect(img,  4, 19, 16, 1, dk)             # sole
	# Toe curl
	_circle(img,  5, 17, 2.0, md)
	# Dragon scale texture (V-shaped lines on shaft)
	for ry in range(6, 14, 3):
		_line(img,  9, ry, 12, ry - 1, dk, 1)
		_line(img, 12, ry - 1, 15, ry, dk, 1)
		_px(img, 12, ry - 1, lt)
	# Scale lines on foot
	_line(img,  6, 17, 18, 17, dk, 1)
	_line(img,  6, 17,  9, 16, lt, 1)
	# Gold trim at top opening
	_rect(img,  8, 4, 8, 1, gd)
	_px(img,  7, 4, gd); _px(img, 16, 4, gd)
	_outline(img); _save(img, "dragon_boots")

# ── Crafting (absorbed from Construction) ────────────────────────────────────

func _gen_campfire() -> void:
	var img := _img()
	var wood := Color(0.42, 0.24, 0.08)
	var wlt := Color(0.65, 0.42, 0.18)
	var flame_dk := Color(0.85, 0.32, 0.08)
	var flame_md := Color(1.00, 0.62, 0.18)
	var flame_lt := Color(1.00, 0.92, 0.45)
	# Three logs forming a triangle base
	_line(img,  4, 20, 14, 14, wood, 3)
	_line(img,  5, 20, 15, 14, wlt, 1)
	_line(img, 20, 20, 10, 14, wood, 3)
	_line(img, 19, 20, 11, 14, wlt, 1)
	_line(img,  4, 21, 20, 21, wood, 2)
	# Log end-circles
	_circle(img,  4, 20, 1.6, wood.darkened(0.2))
	_circle(img, 20, 20, 1.6, wood.darkened(0.2))
	# Flame body (rising teardrop)
	_ellipse(img, 12, 11, 3, 5, flame_dk)
	_ellipse(img, 12, 10, 2, 4, flame_md)
	_ellipse(img, 12,  9, 1, 3, flame_lt)
	# Flame tip
	_px(img, 12, 5, flame_lt)
	# Ember dots near base
	_px(img,  9, 13, flame_md); _px(img, 15, 13, flame_md)
	_px(img,  7, 17, flame_dk); _px(img, 17, 17, flame_dk)
	_outline(img); _save(img, "campfire")

func _gen_storage_crate() -> void:
	var img := _img()
	var dk := Color(0.28, 0.15, 0.04)
	var md := Color(0.55, 0.32, 0.10)
	var lt := Color(0.78, 0.55, 0.25)
	var metal := Color(0.52, 0.48, 0.42)
	# Square crate body
	_rect(img,  4,  6, 16, 14, md)
	_rect(img,  4,  6, 16, 1, lt)             # top edge shine
	_rect(img,  4, 19, 16, 1, dk)             # bottom edge
	# Wood plank lines (vertical)
	_line(img,  9,  6,  9, 19, dk, 1)
	_line(img, 14,  6, 14, 19, dk, 1)
	_line(img, 10,  7, 10, 18, lt.darkened(0.2), 1)
	_line(img, 15,  7, 15, 18, lt.darkened(0.2), 1)
	# Cross-brace (diagonals)
	_line(img,  4,  6, 19, 19, dk.lightened(0.1), 1)
	_line(img,  4, 19, 19,  6, dk.lightened(0.1), 1)
	# Metal corner dots
	for cx: int in [4, 19]:
		for cy: int in [6, 19]:
			_px(img, cx, cy, metal)
			_px(img, cx + (1 if cx == 4 else -1), cy, metal.lightened(0.2))
	_outline(img); _save(img, "storage_crate")

func _gen_torch_post() -> void:
	var img := _img()
	var wood_dk := Color(0.25, 0.14, 0.04)
	var wood_md := Color(0.45, 0.28, 0.10)
	var wood_lt := Color(0.68, 0.45, 0.20)
	var flame_md := Color(1.00, 0.62, 0.18)
	var flame_lt := Color(1.00, 0.92, 0.45)
	# Vertical post
	_rect(img, 10,  9, 4, 13, wood_md)
	_rect(img, 10,  9, 1, 13, wood_lt)        # left highlight
	_rect(img, 13,  9, 1, 13, wood_dk)        # right shadow
	# Base spread
	_rect(img,  8, 21, 8, 1, wood_dk)
	# Torch head (wrapped top)
	_rect(img,  9,  7, 6, 3, wood_dk)
	_rect(img,  9,  7, 6, 1, wood_md)
	# Flame
	_ellipse(img, 12,  5, 2, 3, flame_md)
	_circle(img, 12,  4, 1.2, flame_lt)
	# Glow halo
	_circle(img, 12,  5, 5.0, Color(1.0, 0.65, 0.20, 0.18))
	_circle(img, 12,  5, 3.0, Color(1.0, 0.85, 0.40, 0.30))
	_outline(img); _save(img, "torch_post")

func _gen_bookshelf() -> void:
	var img := _img()
	var dk := Color(0.22, 0.12, 0.04)
	var md := Color(0.52, 0.30, 0.10)
	var lt := Color(0.75, 0.52, 0.22)
	# Outer frame
	_rect(img,  3,  4, 18, 17, md)
	_rect(img,  3,  4, 18, 1, lt)
	_rect(img,  3, 20, 18, 1, dk)
	_rect(img,  3,  4, 1, 17, lt.darkened(0.15))
	_rect(img, 20,  4, 1, 17, dk)
	# Two shelf dividers
	_rect(img,  4, 10, 16, 1, dk)
	_rect(img,  4, 16, 16, 1, dk)
	# Books — three colored spines per shelf
	var books_top: Array = [
		Color(0.62, 0.18, 0.20), Color(0.18, 0.38, 0.62), Color(0.22, 0.55, 0.22)
	]
	var books_mid: Array = [
		Color(0.85, 0.72, 0.20), Color(0.42, 0.22, 0.55), Color(0.65, 0.32, 0.12)
	]
	var books_bot: Array = [
		Color(0.20, 0.20, 0.55), Color(0.55, 0.20, 0.42), Color(0.30, 0.62, 0.62)
	]
	# Top row
	for i in range(3):
		var bx := 5 + i * 5
		_rect(img, bx, 5, 4, 5, books_top[i])
		_rect(img, bx, 5, 1, 5, (books_top[i] as Color).lightened(0.25))
		_px(img, bx, 5, (books_top[i] as Color).darkened(0.3))
	# Middle row
	for i in range(3):
		var bx := 5 + i * 5
		_rect(img, bx, 11, 4, 5, books_mid[i])
		_rect(img, bx, 11, 1, 5, (books_mid[i] as Color).lightened(0.25))
	# Bottom row
	for i in range(3):
		var bx := 5 + i * 5
		_rect(img, bx, 17, 4, 3, books_bot[i])
		_rect(img, bx, 17, 1, 3, (books_bot[i] as Color).lightened(0.25))
	_outline(img); _save(img, "bookshelf")
