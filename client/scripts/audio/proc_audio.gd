extends Node
## Procedural sound effect autoload. Sounds are synthesised ONCE at startup
## into AudioStreamWAV resources (16-bit PCM, mono), then replayed on
## demand from a pool of AudioStreamPlayer nodes.
##
## Why not AudioStreamGenerator: the generator's playback is filled
## asynchronously, so the audio mixer thread polls for samples before
## push_frame() can supply them, producing "is trying to play a sample
## from a stream that cannot be sampled" warnings on every fire/kill.
## In a 5-kill match those warnings accumulate to 300+; each carries a
## long wasm stack trace; Chrome DevTools' log buffer balloons to GB
## of memory and the entire tab freezes (verified via Chrome's task
## manager: DevTools alone at 8.7GB / 170% CPU).
##
## AudioStreamWAV is "static sampleable" — the mixer reads from a fixed
## PCM buffer that already exists, so there's no race and no warning.
##
## Currently exposed:
##   play_fire()         — gun thump
##   play_hitmarker()    — short high beep, "you hit someone"
##   play_take_damage()  — low thud, "you got hit"
##   play_kill()         — rising arpeggio, "you killed them"

const SAMPLE_RATE := 22050
const MASTER_VOLUME_DB := -6.0
const POOL_SIZE := 8   # max concurrent SFX before oldest gets stolen

# NetProtocol reached via the preloaded script class, not the autoload global,
# so this file compiles in standalone `--script` loads (smoke test).
const NetProtocol = preload("res://shared/scripts/network/net_protocol.gd")

# C7: on the dedicated server every play_*() call is a no-op so headless
# boot doesn't spin up AudioStreamPlayer nodes with the dummy driver.
@onready var _muted: bool = NetProtocol.is_dedicated_server_boot()

# Pre-rendered PCM streams, one per sound kind.
var _streams: Dictionary = {}          # name (String) → AudioStreamWAV

# Reusable player pool — never freed, just retriggered.
var _pool: Array[AudioStreamPlayer] = []
var _pool_cursor: int = 0


func _ready() -> void:
	if _muted:
		return
	# Bake all four sounds once.
	_streams["fire"]   = _bake_arpeggio([140.0],                  0.07, "saw",  0.7)
	_streams["hit"]    = _bake_arpeggio([1200.0],                 0.08, "sine", 0.55)
	_streams["damage"] = _bake_arpeggio([190.0],                  0.13, "tri",  0.6)
	_streams["kill"]   = _bake_arpeggio([520.0, 780.0, 1100.0],   0.08, "sine", 0.6)
	# Spin up the player pool.
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = &"Master"
		p.volume_db = MASTER_VOLUME_DB
		add_child(p)
		_pool.append(p)


func play_fire() -> void:
	_play("fire")


func play_hitmarker() -> void:
	_play("hit")


func play_take_damage() -> void:
	_play("damage")


func play_kill() -> void:
	_play("kill")


# ── Internals ─────────────────────────────────────────────────────────────

func _play(name: String) -> void:
	if _muted:
		return
	var stream: AudioStreamWAV = _streams.get(name)
	if stream == null:
		return
	# Round-robin through the pool. If all 8 are still playing, the oldest
	# slot gets stolen — fine for SFX at this density.
	var p: AudioStreamPlayer = _pool[_pool_cursor]
	_pool_cursor = (_pool_cursor + 1) % POOL_SIZE
	p.stream = stream
	p.play()


## Renders `freqs` (one note per entry, sequential) into an AudioStreamWAV
## with `note_duration` each. Same envelope shape as the old realtime path.
func _bake_arpeggio(freqs: Array, note_duration: float, wave: String, volume: float) -> AudioStreamWAV:
	var samples_per_note: int = int(SAMPLE_RATE * note_duration)
	var total_samples: int = samples_per_note * freqs.size()
	var data := PackedByteArray()
	data.resize(total_samples * 2)   # 16-bit mono → 2 bytes per sample

	var byte_idx: int = 0
	for note_idx in range(freqs.size()):
		var freq: float = freqs[note_idx]
		for i in samples_per_note:
			var t_local: float = float(i) / SAMPLE_RATE
			var phase: float = t_local * freq * TAU
			var s: float = _wave_sample(phase, wave)
			# 3ms attack + linear decay to 0 over the note duration.
			var attack: float = clampf(t_local / 0.003, 0.0, 1.0)
			var decay: float = clampf(1.0 - t_local / note_duration, 0.0, 1.0)
			var env: float = attack * decay * volume
			var pcm: int = clamp(int(s * env * 32767.0), -32768, 32767)
			# Little-endian 16-bit.
			data[byte_idx] = pcm & 0xff
			data[byte_idx + 1] = (pcm >> 8) & 0xff
			byte_idx += 2

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = false
	wav.mix_rate = SAMPLE_RATE
	wav.data = data
	return wav


func _wave_sample(phase: float, wave: String) -> float:
	match wave:
		"saw":
			return fmod(phase / TAU, 1.0) * 2.0 - 1.0
		"tri":
			return abs(fmod(phase / TAU, 1.0) * 4.0 - 2.0) - 1.0
		_:
			return sin(phase)
