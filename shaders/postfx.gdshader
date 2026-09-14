shader_type canvas_item;
render_mode blend_mix, unshaded;

// Full-screen grade applied over the 3D viewport: vignette, a soft warm/cool
// split between highlights and shadows, and a very small amount of animated
// grain. A single transparent quad in a CanvasLayer -- no screen reads, so it
// works on Godot's mobile renderer where post-process effects do not.

uniform float vignette_strength : hint_range(0.0, 1.5) = 0.55;
uniform float vignette_radius : hint_range(0.2, 1.5) = 0.82;
uniform float grain_strength : hint_range(0.0, 0.15) = 0.018;
uniform vec4 shadow_tint : source_color = vec4(0.16, 0.22, 0.38, 1.0);
uniform float shadow_tint_amount : hint_range(0.0, 1.0) = 0.16;
uniform float night_boost : hint_range(0.0, 2.0) = 0.7;

global uniform float redline_night;
global uniform float redline_wetness;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = (uv - 0.5) * vec2(1.0, 0.92);
	float r = length(d) / vignette_radius;
	float night = clamp(redline_night, 0.0, 1.0);
	float vig = smoothstep(0.55, 1.25, r)
		* (vignette_strength + night * night_boost + redline_wetness * 0.12);

	float grain = (hash12(uv * vec2(1920.0, 1080.0) + fract(TIME) * 91.7) - 0.5);

	// Darken the corners and cool the shadows. Multiplying down is safe with
	// blend_mix because the layer is transparent everywhere it does nothing.
	vec3 tint = shadow_tint.rgb * shadow_tint_amount * vig;
	COLOR.rgb = tint;
	COLOR.a = clamp(vig, 0.0, 0.94);
	COLOR.rgb += grain * grain_strength;
}
