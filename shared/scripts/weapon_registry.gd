extends Node
## Autoload-friendly singleton-style helper. Scans res://shared/data/weapons/
## for .tres WeaponDefs at startup so newly-dropped weapon files appear in the
## lookup automatically — no engine-code change required when a designer adds
## a weapon.
##
## Until autoload registration, _resolve_weapon() in game_controller is the
## only caller — instantiate WeaponRegistry there.

const WEAPON_DIR := "res://shared/data/weapons/"

var by_id: Dictionary = {}   # StringName id → Resource WeaponDef


func _init() -> void:
	_scan()


func get_weapon(id: StringName) -> Resource:
	return by_id.get(id, null)


func all_ids() -> Array:
	return by_id.keys()


func _scan() -> void:
	var dir := DirAccess.open(WEAPON_DIR)
	if dir == null:
		push_warning("[WeaponRegistry] cannot open %s" % WEAPON_DIR)
		return
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		if dir.current_is_dir():
			continue
		# Web export rewrites .tres → .tres.remap (path indirection). Strip
		# the .remap suffix so the rest of the loop sees the original name
		# and load() resolves correctly. Native runs are unaffected.
		if fname.ends_with(".tres.remap"):
			fname = fname.substr(0, fname.length() - 6)
		if not fname.ends_with(".tres"):
			continue
		# Skip the schema files (underscore prefix convention).
		if fname.begins_with("_"):
			continue
		var path: String = WEAPON_DIR + fname
		var res: Resource = load(path)
		if res == null:
			push_warning("[WeaponRegistry] failed to load %s" % path)
			continue
		if not "id" in res:
			push_warning("[WeaponRegistry] %s has no 'id' field" % path)
			continue
		by_id[res.id] = res
	dir.list_dir_end()
