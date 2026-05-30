extends Node
## Web idle frame-rate governor — caps render FPS to cut fan noise / heat.
##
## Root-cause fix for the recurring "fan spins up" problem: the browser tab
## was rendering at full speed (60–144 fps) even sitting in the menu or while
## tabbed away. That's pure wasted GPU/CPU → heat. We throttle hard when idle
## and only unlock during active gameplay.
##
##   tabbed away / unfocused → FPS_UNFOCUSED (barely ticking)
##   in menus (focused)      → FPS_MENU
##   active gameplay         → FPS_PLAY (60 on web, uncapped/vsync on desktop)
##
## No-op on the headless dedicated server — it has no window and needs its own
## fixed tick for 30Hz snapshots + physics.

const FPS_UNFOCUSED := 8
## Menu frame-rate is INPUT-AWARE. ROOT CAUSE (measured cleanly, single tab,
## per-PID): the heat is the per-frame WebGL render of the menu through ANGLE
## (GL→Metal) on macOS — it scales with FPS, NOT with canvas resolution or
## compositing. Proof: same tab, menu @30fps = 84% CPU, @~1fps (backgrounded)
## = 2.6%. Hiding the canvas or shrinking it to 0.05M px changed nothing; only
## drawing fewer frames did. (My earlier "fps doesn't help / it's the canvas"
## notes were measuring the WRONG Chrome process — a second game tab was open.)
##
## A static menu doesn't need a high frame-rate, so we idle it LOW and bump it
## back up the instant the user touches anything → cool when idle, responsive
## when used.
const FPS_MENU_ACTIVE := 30   # right after any input — smooth/responsive
const FPS_MENU_IDLE := 6      # no input for a moment — the heat win
const MENU_IDLE_DELAY_MS := 700
const FPS_PLAY_WEB := 60      # gameplay needs the frames; left at 60
const FPS_PLAY_NATIVE := 0    # 0 = uncapped (let vsync rule) on desktop

var _focused: bool = true
var _playing: bool = false
var _enabled: bool = true
var _last_input_ms: int = 0


func _ready() -> void:
	# Skip on headless DS — capping its loop would throttle snapshots/physics.
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server"):
		_enabled = false
		set_process(false)
		set_process_input(false)
		return
	# Keep ticking even when the SceneTree is paused (pause menu) so we can
	# still react to focus changes while paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_apply()


func _notification(what: int) -> void:
	if not _enabled:
		return
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_focused = false
			_apply()
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_focused = true
			_apply()


## Game scenes call this: true on entering active play, false back in menus.
func set_playing(playing: bool) -> void:
	_playing = playing
	_apply()


func _input(_event: InputEvent) -> void:
	# Any input while sitting in the (focused) menu bumps us back to the
	# responsive frame-rate. Ignored during gameplay and when unfocused.
	if not _enabled or _playing or not _focused:
		return
	_last_input_ms = Time.get_ticks_msec()
	if Engine.max_fps != FPS_MENU_ACTIVE:
		Engine.max_fps = FPS_MENU_ACTIVE


func _process(_delta: float) -> void:
	# Drop the focused, idle menu to the low frame-rate after a brief grace
	# period. No-op during gameplay / when unfocused (those are set by _apply).
	if not _enabled or _playing or not _focused:
		return
	if Engine.max_fps == FPS_MENU_ACTIVE \
			and Time.get_ticks_msec() - _last_input_ms > MENU_IDLE_DELAY_MS:
		Engine.max_fps = FPS_MENU_IDLE


func _apply() -> void:
	if not _enabled:
		return
	if not _focused:
		Engine.max_fps = FPS_UNFOCUSED
	elif _playing:
		Engine.max_fps = FPS_PLAY_WEB if OS.has_feature("web") else FPS_PLAY_NATIVE
	else:
		# Enter the menu responsive; _process lowers it once the user stops.
		_last_input_ms = Time.get_ticks_msec()
		Engine.max_fps = FPS_MENU_ACTIVE
