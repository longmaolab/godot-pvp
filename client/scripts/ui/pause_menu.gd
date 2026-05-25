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


func _ready() -> void:
	resume_btn.pressed.connect(_on_resume)
	menu_btn.pressed.connect(_on_main_menu)
	quit_btn.pressed.connect(_on_quit)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		resume_btn.grab_focus()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_resume() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_main_menu() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	get_tree().change_scene_to_file(MAIN_MENU_PATH)


func _on_quit() -> void:
	get_tree().quit()
