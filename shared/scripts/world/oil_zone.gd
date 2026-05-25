extends Area3D
class_name OilZone
## Oil slick — even more slippery than ice + slightly slower top speed.

@export var friction: float = 2.0
@export var speed_mult: float = 0.85

var _prev_friction: Dictionary = {}
var _prev_speed_mult: Dictionary = {}


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(b: Node) -> void:
	if not b.is_in_group(&"player"):
		return
	if "ground_friction" in b and not _prev_friction.has(b):
		_prev_friction[b] = b.ground_friction
		b.ground_friction = friction
	if "move_speed_multiplier" in b and not _prev_speed_mult.has(b):
		_prev_speed_mult[b] = b.move_speed_multiplier
		b.move_speed_multiplier *= speed_mult


func _on_body_exited(b: Node) -> void:
	if not is_instance_valid(b):
		_prev_friction.erase(b); _prev_speed_mult.erase(b); return
	if _prev_friction.has(b) and "ground_friction" in b:
		b.ground_friction = _prev_friction[b]
	if _prev_speed_mult.has(b) and "move_speed_multiplier" in b:
		b.move_speed_multiplier = _prev_speed_mult[b]
	_prev_friction.erase(b)
	_prev_speed_mult.erase(b)
