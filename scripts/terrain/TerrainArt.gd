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

## Family 50 water (1.7.6): approved shallow water, caustics, reef/tidepool
## (water50_batch01) and kelp/deep ocean (water50_batch02). Their includes are
## spliced into the generated shaders; every effect defaults OFF there and is
## switched on only here, so --procedural-terrain never loads or binds any of it.
## Game-side wrapper of the approved ocean_surface_3d: identical, except the open
## water keeps the old plane's sRGB colour (see the shader header).
const WATER_OCEAN_3D := "res://shaders/water_plane_3d.gdshader"
const WATER_MAPS := {
	"reef_albedo": _T + "water50_batch01/v001/reef_albedo.png",
	"reef_normal": _T + "water50_batch01/v001/reef_normal.png",
	"reef_params": _T + "water50_batch01/v001/reef_params.png",
	"tidepool_albedo": _T + "water50_batch01/v001/tidepool_albedo.png",
	"tidepool_normal": _T + "water50_batch01/v001/tidepool_normal.png",
	"tidepool_params": _T + "water50_batch01/v001/tidepool_params.png",
	"kelp_fronds": _T + "water50_batch02/v001/kelp_fronds.png",
}
## Biome-lookup samplers + their size uniforms, one pair per water include.
const WATER_LOOKUPS := {
	"water_biomes": "water_map_size", "bottom_biomes": "bottom_map_size",
	"ocean_biomes": "ocean_map_size",
}
const WATER_SWITCHES := ["shallow_enabled", "caustics_enabled", "bottom_enabled", "ocean_enabled"]
const WATER_CLOCKS := ["caustics_clock", "ocean_clock"]
## Animated water loops every 8 s (caustics + kelp sway).
const WATER_LOOP_SEC := 8.0

## One clock for every water material in either view. It is static (survives the
## 2D<->3D scene swap, so the phase carries straight across the toggle) and runs
## on game time (process delta, advanced at most once per frame), so it follows
## pause/time-scale and fixed-fps captures exactly like the legacy water's TIME.
static var _water_t: float = 0.0
static var _water_frame: int = -1

static func water_clock() -> float:
	return _water_t

## Called every frame by the view that owns the material (Ground / World3D).
static func tick_water(mat: Material, delta: float) -> void:
	var frame := Engine.get_process_frames()
	if frame != _water_frame:
		_water_frame = frame
		_water_t = fmod(_water_t + delta, WATER_LOOP_SEC)
	var sm := mat as ShaderMaterial
	if sm == null:
		return
	var t := _water_t
	for c: String in WATER_CLOCKS:
		sm.set_shader_parameter(c, t)

static func _has_uniform(mat: ShaderMaterial, uniform_name: String) -> bool:
	for u: Dictionary in mat.shader.get_shader_uniform_list():
		if str(u["name"]) == uniform_name:
			return true
	return false

## Binds whatever water uniforms this shader declares (2D ground, 3D seabed or
## the 3D water plane each include a different subset).
static func _bind_water(mat: ShaderMaterial, biome_lookup: Texture2D) -> void:
	var size := Vector2(biome_lookup.get_width(), biome_lookup.get_height())
	for sampler: String in WATER_LOOKUPS.keys():
		if _has_uniform(mat, sampler):
			mat.set_shader_parameter(sampler, biome_lookup)
			mat.set_shader_parameter(str(WATER_LOOKUPS[sampler]), size)
	for name: String in WATER_MAPS.keys():
		if _has_uniform(mat, name):
			if not _maps.has(name):
				_maps[name] = load(str(WATER_MAPS[name])) as Texture2D
			mat.set_shader_parameter(name, _maps[name])
	if _has_uniform(mat, "shallow_sand"):
		mat.set_shader_parameter("shallow_sand", _maps["sand_albedo"])
	for sw: String in WATER_SWITCHES:
		if _has_uniform(mat, sw):
			mat.set_shader_parameter(sw, true)

## 3D water plane: same base look as the old StandardMaterial3D (albedo
## 0.18/0.42/0.66, alpha 0.66, roughness 0.12) plus kelp/deep ocean + caustics.
static func water_material_3d(biome_lookup: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(WATER_OCEAN_3D) as Shader
	_texture_params()
	_bind_water(mat, biome_lookup)
	return mat

static func _bind_common(mat: ShaderMaterial, biome_lookup: Texture2D, heights: Texture2D) -> void:
	for name: String in _texture_params().keys():
		if name in WATER_MAPS:
			continue
		mat.set_shader_parameter(name, _maps[name])
	_bind_water(mat, biome_lookup)
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
	# Shallow water keeps the admin tint layer the old ground already uses.
	mat.set_shader_parameter("shallow_tints", old.get_shader_parameter("tint_lookup"))
	return mat

## 3D chunk material: vertex colours stay the base under the authored surface.
static func material_3d(biome_lookup: Texture2D, tint_lookup: Texture2D, heights: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_3D) as Shader
	_bind_common(mat, biome_lookup, heights)
	mat.set_shader_parameter("sample_tints", tint_lookup)
	return mat
