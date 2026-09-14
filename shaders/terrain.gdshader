shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Terrain surface. Biome tint arrives per-vertex from the generator (COLOR),
// slope selects rock, height selects sand/snow. Two detail samples at
// different scales break up tiling without costing screen-space effects the
// Godot mobile renderer cannot run.

uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 rock_color : source_color = vec4(0.32, 0.30, 0.29, 1.0);
uniform vec4 sand_color : source_color = vec4(0.62, 0.56, 0.40, 1.0);
uniform vec4 wet_color : source_color = vec4(0.20, 0.22, 0.20, 1.0);
uniform float detail_scale = 0.18;
uniform float macro_scale = 0.012;
uniform float rock_slope = 0.62;
uniform float rock_blend = 0.18;
uniform float water_level = -6.0;
uniform float roughness_base = 0.94;
uniform float detail_strength = 0.45;

global uniform float redline_wetness;

varying vec3 v_world;
varying float v_slope;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_slope = 1.0 - clamp(wn.y, 0.0, 1.0);
}

void fragment() {
	vec2 duv = v_world.xz * detail_scale;
	vec2 muv = v_world.xz * macro_scale;

	vec3 detail = texture(detail_tex, duv).rgb;
	vec3 macro = texture(macro_tex, muv).rgb;

	vec3 base = COLOR.rgb;
	// Macro noise gently varies the biome tint so large areas are not flat.
	base *= mix(0.82, 1.18, macro.r);
	// Detail noise adds close-range break-up.
	base *= mix(1.0 - detail_strength, 1.0 + detail_strength, detail.g);

	float rock_mask = smoothstep(rock_slope - rock_blend, rock_slope + rock_blend, v_slope);
	rock_mask = clamp(rock_mask + (detail.b - 0.5) * 0.25, 0.0, 1.0);
	base = mix(base, rock_color.rgb * mix(0.8, 1.2, detail.r), rock_mask);

	float shore = 1.0 - smoothstep(water_level, water_level + 3.5, v_world.y);
	base = mix(base, sand_color.rgb, shore * 0.75);

	// Rain darkens and slickens the ground.
	float wet = clamp(redline_wetness, 0.0, 1.0);
	base = mix(base, base * 0.55 + wet_color.rgb * 0.25, wet * 0.7);

	ALBEDO = base;
	ROUGHNESS = mix(roughness_base, 0.28, wet * 0.8) * mix(1.0, 0.82, rock_mask);
	SPECULAR = mix(0.18, 0.45, wet);
	METALLIC = 0.0;
}
