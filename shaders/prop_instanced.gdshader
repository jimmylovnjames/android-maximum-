shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Shared material for every MultiMesh prop batch (crates, barriers, poles,
// rubble, parked vehicles). Per-instance colour comes from COLOR; per-instance
// emission mask and roughness come from INSTANCE_CUSTOM so one draw call can
// mix dull concrete and glowing industrial hardware.

uniform sampler2D surface_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float tex_scale = 0.5;
uniform float base_roughness = 0.78;
uniform float base_metallic = 0.0;
uniform vec4 emission_tint : source_color = vec4(1.0, 0.55, 0.2, 1.0);
uniform float emission_energy = 1.9;

global uniform float redline_night;
global uniform float redline_wetness;

varying vec3 v_world;
varying float v_emis;
varying float v_rough;
varying float v_self_lit;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_emis = INSTANCE_CUSTOM.y;
	v_rough = INSTANCE_CUSTOM.z;
	// w flags an instance that glows in its own colour rather than the batch
	// tint: that is what makes a street of signs read as a street of signs
	// instead of one repeated orange.
	v_self_lit = INSTANCE_CUSTOM.a;
}

void fragment() {
	vec3 tex = texture(surface_tex, v_world.xz * tex_scale + UV * 0.5).rgb;
	vec3 base = COLOR.rgb * mix(0.82, 1.18, tex.r);
	ALBEDO = base;
	float wet = clamp(redline_wetness, 0.0, 1.0);
	ROUGHNESS = clamp(mix(base_roughness, v_rough, step(0.001, v_rough)), 0.04, 1.0)
		* mix(1.0, 0.62, wet);
	METALLIC = base_metallic;
	float night_boost = mix(0.25, 1.0, clamp(redline_night, 0.0, 1.0));
	vec3 glow_tint = mix(emission_tint.rgb, COLOR.rgb, step(0.5, v_self_lit));
	// Self-lit panels stay bright in daylight too -- a neon sign does not
	// switch off at noon, it just stops dominating.
	float boost = mix(night_boost, mix(0.55, 1.0, clamp(redline_night, 0.0, 1.0)),
		step(0.5, v_self_lit));
	EMISSION = glow_tint * v_emis * emission_energy * boost;
	ALBEDO = mix(ALBEDO, base * 0.35, step(0.5, v_self_lit));
}
