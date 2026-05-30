extends CanvasLayer
## Lightweight perf HUD for diagnosing the web CPU/fan problem.
##
## Shows the RENDERER-INDEPENDENT numbers that pinpoint the bottleneck on the
## single-threaded WASM main thread (the thing pegging a core in BOTH Chrome
## and Safari):
##   FPS        — is the frame-rate cap actually taking effect? If FPS already
##                sits below the cap, the game is CPU-saturated and capping does
##                nothing — the per-frame work must shrink instead.
##   draw calls — high (>1500) => draw-call submission is the cost (batching /
##                fewer objects / CSG bake).
##   physics ms — high (>8ms)  => physics is the cost (CSG colliders → static
##                bake). Resolution scaling can NEVER help this.
##   process ms — high         => game logic / script cost.
##
## Toggle: F3. Hidden by default — press F3 to show (dev diagnostic only).
## Autoloaded → available on BOTH the menu and in-match.

var _label: Label
var _accum: float = 0.0

func _ready() -> void:
	layer = 200                                   # above everything
	process_mode = Node.PROCESS_MODE_ALWAYS       # keep updating even if paused
	_label = Label.new()
	_label.add_theme_color_override(&"font_color", Color(0.55, 1.0, 0.72))
	_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override(&"outline_size", 6)
	_label.add_theme_font_size_override(&"font_size", 15)
	_label.position = Vector2(12, 10)
	# Hidden by default — players must never see it. Was on-by-default-on-web
	# during the 2026-05-30 fan/CPU diagnosis (now concluded); F3 reveals it for dev.
	_label.visible = false
	add_child(_label)
	_refresh()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_F3:
		_label.visible = not _label.visible

func _process(delta: float) -> void:
	if not _label.visible:
		return
	_accum += delta
	if _accum < 0.25:                             # update 4×/sec, not every frame
		return
	_accum = 0.0
	_refresh()

func _refresh() -> void:
	var P := Performance
	var cap: int = Engine.max_fps
	var cap_str: String = (str(cap) if cap > 0 else "∞")
	_label.text = "FPS %d  (cap %s)\ndraw calls %d   objects %d\nphysics %.1f ms   process %.1f ms\nvideo %.0f MB" % [
		Engine.get_frames_per_second(),
		cap_str,
		int(P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(P.get_monitor(P.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		P.get_monitor(P.TIME_PHYSICS_PROCESS) * 1000.0,
		P.get_monitor(P.TIME_PROCESS) * 1000.0,
		P.get_monitor(P.RENDER_VIDEO_MEM_USED) / 1048576.0,
	]
