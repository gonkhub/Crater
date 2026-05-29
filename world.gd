extends Node

const PLAYER = preload("res://Objects/player.tscn")

var hud: Node

# ── Physics broadcast ───────────────────────────────────────────────────────
# The host broadcasts every moving world object at ~20 hz (every
# _BCAST_INTERVAL physics ticks at 60 hz). Clients lerp each object toward
# the latest server state so free-flying and punched objects stay in sync.
const _BCAST_INTERVAL: int = 3   # 60 hz / 3 ≈ 20 hz

var _bcast_tick:  int        = 0
var _was_moving:  Dictionary = {}   # path → bool: one trailing frame after stop
var _net_targets: Dictionary = {}   # path → {pos, rot, lin_vel, ang_vel}

func _ready():
	hud = preload("res://hud.tscn").instantiate()
	add_child(hud)

	# Generate trimesh collision for the cave at runtime.
	# The GLB scene importer ignores _subresources physics flags;
	# create_trimesh_collision() is the reliable alternative.
	_generate_mesh_collision($"NavigationRegion3D/Cave Enterway GLB")

	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if not multiplayer.has_multiplayer_peer():
		_do_spawn(1)
		return

	if multiplayer.is_server():
		_do_spawn(1)
	else:
		_client_ready.rpc_id(1)

# ── Server: broadcast moving objects at ~20 hz ─────────────────────────────

func _physics_process(_delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	_bcast_tick += 1
	if _bcast_tick < _BCAST_INTERVAL:
		return
	_bcast_tick = 0
	var states: Array = []
	for node in get_tree().get_nodes_in_group("world_objects"):
		if not node is RigidBody3D or node.freeze:
			continue
		var path: String  = str(node.get_path())
		var lv:   Vector3 = node.linear_velocity
		var av:   Vector3 = node.angular_velocity
		var is_moving:  bool = lv.length_squared() > 0.0001 or av.length_squared() > 0.0001
		var was_moving: bool = _was_moving.get(path, false)
		_was_moving[path] = is_moving
		if is_moving or was_moving:   # one trailing frame ensures final rest pos syncs
			states.append([path, node.global_position,
				node.global_transform.basis.get_rotation_quaternion(), lv, av])
	if not states.is_empty():
		_recv_world_physics.rpc(states)

# ── Client: receive host physics broadcast ──────────────────────────────────

@rpc("authority", "unreliable_ordered")
func _recv_world_physics(states: Array) -> void:
	for s in states:
		_net_targets[s[0]] = {
			"pos":     s[1],
			"rot":     s[2],
			"lin_vel": s[3],
			"ang_vel": s[4]
		}

## Injects a net-target so a held object smoothly tracks its holder even
## while its RigidBody physics is frozen. Called by player.gd _sync_held_object.
func queue_net_target(path: String, pos: Vector3, rot: Quaternion) -> void:
	_net_targets[path] = {
		"pos":     pos,
		"rot":     rot,
		"lin_vel": Vector3.ZERO,
		"ang_vel": Vector3.ZERO
	}

# ── All peers: lerp world objects toward their net targets ──────────────────
# Server applies lerp only for FROZEN (held) objects — it gets those via
# queue_net_target() from _sync_held_object RPCs sent by holding clients.
# Unfrozen objects on the server are physics-authoritative, so we skip them.
# Clients lerp everything: frozen objects (held) + free objects (broadcast).

func _process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var t: float = minf(delta * 15.0, 1.0)
	for path in _net_targets:
		var obj: Node = get_tree().root.get_node_or_null(path)
		if not obj:
			continue
		# Server: physics owns unfrozen RigidBodies — don't fight the simulation.
		if multiplayer.is_server() and obj is RigidBody3D and not obj.freeze:
			continue
		var tgt: Dictionary = _net_targets[path]
		var dist: float = obj.global_position.distance_to(tgt["pos"])
		if dist > 0.5:
			# Large error: snap instantly to prevent rubber-banding
			obj.global_position = tgt["pos"]
			obj.global_transform.basis = Basis(tgt["rot"])
		else:
			obj.global_position = obj.global_position.lerp(tgt["pos"], t)
			var q: Quaternion = obj.global_transform.basis.get_rotation_quaternion()
			obj.global_transform.basis = Basis(q.slerp(tgt["rot"], t))

# ── Peer connection ─────────────────────────────────────────────────────────

@rpc("any_peer", "reliable")
func _client_ready():
	var id = multiplayer.get_remote_sender_id()
	_do_spawn(id)
	_remote_spawn.rpc(id)
	var children = $Players.get_children()
	for child in children:
		var existing_id = str(child.name).to_int()
		if existing_id != id:
			_remote_spawn.rpc_id(id, existing_id)
	_send_world_state_to(id)
	hud.add_log("Player %d joined." % id)
	_broadcast_log.rpc("Player %d joined." % id)

@rpc("any_peer", "reliable")
func _remote_spawn(id: int):
	_do_spawn(id)

func _on_peer_disconnected(id: int):
	_do_remove(id)
	if multiplayer.is_server():
		hud.add_log("Player %d left." % id)
		_peer_left.rpc(id)

# Clients receive this when another player disconnects.
@rpc("any_peer", "reliable")
func _peer_left(id: int):
	_do_remove(id)
	hud.add_log("Player %d left." % id)

@rpc("any_peer", "reliable")
func _broadcast_log(msg: String):
	hud.add_log(msg)

func _do_spawn(id: int):
	if $Players.get_node_or_null(str(id)):
		return
	var player = PLAYER.instantiate()
	player.name = str(id)
	player.set_multiplayer_authority(id)
	player.position = Vector3(0, 3, 0)
	$Players.add_child(player)
	var is_local = not multiplayer.has_multiplayer_peer() \
		or id == multiplayer.get_unique_id()
	if is_local:
		player.init_local(hud)


# ── Late-join world state sync ──────────────────────────────────────────────

func _find_interactable_node(node: Node) -> Interactable:
	for child in node.get_children():
		if child is Interactable:
			return child
	return null

# Host calls this for each newly connected peer to bring them up to date.
func _send_world_state_to(id: int):
	for node in get_tree().get_nodes_in_group("world_objects"):
		if not node is RigidBody3D:
			continue
		var interactable = _find_interactable_node(node)
		var is_held = interactable != null and interactable.is_held
		_sync_world_object.rpc_id(
			id,
			str(node.get_path()),
			node.global_transform,
			node.linear_velocity,
			is_held
		)

@rpc("any_peer", "reliable")
func _sync_world_object(obj_path: String, xform: Transform3D, vel: Vector3, is_held: bool):
	var obj = get_tree().root.get_node_or_null(obj_path)
	if not obj is RigidBody3D:
		push_warning("[world] _sync_world_object: node not found: %s" % obj_path)
		return
	obj.global_transform = xform
	obj.linear_velocity = vel
	if is_held:
		obj.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		obj.freeze = true
		var interactable = _find_interactable_node(obj)
		if interactable:
			interactable.is_held = true

# ── Helpers ─────────────────────────────────────────────────────────────────

## Recursively walks a scene node and calls create_trimesh_collision() on
## every MeshInstance3D found. Used to generate runtime collision for GLB
## imports where the _subresources collision flag is unreliable.
func _generate_mesh_collision(node: Node) -> void:
	if not node:
		return
	if node is MeshInstance3D:
		node.create_trimesh_collision()
	for child in node.get_children():
		_generate_mesh_collision(child)

func _do_remove(id: int):
	var node = $Players.get_node_or_null(str(id))
	if node:
		node.queue_free()
