shader_type sky;

// Analytic day/night sky: horizon gradient, sun disc with bloom-friendly
// overbright core, night stars that fade in, and a haze band that ties into
// the scene fog colour.

uniform vec3 day_top : source_color = vec3(0.20, 0.42, 0.80);
uniform vec3 day_horizon : source_color = vec3(0.72, 0.80, 0.90);
uniform vec3 dusk_horizon : source_color = vec3(0.95, 0.45, 0.20);
uniform vec3 night_top : source_color = vec3(0.012, 0.022, 0.055);
uniform vec3 night_horizon : source_color = vec3(0.05, 0.06, 0.11);
uniform vec3 sun_color : source_color = vec3(1.0, 0.93, 0.78);
uniform vec3 ground_color : source_color = vec3(0.09, 0.09, 0.10);
uniform float sun_size = 0.006;
uniform float sun_energy = 22.0;
uniform float star_density = 0.986;
uniform float haze = 0.35;
uniform float overcast : hint_range(0.0, 1.0) = 0.0;
uniform vec3 overcast_color : source_color = vec3(0.34, 0.35, 0.38);

global uniform float redline_night;

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	float night = clamp(redline_night, 0.0, 1.0);
	float up = clamp(EYEDIR.y, -1.0, 1.0);
	float t = pow(clamp(up, 0.0, 1.0), 0.55);

	// Dusk tint peaks when the sun is near the horizon.
	float dusk = 1.0 - abs(LIGHT0_DIRECTION.y);
	dusk = pow(clamp(dusk, 0.0, 1.0), 3.0) * (1.0 - night);

	vec3 top = mix(day_top, night_top, night);
	vec3 horiz = mix(day_horizon, night_horizon, night);
	horiz = mix(horiz, dusk_horizon, dusk * 0.75);

	vec3 col = mix(horiz, top, t);
	col = mix(col, horiz, haze * (1.0 - t) * 0.8);

	if (up < 0.0) {
		col = mix(col, ground_color, clamp(-up * 3.0, 0.0, 1.0));
	}

	// Stars
	if (night > 0.01 && up > -0.02) {
		vec3 sp = normalize(EYEDIR) * 180.0;
		vec3 cell = floor(sp);
		float r = hash31(cell);
		float s = step(star_density, r);
		float twinkle = 0.65 + 0.35 * sin(TIME * 2.4 + r * 62.0);
		col += vec3(s * twinkle * night * 1.4) * vec3(0.85, 0.9, 1.0);
	}

	// Sun disc
	if (LIGHT0_ENABLED) {
		float d = dot(EYEDIR, LIGHT0_DIRECTION);
		float disc = smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.35, d);
		float glow = pow(clamp(d, 0.0, 1.0), 220.0) * 0.8
			+ pow(clamp(d, 0.0, 1.0), 18.0) * 0.14;
		col += sun_color * (disc * sun_energy + glow * 3.0) * (1.0 - night);
	}

	col = mix(col, overcast_color * mix(0.35, 1.0, t) * (1.0 - night * 0.85), overcast);
	COLOR = col;
}
