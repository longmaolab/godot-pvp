extends Node3D
## Test-only stand-in for PlayerController. Has the bare minimum field
## surface the arcade-rule scripts read (hp / is_dead / ammo_in_mag /
## loadout / weapon_def). NOT a full PlayerController — that pulls in
## CharacterBody3D + camera + hitboxes which we don't need for testing
## rule scripts in isolation.

var hp: float = 100.0
var is_dead: bool = false
var ammo_in_mag: int = 0
var ammo_reserve: int = 0
var weapon_def: Resource = null
var loadout: Array[Resource] = []
var _ammo_state: Dictionary = {}

signal ammo_changed(in_mag: int, reserve: int)


func _sync_ammo_from_state() -> void:
	if weapon_def != null and _ammo_state.has(weapon_def.id):
		var s: Dictionary = _ammo_state[weapon_def.id]
		ammo_in_mag = int(s.get("in_mag", 0))
		ammo_reserve = int(s.get("reserve", 0))


# Minimal damage sink so rules that deal AoE / zone damage (BR zone tick,
# grenade) can be unit-tested. Drops hp, flips is_dead at 0.
func apply_damage(amount: float, _attacker) -> void:
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0:
		is_dead = true
