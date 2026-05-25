extends Node
## DS real-camera-aim integration test. Diff vs headless_two_client.gd: that
## test bypasses player_controller.try_fire() and sends client_fire RPCs by
## hand. THIS test drives `_aim_yaw` / `_aim_pitch` on the local player and
## then calls the real `try_fire()` API — the same code path the real game
## uses when you LMB. It catches bugs in:
##
##   - mouse-to-aim sensitivity / coordinate-system mismatch
##   - camera kick / recoil leakage polluting the sent aim
##   - try_fire() ammo/cooldown gating breaking under multiplayer
##   - mismatched body-yaw vs head-pitch when the server snaps the shooter
##
## Roles:
##   --role A   shooter; uses try_fire() with computed aim
##   --role B   victim; stands still
##
## Asserts (run_real_aim_test.sh): >= 3 [server] hit: lines where victim==B

const GAME_SCENE_PATH := "res://client/scenes/game.tscn"
const TICK_HZ := 30.0

var role: String = "A"
var address: String = "ws://127.0.0.1:9205"
var wait_seconds: float = 4.0

var game: Node = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--role" and i + 1 < args.size():
			role = args[i + 1]
		elif args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]
		elif args[i] == "--wait" and i + 1 < args.size():
			wait_seconds = float(args[i + 1])

	print("[%s] connect → %s" % [role, address])
	if not await _connect_and_mount():
		_die("connect failed")
		return
	if game.local_player == null:
		_die("no local_player after mount")
		return
	# Keep is_human_input=true so _physics_process runs _apply_camera_kick
	# (which writes our _aim_yaw → rotation.y) AND _step_weapon_visuals_only
	# (which decrements time_until_next_shot). In headless, Input.is_action_*
	# returns false so the auto-fire branch is dormant — we drive fire by
	# calling try_fire() directly.

	# Wait until B is visible to A and vice versa.
	if not await _wait_for_peer_count(2, 5.0):
		_die("peer count never reached 2 (got %d)" % game.players_by_peer.size())
		return
	# Extra dwell so the server's snapshot of our spawn has propagated.
	await get_tree().create_timer(0.6).timeout

	if role == "A":
		await _run_shooter()
	else:
		await _run_victim()
	get_tree().quit(0)


func _run_shooter() -> void:
	var me: Node = game.local_player
	# Find B in our snapshot view.
	var target: Node = null
	for pid in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[pid]
		if p != null and not p.is_local:
			target = p
			break
	if target == null:
		_die("A: no target peer in players_by_peer")
		return

	# Compute body-target world position aim. We write the same `_aim_yaw` /
	# `_aim_pitch` the mouse would have written, then let player_controller's
	# normal per-frame composition apply (rotation.y / head.rotation.x).
	# Then call try_fire() — the REAL API the LMB binding uses.
	var dt: float = 1.0 / TICK_HZ
	var elapsed: float = 0.0
	var fired_count: int = 0
	while elapsed < wait_seconds:
		# Re-aim each tick (target might respawn / shift).
		if not is_instance_valid(target):
			break
		var me_pos: Vector3 = me.global_position
		var tgt_pos: Vector3 = target.global_position
		var eye: Vector3 = me_pos + Vector3(0, 1.0, 0)
		var body: Vector3 = tgt_pos + Vector3(0, 0.8, 0)
		var to: Vector3 = body - eye
		var horiz: float = Vector2(to.x, to.z).length()
		var yaw: float = atan2(to.x, to.z) + PI
		var pitch: float = atan2(to.y, horiz)
		me._aim_yaw = yaw
		me._aim_pitch = pitch
		# Force composition immediately (don't wait for next _process) so the
		# camera basis reflects the new aim BEFORE try_fire reads it.
		me.rotation.y = me._aim_yaw + me._camera_kick.x
		me.head.rotation.x = clampf(me._aim_pitch + me._camera_kick.y, -PI * 0.49, PI * 0.49)
		# Real fire path — same call LMB makes.
		if me.try_fire():
			fired_count += 1
		await get_tree().create_timer(dt).timeout
		elapsed += dt
	print("[A] try_fire() returned true %d times over %.1fs" % [fired_count, wait_seconds])


func _run_victim() -> void:
	# With is_human_input=true the local player auto-streams 0-bits input via
	# _send_input_to_server, so we don't need to drive RPCs by hand. Just
	# wait and observe HP.
	var dt: float = 1.0 / TICK_HZ
	var elapsed: float = 0.0
	var loss_count: int = 0
	var last_hp: float = game.local_player.hp
	while elapsed < wait_seconds + 1.0:
		elapsed += dt
		var hp: float = game.local_player.hp
		if hp < last_hp:
			loss_count += 1
			last_hp = hp
		await get_tree().create_timer(dt).timeout
	print("[B] final hp=%.1f hp_drop_events=%d" % [game.local_player.hp, loss_count])


# ── Helpers ───────────────────────────────────────────────────────────────
func _connect_and_mount() -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		return false
	multiplayer.multiplayer_peer = peer
	var deadline: float = Time.get_ticks_msec() / 1000.0 + 5.0
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			return false
		await get_tree().process_frame
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	print("[%s] peer_id=%d" % [role, multiplayer.get_unique_id()])
	var game_scene: PackedScene = load(GAME_SCENE_PATH) as PackedScene
	game = game_scene.instantiate()
	game.name = "Game"
	get_tree().root.add_child.call_deferred(game)
	await get_tree().process_frame
	await get_tree().create_timer(0.7).timeout
	var spawn_deadline: float = Time.get_ticks_msec() / 1000.0 + 4.0
	while Time.get_ticks_msec() / 1000.0 < spawn_deadline:
		var g: Node = get_tree().root.get_node_or_null(^"Game")
		if g != null and g.get("local_player") != null:
			game = g
			return true
		await get_tree().process_frame
	return false


func _wait_for_peer_count(want: int, seconds: float) -> bool:
	var deadline: float = Time.get_ticks_msec() / 1000.0 + seconds
	while Time.get_ticks_msec() / 1000.0 < deadline:
		if game != null and game.players_by_peer.size() == want:
			return true
		await get_tree().process_frame
	return false


func _die(msg: String) -> void:
	push_error("[%s] %s" % [role, msg])
	print("[%s] FAIL: %s" % [role, msg])
	get_tree().quit(1)
