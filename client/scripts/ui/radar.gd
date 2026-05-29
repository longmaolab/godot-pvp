extends Control
## Proximity radar — a small top-down scope showing nearby players as dots,
## rotated so "up" is the local player's facing. Fed by game_controller each
## frame via set_blips(). Range-limited (set by the feeder) so it's situational
## awareness, not full-map omniscience.

const RADIUS := 56.0

# Each blip: { "x": float, "y": float, "enemy": bool } where x/y are -1..1
# (already in radar space: +x right, +y down = behind).
var _blips: Array = []


func _ready() -> void:
	custom_minimum_size = Vector2(RADIUS * 2.0, RADIUS * 2.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_blips(b: Array) -> void:
	_blips = b
	queue_redraw()


func _draw() -> void:
	var c := Vector2(RADIUS, RADIUS)
	draw_circle(c, RADIUS, Color(0.04, 0.07, 0.11, 0.55))
	draw_arc(c, RADIUS, 0.0, TAU, 40, Color(0.4, 0.78, 1.0, 0.45), 1.5, true)
	# Faint forward wedge so "up = where I'm looking" reads at a glance.
	draw_line(c, c + Vector2(0, -RADIUS), Color(0.4, 0.78, 1.0, 0.18), 1.0)
	# Local player — triangle pointing up at centre.
	var tri := PackedVector2Array([
		c + Vector2(0, -6), c + Vector2(-4, 4), c + Vector2(4, 4)])
	draw_colored_polygon(tri, Color(0.55, 0.95, 0.75, 0.95))
	for b in _blips:
		var p := c + Vector2(b.x, b.y) * (RADIUS - 4.0)
		var col: Color = Color(1.0, 0.35, 0.3, 0.95) if b.enemy else Color(0.4, 0.85, 1.0, 0.95)
		draw_circle(p, 3.0, col)
