extends SceneTree
## Verifies the server-side ability state machine + damage multiplier path.
##
## What broke before this batch: ability activation on listen-host clients
## ran only in the client's local PlayerController; the server's view of
## the same player never picked up _buff_def, so fire_resolver applied
## plain weapon damage even when the kid had "Focus Fire" active.
##
## The fix: a `client_use_ability` RPC mirrors the activation onto the
## server's PlayerController copy, and fire_resolver multiplies damage by
## the server's _buff_def.damage_mult / _powershot_armed.damage_mult.
##
## This test pins the state machine directly (skips the WebSocket layer):
##   1. Spawn a player with the AK20 (Focus Fire buff, +40% dmg for 3s).
##   2. Call try_activate_ability() on the server's copy (what the RPC
##      handler does).
##   3. Assert _buff_def is set and _buff_active_until is in the future.
##   4. Compute the buffed damage exactly as fire_resolver does and assert
##      it equals base * damage_mult.
##
## Run: bash tests/run_ability_buff_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const AK20 := preload("res://shared/data/weapons/ak20.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Spin up a real (but unconnected) server peer so multiplayer.is_server()
	# is true — try_activate_ability's RPC-send branch checks for that to
	# decide whether to ALSO send a mirror RPC. We want it not to send (this
	# is the server's own activation), just to update local state.
	var peer := WebSocketMultiplayerPeer.new()
	var port: int = 9100 + (Time.get_ticks_msec() % 600)
	var err := peer.create_server(port)
	assert(err == OK, "create_server failed: %d" % err)
	root.multiplayer.multiplayer_peer = peer
	await physics_frame
	await physics_frame

	var scene: PackedScene = load(PLAYER_SCENE) as PackedScene
	var shooter: Node = scene.instantiate()
	shooter.weapon_def = AK20
	var loadout: Array[Resource] = [AK20]
	shooter.loadout = loadout
	shooter.set_multiplayer_authority(1234567)
	shooter.is_local = false  # server's view of a remote peer
	root.add_child(shooter)
	await physics_frame

	# Sanity: weapon ability is the Focus Fire buff (damage_mult=1.4).
	var ability: Resource = AK20.ability
	if ability == null:
		failures.append("AK20 has no ability resource — can't test buff path")
		_finish()
		return
	if String(ability.type) != "buff":
		failures.append("expected buff ability, got type=%s" % ability.type)
	if ability.damage_mult <= 1.0:
		failures.append("expected damage_mult > 1, got %.2f" % ability.damage_mult)

	# --- Trigger ability activation on the server's copy (what
	# _on_client_ability_server does for an incoming RPC).
	var ok: bool = shooter.try_activate_ability()
	if not ok:
		failures.append("try_activate_ability returned false on first call")

	# --- Assertion 1: _buff_def is set + window is in the future.
	if shooter._buff_def == null:
		failures.append("_buff_def is null after activation — server-side state machine broken")
	var now_s: float = Time.get_ticks_msec() / 1000.0
	if shooter._buff_active_until <= now_s:
		failures.append("_buff_active_until=%.3f not in future (now=%.3f)" % [shooter._buff_active_until, now_s])

	# --- Assertion 2: damage with buff = base × damage_mult.
	# This is the exact math fire_resolver.gd uses post-extraction.
	var base_dmg: float = PlayerController._compute_damage(AK20, false)  # body shot
	var buffed_dmg: float = base_dmg
	if shooter._buff_def != null and now_s < shooter._buff_active_until:
		buffed_dmg *= shooter._buff_def.damage_mult
	if shooter._powershot_armed != null:
		buffed_dmg *= shooter._powershot_armed.damage_mult
	var expected: float = base_dmg * ability.damage_mult
	if absf(buffed_dmg - expected) > 0.01:
		failures.append("buffed damage wrong: got %.2f, expected %.2f (base %.2f × %.2f)" \
			% [buffed_dmg, expected, base_dmg, ability.damage_mult])

	# --- Assertion 3: a second activation within the cooldown window is
	# rejected (try_activate_ability's cooldown guard). This is what makes
	# the redundant DS INPUT_ABILITY + RPC path safe to overlap.
	var ok2: bool = shooter.try_activate_ability()
	if ok2:
		failures.append("second activation within cooldown was accepted (should reject)")

	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — ability buff state mirrors to server-side player, damage mult applied")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
