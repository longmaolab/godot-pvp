extends Node
## Frame-rate governor.
##
## IMPORTANT — WEB DOES NOT CAP. Measured root cause of the "fan spins on the
## menu" bug: on the single-threaded web (emscripten/WASM) build, capping with
## `Engine.max_fps` below the browser's requestAnimationFrame rate makes the
## main loop BUSY-WAIT (spin) to hit the target frame time, so it BURNS MORE
## CPU, not less.
##
## Clean, single-tab, per-PID measurements that pinned this down:
##   • godot-pvp menu capped to 6fps  → live renderer 85% CPU
##   • shrinking the canvas to 0.017M px (≈no rendering) → still 85% (so it is
##     NOT the rendering — it is the WASM main loop spinning)
##   • arena-shooter-3d menu, same engine/machine, uncapped → ~21%
##   • backgrounding the tab → 0% (the browser already throttles hidden tabs'
##     rAF for free, so we don't need to)
##
## So on web we leave Engine.max_fps = 0 (uncapped) and let the browser's rAF
## drive it: full rate while visible, auto-throttled when hidden/backgrounded.
##
## Native desktop is unaffected — there `Engine.max_fps` does a real sleep (no
## spin), so the idle/menu throttling below is a genuine power saving.
##
## No-op on the headless dedicated server (it has no window).

const FPS_UNFOCUSED := 8
const FPS_MENU_ACTIVE := 60
const FPS_MENU_IDLE := 10
const MENU_IDLE_DELAY_MS := 700
const FPS_PLAY_NATIVE := 0   # 0 = uncapped (let vsync rule) on desktop

var _focused: bool = true
var _playing: bool = false
var _enabled: bool = true
var _web: bool = false
var _last_input_ms: int = 0


func _ready() -> void:
	# Skip on headless DS — capping its loop would throttle snapshots/physics.
	if DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server"):
		_enabled = false
		set_process(false)
		set_process_input(false)
		return
	_web = OS.has_feature("web")
	# Keep ticking even when the SceneTree is paused (pause menu).
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _web:
		# Never cap on web (busy-wait). Disable the idle-watcher entirely and
		# leave max_fps uncapped; the browser handles hidden-tab throttling.
		set_process(false)
		set_process_input(false)
		Engine.max_fps = 0
		return
	_apply()


func _notification(what: int) -> void:
	if not _enabled or _web:
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
	if not _web:
		_apply()


func _input(_event: InputEvent) -> void:
	# Native-only menu idle watcher (web disables processing in _ready).
	if not _enabled or _playing or not _focused:
		return
	_last_input_ms = Time.get_ticks_msec()
	if Engine.max_fps != FPS_MENU_ACTIVE:
		Engine.max_fps = FPS_MENU_ACTIVE


func _process(_delta: float) -> void:
	if not _enabled or _playing or not _focused:
		return
	if Engine.max_fps == FPS_MENU_ACTIVE \
			and Time.get_ticks_msec() - _last_input_ms > MENU_IDLE_DELAY_MS:
		Engine.max_fps = FPS_MENU_IDLE


func _apply() -> void:
	if not _enabled or _web:
		return
	if not _focused:
		Engine.max_fps = FPS_UNFOCUSED
	elif _playing:
		Engine.max_fps = FPS_PLAY_NATIVE
	else:
		_last_input_ms = Time.get_ticks_msec()
		Engine.max_fps = FPS_MENU_ACTIVE
