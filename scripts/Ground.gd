extends Node2D

## Fires every time a single tile is mutated through apply_tile_change(). A
## future multiplayer/persistence layer connects to this signal to broadcast
## the change to other clients and/or write it through to the server. Nothing
## else inside Ground emits per-tile changes — apply_tile_change() is the only
## entry point that touches the cache, the lookup texture, and this signal.
@warning_ignore("unused_signal")
signal tile_changed(tx: int, ty: int, biome_id: int)

## Fired once when the SubViewport atlas bake completes (`_atlas_ready` flips
## true). Consumers that need the real 32×32 baked texture per biome
## (e.g. the admin swatch grid) listen for this to swap their placeholder
## color chips for real thumbnails. Never emitted again — a one-shot.
@warning_ignore("unused_signal")
signal atlas_ready

const TILE := 32
const COLS := 300
# ROWS covers BOTH the exterior playable area (rows 0..EXTERIOR_ROWS-1) and
# the reserved interior rows (rows EXTERIOR_ROWS..ROWS-1) that sit far below
# the exterior world at y=12000+. Interior rooms live inside this reserved
# band so the existing tile editor / paint / passability code Just Works
# — admins can paint interior floors with the same brushes they use on the
# overworld. The camera is clamped to EXTERIOR_ROWS during exterior play so
# players can't wander into the interior band; interior mode un-clamps it.
const EXTERIOR_ROWS := 300
const ROWS := 520
# First interior tile row. Everything at ty >= INTERIOR_ROWS_START is treated
# as interior-scope: default biome, no impassable border rules, admin can paint.
const INTERIOR_ROWS_START := 300

# Biome cache — built once in _ready, looked up O(1) during draw
var _biome_cache: PackedByteArray  # biome IDs 0-13

# Per-tile biome lookup as a 300x300 R8 texture. The shader path will sample this
# (each pixel's R channel = biome_id) so terrain can be rendered from an atlas
# with neighbor-aware blending without re-walking the cache per fragment.
var _biome_lookup_img: Image       = null
var _biome_lookup_tex: ImageTexture = null
# Tile editor v2 — per-tile color tint (R=hue shift, G=brightness) packed
# 0..255 where 128 is neutral. Sampled by terrain_blend.gdshader to apply
# ±20% hue + brightness multipliers per tile. Defaults to neutral grey
# (128, 128) until an admin paints.
var _tint_lookup_img: Image       = null
var _tint_lookup_tex: ImageTexture = null
# Per-tile in-memory caches the editor reads back when assembling brush
# stamps + drawing the passability overlay. Both default to "no override"
# until the server pushes paint events.
var _tile_tints:        Dictionary = {}    # idx → {"h": int, "v": int}
var _impassable_tiles:  Dictionary = {}    # idx → true   (only stored when blocked)

# Biome atlas — one 32×32 cell per biome id (0..15), stacked vertically into a
# 32×(16*32) texture. Each cell is a single representative bake of that biome's
# _draw_<name> output (deterministic hv per cell, so no per-tile variation —
# variation will come back later via the shader's noise sample). Built once at
# startup via SubViewport, then handed to the terrain_blend shader as a uniform.
var _biome_atlas_img: Image       = null
var _biome_atlas_tex: ImageTexture = null
const BIOME_COUNT := 50

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
# Interior + exterior additions. Interior floors are walkable, walls are
# impassable via _is_impassable_bid. Exterior additions cover long-missing
# beach/path/river/farm biomes.
const B_WOOD_FLOOR    := 16
const B_STONE_FLOOR   := 17
const B_RED_CARPET    := 18
const B_HEARTH_STONE  := 19
const B_WALL_WOOD     := 20  # impassable
const B_WALL_STONE    := 21  # impassable
const B_SAND          := 22
const B_DIRT_PATH     := 23
const B_SHALLOW_WATER := 24  # walkable water (unlike ocean/coast)
const B_FARM_CROPS    := 25
# Grass-family exterior additions — IDs 26..36 kept CONTIGUOUS so the shader's
# is_grass predicate can use a range test (b >= 26 && b <= 36) alongside the
# original 0..5 block. Hills variants + transition tiles + meadow/tundra/
# clearing all belong here.
const B_PLAINS_HILLS  := 26
const B_OAK_HILLS     := 27
const B_PINE_HILLS    := 28
const B_SNOW_HILLS    := 29
const B_FOREST_EDGE   := 30
const B_SWAMP_EDGE    := 31
const B_SHORE_GRASS   := 32
const B_SNOW_LINE     := 33
const B_MEADOW        := 34
const B_TUNDRA        := 35
const B_CLEARING      := 36
# Non-grass-family additions — IDs 37..47. Rocky / desert / hellish hills,
# variety terrains, and beach/water extras. `reef` and `tidepool` participate
# in the shader's is_water predicate; the rest stay outside category groups.
const B_ASHLANDS_HILLS  := 37
const B_HELHEIM_HILLS   := 38
const B_ROCKY_HILLS     := 39
const B_SAND_HILLS      := 40
const B_CLIFF_SCREE     := 41
const B_MOSS_ROCK       := 42
const B_VOLCANIC_GLASS  := 43
const B_REEF            := 44  # walkable shallow water variant
const B_TIDEPOOL        := 45  # walkable shallow water variant
const B_WET_SAND        := 46
const B_DRIFTWOOD_SHORE := 47
# Bridges — walkable tiles that sit ON water. Painted over water tiles for
# river crossings. Not in is_water/is_grass so the shader treats them as
# ordinary land — the water ripples showing at the tile's north/south
# edges are drawn in the _draw_*_bridge functions themselves.
const B_WOOD_BRIDGE   := 48
const B_STONE_BRIDGE  := 49

const _BIOME_NAMES := [
	"plains", "plains", "oak_forest", "pine_forest", "dark_forest",
	"swamp", "mountain", "rocky", "coast", "ocean",
	"snow", "helheim", "ashlands", "town", "road", "cliff",
	"wood_floor", "stone_floor", "red_carpet", "hearth_stone",
	"wall_wood", "wall_stone",
	"sand", "dirt_path", "shallow_water", "farm_crops",
	# Grass-family block (26..36) — contiguous so is_grass stays a cheap range test.
	"plains_hills", "oak_hills", "pine_hills", "snow_hills",
	"forest_edge", "swamp_edge", "shore_grass", "snow_line",
	"meadow", "tundra", "clearing",
	# Non-grass block (37..47).
	"ashlands_hills", "helheim_hills", "rocky_hills", "sand_hills",
	"cliff_scree", "moss_rock", "volcanic_glass",
	"reef", "tidepool", "wet_sand", "driftwood_shore",
	# Bridges (48..49) — walkable-over-water.
	"wood_bridge", "stone_bridge",
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
	# Water + walls + cliffs block. All hill biomes (both grass-family and
	# non-grass block) also block — hills read as elevated terrain that the
	# player has to path around, matching how cliffs work. Server terrain
	# bitmap must be re-baked (admin panel → Bake Terrain Bitmap) for
	# monster AI to also route around hills; without a re-bake, the client
	# blocks but the server keeps chasing straight through.
	return (bid == B_OCEAN or bid == B_COAST or bid == B_CLIFF
		or bid == B_WALL_WOOD or bid == B_WALL_STONE
		or bid == B_PLAINS_HILLS or bid == B_OAK_HILLS
		or bid == B_PINE_HILLS or bid == B_SNOW_HILLS
		or bid == B_ASHLANDS_HILLS or bid == B_HELHEIM_HILLS
		or bid == B_ROCKY_HILLS or bid == B_SAND_HILLS)

## Public wrapper on _is_impassable_bid + biome_name_to_id. Single source
## of truth for what blocks movement across client collision + server-side
## terrain bake. TerrainBaker.bake() calls this so the passability bitmap
## uploaded to the server matches Ground's live collision exactly.
func is_biome_impassable(biome_name: String) -> bool:
	return _is_impassable_bid(biome_name_to_id(biome_name))

## Cache of 32×32 ImageTextures keyed by biome name. Populated lazily by
## get_biome_thumbnail so the crop + wrap cost only pays on first call
## per biome. Cleared automatically if _biome_atlas_img is rebaked.
var _biome_thumb_cache: Dictionary = {}

## Returns a 32×32 Texture2D of the biome's baked atlas cell, or null if
## the atlas hasn't finished baking yet. Used by the admin panel's tile
## swatch grid to show the actual tile art rather than a flat color chip.
##
## Layout matches _bake_biome_atlas: cells are stacked vertically, one
## 32×32 cell per biome id from top (id 0) down. Crop = Rect2i(0, bid*32,
## 32, 32) from the cached _biome_atlas_img.
func get_biome_thumbnail(biome_name: String) -> Texture2D:
	if not _atlas_ready or _biome_atlas_img == null:
		return null
	if _biome_thumb_cache.has(biome_name):
		return _biome_thumb_cache[biome_name]
	var bid := biome_name_to_id(biome_name)
	if bid < 0 or bid >= BIOME_COUNT:
		return null
	var region := Rect2i(0, bid * TILE, TILE, TILE)
	var cell_img := _biome_atlas_img.get_region(region)
	if cell_img == null or cell_img.is_empty():
		return null
	var tex := ImageTexture.create_from_image(cell_img)
	_biome_thumb_cache[biome_name] = tex
	return tex

## Rebuild the single combined collision body from the effective (override-aware)
## biome map. Called once at startup and again whenever a tile is painted —
## handles both adding and removing impassable tiles cleanly.
##
## A tile is considered impassable when EITHER the biome id blocks (water,
## cliffs, walls, hills — see _is_impassable_bid) OR the admin has explicitly
## flipped its passability via the Pass tile button (stored in
## _impassable_tiles). Previously this only looked at the biome — the Pass
## button wrote to the dict but no collision was ever rebuilt from it, so
## clicking Pass had no effect on player movement.
func _rebuild_impassable_collision() -> void:
	if _collision_body != null and is_instance_valid(_collision_body):
		_collision_body.queue_free()
	var body := StaticBody2D.new()
	body.collision_layer = 2   # blocks on-foot movement (water + cliffs + walls + hills + Pass overrides)
	body.collision_mask  = 0
	add_child(body)
	_collision_body = body
	for ty in range(ROWS):
		var run_start := -1
		for tx in range(COLS + 1):
			var imp := false
			if tx < COLS:
				var idx := ty * COLS + tx
				imp = (_is_impassable_bid(_bid_at(tx, ty))
					or _impassable_tiles.has(idx))
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
	# Tint lookup — RG8, neutral grey (128, 128, 0) until painted. The
	# shader maps R=128 to "no hue shift" and G=128 to "no brightness
	# shift", with ±127 → ±20% in both axes.
	_tint_lookup_img = Image.create(COLS, ROWS, false, Image.FORMAT_RG8)
	_tint_lookup_img.fill(Color8(128, 128, 0, 255))
	_tint_lookup_tex = ImageTexture.create_from_image(_tint_lookup_img)

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
	mat.set_shader_parameter("tint_lookup",      _tint_lookup_tex)
	mat.set_shader_parameter("world_size_tiles", Vector2(float(COLS), float(ROWS)))
	mat.set_shader_parameter("tile_px",          float(TILE))
	mat.set_shader_parameter("atlas_rows",       float(BIOME_COUNT))
	self.material = mat
	_atlas_ready = true
	set_process(false)
	queue_redraw()
	atlas_ready.emit()

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
		"wood_floor":    _draw_wood_floor(ci, hv, x, y, cx, cy)
		"stone_floor":   _draw_stone_floor(ci, hv, x, y, cx, cy)
		"red_carpet":    _draw_red_carpet(ci, hv, x, y, cx, cy)
		"hearth_stone":  _draw_hearth_stone(ci, hv, x, y, cx, cy)
		"wall_wood":     _draw_wall_wood(ci, hv, x, y, cx, cy)
		"wall_stone":    _draw_wall_stone(ci, hv, x, y, cx, cy)
		"sand":          _draw_sand(ci, hv, x, y, cx, cy)
		"dirt_path":     _draw_dirt_path(ci, hv, x, y, cx, cy)
		"shallow_water": _draw_shallow_water(ci, hv, x, y, cx, cy)
		"farm_crops":    _draw_farm_crops(ci, hv, x, y, cx, cy)
		"plains_hills":    _draw_plains_hills(ci, hv, x, y, cx, cy)
		"oak_hills":       _draw_oak_hills(ci, hv, x, y, cx, cy)
		"pine_hills":      _draw_pine_hills(ci, hv, x, y, cx, cy)
		"snow_hills":      _draw_snow_hills(ci, hv, x, y, cx, cy)
		"forest_edge":     _draw_forest_edge(ci, hv, x, y, cx, cy)
		"swamp_edge":      _draw_swamp_edge(ci, hv, x, y, cx, cy)
		"shore_grass":     _draw_shore_grass(ci, hv, x, y, cx, cy)
		"snow_line":       _draw_snow_line(ci, hv, x, y, cx, cy)
		"meadow":          _draw_meadow(ci, hv, x, y, cx, cy)
		"tundra":          _draw_tundra(ci, hv, x, y, cx, cy)
		"clearing":        _draw_clearing(ci, hv, x, y, cx, cy)
		"ashlands_hills":  _draw_ashlands_hills(ci, hv, x, y, cx, cy)
		"helheim_hills":   _draw_helheim_hills(ci, hv, x, y, cx, cy)
		"rocky_hills":     _draw_rocky_hills(ci, hv, x, y, cx, cy)
		"sand_hills":      _draw_sand_hills(ci, hv, x, y, cx, cy)
		"cliff_scree":     _draw_cliff_scree(ci, hv, x, y, cx, cy)
		"moss_rock":       _draw_moss_rock(ci, hv, x, y, cx, cy)
		"volcanic_glass":  _draw_volcanic_glass(ci, hv, x, y, cx, cy)
		"reef":            _draw_reef(ci, hv, x, y, cx, cy)
		"tidepool":        _draw_tidepool(ci, hv, x, y, cx, cy)
		"wet_sand":        _draw_wet_sand(ci, hv, x, y, cx, cy)
		"driftwood_shore": _draw_driftwood_shore(ci, hv, x, y, cx, cy)
		"wood_bridge":     _draw_wood_bridge(ci, hv, x, y, cx, cy)
		"stone_bridge":    _draw_stone_bridge(ci, hv, x, y, cx, cy)
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
	_tile_tints.clear()
	_impassable_tiles.clear()
	# Reset both lookup textures to the procedural baseline + neutral tint.
	if _biome_lookup_img != null:
		for ty in range(ROWS):
			for tx in range(COLS):
				var bid: int = _biome_cache[ty * COLS + tx]
				_biome_lookup_img.set_pixel(tx, ty, Color8(bid, 0, 0, 255))
	if _tint_lookup_img != null:
		_tint_lookup_img.fill(Color8(128, 128, 0, 255))
	for o: Variant in overrides:
		if o is Dictionary:
			var d: Dictionary = o
			var tx := int(d.get("tx", -1))
			var ty := int(d.get("ty", -1))
			if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
				continue
			var idx: int = ty * COLS + tx
			var biome_name: String = str(d.get("biome", ""))
			if biome_name != "":
				var nb_id := biome_name_to_id(biome_name)
				_overrides[idx] = nb_id
				if _biome_lookup_img != null:
					_biome_lookup_img.set_pixel(tx, ty, Color8(nb_id, 0, 0, 255))
			var h := int(d.get("tint_h", 0))
			var v := int(d.get("tint_v", 0))
			if h != 0 or v != 0:
				_tile_tints[idx] = {"h": h, "v": v}
				if _tint_lookup_img != null:
					_tint_lookup_img.set_pixel(tx, ty, _tint_to_color(h, v))
			if not bool(d.get("passable", true)):
				_impassable_tiles[idx] = true
	if _biome_lookup_tex != null and _biome_lookup_img != null:
		_biome_lookup_tex.update(_biome_lookup_img)
	if _tint_lookup_tex != null and _tint_lookup_img != null:
		_tint_lookup_tex.update(_tint_lookup_img)
	_rebuild_impassable_collision()
	queue_redraw()
	# Auto-refresh the minimap so it reflects the server's saved overrides
	# right after the login burst, without the admin needing to click Save Map.
	Events.minimap_refresh.emit()
	# Sentinel emit so HillOverlay (and any future listeners) know a bulk
	# ingest just happened. The bulk sentinel skips per-tile echoes, so this
	# is a single wake-up, not per-override chatter.
	tile_changed.emit(-1, -1, -1)


## Pack the editor's int-100..100 hue/brightness shift into the RG8 lookup
## color. 128 is neutral; ±100 map to roughly ±100 byte offsets so the
## shader sees the full ±0.78 normalized range and applies ±20% effect.
func _tint_to_color(h: int, v: int) -> Color:
	var hh: int = clampi(128 + h, 0, 255)
	var vv: int = clampi(128 + v, 0, 255)
	return Color8(hh, vv, 0, 255)


## Apply a bulk batch from the tile_set_bulk broadcast. Each entry is
## {tx, ty, biome} where biome can be empty/null to clear the override.
func apply_tile_overrides_bulk(entries: Array) -> void:
	if _biome_lookup_img == null or _biome_lookup_tex == null:
		return
	var touched_collision := false
	for o: Variant in entries:
		if not (o is Dictionary):
			continue
		var d: Dictionary = o
		var tx := int(d.get("tx", -1))
		var ty := int(d.get("ty", -1))
		if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
			continue
		var idx := ty * COLS + tx
		var was_imp := _is_impassable_bid(_bid_at(tx, ty))
		var b_val: Variant = d.get("biome", null)
		if b_val == null or str(b_val) == "":
			_overrides.erase(idx)
			_biome_lookup_img.set_pixel(tx, ty,
				Color8(_biome_cache[idx], 0, 0, 255))
		else:
			var nb_id := biome_name_to_id(str(b_val))
			if nb_id == _biome_cache[idx]:
				_overrides.erase(idx)
			else:
				_overrides[idx] = nb_id
			_biome_lookup_img.set_pixel(tx, ty, Color8(nb_id, 0, 0, 255))
		if was_imp != _is_impassable_bid(_bid_at(tx, ty)):
			touched_collision = true
	_biome_lookup_tex.update(_biome_lookup_img)
	if touched_collision:
		_rebuild_impassable_collision()
	queue_redraw()
	tile_changed.emit(-1, -1, -1)


## Apply bulk tint paint. Entries: {tx, ty, h, v} with h/v in -100..100.
## Both 0 clears the tint.
func apply_tile_tints_bulk(entries: Array) -> void:
	if _tint_lookup_img == null or _tint_lookup_tex == null:
		return
	for o: Variant in entries:
		if not (o is Dictionary):
			continue
		var d: Dictionary = o
		var tx := int(d.get("tx", -1))
		var ty := int(d.get("ty", -1))
		if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
			continue
		var idx := ty * COLS + tx
		var h := int(d.get("h", 0))
		var v := int(d.get("v", 0))
		if h == 0 and v == 0:
			_tile_tints.erase(idx)
			_tint_lookup_img.set_pixel(tx, ty, Color8(128, 128, 0, 255))
		else:
			_tile_tints[idx] = {"h": h, "v": v}
			_tint_lookup_img.set_pixel(tx, ty, _tint_to_color(h, v))
	_tint_lookup_tex.update(_tint_lookup_img)
	queue_redraw()


## Apply bulk passability paint. Entries: {tx, ty, passable: bool}.
## Updates the in-memory dict + nudges the impassable collision rebuild.
func apply_tile_passability_bulk(entries: Array) -> void:
	var touched := false
	for o: Variant in entries:
		if not (o is Dictionary):
			continue
		var d: Dictionary = o
		var tx := int(d.get("tx", -1))
		var ty := int(d.get("ty", -1))
		if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
			continue
		var idx := ty * COLS + tx
		var passable := bool(d.get("passable", true))
		if passable:
			if _impassable_tiles.erase(idx):
				touched = true
		else:
			if not _impassable_tiles.has(idx):
				_impassable_tiles[idx] = true
				touched = true
	if touched:
		_rebuild_impassable_collision()
	# Always emit so the world overlay redraws if the editor is open.
	tile_changed.emit(-1, -1, -1)


## Exposed for the passability overlay so it can draw a red square per
## blocked tile during edit mode.
func is_tile_impassable(tx: int, ty: int) -> bool:
	if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
		return false
	return _impassable_tiles.has(ty * COLS + tx)


func impassable_tile_indices() -> Array:
	return _impassable_tiles.keys()

func _biome_at(tx: int, ty: int) -> String:
	if tx < 0 or tx >= COLS or ty < 0 or ty >= ROWS:
		return "plains"
	return _BIOME_NAMES[_bid_at(tx, ty)]

func _compute_biome_id(tx: int, ty: int) -> int:
	# Interior band — default to bare wood floor so first-entry rooms are
	# walkable AND read as "interior" out of the box. Admins can repaint
	# to stone/carpet/hearth per room theme. All noise-based biome rules
	# below are exterior-only.
	if ty >= INTERIOR_ROWS_START:
		return B_WOOD_FLOOR
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
		"wood_floor":    return Color(0.42, 0.30, 0.16)
		"stone_floor":   return Color(0.55, 0.55, 0.55)
		"red_carpet":    return Color(0.55, 0.15, 0.15)
		"hearth_stone":  return Color(0.20, 0.16, 0.14)
		"wall_wood":     return Color(0.32, 0.22, 0.10)
		"wall_stone":    return Color(0.50, 0.48, 0.44)
		"sand":          return Color(0.86, 0.78, 0.58)
		"dirt_path":     return Color(0.42, 0.32, 0.20)
		"shallow_water": return Color(0.45, 0.65, 0.85)
		"farm_crops":    return Color(0.35, 0.22, 0.10)
		"plains_hills":    return Color(0.34, 0.58, 0.24)
		"oak_hills":       return Color(0.22, 0.48, 0.16)
		"pine_hills":      return Color(0.14, 0.34, 0.16)
		"snow_hills":      return Color(0.86, 0.94, 0.98)
		"forest_edge":     return Color(0.28, 0.52, 0.22)
		"swamp_edge":      return Color(0.26, 0.36, 0.20)
		"shore_grass":     return Color(0.60, 0.66, 0.42)
		"snow_line":       return Color(0.62, 0.75, 0.62)
		"meadow":          return Color(0.44, 0.68, 0.30)
		"tundra":          return Color(0.50, 0.55, 0.46)
		"clearing":        return Color(0.36, 0.58, 0.24)
		"ashlands_hills":  return Color(0.42, 0.20, 0.08)
		"helheim_hills":   return Color(0.32, 0.08, 0.42)
		"rocky_hills":     return Color(0.44, 0.42, 0.38)
		"sand_hills":      return Color(0.82, 0.72, 0.50)
		"cliff_scree":     return Color(0.38, 0.34, 0.30)
		"moss_rock":       return Color(0.34, 0.42, 0.28)
		"volcanic_glass":  return Color(0.12, 0.10, 0.14)
		"reef":            return Color(0.48, 0.72, 0.78)
		"tidepool":        return Color(0.40, 0.60, 0.72)
		"wet_sand":        return Color(0.62, 0.54, 0.38)
		"driftwood_shore": return Color(0.78, 0.70, 0.52)
		"wood_bridge":     return Color(0.55, 0.38, 0.20)
		"stone_bridge":    return Color(0.62, 0.60, 0.56)
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
		"wood_floor":    _draw_wood_floor(self, hv, x, y, cx, cy)
		"stone_floor":   _draw_stone_floor(self, hv, x, y, cx, cy)
		"red_carpet":    _draw_red_carpet(self, hv, x, y, cx, cy)
		"hearth_stone":  _draw_hearth_stone(self, hv, x, y, cx, cy)
		"wall_wood":     _draw_wall_wood(self, hv, x, y, cx, cy)
		"wall_stone":    _draw_wall_stone(self, hv, x, y, cx, cy)
		"sand":          _draw_sand(self, hv, x, y, cx, cy)
		"dirt_path":     _draw_dirt_path(self, hv, x, y, cx, cy)
		"shallow_water": _draw_shallow_water(self, hv, x, y, cx, cy)
		"farm_crops":    _draw_farm_crops(self, hv, x, y, cx, cy)
		"plains_hills":    _draw_plains_hills(self, hv, x, y, cx, cy)
		"oak_hills":       _draw_oak_hills(self, hv, x, y, cx, cy)
		"pine_hills":      _draw_pine_hills(self, hv, x, y, cx, cy)
		"snow_hills":      _draw_snow_hills(self, hv, x, y, cx, cy)
		"forest_edge":     _draw_forest_edge(self, hv, x, y, cx, cy)
		"swamp_edge":      _draw_swamp_edge(self, hv, x, y, cx, cy)
		"shore_grass":     _draw_shore_grass(self, hv, x, y, cx, cy)
		"snow_line":       _draw_snow_line(self, hv, x, y, cx, cy)
		"meadow":          _draw_meadow(self, hv, x, y, cx, cy)
		"tundra":          _draw_tundra(self, hv, x, y, cx, cy)
		"clearing":        _draw_clearing(self, hv, x, y, cx, cy)
		"ashlands_hills":  _draw_ashlands_hills(self, hv, x, y, cx, cy)
		"helheim_hills":   _draw_helheim_hills(self, hv, x, y, cx, cy)
		"rocky_hills":     _draw_rocky_hills(self, hv, x, y, cx, cy)
		"sand_hills":      _draw_sand_hills(self, hv, x, y, cx, cy)
		"cliff_scree":     _draw_cliff_scree(self, hv, x, y, cx, cy)
		"moss_rock":       _draw_moss_rock(self, hv, x, y, cx, cy)
		"volcanic_glass":  _draw_volcanic_glass(self, hv, x, y, cx, cy)
		"reef":            _draw_reef(self, hv, x, y, cx, cy)
		"tidepool":        _draw_tidepool(self, hv, x, y, cx, cy)
		"wet_sand":        _draw_wet_sand(self, hv, x, y, cx, cy)
		"driftwood_shore": _draw_driftwood_shore(self, hv, x, y, cx, cy)
		"wood_bridge":     _draw_wood_bridge(self, hv, x, y, cx, cy)
		"stone_bridge":    _draw_stone_bridge(self, hv, x, y, cx, cy)
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

# ══════════════════════════════════════════════════════════════════════════════
# ── Interior + additional exterior tile biomes ────────────────────────────────
# Signature matches the other _draw_<name> funcs: (ci, hv, x, y, cx, cy). hv is
# a per-tile deterministic hash used to seed variation without RNG allocations.

func _draw_wood_floor(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Warm plank floor. Two-tone base for row variation, horizontal plank
	# separator every ~10 px, offset vertical breaks per row.
	var base := Color(0.42, 0.30, 0.16) if hv % 3 != 0 else Color(0.38, 0.27, 0.14)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var dark := base.darkened(0.28)
	# Horizontal plank lines (3 rows of ~10 px).
	for row in range(3):
		var sy := y + 10 + row * 10
		ci.draw_line(Vector2(float(x), float(sy)),
				Vector2(float(x + TILE), float(sy)), dark, 1.0)
	# Vertical plank breaks — one per row, at deterministic x offsets.
	for row in range(3):
		var bx := x + 6 + ((hv >> row) % 20)
		var by := y + row * 10
		ci.draw_line(Vector2(float(bx), float(by)),
				Vector2(float(bx), float(by + 10)), dark, 1.0)
	# Subtle highlight on top of one plank.
	if hv % 5 == 0:
		ci.draw_line(Vector2(float(x + 2), float(y + 4)),
				Vector2(float(x + TILE - 2), float(y + 4)),
				base.lightened(0.10), 1.0)


func _draw_stone_floor(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Grey flagstone. 4×4 tile grid of ~8-px flagstones with dark mortar.
	var base := Color(0.55, 0.55, 0.55) if hv % 3 == 0 else Color(0.50, 0.50, 0.51)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var mortar := base.darkened(0.35)
	# Grid lines every 8 px vertically + horizontally.
	for i in range(1, 4):
		ci.draw_line(Vector2(float(x + i * 8), float(y)),
				Vector2(float(x + i * 8), float(y + TILE)), mortar, 1.0)
		ci.draw_line(Vector2(float(x), float(y + i * 8)),
				Vector2(float(x + TILE), float(y + i * 8)), mortar, 1.0)
	# Random flagstone highlight for depth — pick one cell per tile.
	var hi_col := (hv >> 2) % 4
	var hi_row := (hv >> 5) % 4
	ci.draw_rect(Rect2(x + hi_col * 8 + 1, y + hi_row * 8 + 1, 6, 6),
			base.lightened(0.10))


func _draw_red_carpet(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Deep red woven carpet. Interior-only detail (weave crosshatch + a
	# subtle gold medallion) — no trim on the tile edges so multiple
	# carpet tiles placed side by side read as one large rug without any
	# seams down the middle. The atlas can't know its neighbors, so ANY
	# edge-drawn feature would leak into interior seams. Border trim
	# lives on the FLOOR biome around the rug instead.
	var base := Color(0.55, 0.15, 0.15) if hv % 3 != 0 else Color(0.50, 0.13, 0.13)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Weave — full-tile diagonal hatch that wraps cleanly across seams
	# because the pattern is periodic at 4 px. Alternating shade for depth.
	var hatch := base.lightened(0.12)
	for i in range(-TILE, TILE * 2, 4):
		ci.draw_line(Vector2(float(x + i), float(y)),
				Vector2(float(x + i + TILE), float(y + TILE)),
				hatch, 1.0)
	# Subtle gold medallion centered in the tile — rare (hv-gated) so a
	# large rug isn't visually noisy but individual tiles get some detail.
	if hv % 4 == 0:
		var gold := Color(0.85, 0.70, 0.25, 0.55)
		ci.draw_circle(Vector2(float(x) + 16.0, float(y) + 16.0), 2.0, gold)


func _draw_hearth_stone(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Dark charcoal stone with soot cracks. For the tiles around fireplaces.
	var base := Color(0.20, 0.16, 0.14) if hv % 3 == 0 else Color(0.24, 0.19, 0.16)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Cracks — a few short lines with deterministic angles.
	var crack := base.darkened(0.35)
	for i in range(3):
		var sx := x + 4 + ((hv >> (i * 2)) % 24)
		var sy := y + 4 + ((hv >> (i * 3)) % 24)
		var ex := sx + 4 - ((hv >> i) % 8)
		var ey := sy + 3 + ((hv >> (i + 1)) % 5)
		ci.draw_line(Vector2(float(sx), float(sy)),
				Vector2(float(ex), float(ey)), crack, 1.0)
	# Rare ember glow for warmth.
	if hv % 9 == 0:
		ci.draw_circle(Vector2(float(x) + 16.0, float(y) + 16.0), 1.5,
				Color(0.95, 0.35, 0.10, 0.65))


func _draw_wall_wood(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Vertical planks — impassable. Trim strip on top + shadow strip on
	# bottom so contiguous painted rows read as a wall run.
	var base := Color(0.42, 0.28, 0.14) if hv % 3 != 0 else Color(0.36, 0.24, 0.12)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var dark := base.darkened(0.35)
	# Vertical plank divisions every ~8 px.
	for i in range(1, 4):
		ci.draw_line(Vector2(float(x + i * 8), float(y)),
				Vector2(float(x + i * 8), float(y + TILE)), dark, 1.0)
	# Trim strip at top (bright) + shadow at bottom (dark) — "wall run".
	ci.draw_rect(Rect2(x, y, TILE, 3), base.lightened(0.20))
	ci.draw_rect(Rect2(x, y + TILE - 3, TILE, 3), base.darkened(0.40))


func _draw_wall_stone(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Staggered stone brick — impassable. Two rows of ~4 bricks with
	# alternating half-offset for a running-bond pattern.
	var base := Color(0.50, 0.48, 0.44) if hv % 3 == 0 else Color(0.46, 0.44, 0.40)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var mortar := base.darkened(0.35)
	# Row 1 — full bricks (0..8, 8..16, 16..24, 24..32).
	ci.draw_line(Vector2(float(x), float(y + 10)),
			Vector2(float(x + TILE), float(y + 10)), mortar, 1.0)
	# Row 2 — offset by 4 px.
	ci.draw_line(Vector2(float(x), float(y + 22)),
			Vector2(float(x + TILE), float(y + 22)), mortar, 1.0)
	# Vertical mortar — offset per row.
	for i in range(1, 4):
		ci.draw_line(Vector2(float(x + i * 8), float(y)),
				Vector2(float(x + i * 8), float(y + 10)), mortar, 1.0)
	for i in range(1, 4):
		ci.draw_line(Vector2(float(x + i * 8 - 4), float(y + 10)),
				Vector2(float(x + i * 8 - 4), float(y + 22)), mortar, 1.0)
	for i in range(1, 4):
		ci.draw_line(Vector2(float(x + i * 8), float(y + 22)),
				Vector2(float(x + i * 8), float(y + TILE)), mortar, 1.0)


func _draw_sand(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Warm tan beach sand with fine stipple flecks.
	var base := Color(0.86, 0.78, 0.58) if hv % 3 != 0 else Color(0.82, 0.74, 0.54)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Stipple — a few darker specks (grains of coarser sand).
	var speck := base.darkened(0.18)
	for i in range(5):
		var sx := x + ((hv >> (i * 2)) % TILE)
		var sy := y + ((hv >> (i * 3)) % TILE)
		ci.draw_rect(Rect2(sx, sy, 1, 1), speck)
	# Occasional shell/pebble.
	if hv % 11 == 0:
		ci.draw_circle(Vector2(float(x) + 16.0, float(y) + 16.0), 1.5,
				Color(0.95, 0.92, 0.85, 0.85))


func _draw_dirt_path(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Mid-brown dirt with pebble specks. Softer alternative to the stone road.
	var base := Color(0.42, 0.32, 0.20) if hv % 3 == 0 else Color(0.38, 0.29, 0.18)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Pebble specks.
	var pebble := base.lightened(0.18)
	for i in range(4):
		var sx := x + ((hv >> (i * 2)) % TILE)
		var sy := y + ((hv >> (i * 3)) % TILE)
		ci.draw_circle(Vector2(float(sx), float(sy)), 1.0, pebble)
	# Rare grass tuft edge.
	if hv % 7 == 0:
		ci.draw_line(Vector2(float(x + 4), float(y + 28)),
				Vector2(float(x + 6), float(y + 24)),
				Color(0.30, 0.42, 0.16, 0.70), 1.0)


func _draw_shallow_water(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Light blue water — walkable. Wavy ripple lines animated by _process
	# redraws (existing atlas cache captures a still frame; live tiles get
	# the wave through the time-driven redraw path in Ground._draw).
	var base := Color(0.45, 0.65, 0.85) if hv % 3 != 0 else Color(0.42, 0.62, 0.82)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var ripple := base.lightened(0.15)
	# Two horizontal wave lines, offset in phase per tile via hv.
	for row in range(2):
		var yy: float = float(y + 10 + row * 12)
		var phase: float = t * 2.0 + float(hv % 7)
		for i in range(0, TILE, 4):
			var xx: float = float(x + i)
			var wy: float = yy + sin(phase + float(i) * 0.5) * 1.0
			ci.draw_circle(Vector2(xx, wy), 0.8, ripple)
	# Sandy bottom hint — a couple of light specks.
	if hv % 5 == 0:
		ci.draw_circle(Vector2(float(x) + 8.0, float(y) + 22.0), 1.2,
				Color(0.80, 0.72, 0.55, 0.45))


func _draw_farm_crops(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Tilled brown soil with vertical crop rows. Placeholder for the planned
	# Farming skill — currently paintable so admins can lay out farm plots.
	var base := Color(0.35, 0.22, 0.10) if hv % 3 == 0 else Color(0.32, 0.20, 0.09)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Soil rows — darker vertical stripes every 4 px.
	var row_col := base.darkened(0.30)
	for i in range(0, TILE, 4):
		ci.draw_line(Vector2(float(x + i + 2), float(y + 2)),
				Vector2(float(x + i + 2), float(y + TILE - 2)),
				row_col, 1.0)
	# Sprout tips — small green marks between rows.
	var sprout := Color(0.35, 0.55, 0.18)
	for i in range(3):
		var sx := x + 4 + ((hv >> (i * 2)) % 22)
		var sy := y + 6 + ((hv >> (i * 3)) % 20)
		ci.draw_rect(Rect2(sx, sy, 1, 3), sprout)

# ══════════════════════════════════════════════════════════════════════════════
# ── Hills / transitions / variety / beach biomes (Track 2 expansion) ─────────
# All follow the same signature (ci, hv, x, y, cx, cy). Hills draw a top
# highlight band + bottom shadow band to fake a ridge silhouette without
# breaking the tileable atlas grid. Transitions blend two source biomes'
# base colors with hv-scattered patches so painted seams read as gradual
# rather than a hard line.

# ── Hill tiles — SEAMLESS heavy-texture surfaces. ─────────────────────────
# Same principle as the red_carpet fix: NO edge trim, NO directional
# strips, NO features that stop at tile boundaries. Every mark uses
# world-coordinate (`x + local_offset`) sampling so the pattern flows
# across seams — a 3×3 patch of hill tiles reads as one continuous
# rocky mountain region, not nine bordered squares.
#
# Individual tiles get elevation cues from:
#   1. Dense rock/scree scatter across the full tile face
#   2. Muted-tone base colors darker than the surrounding terrain
#   3. Small highlight dots (bright rocks catching light) placed
#      independently of tile boundaries via `(x, y)` hashing

func _draw_plains_hills(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Grass-topped rocky rise. Base is a mottled darker grass than plains
	# so a cluster of hills reads as "high grass ridge" against surrounding
	# meadow. Rocks poke through everywhere — dense scree makes the tile
	# feel elevated + weighty.
	var base := Color(0.30, 0.48, 0.20) if hv % 3 != 0 else Color(0.26, 0.44, 0.18)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Rock outcrops — 6 rocks per tile, positions seeded from WORLD coords
	# so adjacent tiles don't line up their rocks into visible grid rows.
	var rock := Color(0.55, 0.50, 0.42)
	var rock_shadow := Color(0.36, 0.32, 0.26)
	for i in range(6):
		var nh := (x * 73856 + y * 19349) ^ (i * 83492)
		var sx := x + ((nh >> 3) & 27)
		var sy := y + ((nh >> 8) & 27)
		var sz := 2 + ((nh >> 12) & 2)
		ci.draw_rect(Rect2(sx, sy, sz, sz), rock)
		ci.draw_rect(Rect2(sx, sy + sz - 1, sz, 1), rock_shadow)
	# Sparse grass tufts filling gaps.
	for i in range(3):
		var nh2 := (x * 47143 + y * 65867) ^ (i * 24029)
		var sx2 := x + ((nh2 >> 3) & 29)
		var sy2 := y + ((nh2 >> 9) & 29)
		ci.draw_rect(Rect2(sx2, sy2, 1, 2), base.darkened(0.35))


func _draw_oak_hills(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Wooded rocky slope. Darker forest-floor base with big moss-covered
	# stones. Adjacent tiles read as one forested ridge.
	var base := Color(0.20, 0.38, 0.14) if hv % 3 == 0 else Color(0.17, 0.34, 0.12)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Big moss-covered boulders (2-3 per tile).
	var moss := Color(0.30, 0.44, 0.20)
	var stone := Color(0.42, 0.40, 0.36)
	for i in range(2):
		var nh := (x * 82471 + y * 39847) ^ (i * 91201)
		var cxx := x + 4 + ((nh >> 3) & 23)
		var cyy := y + 4 + ((nh >> 8) & 23)
		ci.draw_circle(Vector2(float(cxx), float(cyy)), 4.0, stone)
		ci.draw_circle(Vector2(float(cxx - 1), float(cyy - 2)), 2.5, moss)
	# Small pebbles filling.
	for i in range(4):
		var nh2 := (x * 17389 + y * 42107) ^ (i * 55403)
		var px := x + ((nh2 >> 3) & 29)
		var py := y + ((nh2 >> 9) & 29)
		ci.draw_rect(Rect2(px, py, 2, 2), stone.darkened(0.15))


func _draw_pine_hills(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Steep pine slopes — very dark forest floor with jagged rocks.
	var base := Color(0.12, 0.28, 0.14) if hv % 3 == 0 else Color(0.10, 0.24, 0.12)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Jagged dark rocks scattered densely.
	var rock := Color(0.32, 0.30, 0.28)
	for i in range(7):
		var nh := (x * 63151 + y * 24631) ^ (i * 47921)
		var sx := x + ((nh >> 3) & 27)
		var sy := y + ((nh >> 8) & 27)
		var sz := 2 + ((nh >> 12) & 2)
		ci.draw_rect(Rect2(sx, sy, sz, sz), rock)
	# Fallen needles as short brown lines — random direction per world pos.
	var needle_dark := Color(0.22, 0.14, 0.08)
	for i in range(4):
		var nh2 := (x * 12583 + y * 96731) ^ (i * 28471)
		var nx := x + ((nh2 >> 3) & 29)
		var ny := y + ((nh2 >> 9) & 29)
		var dx := 2 - int((nh2 >> 15) & 5)
		var dy := 1 + int((nh2 >> 18) & 3)
		ci.draw_line(Vector2(float(nx), float(ny)),
				Vector2(float(nx + dx), float(ny + dy)),
				needle_dark, 1.0)


func _draw_snow_hills(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Frozen peaks — bright white base with dark cold rock poking through.
	var base := Color(0.90, 0.94, 0.98) if hv % 3 != 0 else Color(0.85, 0.90, 0.96)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Exposed rock outcrops — grey-blue stones.
	var stone := Color(0.55, 0.60, 0.68)
	var stone_dark := Color(0.42, 0.48, 0.58)
	for i in range(4):
		var nh := (x * 78493 + y * 21073) ^ (i * 59217)
		var sx := x + 2 + ((nh >> 3) & 25)
		var sy := y + 2 + ((nh >> 8) & 25)
		var sz := 3 + ((nh >> 12) & 2)
		ci.draw_rect(Rect2(sx, sy, sz, sz), stone)
		ci.draw_rect(Rect2(sx, sy + sz - 1, sz, 1), stone_dark)
	# Powdery snow bumps highlight.
	for i in range(3):
		var nh2 := (x * 33871 + y * 84109) ^ (i * 71203)
		var px := x + ((nh2 >> 3) & 29)
		var py := y + ((nh2 >> 9) & 29)
		ci.draw_circle(Vector2(float(px), float(py)), 1.5, Color(1.0, 1.0, 1.0))


func _draw_forest_edge(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Plains ↔ oak_forest blend — grass base with scattered saplings.
	var base := Color(0.28, 0.52, 0.22) if hv % 3 != 0 else Color(0.24, 0.48, 0.20)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Sapling — a small dark triangle + trunk line.
	for i in range(2):
		var sx := x + 6 + ((hv >> (i * 3)) % 20)
		var sy := y + 8 + ((hv >> (i * 2)) % 18)
		ci.draw_line(Vector2(float(sx), float(sy)), Vector2(float(sx), float(sy + 4)),
				Color(0.30, 0.20, 0.10), 1.0)
		ci.draw_circle(Vector2(float(sx), float(sy - 1)), 2.0, Color(0.14, 0.34, 0.12))
	# Grass tufts.
	for i in range(2):
		var sx2 := x + 3 + ((hv >> (i * 2)) % 24)
		var sy2 := y + 20 + ((hv >> (i * 3)) % 8)
		ci.draw_rect(Rect2(sx2, sy2, 1, 2), base.darkened(0.30))


func _draw_swamp_edge(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Plains ↔ swamp blend — patchy wet grass + mud spots.
	var base := Color(0.26, 0.36, 0.20) if hv % 3 == 0 else Color(0.22, 0.32, 0.16)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Mud patches.
	for i in range(2):
		var mx := x + 4 + ((hv >> (i * 3)) % 20)
		var my := y + 6 + ((hv >> (i * 2)) % 18)
		ci.draw_circle(Vector2(float(mx), float(my)), 3.0, Color(0.20, 0.16, 0.10))
	# Reed sprigs.
	if hv % 4 == 0:
		ci.draw_line(Vector2(float(x + 10), float(y + 22)),
				Vector2(float(x + 10), float(y + 16)),
				Color(0.42, 0.48, 0.20), 1.0)


func _draw_shore_grass(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Plains ↔ sand blend — coarse grass over sandy soil.
	var base := Color(0.60, 0.66, 0.42) if hv % 3 != 0 else Color(0.56, 0.62, 0.38)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Sand patches.
	for i in range(3):
		var sx := x + ((hv >> (i * 2)) % TILE)
		var sy := y + ((hv >> (i * 3)) % TILE)
		ci.draw_circle(Vector2(float(sx), float(sy)), 2.0, Color(0.82, 0.74, 0.54, 0.85))
	# Grass blades.
	for i in range(3):
		var sx2 := x + 6 + ((hv >> (i * 2)) % 20)
		var sy2 := y + 10 + ((hv >> (i * 3)) % 14)
		ci.draw_rect(Rect2(sx2, sy2, 1, 3), Color(0.34, 0.50, 0.22))


func _draw_snow_line(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Plains ↔ snow blend — patchy snow on grass.
	var base := Color(0.62, 0.75, 0.62) if hv % 3 != 0 else Color(0.56, 0.70, 0.56)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Snow drifts.
	for i in range(3):
		var sx := x + ((hv >> (i * 2)) % TILE)
		var sy := y + ((hv >> (i * 3)) % TILE)
		ci.draw_circle(Vector2(float(sx), float(sy)), 3.0, Color(0.90, 0.94, 0.98, 0.85))
	# Grass poking through.
	for i in range(2):
		var sx2 := x + 8 + ((hv >> (i * 3)) % 16)
		var sy2 := y + 18 + ((hv >> (i * 2)) % 10)
		ci.draw_rect(Rect2(sx2, sy2, 1, 2), Color(0.32, 0.50, 0.22))


func _draw_meadow(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Flower-strewn plains — brighter grass base with 4-5 flower dots.
	var base := Color(0.44, 0.68, 0.30) if hv % 3 != 0 else Color(0.40, 0.64, 0.28)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Flowers — cycle through colors for variety.
	var flowers := [Color(0.95, 0.85, 0.30), Color(0.92, 0.42, 0.58),
					Color(0.72, 0.42, 0.88), Color(0.98, 0.98, 0.94)]
	for i in range(4):
		var fx := x + 4 + ((hv >> (i * 2)) % 24)
		var fy := y + 4 + ((hv >> (i * 3)) % 24)
		var fc: Color = flowers[(hv + i) % 4]
		ci.draw_circle(Vector2(float(fx), float(fy)), 1.4, fc)


func _draw_tundra(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Cold plains — muted olive-brown with frost specks.
	var base := Color(0.50, 0.55, 0.46) if hv % 3 == 0 else Color(0.46, 0.51, 0.42)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Lichen patches.
	for i in range(2):
		var lx := x + 6 + ((hv >> (i * 3)) % 20)
		var ly := y + 8 + ((hv >> (i * 2)) % 16)
		ci.draw_circle(Vector2(float(lx), float(ly)), 3.0, Color(0.60, 0.66, 0.48, 0.85))
	# Frost specks.
	for i in range(3):
		var sx := x + ((hv >> (i * 2)) % TILE)
		var sy := y + ((hv >> (i * 3)) % TILE)
		ci.draw_rect(Rect2(sx, sy, 1, 1), Color(0.82, 0.88, 0.90))


func _draw_clearing(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Forest opening — grass with tree stumps.
	var base := Color(0.36, 0.58, 0.24) if hv % 3 != 0 else Color(0.32, 0.54, 0.20)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Central stump — one per tile.
	if hv % 3 != 0:
		var sx := x + 12 + ((hv >> 2) % 8)
		var sy := y + 12 + ((hv >> 5) % 8)
		ci.draw_circle(Vector2(float(sx), float(sy)), 4.0, Color(0.42, 0.28, 0.14))
		ci.draw_circle(Vector2(float(sx), float(sy)), 3.0, Color(0.62, 0.44, 0.22))
		ci.draw_circle(Vector2(float(sx), float(sy)), 1.0, Color(0.34, 0.22, 0.10))
	# Grass tufts.
	for i in range(2):
		var gx := x + 4 + ((hv >> (i * 2)) % 24)
		var gy := y + 4 + ((hv >> (i * 3)) % 24)
		ci.draw_rect(Rect2(gx, gy, 1, 2), Color(0.24, 0.42, 0.16))


func _draw_ashlands_hills(ci: CanvasItem, _hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Volcanic slope — dark charred rock, cracks, ember flecks. Seamless
	# (world-coord seeded) so a cluster reads as one lava plateau.
	var base := Color(0.34, 0.16, 0.08)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Dark charred rock chunks.
	var rock := Color(0.20, 0.10, 0.06)
	for i in range(6):
		var nh := (x * 91129 + y * 42421) ^ (i * 33619)
		var sx := x + ((nh >> 3) & 27)
		var sy := y + ((nh >> 8) & 27)
		var sz := 2 + ((nh >> 12) & 2)
		ci.draw_rect(Rect2(sx, sy, sz, sz), rock)
	# Lava cracks — glowing orange lines.
	var lava := Color(0.98, 0.42, 0.10)
	for i in range(2):
		var nh2 := (x * 24631 + y * 78493) ^ (i * 62983)
		var sx2 := x + 2 + ((nh2 >> 3) & 25)
		var sy2 := y + 2 + ((nh2 >> 8) & 25)
		var dx := 3 - int((nh2 >> 12) & 5)
		var dy := 2 + int((nh2 >> 15) & 3)
		ci.draw_line(Vector2(float(sx2), float(sy2)),
				Vector2(float(sx2 + dx), float(sy2 + dy)), lava, 1.0)
	# Ember specks.
	for i in range(3):
		var nh3 := (x * 55927 + y * 14713) ^ (i * 88129)
		var ex := x + ((nh3 >> 3) & 29)
		var ey := y + ((nh3 >> 9) & 29)
		ci.draw_rect(Rect2(ex, ey, 1, 1), Color(1.0, 0.55, 0.15))


func _draw_helheim_hills(ci: CanvasItem, _hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Otherworldly purple ridge — dark stones + wisp glows. Seamless.
	var base := Color(0.28, 0.08, 0.38)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Rock chunks in a darker hue.
	var rock := Color(0.16, 0.04, 0.24)
	for i in range(6):
		var nh := (x * 38491 + y * 61283) ^ (i * 47927)
		var rx := x + ((nh >> 3) & 27)
		var ry := y + ((nh >> 8) & 27)
		var sz := 2 + ((nh >> 12) & 2)
		ci.draw_rect(Rect2(rx, ry, sz, sz), rock)
	# Wisp glow specks.
	for i in range(3):
		var nh2 := (x * 71203 + y * 29473) ^ (i * 54781)
		var sx := x + ((nh2 >> 3) & 29)
		var sy := y + ((nh2 >> 9) & 29)
		ci.draw_circle(Vector2(float(sx), float(sy)), 1.4,
				Color(0.72, 0.60, 0.95, 0.65))


func _draw_rocky_hills(ci: CanvasItem, _hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Grey stone mountain terrain. Dense scree covers the whole tile so
	# adjacent tiles blend into one big rocky region. Seamless.
	var base := Color(0.42, 0.40, 0.36)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Dense scree stones — 8 per tile.
	for i in range(8):
		var nh := (x * 17389 + y * 82471) ^ (i * 26981)
		var sx := x + ((nh >> 3) & 27)
		var sy := y + ((nh >> 8) & 27)
		var sz := 2 + ((nh >> 12) & 2)
		var stone_shade: Color = base.darkened(0.25) if ((nh >> 16) & 1) == 0 else base.darkened(0.40)
		ci.draw_rect(Rect2(sx, sy, sz, sz), stone_shade)
		# Small shadow on the south edge.
		ci.draw_rect(Rect2(sx, sy + sz - 1, sz, 1), Color(0.22, 0.20, 0.18))
	# Occasional bright highlight (rock catching light).
	for i in range(2):
		var nh2 := (x * 33871 + y * 92401) ^ (i * 51119)
		var hx := x + ((nh2 >> 3) & 29)
		var hy := y + ((nh2 >> 9) & 29)
		ci.draw_rect(Rect2(hx, hy, 1, 1), Color(0.72, 0.68, 0.62))


func _draw_sand_hills(ci: CanvasItem, _hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Dune slopes — tan sand with continuous ripple lines that flow across
	# tile seams. Ripple phase uses world x (not local i) so a cluster of
	# sand_hills tiles forms one big undulating dune field.
	var base := Color(0.80, 0.70, 0.48)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Ripple crests — sinusoidal, phase indexed by world x for seam-free flow.
	var crest := base.darkened(0.18)
	var trough := base.darkened(0.10)
	for row in range(4):
		var yy: float = float(y + 4 + row * 7)
		for i in range(0, TILE, 1):
			var wx: int = x + i
			# Continuous phase — every tile picks up where the previous left off.
			var phase: float = float(wx) * 0.42 + float(row) * 1.1
			var wave: float = sin(phase)
			var col: Color = crest if wave > 0.0 else trough
			ci.draw_rect(Rect2(wx, int(yy + wave * 1.4), 1, 1), col)
	# Scattered sand grains for texture.
	for i in range(4):
		var nh := (x * 63151 + y * 47921) ^ (i * 12583)
		var gx := x + ((nh >> 3) & 29)
		var gy := y + ((nh >> 9) & 29)
		ci.draw_rect(Rect2(gx, gy, 1, 1), base.darkened(0.22))


func _draw_cliff_scree(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Cliff ↔ plains — rocky scree with grass tufts.
	var base := Color(0.38, 0.34, 0.30) if hv % 3 == 0 else Color(0.34, 0.30, 0.26)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Rock chunks.
	for i in range(3):
		var sx := x + 3 + ((hv >> (i * 2)) % 24)
		var sy := y + 3 + ((hv >> (i * 3)) % 24)
		var sz := 2 + int((hv >> (i * 4)) % 3)
		ci.draw_rect(Rect2(sx, sy, sz, sz), base.lightened(0.15))
	# Sparse grass poking through.
	if hv % 5 == 0:
		ci.draw_rect(Rect2(x + 20, y + 22, 1, 2), Color(0.28, 0.44, 0.16))


func _draw_moss_rock(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	var base := Color(0.34, 0.42, 0.28) if hv % 3 != 0 else Color(0.30, 0.38, 0.24)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Rock patches showing through the moss.
	for i in range(2):
		var rx := x + 4 + ((hv >> (i * 3)) % 22)
		var ry := y + 6 + ((hv >> (i * 2)) % 20)
		ci.draw_circle(Vector2(float(rx), float(ry)), 4.0, Color(0.42, 0.40, 0.36))
		ci.draw_circle(Vector2(float(rx - 1), float(ry - 1)), 2.0, Color(0.52, 0.50, 0.44))
	# Moss speckle.
	for i in range(4):
		var sx := x + ((hv >> (i * 2)) % TILE)
		var sy := y + ((hv >> (i * 3)) % TILE)
		ci.draw_rect(Rect2(sx, sy, 1, 1), Color(0.42, 0.58, 0.28))


func _draw_volcanic_glass(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Obsidian shards over dark rock.
	var base := Color(0.12, 0.10, 0.14) if hv % 3 == 0 else Color(0.08, 0.06, 0.10)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Sharp glass shards — triangles with sharp highlight.
	for i in range(3):
		var sx := x + 4 + ((hv >> (i * 3)) % 22)
		var sy := y + 6 + ((hv >> (i * 2)) % 20)
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(float(sx), float(sy - 3)),
			Vector2(float(sx + 3), float(sy + 2)),
			Vector2(float(sx - 2), float(sy + 3))]),
			Color(0.24, 0.18, 0.28))
		# Highlight edge.
		ci.draw_line(Vector2(float(sx), float(sy - 3)),
				Vector2(float(sx + 3), float(sy + 2)),
				Color(0.72, 0.65, 0.80, 0.75), 1.0)


func _draw_reef(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Shallow water with coral specks.
	var base := Color(0.48, 0.72, 0.78) if hv % 3 != 0 else Color(0.44, 0.68, 0.74)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Coral clusters.
	var coral := [Color(0.95, 0.55, 0.45), Color(0.98, 0.72, 0.32),
				  Color(0.85, 0.42, 0.62)]
	for i in range(3):
		var cx2 := x + 6 + ((hv >> (i * 3)) % 20)
		var cy2 := y + 6 + ((hv >> (i * 2)) % 20)
		var cc: Color = coral[(hv + i) % 3]
		ci.draw_circle(Vector2(float(cx2), float(cy2)), 2.0, cc)
	# Water ripple line.
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var ripple := base.lightened(0.15)
	for i in range(0, TILE, 4):
		var xx: float = float(x + i)
		var wy: float = float(y + 20) + sin(t * 2.0 + float(i) * 0.5) * 1.0
		ci.draw_circle(Vector2(xx, wy), 0.8, ripple)


func _draw_tidepool(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Water pockets ringed by rock.
	var rock := Color(0.42, 0.40, 0.36)
	ci.draw_rect(Rect2(x, y, TILE, TILE), rock)
	# Central water pool.
	var water := Color(0.40, 0.60, 0.72) if hv % 3 != 0 else Color(0.36, 0.56, 0.68)
	ci.draw_circle(Vector2(float(x) + 16.0, float(y) + 16.0), 10.0, water)
	# Wet edge highlight.
	ci.draw_arc(Vector2(float(x) + 16.0, float(y) + 16.0), 10.0,
			0.0, TAU, 24, Color(0.32, 0.30, 0.26), 1.0)
	# Small critter dot.
	if hv % 7 == 0:
		ci.draw_circle(Vector2(float(x) + 14.0, float(y) + 14.0), 1.0,
				Color(0.95, 0.55, 0.30))


func _draw_wet_sand(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Darker sand — water table just below.
	var base := Color(0.62, 0.54, 0.38) if hv % 3 == 0 else Color(0.58, 0.50, 0.34)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Wet reflection specks.
	for i in range(4):
		var sx := x + ((hv >> (i * 2)) % TILE)
		var sy := y + ((hv >> (i * 3)) % TILE)
		ci.draw_rect(Rect2(sx, sy, 1, 1), base.lightened(0.20))
	# Occasional shell.
	if hv % 8 == 0:
		ci.draw_circle(Vector2(float(x) + 18.0, float(y) + 12.0), 1.5,
				Color(0.98, 0.92, 0.85))


func _draw_driftwood_shore(ci: CanvasItem, hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# Sand with a driftwood plank.
	var base := Color(0.78, 0.70, 0.52) if hv % 3 != 0 else Color(0.74, 0.66, 0.48)
	ci.draw_rect(Rect2(x, y, TILE, TILE), base)
	# Driftwood log — angle varies by hv.
	var wood := Color(0.42, 0.30, 0.18)
	if hv % 2 == 0:
		ci.draw_rect(Rect2(x + 4, y + 14, 24, 5), wood)
		ci.draw_line(Vector2(float(x + 4), float(y + 15)),
				Vector2(float(x + 28), float(y + 15)),
				wood.lightened(0.20), 1.0)
	else:
		ci.draw_rect(Rect2(x + 12, y + 4, 5, 24), wood)
		ci.draw_line(Vector2(float(x + 13), float(y + 4)),
				Vector2(float(x + 13), float(y + 28)),
				wood.lightened(0.20), 1.0)
	# Sand specks.
	for i in range(3):
		var sx := x + ((hv >> (i * 2)) % TILE)
		var sy := y + ((hv >> (i * 3)) % TILE)
		ci.draw_rect(Rect2(sx, sy, 1, 1), base.darkened(0.15))


# ══════════════════════════════════════════════════════════════════════════════
# ── Bridge tiles — walkable-over-water. ──────────────────────────────────────
# North + south edges (4 px each) draw animated blue water ripples so adjacent
# bridge tiles form a continuous span with water visible above and below the
# deck. Interior 24 px is the plank/brick deck itself, seamlessly tileable
# via world-coord seeded detail (same technique as the hills rewrite).

func _draw_wood_bridge(ci: CanvasItem, _hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	# North-edge water band (0..4 px).
	_draw_bridge_water_band(ci, x, y, 4)
	# South-edge water band (TILE-4..TILE).
	_draw_bridge_water_band(ci, x, y + TILE - 4, 4)
	# Middle 24 px: wood plank deck.
	var deck_top: int = y + 4
	var deck_h: int = TILE - 8
	var base := Color(0.55, 0.38, 0.20)
	ci.draw_rect(Rect2(x, deck_top, TILE, deck_h), base)
	# Longitudinal plank seams — 3 running the full tile width so multiple
	# adjacent bridge tiles form a continuous plank floor.
	var dark := Color(0.36, 0.24, 0.12)
	ci.draw_line(Vector2(float(x), float(deck_top + 5)),
			Vector2(float(x + TILE), float(deck_top + 5)), dark, 1.0)
	ci.draw_line(Vector2(float(x), float(deck_top + 12)),
			Vector2(float(x + TILE), float(deck_top + 12)), dark, 1.0)
	ci.draw_line(Vector2(float(x), float(deck_top + 19)),
			Vector2(float(x + TILE), float(deck_top + 19)), dark, 1.0)
	# Cross-planks — vertical dividers every ~10 px, phase indexed on world
	# X so adjacent tiles line up without seams.
	var plank_col := base.darkened(0.20)
	var i: int = 0
	while i < TILE:
		var xx: int = x + ((i + x) % 12) + 2
		if xx < x + TILE - 1:
			ci.draw_line(Vector2(float(xx), float(deck_top)),
					Vector2(float(xx), float(deck_top + deck_h)),
					plank_col, 1.0)
		i += 12
	# Metal support nails at the plank endpoints.
	var nail := Color(0.20, 0.20, 0.22)
	ci.draw_rect(Rect2(x + 3, deck_top + 5, 1, 1), nail)
	ci.draw_rect(Rect2(x + TILE - 4, deck_top + 5, 1, 1), nail)
	ci.draw_rect(Rect2(x + 3, deck_top + deck_h - 6, 1, 1), nail)
	ci.draw_rect(Rect2(x + TILE - 4, deck_top + deck_h - 6, 1, 1), nail)


func _draw_stone_bridge(ci: CanvasItem, _hv: int, x: int, y: int, _cx: float, _cy: float) -> void:
	_draw_bridge_water_band(ci, x, y, 4)
	_draw_bridge_water_band(ci, x, y + TILE - 4, 4)
	# Stone deck.
	var deck_top: int = y + 4
	var deck_h: int = TILE - 8
	var base := Color(0.62, 0.60, 0.56)
	ci.draw_rect(Rect2(x, deck_top, TILE, deck_h), base)
	# Running-bond brick pattern. Two rows of 4 bricks each, offset by half.
	var mortar := base.darkened(0.35)
	# Row 1 (top half) — full-tile brick divisions at 0, 8, 16, 24.
	var row1_y: int = deck_top + deck_h / 2
	ci.draw_line(Vector2(float(x), float(row1_y)),
			Vector2(float(x + TILE), float(row1_y)), mortar, 1.0)
	# Row 2 verticals (offset by 4 px).
	for j in range(1, 4):
		var vx: int = x + j * 8
		ci.draw_line(Vector2(float(vx), float(deck_top)),
				Vector2(float(vx), float(row1_y)), mortar, 1.0)
		var vx2: int = x + j * 8 - 4
		ci.draw_line(Vector2(float(vx2), float(row1_y)),
				Vector2(float(vx2), float(deck_top + deck_h)), mortar, 1.0)
	# Highlight strip along the top of the deck (catches light).
	ci.draw_rect(Rect2(x, deck_top, TILE, 1), base.lightened(0.15))
	# Occasional darker weathered brick.
	var weathered := base.darkened(0.15)
	ci.draw_rect(Rect2(x + ((x * 7 + y * 13) % 20), deck_top + 2, 6, 3), weathered)


## Shared helper for the north/south water band on both bridge biomes.
## Ripples animate off Time.get_ticks_msec and phase across tile boundaries
## via world x, so adjacent tiles' ripples line up seamlessly.
func _draw_bridge_water_band(ci: CanvasItem, x: int, y: int, h: int) -> void:
	var water := Color(0.42, 0.60, 0.78)
	ci.draw_rect(Rect2(x, y, TILE, h), water)
	var ripple := water.lightened(0.20)
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	for i in range(0, TILE, 2):
		var wx: int = x + i
		var phase: float = float(wx) * 0.42 + t * 2.0
		var wy: float = float(y + h / 2) + sin(phase) * float(h) * 0.35
		ci.draw_rect(Rect2(wx, int(wy), 1, 1), ripple)


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
		# Use the outer script's BIOME_COUNT so this loop grows with new
		# biomes without needing to touch the inner class.
		var count: int = int(ground.get("BIOME_COUNT"))
		if count <= 0:
			count = 16
		for bid in range(count):
			ground.call("_draw_biome_cell", self, bid, 0, bid * 32)
