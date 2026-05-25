extends Node
## Extended HUD signal-regression test. death_respawn_test.gd covers the
## `died` signal signature; THIS test covers the other three HUD bindings:
##
##   - hp_changed   → hp_label.text + hp_bar.value
##   - ammo_changed → ammo_label.text
##   - weapon_switched → weapon_name_label.text
##
## What this catches: signal signature drift OR HUD label nodes renamed and
## not reconnected. Either silently breaks the game UI but doesn't crash
## the game scene.

const PLAYER_SCENE := preload("res://shared/scenes/player.tscn")
const HUD_SCENE := preload("res://client/scenes/hud/hud.tscn")
const AK20 := preload("res://shared/data/weapons/ak20.tres")
const SG8 := preload("res://shared/data/weapons/sg8.tres")

var failed: int = 0


func _ready() -> void:
	print("\n=== HUD signal regression test ===")
	await _run()
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _run() -> void:
	var p: Node = PLAYER_SCENE.instantiate()
	p.weapon_def = AK20
	p.loadout = [AK20, SG8] as Array[Resource]
	p.is_local = false
	add_child(p)
	p.global_position = Vector3.ZERO

	var hud: Node = HUD_SCENE.instantiate()
	add_child(hud)
	hud.bind_player(p)
	await get_tree().process_frame

	# 1. weapon_switched signal: bind_player calls _on_weapon_switched(AK20).
	# weapon_name_label should contain "AK20".
	var wn_text: String = hud.weapon_name_label.text
	if not ("AK20" in wn_text):
		_fail("weapon_name_label missing AK20 after initial bind: %s" % wn_text)
	else:
		print("  [ok] weapon_switched → weapon_name_label = '%s'" % wn_text)

	# 2. ammo_changed signal: emit a known ammo state and verify label.
	# bind_player only HOOKS the signal — it doesn't push initial values.
	# So we emit ammo_changed directly to verify the connection works.
	p.ammo_changed.emit(20, 90)
	await get_tree().process_frame
	if hud.ammo_label.text != "20 / 90":
		_fail("ammo_label expected '20 / 90', got '%s'" % hud.ammo_label.text)
	else:
		print("  [ok] ammo_changed → ammo_label = '%s'" % hud.ammo_label.text)

	# 3. hp_changed signal: apply 10 damage, verify hp_label + hp_bar.
	# (Bypass invincibility — _invincible_until defaults to 0, so this works.)
	var attacker_dummy: Node = Node.new()
	add_child(attacker_dummy)
	p.apply_damage(10.0, attacker_dummy)
	await get_tree().process_frame
	if absf(p.hp - 290.0) > 0.01:
		_fail("apply_damage: expected hp=290, got %.1f" % p.hp)
		return
	if not ("290" in hud.hp_label.text):
		_fail("hp_label after 10 dmg missing '290': '%s'" % hud.hp_label.text)
	else:
		print("  [ok] hp_changed → hp_label = '%s'" % hud.hp_label.text)
	if absf(hud.hp_bar.value - 290.0) > 0.01:
		_fail("hp_bar.value expected 290, got %.1f" % hud.hp_bar.value)
	else:
		print("  [ok] hp_changed → hp_bar.value = %.0f" % hud.hp_bar.value)

	# 4. weapon_switched signal at runtime: equip slot 1 (SG8) and re-check.
	p.equip_slot(1)
	await get_tree().process_frame
	if not ("SG-8" in hud.weapon_name_label.text or "SG8" in hud.weapon_name_label.text):
		_fail("weapon_name_label after equip_slot(1) missing SG-8: '%s'" % hud.weapon_name_label.text)
	else:
		print("  [ok] weapon_switched (runtime) → weapon_name_label = '%s'" % hud.weapon_name_label.text)

	# 5. low-HP color tier: hp_bar fill color should be RED at hp<30%.
	p.apply_damage(220.0, attacker_dummy)   # 290 → 70 (~23%)
	await get_tree().process_frame
	var fill: StyleBoxFlat = hud.hp_bar.get_theme_stylebox(&"fill") as StyleBoxFlat
	if fill != null:
		if fill.bg_color.r < 0.5 or fill.bg_color.g > 0.5:
			_fail("hp_bar fill should be RED at <30% HP, got %s" % str(fill.bg_color))
		else:
			print("  [ok] low-hp color tier (red) = %s" % str(fill.bg_color))
	else:
		print("  [warn] could not read hp_bar fill stylebox (not strictly a fail)")


func _fail(msg: String) -> void:
	push_error("[hud-signal] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
