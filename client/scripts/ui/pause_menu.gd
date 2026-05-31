extends CanvasLayer
class_name PauseMenu
## Menu shown when you press Esc. Releases the mouse (so the user can click
## buttons) but DOES NOT pause the SceneTree — arena-shooter-3d does the
## same. In multiplayer the server keeps simulating regardless, and pausing
## the local tree leaves the client desynced + prone to stuck states. The
## game keeps running underneath the menu; pressing Esc / Resume / clicking
## the world just toggles mouse capture.

const MAIN_MENU_PATH := "res://client/scenes/main_menu.tscn"

@onready var resume_btn: Button = $Center/Card/V/ResumeBtn
@onready var menu_btn: Button = $Center/Card/V/MenuBtn
@onready var quit_btn: Button = $Center/Card/V/QuitBtn

# Track the previous mouse mode so we can detect the CAPTURED→VISIBLE edge.
# On web, ESC first gets eaten by the browser to release pointer lock — we
# never see that key event. Polling for the mode flip lets us still open the
# pause menu on the SAME first press, matching native FPS UX.
var _last_mouse_mode: int = Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	resume_btn.pressed.connect(_on_resume)
	menu_btn.pressed.connect(_on_main_menu)
	quit_btn.pressed.connect(_on_quit)
	# On web `get_tree().quit()` is a no-op (can't close a browser tab), so the
	# Quit button just looked broken when clicked. Hide it there — "回主菜单 /
	# Main Menu" is the web "exit" (leaves the match cleanly). Native keeps Quit.
	if OS.has_feature("web"):
		quit_btn.visible = false
	# Initialize from current state so the very first tick doesn't see a
	# spurious CAPTURED→VISIBLE transition during scene load.
	_last_mouse_mode = Input.mouse_mode


func _process(_delta: float) -> void:
	var mode: int = Input.mouse_mode
	# Auto-open on mouse-loss: pointer lock released by browser, alt-tab,
	# cmd-tab — anything that breaks capture should land in the pause menu
	# instead of leaving the player in a "Click to resume" limbo.
	if not visible \
			and _last_mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and mode == Input.MOUSE_MODE_VISIBLE \
			and not DisplayServer.is_touchscreen_available():
		_open()
	# Auto-close on mouse-recapture: PlayerController grabs the mouse when
	# the user clicks in the world (player_controller.gd:251-256). If the
	# menu is up at that moment, the click should also dismiss the menu.
	elif visible \
			and _last_mouse_mode == Input.MOUSE_MODE_VISIBLE \
			and mode == Input.MOUSE_MODE_CAPTURED:
		visible = false
	_last_mouse_mode = mode


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	if visible:
		visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		_open()


func _open() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	resume_btn.grab_focus()


func _on_resume() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_main_menu() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	# Belt-and-suspenders: release the cursor before the scene swap so the
	# new main_menu shows up clickable. main_menu._ready also resets this,
	# but doing it here avoids any single-frame window of captured mouse.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MAIN_MENU_PATH)


func _on_quit() -> void:
	get_tree().quit()
