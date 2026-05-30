extends SceneTree
## Verify first-person weapon view-model swaps GLB by category + hides the
## procedural box gun, for the local human only.
const PLAYER := "res://shared/scenes/player.tscn"
var fails: Array[String] = []
func _init(): call_deferred("_run")
func _run():
	var p = (load(PLAYER) as PackedScene).instantiate()
	p.is_local = true; p.is_human_input = true
	# give it a starting weapon (AK20 = AR)
	var ak = load("res://shared/data/weapons/ak20.tres")
	p.weapon_def = ak
	root.add_child(p)
	await physics_frame
	await physics_frame
	var wv = p.get_node_or_null("Head/Camera3D/WeaponVisual")
	_chk(wv != null, "WeaponVisual exists")
	# AR → blaster-d, GLB child present, GunBody hidden
	var vm = wv.get_node_or_null("_ViewModel") if wv else null
	_chk(vm != null, "AR: _ViewModel GLB spawned")
	var body = wv.get_node_or_null("GunBody") if wv else null
	_chk(body != null and not body.visible, "AR: procedural GunBody hidden")
	_chk(p._resolve_view_model(ak) == "blaster-d", "AR resolves to blaster-d (got %s)" % p._resolve_view_model(ak))
	# Category resolution checks (pure function, no scene needed)
	_chk_resolve(p, "Heavy Sniper", "blaster-h")
	_chk_resolve(p, "Shotgun", "blaster-l")
	_chk_resolve(p, "Beam", "blaster-e")
	_chk_resolve(p, "Explosive Bow", "blaster-r")
	_chk_resolve(p, "Secondary", "blaster-a")
	# Swap weapon → GLB instance should change / refresh (only 1 _ViewModel child)
	var snipe = _fake_weapon("Heavy Sniper")
	p._equip_resource(snipe)
	await physics_frame
	var count = 0
	for c in wv.get_children():
		if c.name == "_ViewModel": count += 1
	_chk(count == 1, "after swap exactly 1 _ViewModel child (got %d)" % count)
	p.free()
	await physics_frame
	if fails.is_empty(): print("VIEWMODEL PASS — %d checks" % _n); quit(0)
	else:
		for f in fails: print("VIEWMODEL FAIL — "+f)
		quit(1)
var _n = 0
func _chk(c, m):
	_n += 1
	if not c:
		fails.append(m)
func _chk_resolve(p, label, expect):
	var w = _fake_weapon(label)
	var got = p._resolve_view_model(w)
	_chk(got == expect, "%s → expected %s got %s" % [label, expect, got])
func _fake_weapon(label):
	var w = load("res://shared/data/weapons/ak20.tres").duplicate()
	w.type_label = label
	w.view_model = &""
	return w
