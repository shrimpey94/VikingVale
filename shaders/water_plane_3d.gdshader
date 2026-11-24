// 1.7.6 3D water plane (family 50): kelp/deep ocean + caustics on the existing
// plane. Same as the approved water50_batch02 v001 review shader ocean_surface_3d
// (not shipped; its includes are used unchanged) EXCEPT the open-water base colour: the old
// StandardMaterial3D's albedo_color (0.18, 0.42, 0.66) is an sRGB colour, so it
// is converted here; open water keeps exactly its pre-1.7.6 colour/alpha/roughness.
shader_type spatial;
render_mode blend_mix;
#include "res://assets/authored/terrain/water_caustics/v001/caustics.gdshaderinc"
#include "res://assets/authored/terrain/water50_batch02/v001/ocean_surface.gdshaderinc"
const vec3 OPEN_WATER_SRGB = vec3(0.18, 0.42, 0.66);
vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
varying vec2 ocean_world;
void vertex() { ocean_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz; }
void fragment() {
	vec3 c; float w; float a;
	ocean_surface(ocean_world, c, w, a);
	ALBEDO = mix(srgb_to_linear(OPEN_WATER_SRGB), c, w);
	ALPHA = mix(0.66, a, w);
	ROUGHNESS = 0.12;
	AO = 1.0;
	EMISSION = vec3(0.67, 0.91, 1.0) * water_glints(ocean_world);
}
