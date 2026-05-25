extends Node
class_name MatchController
## Drives round/match lifecycle: tracks kills per peer, checks win conditions
## per ModeDef.family, fires signals for HUD + game_controller to react.
##
## Designed to be authoritative on the host. Clients should mirror state via
## RPCs in M4; for M3 the same MatchController exists on both sides and is
## driven by player.died signals which both sides observe.

const FAMILY_FFA   := &"ffa"     # last standing OR first-to-kill-goal
const FAMILY_ELIM  := &"elim"    # any death ends round; first to rounds_to_win
const FAMILY_RACE  := &"race"    # first team / player to kill_goal
const FAMILY_KOTH  := &"koth"    # hold-the-hill (later)

@export var mode_def: Resource = null

var kills: Dictionary = {}        # peer_id → count
var deaths: Dictionary = {}       # peer_id → count
var round_wins: Dictionary = {}   # peer_id → rounds won
var current_round: int = 1
var time_remaining: float = 0.0
var round_active: bool = false
var match_over: bool = false
var winner_peer: int = 0

signal round_started(round_num: int)
signal round_ended(winner: int, scores: Dictionary)
signal match_ended(winner: int, final_scores: Dictionary)
signal time_tick(remaining: float)
signal score_changed(peer: int, kills_count: int, deaths_count: int)
## Fired BEFORE win-condition checks so rule_scripts can react and even
## override winner detection (e.g. Gun Game graduating final tier).
signal kill_recorded(killer_peer: int, victim_peer: int)


func start() -> void:
	if mode_def == null:
		push_error("[MatchController] no mode_def assigned")
		return
	kills.clear()
	deaths.clear()
	round_wins.clear()
	current_round = 1
	match_over = false
	winner_peer = 0
	# If the ModeDef points to a custom rule_script (e.g. KOTH hill tracking,
	# Gun Game weapon rotation), instantiate it as a child so its _process
	# drives mode-specific behavior. Falls through silently for vanilla modes.
	if "rule_script" in mode_def and mode_def.rule_script != null:
		var rule: Node = mode_def.rule_script.new()
		rule.name = "RuleScript"
		if "match_controller" in rule:
			rule.match_controller = self
		if "game_controller" in rule:
			rule.game_controller = get_parent()
		add_child(rule)
	_start_round()


func _start_round() -> void:
	round_active = true
	time_remaining = float(mode_def.round_seconds)
	round_started.emit(current_round)


func _process(delta: float) -> void:
	if not round_active or match_over or mode_def == null:
		return
	if mode_def.round_seconds <= 0:
		return
	time_remaining -= delta
	time_tick.emit(time_remaining)
	if time_remaining <= 0.0:
		_on_round_timeout()


## Call from game_controller on every player.died signal. killer_peer == 0
## means environmental death (fall, lava, etc.) — counts only as a death.
func record_kill(killer_peer: int, victim_peer: int) -> void:
	if mode_def == null or match_over:
		return
	# Fire kill_recorded FIRST so rule_scripts can mutate state or short-circuit.
	kill_recorded.emit(killer_peer, victim_peer)
	if killer_peer > 0 and killer_peer != victim_peer:
		kills[killer_peer] = kills.get(killer_peer, 0) + 1
		score_changed.emit(killer_peer, kills.get(killer_peer, 0), deaths.get(killer_peer, 0))
	deaths[victim_peer] = deaths.get(victim_peer, 0) + 1
	score_changed.emit(victim_peer, kills.get(victim_peer, 0), deaths.get(victim_peer, 0))

	# Win-condition checks per family.
	match mode_def.family:
		FAMILY_RACE, FAMILY_FFA:
			if mode_def.kill_goal > 0 and killer_peer > 0:
				if kills.get(killer_peer, 0) >= mode_def.kill_goal:
					_end_match(killer_peer)
		FAMILY_ELIM:
			# Any death ends the round; the killer wins it.
			_end_round(killer_peer)


func _on_round_timeout() -> void:
	# In elim with timeout: the player with most kills this round wins.
	# Simplified — first player in kills dict wins ties.
	var top_peer: int = 0
	var top_score: int = -1
	for peer in kills.keys():
		if kills[peer] > top_score:
			top_score = kills[peer]
			top_peer = peer
	_end_round(top_peer)


func _end_round(winner: int) -> void:
	if not round_active:
		return
	round_active = false
	if winner > 0:
		round_wins[winner] = round_wins.get(winner, 0) + 1
	round_ended.emit(winner, _snapshot())
	if winner > 0 and round_wins.get(winner, 0) >= mode_def.rounds_to_win:
		_end_match(winner)
		return
	# Schedule the next round.
	current_round += 1
	get_tree().create_timer(2.0).timeout.connect(_start_round)


func _end_match(winner: int) -> void:
	match_over = true
	round_active = false
	winner_peer = winner
	match_ended.emit(winner, _snapshot())


func _snapshot() -> Dictionary:
	return {
		"kills": kills.duplicate(),
		"deaths": deaths.duplicate(),
		"round_wins": round_wins.duplicate(),
		"current_round": current_round,
	}
