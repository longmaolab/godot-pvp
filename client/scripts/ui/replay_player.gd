extends SceneTree
## Replay playback — reads a `user://replays/<room>_<ts>.json` recording
## produced by ReplayRecorder on the DS, advances a fresh game scene tick
## by tick replaying the saved client_input stream. Intended as a tool
## for moderators / devs to review specific matches.
##
## Usage:
##   godot --headless --path . -s client/scripts/ui/replay_player.gd -- \
##         --file <path/to/recording.json>
##
## Outputs frame-by-frame: tick, peer_id, bits, yaw, pitch. Combine with
## --redirect-stdout > replay.log for human-readable analysis. This is
## CLI-only for MVP — a visual playback scene (free camera + UI) is a
## follow-up.

# This tool runs via `-s` (standalone SceneTree, no autoloads), so reach the
# input-bit constants through the preloaded script class, not the autoload
# global. Copying the bit values by hand is exactly how the fire bit drifted to
# the wrong value before.
const NetProtocol = preload("res://shared/scripts/network/net_protocol.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var file_path: String = ""
	for i in range(args.size()):
		if args[i] == "--file" and i + 1 < args.size():
			file_path = args[i + 1]
	if file_path.is_empty():
		printerr("usage: --file <path/to/recording.json>")
		quit(2)
		return
	if not FileAccess.file_exists(file_path):
		printerr("replay file not found: %s" % file_path)
		quit(2)
		return
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		printerr("could not open: %s" % file_path)
		quit(2)
		return
	var raw: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary:
		printerr("replay file is not a JSON object")
		quit(2)
		return
	var payload: Dictionary = parsed
	if not payload.has("frames"):
		printerr("replay missing 'frames' array")
		quit(2)
		return
	var frames: Array = payload["frames"]
	print("=== replay: %s ===" % file_path)
	print("room_id: %s" % String(payload.get("room_id", "?")))
	print("frame_count: %d (saved %d)" % [frames.size(), int(payload.get("frame_count", -1))])
	print("saved_at_ms: %d" % int(payload.get("saved_at_ms", 0)))
	# Per-peer summary: total frames, fire bit count, max yaw delta.
	var per_peer: Dictionary = {}
	var prev_aim: Dictionary = {}   # peer → {yaw, pitch}
	for fr in frames:
		var d: Dictionary = fr
		var peer: int = int(d.get("p", 0))
		var summary: Dictionary = per_peer.get(peer, {
			"frames": 0, "fires": 0, "max_yaw_jump": 0.0, "max_speed_proxy": 0.0,
		})
		summary["frames"] = int(summary["frames"]) + 1
		# Fire bit. The recorder stores raw input bitfields, so test the canonical
		# INPUT_FIRE (1 << 7). The old hardcoded `1 << 4` was INPUT_JUMP — every
		# "fires" stat below was actually counting jumps.
		var bits: int = int(d.get("b", 0))
		if (bits & NetProtocol.INPUT_FIRE) != 0:
			summary["fires"] = int(summary["fires"]) + 1
		var yaw: float = float(d.get("y", 0.0))
		var pitch: float = float(d.get("pt", 0.0))
		var prev: Variant = prev_aim.get(peer, null)
		if prev != null:
			var dy: float = absf(wrapf(yaw - float(prev.yaw), -PI, PI))
			if dy > float(summary["max_yaw_jump"]):
				summary["max_yaw_jump"] = dy
		prev_aim[peer] = {"yaw": yaw, "pitch": pitch}
		per_peer[peer] = summary
	print("")
	print("per-peer summary:")
	for peer in per_peer.keys():
		var s: Dictionary = per_peer[peer]
		print("  peer %d: %d frames, %d fires (%.1f%%), max yaw jump %.3f rad" % [
			peer, int(s.frames), int(s.fires),
			100.0 * float(s.fires) / maxf(1.0, float(s.frames)),
			float(s.max_yaw_jump),
		])
	# Sample the first 10 fire events with full state.
	print("")
	print("first 10 fire events:")
	var fire_count: int = 0
	for fr in frames:
		var d: Dictionary = fr
		if (int(d.get("b", 0)) & NetProtocol.INPUT_FIRE) == 0:
			continue
		fire_count += 1
		if fire_count > 10:
			break
		print("  t+%dms peer=%d tick=%d yaw=%.3f pitch=%.3f" % [
			int(d.get("t", 0)) - int(frames[0].get("t", 0)),
			int(d.get("p", 0)), int(d.get("k", 0)),
			float(d.get("y", 0.0)), float(d.get("pt", 0.0)),
		])
	quit(0)
