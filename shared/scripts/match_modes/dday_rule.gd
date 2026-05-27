extends Node
class_name DDayRule
## D-Day — asymmetric defense. One team (defenders) holds a bunker objective.
## The OBJECTIVE_HOLD_SEC timer counts down while no attacker is within
## CAPTURE_RADIUS. When timer hits zero, defenders win. If any attacker
## stays inside CAPTURE_RADIUS for CAPTURE_SECONDS continuously, attackers
## win.
##
## Map needs a Marker3D named "DDayBunker" at the bunker location.

const OBJECTIVE_HOLD_SEC := 180.0   # 3 min — defenders win if timer expires
const CAPTURE_RADIUS := 5.0
const CAPTURE_SECONDS := 8.0        # attackers must stand uncontested this long

var match_controller: Node = null
var game_controller: Node = null
var hold_remaining: float = OBJECTIVE_HOLD_SEC
var capture_progress: float = 0.0
var _bunker_pos: Vector3 = Vector3.ZERO


func _ready() -> void:
	if game_controller != null and "map_root" in game_controller:
		var marker: Node = (game_controller.map_root as Node).get_node_or_null(^"DDayBunker") if game_controller.map_root != null else null
		if marker is Node3D:
			_bunker_pos = (marker as Node3D).global_position


func _process(delta: float) -> void:
	if match_controller == null or match_controller.match_over:
		return
	if game_controller == null or not "players_by_peer" in game_controller:
		return
	# Count attackers inside the capture zone. Team membership comes from
	# the peer's `team_id` if set (P-M2+ lobby flow); else use simple
	# alternating odd-even peers as attackers/defenders for MVP.
	var attackers_in_zone: int = 0
	var defenders_in_zone: int = 0
	for peer in game_controller.players_by_peer.keys():
		var p: Node = game_controller.players_by_peer[peer]
		if p == null or not is_instance_valid(p):
			continue
		if "is_dead" in p and p.is_dead:
			continue
		if p.global_position.distance_to(_bunker_pos) > CAPTURE_RADIUS:
			continue
		# Team assignment fallback: peer_id even = defender, odd = attacker.
		# Real implementation should read p.team_id from match_controller.
		if (peer & 1) == 1:
			attackers_in_zone += 1
		else:
			defenders_in_zone += 1
	if attackers_in_zone > 0 and defenders_in_zone == 0:
		capture_progress += delta
		if capture_progress >= CAPTURE_SECONDS:
			# Attackers win — pick the first alive attacker as nominal.
			for peer in game_controller.players_by_peer.keys():
				if (peer & 1) == 1:
					match_controller._end_match(peer)
					return
	else:
		# Reset capture if defenders contest or no one is there.
		capture_progress = maxf(0.0, capture_progress - delta)
	# Defender hold timer.
	hold_remaining -= delta
	if hold_remaining <= 0.0:
		# Defenders win — pick first alive defender.
		for peer in game_controller.players_by_peer.keys():
			if (peer & 1) == 0:
				match_controller._end_match(peer)
				return


func get_progress() -> Dictionary:
	return {
		"hold_remaining": hold_remaining,
		"capture_progress": capture_progress,
		"capture_goal": CAPTURE_SECONDS,
	}
