extends Node
class_name LastStandRule
## LastStand — solo (or co-op) survival vs waves of bots that grow stronger.
## Each cleared wave spawns N+1 bots in the next. Round ends when all
## humans die. Match-end winner is the human peer with most kills.
##
## Spawning piggybacks on game_controller.spawn_bot. We track wave_index
## so the HUD can render "WAVE N" and the player feels progression.

const WAVE_PAUSE_SEC := 6.0      # cooldown after clearing a wave
const STARTING_WAVE_BOTS := 2
const MAX_WAVES := 12

var match_controller: Node = null
var game_controller: Node = null
var wave_index: int = 0
var _state: String = "spawning"   # spawning / fighting / pause / done
var _state_until: float = 0.0


func _ready() -> void:
	_state = "spawning"
	_advance_to_next_wave_at(0.5)


func _process(_delta: float) -> void:
	if match_controller == null or match_controller.match_over:
		return
	if game_controller == null or not "players_by_peer" in game_controller:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	# Check if all humans are dead — match over.
	var alive_humans: int = 0
	for peer in game_controller.players_by_peer.keys():
		var p: Node = game_controller.players_by_peer[peer]
		if p == null or not is_instance_valid(p):
			continue
		if "is_dead" in p and p.is_dead:
			continue
		# Bots have peer_id < 0 (synthetic).
		if peer > 0:
			alive_humans += 1
	if alive_humans == 0:
		_end_match_with_top_killer()
		return
	# State machine — only spawn the next wave after pause completes.
	match _state:
		"spawning":
			if now >= _state_until:
				_spawn_wave()
				_state = "fighting"
		"fighting":
			# When all bots dead, start pause.
			var alive_bots: int = 0
			if "bots" in game_controller:
				for b in game_controller.bots:
					if b != null and is_instance_valid(b) and "is_dead" in b and not b.is_dead:
						alive_bots += 1
			if alive_bots == 0:
				if wave_index >= MAX_WAVES:
					# Cleared the final wave — top killer wins.
					_end_match_with_top_killer()
					return
				_advance_to_next_wave_at(now + WAVE_PAUSE_SEC)


func _advance_to_next_wave_at(t: float) -> void:
	_state = "spawning"
	_state_until = t


func _spawn_wave() -> void:
	wave_index += 1
	var bot_count: int = STARTING_WAVE_BOTS + wave_index
	if not game_controller.has_method(&"spawn_bot"):
		return
	# Pick first human's position as spawn anchor; offset bots in a ring.
	var anchor: Vector3 = Vector3.ZERO
	for peer in game_controller.players_by_peer.keys():
		if peer > 0:
			var p: Node = game_controller.players_by_peer[peer]
			if p != null and is_instance_valid(p):
				anchor = p.global_position
				break
	var weapon_path: String = "res://shared/data/weapons/ak20.tres"
	var weapon: Resource = load(weapon_path)
	for i in bot_count:
		var angle: float = TAU * float(i) / float(bot_count)
		var offset: Vector3 = Vector3(cos(angle) * 18.0, 1.0, sin(angle) * 18.0)
		game_controller.spawn_bot(_first_human(), anchor + offset, weapon)


func _first_human() -> Node:
	for peer in game_controller.players_by_peer.keys():
		if peer > 0:
			return game_controller.players_by_peer[peer]
	return null


func _end_match_with_top_killer() -> void:
	var winner_peer: int = 0
	var top_kills: int = -1
	if match_controller != null and "kills" in match_controller:
		for peer in match_controller.kills:
			if peer > 0 and int(match_controller.kills[peer]) > top_kills:
				top_kills = int(match_controller.kills[peer])
				winner_peer = peer
	if winner_peer == 0:
		# Fall back to first human.
		for peer in game_controller.players_by_peer.keys():
			if peer > 0:
				winner_peer = peer
				break
	match_controller._end_match(winner_peer)


func get_progress() -> Dictionary:
	return {"wave": wave_index, "max_waves": MAX_WAVES, "state": _state}
