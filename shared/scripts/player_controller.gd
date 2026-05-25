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

# Skin + animation state extracted to PlayerSkin (Node child added in _ready).
# Kenney skin table, per-skin Y-scales, AnimationPlayer wiring and play-state
# all live there. `apply_skin(idx)` below is a thin wrapper for back-compat
# with tests that call it via `.call("apply_skin", idx)`.
# Preload (not class_name) so headless tests don't need the editor to have
# populated the global script class registry first.
const _PlayerSkinScript = preload("res://shared/scripts/player_skin.gd")
const PlayerVisuals = preload("res://shared/scripts/player_visuals.gd")
var _skin: Node = null

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
	# Spin up the skin + animation subsystem. apply_skin below delegates here.
	_skin = _PlayerSkinScript.new()
	_skin.name = "_PlayerSkin"
	add_child(_skin)
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
		PlayerVisuals.attach_name_tag(self, player_name)


func _configure_camera_current() -> void:
	if camera == null:
		return
	camera.current = is_local
	if is_local:
		camera.make_current()


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
## Thin public wrapper around PlayerSkin.apply_skin. Kept on PlayerController
## so existing test code (`.call("apply_skin", idx)`) and external callers
## like the menu skin picker keep working without indirection.
func apply_skin(idx: int) -> void:
	if _skin == null:
		return
	var holder: Node3D = get_node_or_null(^"Visuals/ModelHolder") as Node3D
	var visuals: Node3D = get_node_or_null(^"Visuals") as Node3D
	_skin.apply_skin(idx, holder, visuals)


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
		if _skin != null: _skin.play_anim(_skin.select_anim(is_dead, velocity))
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
		# Listen-host server-side view of a remote peer: position comes from the
		# peer's _net_apply_state, but weapon state (time_until_next_shot,
		# is_reloading) is set authoritatively on this side by
		# _on_client_fire_server — and nothing else ticks it. Without this call,
		# the cooldown clamp from the FIRST fire stays >0 forever and every
		# subsequent fire RPC from the peer is rejected with "cooldown remaining"
		# (kid reported "B 打光所有子弹但 A 只掉 25 血"). Same applies to the
		# auto-reload triggered server-side on empty-mag: reload_remaining never
		# counts down, the peer is stuck in is_reloading=true forever.
		if _is_networked() and multiplayer.is_server():
			_step_weapon_server(delta)
	# Drive the GLB animation state based on actual horizontal velocity.
	if _skin != null: _skin.play_anim(_skin.select_anim(is_dead, velocity))


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
	# R6: clamp pitch BEFORE the delta check + before storing. Previously the
	# clamp only happened on store (line below), so a first frame with pitch=±100
	# would land a clamped ~±1.54 into _remote_input_pitch and then the SECOND
	# frame's `pitch - _remote_input_pitch` delta check used a poisoned baseline
	# (legit values would look like a giant aim snap and get rejected). yaw has
	# no analogous fix because it's wrap-modular — wrapf(-PI, PI) handles any
	# input.
	pitch = clampf(pitch, -PI * 0.49, PI * 0.49)
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
	_remote_input_pitch = pitch
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
	PlayerVisuals.spawn_local_tracer(get_tree(), camera, weapon_def.bullet_color, hit_info)
	_play_shoot_sound()
	PlayerVisuals.spawn_muzzle_flash(weapon_def, camera, get_tree())
	_apply_recoil_kick()
	if not hit_info.is_empty():
		var collider: Node = hit_info.get("collider", null)
		if collider != null and not collider.has_meta(&"owner_player"):
			PlayerVisuals.spawn_wall_impact(get_tree(), hit_info.position, hit_info.normal)


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
		PlayerVisuals.spawn_local_tracer(get_tree(), camera, weapon_def.bullet_color, hit_info)
		_play_shoot_sound()
		if is_human_input:
			# Heavy per-shot effects (point light + particles + recoil kick) only
			# for the actual human shooter. Bots fire too often to afford this.
			PlayerVisuals.spawn_muzzle_flash(weapon_def, camera, get_tree())
			_apply_recoil_kick()
			if not hit_info.is_empty():
				var collider: Node = hit_info.get("collider", null)
				if collider != null and not collider.has_meta(&"owner_player"):
					PlayerVisuals.spawn_wall_impact(get_tree(), hit_info.position, hit_info.normal)

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
	# Mirror the activation to the server so its view of this player has
	# the same buff/powershot state — fire_resolver reads from the server's
	# copy when applying damage mults. Skip when we ARE the server (host's
	# own player is one shared instance) and skip when we're not networked
	# (practice mode). Idempotent: the cooldown guard above means a redundant
	# server-side trigger (e.g., DS INPUT_ABILITY edge already fired) is a
	# no-op the second time.
	if _is_networked() and not multiplayer.is_server() and is_local:
		var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
		if net_rpc != null:
			net_rpc.client_use_ability.rpc_id(1)
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
	# R5 idempotency: a stale RPC, double damage path, or test hook that
	# calls _die() twice on the same player would otherwise re-emit `died`
	# and run scoring twice (H2 dedup only guards the respawn timer, not the
	# score counter). One line, zero risk.
	if is_dead:
		return
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
# Visual effect spawn helpers (muzzle flash / wall impact / bullet tracer)
# moved to shared/scripts/player_visuals.gd as PlayerVisuals static methods.
# Call sites above use PlayerVisuals.spawn_*(get_tree(), camera, ...).


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
