extends Node
## Procedural sound effect autoload. Synthesises short tones on demand via
## AudioStreamGenerator — no .wav assets required, no licensing concerns.
##
## Currently exposed:
##   play_fire()         — gun thump
##   play_hitmarker()    — short high beep, "you hit someone"
##   play_take_damage()  — low thud, "you got hit"
##   play_kill()         — rising arpeggio, "you killed them"
##
## All calls are non-blocking; the generator runs on its own AudioStreamPlayer
## that auto-frees after the sound finishes.

const SAMPLE_RATE := 22050.0
const MASTER_VOLUME_DB := -6.0

# C7: on the dedicated server every play_*() call is a no-op so headless
# boot doesn't spin up AudioStreamGenerator nodes with the dummy driver
# (which emits warnings per call and leaks free-on-finish timers).
@onready var _muted: bool = NetProtocol.is_dedicated_server_boot()


func play_fire() -> void:
	if _muted: return
	# Saw with quick decay — punchy gun thump.
	_play_segment(140.0, 0.07, "saw", 0.7)


func play_hitmarker() -> void:
	if _muted: return
	# Bright high beep.
	_play_segment(1200.0, 0.08, "sine", 0.55)


func play_take_damage() -> void:
	if _muted: return
	# Low triangle — feels heavier than a sine.
	_play_segment(190.0, 0.13, "tri", 0.6)


func play_kill() -> void:
	if _muted: return
	# Quick three-note rising arpeggio.
	_play_arpeggio([520.0, 780.0, 1100.0], 0.08, 0.6)


# ── Internals ─────────────────────────────────────────────────────────────
func _play_segment(freq: float, duration: float, wave: String, volume: float) -> void:
	_play_arpeggio_wave([freq], duration, wave, volume)


func _play_arpeggio(freqs: Array, note_duration: float, volume: float) -> void:
	_play_arpeggio_wave(freqs, note_duration, "sine", volume)


func _play_arpeggio_wave(freqs: Array, note_duration: float, wave: String, volume: float) -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = note_duration * float(freqs.size()) + 0.05

	var player := AudioStreamPlayer.new()
	player.stream = gen
	player.bus = &"Master"
	player.volume_db = MASTER_VOLUME_DB + linear_to_db(volume)
	add_child(player)
	player.play()

	var pb: AudioStreamGeneratorPlayback = player.get_stream_playback()
	if pb == null:
		player.queue_free()
		return

	var samples_per_note: int = int(SAMPLE_RATE * note_duration)
	for note_idx in range(freqs.size()):
		var freq: float = freqs[note_idx]
		for i in samples_per_note:
			var t_local: float = float(i) / SAMPLE_RATE
			var phase: float = t_local * freq * TAU
			var s: float = _wave_sample(phase, wave)
			# 3ms attack + linear decay to 0 over the note duration.
			var attack: float = clampf(t_local / 0.003, 0.0, 1.0)
			var decay: float = clampf(1.0 - t_local / note_duration, 0.0, 1.0)
			var env: float = attack * decay
			pb.push_frame(Vector2(s * env, s * env))

	# Auto-cleanup after the sound has had time to play out.
	var total: float = note_duration * float(freqs.size()) + 0.1
	get_tree().create_timer(total).timeout.connect(
		func():
			if is_instance_valid(player):
				player.queue_free())


func _wave_sample(phase: float, wave: String) -> float:
	match wave:
		"saw":
			return fmod(phase / TAU, 1.0) * 2.0 - 1.0
		"tri":
			return abs(fmod(phase / TAU, 1.0) * 4.0 - 2.0) - 1.0
		_:
			return sin(phase)
