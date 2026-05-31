extends Node
## Regression test for the death → signal → HUD → respawn pipeline.
##
## Catches:
##   - died signal signature mismatch (HUD._on_died must accept killer arg)
##   - respawn() not actually resetting is_dead / visible / hp
##   - per-weapon ammo not refreshing on respawn

const PLAYER_SCENE := preload("res://shared/scenes/player.tscn")
const HUD_SCENE := preload("res://client/scenes/hud/hud.tscn")
const AK20 := preload("res://shared/data/weapons/ak20.tres")
const SG8 := preload("res://shared/data/weapons/sg8.tres")

var failed: int = 0


func _ready() -> void:
	print("\n=== death + respawn regression test ===")
	await _run_test()
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _run_test() -> void:
	# 1. Spawn player + HUD just like game_controller does.
	var p: Node = PLAYER_SCENE.instantiate()
	p.weapon_def = AK20
	p.loadout = [AK20, SG8] as Array[Resource]
	p.is_local = false   # don't read Input
	add_child(p)
	p.global_position = Vector3(0, 1, 0)

	var hud: Node = HUD_SCENE.instantiate()
	add_child(hud)
	hud.bind_player(p)

	await get_tree().process_frame
	if p.is_dead:
		_fail("player should not be dead on spawn")
		return

	# 2. Make sure HUD's _on_died signature accepts the new (killer) arg.
	# If it doesn't, this apply_damage → _die → died.emit(killer) chain crashes.
	var attacker_dummy: Node = Node.new()
	add_child(attacker_dummy)
	p.apply_damage(9999.0, attacker_dummy)
	await get_tree().process_frame
	if not p.is_dead:
		_fail("player should be dead after 9999 damage")
		return
	# NOTE (2026-05-30): _die() no longer hides the body instantly — the
	# corpse-drop feel feature (killcam-era) keeps the corpse VISIBLE for
	# CORPSE_LINGER (2.2s) playing the death anim, THEN hides it. So the
	# correct death-state invariant to assert immediately is `is_dead`, not
	# `visible`. We separately confirm the corpse DOES hide after the linger
	# below, so the eventual-invisibility guarantee is still covered.
	print("  [ok] died: is_dead set (corpse lingers ~%.1fs by design)" % p.get("CORPSE_LINGER"))
	# Wait out the corpse linger + a margin, confirm the body hides.
	await get_tree().create_timer(float(p.get("CORPSE_LINGER")) + 0.4).timeout
	if is_instance_valid(p) and p.is_dead and p.visible:
		_fail("corpse never hid after CORPSE_LINGER — drop-then-vanish broken")
		return
	print("  [ok] corpse hidden after linger window")

	# 3. Verify respawn restores state cleanly.
	# Pre-decrement ammo to confirm respawn refills it.
	p.ammo_in_mag = 5
	# Coverage: respawn() must EMIT ammo_changed (not just write the vars) so
	# the HUD ammo readout refreshes to the refilled count. If a future edit
	# drops the emit, the label would freeze at the pre-death count after
	# respawn (real ammo refilled, but readout looks empty until the next shot,
	# which would read as "重生不满弹 / 备弹没效果"). Watch the signal.
	var respawn_ammo_emit := {"mag": -1, "reserve": -1}
	p.ammo_changed.connect(func(m, r): respawn_ammo_emit.mag = m; respawn_ammo_emit.reserve = r)
	p.respawn(Vector3(7, 1, 0))
	if p.is_dead:
		_fail("respawn did not clear is_dead")
		return
	if not p.visible:
		_fail("respawn did not restore visibility")
		return
	if absf(p.hp - p.max_hp) > 0.01:
		_fail("respawn did not refill hp (got %.1f, expected %.1f)" % [p.hp, p.max_hp])
		return
	if p.ammo_in_mag != AK20.magazine:
		_fail("respawn did not refill AK20 mag (got %d, expected %d)" % [p.ammo_in_mag, AK20.magazine])
		return
	if respawn_ammo_emit.mag != AK20.magazine or respawn_ammo_emit.reserve != AK20.reserve:
		_fail("respawn did not emit ammo_changed with refilled values — HUD freezes at pre-death count (got %d/%d, expected %d/%d)" % [
			respawn_ammo_emit.mag, respawn_ammo_emit.reserve, AK20.magazine, AK20.reserve])
		return
	# Switch to SG-8 — its ammo state should ALSO be refilled by respawn.
	p.equip_slot(1)
	if p.ammo_in_mag != SG8.magazine:
		_fail("respawn did not refill SG-8 mag (got %d, expected %d)" % [p.ammo_in_mag, SG8.magazine])
		return
	print("  [ok] respawn restores hp + visibility + all-weapon ammo")

	# 4. Player can take damage and die again. The respawn handler grants a
	#    2.5s invincibility window; in production the kid genuinely benefits
	#    from this, but the test wants to exercise the damage path back-to-back
	#    so we end the window manually before the second damage call.
	p._invincible_until = 0.0
	p.apply_damage(9999.0, attacker_dummy)
	await get_tree().process_frame
	if not p.is_dead:
		_fail("second death did not register")
		return
	print("  [ok] death/respawn cycle is repeatable (after invincibility bypass)")


func _fail(msg: String) -> void:
	push_error("[death-respawn] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
