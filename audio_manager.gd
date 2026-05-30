extends Node

## Global audio manager — driven by TimeSystem's cycle.
##
## Register as Autoload named "AudioManager" in:
##   Project Settings → Globals → Autoload → audio_manager.gd → Name: AudioManager
##
## Two ambient layers crossfade on phase transitions:
##   _bus_blood_moon — played during Phase.BELOW (dark, quiet, eerie)
##   _bus_starlight  — played during Phase.ABOVE (warmer, alive)
##   Both fade toward silence during RISING / SETTING transitions.
##
## Interaction one-shots are triggered by player.gd via the public methods:
##   AudioManager.play_pickup()
##   AudioManager.play_drop()
##   AudioManager.play_throw()
##   AudioManager.play_punch_swing()
##   AudioManager.play_punch_impact()
##
## To add audio: drop AudioStream resources onto the exported slots below,
## or call AudioManager.set_stream_*(stream) at runtime.
## Until streams are assigned every method is a silent no-op.

# ── Ambient crossfade ─────────────────────────────────────────────────────────

## How quickly ambient layers fade in/out (linear volume per second, 0–1).
const FADE_SPEED: float = 0.4

## Target volumes for each phase (0–1 linear). RISING/SETTING fade both toward
## a quiet in-between — star is transitioning, neither mood is dominant.
const _VOL_BLOOD_MOON := { "blood": 1.0, "star": 0.0 }
const _VOL_STARLIGHT   := { "blood": 0.0, "star": 1.0 }
const _VOL_TRANSITION  := { "blood": 0.3, "star": 0.3 }
const _VOL_SILENT      := { "blood": 0.0, "star": 0.0 }

var _blood_player: AudioStreamPlayer = null
var _star_player:  AudioStreamPlayer = null

var _target_blood: float = 0.0
var _target_star:  float = 0.0

# ── Interaction one-shots ─────────────────────────────────────────────────────

var _pickup_player:       AudioStreamPlayer = null
var _drop_player:         AudioStreamPlayer = null
var _throw_player:        AudioStreamPlayer = null
var _punch_swing_player:  AudioStreamPlayer = null
var _punch_impact_player: AudioStreamPlayer = null

# ── Stream slots (assign via editor exports or set_stream_* methods) ──────────

## AudioStream for the blood-moon ambient loop.
@export var stream_blood_moon: AudioStream = null:
	set(v): stream_blood_moon = v; if _blood_player: _blood_player.stream = v; _refresh_playback(_blood_player)

## AudioStream for the starlight ambient loop.
@export var stream_starlight: AudioStream = null:
	set(v): stream_starlight = v; if _star_player: _star_player.stream = v; _refresh_playback(_star_player)

## AudioStream played when the player picks up an object.
@export var stream_pickup: AudioStream = null:
	set(v): stream_pickup = v; if _pickup_player: _pickup_player.stream = v

## AudioStream played when the player drops an object.
@export var stream_drop: AudioStream = null:
	set(v): stream_drop = v; if _drop_player: _drop_player.stream = v

## AudioStream played when the player throws an object.
@export var stream_throw: AudioStream = null:
	set(v): stream_throw = v; if _throw_player: _throw_player.stream = v

## AudioStream played at the start of a punch (swing / effort).
@export var stream_punch_swing: AudioStream = null:
	set(v): stream_punch_swing = v; if _punch_swing_player: _punch_swing_player.stream = v

## AudioStream played when a punch contacts a surface or object.
@export var stream_punch_impact: AudioStream = null:
	set(v): stream_punch_impact = v; if _punch_impact_player: _punch_impact_player.stream = v

# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	# ── Ambient players (looping, volume controlled each _process frame) ─────
	_blood_player = _make_player(stream_blood_moon, true,  -6.0)
	_star_player  = _make_player(stream_starlight,  true,  -6.0)

	# ── One-shot players ──────────────────────────────────────────────────────
	_pickup_player       = _make_player(stream_pickup,       false, 0.0)
	_drop_player         = _make_player(stream_drop,         false, 0.0)
	_throw_player        = _make_player(stream_throw,        false, 0.0)
	_punch_swing_player  = _make_player(stream_punch_swing,  false, 0.0)
	_punch_impact_player = _make_player(stream_punch_impact, false, 0.0)

	# ── Connect to TimeSystem ─────────────────────────────────────────────────
	if not TimeSystem.phase_changed.is_connected(_on_phase_changed):
		TimeSystem.phase_changed.connect(_on_phase_changed)

	# Seed targets from the current phase so we don't start at wrong volume.
	_apply_phase_targets(TimeSystem.phase)

func _process(delta: float) -> void:
	# Smoothly slew current volume toward target each frame.
	_slew(_blood_player, _target_blood, delta)
	_slew(_star_player,  _target_star,  delta)

# ── Phase reaction ────────────────────────────────────────────────────────────

func _on_phase_changed(new_phase: int, _old: int) -> void:
	_apply_phase_targets(new_phase)

func _apply_phase_targets(phase: int) -> void:
	var targets: Dictionary
	match phase:
		TimeSystem.Phase.BELOW:   targets = _VOL_BLOOD_MOON
		TimeSystem.Phase.ABOVE:   targets = _VOL_STARLIGHT
		TimeSystem.Phase.RISING:  targets = _VOL_TRANSITION
		TimeSystem.Phase.SETTING: targets = _VOL_TRANSITION
		_:                        targets = _VOL_SILENT
	_target_blood = targets["blood"]
	_target_star  = targets["star"]

# ── Public one-shot triggers ──────────────────────────────────────────────────

func play_pickup() -> void:
	_play_oneshot(_pickup_player)

func play_drop() -> void:
	_play_oneshot(_drop_player)

func play_throw() -> void:
	_play_oneshot(_throw_player)

func play_punch_swing() -> void:
	_play_oneshot(_punch_swing_player)

func play_punch_impact() -> void:
	_play_oneshot(_punch_impact_player)

# ── Stream assignment helpers (alternative to export setters) ─────────────────

func set_stream_blood_moon(s: AudioStream) -> void: stream_blood_moon = s
func set_stream_starlight(s: AudioStream)  -> void: stream_starlight  = s
func set_stream_pickup(s: AudioStream)     -> void: stream_pickup      = s
func set_stream_drop(s: AudioStream)       -> void: stream_drop        = s
func set_stream_throw(s: AudioStream)      -> void: stream_throw       = s
func set_stream_punch_swing(s: AudioStream)  -> void: stream_punch_swing  = s
func set_stream_punch_impact(s: AudioStream) -> void: stream_punch_impact = s

# ── Internals ─────────────────────────────────────────────────────────────────

func _make_player(stream: AudioStream, loop: bool, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream    = stream
	p.volume_db = volume_db
	p.bus       = "Master"
	add_child(p)
	if stream and loop:
		_refresh_playback(p)
	return p

func _refresh_playback(player: AudioStreamPlayer) -> void:
	if not player:
		return
	if player.stream:
		# Ensure looping streams restart when a new stream is assigned.
		if not player.playing:
			player.play()
	else:
		player.stop()

func _slew(player: AudioStreamPlayer, target_linear: float, delta: float) -> void:
	if not player:
		return
	var current_linear: float = db_to_linear(player.volume_db)
	var new_linear: float = move_toward(current_linear, target_linear, FADE_SPEED * delta)
	player.volume_db = linear_to_db(new_linear)
	# Start playing a looping ambient stream if volume rises above silence.
	if player.stream and not player.playing and new_linear > 0.001:
		player.play()
	# Stop it when fully faded out to avoid unnecessary audio processing.
	elif player.playing and new_linear <= 0.001 and target_linear <= 0.0:
		player.stop()

func _play_oneshot(player: AudioStreamPlayer) -> void:
	if player and player.stream:
		player.play()
