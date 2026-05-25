extends Node
## DS-M2 test client. Connects to a dedicated server, sends a hello, then
## drives the server-simulated player via client_send_input RPCs for a set
## number of ticks. After the burst, disconnects.
##
## The server-side test asserts the player position changed in the expected
## direction (server-authoritative simulation from received input).
##
## Run:
##   godot --headless --path . tests/headless_input_client.tscn -- \
##     --address ws://127.0.0.1:9102 --duration 1.5 --bits 1   # 1 = FORWARD
##
## Exit code 0 on graceful disconnect, 1 on connect/welcome failure.

const CONNECT_TIMEOUT_SEC := 5.0
const WELCOME_TIMEOUT_SEC := 5.0
const SPAWN_DELAY_SEC     := 0.4    # let server finish spawning the player
const TICK_HZ             := 30.0

var got_welcome: bool = false
var net_rpc: Node
var _bits: int = 0
var _duration: float = 1.5
# DS-M3: snapshot observation for verification
var _snapshot_count: int = 0
var _last_snapshot_self_pos: Vector3 = Vector3.INF
var _my_peer_id: int = -1
# DS-M4: aim direction for hitscan tests
var _aim_yaw: float = 0.0
var _aim_pitch: float = 0.0
# DS-M5: HP from snapshots (so test can verify damage broadcast / respawn)
var _last_snapshot_self_hp: int = -1
# DS-M5: damage events received
var _damage_events: int = 0


func _ready() -> void:
	var address: String = "ws://127.0.0.1:9102"
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]
		elif args[i] == "--duration" and i + 1 < args.size():
			_duration = float(args[i + 1])
		elif args[i] == "--bits" and i + 1 < args.size():
			_bits = int(args[i + 1])
		elif args[i] == "--aim-yaw" and i + 1 < args.size():
			_aim_yaw = float(args[i + 1])
		elif args[i] == "--aim-pitch" and i + 1 < args.size():
			_aim_pitch = float(args[i + 1])

	print("[input-test] connecting to %s, bits=%d, duration=%.2fs" % [address, _bits, _duration])

	net_rpc = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("NetRpc autoload missing")
		return
	net_rpc.server_welcome_received.connect(_on_welcome)
	net_rpc.server_snapshot_received.connect(_on_snapshot)
	net_rpc.server_mode_info_received.connect(_on_mode_info)
	net_rpc.server_damage_received.connect(_on_damage)
	net_rpc.server_respawn_received.connect(_on_respawn)

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		_die("create_client failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer

	# Wait for connection.
	var deadline: float = Time.get_ticks_msec() / 1000.0 + CONNECT_TIMEOUT_SEC
	while multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			_die("connect timeout")
			return
		await get_tree().process_frame
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_die("not connected; status=%s" % multiplayer.multiplayer_peer.get_connection_status())
		return
	print("[input-test] connected; my id=%d" % multiplayer.get_unique_id())

	# Hello → welcome handshake.
	net_rpc.client_hello.rpc_id(1, "input-test")
	deadline = Time.get_ticks_msec() / 1000.0 + WELCOME_TIMEOUT_SEC
	while not got_welcome:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			_die("welcome timeout")
			return
		await get_tree().process_frame

	# Give the server a beat to actually spawn the player node.
	await get_tree().create_timer(SPAWN_DELAY_SEC).timeout

	# Drive input for the requested duration.
	var tick_interval: float = 1.0 / TICK_HZ
	var tick: int = 0
	var elapsed: float = 0.0
	print("[input-test] streaming input bits=%d aim=(%.3f,%.3f) for %.2fs at %.0fHz" % [_bits, _aim_yaw, _aim_pitch, _duration, TICK_HZ])
	while elapsed < _duration:
		net_rpc.client_send_input.rpc_id(1, tick, _bits, _aim_yaw, _aim_pitch)
		tick += 1
		await get_tree().create_timer(tick_interval).timeout
		elapsed += tick_interval

	# Tail with a few zero-input ticks so the server settles velocity → 0
	# before we disconnect (makes the final-position log deterministic).
	for i in range(6):
		net_rpc.client_send_input.rpc_id(1, tick, 0, _aim_yaw, _aim_pitch)
		tick += 1
		await get_tree().create_timer(tick_interval).timeout

	print("[input-test] PASS — sent %d input frames, %d snapshots received, %d damage events" % [tick, _snapshot_count, _damage_events])
	if _last_snapshot_self_pos != Vector3.INF:
		print("[input-test] last snapshot self pos: (%.3f, %.3f, %.3f)" % [
			_last_snapshot_self_pos.x, _last_snapshot_self_pos.y, _last_snapshot_self_pos.z])
	if _last_snapshot_self_hp >= 0:
		print("[input-test] last snapshot self hp: %d" % _last_snapshot_self_hp)
	get_tree().quit(0)


func _on_welcome(your_peer: int, server_tick: int) -> void:
	print("[input-test] welcome: peer=%d tick=%d" % [your_peer, server_tick])
	got_welcome = true
	_my_peer_id = your_peer


func _on_mode_info(is_dedicated: bool) -> void:
	print("[input-test] server is_dedicated=%s" % is_dedicated)


func _on_snapshot(_tick: int, entities: Array) -> void:
	_snapshot_count += 1
	# Pick out our own entity if present.
	for e in entities:
		if int(e.get("p", 0)) == _my_peer_id:
			_last_snapshot_self_pos = e.get("pos", Vector3.ZERO)
			_last_snapshot_self_hp = int(e.get("hp", -1))
			break


func _on_damage(target: int, new_hp: float, src: int, weapon: StringName, headshot: bool) -> void:
	_damage_events += 1
	print("[input-test] server_apply_damage: target=%d new_hp=%.1f src=%d weapon=%s head=%s" % [target, new_hp, src, weapon, headshot])


func _on_respawn(peer: int, pos: Vector3) -> void:
	print("[input-test] server_player_respawned: peer=%d at (%.2f,%.2f,%.2f)" % [peer, pos.x, pos.y, pos.z])


func _die(msg: String) -> void:
	push_error("[input-test] FAIL: " + msg)
	print("[input-test] FAIL: %s" % msg)
	get_tree().quit(1)
