extends Node3D

## Procedurally creates three staggered cloud ceiling mesh layers.
##
## Each layer is a large flat quad at a slightly different altitude.
## Staggering the heights gives parallax depth when the player moves,
## selling the impression of a thick, volumetric cloud mass from below.
##
## SkyManager iterates our MeshInstance3D children every frame to push
## the star direction / energy uniforms.  No per-frame work here.

# ── Sizing ────────────────────────────────────────────────────────────────────
## Altitude of the lowest cloud layer above world origin (metres).
## Reduce this to bring the ceiling closer and more imposing; increase to
## push it toward the crater rim.
@export var cloud_altitude: float = 30.0

## Half-width of each cloud layer mesh (metres).
## Should generously exceed crater_radius so no edge is ever visible.
@export var cloud_radius: float = 150.0

# ── Per-layer configuration ───────────────────────────────────────────────────
# Three layers tuned for large organic cumulus masses:
#
#   Layer 0 (base, y = cloud_altitude):
#       The flat, dark underside.  High density_threshold creates large sky gaps
#       so the visible masses read as distinct cumulus towers rather than a
#       continuous sheet.  Moderate softness keeps edges organic, not grid-sharp.
#
#   Layer 1 (mid, y = cloud_altitude + 22 m):
#       Visible through gaps in the base.  Different drift direction creates
#       clear parallax depth when the player moves.
#
#   Layer 2 (high, y = cloud_altitude + 52 m):
#       Thin, broken cloud caught high above.  Moves fastest so the depth
#       separation is obvious; bright backlight turns it into glowing wisps.
#
# Key parameters:
#   • noise_scale 0.006–0.009  → enough UV periods for domain-warp to act
#                                 (at 0.003 a 300 m world spans < 1 period → grid)
#   • density_threshold 0.62–0.70 → large clear sky between cloud masses
#   • density_softness  0.22–0.30 → moderately soft edges hide lattice structure
const _LAYER_CONFIG: Array[Dictionary] = [
	{
		"altitude_offset":    0.0,
		"density_threshold":  0.62,
		"density_softness":   0.22,
		"layer_opacity":      0.94,
		"noise_scale":        0.0060,
		"detail_scale":       0.022,
		"drift_speed":        0.0018,
		"convect_speed":      0.0009,
		"drift_direction":    Vector2(1.0,  0.15),
		"backlight_strength": 0.70,
	},
	{
		"altitude_offset":    12.0,
		"density_threshold":  0.65,
		"density_softness":   0.25,
		"layer_opacity":      0.55,
		"noise_scale":        0.0075,
		"detail_scale":       0.025,
		"drift_speed":        0.0030,
		"convect_speed":      0.0015,
		"drift_direction":    Vector2(0.6, -0.8),
		"backlight_strength": 0.85,
	},
	{
		"altitude_offset":    26.0,
		"density_threshold":  0.70,
		"density_softness":   0.30,
		"layer_opacity":      0.35,
		"noise_scale":        0.0090,
		"detail_scale":       0.028,
		"drift_speed":        0.0046,
		"convect_speed":      0.0023,
		"drift_direction":    Vector2(-0.5, 0.9),
		"backlight_strength": 0.95,
	},
]

func _ready() -> void:
	# Cloud rendering has moved into sky.gdshader (ray-plane projection).
	# This node is no longer used and will be removed from the scene.
	pass

func _add_layer(cfg: Dictionary, shader: Shader) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(cloud_radius * 2.0, cloud_radius * 2.0)
	# Minimal subdivision — visual detail comes entirely from the shader,
	# not from geometry, so extra verts just waste bandwidth.
	plane.subdivide_width  = 0
	plane.subdivide_depth  = 0

	var inst := MeshInstance3D.new()
	inst.mesh         = plane
	inst.cast_shadow  = MeshInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.position     = Vector3(0.0, cloud_altitude + float(cfg["altitude_offset"]), 0.0)

	var mat := ShaderMaterial.new()
	mat.shader = shader
	for key: String in cfg:
		if key == "altitude_offset":
			continue   # handled as mesh position, not shader param
		mat.set_shader_parameter(key, cfg[key])
	# Radial fade needs to know the mesh boundary to hide it.
	mat.set_shader_parameter("cloud_radius", cloud_radius)
	inst.material_override = mat

	add_child(inst)
