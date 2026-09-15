shader_type sky;

// Analytic sky with procedural cloud cover.
//
// Everything here is arithmetic -- no textures, no screen reads, no volumetric
// pass -- so it runs on Godot's mobile renderer. The cloud FBM is evaluated at
// reduced octave count during the cubemap/low-res passes, where the result is
// only used for ambient light and reflections.

uniform vec3 zenith_day : source_color = vec3(0.09, 0.26, 0.62);
uniform vec3 zenith_night : source_color = vec3(0.010, 0.018, 0.045);
uniform vec3 horizon_day : source_color = vec3(0.62, 0.74, 0.86);
uniform vec3 horizon_night : source_color = vec3(0.045, 0.055, 0.10);
uniform vec3 dusk_color : source_color = vec3(1.0, 0.42, 0.16);
uniform vec3 sun_color : source_color = vec3(1.0, 0.94, 0.82);
uniform vec3 ground_color : source_color = vec3(0.07, 0.075, 0.085);

uniform float sun_size : hint_range(0.0005, 0.05) = 0.004;
uniform float sun_energy = 26.0;
uniform float star_density : hint_range(0.9, 0.999) = 0.9865;

uniform float cloud_cover : hint_range(0.0, 1.0) = 0.52;
uniform float cloud_sharpness : hint_range(1.0, 12.0) = 3.4;
uniform float cloud_height = 900.0;
uniform float cloud_scale = 0.00055;
uniform float cloud_speed = 0.004;
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.97, 0.92);
uniform vec3 cloud_shadow : source_color = vec3(0.34, 0.37, 0.45);
uniform float overcast : hint_range(0.0, 1.0) = 0.0;

global uniform float redline_night;

float hash21(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p, int octaves) {
	float v = 0.0;
	float amp = 0.5;
	mat2 rot = mat2(vec2(0.86, 0.5), vec2(-0.5, 0.86));
	for (int i = 0; i < octaves; i++) {
		v += amp * vnoise(p);
		p = rot * p * 2.02;
		amp *= 0.5;
	}
	return v;
}

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.11, 0.27, 0.39));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	float night = clamp(redline_night, 0.0, 1.0);
	float up = clamp(EYEDIR.y, -1.0, 1.0);
	float t = pow(clamp(up, 0.0, 1.0), 0.52);

	float sun_elev = LIGHT0_ENABLED ? LIGHT0_DIRECTION.y : 0.0;
	float dusk = pow(clamp(1.0 - abs(sun_elev) * 2.2, 0.0, 1.0), 2.2) * (1.0 - night);

	vec3 zen = mix(zenith_day, zenith_night, night);
	vec3 hor = mix(horizon_day, horizon_night, night);
	hor = mix(hor, dusk_color, dusk * 0.8);
	zen = mix(zen, dusk_color * 0.45, dusk * 0.3);

	vec3 col = mix(hor, zen, t);

	// Sun-side warming across the whole dome.
	if (LIGHT0_ENABLED) {
		float towards = clamp(dot(normalize(EYEDIR), LIGHT0_DIRECTION), 0.0, 1.0);
		col += sun_color * pow(towards, 5.0) * 0.16 * (1.0 - night);
	}

	// Stars, fading in as the sun drops. Deliberately skipped in the cubemap
	// pass: they carry no useful light, but a 128px radiance map full of white
	// specks turns every glossy surface in the city into a field of crawling
	// dots -- which is exactly what the night windows were reflecting.
	if (night > 0.01 && up > -0.03 && !AT_CUBEMAP_PASS) {
		vec3 sp = normalize(EYEDIR) * 210.0;
		float r = hash31(floor(sp));
		float s = step(star_density, r);
		float twinkle = 0.6 + 0.4 * sin(TIME * 2.1 + r * 73.0);
		col += vec3(s * twinkle * night * 1.5) * vec3(0.86, 0.91, 1.0);
	}

	// Cloud deck, projected onto a plane above the viewer. Clouds are skipped
	// entirely when looking below the horizon.
	if (up > 0.015) {
		int octaves = AT_CUBEMAP_PASS ? 3 : (AT_HALF_RES_PASS ? 4 : 5);
		vec2 plane = EYEDIR.xz / max(up, 0.02) * cloud_height * cloud_scale;
		vec2 drift = vec2(TIME * cloud_speed, TIME * cloud_speed * 0.6);
		float cover = clamp(cloud_cover + overcast * 0.5, 0.0, 1.0);

		float base_n = fbm(plane + drift, octaves);
		// Domain-warp the second layer so the deck has structure instead of
		// looking like a noise texture stretched across the sky.
		float detail_n = fbm(plane * 2.7 - drift * 1.7 + base_n * 0.9, octaves - 1);
		float d = base_n * 0.68 + detail_n * 0.32;

		float density = clamp((d - (1.0 - cover)) * cloud_sharpness, 0.0, 1.0);
		// Fade the deck out towards the horizon so it does not form a hard band.
		density *= smoothstep(0.015, 0.22, up);

		// Cheap lighting: thicker cloud is darker underneath, and the edge
		// nearest the sun catches light.
		float towards_sun = LIGHT0_ENABLED
			? clamp(dot(normalize(EYEDIR), LIGHT0_DIRECTION), 0.0, 1.0) : 0.0;
		float silver = pow(towards_sun, 6.0);
		vec3 cloud = mix(cloud_shadow, cloud_lit, clamp(1.0 - d * 0.9, 0.0, 1.0));
		cloud = mix(cloud, sun_color * 1.4, silver * 0.55);
		cloud = mix(cloud, cloud * vec3(1.05, 0.72, 0.52), dusk * 0.8);
		cloud *= mix(1.0, 0.10, night);
		col = mix(col, cloud, density);
	}

	if (up < 0.0) {
		col = mix(col, ground_color, clamp(-up * 4.0, 0.0, 1.0));
	}

	// Sun disc last so cloud never dims it entirely.
	if (LIGHT0_ENABLED) {
		float d2 = dot(EYEDIR, LIGHT0_DIRECTION);
		float disc = smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.3, d2);
		float glow = pow(clamp(d2, 0.0, 1.0), 260.0) * 0.9
			+ pow(clamp(d2, 0.0, 1.0), 22.0) * 0.12;
		col += sun_color * (disc * sun_energy + glow * 3.2) * (1.0 - night);
	}

	COLOR = col;
}
