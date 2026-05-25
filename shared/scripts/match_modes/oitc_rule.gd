extends Node
class_name OitcRule
## "One In The Chamber" — every player gets 1 bullet, no reserve. A kill
## refunds 1 bullet to the killer. Missing leaves you with a melee-only
## fallback until someone re-supplies you (or you scavenge from a pickup).

const STARTING_AMMO := 1
const REFUND_PER_KILL := 1

var match_controller: Node = null
var game_controller: Node = null
var _initialized_peers: Dictionary = {}   # peer_id → bool, applied starting ammo


func _ready() -> void:
	if match_controller != null and match_controller.has_signal(&"kill_recorded"):
		match_controller.kill_recorded.connect(_on_kill)


func _process(_delta: float) -> void:
	if game_controller == null or not "players_by_peer" in game_controller:
		return
	# On spawn / first sight: clamp ammo to STARTING_AMMO across loadout. Cheap
	# enough to poll each frame since loadouts are tiny.
	for peer in game_controller.players_by_peer.keys():
		var p: Node = game_controller.players_by_peer[peer]
		if p == null or not is_instance_valid(p):
			continue
		if not _initialized_peers.get(peer, false):
			_apply_starting_ammo(p)
			_initialized_peers[peer] = true


func _apply_starting_ammo(p: Node) -> void:
	if "_ammo_state" not in p or "loadout" not in p:
		return
	for w in p.loadout:
		if w == null:
			continue
		p._ammo_state[w.id] = {"in_mag": STARTING_AMMO, "reserve": 0}
	if p.weapon_def != null and p.has_method(&"_sync_ammo_from_state"):
		p._sync_ammo_from_state()
		p.ammo_changed.emit(p.ammo_in_mag, p.ammo_reserve)


func _on_kill(killer_peer: int, _victim_peer: int) -> void:
	if killer_peer <= 0 or game_controller == null:
		return
	var p: Node = game_controller.players_by_peer.get(killer_peer)
	if p == null or not is_instance_valid(p):
		return
	# Refund 1 bullet to the killer's currently equipped weapon.
	p.ammo_in_mag = mini(p.ammo_in_mag + REFUND_PER_KILL, p.weapon_def.magazine)
	if p.has_signal(&"ammo_changed"):
		p.ammo_changed.emit(p.ammo_in_mag, p.ammo_reserve)
