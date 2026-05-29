class_name Holdable
extends Node

enum Weight { LIGHT, MEDIUM, HEAVY }

# Per-weight hold dynamics. Array index matches the Weight enum value.
# To tune feel system-wide, edit these rows.
# To tune a single object, use the Physics Overrides exports below.
#   sway_mouse_scale  — roll (axial spin) sensitivity to mouse input
#   sway_damping      — damping used during punch phases (higher = snappier)
#   sway_spring_k     — stiffness of the spring pulling sway to the mouse-target edge
#   sway_max_speed    — hard cap on sway angular velocity (rad/s)
#   sway_sensitivity  — mouse pixels/frame required to reach full opposite-edge amplitude;
#                       lower = more responsive, higher = needs a harder flick
#   roll_damping     — how quickly axial spin decays        (lower = coasts longer)
#   max_roll_speed   — hard cap on axial spin (rad/s)
#   punch_pull       — player velocity impulse (m/s) fired once when punch peaks
#   punch_accel      — extend-phase acceleration (m/s²); higher = snappier punch
#   punch_peak_hold  — seconds to dwell at max extension before settling
#   punch_settle_spd — retraction speed (m/s) from peak to the M1-held position
const _WEIGHT_PHYSICS = [
	# LIGHT  — nimble, quick to respond, moderate spin persistence
	{ "sway_mouse_scale": 0.010, "sway_damping": 0.30, "sway_spring_k": 14.0, "sway_max_speed":  8.0,
	  "sway_sensitivity": 18.0,
	  "roll_damping": 0.08, "max_roll_speed": 15.0,
	  "punch_pull":  2.0, "punch_accel": 220.0, "punch_peak_hold": 0.06, "punch_settle_spd": 1.2 },
	# MEDIUM — heavier feel, more resistance to input, spin coasts longer
	{ "sway_mouse_scale": 0.006, "sway_damping": 0.40, "sway_spring_k": 10.0, "sway_max_speed":  5.5,
	  "sway_sensitivity": 32.0,
	  "roll_damping": 0.05, "max_roll_speed":  8.0,
	  "punch_pull":  5.0, "punch_accel": 120.0, "punch_peak_hold": 0.12, "punch_settle_spd": 0.9 },
	# HEAVY  — ponderous, hard to start moving, very persistent spin (flywheel)
	{ "sway_mouse_scale": 0.003, "sway_damping": 0.60, "sway_spring_k":  6.0, "sway_max_speed":  3.5,
	  "sway_sensitivity": 52.0,
	  "roll_damping": 0.02, "max_roll_speed":  4.0,
	  "punch_pull": 10.0, "punch_accel":  55.0, "punch_peak_hold": 0.20, "punch_settle_spd": 0.6 },
]

# ── Hold ────────────────────────────────────────────────────────────────────
@export_group("Hold")

## Local Euler rotation applied on top of the carry system's facing direction.
## Use this to align the object's mesh with the pivot axis.
## Example: Vector3(-90, 0, 0) rotates a Y-axis capsule to point toward the
## anchor (screen-centre end). Leave at zero for symmetric / round objects.
@export var hold_rotation: Vector3 = Vector3.ZERO

## Half-length of the object along the hold axis (metres).
## Defines the radius of the sway circle and how far the tip sits from centre.
## 0 = static carry with no sway.
## Typical values: 0.15 for compact objects, 0.5–0.7 for long weapons.
@export_range(0.0, 1.5, 0.05) var hold_pivot: float = 0.15

## Weight class — sets the baseline physics from the _WEIGHT_PHYSICS table.
## Override individual values below without changing the bucket.
@export var weight: Weight = Weight.LIGHT

# ── Actions ─────────────────────────────────────────────────────────────────
@export_group("Actions")

## Action fired by the primary (left) mouse button while holding.
## Built-in: "punch", "throw". Leave empty to disable.
@export var m1_action: String = "punch"

## Action fired by the secondary (right) mouse button while holding.
## Leave empty to disable.
@export var m2_action: String = ""

## Action fired by scroll-up while holding.
@export var scroll_up_action: String = "throw"

# ── Physics Overrides ────────────────────────────────────────────────────────
@export_group("Physics Overrides")
## Per-object overrides for the weight-bucket physics values.
## Leave at 0 to inherit from the weight bucket. Any non-zero value replaces
## that specific parameter for this object only.

## Mouse input sensitivity. Overrides sway_mouse_scale from the weight bucket.
@export_range(0.0, 0.03, 0.001) var override_mouse_scale: float = 0.0

## Position angular damping per second. Overrides sway_damping.
@export_range(0.0, 2.0, 0.05) var override_sway_damping: float = 0.0

## Axial spin decay per second. Overrides roll_damping.
@export_range(0.0, 0.5, 0.005) var override_roll_damping: float = 0.0

## Hard cap on axial spin speed (rad/s). Overrides max_roll_speed.
@export_range(0.0, 30.0, 0.5) var override_max_roll_speed: float = 0.0

# ────────────────────────────────────────────────────────────────────────────

## Returns the effective physics dictionary for this object: the weight bucket
## with any non-zero per-object overrides applied on top.
func get_dynamics() -> Dictionary:
	var d: Dictionary = _WEIGHT_PHYSICS[weight].duplicate()
	if override_mouse_scale    > 0.0: d["sway_mouse_scale"] = override_mouse_scale
	if override_sway_damping   > 0.0: d["sway_damping"]     = override_sway_damping
	if override_roll_damping   > 0.0: d["roll_damping"]      = override_roll_damping
	if override_max_roll_speed > 0.0: d["max_roll_speed"]   = override_max_roll_speed
	return d

func _ready():
	# Auto-register "Take" so designers don't have to list it manually.
	var interactable = _get_interactable()
	if interactable and "Take" not in interactable.actions:
		interactable.actions.push_front("Take")

func _get_interactable() -> Interactable:
	for child in get_parent().get_children():
		if child is Interactable:
			return child
	return null
