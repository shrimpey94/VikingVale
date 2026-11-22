extends RefCounted
## One terrain height field for BOTH renderers (1.7.6).
##
## The 3D client has always built its ground from per-tile biome heights plus the
## server's admin sculpt deltas, box-blurred and averaged into corner heights.
## That code lives here now so the 2D client can build the SAME corner field
## without instantiating the 3D world, and the authored terrain shaders in both
## views colour by the same heights (owner rule: height drives colour, low = biome
## colour, higher = greyer/bluer).
##
## Visual only: nothing here touches tile ids, passability, collision or the
## server. World3D keeps using these numbers for its mesh exactly as before.

const MAP_N := 300            # height extent (the 3D world's 300x300 tiles)
const N1 := MAP_N + 1         # corner grid side (301)
const SMOOTH_ITERS := 4

## Base height (metres) of a biome, by name. Unchanged from World3D 1.7.5.
static func biome_height(nm: String) -> float:
	if "mountain" in nm or "cliff" in nm or "granite" in nm or "alpine" in nm or "scree" in nm: return 13.0
	# Hills ARE mountains (owner call 2026-09-25) — same height as a peak, so a painted
	# hill region (e.g. the whole Ashlands) reads as real elevation in the 3D client.
	if "_hills" in nm or "mound" in nm or "dune" in nm: return 13.0
	if "rocky" in nm or "basalt" in nm or "obsidian" in nm: return 6.0
	if "ocean" in nm: return -5.0
	if "coast" in nm or "shallow" in nm or "reef" in nm or "tidepool" in nm or "kelp" in nm or "wet_sand" in nm or "lily" in nm: return -2.0
	return 0.0

## Per-tile base heights for the 300x300 height extent, read from a Ground node
## (its `_biome_at(tx, ty)` already includes admin paints once they've arrived).
static func base_heights(ground: Object) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(MAP_N * MAP_N)
	for ty in range(MAP_N):
		for tx in range(MAP_N):
			h[ty * MAP_N + tx] = biome_height(str(ground.call("_biome_at", tx, ty)))
	return h

## Box-blur the tile height field `iters` times (self + 4 neighbours) so hard
## biome height jumps round out. Admin sculpt deltas (tile idx -> metres) are
## layered on the biome base BEFORE blurring. Identical to World3D 1.7.5.
static func smoothed_heights(tile_h: PackedFloat32Array, h_delta: Dictionary, iters: int) -> PackedFloat32Array:
	var h := tile_h.duplicate()
	for idx: Variant in h_delta.keys():
		var i := int(idx)
		if i >= 0 and i < h.size():
			h[i] += float(h_delta[idx])
	for _p in range(iters):
		var out := h.duplicate()
		for ty in range(MAP_N):
			for tx in range(MAP_N):
				var i := ty * MAP_N + tx
				var s := h[i]
				var c := 1.0
				if tx > 0:
					s += h[i - 1]; c += 1.0
				if tx < MAP_N - 1:
					s += h[i + 1]; c += 1.0
				if ty > 0:
					s += h[i - MAP_N]; c += 1.0
				if ty < MAP_N - 1:
					s += h[i + MAP_N]; c += 1.0
				out[i] = s / c
		h = out
	return h

## Final corner heights (N1 x N1, metres): each corner is the average of the 4
## surrounding SMOOTHED tiles (off-map tiles count as 0). Identical to World3D 1.7.5.
static func corners(tile_h: PackedFloat32Array, h_delta: Dictionary) -> PackedFloat32Array:
	var sm := smoothed_heights(tile_h, h_delta, SMOOTH_ITERS)
	var out := PackedFloat32Array()
	out.resize(N1 * N1)
	for cy in range(N1):
		for cx in range(N1):
			var sum := 0.0
			var cnt := 0
			for oy: int in [-1, 0]:
				for ox: int in [-1, 0]:
					var tx := cx + ox
					var ty := cy + oy
					if tx >= 0 and tx < MAP_N and ty >= 0 and ty < MAP_N:
						sum += sm[ty * MAP_N + tx]
					cnt += 1
			out[cy * N1 + cx] = sum / float(cnt)
	return out

## Sculpt deltas as the server sends them (idx string -> metres) -> idx int -> metres.
static func deltas_from_server(tiles: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in tiles.keys():
		var d := float(tiles[k])
		if absf(d) >= 0.0001:
			out[int(str(k))] = d
	return out

## R32F corner texture for the authored shaders (linear filtering, no mipmaps,
## sampled at (metres + 0.5) / 301). Pass `tex` to update an existing texture
## in place (same size), so the materials keep their binding.
static func corner_texture(corner: PackedFloat32Array, tex: ImageTexture = null) -> ImageTexture:
	var img := Image.create_from_data(N1, N1, false, Image.FORMAT_RF, corner.to_byte_array())
	if tex == null:
		return ImageTexture.create_from_image(img)
	tex.update(img)
	return tex
