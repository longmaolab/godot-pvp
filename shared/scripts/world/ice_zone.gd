extends Area3D
class_name IceZone
## Slippery ice patch — slows acceleration to a crawl (low friction) but
## doesn't reduce max speed. Players slide past their target.

@export var friction: float = 4.0   # base is 30; lower = slipperier

var _prev_friction: Dictionary = {}   # player → previous ground_friction


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(b: Node) -> void:
	if not b.is_in_group(&"player"):
		return
	if not _prev_friction.has(b) and "ground_friction" in b:
		_prev_friction[b] = b.ground_friction
		b.ground_friction = friction


func _on_body_exited(b: Node) -> void:
	if _prev_friction.has(b) and is_instance_valid(b) and "ground_friction" in b:
		b.ground_friction = _prev_friction[b]
	_prev_friction.erase(b)
