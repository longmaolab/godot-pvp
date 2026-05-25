extends SceneTree
## Smoke test — run with:
##   godot --headless --path . --script tests/smoke_test.gd
##
## Loads every M1 skeleton file and verifies:
##   - Scripts parse without errors.
##   - WeaponDef Resource instantiates with expected fields from ak20.tres.
##   - Constants in NetProtocol are reachable.

## Directories scanned recursively for .gd / .tscn files at test time.
## Adding a new script/scene under any of these is automatically covered.
const SCAN_ROOTS := ["res://client/", "res://server/", "res://shared/"]

var failed := 0


func _init() -> void:
	print("\n=== M1 smoke test ===")
	# Recursively gather every .gd and .tscn under the project source dirs and
	# verify each one loads without parse errors. This is what blocks the kind
	# of regression where a new UI script has a typo but the test suite is
	# unaware of its existence.
	var gd_files: Array = []
	var tscn_files: Array = []
	for root in SCAN_ROOTS:
		_collect_recursive(root, gd_files, tscn_files)
	gd_files.sort()
	tscn_files.sort()
	print("  scanning %d .gd + %d .tscn under %s" % [
		gd_files.size(), tscn_files.size(), SCAN_ROOTS])
	for path in gd_files:
		_check_parse(path)
	for path in tscn_files:
		_check_scene_loads(path)

	_check_weapon_def()
	_check_sg8_weapon_def()
	_check_extra_weapons()
	_check_weapon_registry()
	_check_descriptions_present()
	_check_net_protocol_constants()
	_check_match_authority_instantiates()
	_check_hit_validator_instantiates()
	_check_entity_interpolator()
	_check_maps_load()

	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	quit(0 if failed == 0 else 1)


## Walk a directory tree, collecting .gd and .tscn paths. Skips Godot's
## .godot/imported cache + dot-folders.
func _collect_recursive(dir_path: String, gd_out: Array, tscn_out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var name: String = d.get_next()
		if name == "":
			break
		if name.begins_with("."):
			continue
		var full: String = dir_path + name
		if d.current_is_dir():
			_collect_recursive(full + "/", gd_out, tscn_out)
		elif name.ends_with(".gd"):
			gd_out.append(full)
		elif name.ends_with(".tscn"):
			tscn_out.append(full)
	d.list_dir_end()


## Try to instantiate a scene — catches things like missing SubResources,
## bad node paths in script @onready bindings, ext_resource pointing nowhere.
func _check_scene_loads(path: String) -> void:
	if not ResourceLoader.exists(path):
		_fail("scene missing: %s" % path)
		return
	var packed: PackedScene = load(path)
	if packed == null:
		_fail("scene failed to load: %s" % path)
		return
	# Don't instantiate every scene blindly — some need the SceneTree (e.g.
	# CanvasLayers with autoload deps). Just confirm the .tscn parsed.
	print("  [ok] scene %s parses" % path)


func _check_parse(path: String) -> void:
	# ResourceLoader.load surfaces parse errors via the error stack but always
	# returns SOMETHING (possibly broken). Use load_threaded for explicit status.
	if not ResourceLoader.exists(path):
		_fail("file missing: %s" % path)
		return
	var err: int = ResourceLoader.load_threaded_request(path)
	if err != OK:
		_fail("load_threaded_request failed for %s: %s" % [path, err])
		return
	var status: int = ResourceLoader.load_threaded_get_status(path)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		OS.delay_msec(10)
		status = ResourceLoader.load_threaded_get_status(path)
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		_fail("script did not load cleanly (status=%d): %s" % [status, path])
		return
	var res: Resource = ResourceLoader.load_threaded_get(path)
	if res == null:
		_fail("loaded null script: %s" % path)
		return
	print("  [ok] parsed %s" % path)


func _check_weapon_def() -> void:
	var ak: Resource = load("res://shared/data/weapons/ak20.tres")
	if ak == null:
		_fail("ak20.tres failed to load")
		return
	if ak.id != &"ak20":
		_fail("ak20.id expected 'ak20', got '%s'" % ak.id)
	if ak.damage != 25.0:
		_fail("ak20.damage expected 25.0, got %s" % ak.damage)
	if ak.magazine != 30:
		_fail("ak20.magazine expected 30, got %d" % ak.magazine)
	if ak.fire_interval_ms != 150:
		_fail("ak20.fire_interval_ms expected 150, got %d" % ak.fire_interval_ms)
	if not ak.free_starter:
		_fail("ak20.free_starter expected true")
	if not ak.auto:
		_fail("ak20.auto expected true")
	if ak.ability == null:
		_fail("ak20.ability missing")
	elif ak.ability.name != "Focus Fire":
		_fail("ak20.ability.name expected 'Focus Fire', got '%s'" % ak.ability.name)
	elif ak.ability.damage_mult != 1.4:
		_fail("ak20.ability.damage_mult expected 1.4, got %s" % ak.ability.damage_mult)

	var sps: float = ak.shots_per_second()
	var expected_sps: float = 1000.0 / 150.0
	if absf(sps - expected_sps) > 0.001:
		_fail("shots_per_second() expected ~%f, got %f" % [expected_sps, sps])

	if ak.is_hitscan():
		_fail("AK20 has bullet_speed=120, is_hitscan() should be false")
	print("  [ok] WeaponDef ak20.tres loads with all expected values")


func _check_sg8_weapon_def() -> void:
	# Second weapon — proves the data-driven Resource model: adding a .tres
	# requires zero engine-code changes (only the central _resolve_weapon
	# match table for server-side fire routing).
	var sg: Resource = load("res://shared/data/weapons/sg8.tres")
	if sg == null:
		_fail("sg8.tres failed to load")
		return
	if sg.id != &"sg8":
		_fail("sg8.id expected 'sg8', got '%s'" % sg.id)
	if sg.damage != 18.0:
		_fail("sg8.damage expected 18.0, got %s" % sg.damage)
	if sg.pellets != 6:
		_fail("sg8.pellets expected 6, got %d" % sg.pellets)
	if absf(sg.spread - 0.08) > 0.0001:
		_fail("sg8.spread expected 0.08, got %s" % sg.spread)
	if sg.auto:
		_fail("sg8.auto expected false (pump shotgun)")
	if not sg.scary_close:
		_fail("sg8.scary_close expected true (bots should flee)")
	if sg.fire_interval_ms != 900:
		_fail("sg8.fire_interval_ms expected 900, got %d" % sg.fire_interval_ms)
	if sg.ability == null or sg.ability.type != &"bulletwave":
		_fail("sg8.ability expected type 'bulletwave'")
	print("  [ok] WeaponDef sg8.tres loads (6 pellets, scary_close=true, bullet_wave ability)")


func _check_extra_weapons() -> void:
	# SR-X sniper — instakill on head.
	var srx: Resource = load("res://shared/data/weapons/srx.tres")
	if srx == null or srx.id != &"srx" or srx.damage != 95.0:
		_fail("srx.tres invalid")
		return
	if not srx.instakill_headshot:
		_fail("srx should be instakill_headshot")
	if absf(srx.ads_zoom_fov - 15.0) > 0.01:
		_fail("srx ads_zoom should be 15° (high zoom)")
	print("  [ok] WeaponDef srx.tres (dmg=95, instakill HS, ADS fov=15°)")

	# Railgun — high damage, fastest bullet.
	var rg: Resource = load("res://shared/data/weapons/railgun.tres")
	if rg == null or rg.id != &"railgun" or rg.damage != 110.0:
		_fail("railgun.tres invalid")
		return
	if rg.bullet_speed != 280.0:
		_fail("railgun bullet_speed should be 280 (fastest)")
	print("  [ok] WeaponDef railgun.tres (dmg=110, bullet_speed=280, overcharge ability)")

	# Crossbow — slow projectile.
	var cb: Resource = load("res://shared/data/weapons/crossbow.tres")
	if cb == null or cb.id != &"crossbow" or cb.damage != 80.0:
		_fail("crossbow.tres invalid")
		return
	if cb.bullet_speed != 72.0:
		_fail("crossbow bullet_speed should be 72 (slowest)")
	if cb.magazine != 1:
		_fail("crossbow magazine should be 1")
	print("  [ok] WeaponDef crossbow.tres (dmg=80, bullet_speed=72, mag=1)")


func _check_weapon_registry() -> void:
	# Verifies the data-driven catalog: dropping a .tres into the weapons
	# folder should make it discoverable without code changes.
	var script: Script = load("res://shared/scripts/weapon_registry.gd")
	if script == null:
		_fail("weapon_registry.gd failed to load")
		return
	var reg: Object = script.new()
	var ids: Array = reg.all_ids()
	if ids.size() < 5:
		_fail("weapon_registry found only %d weapons (expected >= 5)" % ids.size())
		return
	for expected in [&"ak20", &"sg8", &"srx", &"railgun", &"crossbow"]:
		if not ids.has(expected):
			_fail("weapon_registry missing %s" % expected)
			return
	# Lookup correctness.
	var ak: Resource = reg.get_weapon(&"ak20")
	if ak == null or ak.damage != 25.0:
		_fail("registry get_weapon(ak20) wrong")
		return
	reg.free()
	print("  [ok] WeaponRegistry scans %d weapons from filesystem" % ids.size())


func _check_descriptions_present() -> void:
	# Scan the WHOLE weapons/modes folders so newly-added entries can't ship
	# with an empty `description`. The main-menu pickers depend on this.
	var weapon_total: int = 0
	var weapon_bad: Array = []
	var w_dir := DirAccess.open("res://shared/data/weapons/")
	if w_dir != null:
		w_dir.list_dir_begin()
		while true:
			var fname: String = w_dir.get_next()
			if fname == "":
				break
			if w_dir.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
				continue
			weapon_total += 1
			var w: Resource = load("res://shared/data/weapons/" + fname)
			if w == null:
				weapon_bad.append(fname + " (failed to load)")
				continue
			if not ("description" in w) or w.description.strip_edges().is_empty():
				weapon_bad.append(fname)
		w_dir.list_dir_end()
	if weapon_bad.size() > 0:
		_fail("weapons with empty description: %s" % str(weapon_bad))

	var mode_total: int = 0
	var mode_bad: Array = []
	var m_dir := DirAccess.open("res://shared/data/modes/")
	if m_dir != null:
		m_dir.list_dir_begin()
		while true:
			var fname2: String = m_dir.get_next()
			if fname2 == "":
				break
			if m_dir.current_is_dir() or fname2.begins_with("_") or not fname2.ends_with(".tres"):
				continue
			mode_total += 1
			var m: Resource = load("res://shared/data/modes/" + fname2)
			if m == null:
				mode_bad.append(fname2 + " (failed to load)")
				continue
			if not ("description" in m) or m.description.strip_edges().is_empty():
				mode_bad.append(fname2)
		m_dir.list_dir_end()
	if mode_bad.size() > 0:
		_fail("modes with empty description: %s" % str(mode_bad))

	print("  [ok] %d weapons + %d modes all have non-empty descriptions" % [weapon_total, mode_total])


func _check_net_protocol_constants() -> void:
	# NetProtocol is autoloaded; reach via the script class (autoload Node won't
	# be alive in a SceneTree --script run). Use the file directly.
	var script: Script = load("res://shared/scripts/network/net_protocol.gd")
	if script == null:
		_fail("net_protocol.gd missing")
		return
	# Constants are class-level — we instantiate the script to access them.
	var inst: Object = script.new()
	if inst.TICK_RATE != 30:
		_fail("TICK_RATE expected 30, got %d" % inst.TICK_RATE)
	if inst.PLAYER_MAX_HP != 300:
		_fail("PLAYER_MAX_HP expected 300, got %d" % inst.PLAYER_MAX_HP)
	if inst.STARTER_CREDITS != 500:
		_fail("STARTER_CREDITS expected 500, got %d" % inst.STARTER_CREDITS)
	if inst.INPUT_FIRE != (1 << 7):
		_fail("INPUT_FIRE bit position wrong")
	inst.free()
	print("  [ok] NetProtocol constants match expected values")


func _check_match_authority_instantiates() -> void:
	var script: Script = load("res://server/scripts/match_authority.gd")
	var node: Node = script.new()
	if node == null:
		_fail("match_authority.gd .new() returned null")
		return
	node.queue_input(42, 1, 0, 0.0, 0.0)
	if not node._input_queue.has(42):
		_fail("queue_input did not store under peer_id")
	node.queue_free()
	print("  [ok] MatchAuthority instantiates and queue_input works")


func _check_hit_validator_instantiates() -> void:
	var script: Script = load("res://server/scripts/hit_validator.gd")
	var node: Node = script.new()
	if node == null:
		_fail("hit_validator.gd .new() returned null")
		return
	# Test damage math directly (no physics needed).
	var weapon: Resource = load("res://shared/data/weapons/ak20.tres")
	var body_dmg = node._compute_damage(weapon, false, {})
	if body_dmg != 25.0:
		_fail("body damage expected 25.0, got %s" % body_dmg)
	var head_dmg = node._compute_damage(weapon, true, {})
	if head_dmg != 50.0:
		_fail("head damage expected 50.0 (25 * 2), got %s" % head_dmg)
	var upgraded = node._compute_damage(weapon, false, {&"damage": 2})
	# 25 * (1 + 2*0.12) = 25 * 1.24 = 31.0
	if absf(upgraded - 31.0) > 0.001:
		_fail("upgraded damage expected 31.0, got %s" % upgraded)
	node.queue_free()
	print("  [ok] HitValidator instantiates; damage math correct (25/50/31)")


func _check_maps_load() -> void:
	for path in [
		"res://shared/scenes/maps/blank.tscn",
		"res://shared/scenes/maps/battlefield.tscn",
		"res://shared/scenes/maps/koth.tscn",
		"res://shared/scenes/maps/trenches.tscn",
		"res://shared/scenes/maps/skydock.tscn",
	]:
		var scene: PackedScene = load(path)
		if scene == null:
			_fail("map failed to load: %s" % path)
			continue
		var inst: Node = scene.instantiate()
		if inst == null:
			_fail("map failed to instantiate: %s" % path)
			continue
		# Every map should expose spawn points.
		var spawns: Node = inst.get_node_or_null(^"SpawnPoints")
		if spawns == null:
			_fail("map missing SpawnPoints node: %s" % path)
			inst.queue_free()
			continue
		var spawn_count: int = spawns.get_child_count()
		if spawn_count < 2:
			_fail("map %s has only %d spawn points (need >= 2)" % [path, spawn_count])
		else:
			print("  [ok] map %s loads with %d spawn points" % [path.get_file(), spawn_count])
		inst.queue_free()


func _check_entity_interpolator() -> void:
	var script: Script = load("res://client/scripts/prediction/entity_interpolator.gd")
	var node: Node = script.new()
	if node == null:
		_fail("entity_interpolator.gd .new() returned null")
		return
	node.push_snapshot(7, 1000.0, Vector3(0, 0, 0), 0.0, 0.0)
	node.push_snapshot(7, 1100.0, Vector3(10, 0, 0), 0.0, 0.0)
	# Render time = 1100 - 100 (interp delay) = 1000 → should return start pos.
	var s1 = node.sample(7, 1100.0)
	if s1 == null or s1.pos.distance_to(Vector3(0, 0, 0)) > 0.01:
		_fail("interp at delay-edge expected (0,0,0), got %s" % str(s1))
	# Render time = 1150 - 100 = 1050 → halfway → (5,0,0)
	var s2 = node.sample(7, 1150.0)
	if s2 == null or s2.pos.distance_to(Vector3(5, 0, 0)) > 0.01:
		_fail("interp at midpoint expected (5,0,0), got %s" % str(s2))
	node.queue_free()
	print("  [ok] EntityInterpolator lerps correctly between snapshots")


func _fail(msg: String) -> void:
	push_error("[FAIL] %s" % msg)
	print("  [FAIL] %s" % msg)
	failed += 1
