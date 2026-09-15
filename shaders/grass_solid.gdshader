shader_type spatial;
// Ground cover, drawn as solid geometry with no alpha test at all.
//
// The masked foliage shader has to `discard`, and a discard disables early
// depth rejection for the whole draw on a tile-based mobile GPU. Ground cover
// is by far the most numerous thing in the world -- a quarter of a million
// instances in a forest -- so it is the one material where that matters most.
// The blade shape is built into the mesh instead of cut out of a texture,
// which costs a few more vertices per tuft and buys back hidden-surface
// removal on every one of them.
render_mode cull_disabled, depth_draw_opaque, diffuse_lambert, specular_disabled;

uniform float wind_strength = 0.5;
uniform float wind_speed = 2.0;
uniform float stiffness : hint_range(0.0, 1.0) = 0.2;
uniform vec4 tint : source_color = vec4(1.0);
uniform float translucency : hint_range(0.0, 1.0) = 0.5;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.45;

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
	vec3 c = COLOR.rgb * tint.rgb;
	// Darker at the base: cheap contact shading that makes a field read as
	// depth rather than as a flat green mat.
	c *= mix(1.0 - ao_strength, 1.0, v_height);
	c = mix(c, c * 0.62, clamp(redline_wetness, 0.0, 1.0) * 0.5);
	ALBEDO = c;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	ROUGHNESS = 0.9;
	SPECULAR = 0.1;
	BACKLIGHT = vec3(translucency) * c;
}
