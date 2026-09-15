shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// One MultiMesh draw call renders every floor module in a district. The window
// grid is generated from the instance's world-space scale so modules of
// different sizes still line up, and the lit-window pattern is stable per
// instance (derived from INSTANCE_CUSTOM) instead of flickering per frame.

uniform sampler2D wall_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float window_w = 1.35;
uniform float window_h = 1.7;
uniform float window_fill = 0.46;
uniform vec4 window_day : source_color = vec4(0.11, 0.14, 0.17, 1.0);
uniform vec4 window_lit : source_color = vec4(1.0, 0.82, 0.52, 1.0);
uniform float emission_energy = 1.85;
uniform float lit_fraction : hint_range(0.0, 1.0) = 0.38;
uniform float wall_roughness = 0.82;

global uniform float redline_night;
global uniform float redline_wetness;

varying vec2 v_facade_uv;
varying float v_is_wall;
varying float v_seed;
varying vec3 v_wnormal;

void vertex() {
	vec3 sx = MODEL_MATRIX[0].xyz;
	vec3 sy = MODEL_MATRIX[1].xyz;
	vec3 sz = MODEL_MATRIX[2].xyz;
	float w = length(sx);
	float h = length(sy);
	float d = length(sz);

	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_is_wall = 1.0 - step(0.72, abs(NORMAL.y));

	// Pick the horizontal extent that matches the face we are on.
	float horiz = mix(w, d, step(0.5, abs(NORMAL.x)));
	v_facade_uv = vec2(UV.x * horiz, UV.y * h);
	v_seed = INSTANCE_CUSTOM.x;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec3 wall = texture(wall_tex, v_facade_uv * 0.25).rgb;
	vec3 base = COLOR.rgb * mix(0.8, 1.15, wall.r);

	vec2 cell = vec2(v_facade_uv.x / window_w, v_facade_uv.y / window_h);
	vec2 cid = floor(cell);
	vec2 f = fract(cell);
	float half_fill = window_fill * 0.5;
	float inw = step(0.5 - half_fill, f.x) * step(f.x, 0.5 + half_fill)
		* step(0.5 - half_fill * 1.15, f.y) * step(f.y, 0.5 + half_fill * 1.15);
	inw *= v_is_wall;

	float r = hash21(cid + vec2(v_seed * 97.0, v_seed * 37.0));
	float lit = step(1.0 - lit_fraction, r) * clamp(redline_night, 0.0, 1.0);

	// Horizontal spandrel band between floors so storeys read at distance even
	// when the window grid itself is too small to resolve.
	float band = smoothstep(0.06, 0.0, abs(f.y - 0.02)) * v_is_wall;
	base *= mix(1.0, 0.82, band);

	vec3 glass = mix(window_day.rgb, window_lit.rgb, lit);
	// Daylight glass picks up a little of the sky rather than reading as a
	// hole punched through the facade.
	float sky_bounce = 1.0 - clamp(redline_night, 0.0, 1.0);
	glass = mix(glass, glass + vec3(0.05, 0.07, 0.11) * (0.5 + r), sky_bounce);
	ALBEDO = mix(base, glass, inw);
	EMISSION = window_lit.rgb * (inw * lit * emission_energy * (0.55 + 0.45 * r));
	ROUGHNESS = mix(wall_roughness, 0.08, inw);
	METALLIC = mix(0.0, 0.55, inw);
	SPECULAR = mix(0.3, 0.85, inw);

	float wet = clamp(redline_wetness, 0.0, 1.0);
	ROUGHNESS *= mix(1.0, 0.6, wet);
}
