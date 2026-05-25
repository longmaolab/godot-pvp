extends SceneTree
## EXACT host-mode physics test. User reports walking through walls in
## HOST mode (local listen-server, full local physics). My previous tests
## used use_remote_input=true which takes a DIFFERENT _physics_process
## branch. This one takes the SAME branch as the user's HOST player:
##   is_local=true, is_human_input=true, no use_remote_input.
##
## Drives input via Input.action_press("move_back") to simulate keyboard.

const PLAYER_SCENE := "res://shared/scenes/player.tscn"
const MAP_SCENE := "res://shared/scenes/maps/trenches.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# blank.tscn boundary wall WallNorth at (0, 2, -30), size (60, 4, 1).
	# North face at z=-30.5, south face at z=-29.5.
	var map: Node = (load(MAP_SCENE) as PackedScene).instantiate()
	root.add_child(map)
	await physics_frame
	await physics_frame

	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	# EXACT host-mode config — what _local_spawn does for the local player.
	p.is_local = true
	p.is_human_input = true
	# Critical: human-input path reads from InputMap, which requires actions
	# registered. The InputSetup autoload normally does this on project boot,
	# but a SceneTree-mode test doesn't run autoloads → register manually.
	_ensure_input_actions()
	root.add_child(p)
	# Trenches: GroundN spans z in [-35, -5], TrenchN_Front at z=-5.5 (north
	# face -6). Spawn at z=-8 (on GroundN), walk SOUTH (+Z) toward wall.
	p.global_position = Vector3(0.0, 1.0, -8.0)
	await physics_frame
	await physics_frame

	# Walk north (toward wall at z=-30) via "move_forward" action.
	# In FPS convention, forward = -Z when yaw=0. Player spawned facing yaw=0
	# means basis.z = +Z (Godot convention) → "forward" input maps to -Z.
	# move_back = +Z = south (toward trench wall at z=-6)
	Input.action_press(&"move_back")
	var samples: Array[String] = []
	for i in range(180):  # 3s
		await physics_frame
		if i % 20 == 0:
			samples.append("t=%.2fs z=%.3f y=%.3f" % [i/60.0, p.global_position.z, p.global_position.y])
	Input.action_release(&"move_back")
	var final: Vector3 = p.global_position

	print("[host-wall] samples: %s" % str(samples))
	print("[host-wall] final pos=%s" % str(final))

	# TrenchN_Front north face at z=-6. Player walks +Z direction, blocked
	# at z = -6 - 0.35 = -6.35. Through-wall = z > -5 (past south face).
	var passed_through: bool = final.z > -5.0
	if passed_through:
		print("[host-wall] FAIL — walked THROUGH trench wall: final z=%.3f (wall is z=-6 to -5)" % final.z)
		quit(1)
	else:
		print("[host-wall] PASS — blocked at z=%.3f (expected near -6.35)" % final.z)
		quit(0)


func _ensure_input_actions() -> void:
	# Mirror InputSetup autoload registrations for the keys we need.
	for spec in [
			[&"move_forward", KEY_W],
			[&"move_back", KEY_S],
			[&"move_left", KEY_A],
			[&"move_right", KEY_D],
			[&"jump", KEY_SPACE],
			[&"sprint", KEY_SHIFT],
		]:
		var name: StringName = spec[0]
		var key: int = spec[1]
		if not InputMap.has_action(name):
			InputMap.add_action(name)
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(name, ev)
