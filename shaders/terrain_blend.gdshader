// terrain_blend.gdshader
// Renders the whole world ground in one full-coverage draw_rect. Per fragment:
//   1. Compute world_px from UV * world_size.
//   2. Look up the biome id at this fragment's tile from `biome_lookup` (300x300
//      R8 texture; each pixel's R channel encodes the biome id 0..15).
//   3. Sample the matching cell from `atlas` (32 x (16*32) vertical strip baked
//      at startup — one cell per biome id).
//   4. For each of the 4 axis neighbors, look up their biome id and blend per
//      the same pair rules the GDScript path used (_blend_params in Ground.gd):
//         path ↔ anything  → sharp 2px Bayer edge,  strength 0.90
//         water ↔ water    → no overlay (biome art already shows ripples)
//         water ↔ land     → soft 6px alpha strip, strength 0.30
//         default land     → wide 8px Bayer edge,  strength 0.85
//   5. Apply a 1-2 px screen-space checkerboard and the per-pixel grain so the
//      result matches the existing ground_noise look.

shader_type canvas_item;

uniform sampler2D atlas        : filter_nearest, source_color;
uniform sampler2D biome_lookup : filter_nearest;
// Per-tile color tint. RG8 texture, both channels centered on 0.5
// (neutral grey 128). R = hue shift (warm vs cool), G = brightness
// shift. Both map to ±20% effect at the channel extremes.
uniform sampler2D tint_lookup  : filter_nearest;
uniform vec2  world_size_tiles = vec2(300.0, 300.0);
uniform float tile_px          = 32.0;
uniform float atlas_rows       = 16.0;

// `draw_rect` without a texture leaves UV undefined, so we carry the canvas-
// local position through as a varying. Ground is parented at world origin so
// local == world; if Ground ever moves, the MODEL_MATRIX product would be
// needed but that's not the case in this project.
varying vec2 world_pos;

// 4x4 ordered (Bayer) dither matrix, values 0..15. Same matrix the CPU
// edge-blend in Ground.gd uses, so the shader path matches pixel-for-pixel
// during the transition.
const float BAYER_M[16] = float[16](
	 0.0,  8.0,  2.0, 10.0,
	12.0,  4.0, 14.0,  6.0,
	 3.0, 11.0,  1.0,  9.0,
	15.0,  7.0, 13.0,  5.0
);

int biome_at(ivec2 t) {
	t = clamp(t, ivec2(0), ivec2(world_size_tiles) - ivec2(1));
	vec2 uv = (vec2(t) + 0.5) / world_size_tiles;
	return int(texture(biome_lookup, uv).r * 255.0 + 0.5);
}

vec4 sample_biome(int b, vec2 local_px) {
	// Atlas is a vertical strip: cell `b` occupies y in [b*tile_px, (b+1)*tile_px).
	vec2 c = vec2(local_px.x, float(b) * tile_px + local_px.y);
	vec2 atlas_uv = c / vec2(tile_px, atlas_rows * tile_px);
	return texture(atlas, atlas_uv);
}

bool is_water(int b) { return b == 8 || b == 9; }    // coast, ocean
bool is_path (int b) { return b == 13 || b == 14; }  // town, road
// Grass-family biomes that get the per-blade detail pass (yellowing, dirt
// patches, pebbles). PLAINS/PLAINS2/forests/swamp — anything where the
// player walks on actual ground vegetation.
bool is_grass(int b) { return b >= 0 && b <= 5; }

// ── Deterministic per-tile hashes ────────────────────────────────────────────
// Three uncorrelated [0,1) values seeded from integer tile coords so a tile's
// look is stable across frames (no shimmer) and across reloads.
vec3 tile_hash3(ivec2 t) {
	vec2 p = vec2(t);
	return vec3(
		fract(sin(dot(p, vec2(12.9898, 78.233)))  * 43758.5453),
		fract(sin(dot(p, vec2(63.7264, 10.873)))  * 21344.3215),
		fract(sin(dot(p, vec2(45.1623, 91.842)))  * 19833.4827)
	);
}
// Sub-tile hash for patch lookups inside a single grass tile. Quantizes the
// sub-tile UV to 8x8 cells so patches read as discrete shapes, not noise.
float subtile_hash(ivec2 t, vec2 sub) {
	vec2 q = vec2(t) + floor(sub * 8.0) * 0.125;
	return fract(sin(dot(q, vec2(31.5, 67.1))) * 12345.6789);
}

// Smooth value noise — bilerp of four corner hashes with a smoothstep on
// the fractional offset. Used for the two scrolling water layers; we feed
// it world coordinates (not local) so flow lines stay continuous across
// tile boundaries.
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = fract(sin(dot(i,             vec2(127.1, 311.7))) * 43758.5453);
	float b = fract(sin(dot(i + vec2(1,0), vec2(127.1, 311.7))) * 43758.5453);
	float c = fract(sin(dot(i + vec2(0,1), vec2(127.1, 311.7))) * 43758.5453);
	float d = fract(sin(dot(i + vec2(1,1), vec2(127.1, 311.7))) * 43758.5453);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float bayer4_at(ivec2 p) {
	int x = p.x & 3;
	int y = p.y & 3;
	return BAYER_M[y * 4 + x] / 16.0;
}

void vertex() {
	world_pos = VERTEX;
}

void fragment() {
	vec2  world_px = world_pos;
	ivec2 tile     = ivec2(floor(world_px / tile_px));
	vec2  local_px = world_px - vec2(tile) * tile_px;

	int  b_self = biome_at(tile);
	vec4 col    = sample_biome(b_self, local_px);

	// Land-direction tracker for the shoreline wave pass. Populated during
	// the existing neighbor loop so we don't pay for a second round of
	// biome_at lookups. `land_dir` is the unnormalized sum of offsets
	// toward each land neighbor; we normalize it once after the loop.
	vec2 land_dir   = vec2(0.0);
	int  land_count = 0;
	// Minimum distance (in px) from this fragment to the nearest tile edge
	// shared with a DIFFERENT biome. Drives the edge-shadow pass after the
	// loop. Seeded high so an interior fragment (no different neighbors)
	// reads "very far from any boundary" and skips the shadow entirely.
	float min_edge_dist = 1000.0;

	// Walk the 4 axis neighbors (top, bottom, left, right).
	for (int i = 0; i < 4; i++) {
		ivec2 off;
		float dist;
		if (i == 0)      { off = ivec2( 0, -1); dist = local_px.y; }
		else if (i == 1) { off = ivec2( 0,  1); dist = tile_px - local_px.y; }
		else if (i == 2) { off = ivec2(-1,  0); dist = local_px.x; }
		else             { off = ivec2( 1,  0); dist = tile_px - local_px.x; }

		int b_n = biome_at(tile + off);
		// Record this neighbor if it's land and we're water — feeds the
		// shoreline wave direction. Free piggyback on the lookup we're
		// already doing.
		if (is_water(b_self) && !is_water(b_n)) {
			land_dir += vec2(off);
			land_count += 1;
		}
		if (b_n == b_self) continue;
		// Track the nearest different-biome edge for the post-loop shadow.
		min_edge_dist = min(min_edge_dist, dist);

		// Pair rule: mirrors _blend_params() in Ground.gd.
		// mode: 0 = none, 1 = soft alpha strip, 2 = Bayer-dithered edge.
		float span_px;
		float strength;
		int   mode;
		if (is_path(b_self) || is_path(b_n)) {
			span_px = 2.0; strength = 0.90; mode = 2;
		} else if (is_water(b_self) && is_water(b_n)) {
			span_px = 0.0; strength = 0.0;  mode = 0;
		} else if (is_water(b_self) != is_water(b_n)) {
			span_px = 6.0; strength = 0.30; mode = 1;
		} else {
			span_px = 8.0; strength = 0.85; mode = 2;
		}

		if (mode == 0 || dist >= span_px) continue;

		// Linear ramp: 1.0 at the tile edge, falling to 0.0 at `span_px`.
		float s = (1.0 - dist / span_px) * strength;

		vec4 nb_col = sample_biome(b_n, local_px);
		if (mode == 2) {
			// Ordered-dither edge: keep the neighbor pixel only where the
			// Bayer threshold is below the local strength. Same look the CPU
			// path produces in _draw_tile's Bayer block.
			float th = bayer4_at(ivec2(floor(world_px)));
			if (th > s) continue;
			col = mix(col, nb_col, 0.95);
		} else {
			// Soft uniform alpha strip — the shoreline look.
			col = mix(col, nb_col, s);
		}
	}

	// ── Per-tile micro-variation ────────────────────────────────────────────
	// Seeded by tile coords so neighboring tiles look distinct but each tile
	// is stable across frames (no shimmer). Three uncorrelated hashes drive
	// brightness, channel-weighted hue shift, and the grass-patch lookup.
	vec3 h3 = tile_hash3(tile);
	float bright_delta = (h3.x - 0.5) * 0.16;         // ±8%
	col.rgb *= 1.0 + bright_delta;
	col.r *= 1.0 + (h3.y - 0.5) * 0.06;               // ±3% per channel
	col.g *= 1.0 + (h3.z - 0.5) * 0.06;               // (functions as a soft hue shift)
	col.b *= 1.0 + ((1.0 - h3.x) - 0.5) * 0.06;       // mild counter-shift on B

	// ── Directional shading (top-down light from upper-left) ────────────────
	// Per-fragment gradient across the tile in BOTH axes. North edge sits
	// darkest, south edge brightest; left edge darker, right edge brighter.
	// Stacks additively into a single multiplicative factor so a fragment
	// near the upper-left corner combines both terms for the deepest
	// shading and lower-right gets the brightest highlight.
	vec2 norm = local_px / tile_px;             // 0..1 within tile
	float y_factor = mix(-0.10, 0.08, norm.y);   // -10% top → +8% bottom
	float x_factor = mix(-0.05, 0.05, norm.x);   // -5% left  → +5% right
	col.rgb *= 1.0 + y_factor + x_factor;

	// ── Biome-boundary shadow ───────────────────────────────────────────────
	// 3 px gradient darkening wherever a tile meets a different biome — sits
	// on top of the existing smooth-blend so transitions get a touch of
	// drop-shadow weight without changing the underlying blend rules.
	if (min_edge_dist < 3.0) {
		float shadow = (1.0 - min_edge_dist / 3.0) * 0.20;
		col.rgb *= 1.0 - shadow;
	}

	// ── Animated water ──────────────────────────────────────────────────────
	// Two layers of scrolling value noise on a slow diagonal and a faster
	// counter-diagonal. Mixing them produces visible flow without the look
	// of a single repeating ripple. World-coordinate input keeps the flow
	// continuous across tile boundaries.
	if (is_water(b_self)) {
		float t = TIME;
		vec2 uv1 = world_px / 80.0 + vec2( t * 0.10,  t * 0.07);  // slow ↘
		vec2 uv2 = world_px / 60.0 + vec2(-t * 0.18, -t * 0.12);  // faster ↖
		float n1 = vnoise(uv1);
		float n2 = vnoise(uv2);
		float flow = (n1 + n2) * 0.5;
		// Use the flow value to drive both a brightness bump (white sparkle
		// where the layers crest) and a slight blue darkening in the troughs.
		col.rgb += (flow - 0.5) * 0.16;

		// Subtle brightness pulse on a 2.5s cycle — sells "light reflecting
		// off moving water" without overpowering the per-pixel flow.
		float pulse = sin(t * (6.28318 / 2.5)) * 0.10;
		col.rgb *= 1.0 + pulse;

		// ── Shoreline wave pass ─────────────────────────────────────────────
		// Only runs on tiles that actually border land. land_dir was filled
		// during the neighbor loop; normalize it to a unit vector pointing
		// toward the nearest land side.
		if (land_count > 0) {
			vec2 wd = normalize(land_dir);
			vec2 luv = local_px / tile_px;            // [0,1] within tile
			// `progress` is the fragment's position along the wave-travel
			// axis: 0 = far side of tile, 1 = land edge.
			float progress = clamp(dot(luv - 0.5, wd) + 0.5, 0.0, 1.0);
			// Three waves on a 3.5s period, phase-offset by 1/3 each so
			// there's always a wave somewhere on the tile. Spatial profile
			// is a sharp bell curve; temporal fade ramps in from invisible
			// at the deep side and peaks near the shore edge.
			float total = 0.0;
			for (int k = 0; k < 3; k++) {
				float phase = float(k) / 3.0;
				float wave_pos = fract((t / 3.5) + phase);
				float d = progress - wave_pos;
				float band = exp(-d * d * 90.0);
				float fade = smoothstep(0.0, 0.7, wave_pos);
				total += band * fade;
			}
			total = clamp(total, 0.0, 1.0);
			col.rgb = mix(col.rgb, vec3(0.95, 0.97, 1.0), total * 0.42);
		}
	}

	// ── Grass blade variation (biomes 0..5) ─────────────────────────────────
	// Per-sub-tile patch selector + per-pixel pebble dots. Makes individual
	// grass tiles look hand-painted rather than tiled.
	if (is_grass(b_self)) {
		vec2 sub_uv = local_px / tile_px;
		float patch_h = subtile_hash(tile, sub_uv);
		if (patch_h > 0.78 && patch_h < 0.90) {
			// Yellowed grass patch.
			col.rgb = mix(col.rgb, vec3(0.82, 0.74, 0.32), 0.28);
		} else if (patch_h >= 0.90 && patch_h < 0.97) {
			// Bare dirt patch.
			col.rgb = mix(col.rgb, vec3(0.42, 0.30, 0.16), 0.45);
		} else if (patch_h >= 0.97) {
			// Darker rich soil pocket.
			col.rgb = mix(col.rgb, vec3(0.20, 0.16, 0.10), 0.35);
		}
		// Sparse pebble dots — quantized to 1-pixel cells so they look like
		// individual stones, not blurry noise.
		float pebble_h = fract(sin(dot(floor(local_px), vec2(94.5, 21.3)))
				* 4567.9012);
		if (pebble_h > 0.985) {
			col.rgb = mix(col.rgb, vec3(0.50, 0.46, 0.40), 0.70);
		}
	}

	// 1-px screen-space checkerboard — micro-dither in screen coords (not tile
	// coords) so it stays crisp regardless of camera zoom.
	vec2  fc  = floor(FRAGCOORD.xy);
	float chk = mod(fc.x + fc.y, 2.0);
	col.rgb += (chk - 0.5) * 0.012;

	// Per-pixel grain — same hash + amplitude as ground_noise.gdshader for a
	// consistent surface look across the project.
	vec2 p = fract(fc * vec2(127.1, 311.7));
	p += vec2(dot(p, p + 45.32));
	float g = (fract(p.x * p.y) - 0.5) * 0.042;
	col.rgb = clamp(col.rgb + g, 0.0, 1.0);

	// Higher-frequency fine grain — second pass at 2× screen rate with a
	// different hash, layered on top of the coarse grain for a finer surface
	// texture without overwhelming the base color.
	vec2 fp = fract(fc * 2.0 * vec2(83.45, 109.7));
	fp += vec2(dot(fp, fp + 23.1));
	float g2 = (fract(fp.x * fp.y) - 0.5) * 0.028;
	col.rgb = clamp(col.rgb + g2, 0.0, 1.0);

	// ── Per-tile admin tint ─────────────────────────────────────────────────
	// Sample the tint lookup at this tile's UV. R is centered at 0.5 with a
	// ±0.5 range meaning ±20% warm/cool shift; G is similarly centered for
	// brightness. Neutral grey (0.5, 0.5) is the default and produces no
	// effect — every tile is grey at startup until an admin paints.
	vec2 tile_uv = (vec2(tile) + 0.5) / world_size_tiles;
	vec2 tint    = texture(tint_lookup, tile_uv).rg;
	float warm   = (tint.r - 0.5) * 0.4;    // ±0.2
	float bright = (tint.g - 0.5) * 0.4;    // ±0.2
	if (abs(warm) > 0.001 || abs(bright) > 0.001) {
		// Warm/cool channel shift — cheap approximation of a hue rotation.
		// Positive `warm` pushes the image toward orange (R up, B down);
		// negative pushes toward teal. Keeps perceived brightness roughly
		// constant by counter-shifting G slightly.
		col.r *= 1.0 + warm * 0.30;
		col.g *= 1.0 + warm * 0.05;
		col.b *= 1.0 - warm * 0.30;
		// Multiplicative brightness shift.
		col.rgb *= 1.0 + bright;
		col.rgb = clamp(col.rgb, 0.0, 1.0);
	}

	COLOR = col;
}
