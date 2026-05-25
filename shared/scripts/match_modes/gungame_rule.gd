extends Node
class_name GunGameRule
## Gun Game — every kill bumps the killer up a weapon tier. Graduating
## through all tiers (final kill with the "demote" weapon) wins.
##
## Tier ladder mirrors original /Users/longmao/projects/pvp-game's gungame
## family: AR → SMG → Shotgun → Sniper → Revolver → Crossbow (fists proxy).
## Each kill swaps the killer's equipped weapon. Final tier kill = victory.

const TIER_WEAPONS := [
	"ak20",
	"mp40",
	"sg8",
	"srx",
	"revolver",
	"crossbow",
]
const GRADUATION_TIER := 6   # killing after reaching this tier wins

var match_controller: Node = null
var game_controller: Node = null
var peer_tiers: Dictionary = {}   # peer_id → tier (0..GRADUATION_TIER)


func _ready() -> void:
	if match_controller != null and match_controller.has_signal(&"kill_recorded"):
		match_controller.kill_recorded.connect(_on_kill)


func _on_kill(killer_peer: int, _victim_peer: int) -> void:
	if killer_peer <= 0:
		return
	var tier: int = peer_tiers.get(killer_peer, 0)
	tier += 1
	peer_tiers[killer_peer] = tier
	if tier >= GRADUATION_TIER:
		match_controller._end_match(killer_peer)
		return
	# Swap killer's weapon to next tier (only meaningful if they're locally
	# controlled or the host is authoritative on loadouts).
	_swap_weapon(killer_peer, tier)


func _swap_weapon(peer: int, tier: int) -> void:
	if game_controller == null or not "players_by_peer" in game_controller:
		return
	var p: Node = game_controller.players_by_peer.get(peer)
	if p == null or not is_instance_valid(p):
		return
	if tier < 0 or tier >= TIER_WEAPONS.size():
		return
	var path: String = "res://shared/data/weapons/" + TIER_WEAPONS[tier] + ".tres"
	var weapon: Resource = load(path)
	if weapon == null:
		return
	# Replace loadout slot 0 with the new tier weapon and equip it.
	var lo: Array = p.loadout
	if lo.is_empty():
		lo = [weapon]
	else:
		lo[0] = weapon
	p.loadout = lo
	p._ammo_state[weapon.id] = {"in_mag": weapon.magazine, "reserve": weapon.reserve}
	if p.has_method(&"equip_slot"):
		p.equip_slot(0)


func get_progress() -> Dictionary:
	return {"tiers": peer_tiers.duplicate(), "graduate_at": GRADUATION_TIER}
