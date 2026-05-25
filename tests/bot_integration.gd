extends Node
## Verifies the AI bot actually:
##   1. Walks toward its target,
##   2. Aims, and
##   3. Fires + damages the target through the practice-mode local-hit path.
##
## Setup: spawn a bot far from a stationary dummy; assign dummy as bot.target.
## Wait several seconds and assert the dummy took damage.

const BOT_SCENE := preload("res://shared/scenes/bot.tscn")
const DUMMY_SCENE := preload("res://shared/scenes/dummy_target.tscn")
const MAP_SCENE := preload("res://shared/scenes/maps/blank.tscn")
const AK20 := preload("res://shared/data/weapons/ak20.tres")

var failed: int = 0
var completed: bool = false


func _ready() -> void:
	print("\n=== bot AI integration test ===")
	await _run_test()
	completed = true
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _run_test() -> void:
	var map: Node3D = MAP_SCENE.instantiate()
	add_child(map)

	var dummy: Node = DUMMY_SCENE.instantiate()
	add_child(dummy)
	dummy.global_position = Vector3(0, 0, 0)

	var bot: Node = BOT_SCENE.instantiate()
	bot.weapon_def = AK20
	bot.target = dummy
	add_child(bot)
	# Override the difficulty-tier defaults that _ready applies so the test
	# closes the distance quickly. After add_child the bot has finished _ready
	# and _apply_difficulty(); subsequent assignments stick.
	bot.pursue_speed = 8.0
	bot.attack_range = 8.0
	bot.global_position = Vector3(0, 1, 15)
	bot.head_hitbox.monitoring = true
	bot.body_hitbox.monitoring = true

	# Allow ~5 seconds: travel time + aim + fire (AK20 fires every 150ms).
	var hp_before: float = dummy.hp
	var elapsed: float = 0.0
	var timeout: float = 6.0
	while elapsed < timeout and dummy.hp >= hp_before:
		await get_tree().physics_frame
		elapsed += float(get_physics_process_delta_time())

	if dummy.hp >= hp_before:
		_fail("bot did not damage dummy in %.1fs (hp still %.1f)" % [timeout, dummy.hp])
		return
	print("  [ok] bot landed first shot in %.2fs (dummy hp %.1f → %.1f)" %
		[elapsed, hp_before, dummy.hp])

	# Continue for a couple more seconds — bot should pursue and keep shooting.
	var shots_landed: int = 1
	var t2: float = 0.0
	var prev_hp: float = dummy.hp
	while t2 < 3.0:
		await get_tree().physics_frame
		t2 += float(get_physics_process_delta_time())
		if dummy.hp < prev_hp:
			shots_landed += 1
			prev_hp = dummy.hp

	if shots_landed < 3:
		_fail("expected several follow-up hits, only got %d (final hp=%.1f)" %
			[shots_landed, dummy.hp])
		return
	print("  [ok] bot landed %d shots total (dummy hp final=%.1f)" % [shots_landed, dummy.hp])

	# Verify bot actually moved closer.
	var final_dist: float = bot.global_position.distance_to(dummy.global_position)
	if final_dist > 15.0:
		_fail("bot did not close distance (still %.1fm away)" % final_dist)
		return
	print("  [ok] bot closed distance to %.1fm" % final_dist)


func _fail(msg: String) -> void:
	push_error("[bot-test] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
