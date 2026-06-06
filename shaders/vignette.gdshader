// Post-processing vignette. Renders as a fullscreen ColorRect with this
// shader applied as a material. Transparent at the center, darkening
// quadratically toward the corners up to `intensity` alpha. SCREEN_UV is
// already normalized [0,1] across the viewport, so the effect tracks the
// window without needing world coords or aspect correction.

shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.25;
uniform float falloff   : hint_range(1.0, 4.0) = 1.8;

void fragment() {
	vec2 uv = SCREEN_UV - 0.5;
	// Normalize so corners hit 1.0 (length of (0.5, 0.5) = 0.707 → ×1.4142).
	float d = clamp(length(uv) * 1.4142, 0.0, 1.0);
	float v = pow(d, falloff);
	COLOR = vec4(0.0, 0.0, 0.0, v * intensity);
}
