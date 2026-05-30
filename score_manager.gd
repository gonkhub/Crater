extends Node

signal score_updated(peer_id: int, new_score: int)
signal player_registered(peer_id: int)
signal player_unregistered(peer_id: int)

# peer_id → cumulative score (int)
var _scores: Dictionary = {}
# scene_path → true once that type has been incinerated (first incineration = 2×)
var _seen_types: Dictionary = {}

# ── Registration ──────────────────────────────────────────────────────────────

func register_player(peer_id: int) -> void:
	if _scores.has(peer_id):
		return
	_scores[peer_id] = 0
	player_registered.emit(peer_id)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rpc_register_player.rpc(peer_id)

func unregister_player(peer_id: int) -> void:
	if not _scores.has(peer_id):
		return
	_scores.erase(peer_id)
	player_unregistered.emit(peer_id)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rpc_unregister_player.rpc(peer_id)

# ── Scoring ───────────────────────────────────────────────────────────────────

## Award points for an incinerated object. Call on the server (or in solo play) only.
## First time a given scene_path is incinerated in this session, base_points is doubled.
func award_score(peer_id: int, scene_path: String, base_points: int) -> void:
	if not _scores.has(peer_id):
		return
	var multiplier: int = 2 if not _seen_types.has(scene_path) else 1
	_seen_types[scene_path] = true
	var points: int = base_points * multiplier
	_scores[peer_id] += points
	score_updated.emit(peer_id, _scores[peer_id])
	if multiplayer.has_multiplayer_peer():
		_rpc_score_updated.rpc(peer_id, _scores[peer_id])

func get_scores() -> Dictionary:
	return _scores.duplicate()

func get_score(peer_id: int) -> int:
	return _scores.get(peer_id, 0)

# ── Late-join sync ────────────────────────────────────────────────────────────

## Called by world.gd when a new client connects — sends full state to that peer.
func sync_to_peer(peer_id: int) -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rpc_full_state.rpc_id(peer_id, _scores.duplicate(), _seen_types.duplicate())

# ── RPCs ──────────────────────────────────────────────────────────────────────

@rpc("authority", "reliable")
func _rpc_score_updated(peer_id: int, new_score: int) -> void:
	_scores[peer_id] = new_score
	score_updated.emit(peer_id, new_score)

@rpc("authority", "reliable")
func _rpc_register_player(peer_id: int) -> void:
	if _scores.has(peer_id):
		return
	_scores[peer_id] = 0
	player_registered.emit(peer_id)

@rpc("authority", "reliable")
func _rpc_unregister_player(peer_id: int) -> void:
	_scores.erase(peer_id)
	player_unregistered.emit(peer_id)

@rpc("authority", "reliable")
func _rpc_full_state(scores: Dictionary, seen_types: Dictionary) -> void:
	for pid in scores:
		if not _scores.has(pid):
			_scores[pid] = scores[pid]
			player_registered.emit(pid)
		else:
			_scores[pid] = scores[pid]
			score_updated.emit(pid, _scores[pid])
	_seen_types.merge(seen_types)
