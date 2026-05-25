extends Node
## Local-player input prediction with server reconciliation.
##
## Each render frame on the client:
##   1. Sample input → bitfield + look angles.
##   2. Apply locally NOW (movement, ADS toggle, fire visuals).
##   3. Push {tick, bits, yaw, pitch} into pending_inputs and send to server.
##
## When a server snapshot arrives (tick T_ack):
##   1. Drop any pending_inputs with tick <= T_ack (they're confirmed).
##   2. Compare authoritative position vs locally-predicted at T_ack.
##   3. If diff > RECONCILE_THRESHOLD: snap local state to authoritative,
##      then re-simulate every still-pending input on top to keep responsiveness.

const RECONCILE_THRESHOLD := 0.5   # meters

var local_player: CharacterBody3D
var pending_inputs: Array = []   # [{tick, bits, yaw, pitch, pos_after}]
var last_acked_tick: int = 0


func _ready() -> void:
	set_physics_process(true)


func _physics_process(_delta: float) -> void:
	if local_player == null:
		return
	# TODO M1: sample input, advance local sim, send RPC, append to pending.


func on_server_snapshot(tick: int, my_authoritative_pos: Vector3) -> void:
	# Discard confirmed inputs.
	while pending_inputs.size() > 0 and pending_inputs[0].tick <= tick:
		pending_inputs.pop_front()
	last_acked_tick = tick

	if local_player == null:
		return

	# Find the pending entry that was at this tick (or use current if none).
	# In a full impl we'd interpolate; here we just snap-and-replay on big diffs.
	var predicted_now: Vector3 = local_player.global_position
	if predicted_now.distance_to(my_authoritative_pos) > RECONCILE_THRESHOLD:
		local_player.global_position = my_authoritative_pos
		# Re-simulate every still-pending input on top.
		for entry in pending_inputs:
			_replay_input(entry)


func _replay_input(_entry: Dictionary) -> void:
	# TODO M1: rerun movement step from this input. Must be deterministic with
	# the server's step or reconciliation will oscillate.
	pass
