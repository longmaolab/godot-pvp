extends Area3D
class_name LowGravZone
## Moon-jump zone — gravity is reduced, jumps reach much higher.

@export var gravity_mult: float = 0.4

var _prev_gravity: Dictionary = {}


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(b: Node) -> void:
	if not b.is_in_group(&"player"):
		return
	if "gravity_multiplier" in b and not _prev_gravity.has(b):
		_prev_gravity[b] = b.gravity_multiplier
		b.gravity_multiplier *= gravity_mult


func _on_body_exited(b: Node) -> void:
	if _prev_gravity.has(b) and is_instance_valid(b) and "gravity_multiplier" in b:
		b.gravity_multiplier = _prev_gravity[b]
	_prev_gravity.erase(b)
