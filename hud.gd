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

# ── Spawn mode ───────────────────────────────────────────────────────────────
var _pending_spawn: String = ""   # scene path queued for placement; "" = inactive
var _spawn_label:   Label  = null

# ── Despawn mode ─────────────────────────────────────────────────────────────
var _despawn_mode:  bool  = false
var _despawn_label: Label = null

# ── Tune mode ────────────────────────────────────────────────────────────────
var _tune_mode:  bool  = false
var _tune_label: Label = null

# ── FPS overlay ───────────────────────────────────────────────────────────────
var _fps_label: Label = null

# ── Dev drag state ───────────────────────────────────────────────────────────
var _dev_drag_active: bool    = false
var _dev_drag_offset: Vector2 = Vector2.ZERO
var _dev_drag_target: Control = null   # which panel is currently being dragged

# ── Dev sidebar + floating window state ──────────────────────────────────────
var _dev_sidebar:  Control    = null   # the persistent sidebar strip
var _dev_windows:  Dictionary = {}     # id → PanelContainer (section windows)
var _dev_win_open: Dictionary = {}     # id → bool (open state before Tab exit)

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
	{"label": "Stick",       "scene": "res://Objects/stick.tscn"},
	{"label": "Mushroom",    "scene": "res://Objects/mushroom.tscn"},
	{"label": "Incinerator", "scene": "res://Objects/incinerator.tscn"},
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
	{"key": "punch_cooldown",    "label": "M1 Cooldown (s)","min": 0.0,   "max": 2.0,   "step": 0.05},
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
	_build_dev_sidebar()

# ── Tab mode ─────────────────────────────────────────────────────────────────

## Called by player.gd whenever tab mode is toggled.
func set_tab_mode(active: bool) -> void:
	if _dev_sidebar:
		_dev_sidebar.visible = active
	if active:
		# Restore section windows that were open when Tab was last closed.
		for id in _dev_win_open:
			if _dev_windows.has(id):
				_dev_windows[id].visible = _dev_win_open[id]
	else:
		# Snapshot each window's open state then hide everything.
		for id in _dev_windows:
			_dev_win_open[id] = _dev_windows[id].visible
			_dev_windows[id].visible = false
		cancel_pending_spawn()
		end_despawn_mode()
		end_tune_mode()

# ── Dev sidebar ──────────────────────────────────────────────────────────────

## Shared header-drag handler — bind(win) to wire any panel's header.
## Buttons inside the header consume their own events; only blank header space drags.
func _on_win_header_input(event: InputEvent, win: Control) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dev_drag_active = true
			_dev_drag_target = win
			_dev_drag_offset = win.global_position - event.global_position
			win.move_to_front()
			get_viewport().set_input_as_handled()
		elif _dev_drag_target == win:
			_dev_drag_active = false
			_dev_drag_target = null

## Global handler — moves the dragged panel and releases on mouse-up anywhere.
func _input(event: InputEvent) -> void:
	if not _dev_drag_active or _dev_drag_target == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_dev_drag_active = false
		_dev_drag_target = null
	elif event is InputEventMouseMotion:
		var me:      InputEventMouseMotion = event as InputEventMouseMotion
		var new_pos: Vector2               = me.global_position + _dev_drag_offset
		var vs:      Vector2               = get_viewport().get_visible_rect().size
		new_pos.x = clampf(new_pos.x, -(_dev_drag_target.size.x - 80.0), vs.x - 80.0)
		new_pos.y = clampf(new_pos.y, 0.0, vs.y - 30.0)
		_dev_drag_target.global_position = new_pos
		get_viewport().set_input_as_handled()

## Builds the persistent narrow sidebar shown whenever Tab mode is active.
## Section buttons lazily create their own floating windows on first press.
func _build_dev_sidebar() -> void:
	if _dev_sidebar:
		return

	var panel = PanelContainer.new()
	panel.visible             = false
	panel.anchor_left         = 0.0
	panel.anchor_right        = 0.0
	panel.anchor_top          = 0.0
	panel.anchor_bottom       = 0.0
	panel.custom_minimum_size = Vector2(120, 0)

	var outer = VBoxContainer.new()
	outer.add_theme_constant_override("separation", 2)
	panel.add_child(outer)

	# Draggable header — no close button; sidebar persists for the whole Tab session.
	var header = HBoxContainer.new()
	header.mouse_filter               = Control.MOUSE_FILTER_STOP
	header.mouse_default_cursor_shape = Control.CURSOR_DRAG
	header.gui_input.connect(_on_win_header_input.bind(panel))
	outer.add_child(header)

	var title = Label.new()
	title.text = "DEV"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	outer.add_child(HSeparator.new())

	var buttons = VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 2)
	outer.add_child(buttons)

	_dev_windows  = {}
	_dev_win_open = {}
	_add_dev_section(buttons, "scores",   "Scores",   _build_scores_section)
	buttons.add_child(HSeparator.new())
	_add_dev_section(buttons, "player",   "Player",   _build_player_section)
	_add_dev_section(buttons, "world",    "World",    _build_world_section)
	_add_dev_section(buttons, "settings", "Settings", _build_settings_section)
	_add_dev_section(buttons, "hold",     "Hold",     _build_hold_section)
	_add_dev_section(buttons, "spawn",    "Spawn",    _build_spawn_section)

	# Tune: direct action, enters click-to-tune mode (no window on press).
	var tune_btn = Button.new()
	tune_btn.text      = "Tune"
	tune_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	tune_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tune_btn.pressed.connect(func() -> void: start_tune_mode())
	buttons.add_child(tune_btn)

	# Despawn: direct action, no window.
	var despawn_btn = Button.new()
	despawn_btn.text      = "Despawn"
	despawn_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	despawn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	despawn_btn.pressed.connect(func() -> void: start_despawn_mode())
	buttons.add_child(despawn_btn)

	_add_dev_section(buttons, "weather", "Weather", _build_weather_section)

	add_child(panel)
	# Top-right by default; position persists across Tab cycles.
	_disable_focus_recursive(panel)
	var vs: Vector2 = get_viewport().get_visible_rect().size
	panel.position  = Vector2(vs.x - 130.0, 50.0).floor()
	_dev_sidebar    = panel

## Builds a standalone floating window for one dev section.
## Added to the scene tree by _toggle_dev_window on first open.
func _create_dev_window(title_text: String, builder: Callable) -> PanelContainer:
	var win = PanelContainer.new()
	win.anchor_left         = 0.0
	win.anchor_right        = 0.0
	win.anchor_top          = 0.0
	win.anchor_bottom       = 0.0
	win.custom_minimum_size = Vector2(400, 0)

	var outer = VBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	win.add_child(outer)

	var header = HBoxContainer.new()
	header.mouse_filter               = Control.MOUSE_FILTER_STOP
	header.mouse_default_cursor_shape = Control.CURSOR_DRAG
	header.gui_input.connect(_on_win_header_input.bind(win))
	outer.add_child(header)

	var lbl = Label.new()
	lbl.text = title_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)

	var close_btn = Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.pressed.connect(func(): win.visible = false)
	header.add_child(close_btn)

	outer.add_child(HSeparator.new())

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size    = Vector2(0, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	var content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)

	builder.call(content)
	_disable_focus_recursive(win)
	return win

## Toggles a section window open/closed. Creates it lazily on first press.
func _toggle_dev_window(id: String, label: String, builder: Callable) -> void:
	if _dev_windows.has(id):
		var win: Control = _dev_windows[id]
		win.visible = not win.visible
		if win.visible:
			win.move_to_front()
		return
	# First open: build, register, position next to the sidebar.
	var win := _create_dev_window(label, builder)
	add_child(win)
	# Second sweep: catches runtime-created internals (e.g. SpinBox's LineEdit)
	# that only exist after _ready() fires when the node enters the scene tree.
	_disable_focus_recursive(win)
	var sx: float  = _dev_sidebar.global_position.x if _dev_sidebar else 100.0
	var sy: float  = _dev_sidebar.global_position.y if _dev_sidebar else 50.0
	var off: float = float(_dev_windows.size()) * 28.0
	win.position   = Vector2(maxf(sx - 410.0, 10.0), sy + off).floor()
	_dev_windows[id]  = win
	_dev_win_open[id] = true

## Recursively disables keyboard focus on every Control in a subtree,
## including the root node itself. Safe to call multiple times — call once
## before add_child (catches statically built controls) and once after
## (catches runtime-created internals like SpinBox's LineEdit).
func _disable_focus_recursive(node: Node) -> void:
	if node is Control:
		(node as Control).focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		_disable_focus_recursive(child)

## Adds a sidebar button that lazily creates and toggles its floating window.
func _add_dev_section(buttons: VBoxContainer, id: String, label: String, builder: Callable) -> void:
	var btn = Button.new()
	btn.text      = label
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(_toggle_dev_window.bind(id, label, builder))
	buttons.add_child(btn)

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
		if _info_popup != null:
			hide_info_popup()
			return
		# Cancel active modes before reaching the dev panel / pause toggle.
		if not _pending_spawn.is_empty():
			cancel_pending_spawn()
			return
		if _despawn_mode:
			end_despawn_mode()
			return
		if _tune_mode:
			end_tune_mode()
			return
		# Close open section windows before reaching the pause toggle.
		var any_closed := false
		for id in _dev_windows:
			if _dev_windows[id].visible:
				_dev_windows[id].visible = false
				any_closed = true
		if any_closed:
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

# ── Tune mode ────────────────────────────────────────────────────────────────

func start_tune_mode() -> void:
	_tune_mode = true
	if _tune_label == null:
		_tune_label = Label.new()
		_tune_label.anchor_left   = 0.5
		_tune_label.anchor_right  = 0.5
		_tune_label.anchor_top    = 0.0
		_tune_label.anchor_bottom = 0.0
		_tune_label.offset_left   = -300.0
		_tune_label.offset_right  =  300.0
		_tune_label.offset_top    = 10.0
		_tune_label.offset_bottom = 34.0
		_tune_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_tune_label.mouse_filter  = Control.MOUSE_FILTER_IGNORE
		_tune_label.add_theme_color_override("font_color", Color(0.4, 0.9, 1.0))
		add_child(_tune_label)
	_tune_label.text    = "TUNE MODE  ·  Click an object to open its tune panel  ·  Esc to exit"
	_tune_label.visible = true

func end_tune_mode() -> void:
	_tune_mode = false
	if _tune_label:
		_tune_label.visible = false

func is_tune_mode() -> bool:
	return _tune_mode

## Opens (or brings to front) a draggable tune window for the clicked object.
## Windows are keyed by scene file path so all instances of the same scene
## share one window. The window persists across Tab cycles like other dev windows.
func open_tune_for(target: Node) -> void:
	var holdable: Holdable = null
	for child in target.get_children():
		if child is Holdable:
			holdable = child
			break
	if not holdable:
		return

	# Stable key: scene path, or fall back to node name for unsaved objects.
	var scene_path: String = target.scene_file_path
	var win_id: String     = "tune:" + (scene_path if not scene_path.is_empty() else target.name)

	if _dev_windows.has(win_id):
		var existing: Control = _dev_windows[win_id]
		existing.visible = true
		existing.move_to_front()
		return

	var display_name: String = (
		scene_path.get_file().get_basename() if not scene_path.is_empty() else target.name
	)

	var win := _create_dev_window(
		"Tune · " + display_name,
		func(c: VBoxContainer) -> void: _build_tune_content(c, holdable)
	)
	add_child(win)
	_disable_focus_recursive(win)

	var vs:  Vector2 = get_viewport().get_visible_rect().size
	var off: float   = float(_dev_windows.size()) * 24.0
	win.position = Vector2(
		clampf(vs.x * 0.5 - 200.0 + off, 10.0, vs.x - 420.0),
		clampf(vs.y * 0.3  + off,         10.0, vs.y - 300.0)
	).floor()

	_dev_windows[win_id]  = win
	_dev_win_open[win_id] = true

## Builds the tune window content from the holdable's tune_schema().
## Supports entry types: "group", "dropdown", "number", "vector3".
func _build_tune_content(content: VBoxContainer, holdable: Holdable) -> void:
	for entry in holdable.tune_schema():
		match entry.get("type", ""):
			"group":
				content.add_child(HSeparator.new())
				var grp_lbl = Label.new()
				grp_lbl.text = entry.get("label", "")
				grp_lbl.add_theme_font_size_override("font_size", 11)
				grp_lbl.add_theme_color_override("font_color", Color(0.45, 0.85, 1.0))
				content.add_child(grp_lbl)
			"dropdown":
				var row = HBoxContainer.new()
				row.add_theme_constant_override("separation", 8)
				content.add_child(row)
				var lbl = Label.new()
				lbl.text = entry["label"]
				lbl.custom_minimum_size = Vector2(120, 0)
				lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				row.add_child(lbl)
				var opt = OptionButton.new()
				for option in entry["options"]:
					opt.add_item(option)
				opt.selected = int(holdable.get(entry["prop"]))
				opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(opt)
				var d_prop: String = entry["prop"]
				opt.item_selected.connect(func(idx: int) -> void:
					if is_instance_valid(holdable):
						holdable.save_tune_value(d_prop, idx)
				)
			"number":
				var row = HBoxContainer.new()
				row.add_theme_constant_override("separation", 8)
				content.add_child(row)
				var lbl = Label.new()
				lbl.text = entry["label"]
				lbl.custom_minimum_size = Vector2(120, 0)
				lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				row.add_child(lbl)
				var spin = SpinBox.new()
				spin.min_value    = entry["min"]
				spin.max_value    = entry["max"]
				spin.step         = entry["step"]
				spin.value        = holdable.get(entry["prop"])
				spin.allow_greater = true
				spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(spin)
				var n_prop: String = entry["prop"]
				spin.value_changed.connect(func(val: float) -> void:
					if is_instance_valid(holdable):
						holdable.save_tune_value(n_prop, val)
				)
			"vector3":
				# One sub-label above three axis spinboxes.
				var field_box = VBoxContainer.new()
				field_box.add_theme_constant_override("separation", 2)
				content.add_child(field_box)
				var field_lbl = Label.new()
				field_lbl.text = entry["label"]
				field_lbl.add_theme_font_size_override("font_size", 11)
				field_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
				field_box.add_child(field_lbl)
				var axes_row = HBoxContainer.new()
				axes_row.add_theme_constant_override("separation", 4)
				field_box.add_child(axes_row)
				var current_v3: Vector3 = holdable.get(entry["prop"])
				var initial: Array      = [current_v3.x, current_v3.y, current_v3.z]
				var axis_spins: Array   = []
				for axis_i in range(3):
					var ax_lbl = Label.new()
					ax_lbl.text = ["X", "Y", "Z"][axis_i]
					ax_lbl.custom_minimum_size = Vector2(14, 0)
					ax_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
					axes_row.add_child(ax_lbl)
					var ax_spin = SpinBox.new()
					ax_spin.min_value    = entry["min"]
					ax_spin.max_value    = entry["max"]
					ax_spin.step         = entry["step"]
					ax_spin.allow_greater = true
					ax_spin.allow_lesser  = true
					ax_spin.value        = initial[axis_i]
					ax_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					axes_row.add_child(ax_spin)
					axis_spins.append(ax_spin)
				var v3_prop: String = entry["prop"]
				for ax_spin in axis_spins:
					ax_spin.value_changed.connect(func(_v: float) -> void:
						if is_instance_valid(holdable):
							holdable.save_tune_value(v3_prop, Vector3(
								axis_spins[0].value,
								axis_spins[1].value,
								axis_spins[2].value
							))
					)

# ── Scores section ───────────────────────────────────────────────────────────

func _build_scores_section(vbox: VBoxContainer) -> void:
	var score_labels: Dictionary = {}   # peer_id → score Label

	var header_row := HBoxContainer.new()
	vbox.add_child(header_row)
	var name_hdr := Label.new()
	name_hdr.text = "Player"
	name_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_hdr.add_theme_color_override("font_color", Color(0.55, 0.75, 0.55))
	name_hdr.add_theme_font_size_override("font_size", 11)
	header_row.add_child(name_hdr)
	var score_hdr := Label.new()
	score_hdr.text = "Score"
	score_hdr.custom_minimum_size = Vector2(60, 0)
	score_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score_hdr.add_theme_color_override("font_color", Color(0.55, 0.75, 0.55))
	score_hdr.add_theme_font_size_override("font_size", 11)
	header_row.add_child(score_hdr)
	vbox.add_child(HSeparator.new())

	var add_row := func(pid: int, pts: int) -> void:
		if not is_instance_valid(vbox):
			return
		var row := HBoxContainer.new()
		row.name = "row_%d" % pid
		vbox.add_child(row)
		var name_lbl := Label.new()
		name_lbl.text = "P%d" % pid
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_lbl)
		var pts_lbl := Label.new()
		pts_lbl.text = str(pts)
		pts_lbl.custom_minimum_size = Vector2(60, 0)
		pts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(pts_lbl)
		score_labels[pid] = pts_lbl

	# Populate players who are already registered.
	for pid in ScoreManager.get_scores():
		add_row.call(pid, ScoreManager.get_score(pid))

	# Live updates.
	ScoreManager.player_registered.connect(func(pid: int) -> void:
		if not is_instance_valid(vbox) or score_labels.has(pid):
			return
		add_row.call(pid, 0)
	)
	ScoreManager.player_unregistered.connect(func(pid: int) -> void:
		if not score_labels.has(pid):
			return
		var lbl: Label = score_labels.get(pid)
		if is_instance_valid(lbl):
			lbl.get_parent().queue_free()
		score_labels.erase(pid)
	)
	ScoreManager.score_updated.connect(func(pid: int, new_score: int) -> void:
		if not score_labels.has(pid):
			return
		var lbl: Label = score_labels.get(pid)
		if is_instance_valid(lbl):
			lbl.text = str(new_score)
	)

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
