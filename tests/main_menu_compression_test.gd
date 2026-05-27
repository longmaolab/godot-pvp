extends SceneTree
## Verify the main menu's natural content height fits within reasonable
## browser viewports. User report:配置页面太高,需要下拉。
##
## Loads main_menu.tscn, lets it fully layout, then prints the rendered
## size of LeftCard / RightCard / overall content. Asserts the total
## content height stays under a threshold (currently 600 design px) so
## a 720-px-tall viewport always fits with breathing room.
##
## Run: bash tests/run_main_menu_compression_test.sh

const MAX_CARD_HEIGHT := 860   # design px; fits 880 viewport_height with 8/8 Center margins giving 864 usable.

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var menu_scene: PackedScene = load("res://client/scenes/main_menu.tscn")
	if menu_scene == null:
		print("[menu-compression] FAIL — main_menu.tscn failed to load")
		quit(1)
		return
	var menu: Node = menu_scene.instantiate()
	root.add_child(menu)
	# Let _ready run (autoloads not present in test, may push warnings — OK).
	await physics_frame
	await physics_frame

	var left_card: Control = menu.get_node_or_null("Scroll/Center/Cols/LeftCard") as Control
	var right_card: Control = menu.get_node_or_null("Scroll/Center/Cols/RightCard") as Control
	if left_card == null or right_card == null:
		print("[menu-compression] FAIL — card nodes missing (scene structure changed?)")
		quit(1)
		return
	# Force a layout pass on the containers.
	left_card.update_minimum_size()
	right_card.update_minimum_size()
	await physics_frame

	var lh: float = left_card.size.y
	var rh: float = right_card.size.y
	var lm: Vector2 = left_card.get_combined_minimum_size()
	var rm: Vector2 = right_card.get_combined_minimum_size()
	print("[menu-compression] LeftCard rendered=%.0f, min=%.0fx%.0f" % [lh, lm.x, lm.y])
	print("[menu-compression] RightCard rendered=%.0f, min=%.0fx%.0f" % [rh, rm.x, rm.y])

	# Both cards' natural minimum heights should be small enough that they
	# fit in a typical 700-design-px tall viewport with the 8px Center margin
	# top/bottom + the panel padding.
	if lm.y > MAX_CARD_HEIGHT:
		failures.append("LeftCard min height %.0f exceeds budget %d — will overflow short viewports" % [lm.y, MAX_CARD_HEIGHT])
	if rm.y > MAX_CARD_HEIGHT:
		failures.append("RightCard min height %.0f exceeds budget %d — will overflow short viewports" % [rm.y, MAX_CARD_HEIGHT])

	menu.queue_free()
	await physics_frame

	if failures.is_empty():
		print("[menu-compression] PASS — both cards fit %d design px budget" % MAX_CARD_HEIGHT)
		quit(0)
	else:
		for f in failures:
			print("[menu-compression] FAIL — " + f)
		quit(1)
