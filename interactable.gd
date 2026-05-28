class_name Interactable
extends Node

@export var display_name: String = "Object"
@export var actions: Array[String] = ["Take"]
@export var hold_rotation: Vector3 = Vector3.ZERO
@export var m1_action: String = "punch"
@export var m2_action: String = ""
@export var scroll_up_action: String = "throw"

# Locked by the player holding this object; prevents others from taking it.
var is_held: bool = false
