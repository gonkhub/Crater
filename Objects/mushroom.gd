extends CharacterBody3D

const SPEED = 2.0
const GRAVITY_SCALE = 2.5

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D

var _target: Vector3
var _has_target: bool = false

func _ready():
	if not is_multiplayer_authority():
		set_physics_process(false)
		return
	await get_tree().physics_frame
	var highest = _find_highest_nav_point()
	if highest != Vector3.ZERO:
		_target = highest
		_has_target = true

func _physics_process(delta):
	var gravity = get_gravity() * GRAVITY_SCALE
	if not is_on_floor():
		velocity += gravity * delta

	if _has_target:
		nav_agent.set_target_position(_target)
		if not nav_agent.is_navigation_finished():
			var next_pos = nav_agent.get_next_path_position()
			var dir = (next_pos - global_position).normalized()
			velocity.x = dir.x * SPEED
			velocity.z = dir.z * SPEED
		else:
			velocity.x = move_toward(velocity.x, 0, SPEED)
			velocity.z = move_toward(velocity.z, 0, SPEED)
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)

	move_and_slide()

	if multiplayer.has_multiplayer_peer():
		_sync_state.rpc(global_position, rotation.y)

func _find_highest_nav_point() -> Vector3:
	var regions = get_tree().root.find_children("*", "NavigationRegion3D", true, false)
	var best: Vector3
	var found := false
	for region in regions:
		var nav_mesh: NavigationMesh = region.navigation_mesh
		if nav_mesh == null:
			continue
		var xform: Transform3D = region.global_transform
		for v in nav_mesh.get_vertices():
			var world_v: Vector3 = xform * v
			if not found or world_v.y > best.y:
				best = world_v
				found = true
	return best if found else Vector3.ZERO

@rpc("authority", "unreliable_ordered")
func _sync_state(pos: Vector3, body_y: float):
	global_position = pos
	rotation.y = body_y
