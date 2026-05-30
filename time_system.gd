extends Node

## Global time-cycle access point for NPCs and world systems.
##
## Add this script as an Autoload named "TimeSystem" in:
##   Project Settings → Autoload → add time_system.gd → Name: TimeSystem
##
## Usage examples:
##
##   # Check current phase
##   if TimeSystem.phase == TimeSystem.Phase.BELOW:
##       seek_shelter()
##
##   # How bright is the position I'm standing on?
##   var lit := TimeSystem.get_light_at(global_position)
##   if lit > 0.6: hide()
##
##   # Which way is shade?
##   velocity = TimeSystem.get_shade_direction() * speed
##
##   # React when the star rises
##   func _ready():
##       TimeSystem.phase_changed.connect(_on_phase_changed)
##   func _on_phase_changed(new_phase, _old):
##       if new_phase == TimeSystem.Phase.RISING: wake_up()

# ── Phase enum ────────────────────────────────────────────────────────────────
## Semantic equivalent of "time of day" for this crater environment.
## Defined here (not in SkyManager) so any script can use TimeSystem.Phase
## without a separate import.
enum Phase {
	BELOW   = 0,  ## Star below the horizon — blood-moon crimson, dim light
	RISING  = 1,  ## Star crossing upward through the horizon (±3° window)
	ABOVE   = 2,  ## Star above the horizon — strawberry red-orange light
	SETTING = 3,  ## Star crossing downward through the horizon (±3° window)
}

# ── Live state (refreshed every frame from SkyManager) ────────────────────────
## Current semantic cycle phase.
var phase: Phase = Phase.BELOW

## True while the star's elevation is increasing.
var is_rising: bool = false

## True when star_elevation_deg > 0.
var is_above_horizon: bool = false

## Star elevation in degrees (-TILT_AMPLITUDE … +TILT_AMPLITUDE).
var elevation_deg: float = 0.0

## Star azimuth in degrees (0–360, clockwise from north).
var azimuth_deg: float = 0.0

## Unit vector FROM the scene TOWARD the star (world space).
var star_direction: Vector3 = Vector3.FORWARD

## Current light colour (transitions between blood-moon red and strawberry orange).
var light_color: Color = Color(0.54, 0.05, 0.03)

## 0–1 progress through the current planet rotation (short cycle, minutes).
var normalized_rotation: float = 0.0

## 0–1 progress through the current orbital period (long cycle, hours).
var normalized_orbit: float = 0.0

# ── Signals ───────────────────────────────────────────────────────────────────
## Emitted when the phase changes (e.g. BELOW → RISING at a horizon crossing).
## Connect from NPCs to trigger behaviour changes without polling every frame.
signal phase_changed(new_phase: Phase, old_phase: Phase)

# ── Convenience read-only properties ─────────────────────────────────────────
## True during the blood-moon phase (star below horizon, dim crimson light).
## Light-shy or nocturnal creatures are most active here.
var is_blood_moon: bool:
	get: return phase == Phase.BELOW

## True during the strawberry phase (star above horizon, warm red-orange light).
## Heat-tolerant creatures or day-active NPCs operate freely here.
var is_full_starlight: bool:
	get: return phase == Phase.ABOVE

## True during either horizon-crossing transition (RISING or SETTING).
var is_transitioning: bool:
	get: return phase == Phase.RISING or phase == Phase.SETTING

# ── Internal ──────────────────────────────────────────────────────────────────
var _sky_manager: Node = null

func _ready() -> void:
	# Defer so SkyManager has time to add itself to the group in its own _ready().
	call_deferred("_find_sky_manager")

func _process(_delta: float) -> void:
	if not is_instance_valid(_sky_manager):
		_find_sky_manager()
		return
	_sync()

func _find_sky_manager() -> void:
	_sky_manager = get_tree().get_first_node_in_group("sky_manager")
	if not _sky_manager:
		push_warning("[TimeSystem] SkyManager not found — ensure it is in the scene.")

func _sync() -> void:
	var sm := _sky_manager

	# Phase — detect change and emit signal.
	var new_phase := sm.phase as Phase
	if new_phase != phase:
		var old := phase
		phase = new_phase
		phase_changed.emit(phase, old)
	else:
		phase = new_phase

	is_rising        = sm.is_rising
	is_above_horizon = sm.is_above_horizon
	elevation_deg    = sm.star_elevation_deg
	azimuth_deg      = sm.star_azimuth_deg
	star_direction   = sm.star_direction
	light_color      = sm.light_color
	normalized_rotation = sm.rotation_time / sm.ROTATION_PERIOD
	normalized_orbit    = sm.orbital_time  / sm.ORBITAL_PERIOD

# ── Public helpers ────────────────────────────────────────────────────────────

## Returns estimated light intensity (0–1) at a world position.
## Factors in star direction and the position's angle within the crater.
## Use for stealth, visibility checks, and heat-avoidance decisions.
func get_light_at(world_pos: Vector3) -> float:
	if not is_instance_valid(_sky_manager):
		return 0.0
	return _sky_manager.get_light_at_position(world_pos)

## Returns true if world_pos is on the star-facing (brighter) side of the crater.
func is_bright_side(world_pos: Vector3) -> bool:
	var flat_star := Vector2(star_direction.x, star_direction.z).normalized()
	var flat_pos  := Vector2(world_pos.x, world_pos.z).normalized()
	return flat_star.dot(flat_pos) > 0.0

## Returns the horizontal world-space direction AWAY from the star.
## Light-shy or heat-avoiding NPCs should move in this direction for shade.
func get_shade_direction() -> Vector3:
	return -Vector3(star_direction.x, 0.0, star_direction.z).normalized()

## Returns the horizontal world-space direction TOWARD the star.
## Warmth-seeking NPCs should move in this direction.
func get_warmth_direction() -> Vector3:
	return Vector3(star_direction.x, 0.0, star_direction.z).normalized()
