class_name Interactable
extends Node

signal action_performed(action: String, by_player: Node)

@export var display_name: String = "Object"
@export var actions: Array[String] = []

# Set by the player holding this object; prevents others from taking it.
var is_held: bool = false
