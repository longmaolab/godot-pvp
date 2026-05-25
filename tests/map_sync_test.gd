extends SceneTree
## Regression test for server-authoritative map sync.
##
## Bug: when JOIN was clicked from the menu, _launch_game() passed the
## JOIN-side user's locally-picked map into the GameController. Two
## players picking different maps would each render their own geometry
## while sharing server-authoritative positions — bullets pass through
## walls that don't exist on the shooter's side, spawns land inside
## obstacles, etc. Fix: server emits `server_map_info(map_path)` during
## the sync handshake and the client free/loads to match.
##
## What this test pins:
##   1. _on_server_map_info on a different path swaps map_root to the
##      new scene.
##   2. Same-path message is a no-op (no churn on duplicate sync).
##   3. Unknown / empty path is rejected without crashing.
##
## Run: bash tests/run_map_sync_test.sh

const GAME_SCRIPT := preload("res://client/scripts/game_controller.gd")
const BLANK_MAP := "res://shared/scenes/maps/blank.tscn"
const KOTH_MAP := "res://shared/scenes/maps/koth.tscn"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Build a minimal GameController-like host (we can't instantiate the full
	# game.tscn here because that pulls in the whole HUD + map; instead we
	# attach the script to a Node3D and only exercise the map-swap method).
	var game: Node3D = Node3D.new()
	game.set_script(GAME_SCRIPT)
	root.add_child(game)
	await physics_frame

	# Seed: pretend the client already loaded blank.tscn locally (matches the
	# real flow where _launch_game instantiates map_scene before connecting).
	var blank_scene: PackedScene = load(BLANK_MAP)
	game.map_root = blank_scene.instantiate()
	game.add_child(game.map_root)
	await physics_frame

	# --- Assertion 1: receiving a different-path message swaps the map.
	game._on_server_map_info(KOTH_MAP)
	await physics_frame
	if game.map_root == null:
		failures.append("map_root null after swap")
	elif game.map_root.scene_file_path != KOTH_MAP:
		failures.append("expected map_root path %s, got %s" % [KOTH_MAP, game.map_root.scene_file_path])

	# --- Assertion 2: receiving the same path is a no-op (no new instance).
	var same_node_id: int = game.map_root.get_instance_id()
	game._on_server_map_info(KOTH_MAP)
	await physics_frame
	if game.map_root == null:
		failures.append("map_root null after idempotent sync")
	elif game.map_root.get_instance_id() != same_node_id:
		failures.append("idempotent sync re-instantiated map (was %d, now %d)" \
			% [same_node_id, game.map_root.get_instance_id()])

	# --- Assertion 3: unknown/empty path is rejected, doesn't crash.
	# (Should just push_warning and return; map_root stays put.)
	var preserved_id: int = game.map_root.get_instance_id()
	game._on_server_map_info("")
	game._on_server_map_info("res://shared/scenes/maps/nope_does_not_exist.tscn")
	await physics_frame
	if game.map_root == null:
		failures.append("map_root cleared by bad path — should be rejected, not destroyed")
	elif game.map_root.get_instance_id() != preserved_id:
		failures.append("bad-path message replaced map (was %d, now %d)" \
			% [preserved_id, game.map_root.get_instance_id()])

	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — map_root swaps on different-path, no-ops on same-path, rejects bad paths")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
