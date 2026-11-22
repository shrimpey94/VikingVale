extends RefCounted
## Authored terrain (families 48 + 49) for the 2D and 3D ground (1.7.6).
##
## Visual only and reversible:
##   --procedural-terrain   restores today's ground in BOTH views exactly: the old
##                          shaders, old bridges, and NO authored texture or height
##                          lookup allocations.
## Tile ids, passability, collision, picking and the server are untouched. The
## authored layer reads the same biome lookup / tint lookup textures the old
## ground already keeps up to date, plus one shared corner-height texture
## (TerrainHeights) so height drives colour identically in 2D and 3D.
##
## Runtime shaders are GENERATED from the art-side cumulative shaders by
## tools/art/build_terrain_runtime_shaders.py (only bridges are held back, see
## there). Paths and ids are constants here; nothing reads JSON at runtime.

const FLAG := "--procedural-terrain"

const SHADER_2D := "res://shaders/terrain_authored_2d.gdshader"
const SHADER_2D_SMOOTH := "res://shaders/terrain_authored_2d_smooth.gdshader"
const SHADER_3D := "res://shaders/terrain_authored_3d.gdshader"

const _T := "res://assets/authored/terrain/"
## Material set -> folder. Each set is <kind>_albedo/_normal/_orm.png (BC7, mipmapped).
const SETS := {
	"grass": _T + "grass_forest/v002/", "forest": _T + "grass_forest/v002/",
	"pine": _T + "natural_batch01/v001/", "plains": _T + "natural_batch01/v001/",
	"snow": _T + "natural_batch01/v001/",
	"ash": _T + "natural_batch02/v001/", "helheim": _T + "natural_batch02/v001/",
	"rocky": _T + "natural_batch03/v001/", "mountain": _T + "natural_batch03/v001/",
	"cliff": _T + "natural_batch03/v001/",
	"swamp": _T + "natural_batch04/v001/", "sand": _T + "natural_batch04/v001/",
	"town": _T + "surface49_batch01/v002/", "road": _T + "surface49_batch01/v002/",
	"timber": _T + "surface49_batch02/v001/", "flagstone": _T + "surface49_batch02/v001/",
	"weave": _T + "surface49_batch02/v001/",
}
const CHANNELS := ["albedo", "normal", "orm"]

## Loaded maps, kept alive for the session once either view has used them (the
## 2D<->3D toggle swaps scenes; holding them avoids a reload + re-upload).
static var _maps: Dictionary = {}

static func enabled() -> bool:
	return not (FLAG in OS.get_cmdline_user_args())

static func _texture_params() -> Dictionary:
	if _maps.is_empty():
		for kind: String in SETS.keys():
			for ch: String in CHANNELS:
				var name := "%s_%s" % [kind, ch]
				_maps[name] = load(str(SETS[kind]) + name + ".png") as Texture2D
	return _maps

static func _bind_common(mat: ShaderMaterial, biome_lookup: Texture2D, heights: Texture2D) -> void:
	for name: String in _texture_params().keys():
		mat.set_shader_parameter(name, _maps[name])
	mat.set_shader_parameter("sample_biomes", biome_lookup)
	mat.set_shader_parameter("sample_map_size", Vector2(biome_lookup.get_width(), biome_lookup.get_height()))
	mat.set_shader_parameter("terrain_height_corners", heights)
	mat.set_shader_parameter("terrain_height_grid_size", Vector2(heights.get_width(), heights.get_height()))
	mat.set_shader_parameter("height_colors_enabled", true)

## 2D ground material: copies every parameter of the old crisp/smooth material
## (atlas, lookups, sizes), then adds the authored maps and the height lookup.
static func material_2d(old: ShaderMaterial, smooth: bool, biome_lookup: Texture2D, heights: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_2D_SMOOTH if smooth else SHADER_2D) as Shader
	for u: Dictionary in old.shader.get_shader_uniform_list():
		var n := str(u["name"])
		mat.set_shader_parameter(n, old.get_shader_parameter(n))
	_bind_common(mat, biome_lookup, heights)
	return mat

## 3D chunk material: vertex colours stay the base under the authored surface.
static func material_3d(biome_lookup: Texture2D, tint_lookup: Texture2D, heights: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_3D) as Shader
	_bind_common(mat, biome_lookup, heights)
	mat.set_shader_parameter("sample_tints", tint_lookup)
	return mat
