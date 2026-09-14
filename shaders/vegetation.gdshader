shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_lambert, specular_disabled;

// MultiMesh foliage. Per-instance wind phase comes in through INSTANCE_CUSTOM.x
// so a whole forest sways out of sync from one draw call.

uniform sampler2D leaf_mask : source_color, filter_linear_mipmap, repeat_enable;
uniform float wind_strength = 0.35;
uniform float wind_speed = 1.4;
uniform float stiffness = 0.35;     // 0 = whole plant sways, 1 = only the tip
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.4;
uniform vec4 tint : source_color = vec4(1.0);
uniform float translucency : hint_range(0.0, 1.0) = 0.35;
uniform bool use_mask = true;

global uniform float redline_wind;
global uniform float redline_wetness;

varying float v_height;

void vertex() {
	v_height = clamp(1.0 - UV.y, 0.0, 1.0);
	float phase = INSTANCE_CUSTOM.x * 6.2831853;
	float amp = pow(v_height, mix(1.0, 3.0, stiffness)) * wind_strength
		* (0.35 + redline_wind);
	vec3 wpos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float t = TIME * wind_speed + phase + wpos.x * 0.06 + wpos.z * 0.05;
	VERTEX.x += sin(t) * amp;
	VERTEX.z += cos(t * 0.83 + 1.3) * amp * 0.7;
	VERTEX.y -= (abs(sin(t)) + abs(cos(t * 0.83))) * amp * 0.12;
}

void fragment() {
	float a = 1.0;
	if (use_mask) {
		a = texture(leaf_mask, UV).a;
	}
	if (a < alpha_cut) {
		discard;
	}
	vec3 c = COLOR.rgb * tint.rgb;
	c *= mix(0.72, 1.0, v_height);
	c = mix(c, c * 0.6, clamp(redline_wetness, 0.0, 1.0) * 0.5);
	ALBEDO = c;
	ALPHA = 1.0;
	ROUGHNESS = 0.85;
	BACKLIGHT = vec3(translucency) * c;
}
