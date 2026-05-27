extends SceneTree
## Rigorous match-end / rematch flow regression. User reported "再来一局"
## had no error feedback when it failed (e.g. joiner clicking it just
## froze the button; host disconnect → joiner stuck).
##
## What this test pins:
##   1. RoomManager._on_client_start_match honors host gate — start_match
##      only fires when peer == room.host_peer.
##   2. Non-host start_match calls leave room.state == LOBBY (idempotent).
##   3. start_match from missing-room peer is harmless (no crash).
##   4. MatchEnd UI reacts to server_start_match_failed by re-enabling
##      the Play Again button and showing a reject reason.
##   5. MatchEnd hides Play Again entirely on "room_gone" / "no_room"
##      reasons (no point keeping a permanently-failing button).
##   6. MatchEnd uses room_state to render "你是 HOST/JOINER".
##
## Run: bash tests/run_rematch_reject_test.sh

const Room = preload("res://server/scripts/room.gd")
const RoomManager = preload("res://server/scripts/room_manager.gd")
const MatchEnd = preload("res://client/scenes/hud/match_end.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# --- Server-side: RoomManager start_match host gate ---
	await _test_server_start_match_gate()
	# --- Client-side: MatchEnd reaction to server feedback ---
	await _test_match_end_reject_handling()
	await _test_match_end_room_status()
	await _test_match_end_room_gone_hides_button()

	if failures.is_empty():
		print("[rematch-reject] PASS — %d assertions held" % _check_count)
		quit(0)
	else:
		for f in failures:
			print("[rematch-reject] FAIL — " + f)
		quit(1)


var _check_count: int = 0
func _expect(cond: bool, msg: String) -> void:
	_check_count += 1
	if not cond:
		failures.append(msg)


# ── Server-side gate ─────────────────────────────────────────────────────

func _test_server_start_match_gate() -> void:
	var rm := RoomManager.new()
	root.add_child(rm)
	await physics_frame

	# Create room with peer 100 as host, peer 200 as joiner.
	var room_id: String = rm.create_room(100, "res://shared/scenes/maps/blank.tscn", "")
	_expect(room_id != "", "create_room returned empty (registry broken?)")
	_expect(rm.join_room(200, room_id), "join_room failed for peer 200")
	var room: Room = rm.rooms[room_id]
	_expect(room.state == Room.STATE_LOBBY, "fresh room state should be LOBBY, got %d" % room.state)

	# Joiner sends start_match — should be rejected, room stays LOBBY.
	rm._on_client_start_match(200)
	_expect(room.state == Room.STATE_LOBBY, "joiner start_match should not flip room state, got %d" % room.state)

	# Host sends start_match — should flip to MATCH.
	rm._on_client_start_match(100)
	_expect(room.state == Room.STATE_MATCH, "host start_match should flip to MATCH, got %d" % room.state)

	# Host sends again while in MATCH — idempotent no-op.
	var before: int = room.state
	rm._on_client_start_match(100)
	_expect(room.state == before, "duplicate start_match should not change state")

	# Random unknown peer — should not crash.
	rm._on_client_start_match(999)   # not in peer_to_room
	_expect(true, "start_match from unknown peer should not crash (got here)")

	rm.queue_free()
	await physics_frame


# ── Client-side MatchEnd UI ──────────────────────────────────────────────

func _test_match_end_reject_handling() -> void:
	var me: Node = MatchEnd.instantiate()
	root.add_child(me)
	await physics_frame
	# Simulate the populated room state a joiner would see.
	me.local_peer = 200
	me.set_room_state({
		"id": "AXJ7",
		"host": 100,
		"players": [100, 200],
		"profiles": {100: {"name": "Ranger"}, 200: {"name": "Xeno"}},
		"last_winner": 100,
		"last_scores": {},
	})
	# Set a no-op callable so _on_play_again takes the DS-client path
	# (callable invocation) instead of the listen-host fallback that calls
	# reload_current_scene — which errors in SceneTree test mode because
	# there's no current_scene to reload.
	me.set_play_again_callable(func(): pass)
	me.show_for(100, {}, 200)
	await physics_frame

	# Joiner clicks Play Again — disabled + "请求中..."
	me._on_play_again()
	_expect(me.play_again_btn.disabled, "Play Again should disable on click while RPC pending")
	_expect(me._action_status_label.text.find("请求中") >= 0, "Action status should say '请求中...' while waiting")

	# Server replies "not_host" — re-enable + show Chinese reason.
	me._on_start_match_failed("not_host")
	_expect(not me.play_again_btn.disabled, "Play Again should re-enable on reject")
	_expect(me._action_status_label.text.find("只有房主能开新一局") >= 0,
		"reject reason 'not_host' should show 'only host can start' message, got '%s'" % me._action_status_label.text)
	_expect(me.play_again_btn.visible, "Play Again should still be visible on 'not_host' (host might start)")

	me.queue_free()
	await physics_frame


func _test_match_end_room_status() -> void:
	var me: Node = MatchEnd.instantiate()
	root.add_child(me)
	await physics_frame

	# Local = host.
	me.local_peer = 100
	me.set_room_state({"id": "BXYZ", "host": 100, "players": [100, 200], "profiles": {}})
	me.show_for(100, {}, 100)
	await physics_frame
	_expect(me._room_status_label.text.find("BXYZ") >= 0, "room status should include id, got '%s'" % me._room_status_label.text)
	_expect(me._room_status_label.text.find("HOST") >= 0, "host's status should say HOST, got '%s'" % me._room_status_label.text)

	# Switch to joiner perspective.
	me.local_peer = 200
	me.set_room_state({"id": "BXYZ", "host": 100, "players": [100, 200], "profiles": {}})
	await physics_frame
	_expect(me._room_status_label.text.find("JOINER") >= 0,
		"joiner's status should say JOINER, got '%s'" % me._room_status_label.text)

	me.queue_free()
	await physics_frame


func _test_match_end_room_gone_hides_button() -> void:
	var me: Node = MatchEnd.instantiate()
	root.add_child(me)
	await physics_frame
	me.local_peer = 200
	me.set_room_state({"id": "DEAD", "host": 100, "players": [200], "profiles": {}})
	me.show_for(0, {}, 200)
	await physics_frame
	_expect(me.play_again_btn.visible, "Play Again starts visible when room exists")

	# Server says room_gone — UI should hide button + mark room dead.
	me._on_start_match_failed("room_gone")
	_expect(not me.play_again_btn.visible, "Play Again should hide on 'room_gone'")
	_expect(me._room_status_label.text.find("房间已不存在") >= 0,
		"room status should flip to '房间已不存在', got '%s'" % me._room_status_label.text)

	me.queue_free()
	await physics_frame
