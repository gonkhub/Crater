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
var _info_popup: Control = null
var _tune_popup: Control = null
var _tune_holdable: Holdable = null

const _SETTINGS = [
	{"group": "Movement"},
	{"prop": "SPEED",            "label": "Speed",          "min": 1.0,    "max": 20.0,  "step": 0.5},
	{"prop": "JUMP_VELOCITY",    "label": "Jump Height",    "min": 1.0,    "max": 20.0,  "step": 0.5},
	{"prop": "MOUSE_SENSITIVITY","label": "Sensitivity",    "min": 0.0005, "max": 0.01,  "step": 0.0005},
	{"prop": "GRAVITY_SCALE",    "label": "Gravity",        "min": 0.5,    "max": 5.0,   "step": 0.1},
	{"prop": "SLIDE_FRICTION",   "label": "Slide Friction", "min": 0.0,    "max": 20.0,  "step": 0.5},
]

# Physics params exposed per weight class in the pause-menu settings panel.
# Each entry maps to a key in Holdable._WEIGHT_PHYSICS[i].
const _WEIGHT_PARAMS = [
	{"key": "sway_mouse_scale",  "label": "Mouse Scale",      "min": 0.0,   "max": 0.05,  "step": 0.001},
	{"key": "sway_damping",      "label": "Sway Damping",     "min": 0.0,   "max": 2.0,   "step": 0.05},
	{"key": "sway_spring_k",     "label": "Sway Spring",      "min": 0.0,   "max": 30.0,  "step": 0.5},
	{"key": "sway_max_speed",    "label": "Sway Max Speed",   "min": 0.0,   "max": 20.0,  "step": 0.5},
	{"key": "sway_sensitivity",  "label": "Sway Sensitivity", "min": 1.0,   "max": 100.0, "step": 1.0},
	{"key": "roll_damping",      "label": "Roll Damping",     "min": 0.0,   "max": 0.5,   "step": 0.005},
	{"key": "max_roll_speed",    "label": "Max Roll Speed",   "min": 0.0,   "max": 30.0,  "step": 0.5},
	{"key": "punch_pull",        "label": "Punch Pull",       "min": 0.0,   "max": 20.0,  "step": 0.5},
	{"key": "punch_accel",       "label": "Punch Accel",      "min": 0.0,   "max": 500.0, "step": 5.0},
	{"key": "punch_peak_hold",   "label": "Peak Hold (s)",    "min": 0.0,   "max": 1.0,   "step": 0.01},
	{"key": "punch_settle_spd",  "label": "Settle Speed",     "min": 0.0,   "max": 5.0,   "step": 0.1},
	{"key": "punch_pushback",    "label": "Punch Pushback",   "min": 0.0,   "max": 60.0,  "step": 1.0},
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

	_build_weight_settings(settings_vbox)

	outer_vbox.add_child(HSeparator.new())

	var quit_btn = Button.new()
	quit_btn.text = "Quit to Menu"
	quit_btn.pressed.connect(_quit_to_menu)
	outer_vbox.add_child(quit_btn)

func _build_weight_settings(vbox: VBoxContainer) -> void:
	var weight_names = ["Light", "Medium", "Heavy"]
	for i in range(3):
		var group_lbl = Label.new()
		group_lbl.text = "— Weight Class: %s —" % weight_names[i]
		group_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(group_lbl)

		for param in _WEIGHT_PARAMS:
			var row = HBoxContainer.new()
			vbox.add_child(row)

			var name_lbl = Label.new()
			name_lbl.text = param["label"]
			name_lbl.custom_minimum_size = Vector2(150, 0)
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(name_lbl)

			var slider = HSlider.new()
			slider.min_value = param["min"]
			slider.max_value = param["max"]
			slider.step      = param["step"]
			slider.value     = Holdable._WEIGHT_PHYSICS[i].get(param["key"], 0.0)
			slider.custom_minimum_size = Vector2(180, 0)
			row.add_child(slider)

			var val_lbl = Label.new()
			val_lbl.text = str(slider.value)
			val_lbl.custom_minimum_size = Vector2(60, 0)
			val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(val_lbl)

			slider.value_changed.connect(_on_weight_setting_changed.bind(i, param["key"], val_lbl))

func _on_weight_setting_changed(value: float, weight_idx: int, key: String, val_lbl: Label) -> void:
	Holdable.save_weight_physics(weight_idx, key, value)
	val_lbl.text = str(value)

func _unhandled_input(event):
	if event.is_action_pressed("ui_cancel"):
		if _tune_popup != null:
			hide_tune_popup()
			return
		if _info_popup != null:
			hide_info_popup()
			return
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
	hide_info_popup()
	hide_tune_popup()
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

# ── Info popup ──────────────────────────────────────────────────────────────

func show_info_popup(interactable: Interactable, target: Node) -> void:
	hide_info_popup()

	var popup = PanelContainer.new()
	popup.anchor_left   = 0.5
	popup.anchor_right  = 0.5
	popup.anchor_top    = 0.5
	popup.anchor_bottom = 0.5
	popup.offset_left   = -160.0
	popup.offset_right  =  160.0
	popup.offset_top    = -140.0
	popup.offset_bottom =  140.0

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	popup.add_child(vbox)

	# ── Header: name (left) + weight tag (right, small italic) ──────────────
	var header = HBoxContainer.new()
	vbox.add_child(header)

	var name_lbl = Label.new()
	name_lbl.text = interactable.display_name
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 18)
	header.add_child(name_lbl)

	# Weight tag — only shown for objects that have a Holdable component
	var holdable: Holdable = null
	for child in target.get_children():
		if child is Holdable:
			holdable = child
			break
	if holdable:
		var weight_names = ["light", "medium", "heavy"]
		var weight_lbl = Label.new()
		weight_lbl.text = weight_names[holdable.weight]
		weight_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		weight_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		weight_lbl.size_flags_horizontal = Control.SIZE_SHRINK_END
		weight_lbl.add_theme_font_size_override("font_size", 11)
		weight_lbl.add_theme_color_override("font_color", Color(0.60, 0.60, 0.60))
		weight_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header.add_child(weight_lbl)

	vbox.add_child(HSeparator.new())

	# ── Description (scrollable) ─────────────────────────────────────────────
	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var desc = RichTextLabel.new()
	desc.bbcode_enabled = true
	desc.fit_content = true
	desc.scroll_active = false
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if interactable.description.is_empty():
		desc.text = "[color=#888888][i]No description available.[/i][/color]"
	else:
		desc.text = interactable.description
	scroll.add_child(desc)

	vbox.add_child(HSeparator.new())

	# ── Close button (right-aligned) ─────────────────────────────────────────
	var btn_row = HBoxContainer.new()
	vbox.add_child(btn_row)
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)
	var close_btn = Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(hide_info_popup)
	btn_row.add_child(close_btn)

	add_child(popup)
	_info_popup = popup

func hide_info_popup() -> void:
	if _info_popup:
		_info_popup.queue_free()
		_info_popup = null

func is_info_popup_visible() -> bool:
	return _info_popup != null

# ── Tune popup ───────────────────────────────────────────────────────────────

func show_tune_popup(target: Node) -> void:
	hide_tune_popup()

	var holdable: Holdable = null
	var interactable: Interactable = null
	for child in target.get_children():
		if child is Holdable:    holdable = child
		elif child is Interactable: interactable = child
	if not holdable:
		return
	_tune_holdable = holdable

	var popup = PanelContainer.new()
	popup.anchor_left   = 0.5
	popup.anchor_right  = 0.5
	popup.anchor_top    = 0.5
	popup.anchor_bottom = 0.5
	popup.offset_left   = -200.0
	popup.offset_right  =  200.0
	popup.offset_top    = -200.0
	popup.offset_bottom =  200.0

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	popup.add_child(vbox)

	# ── Header ────────────────────────────────────────────────────────────────
	var header = HBoxContainer.new()
	vbox.add_child(header)

	var name_lbl = Label.new()
	name_lbl.text = interactable.display_name if interactable else target.name
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 18)
	header.add_child(name_lbl)

	var tag_lbl = Label.new()
	tag_lbl.text = "tune"
	tag_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tag_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	tag_lbl.size_flags_horizontal = Control.SIZE_SHRINK_END
	tag_lbl.add_theme_font_size_override("font_size", 11)
	tag_lbl.add_theme_color_override("font_color", Color(0.60, 0.60, 0.60))
	tag_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(tag_lbl)

	vbox.add_child(HSeparator.new())

	# ── Field rows (scrollable) ───────────────────────────────────────────────
	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var content_vbox = VBoxContainer.new()
	content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(content_vbox)

	for entry in holdable.tune_schema():
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		content_vbox.add_child(row)

		var lbl = Label.new()
		lbl.text = entry["label"]
		lbl.custom_minimum_size = Vector2(140, 0)
		lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lbl)

		match entry.get("type", ""):
			"dropdown":
				var opt = OptionButton.new()
				for option in entry["options"]:
					opt.add_item(option)
				opt.selected = int(holdable.get(entry["prop"]))
				opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(opt)
				opt.item_selected.connect(_on_tune_dropdown_changed.bind(entry["prop"], holdable))
			"number":
				var spin = SpinBox.new()
				spin.min_value     = entry["min"]
				spin.max_value     = entry["max"]
				spin.step          = entry["step"]
				spin.value         = holdable.get(entry["prop"])
				spin.allow_greater = true
				spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(spin)
				spin.value_changed.connect(_on_tune_number_changed.bind(entry["prop"], holdable))

	vbox.add_child(HSeparator.new())

	# ── Close button ──────────────────────────────────────────────────────────
	var btn_row = HBoxContainer.new()
	vbox.add_child(btn_row)
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)
	var close_btn = Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(hide_tune_popup)
	btn_row.add_child(close_btn)

	add_child(popup)
	_tune_popup = popup

func hide_tune_popup() -> void:
	if _tune_popup:
		_tune_popup.queue_free()
		_tune_popup = null
	_tune_holdable = null

func is_tune_popup_visible() -> bool:
	return _tune_popup != null

func _on_tune_number_changed(value: float, prop: String, holdable: Holdable) -> void:
	if is_instance_valid(holdable):
		holdable.save_tune_value(prop, value)

func _on_tune_dropdown_changed(index: int, prop: String, holdable: Holdable) -> void:
	if is_instance_valid(holdable):
		holdable.save_tune_value(prop, index)
