extends CanvasLayer

signal action_chosen(action: String, target: Node)

@onready var log_label = $ConnectionLog
@onready var pause_overlay = $PauseOverlay
@onready var hover_label = $HoverLabel
@onready var action_menu = $ActionMenu
@onready var action_name_label = $ActionMenu/VBox/NameLabel
@onready var action_buttons = $ActionMenu/VBox/Buttons

var _action_target: Node = null
var _local_player: Node = null

const _SETTINGS = [
	{"group": "Movement"},
	{"prop": "SPEED",            "label": "Speed",          "min": 1.0,    "max": 20.0,  "step": 0.5},
	{"prop": "JUMP_VELOCITY",    "label": "Jump Height",    "min": 1.0,    "max": 20.0,  "step": 0.5},
	{"prop": "MOUSE_SENSITIVITY","label": "Sensitivity",    "min": 0.0005, "max": 0.01,  "step": 0.0005},
	{"prop": "GRAVITY_SCALE",    "label": "Gravity",        "min": 0.5,    "max": 5.0,   "step": 0.1},
	{"prop": "SLIDE_FRICTION",   "label": "Slide Friction", "min": 0.0,    "max": 20.0,  "step": 0.5},
	{"group": "Interaction"},
	{"prop": "INTERACT_RANGE",   "label": "Interact Range", "min": 1.0,    "max": 15.0,  "step": 0.5},
	{"prop": "CARRY_DISTANCE",   "label": "Carry Distance", "min": 0.5,    "max": 5.0,   "step": 0.1},
	{"prop": "MAX_CARRY_DIST",   "label": "Max Carry Dist", "min": 2.0,    "max": 20.0,  "step": 0.5},
	{"prop": "THROW_SPEED",      "label": "Throw Speed",    "min": 1.0,    "max": 50.0,  "step": 1.0},
	{"group": "Punch"},
	{"prop": "PUNCH_DISTANCE",   "label": "Distance",       "min": 0.5,    "max": 8.0,   "step": 0.1},
	{"prop": "PUNCH_ACCEL",      "label": "Acceleration",   "min": 10.0,   "max": 500.0, "step": 10.0},
	{"prop": "PUNCH_RETURN_SPEED","label": "Return Speed",  "min": 0.5,    "max": 20.0,  "step": 0.5},
	{"prop": "PUNCH_IMPULSE",    "label": "Impulse",        "min": 1.0,    "max": 50.0,  "step": 1.0},
	{"prop": "PUNCH_COOLDOWN",   "label": "Cooldown (s)",   "min": 0.05,   "max": 2.0,   "step": 0.05},
	{"prop": "PUNCH_PUSHBACK",   "label": "Pushback",       "min": 0.0,    "max": 2.0,   "step": 0.05},
]

func _ready():
	$PauseOverlay/CenterContainer.hide()
	var transparent = StyleBoxFlat.new()
	transparent.bg_color = Color.TRANSPARENT
	$PauseOverlay.add_theme_stylebox_override("panel", transparent)
	_add_role_label()

func _add_role_label():
	var label = Label.new()
	if not multiplayer.has_multiplayer_peer():
		label.text = "SOLO"
	elif multiplayer.is_server():
		label.text = "HOST"
	else:
		label.text = "CLIENT"
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.anchor_top = 0.0
	label.anchor_bottom = 0.0
	label.offset_left = -110
	label.offset_right = -10
	label.offset_top = 10
	label.offset_bottom = 40
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)

func set_local_player(player: Node):
	_local_player = player
	_build_settings()

func _on_setting_changed(value: float, prop: String, val_lbl: Label) -> void:
	_local_player.set(prop, value)
	val_lbl.text = str(value)

func _build_settings():
	if pause_overlay.get_node_or_null("SettingsPanel"):
		return
	var panel = PanelContainer.new()
	panel.name = "SettingsPanel"
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -230.0
	panel.offset_right = 230.0
	panel.offset_top = -300.0
	panel.offset_bottom = 300.0
	pause_overlay.add_child(panel)

	var outer_vbox = VBoxContainer.new()
	outer_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(outer_vbox)

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer_vbox.add_child(scroll)

	var settings_vbox = VBoxContainer.new()
	settings_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(settings_vbox)

	for entry in _SETTINGS:
		if entry.has("group"):
			var group_lbl = Label.new()
			group_lbl.text = "— " + entry["group"] + " —"
			group_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			settings_vbox.add_child(group_lbl)
			continue

		var row = HBoxContainer.new()
		settings_vbox.add_child(row)

		var name_lbl = Label.new()
		name_lbl.text = entry["label"]
		name_lbl.custom_minimum_size = Vector2(150, 0)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_lbl)

		var slider = HSlider.new()
		slider.min_value = entry["min"]
		slider.max_value = entry["max"]
		slider.step = entry["step"]
		slider.value = _local_player.get(entry["prop"])
		slider.custom_minimum_size = Vector2(180, 0)
		row.add_child(slider)

		var val_lbl = Label.new()
		val_lbl.text = str(slider.value)
		val_lbl.custom_minimum_size = Vector2(60, 0)
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(val_lbl)

		slider.value_changed.connect(_on_setting_changed.bind(entry["prop"], val_lbl))

	outer_vbox.add_child(HSeparator.new())

	var quit_btn = Button.new()
	quit_btn.text = "Quit to Menu"
	quit_btn.pressed.connect(_quit_to_menu)
	outer_vbox.add_child(quit_btn)

func _unhandled_input(event):
	if event.is_action_pressed("ui_cancel"):
		_toggle_pause()

func _toggle_pause():
	var showing = not pause_overlay.visible
	pause_overlay.visible = showing
	if showing:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif not (_local_player and _local_player.get("tab_mode")):
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _quit_to_menu():
	multiplayer.multiplayer_peer = null
	get_tree().change_scene_to_file("res://menu.tscn")

func add_log(msg: String):
	log_label.append_text(msg + "\n")

func show_hover_label(screen_pos: Vector2, text: String):
	hover_label.text = "[" + text + "]"
	hover_label.position = screen_pos + Vector2(14, -24)
	hover_label.visible = true

func hide_hover_label():
	hover_label.visible = false

func show_action_menu(screen_pos: Vector2, target: Node, display_name: String, actions: Array[String]):
	_action_target = target
	action_name_label.text = display_name
	for child in action_buttons.get_children():
		child.queue_free()
	for action in actions:
		var btn = Button.new()
		btn.text = action
		btn.pressed.connect(_on_action_pressed.bind(action))
		action_buttons.add_child(btn)
	action_menu.position = screen_pos - Vector2(action_menu.custom_minimum_size.x * 0.5, action_menu.size.y + 16)
	action_menu.visible = true

func hide_action_menu():
	action_menu.visible = false
	_action_target = null

func is_action_menu_visible() -> bool:
	return action_menu.visible

func _on_action_pressed(action: String):
	var target = _action_target
	hide_action_menu()
	action_chosen.emit(action, target)

func _notification(what):
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
