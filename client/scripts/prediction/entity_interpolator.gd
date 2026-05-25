extends Node
## Smooth-out remote players & bots by rendering them ~100ms behind the latest
## snapshot. Two snapshots straddling render_time gives us a clean lerp; missing
## snapshots fall back to extrapolation for at most one tick.

const INTERP_DELAY_MS := 100.0
const MAX_EXTRAPOLATE_MS := 50.0

# entity_id → Array[{server_time_ms, pos, yaw, pitch}] kept short (~10 entries).
var _snapshot_buffer: Dictionary = {}


func push_snapshot(entity_id: int, server_time_ms: float, pos: Vector3, yaw: float, pitch: float) -> void:
	if not _snapshot_buffer.has(entity_id):
		_snapshot_buffer[entity_id] = []
	var buf: Array = _snapshot_buffer[entity_id]
	buf.append({"t": server_time_ms, "pos": pos, "yaw": yaw, "pitch": pitch})
	# Trim old samples (anything older than 1s is useless).
	while buf.size() > 0 and server_time_ms - buf[0].t > 1000.0:
		buf.pop_front()


# Returns {pos, yaw, pitch} for rendering, or null if no data.
func sample(entity_id: int, now_server_time_ms: float):
	var buf: Array = _snapshot_buffer.get(entity_id, [])
	if buf.size() == 0:
		return null

	var render_t := now_server_time_ms - INTERP_DELAY_MS

	# Find straddling pair.
	for i in range(buf.size() - 1):
		var a: Dictionary = buf[i]
		var b: Dictionary = buf[i + 1]
		if a.t <= render_t and render_t <= b.t:
			var span: float = maxf(0.001, b.t - a.t)
			var alpha: float = clampf((render_t - a.t) / span, 0.0, 1.0)
			return {
				"pos": a.pos.lerp(b.pos, alpha),
				"yaw": lerp_angle(a.yaw, b.yaw, alpha),
				"pitch": lerpf(a.pitch, b.pitch, alpha),
			}

	# render_t past newest sample: short extrapolation, else clamp.
	var newest: Dictionary = buf[buf.size() - 1]
	var ahead: float = render_t - newest.t
	if ahead > 0.0 and ahead < MAX_EXTRAPOLATE_MS and buf.size() >= 2:
		var prev: Dictionary = buf[buf.size() - 2]
		var dt: float = maxf(0.001, newest.t - prev.t)
		var vel: Vector3 = (newest.pos - prev.pos) / dt
		return {
			"pos": newest.pos + vel * ahead,
			"yaw": newest.yaw,
			"pitch": newest.pitch,
		}
	return {"pos": newest.pos, "yaw": newest.yaw, "pitch": newest.pitch}


func forget(entity_id: int) -> void:
	_snapshot_buffer.erase(entity_id)
