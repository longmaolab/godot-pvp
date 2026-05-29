extends Node
## Verifies MatchController win conditions for each mode family.
##   1. FFA kill-goal: simulate kills, assert match_ended fires at goal.
##   2. ELIM 1v1: simulate a death, assert round_ended; reach rounds_to_win → match_ended.
##   3. RACE (TDM-style): kill goal applies, simulate, verify.

const MC_SCRIPT := preload("res://shared/scripts/match_controller.gd")
const MODE_FFA := preload("res://shared/data/modes/ffa_kill5.tres")
const MODE_ELIM := preload("res://shared/data/modes/elim_1v1.tres")
const MODE_TDM := preload("res://shared/data/modes/tdm_kill10.tres")
const MODE_GUNGAME := preload("res://shared/data/modes/gungame.tres")
const MODE_INFECTION := preload("res://shared/data/modes/infection.tres")
const MODE_OITC := preload("res://shared/data/modes/oitc.tres")
const MODE_KOTH := preload("res://shared/data/modes/koth.tres")
const MODE_BR := preload("res://shared/data/modes/br.tres")
const MODE_DDAY := preload("res://shared/data/modes/dday.tres")
const MODE_FRONTLINES := preload("res://shared/data/modes/frontlines.tres")
const MODE_LASTSTAND := preload("res://shared/data/modes/laststand.tres")
const AK20 := preload("res://shared/data/weapons/ak20.tres")

var failed: int = 0

# Exposed to rule_scripts via match_controller's `rule.game_controller =
# get_parent()` wiring. Each arcade-mode test populates this with fake
# player nodes before adding MC; rule scripts read it as their world view.
var players_by_peer: Dictionary = {}
var map_root: Node = null   # KOTH rule needs a map with HillZone marker


func _ready() -> void:
	print("\n=== match-mode integration test ===")
	await _test_ffa_kill_goal()
	await _test_elim_round_progression()
	await _test_race_kill_goal()
	await _test_elim_round_kills_dont_leak()
	await _test_gungame_tier_progression()
	await _test_infection_propagation()
	await _test_oitc_ammo_refund()
	await _test_koth_hold_advances()
	await _test_br_zone_and_last_man()
	await _test_dday_attacker_capture()
	await _test_frontlines_uncontested_hold()
	await _test_laststand_all_dead_ends()
	print("\n=== result: %s (%d failures) ===" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(0 if failed == 0 else 1)


func _test_ffa_kill_goal() -> void:
	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_FFA
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()

	# Simulate 4 kills by peer 100 (not enough), then 5th triggers match_ended.
	for i in range(5):
		mc.record_kill(100, 200)

	await get_tree().process_frame
	if not captured["match_ended"]:
		_fail("FFA kill_goal=5: match did not end after 5 kills")
		mc.queue_free()
		return
	if captured["winner"] != 100:
		_fail("FFA winner expected 100, got %d" % captured["winner"])
		mc.queue_free()
		return
	if mc.kills.get(100, 0) != 5:
		_fail("FFA kills tracking: expected 5, got %d" % mc.kills.get(100, 0))
		mc.queue_free()
		return
	print("  [ok] FFA kill_goal: peer 100 won after 5 kills (deaths=%d)" % mc.deaths.get(200, 0))
	mc.queue_free()


func _test_elim_round_progression() -> void:
	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_ELIM
	add_child(mc)
	var state := {"rounds_ended": [] as Array, "match_won": 0}
	mc.round_ended.connect(func(w, _s): state["rounds_ended"].append(w))
	mc.match_ended.connect(func(w, _f): state["match_won"] = w)
	mc.start()

	# Round 1: peer 1 kills peer 2 → round_ended(1)
	mc.record_kill(1, 2)
	await get_tree().process_frame
	var rounds_ended: Array = state["rounds_ended"]
	if rounds_ended.size() != 1 or rounds_ended[0] != 1:
		_fail("elim round 1: expected winner=1, got %s" % rounds_ended)
		mc.queue_free()
		return
	if mc.match_over:
		_fail("elim: match ended after 1 round (best-of-3 needs 2)")
		mc.queue_free()
		return

	# Speed-run past the 2s inter-round timer by directly resuming the round.
	mc.round_active = true
	mc.record_kill(1, 2)
	await get_tree().process_frame
	if not mc.match_over:
		_fail("elim: match should be over after 2 round wins (rounds_to_win=2)")
		mc.queue_free()
		return
	if state["match_won"] != 1:
		_fail("elim match winner expected 1, got %d" % state["match_won"])
		mc.queue_free()
		return
	print("  [ok] ELIM 1v1: peer 1 won match after 2 rounds (best-of-3)")
	mc.queue_free()


func _test_race_kill_goal() -> void:
	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_TDM
	add_child(mc)
	var state := {"done": -1}
	mc.match_ended.connect(func(w, _f): state["done"] = w)
	mc.start()

	# TDM kill goal is 10 → peer 7 reaches 10 kills.
	for i in range(10):
		mc.record_kill(7, 99)
	await get_tree().process_frame
	if state["done"] != 7:
		_fail("race: expected winner=7 after 10 kills, got %d" % state["done"])
		mc.queue_free()
		return
	print("  [ok] RACE/TDM: peer 7 won at 10 kills")
	mc.queue_free()


## codexreview 12:39 P2 regression: round 2 timeout must not crown the
## player who scored in round 1. Locks in the round-local stats fix.
func _test_elim_round_kills_dont_leak() -> void:
	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_ELIM
	add_child(mc)
	mc.start()

	# Round 1: peer 5 kills peer 9. record_kill auto-ends the elim round.
	mc.record_kill(5, 9)
	await get_tree().process_frame
	if mc.round_wins.get(5, 0) != 1:
		_fail("round-leak: expected peer 5 has 1 round_win after round 1, got %d" %
			mc.round_wins.get(5, 0))
		mc.queue_free()
		return

	# Manually start round 2 (bypass the 2s inter-round timer).
	mc._start_round()
	# Sanity: round_kills must be cleared on _start_round; the previous
	# round's 1 kill for peer 5 must not still be sitting there.
	if mc.round_kills.get(5, 0) != 0:
		_fail("round-leak: peer 5 round_kills should be 0 at start of round 2, got %d" %
			mc.round_kills.get(5, 0))
		mc.queue_free()
		return

	# Round 2: nobody scores; timeout fires. The bug we're guarding against
	# would crown peer 5 because their CUMULATIVE `kills` is still 1.
	mc._on_round_timeout()
	await get_tree().process_frame
	if mc.round_wins.get(5, 0) != 1:
		_fail("round-leak: peer 5 round_wins jumped to %d on zero-kill timeout — round 1's kill leaked into round 2's tally" %
			mc.round_wins.get(5, 0))
		mc.queue_free()
		return
	print("  [ok] ELIM round 2 zero-kill timeout: no spurious winner from round 1's kills")
	mc.queue_free()


func _test_gungame_tier_progression() -> void:
	# Gun Game (gungame.tres) sets `rule_script = GunGameRule.gd`. MC
	# instantiates it as a child; each `kill_recorded` advances the
	# killer's tier. Tier 6 (GRADUATION_TIER) wins. Weapon swap is
	# best-effort (it tries to mutate players_by_peer entries) — when
	# game_controller has no such entry the swap silently no-ops, which
	# is exactly what we want for this unit test.
	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_GUNGAME
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()
	# Verify the rule_script wired up.
	var rule: Node = mc.get_node_or_null(^"RuleScript")
	if rule == null:
		_fail("Gun Game: rule_script not instantiated under match_controller")
		mc.queue_free()
		return
	# Simulate 6 kills by peer 100 → graduates → match_ended.
	for i in range(6):
		mc.record_kill(100, 200)
		await get_tree().process_frame
	if not captured["match_ended"]:
		_fail("Gun Game: match did not end after 6 kills (GRADUATION_TIER)")
		mc.queue_free()
		return
	if captured["winner"] != 100:
		_fail("Gun Game winner expected 100, got %d" % captured["winner"])
		mc.queue_free()
		return
	# Verify tier counter inside the rule matches.
	if rule.peer_tiers.get(100, 0) != 6:
		_fail("Gun Game peer_tiers[100] expected 6, got %d" % rule.peer_tiers.get(100, 0))
		mc.queue_free()
		return
	print("  [ok] Gun Game: 6 kills → tier 6 → match_ended winner=100")
	mc.queue_free()


# ── Infection ────────────────────────────────────────────────────────────
# Patient zero gets picked after START_DELAY_SEC. When the infected kills
# a survivor, the survivor flips. When everyone is infected, match_ended
# fires with patient zero as nominal winner.
func _test_infection_propagation() -> void:
	# Set up 3 fake players in our parent's players_by_peer (the rule reads
	# from get_parent(), which is this test node).
	var p100: Node = _make_fake_player()
	var p200: Node = _make_fake_player()
	var p300: Node = _make_fake_player()
	players_by_peer = {100: p100, 200: p200, 300: p300}
	add_child(p100); add_child(p200); add_child(p300)

	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_INFECTION
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()

	var rule: Node = mc.get_node_or_null(^"RuleScript")
	if rule == null:
		_fail("Infection: rule_script not instantiated")
		_cleanup_infection_test(mc, [p100, p200, p300])
		return
	# Force patient zero pick by short-circuiting the start delay.
	rule._start_time_ms = Time.get_ticks_msec() - 10_000
	# Advance two frames to let _process pick patient zero.
	await get_tree().process_frame
	await get_tree().process_frame

	# Whichever player got patient zero, we'll have them kill everyone else.
	var pz_peer: int = 0
	for peer in players_by_peer.keys():
		var p: Node = players_by_peer[peer]
		if p.has_meta(&"infected") and p.get_meta(&"infected"):
			pz_peer = peer
			break
	if pz_peer == 0:
		_fail("Infection: no patient zero picked after process tick")
		_cleanup_infection_test(mc, [p100, p200, p300])
		return
	# Kill the other 2 survivors.
	for peer in [100, 200, 300]:
		if peer == pz_peer:
			continue
		mc.record_kill(pz_peer, peer)
	await get_tree().process_frame

	if not captured["match_ended"]:
		_fail("Infection: match did not end after all converted")
	# Rule picks "first infected in dict iter order" as nominal winner, not
	# necessarily patient zero. Just check that A winner exists and is one
	# of our infected players.
	elif not captured["winner"] in players_by_peer:
		_fail("Infection winner not in players_by_peer: %d" % captured["winner"])
	else:
		print("  [ok] Infection: patient zero %d converts all → match_ended winner=%d" % [pz_peer, captured["winner"]])
	_cleanup_infection_test(mc, [p100, p200, p300])


func _cleanup_infection_test(mc: Node, players: Array) -> void:
	players_by_peer = {}
	mc.queue_free()
	for p in players:
		p.queue_free()


# ── OITC ──────────────────────────────────────────────────────────────────
# Every player gets 1 bullet, no reserve. Kills refund 1 bullet.
func _test_oitc_ammo_refund() -> void:
	var p100: Node = _make_fake_player()
	p100.weapon_def = AK20
	p100.loadout = [AK20] as Array[Resource]
	if p100.has_method(&"_sync_ammo_from_state"):
		# Pre-populate _ammo_state so the loop doesn't trip on missing entry.
		p100._ammo_state[AK20.id] = {"in_mag": 30, "reserve": 90}
	players_by_peer = {100: p100}
	add_child(p100)

	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_OITC
	add_child(mc)
	mc.start()
	var rule: Node = mc.get_node_or_null(^"RuleScript")
	if rule == null:
		_fail("OITC: rule_script not instantiated")
		_cleanup_oitc_test(mc, [p100])
		return
	# First _process tick should clamp ammo to 1.
	await get_tree().process_frame
	if p100.ammo_in_mag != 1:
		_fail("OITC: ammo not clamped to 1 (got %d)" % p100.ammo_in_mag)
		_cleanup_oitc_test(mc, [p100])
		return
	# Simulate firing → 0 ammo → kill → expect refund to 1.
	p100.ammo_in_mag = 0
	mc.record_kill(100, 0)   # victim_peer=0 (dummy), killer=100
	if p100.ammo_in_mag != 1:
		_fail("OITC: ammo not refunded to 1 after kill (got %d)" % p100.ammo_in_mag)
	else:
		print("  [ok] OITC: starting ammo=1 + kill refunds 1")
	_cleanup_oitc_test(mc, [p100])


func _cleanup_oitc_test(mc: Node, players: Array) -> void:
	players_by_peer = {}
	mc.queue_free()
	for p in players:
		p.queue_free()


# ── KOTH ──────────────────────────────────────────────────────────────────
# Living player inside HILL_RADIUS accumulates seconds on the hill. First
# to HOLD_GOAL_SEC ends the match. We can't easily wait 30 real seconds in
# a test, so we directly mutate hold_times to verify the end-condition
# branch.
func _test_koth_hold_advances() -> void:
	var p100: Node = _make_fake_player()
	players_by_peer = {100: p100}
	add_child(p100)
	# global_position only valid AFTER add_child (Node3D needs to be in tree).
	p100.global_position = Vector3.ZERO
	# Build a stand-in map with a HillZone marker at origin.
	var hill_map: Node3D = Node3D.new()
	hill_map.name = "FakeMap"
	var hill_marker: Marker3D = Marker3D.new()
	hill_marker.name = "HillZone"
	hill_map.add_child(hill_marker)
	add_child(hill_map)
	map_root = hill_map

	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_KOTH
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()
	var rule: Node = mc.get_node_or_null(^"RuleScript")
	if rule == null:
		_fail("KOTH: rule_script not instantiated")
		_cleanup_koth_test(mc, [p100], hill_map)
		return
	# Inject a hold time just below the goal, then drive _process directly
	# with a synthetic delta. Calling rule._process(delta) is more reliable
	# than awaiting process_frame for unit tests — frame ticks in headless
	# mode are inconsistent, and the rule body is pure GDScript.
	rule.hold_times[100] = rule.HOLD_GOAL_SEC - 0.05
	rule._process(0.1)   # 0.1 > 0.05 gap → hold_times >= HOLD_GOAL_SEC
	if not captured["match_ended"]:
		_fail("KOTH: match did not end after hold goal reached")
	elif captured["winner"] != 100:
		_fail("KOTH winner expected 100, got %d" % captured["winner"])
	else:
		print("  [ok] KOTH: hold ≥ HOLD_GOAL_SEC → match_ended winner=100")
	_cleanup_koth_test(mc, [p100], hill_map)


func _cleanup_koth_test(mc: Node, players: Array, hill_map: Node) -> void:
	players_by_peer = {}
	map_root = null
	mc.queue_free()
	for p in players:
		p.queue_free()
	hill_map.queue_free()


const _FAKE_PLAYER := preload("res://tests/_fake_player.gd")


# Build a minimal stand-in for PlayerController — just enough fields the
# arcade-rule scripts read. See _fake_player.gd for the field surface.
func _make_fake_player() -> Node3D:
	var n := Node3D.new()
	n.set_script(_FAKE_PLAYER)
	return n


# ── Battle Royale ──────────────────────────────────────────────────────────
# Player outside the shrinking zone takes ZONE_DPS dmg; last alive wins.
func _test_br_zone_and_last_man() -> void:
	var inside: Node = _make_fake_player()    # at origin = always inside
	var outside: Node = _make_fake_player()   # far away = always outside
	players_by_peer = {100: inside, 200: outside}
	add_child(inside); add_child(outside)
	inside.global_position = Vector3.ZERO
	outside.global_position = Vector3(100, 0, 0)

	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_BR
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()
	var rule: Node = mc.get_node_or_null(^"RuleScript")
	if rule == null:
		_fail("BR: rule_script not instantiated")
		_cleanup_simple(mc, [inside, outside]); return
	# One tick: outside player should take zone damage, inside player should not.
	var hp_in_before: float = inside.hp
	var hp_out_before: float = outside.hp
	rule._process(1.0)   # 1s → ZONE_DPS dmg to the outside player
	if outside.hp >= hp_out_before:
		_fail("BR: outside-zone player took no damage (%.1f → %.1f)" % [hp_out_before, outside.hp])
	elif inside.hp < hp_in_before:
		_fail("BR: inside-zone player wrongly took damage (%.1f → %.1f)" % [hp_in_before, inside.hp])
	else:
		# Now kill the outside player → only 1 alive → match ends with inside.
		outside.is_dead = true
		rule._process(0.1)
		if not captured["match_ended"]:
			_fail("BR: match did not end with 1 survivor")
		elif captured["winner"] != 100:
			_fail("BR winner expected 100, got %d" % captured["winner"])
		else:
			print("  [ok] BR: zone dmg outside / safe inside + last-man-standing wins")
	_cleanup_simple(mc, [inside, outside])


# ── D-Day ──────────────────────────────────────────────────────────────────
# Attacker (odd peer) standing uncontested on the bunker for CAPTURE_SECONDS
# wins. Even peer = defender.
func _test_dday_attacker_capture() -> void:
	var attacker: Node = _make_fake_player()   # peer 101 (odd) = attacker
	players_by_peer = {101: attacker}
	add_child(attacker)
	# Bunker defaults to origin (no DDayBunker marker on our fake map).
	attacker.global_position = Vector3.ZERO

	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_DDAY
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()
	var rule: Node = mc.get_node_or_null(^"RuleScript")
	if rule == null:
		_fail("DDay: rule_script not instantiated")
		_cleanup_simple(mc, [attacker]); return
	# Drive enough seconds for capture_progress to exceed CAPTURE_SECONDS.
	rule._process(rule.CAPTURE_SECONDS + 0.1)
	if not captured["match_ended"]:
		_fail("DDay: attacker capture did not end match")
	elif captured["winner"] != 101:
		_fail("DDay winner expected attacker 101, got %d" % captured["winner"])
	else:
		print("  [ok] DDay: uncontested attacker capture → attacker wins")
	_cleanup_simple(mc, [attacker])


# ── Frontlines ─────────────────────────────────────────────────────────────
# Team A (even peer) uncontested on team B's base for HOLD_TO_WIN wins.
func _test_frontlines_uncontested_hold() -> void:
	var team_a: Node = _make_fake_player()   # peer 100 (even) = team A
	players_by_peer = {100: team_a}
	add_child(team_a)

	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_FRONTLINES
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()
	var rule: Node = mc.get_node_or_null(^"RuleScript")
	if rule == null:
		_fail("Frontlines: rule_script not instantiated")
		_cleanup_simple(mc, [team_a]); return
	# Stand team A on team B's base (defaults to +15,0,0).
	team_a.global_position = rule._base_b
	rule._process(rule.HOLD_TO_WIN + 0.1)
	if not captured["match_ended"]:
		_fail("Frontlines: uncontested hold did not end match")
	elif captured["winner"] != 100:
		_fail("Frontlines winner expected team-A 100, got %d" % captured["winner"])
	else:
		print("  [ok] Frontlines: uncontested enemy-base hold → team wins")
	_cleanup_simple(mc, [team_a])


# ── LastStand ──────────────────────────────────────────────────────────────
# Match ends when all humans (peer > 0) are dead. Winner = top killer.
func _test_laststand_all_dead_ends() -> void:
	var human: Node = _make_fake_player()    # peer 100 (human)
	players_by_peer = {100: human}
	add_child(human)
	human.global_position = Vector3.ZERO

	var mc: Node = MC_SCRIPT.new()
	mc.mode_def = MODE_LASTSTAND
	add_child(mc)
	var captured := {"match_ended": false, "winner": 0}
	mc.match_ended.connect(func(w, _f):
		captured["match_ended"] = true
		captured["winner"] = w)
	mc.start()
	var rule: Node = mc.get_node_or_null(^"RuleScript")
	if rule == null:
		_fail("LastStand: rule_script not instantiated")
		_cleanup_simple(mc, [human]); return
	# Kill the only human → next tick should end the match.
	human.is_dead = true
	rule._process(0.1)
	if not captured["match_ended"]:
		_fail("LastStand: match did not end when all humans dead")
	else:
		print("  [ok] LastStand: all humans dead → match ends (winner=%d)" % captured["winner"])
	_cleanup_simple(mc, [human])


# Shared cleanup for the _process-driven rule tests.
func _cleanup_simple(mc: Node, players: Array) -> void:
	players_by_peer = {}
	mc.queue_free()
	for p in players:
		if is_instance_valid(p):
			p.queue_free()


func _fail(msg: String) -> void:
	push_error("[match-mode] " + msg)
	print("  [FAIL] %s" % msg)
	failed += 1
