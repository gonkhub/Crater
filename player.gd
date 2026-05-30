extends CharacterBody3D

var SPEED = 5.0
var JUMP_VELOCITY = 7.0
var MOUSE_SENSITIVITY = 0.003
var GRAVITY_SCALE = 2.5
var SLIDE_FRICTION = 4.0
var INTERACT_RANGE = 5.0
var CARRY_DISTANCE = 2.0
var CARRY_OFFSET_X: float =  0.0    # camera-right offset for carry anchor (m)
var CARRY_OFFSET_Y: float = -0.35   # camera-down  offset for carry anchor (m)
var PUNCH_DISTANCE = 1.5
var PUNCH_ACCEL = 120.0
var PUNCH_RETURN_SPEED = 3.5
var PUNCH_IMPULSE = 10.0
var THROW_SPEED = 15.0
var MAX_CARRY_DIST = 7.0
var PUNCH_COOLDOWN = 0.5
var PUNCH_PUSHBACK = 0.4
var PUNCH_SETTLE_FRAC: float = 0.65  # settle at this fraction of PUNCH_DISTANCE while M1 held
var SWAY_DAMPING = 0.3        # position damping rate (per second)
var ROLL_DAMPING = 0.08       # axial-spin damping — much lower so spin coasts freely
var SWAY_MOUSE_SCALE = 0.008  # pixels → angular velocity (rad/s, scaled by 1/pivot)
var ENDPOINT_MARGIN = 0.06    # minimum clearance between object endpoints and surfaces

var _sliding  := false
var _tab_mode := false
var _noclip   := false
var _sway_angle: float = -PI / 2.0   # position of close end on the circle (−½π = bottom)
var _sway_ang_vel: float = 0.0       # position angular velocity (rad/s)
var _sway_target:    float = -PI / 2.0  # spring target angle
var _sway_amplitude: float = 0.0        # current deflection 0 (rest) → 1 (full opposite edge)
var _sway_direction: float = 0.0        # last mouse direction angle (for change detection)
var _roll_angle: float = -PI / 2.0   # axial spin angle (starts matched to sway rest)
var _roll_ang_vel: float = 0.0       # axial spin angular velocity (rad/s)
var _mouse_delta: Vector2 = Vector2.ZERO # accumulated mouse movement since last carry update

var _held_object:       PhysicsBody3D = null
var _held_interactable: Interactable  = null
var _held_holdable:     Holdable      = null

var _punch_offset:      float  = 0.0
var _punch_vel:         float  = 0.0
var _punch_held:        bool   = false
var _punch_cooldown:    float  = 0.0
var _punch_peaked:      bool   = false
var _punch_hold_timer:  float  = 0.0   # countdown at max extension before settling begins
var _punch_start_angle: float  = 0.0   # sway angle when punch was initiated
var _punch_returning:   bool   = false # true while spring is guiding sway to opposite side
var _punch_measuring:   bool   = false
var _punch_peak_speed:  float  = 0.0
var _punch_target_name: String = ""
var _lunge_active:      bool   = false # true only when punch fully extended AND w_pull > 0

var _hud: Node = null

# ── Remote-player lerp targets (non-authority only) ─────────────────────────
var _net_pos:        Vector3 = Vector3.ZERO
var _net_rot_y:      float   = 0.0
var _net_cam_x:      float   = 0.0
var _has_net_state:  bool    = false

@onready var camera: Camera3D = $Camera3D

var _test_params := PhysicsTestMotionParameters3D.new()
var _test_result := PhysicsTestMotionResult3D.new()

func _is_peer_connected() -> bool:
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

func _lerp_remote_player(delta: float) -> void:
	if not _has_net_state:
		return
	var t: float = minf(delta * 20.0, 1.0)
	global_position   = global_position.lerp(_net_pos, t)
	rotation.y        = lerp_angle(rotation.y,        _net_rot_y, t)
	camera.rotation.x = lerp_angle(camera.rotation.x, _net_cam_x, t)

func _process(delta):
	if not is_multiplayer_authority():
		_lerp_remote_player(delta)
		return
	var prev_cooldown = _punch_cooldown
	_punch_cooldown = maxf(_punch_cooldown - delta, 0.0)
	if _punch_measuring and prev_cooldown > 0.0 and _punch_cooldown <= 0.0:
		print("[punch] peak speed on '%s': %.1f u/s" % [_punch_target_name, _punch_peak_speed])
		_punch_measuring = false
	if _held_object:
		_update_held_object(delta)
	if not _hud:
		return
	if not _tab_mode:
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
	if event is InputEventMouseButton and event.pressed and not _tab_mode:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return

	# Held object inputs (mouse captured, not in tab mode)
	if _held_object and not _tab_mode and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseButton:
			if event.pressed:
				match event.button_index:
					MOUSE_BUTTON_LEFT:
						_dispatch_held_input("m1")
						return
					MOUSE_BUTTON_RIGHT:
						_dispatch_held_input("m2")
						return
					MOUSE_BUTTON_WHEEL_UP:
						_dispatch_held_input("scroll_up")
						return
			elif event.button_index == MOUSE_BUTTON_LEFT:
				_punch_held = false
				return

	# Tab: toggle HUD interact mode
	if event is InputEventKey and not event.echo and event.pressed:
		if event.physical_keycode == KEY_TAB:
			_tab_mode = !_tab_mode
			if _hud:
				_hud.hide_action_menu()
				_hud.hide_hover_label()
				_hud.hide_info_popup()
				_hud.set_tab_mode(_tab_mode)
			if _tab_mode:
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
		if _held_object:
			_mouse_delta += event.relative

	# Left / right click in tab mode
	if _tab_mode and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if _hud and not _hud._pending_spawn.is_empty():
				_place_queued_spawn()
			elif _hud and _hud.is_despawn_mode():
				_execute_despawn_at_cursor()
			elif _hud and _hud.is_action_menu_visible():
				_hud.hide_action_menu()
			elif _hud and _hud.is_info_popup_visible():
				_hud.hide_info_popup()
			elif _hud and _hud.is_tune_popup_visible():
				_hud.hide_tune_popup()
			elif _held_object:
				_drop_object()
			else:
				_show_interact_menu()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if _hud and not _hud._pending_spawn.is_empty():
				_hud.cancel_pending_spawn()

func _physics_process(delta):
	if _noclip:
		_noclip_fly(delta)
		if _is_peer_connected():
			_rpc_player_state.rpc(global_position, rotation.y, camera.rotation.x)
		return

	var gravity = get_gravity() * GRAVITY_SCALE

	if not is_on_floor():
		velocity += gravity * delta

	_sliding = Input.is_action_pressed("slide") and is_on_floor()

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		_sliding = false

	if _sliding:
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

	if _is_peer_connected():
		_rpc_player_state.rpc(global_position, rotation.y, camera.rotation.x)
		if _held_object:
			_rpc_held_xform.rpc(str(_held_object.get_path()), _held_object.global_transform)

func _show_interact_menu():
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
				_held_object = target
				_held_object.add_collision_exception_with(self)
				add_collision_exception_with(_held_object)
				_held_object.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				_held_object.freeze = true
				_held_interactable = _find_interactable(target)
				_held_holdable = holdable
				if _held_interactable:
					_held_interactable.is_held = true
				if _is_peer_connected():
					_rpc_take_object.rpc(str(_held_object.get_path()))
				_tab_mode = false
				if _hud:
					_hud.set_tab_mode(false)
				if not (_hud and _hud.pause_overlay.visible):
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				AudioManager.play_pickup()
			elif target is CharacterBody3D and holdable:
				_held_object = target
				_held_object.add_collision_exception_with(self)
				add_collision_exception_with(_held_object)
				_held_interactable = _find_interactable(target)
				_held_holdable = holdable
				if target.is_multiplayer_authority():
					target.set_physics_process(false)
				if _held_interactable:
					_held_interactable.is_held = true
				if _is_peer_connected():
					_rpc_take_object.rpc(str(_held_object.get_path()))
				_tab_mode = false
				if _hud:
					_hud.set_tab_mode(false)
				if not (_hud and _hud.pause_overlay.visible):
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				AudioManager.play_pickup()
		"Info":
			var interactable = _find_interactable(target)
			if interactable and _hud:
				_hud.show_info_popup(interactable, target)
		"Tune":
			var holdable = _find_holdable(target)
			if holdable and _hud:
				_hud.show_tune_popup(target)
		_:
			var interactable = _find_interactable(target)
			if interactable:
				interactable.action_performed.emit(action, self)

func _clear_hold_state():
	if is_instance_valid(_held_object):
		_held_object.remove_collision_exception_with(self)
		remove_collision_exception_with(_held_object)
	_held_object        = null
	_held_interactable  = null
	_held_holdable      = null
	_punch_offset       = 0.0
	_punch_vel          = 0.0
	_punch_held         = false
	_punch_peaked       = false
	_punch_hold_timer   = 0.0
	_punch_start_angle  = 0.0
	_punch_returning    = false
	_punch_cooldown     = 0.0
	_punch_measuring    = false
	_lunge_active       = false
	_sway_angle         = -PI / 2.0
	_sway_ang_vel       = 0.0
	_sway_target        = -PI / 2.0
	_sway_amplitude     = 0.0
	_sway_direction     = 0.0
	_roll_angle         = -PI / 2.0
	_roll_ang_vel       = 0.0
	_mouse_delta        = Vector2.ZERO

func _drop_object():
	if not _held_object:
		return
	if _held_object is RigidBody3D:
		_held_object.continuous_cd = true   # prevent tunnelling through thin geometry
		_held_object.freeze = false
		_held_object.linear_velocity = velocity
		var ang_vel: Vector3 = _held_object.global_transform.basis.y * _roll_ang_vel
		_held_object.angular_velocity = ang_vel
		if _is_peer_connected():
			_rpc_drop_object.rpc(str(_held_object.get_path()), _held_object.global_position, velocity, ang_vel)
	elif _held_object is CharacterBody3D:
		if _held_object.is_multiplayer_authority():
			_held_object.set_physics_process(true)
		if _is_peer_connected():
			_rpc_drop_object.rpc(str(_held_object.get_path()), _held_object.global_position, Vector3.ZERO, Vector3.ZERO)
	if _held_interactable:
		_held_interactable.is_held = false
	AudioManager.play_drop()
	_clear_hold_state()

func _dispatch_held_input(input: String):
	if not _held_holdable:
		return
	var action: String
	match input:
		"m1": action = _held_holdable.m1_action
		"m2": action = _held_holdable.m2_action
		"scroll_up": action = _held_holdable.scroll_up_action
	if action.is_empty():
		return
	match action:
		"punch": _start_punch()
		"throw": _throw_object()
		_:
			if _held_interactable:
				_held_interactable.action_performed.emit(action, self)

func _start_punch():
	if _punch_cooldown > 0.0:
		return
	# Lunge lock: for objects with punch_pull > 0, block re-punch until the
	# object has fully returned to its carry position after the previous lunge.
	if _held_holdable:
		var pull: float = _held_holdable.get_dynamics().get("punch_pull", 0.0)
		if pull > 0.0 and (_punch_offset > 0.001 or _punch_returning):
			return
	AudioManager.play_punch_swing()
	# Resolve per-object overrides: holdable > player default
	var eff_cooldown:    float = _held_holdable.punch_cooldown if _held_holdable and _held_holdable.punch_cooldown > 0.0 else PUNCH_COOLDOWN
	var eff_punch_dist:  float = _held_holdable.punch_distance if _held_holdable and _held_holdable.punch_distance > 0.0 else PUNCH_DISTANCE
	var eff_carry_dist:  float = _held_holdable.carry_distance if _held_holdable and _held_holdable.carry_distance > 0.0 else CARRY_DISTANCE
	var eff_impulse:     float = _held_holdable.punch_impulse  if _held_holdable and _held_holdable.punch_impulse  > 0.0 else PUNCH_IMPULSE
	_punch_cooldown    = eff_cooldown
	_punch_held        = true
	_punch_vel         = 0.0
	_punch_start_angle = _sway_angle
	_punch_measuring   = true
	_punch_peak_speed  = 0.0
	_punch_target_name = _held_object.name
	print("[punch] player %d punched '%s'" % [multiplayer.get_unique_id(), _punch_target_name])
	var punch_dir = -camera.global_transform.basis.z
	var from = camera.global_position
	var to = from + punch_dir * (eff_carry_dist + eff_punch_dist)
	var params = PhysicsRayQueryParameters3D.create(from, to)
	params.exclude = [get_rid(), _held_object.get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(params)
	if hit and hit.collider is RigidBody3D:
		hit.collider.apply_central_impulse(punch_dir * eff_impulse)
		AudioManager.play_punch_impact()
		# Non-host clients: forward the impulse to the host so authoritative
		# physics drives the result and it propagates to all peers via the broadcast.
		if _is_peer_connected() and not multiplayer.is_server():
			_rpc_punch_impulse.rpc_id(1, str(hit.collider.get_path()), punch_dir * eff_impulse)

func _throw_object():
	if not _held_object:
		return
	print("[throw] player %d threw '%s'" % [multiplayer.get_unique_id(), _held_object.name])
	var eff_throw_speed: float = _held_holdable.throw_speed if _held_holdable and _held_holdable.throw_speed > 0.0 else THROW_SPEED
	if _held_object is RigidBody3D:
		var throw_dir = -camera.global_transform.basis.z
		var throw_vel = velocity + throw_dir * eff_throw_speed
		var throw_ang_vel: Vector3 = _held_object.global_transform.basis.y * _roll_ang_vel
		_held_object.continuous_cd = true   # prevent tunnelling through thin geometry
		_held_object.freeze = false
		_held_object.linear_velocity = throw_vel
		_held_object.angular_velocity = throw_ang_vel
		if _is_peer_connected():
			_rpc_drop_object.rpc(str(_held_object.get_path()), _held_object.global_position, throw_vel, throw_ang_vel)
	elif _held_object is CharacterBody3D:
		if _held_object.is_multiplayer_authority():
			_held_object.set_physics_process(true)
		if _is_peer_connected():
			_rpc_drop_object.rpc(str(_held_object.get_path()), _held_object.global_position, Vector3.ZERO, Vector3.ZERO)
	if _held_interactable:
		_held_interactable.is_held = false
	AudioManager.play_throw()
	_clear_hold_state()

func _place_queued_spawn() -> void:
	if not _hud or _hud._pending_spawn.is_empty():
		return
	var scene_path: String = _hud._pending_spawn
	var mouse_pos          = get_viewport().get_mouse_position()
	var origin: Vector3    = camera.project_ray_origin(mouse_pos)
	var ray_end: Vector3   = origin + camera.project_ray_normal(mouse_pos) * 50.0
	var params             = PhysicsRayQueryParameters3D.create(origin, ray_end)
	params.exclude         = [get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(params)
	if not hit:
		return
	# Place the object slightly above the surface so physics doesn't start intersecting.
	var spawn_pos: Vector3 = hit.position + hit.normal * 0.8
	var world: Node        = get_parent().get_parent()
	if world and world.has_method("spawn_object"):
		world.spawn_object(scene_path, spawn_pos)

func _update_held_object(delta: float):
	if not is_instance_valid(_held_object):
		if is_instance_valid(_held_interactable):
			_held_interactable.is_held = false
		_clear_hold_state()
		return
	# ── Effective per-object values (holdable overrides > player defaults) ───────
	var eff_max_carry:  float = _held_holdable.max_carry_dist  if _held_holdable and _held_holdable.max_carry_dist  > 0.0 else MAX_CARRY_DIST
	var eff_carry_dist: float = _held_holdable.carry_distance  if _held_holdable and _held_holdable.carry_distance  > 0.0 else CARRY_DISTANCE
	var eff_punch_dist: float = _held_holdable.punch_distance  if _held_holdable and _held_holdable.punch_distance  > 0.0 else PUNCH_DISTANCE

	if _held_object.global_position.distance_to(camera.global_position) > eff_max_carry:
		_drop_object()
		return

	# ── Weight bucket dynamics ────────────────────────────────────────────────
	# Fetched once per frame so punch-pull and sway share the same values.
	var pivot: float     = _held_holdable.hold_pivot if _held_holdable else 0.0
	var dyn: Dictionary  = _held_holdable.get_dynamics() if _held_holdable else {}
	var w_mouse:  float  = dyn.get("sway_mouse_scale", SWAY_MOUSE_SCALE)
	var w_sway:   float  = dyn.get("sway_damping",     SWAY_DAMPING)
	var w_roll:   float  = dyn.get("roll_damping",      ROLL_DAMPING)
	var w_maxspin: float = dyn.get("max_roll_speed",    15.0)
	var w_pull:        float = dyn.get("punch_pull",       0.0)
	var w_punch_accel: float = dyn.get("punch_accel",     PUNCH_ACCEL)
	var w_peak_hold:   float = dyn.get("punch_peak_hold", 0.10)
	var w_settle_spd:  float = dyn.get("punch_settle_spd", PUNCH_RETURN_SPEED * 0.4)
	var w_sway_sens:   float = dyn.get("sway_sensitivity", 30.0)
	var w_pushback:    float = dyn.get("punch_pushback",   PUNCH_PUSHBACK)

	# ── Punch offset ─────────────────────────────────────────────────────────
	# Four phases while M1 is held:
	#   1. Extending  — weight-scaled acceleration to PUNCH_DISTANCE.
	#   2. Peak hold  — dwells at max for w_peak_hold seconds; fires player-pull once.
	#   3. Settling   — slow retraction (w_settle_spd) to the idle M1 position.
	# When M1 is released (Phase 4):
	#   offset returns to 0; sway springs to the opposite side of the circle.
	if _punch_held:
		if not _punch_peaked:
			# Phase 1: weight-scaled extend
			if _punch_offset < eff_punch_dist:
				_punch_vel    += w_punch_accel * delta
				_punch_offset  = minf(_punch_offset + _punch_vel * delta, eff_punch_dist)
			# Transition to Phase 2 on first frame at max
			if _punch_offset >= eff_punch_dist:
				# Lunge only granted if the object actually reached full extension.
				var fwd: Vector3        = -camera.global_transform.basis.z
				var forward_dist: float = (_held_object.global_position - camera.global_position).dot(fwd)
				var intended_fwd: float = eff_carry_dist + eff_punch_dist - pivot
				_lunge_active  = (w_pull > 0.0) and (forward_dist >= intended_fwd * 0.85)
				_punch_peaked  = true
				_punch_hold_timer = w_peak_hold
		elif _punch_hold_timer > 0.0:
			# Phase 2: dwell at max extension — continuously pull player while lunging
			_punch_hold_timer -= delta
			_punch_vel         = 0.0
			_punch_offset      = eff_punch_dist
			if _lunge_active and w_peak_hold > 0.001:
				var punch_dir: Vector3 = -camera.global_transform.basis.z
				velocity += punch_dir * (w_pull / w_peak_hold) * delta
		else:
			# Phase 3: slow retraction to the M1-held settle position — end lunge,
			# begin opposite-side swing so the object tracks back through the far edge.
			_lunge_active = false
			if not _punch_returning:
				_punch_returning = true
				var return_target: float = fposmod(_punch_start_angle + PI, TAU)
				_sway_target    = return_target
				_sway_direction = return_target
				_sway_amplitude = 1.0
			_punch_vel    = 0.0
			_punch_offset = move_toward(_punch_offset, eff_punch_dist * PUNCH_SETTLE_FRAC, w_settle_spd * delta)
	else:
		# Phase 4: M1 released — retract offset; activate opposite-side sway spring
		_lunge_active = false
		if _punch_peaked:
			_punch_returning = true
			# Pre-aim the normal sway spring at the destination so it holds the object
			# there once _punch_returning finishes, instead of snapping back to the old target.
			var return_target: float = fposmod(_punch_start_angle + PI, TAU)
			_sway_target    = return_target
			_sway_direction = return_target
			_sway_amplitude = 1.0
		_punch_peaked     = false
		_punch_hold_timer = 0.0
		_punch_vel        = 0.0
		_punch_offset     = move_toward(_punch_offset, 0.0, PUNCH_RETURN_SPEED * delta)

	# ── Sway + roll (two independent angular degrees of freedom) ────────────
	# _sway_angle — position of close end on the sway circle.
	#   Mouse direction sets a TARGET ANGLE on the opposite side of the circle
	#   (flick right → target = left edge). A weight-scaled spring pulls sway
	#   there and holds it, preventing wild orbiting from fast mouse input.
	# _roll_angle — axial spin; still impulse-driven (unchanged).

	# Update sway target from mouse input.
	var mouse_len: float = _mouse_delta.length()
	if mouse_len > 2.0:
		var new_dir: float  = atan2(_mouse_delta.y, -_mouse_delta.x)
		var new_amp: float  = clampf(mouse_len / w_sway_sens, 0.0, 1.0)
		var dir_diff: float = abs(fposmod(new_dir - _sway_direction + PI, TAU) - PI)
		if dir_diff > PI * 0.6:
			_sway_amplitude = new_amp
		else:
			_sway_amplitude = maxf(_sway_amplitude, new_amp)
		_sway_direction = new_dir
		_sway_target    = lerp_angle(-PI * 0.5, _sway_direction, _sway_amplitude)

	# Axial roll — tangential impulse
	var tangent: Vector2 = Vector2(-sin(_sway_angle), cos(_sway_angle))
	_roll_ang_vel += -_mouse_delta.dot(tangent) * w_mouse / maxf(pivot, 0.25)
	_mouse_delta = Vector2.ZERO

	if _punch_returning:
		# Critically-damped spring pulls sway to the opposite side of the circle.
		var return_target: float = _punch_start_angle + PI
		var angle_err: float     = fposmod(return_target - _sway_angle + PI, TAU) - PI
		var spring_k: float      = 36.0 * (0.3 / maxf(w_sway, 0.01))
		var spring_d: float      = 2.0 * sqrt(spring_k)   # critically damped
		_sway_ang_vel += angle_err * spring_k * delta
		_sway_ang_vel *= maxf(0.0, 1.0 - spring_d * delta)
		_sway_angle   += _sway_ang_vel * delta
		if _punch_offset <= 0.001 and abs(angle_err) < 0.08 and abs(_sway_ang_vel) < 0.1:
			_punch_returning = false
	elif _punch_held:
		# Suppress sway quickly so the object straightens during a punch
		_sway_ang_vel *= maxf(0.0, 1.0 - w_sway * 8.0 * delta)
	else:
		# Spring toward the mouse-direction target.
		# 0.85 damping ratio = slightly underdamped: a gentle wobble at the edge
		# gives the "wiggle room" feel without ever orbiting past it.
		var sway_err: float = fposmod(_sway_target - _sway_angle + PI, TAU) - PI
		var sway_k:   float = dyn.get("sway_spring_k",  10.0)
		var sway_d:   float = 2.0 * sqrt(sway_k) * 0.85  # slightly underdamped
		var sway_max: float = dyn.get("sway_max_speed",  6.0)
		_sway_ang_vel += sway_err * sway_k * delta
		_sway_ang_vel  = clampf(_sway_ang_vel, -sway_max, sway_max)
		_sway_ang_vel *= maxf(0.0, 1.0 - sway_d * delta)
		_sway_angle   += _sway_ang_vel * delta

	# Roll always updates — keeps spinning through punches (spinning stab effect)
	_roll_ang_vel *= maxf(0.0, 1.0 - w_roll * delta)
	_roll_ang_vel  = clampf(_roll_ang_vel, -w_maxspin, w_maxspin)
	_roll_angle   += _roll_ang_vel * delta

	# Cartesian position of the close end.
	# Scale by (1 - punch_t) so the butt smoothly closes toward the tip as the
	# punch extends, then drifts back out as it retracts — no snap.
	var sway_pos: Vector2 = Vector2.ZERO
	if pivot > 0.001:
		var punch_t: float = _punch_offset / maxf(eff_punch_dist, 0.001)
		sway_pos = Vector2(cos(_sway_angle), sin(_sway_angle)) * pivot * (1.0 - punch_t)

	# ── Object transform + endpoint collision protection ─────────────────────
	# For pivot objects the system runs two raycasts every frame:
	#   Ray 1 (anchor / tip)  — camera → intended tip position.
	#     If geometry is in the way, depth is shortened so the tip stays clear.
	#   Ray 2 (butt / close end) — tip → intended butt position.
	#     If geometry is in the way, the butt is clamped back and angular
	#     velocity is killed so the object doesn't keep pushing into the surface.
	# The existing body_test_motion sweep then handles linear centre-motion for
	# all objects (pivot and no-pivot alike).
	var rotation_offset: Basis = Basis.from_euler(_held_holdable.hold_rotation * (PI / 180.0)) if _held_holdable else Basis.IDENTITY

	var cam_basis: Basis   = camera.global_transform.basis
	var cam_pos:   Vector3 = camera.global_position
	var depth: float       = eff_carry_dist + _punch_offset

	var target_pos:   Vector3
	var target_basis: Basis

	if pivot > 0.001:
		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
		ray.exclude = [get_rid(), _held_object.get_rid()]

		# ── Ray 1: anchor (tip / far end) ────────────────────────────────────
		var anchor: Vector3 = cam_pos + cam_basis * Vector3(CARRY_OFFSET_X, CARRY_OFFSET_Y, -depth)
		ray.from = cam_pos
		ray.to   = anchor
		var tip_hit: Dictionary = space.intersect_ray(ray)
		if tip_hit:
			var min_depth: float = 2.0 * pivot + ENDPOINT_MARGIN
			depth  = maxf(cam_pos.distance_to(tip_hit.position) - ENDPOINT_MARGIN, min_depth)
			anchor = cam_pos + cam_basis * Vector3(CARRY_OFFSET_X, CARRY_OFFSET_Y, -depth)

		# ── Pivot-path transform (computed with post-ray depth) ───────────────
		target_pos = cam_pos + cam_basis * Vector3(
			CARRY_OFFSET_X + sway_pos.x * 0.5,
			CARRY_OFFSET_Y + sway_pos.y * 0.5,
			-depth + pivot
		)
		var fwd_cam:   Vector3 = Vector3(-sway_pos.x, -sway_pos.y, -2.0 * pivot).normalized()
		var fwd_world: Vector3 = cam_basis * fwd_cam
		var up_ref: Vector3 = cam_basis * Vector3(-cos(_roll_angle), -sin(_roll_angle), 0.0)
		if abs(fwd_world.dot(up_ref)) > 0.999:
			up_ref = cam_basis.x
		target_basis = Basis.looking_at(fwd_world, up_ref) * rotation_offset

		# ── Ray 2: butt (close end) ───────────────────────────────────────────
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
		# No-pivot path: centre at carry offset point, no sway tilt.
		target_pos   = cam_pos + cam_basis * Vector3(CARRY_OFFSET_X, CARRY_OFFSET_Y, -depth)
		target_basis = cam_basis * rotation_offset

	# ── Centre sweep (all objects) ────────────────────────────────────────────
	var motion: Vector3 = target_pos - _held_object.global_position
	_test_params.from   = _held_object.global_transform
	_test_params.motion = motion
	if PhysicsServer3D.body_test_motion(_held_object.get_rid(), _test_params, _test_result):
		target_pos = _held_object.global_position + _test_result.get_travel()
		# Pushback: weight-scaled force pushed back onto the player whenever M1
		# is held and the object is blocked by geometry.
		if _punch_held:
			var punch_dir: Vector3 = -camera.global_transform.basis.z
			velocity -= punch_dir * w_pushback * delta

	if _punch_measuring:
		var frame_speed: float = _held_object.global_position.distance_to(target_pos) / delta
		_punch_peak_speed = maxf(_punch_peak_speed, frame_speed)

	_held_object.global_transform = Transform3D(target_basis, target_pos)

# ── Dev tools ───────────────────────────────────────────────────────────────

func dev_set_noclip(on: bool) -> void:
	_noclip = on
	if on and _held_object:
		_drop_object()
	if not on:
		velocity = Vector3.ZERO

func dev_teleport_to_origin() -> void:
	global_position = Vector3(0.0, 3.0, 0.0)
	velocity        = Vector3.ZERO

## Free-flight movement used in noclip mode.
## WASD moves relative to camera direction; Jump = up; Slide = down.
func _noclip_fly(delta: float) -> void:
	var dir := Vector3.ZERO
	var input := Input.get_vector("left", "right", "up", "down")
	dir += camera.global_transform.basis.z *  input.y
	dir += camera.global_transform.basis.x *  input.x
	if Input.is_action_pressed("jump"):  dir.y += 1.0
	if Input.is_action_pressed("slide"): dir.y -= 1.0
	if dir.length_squared() > 0.0:
		global_position += dir.normalized() * SPEED * 3.0 * delta

## Fires a raycast from the cursor and despawns the first physics body hit.
func _execute_despawn_at_cursor() -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	var origin    := camera.project_ray_origin(mouse_pos)
	var ray_end: Vector3 = origin + camera.project_ray_normal(mouse_pos) * INTERACT_RANGE
	var params    := PhysicsRayQueryParameters3D.create(origin, ray_end)
	params.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if not hit:
		return
	var target: Node = hit.collider
	# Walk up to a root-level physics body (handles mesh children hitting the raycast).
	while target and not (target is RigidBody3D or target is CharacterBody3D):
		target = target.get_parent()
	if not target:
		return
	# If we're holding this object, drop it first.
	if target == _held_object:
		_drop_object()
	var world: Node = get_parent().get_parent()
	if world and world.has_method("despawn_object"):
		world.despawn_object(target)

# ── Multiplayer RPCs ────────────────────────────────────────────────────────

@rpc("any_peer", "reliable")
func _rpc_take_object(obj_path: String):
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
		push_warning("[player] _rpc_take_object: node not found or unsupported type: %s" % obj_path)

@rpc("any_peer", "unreliable_ordered")
func _rpc_held_xform(obj_path: String, xform: Transform3D):
	# Route through world's net-target table so the lerp system handles smoothing.
	var world: Node = get_parent().get_parent()
	if world and world.has_method("queue_net_target"):
		world.queue_net_target(obj_path, xform.origin, xform.basis.get_rotation_quaternion())
	else:
		var obj = get_tree().root.get_node_or_null(obj_path)
		if obj:
			obj.global_transform = xform

@rpc("any_peer", "reliable")
func _rpc_drop_object(obj_path: String, pos: Vector3, vel: Vector3, ang_vel: Vector3):
	var obj = get_tree().root.get_node_or_null(obj_path)
	if obj is RigidBody3D:
		obj.continuous_cd = true   # prevent tunnelling on all clients
		obj.freeze = false
		obj.global_position = pos
		obj.linear_velocity = vel
		obj.angular_velocity = ang_vel
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
		push_warning("[player] _rpc_drop_object: node not found: %s" % obj_path)

@rpc("any_peer", "unreliable_ordered")
func _rpc_player_state(pos: Vector3, body_y: float, cam_x: float):
	_net_pos = pos; _net_rot_y = body_y; _net_cam_x = cam_x; _has_net_state = true

## Client sends punch impulse to the host; host applies it to the live physics
## object so the authoritative simulation drives the result.
@rpc("any_peer", "reliable")
func _rpc_punch_impulse(obj_path: String, impulse: Vector3):
	if not multiplayer.is_server():
		return
	var obj = get_tree().root.get_node_or_null(obj_path)
	if obj is RigidBody3D and not obj.freeze:
		obj.apply_central_impulse(impulse)
