extends CharacterBody3D

const SPEED         = 2.0
const GRAVITY_SCALE = 2.5

## Idle pause at each waypoint — randomised between these bounds (seconds).
const IDLE_MIN = 1.5
const IDLE_MAX = 4.0

## Stuck detection: if the mushroom travels less than STUCK_DIST metres within
## STUCK_INTERVAL seconds it gives up and picks a new waypoint.
const STUCK_DIST     = 0.3   # metres
const STUCK_INTERVAL = 2.5   # seconds

## Light threshold below which the mushroom stays dormant.
## get_light_at() returns 0.4–1.0 when the star is above the horizon
## (lower on the far side of the crater, higher on the near side) and 0.0
## when the star is below the horizon.  0.45 means mushrooms on the far
## (dark) side stay still even during starlight; lower this toward 0.0 to
## let them move anywhere as long as the star is up at all.
const MIN_LIGHT_TO_MOVE: float = 0.45

## How long to wait before rechecking light when dormant (seconds).
const DORMANT_RECHECK: float = 2.5

## Sync rate: broadcast position every N physics ticks (~20 hz at 60 hz physics).
const _RPC_INTERVAL: int = 3

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D

# ── Multiplayer lerp targets (non-authority peers only) ──────────────────────
var _net_pos:       Vector3 = Vector3.ZERO
var _net_rot_y:     float   = 0.0
var _has_net_state: bool    = false

# ── Wander state machine ─────────────────────────────────────────────────────
enum State { IDLE, WALKING }
var _state:        State   = State.IDLE
var _idle_timer:   float   = 0.0
var _stuck_timer:  float   = 0.0
var _stuck_origin: Vector3 = Vector3.ZERO  # position sampled when stuck timer resets
var _sync_tick:    int     = 0

func _ready() -> void:
	if not is_multiplayer_authority():
		set_physics_process(false)
		return

	# ── Core sizing ───────────────────────────────────────────────────────────
	# radius must match the baked NavigationMesh agent_radius so paths carry
	# enough clearance around corners for the capsule to fit without clipping.
	nav_agent.radius     = 0.25
	nav_agent.height     = 0.9    # matches CapsuleShape3D height
	nav_agent.max_speed  = SPEED

	# ── Path quality ─────────────────────────────────────────────────────────
	# EDGE_CENTERING biases each waypoint toward the centre of its nav polygon,
	# naturally pulling paths away from geometry edges. Primary fix for the
	# ramp-corner sticking: the default CORRIDORFUNNEL routes along the shortest
	# path, which hugs edges and corners tightly.
	nav_agent.path_postprocessing     = 1  # PathPostProcessing.EDGECENTERING
	nav_agent.path_desired_distance   = 0.4
	nav_agent.target_desired_distance = 0.6
	# Repath when the agent drifts more than 1.5 m off its computed corridor.
	nav_agent.path_max_distance       = 1.5
	# Collapse near-collinear waypoints — reduces steering jitter on flat areas.
	nav_agent.simplify_path           = true
	nav_agent.simplify_epsilon        = 0.3

	# ── Avoidance ─────────────────────────────────────────────────────────────
	# keep_y_velocity: preserves gravity / ramp Y when avoidance fires its
	# velocity_computed callback, so slope traversal isn't disrupted.
	nav_agent.avoidance_enabled  = true
	nav_agent.keep_y_velocity    = true
	# Limit neighbour search to 5 m — avoids evaluating distant agents needlessly.
	nav_agent.neighbor_distance  = 5.0
	# Lower priority means this agent yields to others — mushrooms shuffle around
	# each other rather than standing their ground.
	nav_agent.avoidance_priority = 0.4
	nav_agent.velocity_computed.connect(_on_velocity_computed)

	await get_tree().physics_frame   # wait for navigation map to initialise
	_set_idle(randf_range(0.3, 1.2))

# ── Remote-peer lerp (non-authority only) ────────────────────────────────────

func _process(delta: float) -> void:
	if not is_multiplayer_authority() and _has_net_state:
		var t: float = minf(delta * 15.0, 1.0)
		global_position = global_position.lerp(_net_pos, t)
		rotation.y      = lerp_angle(rotation.y, _net_rot_y, t)

# ── Server-side physics & AI ─────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * GRAVITY_SCALE * delta

	match _state:
		State.IDLE:
			# Bleed off horizontal momentum; wait for idle timer then pick next waypoint.
			velocity.x = move_toward(velocity.x, 0.0, SPEED * 6.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, SPEED * 6.0 * delta)
			_idle_timer -= delta
			if _idle_timer <= 0.0:
				if _is_lit():
					_set_walking(_pick_waypoint())
				else:
					# Not enough light — stay dormant and recheck after a short delay.
					_idle_timer = DORMANT_RECHECK

		State.WALKING:
			if not _is_lit():
				# Light dropped below threshold mid-journey — stop immediately and wait.
				_set_idle(DORMANT_RECHECK)
			elif nav_agent.is_navigation_finished():
				_set_idle(randf_range(IDLE_MIN, IDLE_MAX))
			else:
				# ── Stuck detection ───────────────────────────────────────────
				_stuck_timer -= delta
				if _stuck_timer <= 0.0:
					if global_position.distance_to(_stuck_origin) < STUCK_DIST:
						_set_idle(0.15)   # brief pause, then a fresh random target
					else:
						_stuck_origin = global_position
						_stuck_timer  = STUCK_INTERVAL

				# ── Variable speed ────────────────────────────────────────────
				# Ramp velocity down when close to the target so the mushroom
				# decelerates naturally rather than stopping abruptly.
				var dist_to_target: float = global_position.distance_to(
						nav_agent.get_target_position())
				var speed_scale: float    = clampf(dist_to_target / 1.5, 0.3, 1.0)

				# ── Steering ─────────────────────────────────────────────────
				# Feed desired XZ velocity into the agent. RVO adjusts it for
				# avoidance and fires _on_velocity_computed with the safe result.
				var next: Vector3 = nav_agent.get_next_path_position()
				var dir:  Vector3 = next - global_position
				dir.y = 0.0
				if dir.length_squared() > 0.001:
					nav_agent.set_velocity(dir.normalized() * SPEED * speed_scale)
				else:
					nav_agent.set_velocity(Vector3.ZERO)

	move_and_slide()

	# Rate-limited sync: ~20 hz instead of every physics tick (60 hz).
	if multiplayer.has_multiplayer_peer():
		_sync_tick += 1
		if _sync_tick >= _RPC_INTERVAL:
			_sync_tick = 0
			_rpc_state.rpc(global_position, rotation.y)

# RVO callback — apply safe XZ velocity. Y is preserved by keep_y_velocity.
func _on_velocity_computed(safe_vel: Vector3) -> void:
	velocity.x = safe_vel.x
	velocity.z = safe_vel.z

# ── State transitions ────────────────────────────────────────────────────────

func _set_idle(duration: float) -> void:
	_state      = State.IDLE
	_idle_timer = duration

func _set_walking(target: Vector3) -> void:
	_state        = State.WALKING
	_stuck_origin = global_position
	_stuck_timer  = STUCK_INTERVAL
	nav_agent.set_target_position(target)

## Returns true when the light level at this mushroom's position is high enough
## to warrant movement.  Queries TimeSystem which wraps SkyManager's per-position
## light calculation (star direction × positional angle within the crater).
func _is_lit() -> bool:
	return TimeSystem.get_light_at(global_position) >= MIN_LIGHT_TO_MOVE

# ── Waypoint selection ───────────────────────────────────────────────────────

func _pick_waypoint() -> Vector3:
	var map: RID = nav_agent.get_navigation_map()
	if not map.is_valid():
		return global_position

	# Generate a small pool of candidates and score each one.
	# Scoring favours vertical travel (abs Y delta) — movement up or down the
	# ramp is more visually interesting than flat shuffling. A random noise term
	# prevents all mushrooms from deterministically chasing the same direction.
	var best:       Vector3 = Vector3.ZERO
	var best_score: float   = -1.0

	for _i in range(5):
		var pt: Vector3 = NavigationServer3D.map_get_random_point(
				map, nav_agent.navigation_layers, false)
		if pt == Vector3.ZERO:
			continue
		# Skip points too close — would cause micro-movements and look jittery.
		if pt.distance_to(global_position) < 1.5:
			continue
		var score: float = abs(pt.y - global_position.y) + randf() * 2.0
		if score > best_score:
			best_score = score
			best       = pt

	# Fallback: random vertex from baked nav mesh geometry.
	if best == Vector3.ZERO:
		var verts: Array = []
		for region in get_tree().root.find_children("*", "NavigationRegion3D", true, false):
			if region.navigation_mesh:
				var xform: Transform3D = region.global_transform
				for v in region.navigation_mesh.get_vertices():
					verts.append(xform * v)
		if not verts.is_empty():
			return verts[randi() % verts.size()]
		return global_position

	return best

# ── Multiplayer sync ─────────────────────────────────────────────────────────

@rpc("authority", "unreliable_ordered")
func _rpc_state(pos: Vector3, body_y: float) -> void:
	_net_pos       = pos
	_net_rot_y     = body_y
	_has_net_state = true
