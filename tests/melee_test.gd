extends SceneTree
## Melee test (offline/practice authority path). A forward strike within
## MELEE_RANGE damages a target; out-of-range and behind miss; a second strike
## inside the cooldown does nothing.
##
## Run: bash tests/run_melee_test.sh

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const DUMMY_SCENE := "res://shared/scenes/dummy_target.tscn"

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	# No multiplayer peer in this bare tree → _is_networked() is false → melee
	# takes the offline authority (damage) branch.
	call_deferred("_run")


func _run() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = Vector3(40, 0.5, 40); fs.shape = box
	floor_body.add_child(fs); root.add_child(floor_body)
	floor_body.global_position = Vector3(0, -0.25, 0)

	# ── A. In-range front strike damages ────────────────────────────────────
	var atk: Node = await _spawn_attacker(Vector3(0, 1, 0))
	var d1: Node = await _spawn_dummy(Vector3(0, 1, -1.6))   # in front, within 2.6m
	var hp0: float = d1.hp
	atk.try_melee()
	await physics_frame
	if d1.hp >= hp0:
		failures.append("A: in-range melee dealt no damage (hp %.0f→%.0f)." % [hp0, d1.hp])
	checks_done += 1

	# ── B. Cooldown blocks an immediate second strike ───────────────────────
	var hp1: float = d1.hp
	atk.try_melee()
	await physics_frame
	if d1.hp < hp1:
		failures.append("B: second melee inside cooldown still hit (hp %.0f→%.0f)." % [hp1, d1.hp])
	checks_done += 1

	# ── C. Out of range misses ──────────────────────────────────────────────
	var atk2: Node = await _spawn_attacker(Vector3(10, 1, 0))
	var d2: Node = await _spawn_dummy(Vector3(10, 1, -5.0))   # 5m away > 2.6m
	var hp2: float = d2.hp
	atk2.try_melee()
	await physics_frame
	if d2.hp < hp2:
		failures.append("C: out-of-range target took melee damage (%.1fm away)." % 5.0)
	checks_done += 1

	# ── D. Behind misses ────────────────────────────────────────────────────
	var atk3: Node = await _spawn_attacker(Vector3(20, 1, 0))
	var d3: Node = await _spawn_dummy(Vector3(20, 1, 1.6))    # behind (+Z; attacker faces -Z)
	var hp3: float = d3.hp
	atk3.try_melee()
	await physics_frame
	if d3.hp < hp3:
		failures.append("D: target behind the attacker took melee damage.")
	checks_done += 1

	_finish("front dmg=%.0f, cooldown-held, out-of-range/behind missed" % (hp0 - d1.hp))


func _spawn_attacker(pos: Vector3) -> Node:
	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.is_local = true
	p.is_human_input = false
	root.add_child(p)
	p.global_position = pos
	await physics_frame
	p.set_aim(0.0, -0.08)   # face -Z, slight down so the ray meets the torso
	await physics_frame
	return p


func _spawn_dummy(pos: Vector3) -> Node:
	var d: Node = (load(DUMMY_SCENE) as PackedScene).instantiate()
	root.add_child(d)
	d.global_position = pos
	if "head_hitbox" in d and d.head_hitbox != null: d.head_hitbox.monitoring = true
	if "body_hitbox" in d and d.body_hitbox != null: d.body_hitbox.monitoring = true
	await physics_frame
	return d


func _finish(summary: String) -> void:
	print("[melee] %s" % summary)
	if failures.is_empty():
		print("  PASS — %d checks: strike hits in range, cooldown gates, range+arc respected" % checks_done)
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
