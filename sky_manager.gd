extends Node

## Drives the sky cycle for the crater environment.
##
## Two nested cycles determine the star's position:
##   rotation_time — planet rotation (minutes)  → star sweeps azimuth around the horizon
##   orbital_time  — orbital period  (hours)    → slowly shifts which side is brightest
##
## The star's elevation follows:
##   elevation = TILT_AMPLITUDE * sin(rotation_phase - orbital_phase)
##
## This means at any given orbital position, one side of the crater has the star
## barely above the horizon and the opposite side barely below.  As orbital_time
## advances, the bright window migrates all the way around the crater.
##
## Server-authoritative: only the server advances time.  Clients receive a
## lightweight time sync every SYNC_INTERVAL seconds and run the same
## deterministic math locally — zero per-frame bandwidth after the sync.
##
## All sky-dependent systems (light, shaders, NPCs) read from the public
## properties below.  For position-dependent queries use get_light_at_position().

# ── Cycle parameters (exported so the editor can tune them) ───────────────────
@export_group("Cycle")
@export var ROTATION_PERIOD: float = 180.0   ## seconds per planet rotation  (3 min)
@export var ORBITAL_PERIOD:  float = 5400.0  ## seconds per full orbit       (90 min)
@export var TILT_AMPLITUDE:  float = 8.0     ## degrees — max star elevation above/below horizon
@export var SYNC_INTERVAL:   float = 3.0     ## seconds between authoritative peer syncs

# ── Authoritative time values ─────────────────────────────────────────────────
var rotation_time: float = 0.0   # 0 → ROTATION_PERIOD
var orbital_time:  float = 0.0   # 0 → ORBITAL_PERIOD

# ── Derived state — recomputed every frame, free to read from anywhere ─────────
var star_azimuth_deg:   float   = 0.0
var star_elevation_deg: float   = 0.0
var star_direction:     Vector3 = Vector3.FORWARD   # unit vec FROM scene TOWARD star
var light_intensity:    float   = 0.0               # 0–1, direct starlight (goes dark quickly after sunset)
var glow_intensity:     float   = 0.0               # 0–1, atmospheric glow (persists through most of night)
var light_color:        Color   = Color(1.0, 0.47, 0.13, 1.0)
var is_above_horizon:   bool    = false

## Current cycle phase.  Values match TimeSystem.Phase (0–3) so TimeSystem
## can cast directly without importing SkyManager.
## 0 = BELOW  1 = RISING  2 = ABOVE  3 = SETTING
var phase:     int  = 0
var is_rising: bool = false

## Emitted when the phase changes.  TimeSystem re-broadcasts this to listeners.
signal phase_changed(new_phase: int, old_phase: int)

# Star colour palette (red dwarf, low-angle atmospheric scattering)
# _COL_PEAK    — star above horizon: strawberry red-orange.
#                Green pulled down from 0.47 → 0.28 to shift away from orange toward red.
# _COL_HORIZON — star below horizon: blood moon dark crimson.
#                Red held at 0.54 (not 1.0) so the scene reads as genuinely dim and moody,
#                not just "red-tinted bright".  Green/blue nearly zeroed for pure crimson.
const _COL_PEAK    := Color(1.00, 0.28, 0.10, 1.0)   # strawberry red-orange
const _COL_HORIZON := Color(0.54, 0.05, 0.03, 1.0)   # blood moon dark crimson
const _COL_AMBIENT := Color(0.03, 0.003, 0.001, 1.0) # barely-there ember in the dark

# ── Dev overrides ─────────────────────────────────────────────────────────────
var _paused:        bool  = false
var _speed_mult:    float = 1.0
var _elev_override: float = NAN   # NAN = not overriding

var _sync_timer:    float          = 0.0
var _cloud_fog_mat:  ShaderMaterial = null   # lower FogVolume (base layer)
var _cloud_fog_mat2: ShaderMaterial = null   # upper FogVolume (fills gaps in base)
var _fill_light:    OmniLight3D    = null   # positional fill — makes near side brighter

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Register in group so any node can locate us without a hardcoded scene path.
	add_to_group("sky_manager")
	_setup_environment()
	_setup_cloud_fog()
	_setup_fill_light()
	# Only the server (or solo player) advances time.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		set_process(false)

func _process(delta: float) -> void:
	if not _paused:
		rotation_time = fmod(rotation_time + delta * _speed_mult, ROTATION_PERIOD)
		orbital_time  = fmod(orbital_time  + delta * _speed_mult, ORBITAL_PERIOD)

	_recompute_state()
	_apply_to_scene()

	if multiplayer.has_multiplayer_peer():
		_sync_timer += delta
		if _sync_timer >= SYNC_INTERVAL:
			_sync_timer = 0.0
			_rpc_sync_sky.rpc(rotation_time, orbital_time)

# ── Environment setup ─────────────────────────────────────────────────────────

func _setup_environment() -> void:
	var world_env: WorldEnvironment = get_parent().get_node_or_null("WorldEnvironment")
	if not world_env:
		push_warning("[SkyManager] WorldEnvironment not found — sky won't render.")
		return

	var sky_shader: Shader = load("res://Shaders/sky.gdshader")
	if not sky_shader:
		push_warning("[SkyManager] res://Shaders/sky.gdshader not found.")
		return

	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = sky_shader

	var sky := Sky.new()
	sky.sky_material  = sky_mat
	sky.process_mode  = Sky.PROCESS_MODE_REALTIME

	var env := Environment.new()
	env.background_mode          = Environment.BG_SKY
	env.sky                      = sky
	env.ambient_light_source     = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color      = _COL_AMBIENT
	env.ambient_light_energy     = 1.0
	env.reflected_light_source   = Environment.REFLECTION_SOURCE_SKY
	# Subtle distance fog for atmospheric depth inside the crater
	env.fog_enabled              = true
	env.fog_light_color          = Color(0.08, 0.02, 0.01)
	env.fog_density              = 0.003
	env.fog_aerial_perspective   = 0.1

	# Volumetric fog — required for the FogVolume cloud ceiling.
	# Forward+ renderer only; harmless no-op on Compatibility.
	# Global density is 0: the FogVolume shader provides all cloud density.
	env.volumetric_fog_enabled       = true
	env.volumetric_fog_density       = 0.0
	env.volumetric_fog_albedo        = Color(0.05, 0.01, 0.005)
	env.volumetric_fog_emission      = Color(0.0, 0.0, 0.0)
	env.volumetric_fog_length        = 80.0
	env.volumetric_fog_detail_spread = 2.0
	# sky_affect: FogVolume density attenuates the sky behind dense cloud.
	# 0 = no sky interaction; 1 = full attenuation.
	env.volumetric_fog_sky_affect    = 0.6

	world_env.environment = env

# ── Sky math ──────────────────────────────────────────────────────────────────

func _recompute_state() -> void:
	var rot: float = (rotation_time / ROTATION_PERIOD) * TAU
	var orb: float = (orbital_time  / ORBITAL_PERIOD)  * TAU

	star_azimuth_deg = fposmod(rad_to_deg(rot), 360.0)

	var elev: float = _elev_override if not is_nan(_elev_override) \
					  else TILT_AMPLITUDE * sin(rot - orb)
	star_elevation_deg = elev
	is_above_horizon   = elev > 0.0

	# World-space unit vector pointing FROM scene TOWARD the star
	var az_r := deg_to_rad(star_azimuth_deg)
	var el_r := deg_to_rad(clampf(star_elevation_deg, -89.0, 89.0))
	star_direction = Vector3(
		sin(az_r) * cos(el_r),
		sin(el_r),
		cos(az_r) * cos(el_r)
	)

	# Luminosity is constant throughout the cycle — the star always shines at full strength.
	light_intensity = 1.0
	glow_intensity  = 1.0

	# Colour only: smooth transition from red (below horizon) to orange (above horizon).
	# Transition zone spans ±3° around the horizon so the crossing is gradual.
	var t := clampf(remap(elev, -3.0, 3.0, 0.0, 1.0), 0.0, 1.0)
	light_color = _COL_HORIZON.lerp(_COL_PEAK, t)

	# ── Phase ─────────────────────────────────────────────────────────────────
	# d(elevation)/d(rotation) = TILT_AMPLITUDE * cos(rot − orb).
	# cos > 0 → elevation increasing → star is rising.
	is_rising = cos(rot - orb) > 0.0

	# Phase thresholds match the ±3° colour-transition zone.
	var new_phase: int
	if   elev >  3.0: new_phase = 2   # ABOVE
	elif elev < -3.0: new_phase = 0   # BELOW
	elif is_rising:   new_phase = 1   # RISING
	else:             new_phase = 3   # SETTING

	if new_phase != phase:
		var old_phase := phase
		phase = new_phase
		phase_changed.emit(phase, old_phase)

func _apply_to_scene() -> void:
	_update_star_light()
	_update_fill_light()
	_update_sky_shader()
	_update_cloud_fog()
	_update_ambient()

func _update_star_light() -> void:
	var star_light: DirectionalLight3D = get_parent().get_node_or_null("StarLight")
	if not star_light:
		return
	var dir := -star_direction
	var up  := Vector3.RIGHT if abs(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP
	star_light.global_transform.basis = Basis.looking_at(dir, up)
	star_light.light_energy           = 1.2   # constant — luminosity never changes
	star_light.light_color            = light_color

## Creates a positional OmniLight on the crater rim at the star's azimuth.
## Being positional, it naturally falls off with distance — the near side of the
## crater (within ~40 m of the light) is noticeably brighter than the far side
## (~160 m away), giving the illumination gradient a directional light cannot.
func _setup_fill_light() -> void:
	if get_parent().get_node_or_null("StarFillLight"):
		_fill_light = get_parent().get_node("StarFillLight") as OmniLight3D
		return
	_fill_light               = OmniLight3D.new()
	_fill_light.name          = "StarFillLight"
	_fill_light.omni_range    = 50   # covers full crater diameter with rolloff
	_fill_light.light_energy  = 0.7
	_fill_light.shadow_enabled = false  # soft fill, not a shadow caster
	get_parent().add_child(_fill_light)

## Repositions the fill light each frame to track the star's azimuth.
## Placed 80 m from crater centre at the rim, 4 m off the ground —
## simulates indirect light bouncing off the star-facing rim wall.
func _update_fill_light() -> void:
	if not _fill_light:
		return
	var azimuth_flat := Vector3(star_direction.x, 0.0, star_direction.z).normalized()
	_fill_light.global_position = azimuth_flat * 80.0 + Vector3(0.0, 4.0, 0.0)
	_fill_light.light_color     = light_color

func _update_sky_shader() -> void:
	var mat := _sky_material()
	if not mat:
		return
	mat.set_shader_parameter("star_direction", star_direction)
	# Sky receives glow_intensity so the horizon haze persists through most of night.
	mat.set_shader_parameter("star_energy",    glow_intensity)
	mat.set_shader_parameter("star_color",     light_color)


func _update_ambient() -> void:
	var world_env: WorldEnvironment = get_parent().get_node_or_null("WorldEnvironment")
	if not world_env or not world_env.environment:
		return
	var env := world_env.environment

	# Luminosity is constant, so ambient is a fixed fraction of the current colour.
	# Only the hue shifts (orange ↔ red) as the star crosses the horizon.
	env.ambient_light_color  = light_color
	env.ambient_light_energy = 0.20

# ── FogVolume cloud ceiling ───────────────────────────────────────────────────

## Creates the FogVolume node that renders the cloud ceiling.
## The box sits from y = 30 m (cloud base) to y = 50 m (cloud top),
## wide enough to cover the crater and then some.
func _setup_cloud_fog() -> void:
	var fog_shader: Shader = load("res://Shaders/cloud_fog.gdshader")
	if not fog_shader:
		push_warning("[SkyManager] res://Shaders/cloud_fog.gdshader not found — no cloud ceiling.")
		return

	# ── Layer 0 — base ceiling (y 30–50 m) ───────────────────────────────────
	if get_parent().get_node_or_null("CloudFogVolume"):
		_cloud_fog_mat = (get_parent().get_node("CloudFogVolume") as FogVolume).material as ShaderMaterial
	else:
		_cloud_fog_mat        = ShaderMaterial.new()
		_cloud_fog_mat.shader = fog_shader
		# noise_offset = vec2(0,0) — default, no shift needed for the base layer
		var vol := FogVolume.new()
		vol.name     = "CloudFogVolume"
		vol.position = Vector3(0.0, 40.0, 0.0)   # centre; base at 30 m, top at 50 m
		vol.size     = Vector3(500.0, 20.0, 500.0)
		vol.material = _cloud_fog_mat
		get_parent().add_child(vol)

	# ── Layer 1 — upper fill (y 44–58 m) ─────────────────────────────────────
	# Offset into a different noise-domain patch so it fills gaps left by layer 0.
	if get_parent().get_node_or_null("CloudFogVolume2"):
		_cloud_fog_mat2 = (get_parent().get_node("CloudFogVolume2") as FogVolume).material as ShaderMaterial
	else:
		_cloud_fog_mat2        = ShaderMaterial.new()
		_cloud_fog_mat2.shader = fog_shader
		_cloud_fog_mat2.set_shader_parameter("noise_offset", Vector2(31.5, 67.2))
		var vol2 := FogVolume.new()
		vol2.name     = "CloudFogVolume2"
		vol2.position = Vector3(0.0, 51.0, 0.0)   # centre; base at 44 m, top at 58 m
		vol2.size     = Vector3(500.0, 14.0, 500.0)
		vol2.material = _cloud_fog_mat2
		get_parent().add_child(vol2)

## Pushes star state to both cloud fog layers each frame.
func _update_cloud_fog() -> void:
	for mat in [_cloud_fog_mat, _cloud_fog_mat2]:
		if not mat:
			continue
		mat.set_shader_parameter("star_direction", star_direction)
		mat.set_shader_parameter("star_energy",    glow_intensity)
		mat.set_shader_parameter("star_color",     light_color)

func _sky_material() -> ShaderMaterial:
	var world_env: WorldEnvironment = get_parent().get_node_or_null("WorldEnvironment")
	if not world_env or not world_env.environment or not world_env.environment.sky:
		return null
	return world_env.environment.sky.sky_material as ShaderMaterial

# ── Public API ────────────────────────────────────────────────────────────────

## Returns estimated relative light level (0–1) at a world position.
## Accounts for star direction and the position's angle within the crater.
## Use this from NPC scripts to determine visibility and behaviour.
func get_light_at_position(world_pos: Vector3) -> float:
	if not is_above_horizon:
		return 0.0
	var flat_star := Vector2(star_direction.x, star_direction.z).normalized()
	var flat_pos  := Vector2(world_pos.x,      world_pos.z).normalized()
	var directional: float = flat_star.dot(flat_pos) * 0.5 + 0.5   # 0 = shadowed side, 1 = lit side
	return light_intensity * (0.4 + 0.6 * directional)

# ── Dev controls (called by HUD weather section) ──────────────────────────────

func dev_set_paused(v: bool)              -> void: _paused        = v
func dev_set_speed(v: float)              -> void: _speed_mult    = v
func dev_set_rotation_time(v: float)      -> void: rotation_time  = clampf(v, 0.0, ROTATION_PERIOD)
func dev_set_orbital_time(v: float)       -> void: orbital_time   = clampf(v, 0.0, ORBITAL_PERIOD)
func dev_set_elevation_override(v: float) -> void: _elev_override = v
func dev_clear_elevation_override()       -> void: _elev_override = NAN

# ── Multiplayer sync ──────────────────────────────────────────────────────────

@rpc("authority", "reliable")
func _rpc_sync_sky(r_time: float, o_time: float) -> void:
	rotation_time = r_time
	orbital_time  = o_time
