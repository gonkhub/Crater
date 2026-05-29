class_name Holdable
extends Node

@export var hold_rotation: Vector3 = Vector3.ZERO
@export var hold_pivot: float = 0.15  # world-space distance from object centre to the far (screen-centre) end
                                      # 0 = static hold (no sway). Default 0.15 gives subtle sway for compact objects.
@export var m1_action: String = "punch"
@export var m2_action: String = ""
@export var scroll_up_action: String = "throw"

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
