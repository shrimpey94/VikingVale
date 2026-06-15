extends RefCounted
class_name TerrainBaker

## Builds a 300×300 passability bitmap by sampling Ground.biome_at_world
## for every tile in the world, then base64-encodes it for upload via
## NetworkManager.send_admin_upload_terrain.
##
## Format the server expects (see server/terrain.py):
##   GRID_W × GRID_H bits, row-major, MSB-first in each byte
##   bit=1 → passable
##   "ocean" and "coast" biomes are impassable; everything else is passable.

const GRID_W := 300
const GRID_H := 300
const TILE   := 32

## Synchronously walk every tile and bake the bitmap. Returns the
## base64-encoded payload ready for the server. Takes a fraction of a
## second on a desktop — bake is a one-time admin operation.
static func bake(ground: Node) -> String:
	if ground == null or not ground.has_method("biome_at_world"):
		return ""
	var n_bits := GRID_W * GRID_H
	var n_bytes := (n_bits + 7) / 8
	var data := PackedByteArray()
	data.resize(n_bytes)
	for ty: int in range(GRID_H):
		for tx: int in range(GRID_W):
			# Sample at tile center so we catch the actual biome rather
			# than the edge of a transition.
			var wx := float(tx) * float(TILE) + float(TILE) * 0.5
			var wy := float(ty) * float(TILE) + float(TILE) * 0.5
			var biome: String = ground.call("biome_at_world",
				Vector2(wx, wy)) as String
			var passable: bool = biome != "ocean" and biome != "coast"
			if passable:
				var bit_index := ty * GRID_W + tx
				var byte_index := bit_index / 8
				var bit_offset := 7 - (bit_index % 8)
				data[byte_index] = data[byte_index] | (1 << bit_offset)
	return Marshalls.raw_to_base64(data)
