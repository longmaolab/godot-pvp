extends Control
class_name PrizeWheel
## Segmented prize wheel drawn with _draw(). Equal-sized colored wedges (one per
## outcome), radial labels, a glowing rim + center hub. This node ROTATES (the
## shop tweens `rotation`); the fixed pointer is drawn by `PrizeWheelPointer`
## sitting on top, so it stays put while the wheel spins.
##
## Segment 0 is centered at the TOP (under the pointer) when rotation == 0, so
## `angle_for(i)` gives the rotation that lands segment i under the pointer.

var segments: Array = []        # Array of { "label": String, "color": Color }
var highlight: int = -1         # segment index to glow (the win), or -1
var _font: Font = ThemeDB.fallback_font


func set_segments(segs: Array) -> void:
	segments = segs
	pivot_offset = size * 0.5     # rotate around our own center
	queue_redraw()


func set_highlight(idx: int) -> void:
	highlight = idx
	queue_redraw()


# Wheel rotation (radians) that brings segment `i`'s center under the top
# pointer. Segment i is drawn centered at screen-angle (-PI/2 + i*seg); to move
# it to the pointer (-PI/2) the wheel must rotate by -i*seg.
func angle_for(i: int) -> float:
	if segments.is_empty():
		return 0.0
	return -float(i) * (TAU / float(segments.size()))


func _draw() -> void:
	var n: int = segments.size()
	if n == 0:
		return
	var c: Vector2 = size * 0.5
	var r: float = minf(size.x, size.y) * 0.5 - 6.0
	var seg: float = TAU / float(n)
	var arc_steps: int = 28
	for i in n:
		var mid: float = -PI * 0.5 + i * seg
		var a0: float = mid - seg * 0.5
		var a1: float = mid + seg * 0.5
		var base: Color = segments[i].get("color", Color(0.5, 0.5, 0.5))
		var col: Color = base.lightened(0.4) if i == highlight else base
		# Filled wedge (triangle fan from center).
		var pts := PackedVector2Array([c])
		for s in arc_steps + 1:
			var a: float = a0 + (a1 - a0) * float(s) / float(arc_steps)
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		draw_colored_polygon(pts, col)
		# Wedge edge line for crisp separation.
		draw_line(c, c + Vector2(cos(a0), sin(a0)) * r, Color(0, 0, 0, 0.4), 2.0)
		# Radial label, oriented along the wedge so it reads outward.
		var lbl: String = String(segments[i].get("label", ""))
		if not lbl.is_empty():
			var lp: Vector2 = c + Vector2(cos(mid), sin(mid)) * (r * 0.60)
			var fs: int = 15
			var tw: float = _font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			# Flip text on the lower half so it isn't upside-down.
			var ang: float = mid
			if cos(mid) < 0.0:
				ang += PI
			draw_set_transform(lp, ang, Vector2.ONE)
			draw_string(_font, Vector2(-tw * 0.5, fs * 0.35), lbl,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.96))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Glowing rim.
	draw_arc(c, r, 0.0, TAU, 72, Color(0.6, 0.85, 1.0, 0.9), 4.0, true)
	draw_arc(c, r + 3.0, 0.0, TAU, 72, Color(0.6, 0.85, 1.0, 0.25), 6.0, true)
	# Center hub.
	draw_circle(c, r * 0.16, Color(0.08, 0.10, 0.16))
	draw_arc(c, r * 0.16, 0.0, TAU, 36, Color(0.85, 0.92, 1.0, 0.7), 2.0, true)
