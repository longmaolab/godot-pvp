extends Control
class_name PrizeWheelPointer
## Fixed pointer that sits on top of the spinning PrizeWheel. Draws a downward
## triangle at the top-center, so the wedge it points at when the wheel stops is
## the winning segment. Does NOT rotate.

func _draw() -> void:
	var cx: float = size.x * 0.5
	var w: float = 14.0
	var h: float = 22.0
	var pts := PackedVector2Array([
		Vector2(cx - w, 0.0),
		Vector2(cx + w, 0.0),
		Vector2(cx, h),
	])
	# Drop shadow then the bright marker.
	var shadow := PackedVector2Array([
		Vector2(cx - w, 2.0), Vector2(cx + w, 2.0), Vector2(cx, h + 2.0),
	])
	draw_colored_polygon(shadow, Color(0, 0, 0, 0.5))
	draw_colored_polygon(pts, Color(1.0, 0.86, 0.28))
	draw_polyline(PackedVector2Array([pts[0], pts[2], pts[1]]), Color(1, 1, 1, 0.9), 2.0, true)
