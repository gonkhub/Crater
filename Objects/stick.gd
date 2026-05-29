extends RigidBody3D

func _ready():
	add_to_group("world_objects")
	continuous_cd = true   # prevent tunnelling through thin geometry from spawn
