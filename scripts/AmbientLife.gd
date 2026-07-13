extends Node2D

## ── Ambient Life ──────────────────────────────────────────────────────────
##
## A lightweight chunk-scoped Node2D that draws 2-5 tiny non-interactable
## creatures based on the dominant biome of the chunk it lives in. Butterflies
## over meadow, dragonflies over swamp, seagulls over coast, etc.
##
## Purely visual — no Area2D, no collision, no server sync, no persistence.
## Different players see different creatures. When the chunk unloads, the
## Node2D is freed and its creatures vanish with it.
##
## Behavior rules:
## - **Air creatures** (butterfly, small_bird, raven, pigeon, seagull,
##   firefly, dragonfly, gnat, ash_flake, wisp) ignore terrain — they can
##   drift over water, hills, and walls.
## - **Ground creatures** (crab, ptarmigan) reject targets on impassable
##   tiles — they stay on walkable terrain.
## - **Flee from active players**: every creature checks the nearest
##   player each frame. If the player is within FLEE_RADIUS AND has moved
##   in the last IDLE_THRESHOLD seconds, the creature veers away. Idle
##   players (30+ seconds no movement) are ignored — creatures approach
##   as if no one is there. Makes the world feel alive: creatures scatter
##   from a hurrying player but land back on a resting one.
##
## Spawned by World._load_chunk right after the resource/monster passes.

const TILE := 32
const CHUNK_PX := 512

## Distance within which a moving player scares creatures.
const FLEE_RADIUS := 160.0
## Player must have moved within this many seconds to spook creatures.
## Sitting still for 30 seconds = creatures accept them.
const IDLE_THRESHOLD := 30.0
## Speed multiplier applied while fleeing — creatures move faster + more
## erratically away from the player.
const FLEE_SPEED_MULT := 3.5

# Ground creatures walk on the terrain and can't step onto impassable tiles.
# Everything else is considered air-drift and unrestricted.
const _GROUND_TYPES := ["crab", "ptarmigan"]

## Per-biome creature table. Keys are biome name strings (must match
## Ground._BIOME_NAMES). Values are Arrays of creature-type names that this
## Node knows how to draw + animate in `_process` / `_draw`.
const _BIOME_LIFE: Dictionary = {
	# Grass-family — bright open-air pollinators + small birds.
	"plains":        ["butterfly", "small_bird"],
	"plains2":       ["butterfly", "small_bird"],
	"plains_hills":  ["butterfly", "small_bird"],
	"meadow":        ["butterfly", "small_bird", "butterfly"],
	"tundra":        ["ptarmigan"],
	"clearing":      ["small_bird", "firefly"],
	"snow_line":     ["small_bird"],
	"shore_grass":   ["butterfly", "seagull"],
	# Forest — small birds + fireflies.
	"oak_forest":    ["small_bird", "firefly"],
	"pine_forest":   ["small_bird", "firefly"],
	"oak_hills":     ["small_bird"],
	"pine_hills":    ["small_bird"],
	"dark_forest":   ["raven", "firefly"],
	"forest_edge":   ["small_bird", "butterfly"],
	# Wetlands — dragonflies + gnats.
	"swamp":         ["dragonfly", "gnat"],
	"swamp_edge":    ["dragonfly", "gnat"],
	"farm_crops":    ["bee", "butterfly"],
	# Water — seagulls arc across the surface; small fish drift below.
	"coast":         ["seagull", "small_fish"],
	"ocean":         ["seagull", "small_fish"],
	"reef":          ["seagull", "small_fish"],
	"tidepool":      ["seagull", "crab", "small_fish"],
	"shallow_water": ["seagull", "small_fish"],
	# Beach — crabs + seagulls.
	"sand":              ["crab", "seagull"],
	"wet_sand":          ["crab", "seagull"],
	"driftwood_shore":   ["crab", "seagull"],
	# Snow — ptarmigan (rare).
	"snow":              ["ptarmigan"],
	"snow_hills":        ["ptarmigan"],
	# Fire/hell — ash flakes + wisps.
	"ashlands":          ["ash_flake"],
	"ashlands_hills":    ["ash_flake"],
	"volcanic_glass":    ["ash_flake"],
	"helheim":           ["wisp"],
	"helheim_hills":     ["wisp"],
	# Rock/mountain — small birds.
	"mountain":          ["small_bird"],
	"rocky":             ["small_bird"],
	"rocky_hills":       ["small_bird"],
	"moss_rock":         ["small_bird"],
	"cliff_scree":       ["small_bird"],
	# Path/town — pigeons.
	"town":              ["pigeon"],
	"road":              ["pigeon"],
	"dirt_path":         ["pigeon"],
	# Interior biomes — none. Explicitly empty to short-circuit.
}

## Runtime creature list. Each entry: {type, pos, vel, phase, life_bounds}.
## `pos` and `life_bounds` are in this Node's LOCAL coord space (chunk-relative).
var _creatures: Array = []

## Set by World when instancing so the Node knows which chunk it belongs to.
## Used only for logging; unloads happen via queue_free from World's chunk map.
var chunk_key: Vector2i = Vector2i.ZERO

## Called by World right after add_child. Reads the ground's dominant biome
## at the chunk center + rolls the creature list. Idempotent — safe to call
## once; extra calls are no-ops (returns early on non-empty _creatures).
func setup(dominant_biome: String) -> void:
	if _creatures.size() > 0:
		return
	var types: Array = _BIOME_LIFE.get(dominant_biome, []) as Array
	if types.is_empty():
		set_process(false)
		return
	# 2-5 creatures per chunk (was 3-6 — user reported the world was too
	# busy). Deterministic seed derived from chunk key so creatures stay
	# in the same rough spots when the chunk reloads.
	var rng := RandomNumberGenerator.new()
	rng.seed = (chunk_key.x * 31337 + chunk_key.y * 91129) ^ 0xB1CE
	var count := 2 + rng.randi() % 4
	for _i in range(count):
		var t: String = types[rng.randi() % types.size()]
		_creatures.append(_new_creature(t, rng))
	queue_redraw()


func _new_creature(t: String, rng: RandomNumberGenerator) -> Dictionary:
	# Position within the chunk (0..CHUNK_PX) in local coords.
	var pos := Vector2(rng.randf() * CHUNK_PX, rng.randf() * CHUNK_PX)
	# Baseline drift velocity per creature type.
	var speed := 20.0
	match t:
		"seagull":   speed = 45.0
		"raven":     speed = 30.0
		"pigeon":    speed = 18.0
		"dragonfly": speed = 25.0
		"gnat":      speed = 10.0
		"crab":      speed = 8.0
		"small_fish": speed = 22.0
		"ash_flake": speed = 12.0
		"wisp":      speed = 15.0
		"ptarmigan": speed = 5.0
		_:           speed = 20.0
	var ang := rng.randf() * TAU
	var vel := Vector2(cos(ang), sin(ang)) * speed
	return {
		"type":  t,
		"pos":   pos,
		"vel":   vel,
		"phase": rng.randf() * TAU,
	}


func _process(delta: float) -> void:
	if _creatures.is_empty():
		return
	# ── Find the nearest ACTIVE (recently-moved) player. ──
	# Idle players (no movement for IDLE_THRESHOLD seconds) don't scare
	# anything. A quiet resting player is invisible to ambient life; a
	# hurrying one scatters everything nearby.
	var scary_pos: Vector2 = Vector2.INF
	var scary_dist_sq: float = INF
	var players := get_tree().get_nodes_in_group("player")
	for pl_v in players:
		var pl := pl_v as Node2D
		if pl == null:
			continue
		if _player_is_idle(pl):
			continue
		var d: Vector2 = pl.global_position - global_position - Vector2(CHUNK_PX * 0.5, CHUNK_PX * 0.5)
		var ds: float = d.length_squared()
		if ds < scary_dist_sq:
			scary_dist_sq = ds
			scary_pos = pl.global_position

	# March each creature. Bounce softly at chunk edges (add 32 px margin)
	# so creatures stay visible over the chunk instead of scattering.
	var margin := 32.0
	var minv := margin
	var maxv := float(CHUNK_PX) - margin
	var ground := get_tree().get_first_node_in_group("ground")
	for c: Dictionary in _creatures:
		var t: String = str(c["type"])
		var p: Vector2 = c["pos"]
		var v: Vector2 = c["vel"]
		var ph: float = float(c["phase"])
		var is_ground := t in _GROUND_TYPES

		# ── Flee vector: if a moving player is nearby, add velocity away. ──
		var fleeing := false
		if scary_pos != Vector2.INF:
			var world_pos := global_position + p
			var away: Vector2 = world_pos - scary_pos
			var dist := away.length()
			if dist > 0.001 and dist < FLEE_RADIUS:
				# Blend flee direction into velocity — stronger when closer.
				var urgency: float = 1.0 - (dist / FLEE_RADIUS)
				v = v.lerp(away.normalized() * v.length() * FLEE_SPEED_MULT,
						urgency * 0.7)
				fleeing = true

		var speed_scale: float = FLEE_SPEED_MULT if fleeing else 1.0

		# Type-specific motion overlay on top of linear drift.
		var new_p: Vector2 = p
		match t:
			"butterfly":
				# Sine-wave path — flutters up and down.
				new_p.y += sin(ph) * 20.0 * delta
				new_p += v * delta
				ph += delta * 5.0
			"firefly":
				# Slow lazy circles; use vel-perp.
				new_p += v.rotated(sin(ph)) * delta
				ph += delta * 1.5
			"ash_flake":
				# Drift downward with a horizontal wobble.
				new_p.x += sin(ph) * 4.0 * delta
				new_p.y += 8.0 * delta
				ph += delta * 2.0
			"wisp":
				# Slow floaty drift with a shrinking-growing radius.
				new_p += v * delta
				ph += delta * 1.0
			_:
				# Default: straight linear drift.
				new_p += v * delta * speed_scale

		# ── Ground creatures: reject impassable targets. ──
		# Air creatures skip this — they drift over water and hills freely.
		if is_ground and ground != null:
			var world_target := global_position + new_p
			var tx := int(world_target.x / TILE)
			var ty := int(world_target.y / TILE)
			if ground.has_method("is_tile_impassable") and \
					ground.call("is_tile_impassable", tx, ty):
				# Blocked — invert velocity so we peel off.
				v = -v
				new_p = p
		p = new_p

		# Bounce off chunk margins.
		if p.x < minv:
			p.x = minv; v.x = abs(v.x)
		elif p.x > maxv:
			p.x = maxv; v.x = -abs(v.x)
		if p.y < minv:
			p.y = minv; v.y = abs(v.y)
		elif p.y > maxv:
			p.y = maxv; v.y = -abs(v.y)
		c["pos"] = p
		c["vel"] = v
		c["phase"] = ph
	queue_redraw()


## True when a player has not moved for IDLE_THRESHOLD seconds. Falls back
## to "not idle" (i.e. scary) when the player script doesn't expose a
## last-movement timestamp — safer default: creatures avoid unknown
## players. Player.gd sets `_ambient_idle_since` (float unix seconds) on
## its own tick.
func _player_is_idle(pl: Node) -> bool:
	if pl == null:
		return true
	if not pl.has_meta("ambient_last_move_ms"):
		return false
	var last_ms: int = int(pl.get_meta("ambient_last_move_ms"))
	var now_ms: int = Time.get_ticks_msec()
	return float(now_ms - last_ms) / 1000.0 >= IDLE_THRESHOLD


func _draw() -> void:
	for c: Dictionary in _creatures:
		var t: String = str(c["type"])
		var p: Vector2 = c["pos"]
		var ph: float = float(c["phase"])
		match t:
			"butterfly":
				# Two little wing petals + body dot.
				var wing_col := Color(0.95, 0.62, 0.82)
				var flap: float = 1.2 + sin(ph * 4.0) * 0.5
				draw_circle(p + Vector2(-flap, -1), 1.6, wing_col)
				draw_circle(p + Vector2( flap, -1), 1.6, wing_col)
				draw_circle(p, 0.9, Color(0.30, 0.20, 0.10))
			"small_bird":
				# V-shape silhouette drifting through the air.
				var col := Color(0.10, 0.10, 0.10)
				draw_line(p + Vector2(-2, 1), p, col, 1.0)
				draw_line(p + Vector2( 2, 1), p, col, 1.0)
			"raven":
				# Bigger black V.
				var col2 := Color(0.05, 0.05, 0.05)
				draw_line(p + Vector2(-3, 1), p, col2, 1.5)
				draw_line(p + Vector2( 3, 1), p, col2, 1.5)
			"pigeon":
				var col3 := Color(0.60, 0.60, 0.60)
				draw_circle(p, 2.0, col3)
				draw_circle(p + Vector2(1.5, -0.5), 0.8, col3.darkened(0.15))
			"seagull":
				# White M-wing.
				var col4 := Color(0.95, 0.95, 0.95)
				draw_line(p + Vector2(-3, 1), p + Vector2(-1, -1), col4, 1.5)
				draw_line(p + Vector2(-1, -1), p + Vector2(1, 1), col4, 1.5)
				draw_line(p + Vector2( 1, 1), p + Vector2( 3, -1), col4, 1.5)
			"firefly":
				# Pulsing yellow glow.
				var glow: float = 0.4 + 0.6 * abs(sin(ph))
				var col5 := Color(1.0, 0.92, 0.30, glow)
				draw_circle(p, 1.8, col5)
				draw_circle(p, 0.8, Color(1.0, 1.0, 0.60, glow))
			"dragonfly":
				# Iridescent body with two wing streaks.
				draw_circle(p, 1.6, Color(0.30, 0.80, 0.65))
				var wing := Color(0.85, 0.92, 0.95, 0.55)
				draw_line(p + Vector2(-3, 0), p, wing, 1.0)
				draw_line(p + Vector2( 3, 0), p, wing, 1.0)
			"gnat":
				# Tiny grey dot.
				draw_circle(p, 0.9, Color(0.30, 0.30, 0.28))
			"crab":
				# Red circle + two pincer dots.
				draw_circle(p, 2.0, Color(0.82, 0.28, 0.20))
				draw_circle(p + Vector2(-3, -1), 0.9, Color(0.72, 0.20, 0.15))
				draw_circle(p + Vector2( 3, -1), 0.9, Color(0.72, 0.20, 0.15))
			"small_fish":
				# Silver oval body + triangular tail, semi-transparent so
				# it reads as swimming below the water surface.
				var body_col := Color(0.75, 0.80, 0.85, 0.70)
				var tail_col := Color(0.55, 0.62, 0.70, 0.65)
				# Direction inferred from velocity sign so tail sits behind.
				# Cheap approximation via phase-based facing (all fish in a
				# chunk face the same way roughly — good enough for flavor).
				var facing: float = -1.0 if fmod(ph, TAU) < PI else 1.0
				# Body — 3 px wide oval.
				draw_circle(p, 1.6, body_col)
				draw_circle(p + Vector2(facing * 1.4, 0), 1.0, body_col)
				# Tail fluke.
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-facing * 1.8, 0),
					p + Vector2(-facing * 3.2, -1.4),
					p + Vector2(-facing * 3.2,  1.4)]), tail_col)
			"ash_flake":
				# Grey ember flake.
				draw_circle(p, 1.2, Color(0.85, 0.55, 0.35, 0.75))
				draw_circle(p, 0.5, Color(1.0, 0.85, 0.42, 0.85))
			"wisp":
				# Purple orb with alpha halo.
				var pulse: float = 0.5 + 0.5 * abs(sin(ph))
				draw_circle(p, 3.0, Color(0.72, 0.42, 0.95, 0.35 * pulse))
				draw_circle(p, 1.4, Color(0.92, 0.72, 1.0, 0.85 * pulse))
			"ptarmigan":
				# White puff on the snow.
				draw_circle(p, 2.5, Color(0.95, 0.95, 0.98))
				draw_circle(p + Vector2(1.5, -1), 0.8, Color(0.30, 0.30, 0.30))
			_:
				draw_circle(p, 1.0, Color(1.0, 1.0, 1.0, 0.5))
