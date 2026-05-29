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
var SWAY_SPRING = 80.0        # spring constant pulling close end onto the circle (units/s²/unit)
var SWAY_DAMPING = 5.0        # exponential damping rate (per second)
var SWAY_MOUSE_SCALE = 0.004  # pixels → sway velocity (units/s)
var SWAY_TILT_SCALE = 0.5     # sway_pos units → tilt radians (no-pivot objects only)

var sliding := false
var tab_mode := false
var _sway_pos: Vector2 = Vector2.ZERO   # camera-local XY displacement of the close end (world units)
var _sway_vel: Vector2 = Vector2.ZERO   # derivative of _sway_pos (units/s)
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
	_sway_pos = Vector2.ZERO
	_sway_vel = Vector2.ZERO
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

	# ── Sway physics ──────────────────────────────────────────────────────────
	# The far (screen-centre) end of the object is anchored at the camera's
	# forward look point.  The close (player-side) end floats on an imaginary
	# circle of radius = hold_pivot, pushed back onto it by an elastic spring.
	# When hold_pivot == 0 the same spring collapses to a centre-restore, and
	# the sway is expressed purely as a tilt rotation around the carry position.
	var pivot := held_holdable.hold_pivot if held_holdable else 0.0

	# Consume accumulated mouse delta — drives the close end laterally
	_sway_vel += _mouse_delta * SWAY_MOUSE_SCALE
	_mouse_delta = Vector2.ZERO

	if pivot > 0.001:
		# Elastic force: pull _sway_pos toward the circle of radius = pivot.
		# Force = k * (R - |pos|) * pos_dir  →  positive inside circle, negative outside.
		var dist := _sway_pos.length()
		if dist > 0.0001:
			_sway_vel += (pivot - dist) * (_sway_pos / dist) * SWAY_SPRING * delta
		else:
			# At the exact centre there is no direction; give a downward nudge
			# so the spring settles to the natural bottom-of-circle rest.
			_sway_vel += Vector2(0.0, -1.0) * pivot * SWAY_SPRING * delta
	else:
		# No pivot: spring toward the centre (pure tilt effect)
		_sway_vel -= _sway_pos * SWAY_SPRING * delta

	# Exponential damping (applied uniformly regardless of punch state)
	_sway_vel *= maxf(0.0, 1.0 - SWAY_DAMPING * delta)
	_sway_pos += _sway_vel * delta

	# ── Object transform ──────────────────────────────────────────────────────
	var rotation_offset: Basis = Basis.from_euler(held_holdable.hold_rotation * (PI / 180.0)) if held_holdable else Basis.IDENTITY

	var cam_basis := camera.global_transform.basis
	var cam_pos   := camera.global_position
	var depth     := CARRY_DISTANCE + punch_offset  # positive scalar

	var target_pos: Vector3
	var target_basis: Basis

	if pivot > 0.001:
		# Far end is anchored at the camera-forward point (screen centre).
		# In camera-local space:
		#   far_end  = (0, 0, -depth)
		#   close_end = (_sway_pos.x, _sway_pos.y, -depth + 2*pivot)   [+Z is toward player]
		#   centre    = average = (_sway_pos.x/2, _sway_pos.y/2, -depth + pivot)
		target_pos = cam_pos + cam_basis * Vector3(
			_sway_pos.x * 0.5,
			_sway_pos.y * 0.5,
			-depth + pivot
		)

		# Object "forward" = direction from close end to far end (camera-local)
		#   = far_end - close_end = (-sx, -sy, -2*pivot)
		var fwd_cam  := Vector3(-_sway_pos.x, -_sway_pos.y, -2.0 * pivot).normalized()
		var fwd_world := cam_basis * fwd_cam

		# Build a Basis whose -Z aligns with fwd_world.
		# Guard against fwd being parallel to cam up (degenerate cross-product).
		var up_ref := cam_basis.y
		if abs(fwd_world.dot(up_ref)) > 0.999:
			up_ref = cam_basis.x
		target_basis = Basis.looking_at(fwd_world, up_ref) * rotation_offset
	else:
		# No-pivot path: centre sits at the camera-forward point; sway is
		# expressed as a tilt rotation around the carry position.
		target_pos = cam_pos + cam_basis * Vector3(0.0, 0.0, -depth)
		var tilt := Basis.from_euler(
			Vector3(-_sway_pos.y, _sway_pos.x, 0.0) * SWAY_TILT_SCALE
		)
		target_basis = cam_basis * tilt * rotation_offset

	# ── Collision sweep ───────────────────────────────────────────────────────
	var motion := target_pos - held_object.global_position
	_test_params.from = held_object.global_transform
	_test_params.motion = motion
	if PhysicsServer3D.body_test_motion(held_object.get_rid(), _test_params, _test_result):
		target_pos = held_object.global_position + _test_result.get_travel()
		if punch_held and punch_velocity > 0.0:
			var punch_dir := -camera.global_transform.basis.z
			velocity -= punch_dir * punch_velocity * PUNCH_PUSHBACK * delta

	if punch_measuring:
		var frame_speed := held_object.global_position.distance_to(target_pos) / delta
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
