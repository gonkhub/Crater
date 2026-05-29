extends CharacterBody3D

var SPEED = 5.0
var JUMP_VELOCITY = 7.0
var MOUSE_SENSITIVITY = 0.003
var GRAVITY_SCALE = 2.5
var SLIDE_FRICTION = 4.0
var INTERACT_RANGE = 5.0
var CARRY_DISTANCE = 2.0
var PUNCH_DISTANCE = 1.5
var PUNCH_ACCEL = 120.0
var PUNCH_RETURN_SPEED = 3.5
var PUNCH_IMPULSE = 10.0
var THROW_SPEED = 15.0
var MAX_CARRY_DIST = 7.0
var PUNCH_COOLDOWN = 0.5
var PUNCH_PUSHBACK = 0.4
var SWAY_DAMPING = 0.3        # angular damping rate (per second) — low = very slippery
var SWAY_MOUSE_SCALE = 0.008  # pixels → angular velocity (rad/s, scaled by 1/pivot)
var ENDPOINT_MARGIN = 0.06    # minimum clearance between object endpoints and surfaces

var sliding := false
var tab_mode := false
var _sway_angle: float = -PI / 2.0  # angle of close end on the circle (−½π = bottom = natural rest)
var _sway_ang_vel: float = 0.0      # angular velocity (rad/s, + = counterclockwise)
var _mouse_delta: Vector2 = Vector2.ZERO # accumulated mouse movement since last carry update
var held_object: PhysicsBody3D = null
var held_interactable: Interactable = null
var held_holdable: Holdable = null
var punch_offset: float = 0.0
var punch_velocity: float = 0.0
var punch_held: bool = false
var punch_cooldown: float = 0.0
var punch_measuring: bool = false
var punch_peak_speed: float = 0.0
var punch_target_name: String = ""
var _hud: Node = null

@onready var camera: Camera3D = $Camera3D

var _test_params := PhysicsTestMotionParameters3D.new()
var _test_result := PhysicsTestMotionResult3D.new()

func _is_mp_connected() -> bool:
	return multiplayer.has_multiplayer_peer() and \
		multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func _ready():
	if not is_multiplayer_authority():
		set_physics_process(false)
		var mesh_instance = MeshInstance3D.new()
		var capsule = CapsuleMesh.new()
		capsule.radius = 0.3
		capsule.height = 1.8
		mesh_instance.mesh = capsule
		add_child(mesh_instance)
		return
	_test_params.exclude_bodies = [get_rid()]
	camera.current = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# Called by world.gd after spawning the local player — no fragile path lookup needed.
func init_local(hud_node: Node) -> void:
	_hud = hud_node
	if not _hud:
		return
	_hud.action_chosen.connect(_on_action_chosen)
	_hud.set_local_player(self)

func _process(delta):
	if not is_multiplayer_authority():
		return
	var prev_cooldown = punch_cooldown
	punch_cooldown = maxf(punch_cooldown - delta, 0.0)
	if punch_measuring and prev_cooldown > 0.0 and punch_cooldown <= 0.0:
		print("[punch] peak speed on '%s': %.1f u/s" % [punch_target_name, punch_peak_speed])
		punch_measuring = false
	if held_object:
		_carry_update(delta)
	if not _hud:
		return
	if not tab_mode:
		_hud.hide_hover_label()
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var origin = camera.project_ray_origin(mouse_pos)
	var ray_end = origin + camera.project_ray_normal(mouse_pos) * INTERACT_RANGE
	var params = PhysicsRayQueryParameters3D.create(origin, ray_end)
	params.exclude = [get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(params)
	if hit:
		var interactable = _find_interactable(hit.collider)
		if interactable:
			_hud.show_hover_label(mouse_pos, interactable.display_name)
		else:
			_hud.show_hover_label(mouse_pos, hit.collider.name + " (no tag)")
	else:
		_hud.hide_hover_label()

func _unhandled_input(event):
	if not is_multiplayer_authority():
		return

	# Click to recapture mouse when free (not in tab mode)
	if event is InputEventMouseButton and event.pressed and not tab_mode:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return

	# Held object inputs (mouse captured, not in tab mode)
	if held_object and not tab_mode and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseButton:
			if event.pressed:
				match event.button_index:
					MOUSE_BUTTON_LEFT:
						_try_held_action("m1")
						return
					MOUSE_BUTTON_RIGHT:
						_try_held_action("m2")
						return
					MOUSE_BUTTON_WHEEL_UP:
						_try_held_action("scroll_up")
						return
			elif event.button_index == MOUSE_BUTTON_LEFT:
				punch_held = false
				return

	# Tab: toggle HUD interact mode
	if event is InputEventKey and not event.echo and event.pressed:
		if event.physical_keycode == KEY_TAB:
			tab_mode = !tab_mode
			if _hud:
				_hud.hide_action_menu()
				_hud.hide_hover_label()
			if tab_mode:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			elif not (_hud and _hud.pause_overlay.visible):
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return

	# Mouse look (only when captured)
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			return
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)
		if held_object:
			_mouse_delta += event.relative

	# Left click in tab mode
	if tab_mode and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if _hud and _hud.is_action_menu_visible():
				_hud.hide_action_menu()
			elif held_object:
				_release_object()
			else:
				_try_interact()

func _physics_process(delta):
	var gravity = get_gravity() * GRAVITY_SCALE

	if not is_on_floor():
		velocity += gravity * delta

	sliding = Input.is_action_pressed("slide") and is_on_floor()

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		sliding = false

	if sliding:
		var floor_normal = get_floor_normal()
		# Component of gravity tangent to the slope — pulls downhill, resists uphill
		var slope_accel = gravity - gravity.dot(floor_normal) * floor_normal
		velocity += slope_accel * delta
		var horiz = Vector3(velocity.x, 0, velocity.z)
		if horiz.length() > 0:
			var decel = minf(SLIDE_FRICTION * delta, horiz.length())
			velocity.x -= horiz.normalized().x * decel
			velocity.z -= horiz.normalized().z * decel
	elif is_on_floor():
		var input_dir = Input.get_vector("left", "right", "up", "down")
		var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
		if direction:
			velocity.x = direction.x * SPEED
			velocity.z = direction.z * SPEED
		else:
			velocity.x = move_toward(velocity.x, 0, SPEED)
			velocity.z = move_toward(velocity.z, 0, SPEED)

	move_and_slide()

	if _is_mp_connected():
		_sync_state.rpc(global_position, rotation.y, camera.rotation.x)
		if held_object:
			_sync_held_object.rpc(str(held_object.get_path()), held_object.global_transform)

func _try_interact():
	var mouse_pos = get_viewport().get_mouse_position()
	var origin = camera.project_ray_origin(mouse_pos)
	var ray_end = origin + camera.project_ray_normal(mouse_pos) * INTERACT_RANGE
	var params = PhysicsRayQueryParameters3D.create(origin, ray_end)
	params.exclude = [get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(params)
	if not hit:
		return
	var interactable = _find_interactable(hit.collider)
	if not interactable:
		return
	# Strip actions that are currently unavailable (e.g. Take on a held object).
	var available: Array[String] = []
	for a in interactable.actions:
		if a == "Take" and interactable.is_held:
			continue
		available.append(a)
	if available.is_empty():
		return
	if _hud:
		_hud.show_action_menu(mouse_pos, hit.collider, interactable.display_name, available)

func _find_interactable(node: Node) -> Interactable:
	for child in node.get_children():
		if child is Interactable:
			return child
	return null

func _find_holdable(node: Node) -> Holdable:
	for child in node.get_children():
		if child is Holdable:
			return child
	return null

func _on_action_chosen(action: String, target: Node):
	match action:
		"Take":
			var holdable = _find_holdable(target)
			if target is RigidBody3D and holdable:
				held_object = target
				held_object.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				held_object.freeze = true
				held_interactable = _find_interactable(target)
				held_holdable = holdable
				if held_interactable:
					held_interactable.is_held = true
				if _is_mp_connected():
					_sync_take_object.rpc(str(held_object.get_path()))
				tab_mode = false
				if not (_hud and _hud.pause_overlay.visible):
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			elif target is CharacterBody3D and holdable:
				held_object = target
				held_interactable = _find_interactable(target)
				held_holdable = holdable
				if target.is_multiplayer_authority():
					target.set_physics_process(false)
				if held_interactable:
					held_interactable.is_held = true
				if _is_mp_connected():
					_sync_take_object.rpc(str(held_object.get_path()))
				tab_mode = false
				if not (_hud and _hud.pause_overlay.visible):
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		_:
			var interactable = _find_interactable(target)
			if interactable:
				interactable.action_performed.emit(action, self)

func _reset_held_state():
	held_object = null
	held_interactable = null
	held_holdable = null
	punch_offset = 0.0
	punch_velocity = 0.0
	punch_held = false
	punch_cooldown = 0.0
	punch_measuring = false
	_sway_angle = -PI / 2.0
	_sway_ang_vel = 0.0
	_mouse_delta = Vector2.ZERO

func _release_object():
	if not held_object:
		return
	if held_object is RigidBody3D:
		held_object.freeze = false
		held_object.linear_velocity = velocity
		if _is_mp_connected():
			_sync_release_object.rpc(str(held_object.get_path()), held_object.global_position, velocity)
	elif held_object is CharacterBody3D:
		if held_object.is_multiplayer_authority():
			held_object.set_physics_process(true)
		if _is_mp_connected():
			_sync_release_object.rpc(str(held_object.get_path()), held_object.global_position, Vector3.ZERO)
	if held_interactable:
		held_interactable.is_held = false
	_reset_held_state()

func _try_held_action(input: String):
	if not held_holdable:
		return
	var action: String
	match input:
		"m1": action = held_holdable.m1_action
		"m2": action = held_holdable.m2_action
		"scroll_up": action = held_holdable.scroll_up_action
	if action.is_empty():
		return
	match action:
		"punch": _do_punch()
		"throw": _do_throw()
		_:
			if held_interactable:
				held_interactable.action_performed.emit(action, self)

func _do_punch():
	if punch_cooldown > 0.0:
		return
	punch_cooldown = PUNCH_COOLDOWN
	punch_held = true
	punch_velocity = 0.0
	punch_measuring = true
	punch_peak_speed = 0.0
	punch_target_name = held_object.name
	print("[punch] player %d punched '%s'" % [multiplayer.get_unique_id(), punch_target_name])
	var punch_dir = -camera.global_transform.basis.z
	var from = camera.global_position
	var to = from + punch_dir * (CARRY_DISTANCE + PUNCH_DISTANCE)
	var params = PhysicsRayQueryParameters3D.create(from, to)
	params.exclude = [get_rid(), held_object.get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(params)
	if hit and hit.collider is RigidBody3D:
		hit.collider.apply_central_impulse(punch_dir * PUNCH_IMPULSE)

func _do_throw():
	if not held_object:
		return
	print("[throw] player %d threw '%s'" % [multiplayer.get_unique_id(), held_object.name])
	if held_object is RigidBody3D:
		var throw_dir = -camera.global_transform.basis.z
		var throw_vel = velocity + throw_dir * THROW_SPEED
		held_object.freeze = false
		held_object.linear_velocity = throw_vel
		if _is_mp_connected():
			_sync_release_object.rpc(str(held_object.get_path()), held_object.global_position, throw_vel)
	elif held_object is CharacterBody3D:
		if held_object.is_multiplayer_authority():
			held_object.set_physics_process(true)
		if _is_mp_connected():
			_sync_release_object.rpc(str(held_object.get_path()), held_object.global_position, Vector3.ZERO)
	if held_interactable:
		held_interactable.is_held = false
	_reset_held_state()

func _carry_update(delta: float):
	if not is_instance_valid(held_object):
		if is_instance_valid(held_interactable):
			held_interactable.is_held = false
		_reset_held_state()
		return
	if held_object.global_position.distance_to(camera.global_position) > MAX_CARRY_DIST:
		_release_object()
		return

	# ── Punch offset ─────────────────────────────────────────────────────────
	if punch_held:
		if punch_offset < PUNCH_DISTANCE:
			punch_velocity += PUNCH_ACCEL * delta
			punch_offset = minf(punch_offset + punch_velocity * delta, PUNCH_DISTANCE)
	else:
		punch_velocity = 0.0
		punch_offset = move_toward(punch_offset, 0.0, PUNCH_RETURN_SPEED * delta)

	# ── Sway physics (polar / angular) ───────────────────────────────────────
	# The close end rotates around the anchor circle in a single angular degree
	# of freedom. Mouse movement is projected onto the circle's tangent so only
	# rotational impulse is added — no radial spring, no bouncing.
	var pivot: float = held_holdable.hold_pivot if held_holdable else 0.0

	# Tangent direction at the current angle (counterclockwise = + angle)
	var tangent: Vector2 = Vector2(-sin(_sway_angle), cos(_sway_angle))
	# Project mouse onto tangent; negate so looking-left spins the close end
	# rightward (positive angle = counterclockwise = toward the right from bottom)
	_sway_ang_vel -= _mouse_delta.dot(tangent) * SWAY_MOUSE_SCALE / maxf(pivot, 0.25)
	_mouse_delta = Vector2.ZERO

	if punch_held:
		# Heavier damping during punch so spin settles while straightening
		_sway_ang_vel *= maxf(0.0, 1.0 - SWAY_DAMPING * 8.0 * delta)
	else:
		_sway_ang_vel *= maxf(0.0, 1.0 - SWAY_DAMPING * delta)
		_sway_angle   += _sway_ang_vel * delta

	# Cartesian position of the close end, used by the transform below.
	# During punch the object straightens (sway_pos = 0 → tip and butt aligned).
	var sway_pos: Vector2 = Vector2.ZERO
	if not punch_held and pivot > 0.001:
		sway_pos = Vector2(cos(_sway_angle), sin(_sway_angle)) * pivot

	# ── Object transform + endpoint collision protection ─────────────────────
	# For pivot objects the system runs two raycasts every frame:
	#   Ray 1 (anchor / tip)  — camera → intended tip position.
	#     If geometry is in the way, depth is shortened so the tip stays clear.
	#   Ray 2 (butt / close end) — tip → intended butt position.
	#     If geometry is in the way, the butt is clamped back and angular
	#     velocity is killed so the object doesn't keep pushing into the surface.
	# The existing body_test_motion sweep then handles linear centre-motion for
	# all objects (pivot and no-pivot alike).
	var rotation_offset: Basis = Basis.from_euler(held_holdable.hold_rotation * (PI / 180.0)) if held_holdable else Basis.IDENTITY

	var cam_basis: Basis   = camera.global_transform.basis
	var cam_pos:   Vector3 = camera.global_position
	var depth: float       = CARRY_DISTANCE + punch_offset

	var target_pos:   Vector3
	var target_basis: Basis

	if pivot > 0.001:
		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
		ray.exclude = [get_rid(), held_object.get_rid()]

		# ── Ray 1: anchor (tip / far end) ────────────────────────────────────
		# Prevents the tip from passing into any surface in front of the player.
		var anchor: Vector3 = cam_pos + cam_basis * Vector3(0.0, 0.0, -depth)
		ray.from = cam_pos
		ray.to   = anchor
		var tip_hit: Dictionary = space.intersect_ray(ray)
		if tip_hit:
			# Minimum depth = 2*pivot + margin so the butt end never crosses
			# behind the camera plane and into the player's collision capsule.
			var min_depth: float = 2.0 * pivot + ENDPOINT_MARGIN
			depth  = maxf(cam_pos.distance_to(tip_hit.position) - ENDPOINT_MARGIN, min_depth)
			anchor = cam_pos + cam_basis * Vector3(0.0, 0.0, -depth)

		# ── Pivot-path transform (computed with post-ray depth) ───────────────
		# Camera-local layout:
		#   tip    = (0,          0,          -depth)
		#   butt   = (sway_pos.x, sway_pos.y, -depth + 2*pivot)
		#   centre = midpoint
		target_pos = cam_pos + cam_basis * Vector3(
			sway_pos.x * 0.5, sway_pos.y * 0.5, -depth + pivot
		)
		var fwd_cam:   Vector3 = Vector3(-sway_pos.x, -sway_pos.y, -2.0 * pivot).normalized()
		var fwd_world: Vector3 = cam_basis * fwd_cam
		var up_ref:    Vector3 = cam_basis.y
		if abs(fwd_world.dot(up_ref)) > 0.999:
			up_ref = cam_basis.x
		target_basis = Basis.looking_at(fwd_world, up_ref) * rotation_offset

		# ── Ray 2: butt (close end) ───────────────────────────────────────────
		# Prevents the butt from embedding into geometry behind the anchor.
		# Because centre = (anchor + butt) / 2, butt = 2*centre - anchor.
		var butt: Vector3 = 2.0 * target_pos - anchor
		ray.from = anchor
		ray.to   = butt
		var butt_hit: Dictionary = space.intersect_ray(ray)
		if butt_hit:
			var butt_dir:  Vector3 = (butt - anchor).normalized()
			var safe_dist: float   = maxf(anchor.distance_to(butt_hit.position) - ENDPOINT_MARGIN, 0.0)
			var safe_butt: Vector3 = anchor + butt_dir * safe_dist
			target_pos = (anchor + safe_butt) * 0.5
			var new_fwd: Vector3 = (anchor - safe_butt).normalized()
			if abs(new_fwd.dot(up_ref)) > 0.999:
				up_ref = cam_basis.x
			target_basis   = Basis.looking_at(new_fwd, up_ref) * rotation_offset
			_sway_ang_vel  = 0.0  # kill angular velocity into the surface
	else:
		# No-pivot path: centre at camera-forward point, no sway tilt.
		target_pos   = cam_pos + cam_basis * Vector3(0.0, 0.0, -depth)
		target_basis = cam_basis * rotation_offset

	# ── Centre sweep (all objects) ────────────────────────────────────────────
	# Catches linear-motion penetration that the endpoint rays don't cover.
	var motion: Vector3 = target_pos - held_object.global_position
	_test_params.from   = held_object.global_transform
	_test_params.motion = motion
	if PhysicsServer3D.body_test_motion(held_object.get_rid(), _test_params, _test_result):
		target_pos = held_object.global_position + _test_result.get_travel()
		if punch_held and punch_velocity > 0.0:
			var punch_dir: Vector3 = -camera.global_transform.basis.z
			velocity -= punch_dir * punch_velocity * PUNCH_PUSHBACK * delta

	if punch_measuring:
		var frame_speed: float = held_object.global_position.distance_to(target_pos) / delta
		punch_peak_speed = maxf(punch_peak_speed, frame_speed)

	held_object.global_transform = Transform3D(target_basis, target_pos)

# ── Multiplayer RPCs ────────────────────────────────────────────────────────

@rpc("any_peer", "reliable")
func _sync_take_object(obj_path: String):
	var obj = get_tree().root.get_node_or_null(obj_path)
	if obj is RigidBody3D:
		obj.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		obj.freeze = true
		var interactable = _find_interactable(obj)
		if interactable:
			interactable.is_held = true
	elif obj is CharacterBody3D:
		if obj.is_multiplayer_authority():
			obj.set_physics_process(false)
		var interactable = _find_interactable(obj)
		if interactable:
			interactable.is_held = true
	else:
		push_warning("[sync] _sync_take_object: node not found or unsupported type: %s" % obj_path)

@rpc("any_peer", "unreliable_ordered")
func _sync_held_object(obj_path: String, xform: Transform3D):
	var obj = get_tree().root.get_node_or_null(obj_path)
	if obj:
		obj.global_transform = xform

@rpc("any_peer", "reliable")
func _sync_release_object(obj_path: String, pos: Vector3, vel: Vector3):
	var obj = get_tree().root.get_node_or_null(obj_path)
	if obj is RigidBody3D:
		obj.freeze = false
		obj.global_position = pos
		obj.linear_velocity = vel
		var interactable = _find_interactable(obj)
		if interactable:
			interactable.is_held = false
	elif obj is CharacterBody3D:
		obj.global_position = pos
		if obj.is_multiplayer_authority():
			obj.set_physics_process(true)
		var interactable = _find_interactable(obj)
		if interactable:
			interactable.is_held = false
	else:
		push_warning("[sync] _sync_release_object: node not found: %s" % obj_path)

@rpc("any_peer", "unreliable_ordered")
func _sync_state(pos: Vector3, body_y: float, cam_x: float):
	global_position = pos
	rotation.y = body_y
	camera.rotation.x = cam_x
