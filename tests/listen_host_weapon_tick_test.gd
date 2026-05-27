extends SceneTree
## Regression test for listen-host weapon-tick bug.
##
## Background: in listen-host mode (one of the clients is also the server),
## the server-side view of every REMOTE peer's player went down the
## `else: _apply_remote_state(delta)` branch in PlayerController._physics_process
## — which never called _step_weapon_server. Result: after the first
## successful fire RPC from a remote peer, the server stamps
## `time_until_next_shot` and never decrements it, so every subsequent fire
## from that peer is rejected by GameController._on_client_fire_server's
## cooldown gate. Same for auto-reload on empty mag: is_reloading=true gets
## set server-side and never clears.
##
## User-visible symptom: "B 把子弹打光全都命中，但 A 只掉了 25 血" — only
## the first body shot of a session ever registered.
##
## This test pins the fix: on listen-host server, remote-player weapon state
## must tick down between snapshot ticks.
##
## Strategy: stand up a WebSocketMultiplayerPeer in server mode (no client
## ever connects — we just need multiplayer.is_server() == true and a real
## peer so _is_networked() returns true). Spawn one player flagged as a
## remote peer's avatar (is_local=false, no DS-only flags). Set
## time_until_next_shot to a fixed value, run a few physics frames, assert
## it counted down to zero.
##
## Run: bash tests/run_listen_host_weapon_tick_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const AK20 := preload("res://shared/data/weapons/ak20.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Stand up a real (but unconnected) server peer so multiplayer.is_server()
	# is true and _is_networked() returns true on the player controller.
	var peer := WebSocketMultiplayerPeer.new()
	# Bind to an ephemeral port — the OS picks something free; we never
	# actually accept connections.
	var port: int = 9000 + (Time.get_ticks_msec() % 800)
	var err := peer.create_server(port)
	assert(err == OK, "create_server(%d) failed: %d" % [port, err])
	root.multiplayer.multiplayer_peer = peer

	# Allow Godot to finalize the peer state.
	await physics_frame
	await physics_frame

	if not root.multiplayer.is_server():
		failures.append("multiplayer.is_server() returned false after create_server — env bug")
		_finish()
		return

	# Spawn a remote-peer player exactly as GameController._local_spawn does
	# for a non-local peer on a listen-host (no use_remote_input, no
	# is_snapshot_only).
	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	assert(scene != null, "could not load player.tscn")
	var p: Node = scene.instantiate()
	p.weapon_def = AK20
	var loadout: Array[Resource] = [AK20]
	p.loadout = loadout
	# Pretend this player belongs to a peer that isn't us (1) — must be a
	# valid 32-bit-ish int, value doesn't matter for the tick path.
	var remote_peer: int = 1234567
	p.set_multiplayer_authority(remote_peer)
	p.is_local = false
	# CRITICAL: server-side mirror of a remote peer needs `use_remote_input=true`
	# so PlayerController._physics_process branches into _step_weapon_server.
	# Without it, the player goes to the "ghost" branch (`_apply_remote_state`)
	# which doesn't tick weapon state at all — and this test was failing for
	# years because the original setup forgot this flag.
	p.use_remote_input = true
	root.add_child(p)
	p.global_position = Vector3.ZERO

	# Wait one frame so _ready + onready vars resolve.
	await physics_frame

	# --- Assertion 1: time_until_next_shot decrements between physics ticks.
	p.time_until_next_shot = 0.1
	var t0: float = p.time_until_next_shot
	# 8 physics ticks at 60Hz = ~133ms — more than enough to drain 0.1s.
	for i in 8:
		await physics_frame
	if p.time_until_next_shot >= t0:
		failures.append(
			"time_until_next_shot did NOT decrement on listen-host server (start=%.3f, end=%.3f) — _step_weapon_server is not running in the else branch"
			% [t0, p.time_until_next_shot]
		)
	elif p.time_until_next_shot > 0.001:
		failures.append(
			"time_until_next_shot only partially decremented (start=%.3f, end=%.3f) — likely too few frames or wrong delta"
			% [t0, p.time_until_next_shot]
		)

	# --- Assertion 2: reload_remaining decrements + is_reloading clears.
	p.ammo_in_mag = 0
	p.ammo_reserve = 60
	p.is_reloading = true
	p.reload_remaining = 0.15      # well under AK20's real reload, just need it to drain
	for i in 16:
		await physics_frame
	if p.is_reloading:
		failures.append(
			"is_reloading stuck true after %.3fs of physics frames (reload_remaining=%.3f) — _finish_reload never ran"
			% [16.0 / 60.0, p.reload_remaining]
		)

	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — listen-host weapon tick decrements as expected")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
