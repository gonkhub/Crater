class_name Interactable
extends Node

signal action_performed(action: String, by_player: Node)

# ── Identity ─────────────────────────────────────────────────────────────────
@export_group("Identity")

## Name shown in hover labels, action menus, and the info popup header.
@export var display_name: String = "Object"

## Body text shown in the info popup. Supports RichTextLabel BBCode tags
## ([b]bold[/b], [i]italic[/i], [color=#hex]text[/color], etc.).
## Leave empty to show "No description available."
@export_multiline var description: String = ""

# ── Actions ───────────────────────────────────────────────────────────────────
@export_group("Actions")

## Additional actions shown in the interaction menu beyond the auto-registered
## ones. "Take" is prepended automatically by a Holdable component if present.
## "Info" is always appended last. Example custom actions: ["Open", "Activate"].
@export var actions: Array[String] = []

# ─────────────────────────────────────────────────────────────────────────────

# Set by the player holding this object; prevents others from taking it.
var is_held: bool = false

func _ready():
	# "Tune" and "Info" are available on every interactable — Tune first, Info last.
	if "Tune" not in actions:
		actions.append("Tune")
	if "Info" not in actions:
		actions.append("Info")
