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
const FPS_MENU := 10         # MEASURED root cause of the fan: the main menu's
                             # full-screen bg + ~874 translucent UI panels overdraw
                             # the 12.9M-px (5K, DPR2) canvas → GPU fill + compositor
                             # pegged ~81% CPU + 37% WindowServer at 20fps, while the
                             # menu's own CPU work is tiny (process 2.8ms, 185 draw
                             # calls). The menu is static, so 10fps halves the fill
                             # cost with no real interactivity loss. (In-game is only
                             # ~34% — opaque 3D has far less overdraw — so it stays 60.)
const FPS_PLAY_WEB := 60     # gameplay stays 60 until the perf overlay proves the
                             # machine can't sustain it (capping below the actual
                             # frame-rate does nothing but hurt feel)
const FPS_PLAY_NATIVE := 0   # 0 = uncapped (let vsync rule) on desktop

var _focused: bool = true
var _playing: bool = false
var _enabled: bool = true


func _ready() -> void:
	# Skip on headless DS — capping its loop would throttle snapshots/physics.
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server"):
		_enabled = false
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


func _apply() -> void:
	if not _enabled:
		return
	if not _focused:
		Engine.max_fps = FPS_UNFOCUSED
	elif _playing:
		Engine.max_fps = FPS_PLAY_WEB if OS.has_feature("web") else FPS_PLAY_NATIVE
	else:
		Engine.max_fps = FPS_MENU
