extends Node
## Verifies MatchController win conditions for each mode family.
##   1. FFA kill-goal: simulate kills, assert match_ended fires at goal.
##   2. ELIM 1v1: simulate a death, assert round_ended; reach rounds_to_win → match_ended.
##   3. RACE (TDM-style): kill goal applies, simulate, verify.

const MC_SCRIPT := preload("res://shared/scripts/match_controller.gd")
const MODE_FFA := preload("res://shared/data/modes/ffa_kill5.tres")
const MODE_ELIM := preload("res://shared/data/modes/elim_1v1.tres")
const MODE_TDM := preload("res://shared/data/modes/tdm_kill10.tres")

var failed: int = 0


func _ready() -> void:
	print("\n=== match-mode integration test ===")
	await _test_ffa_kill_goal()
	await _test_elim_round_progression()
	await _test_race_kill_goal()
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _test_ffa_kill_goal() -> void:
	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_FFA
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()

	# Simulate 4 kills by peer 100 (not enough), then 5th triggers match_ended.
	for i in range(5):
		mc.record_kill(100, 200)

	await get_tree().process_frame
	if not captured["match_ended"]:
		_fail("FFA kill_goal=5: match did not end after 5 kills")
		mc.queue_free()
		return
	if captured["winner"] != 100:
		_fail("FFA winner expected 100, got %d" % captured["winner"])
		mc.queue_free()
		return
	if mc.kills.get(100, 0) != 5:
		_fail("FFA kills tracking: expected 5, got %d" % mc.kills.get(100, 0))
		mc.queue_free()
		return
	print("  [ok] FFA kill_goal: peer 100 won after 5 kills (deaths=%d)" % mc.deaths.get(200, 0))
	mc.queue_free()


func _test_elim_round_progression() -> void:
	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_ELIM
	add_child(mc)
	var state := {"rounds_ended": [] as Array, "match_won": 0}
	mc.round_ended.connect(func(w, _s): state["rounds_ended"].append(w))
	mc.match_ended.connect(func(w, _f): state["match_won"] = w)
	mc.start()

	# Round 1: peer 1 kills peer 2 → round_ended(1)
	mc.record_kill(1, 2)
	await get_tree().process_frame
	var rounds_ended: Array = state["rounds_ended"]
	if rounds_ended.size() != 1 or rounds_ended[0] != 1:
		_fail("elim round 1: expected winner=1, got %s" % rounds_ended)
		mc.queue_free()
		return
	if mc.match_over:
		_fail("elim: match ended after 1 round (best-of-3 needs 2)")
		mc.queue_free()
		return

	# Speed-run past the 2s inter-round timer by directly resuming the round.
	mc.round_active = true
	mc.record_kill(1, 2)
	await get_tree().process_frame
	if not mc.match_over:
		_fail("elim: match should be over after 2 round wins (rounds_to_win=2)")
		mc.queue_free()
		return
	if state["match_won"] != 1:
		_fail("elim match winner expected 1, got %d" % state["match_won"])
		mc.queue_free()
		return
	print("  [ok] ELIM 1v1: peer 1 won match after 2 rounds (best-of-3)")
	mc.queue_free()


func _test_race_kill_goal() -> void:
	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_TDM
	add_child(mc)
	var state := {"done": -1}
	mc.match_ended.connect(func(w, _f): state["done"] = w)
	mc.start()

	# TDM kill goal is 10 → peer 7 reaches 10 kills.
	for i in range(10):
		mc.record_kill(7, 99)
	await get_tree().process_frame
	if state["done"] != 7:
		_fail("race: expected winner=7 after 10 kills, got %d" % state["done"])
		mc.queue_free()
		return
	print("  [ok] RACE/TDM: peer 7 won at 10 kills")
	mc.queue_free()


func _fail(msg: String) -> void:
	push_error("[match-mode] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
