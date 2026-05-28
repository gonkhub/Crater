extends Control

const PORT = 7777
const CONNECT_TIMEOUT = 5.0

var _connecting := false

@onready var ip_input = $CenterContainer/VBoxContainer/IPInput
@onready var status_label = $CenterContainer/VBoxContainer/StatusLabel

func _ready():
	$CenterContainer/VBoxContainer/HostButton.pressed.connect(_on_host)
	$CenterContainer/VBoxContainer/JoinButton.pressed.connect(_on_join)
	$CenterContainer/VBoxContainer/QuitButton.pressed.connect(_on_quit)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)

func _on_host():
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(PORT)
	if err != OK:
		_set_status("Failed to start server (error %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	_set_status("Hosting on port %d..." % PORT)
	get_tree().change_scene_to_file("res://world.tscn")

func _on_join():
	var ip = ip_input.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(ip, PORT)
	if err != OK:
		_set_status("Failed to connect (error %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	_connecting = true
	_set_status("Connecting to %s:%d..." % [ip, PORT])
	get_tree().create_timer(CONNECT_TIMEOUT).timeout.connect(_on_connect_timeout)

func _on_connected():
	_connecting = false
	get_tree().change_scene_to_file("res://world.tscn")

func _on_connection_failed():
	_connecting = false
	multiplayer.multiplayer_peer = null
	_set_status("Connection failed.")

func _on_connect_timeout():
	if _connecting:
		_connecting = false
		multiplayer.multiplayer_peer = null
		_set_status("Timed out after %ds. Is the host running?" % CONNECT_TIMEOUT)

func _on_quit():
	get_tree().quit()

func _set_status(msg: String):
	status_label.text = msg
	status_label.visible = true
