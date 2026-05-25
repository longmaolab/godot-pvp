extends Node
## Headless test client. Connects to a running server, sends a hello, waits
## for the server_welcome RPC, then quits.
##
## Run:  godot --headless --path . tests/headless_client.tscn -- --address ws://127.0.0.1:7777
##
## Exit code 0 = received welcome, 1 = timed out or connection failed.

const CONNECT_TIMEOUT_SEC := 5.0
const WELCOME_TIMEOUT_SEC := 5.0

var got_welcome: bool = false
var net_rpc: Node


func _ready() -> void:
	var address: String = "ws://127.0.0.1:7777"
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]

	print("[client-test] connecting to %s" % address)

	net_rpc = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("NetRpc autoload missing")
		return
	net_rpc.server_welcome_received.connect(_on_welcome)

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		_die("create_client failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer

	# Wait for connection (peer_connected when our connection_id materializes).
	var deadline: float = Time.get_ticks_msec() / 1000.0 + CONNECT_TIMEOUT_SEC
	while multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			_die("connect timeout")
			return
		await get_tree().process_frame
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_die("not connected; status=%s" % multiplayer.multiplayer_peer.get_connection_status())
		return
	print("[client-test] connected; my id=%d" % multiplayer.get_unique_id())

	# Send hello.
	net_rpc.client_hello.rpc_id(1, "headless-test")
	print("[client-test] hello sent")

	# Wait for welcome (with timeout).
	deadline = Time.get_ticks_msec() / 1000.0 + WELCOME_TIMEOUT_SEC
	while not got_welcome:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			_die("welcome timeout")
			return
		await get_tree().process_frame

	print("[client-test] PASS — received welcome from server")
	get_tree().quit(0)


func _on_welcome(your_peer: int, server_tick: int) -> void:
	print("[client-test] server_welcome received: peer=%d tick=%d" % [your_peer, server_tick])
	got_welcome = true


func _die(msg: String) -> void:
	push_error("[client-test] FAIL: " + msg)
	print("[client-test] FAIL: %s" % msg)
	get_tree().quit(1)
