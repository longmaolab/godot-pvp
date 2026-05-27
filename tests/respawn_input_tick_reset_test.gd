extends SceneTree
## Regression test for the rematch "input ignored after Play Again" bug.
##
## player_controller.gd push_remote_input has a tick replay-protection:
##   if tick <= _remote_input_tick: return
##
## When a client re-enters the game scene (after match-end / Play Again),
## the client-side PlayerController is brand new → _input_tick starts at 0.
## But the server-side player persists with _remote_input_tick at whatever
## the prior match accumulated (typically several hundred or thousands).
## Result: every new client input was rejected → server-simulated player
## frozen, fire bit never seen → "打不死人" bug.
##
## Fix: respawn() resets _remote_input_tick to -1 (and bits/just_pressed
## to 0) so the next incoming frame establishes a fresh baseline.
##
## Run: bash tests/run_respawn_input_tick_reset_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Tiny floor so respawn doesn't fall into the void (gravity hits during
	# the await physics_frame between push_remote_input and assertion).
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0, -0.5, 0)

	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.is_local = false
	p.is_human_input = false
	p.use_remote_input = true
	root.add_child(p)
	p.global_position = Vector3(0, 1.0, 0)
	await physics_frame
	await physics_frame

	# --- Phase 1: simulate a played-out match. Push a bunch of input ticks
	# so _remote_input_tick climbs to a "large" value.
	for tick in range(1, 1200):
		p.push_remote_input(tick, 0, 0.0, 0.0)
	if p._remote_input_tick != 1199:
		failures.append("setup: _remote_input_tick expected 1199, got %d" % p._remote_input_tick)

	# --- Phase 2: respawn (simulates _boot_match_for_room calling
	# p.respawn() at the start of round 2).
	p.respawn(Vector3(5, 1, 5))
	if p._remote_input_tick != -1:
		failures.append("respawn did NOT reset _remote_input_tick (still %d)" % p._remote_input_tick)
	if p._remote_input_bits != 0:
		failures.append("respawn did NOT reset _remote_input_bits (still %d)" % p._remote_input_bits)
	if p._remote_input_just_pressed != 0:
		failures.append("respawn did NOT reset _remote_input_just_pressed (still %d)" % p._remote_input_just_pressed)

	# --- Phase 3: simulate the client's re-entry — a fresh PlayerController
	# starts sending ticks from 1. Without the reset, all of these get
	# rejected by `tick <= _remote_input_tick` (which would still be 1199).
	# With the reset (tick = -1), each tick should be accepted in order.
	const INPUT_FIRE := 1 << 5    # NetProtocol.INPUT_FIRE
	const INPUT_FORWARD := 1 << 0
	for tick in range(1, 6):
		p.push_remote_input(tick, INPUT_FORWARD | INPUT_FIRE, 0.1, 0.05)
	if p._remote_input_tick != 5:
		failures.append("post-respawn ticks rejected: expected last tick 5, got %d" % p._remote_input_tick)
	if (p._remote_input_bits & INPUT_FIRE) == 0:
		failures.append("INPUT_FIRE bit not stored after post-respawn input")
	if (p._remote_input_bits & INPUT_FORWARD) == 0:
		failures.append("INPUT_FORWARD bit not stored after post-respawn input")

	if failures.is_empty():
		print("[respawn-tick] PASS — respawn resets input baseline, post-rematch ticks accepted")
		quit(0)
	else:
		for f in failures:
			print("[respawn-tick] FAIL — " + f)
		quit(1)
