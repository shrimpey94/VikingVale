shader_type canvas_item;

float _h(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	// Multiply vertex color by the primitive's texture (white for untextured draws)
	COLOR *= texture(TEXTURE, UV);
	// Per screen-pixel grain — stays crisp regardless of camera zoom
	float g = (_h(floor(FRAGCOORD.xy)) - 0.5) * 0.042;
	COLOR.rgb = clamp(COLOR.rgb + g, 0.0, 1.0);
}
