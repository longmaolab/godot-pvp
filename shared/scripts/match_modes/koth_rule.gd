extends Node
class_name KothRule
## King of the Hill rule script. Attached as child of MatchController when the
## active mode_def.family == "koth" (or when koth.tres assigns this script).
##
## Behavior: a Marker3D named "HillZone" must exist on the map. Any living
## player within HILL_RADIUS accumulates seconds on the hill. First to
## HOLD_GOAL_SEC ends the match in their favor.

const HOLD_GOAL_SEC := 30.0
const HILL_RADIUS := 5.0

var match_controller: Node = null
var game_controller: Node = null
var hold_times: Dictionary = {}   # peer_id → cumulative seconds held


func _process(delta: float) -> void:
	if match_controller == null or match_controller.match_over:
		return
	if game_controller == null or not "players_by_peer" in game_controller:
		return
	var hill: Node3D = _find_hill()
	if hill == null:
		return
	var hill_pos: Vector3 = hill.global_position
	for peer in game_controller.players_by_peer.keys():
		var p: Node = game_controller.players_by_peer[peer]
		if p == null or not is_instance_valid(p) or p.is_dead:
			continue
		if p.global_position.distance_to(hill_pos) <= HILL_RADIUS:
			hold_times[peer] = hold_times.get(peer, 0.0) + delta
			if hold_times[peer] >= HOLD_GOAL_SEC:
				match_controller._end_match(peer)
				queue_free()
				return


func _find_hill() -> Node3D:
	if game_controller == null or not "map_root" in game_controller:
		return null
	var map: Node = game_controller.map_root
	if map == null:
		return null
	var hill: Node = map.get_node_or_null(^"HillZone")
	return hill if hill is Node3D else null


## Snapshot for UI (HUD KOTH widget can poll this).
func get_progress() -> Dictionary:
	return {"hold_times": hold_times.duplicate(), "goal": HOLD_GOAL_SEC}
