class_name Holdable
extends Node

enum Weight { LIGHT, MEDIUM, HEAVY }

@export var hold_rotation: Vector3 = Vector3.ZERO
@export var hold_pivot: float = 0.15  # world-space distance from object centre to the far (screen-centre) end
                                      # 0 = static hold (no sway). Default 0.15 gives subtle sway for compact objects.
@export var weight: Weight = Weight.LIGHT
@export var m1_action: String = "punch"
@export var m2_action: String = ""
@export var scroll_up_action: String = "throw"

# Per-weight hold dynamics. Index matches the Weight enum value.
#   sway_mouse_scale — mouse input sensitivity for both position and spin impulse
#   sway_damping     — how quickly angular position decays (higher = snappier stop)
#   roll_damping     — how quickly axial spin decays (lower = spins much longer)
#   max_roll_speed   — hard cap on axial spin rate (rad/s)
const _WEIGHT_PHYSICS = [
	# LIGHT  — nimble, quick to respond, moderate spin persistence
	{ "sway_mouse_scale": 0.010, "sway_damping": 0.30, "roll_damping": 0.08, "max_roll_speed": 15.0 },
	# MEDIUM — heavier feel, more resistance to input, spin coasts longer
	{ "sway_mouse_scale": 0.006, "sway_damping": 0.40, "roll_damping": 0.05, "max_roll_speed":  8.0 },
	# HEAVY  — ponderous, hard to start moving, very persistent spin (flywheel)
	{ "sway_mouse_scale": 0.003, "sway_damping": 0.60, "roll_damping": 0.02, "max_roll_speed":  4.0 },
]

func get_dynamics() -> Dictionary:
	return _WEIGHT_PHYSICS[weight]

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
