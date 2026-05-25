extends SceneTree
## Verifies the menu's staging-lobby state machine — the "click HOST,
## wait for joiners, click START" path that replaced the old
## "click HOST → straight into game" flow.
##
## Single-process: stands up the main_menu scene, drives the state
## machine via the same public methods the buttons call, and asserts
## panel visibility + button enable state at each step. Doesn't spin
## up a real WebSocket (that path is exercised manually by running
## two godot instances); this is the unit-level "does the UI flip
## correctly" check.
##
## Run: bash tests/run_staging_lobby_test.sh

const MAIN_MENU := "res://client/scenes/main_menu.tscn"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: PackedScene = load(MAIN_MENU)
	if scene == null:
		failures.append("could not load main_menu.tscn")
		_finish()
		return
	var menu: Node = scene.instantiate()
	root.add_child(menu)
	await physics_frame
	await physics_frame

	# --- Baseline: nothing in staging, panel hidden, entry buttons visible.
	if menu.staging_panel.visible:
		failures.append("staging_panel visible before HOST/JOIN clicked")
	if not menu.host_btn.visible or not menu.join_btn.visible or not menu.practice_btn.visible:
		failures.append("entry buttons hidden before staging started")
	if menu._is_staging:
		failures.append("_is_staging true before HOST/JOIN")

	# --- Enter staging as host. Direct call mirrors what _on_host does
	# after a successful create_server (we skip the real peer here).
	menu._enter_staging(true)
	await physics_frame
	if not menu.staging_panel.visible:
		failures.append("staging_panel not visible after _enter_staging(true)")
	if not menu.start_btn.visible:
		failures.append("START button hidden when staging as host")
	if not menu._is_host:
		failures.append("_is_host false after _enter_staging(true)")
	if menu._peer_count != 1:
		failures.append("_peer_count = %d after entering staging, expected 1" % menu._peer_count)
	# In the new design HOST/PRACTICE/JOIN aren't disabled — they're
	# hidden entirely so START is the only primary action visible.
	if menu.host_btn.visible or menu.practice_btn.visible or menu.join_btn.visible:
		failures.append("entry buttons (PRACTICE/HOST/JOIN) still visible during staging — should be hidden so START is the only call to action")

	# --- Simulate a peer connecting (host side).
	menu._on_peer_connected_staging(99999)
	if menu._peer_count != 2:
		failures.append("_peer_count = %d after peer_connected, expected 2" % menu._peer_count)
	if not menu.staging_count.text.contains("2"):
		failures.append("staging_count text didn't update to show 2 players: %s" % menu.staging_count.text)

	# --- Peer disconnect.
	menu._on_peer_disconnected_staging(99999)
	if menu._peer_count != 1:
		failures.append("_peer_count = %d after peer_disconnected, expected 1" % menu._peer_count)

	# --- Cancel → back to normal menu state.
	menu._on_cancel_staging()
	await physics_frame
	if menu.staging_panel.visible:
		failures.append("staging_panel still visible after cancel")
	if not menu.host_btn.visible or not menu.join_btn.visible or not menu.practice_btn.visible:
		failures.append("entry buttons (PRACTICE/HOST/JOIN) still hidden after cancel — should be restored")
	if menu._is_staging:
		failures.append("_is_staging still true after cancel")

	# --- Enter as JOIN-side client. START should be hidden.
	menu._enter_staging(false)
	await physics_frame
	if menu.start_btn.visible:
		failures.append("START button visible when staging as client (should be host-only)")
	if menu._is_host:
		failures.append("_is_host true after _enter_staging(false)")

	# --- The "connected to host" status update.
	menu._on_connected_to_host_staging()
	if not menu.staging_status.text.contains("等房主"):
		failures.append("client status didn't update on connect: %s" % menu.staging_status.text)

	# --- Cleanup
	menu._exit_staging()
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("  PASS — staging lobby state machine transitions correctly")
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)
