extends Node
## Unit-test the LagCompensator history buffer + sample_at interpolation math.

const LC_SCRIPT := preload("res://server/scripts/lag_compensator.gd")

var failed: int = 0


func _ready() -> void:
	print("\n=== lag_compensator unit test ===")
	_test_basic_record_and_sample()
	_test_interpolation_midpoint()
	_test_clamp_to_oldest_and_newest()
	_test_history_trim()
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _test_basic_record_and_sample() -> void:
	var lc: Node = LC_SCRIPT.new()
	add_child(lc)
	lc.record(42, Vector3(0, 0, 0), 0.0, 0.0, 1000.0)
	lc.record(42, Vector3(10, 0, 0), 1.5, 0.5, 1100.0)
	if lc.snapshot_count(42) != 2:
		_fail("snapshot_count: expected 2, got %d" % lc.snapshot_count(42))
		lc.queue_free(); return
	var s = lc.sample_at(42, 1050.0)
	if s == null:
		_fail("sample_at returned null at midpoint")
		lc.queue_free(); return
	# Expect halfway interpolation: (5, 0, 0)
	if s.pos.distance_to(Vector3(5, 0, 0)) > 0.01:
		_fail("midpoint pos expected (5,0,0), got %s" % s.pos)
		lc.queue_free(); return
	print("  [ok] basic record + midpoint sample (5, 0, 0)")
	lc.queue_free()


func _test_interpolation_midpoint() -> void:
	var lc: Node = LC_SCRIPT.new()
	add_child(lc)
	lc.record(1, Vector3(0, 0, 0), 0.0, 0.0, 0.0)
	lc.record(1, Vector3(20, 0, 0), 0.0, 0.0, 200.0)
	lc.record(1, Vector3(20, 10, 0), 0.0, 0.0, 400.0)
	var s = lc.sample_at(1, 100.0)
	if s == null or s.pos.distance_to(Vector3(10, 0, 0)) > 0.01:
		_fail("interp at 100ms expected (10,0,0), got %s" % str(s))
		lc.queue_free(); return
	var s2 = lc.sample_at(1, 300.0)
	if s2 == null or s2.pos.distance_to(Vector3(20, 5, 0)) > 0.01:
		_fail("interp at 300ms expected (20,5,0), got %s" % str(s2))
		lc.queue_free(); return
	print("  [ok] multi-segment interpolation correct")
	lc.queue_free()


func _test_clamp_to_oldest_and_newest() -> void:
	var lc: Node = LC_SCRIPT.new()
	add_child(lc)
	lc.record(7, Vector3(0, 0, 0), 0.0, 0.0, 500.0)
	lc.record(7, Vector3(10, 0, 0), 0.0, 0.0, 600.0)
	# Before oldest:
	var s1 = lc.sample_at(7, 100.0)
	if s1 == null or s1.pos != Vector3(0, 0, 0):
		_fail("sample before oldest should clamp to oldest, got %s" % str(s1))
		lc.queue_free(); return
	# After newest:
	var s2 = lc.sample_at(7, 1000.0)
	if s2 == null or s2.pos != Vector3(10, 0, 0):
		_fail("sample after newest should clamp to newest, got %s" % str(s2))
		lc.queue_free(); return
	print("  [ok] clamp to oldest/newest works")
	lc.queue_free()


func _test_history_trim() -> void:
	var lc: Node = LC_SCRIPT.new()
	add_child(lc)
	# Records 0..3000ms; HISTORY_MS=1500, so oldest at 3000-1500=1500 should remain.
	for i in range(0, 31):
		var t: float = float(i) * 100.0
		lc.record(3, Vector3(t, 0, 0), 0.0, 0.0, t)
	var count: int = lc.snapshot_count(3)
	# 1500..3000 in steps of 100 = 16 samples
	if count > 17 or count < 14:
		_fail("expected ~16 samples after trim, got %d" % count)
		lc.queue_free(); return
	# Oldest sample should now be at t >= 1500
	var oldest_t: float = lc._history[3][0].t
	if oldest_t < 1450.0:
		_fail("oldest sample should be t>=1500 after trim, got %f" % oldest_t)
		lc.queue_free(); return
	print("  [ok] history trimmed to ~%d samples (oldest t=%.0f, HISTORY_MS=1500)" % [count, oldest_t])
	lc.queue_free()


func _fail(msg: String) -> void:
	push_error("[lag-comp] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
