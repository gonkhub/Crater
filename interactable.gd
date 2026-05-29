class_name Interactable
extends Node

signal action_performed(action: String, by_player: Node)

@export var display_name: String = "Object"
@export var description: String = ""
@export var actions: Array[String] = []

# Set by the player holding this object; prevents others from taking it.
var is_held: bool = false

func _ready():
	# "Info" is available on every interactable — always appended last.
	if "Info" not in actions:
		actions.append("Info")
