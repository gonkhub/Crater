shader_type sky;

// Pushed every frame by SkyManager._update_sky_shader()
uniform vec4  star_color     : source_color = vec4(1.0, 0.47, 0.13, 1.0);
uniform vec3  star_direction                = vec3(0.0, 0.05, 1.0);  // FROM scene TOWARD star
uniform float star_energy                   = 0.0;

void sky() {
	vec3 dir = EYEDIR;

	// ── Horizontal components ─────────────────────────────────────────────────
	vec3  dir_flat    = normalize(vec3(dir.x, 0.0, dir.z));
	vec3  star_flat   = normalize(vec3(star_direction.x, 0.0, star_direction.z));
	float horizon_dot = dot(dir_flat, star_flat);   // -1 (away) → +1 (toward star)
	float elevation   = dir.y;

	// ── Base: deep space — near-black with a faint red tint ───────────────────
	vec3 col = vec3(0.010, 0.002, 0.005);

	// ── Primary horizon glow — concentrated on the star side ─────────────────
	float horizon_band = exp(-abs(elevation) * 5.5);
	float star_side    = max(horizon_dot, 0.0);
	col += star_color.rgb * star_energy * star_side * horizon_band * 0.85;

	// ── Wide atmospheric haze — wraps further around the horizon ──────────────
	float haze = (horizon_dot * 0.5 + 0.5) * exp(-abs(elevation) * 2.5) * star_energy * 0.16;
	col += star_color.rgb * haze;

	// ── Very subtle counter-glow on the opposite side (reflected off terrain) ─
	float counter = max(-horizon_dot, 0.0) * exp(-abs(elevation) * 8.0) * star_energy * 0.04;
	col += star_color.rgb * counter;

	// ── Star disc ─────────────────────────────────────────────────────────────
	float star_dist = length(dir - star_direction);
	float disc      = smoothstep(0.05, 0.008, star_dist);
	col += star_color.rgb * disc * star_energy * 2.8;

	// ── Bloom / corona around disc ────────────────────────────────────────────
	float bloom = exp(-star_dist * 9.0) * star_energy * 0.38;
	col += star_color.rgb * bloom;

	// ── Below-horizon ember (light scattered through solid planet limb) ────────
	if (elevation < 0.0) {
		float sub = exp(elevation * 5.0) * star_energy * 0.07;
		col += star_color.rgb * (horizon_dot * 0.5 + 0.5) * sub;
	}

	COLOR = col;
}
