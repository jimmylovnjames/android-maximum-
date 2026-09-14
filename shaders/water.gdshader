shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx, depth_draw_always;

// Deliberately screen-space free: the Godot mobile renderer cannot read the
// screen or depth buffer, so this is Gerstner-ish vertex motion plus a
// normal-map scroll and a fresnel alpha ramp.

uniform sampler2D wave_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 shallow_color : source_color = vec4(0.14, 0.34, 0.36, 0.72);
uniform vec4 deep_color : source_color = vec4(0.02, 0.08, 0.14, 0.96);
uniform float wave_height = 0.28;
uniform float wave_scale = 0.05;
uniform float scroll_speed = 0.045;
uniform float fresnel_power = 4.0;
uniform float normal_strength = 0.55;

global uniform float redline_wind;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = 0.35 + redline_wind;
	float t = TIME * 0.6;
	float h = sin(v_world.x * 0.11 + t) * 0.5
		+ sin(v_world.z * 0.147 - t * 1.23) * 0.35
		+ sin((v_world.x + v_world.z) * 0.071 + t * 0.7) * 0.3;
	VERTEX.y += h * wave_height * w;
}

void fragment() {
	vec2 uv1 = v_world.xz * wave_scale + vec2(TIME * scroll_speed, TIME * scroll_speed * 0.6);
	vec2 uv2 = v_world.xz * wave_scale * 1.9 - vec2(TIME * scroll_speed * 0.8, 0.0);
	vec3 n1 = texture(wave_normal, uv1).xyz * 2.0 - 1.0;
	vec3 n2 = texture(wave_normal, uv2).xyz * 2.0 - 1.0;
	vec3 n = normalize(mix(n1, n2, 0.5));
	NORMAL_MAP = n * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength * (0.5 + redline_wind);

	float fres = pow(1.0 - clamp(dot(normalize(VIEW), NORMAL), 0.0, 1.0), fresnel_power);
	ALBEDO = mix(deep_color.rgb, shallow_color.rgb, fres);
	ALPHA = mix(deep_color.a, shallow_color.a, fres * 0.6);
	ROUGHNESS = 0.06;
	METALLIC = 0.1;
	SPECULAR = 0.9;
}
