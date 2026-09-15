shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Terrain surface. Biome tint arrives per-vertex from the generator (COLOR),
// slope selects rock, height selects sand/snow. Two detail samples at
// different scales break up tiling without costing screen-space effects the
// Godot mobile renderer cannot run.

uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 rock_color : source_color = vec4(0.32, 0.30, 0.29, 1.0);
uniform vec4 sand_color : source_color = vec4(0.62, 0.56, 0.40, 1.0);
uniform vec4 wet_color : source_color = vec4(0.20, 0.22, 0.20, 1.0);
uniform float detail_scale = 0.18;
uniform float macro_scale = 0.012;
uniform float rock_slope = 0.62;
uniform float rock_blend = 0.18;
uniform float water_level = -6.0;
uniform vec4 foam_color : source_color = vec4(0.82, 0.86, 0.88, 1.0);
uniform float foam_width = 0.9;
uniform sampler2D foam_noise : source_color, filter_linear_mipmap, repeat_enable;
uniform float roughness_base = 0.94;
uniform float detail_strength = 0.36;
uniform float normal_strength = 0.85;
uniform float macro_variation = 0.42;

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
	// COLOR.a is how built-up this vertex is. Organic hue variation is for
	// soil and grass; concrete and asphalt only get brightness variation.
	float organic = 1.0 - COLOR.a;
	float m = macro.r;
	base *= mix(1.0 - macro_variation * mix(0.45, 1.0, organic),
		1.0 + macro_variation * 0.75 * mix(0.45, 1.0, organic), m);
	base = mix(base, base * vec3(1.25, 1.05, 0.7),
		clamp((m - 0.55) * 1.8, 0.0, 1.0) * 0.55 * organic);
	base = mix(base, base * vec3(0.72, 0.92, 0.78),
		clamp((0.45 - m) * 1.8, 0.0, 1.0) * 0.5 * organic);
	// Detail noise adds close-range break-up.
	base *= mix(1.0 - detail_strength * mix(0.5, 1.0, organic),
		1.0 + detail_strength * mix(0.5, 1.0, organic), detail.g);

	float rock_mask = smoothstep(rock_slope - rock_blend, rock_slope + rock_blend, v_slope);
	rock_mask = clamp(rock_mask + (detail.b - 0.5) * 0.25, 0.0, 1.0) * organic;
	base = mix(base, rock_color.rgb * mix(0.8, 1.2, detail.r), rock_mask);

	float shore = 1.0 - smoothstep(water_level, water_level + 3.5, v_world.y);
	base = mix(base, sand_color.rgb, shore * 0.75 * organic);

	// Shoreline. The mobile renderer cannot read depth, so the foam band is
	// computed from the vertex's own height against the water plane and
	// animated with a scrolling noise lookup instead of an intersection test.
	float tide = (texture(foam_noise, v_world.xz * 0.035
		+ vec2(TIME * 0.011, TIME * -0.007)).r - 0.5) * 0.55;
	float band = 1.0 - smoothstep(0.0, foam_width, abs(v_world.y - water_level - tide));
	float surf = texture(foam_noise, v_world.xz * 0.22 + vec2(TIME * 0.05, 0.0)).g;
	band *= 0.45 + 0.55 * surf;
	base = mix(base, foam_color.rgb, clamp(band, 0.0, 1.0) * 0.8);

	// Rain darkens and slickens the ground.
	float wet = clamp(redline_wetness, 0.0, 1.0);
	base = mix(base, base * 0.55 + wet_color.rgb * 0.25, wet * 0.7);

	// Surface normal detail at two scales. A single lookup tiles visibly as
	// diagonal streaking across open ground; crossing two rates breaks it up
	// for one extra sample.
	vec3 n_near = texture(detail_normal, duv * 0.9).xyz;
	vec3 n_far = texture(detail_normal, duv * 0.21 + vec2(0.37, 0.11)).xyz;
	NORMAL_MAP = normalize(mix(n_near, n_far, 0.45) * 2.0 - 1.0) * 0.5 + 0.5;
	// Paved ground is smoother than soil.
	NORMAL_MAP_DEPTH = normal_strength * mix(1.0, 0.45, wet) * mix(0.35, 1.0, organic);

	// Slopes read darker, which is what makes the relief legible at distance.
	base *= mix(1.0, 0.78, clamp(v_slope * 1.4, 0.0, 1.0));

	ALBEDO = base;
	// Ground within the tide band stays wet whatever the weather.
	float shore_wet = max(wet, clamp(band * 1.2, 0.0, 1.0));
	ROUGHNESS = mix(roughness_base, 0.22, shore_wet * 0.85) * mix(1.0, 0.82, rock_mask)
		* mix(0.86, 1.0, organic);
	SPECULAR = mix(0.18, 0.45, wet);
	METALLIC = 0.0;
}
