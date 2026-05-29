extends SceneTree
## Batch-1 feel test: death-anim corpse linger + dynamic crosshair bloom.
##
##   A. _die() no longer vanishes instantly — the corpse stays visible (playing
##      its death anim) for CORPSE_LINGER, then hides.
##   B. Respawning before the linger elapses keeps the player visible (the stale
##      hide timer must no-op once is_dead is false).
##   C. crosshair_spread() opens with movement + firing, tightens with ADS.
##
## Run: bash tests/run_feel_batch1_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# ── A. Corpse lingers then hides ────────────────────────────────────────
	var a: Node = await _spawn()
	a._die()
	if not a.is_dead:
		failures.append("A: _die didn't set is_dead")
	if not a.visible:
		failures.append("A: corpse hidden instantly — death anim never shows (should linger).")
	checks_done += 1
	await _wait(a.CORPSE_LINGER + 0.4)
	if a.visible:
		failures.append("A: corpse never hid after CORPSE_LINGER (%.1fs)." % a.CORPSE_LINGER)
	checks_done += 1

	# ── B. Respawn before linger keeps us visible ───────────────────────────
	var b: Node = await _spawn()
	b._die()
	await _wait(0.3)
	b.respawn(Vector3(0, 1, 0))
	if not b.visible or b.is_dead:
		failures.append("B: respawn didn't restore visible/alive")
	await _wait(b.CORPSE_LINGER + 0.3)   # past where the cancelled timer fires
	if not b.visible:
		failures.append("B: stale corpse-hide timer hid a respawned (living) player.")
	checks_done += 1

	# ── C. Crosshair bloom responds to state ────────────────────────────────
	var c: Node = await _spawn()
	c.velocity = Vector3.ZERO
	c._crosshair_kick = 0.0
	c._is_ads = false
	c._is_crouching = false
	var base: float = c.crosshair_spread()
	c.velocity = Vector3(12, 0, 0)
	var moving: float = c.crosshair_spread()
	if moving <= base:
		failures.append("C: crosshair didn't open while moving (%.2f vs base %.2f)." % [moving, base])
	checks_done += 1
	c.velocity = Vector3.ZERO
	c._crosshair_kick = 0.8
	var fired: float = c.crosshair_spread()
	if fired <= base:
		failures.append("C: crosshair didn't open after firing (%.2f vs base %.2f)." % [fired, base])
	checks_done += 1
	c._crosshair_kick = 0.0
	c.velocity = Vector3(12, 0, 0)
	c._is_ads = false
	var hip: float = c.crosshair_spread()
	c._is_ads = true
	var ads: float = c.crosshair_spread()
	if ads >= hip:
		failures.append("C: ADS didn't tighten the crosshair (ads %.2f vs hip %.2f)." % [ads, hip])
	checks_done += 1

	_finish()


func _spawn() -> Node:
	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.is_local = true
	p.is_human_input = false
	root.add_child(p)
	p.global_position = Vector3(0, 1, 0)
	await physics_frame
	return p


func _wait(t: float) -> void:
	var e: float = 0.0
	while e < t:
		await physics_frame
		e += 1.0 / 60.0


func _finish() -> void:
	print("[feel-batch1] %d checks" % checks_done)
	if failures.is_empty():
		print("  PASS — corpse lingers + hides, respawn cancels it, crosshair blooms/tightens")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
