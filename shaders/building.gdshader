shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// One MultiMesh draw call renders every floor module in a district. The window
// grid is generated from the instance's world-space scale so modules of
// different sizes still line up, and the lit-window pattern is stable per
// instance (derived from INSTANCE_CUSTOM) instead of flickering per frame.

uniform sampler2D wall_tex : source_color, filter_linear_mipmap, repeat_enable;
// One window row per storey: window_h must match ChunkGenerator.FLOOR_HEIGHT
// or the grid drifts out of step with the module seams. At the old 1.35 x 1.7
// the openings were 0.6 m portholes, which at any real viewing distance
// aliased into speckle and then bloomed into solid blocks.
uniform float window_w = 2.7;
uniform float window_h = 3.4;
uniform float window_fill = 0.62;
uniform vec4 window_day : source_color = vec4(0.11, 0.14, 0.17, 1.0);
uniform vec4 window_lit : source_color = vec4(1.0, 0.82, 0.52, 1.0);
uniform float emission_energy = 1.5;
uniform float lit_fraction : hint_range(0.0, 1.0) = 0.34;
uniform float wall_roughness = 0.82;

uniform float sky_glow_energy = 0.42;
uniform float sky_glow_height = 130.0;
uniform vec3 sky_glow_color : source_color = vec3(1.0, 0.70, 0.44);
uniform float grime_height = 9.0;

global uniform float redline_night;
global uniform float redline_wetness;
global uniform float redline_urban_night;

varying vec2 v_facade_uv;
// These four are constant across a face, but a plain varying is still
// *interpolated*, and the float error that introduces is enough to break the
// hash below: hash21 squares its input, so a 1e-5 wobble on a value near 100
// comes out as a completely different number on every pixel. That is what
// turned each lit window into a field of crawling white speckle. `flat` stops
// the interpolation and the speckle with it.
varying flat float v_is_wall;
varying flat float v_seed;
varying flat vec3 v_wnormal;
varying flat vec2 v_cell_offset;
varying float v_world_y;

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
	v_world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;

	// With one window row per storey the cell index is constant inside a
	// module, so the storey and the face have to be folded into the hash by
	// hand -- otherwise every floor of a column lights up identically and all
	// four elevations match.
	float storey = floor(MODEL_MATRIX[3].y / max(window_h, 0.01));
	float face = abs(NORMAL.x) * 2.0 + step(NORMAL.x + NORMAL.z, -0.5) * 5.0;
	v_cell_offset = vec2(
		mod(storey * 7.0 + face * 23.0, 251.0),
		mod(storey * 19.0 + face * 41.0, 241.0));
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
	float half_fill_y = half_fill * 1.15;

	// Analytic antialiasing. A hard step on a grid this fine turns a distant
	// tower into crawling speckle, and additive glow then welds the speckle
	// into solid blobs -- which is what the night skyline looked like. fwidth
	// is taken on `cell`, not on `f`: fract() has a discontinuity at every
	// seam and its derivative spikes there.
	vec2 fw = max(fwidth(cell), vec2(1e-5));
	float ax = smoothstep(0.5 - half_fill - fw.x, 0.5 - half_fill + fw.x, f.x)
		- smoothstep(0.5 + half_fill - fw.x, 0.5 + half_fill + fw.x, f.x);
	float ay = smoothstep(0.5 - half_fill_y - fw.y, 0.5 - half_fill_y + fw.y, f.y)
		- smoothstep(0.5 + half_fill_y - fw.y, 0.5 + half_fill_y + fw.y, f.y);
	float inw = clamp(ax, 0.0, 1.0) * clamp(ay, 0.0, 1.0);

	// Once a cell is smaller than a pixel there is no pattern left to resolve,
	// so fall back to its average coverage rather than to whatever the sample
	// happened to land on.
	float resolve = clamp(1.0 - max(fw.x, fw.y) * 1.7, 0.0, 1.0);
	float mean_cover = window_fill * window_fill * 1.15;
	inw = mix(mean_cover, inw, resolve);
	inw *= v_is_wall;

	// Keep the hash input small: hash21 is fract-based, so feeding it large
	// coordinates loses mantissa bits and the lit pattern turns blocky.
	float r = hash21(mod(cid, 191.0) + v_cell_offset
		+ vec2(fract(v_seed) * 97.0, fract(v_seed * 1.7) * 37.0));
	// Same treatment for which windows are lit: at distance the per-cell coin
	// flip is sub-pixel noise, so it resolves to the mean.
	float lit = mix(lit_fraction, step(1.0 - lit_fraction, r), resolve)
		* clamp(redline_night, 0.0, 1.0);

	// Horizontal spandrel band between floors so storeys read at distance even
	// when the window grid itself is too small to resolve.
	float band = smoothstep(0.06, 0.0, abs(f.y - 0.02)) * v_is_wall;
	base *= mix(1.0, 0.82, band);

	vec3 glass = mix(window_day.rgb, window_lit.rgb, lit);
	// Daylight glass picks up a little of the sky rather than reading as a
	// hole punched through the facade.
	float sky_bounce = 1.0 - clamp(redline_night, 0.0, 1.0);
	glass = mix(glass, glass + vec3(0.05, 0.07, 0.11) * (0.5 + r), sky_bounce);
	// Street grime darkening the first few metres of every facade. Cheap, and
	// it stops a tower reading as one flat extrusion from ground to roof.
	base *= mix(0.72, 1.0, clamp(v_world_y / grime_height, 0.0, 1.0));

	ALBEDO = mix(base, glass, inw);

	float glow = inw * lit * emission_energy * (0.55 + 0.45 * r);
	// Light pollution. A city's own sodium haze lights its walls from below,
	// and it has to be emission rather than ambient: raising ambient_light_energy
	// far enough to do this leaks the ambient colour into the sky background
	// and turns a night sky brown.
	float urban = clamp(redline_urban_night, 0.0, 1.0);
	float from_below = mix(1.0, 0.28, clamp(v_world_y / sky_glow_height, 0.0, 1.0));
	// Faces angled up catch less of it than the vertical walls that see the
	// street, which is what keeps the massing readable instead of flat.
	float facing = mix(1.0, 0.45, clamp(abs(v_wnormal.y), 0.0, 1.0));
	vec3 fill = sky_glow_color * base * sky_glow_energy * urban * from_below * facing;
	EMISSION = window_lit.rgb * glow + fill * (1.0 - inw);
	// A dark window is a mirror; a lit one is a diffuse interior seen through
	// glass, so it should not also be a sharp reflector of the night sky.
	ROUGHNESS = mix(wall_roughness, mix(0.09, 0.42, lit), inw);
	METALLIC = mix(0.0, mix(0.55, 0.12, lit), inw);
	SPECULAR = mix(0.3, mix(0.85, 0.45, lit), inw);

	float wet = clamp(redline_wetness, 0.0, 1.0);
	ROUGHNESS *= mix(1.0, 0.6, wet);
}
