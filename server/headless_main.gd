extends Node
## Server entry point.
## Launched via:  godot --headless -- --server [--port 7777] [--map MAP] [--seconds N]
##
## DS-M1: The server now instantiates a real GameController world (with map,
## physics, hit registration), not just the MatchAuthority stub. Clients
## connecting to this port will be spawned into THIS world by the server, and
## (in later milestones) the server will own simulation + snapshot broadcast.
##
## When NOT launched with --server, this script no-ops and the client UI
## (main_menu.tscn) takes over as normal.

## Both DS and the in-editor HOST button use 7777 — same as the JOIN placeholder.
## You can only run ONE at a time (port conflict). DS is the recommended path;
## HOST is a quick listen-host shortcut for local debugging.
const DEFAULT_PORT := 7777
const GAME_SCENE_PATH := "res://client/scenes/game.tscn"

# Default map for dedicated-server boot. Overridable via --map blank|battlefield|koth|trenches|skydock.
const MAP_PATHS := {
	"blank":       "res://shared/scenes/maps/blank.tscn",
	"battlefield": "res://shared/scenes/maps/battlefield.tscn",
	"koth":        "res://shared/scenes/maps/koth.tscn",
	"trenches":    "res://shared/scenes/maps/trenches.tscn",
	"skydock":     "res://shared/scenes/maps/skydock.tscn",
}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--server"):
		queue_free()
		return

	var port := DEFAULT_PORT
	var run_seconds: int = 0   # 0 = forever
	var map_id: String = "blank"
	var spawn_dummy: bool = false
	var test_kill_after: float = 0.0  # 0 = disabled (DS-M5 test only)
	var mode_path: String = ""        # empty = casual (no MatchController)
	var test_repeat_kill_interval: float = 0.0  # 0 = disabled (match-e2e test)
	for i in range(args.size()):
		if args[i] == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
		elif args[i] == "--seconds" and i + 1 < args.size():
			run_seconds = int(args[i + 1])
		elif args[i] == "--map" and i + 1 < args.size():
			map_id = args[i + 1]
		elif args[i] == "--dummy":
			spawn_dummy = true
		elif args[i] == "--test-kill-after" and i + 1 < args.size():
			test_kill_after = float(args[i + 1])
		elif args[i] == "--mode" and i + 1 < args.size():
			mode_path = "res://shared/data/modes/%s.tres" % args[i + 1]
		elif args[i] == "--test-repeat-kill-interval" and i + 1 < args.size():
			test_repeat_kill_interval = float(args[i + 1])

	print("[server] starting headless on port %d, map=%s" % [port, map_id])

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_error("[server] failed to bind port %d: %s" % [port, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer

	# Instantiate the actual game world. This boots GameController in
	# is_dedicated_server mode — no HUD, no local player, just authority.
	var game_scene: PackedScene = load(GAME_SCENE_PATH) as PackedScene
	if game_scene == null:
		push_error("[server] could not load %s" % GAME_SCENE_PATH)
		get_tree().quit(1)
		return
	var map_path: String = MAP_PATHS.get(map_id, MAP_PATHS["blank"])
	var map_scene: PackedScene = load(map_path) as PackedScene
	if map_scene == null:
		push_error("[server] could not load map %s" % map_path)
		get_tree().quit(1)
		return

	var game_root: Node = game_scene.instantiate()
	game_root.name = "Game"
	game_root.set("is_dedicated_server", true)
	game_root.set("map_scene", map_scene)
	game_root.set("spawn_dummy", spawn_dummy)
	if mode_path != "":
		var mode_def: Resource = load(mode_path)
		if mode_def == null:
			push_error("[server] could not load mode %s" % mode_path)
		else:
			game_root.set("mode_def", mode_def)
			print("[server] mode=%s" % mode_def.id)
	# Defer mount so multiplayer_peer is fully wired before GameController._ready
	# checks `multiplayer.is_server()`.
	get_tree().root.add_child.call_deferred(game_root)

	print("[server] ready — world mounted, awaiting peers (dummy=%s)" % spawn_dummy)

	# DS-M5 test hook: after the configured delay, deal lethal damage to the
	# first connected player. Lets the run_respawn_test.sh prove the server
	# detects death, schedules respawn, and broadcasts server_player_respawned.
	if test_kill_after > 0.0:
		print("[server] DS-M5 test: will kill first player after %.1fs" % test_kill_after)
		get_tree().create_timer(test_kill_after).timeout.connect(
			func():
				var g: Node = get_tree().root.get_node_or_null(^"Game")
				if g == null:
					push_warning("[server] kill: no Game node")
					return
				var pbp: Dictionary = g.get("players_by_peer")
				if pbp == null or pbp.is_empty():
					push_warning("[server] kill: no players to kill")
					return
				var first_id = pbp.keys()[0]
				var p: Node = pbp[first_id]
				if p != null and is_instance_valid(p) and p.has_method(&"apply_damage"):
					print("[server] DS-M5 test: dealing 9999 dmg to peer %d" % first_id)
					p.apply_damage(9999.0, null)
		)

	# Match-end E2E test hook: every N seconds, kill the FIRST connected
	# peer and credit the kill to the second peer. Drives MatchController
	# toward its kill-goal without depending on the (notoriously hard to
	# headlessly aim) fire-and-raycast pipeline.
	if test_repeat_kill_interval > 0.0:
		print("[server] match-e2e test: will kill peers[0] crediting peers[1] every %.1fs" % test_repeat_kill_interval)
		var timer := Timer.new()
		timer.wait_time = test_repeat_kill_interval
		timer.one_shot = false
		timer.autostart = true
		add_child(timer)
		timer.timeout.connect(
			func():
				var g: Node = get_tree().root.get_node_or_null(^"Game")
				if g == null:
					return
				var pbp: Dictionary = g.get("players_by_peer")
				if pbp == null or pbp.size() < 2:
					return
				var keys = pbp.keys()
				var victim: Node = pbp[keys[0]]
				var killer: Node = pbp[keys[1]]
				if victim == null or killer == null:
					return
				if not is_instance_valid(victim) or victim.is_dead:
					return
				# Bypass i-frame for the test helper so kills credit reliably.
				victim._invincible_until = 0.0
				victim.apply_damage(9999.0, killer)
		)

	if run_seconds > 0:
		# Used by integration tests so the server self-terminates.
		get_tree().create_timer(float(run_seconds)).timeout.connect(
			func():
				print("[server] auto-shutdown after %ds" % run_seconds)
				get_tree().quit(0)
		)
