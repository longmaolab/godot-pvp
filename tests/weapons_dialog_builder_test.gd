extends SceneTree
## Unit test for WeaponsDialogBuilder (P1-14 main_menu god-object split).
## Verifies the extracted pure-rendering helper actually builds weapon cards
## into a container and wires the upgrade callback, without needing the full
## main_menu scene / autoloads.

const Builder = preload("res://client/scripts/ui/weapons_dialog_builder.gd")


func _init() -> void:
	var failures: Array[String] = []

	# Detached container — the builder only does add_child / queue_free on it,
	# which work without the node being in the scene tree.
	var container := VBoxContainer.new()

	# Track upgrade-callback invocations to prove the wiring survives extraction.
	var upgrade_calls: Array = []
	var on_upgrade := func(wid: String, stat: String, lvl: int):
		upgrade_calls.append([wid, stat, lvl])

	# settings=null exercises the offline path (upgrade levels render as 0).
	Builder.populate(container, null, on_upgrade)

	# --- 1. Cards were built (one per weapon .tres on disk)
	var card_count: int = container.get_child_count()
	if card_count < 5:
		failures.append("expected >=5 weapon cards, got %d" % card_count)

	# --- 2. Each card is a PanelContainer with nested content
	var first: Node = container.get_child(0) if card_count > 0 else null
	if first == null or not (first is PanelContainer):
		failures.append("first card is not a PanelContainer")

	# --- 3. Upgrade buttons exist + fire the callback. Find the first Button
	# anywhere in the first card's subtree and press it.
	var btn: Button = _find_button(first) if first != null else null
	if btn == null:
		failures.append("no upgrade Button found in first card")
	else:
		btn.pressed.emit()
		if upgrade_calls.is_empty():
			failures.append("upgrade button press did not invoke on_upgrade callback")
		elif upgrade_calls[0].size() != 3:
			failures.append("on_upgrade callback got wrong arg count: %s" % str(upgrade_calls[0]))

	# (Note: re-populate idempotency isn't asserted here — populate() uses
	# queue_free() to clear, which is deferred to the next frame. In the real
	# menu the dialog re-opens across frames so the old cards are gone by
	# then; testing it synchronously would just measure queue_free timing,
	# not the builder. This matches the pre-extraction behavior exactly.)

	if failures.is_empty():
		print("  PASS — WeaponsDialogBuilder builds %d cards, upgrade callback wired" % card_count)
		quit(0)
	else:
		for f in failures:
			print("  FAIL: %s" % f)
		quit(1)


func _find_button(node: Node) -> Button:
	if node is Button:
		return node
	for child in node.get_children():
		var found: Button = _find_button(child)
		if found != null:
			return found
	return null
