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

	// Walk the 4 axis neighbors (top, bottom, left, right).
	for (int i = 0; i < 4; i++) {
		ivec2 off;
		float dist;
		if (i == 0)      { off = ivec2( 0, -1); dist = local_px.y; }
		else if (i == 1) { off = ivec2( 0,  1); dist = tile_px - local_px.y; }
		else if (i == 2) { off = ivec2(-1,  0); dist = local_px.x; }
		else             { off = ivec2( 1,  0); dist = tile_px - local_px.x; }

		int b_n = biome_at(tile + off);
		if (b_n == b_self) continue;

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

	COLOR = col;
}
