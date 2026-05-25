extends SceneTree
## Time trenches map load + physics tick cost vs blank. Helps determine if
## trenches-specific jitter is caused by scene weight (heavy CSG / shadows /
## subtraction ops compute) or by something else.

const BLANK := "res://shared/scenes/maps/blank.tscn"
const TRENCHES := "res://shared/scenes/maps/trenches.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for path in [BLANK, TRENCHES]:
		await _profile(path)
	quit(0)


func _profile(path: String) -> void:
	# Cold load.
	var t0_us := Time.get_ticks_usec()
	var scene: PackedScene = load(path)
	var t1_us := Time.get_ticks_usec()
	var inst: Node = scene.instantiate()
	var t2_us := Time.get_ticks_usec()
	root.add_child(inst)
	# Wait for CSG bake + first physics tick.
	await physics_frame
	await physics_frame
	var t3_us := Time.get_ticks_usec()

	# Measure 60 physics frames.
	var per_frame_us: Array[int] = []
	for i in 60:
		var f0 := Time.get_ticks_usec()
		await physics_frame
		per_frame_us.append(Time.get_ticks_usec() - f0)

	# Stats.
	var total: int = 0
	var maxv: int = 0
	for v in per_frame_us:
		total += v
		if v > maxv: maxv = v
	var avg: float = float(total) / float(per_frame_us.size())

	var name: String = path.get_file()
	print("[perf] %s" % name)
	print("    load packed scene: %d us" % (t1_us - t0_us))
	print("    instantiate:       %d us" % (t2_us - t1_us))
	print("    add+bake (2 frames): %d us" % (t3_us - t2_us))
	print("    avg physics frame: %.2f us  (max %d us)" % [avg, maxv])

	# Count nodes to give a sense of scene weight.
	var n: int = _count_nodes(inst)
	print("    node count:        %d" % n)

	inst.queue_free()
	await physics_frame


func _count_nodes(n: Node) -> int:
	var c: int = 1
	for child in n.get_children():
		c += _count_nodes(child)
	return c
