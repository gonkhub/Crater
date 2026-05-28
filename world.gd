extends Node

const PLAYER = preload("res://Objects/player.tscn")

var hud: Node

func _ready():
	hud = preload("res://hud.tscn").instantiate()
	add_child(hud)

	_register_interactables()
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if not multiplayer.has_multiplayer_peer():
		_do_spawn(1)
		return

	if multiplayer.is_server():
		multiplayer.peer_connected.connect(_on_peer_connected)
		_do_spawn(1)
	else:
		_client_ready.rpc_id(1)

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

func _on_peer_connected(_id: int):
	pass

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

func _register_interactables():
	_make_interactable("adio", "Adio", ["Take"])

func _make_interactable(node_name: String, display_name: String, actions: Array[String]):
	var node = get_node_or_null(node_name)
	if not node:
		push_warning("_make_interactable: node '%s' not found" % node_name)
		return
	node.add_to_group("world_objects")
	var tag = Interactable.new()
	tag.display_name = display_name
	tag.actions = actions
	node.add_child(tag)

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

func _do_remove(id: int):
	var node = $Players.get_node_or_null(str(id))
	if node:
		node.queue_free()
