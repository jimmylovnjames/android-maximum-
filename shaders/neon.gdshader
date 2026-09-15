shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// Lit signage.
//
// Emission is driven entirely by COLOR -- the MultiMesh instance colour times
// the mesh's own vertex colour. The sign mesh is a near-black frame around a
// white panel, so one instance colour gives a dark surround and a glowing face
// without needing per-instance custom data, which the shared prop shader was
// not reliably receiving.

uniform float energy = 2.6;
uniform float day_level : hint_range(0.0, 1.0) = 0.55;
uniform float albedo_level : hint_range(0.0, 1.0) = 0.22;
uniform float flicker_amount : hint_range(0.0, 1.0) = 0.06;

global uniform float redline_night;

varying float v_phase;

void vertex() {
	// Per-instance phase from the model matrix origin: no two signs on a
	// street flicker together.
	vec3 o = MODEL_MATRIX[3].xyz;
	v_phase = fract(sin(o.x * 12.9898 + o.z * 78.233) * 43758.5453);
}

void fragment() {
	float night = clamp(redline_night, 0.0, 1.0);
	float level = mix(day_level, 1.0, night);
	// A slow, shallow flicker: enough to read as gas discharge, not enough to
	// look broken.
	float f = 1.0 - flicker_amount
		* (0.5 + 0.5 * sin(TIME * (2.1 + v_phase * 3.0) + v_phase * 40.0));
	ALBEDO = COLOR.rgb * albedo_level;
	EMISSION = COLOR.rgb * energy * level * f;
	ROUGHNESS = 0.45;
	METALLIC = 0.0;
}
