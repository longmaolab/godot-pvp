extends SceneTree
## Indirect verification that the HitMarker tofu fix actually works.
##
## User reported "命中后 NPC 周围蹦出 4 个 tofu 块" — turned out to be
## HUD's HitMarker (4 corner Labels with ╲ ╱ ╱ ╲ box-drawing chars). The
## fix was project.godot gui/theme/custom = pvp_theme.tres so all Labels
## inherit the theme's default_font (ui_font.tres = RussoOne + NotoSansSC
## subset which contains U+2571 and U+2572).
##
## Chrome MCP at "read" tier can't click PRACTICE to fire a shot, so
## we verify the data-side preconditions instead:
##   1. project.godot has gui/theme/custom set
##   2. The themed font's cmap contains the HitMarker glyphs
##   3. hud.tscn instantiates and the HitMarker Labels' resolved theme
##      font is the one we expect (not the engine fallback).
##
## Run: bash tests/run_hud_font_inheritance_test.sh

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# --- 1. project setting wired
	var theme_path: String = ProjectSettings.get_setting("gui/theme/custom", "")
	_expect(theme_path == "res://assets/themes/pvp_theme.tres",
		"gui/theme/custom expected pvp_theme.tres, got '%s'" % theme_path)

	# --- 2. the project theme has the expected default font
	var proj_theme: Theme = load(theme_path) as Theme
	_expect(proj_theme != null, "project theme failed to load: %s" % theme_path)
	var default_font: Font = proj_theme.default_font if proj_theme != null else null
	_expect(default_font != null, "project theme has no default_font")

	# --- 3. instantiate hud.tscn and verify HitMarker Labels resolve to
	#       a font that's NOT the engine fallback (which is what causes tofu).
	var hud_scene: PackedScene = load("res://client/scenes/hud/hud.tscn")
	_expect(hud_scene != null, "hud.tscn failed to load")
	if hud_scene == null:
		_finish()
		return
	var hud: Node = hud_scene.instantiate()
	root.add_child(hud)
	await physics_frame

	# Walk the HitMarker corners; each should render its glyph through the
	# inherited theme. If theme inheritance is broken, get_theme_default_font
	# returns the engine fallback whose cmap lacks U+2571/U+2572.
	for corner_name in ["MarkTL", "MarkTR", "MarkBL", "MarkBR"]:
		var path: String = "Crosshair/HitMarker/%s" % corner_name
		var lbl: Label = hud.get_node_or_null(path)
		_expect(lbl != null, "HUD missing %s — scene structure changed?" % path)
		if lbl == null:
			continue
		# The corner label text is a single box-drawing char. Confirm it's
		# what we expect (not empty / not replaced with ASCII at some point).
		var ch: String = lbl.text
		_expect(ch in ["╲", "╱"], "%s text expected ╲ or ╱, got '%s'" % [corner_name, ch])
		# Get the resolved font that will actually render this label.
		var resolved: Font = lbl.get_theme_font(&"font", &"Label")
		_expect(resolved != null, "%s has no resolved theme font" % corner_name)
		# Crucial check: the resolved font must support the box-drawing glyphs.
		# get_char_size returns Vector2.ZERO when the glyph is missing.
		if resolved != null:
			var fs: int = lbl.get_theme_font_size(&"font_size", &"Label")
			if fs <= 0:
				fs = 16
			var sz: Vector2 = resolved.get_char_size(ch.unicode_at(0), fs)
			_expect(sz.x > 0.0,
				"%s glyph '%s' (U+%04X) missing in resolved font size %d — will tofu!" \
					% [corner_name, ch, ch.unicode_at(0), fs])

	hud.queue_free()
	await physics_frame
	_finish()


var _checks: int = 0
func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		failures.append(msg)


func _finish() -> void:
	if failures.is_empty():
		print("[hud-font] PASS — %d HUD font assertions held (HitMarker won't tofu)" % _checks)
		quit(0)
	else:
		for f in failures:
			print("[hud-font] FAIL — " + f)
		quit(1)
