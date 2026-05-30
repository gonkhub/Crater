## Base script for simple physics props.
##
## Attach to any RigidBody3D that should participate in the world-object
## broadcast and interact with the hold system.  Replaces per-object
## boilerplate (group registration, CCD).
##
## For objects that need custom behaviour, extend this script instead of
## repeating the boilerplate, or use it as-is for generic props.

extends RigidBody3D

func _ready() -> void:
	add_to_group("world_objects")
	# Continuous collision detection prevents tunnelling through thin geometry
	# at high velocity (throw, punch, spawn with momentum).
	continuous_cd = true
