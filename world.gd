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

# ── Dynamic object spawning ──────────────────────────────────────────────────
var _spawn_counter:   int   = 0
var _spawned_objects: Array = []   # [{scene, name}] — used for late-join sync

func _ready():
	hud = preload("res://hud.tscn").instantiate()
	add_child(hud)

	# ── Sky system ────────────────────────────────────────────────────────────
	# SkyManager and CloudCeiling are authored in world.tscn, but this guard
	# creates them at runtime if the scene file is stale or the editor hasn't
	# reloaded it after the tscn edit.  Also renames the legacy DirectionalLight3D
	# to StarLight so SkyManager can find it by the expected name.
	_ensure_sky_nodes()

	# Generate trimesh collision for the cave at runtime.
	# The GLB scene importer ignores _subresources physics flags;
	# create_trimesh_collision() is the reliable alternative.
	_build_mesh_colliders($"NavigationRegion3D/Cave Enterway GLB")

	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if not multiplayer.has_multiplayer_peer():
		_instantiate_player(1)
		return

	if multiplayer.is_server():
		_instantiate_player(1)
	else:
		_on_client_connected.rpc_id(1)

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
		_rpc_recv_physics.rpc(states)

# ── Client: receive host physics broadcast ──────────────────────────────────

@rpc("authority", "unreliable_ordered")
func _rpc_recv_physics(states: Array) -> void:
	for s in states:
		_net_targets[s[0]] = {
			"pos":     s[1],
			"rot":     s[2],
			"lin_vel": s[3],
			"ang_vel": s[4]
		}

## Injects a net-target so a held object smoothly tracks its holder even
## while its RigidBody physics is frozen. Called by player.gd _rpc_held_xform.
func queue_net_target(path: String, pos: Vector3, rot: Quaternion) -> void:
	_net_targets[path] = {
		"pos":     pos,
		"rot":     rot,
		"lin_vel": Vector3.ZERO,
		"ang_vel": Vector3.ZERO
	}

# ── All peers: lerp world objects toward their net targets ──────────────────
# Server applies lerp only for FROZEN (held) objects — it gets those via
# queue_net_target() from _rpc_held_xform RPCs sent by holding clients.
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
		if dist > 1.5:
			# Major desync (>1.5 m): snap instantly.
			obj.global_position = tgt["pos"]
			obj.global_transform.basis = Basis(tgt["rot"])
		else:
			obj.global_position = obj.global_position.lerp(tgt["pos"], t)
			var q: Quaternion = obj.global_transform.basis.get_rotation_quaternion()
			obj.global_transform.basis = Basis(q.slerp(tgt["rot"], t))

# ── Peer connection ─────────────────────────────────────────────────────────

## Client calls this on the server when it has loaded and is ready to join.
@rpc("any_peer", "reliable")
func _on_client_connected():
	var id = multiplayer.get_remote_sender_id()
	_instantiate_player(id)
	_rpc_spawn_player.rpc(id)
	var children = $Players.get_children()
	for child in children:
		var existing_id = str(child.name).to_int()
		if existing_id != id:
			_rpc_spawn_player.rpc_id(id, existing_id)
	# Bring the new peer up to date on any objects spawned after scene load.
	for entry in _spawned_objects:
		var obj: Node = get_node_or_null(entry["name"])
		if obj and is_instance_valid(obj):
			_rpc_recv_spawn.rpc_id(id, entry["scene"], obj.global_transform, entry["name"])
	_sync_world_to_peer(id)
	hud.add_log("Player %d joined." % id)
	_broadcast_log.rpc("Player %d joined." % id)

## Received by all peers — instantiates the player with the given authority id.
@rpc("any_peer", "reliable")
func _rpc_spawn_player(id: int):
	_instantiate_player(id)

func _on_peer_disconnected(id: int):
	_remove_player(id)
	if multiplayer.is_server():
		hud.add_log("Player %d left." % id)
		_peer_left.rpc(id)

# Clients receive this when another player disconnects.
@rpc("any_peer", "reliable")
func _peer_left(id: int):
	_remove_player(id)
	hud.add_log("Player %d left." % id)

@rpc("any_peer", "reliable")
func _broadcast_log(msg: String):
	hud.add_log(msg)

func _instantiate_player(id: int):
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

func _remove_player(id: int):
	var node = $Players.get_node_or_null(str(id))
	if node:
		node.queue_free()

# ── Late-join world state sync ──────────────────────────────────────────────

func _find_interactable_node(node: Node) -> Interactable:
	for child in node.get_children():
		if child is Interactable:
			return child
	return null

## Sends a full world state snapshot to a newly connected peer.
func _sync_world_to_peer(id: int):
	for node in get_tree().get_nodes_in_group("world_objects"):
		if not node is RigidBody3D:
			continue
		var interactable = _find_interactable_node(node)
		var is_held = interactable != null and interactable.is_held
		_rpc_recv_object_state.rpc_id(
			id,
			str(node.get_path()),
			node.global_transform,
			node.linear_velocity,
			is_held
		)

@rpc("any_peer", "reliable")
func _rpc_recv_object_state(obj_path: String, xform: Transform3D, vel: Vector3, is_held: bool):
	var obj = get_tree().root.get_node_or_null(obj_path)
	if not obj is RigidBody3D:
		push_warning("[world] _rpc_recv_object_state: node not found: %s" % obj_path)
		return
	obj.global_transform = xform
	obj.linear_velocity = vel
	if is_held:
		obj.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		obj.freeze = true
		var interactable = _find_interactable_node(obj)
		if interactable:
			interactable.is_held = true

# ── Dynamic spawning ────────────────────────────────────────────────────────

## Removes a node from the scene on all peers. Server-authoritative.
## Accepts any PhysicsBody3D — works for RigidBody3D props and CharacterBody3D NPCs.
func despawn_object(node: Node) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		_rpc_request_despawn.rpc_id(1, str(node.get_path()))
	else:
		_server_despawn_object(str(node.get_path()))

@rpc("any_peer", "reliable")
func _rpc_request_despawn(node_path: String) -> void:
	if not multiplayer.is_server():
		return
	_server_despawn_object(node_path)

func _server_despawn_object(node_path: String) -> void:
	var node := get_tree().root.get_node_or_null(node_path)
	if not node:
		return
	_was_moving.erase(node_path)
	_net_targets.erase(node_path)
	node.queue_free()
	if multiplayer.has_multiplayer_peer():
		_rpc_recv_despawn.rpc(node_path)

@rpc("authority", "reliable")
func _rpc_recv_despawn(node_path: String) -> void:
	_was_moving.erase(node_path)
	_net_targets.erase(node_path)
	var node := get_tree().root.get_node_or_null(node_path)
	if node:
		node.queue_free()

## Public entry-point called by player.gd after a successful spawn raycast.
## Routes through the server so physics authority is always correct.
func spawn_object(scene_path: String, pos: Vector3) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		_rpc_request_spawn.rpc_id(1, scene_path, pos)
	else:
		_server_spawn_object(scene_path, pos)

## Client asks the server to spawn an object.
@rpc("any_peer", "reliable")
func _rpc_request_spawn(scene_path: String, pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_server_spawn_object(scene_path, pos)

## Server-side: instantiate, record, and broadcast to all clients.
func _server_spawn_object(scene_path: String, pos: Vector3) -> void:
	_spawn_counter += 1
	var obj_name: String = "dynobj_%d" % _spawn_counter
	var xform: Transform3D = Transform3D(Basis.IDENTITY, pos)
	_add_scene_object(scene_path, xform, obj_name)
	_spawned_objects.append({"scene": scene_path, "name": obj_name})
	if multiplayer.has_multiplayer_peer():
		_rpc_recv_spawn.rpc(scene_path, xform, obj_name)

## Clients (and late-joiners) receive this to instantiate the object locally.
@rpc("authority", "reliable")
func _rpc_recv_spawn(scene_path: String, xform: Transform3D, obj_name: String) -> void:
	_add_scene_object(scene_path, xform, obj_name)

func _add_scene_object(scene_path: String, xform: Transform3D, obj_name: String) -> void:
	var packed = load(scene_path)
	if not packed:
		push_warning("[world] spawn: cannot load '%s'" % scene_path)
		return
	# Avoid duplicate if this peer already has the node (e.g. server calling rpc()).
	if get_node_or_null(obj_name):
		return
	var obj: Node = packed.instantiate()
	obj.name = obj_name
	add_child(obj)
	obj.global_transform = xform   # must be set after add_child

# ── Sky system bootstrapping ─────────────────────────────────────────────────

## Guarantees SkyManager and CloudCeiling are present as siblings under this node.
## Idempotent: if world.tscn already has them (after the .tscn is reloaded in the
## editor) this is a no-op.  Also normalises the directional light name so
## SkyManager can locate it by the expected name "StarLight".
func _ensure_sky_nodes() -> void:
	# Rename legacy default name → StarLight (no-op if already renamed in .tscn).
	var dl := get_node_or_null("DirectionalLight3D")
	if dl:
		dl.name = "StarLight"

	# SkyManager —————————————————————————————————————————————————————————————
	if not get_node_or_null("SkyManager"):
		var sm := Node.new()
		sm.name = "SkyManager"
		sm.set_script(load("res://sky_manager.gd"))
		add_child(sm)

	# CloudCeiling — retired.  Cloud rendering is now done entirely inside
	# sky.gdshader via ray-plane projection (no geometry, no rectangular edges).

# ── Helpers ─────────────────────────────────────────────────────────────────

## Recursively walks a scene node and calls create_trimesh_collision() on
## every MeshInstance3D found. Used to generate runtime collision for GLB
## imports where the _subresources collision flag is unreliable.
func _build_mesh_colliders(node: Node) -> void:
	if not node:
		return
	if node is MeshInstance3D:
		node.create_trimesh_collision()
	for child in node.get_children():
		_build_mesh_colliders(child)
