extends SceneTree
## Client-side prediction + reconciliation convergence test (DS-client local
## human). Proves the safety contract of player_controller's PREDICT_LOCAL_
## MOVEMENT path so we can ship it without being able to feel it in-browser:
##
##   A. Responsiveness — a snapshot-only local human now MOVES from input the
##      same frame, WITHOUT any server snapshot. (Before prediction it would
##      sit frozen until the first snapshot landed ~150ms later.)
##   B. Deadzone (no rubber-band) — when the server snapshot is within
##      PRED_SOFT_M (the gap is just network latency), prediction is trusted
##      and the body is NOT dragged backward.
##   C. Soft ease — a mid-size divergence (SOFT..HARD) eases toward the server
##      smoothly (partial correction, not a teleport).
##   D. Hard snap — a large divergence (>= HARD, i.e. respawn / teleport /
##      genuine desync) snaps straight to the authoritative position.
##
## What it does NOT prove: the in-game *feel* at real latency — that needs a
## human with two clients. This pins the math/wiring so a regression here is
## caught headless. Run: bash tests/run_prediction_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const SPAWN_Y := 1.0
const INPUT_FORWARD := 1 << 0   # mirror NetProtocol.INPUT_FORWARD

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Floor so the predicted body stands instead of free-falling.
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 0.5, 60)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0, -0.25, 0)

	# DS-client local human in snapshot-only mode = the predictor. We also set
	# use_remote_input so _step_movement reads _remote_input_bits instead of
	# Input.* (unavailable headless); the snapshot-only branch is entered
	# regardless of use_remote_input, so the real predictor wiring is exercised.
	var p: Node = await _spawn_predictor(Vector3(0, SPAWN_Y, 0))
	if p == null:
		_finish("could not instantiate predictor player")
		return
	if not p.PREDICT_LOCAL_MOVEMENT:
		_finish("PREDICT_LOCAL_MOVEMENT is off — prediction disabled, nothing to test")
		return
	if p._interpolator == null:
		_finish("interpolator missing — _ready did not set up snapshot-only mode")
		return

	# ── A. Responsiveness: move from input with NO snapshot pushed ──────────
	var a_start: Vector3 = p.global_position
	p.use_remote_input = true
	p._remote_input_bits = INPUT_FORWARD
	await _wait_seconds(0.4)          # tree drives _physics_process → predictor moves
	p._remote_input_bits = 0
	var a_end: Vector3 = p.global_position
	var travel: float = Vector2(a_end.x - a_start.x, a_end.z - a_start.z).length()
	if travel < 1.0:
		failures.append("A: predictor did not move from input without a snapshot (travel=%.2fm, expected >1m). Prediction not wired into the snapshot-only branch." % travel)
	checks_done += 1

	# Freeze the tree's physics callback so B/C/D are fully deterministic — we
	# drive _reconcile_prediction by hand with controlled authoritative input.
	p.set_physics_process(false)
	p.velocity = Vector3.ZERO

	# ── B. Deadzone: server within PRED_SOFT_M → NO correction ──────────────
	var base_b := Vector3(10, SPAWN_Y, 0)
	p.global_position = base_b
	var auth_b := base_b + Vector3(p.PRED_SOFT_M - 1.0, 0, 0)   # gap < SOFT
	_set_auth(p, auth_b)
	p._reconcile_prediction(1.0 / 60.0)
	var moved_b: float = p.global_position.distance_to(base_b)
	if moved_b > 0.01:
		failures.append("B: rubber-band inside deadzone — body moved %.3fm toward a within-SOFT snapshot (should be 0). Normal-latency play would jitter." % moved_b)
	checks_done += 1

	# ── C. Soft ease: SOFT < gap < HARD → partial correction, not a snap ────
	var base_c := Vector3(20, SPAWN_Y, 0)
	p.global_position = base_c
	var gap_c: float = (p.PRED_SOFT_M + p.PRED_HARD_M) * 0.5   # squarely between
	var auth_c := base_c + Vector3(gap_c, 0, 0)
	_set_auth(p, auth_c)
	p._reconcile_prediction(1.0 / 60.0)
	var moved_c: float = p.global_position.distance_to(base_c)
	var remain_c: float = p.global_position.distance_to(auth_c)
	if moved_c <= 0.01:
		failures.append("C: no correction in the soft band (gap=%.2fm) — drift would never heal." % gap_c)
	elif remain_c <= 0.01:
		failures.append("C: snapped in the soft band (gap=%.2fm) — should ease, not teleport." % gap_c)
	checks_done += 1

	# ── D. Hard snap: gap >= PRED_HARD_M → snap to authoritative ────────────
	var base_d := Vector3(30, SPAWN_Y, 0)
	p.global_position = base_d
	var auth_d := base_d + Vector3(p.PRED_HARD_M + 3.0, 0, 0)   # respawn-scale
	_set_auth(p, auth_d)
	p._reconcile_prediction(1.0 / 60.0)
	var remain_d: float = p.global_position.distance_to(auth_d)
	if remain_d > 0.05:
		failures.append("D: did not snap on a >=HARD divergence (%.2fm left). Respawn/teleport would lag behind the server." % remain_d)
	checks_done += 1

	_finish("travel=%.2fm | deadzone moved=%.3fm | soft moved=%.2f remain=%.2f | hard remain=%.3f" \
		% [travel, moved_b, moved_c, remain_c, remain_d])


func _set_auth(p: Node, pos: Vector3) -> void:
	# Single fresh authoritative sample so interpolator.sample() returns it
	# deterministically (size<2 → returns newest, no extrapolation).
	p._interpolator.forget(0)
	p.push_snapshot(float(Time.get_ticks_msec()), pos, 0.0, 0.0)


func _spawn_predictor(pos: Vector3) -> Node:
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	if scene == null:
		return null
	var p: Node = scene.instantiate()
	p.is_local = true
	p.is_human_input = true
	p.is_snapshot_only = true
	root.add_child(p)
	p.global_position = pos
	await physics_frame   # let _ready build the interpolator
	return p


func _wait_seconds(t: float) -> void:
	var elapsed: float = 0.0
	while elapsed < t:
		await physics_frame
		elapsed += 1.0 / 60.0


func _finish(summary: String) -> void:
	print("[prediction-test] %s" % summary)
	if failures.is_empty():
		print("  PASS — %d checks ok: responsive, deadzone holds, soft eases, hard snaps" % checks_done)
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
