extends Control
## Sniper scope overlay — a dark vignette framing a clear central circle with a
## fine reticle. Toggled visible by the HUD when the local player aims down the
## sights of a sniper-class weapon (the ADS FOV zoom does the magnification;
## this sells it as "looking through a scope").

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _draw() -> void:
	var vp: Vector2 = size
	var c: Vector2 = vp * 0.5
	var r: float = min(vp.x, vp.y) * 0.42         # clear scope radius
	var ring_w: float = max(vp.x, vp.y)           # thick enough to cover corners
	# Vignette: a very thick black ring whose inner edge is the scope circle, so
	# everything outside the circle (incl. corners) goes dark.
	draw_arc(c, r + ring_w * 0.5, 0.0, TAU, 64, Color(0, 0, 0, 0.93), ring_w, false)
	# Scope bezel.
	draw_arc(c, r, 0.0, TAU, 96, Color(0.04, 0.05, 0.07, 0.95), 5.0, true)
	# Fine reticle: crosshair with a center gap + dot.
	var col := Color(0.08, 0.1, 0.12, 0.9)
	draw_line(Vector2(c.x - r, c.y), Vector2(c.x - 7, c.y), col, 1.5)
	draw_line(Vector2(c.x + 7, c.y), Vector2(c.x + r, c.y), col, 1.5)
	draw_line(Vector2(c.x, c.y - r), Vector2(c.x, c.y - 7), col, 1.5)
	draw_line(Vector2(c.x, c.y + 7), Vector2(c.x, c.y + r), col, 1.5)
	draw_circle(c, 1.5, col)
