extends Node3D

const _BOX_SIZE := Vector3(2.0, 2.0, 2.0)

func _ready() -> void:
	# ── Visual: glowing orange box (no physics collision) ────────────────────
	var mesh_inst := MeshInstance3D.new()
	var box_mesh  := BoxMesh.new()
	box_mesh.size = _BOX_SIZE
	var mat := StandardMaterial3D.new()
	mat.albedo_color               = Color(1.0, 0.42, 0.0)
	mat.emission_enabled           = true
	mat.emission                   = Color(1.0, 0.35, 0.0)
	mat.emission_energy_multiplier = 0.8
	box_mesh.surface_set_material(0, mat)
	mesh_inst.mesh        = box_mesh
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_inst)

	# ── Detection area — same footprint as the visual box ────────────────────
	var area   := Area3D.new()
	var cshape := CollisionShape3D.new()
	var bshape := BoxShape3D.new()
	bshape.size  = _BOX_SIZE
	cshape.shape = bshape
	area.add_child(cshape)
	add_child(area)
	area.body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	# Scoring and despawn are server-authoritative.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return

	var interactable: Interactable = null
	for child in body.get_children():
		if child is Interactable:
			interactable = child
			break
	# Only scoreable world objects (those with an Interactable) are processed.
	if not interactable:
		return

	var holdable: Holdable = null
	for child in body.get_children():
		if child is Holdable:
			holdable = child
			break

	# Award points to the last player who held the object.
	var last_holder: int = interactable.last_holder_id
	if last_holder >= 0 and holdable and holdable.point_value > 0.0:
		ScoreManager.award_score(last_holder, body.scene_file_path, roundi(holdable.point_value))

	# Always despawn the object on all peers.
	var world := get_tree().get_first_node_in_group("world_root")
	if world and world.has_method("despawn_object"):
		world.despawn_object(body)
