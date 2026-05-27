extends Node
class_name FrontlinesRule
## Frontlines — territory push. Each team's home base is a Marker3D on the
## map; a team wins by holding the enemy base for HOLD_TO_WIN seconds
## without enemy contest.
##
## Team assignment by peer_id parity (even = team A, odd = team B) until
## proper team_id is wired through the lobby. Map needs Marker3D nodes
## named "FrontA" and "FrontB".

const BASE_RADIUS := 5.0
const HOLD_TO_WIN := 30.0

var match_controller: Node = null
var game_controller: Node = null
var hold_a: float = 0.0   # team A's accumulated hold on B's base
var hold_b: float = 0.0   # team B's accumulated hold on A's base
var _base_a: Vector3 = Vector3(-15, 0, 0)
var _base_b: Vector3 = Vector3(15, 0, 0)


func _ready() -> void:
	if game_controller != null and "map_root" in game_controller and game_controller.map_root != null:
		var map: Node = game_controller.map_root
		var a: Node = map.get_node_or_null(^"FrontA")
		var b: Node = map.get_node_or_null(^"FrontB")
		if a is Node3D:
			_base_a = (a as Node3D).global_position
		if b is Node3D:
			_base_b = (b as Node3D).global_position


func _process(delta: float) -> void:
	if match_controller == null or match_controller.match_over:
		return
	if game_controller == null or not "players_by_peer" in game_controller:
		return
	# Count team members on each enemy base.
	var a_at_b: int = 0
	var b_at_a: int = 0
	var a_at_a: int = 0
	var b_at_b: int = 0
	for peer in game_controller.players_by_peer.keys():
		var p: Node = game_controller.players_by_peer[peer]
		if p == null or not is_instance_valid(p):
			continue
		if "is_dead" in p and p.is_dead:
			continue
		var on_b: bool = p.global_position.distance_to(_base_b) <= BASE_RADIUS
		var on_a: bool = p.global_position.distance_to(_base_a) <= BASE_RADIUS
		var is_team_a: bool = (peer & 1) == 0
		if is_team_a:
			if on_b: a_at_b += 1
			if on_a: a_at_a += 1
		else:
			if on_a: b_at_a += 1
			if on_b: b_at_b += 1
	# Hold only ticks when uncontested at enemy base.
	if a_at_b > 0 and b_at_b == 0:
		hold_a += delta
	else:
		hold_a = maxf(0.0, hold_a - delta * 0.5)   # slow decay
	if b_at_a > 0 and a_at_a == 0:
		hold_b += delta
	else:
		hold_b = maxf(0.0, hold_b - delta * 0.5)
	# Win check.
	if hold_a >= HOLD_TO_WIN:
		for peer in game_controller.players_by_peer.keys():
			if (peer & 1) == 0:
				match_controller._end_match(peer)
				return
	if hold_b >= HOLD_TO_WIN:
		for peer in game_controller.players_by_peer.keys():
			if (peer & 1) == 1:
				match_controller._end_match(peer)
				return


func get_progress() -> Dictionary:
	return {"hold_a": hold_a, "hold_b": hold_b, "goal": HOLD_TO_WIN}
