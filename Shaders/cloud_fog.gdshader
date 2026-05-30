shader_type fog;

// ── SkyManager pushes these every frame ───────────────────────────────────────
uniform vec4  star_color : source_color = vec4(1.0, 0.47, 0.13, 1.0);
uniform vec3  star_direction             = vec3(1.0, 0.0, 0.0);
uniform float star_energy                = 0.0;

// ── Per-volume offset ─────────────────────────────────────────────────────────
// Shifts this volume to a different region of the noise domain so multiple
// FogVolumes stacked at different altitudes show distinct cloud patterns.
uniform vec2 noise_offset = vec2(0.0);

// ── Value noise (hash-based, no texture reads) ────────────────────────────────
float _hash(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p.yx + vec2(19.19, 74.35));
	return fract(p.x * p.y);
}

float _vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);   // cubic smoothstep
	return mix(
		mix(_hash(i),                  _hash(i + vec2(1.0, 0.0)), f.x),
		mix(_hash(i + vec2(0.0, 1.0)), _hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

float _fbm(vec2 uv, int octaves) {
	float val = 0.0;
	float amp = 0.5;
	for (int i = 0; i < octaves; i++) {
		val += amp * _vnoise(uv);
		uv   = uv * 2.1 + vec2(1.7, 9.2);
		amp *= 0.5;
	}
	return val;
}

void fog() {
	// ── Noise UV in world space ───────────────────────────────────────────────
	vec2 xz = WORLD_POSITION.xz;
	const float NOISE_SCALE = 0.0055;

	// noise_offset shifts this volume to a different noise-domain patch so
	// stacked volumes don't repeat the same cloud silhouette.
	vec2 uv = xz * NOISE_SCALE + noise_offset;

	// Two independent drift streams — slow rolling overcast feel.
	vec2 d1 = normalize(vec2( 1.0,  0.30)) * TIME * 0.006;
	vec2 d2 = normalize(vec2(-0.4,  0.90)) * TIME * 0.004;

	// ── Domain-warped FBM ─────────────────────────────────────────────────────
	vec2 q = vec2(
		_fbm(uv + d1,                    3),
		_fbm(uv + d2 + vec2(5.2, 1.3),  3)
	);
	vec2 r = vec2(
		_fbm(uv + q + d1 * 1.3 + vec2(1.7, 9.2), 3),
		_fbm(uv + q + d2 * 1.5 + vec2(8.3, 2.8), 3)
	);

	float dens = _fbm(uv + 0.6 * r + d1, 4);

	// Lower threshold → more coverage.  Two overlapping volumes with different
	// noise_offsets fill gaps in each other, producing a dense broken overcast.
	dens = smoothstep(0.38, 0.60, dens);

	// ── Soft bottom edge ──────────────────────────────────────────────────────
	// UVW.y = 0 at box floor (cloud base), 1 at top.
	// Fade to zero at the base so the ceiling has no hard-altitude cut.
	dens *= smoothstep(0.0, 0.35, UVW.y);

	// ── Directional lighting — star near horizon ───────────────────────────────
	vec2 star_xz     = normalize(star_direction.xz + vec2(0.0001));
	vec2 from_center = WORLD_POSITION.xz - OBJECT_POSITION.xz;
	float fc_len     = length(from_center);
	float side = (fc_len > 0.5) ? dot(from_center / fc_len, star_xz) * 0.5 + 0.5
	                            : 0.5;

	vec3 dark = vec3(0.020, 0.004, 0.002);
	vec3 lit  = star_color.rgb * (side * star_energy * 0.22);
	float gap_glow = (1.0 - dens) * side * star_energy;

	DENSITY  = dens * 3.0;
	ALBEDO   = dark + lit;
	EMISSION = star_color.rgb * gap_glow * 0.05;
}
