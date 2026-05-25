extends Node3D
class_name DummyTarget
## Stationary practice target. Two Area3D children named HeadHitbox / BodyHitbox
## are the raycast-detectable colliders.

@export var max_hp: float = 200.0
@export var respawn_seconds: float = 3.0

@onready var head_hitbox: Area3D = $HeadHitbox
@onready var body_hitbox: Area3D = $BodyHitbox
@onready var visual: Node3D = $Visual

var hp: float = 0.0
var is_down: bool = false

signal damaged(amount: float, is_headshot: bool, new_hp: float)
signal downed()
signal respawned()


func _ready() -> void:
	hp = max_hp
	# Meta so generic raycast hit handler can recognize hitboxes uniformly with
	# PlayerController's hitboxes.
	head_hitbox.set_meta(&"owner_player", self)
	head_hitbox.set_meta(&"is_head", true)
	body_hitbox.set_meta(&"owner_player", self)
	body_hitbox.set_meta(&"is_head", false)


# Called by PlayerController's _apply_local_hit when target has owner_player meta.
func apply_damage(dmg: float, _attacker: Node) -> void:
	if is_down:
		return
	hp = maxf(0.0, hp - dmg)
	damaged.emit(dmg, false, hp)
	if hp <= 0.0:
		_go_down()


# Alternative entrypoint kept for the dummy's "I'm just a static hit zone" path.
func take_hit(weapon: Resource, is_head: bool, _attacker: Node) -> void:
	if is_down or weapon == null:
		return
	var dmg: float = PlayerController._compute_damage(weapon, is_head)
	hp = maxf(0.0, hp - dmg)
	damaged.emit(dmg, is_head, hp)
	if hp <= 0.0:
		_go_down()


func _go_down() -> void:
	is_down = true
	visual.visible = false
	head_hitbox.monitoring = false
	body_hitbox.monitoring = false
	downed.emit()
	get_tree().create_timer(respawn_seconds).timeout.connect(_respawn)


func _respawn() -> void:
	hp = max_hp
	is_down = false
	visual.visible = true
	head_hitbox.monitoring = true
	body_hitbox.monitoring = true
	respawned.emit()
