extends PlayerController
class_name BotPlayer
## Simple combat AI. Inherits all the locomotion / weapon / hit code from
## PlayerController and overrides _step_movement / _step_weapon to drive
## itself instead of reading human input.
##
## Behavior:
##   - Pursue target until within attack_range
##   - At range, sidestep + face target + check LOS via raycast
##   - Fire when in range AND has clear line of sight AND has ammo
##   - Flee when HP < flee_hp_ratio * max_hp (back away from target)
##   - Reload when mag empty

@export var target: Node3D = null
@export var pursue_speed: float = 4.5
@export var attack_range: float = 20.0
@export var max_engage_range: float = 80.0
@export var flee_hp_ratio: float = 0.15
@export var difficulty: StringName = &"medium"  # easy/medium/hard/expert

# Difficulty tuning. Each tier overrides the base exports above so the same
# bot scene works at any skill level — set difficulty before _ready.
const TIERS := {
	&"easy": {
		"pursue_speed": 2.5, "attack_range": 14.0, "max_engage_range": 35.0,
		"flee_hp_ratio": 0.45, "aim_smoothing": 4.0, "extra_fire_cooldown": 0.6,
		"miss_chance": 0.45,
	},
	&"medium": {
		"pursue_speed": 3.4, "attack_range": 18.0, "max_engage_range": 55.0,
		"flee_hp_ratio": 0.30, "aim_smoothing": 8.0, "extra_fire_cooldown": 0.30,
		"miss_chance": 0.25,
	},
	&"hard": {
		"pursue_speed": 4.2, "attack_range": 22.0, "max_engage_range": 80.0,
		"flee_hp_ratio": 0.20, "aim_smoothing": 14.0, "extra_fire_cooldown": 0.12,
		"miss_chance": 0.10,
	},
	&"expert": {
		"pursue_speed": 4.8, "attack_range": 24.0, "max_engage_range": 120.0,
		"flee_hp_ratio": 0.12, "aim_smoothing": 99.0, "extra_fire_cooldown": 0.0,
		"miss_chance": 0.02,
	},
}

var _aim_pos: Vector3 = Vector3.ZERO
var _current_aim_yaw: float = 0.0
var _current_aim_pitch: float = 0.0
var _aim_smoothing: float = 8.0
var _extra_fire_cooldown: float = 0.0
var _next_fire_after: float = 0.0
var _miss_chance: float = 0.25
# Throwable cadence — every THROWABLE_INTERVAL seconds we try a one-shot
# toss with the first throwable in loadout. Randomized initial value so
# multiple bots don't all throw on the same frame.
const THROWABLE_INTERVAL_MIN := 8.0
const THROWABLE_INTERVAL_MAX := 18.0
var _next_throwable_at: float = 0.0


func _ready() -> void:
	# Bot is a server-driven AI: still "local-authority" (it ticks movement +
	# weapons here, not remote-state-synced), but it must NOT capture mouse
	# or hide first-person visuals. Set the human-input flag false before
	# super._ready() runs so PlayerController skips those branches.
	is_human_input = false
	super._ready()
	set_meta(&"is_bot", true)
	# Apply difficulty tuning. Higher tiers = faster, smarter aim, lower miss.
	_apply_difficulty(difficulty)
	# Initialize aim trackers from spawn rotation so the very first frame
	# doesn't snap from yaw=0 to whatever target direction we compute.
	_current_aim_yaw = rotation.y
	_current_aim_pitch = head.rotation.x


func _apply_difficulty(d: StringName) -> void:
	var t: Dictionary = TIERS.get(d, TIERS[&"medium"])
	pursue_speed = float(t["pursue_speed"])
	attack_range = float(t["attack_range"])
	max_engage_range = float(t["max_engage_range"])
	flee_hp_ratio = float(t["flee_hp_ratio"])
	_aim_smoothing = float(t["aim_smoothing"])
	_extra_fire_cooldown = float(t["extra_fire_cooldown"])
	_miss_chance = float(t["miss_chance"])


func set_difficulty(d: StringName) -> void:
	difficulty = d
	_apply_difficulty(d)


func _step_movement(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	if target == null or not is_instance_valid(target):
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	var to: Vector3 = target.global_position - global_position
	to.y = 0.0
	var dist: float = to.length()
	if dist < 0.001:
		move_and_slide()
		return

	var dir: Vector3 = to / dist
	var fleeing: bool = (hp / max_hp) < flee_hp_ratio

	if fleeing:
		# Walk away from target.
		velocity.x = -dir.x * pursue_speed
		velocity.z = -dir.z * pursue_speed
	elif dist > attack_range:
		# Pursue.
		velocity.x = dir.x * pursue_speed
		velocity.z = dir.z * pursue_speed
	else:
		# In range: gentle sidestep so we're not a stationary punching bag.
		var t: float = Time.get_ticks_msec() / 1000.0
		var oscillation: float = sin(t * 1.7 + float(get_instance_id() % 100))
		var perp: Vector3 = Vector3(-dir.z, 0.0, dir.x)
		velocity.x = perp.x * oscillation * 1.6
		velocity.z = perp.z * oscillation * 1.6

	move_and_slide()


func _step_weapon(delta: float) -> void:
	time_until_next_shot = maxf(0.0, time_until_next_shot - delta)
	if is_reloading:
		reload_remaining -= delta
		if reload_remaining <= 0.0:
			_finish_reload()
		return
	if target == null or not is_instance_valid(target) or weapon_def == null:
		return

	# Aim at target head if it has one (player), else at target origin + 1m.
	if target.has_node(^"HeadHitbox"):
		_aim_pos = target.get_node(^"HeadHitbox").global_position
	else:
		_aim_pos = target.global_position + Vector3(0, 1.0, 0)

	var camera_pos: Vector3 = camera.global_position
	var to_aim: Vector3 = _aim_pos - camera_pos
	if to_aim.length() < 0.01:
		return

	# Smoothed aim — _aim_smoothing per tier. expert ≈ instant; easy lags
	# enough that fast strafers can dodge.
	var horiz: float = Vector2(to_aim.x, to_aim.z).length()
	var desired_yaw: float = atan2(to_aim.x, to_aim.z) + PI
	var desired_pitch: float = atan2(to_aim.y, horiz)
	# Easy/medium bots intentionally introduce miss by jittering aim.
	if _miss_chance > 0.0 and randf() < _miss_chance:
		desired_yaw += randf_range(-0.06, 0.06)
		desired_pitch += randf_range(-0.04, 0.04)
	var alpha: float = clampf(_aim_smoothing * delta, 0.0, 1.0)
	_current_aim_yaw = lerp_angle(_current_aim_yaw, desired_yaw, alpha)
	_current_aim_pitch = lerpf(_current_aim_pitch, desired_pitch, alpha)
	set_aim(_current_aim_yaw, _current_aim_pitch)

	# Reload if empty.
	if ammo_in_mag <= 0:
		start_reload()
		return

	# Range gate — don't burn ammo at extreme distance.
	if to_aim.length() > max_engage_range:
		return

	# Cooldown gate — match the weapon's fire interval.
	if time_until_next_shot > 0.0:
		return

	# LOS check.
	if not _has_line_of_sight(_aim_pos):
		return
	# Tier-specific extra cooldown on top of weapon fire interval.
	var now_s: float = Time.get_ticks_msec() / 1000.0
	if now_s < _next_fire_after:
		return
	# Occasional throwable toss — see _maybe_throw_grenade for the logic.
	# Runs BEFORE try_fire so a successful throw consumes the tick.
	if _maybe_throw_grenade(now_s):
		_next_fire_after = now_s + _extra_fire_cooldown
		return
	if try_fire():
		_next_fire_after = now_s + _extra_fire_cooldown


# Periodically swap to a throwable in loadout, fire it, swap back. Returns
# true iff a throw was actually attempted (cooldown reached + throwable
# present + target within practical AoE range). The caller treats a true
# return like a regular fire — arms _next_fire_after etc.
func _maybe_throw_grenade(now_s: float) -> bool:
	if now_s < _next_throwable_at:
		return false
	if loadout.size() < 2:
		return false
	# Find first throwable in loadout.
	var thrown: Resource = null
	var thrown_idx: int = -1
	for i in loadout.size():
		var w: Resource = loadout[i]
		if w == null:
			continue
		if "is_throwable" in w and w.is_throwable:
			thrown = w
			thrown_idx = i
			break
	if thrown == null:
		return false
	# Reschedule regardless of throw success — don't spam if conditions
	# aren't met right now.
	_next_throwable_at = now_s + randf_range(THROWABLE_INTERVAL_MIN, THROWABLE_INTERVAL_MAX)
	if target == null or not is_instance_valid(target):
		return false
	var dist: float = global_position.distance_to(target.global_position)
	# Only throw at mid-range — too close = self-damage, too far = wasted.
	if dist < thrown.explode_radius * 1.5 or dist > 30.0:
		return false
	# Swap to throwable, fire, swap back. equip_by_id mirrors what a
	# human player would do via slot keys.
	var saved_id: StringName = weapon_def.id if weapon_def != null else &""
	if not has_method(&"equip_by_id"):
		return false
	equip_by_id(thrown.id)
	# Refill the throwable's mag in case prior throws emptied it — bots
	# don't carry reload UX, just always have one ready.
	_ammo_state[thrown.id] = {"in_mag": thrown.magazine, "reserve": thrown.reserve}
	if has_method(&"_sync_ammo_from_state"):
		_sync_ammo_from_state()
	var fired_ok: bool = try_fire()
	# Always swap back so the bot resumes shooting its primary.
	if not saved_id.is_empty() and saved_id != thrown.id:
		equip_by_id(saved_id)
	return fired_ok


## Raycast from camera to target. World-only mask: we just want to know if a
## wall blocks the shot, not whether other player hitboxes intersect.
func _has_line_of_sight(target_pos: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, target_pos)
	query.collision_mask = 1   # static world only
	var ex: Array[RID] = [get_rid()]
	query.exclude = ex
	var hit: Dictionary = space.intersect_ray(query)
	return hit.is_empty()
