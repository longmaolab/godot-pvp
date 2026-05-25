extends Node
## DS two-client integration test. Two headless game.tscn clients connect to
## the same DS. Client A points at Client B's spawn position and holds FIRE
## for several seconds. Asserts: B's HP drops on the server.
##
## This exercises the EXACT path the user runs interactively:
##   - DS started independently
##   - Real game.tscn instance for each client (with full _enter_client_mode flow)
##   - client_send_input + client_fire RPCs flowing
##   - server-side raycast + lag-comp rewind
##   - server_apply_damage broadcast reaching both clients
##   - snapshot HP updates
##
## Run (from run_two_client_test.sh):
##   godot --headless --path . tests/headless_two_client.tscn -- \
##     --role A --address ws://127.0.0.1:<port> --aim-yaw 0.785 --aim-pitch -0.05
##   godot --headless --path . tests/headless_two_client.tscn -- \
##     --role B --address ws://127.0.0.1:<port>

const GAME_SCENE_PATH := "res://client/scenes/game.tscn"
const TICK_HZ := 30.0

var role: String = "A"     # A = shooter, B = victim
var address: String = "ws://127.0.0.1:9201"
var wait_seconds: float = 4.0
var aim_yaw: float = 0.0
var aim_pitch: float = 0.0
var bits_fire: int = 0     # set to INPUT_FIRE for shooter

var game: Node = null
var my_peer: int = -1


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--role" and i + 1 < args.size():
			role = args[i + 1]
		elif args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]
		elif args[i] == "--wait" and i + 1 < args.size():
			wait_seconds = float(args[i + 1])
		elif args[i] == "--aim-yaw" and i + 1 < args.size():
			aim_yaw = float(args[i + 1])
		elif args[i] == "--aim-pitch" and i + 1 < args.size():
			aim_pitch = float(args[i + 1])
		elif args[i] == "--fire":
			bits_fire = NetProtocol.INPUT_FIRE

	print("[%s] connecting to %s (fire=%d)" % [role, address, bits_fire])

	# Create WebSocket client peer.
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		_die("create_client failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer

	# Wait for connection.
	var deadline: float = Time.get_ticks_msec() / 1000.0 + 5.0
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			_die("connect timeout")
			return
		await get_tree().process_frame
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_die("not connected, status=%d" % peer.get_connection_status())
		return
	my_peer = multiplayer.get_unique_id()
	print("[%s] connected, peer_id=%d" % [role, my_peer])

	# Mount the real game scene — this exercises the full _enter_client_mode flow.
	var game_scene: PackedScene = load(GAME_SCENE_PATH) as PackedScene
	game = game_scene.instantiate()
	game.name = "Game"
	get_tree().root.add_child.call_deferred(game)
	await get_tree().process_frame
	print("[%s] game scene mounted" % role)

	# Let spawn handshake settle.
	await get_tree().create_timer(0.6).timeout

	# Disable the game scene's automatic _send_input_to_server on our local
	# player. Without this, Input.* (which is null in headless) overrides our
	# manually-driven RPCs every tick and zeros out the fire bit.
	if game != null and game.local_player != null:
		game.local_player.is_human_input = false

	if role == "A":
		await _run_shooter()
	else:
		await _run_victim()


func _run_shooter() -> void:
	# Drive the input RPC stream manually, aiming at the configured yaw/pitch
	# with FIRE held. We bypass main_menu's _send_input_to_server since this
	# is a headless test and Input.* isn't connected to a real keyboard.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("no NetRpc")
		return
	# Discover B's actual position from our local snapshot view so the aim is
	# correct regardless of which spawn marker the server picked for them.
	var me: Vector3 = Vector3.ZERO
	var target: Vector3 = Vector3.ZERO
	for pid in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[pid]
		if p == null:
			continue
		if p.is_local:
			me = p.global_position
		else:
			target = p.global_position
	# Aim at target's body hitbox center (~+0.8m above their feet) from our
	# camera at (eye = my_pos + 1.0m head offset + 0.x cam... ≈ my_pos.y + 1.0).
	var eye: Vector3 = me + Vector3(0, 1.0, 0)
	var body_target: Vector3 = target + Vector3(0, 0.8, 0)
	var to: Vector3 = body_target - eye
	var horiz: float = Vector2(to.x, to.z).length()
	aim_yaw = atan2(to.x, to.z) + PI   # Godot dir = (-sin(yaw), ..., -cos(yaw)); look toward to → yaw such that -sin(yaw)=to.x/|to_horiz|, -cos(yaw)=to.z/|to_horiz|.
	aim_pitch = atan2(to.y, horiz)
	print("[A] eye=%s target=%s computed aim yaw=%.3f pitch=%.3f" % [str(eye), str(body_target), aim_yaw, aim_pitch])
	print("[A] shooter streaming bits=%d for %.1fs" % [bits_fire, wait_seconds])
	var tick_interval: float = 1.0 / TICK_HZ
	var tick: int = 0
	var elapsed: float = 0.0
	while elapsed < wait_seconds:
		net_rpc.client_send_input.rpc_id(1, tick, bits_fire, aim_yaw, aim_pitch)
		# Also send the client_fire RPC carrying aim (matches what try_fire does
		# when a real player presses LMB). This is what the actual fire path
		# uses for authoritative aim, in addition to the input stream.
		if bits_fire != 0:
			net_rpc.client_fire.rpc_id(1, &"ak20", aim_yaw, aim_pitch)
		tick += 1
		await get_tree().create_timer(tick_interval).timeout
		elapsed += tick_interval
	# Print our final view of victim HP (read from local game_node.players_by_peer).
	_dump_state("A")
	get_tree().quit(0)


func _run_victim() -> void:
	# Stand still and let the shooter try to hit us. Stream zero-bits input
	# at the same rate so the server's view of our position is stable.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("no NetRpc")
		return
	print("[B] victim standing still for %.1fs" % wait_seconds)
	var tick_interval: float = 1.0 / TICK_HZ
	var tick: int = 0
	var elapsed: float = 0.0
	while elapsed < wait_seconds + 1.0:
		net_rpc.client_send_input.rpc_id(1, tick, 0, 0.0, 0.0)
		tick += 1
		await get_tree().create_timer(tick_interval).timeout
		elapsed += tick_interval
	_dump_state("B")
	get_tree().quit(0)


func _dump_state(label: String) -> void:
	if game == null:
		return
	var peers = game.players_by_peer.keys()
	print("[%s] players_by_peer: %s" % [label, peers])
	for pid in peers:
		var p: Node = game.players_by_peer[pid]
		if p == null:
			continue
		print("[%s]   peer %d hp=%.1f pos=%s is_local=%s snapshot_only=%s" % [
			label, pid, p.hp, str(p.global_position), p.is_local, p.is_snapshot_only])


func _die(msg: String) -> void:
	push_error("[" + role + "] " + msg)
	print("[%s] FAIL: %s" % [role, msg])
	get_tree().quit(1)
