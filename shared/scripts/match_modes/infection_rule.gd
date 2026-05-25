extends Node
class_name InfectionRule
## Infection — one random player starts INFECTED. When an infected player
## kills a survivor, the survivor flips to infected. Survivors win if any
## remain alive at timeout; infected wins if everyone is converted.
##
## We tag players via set_meta(&"infected", true/false). game_controller's
## kill broadcast checks the meta when determining whether to flip.

const START_DELAY_SEC := 3.0   # grace period before first infected is picked

var match_controller: Node = null
var game_controller: Node = null
var _picked_patient_zero: bool = false
var _start_time_ms: int = 0


func _ready() -> void:
	_start_time_ms = Time.get_ticks_msec()
	if match_controller != null and match_controller.has_signal(&"kill_recorded"):
		match_controller.kill_recorded.connect(_on_kill)


func _process(_delta: float) -> void:
	if _picked_patient_zero or game_controller == null:
		return
	if Time.get_ticks_msec() - _start_time_ms < int(START_DELAY_SEC * 1000):
		return
	_pick_patient_zero()


func _pick_patient_zero() -> void:
	if not "players_by_peer" in game_controller:
		return
	var candidates: Array = []
	for peer in game_controller.players_by_peer.keys():
		var p: Node = game_controller.players_by_peer[peer]
		if p != null and is_instance_valid(p):
			candidates.append(p)
	if candidates.is_empty():
		return
	var patient: Node = candidates[randi() % candidates.size()]
	patient.set_meta(&"infected", true)
	_picked_patient_zero = true
	# Visual tag — tint the player's GLB hint material red. We don't have a
	# clean material override path so we just nudge the holder modulate.
	var visuals: Node = patient.get_node_or_null(^"Visuals")
	if visuals is CanvasItem:
		(visuals as CanvasItem).modulate = Color(1.2, 0.5, 0.5)


func _on_kill(killer_peer: int, victim_peer: int) -> void:
	if killer_peer <= 0 or game_controller == null:
		return
	var killer: Node = game_controller.players_by_peer.get(killer_peer)
	var victim: Node = game_controller.players_by_peer.get(victim_peer)
	if killer == null or victim == null:
		return
	# If infected killed a survivor, convert.
	if killer.has_meta(&"infected") and killer.get_meta(&"infected"):
		victim.set_meta(&"infected", true)
		_check_win_condition()


func _check_win_condition() -> void:
	# Infected wins if everyone is now infected.
	var any_survivor: bool = false
	var infected_count: int = 0
	for peer in game_controller.players_by_peer.keys():
		var p: Node = game_controller.players_by_peer[peer]
		if p == null:
			continue
		if p.has_meta(&"infected") and p.get_meta(&"infected"):
			infected_count += 1
		else:
			any_survivor = true
	if not any_survivor and infected_count > 0:
		# Infected team wins — pick patient zero as nominal winner.
		for peer in game_controller.players_by_peer.keys():
			var p: Node = game_controller.players_by_peer[peer]
			if p != null and p.has_meta(&"infected"):
				match_controller._end_match(peer)
				return
