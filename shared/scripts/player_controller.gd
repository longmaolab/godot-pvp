extends CharacterBody3D
class_name PlayerController
## Player controller — handles movement, look, shooting.
##
## Collision layers used across the project:
##   1 = static world (walls, floor)
##   2 = player movement bodies (CharacterBody3D)
##   3 = hit-detection Areas (head_hitbox + body_hitbox)
##
## Shoot raycasts query mask = 1 (so walls stop bullets) + 3 (hitboxes register
## damage). The CharacterBody capsule (layer 2) is intentionally NOT in the
## shoot mask, so the body collider doesn't shadow the hitbox areas.

const GRAVITY: float = 28.0
const SHOOT_MASK: int = (1 << 0) | (1 << 2)   # world + hitboxes
const SHOOT_RANGE: float = 500.0

# Multiplicative environment effects. Map gimmick zones write to these on
# enter and reset to 1.0 on exit. Multiple overlapping zones stack.
var move_speed_multiplier: float = 1.0
var gravity_multiplier: float = 1.0
# Smaller = slippier. 30 ≈ snappy stop, 3 ≈ ice/oil "I keep going" feel.
var ground_friction: float = 30.0

@export var weapon_def: Resource              # currently equipped WeaponDef
@export var loadout: Array[Resource] = []     # WeaponDefs available to switch via 1/2/3/4
@export var move_speed: float = 5.0
@export var sprint_multiplier: float = 1.6
@export var jump_velocity: float = 13.0
@export var mouse_sensitivity: float = 0.002
@export var is_local: bool = true             # set false for remote/networked
@export var is_human_input: bool = true        # false for bots: skip mouse/key
# DS-M2: when true, this controller runs authoritative physics on the server
# but consumes input from the network (push_remote_input) instead of Input.*.
# Used by the dedicated server to simulate each connected peer's player.
@export var use_remote_input: bool = false
# DS-M3: when true, this controller does NOT simulate physics locally — it only
# renders from server snapshots (push_snapshot). Used on DS clients for every
# player (including the local human). Local human + is_snapshot_only also
# implies "send my input to the server every tick" so the server can simulate.
@export var is_snapshot_only: bool = false
@export var player_name: String = "Player"
@export var skin_index: int = 0               # 0..17 — selects character-{a..r}.glb

const SKIN_LETTERS := "abcdefghijklmnopqr"   # 18 Kenney skins
# Per-skin model scale. Kenney rigs have wildly different native heights
# (head-attach Y from 1.18 → 1.86 GLB units between skins a..r); a single
# scale leaves either the tall ones poking miles above the HeadHitbox or the
# short ones with their head buried inside the BodyHitbox. Each entry =
# 1.65 / measured native head-origin Y, so every skin's neck lands at world
# Y≈1.65, head mesh center near sphere center Y=1.9. Measured via
# tests/measure_hitbox.gd; re-run if Kenney updates the GLBs.
const SKIN_SCALES: Array = [
	0.888, 0.898, 0.911, 0.926, 0.926, 0.943, 0.964, 0.989, 1.017,
	1.017, 1.050, 1.088, 1.132, 1.183, 1.183, 1.243, 1.313, 1.397,
]
const SKIN_PATH := "res://assets/models/characters/character-%s.glb"

var _current_skin: int = -1
var _anim_player: AnimationPlayer = null
var _current_anim: String = ""
const _ANIM_LOOPED := ["idle", "walk", "sprint"]
const _ANIM_IDLE := "idle"
const _ANIM_WALK := "walk"
const _ANIM_SPRINT := "sprint"
const _ANIM_DIE := "die"

# Per-weapon ammo tracking so swap doesn't reset everyone's mag/reserve.
var _ammo_state: Dictionary = {}              # weapon_id → {in_mag: int, reserve: int}

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var head_hitbox: Area3D = $HeadHitbox
@onready var body_hitbox: Area3D = $BodyHitbox
@onready var audio_3d: AudioStreamPlayer3D = $Audio3D
@onready var audio_local: AudioStreamPlayer = $AudioLocal

const SFX_SHOOT: AudioStream = preload("res://assets/audio/shoot.ogg")
const SFX_HIT: AudioStream = preload("res://assets/audio/hit.ogg")
const SFX_DEATH: AudioStream = preload("res://assets/audio/death.ogg")
const SFX_RESPAWN: AudioStream = preload("res://assets/audio/respawn.ogg")

var max_hp: float = 300.0
var hp: float = 300.0
var ammo_in_mag: int = 0
var ammo_reserve: int = 0
var time_until_next_shot: float = 0.0
var is_reloading: bool = false
var reload_remaining: float = 0.0
var is_dead: bool = false

# Respawn invincibility — short window where damage is ignored. Visualized by
# the model alpha-blinking on/off.
const RESPAWN_INVINCIBILITY_SEC := 2.5
const INVINCIBILITY_BLINK_PERIOD := 0.12
var _invincible_until: float = 0.0
var _last_blink_toggle: float = 0.0
var _blink_visible: bool = true

# Weapon ability state. weapon_def.ability is a one-of:
#   buff      — apply damage_mult / spread_mult for duration_ms
#   powershot — apply mults to the NEXT shot only, then consume
#   bulletwave — fire a grid of extra pellets in one shot
var _ability_cooldown_until: float = 0.0
var _buff_active_until: float = 0.0
var _buff_def: Resource = null
var _powershot_armed: Resource = null
signal ability_activated(ability: Resource)
signal ability_consumed(ability: Resource)

# Camera shake / recoil. The mouse writes _aim_yaw / _aim_pitch directly, and
# each frame we set rotation.y = _aim_yaw + kick.x and head.rotation.x =
# _aim_pitch + kick.y. _camera_kick decays toward zero, leaving aim stable.
var _aim_yaw: float = 0.0
var _aim_pitch: float = 0.0
var _camera_kick: Vector2 = Vector2.ZERO

# DS-M2: latest input frame received from a network client (used only when
# use_remote_input=true). Tick gates against replay/out-of-order.
var _remote_input_bits: int = 0
var _remote_input_yaw: float = 0.0
var _remote_input_pitch: float = 0.0
var _remote_input_tick: int = -1
# Edge-detection for "just pressed" semantics on remote-input players. Bits
# that were 0 last tick and 1 this tick. Cleared after _step_movement consumes.
var _remote_input_just_pressed: int = 0
const _CAMERA_KICK_DECAY: float = 14.0   # higher = snappier return to rest
const _RECOIL_KICK_PITCH: float = -0.022  # negative = upward muzzle climb
const _HIT_SHAKE_AMOUNT: float = 0.04

# Multiplayer position sync — local authority broadcasts at 30Hz to remotes.
const NET_SYNC_INTERVAL: float = 1.0 / 30.0
var _net_sync_accum: float = 0.0
var _net_remote_pos: Vector3 = Vector3.ZERO
var _net_remote_yaw: float = 0.0
var _net_remote_pitch: float = 0.0
var _net_has_remote_target: bool = false

# Remote-side interpolator (one per non-local player). Buffers snapshots and
# samples 100ms behind for smooth rendering. Falls back to direct lerp if null.
const _INTERPOLATOR_SCRIPT := preload("res://client/scripts/prediction/entity_interpolator.gd")
var _interpolator: Node = null

signal fired(weapon: Resource, hit_info: Dictionary)   # hit_info empty if miss
signal hp_changed(new_hp: float, max: float)
signal ammo_changed(in_mag: int, reserve: int)
signal weapon_switched(new_weapon: Resource)
signal died(killer: Node)

var last_attacker: Node = null


func _ready() -> void:
	# Tag for group lookups (jump pads, pickups, AI target search).
	add_to_group(&"player")
	# Equip the chosen character GLB. Replaces the procedural box body with
	# a Kenney humanoid skin.
	apply_skin(skin_index)
	# Auto-populate loadout if a single weapon was assigned via inspector.
	if loadout.is_empty() and weapon_def != null:
		loadout = [weapon_def]
	# Initialize ammo state per weapon.
	for w in loadout:
		if w != null and not _ammo_state.has(w.id):
			_ammo_state[w.id] = {"in_mag": w.magazine, "reserve": w.reserve}
	if weapon_def != null:
		_sync_ammo_from_state()
	hp_changed.emit(hp, max_hp)
	ammo_changed.emit(ammo_in_mag, ammo_reserve)

	# Tag hitboxes with reference to owner — used by raycast hit lookup.
	head_hitbox.set_meta(&"owner_player", self)
	head_hitbox.set_meta(&"is_head", true)
	body_hitbox.set_meta(&"owner_player", self)
	body_hitbox.set_meta(&"is_head", false)

	if is_local and is_human_input:
		# Always capture the mouse for FPS aim. Press Esc to release (handled
		# in _unhandled_input) and F1 to re-grab.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_configure_camera_current()

	if is_local:
		# Initial aim state mirrors the spawn transform so the player starts
		# facing whatever direction _local_spawn placed them in.
		_aim_yaw = rotation.y
		_aim_pitch = head.rotation.x
		_configure_camera_current()
	if is_local and is_human_input:
		_hide_first_person_obstructions()

	if not is_local or is_snapshot_only:
		_configure_camera_current()
		# Snapshot interpolator buffers ~100ms of remote position history and
		# samples behind realtime for smooth rendering. Needed for any player
		# whose position is server-driven: ghosts (is_local=false) AND the
		# DS-client's own player (is_snapshot_only=true).
		_interpolator = _INTERPOLATOR_SCRIPT.new()
		add_child(_interpolator)

	# Floating name tag above remote players so the human can SEE the enemy
	# (and where to aim). Skipped on the local player's own avatar.
	if not is_local:
		_create_name_tag()


func _configure_camera_current() -> void:
	if camera == null:
		return
	camera.current = is_local
	if is_local:
		camera.make_current()


func _create_name_tag() -> void:
	var tag := Label3D.new()
	tag.name = "_NameTag"
	tag.text = player_name
	tag.font_size = 48
	tag.outline_size = 12
	tag.outline_modulate = Color(0, 0, 0, 1)
	tag.modulate = Color(1, 0.85, 0.4, 1)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true  # render through walls so you can find enemies
	tag.pixel_size = 0.004
	tag.position = Vector3(0, 2.4, 0)  # above head
	add_child(tag)


## The player's own head + visor + body + GLB skin all wrap around the
## first-person camera. We hide the whole Visuals + head-mounted geometry
## on the local view so the player isn't staring at their own model.
## Remote views still see the full character (the hidden nodes only affect
## the locally-controlled instance).
func _hide_first_person_obstructions() -> void:
	for path in [^"Head/HeadVisual", ^"Head/Visor"]:
		var n: Node = get_node_or_null(path)
		if n is MeshInstance3D:
			(n as MeshInstance3D).visible = false
	# Hide the WHOLE Visuals subtree — procedural body + ModelHolder (GLB).
	# Using visible=false on the parent cascades to all descendants.
	var visuals: Node3D = get_node_or_null(^"Visuals") as Node3D
	if visuals != null:
		visuals.visible = false


# ── Skin (GLB character model) ───────────────────────────────────────────
func apply_skin(idx: int) -> void:
	idx = clampi(idx, 0, SKIN_LETTERS.length() - 1)
	if idx == _current_skin and _anim_player != null:
		return
	_current_skin = idx
	var holder: Node3D = get_node_or_null(^"Visuals/ModelHolder") as Node3D
	if holder == null:
		return
	for c in holder.get_children():
		c.queue_free()
	var letter: String = SKIN_LETTERS.substr(idx, 1)
	var path: String = SKIN_PATH % letter
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		push_warning("[player] missing skin: %s" % path)
		return
	var model: Node3D = scene.instantiate() as Node3D
	if model == null:
		return
	model.scale = Vector3.ONE * SKIN_SCALES[idx]
	holder.add_child(model)
	# Hide the procedural body — GLB replaces it.
	for body_name in ["Torso", "ArmL", "ArmR", "LegL", "LegR"]:
		var n: Node = get_node_or_null(NodePath("Visuals/" + body_name))
		if n is MeshInstance3D:
			(n as MeshInstance3D).visible = false
	# Wire up the GLB's baked AnimationPlayer.
	_anim_player = _find_animation_player(model)
	if _anim_player:
		for n in _anim_player.get_animation_list():
			if n in _ANIM_LOOPED:
				var anim: Animation = _anim_player.get_animation(n)
				if anim:
					anim.loop_mode = Animation.LOOP_LINEAR
		_play_anim(_ANIM_IDLE)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var found: AnimationPlayer = _find_animation_player(c)
		if found:
			return found
	return null


func _play_anim(anim: String) -> void:
	if _anim_player == null or anim == _current_anim:
		return
	if not _anim_player.has_animation(anim):
		return
	_current_anim = anim
	var blend: float = 0.0 if anim == _ANIM_DIE else 0.12
	_anim_player.play(anim, blend)


func _select_anim() -> String:
	if is_dead:
		return _ANIM_DIE
	var horiz: float = Vector2(velocity.x, velocity.z).length()
	if horiz > 7.5:
		return _ANIM_SPRINT
	if horiz > 0.4:
		return _ANIM_WALK
	return _ANIM_IDLE


func _unhandled_input(event: InputEvent) -> void:
	if not is_local or not is_human_input or is_dead:
		return
	# Mouse-look — gated on CAPTURED. When mouse is loose (pause menu open,
	# Cmd-Tab'd away, browser focus stolen), event.relative still fires but
	# from cursor edge-clamps and would jerk the view. Same pattern as
	# arena-shooter-3d/scripts/player.gd:243.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_aim_yaw -= event.relative.x * mouse_sensitivity
		_aim_pitch -= event.relative.y * mouse_sensitivity
		_aim_pitch = clampf(_aim_pitch, -PI * 0.49, PI * 0.49)
	# Click-anywhere-to-recapture. If the mouse is loose AND user left-clicks
	# in the game world (not on pause-menu UI — those clicks are consumed by
	# the button's GUI input first), re-grab the mouse. Lets the user "un-pause"
	# the game without a Resume button. Touchscreen guard so this doesn't fire
	# on phones where tap is the normal control.
	if event is InputEventMouseButton \
			and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE \
			and not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			# Pause menu owns Esc — see pause_menu.gd._unhandled_input. We don't
			# touch mouse_mode here anymore; it would race with the menu's toggle.
			pass
		elif event.keycode == KEY_F1:
			# Convenience for testing — re-grab mouse.
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.keycode >= KEY_1 and event.keycode <= KEY_4:
			var slot: int = event.keycode - KEY_1
			equip_slot(slot)


func equip_slot(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= loadout.size():
		return
	var new_weapon: Resource = loadout[slot_index]
	if new_weapon == null or new_weapon == weapon_def:
		return
	# Stash current ammo before switching.
	if weapon_def != null:
		_ammo_state[weapon_def.id] = {"in_mag": ammo_in_mag, "reserve": ammo_reserve}
	weapon_def = new_weapon
	# Restore the new weapon's saved ammo (or initialize on first equip).
	if not _ammo_state.has(new_weapon.id):
		_ammo_state[new_weapon.id] = {"in_mag": new_weapon.magazine, "reserve": new_weapon.reserve}
	_sync_ammo_from_state()
	is_reloading = false
	time_until_next_shot = 0.0
	weapon_switched.emit(new_weapon)
	ammo_changed.emit(ammo_in_mag, ammo_reserve)


func _sync_ammo_from_state() -> void:
	if weapon_def == null:
		return
	var s: Dictionary = _ammo_state.get(weapon_def.id, {})
	ammo_in_mag = s.get("in_mag", weapon_def.magazine)
	ammo_reserve = s.get("reserve", weapon_def.reserve)


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	_step_invincibility_blink(delta)
	# DS-M3: snapshot-only mode — never simulate locally. If we're the local
	# human, send our input bits up to the server each tick. Either way, we
	# just render whatever the server tells us via push_snapshot.
	if is_snapshot_only:
		if is_local and is_human_input:
			_apply_camera_kick(delta)
			_send_input_to_server()
			# Local cosmetic fire feedback — server is the damage authority, but
			# the player still expects tracer / muzzle flash / sound / recoil
			# kick / ammo countdown to happen when they pull the trigger.
			_step_weapon_visuals_only(delta)
		_apply_remote_state(delta)
		_play_anim(_select_anim())
		return
	# Authoritative branch — this controller owns simulation.
	# is_local = local human / bot. use_remote_input = server simulating a
	# remote peer from received input RPCs. Mutually exclusive in practice.
	if is_local:
		_apply_camera_kick(delta)
		_step_movement(delta)
		_step_weapon(delta)
		_step_net_send(delta)
	elif use_remote_input:
		# Apply the latest received aim BEFORE _step_movement so transform.basis
		# (used to compute world-space move vector) reflects the client's look.
		_apply_aim_from_remote_input()
		_step_movement(delta)
		# DS-M4: tick weapon cooldown + reload timer server-side. Fire is edge-
		# triggered in push_remote_input (just_pressed semantics) so we don't
		# need to read Input.* here. Reload uses a similar edge.
		_step_weapon_server(delta)
	else:
		_apply_remote_state(delta)
	# Drive the GLB animation state based on actual horizontal velocity.
	_play_anim(_select_anim())


## DS-M3: client-side input sender. Packs the current Input.* state into a bit
## field and ships it to the server via client_send_input. Throttled to the
## same NET_SYNC_INTERVAL so we don't flood the channel.
var _input_tick: int = 0
var _input_send_accum: float = 0.0


func _send_input_to_server() -> void:
	_input_send_accum += get_physics_process_delta_time()
	if _input_send_accum < NET_SYNC_INTERVAL:
		return
	_input_send_accum = 0.0
	var bits: int = 0
	if Input.is_action_pressed(&"move_forward"): bits |= NetProtocol.INPUT_FORWARD
	if Input.is_action_pressed(&"move_back"):    bits |= NetProtocol.INPUT_BACK
	if Input.is_action_pressed(&"move_left"):    bits |= NetProtocol.INPUT_LEFT
	if Input.is_action_pressed(&"move_right"):   bits |= NetProtocol.INPUT_RIGHT
	if Input.is_action_pressed(&"jump"):         bits |= NetProtocol.INPUT_JUMP
	if Input.is_action_pressed(&"sprint"):       bits |= NetProtocol.INPUT_SPRINT
	if Input.is_action_pressed(&"fire"):         bits |= NetProtocol.INPUT_FIRE
	if Input.is_action_pressed(&"reload"):       bits |= NetProtocol.INPUT_RELOAD
	if Input.is_action_pressed(&"ability"):      bits |= NetProtocol.INPUT_ABILITY
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	_input_tick += 1
	net_rpc.client_send_input.rpc_id(1, _input_tick, bits, _aim_yaw, _aim_pitch)


## DS-M3: pushes a snapshot entry into this player's interpolator, replacing
## the older _net_apply_state path. Called by GameController when it receives
## a server_send_snapshot RPC.
func push_snapshot(now_ms: float, pos: Vector3, yaw: float, pitch: float) -> void:
	_net_remote_pos = pos
	_net_remote_yaw = yaw
	_net_remote_pitch = pitch
	_net_has_remote_target = true
	if _interpolator != null:
		_interpolator.push_snapshot(0, now_ms, pos, yaw, pitch)


## DS-M2: public API used by the dedicated server's GameController to deliver
## a client_send_input RPC payload to this controller. Older or duplicate ticks
## are silently dropped (last-write-wins ordering).
## DS-M4: also handles edge-triggered actions (FIRE, RELOAD, ABILITY) so the
## server resolves them immediately when the bit flips 0→1.
func push_remote_input(tick: int, bits: int, yaw: float, pitch: float) -> void:
	# H1: sanitize all client-supplied fields BEFORE accepting the frame.
	# Reject NaN/Inf aim (would corrupt CharacterBody3D transform on next sim).
	if not (is_finite(yaw) and is_finite(pitch)):
		return
	# Drop replays / out-of-order, AND wildly-future ticks. A peer cramming
	# `tick = INT_MAX` on its first packet would otherwise pin _remote_input_tick
	# permanently and lock out every legitimate subsequent input frame.
	if tick <= _remote_input_tick:
		return
	if _remote_input_tick >= 0 and tick > _remote_input_tick + NetProtocol.MAX_INPUT_TICK_JUMP:
		return
	# Mask to the defined input bits; ignore unknown high bits.
	bits = bits & NetProtocol.INPUT_BITS_MASK
	# Reject snap-aim deltas larger than a human can produce in one tick. Only
	# applied once we have a baseline (second frame onward).
	if _remote_input_tick >= 0:
		var dy: float = absf(wrapf(yaw - _remote_input_yaw, -PI, PI))
		var dp: float = absf(pitch - _remote_input_pitch)
		if dy > NetProtocol.MAX_AIM_DELTA_RAD or dp > NetProtocol.MAX_AIM_DELTA_RAD:
			return
	# Edge-trigger bits that flipped from 0→1 since last accepted frame.
	var just_pressed: int = bits & (~_remote_input_bits)
	_remote_input_just_pressed = just_pressed
	_remote_input_tick = tick
	_remote_input_bits = bits
	_remote_input_yaw = yaw
	_remote_input_pitch = clampf(pitch, -PI * 0.49, PI * 0.49)
	# Apply aim immediately so a fire issued in the same tick uses the freshest
	# look direction (matters for snap-aim sniper shots).
	if use_remote_input:
		_apply_aim_from_remote_input()
	# Fire: hitscan weapons fire on every press while held (auto fire works too
	# because just_pressed is OR'd each tick when the bit stays held; we gate
	# via time_until_next_shot for cooldown).
	if use_remote_input and weapon_def != null:
		var fire_held: bool = (bits & NetProtocol.INPUT_FIRE) != 0
		var fire_should: bool = (weapon_def.auto and fire_held) or \
			(not weapon_def.auto and (just_pressed & NetProtocol.INPUT_FIRE) != 0)
		if fire_should:
			try_fire()
		if (just_pressed & NetProtocol.INPUT_RELOAD) != 0:
			start_reload()
		if (just_pressed & NetProtocol.INPUT_ABILITY) != 0:
			try_activate_ability()


func _apply_aim_from_remote_input() -> void:
	_aim_yaw = _remote_input_yaw
	_aim_pitch = clampf(_remote_input_pitch, -PI * 0.49, PI * 0.49)
	rotation.y = _aim_yaw
	head.rotation.x = _aim_pitch


## Toggle the player's visible meshes on/off rapidly during the invincibility
## window so others can see that the player can't be killed yet. Skipped
## entirely for the local human, whose Visuals must stay hidden (otherwise
## the first-person camera sees the inside of its own character model).
func _step_invincibility_blink(delta: float) -> void:
	if is_local and is_human_input:
		return
	var now_s: float = Time.get_ticks_msec() / 1000.0
	if now_s < _invincible_until:
		_last_blink_toggle += delta
		if _last_blink_toggle >= INVINCIBILITY_BLINK_PERIOD:
			_last_blink_toggle = 0.0
			_blink_visible = not _blink_visible
			var v: Node = get_node_or_null(^"Visuals")
			if v != null:
				v.visible = _blink_visible
	elif not _blink_visible:
		# Window closed — ensure visuals are back on.
		_blink_visible = true
		var v2: Node = get_node_or_null(^"Visuals")
		if v2 != null:
			v2.visible = true


## Single entry point for setting aim from outside (bots, tests, AI). Always
## use this instead of writing `rotation.y` / `head.rotation.x` directly —
## the camera-kick layer will overwrite direct writes next frame.
func set_aim(yaw: float, pitch: float) -> void:
	_aim_yaw = yaw
	_aim_pitch = clampf(pitch, -PI * 0.49, PI * 0.49)
	# Apply immediately so callers don't have to await a frame for the new
	# aim to be observable (raycast tests rely on this).
	rotation.y = _aim_yaw + _camera_kick.x
	head.rotation.x = _aim_pitch + _camera_kick.y


## Decay the camera kick toward zero and compose it with the mouse-driven
## aim values to produce the actual transform.
func _apply_camera_kick(delta: float) -> void:
	if _camera_kick.length_squared() > 0.000001:
		# Exponential decay — frame-rate independent.
		_camera_kick *= exp(-_CAMERA_KICK_DECAY * delta)
	# Compose final rotation.
	rotation.y = _aim_yaw + _camera_kick.x
	head.rotation.x = clampf(_aim_pitch + _camera_kick.y, -PI * 0.49, PI * 0.49)


## Applied on each successful shot — modest upward muzzle climb + a touch of
## horizontal sway so AR bursts don't feel static.
func _apply_recoil_kick() -> void:
	_camera_kick.y += _RECOIL_KICK_PITCH
	_camera_kick.x += randf_range(-0.006, 0.006)


## Applied when this player takes damage — small jolt in a random direction.
func _apply_hit_shake() -> void:
	_camera_kick.x += randf_range(-_HIT_SHAKE_AMOUNT, _HIT_SHAKE_AMOUNT)
	_camera_kick.y += randf_range(-_HIT_SHAKE_AMOUNT, _HIT_SHAKE_AMOUNT)


# ── Audio helpers ─────────────────────────────────────────────────────────
func _play_3d(stream: AudioStream) -> void:
	if audio_3d == null or stream == null:
		return
	audio_3d.stream = stream
	audio_3d.play()


func _play_shoot_sound() -> void:
	_play_3d(SFX_SHOOT)


func _play_hit_sound() -> void:
	_play_3d(SFX_HIT)


func _step_movement(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * gravity_multiplier * delta

	# Determine input source: keyboard for local human, remote bits for DS
	# server-simulated player, zero for bots (BotPlayer overrides this whole
	# method).
	var input_x: float = 0.0
	var input_z: float = 0.0
	var jump_pressed: bool = false
	var sprint_pressed: bool = false
	if use_remote_input:
		var bits: int = _remote_input_bits
		input_x = float((bits & NetProtocol.INPUT_RIGHT) != 0) - float((bits & NetProtocol.INPUT_LEFT) != 0)
		input_z = float((bits & NetProtocol.INPUT_BACK) != 0) - float((bits & NetProtocol.INPUT_FORWARD) != 0)
		jump_pressed = (bits & NetProtocol.INPUT_JUMP) != 0
		sprint_pressed = (bits & NetProtocol.INPUT_SPRINT) != 0
	elif is_human_input:
		input_x = float(Input.is_action_pressed(&"move_right")) - float(Input.is_action_pressed(&"move_left"))
		input_z = float(Input.is_action_pressed(&"move_back")) - float(Input.is_action_pressed(&"move_forward"))
		jump_pressed = Input.is_action_pressed(&"jump")
		sprint_pressed = Input.is_action_pressed(&"sprint")

	if jump_pressed and is_on_floor():
		velocity.y = jump_velocity

	var dir: Vector3 = (transform.basis * Vector3(input_x, 0, input_z))
	if dir.length() > 0.001:
		dir = dir.normalized()
	var speed: float = move_speed * move_speed_multiplier
	if sprint_pressed:
		speed *= sprint_multiplier
	var target_vx: float = dir.x * speed
	var target_vz: float = dir.z * speed
	# Smooth blending toward target velocity so oil/ice zones feel slippy.
	var alpha: float = clampf(ground_friction * delta, 0.0, 1.0)
	velocity.x = lerpf(velocity.x, target_vx, alpha)
	velocity.z = lerpf(velocity.z, target_vz, alpha)
	move_and_slide()


## DS-M3 client-side fire feedback. When the local human is in snapshot-only
## mode (DS client), the actual damage resolution happens server-side, but the
## client still needs cosmetic feedback per shot: tracer, muzzle flash, recoil,
## fire sound, ammo countdown. This is the visual-only side of try_fire().
func _step_weapon_visuals_only(delta: float) -> void:
	time_until_next_shot = maxf(0.0, time_until_next_shot - delta)
	if is_reloading:
		reload_remaining -= delta
		if reload_remaining <= 0.0:
			_finish_reload()
		return
	if weapon_def == null:
		return
	# Manual reload. The R-key press also goes to the server via INPUT_RELOAD
	# (set in _send_input_to_server), so server + local stay in sync. Without
	# this branch the local ammo UI / "RELOADING" indicator never updates and
	# the DS-mode client looks frozen after pressing R.
	if Input.is_action_just_pressed(&"reload"):
		start_reload()
		return
	# Edge-detect or held-fire depending on weapon kind. Matches try_fire().
	var should_fire: bool = false
	if weapon_def.auto:
		should_fire = Input.is_action_pressed(&"fire")
	else:
		should_fire = Input.is_action_just_pressed(&"fire")
	if not should_fire:
		return
	# Local-cooldown gate — keeps the visuals in sync with what the server
	# will actually accept (same fire interval).
	if time_until_next_shot > 0.0:
		return
	# Auto-reload when the mag is empty. The server-side try_fire does the
	# same (line 712), but without this branch the DS-client local copy is
	# stuck at 0 forever: visuals stop, R-key feels dead, "can't continue
	# playing" (user-reported bug). Returning here is important — we don't
	# want to fire on the same frame the reload starts.
	if ammo_in_mag <= 0:
		start_reload()
		return
	ammo_in_mag -= 1
	time_until_next_shot = weapon_def.fire_interval_seconds()
	ammo_changed.emit(ammo_in_mag, ammo_reserve)
	# Local hit info only used for muzzle flash position + tracer endpoint;
	# the server-side raycast is the one that actually applies damage.
	var hit_info: Dictionary = _local_hitscan()
	fired.emit(weapon_def, hit_info)
	_spawn_local_tracer(weapon_def.bullet_color, hit_info)
	_play_shoot_sound()
	_spawn_muzzle_flash()
	_apply_recoil_kick()
	if not hit_info.is_empty():
		var collider: Node = hit_info.get("collider", null)
		if collider != null and not collider.has_meta(&"owner_player"):
			_spawn_wall_impact(hit_info.position, hit_info.normal)


## DS-M4: minimal weapon tick for server-simulated players. Just decrements
## cooldown + advances reload; the actual fire/reload triggers come from
## push_remote_input edge detection, not Input.*.
func _step_weapon_server(delta: float) -> void:
	time_until_next_shot = maxf(0.0, time_until_next_shot - delta)
	if is_reloading:
		reload_remaining -= delta
		if reload_remaining <= 0.0:
			_finish_reload()


func _step_weapon(delta: float) -> void:
	time_until_next_shot = maxf(0.0, time_until_next_shot - delta)
	if is_reloading:
		reload_remaining -= delta
		if reload_remaining <= 0.0:
			_finish_reload()
		return

	if Input.is_action_just_pressed(&"reload"):
		start_reload()
		return

	if Input.is_action_just_pressed(&"ability"):
		try_activate_ability()

	if weapon_def == null:
		return

	var should_fire: bool = false
	if weapon_def.auto:
		should_fire = Input.is_action_pressed(&"fire")
	else:
		should_fire = Input.is_action_just_pressed(&"fire")

	if should_fire:
		try_fire()


# ── public API (testable + RPC-callable) ──────────────────────────────────
func try_fire() -> bool:
	if is_dead or is_reloading or time_until_next_shot > 0.0 or weapon_def == null:
		return false
	if ammo_in_mag <= 0:
		start_reload()
		return false
	# C3: when running server-authoritative in MP, the actual ammo/cooldown
	# commit is deferred to `_on_client_fire_server` so it runs through the
	# same gate as direct client_fire RPCs (which bypass this function).
	# Without this, an attacker could fire-spam via raw client_fire because
	# the server-side handler had no cooldown check of its own.
	var server_authoritative: bool = _is_networked() and multiplayer.is_server()
	if not server_authoritative:
		ammo_in_mag -= 1
		time_until_next_shot = weapon_def.fire_interval_seconds()
		ammo_changed.emit(ammo_in_mag, ammo_reserve)
	# Local hitscan is for cosmetic feedback only (tracer endpoint, muzzle pos);
	# skip it on a dedicated server which has no visuals.
	var hit_info: Dictionary = {} if server_authoritative and not is_local else _local_hitscan()
	fired.emit(weapon_def, hit_info)
	# Visible bullet trail + muzzle flash + recoil kick + wall impact + sound
	# for the local shooter. Server-authoritative damage still happens via
	# the network branch below, but these visuals run client-side immediately.
	if is_local:
		_spawn_local_tracer(weapon_def.bullet_color, hit_info)
		_play_shoot_sound()
		if is_human_input:
			# Heavy per-shot effects (point light + particles + recoil kick) only
			# for the actual human shooter. Bots fire too often to afford this.
			_spawn_muzzle_flash()
			_apply_recoil_kick()
			if not hit_info.is_empty():
				var collider: Node = hit_info.get("collider", null)
				if collider != null and not collider.has_meta(&"owner_player"):
					_spawn_wall_impact(hit_info.position, hit_info.normal)

	if _is_networked():
		# Multiplayer: damage is server-authoritative. We send the fire intent
		# to the host along with our INSTANTANEOUS aim so the server raycasts
		# in the exact direction we were looking — not its interp-delayed view
		# of our transform (which lags ~100ms and makes shots miss fast aim).
		var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
		if net_rpc != null:
			if multiplayer.is_server():
				# call_remote excludes self, so emit the signal directly so the
				# host's GameController handler still picks it up. We pass this
				# player's *authority* peer (the human pulling the trigger), not
				# multiplayer.get_unique_id() which on a dedicated server is 1.
				net_rpc.client_fire_received.emit(get_multiplayer_authority(), weapon_def.id, _aim_yaw, _aim_pitch)
			else:
				net_rpc.client_fire.rpc_id(1, weapon_def.id, _aim_yaw, _aim_pitch)
		# Local hit-feedback only — actual HP change waits for server broadcast.
	elif not hit_info.is_empty():
		# Practice / offline mode: apply hit immediately.
		_apply_local_hit(hit_info)
	return true


## True when a real network transport is active. Discriminates against
## Godot's default OfflineMultiplayerPeer (which paradoxically reports
## CONNECTION_CONNECTED — verified empirically with 4.6.2).
func _is_networked() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null:
		return false
	return not (peer is OfflineMultiplayerPeer)


## Activate the equipped weapon's ability. Returns true if it fired.
## Buff abilities stay active for ability.duration_ms; powershot arms the
## next shot; bulletwave fires the grid immediately.
func try_activate_ability() -> bool:
	if weapon_def == null or weapon_def.ability == null:
		return false
	var a: Resource = weapon_def.ability
	if String(a.name).is_empty():
		return false
	var now_s: float = Time.get_ticks_msec() / 1000.0
	if now_s < _ability_cooldown_until:
		return false
	_ability_cooldown_until = now_s + float(a.cooldown_ms) / 1000.0
	ability_activated.emit(a)
	match a.type:
		&"buff":
			_buff_def = a
			_buff_active_until = now_s + maxf(0.1, float(a.duration_ms) / 1000.0)
			return true
		&"powershot":
			_powershot_armed = a
			return true
		&"bulletwave":
			_fire_bullet_wave(a)
			return true
		_:
			# Charge / blink / freeze / drone / aoe / heal — placeholders that
			# at least obey the cooldown so the kid can see the icon refresh
			# when M4 implements them. No-op for now.
			return true


## Fire a grid of extra pellets in one frame. Used by SG-8's Bullet Wave
## ability — 6×6 = 36 pellets at low individual damage, big spread.
func _fire_bullet_wave(a: Resource) -> void:
	if weapon_def == null:
		return
	var grid_w: int = maxi(2, a.grid_w if a.grid_w > 0 else 6)
	var grid_h: int = maxi(2, a.grid_h if a.grid_h > 0 else 6)
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var origin: Vector3 = camera.global_position
	var forward: Vector3 = -camera.global_transform.basis.z
	var right: Vector3 = camera.global_transform.basis.x
	var up: Vector3 = camera.global_transform.basis.y
	var cone_half: float = 0.18   # radians — wide spread
	for ix in grid_w:
		for iy in grid_h:
			var fx: float = (float(ix) / float(grid_w - 1)) * 2.0 - 1.0
			var fy: float = (float(iy) / float(grid_h - 1)) * 2.0 - 1.0
			var dir: Vector3 = (forward + right * (fx * cone_half) + up * (fy * cone_half)).normalized()
			var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * SHOOT_RANGE)
			query.collision_mask = SHOOT_MASK
			query.collide_with_areas = true
			query.collide_with_bodies = true
			var ex: Array[RID] = [self.get_rid(), head_hitbox.get_rid(), body_hitbox.get_rid()]
			query.exclude = ex
			var hit: Dictionary = space.intersect_ray(query)
			if hit.is_empty():
				continue
			var collider: Node = hit.collider
			if collider == null:
				continue
			# Light damage per pellet so 36 of them still feel fair.
			if collider.has_meta(&"owner_player"):
				var victim: Node = collider.get_meta(&"owner_player")
				var is_head_v: bool = collider.get_meta(&"is_head", false)
				var per_dmg: float = weapon_def.damage * 0.5
				if is_head_v:
					per_dmg *= weapon_def.headshot_multiplier
				if victim.has_method(&"apply_damage"):
					victim.apply_damage(per_dmg, self)
	_play_3d(SFX_SHOOT)


func start_reload() -> void:
	if is_reloading or weapon_def == null:
		return
	if weapon_def.no_reload:
		return
	if ammo_reserve <= 0 and ammo_in_mag == weapon_def.magazine:
		return
	is_reloading = true
	reload_remaining = float(weapon_def.reload_time_ms) / 1000.0


func _finish_reload() -> void:
	is_reloading = false
	if weapon_def == null:
		return
	if weapon_def.no_reload:
		ammo_in_mag = weapon_def.magazine
	else:
		var needed: int = weapon_def.magazine - ammo_in_mag
		var taken: int = mini(needed, ammo_reserve)
		ammo_in_mag += taken
		ammo_reserve -= taken
	ammo_changed.emit(ammo_in_mag, ammo_reserve)


func apply_damage(dmg: float, attacker: Node) -> void:
	if is_dead:
		return
	if Time.get_ticks_msec() / 1000.0 < _invincible_until:
		return
	last_attacker = attacker
	hp = maxf(0.0, hp - dmg)
	hp_changed.emit(hp, max_hp)
	_play_hit_sound()
	if is_local:
		_apply_hit_shake()
	if hp <= 0.0:
		_die()


func _die() -> void:
	is_dead = true
	visible = false
	collision_layer = 0
	collision_mask = 0
	head_hitbox.monitoring = false
	body_hitbox.monitoring = false
	_play_3d(SFX_DEATH)
	died.emit(last_attacker)


func respawn(at: Vector3) -> void:
	global_position = at
	velocity = Vector3.ZERO
	hp = max_hp
	is_reloading = false
	time_until_next_shot = 0.0
	# Reset camera state — kick zeroed, base angles re-pulled from transform.
	_camera_kick = Vector2.ZERO
	if is_local:
		_aim_yaw = rotation.y
		_aim_pitch = head.rotation.x
	# Refill every weapon in the loadout, not just the currently held one.
	for w in loadout:
		if w != null:
			_ammo_state[w.id] = {"in_mag": w.magazine, "reserve": w.reserve}
	if weapon_def != null:
		_sync_ammo_from_state()
	is_dead = false
	visible = true
	collision_layer = 1 << 1
	collision_mask = (1 << 0)
	head_hitbox.monitoring = true
	body_hitbox.monitoring = true
	hp_changed.emit(hp, max_hp)
	ammo_changed.emit(ammo_in_mag, ammo_reserve)
	# Start the invincibility window — _physics_process will blink the model
	# until the window closes.
	_invincible_until = Time.get_ticks_msec() / 1000.0 + RESPAWN_INVINCIBILITY_SEC
	_last_blink_toggle = 0.0
	_blink_visible = true
	# Re-hide local-human visuals after the visibility=true cascade above. If
	# anything (blink, future code) ever flips Visuals.visible to true for the
	# local player, the first-person camera sees the inside of its own model.
	if is_local and is_human_input:
		_hide_first_person_obstructions()
	# Respawn chime — local audio for the player themselves (don't spam
	# everyone's spatial channel with a 2D sound).
	if is_local and audio_local != null:
		audio_local.stream = SFX_RESPAWN
		audio_local.play()


# ── shooting ──────────────────────────────────────────────────────────────
## Brief bright flash at the muzzle: an OmniLight3D pulse + a small emissive
## sphere. Both auto-free after ~80ms. Color follows the weapon's bullet_color.
func _spawn_muzzle_flash() -> void:
	if weapon_def == null:
		return
	var color: Color = weapon_def.bullet_color
	var flash_pos: Vector3 = camera.global_transform * Vector3(0.18, -0.14, -0.5)

	# Dynamic point light — short and bright, faded by tween.
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 6.0
	light.omni_range = 4.5
	light.omni_attenuation = 1.5
	get_tree().root.add_child(light)
	light.global_position = flash_pos
	var tl: Tween = light.create_tween()
	tl.tween_property(light, "light_energy", 0.0, 0.08)
	tl.tween_callback(light.queue_free)

	# Tiny visible spark sphere so even un-lit surroundings show the flash.
	var spark := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.08
	sm.height = 0.16
	spark.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 8.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark.material_override = mat
	get_tree().root.add_child(spark)
	spark.global_position = flash_pos
	var ts: Tween = spark.create_tween()
	ts.tween_property(mat, "emission_energy_multiplier", 0.0, 0.07)
	ts.tween_callback(spark.queue_free)


## A short black scuff + a small burst of glowing particles where a bullet
## hits the world. Only fires on non-player hits (we have tracer + hitmarker
## for player hits already).
func _spawn_wall_impact(world_pos: Vector3, normal: Vector3) -> void:
	# Scuff mark — flattened sphere lying on the surface.
	var decal := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.05
	sm.height = 0.03
	decal.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.05, 0.05, 0.9)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	decal.material_override = mat
	get_tree().root.add_child(decal)
	decal.global_position = world_pos + normal * 0.01
	# Orient the flat disk so its Y axis points along the surface normal.
	if normal.length_squared() > 0.0:
		var up: Vector3 = normal.normalized()
		var fwd: Vector3 = up.cross(Vector3.UP)
		if fwd.length_squared() < 0.001:
			fwd = up.cross(Vector3.RIGHT)
		fwd = fwd.normalized()
		var right: Vector3 = up.cross(fwd).normalized()
		decal.global_transform.basis = Basis(right, up, fwd)
	var td: Tween = decal.create_tween()
	td.tween_interval(1.6)
	td.tween_property(mat, "albedo_color:a", 0.0, 0.6)
	td.tween_callback(decal.queue_free)

	# Spark burst — CPUParticles3D one-shot, 5 emissive particles.
	var sparks := CPUParticles3D.new()
	sparks.amount = 6
	sparks.lifetime = 0.45
	sparks.one_shot = true
	sparks.explosiveness = 1.0
	sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINT
	sparks.direction = normal
	sparks.spread = 60.0
	sparks.initial_velocity_min = 2.0
	sparks.initial_velocity_max = 6.0
	sparks.gravity = Vector3(0, -8.0, 0)
	sparks.scale_amount_min = 0.04
	sparks.scale_amount_max = 0.08
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(1.0, 0.85, 0.4)
	smat.emission_enabled = true
	smat.emission = Color(1.0, 0.7, 0.2)
	smat.emission_energy_multiplier = 5.0
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var spark_mesh := SphereMesh.new()
	spark_mesh.radius = 0.025
	spark_mesh.height = 0.05
	sparks.mesh = spark_mesh
	sparks.material_override = smat
	get_tree().root.add_child(sparks)
	sparks.global_position = world_pos
	# Auto-free after particles finish.
	var tp: Tween = sparks.create_tween()
	tp.tween_interval(sparks.lifetime + 0.1)
	tp.tween_callback(sparks.queue_free)


## Traveling-bullet tracer adapted from arena-shooter-3d/scripts/player.gd
## (line 635). A glowing sphere head flies from muzzle to impact over
## 0.05-0.25s (distance-scaled) with a thin streak fading behind it. This
## reads as a real projectile, not the static line v0.3 used to draw.
func _spawn_local_tracer(color: Color, hit_info: Dictionary) -> void:
	var muzzle_world: Vector3 = camera.global_transform * Vector3(0.18, -0.16, -0.45)
	var end_pos: Vector3
	var hit_player: bool = false
	if hit_info.is_empty():
		end_pos = camera.global_position + (-camera.global_transform.basis.z) * 120.0
	else:
		end_pos = hit_info.position
		var c: Node = hit_info.get("collider", null)
		hit_player = c != null and c.has_meta(&"owner_player")
	var dist: float = muzzle_world.distance_to(end_pos)
	if dist < 0.5:
		return
	# Capped distance-scaled flight time so a sniper shot has visible travel
	# but close-range fire still feels snappy.
	var flight_time: float = clampf(0.05 + dist * 0.0025, 0.05, 0.25)
	# Hit-player tracers tint slightly red so even peripheral vision tells
	# the kid "you connected" vs "you missed".
	var trail_color: Color = Color(1, 0.45, 0.45) if hit_player else color

	# Bullet head — glowing sphere that flies from muzzle to impact.
	var bullet_head := MeshInstance3D.new()
	var bullet_mesh := SphereMesh.new()
	bullet_mesh.radius = 0.08
	bullet_mesh.height = 0.16
	bullet_mesh.radial_segments = 8
	bullet_mesh.rings = 4
	bullet_head.mesh = bullet_mesh
	bullet_head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bullet_mat := StandardMaterial3D.new()
	bullet_mat.albedo_color = trail_color
	bullet_mat.emission_enabled = true
	bullet_mat.emission = trail_color
	bullet_mat.emission_energy_multiplier = 6.5
	bullet_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bullet_head.material_override = bullet_mat
	get_tree().root.add_child(bullet_head)
	bullet_head.global_position = muzzle_world
	var ht: Tween = bullet_head.create_tween()
	ht.tween_property(bullet_head, "global_position", end_pos, flight_time)
	ht.tween_callback(bullet_head.queue_free)

	# Thin streak that fades behind the bullet head.
	var trail := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.04, 0.04, dist)
	trail.mesh = bm
	trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var trail_mat := StandardMaterial3D.new()
	trail_mat.albedo_color = Color(trail_color.r, trail_color.g, trail_color.b, 0.55)
	trail_mat.emission_enabled = true
	trail_mat.emission = trail_color
	trail_mat.emission_energy_multiplier = 3.0
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail.material_override = trail_mat
	get_tree().root.add_child(trail)
	trail.global_position = (muzzle_world + end_pos) * 0.5
	# look_at fails on collinear vectors (shot straight up/down). Skip orient.
	var dir_to_end: Vector3 = end_pos - trail.global_position
	if absf(dir_to_end.normalized().dot(Vector3.UP)) < 0.99 and dir_to_end.length() > 0.01:
		trail.look_at(end_pos, Vector3.UP, true)
	var tt: Tween = trail.create_tween()
	tt.tween_property(trail_mat, "albedo_color:a", 0.0, flight_time * 0.8)
	tt.parallel().tween_property(trail_mat, "emission_energy_multiplier", 0.0, flight_time * 0.8)
	tt.tween_callback(trail.queue_free)


## Performs the hitscan and returns hit info, but does NOT apply damage —
## that's the caller's job (local mode applies immediately; networked mode
## delegates to server via RPC).
func _local_hitscan() -> Dictionary:
	if weapon_def == null:
		return {}
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = camera.global_position
	var aim_dir: Vector3 = -camera.global_transform.basis.z
	if weapon_def.spread > 0.0:
		aim_dir = _apply_spread(aim_dir, weapon_def.spread)
	var to: Vector3 = from + aim_dir * SHOOT_RANGE

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = SHOOT_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = true

	var exclude_rids: Array[RID] = []
	exclude_rids.append(self.get_rid())
	exclude_rids.append(head_hitbox.get_rid())
	exclude_rids.append(body_hitbox.get_rid())
	query.exclude = exclude_rids

	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return {}
	return {
		"position": hit.position,
		"normal": hit.normal,
		"collider": hit.collider,
	}


func _apply_local_hit(hit_info: Dictionary) -> void:
	var collider: Node = hit_info.collider
	if collider == null:
		return
	# Compose damage multipliers from active buff + armed powershot.
	var dmg_mult: float = 1.0
	var now_s: float = Time.get_ticks_msec() / 1000.0
	if _buff_def != null and now_s < _buff_active_until:
		dmg_mult *= _buff_def.damage_mult
	if _powershot_armed != null:
		dmg_mult *= _powershot_armed.damage_mult
		ability_consumed.emit(_powershot_armed)
		_powershot_armed = null

	if collider.has_meta(&"owner_player"):
		var victim: Node = collider.get_meta(&"owner_player")
		var is_head: bool = collider.get_meta(&"is_head", false)
		var dmg: float = _compute_damage(weapon_def, is_head) * dmg_mult
		if victim.has_method(&"apply_damage"):
			victim.apply_damage(dmg, self)
	elif collider.has_method(&"take_hit"):
		var is_head_dummy: bool = collider.name == &"HeadHitbox"
		collider.take_hit(weapon_def, is_head_dummy, self)


static func _compute_damage(weapon: Resource, is_head: bool) -> float:
	var dmg: float = weapon.damage
	if is_head:
		if weapon.instakill_headshot:
			return 999_999.0
		dmg *= weapon.headshot_multiplier
	return dmg


static func _apply_spread(dir: Vector3, spread: float) -> Vector3:
	var yaw: float = randf_range(-spread, spread)
	var pitch: float = randf_range(-spread, spread)
	var look_basis := Basis.looking_at(dir, Vector3.UP)
	return (look_basis * Vector3(yaw, pitch, -1.0)).normalized()


# ── Multiplayer position sync ─────────────────────────────────────────────
func _step_net_send(_delta: float) -> void:
	if not _is_networked():
		return
	var targets: Array = _net_broadcast_targets()
	if targets.is_empty():
		return
	_net_sync_accum += _delta
	if _net_sync_accum < NET_SYNC_INTERVAL:
		return
	_net_sync_accum = 0.0
	for peer_id in targets:
		_net_apply_state.rpc_id(peer_id, global_position, rotation.y, head.rotation.x)


## Picks which peers to send our position update to. On the host, prefers the
## game_controller's ready-peer set so we don't spray packets at clients whose
## scene isn't mounted yet. On clients, just use the full peer list (which is
## typically just the host).
func _net_broadcast_targets() -> Array:
	var my_id: int = multiplayer.get_unique_id()
	if multiplayer.is_server():
		var game: Node = get_tree().root.get_node_or_null(^"Game")
		if game != null and game.has_method(&"get_ready_peers"):
			var ready_set: Array = game.get_ready_peers()
			var out: Array = []
			for p in ready_set:
				if p != my_id:
					out.append(p)
			return out
	# Client: send to host (and any other peer we happen to know about).
	var all_peers: Array = multiplayer.get_peers()
	var out_c: Array = []
	for p in all_peers:
		if p != my_id:
			out_c.append(p)
	return out_c


func _apply_remote_state(delta: float) -> void:
	# DS-M3 / UX: for the LOCAL human in snapshot-only mode, the camera-aim
	# (yaw/pitch) is driven by Input here on the client and only the POSITION
	# comes from the snapshot. Otherwise mouse-look would feel rubber-bandy
	# (server's reply is 1 RTT behind whatever the user is doing). The server
	# uses what we send via client_send_input, so the loop is consistent.
	var preserve_aim: bool = is_local and is_snapshot_only
	# Prefer the 100ms-buffered interpolator path. Fall back to direct lerp
	# if no interpolator (shouldn't happen, but defensive).
	if _interpolator != null:
		var now_ms: float = float(Time.get_ticks_msec())
		var sample = _interpolator.sample(0, now_ms)
		if sample == null:
			return
		global_position = sample.pos
		if not preserve_aim:
			rotation.y = sample.yaw
			head.rotation.x = sample.pitch
		return
	if not _net_has_remote_target:
		return
	var t: float = clampf(delta * 18.0, 0.0, 1.0)
	global_position = global_position.lerp(_net_remote_pos, t)
	if not preserve_aim:
		rotation.y = lerp_angle(rotation.y, _net_remote_yaw, t)
		head.rotation.x = lerpf(head.rotation.x, _net_remote_pitch, t)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _net_apply_state(pos: Vector3, yaw: float, pitch: float) -> void:
	# C1: server-authoritative paths must NEVER accept client-pushed transforms.
	# - use_remote_input=true: server simulates this player from input bits;
	#   a transform-push RPC would let the client teleport its own avatar past
	#   collision and lag-comp.
	# - is_snapshot_only=true: DS-client; the only legitimate position source
	#   is server snapshots (push_snapshot). Refusing here also stops a peer
	#   from broadcasting its own transform to other clients in DS mode.
	if use_remote_input or is_snapshot_only:
		return
	# Only accept updates from this player's owning peer (listen-host path).
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return
	# Reject NaN/Inf — would corrupt physics state.
	if not (is_finite(pos.x) and is_finite(pos.y) and is_finite(pos.z) \
			and is_finite(yaw) and is_finite(pitch)):
		return
	_net_remote_pos = pos
	_net_remote_yaw = yaw
	_net_remote_pitch = pitch
	_net_has_remote_target = true
	if _interpolator != null:
		_interpolator.push_snapshot(0, float(Time.get_ticks_msec()), pos, yaw, pitch)
