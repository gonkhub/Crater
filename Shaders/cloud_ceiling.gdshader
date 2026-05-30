shader_type spatial;

// The cloud ceiling is viewed from BELOW — cull_disabled lets the back face render.
// unshaded: all lighting is computed manually so we have full control over the
// dim, directional red-dwarf look.  blend_mix + depth_draw_never lets clouds
// composite correctly over the sky and over each other.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

// ── SkyManager pushes these every frame ───────────────────────────────────────
uniform vec4  star_color     : source_color = vec4(1.0, 0.47, 0.13, 1.0);
uniform vec3  star_direction                = vec3(1.0, 0.05, 0.0);
uniform float star_energy                   = 0.0;

// ── Per-layer tuning (set by CloudCeiling._add_layer) ─────────────────────────
uniform float noise_scale        = 0.006;
uniform float detail_scale       = 0.025;
uniform float drift_speed        = 0.004;
uniform float convect_speed      = 0.002;
uniform vec2  drift_direction    = vec2(1.0, 0.3);
uniform float density_threshold  = 0.40;
uniform float density_softness   = 0.32;
uniform float layer_opacity      = 0.88;
uniform float backlight_strength = 0.50;
// Mesh half-width — must match cloud_ceiling.gd cloud_radius.
// Used for radial fade that hides the rectangular plane boundary.
uniform float cloud_radius       = 150.0;

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
		mix(_hash(i),                 _hash(i + vec2(1.0, 0.0)), f.x),
		mix(_hash(i + vec2(0.0, 1.0)), _hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

// Fractional Brownian Motion — layered noise octaves.
float _fbm(vec2 uv, int octaves) {
	float val = 0.0;
	float amp = 0.5;
	for (int i = 0; i < octaves; i++) {
		val += amp * _vnoise(uv);
		uv   = uv * 2.07 + vec2(1.7, 9.2);   // slight scale offset avoids grid artefacts
		amp *= 0.5;
	}
	return val;
}

void fragment() {
	// ── World-space XZ position ───────────────────────────────────────────────
	// VERTEX is in view space in the fragment function; INV_VIEW_MATRIX
	// transforms it back to world space.  We only need XZ for noise UVs.
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 xz        = world_pos.xz;

	// ── Animated drift offsets ────────────────────────────────────────────────
	// Two independent drift directions produce the cross-current convection look.
	vec2 dir_n   = normalize(drift_direction);
	vec2 dir_p   = vec2(-dir_n.y, dir_n.x);       // perpendicular to drift

	vec2 drift   = dir_n * TIME * drift_speed;
	vec2 convect = dir_p * TIME * convect_speed;

	// ── Domain-warped FBM ─────────────────────────────────────────────────────
	// Two rounds of domain warping produce the folding, churning organic shapes
	// characteristic of active convection cells.
	vec2 uv = xz * noise_scale;

	// First warp: large convection rolls
	vec2 q = vec2(
		_fbm(uv + drift,                      3),
		_fbm(uv + convect + vec2(5.2, 1.3),   3)
	);

	// Second warp: finer folding within the rolls
	vec2 r = vec2(
		_fbm(uv + 1.1 * q + drift   * 1.3 + vec2(1.7, 9.2), 3),
		_fbm(uv + 1.1 * q + convect * 1.5 + vec2(8.3, 2.8), 3)
	);

	float base = _fbm(uv + 0.75 * r + drift, 4);

	// ── Detail layer (small wisps and surface texture) ────────────────────────
	vec2  det = xz * detail_scale;
	float detail = _fbm(det + convect * 2.0 + vec2(3.1, 6.7), 3);

	// Combine: base drives large shape, detail adds surface interest
	float density = base * 0.72 + detail * 0.28;
	density = smoothstep(density_threshold,
	                     density_threshold + density_softness,
	                     density);

	// ── Underside lighting ────────────────────────────────────────────────────
	// The star is near the horizon — its light enters nearly horizontally.
	// We compute how much each world-space point faces toward the star's
	// horizontal projection, then use that for the side-lit face, the
	// backlit thin-gap effect, and the silver-lining edge glow.

	vec2  star_xz  = normalize(star_direction.xz);
	// Tiny epsilon avoids zero-length normalise at the exact crater centre.
	float side_dot = dot(normalize(xz + vec2(0.0001)), star_xz);
	float side     = side_dot * 0.5 + 0.5;   // 0 = away, 1 = facing star

	// Thin regions glow: star light bleeds through cloud gaps
	float thin    = 1.0 - density;
	float backlit = thin * side * star_energy * backlight_strength * 0.45;

	// Dense regions: very subtle diffuse lit face (cloud interior scatters little)
	float sidelit = density * side * star_energy * 0.18;

	// Silver lining: subtle bright rim at the transition edge between gap and cloud base.
	// density*(1−density)*4 peaks at 1.0 exactly in the smoothstep transition band.
	float edge_glow = density * (1.0 - density) * 4.0;
	float silver    = edge_glow * (0.35 + 0.65 * side) * star_energy * 1.2;

	// ── Colour composition ────────────────────────────────────────────────────
	vec3 dark_col    = vec3(0.014, 0.002, 0.001);   // unlit base — very dark brownish
	vec3 lit_col     = star_color.rgb * 0.28;         // side-lit cloud face
	vec3 backlit_col = star_color.rgb * 0.55;         // backlit thin gap
	vec3 silver_col  = star_color.rgb * 1.10;         // silver lining rim

	vec3 col = dark_col
	         + lit_col     * sidelit
	         + backlit_col * backlit
	         + silver_col  * silver;

	// ── Radial edge fade ──────────────────────────────────────────────────────
	// Each layer is a finite flat quad.  Without a fade, the rectangular boundary
	// is visible as a hard horizontal shelf when viewed at oblique angles.
	// Fade alpha to 0 beyond 70 % of cloud_radius so the plane edge is never seen.
	float radial    = length(xz) / cloud_radius;
	float edge_fade = 1.0 - smoothstep(0.68, 0.95, radial);

	// ── Alpha ─────────────────────────────────────────────────────────────────
	float alpha = clamp(density * layer_opacity + backlit * 0.18 + silver * 0.12, 0.0, 1.0);
	alpha *= edge_fade;

	ALBEDO = col;
	ALPHA  = alpha;
}
