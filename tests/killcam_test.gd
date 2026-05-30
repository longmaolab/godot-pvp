extends Node
## Killcam (death replay) regression test — headless.
##
## Killcam had 8 commits / 5 bug-fixes (floating ghosts, asymmetric
## invisibility, wrong name tags, live-framing vs rewind). Zero automated
## coverage before this. This test locks in the two invariants that
## actually broke in production:
##
##   1. VISIBILITY RESTORE (bug 919d0f2 "B died once → permanently can't
##      see A"): after _stop_killcam(), EVERY living combatant must be
##      visible again. The killcam hides live bodies to show ghosts; a
##      leaked hide is the exact asymmetric-invisibility bug.
##   2. CAMERA + GHOST LIFECYCLE: _start_killcam creates a Camera3D +
##      ghost nodes; _stop_killcam must free them (no orphan cameras
##      stealing `current`, no ghost leak).
##
## Run:  godot --headless --path . tests/killcam_test.tscn

const GAME_SCENE := preload("res://client/scenes/game.tscn")

var failed: int = 0


func _ready() -> void:
	print("\n=== killcam regression test ===")
	await _run()
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _run() -> void:
	# Boot game in PRACTICE mode (no multiplayer peer → _enter_practice_mode
	# spawns local_player + a chase bot). That's the minimal real world with
	# both a victim (local_player) and a killer candidate (bot).
	var game: Node = GAME_SCENE.instantiate()
	game.name = "Game"
	# Defer — GameController._ready checks multiplayer.is_server() and the
	# tree is mid-setup during our _ready (same reason headless_two_client +
	# server/headless_main both call_deferred the game mount).
	get_tree().root.add_child.call_deferred(game)
	await get_tree().process_frame

	# Let practice mode spawn the player + bot and let _process fill the
	# killcam ring buffer (_record_kc_buffer needs >=2 frames before
	# _start_killcam will do anything).
	for _i in 90:
		await get_tree().process_frame
	await get_tree().create_timer(0.6).timeout

	if game.local_player == null or not is_instance_valid(game.local_player):
		_fail("practice mode never spawned local_player")
		game.queue_free()
		return
	print("  [ok] practice world up: local_player + %d bot(s)" % game.bots.size())

	# Need a killer node distinct from the victim. Use the practice bot.
	var killer: Node = null
	for b in game.bots:
		if b != null and is_instance_valid(b):
			killer = b
			break
	if killer == null:
		_fail("no bot to act as killer")
		game.queue_free()
		return

	# Confirm the ring buffer recorded frames (else _start_killcam no-ops and
	# this test would vacuously pass).
	var buf: Array = game.get("_kc_buffer")
	if buf == null or buf.size() < 2:
		_fail("killcam ring buffer didn't fill (size=%s) — _record_kc_buffer not running?" % (buf.size() if buf else "null"))
		game.queue_free()
		return
	print("  [ok] killcam ring buffer recorded %d frames" % buf.size())

	# ── Trigger killcam ─────────────────────────────────────────────────────
	game._start_killcam(killer)
	await get_tree().process_frame

	if not game._killcam_active:
		_fail("_start_killcam didn't activate (killer rejected?)")
		game.queue_free()
		return
	if game._killcam_cam == null or not is_instance_valid(game._killcam_cam):
		_fail("killcam camera not created")
	# At least one live body should be hidden while the reel plays.
	var any_hidden: bool = false
	if "_kc_hidden" in game and game._kc_hidden.size() > 0:
		any_hidden = true
	if not any_hidden:
		_fail("killcam hid no live bodies (ghosts would overlap real players)")
	var ghost_count: int = game._kc_ghosts.size() if "_kc_ghosts" in game else 0
	print("  [ok] killcam active: cam=%s ghosts=%d hidden=%d" % [
		is_instance_valid(game._killcam_cam), ghost_count, game._kc_hidden.size()])

	# Tick the reel a few frames (exercises _tick_killcam — the lerp/orbit path).
	for _i in 30:
		await get_tree().process_frame

	# ── Stop killcam → the critical invariant checks ────────────────────────
	game._stop_killcam()
	await get_tree().process_frame

	# 1. Visibility restore: every ALIVE player + bot visible again.
	var bad_hidden: Array = []
	for peer in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[peer]
		if p != null and is_instance_valid(p):
			var dead: bool = ("is_dead" in p) and p.is_dead
			if not dead and not p.visible:
				bad_hidden.append("player peer=%s" % peer)
	for b in game.bots:
		if b != null and is_instance_valid(b):
			var dead2: bool = ("is_dead" in b) and b.is_dead
			if not dead2 and not b.visible:
				bad_hidden.append("bot %s" % b.name)
	if bad_hidden.size() > 0:
		_fail("VISIBILITY LEAK after _stop_killcam (bug 919d0f2): %s" % str(bad_hidden))
	else:
		print("  [ok] all living combatants visible after killcam (no 919d0f2 leak)")

	# 2. Camera + ghost teardown.
	if game._killcam_cam != null and is_instance_valid(game._killcam_cam):
		_fail("killcam camera not freed on stop (orphan camera)")
	else:
		print("  [ok] killcam camera freed")
	# Ghosts queue_free'd — give a frame, then count valid ones.
	await get_tree().process_frame
	var live_ghosts: int = 0
	if "_kc_ghosts" in game:
		for g in game._kc_ghosts.values():
			if is_instance_valid(g):
				live_ghosts += 1
	if live_ghosts > 0:
		_fail("%d ghost(s) leaked after _stop_killcam" % live_ghosts)
	else:
		print("  [ok] ghosts cleared")

	# 3. View handed back to the local player's camera (no black screen).
	if game.local_player != null and is_instance_valid(game.local_player) \
			and game.local_player.camera != null:
		if not game.local_player.camera.current:
			_fail("local player camera not current after killcam (black screen risk)")
		else:
			print("  [ok] view handed back to local player camera")

	game.queue_free()
	await get_tree().process_frame


func _fail(msg: String) -> void:
	push_error("[killcam] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
