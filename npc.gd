extends CharacterBody3D

const SPEED = 3.0
const GRAVITY_SCALE = 2.5

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D

var _follow_target: Node3D = null

# ── Remote lerp targets (non-authority only) ────────────────────────────────
var _net_pos:       Vector3 = Vector3.ZERO
var _net_rot_y:     float   = 0.0
var _has_net_target: bool   = false

func _ready():
	if not is_multiplayer_authority():
		set_physics_process(false)
		return

func _physics_process(delta):
	var gravity = get_gravity() * GRAVITY_SCALE
	if not is_on_floor():
		velocity += gravity * delta

	if _follow_target:
		nav_agent.set_target_position(_follow_target.global_position)

	if not nav_agent.is_navigation_finished():
		var next_pos = nav_agent.get_next_path_position()
		var dir = (next_pos - global_position).normalized()
		velocity.x = dir.x * SPEED
		velocity.z = dir.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)

	move_and_slide()

	if multiplayer.has_multiplayer_peer():
		_sync_npc_state.rpc(global_position, rotation.y)

func _process(delta: float) -> void:
	if is_multiplayer_authority() or not _has_net_target:
		return
	global_position = global_position.lerp(_net_pos, delta * 15.0)
	rotation.y      = lerp_angle(rotation.y, _net_rot_y, delta * 15.0)

func set_follow_target(target: Node3D):
	_follow_target = target

@rpc("authority", "unreliable_ordered")
func _sync_npc_state(pos: Vector3, body_y: float):
	_net_pos = pos; _net_rot_y = body_y; _has_net_target = true
