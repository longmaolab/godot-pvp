extends Node
## DS multi-client rejoin regression. The current rejoin_test only exercises
## one client reconnecting alone. The user-reported bug: client A and B are
## both in the match, A hits ESC → Main Menu → JOIN, and after rejoin either
## A and B can no longer see each other, or shots from rejoined A no longer
## land on B. This test reproduces THAT flow.
##
## Roles (one Godot process each):
##   --role A   shooter; connects, waits for B, disconnects, reconnects, fires at B
##   --role B   victim;  connects, stands still, watches players_by_peer churn
##
## Asserts (per-role exits + log assertions in run_multi_rejoin_test.sh):
##   - A's second connection successfully spawns local_player
##   - After A rejoins, A and B both observe players_by_peer.size() == 2
##   - Server logs at least 1 [server] hit: after A's rejoin (damage path
##     survives the disconnect)

const GAME_SCENE_PATH := "res://client/scenes/game.tscn"
const TICK_HZ := 30.0

var role: String = "A"
var address: String = "ws://127.0.0.1:9203"
var wait_before_leave: float = 2.0
var pause_between: float = 1.0
var wait_after_rejoin: float = 4.0

var game: Node = null
var saw_two_peers_before_leave: bool = false
var saw_one_after_leave: bool = false
var saw_two_after_rejoin: bool = false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--role" and i + 1 < args.size():
			role = args[i + 1]
		elif args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]
		elif args[i] == "--wait-before-leave" and i + 1 < args.size():
			wait_before_leave = float(args[i + 1])
		elif args[i] == "--pause" and i + 1 < args.size():
			pause_between = float(args[i + 1])
		elif args[i] == "--wait-after-rejoin" and i + 1 < args.size():
			wait_after_rejoin = float(args[i + 1])

	if role == "A":
		await _run_a()
	else:
		await _run_b()


# ── Role A: connects, sees B, leaves, rejoins, fires at B ────────────────
func _run_a() -> void:
	print("[A] first connect → %s" % address)
	if not await _connect_and_mount():
		_die("A: first connect failed")
		return
	if not await _wait_for_peer_count(2, 5.0):
		_die("A: B never appeared in players_by_peer before leave")
		return
	saw_two_peers_before_leave = true
	print("[A] saw 2 peers; holding %.1fs before disconnect" % wait_before_leave)
	await get_tree().create_timer(wait_before_leave).timeout

	# Tear down — same path pause_menu uses for "Main Menu".
	_teardown()
	print("[A] disconnected; pausing %.1fs before rejoin" % pause_between)
	await get_tree().create_timer(pause_between).timeout

	# Rejoin.
	print("[A] reconnecting")
	if not await _connect_and_mount():
		_die("A: REJOIN failed — second connect never produced local_player")
		return
	if not await _wait_for_peer_count(2, 5.0):
		_die("A: REJOIN failed — B not visible in players_by_peer after rejoin")
		return
	saw_two_after_rejoin = true
	print("[A] REJOIN OK — both peers visible; firing at B for %.1fs" % wait_after_rejoin)

	# Now fire. We use the manual-RPC pattern from headless_two_client.gd so
	# we don't depend on Input.* in headless. Aim is derived from B's actual
	# snapshot position.
	if game.local_player != null:
		game.local_player.is_human_input = false
	await _fire_at_other_peer(wait_after_rejoin)
	print("[A] done")
	get_tree().quit(0)


# ── Role B: connects, stays, exits when A's rejoin window finishes ───────
func _run_b() -> void:
	print("[B] connect → %s" % address)
	if not await _connect_and_mount():
		_die("B: connect failed")
		return
	if game.local_player != null:
		game.local_player.is_human_input = false

	# Drive zero-input RPCs throughout so the server's view of B stays current
	# (otherwise the server might mark us idle / kick).
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("B: no NetRpc")
		return
	var total_wait: float = wait_before_leave + pause_between + wait_after_rejoin + 4.0
	var tick: int = 0
	var elapsed: float = 0.0
	var dt: float = 1.0 / TICK_HZ
	# Sample players_by_peer.size() at coarse intervals to confirm the churn
	# is visible from B's side too.
	var last_seen_size: int = -1
	while elapsed < total_wait:
		net_rpc.client_send_input.rpc_id(1, tick, 0, 0.0, 0.0)
		var n: int = game.players_by_peer.size() if game != null else 0
		if n != last_seen_size:
			print("[B] players_by_peer.size() = %d" % n)
			if n == 2 and not saw_two_peers_before_leave:
				saw_two_peers_before_leave = true
			elif n == 1 and saw_two_peers_before_leave and not saw_one_after_leave:
				saw_one_after_leave = true
			elif n == 2 and saw_one_after_leave:
				saw_two_after_rejoin = true
			last_seen_size = n
		tick += 1
		elapsed += dt
		await get_tree().create_timer(dt).timeout

	# Final state dump so the shell script can grep.
	print("[B] saw_two_before_leave=%s saw_one_after_leave=%s saw_two_after_rejoin=%s" % [
		saw_two_peers_before_leave, saw_one_after_leave, saw_two_after_rejoin])
	if not saw_two_after_rejoin:
		_die("B: never observed 2 peers AFTER A's rejoin — A is invisible to B")
		return
	get_tree().quit(0)


# ── Helpers ───────────────────────────────────────────────────────────────
func _connect_and_mount() -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		push_error("[%s] create_client failed: %s" % [role, err])
		return false
	multiplayer.multiplayer_peer = peer
	var deadline: float = Time.get_ticks_msec() / 1000.0 + 5.0
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			push_error("[%s] connect timeout" % role)
			return false
		await get_tree().process_frame
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		push_error("[%s] not connected: %d" % [role, peer.get_connection_status()])
		return false
	print("[%s] connected as peer %d" % [role, multiplayer.get_unique_id()])

	var game_scene: PackedScene = load(GAME_SCENE_PATH) as PackedScene
	game = game_scene.instantiate()
	game.name = "Game"
	get_tree().root.add_child.call_deferred(game)
	await get_tree().process_frame
	await get_tree().create_timer(0.6).timeout

	# Wait for our local player to materialize.
	var spawn_deadline: float = Time.get_ticks_msec() / 1000.0 + 4.0
	while Time.get_ticks_msec() / 1000.0 < spawn_deadline:
		var g: Node = get_tree().root.get_node_or_null(^"Game")
		if g != null and g.get("local_player") != null:
			game = g
			print("[%s] local_player up" % role)
			return true
		await get_tree().process_frame
	push_error("[%s] local_player never spawned" % role)
	return false


func _teardown() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	var g: Node = get_tree().root.get_node_or_null(^"Game")
	if g != null:
		g.queue_free()
	game = null
	# Yield a few frames so queue_free actually completes.
	for _i in 4:
		await get_tree().process_frame


func _wait_for_peer_count(want: int, seconds: float) -> bool:
	var deadline: float = Time.get_ticks_msec() / 1000.0 + seconds
	while Time.get_ticks_msec() / 1000.0 < deadline:
		if game != null and game.players_by_peer.size() == want:
			return true
		await get_tree().process_frame
	if game != null:
		push_error("[%s] expected %d peers, saw %d" % [role, want, game.players_by_peer.size()])
	return false


func _fire_at_other_peer(seconds: float) -> void:
	# Find B's position from our snapshot view and shoot at their body hitbox.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	var me_pos: Vector3 = Vector3.ZERO
	var target_pos: Vector3 = Vector3.ZERO
	for pid in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[pid]
		if p == null:
			continue
		if p.is_local:
			me_pos = p.global_position
		else:
			target_pos = p.global_position
	var eye: Vector3 = me_pos + Vector3(0, 1.0, 0)
	var body: Vector3 = target_pos + Vector3(0, 0.8, 0)
	var to: Vector3 = body - eye
	var horiz: float = Vector2(to.x, to.z).length()
	var aim_yaw: float = atan2(to.x, to.z) + PI
	var aim_pitch: float = atan2(to.y, horiz)
	var dt: float = 1.0 / TICK_HZ
	var tick: int = 0
	var elapsed: float = 0.0
	while elapsed < seconds:
		net_rpc.client_send_input.rpc_id(1, tick, NetProtocol.INPUT_FIRE, aim_yaw, aim_pitch)
		net_rpc.client_fire.rpc_id(1, &"ak20", aim_yaw, aim_pitch)
		tick += 1
		elapsed += dt
		await get_tree().create_timer(dt).timeout


func _die(msg: String) -> void:
	push_error(msg)
	print("[%s] FAIL: %s" % [role, msg])
	get_tree().quit(1)
