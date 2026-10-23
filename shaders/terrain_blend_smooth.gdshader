// terrain_blend_smooth.gdshader
// "Civ IV" painterly variant of terrain_blend.gdshader. Same biome-lookup +
// atlas pipeline, but:
//   • atlas sampled with filter_linear (bilinear) instead of nearest
//   • atlas cells baked at atlas_cell_px (128) so there's real per-biome detail
//   • biome borders MELT via a noise-warped smooth alpha ramp instead of the
//     Bayer ordered dither — organic wavy transitions, no visible grid
//   • the in-cell sample position is domain-warped by low-freq world noise so
//     the 128px texture doesn't visibly repeat
//   • directional shading is world-space (large-scale undulation) instead of a
//     per-tile gradient that would re-draw the grid
//   • the per-tile boundary drop-shadow + screen checkerboard are dropped
// biome_lookup + tint_lookup STAY filter_nearest — linear on the lookup would
// interpolate biome *ids* into garbage biomes.

shader_type canvas_item;

uniform sampler2D atlas        : filter_linear, source_color;
uniform sampler2D biome_lookup : filter_nearest;
uniform sampler2D tint_lookup  : filter_nearest;
uniform vec2  world_size_tiles = vec2(300.0, 300.0);
uniform float tile_px          = 32.0;    // world-space tile size (unchanged)
uniform float atlas_rows       = 16.0;
uniform float atlas_cell_px    = 128.0;   // atlas cell resolution (decoupled)

varying vec2 world_pos;

int biome_at(ivec2 t) {
	t = clamp(t, ivec2(0), ivec2(world_size_tiles) - ivec2(1));
	vec2 uv = (vec2(t) + 0.5) / world_size_tiles;
	return int(texture(biome_lookup, uv).r * 255.0 + 0.5);
}

// Sample biome `b` at `local_px` (world-tile-local, 0..tile_px). Maps into the
// atlas cell with a half-texel inset so bilinear taps never bleed into the
// vertically-adjacent biome cell.
vec4 sample_biome(int b, vec2 local_px) {
	vec2 norm = local_px / tile_px;              // 0..1 within the world tile
	float inset = 0.5 / atlas_cell_px;           // half a texel in cell space
	norm = clamp(norm, vec2(inset), vec2(1.0 - inset));
	vec2 atlas_uv = vec2(norm.x, (float(b) + norm.y) / atlas_rows);
	return texture(atlas, atlas_uv);
}

// coast, ocean, shallow_water, reef, tidepool, ocean_kelp, ocean_deep
bool is_water(int b) { return b == 8 || b == 9 || b == 24 || b == 44 || b == 45 || b == 57 || b == 58; }
bool is_path (int b) { return b == 13 || b == 14; }  // town, road
bool is_grass(int b) { return (b >= 0 && b <= 5) || (b >= 26 && b <= 36) || (b >= 50 && b <= 56); }

vec3 tile_hash3(ivec2 t) {
	vec2 p = vec2(t);
	return vec3(
		fract(sin(dot(p, vec2(12.9898, 78.233)))  * 43758.5453),
		fract(sin(dot(p, vec2(63.7264, 10.873)))  * 21344.3215),
		fract(sin(dot(p, vec2(45.1623, 91.842)))  * 19833.4827)
	);
}
float subtile_hash(ivec2 t, vec2 sub) {
	vec2 q = vec2(t) + floor(sub * 8.0) * 0.125;
	return fract(sin(dot(q, vec2(31.5, 67.1))) * 12345.6789);
}

// Smooth value noise — bilerp of four corner hashes with a smoothstep on the
// fractional offset. World-coordinate input keeps everything continuous
// across tile boundaries (no seams in the melt / warp / water).
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

void vertex() {
	world_pos = VERTEX;
}

void fragment() {
	vec2  world_px = world_pos;
	ivec2 tile     = ivec2(floor(world_px / tile_px));
	vec2  local_px = world_px - vec2(tile) * tile_px;

	// Domain warp — break the obvious per-tile texture repeat by nudging the
	// in-cell sample position with a low-frequency world-space noise. Kept
	// small (±3 px) so the biome still reads as itself.
	vec2 warp = vec2(vnoise(world_px * 0.02),
	                 vnoise(world_px * 0.02 + vec2(50.0))) - 0.5;
	vec2 local_s = local_px + warp * 6.0;

	int  b_self = biome_at(tile);
	vec4 col    = sample_biome(b_self, local_s);

	// Land-direction tracker for the shoreline wave pass (unchanged).
	vec2 land_dir   = vec2(0.0);
	int  land_count = 0;

	// Walk the 4 axis neighbors — MELT each different-biome edge with a
	// noise-warped smooth alpha ramp. No dithering.
	for (int i = 0; i < 4; i++) {
		ivec2 off;
		float dist;
		if (i == 0)      { off = ivec2( 0, -1); dist = local_px.y; }
		else if (i == 1) { off = ivec2( 0,  1); dist = tile_px - local_px.y; }
		else if (i == 2) { off = ivec2(-1,  0); dist = local_px.x; }
		else             { off = ivec2( 1,  0); dist = tile_px - local_px.x; }

		int b_n = biome_at(tile + off);
		if (is_water(b_self) && !is_water(b_n)) {
			land_dir += vec2(off);
			land_count += 1;
		}
		if (b_n == b_self) continue;

		// Pair rules — melt widths + strengths. Water↔water never overlays.
		float span_px; float strength; float warp_amp;
		if (is_path(b_self) || is_path(b_n)) {
			// Roads/paths stay comparatively defined — narrow melt.
			span_px = 6.0; strength = 0.60; warp_amp = 3.0;
		} else if (is_water(b_self) && is_water(b_n)) {
			span_px = 0.0; strength = 0.0; warp_amp = 0.0;
		} else if (is_water(b_self) != is_water(b_n)) {
			// Shoreline — soft, wide.
			span_px = 16.0; strength = 0.40; warp_amp = 8.0;
		} else {
			// Land ↔ land — the big painterly melt. 0.5 strength so both
			// sides meet at a clean 50/50 along the wavy boundary.
			span_px = 22.0; strength = 0.50; warp_amp = 12.0;
		}
		if (span_px <= 0.0) continue;

		// Warp the edge distance with low-freq world noise so the transition
		// line meanders organically instead of following the straight tile
		// edge. Then a smoothstep alpha ramp: 1 at the (warped) edge → 0 at
		// span distance, scaled by strength.
		float edge_noise = (vnoise(world_px * 0.06) - 0.5) * warp_amp;
		float d_warp = dist + edge_noise;
		if (d_warp >= span_px) continue;
		float s = smoothstep(span_px, 0.0, d_warp) * strength;
		vec4 nb_col = sample_biome(b_n, local_s);
		col = mix(col, nb_col, clamp(s, 0.0, 1.0));
	}

	// ── Per-tile micro-variation (subtle; keeps biomes from looking flat) ────
	vec3 h3 = tile_hash3(tile);
	col.rgb *= 1.0 + (h3.x - 0.5) * 0.10;              // ±5% brightness
	col.r *= 1.0 + (h3.y - 0.5) * 0.04;
	col.g *= 1.0 + (h3.z - 0.5) * 0.04;

	// ── World-space soft shading ─────────────────────────────────────────────
	// Large-scale brightness undulation across the world instead of a per-tile
	// gradient (which would re-draw the grid). Very low frequency.
	float shade = (vnoise(world_px * 0.008) - 0.5) * 0.14;
	col.rgb *= 1.0 + shade;

	// ── Animated water (unchanged) ───────────────────────────────────────────
	if (is_water(b_self)) {
		float t = TIME;
		vec2 uv1 = world_px / 80.0 + vec2( t * 0.10,  t * 0.07);
		vec2 uv2 = world_px / 60.0 + vec2(-t * 0.18, -t * 0.12);
		float flow = (vnoise(uv1) + vnoise(uv2)) * 0.5;
		col.rgb += (flow - 0.5) * 0.16;
		float pulse = sin(t * (6.28318 / 2.5)) * 0.10;
		col.rgb *= 1.0 + pulse;

		if (land_count > 0) {
			vec2 wd = normalize(land_dir);
			vec2 luv = local_px / tile_px;
			float progress = clamp(dot(luv - 0.5, wd) + 0.5, 0.0, 1.0);
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

	// ── Grass patch variation (soft; no 1px pebble dither in smooth mode) ────
	if (is_grass(b_self)) {
		vec2 sub_uv = local_px / tile_px;
		float patch_h = subtile_hash(tile, sub_uv);
		if (patch_h > 0.78 && patch_h < 0.90) {
			col.rgb = mix(col.rgb, vec3(0.82, 0.74, 0.32), 0.22);
		} else if (patch_h >= 0.90 && patch_h < 0.97) {
			col.rgb = mix(col.rgb, vec3(0.42, 0.30, 0.16), 0.35);
		} else if (patch_h >= 0.97) {
			col.rgb = mix(col.rgb, vec3(0.20, 0.16, 0.10), 0.28);
		}
	}

	// ── Fine grain — soft surface texture, no screen checkerboard ────────────
	vec2  fc = floor(FRAGCOORD.xy);
	vec2 p = fract(fc * vec2(127.1, 311.7));
	p += vec2(dot(p, p + 45.32));
	float g = (fract(p.x * p.y) - 0.5) * 0.030;
	col.rgb = clamp(col.rgb + g, 0.0, 1.0);

	// ── Per-tile admin tint (unchanged) ──────────────────────────────────────
	vec2 tile_uv = (vec2(tile) + 0.5) / world_size_tiles;
	vec2 tint    = texture(tint_lookup, tile_uv).rg;
	float warm   = (tint.r - 0.5) * 0.4;
	float bright = (tint.g - 0.5) * 0.4;
	if (abs(warm) > 0.001 || abs(bright) > 0.001) {
		col.r *= 1.0 + warm * 0.30;
		col.g *= 1.0 + warm * 0.05;
		col.b *= 1.0 - warm * 0.30;
		col.rgb *= 1.0 + bright;
		col.rgb = clamp(col.rgb, 0.0, 1.0);
	}

	COLOR = col;
}
