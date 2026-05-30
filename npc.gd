extends CharacterBody3D

const SPEED        = 3.0
const GRAVITY_SCALE = 2.5

## Sync rate: broadcast position every N physics ticks (~20 hz at 60 hz physics).
const _RPC_INTERVAL: int = 3

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D

var _follow_target: Node3D = null

# ── Remote lerp targets (non-authority only) ────────────────────────────────
var _net_pos:        Vector3 = Vector3.ZERO
var _net_rot_y:      float   = 0.0
var _has_net_target: bool    = false

var _sync_tick: int = 0

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
		var next_pos := nav_agent.get_next_path_position()
		var dir := (next_pos - global_position)
		dir.y = 0.0
		if dir.length_squared() > 0.001:
			var dir_n := dir.normalized()
			velocity.x = dir_n.x * SPEED
			velocity.z = dir_n.z * SPEED
			# Face the direction of travel.
			rotation.y = lerp_angle(rotation.y, atan2(-dir_n.x, -dir_n.z), 10.0 * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)

	move_and_slide()

	# Rate-limited sync: ~20 hz instead of every physics tick (60 hz).
	if multiplayer.has_multiplayer_peer():
		_sync_tick += 1
		if _sync_tick >= _RPC_INTERVAL:
			_sync_tick = 0
			_rpc_state.rpc(global_position, rotation.y)

func _process(delta: float) -> void:
	if is_multiplayer_authority() or not _has_net_target:
		return
	var t := minf(delta * 15.0, 1.0)
	global_position = global_position.lerp(_net_pos, t)
	rotation.y      = lerp_angle(rotation.y, _net_rot_y, t)

func set_follow_target(target: Node3D) -> void:
	_follow_target = target

@rpc("authority", "unreliable_ordered")
func _rpc_state(pos: Vector3, body_y: float) -> void:
	_net_pos = pos; _net_rot_y = body_y; _has_net_target = true
