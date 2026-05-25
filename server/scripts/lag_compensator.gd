extends Node
class_name LagCompensator
## Records each tracked entity's recent position history so the server can
## "rewind" the world to the state a shooter saw on their screen when they
## pulled the trigger.
##
## Algorithm (per fire RPC):
##   estimated_view_time = now_ms - (client_ping_ms / 2 + INTERP_DELAY_MS)
##   for each potential target:
##     hist_pos = sample_at(target_peer, estimated_view_time)
##     temporarily move target_node to hist_pos
##   raycast
##   restore positions
##
## This file owns just the buffer + sample math. game_controller wires the
## physical-rewind step around its raycast call.

const HISTORY_MS: float = 1500.0   # keep ~1.5s of recent positions

# peer_id → Array of {t: float, pos: Vector3, yaw: float, pitch: float}
# (oldest first; we trim from the front).
var _history: Dictionary = {}


func record(peer_id: int, pos: Vector3, yaw: float, pitch: float, t_ms: float = -1.0) -> void:
	if t_ms < 0.0:
		t_ms = float(Time.get_ticks_msec())
	if not _history.has(peer_id):
		_history[peer_id] = []
	var buf: Array = _history[peer_id]
	buf.append({"t": t_ms, "pos": pos, "yaw": yaw, "pitch": pitch})
	# Trim old samples.
	while buf.size() > 0 and t_ms - buf[0].t > HISTORY_MS:
		buf.pop_front()


## Returns {pos, yaw, pitch} for peer at the given timestamp, interpolating
## between the two straddling samples. Returns null if no data.
func sample_at(peer_id: int, t_ms: float):
	var buf: Array = _history.get(peer_id, [])
	if buf.is_empty():
		return null
	# Clamp to oldest if request precedes our data.
	if t_ms <= buf[0].t:
		return {"pos": buf[0].pos, "yaw": buf[0].yaw, "pitch": buf[0].pitch}
	# Clamp to newest if request exceeds our data.
	var last: Dictionary = buf[buf.size() - 1]
	if t_ms >= last.t:
		return {"pos": last.pos, "yaw": last.yaw, "pitch": last.pitch}
	# Find straddling pair and lerp.
	for i in range(buf.size() - 1):
		var a: Dictionary = buf[i]
		var b: Dictionary = buf[i + 1]
		if a.t <= t_ms and t_ms <= b.t:
			var span: float = maxf(0.001, b.t - a.t)
			var alpha: float = (t_ms - a.t) / span
			return {
				"pos": a.pos.lerp(b.pos, alpha),
				"yaw": lerp_angle(a.yaw, b.yaw, alpha),
				"pitch": lerpf(a.pitch, b.pitch, alpha),
			}
	return null


func forget(peer_id: int) -> void:
	_history.erase(peer_id)


func snapshot_count(peer_id: int) -> int:
	return _history.get(peer_id, []).size()


func clear() -> void:
	_history.clear()
