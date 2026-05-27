extends Node
class_name BattleRoyaleRule
## Battle Royale — shrinking play zone. Every SHRINK_INTERVAL_SEC the safe
## zone radius drops by SHRINK_STEP. Players outside the zone take ZONE_DPS
## damage per second. Last player standing wins.
##
## Zone is centered on the map origin by default; rule_script reads the
## map's `BRCenter` Marker3D if present.

const STARTING_RADIUS := 30.0
const SHRINK_INTERVAL_SEC := 60.0
const SHRINK_STEP := 5.0
const MIN_RADIUS := 4.0
const ZONE_DPS := 3.0

var match_controller: Node = null
var game_controller: Node = null
var current_radius: float = STARTING_RADIUS
var _accum: float = 0.0
var _zone_center: Vector3 = Vector3.ZERO


func _ready() -> void:
	# Look for a custom zone center on the map; fall back to origin.
	if game_controller != null and "map_root" in game_controller:
		var map: Node = game_controller.map_root
		if map != null:
			var marker: Node = map.get_node_or_null(^"BRCenter")
			if marker is Node3D:
				_zone_center = (marker as Node3D).global_position


func _process(delta: float) -> void:
	if match_controller == null or match_controller.match_over:
		return
	if game_controller == null or not "players_by_peer" in game_controller:
		return
	# Shrink timer.
	_accum += delta
	if _accum >= SHRINK_INTERVAL_SEC:
		_accum = 0.0
		current_radius = maxf(current_radius - SHRINK_STEP, MIN_RADIUS)
	# Zone DPS — every player outside radius takes ZONE_DPS * delta dmg.
	var alive_peers: Array = []
	for peer in game_controller.players_by_peer.keys():
		var p: Node = game_controller.players_by_peer[peer]
		if p == null or not is_instance_valid(p):
			continue
		if "is_dead" in p and p.is_dead:
			continue
		var horiz: Vector3 = p.global_position - _zone_center
		horiz.y = 0
		if horiz.length() > current_radius and p.has_method(&"apply_damage"):
			p.apply_damage(ZONE_DPS * delta, p)   # self-source so no kill credit
		if "is_dead" in p and not p.is_dead:
			alive_peers.append(peer)
	# Last-man-standing win condition.
	if alive_peers.size() == 1 and game_controller.players_by_peer.size() > 1:
		match_controller._end_match(alive_peers[0])


func get_progress() -> Dictionary:
	return {"radius": current_radius, "center": _zone_center}
