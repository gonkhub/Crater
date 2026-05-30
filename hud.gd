extends CanvasLayer

signal action_chosen(action: String, target: Node)

@onready var log_label    = $ConnectionLog
@onready var pause_overlay = $PauseOverlay
@onready var hover_label  = $HoverLabel
@onready var action_menu  = $ActionMenu
@onready var action_name_label = $ActionMenu/VBox/NameLabel
@onready var action_buttons    = $ActionMenu/VBox/Buttons

var _action_target:  Node     = null
var _local_player:   Node     = null
var _info_popup:     Control  = null
var _tune_popup:     Control  = null
var _tune_holdable:  Holdable = null

# ── Spawn mode ───────────────────────────────────────────────────────────────
var _pending_spawn: String = ""   # scene path queued for placement; "" = inactive
var _spawn_label:   Label  = null

# ── Despawn mode ─────────────────────────────────────────────────────────────
var _despawn_mode:  bool  = false
var _despawn_label: Label = null

# ── FPS overlay ───────────────────────────────────────────────────────────────
var _fps_label: Label = null

# ── Dev panel drag state ──────────────────────────────────────────────────────
var _dev_drag_active: bool    = false
var _dev_drag_offset: Vector2 = Vector2.ZERO

# ── Dev panel state ──────────────────────────────────────────────────────────
var _tab_bar:     Control    = null   # button strip shown only in tab mode
var _dev_panel:   Control    = null   # the floating dev tools window
var _dev_sections: Dictionary = {}    # section_id → content VBoxContainer

# ── Weather section state ─────────────────────────────────────────────────────
var _sky_manager:    Node  = null   # resolved lazily via scene tree
var _weather_readout: Label = null  # live telemetry label updated in _process

# ── Tunable constants ────────────────────────────────────────────────────────

const _SETTINGS = [
	{"group": "Movement"},
	{"prop": "SPEED",            "label": "Speed",          "min": 1.0,    "max": 20.0,  "step": 0.5},
	{"prop": "JUMP_VELOCITY",    "label": "Jump Height",    "min": 1.0,    "max": 20.0,  "step": 0.5},
	{"prop": "MOUSE_SENSITIVITY","label": "Sensitivity",    "min": 0.0005, "max": 0.01,  "step": 0.0005},
	{"prop": "GRAVITY_SCALE",    "label": "Gravity",        "min": 0.5,    "max": 5.0,   "step": 0.1},
	{"prop": "SLIDE_FRICTION",   "label": "Slide Friction", "min": 0.0,    "max": 20.0,  "step": 0.5},
]

const _SPAWNABLE = [
	{"label": "Stick",    "scene": "res://Objects/stick.tscn"},
	{"label": "Mushroom", "scene": "res://Objects/mushroom.tscn"},
]

const _HOLD_SWAY_PARAMS = [
	{"key": "sway_mouse_scale",  "label": "Mouse Scale",    "min": 0.0,   "max": 0.05,  "step": 0.001},
	{"key": "sway_damping",      "label": "Sway Damping",   "min": 0.0,   "max": 2.0,   "step": 0.05},
	{"key": "sway_spring_k",     "label": "Sway Spring",    "min": 0.0,   "max": 30.0,  "step": 0.5},
	{"key": "sway_max_speed",    "label": "Max Speed",      "min": 0.0,   "max": 20.0,  "step": 0.5},
	{"key": "sway_sensitivity",  "label": "Sensitivity",    "min": 1.0,   "max": 100.0, "step": 1.0},
	{"key": "roll_damping",      "label": "Roll Damping",   "min": 0.0,   "max": 0.5,   "step": 0.005},
	{"key": "max_roll_speed",    "label": "Max Roll Speed", "min": 0.0,   "max": 30.0,  "step": 0.5},
]
const _HOLD_PUNCH_PARAMS = [
	{"key": "punch_pull",        "label": "Lunge Pull",     "min": 0.0,   "max": 20.0,  "step": 0.5},
	{"key": "punch_accel",       "label": "Punch Accel",    "min": 0.0,   "max": 500.0, "step": 5.0},
	{"key": "punch_peak_hold",   "label": "Peak Hold (s)",  "min": 0.0,   "max": 1.0,   "step": 0.01},
	{"key": "punch_settle_spd",  "label": "Settle Speed",   "min": 0.0,   "max": 5.0,   "step": 0.1},
	{"key": "punch_pushback",    "label": "Pushback",       "min": 0.0,   "max": 60.0,  "step": 1.0},
]

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready():
	var transparent = StyleBoxFlat.new()
	transparent.bg_color = Color.TRANSPARENT
	$PauseOverlay.add_theme_stylebox_override("panel", transparent)
	$PauseOverlay/CenterContainer/VBoxContainer/ResumeButton.pressed.connect(_toggle_pause)
	$PauseOverlay/CenterContainer/VBoxContainer/QuitButton.pressed.connect(_quit_to_menu)
	_add_role_label()

func _add_role_label():
	var label = Label.new()
	if not multiplayer.has_multiplayer_peer():
		label.text = "SOLO"
	elif multiplayer.is_server():
		label.text = "HOST"
	else:
		label.text = "CLIENT"
	label.anchor_left   = 1.0
	label.anchor_right  = 1.0
	label.anchor_top    = 0.0
	label.anchor_bottom = 0.0
	label.offset_left   = -110
	label.offset_right  = -10
	label.offset_top    = 10
	label.offset_bottom = 40
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)

# Called by world.gd after local player is ready.
func set_local_player(player: Node):
	_local_player = player
	_build_tab_bar()
	_build_dev_panel()

# ── Tab mode ─────────────────────────────────────────────────────────────────

## Called by player.gd whenever tab mode is toggled.
func set_tab_mode(active: bool) -> void:
	if _tab_bar:
		_tab_bar.visible = active
	if not active:
		cancel_pending_spawn()
		end_despawn_mode()

func _build_tab_bar() -> void:
	if _tab_bar:
		return
	# Vertical strip of tab-mode buttons, top-right corner, below the role label.
	var bar = VBoxContainer.new()
	bar.visible       = false
	bar.anchor_left   = 1.0
	bar.anchor_right  = 1.0
	bar.anchor_top    = 0.0
	bar.anchor_bottom = 0.0
	bar.offset_left   = -90.0
	bar.offset_right  = -10.0
	bar.offset_top    = 50.0
	bar.offset_bottom = 300.0

	var dev_btn = Button.new()
	dev_btn.text = "Dev"
	dev_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dev_btn.pressed.connect(_toggle_dev_panel)
	bar.add_child(dev_btn)

	add_child(bar)
	_tab_bar = bar

# ── Dev panel ────────────────────────────────────────────────────────────────

func _toggle_dev_panel() -> void:
	if _dev_panel:
		_dev_panel.visible = not _dev_panel.visible

## Called by the header's gui_input; starts a drag from the mouse-down position.
func _on_dev_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _dev_panel:
			_dev_drag_active = true
			_dev_drag_offset = _dev_panel.global_position - event.global_position
			get_viewport().set_input_as_handled()
		else:
			_dev_drag_active = false

## Global input handler: moves the panel while dragging, releases on mouse-up.
## Using _input (not _unhandled_input) so release is caught even outside the header.
func _input(event: InputEvent) -> void:
	if not _dev_drag_active or _dev_panel == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_dev_drag_active = false
	elif event is InputEventMouseMotion:
		var new_pos := event.global_position + _dev_drag_offset
		var vs      := get_viewport().get_visible_rect().size
		# Keep at least 80 px on-screen horizontally and the title bar always visible.
		new_pos.x = clampf(new_pos.x, -(_dev_panel.size.x - 80.0), vs.x - 80.0)
		new_pos.y = clampf(new_pos.y, 0.0, vs.y - 30.0)
		_dev_panel.global_position = new_pos
		get_viewport().set_input_as_handled()

func _build_dev_panel() -> void:
	if _dev_panel:
		return

	var panel = PanelContainer.new()
	panel.visible             = false
	panel.anchor_left         = 0.0
	panel.anchor_right        = 0.0
	panel.anchor_top          = 0.0
	panel.anchor_bottom       = 0.0
	panel.custom_minimum_size = Vector2(580, 520)

	var outer = VBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	panel.add_child(outer)

	# ── Header row ───────────────────────────────────────────────────────────
	var header = HBoxContainer.new()
	outer.add_child(header)

	var title = Label.new()
	title.text = "DEV TOOLS"
	title.add_theme_font_size_override("font_size", 15)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close_btn = Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.pressed.connect(func(): panel.visible = false)
	header.add_child(close_btn)

	# Drag: clicking and dragging the header moves the panel.
	# Buttons in the header still consume their own events and are unaffected.
	header.mouse_filter               = Control.MOUSE_FILTER_STOP
	header.mouse_default_cursor_shape = Control.CURSOR_DRAG
	header.gui_input.connect(_on_dev_header_input)

	outer.add_child(HSeparator.new())

	# ── Body: left sidebar + right content ────────────────────────────────────
	var body = HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(body)

	var sidebar = VBoxContainer.new()
	sidebar.custom_minimum_size = Vector2(100, 0)
	sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(sidebar)

	body.add_child(VSeparator.new())

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)

	var stack = VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(stack)

	# ── Register sections ─────────────────────────────────────────────────────
	# Add new sections here as the dev toolset grows.
	_dev_sections = {}
	_add_dev_section(sidebar, stack, "player",   "Player",   _build_player_section)
	_add_dev_section(sidebar, stack, "world",    "World",    _build_world_section)
	_add_dev_section(sidebar, stack, "settings", "Settings", _build_settings_section)
	_add_dev_section(sidebar, stack, "hold",     "Hold",     _build_hold_section)
	_add_dev_section(sidebar, stack, "spawn",    "Spawn",    _build_spawn_section)

	# Despawn is a direct action button, not a section.
	var despawn_sidebar_btn := Button.new()
	despawn_sidebar_btn.text = "Despawn"
	despawn_sidebar_btn.alignment             = HORIZONTAL_ALIGNMENT_LEFT
	despawn_sidebar_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	despawn_sidebar_btn.pressed.connect(func() -> void:
		start_despawn_mode())
	sidebar.add_child(despawn_sidebar_btn)

	_add_dev_section(sidebar, stack, "weather",  "Weather",  _build_weather_section)

	_activate_dev_section("player")

	add_child(panel)
	# Centre on first build; position is absolute and persists across show/hide.
	var vs := get_viewport().get_visible_rect().size
	panel.position = Vector2(
		maxf((vs.x - 580.0) * 0.5, 10.0),
		maxf((vs.y - 520.0) * 0.5, 50.0)).floor()
	_dev_panel = panel

## Registers a named section: adds a sidebar button and builds its content.
## `builder` receives the section's VBoxContainer and populates it.
func _add_dev_section(sidebar: VBoxContainer, stack: VBoxContainer,
		id: String, label: String, builder: Callable) -> void:
	var section = VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.visible = false
	stack.add_child(section)
	builder.call(section)
	_dev_sections[id] = section

	var btn = Button.new()
	btn.text = label
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(_activate_dev_section.bind(id))
	sidebar.add_child(btn)

func _activate_dev_section(id: String) -> void:
	for key in _dev_sections:
		_dev_sections[key].visible = (key == id)

# ── Spawn section ────────────────────────────────────────────────────────────

func _build_spawn_section(vbox: VBoxContainer) -> void:
	for entry in _SPAWNABLE:
		var btn = Button.new()
		btn.text = entry["label"]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_spawn_btn_pressed.bind(entry["scene"], entry["label"]))
		vbox.add_child(btn)

func _on_spawn_btn_pressed(scene_path: String, display_name: String) -> void:
	_pending_spawn = scene_path
	_show_spawn_hint(display_name)

func _show_spawn_hint(display_name: String) -> void:
	if _spawn_label == null:
		_spawn_label = Label.new()
		_spawn_label.anchor_left   = 0.5
		_spawn_label.anchor_right  = 0.5
		_spawn_label.anchor_top    = 0.0
		_spawn_label.anchor_bottom = 0.0
		_spawn_label.offset_left   = -300.0
		_spawn_label.offset_right  =  300.0
		_spawn_label.offset_top    = 10.0
		_spawn_label.offset_bottom = 34.0
		_spawn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_spawn_label.mouse_filter  = Control.MOUSE_FILTER_IGNORE
		add_child(_spawn_label)
	_spawn_label.text    = "Spawning: %s  ·  Click surface to place  ·  Right-click to cancel" % display_name
	_spawn_label.visible = true

func cancel_pending_spawn() -> void:
	_pending_spawn = ""
	if _spawn_label:
		_spawn_label.visible = false

# ── Despawn mode ─────────────────────────────────────────────────────────────

func start_despawn_mode() -> void:
	_despawn_mode = true
	if _despawn_label == null:
		_despawn_label = Label.new()
		_despawn_label.anchor_left   = 0.5
		_despawn_label.anchor_right  = 0.5
		_despawn_label.anchor_top    = 0.0
		_despawn_label.anchor_bottom = 0.0
		_despawn_label.offset_left   = -300.0
		_despawn_label.offset_right  =  300.0
		_despawn_label.offset_top    = 10.0
		_despawn_label.offset_bottom = 34.0
		_despawn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_despawn_label.mouse_filter  = Control.MOUSE_FILTER_IGNORE
		_despawn_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3))
		add_child(_despawn_label)
	_despawn_label.text    = "DESPAWN MODE  ·  Click object or NPC  ·  Esc to cancel"
	_despawn_label.visible = true

func end_despawn_mode() -> void:
	_despawn_mode = false
	if _despawn_label:
		_despawn_label.visible = false

func is_despawn_mode() -> bool:
	return _despawn_mode

# ── Player dev section ───────────────────────────────────────────────────────

func _build_player_section(vbox: VBoxContainer) -> void:
	# Noclip toggle
	var noclip_btn = CheckButton.new()
	noclip_btn.text = "Noclip  (WASD + Jump/Slide)"
	noclip_btn.toggled.connect(func(on: bool) -> void:
		if _local_player:
			_local_player.dev_set_noclip(on))
	vbox.add_child(noclip_btn)

	vbox.add_child(HSeparator.new())

	# Teleport to origin
	var tp_btn = Button.new()
	tp_btn.text = "Teleport to Origin"
	tp_btn.pressed.connect(func() -> void:
		if _local_player:
			_local_player.dev_teleport_to_origin())
	vbox.add_child(tp_btn)

# ── World dev section ─────────────────────────────────────────────────────────

func _build_world_section(vbox: VBoxContainer) -> void:
	# Freeze all physics objects
	var freeze_btn = CheckButton.new()
	freeze_btn.text = "Freeze All Objects"
	freeze_btn.toggled.connect(func(on: bool) -> void:
		for node in get_tree().get_nodes_in_group("world_objects"):
			if node is RigidBody3D:
				node.freeze = on)
	vbox.add_child(freeze_btn)

	# NPC AI toggle
	var npc_btn = CheckButton.new()
	npc_btn.text = "Freeze NPC AI"
	npc_btn.toggled.connect(func(on: bool) -> void:
		for node in get_tree().get_nodes_in_group("npcs"):
			node.set_physics_process(not on))
	vbox.add_child(npc_btn)

	vbox.add_child(HSeparator.new())

	# Nav mesh debug draw
	var nav_btn = CheckButton.new()
	nav_btn.text = "Nav Mesh Debug"
	nav_btn.toggled.connect(func(on: bool) -> void:
		NavigationServer3D.set_debug_enabled(on))
	vbox.add_child(nav_btn)

	# FPS overlay
	var fps_btn = CheckButton.new()
	fps_btn.text = "FPS Overlay"
	fps_btn.toggled.connect(func(on: bool) -> void:
		if _fps_label == null:
			_fps_label = Label.new()
			_fps_label.add_theme_font_size_override("font_size", 12)
			_fps_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
			_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_fps_label.anchor_left   = 0.0
			_fps_label.anchor_right  = 0.0
			_fps_label.anchor_top    = 0.0
			_fps_label.anchor_bottom = 0.0
			_fps_label.offset_left   = 10.0
			_fps_label.offset_top    = 10.0
			_fps_label.offset_right  = 300.0
			_fps_label.offset_bottom = 30.0
			add_child(_fps_label)
		_fps_label.visible = on)
	vbox.add_child(fps_btn)

# ── Settings section ─────────────────────────────────────────────────────────

func _build_settings_section(vbox: VBoxContainer) -> void:
	for entry in _SETTINGS:
		if entry.has("group"):
			var group_lbl = Label.new()
			group_lbl.text = "— " + entry["group"] + " —"
			group_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			vbox.add_child(group_lbl)
			continue

		var row = HBoxContainer.new()
		vbox.add_child(row)

		var name_lbl = Label.new()
		name_lbl.text = entry["label"]
		name_lbl.custom_minimum_size    = Vector2(130, 0)
		name_lbl.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
		row.add_child(name_lbl)

		var slider = HSlider.new()
		slider.min_value          = entry["min"]
		slider.max_value          = entry["max"]
		slider.step               = entry["step"]
		slider.value              = _local_player.get(entry["prop"])
		slider.custom_minimum_size = Vector2(150, 0)
		row.add_child(slider)

		var val_lbl = Label.new()
		val_lbl.text                   = str(slider.value)
		val_lbl.custom_minimum_size    = Vector2(60, 0)
		val_lbl.horizontal_alignment   = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(val_lbl)

		slider.value_changed.connect(_on_setting_changed.bind(entry["prop"], val_lbl))

func _on_setting_changed(value: float, prop: String, val_lbl: Label) -> void:
	_local_player.set(prop, value)
	val_lbl.text = str(value)

# ── Hold physics section ─────────────────────────────────────────────────────

func _build_hold_section(vbox: VBoxContainer) -> void:
	var weight_names := ["Light", "Medium", "Heavy"]

	# Tab switcher (Light / Medium / Heavy) — ButtonGroup keeps one active.
	var tab_row = HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 2)
	vbox.add_child(tab_row)

	# Build panes before buttons so closures can reference them.
	var panes: Array = []
	for _i in range(3):
		var pane = VBoxContainer.new()
		pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pane.visible               = false
		vbox.add_child(pane)
		panes.append(pane)
	panes[0].visible = true

	var tab_group = ButtonGroup.new()
	for i in range(3):
		var btn = Button.new()
		btn.text              = weight_names[i]
		btn.toggle_mode       = true
		btn.button_group      = tab_group
		btn.button_pressed    = (i == 0)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_activate_hold_tab.bind(panes, i))
		tab_row.add_child(btn)

	# Per-weight pane — Sway group then Punch / Lunge group.
	for i in range(3):
		var pane: VBoxContainer = panes[i]
		var ctrl_refs: Array    = []

		_add_hold_group_label(pane, "Sway")
		for p in _HOLD_SWAY_PARAMS:
			ctrl_refs.append(_add_hold_row(pane, i, p))

		_add_hold_group_label(pane, "Punch  ·  Lunge")
		for p in _HOLD_PUNCH_PARAMS:
			ctrl_refs.append(_add_hold_row(pane, i, p))

		pane.add_child(HSeparator.new())

		var reset_btn = Button.new()
		reset_btn.text = "↺  Reset %s to Defaults" % weight_names[i]
		reset_btn.add_theme_color_override("font_color", Color(0.9, 0.5, 0.3))
		reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pane.add_child(reset_btn)
		reset_btn.pressed.connect(_on_hold_reset.bind(i, ctrl_refs))

func _activate_hold_tab(panes: Array, active: int) -> void:
	for j in range(panes.size()):
		panes[j].visible = (j == active)

func _add_hold_group_label(parent: VBoxContainer, text: String) -> void:
	parent.add_child(HSeparator.new())
	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.55, 0.75, 0.55))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(lbl)

## Builds one parameter row: Label + HSlider (sweep) + SpinBox (precise entry).
## Slider and SpinBox are bidirectionally synced; both save on change.
func _add_hold_row(parent: VBoxContainer, weight_idx: int, param: Dictionary) -> Dictionary:
	var key:     String = param["key"]
	var current: float  = Holdable._WEIGHT_PHYSICS[weight_idx].get(key, 0.0)

	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)

	var lbl = Label.new()
	lbl.text                = param["label"]
	lbl.custom_minimum_size = Vector2(105, 0)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)

	var slider = HSlider.new()
	slider.min_value             = param["min"]
	slider.max_value             = param["max"]
	slider.step                  = param["step"]
	slider.value                 = current
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size   = Vector2(110, 0)
	row.add_child(slider)

	var spin = SpinBox.new()
	spin.min_value           = param["min"]
	spin.max_value           = param["max"]
	spin.step                = param["step"]
	spin.value               = current
	spin.allow_greater       = true
	spin.custom_minimum_size = Vector2(80, 0)
	row.add_child(spin)

	# Slider → SpinBox + save
	slider.value_changed.connect(func(v: float) -> void:
		spin.set_block_signals(true)
		spin.value = v
		spin.set_block_signals(false)
		Holdable.save_weight_physics(weight_idx, key, v))

	# SpinBox → Slider + save (slider's own signal is blocked to avoid double-save)
	spin.value_changed.connect(func(v: float) -> void:
		slider.set_block_signals(true)
		slider.value = v
		slider.set_block_signals(false)
		Holdable.save_weight_physics(weight_idx, key, v))

	return {"slider": slider, "spin": spin, "key": key}

func _on_hold_reset(weight_idx: int, ctrl_refs: Array) -> void:
	var restored: Dictionary = Holdable.reset_weight_physics(weight_idx)
	for ref in ctrl_refs:
		var v: float = restored.get(ref["key"], 0.0)
		ref["slider"].set_block_signals(true)
		ref["slider"].value = v
		ref["slider"].set_block_signals(false)
		ref["spin"].set_block_signals(true)
		ref["spin"].value = v
		ref["spin"].set_block_signals(false)

# ── Input handling ───────────────────────────────────────────────────────────

func _unhandled_input(event):
	if event.is_action_pressed("ui_cancel"):
		if _tune_popup != null:
			hide_tune_popup()
			return
		if _info_popup != null:
			hide_info_popup()
			return
		# Cancel active spawn or despawn mode before reaching the dev panel / pause toggle.
		if not _pending_spawn.is_empty():
			cancel_pending_spawn()
			return
		if _despawn_mode:
			end_despawn_mode()
			return
		# Close the dev panel before reaching the pause toggle.
		if _dev_panel != null and _dev_panel.visible:
			_dev_panel.visible = false
			return
		_toggle_pause()

func _toggle_pause():
	var showing = not pause_overlay.visible
	pause_overlay.visible = showing
	if showing:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif not (_local_player and _local_player.get("_tab_mode")):
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _quit_to_menu():
	multiplayer.multiplayer_peer = null
	get_tree().change_scene_to_file("res://menu.tscn")

func _notification(what):
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

# ── Log ──────────────────────────────────────────────────────────────────────

func add_log(msg: String):
	log_label.append_text(msg + "\n")

# ── Hover label ──────────────────────────────────────────────────────────────

func show_hover_label(screen_pos: Vector2, text: String):
	hover_label.text     = "[" + text + "]"
	hover_label.position = screen_pos + Vector2(14, -24)
	hover_label.visible  = true

func hide_hover_label():
	hover_label.visible = false

# ── Action menu ──────────────────────────────────────────────────────────────

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
	action_menu.visible  = true

func hide_action_menu():
	action_menu.visible = false
	_action_target = null

func is_action_menu_visible() -> bool:
	return action_menu.visible

func _on_action_pressed(action: String):
	var target = _action_target
	hide_action_menu()
	action_chosen.emit(action, target)

# ── Info popup ───────────────────────────────────────────────────────────────

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

	# Header: name (left) + weight tag (right)
	var header = HBoxContainer.new()
	vbox.add_child(header)

	var name_lbl = Label.new()
	name_lbl.text = interactable.display_name
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 18)
	header.add_child(name_lbl)

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
		weight_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		weight_lbl.size_flags_horizontal = Control.SIZE_SHRINK_END
		weight_lbl.add_theme_font_size_override("font_size", 11)
		weight_lbl.add_theme_color_override("font_color", Color(0.60, 0.60, 0.60))
		weight_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header.add_child(weight_lbl)

	vbox.add_child(HSeparator.new())

	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var desc = RichTextLabel.new()
	desc.bbcode_enabled = true
	desc.fit_content    = true
	desc.scroll_active  = false
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.mouse_filter   = Control.MOUSE_FILTER_IGNORE
	desc.text = "[color=#888888][i]No description available.[/i][/color]" \
		if interactable.description.is_empty() else interactable.description
	scroll.add_child(desc)

	vbox.add_child(HSeparator.new())

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
		if child is Holdable:       holdable = child
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

	var header = HBoxContainer.new()
	vbox.add_child(header)

	var name_lbl = Label.new()
	name_lbl.text = interactable.display_name if interactable else target.name
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 18)
	header.add_child(name_lbl)

	var tag_lbl = Label.new()
	tag_lbl.text = "tune"
	tag_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	tag_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	tag_lbl.size_flags_horizontal = Control.SIZE_SHRINK_END
	tag_lbl.add_theme_font_size_override("font_size", 11)
	tag_lbl.add_theme_color_override("font_color", Color(0.60, 0.60, 0.60))
	tag_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(tag_lbl)

	vbox.add_child(HSeparator.new())

	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
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

# ── Per-frame update (weather readout) ───────────────────────────────────────

func _process(_delta: float) -> void:
	if _fps_label and _fps_label.visible:
		_fps_label.text = "FPS: %d  |  Physics: %.2f ms" % [
			Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		]
	if _weather_readout == null or not _weather_readout.is_visible_in_tree():
		return
	var sm := _get_sky_manager()
	if sm == null:
		_weather_readout.text = "SkyManager not found in scene"
		return
	var horizon_str: String = "above horizon" if sm.is_above_horizon else "BELOW horizon"
	_weather_readout.text = (
		"Az: %.1f°   El: %+.2f°   Int: %.2f\n[%s]"
		% [sm.star_azimuth_deg, sm.star_elevation_deg, sm.light_intensity, horizon_str]
	)

# ── Weather section ───────────────────────────────────────────────────────────

func _get_sky_manager() -> Node:
	if _sky_manager == null or not is_instance_valid(_sky_manager):
		# Use group membership — avoids any hardcoded scene-root name assumption.
		_sky_manager = get_tree().get_first_node_in_group("sky_manager")
	return _sky_manager

func _build_weather_section(vbox: VBoxContainer) -> void:
	# ── Live telemetry ────────────────────────────────────────────────────────
	var readout = Label.new()
	readout.text = "Az: —   El: —   Int: —"
	readout.add_theme_font_size_override("font_size", 11)
	readout.add_theme_color_override("font_color", Color(0.65, 0.85, 0.65))
	readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(readout)
	_weather_readout = readout

	vbox.add_child(HSeparator.new())

	# ── Pause / resume cycle ──────────────────────────────────────────────────
	var pause_btn = CheckButton.new()
	pause_btn.text = "Pause Cycle"
	pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pause_btn.toggled.connect(func(on: bool) -> void:
		var sm := _get_sky_manager()
		if sm:
			sm.dev_set_paused(on))
	vbox.add_child(pause_btn)

	# ── Time scale ────────────────────────────────────────────────────────────
	_add_weather_slider(vbox, "Speed ×", 0.1, 100.0, 0.1, 1.0,
		func(v: float) -> void:
			var sm := _get_sky_manager()
			if sm:
				sm.dev_set_speed(v),
		"%.1f×")

	vbox.add_child(HSeparator.new())

	# ── Rotation position ─────────────────────────────────────────────────────
	# Range matches ROTATION_PERIOD default (180 s).  Drag to scrub star azimuth.
	_add_weather_slider(vbox, "Rotation (s)", 0.0, 180.0, 0.5, 0.0,
		func(v: float) -> void:
			var sm := _get_sky_manager()
			if sm:
				sm.dev_set_rotation_time(v))

	# ── Orbital position ──────────────────────────────────────────────────────
	# Range matches ORBITAL_PERIOD default (5400 s).
	_add_weather_slider(vbox, "Orbit (s)", 0.0, 5400.0, 10.0, 0.0,
		func(v: float) -> void:
			var sm := _get_sky_manager()
			if sm:
				sm.dev_set_orbital_time(v),
		"%.0f")

	vbox.add_child(HSeparator.new())

	# ── Elevation override ────────────────────────────────────────────────────
	# Toggle enables the override; slider sets the value (-10°…+10°).
	var elev_row = HBoxContainer.new()
	vbox.add_child(elev_row)

	var override_btn = CheckButton.new()
	override_btn.text = "Override Elevation"
	override_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	elev_row.add_child(override_btn)

	var elev_val_lbl = Label.new()
	elev_val_lbl.text = " 0.0°"
	elev_val_lbl.custom_minimum_size = Vector2(48, 0)
	elev_val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	elev_row.add_child(elev_val_lbl)

	var elev_slider = HSlider.new()
	elev_slider.min_value  = -10.0
	elev_slider.max_value  =  10.0
	elev_slider.step       =   0.1
	elev_slider.value      =   0.0
	elev_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(elev_slider)

	elev_slider.value_changed.connect(func(v: float) -> void:
		elev_val_lbl.text = "%+.1f°" % v
		if override_btn.button_pressed:
			var sm := _get_sky_manager()
			if sm:
				sm.dev_set_elevation_override(v))

	override_btn.toggled.connect(func(on: bool) -> void:
		var sm := _get_sky_manager()
		if not sm:
			return
		if on:
			sm.dev_set_elevation_override(elev_slider.value)
		else:
			sm.dev_clear_elevation_override())

## Adds a labelled HSlider row to `vbox` and calls `on_change` when dragged.
## `fmt` is an optional format string for the value label (default "%.2f").
func _add_weather_slider(vbox: VBoxContainer, label_text: String,
		min_v: float, max_v: float, step_v: float, default_v: float,
		on_change: Callable, fmt: String = "%.2f") -> void:
	var row = HBoxContainer.new()
	vbox.add_child(row)

	var lbl = Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size   = Vector2(110, 0)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var slider = HSlider.new()
	slider.min_value           = min_v
	slider.max_value           = max_v
	slider.step                = step_v
	slider.value               = default_v
	slider.custom_minimum_size = Vector2(130, 0)
	row.add_child(slider)

	var val_lbl = Label.new()
	val_lbl.text                 = fmt % default_v
	val_lbl.custom_minimum_size  = Vector2(55, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_lbl)

	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = fmt % v
		on_change.call(v))
