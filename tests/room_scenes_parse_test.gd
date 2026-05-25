extends SceneTree
## Smoke test for the new lobby scenes — instantiates room_browser.tscn
## and room_lobby.tscn to make sure all @onready paths resolve (no
## typos in node names) and the scripts compile + run _ready() cleanly.
##
## This is the cheap pre-check before someone opens Godot and tries
## the UI manually. The state machine logic is covered by other tests.
##
## Run: bash tests/run_room_scenes_parse_test.sh

const BROWSER := "res://client/scenes/ui/room_browser.tscn"
const LOBBY := "res://client/scenes/ui/room_lobby.tscn"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for path in [BROWSER, LOBBY]:
		var scene: PackedScene = load(path)
		if scene == null:
			failures.append("failed to load %s" % path)
			continue
		var node: Node = scene.instantiate()
		if node == null:
			failures.append("failed to instantiate %s" % path)
			continue
		root.add_child(node)
		await physics_frame
		await physics_frame
		# Spot-check that the script's onready vars resolved by reading a
		# named UI node we know each scene must have.
		match path:
			BROWSER:
				if not ("room_list" in node) or node.room_list == null:
					failures.append("[browser] room_list onready missing or null")
				if not ("create_btn" in node) or node.create_btn == null:
					failures.append("[browser] create_btn onready missing or null")
				if not ("join_btn" in node) or node.join_btn == null:
					failures.append("[browser] join_btn onready missing or null")
			LOBBY:
				if not ("room_id_label" in node) or node.room_id_label == null:
					failures.append("[lobby] room_id_label onready missing or null")
				if not ("start_btn" in node) or node.start_btn == null:
					failures.append("[lobby] start_btn onready missing or null")
				if not ("player_list" in node) or node.player_list == null:
					failures.append("[lobby] player_list onready missing or null")
		node.queue_free()
		await physics_frame

	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — room_browser.tscn + room_lobby.tscn instantiate cleanly")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
