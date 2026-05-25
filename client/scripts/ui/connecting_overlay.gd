extends CanvasLayer
class_name ConnectingOverlay
## Lightweight overlay shown while joining a server. Auto-hides when the local
## player materializes. On timeout/failure, swaps to an error state with a
## clickable "Back to menu" button so the user is never stuck.

@onready var spinner: Label = $Center/Card/V/Spinner
@onready var subtitle: Label = $Center/Card/V/Subtitle
@onready var back_button: Button = $Center/Card/V/BackButton

const SPINNER_FRAMES := ["◐", "◓", "◑", "◒"]
const TIMEOUT_SEC := 6.0
const MAIN_MENU_PATH := "res://client/scenes/main_menu.tscn"

var _frame: int = 0
var _elapsed: float = 0.0
var _timed_out: bool = false


func _ready() -> void:
	# PROCESS_MODE_ALWAYS so timeout + button still work if the SceneTree gets
	# paused (e.g. pause_menu opened mid-connect).
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	back_button.visible = false
	back_button.pressed.connect(_back_to_menu)


func show_connecting(address: String) -> void:
	subtitle.text = address
	visible = true
	_elapsed = 0.0
	_timed_out = false
	spinner.text = SPINNER_FRAMES[0]
	back_button.visible = false
	set_process(true)


func dismiss() -> void:
	visible = false
	set_process(false)


## Public: surface a connection failure immediately (skip the 6s wait).
func show_error(msg: String) -> void:
	visible = true
	_timed_out = true
	spinner.text = "✗"
	subtitle.text = msg
	back_button.visible = true
	set_process(true)
	# Make sure the cursor is usable for the button click.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	if Engine.get_process_frames() % 12 == 0 and not _timed_out:
		_frame = (_frame + 1) % SPINNER_FRAMES.size()
		spinner.text = SPINNER_FRAMES[_frame]
	if _timed_out:
		return
	_elapsed += delta
	if _elapsed >= TIMEOUT_SEC:
		show_error("无法连接 — 服务器没响应\n确认服务器在线，端口正确")


func _back_to_menu() -> void:
	if multiplayer.has_multiplayer_peer():
		var peer := multiplayer.multiplayer_peer
		if peer != null:
			peer.close()
		multiplayer.multiplayer_peer = null
	get_tree().change_scene_to_file(MAIN_MENU_PATH)
