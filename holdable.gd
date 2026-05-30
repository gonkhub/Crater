class_name Holdable
extends Node

enum Weight { LIGHT, MEDIUM, HEAVY }

# Per-weight hold dynamics. Array index matches the Weight enum value.
# Tunable at runtime via the pause-menu Weight Class settings (changes saved to disk).
# To tune a single object at runtime, use the in-game Tune action.
# To tune a single object in the editor, use the Physics Overrides exports.
#   sway_mouse_scale  — mouse input scale for sway position
#   sway_damping      — positional sway damping (higher = snappier)
#   sway_spring_k     — stiffness of the spring pulling sway to the target edge
#   sway_max_speed    — hard cap on sway angular velocity (rad/s)
#   sway_sensitivity  — mouse pixels/frame to reach full opposite-edge amplitude
#   roll_damping      — how quickly axial spin decays (lower = coasts longer)
#   max_roll_speed    — hard cap on axial spin (rad/s)
#   punch_pull        — player velocity impulse (m/s) fired once when punch peaks
#   punch_accel       — extend-phase acceleration (m/s²)
#   punch_peak_hold   — seconds to dwell at max extension before settling
#   punch_settle_spd  — retraction speed (m/s) from peak to M1-held position
#   punch_pushback    — acceleration (m/s²) pushed back onto the player on collision
## Static so all Holdable instances share one live table.
static var _WEIGHT_PHYSICS = [
	# LIGHT  — nimble, quick to respond, moderate spin persistence
	{ "sway_mouse_scale": 0.010, "sway_damping": 0.30, "sway_spring_k": 14.0, "sway_max_speed":  8.0,
	  "sway_sensitivity": 18.0,
	  "roll_damping": 0.08, "max_roll_speed": 15.0,
	  "punch_pull":  2.0, "punch_accel": 220.0, "punch_peak_hold": 0.06, "punch_settle_spd": 1.2,
	  "punch_pushback":  6.0 },
	# MEDIUM — heavier feel, more resistance to input, spin coasts longer
	{ "sway_mouse_scale": 0.006, "sway_damping": 0.40, "sway_spring_k": 10.0, "sway_max_speed":  5.5,
	  "sway_sensitivity": 32.0,
	  "roll_damping": 0.05, "max_roll_speed":  8.0,
	  "punch_pull":  5.0, "punch_accel": 120.0, "punch_peak_hold": 0.12, "punch_settle_spd": 0.9,
	  "punch_pushback": 14.0 },
	# HEAVY  — ponderous, hard to start moving, very persistent spin (flywheel)
	{ "sway_mouse_scale": 0.003, "sway_damping": 0.60, "sway_spring_k":  6.0, "sway_max_speed":  3.5,
	  "sway_sensitivity": 52.0,
	  "roll_damping": 0.02, "max_roll_speed":  4.0,
	  "punch_pull": 10.0, "punch_accel":  55.0, "punch_peak_hold": 0.20, "punch_settle_spd": 0.6,
	  "punch_pushback": 28.0 },
]

# ── Hold ────────────────────────────────────────────────────────────────────
@export_group("Hold")

## Local Euler rotation applied on top of the carry system's facing direction.
## Use this to align the object's mesh with the pivot axis.
## Example: Vector3(-90, 0, 0) rotates a Y-axis capsule to point toward the
## anchor (screen-centre end). Leave at zero for symmetric / round objects.
@export var hold_rotation: Vector3 = Vector3.ZERO

## Half-length of the object along the hold axis (metres).
## Defines the radius of the sway circle and how far the tip sits from centre.
## 0 = static carry with no sway.
## Typical values: 0.15 for compact objects, 0.5–0.7 for long weapons.
@export_range(0.0, 1.5, 0.05) var hold_pivot: float = 0.15

## Weight class — sets the baseline physics from the _WEIGHT_PHYSICS table.
## Override individual values below without changing the bucket.
@export var weight: Weight = Weight.LIGHT

# ── Actions ─────────────────────────────────────────────────────────────────
@export_group("Actions")

## Action fired by the primary (left) mouse button while holding.
## Built-in: "punch", "throw". Leave empty to disable.
@export var m1_action: String = "punch"

## Action fired by the secondary (right) mouse button while holding.
## Leave empty to disable.
@export var m2_action: String = ""

## Action fired by scroll-up while holding.
@export var scroll_up_action: String = "throw"

# ── Physics Overrides ────────────────────────────────────────────────────────
@export_group("Physics Overrides")
## Per-object overrides for the weight-bucket physics values.
## Leave at 0 to inherit from the weight bucket. Any non-zero value replaces
## that specific parameter for this object only.

## Mouse input sensitivity. Overrides sway_mouse_scale from the weight bucket.
@export_range(0.0, 0.03, 0.001) var override_mouse_scale: float = 0.0

## Position angular damping per second. Overrides sway_damping.
@export_range(0.0, 2.0, 0.05) var override_sway_damping: float = 0.0

## Axial spin decay per second. Overrides roll_damping.
@export_range(0.0, 0.5, 0.005) var override_roll_damping: float = 0.0

## Hard cap on axial spin speed (rad/s). Overrides max_roll_speed.
@export_range(0.0, 30.0, 0.5) var override_max_roll_speed: float = 0.0

# ── Carry Overrides ──────────────────────────────────────────────────────────
@export_group("Carry Overrides")
## Per-object carry/throw overrides. Leave at 0 to use the player's global setting.

## How far in front of the camera this object is held (metres). 0 = player default.
@export_range(0.0, 5.0, 0.1) var carry_distance: float = 0.0

## Maximum tether distance before the object is dropped. 0 = player default.
@export_range(0.0, 20.0, 0.5) var max_carry_dist: float = 0.0

## Speed added to the throw direction vector (m/s). 0 = player default.
@export_range(0.0, 50.0, 1.0) var throw_speed: float = 0.0

# ── Punch Overrides ──────────────────────────────────────────────────────────
@export_group("Punch Overrides")
## Per-object punch overrides. Leave at 0 to use the player's global setting.

## Maximum punch extension distance (metres). 0 = player default.
@export_range(0.0, 8.0, 0.1) var punch_distance: float = 0.0

## Impulse applied to hit rigid bodies (N·s). 0 = player default.
@export_range(0.0, 50.0, 1.0) var punch_impulse: float = 0.0

## Minimum time between punches (seconds). 0 = player default.
@export_range(0.0, 2.0, 0.05) var punch_cooldown: float = 0.0

# ────────────────────────────────────────────────────────────────────────────

## Returns the effective physics dictionary for this object: the weight bucket
## with any non-zero per-object overrides applied on top.
func get_dynamics() -> Dictionary:
	var d: Dictionary = _WEIGHT_PHYSICS[weight].duplicate()
	if override_mouse_scale    > 0.0: d["sway_mouse_scale"] = override_mouse_scale
	if override_sway_damping   > 0.0: d["sway_damping"]     = override_sway_damping
	if override_roll_damping   > 0.0: d["roll_damping"]      = override_roll_damping
	if override_max_roll_speed > 0.0: d["max_roll_speed"]   = override_max_roll_speed
	return d

## Returns the per-object tunable properties for the Tune popup.
## Each entry must have "type": "dropdown" or "type": "number".
##   dropdown — "prop", "label", "options": Array[String]
##   number   — "prop", "label", "min", "max", "step"
## Values of 0 for carry/punch fields inherit the player's global default.
## Weight-class physics are tuned globally in the pause-menu settings panel.
func tune_schema() -> Array:
	return [
		{"type": "dropdown", "prop": "weight",        "label": "Weight Bucket",
		 "options": ["Light", "Medium", "Heavy"]},
		{"type": "number",   "prop": "carry_distance", "label": "Hold Point",         "min": 0.0,  "max": 20.0,  "step": 0.1},
		{"type": "number",   "prop": "max_carry_dist", "label": "Max Carry Distance", "min": 0.0,  "max": 50.0,  "step": 0.5},
		{"type": "number",   "prop": "throw_speed",    "label": "Throw Force",        "min": 0.0,  "max": 100.0, "step": 0.5},
		{"type": "number",   "prop": "punch_impulse",  "label": "Punch Force",        "min": 0.0,  "max": 100.0, "step": 0.5},
		{"type": "number",   "prop": "punch_cooldown", "label": "Punch Cooldown",     "min": 0.0,  "max": 10.0,  "step": 0.05},
		{"type": "number",   "prop": "punch_distance", "label": "Punch Distance",     "min": 0.0,  "max": 20.0,  "step": 0.1},
	]

# ── Persistent tune save / load ──────────────────────────────────────────────

const TUNE_SAVE_PATH = "user://object_tunes.cfg"

## ConfigFile section key — uses the parent scene file path so all instances
## of the same scene share one saved tune.
func _save_key() -> String:
	var parent = get_parent()
	if parent:
		var path: String = parent.scene_file_path
		if not path.is_empty():
			return path
	return ""

## Called in _ready(): applies any previously saved values for this scene.
func _apply_saved_tune() -> void:
	var key: String = _save_key()
	if key.is_empty():
		return
	var cfg := ConfigFile.new()
	if cfg.load(TUNE_SAVE_PATH) != OK:
		return
	for entry in tune_schema():
		if not entry.has("prop"):
			continue
		var prop: String = entry["prop"]
		if cfg.has_section_key(key, prop):
			set(prop, cfg.get_value(key, prop))

## Called by hud.gd when the player changes a field in the Tune popup.
## Accepts any value type (float for number fields, int for dropdown index).
func save_tune_value(prop: String, value) -> void:
	var key: String = _save_key()
	if key.is_empty():
		set(prop, value)
		return
	var cfg := ConfigFile.new()
	cfg.load(TUNE_SAVE_PATH)   # silently ignored if file doesn't exist yet
	cfg.set_value(key, prop, value)
	cfg.save(TUNE_SAVE_PATH)
	set(prop, value)

# ── Weight-class physics persistence ────────────────────────────────────────

static var _physics_loaded: bool = false

## Loads any saved weight-class physics overrides into the live table.
## Called once (guarded by _physics_loaded) from the first _ready().
static func load_weight_physics() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(TUNE_SAVE_PATH) != OK:
		return
	for i in range(3):
		var section := "weight_%d" % i
		if not cfg.has_section(section):
			continue
		for key in cfg.get_section_keys(section):
			if _WEIGHT_PHYSICS[i].has(key):
				_WEIGHT_PHYSICS[i][key] = cfg.get_value(section, key)

## Called by hud.gd's weight-class sliders: updates the live table and saves.
static func save_weight_physics(weight_idx: int, key: String, value: float) -> void:
	_WEIGHT_PHYSICS[weight_idx][key] = value
	var cfg := ConfigFile.new()
	cfg.load(TUNE_SAVE_PATH)
	cfg.set_value("weight_%d" % weight_idx, key, value)
	cfg.save(TUNE_SAVE_PATH)

## Returns the compile-time default physics table (not the live/saved one).
## Used by the HUD reset button to restore a weight class to factory values.
static func get_default_physics() -> Array:
	return [
		{ "sway_mouse_scale": 0.010, "sway_damping": 0.30, "sway_spring_k": 14.0, "sway_max_speed":  8.0,
		  "sway_sensitivity": 18.0,
		  "roll_damping": 0.08, "max_roll_speed": 15.0,
		  "punch_pull":  2.0, "punch_accel": 220.0, "punch_peak_hold": 0.06, "punch_settle_spd": 1.2,
		  "punch_pushback":  6.0 },
		{ "sway_mouse_scale": 0.006, "sway_damping": 0.40, "sway_spring_k": 10.0, "sway_max_speed":  5.5,
		  "sway_sensitivity": 32.0,
		  "roll_damping": 0.05, "max_roll_speed":  8.0,
		  "punch_pull":  5.0, "punch_accel": 120.0, "punch_peak_hold": 0.12, "punch_settle_spd": 0.9,
		  "punch_pushback": 14.0 },
		{ "sway_mouse_scale": 0.003, "sway_damping": 0.60, "sway_spring_k":  6.0, "sway_max_speed":  3.5,
		  "sway_sensitivity": 52.0,
		  "roll_damping": 0.02, "max_roll_speed":  4.0,
		  "punch_pull": 10.0, "punch_accel":  55.0, "punch_peak_hold": 0.20, "punch_settle_spd": 0.6,
		  "punch_pushback": 28.0 },
	]

## Resets one weight class to factory defaults: updates the live table,
## wipes the saved section, and returns the restored dict so the HUD can
## refresh its sliders without a rebuild.
static func reset_weight_physics(weight_idx: int) -> Dictionary:
	var defaults := get_default_physics()
	_WEIGHT_PHYSICS[weight_idx] = defaults[weight_idx].duplicate()
	var cfg := ConfigFile.new()
	cfg.load(TUNE_SAVE_PATH)
	cfg.erase_section("weight_%d" % weight_idx)
	cfg.save(TUNE_SAVE_PATH)
	return _WEIGHT_PHYSICS[weight_idx]

func _ready():
	# Load global weight-class overrides once, before any per-object tune is applied.
	if not _physics_loaded:
		_physics_loaded = true
		load_weight_physics()
	_apply_saved_tune()
	# Auto-register "Take" so designers don't have to list it manually.
	var interactable = _get_interactable()
	if interactable and "Take" not in interactable.actions:
		interactable.actions.push_front("Take")

func _get_interactable() -> Interactable:
	for child in get_parent().get_children():
		if child is Interactable:
			return child
	return null
