extends SceneTree
## Damage falloff curve test. _falloff_mult must be 1.0 within falloff_start,
## ramp linearly to falloff_min_mult by falloff_end, and hold the floor beyond.
##
## Run: bash tests/run_falloff_test.sh

const FR := preload("res://server/scripts/fire_resolver.gd")
const AK20 := preload("res://shared/data/weapons/ak20.tres")

var failures: Array[String] = []


func _init() -> void:
	var w: Resource = AK20
	var s: float = w.falloff_start
	var e: float = w.falloff_end
	var m: float = w.falloff_min_mult

	_expect("point-blank", FR._falloff_mult(w, 1.0), 1.0)
	_expect("at start", FR._falloff_mult(w, s), 1.0)
	_expect("midpoint", FR._falloff_mult(w, (s + e) * 0.5), lerpf(1.0, m, 0.5))
	_expect("at end", FR._falloff_mult(w, e), m)
	_expect("beyond end", FR._falloff_mult(w, e + 50.0), m)
	# Monotonic non-increasing with distance.
	if FR._falloff_mult(w, s + 5.0) < FR._falloff_mult(w, e - 5.0):
		failures.append("falloff not monotonic decreasing")

	if failures.is_empty():
		print("  PASS — falloff full→min over [%.0f,%.0f]m, floor %.2f" % [s, e, m])
		quit(0)
	else:
		for line in failures:
			print("  FAIL — " + line)
		quit(1)


func _expect(label: String, got: float, want: float) -> void:
	if absf(got - want) > 0.02:
		failures.append("%s: got %.3f, expected %.3f" % [label, got, want])
