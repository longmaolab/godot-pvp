extends SceneTree
## Regression: bots must ENGAGE on every map, including the dense new ones.
##
## Bug (2026-05-30): on crossfire / longshot / foundry bots "didn't fight back".
## Root cause — bots steered in a straight line toward the target with no
## obstacle avoidance, so they jammed against the first wall/crate/pillar
## between the two spawn corners and never reached line-of-sight to fire. The
## old maps rarely put cover dead-center on the spawn-to-spawn line, so it never
## showed. Fix: whisker-ray avoidance + a stuck-escape in bot_brain.
##
## This spawns a bot at one spawn corner and a PATROLLING target across the map
## (a real player roams — they don't camp a corner behind a crate) and asserts
## the bot lands a shot within the timeout on each map.
##
## Run: bash tests/run_bot_map_engage_test.sh

const BOT_SCENE := "res://shared/scenes/bot.tscn"
const DUMMY_SCENE := "res://shared/scenes/dummy_target.tscn"
const AK20 := preload("res://shared/data/weapons/ak20.tres")
const TIMEOUT := 17.0

# map_path : [target_anchor, bot_spawn]
const CASES := {
	"res://shared/scenes/maps/blank.tscn":     [Vector3(0, 0, 0),  Vector3(0, 1, 15)],
	"res://shared/scenes/maps/crossfire.tscn": [Vector3(19, 0, 19), Vector3(-19, 1, -19)],
	"res://shared/scenes/maps/longshot.tscn":  [Vector3(42, 0, 13), Vector3(-42, 1, -13)],
	"res://shared/scenes/maps/foundry.tscn":   [Vector3(27, 0, 27), Vector3(-27, 1, -27)],
}

var failures: Array[String] = []
var checks_done: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for map_path in CASES:
		await _trial(map_path, CASES[map_path][0], CASES[map_path][1])
	_finish()


func _trial(map_path: String, anchor: Vector3, bot_pos: Vector3) -> void:
	var map: Node3D = (load(map_path) as PackedScene).instantiate()
	root.add_child(map)
	var dummy: Node = (load(DUMMY_SCENE) as PackedScene).instantiate()
	root.add_child(dummy)
	dummy.global_position = anchor

	var bot: Node = (load(BOT_SCENE) as PackedScene).instantiate()
	bot.weapon_def = AK20
	bot.is_local = false
	bot.is_human_input = false
	bot.target = dummy
	root.add_child(bot)
	bot.pursue_speed = 8.0
	bot.attack_range = 8.0
	bot._miss_chance = 0.0   # isolate navigation: no aim-RNG delaying the first hit
	bot.global_position = bot_pos
	bot.head_hitbox.monitoring = true
	bot.body_hitbox.monitoring = true

	var patrol_z: float = anchor.z * 0.6
	var patrol_amp: float = absf(anchor.x) * 0.85
	var hp_before: float = dummy.hp
	var elapsed: float = 0.0
	while elapsed < TIMEOUT and dummy.hp >= hp_before:
		await physics_frame
		elapsed += 1.0 / 60.0
		dummy.global_position = Vector3(patrol_amp * sin(elapsed * 0.9), anchor.y, patrol_z)

	var name: String = map_path.get_file().get_basename()
	if dummy.hp >= hp_before:
		failures.append("%s: bot never engaged a moving target in %.0fs — obstacle avoidance stalled." % [name, TIMEOUT])
	else:
		print("  [ok] %s — bot engaged in %.1fs" % [name, elapsed])
	checks_done += 1

	bot.queue_free(); dummy.queue_free(); map.queue_free()
	await physics_frame


func _finish() -> void:
	print("[bot-map-engage] %d maps checked" % checks_done)
	if failures.is_empty():
		print("  PASS — bots engage on every map (no obstacle-jam)")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
