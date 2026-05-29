extends Node3D
## Visual replay viewer. Loads a recording produced by ReplayRecorder
## (version 2 — carries a 10Hz `snapshots` position stream), spawns a
## colored ghost capsule per peer, and plays the match back by lerping
## each ghost along its recorded path. No physics re-sim — we just move
## the ghosts to recorded positions, so playback is exact and cheap.
##
## Run standalone:
##   godot --path . client/scenes/replay_viewer.tscn -- --file <path.json>
## With no --file, loads the most recent replay in user://replays/.
##
## Controls:
##   Space      play / pause
##   ← / →      seek -2s / +2s
##   - / =      slow down / speed up (0.25x .. 4x)
##   R          restart from 0
##   mouse drag orbit camera   ·   wheel  zoom   ·   Esc  quit

const REPLAY_DIR := "user://replays/"
const GHOST_COLORS := [
	Color(0.4, 0.8, 1.0), Color(1.0, 0.5, 0.5), Color(0.6, 1.0, 0.5),
	Color(1.0, 0.85, 0.4), Color(0.85, 0.55, 1.0), Color(0.5, 0.95, 0.9),
	Color(1.0, 0.65, 0.85), Color(0.7, 0.7, 0.7),
]

var _snapshots: Array = []        # [{t, s:[[peer,x,y,z,ry],...]}, ...]
var _t0_ms: int = 0               # first snapshot timestamp
var _duration_s: float = 0.0
var _playhead_s: float = 0.0
var _speed: float = 1.0
var _playing: bool = true
var _ghosts: Dictionary = {}      # peer (int) → MeshInstance3D

# Camera orbit state.
var _cam_target: Vector3 = Vector3.ZERO
var _cam_yaw: float = 0.6
var _cam_pitch: float = 0.9
var _cam_dist: float = 30.0
var _dragging: bool = false

@onready var _camera: Camera3D = $Camera3D
@onready var _hud: Label = $HUD/Info


func _ready() -> void:
	var path: String = _resolve_replay_path()
	if path.is_empty():
		_hud.text = "没有找到录像文件 (user://replays/*.json)\nEsc 退出"
		return
	if not _load_replay(path):
		_hud.text = "录像加载失败: %s\nEsc 退出" % path
		return
	_spawn_ghosts()
	_frame_camera()


func _resolve_replay_path() -> String:
	# --file arg wins; else newest *.json in REPLAY_DIR.
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--file" and i + 1 < args.size():
			return args[i + 1]
	var dir := DirAccess.open(REPLAY_DIR)
	if dir == null:
		return ""
	var newest: String = ""
	var newest_mtime: int = -1
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		if dir.current_is_dir() or not fname.ends_with(".json"):
			continue
		var full: String = REPLAY_DIR + fname
		var mt: int = FileAccess.get_modified_time(full)
		if mt > newest_mtime:
			newest_mtime = mt
			newest = full
	return newest


func _load_replay(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not parsed is Dictionary:
		return false
	var payload: Dictionary = parsed
	_snapshots = payload.get("snapshots", [])
	if _snapshots.is_empty():
		# v1 recording (input-only) — no position stream to render.
		_hud.text = "这是旧版录像(只有输入流,无位置)\n用命令行分析器看,或重新录一局\nEsc 退出"
		return false
	_t0_ms = int(_snapshots[0].get("t", 0))
	var last_ms: int = int(_snapshots[_snapshots.size() - 1].get("t", _t0_ms))
	_duration_s = maxf(0.1, float(last_ms - _t0_ms) / 1000.0)
	return true


func _spawn_ghosts() -> void:
	# Collect every peer that appears anywhere in the stream.
	var seen: Dictionary = {}
	for snap in _snapshots:
		for st in snap.get("s", []):
			seen[int(st[0])] = true
	var idx: int = 0
	for peer in seen.keys():
		var ghost := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.4
		capsule.height = 1.8
		ghost.mesh = capsule
		var mat := StandardMaterial3D.new()
		var col: Color = GHOST_COLORS[idx % GHOST_COLORS.size()]
		mat.albedo_color = col
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 0.4
		ghost.material_override = mat
		add_child(ghost)
		_ghosts[peer] = ghost
		idx += 1


func _process(delta: float) -> void:
	if _snapshots.is_empty():
		return
	if _playing:
		_playhead_s += delta * _speed
		if _playhead_s >= _duration_s:
			_playhead_s = _duration_s
			_playing = false   # pause at the end
	_apply_playhead()
	_update_camera()
	_update_hud()


# Find the two snapshots bracketing the playhead and lerp ghosts between them.
func _apply_playhead() -> void:
	var target_ms: int = _t0_ms + int(_playhead_s * 1000.0)
	# Linear scan is fine — ~8k snapshots max, and we keep a cursor hint.
	var lo: Dictionary = {}
	var hi: Dictionary = {}
	for i in range(_snapshots.size()):
		var t: int = int(_snapshots[i].get("t", 0))
		if t <= target_ms:
			lo = _snapshots[i]
		else:
			hi = _snapshots[i]
			break
	if lo.is_empty():
		lo = _snapshots[0]
	var frac: float = 0.0
	if not hi.is_empty():
		var lo_t: float = float(lo.get("t", 0))
		var hi_t: float = float(hi.get("t", 0))
		if hi_t > lo_t:
			frac = clampf((float(target_ms) - lo_t) / (hi_t - lo_t), 0.0, 1.0)
	# Build quick lookup of hi states by peer.
	var hi_states: Dictionary = {}
	for st in hi.get("s", []):
		hi_states[int(st[0])] = st
	var present: Dictionary = {}
	for st in lo.get("s", []):
		var peer: int = int(st[0])
		present[peer] = true
		var g: MeshInstance3D = _ghosts.get(peer)
		if g == null:
			continue
		var from := Vector3(st[1], st[2], st[3])
		var pos := from
		var yaw: float = float(st[4])
		if hi_states.has(peer):
			var h = hi_states[peer]
			pos = from.lerp(Vector3(h[1], h[2], h[3]), frac)
			yaw = lerp_angle(yaw, float(h[4]), frac)
		g.visible = true
		g.global_position = pos + Vector3(0, 0.9, 0)   # capsule origin at center
		g.rotation.y = yaw
	# Hide ghosts not present in this frame (dead / not yet spawned).
	for peer in _ghosts.keys():
		if not present.has(peer):
			_ghosts[peer].visible = false


func _frame_camera() -> void:
	# Center the orbit target on the centroid of all recorded positions, and
	# back off enough to see the whole play area.
	var sum := Vector3.ZERO
	var n: int = 0
	var max_r: float = 8.0
	for snap in _snapshots:
		for st in snap.get("s", []):
			sum += Vector3(st[1], st[2], st[3])
			n += 1
	if n > 0:
		_cam_target = sum / float(n)
	for snap in _snapshots:
		for st in snap.get("s", []):
			var d: float = Vector3(st[1], st[2], st[3]).distance_to(_cam_target)
			max_r = maxf(max_r, d)
	_cam_dist = clampf(max_r * 1.8, 12.0, 80.0)


func _update_camera() -> void:
	var dir := Vector3(
		cos(_cam_pitch) * sin(_cam_yaw),
		sin(_cam_pitch),
		cos(_cam_pitch) * cos(_cam_yaw)
	)
	_camera.global_position = _cam_target + dir * _cam_dist
	_camera.look_at(_cam_target, Vector3.UP)


func _update_hud() -> void:
	var state: String = "▶" if _playing else "⏸"
	_hud.text = "%s  %.1f / %.1f s   速度 %.2fx\n空格 播放/暂停 · ←→ 快退/快进 · -= 调速 · R 重来 · 拖动 转镜头 · Esc 退出" % [
		state, _playhead_s, _duration_s, _speed,
	]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_playing = not _playing
				if _playhead_s >= _duration_s:
					_playhead_s = 0.0   # replay from start if at end
			KEY_LEFT:
				_playhead_s = clampf(_playhead_s - 2.0, 0.0, _duration_s)
			KEY_RIGHT:
				_playhead_s = clampf(_playhead_s + 2.0, 0.0, _duration_s)
			KEY_MINUS:
				_speed = clampf(_speed * 0.5, 0.25, 4.0)
			KEY_EQUAL:
				_speed = clampf(_speed * 2.0, 0.25, 4.0)
			KEY_R:
				_playhead_s = 0.0
				_playing = true
			KEY_ESCAPE:
				get_tree().quit()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_dist = clampf(_cam_dist - 3.0, 6.0, 120.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_dist = clampf(_cam_dist + 3.0, 6.0, 120.0)
	elif event is InputEventMouseMotion and _dragging:
		_cam_yaw -= event.relative.x * 0.01
		_cam_pitch = clampf(_cam_pitch - event.relative.y * 0.01, 0.1, 1.4)
