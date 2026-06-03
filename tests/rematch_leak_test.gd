extends SceneTree
## Reproduction harness for: "two clients on two different machines, both
## browsers QUIT simultaneously after ~2 matches, Chrome auto-restarts."
##
## Two browsers on separate machines crashing at the same instant rules out
## local memory — it's a SHARED trigger from the server. A whole-browser /
## GPU-process crash after a few matches points at GPU-memory accumulation:
## entities/nodes that aren't freed when a match ends, so every rematch the
## server's room world holds more, broadcasts more, and every client renders
## a larger scene until the renderer dies.
##
## This single-process server harness boots a real room match (the same
## _boot_match_for_room path the DS uses), ends it — which fires the real
## end_match → match_finished → _tear_down_match_world teardown — then
## rematches, repeating CYCLES times. After each teardown it records the live
## node count (Performance.OBJECT_NODE_COUNT) and orphan count (removed-but-
## not-freed = a hard leak). If the post-teardown baseline climbs every cycle,
## the room teardown LEAKS and that's the client-crash root cause. A flat
## baseline means the leak is elsewhere (NaN positions / client-side / per-shot)
## and we look there next. It also scans every entity for NaN/Inf positions
## (a degenerate-geometry render is the other GPU-crash vector).

const GameControllerScript = preload("res://client/scripts/game_controller.gd")
const MAP := "res://shared/scenes/maps/blank.tscn"
const MODE := "res://shared/data/modes/10v10.tres"   # what the user actually plays
const CYCLES := 4

var failures: Array = []
var gc: Node = null
var rm: Node = null
var room_id: String = ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# OfflineMultiplayerPeer → multiplayer.is_server() == true so
	# _boot_match_for_room doesn't early-return (same trick as concurrent_match).
	root.get_multiplayer().multiplayer_peer = OfflineMultiplayerPeer.new()
	rm = root.get_node_or_null(^"RoomManager")
	if rm == null:
		_fail("RoomManager autoload missing")
		return _finish()
	await physics_frame

	gc = GameControllerScript.new()
	gc.name = "Game"
	gc.is_dedicated_server = true
	root.add_child(gc)
	await physics_frame
	# Defensive wire-up (GameController._ready hooks these in real DS mode).
	if not rm.match_started.is_connected(gc._boot_match_for_room):
		rm.match_started.connect(gc._boot_match_for_room)
		rm.match_finished.connect(gc._on_match_finished_in_room)
		rm.room_destroyed.connect(gc._on_room_destroyed_check_active)

	room_id = rm.create_room(1001, MAP, MODE)
	if room_id.is_empty():
		_fail("create_room failed (bad map/mode path?)")
		return _finish()
	rm.join_room(1002, room_id)

	var teardown_nodes: Array = []
	var orphan_counts: Array = []
	for cycle in range(CYCLES):
		rm.start_match(room_id)
		await _settle(30)   # RoomWorld add_child + load_map + bot spawn are deferred
		var rw: Node = gc.room_worlds.get(room_id, null)
		var rw_nodes: int = _count_descendants(rw)
		print("[rematch-leak] cycle %d BOOT          : total_nodes=%d room_world=%d orphans=%d" % [
			cycle + 1, _node_count(), rw_nodes, _orphan_count()])
		_scan_nan(rw, cycle + 1)

		rm.end_match(room_id, 1001, {})
		await _settle(30)   # let the queue_free cascade fully complete
		teardown_nodes.append(_node_count())
		orphan_counts.append(_orphan_count())
		print("[rematch-leak] cycle %d AFTER TEARDOWN : total_nodes=%d orphans=%d" % [
			cycle + 1, _node_count(), _orphan_count()])

	# Verdict: the post-teardown node baseline must not climb cycle-over-cycle.
	# Skip cycle 1 (one-time first-boot allocations: shaders, fonts, autoload
	# lazy-init). Compare the stable tail.
	var base: int = teardown_nodes[1]
	var tail: int = teardown_nodes[CYCLES - 1]
	var growth: int = tail - base
	var per_cycle: float = float(growth) / float(maxi(1, CYCLES - 2))
	print("[rematch-leak] post-teardown baseline: %s" % str(teardown_nodes))
	print("[rematch-leak] orphan counts:         %s" % str(orphan_counts))
	print("[rematch-leak] baseline growth cycles 2..%d: +%d nodes (~%.1f / rematch)" % [
		CYCLES, growth, per_cycle])
	if per_cycle > 5.0:
		_fail("LEAK — room teardown leaks ~%.0f nodes per rematch. These accumulate on every client (each renders the broadcast scene), so after a few matches the renderer/GPU runs out of memory and the browser crashes — matching the report. Baseline=%s" % [per_cycle, str(teardown_nodes)])
	else:
		print("  [ok] no node accumulation across %d rematches — teardown frees cleanly" % CYCLES)
	_finish()


func _settle(frames: int) -> void:
	for i in range(frames):
		await physics_frame


func _node_count() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func _orphan_count() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))


func _count_descendants(n: Node) -> int:
	if n == null or not is_instance_valid(n):
		return 0
	var c: int = 0
	for ch in n.get_children():
		c += 1 + _count_descendants(ch)
	return c


func _scan_nan(rw: Node, cycle: int) -> void:
	if rw == null or not is_instance_valid(rw):
		return
	for node in _all_nodes(rw):
		if node is Node3D:
			var p: Vector3 = (node as Node3D).global_position
			if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
				_fail("NaN/Inf position on '%s' = %s (cycle %d) — a client rendering this geometry crashes the GPU" % [
					node.name, str(p), cycle])
				return


func _all_nodes(n: Node) -> Array:
	var out: Array = [n]
	for ch in n.get_children():
		out.append_array(_all_nodes(ch))
	return out


func _fail(msg: String) -> void:
	failures.append(msg)
	print("  [FAIL] %s" % msg)


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — rematch harness: no node accumulation / no NaN across %d matches" % CYCLES)
		quit(0)
	else:
		print("  FAIL — rematch harness found %d issue(s) (see [FAIL] lines above)" % failures.size())
		quit(1)
