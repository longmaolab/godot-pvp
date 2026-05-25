extends Area3D
class_name DamageZone
## Players inside this area take periodic damage. Used for lava, acid pools,
## radioactive fog, etc. Drop one into any map.tscn and tune the exports.

@export var damage_per_tick: float = 6.0
@export var tick_interval_sec: float = 0.25
@export var hud_feed: bool = false   # noisy in some maps; off by default

var _bodies_inside: Array[Node] = []
var _accum: float = 0.0


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	if _bodies_inside.is_empty():
		return
	_accum += delta
	if _accum < tick_interval_sec:
		return
	_accum = 0.0
	# Only the server applies damage; in practice the host (or offline)
	# applies locally.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server() \
			and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		return
	for b in _bodies_inside:
		if not is_instance_valid(b):
			continue
		if b.has_method(&"apply_damage"):
			b.apply_damage(damage_per_tick, null)


func _on_body_entered(b: Node) -> void:
	if b.is_in_group(&"player") and b not in _bodies_inside:
		_bodies_inside.append(b)


func _on_body_exited(b: Node) -> void:
	_bodies_inside.erase(b)
