extends Node2D

## Fires every time a single tile is mutated through apply_tile_change(). A
## future multiplayer/persistence layer connects to this signal to broadcast
## the change to other clients and/or write it through to the server. Nothing
## else inside Ground emits per-tile changes — apply_tile_change() is the only
## entry point that touches the cache, the lookup texture, and this signal.
@warning_ignore("unused_signal")
signal tile_changed(tx: int, ty: int, biome_id: int)

const TILE := 32
const COLS := 300
const ROWS := 300

# Biome cache — built once in _ready, looked up O(1) during draw
var _biome_cache: PackedByteArray  # biome IDs 0-13

# Per-tile biome lookup as a 300x300 R8 texture. The shader path will sample this
# (each pixel's R channel = biome_id) so terrain can be rendered from an atlas
# with neighbor-aware blending without re-walking the cache per fragment.
var _biome_lookup_img: Image       = null
var _biome_lookup_tex: ImageTexture = null

# Biome atlas — one 32×32 cell per biome id (0..15), stacked vertically into a
# 32×(16*32) texture. Each cell is a single representative bake of that biome's
# _draw_<name> output (deterministic hv per cell, so no per-tile variation —
# variation will come back later via the shader's noise sample). Built once at
# startup via SubViewport, then handed to the terrain_blend shader as a uniform.
var _biome_atlas_img: Image       = null
var _biome_atlas_tex: ImageTexture = null
const BIOME_COUNT := 16

# True once the atlas bake has finished AND terrain_blend.gdshader is bound to
# this node. Before that, _draw() falls back to the CPU per-tile dispatch so the
# world isn't blank for the ~2 frames the SubViewport bake takes.
var _atlas_ready: bool = false

# Biome ID constants
const B_PLAINS      := 0
const B_PLAINS2     := 1  # variant
const B_OAK_FOREST  := 2
const B_PINE_FOREST := 3
const B_DARK_FOREST := 4
const B_SWAMP       := 5
const B_MOUNTAIN    := 6
const B_ROCKY       := 7
const B_COAST       := 8
const B_OCEAN       := 9
const B_SNOW        := 10
const B_HELHEIM     := 11
const B_ASHLANDS    := 12
const B_TOWN        := 13
const B_ROAD        := 14
const B_CLIFF       := 15  # impassable mountain wall (zone border, hard collision)

const _BIOME_NAMES := [
	"plains", "plains", "oak_forest", "pine_forest", "dark_forest",
	"swamp", "mountain", "rocky", "coast", "ocean",
	"snow", "helheim", "ashlands", "town", "road", "cliff",
]

func _ready() -> void:
	add_to_group("ground")
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/ground_noise.gdshader") as Shader
	self.material = mat
	_build_cache()
	_build_biome_lookup_tex()
	_rebuild_impassable_collision()
	# Atlas bake awaits a SubViewport render — runs after the rest of init so
	# the world is fully playable before the bake completes. Step 4 will switch
	# the per-tile draw path over to atlas sampling once this is ready.
	await _bake_biome_atlas()

## Public API — returns the biome name at a world pixel position.
func biome_at_world(world_pos: Vector2) -> String:
	return _biome_at(floori(world_pos.x / float(TILE)), floori(world_pos.y / float(TILE)))

## True when a position is open ocean far from any shore (a 5×5 tile block of
## ocean). Used for boat fishing to gate rare deep-sea catches.
func is_deep_ocean(world_pos: Vector2) -> bool:
	var tx := floori(world_pos.x / float(TILE))
	var ty := floori(world_pos.y / float(TILE))
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if _biome_at(tx + dx, ty + dy) != "ocean":
				return false
	return true

# ── Noise helpers ─────────────────────────────────────────────────────────────

func _tile_hash(x: int, y: int) -> int:
	return (x * 1619 + y * 31337) & 0xFFFF

func _tile_hash2(x: int, y: int, s: int) -> int:
	return (x * 2179 + y * 47623 + s * 1031) & 0xFFFF

# Smooth value noise 0.0–1.0
func _vnoise(x: float, y: float) -> float:
	var ix := floori(x); var iy := floori(y)
	var fx := x - float(ix); var fy := y - float(iy)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a := float(_tile_hash(ix,     iy    )) / 65535.0
	var b := float(_tile_hash(ix + 1, iy    )) / 65535.0
	var c := float(_tile_hash(ix,     iy + 1)) / 65535.0
	var d := float(_tile_hash(ix + 1, iy + 1)) / 65535.0
	return lerp(lerp(a, b, fx), lerp(c, d, fx), fy)

# 3-octave fractional Brownian motion — result 0.0–1.0
func _fbm(x: float, y: float) -> float:
	return (_vnoise(x, y) * 0.55
		+   _vnoise(x * 2.1 + 17.3, y * 2.1 +  9.7) * 0.30
		+   _vnoise(x * 4.2 + 52.1, y * 4.2 + 31.5) * 0.15)

# ── Settlement / road detection ───────────────────────────────────────────────

func _is_town(tx: int, ty: int) -> bool:
	# Kjelvik (hub) tx 77-90, ty 109-122
	if tx >= 77 and tx <= 90 and ty >= 109 and ty <= 122: return true
	# Frostheim tx 37-50, ty 23-36
	if tx >= 37 and tx <= 50 and ty >= 23 and ty <= 36:  return true
	# Ironwood Keep tx 105-118, ty 149-162
	if tx >= 105 and tx <= 118 and ty >= 149 and ty <= 162: return true
	# Eastmark Post tx 179-192, ty 177-190
	if tx >= 179 and tx <= 192 and ty >= 177 and ty <= 190: return true
	# Bjorn's Landing tx 240-253, ty 132-145
	if tx >= 240 and tx <= 253 and ty >= 132 and ty <= 145: return true
	return false

func _is_road(tx: int, ty: int) -> bool:
	# Kjelvik ↔ Frostheim (N road + E-W connector)
	if tx >= 77 and tx <= 79 and ty >= 36 and ty <= 109: return true
	if tx >= 50 and tx <= 77 and ty >= 76 and ty <= 78:  return true
	if tx >= 50 and tx <= 52 and ty >= 36 and ty <= 77:  return true
	# Kjelvik ↔ Ironwood Keep (S road)
	if tx >= 84 and tx <= 86 and ty >= 122 and ty <= 149: return true
	# Kjelvik ↔ Eastmark Post (E road)
	if tx >= 90 and tx <= 179 and ty >= 113 and ty <= 115: return true
	# Kjelvik ↔ Bjorn's Landing (NE road)
	if tx >= 90 and tx <= 239 and ty >= 109 and ty <= 111: return true
	if tx >= 239 and tx <= 241 and ty >= 109 and ty <= 132: return true
	# Eastmark ↔ Bjorn's Landing (N-S connection)
	if tx >= 192 and tx <= 243 and ty >= 132 and ty <= 134: return true
	return false

# ── Biome cache build ─────────────────────────────────────────────────────────

func _build_cache() -> void:
	_biome_cache.resize(COLS * ROWS)
	for ty in range(ROWS):
		for tx in range(COLS):
			_biome_cache[ty * COLS + tx] = _compute_biome_id(tx, ty)

# Admin-painted terrain overrides: idx (ty*COLS+tx) → biome id. Applied on top of
# the deterministic biome cache, persisted server-side, so edits last forever.
var _overrides: Dictionary = {}
var _collision_body: StaticBody2D = null

func _bid_at(tx: int, ty: int) -> int:
	var idx := ty * COLS + tx
	if _overrides.has(idx):
		return int(_overrides[idx])
	return _biome_cache[idx]

func _is_impassable_bid(bid: int) -> bool:
	return bid == B_OCEAN or bid == B_COAST or bid == B_CLIFF

## Rebuild the single combined collision body from the effective (override-aware)
## biome map. Called once at startup and again whenever a tile is painted —
## handles both adding and removing impassable tiles cleanly.
func _rebuild_impassable_collision() -> void:
	if _collision_body != null and is_instance_valid(_collision_body):
		_collision_body.queue_free()
	var body := StaticBody2D.new()
	body.collision_layer = 2   # blocks on-foot movement (water + cliffs)
	body.collision_mask  = 0
	add_child(body)
	_collision_body = body
	for ty in range(ROWS):
		var run_start := -1
		for tx in range(COLS + 1):
			var imp := tx < COLS and _is_impassable_bid(_bid_at(tx, ty))
			if imp and run_start < 0:
				run_start = tx
			elif not imp and run_start >= 0:
				var cs   := CollisionShape2D.new()
				var rect := RectangleShape2D.new()
				var w    := float((tx - run_start) * TILE)
				rect.size   = Vector2(w, float(TILE))
				cs.position = Vector2(float(run_start * TILE) + w * 0.5,
				                      float(ty * TILE) + float(TILE) * 0.5)
				cs.shape = rect
				body.add_child(cs)
				run_start = -1

# ── Tile-override public API (driven by the admin editor via World) ────────────
func biome_name_to_id(biome_name: String) -> int:
	var i := _BIOME_NAMES.find(biome_name)
	return i if i >= 0 else B_PLAINS

## Build the 300x300 R8 biome lookup texture from the current _biome_cache.
## Each pixel's R channel encodes the biome id (0..15). The shader path samples
## this to do per-fragment biome lookup + neighbor blending. Updates after
## startup happen incrementally inside apply_tile_change().
func _build_biome_lookup_tex() -> void:
	_biome_lookup_img = Image.create(COLS, ROWS, false, Image.FORMAT_R8)
	for ty in range(ROWS):
		for tx in range(COLS):
			var bid: int = _biome_cache[ty * COLS + tx]
			_biome_lookup_img.set_pixel(tx, ty, Color8(bid, 0, 0, 255))
	_biome_lookup_tex = ImageTexture.create_from_image(_biome_lookup_img)

## Render each biome's draw output into a single representative 32×32 cell, all
## stacked into a 32 × (BIOME_COUNT*32) atlas. Uses a one-shot SubViewport and
## the inner _AtlasBaker node to dispatch into the shared per-biome draw funcs.
## Awaits two frame_post_draw to let the viewport flush before we read it back.
func _bake_biome_atlas() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(TILE, BIOME_COUNT * TILE)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Don't let the viewport's render texture pick up filter/repeat from the
	# world — we want crisp 1:1 pixels in the atlas.
	vp.disable_3d = true
	add_child(vp)
	var baker := _AtlasBaker.new()
	baker.ground = self
	vp.add_child(baker)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	_biome_atlas_img = vp.get_texture().get_image()
	_biome_atlas_tex = ImageTexture.create_from_image(_biome_atlas_img)
	vp.queue_free()
	_activate_terrain_shader()

## Swap the placeholder ground_noise material for terrain_blend.gdshader and
## hand it the baked atlas + biome lookup. After this, _draw() collapses to a
## single full-coverage rect and per-frame redraws stop — the shader keeps
## rendering on its own; we only `queue_redraw` when the lookup texture
## actually changes (apply_tile_change / apply_tile_overrides).
func _activate_terrain_shader() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain_blend.gdshader") as Shader
	mat.set_shader_parameter("atlas",            _biome_atlas_tex)
	mat.set_shader_parameter("biome_lookup",     _biome_lookup_tex)
	mat.set_shader_parameter("world_size_tiles", Vector2(float(COLS), float(ROWS)))
	mat.set_shader_parameter("tile_px",          float(TILE))
	mat.set_shader_parameter("atlas_rows",       float(BIOME_COUNT))
	self.material = mat
	_atlas_ready = true
	set_process(false)
	queue_redraw()

## Dispatcher used by the atlas baker — same routing as _draw_tile but no
## edge-blend post pass (the shader will handle inter-biome blending later).
## Uses a deterministic per-biome hash so each cell is reproducible.
func _draw_biome_cell(ci: CanvasItem, bid: int, x: int, y: int) -> void:
	var hv := bid * 1009 + 37
	var cx := float(x) + 16.0
	var cy := float(y) + 16.0
	var biome: String = _BIOME_NAMES[bid]
	match biome:
		"town":        _draw_town(ci, hv, x, y, cx, cy)
		"road":        _draw_road(ci, hv, x, y, cx, cy)
		"coast":       _draw_coast(ci, hv, x, y, cx, cy)
		"ocean":       _draw_ocean(ci, hv, x, y, cx, cy)
		"snow":        _draw_snow(ci, hv, x, y, cx, cy)
		"mountain":    _draw_mountain(ci, hv, x, y, cx, cy)
		"cliff":       _draw_cliff(ci, hv, x, y, cx, cy)
		"rocky":       _draw_rocky(ci, hv, x, y, cx, cy)
		"dark_forest": _draw_dark_forest(ci, hv, x, y, cx, cy)
		"oak_forest":  _draw_oak_forest(ci, hv, x, y, cx, cy)
		"pine_forest": _draw_pine_forest(ci, hv, x, y, cx, cy)
		"swamp":       _draw_swamp(ci, hv, x, y, cx, cy)
		"helheim":     _draw_helheim(ci, hv, x, y, cx, cy)
		"ashlands":    _draw_ashlands(ci, hv, x, y, cx, cy)
		_:             _draw_plains(ci, hv, x, y, cx, cy)

## THE single entry point for mutating a tile. Nothing else (editor, network,
## load path) should poke _overrides / _biome_lookup_img / _biome_cache
## directly — go through here. Steps performed, in order:
##   1. Write the new id into the override map (or erase the override if the
##      new id matches the procedurally-cached base biome).
##   2. Update the single lookup texture pixel for (tx, ty). This is also the
##      "atlas region refresh" for that tile + its 4 neighbors under the GPU
##      path: terrain_blend.gdshader samples biome ids from this texture every
##      frame, so changing one pixel automatically (a) re-skins the painted
##      tile and (b) re-evaluates the edge blend on all 4 neighbors next frame
##      — no per-tile atlas patching is needed because the atlas is keyed by
##      biome id, not by world position.
##   3. Rebuild impassable collision iff the impassable status of the tile flipped.
##   4. queue_redraw — the GPU path re-issues the same single rect (cheap) and
##      the new lookup pixel takes effect; the CPU fallback repaints the
##      affected area (which also refreshes the 4 neighbor blends because each
##      neighbor's _draw reads _bid_at() of the changed tile).
##   5. Emit tile_changed so the multiplayer manager can broadcast / persist.
func apply_tile_change(tx: int, ty: int, biome_id: int) -> void:
	if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
		return
	var idx := ty * COLS + tx
	var base_bid: int = _biome_cache[idx]
	var was_imp := _is_impassable_bid(_bid_at(tx, ty))
	if biome_id == base_bid:
		_overrides.erase(idx)
	else:
		_overrides[idx] = biome_id
	if _biome_lookup_img != null and _biome_lookup_tex != null:
		_biome_lookup_img.set_pixel(tx, ty, Color8(biome_id, 0, 0, 255))
		_biome_lookup_tex.update(_biome_lookup_img)
	if was_imp != _is_impassable_bid(_bid_at(tx, ty)):
		_rebuild_impassable_collision()
	queue_redraw()
	tile_changed.emit(tx, ty, biome_id)

# Thin wrappers kept for back-compat with existing call sites (World tile-event
# routing and the admin paint network handler). All real work flows through
# apply_tile_change() above.
func set_tile_override(tx: int, ty: int, biome: String) -> void:
	apply_tile_change(tx, ty, biome_name_to_id(biome))

func clear_tile_override(tx: int, ty: int) -> void:
	if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
		return
	apply_tile_change(tx, ty, _biome_cache[ty * COLS + tx])

## Bulk load path (called on login with the full server-persisted override set).
## Intentionally does NOT emit per-tile signals — a future multiplayer manager
## would otherwise echo every tile back to the network at every login. Treat
## this as data ingestion, not a user action.
func apply_tile_overrides(overrides: Array) -> void:
	_overrides.clear()
	# Reset the lookup image to the procedural baseline before re-applying overrides.
	if _biome_lookup_img != null:
		for ty in range(ROWS):
			for tx in range(COLS):
				var bid: int = _biome_cache[ty * COLS + tx]
				_biome_lookup_img.set_pixel(tx, ty, Color8(bid, 0, 0, 255))
	for o: Variant in overrides:
		if o is Dictionary:
			var d: Dictionary = o
			var tx := int(d.get("tx", -1))
			var ty := int(d.get("ty", -1))
			if tx >= 0 and tx < COLS and ty >= 0 and ty < ROWS:
				var nb_id := biome_name_to_id(str(d.get("biome", "plains")))
				_overrides[ty * COLS + tx] = nb_id
				if _biome_lookup_img != null:
					_biome_lookup_img.set_pixel(tx, ty, Color8(nb_id, 0, 0, 255))
	if _biome_lookup_tex != null and _biome_lookup_img != null:
		_biome_lookup_tex.update(_biome_lookup_img)
	_rebuild_impassable_collision()
	queue_redraw()
	# Auto-refresh the minimap so it reflects the server's saved overrides
	# right after the login burst, without the admin needing to click Save Map.
	# The Save Map button still emits this signal manually on demand.
	Events.minimap_refresh.emit()

func _biome_at(tx: int, ty: int) -> String:
	if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
		return "plains"
	return _BIOME_NAMES[_bid_at(tx, ty)]

func _compute_biome_id(tx: int, ty: int) -> int:
	if _is_town(tx, ty): return B_TOWN
	if _is_road(tx, ty): return B_ROAD

	var fx := float(tx)
	var fy := float(ty)

	# Domain warp — perturb sampling position with fbm noise
	# Two independent warp offsets give organic, non-correlated borders
	var sc := 1.0 / 42.0
	var wx := fx + (_fbm(fx * sc,        fy * sc       ) - 0.5) * 30.0
	var wy := fy + (_fbm(fx * sc + 8.7,  fy * sc + 4.1) - 0.5) * 26.0

	# === RIGHT COASTAL WATERS (eastern bay) ===
	if wx > 254.0 and wy > 82.0: return B_COAST

	# === LEFT OCEAN (Serpent Sea) ===
	if wx < 11.0 + wy * 0.055 and wy > 88.0: return B_OCEAN

	# === SNOW / ICE (Frostheim, top-left) ===
	if wx < 124.0 - wy * 0.87 and wy < 93.0: return B_SNOW

	# === MOUNTAINS (top-center-right strip) ===
	if wy < 80.0 and wx > 84.0 - wy * 0.28: return B_MOUNTAIN

	# === IRONWOOD DARK FOREST (center, ellipse) ===
	# Center (112, 144), semi-axes 52 × 29
	var iw_dx := (wx - 112.0) / 52.0
	var iw_dy := (wy - 144.0) / 29.0
	if iw_dx * iw_dx + iw_dy * iw_dy < 1.0: return B_DARK_FOREST

	# === HELHEIM (bottom-left purple zone) ===
	if wx < 112.0 + (wy - 176.0) * 0.12 and wy > 174.0: return B_HELHEIM

	# === ASHLANDS (bottom-center orange zone) ===
	if wy > 152.0 and wx > 76.0: return B_ASHLANDS

	# === OAK FOREST (west, flanking the ocean coast) ===
	if wx < 71.0 and wy > 88.0 and wy < 166.0: return B_OAK_FOREST

	# === PINE FOREST (central-north, between mountains and grassland) ===
	if wy > 84.0 and wy < 117.0 and wx > 70.0 and wx < 182.0: return B_PINE_FOREST

	# === SWAMP (transition fringe near helheim/ironwood) ===
	var sw_dx := (wx - 112.0) / 60.0
	var sw_dy := (wy - 144.0) / 36.0
	if sw_dx * sw_dx + sw_dy * sw_dy < 1.0: return B_SWAMP

	# === ROCKY HIGHLANDS (mountain foot) ===
	if wy < 102.0 and wx > 86.0: return B_ROCKY

	return B_PLAINS

# ── Render ────────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	if _atlas_ready:
		# GPU path. One full-world rect; terrain_blend.gdshader does per-pixel
		# biome lookup, atlas sampling, neighbor-aware edge blend, dither and
		# grain. The rect's VERTEX carries world coords to the fragment via the
		# `world_pos` varying.
		draw_rect(Rect2(0, 0, COLS * TILE, ROWS * TILE), Color(1, 1, 1, 1))
	else:
		_draw_cpu()
	draw_rect(Rect2(0, 0, COLS * TILE, ROWS * TILE), Color(0.05, 0.05, 0.05), false, 2.0)

## Pre-bake fallback (CPU per-tile dispatch). Active only for the ~2 frames
## between _ready and _activate_terrain_shader. Culls to the visible rect so
## even the fallback doesn't try to draw all 90 000 tiles per frame.
func _draw_cpu() -> void:
	var ct  := get_canvas_transform()
	var inv := ct.affine_inverse()
	var vr  := get_viewport_rect()
	var tl  := inv * vr.position
	var br  := inv * (vr.position + vr.size)

	var tx_min := maxi(0,        floori(tl.x / float(TILE)) - 1)
	var ty_min := maxi(0,        floori(tl.y / float(TILE)) - 1)
	var tx_max := mini(COLS - 1, ceili(br.x  / float(TILE)) + 1)
	var ty_max := mini(ROWS - 1, ceili(br.y  / float(TILE)) + 1)

	for ty in range(ty_min, ty_max + 1):
		for tx in range(tx_min, tx_max + 1):
			var hv := _tile_hash(tx, ty)
			var bm := _biome_at(tx, ty)
			_draw_tile(bm, hv, tx, ty, tx * TILE, ty * TILE)

## Blend behavior between a tile of biome `a` and a neighbor of biome `b`.
## Returns a Dictionary with at least `mode` ("edge" or "interior") and the
## mode-specific params used by the edge-transition loop in _draw_tile.
func _blend_params(a: String, b: String) -> Dictionary:
	# Path / town adjacency → sharp narrow edge regardless of neighbor.
	if a == "road" or a == "town" or b == "road" or b == "town":
		return {"mode": "edge", "span": 2, "strength": 0.90}
	var a_water := a == "ocean" or a == "coast"
	var b_water := b == "ocean" or b == "coast"
	# Both water (ocean ↔ coast) → no overlay; let the biome's own ripple art show.
	if a_water and b_water:
		return {"mode": "none"}
	# Water ↔ land (shoreline) → soft uniform strip, no dither. Restores the
	# original pre-dither shoreline look.
	if a_water != b_water:
		return {"mode": "soft_strip", "width": 6, "strength": 0.30}
	# Default land ↔ land.
	return {"mode": "edge", "span": 8, "strength": 0.85}

func _biome_base_color(biome: String) -> Color:
	match biome:
		"town":        return Color(0.50, 0.44, 0.34)
		"road":        return Color(0.52, 0.43, 0.28)
		"coast":       return Color(0.20, 0.55, 0.82)
		"ocean":       return Color(0.05, 0.12, 0.58)
		"snow":        return Color(0.80, 0.90, 0.96)
		"mountain":    return Color(0.52, 0.50, 0.48)
		"cliff":       return Color(0.30, 0.27, 0.25)
		"rocky":       return Color(0.42, 0.40, 0.37)
		"dark_forest": return Color(0.07, 0.16, 0.08)
		"oak_forest":  return Color(0.18, 0.42, 0.14)
		"pine_forest": return Color(0.11, 0.28, 0.13)
		"swamp":       return Color(0.20, 0.27, 0.14)
		"helheim":     return Color(0.40, 0.06, 0.50)
		"ashlands":    return Color(0.54, 0.28, 0.08)
		_:             return Color(0.30, 0.52, 0.20)

func _draw_tile(biome: String, hv: int, tx: int, ty: int, x: int, y: int) -> void:
	var cx := float(x) + 16.0
	var cy := float(y) + 16.0
	# `self` here is the bake target for now (per-frame draw). When the atlas
	# bake lands, the dispatcher in the bake path will pass a SubViewport-owned
	# CanvasItem instead, and the per-biome funcs need zero changes.
	match biome:
		"town":        _draw_town(self, hv, x, y, cx, cy)
		"road":        _draw_road(self, hv, x, y, cx, cy)
		"coast":       _draw_coast(self, hv, x, y, cx, cy)
		"ocean":       _draw_ocean(self, hv, x, y, cx, cy)
		"snow":        _draw_snow(self, hv, x, y, cx, cy)
		"mountain":    _draw_mountain(self, hv, x, y, cx, cy)
		"cliff":       _draw_cliff(self, hv, x, y, cx, cy)
		"rocky":       _draw_rocky(self, hv, x, y, cx, cy)
		"dark_forest": _draw_dark_forest(self, hv, x, y, cx, cy)
		"oak_forest":  _draw_oak_forest(self, hv, x, y, cx, cy)
		"pine_forest": _draw_pine_forest(self, hv, x, y, cx, cy)
		"swamp":       _draw_swamp(self, hv, x, y, cx, cy)
		"helheim":     _draw_helheim(self, hv, x, y, cx, cy)
		"ashlands":    _draw_ashlands(self, hv, x, y, cx, cy)
		_:             _draw_plains(self, hv, x, y, cx, cy)

	# Biome edge transitions — width / intensity / dither scale vary per biome PAIR:
	#   path adjacency (road/town ↔ anything) → sharp narrow edge (span 2, strength 0.9)
	#   water ↔ water (ocean ↔ coast)         → fine pixel-level checkerboard (2 px, no fade)
	#   water ↔ land  (shoreline)             → soft wide blend (span 8, strength 0.20)
	#   land  ↔ land  (default)               → Bayer dither (span 8, strength 0.85)
	var _nb_offsets := [[0, -1, 0], [0, 1, 1], [-1, 0, 2], [1, 0, 3]]
	const BLK := 4          # block size for the edge-fade dither (px)
	const BPT := 8          # blocks per tile side (TILE / BLK), constant
	# 4×4 Bayer matrix (0..15) — ordered dither for the fade.
	const BAYER := [
		 0,  8,  2, 10,
		12,  4, 14,  6,
		 3, 11,  1,  9,
		15,  7, 13,  5]
	for _nb: Array in _nb_offsets:
		var nx: int = tx + (_nb[0] as int)
		var ny: int = ty + (_nb[1] as int)
		if nx < 0 or nx >= COLS or ny < 0 or ny >= ROWS:
			continue
		var nb_biome := _biome_at(nx, ny)
		if nb_biome == biome:
			continue
		var bc := _biome_base_color(nb_biome)
		var p := _blend_params(biome, nb_biome)
		if p["mode"] == "none":
			# Water ↔ water: nothing extra — biome draw funcs already show ripples.
			continue
		if p["mode"] == "soft_strip":
			# Water ↔ land shoreline: a single uniform-alpha strip on the
			# neighbor's edge, no dithering. The soft pre-batch shoreline look.
			var width: int = p["width"]
			bc.a = p["strength"] as float
			var dir_s := _nb[2] as int
			match dir_s:
				0: draw_rect(Rect2(x, y, TILE, width), bc)
				1: draw_rect(Rect2(x, y + TILE - width, TILE, width), bc)
				2: draw_rect(Rect2(x, y, width, TILE), bc)
				3: draw_rect(Rect2(x + TILE - width, y, width, TILE), bc)
			continue
		# Edge fade (Bayer-dithered), with span and max strength from the pair table.
		var span: int = p["span"]
		var max_strength: float = p["strength"]
		var dir := _nb[2] as int
		for bi in range(span):
			var strength := (1.0 - float(bi) / float(span)) * max_strength
			for bj in range(BPT):
				var ax := tx * BPT
				var ay := ty * BPT
				var bx_block := ax
				var by_block := ay
				match dir:
					0: bx_block = ax + bj; by_block = ay + bi
					1: bx_block = ax + bj; by_block = ay + (BPT - 1 - bi)
					2: bx_block = ax + bi; by_block = ay + bj
					3: bx_block = ax + (BPT - 1 - bi); by_block = ay + bj
				var thresh := float(BAYER[(by_block & 3) * 4 + (bx_block & 3)]) / 16.0
				if thresh > strength:
					continue
				bc.a = clampf(strength * 0.95, 0.0, 0.95)
				var rx := x + (bx_block - ax) * BLK
				var ry := y + (by_block - ay) * BLK
				draw_rect(Rect2(rx, ry, BLK, BLK), bc)

	# (Tile-edge bevel removed — the dithered atlas blend handles transitions.)

# ── Biome draw functions ──────────────────────────────────────────────────────

func _draw_town(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	var base := Color(0.52, 0.46, 0.36) if hv % 3 == 0 else Color(0.46, 0.41, 0.32)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var stone_shades := [base.lightened(0.10), base, base.darkened(0.10), base.lightened(0.05)]
	for row in range(3):
		var ox := (row % 2) * 5
		for col in range(3):
			var sx := x + 2 + col * 10 + ox
			var sy := y + 2 + row * 10
			if sx + 8 < x + TILE and sy + 7 < y + TILE:
				var sc: Color = stone_shades[(hv + row * 3 + col) % 4]
				ci.draw_rect(Rect2(sx, sy, 8, 7), sc)
				ci.draw_rect(Rect2(sx, sy, 8, 1), sc.lightened(0.18))
				ci.draw_rect(Rect2(sx, sy + 6, 8, 1), sc.darkened(0.22))
	if hv % 5 == 0:
		ci.draw_line(Vector2(float(x) + 3, float(y) + 5),
				  Vector2(float(x) + 14, float(y) + 11),
				  Color(0.28, 0.24, 0.18, 0.50), 1.0)
	if hv % 11 == 0:
		ci.draw_circle(Vector2(float(x) + 10, float(y) + 8), 1.2, Color(0.28, 0.44, 0.12, 0.60))

func _draw_road(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	var base := Color(0.54, 0.45, 0.30) if hv % 3 != 0 else Color(0.48, 0.40, 0.26)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	ci.draw_rect(Rect2(x + 9, y, 14, TILE), base.darkened(0.07))
	ci.draw_rect(Rect2(x + 6, y, 3, TILE), base.darkened(0.20))
	ci.draw_rect(Rect2(x + 23, y, 3, TILE), base.darkened(0.20))
	if hv % 7 == 0:
		ci.draw_circle(Vector2(cx - 5.0, cy + 3.0), 1.5, Color(0.38, 0.32, 0.22, 0.65))
	if hv % 11 == 0:
		ci.draw_circle(Vector2(cx + 4.0, cy - 3.0), 1.2, Color(0.38, 0.32, 0.22, 0.45))
	if hv % 9 == 0:
		ci.draw_circle(Vector2(float(x) + 2.0, float(y) + float(hv % 24) + 4.0), 2.5,
				Color(0.28, 0.46, 0.14, 0.55))

func _draw_coast(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	var wave := Color(0.16, 0.50, 0.84) if hv % 3 != 0 else Color(0.20, 0.56, 0.90)
	ci.draw_rect(Rect2(x, y, TILE, TILE), wave)
	ci.draw_rect(Rect2(x, y, TILE, 6), wave.darkened(0.10))
	if hv % 3 == 0:
		ci.draw_arc(Vector2(cx, cy), 7.0, 0.0, PI, 8, Color(1, 1, 1, 0.22), 1.5)
	if hv % 5 == 0:
		ci.draw_circle(Vector2(cx - 4, cy + 3), 1.5, Color(0.88, 0.94, 1.0, 0.42))
		ci.draw_circle(Vector2(cx + 5, cy - 2), 1.0, Color(0.88, 0.94, 1.0, 0.35))
	if hv % 7 == 0:
		ci.draw_circle(Vector2(float(x) + float(hv % 28) + 2, float(y) + float((hv >> 5) % 28) + 2),
				0.8, Color(0.82, 0.95, 1.0, 0.45))

func _draw_ocean(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	var deep := Color(0.04, 0.10, 0.52) if hv % 3 != 0 else Color(0.06, 0.14, 0.60)
	ci.draw_rect(Rect2(x, y, TILE, TILE), deep)
	# Depth gradient (darker at top = horizon)
	ci.draw_rect(Rect2(x, y, TILE, 5), deep.darkened(0.15))
	# Swell arc
	if hv % 4 == 0:
		ci.draw_arc(Vector2(cx, cy + 6.0), 9.0, PI, TAU, 8, Color(0.14, 0.35, 0.72, 0.28), 1.5)
	# Foam crest
	if hv % 5 == 0:
		ci.draw_rect(Rect2(float(x) + float(hv % 24), float(y) + float((hv >> 4) % 20), 8, 1),
				Color(0.75, 0.88, 1.0, 0.28))
	# Sparkle dots (sunlight)
	if hv % 9 == 0:
		ci.draw_circle(Vector2(cx - 6, cy - 3), 0.8, Color(0.80, 0.92, 1.0, 0.40))
	if hv % 13 == 0:
		ci.draw_circle(Vector2(cx + 7, cy + 5), 0.6, Color(0.70, 0.85, 1.0, 0.35))

func _draw_snow(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	var base := Color(0.84, 0.92, 0.96) if hv % 4 != 0 else Color(0.76, 0.86, 0.94)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Snowdrift texture — subtle ridges
	if hv % 3 == 0:
		ci.draw_rect(Rect2(float(x) + 4, float(y) + 10, 24, 3), base.lightened(0.06))
		ci.draw_rect(Rect2(float(x) + 8, float(y) + 20, 18, 2), base.lightened(0.05))
	# Ice patch (slightly blue)
	if hv % 7 == 0:
		ci.draw_circle(Vector2(float(x) + 20.0, float(y) + 14.0), 5.0,
				Color(0.72, 0.86, 0.96, 0.45))
		ci.draw_circle(Vector2(float(x) + 18.0, float(y) + 12.0), 2.0,
				Color(0.85, 0.94, 1.0, 0.60))  # ice highlight
	# Wind-blown snow particles
	var h2 := _tile_hash2(x, y, 4)
	for i in range(3):
		var gi := (h2 + i * 1543) & 0xFFFF
		ci.draw_circle(Vector2(float(x + 2 + gi % 28), float(y + 2 + (gi >> 5) % 28)),
				0.7, Color(1.0, 1.0, 1.0, 0.70))
	# Ice crack
	if hv % 11 == 0:
		ci.draw_line(Vector2(float(x) + 6, float(y) + 24),
				  Vector2(float(x) + 18, float(y) + 28),
				  Color(0.62, 0.78, 0.92, 0.40), 1.0)
	# Sparkle crystal
	if hv % 9 == 0:
		ci.draw_circle(Vector2(cx, cy - 6.0), 1.2, Color(0.92, 0.97, 1.0, 0.80))
		ci.draw_line(Vector2(cx - 3, cy - 6), Vector2(cx + 3, cy - 6),
				Color(0.88, 0.95, 1.0, 0.55), 0.8)
		ci.draw_line(Vector2(cx, cy - 9), Vector2(cx, cy - 3),
				Color(0.88, 0.95, 1.0, 0.55), 0.8)

func _draw_mountain(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	var base := Color(0.52, 0.50, 0.48) if hv % 3 == 0 else Color(0.60, 0.58, 0.55)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var h2 := _tile_hash2(x, y, 2)
	for i in range(4):
		var gi := (h2 + i * 1499) & 0xFFFF
		ci.draw_rect(Rect2(x + 2 + gi % 24, y + 2 + (gi >> 5) % 24, 2 + i % 3, 1),
				base.darkened(0.20))
	if hv % 3 == 0:
		ci.draw_circle(Vector2(float(x) + 10.0, float(y) + 8.0), 5.5, Color(0.92, 0.94, 0.98, 0.72))
		ci.draw_circle(Vector2(float(x) + 8.5, float(y) + 6.5), 2.0, Color(1.0, 1.0, 1.0, 0.80))
		ci.draw_circle(Vector2(float(x) + 12.0, float(y) + 11.0), 1.5, Color(0.70, 0.75, 0.85, 0.55))
	if hv % 7 == 0:
		ci.draw_circle(Vector2(float(x) + 22.0, float(y) + 20.0), 4.0, Color(0.90, 0.92, 0.96, 0.55))
		ci.draw_circle(Vector2(float(x) + 20.5, float(y) + 18.5), 1.5, Color(1.0, 1.0, 1.0, 0.72))
	if hv % 9 == 0:
		ci.draw_line(Vector2(float(x) + 6, float(y) + 22),
				  Vector2(float(x) + 18, float(y) + 28),
				  Color(0.68, 0.78, 0.92, 0.45), 1.0)
	if hv % 4 == 0:
		ci.draw_circle(Vector2(float(x) + float((h2 >> 2) % 28) + 2, float(y) + 2),
				0.8, Color(0.95, 0.97, 1.0, 0.60))

func _draw_cliff(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	# Tall dark rock face — visually reads as an impassable cliff wall.
	var base := Color(0.30, 0.27, 0.25) if hv % 3 != 0 else Color(0.25, 0.22, 0.21)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Sunlit top ridge + deep base shadow give it height.
	ci.draw_rect(Rect2(x, y, TILE, 5), base.lightened(0.28))
	ci.draw_rect(Rect2(x, y + TILE - 7, TILE, 7), base.darkened(0.42))
	# Vertical fracture columns — facets of the rock face.
	var h2 := _tile_hash2(x, y, 6)
	for i in range(4):
		var gi := (h2 + i * 1361) & 0xFFFF
		var fx := float(x + 3 + gi % 26)
		ci.draw_line(Vector2(fx, float(y) + 4.0), Vector2(fx + 1.0, float(y) + float(TILE) - 4.0),
				base.darkened(0.30), 1.0)
	# Jagged peak silhouette near the top.
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(float(x) + 4, float(y) + 8),
		Vector2(cx,            float(y) + 1),
		Vector2(float(x) + TILE - 4, float(y) + 9)]),
		base.lightened(0.18))
	# Rubble at the foot.
	if hv % 2 == 0:
		ci.draw_circle(Vector2(cx - 6.0, cy + 9.0), 2.0, base.darkened(0.20))
		ci.draw_circle(Vector2(cx + 7.0, cy + 10.0), 1.6, base.darkened(0.26))

func _draw_rocky(ci: CanvasItem, hv: int, x: int, y: int, cx: float, _cy: float) -> void:
	var v    := hv % 4
	var cols := [Color(0.40, 0.39, 0.36), Color(0.44, 0.42, 0.38),
				 Color(0.36, 0.35, 0.32), Color(0.46, 0.44, 0.40)]
	ci.draw_rect(Rect2(x, y, TILE, TILE), cols[v])
	var h2 := _tile_hash2(x, y, 7)
	for i in range(6):
		var gi := (h2 + i * 1337) & 0xFFFF
		ci.draw_circle(Vector2(float(x + 2 + gi % 28), float(y + 2 + (gi >> 5) % 28)),
				0.8, cols[v].darkened(0.18 + 0.05 * (i % 3)))
	if hv % 5 == 0:
		ci.draw_circle(Vector2(float(x) + 8.0,  float(y) + 10.0), 4.5, cols[v].darkened(0.22))
		ci.draw_circle(Vector2(float(x) + 6.5,  float(y) + 8.5),  1.8, cols[v].lightened(0.28))
		ci.draw_circle(Vector2(float(x) + 22.0, float(y) + 20.0), 3.0, cols[v].darkened(0.22))
		ci.draw_circle(Vector2(float(x) + 21.0, float(y) + 18.5), 1.2, cols[v].lightened(0.24))
	if hv % 8 == 0:
		ci.draw_circle(Vector2(cx, float(y) + 6.0), 2.5, Color(0.55, 0.53, 0.50))
		ci.draw_circle(Vector2(cx - 1, float(y) + 5.0), 1.0, Color(0.68, 0.66, 0.64))
	if hv % 11 == 0:
		ci.draw_rect(Rect2(float(x) + 14, float(y) + 16, 3, 8), Color(0.62, 0.54, 0.38, 0.55))
		ci.draw_rect(Rect2(float(x) + 14, float(y) + 16, 3, 1), Color(0.85, 0.78, 0.52, 0.70))
	if hv % 6 == 0:
		ci.draw_line(Vector2(float(x) + 18, float(y) + 4),
				  Vector2(float(x) + 12, float(y) + 14),
				  cols[v].darkened(0.35), 1.0)

func _draw_dark_forest(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	var base := Color(0.08, 0.15, 0.09) if hv % 4 != 0 else Color(0.06, 0.11, 0.07)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	if hv % 11 == 0:
		ci.draw_circle(Vector2(cx, cy), 4.0, Color(0.50, 0.15, 0.65, 0.25))
		ci.draw_circle(Vector2(cx, cy), 2.0, Color(0.55, 0.20, 0.70, 0.20))
	if hv % 13 == 0:
		ci.draw_circle(Vector2(float(x) + 12.0, float(y) + 20.0), 5.5, Color(0.50, 0.15, 0.22, 0.75))
		ci.draw_rect(Rect2(float(x) + 11.0, float(y) + 20.0, 2.0, 6.0), Color(0.78, 0.76, 0.70, 0.70))
		ci.draw_circle(Vector2(float(x) + 12.5, float(y) + 19.5), 1.0, Color(0.88, 0.70, 0.10, 0.80))
	if hv % 7 == 0:
		ci.draw_line(Vector2(float(x) + 4, float(y) + 30),
				  Vector2(float(x) + 20, float(y) + 12),
				  Color(0.18, 0.14, 0.10, 0.55), 1.5)
		ci.draw_line(Vector2(float(x) + 14, float(y) + 18),
				  Vector2(float(x) + 22, float(y) + 14),
				  Color(0.18, 0.14, 0.10, 0.40), 1.0)
	if hv % 17 == 0:
		ci.draw_rect(Rect2(float(x) + 20, float(y) + 26, 6, 2), Color(0.72, 0.70, 0.60, 0.50))
	var h2 := _tile_hash2(x, y, 11)
	for i in range(3):
		var gi := (h2 + i * 1777) & 0xFFFF
		ci.draw_circle(Vector2(float(x + 2 + gi % 28), float(y + 2 + (gi >> 5) % 28)),
				0.8, Color(0.04, 0.07, 0.04))

func _draw_oak_forest(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	var base := Color(0.18, 0.42, 0.14) if hv % 5 != 0 else Color(0.13, 0.34, 0.10)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var h2 := _tile_hash2(x, y, 3)
	for i in range(4):
		var gi := (h2 + i * 911) & 0xFFFF
		ci.draw_circle(Vector2(float(x + 2 + gi % 28), float(y + 2 + (gi >> 5) % 28)),
				1.0, base.darkened(0.20 + 0.05 * (i % 3)))
	if hv % 5 == 0:
		ci.draw_circle(Vector2(float(x) + 8.0, float(y) + 8.0), 4.5, Color(0.26, 0.52, 0.18, 0.40))
		ci.draw_circle(Vector2(float(x) + 7.0, float(y) + 7.0), 2.0, Color(0.35, 0.62, 0.22, 0.50))
	if hv % 9 == 0:
		ci.draw_circle(Vector2(float(x) + 20.0, float(y) + 22.0), 2.5, Color(0.65, 0.40, 0.10, 0.60))
	if hv % 6 == 0:
		ci.draw_line(Vector2(float(x) + 14.0, float(y) + 24.0),
				  Vector2(float(x) + 12.0, float(y) + 16.0),
				  Color(0.14, 0.34, 0.10, 0.65), 1.5)
	if hv % 7 == 0:
		ci.draw_circle(Vector2(float(x) + 22.0, float(y) + 10.0), 3.5, Color(0.55, 0.80, 0.30, 0.18))

func _draw_pine_forest(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	var base := Color(0.11, 0.28, 0.13) if hv % 4 != 0 else Color(0.08, 0.22, 0.10)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var h2 := _tile_hash2(x, y, 5)
	for i in range(5):
		var gi := (h2 + i * 733) & 0xFFFF
		var nx := float(x + 2 + gi % 28)
		var ny := float(y + 2 + (gi >> 5) % 28)
		ci.draw_line(Vector2(nx, ny), Vector2(nx + 2.0 - float(i % 2) * 4.0, ny - 2.0),
				Color(0.06, 0.18, 0.08, 0.55), 1.0)
	if hv % 4 == 0:
		ci.draw_line(Vector2(float(x) + 6.0, float(y) + 22.0),
				  Vector2(float(x) + 8.0, float(y) + 14.0),
				  Color(0.06, 0.18, 0.08, 0.60), 1.5)
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(float(x) + 8, float(y) + 20),
			Vector2(float(x) + 24, float(y) + 20),
			Vector2(float(x) + 16, float(y) + 10)]),
			Color(0.08, 0.22, 0.10, 0.60))
	if hv % 8 == 0:
		ci.draw_rect(Rect2(float(x) + 10, float(y) + 4, 12, 3), Color(0.88, 0.92, 0.96, 0.22))

func _draw_swamp(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	var base := Color(0.20, 0.27, 0.14) if hv % 3 != 0 else Color(0.16, 0.22, 0.11)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	if hv % 6 == 0:
		ci.draw_circle(Vector2(float(x) + 14.0, float(y) + 16.0), 6.5, Color(0.28, 0.20, 0.08, 0.45))
		ci.draw_circle(Vector2(float(x) + 14.0, float(y) + 16.0), 3.0, Color(0.24, 0.30, 0.10, 0.35))
		ci.draw_arc(Vector2(float(x) + 13, float(y) + 15), 3.0, 0.0, PI, 6, Color(0.35, 0.42, 0.18, 0.30), 1.0)
	if hv % 8 == 0:
		ci.draw_line(Vector2(float(x) + 24.0, float(y) + 6.0),
				  Vector2(float(x) + 23.0, float(y) + 28.0),
				  Color(0.38, 0.48, 0.16, 0.75), 2.0)
		ci.draw_circle(Vector2(float(x) + 23.0, float(y) + 6.0), 2.5, Color(0.55, 0.28, 0.08, 0.60))
	if hv % 9 == 0:
		ci.draw_circle(Vector2(cx - 6.0, cy - 4.0), 1.2, Color(0.42, 0.50, 0.20, 0.45))
		ci.draw_circle(Vector2(cx + 4.0, cy + 2.0), 0.8, Color(0.42, 0.50, 0.20, 0.40))

func _draw_helheim(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	var base := Color(0.42, 0.06, 0.54) if hv % 3 != 0 else Color(0.35, 0.04, 0.45)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Ethereal mist patches
	if hv % 5 == 0:
		ci.draw_circle(Vector2(cx, cy), 6.5, Color(0.60, 0.15, 0.75, 0.22))
		ci.draw_circle(Vector2(cx, cy), 3.0, Color(0.70, 0.25, 0.85, 0.16))
	# Glowing ground veins
	if hv % 7 == 0:
		ci.draw_line(Vector2(float(x) + 4, float(y) + 20),
				  Vector2(float(x) + 18, float(y) + 10),
				  Color(0.75, 0.20, 0.90, 0.35), 1.0)
		ci.draw_line(Vector2(float(x) + 18, float(y) + 10),
				  Vector2(float(x) + 26, float(y) + 18),
				  Color(0.75, 0.20, 0.90, 0.25), 1.0)
	# Skull/bone fragment
	if hv % 17 == 0:
		ci.draw_circle(Vector2(float(x) + 14.0, float(y) + 22.0), 3.5, Color(0.72, 0.68, 0.60, 0.55))
		ci.draw_circle(Vector2(float(x) + 12.5, float(y) + 21.5), 1.2, Color(0.88, 0.85, 0.78, 0.60))
	# Eerie ember glow
	if hv % 11 == 0:
		ci.draw_circle(Vector2(float(x) + 8.0, float(y) + 14.0), 1.5, Color(0.90, 0.55, 0.10, 0.50))
		ci.draw_circle(Vector2(float(x) + 22.0, float(y) + 26.0), 1.0, Color(0.85, 0.45, 0.08, 0.45))
	# Dark scatter
	var h2 := _tile_hash2(x, y, 13)
	for i in range(3):
		var gi := (h2 + i * 2311) & 0xFFFF
		ci.draw_circle(Vector2(float(x + 2 + gi % 28), float(y + 2 + (gi >> 5) % 28)),
				0.7, Color(0.20, 0.02, 0.28))

func _draw_ashlands(ci: CanvasItem, hv: int, x: int, y: int, cx: float, cy: float) -> void:
	var base := Color(0.55, 0.28, 0.08) if hv % 4 != 0 else Color(0.48, 0.24, 0.06)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Cracked earth pattern
	if hv % 4 == 0:
		ci.draw_line(Vector2(float(x) + 8, float(y) + 4),
				  Vector2(float(x) + 4, float(y) + 16),
				  base.darkened(0.35), 1.0)
		ci.draw_line(Vector2(float(x) + 4, float(y) + 16),
				  Vector2(float(x) + 14, float(y) + 26),
				  base.darkened(0.35), 1.0)
	if hv % 5 == 0:
		ci.draw_line(Vector2(float(x) + 22, float(y) + 6),
				  Vector2(float(x) + 26, float(y) + 18),
				  base.darkened(0.30), 1.0)
		ci.draw_line(Vector2(float(x) + 26, float(y) + 18),
				  Vector2(float(x) + 20, float(y) + 28),
				  base.darkened(0.30), 1.0)
	# Ash patches (gray spots)
	if hv % 6 == 0:
		ci.draw_circle(Vector2(float(x) + 18.0, float(y) + 12.0), 4.0,
				Color(0.62, 0.58, 0.52, 0.45))
		ci.draw_circle(Vector2(float(x) + 16.5, float(y) + 10.5), 1.5,
				Color(0.72, 0.68, 0.62, 0.55))
	# Ember glow spots
	if hv % 9 == 0:
		ci.draw_circle(Vector2(cx - 5.0, cy + 6.0), 1.5, Color(1.0, 0.55, 0.08, 0.55))
		ci.draw_circle(Vector2(cx - 5.0, cy + 6.0), 0.6, Color(1.0, 0.80, 0.20, 0.70))
	if hv % 13 == 0:
		ci.draw_circle(Vector2(float(x) + 24.0, float(y) + 22.0), 1.2,
				Color(0.98, 0.45, 0.05, 0.50))
	# Scattered pebbles
	var h2 := _tile_hash2(x, y, 9)
	for i in range(4):
		var gi := (h2 + i * 1019) & 0xFFFF
		ci.draw_circle(Vector2(float(x + 2 + gi % 28), float(y + 2 + (gi >> 5) % 28)),
				0.7, base.darkened(0.20))

func _draw_plains(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	var base := Color(0.30, 0.52, 0.20) if hv % 5 != 0 else Color(0.24, 0.44, 0.16)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var gc := Color(0.20, 0.40, 0.12, 0.65)
	if hv % 5 == 0:
		ci.draw_line(Vector2(float(x) + 8.0,  float(y) + 22.0),
				  Vector2(float(x) + 6.0,  float(y) + 13.0), gc, 1.5)
		ci.draw_line(Vector2(float(x) + 11.0, float(y) + 22.0),
				  Vector2(float(x) + 13.0, float(y) + 14.0), gc, 1.5)
	if hv % 3 == 0:
		ci.draw_line(Vector2(float(x) + 20.0, float(y) + 28.0),
				  Vector2(float(x) + 18.0, float(y) + 19.0), gc.darkened(0.1), 1.5)
		ci.draw_line(Vector2(float(x) + 25.0, float(y) + 26.0),
				  Vector2(float(x) + 27.0, float(y) + 17.0), gc, 1.5)
	if hv % 7 == 0:
		ci.draw_line(Vector2(float(x) + 4.0, float(y) + 16.0),
				  Vector2(float(x) + 5.0, float(y) + 8.0), gc.lightened(0.08), 1.5)
		ci.draw_line(Vector2(float(x) + 28.0, float(y) + 20.0),
				  Vector2(float(x) + 26.0, float(y) + 12.0), gc, 1.5)
	if hv % 8 == 0:
		ci.draw_circle(Vector2(float(x) + 22.0, float(y) + 18.0), 2.5,
				Color(0.55, 0.52, 0.48, 0.75))
		ci.draw_circle(Vector2(float(x) + 21.0, float(y) + 17.0), 1.0,
				Color(0.72, 0.70, 0.66, 0.80))
	if hv % 11 == 0:
		ci.draw_circle(Vector2(float(x) + 22.0, float(y) + 14.0), 2.0,
				Color(1.0, 0.85, 0.20, 0.80))
		ci.draw_circle(Vector2(float(x) + 22.0, float(y) + 14.0), 0.8,
				Color(0.95, 0.55, 0.05, 0.80))
	if hv % 13 == 0:
		ci.draw_circle(Vector2(float(x) + 16.0, float(y) + 24.0), 2.0,
				Color(0.85, 0.20, 0.80, 0.70))
		ci.draw_circle(Vector2(float(x) + 16.0, float(y) + 24.0), 0.8,
				Color(0.65, 0.08, 0.60, 0.80))

# ── Atlas bake helper ─────────────────────────────────────────────────────────
# Inner Node2D used once at startup as the SubViewport bake target. Its _draw()
# walks every biome id and calls back into Ground's biome dispatcher, drawing
# one cell per row. Held as an inner class to keep the bake plumbing local to
# Ground.gd; nothing outside this file references it.
class _AtlasBaker extends Node2D:
	var ground: Node = null
	func _draw() -> void:
		if ground == null:
			return
		for bid in range(16):
			ground.call("_draw_biome_cell", self, bid, 0, bid * 32)
