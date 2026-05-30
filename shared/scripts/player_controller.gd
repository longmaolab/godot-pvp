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
# Crouch: lower the camera/head + slow movement. Server-authoritative via
# the INPUT_CROUCH bit (DS / listen-host read it from remote input; local
# human reads the action directly). STAND_HEAD_Y must match the Head node's
# Y in player.tscn (1.0).
const STAND_HEAD_Y := 1.0
const CROUCH_HEAD_Y := 0.55
const CROUCH_SPEED_MULT := 0.5
const CROUCH_LERP := 12.0   # head-height ease speed
var _is_crouching: bool = false
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
# Real recoil: each shot climbs the aim (persists, must be controlled);
# auto-recovers when you stop firing. _recoil_owed tracks how much climb is
# still pending recovery. The server raycasts along the client's reported
# aim, so this recoil naturally lands shots higher during sustained fire.
var _recoil_owed: float = 0.0
var _recoil_idle: float = 0.0   # seconds since last shot (recovery delay)
# ADS (aim down sights): zooms FOV, slows movement, tightens spread. Mirror
# on the server from the INPUT_ADS bit so fire_resolver can read it.
var _is_ads: bool = false
var _base_fov: float = 75.0
const ADS_MOVE_MULT := 0.55
const ADS_FOV_LERP := 12.0

# ── Client-side prediction (DS-client local human only) ──────────────────
# The local player runs the SAME _step_movement the server runs, on the SAME
# map, so it responds to input THIS frame instead of ~150ms later when the
# snapshot lands. _reconcile_prediction then compares against the server
# snapshot and only corrects on genuine divergence — normal play stays inside
# the deadzone (no rubber-band), large desyncs (respawn/teleport) snap.
# Flip PREDICT_LOCAL_MOVEMENT to false for a one-line revert to pure snapshot
# rendering if live testing shows any rubber-banding.
const PREDICT_LOCAL_MOVEMENT := true
const PRED_SOFT_M := 2.5    # within this of the server: trust prediction fully
const PRED_HARD_M := 5.0    # beyond this: snap (respawn / teleport / big desync)
const PRED_EASE_RATE := 6.0 # soft-band correction lerp rate toward the server

# ── Slide (sprint + tap-crouch movement tech) ────────────────────────────
# Tapping crouch while sprinting fires a low, fast slide that decays back to
# crouch speed — the arena-shooter standard for closing/dodging. Resolved
# inside _step_movement so it works identically for local prediction and the
# server mirror (no new input bits; reuses SPRINT + CROUCH). Edge-detected per
# instance via _slide_crouch_was_down so a held crouch doesn't re-trigger.
var _slide_timer: float = 0.0
var _slide_cooldown: float = 0.0
var _slide_dir: Vector3 = Vector3.ZERO
var _slide_crouch_was_down: bool = false
const SLIDE_DURATION := 0.55
const SLIDE_SPEED_MULT := 1.9   # × move_speed at slide start (decays to CROUCH_SPEED_MULT)
const SLIDE_COOLDOWN := 0.7     # after a slide ends, before another can start
const SLIDE_ENTRY_FRAC := 0.8   # must be moving > this × move_speed to slide

# ── Lean / peek (server-authoritative) ───────────────────────────────────
# Holding lean shifts the head sideways + rolls the view so you can peek a
# corner with less body exposed. The SERVER mirror runs _step_movement too, so
# it offsets head_hitbox the same way → an enemy hits your peeking head where
# it's drawn (fair). Remote clients learn the peek from the snapshot lean flags
# and tilt the visible model to match the hitbox. _lean is the smoothed value;
# _lean_target is the instantaneous intent (-1 left / 0 / +1 right).
var _lean: float = 0.0
var _lean_target: float = 0.0
const LEAN_OFFSET := 0.45   # metres the head shifts sideways at full lean
const LEAN_ROLL := 0.13     # radians the head/body rolls into the lean
const LEAN_LERP := 11.0

# ── Melee ────────────────────────────────────────────────────────────────
# Quick close-range strike (F). Server-authoritative via the INPUT_MELEE edge
# (no new RPC — flows through the existing input pipeline like ability). A
# short forward ray against the hitbox layer applies MELEE_DAMAGE; HP syncs to
# the victim via snapshot, kills via the existing died→server_death broadcast.
const MELEE_RANGE := 2.6
const MELEE_DAMAGE := 55.0
const MELEE_COOLDOWN := 0.6
const MELEE_HITBOX_MASK := 4   # HeadHitbox/BodyHitbox collision_layer
var _melee_until: float = 0.0

# How long a corpse stays (playing its death anim) before hiding.
const CORPSE_LINGER := 2.2

# ── Footsteps (positional) ───────────────────────────────────────────────
# Distance-accumulator footsteps: a step fires every FOOTSTEP_STRIDE metres of
# horizontal travel, so cadence scales with speed automatically and works for
# BOTH locally-simulated and snapshot-driven (remote) players — the whole point
# is hearing enemies move. Played through a dedicated 3D emitter so it doesn't
# fight the gunshot/hit channel. Own steps are quieter; enemy steps carry.
const FOOTSTEP_STRIDE := 2.0
var _foot_prev_xz: Vector2 = Vector2.ZERO
var _foot_accum: float = 0.0
var _foot_audio: AudioStreamPlayer3D = null
var footstep_count: int = 0   # test hook
static var _footstep_wav: AudioStreamWAV = null
static var _reload_wav: AudioStreamWAV = null

# ── Viewmodel (first-person weapon) animation ────────────────────────────
# Local cosmetic: the held weapon bobs while walking, sways opposite to aim,
# pulls toward center when ADS, and kicks back per shot. Subtle amplitudes so
# it reads as life, not seasickness. Local human only.
@onready var weapon_visual: Node3D = get_node_or_null(^"Head/Camera3D/WeaponVisual")
var _vm_rest_pos: Vector3 = Vector3.ZERO

# ── First-person weapon view-model (GLB) ──────────────────────────────────
# Local human only. The procedural box gun (GunBody/Barrel/Grip in the .tscn)
# is hidden and a Kenney Blaster Kit GLB is shown instead, picked by weapon
# category. These 3 constants are the placement knobs — tune from a screenshot.
const VIEW_MODEL_SCALE := 0.2
const VIEW_MODEL_OFFSET := Vector3(0.0, -0.04, 0.0)   # local to WeaponVisual
# Euler rotation (radians) applied to the GLB. Kenney blaster root carries an
# internal rotation, so tune empirically from a screenshot. Barrel should
# point into the screen (away from camera).
# Headless: long axis = Z. Live check: the MUZZLE is the model's -Z end, so at
# rot=0 the muzzle points world -Z = into the screen (correct FPS hold). yaw=PI
# was wrong (muzzle pointed back at the player). Keep rot=0.
const VIEW_MODEL_ROT := Vector3(0.0, 0.0, 0.0)
const _VIEW_MODEL_DIR := "res://assets/models/weapons/glb/"
# type_label keyword (lowercase substring) → blaster GLB. First match wins;
# order matters (check specific before generic). Falls through to default AR.
const _VIEW_MODEL_TABLE := [
	["sniper", "blaster-h"], ["anti-material", "blaster-h"], ["railgun", "blaster-h"],
	["shotgun", "blaster-l"],
	["smg", "blaster-c"], ["pdw", "blaster-c"],
	["pistol", "blaster-a"], ["secondary", "blaster-a"], ["revolver", "blaster-a"],
	["beam", "blaster-e"], ["laser", "blaster-e"], ["arc", "blaster-e"],
	["lightning", "blaster-e"], ["plasma", "blaster-e"], ["energy", "blaster-e"],
	["bow", "blaster-r"], ["launcher", "blaster-r"], ["rocket", "blaster-r"],
	["explosive", "blaster-r"], ["knockback", "blaster-r"], ["throwable", "blaster-r"],
	["lmg", "blaster-n"], ["heavy", "blaster-n"], ["minigun", "blaster-n"],
]
var _vm_instance: Node3D = null   # currently-shown GLB (freed on weapon swap)
var _vm_bob_phase: float = 0.0
var _vm_kick: float = 0.0
var _vm_prev_yaw: float = 0.0
var _vm_prev_pitch: float = 0.0
# Transient crosshair bloom from firing — bumped per shot, decays each frame.
# Feeds crosshair_spread() so the reticle visibly opens up during sustained
# fire (matching the server-side accuracy cone).
var _crosshair_kick: float = 0.0

# DS-M2: latest input frame received from a network client (used only when
# use_remote_input=true). Tick gates against replay/out-of-order.
var _remote_input_bits: int = 0
var _remote_input_yaw: float = 0.0
var _remote_input_pitch: float = 0.0
var _remote_input_tick: int = -1
# Anti-cheat: last time we warned about excessive horizontal speed for this
# peer. Throttle to 1 log / 5s so a sustained speedhack doesn't spam.
var _last_speed_warn_ms: int = 0
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
## Emitted whenever this player actually loses HP, carrying who did it. Used by
## the HUD's directional damage indicator on the local player. Fires wherever
## apply_damage runs locally (practice, listen-host-as-victim); pure DS-client
## victims get the same cue from the server_apply_damage broadcast instead.
signal took_damage(attacker: Node)

var last_attacker: Node = null


func _ready() -> void:
	# Tag for group lookups (jump pads, pickups, AI target search).
	add_to_group(&"player")
	# The touch overlay finds the human's own controller via this group.
	if is_local and is_human_input:
		add_to_group(&"local_player")
	if camera != null:
		_base_fov = camera.fov
	_foot_prev_xz = Vector2(global_position.x, global_position.z)
	_setup_footstep_audio()
	if weapon_visual != null:
		_vm_rest_pos = weapon_visual.position
	_vm_prev_yaw = _aim_yaw
	_vm_prev_pitch = _aim_pitch
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
	# Show the GLB view-model for the starting weapon (local human only).
	_apply_view_model()

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
	_equip_resource(new_weapon)
	# P1-8: tell the server so its mirror's weapon_def matches and
	# fire_resolver can enforce "weapon_id of fire RPC == current". Without
	# this, the server's view stays on whatever the spawn put us on, and
	# a tampered client could fire as any-loadout-weapon at-will.
	if is_local and _is_networked() and not multiplayer.is_server():
		var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
		if net_rpc != null:
			net_rpc.client_switch_weapon.rpc_id(1, new_weapon.id)


## Same effect as equip_slot but keyed by weapon id rather than loadout
## slot. Used by the server-side switch handler — the host's mirror only
## knows the client by their weapon's id, not their UI slot.
func equip_by_id(weapon_id: StringName) -> bool:
	for w in loadout:
		if w != null and StringName(w.id) == weapon_id:
			if w == weapon_def:
				return true   # already equipped — idempotent
			_equip_resource(w)
			return true
	return false


# Internal — actual weapon-swap state mutation. Both equip_slot and
# equip_by_id route through here so client local + server mirror flip
# the same set of fields.
func _equip_resource(new_weapon: Resource) -> void:
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
	_apply_view_model()


## Pick the first-person GLB for a weapon: explicit view_model override wins,
## else first keyword match on type_label, else default AR blaster.
func _resolve_view_model(weapon: Resource) -> String:
	if weapon == null:
		return ""
	if "view_model" in weapon and String(weapon.view_model) != "":
		return String(weapon.view_model)
	var label: String = String(weapon.type_label).to_lower()
	for pair in _VIEW_MODEL_TABLE:
		if label.find(pair[0]) != -1:
			return pair[1]
	return "blaster-d"   # default assault rifle silhouette


## Swap the held GLB to match weapon_def. Local human only — bots / remote
## ghosts / the DS never render a first-person weapon, so we skip them (avoids
## spawning 96 GLBs server-side). Hides the procedural box gun when a GLB shows.
func _apply_view_model() -> void:
	if not (is_local and is_human_input) or weapon_visual == null:
		return
	if _vm_instance != null and is_instance_valid(_vm_instance):
		# remove_child first so the "_ViewModel" name frees up immediately —
		# otherwise the new instance added this frame collides and Godot
		# auto-renames it while queue_free is still pending.
		weapon_visual.remove_child(_vm_instance)
		_vm_instance.queue_free()
		_vm_instance = null
	var model_name: String = _resolve_view_model(weapon_def)
	var procedural := ["GunBody", "GunBarrel", "GunGrip"]
	if model_name == "":
		for n in procedural:
			var box: Node = weapon_visual.get_node_or_null(n)
			if box is Node3D: (box as Node3D).visible = true
		return
	var path: String = _VIEW_MODEL_DIR + model_name + ".glb"
	if not ResourceLoader.exists(path):
		return   # missing model → keep procedural gun visible
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		return
	# Hide procedural boxes only once we know the GLB loaded.
	for n in procedural:
		var box: Node = weapon_visual.get_node_or_null(n)
		if box is Node3D: (box as Node3D).visible = false
	var inst: Node3D = scene.instantiate() as Node3D
	inst.name = "_ViewModel"
	weapon_visual.add_child(inst)
	inst.position = VIEW_MODEL_OFFSET
	inst.rotation = VIEW_MODEL_ROT
	inst.scale = Vector3(VIEW_MODEL_SCALE, VIEW_MODEL_SCALE, VIEW_MODEL_SCALE)
	_vm_instance = inst


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
	# Lean runs on every instance every frame: local human peeks (POV), the
	# server mirror offsets head_hitbox (fair hit-reg), remote clients tilt the
	# model toward the snapshot-driven _lean_target. _lean_target is set by
	# _step_movement (local/mirror) or set_remote_lean (remote enemies).
	_apply_lean(delta)
	# Positional footsteps for every moving player (own + enemies you hear).
	_step_footsteps(delta)
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
			# Recoil recovery + ADS FOV (DS-client local human).
			_step_local_feel(delta)
			if PREDICT_LOCAL_MOVEMENT:
				# Predict our own movement locally (same code + map as the
				# server) so input feels instant, then reconcile against the
				# authoritative snapshot. _step_movement also dips the head for
				# crouch, so _apply_local_crouch_visual isn't needed here.
				_step_movement(delta)
				_reconcile_prediction(delta)
			else:
				# Pure snapshot rendering. Crouch head-dip is cosmetic-only here
				# (snapshots don't carry head height); position comes from the
				# server via _apply_remote_state.
				_apply_local_crouch_visual(delta)
				_apply_remote_state(delta)
		else:
			# Ghosts / bots on the DS client: position straight from snapshots.
			_apply_remote_state(delta)
		if _skin != null: _skin.play_anim(_skin.select_anim(is_dead, velocity))
		return
	# Authoritative branch — this controller owns simulation.
	# is_local = local human / bot. use_remote_input = server simulating a
	# remote peer from received input RPCs. Mutually exclusive in practice.
	if is_local:
		_apply_camera_kick(delta)
		if is_human_input:
			_step_local_feel(delta)   # recoil recovery + ADS FOV
		# Listen-host clients also stream movement input to the host so the host's
		# mirror of this player runs through CharacterBody3D collision instead of
		# blindly accepting transform pushes. Keep fire on the existing
		# client_fire RPC path there; otherwise the host would resolve each shot
		# twice (once from INPUT_FIRE edge, once from client_fire).
		if _is_networked() and not multiplayer.is_server():
			_send_input_to_server(false)
		_step_movement(delta)
		_step_weapon(delta)
		_step_net_send(delta)
	elif has_meta(&"is_bot"):
		# Bots own their own simulation (BotPlayer overrides _step_movement /
		# _step_weapon) but must NOT be is_local — that would make their camera
		# current and steal the human's view (the 4587588 camera-steal fix set
		# is_local=false, which silently routed bots into the inert
		# `_apply_remote_state` branch below → frozen, never moving or firing.
		# This dedicated branch restores bot simulation without the camera.)
		# MP bot positions reach clients via the DS snapshot broadcast, so no
		# _step_net_send / camera kick needed here.
		_step_movement(delta)
		_step_weapon(delta)
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
	if _skin != null: _skin.play_anim(_skin.select_anim(is_dead, velocity))


## DS-M3: client-side input sender. Packs the current Input.* state into a bit
## field and ships it to the server via client_send_input. Throttled to the
## same NET_SYNC_INTERVAL so we don't flood the channel.
var _input_tick: int = 0
var _input_send_accum: float = 0.0


func _send_input_to_server(include_fire_bit: bool = true) -> void:
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
	if Input.is_action_pressed(&"crouch"):       bits |= NetProtocol.INPUT_CROUCH
	if Input.is_action_pressed(&"ads"):          bits |= NetProtocol.INPUT_ADS
	if Input.is_action_pressed(&"lean_left"):    bits |= NetProtocol.INPUT_LEAN_LEFT
	if Input.is_action_pressed(&"lean_right"):   bits |= NetProtocol.INPUT_LEAN_RIGHT
	if Input.is_action_pressed(&"melee"):        bits |= NetProtocol.INPUT_MELEE
	if include_fire_bit and Input.is_action_pressed(&"fire"):
		bits |= NetProtocol.INPUT_FIRE
	if Input.is_action_pressed(&"reload"):       bits |= NetProtocol.INPUT_RELOAD
	if Input.is_action_pressed(&"ability"):      bits |= NetProtocol.INPUT_ABILITY
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		return
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
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
		if (just_pressed & NetProtocol.INPUT_MELEE) != 0:
			try_melee()


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


## Touch look — the mobile overlay feeds drag deltas (already × sensitivity)
## here, mirroring the mouse-look in _unhandled_input so aim stays consistent.
func apply_touch_look(delta: Vector2) -> void:
	_aim_yaw -= delta.x
	_aim_pitch = clampf(_aim_pitch - delta.y, -PI * 0.49, PI * 0.49)


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


## Applied on each successful shot. Two layers:
##  - a transient camera KICK (snappy visual punch, decays to zero)
##  - PERSISTENT recoil: the aim actually climbs and you must pull down (or
##    let it auto-recover). Per-weapon via recoil_rise / recoil_horiz. The
##    server raycasts along the reported aim, so this recoil moves where
##    shots land during sustained fire — the learnable "recoil pattern".
func _apply_recoil_kick() -> void:
	var rise: float = weapon_def.recoil_rise if (weapon_def != null and "recoil_rise" in weapon_def) else 0.011
	var horiz: float = weapon_def.recoil_horiz if (weapon_def != null and "recoil_horiz" in weapon_def) else 0.005
	# Transient punch (visual only).
	_camera_kick.y += _RECOIL_KICK_PITCH * 0.5
	_camera_kick.x += randf_range(-horiz, horiz)
	# Persistent climb — negative pitch = up (matches _RECOIL_KICK_PITCH sign).
	_aim_pitch = clampf(_aim_pitch - rise, -PI * 0.49, PI * 0.49)
	_aim_yaw += randf_range(-horiz, horiz)
	_recoil_owed += rise
	_recoil_idle = 0.0
	_crosshair_kick = minf(1.0, _crosshair_kick + 0.35)   # bloom the reticle
	_vm_kick = minf(1.0, _vm_kick + 0.6)                  # punch the viewmodel


## Per-frame recoil recovery + ADS handling for the LOCAL human. Eases the
## accumulated recoil climb back down shortly after firing stops, and lerps
## the camera FOV / sets the ADS flag. Called from the is_local branch.
func _step_local_feel(delta: float) -> void:
	_recoil_idle += delta
	# Decay the firing bloom (≈0.4s back to rest).
	_crosshair_kick = maxf(0.0, _crosshair_kick - delta * 2.5)
	# Recover the owed recoil once there's a brief gap in fire (~0.12s).
	if _recoil_owed > 0.0 and _recoil_idle > 0.12:
		var rate: float = weapon_def.recoil_recover if (weapon_def != null and "recoil_recover" in weapon_def) else 5.0
		var step: float = minf(rate * delta, _recoil_owed)
		_aim_pitch = clampf(_aim_pitch + step, -PI * 0.49, PI * 0.49)
		_recoil_owed -= step
	# ADS: held aim, but not while sprinting or reloading.
	_is_ads = is_human_input and Input.is_action_pressed(&"ads") and not is_reloading \
		and not Input.is_action_pressed(&"sprint")
	if camera != null:
		var target_fov: float = (weapon_def.ads_zoom_fov if (weapon_def != null) else 45.0) if _is_ads else _base_fov
		camera.fov = lerpf(camera.fov, target_fov, clampf(ADS_FOV_LERP * delta, 0.0, 1.0))
	_step_viewmodel(delta)


## First-person weapon juice: walk bob + aim sway + ADS centering + recoil
## kick, blended toward a target each frame. Subtle on purpose. Local only.
func _step_viewmodel(delta: float) -> void:
	if weapon_visual == null:
		return
	_vm_kick = maxf(0.0, _vm_kick - delta * 5.0)
	var hs: float = Vector2(velocity.x, velocity.z).length()
	var move_frac: float = clampf(hs / maxf(move_speed, 0.1), 0.0, 1.0)
	# Walk bob — figure-8: x sways at half rate, y bobs at full rate.
	_vm_bob_phase += delta * (6.0 + hs * 1.2)
	var bob_amp: float = (0.10 if _is_ads else 0.5) * move_frac
	var bob: Vector3 = Vector3(cos(_vm_bob_phase) * 0.010, -absf(sin(_vm_bob_phase)) * 0.012, 0.0) * bob_amp
	# Sway — weapon lags behind aim changes, then eases back.
	var dyaw: float = wrapf(_aim_yaw - _vm_prev_yaw, -PI, PI)
	var dpitch: float = _aim_pitch - _vm_prev_pitch
	_vm_prev_yaw = _aim_yaw
	_vm_prev_pitch = _aim_pitch
	var sway: Vector3 = Vector3(clampf(dyaw, -0.05, 0.05), clampf(-dpitch, -0.05, 0.05), 0.0)
	# ADS — pull the weapon toward the screen centre (kill the rest x offset).
	var ads_off: Vector3 = Vector3(-_vm_rest_pos.x * 0.85, -_vm_rest_pos.y * 0.3, 0.02) if _is_ads else Vector3.ZERO
	# Recoil — punch back toward the camera (+z) and up.
	var kick: Vector3 = Vector3(0.0, _vm_kick * 0.008, _vm_kick * 0.05)
	# Reload — dip the weapon down/in and tilt it (muzzle down) while reloading,
	# so the reload reads visually instead of just an ammo timer.
	var reload_off: Vector3 = Vector3(0.03, -0.08, 0.0) if is_reloading else Vector3.ZERO
	var target: Vector3 = _vm_rest_pos + bob + sway + ads_off + kick + reload_off
	weapon_visual.position = weapon_visual.position.lerp(target, clampf(delta * 16.0, 0.0, 1.0))
	var target_tilt: float = 0.5 if is_reloading else 0.0
	weapon_visual.rotation.x = lerpf(weapon_visual.rotation.x, target_tilt, clampf(delta * 9.0, 0.0, 1.0))


## Normalized 0..1 reticle bloom for the local human's HUD crosshair — mirrors
## the server-side accuracy cone so the gap visibly opens when you move / fire /
## jump and tightens when you ADS or crouch. Pure read of current state.
func crosshair_spread() -> float:
	var f: float = 0.0
	var hs: float = Vector2(velocity.x, velocity.z).length()
	f += clampf(hs / maxf(move_speed, 0.1), 0.0, 1.0) * 0.5
	if not is_on_floor():
		f += 0.4
	f += _crosshair_kick
	if _is_ads:
		f *= 0.2
	elif _is_crouching:
		f *= 0.55
	return clampf(f, 0.0, 1.0)


## Applied when this player takes damage — small jolt in a random direction.
func _apply_hit_shake() -> void:
	_camera_kick.x += randf_range(-_HIT_SHAKE_AMOUNT, _HIT_SHAKE_AMOUNT)
	_camera_kick.y += randf_range(-_HIT_SHAKE_AMOUNT, _HIT_SHAKE_AMOUNT)


# ── Lean / peek ───────────────────────────────────────────────────────────
## Smooth the lean toward _lean_target and apply it to the head (POV + camera),
## the head hitbox (so the server hits where the head is drawn), and the visible
## body (so remote clients see the peek). Runs on every instance every frame.
func _apply_lean(delta: float) -> void:
	_lean = lerpf(_lean, _lean_target, clampf(LEAN_LERP * delta, 0.0, 1.0))
	if absf(_lean) < 0.0005 and absf(_lean_target) < 0.0005:
		_lean = 0.0
	var ox: float = _lean * LEAN_OFFSET   # +x = player's right
	var rz: float = -_lean * LEAN_ROLL    # roll the view into the lean
	if head != null:
		head.position.x = ox
		head.rotation.z = rz
	# Server resolves hits against head_hitbox, so shifting it with the head is
	# what makes a peek fair — the enemy hits the head where it appears.
	if head_hitbox != null:
		head_hitbox.position.x = ox
	# Tilt the visible body so remote clients see the lean aligned with the
	# hitbox (own model is hidden first-person, so this is a no-op locally).
	var visuals: Node3D = get_node_or_null(^"Visuals") as Node3D
	if visuals != null:
		visuals.rotation.z = rz


## Remote enemies don't run _step_movement, so the snapshot's lean flags drive
## their peek through this setter (called from game_controller._on_server_snapshot).
func set_remote_lean(dir: int) -> void:
	_lean_target = float(clampi(dir, -1, 1))


## Current lean intent as a sign (-1/0/+1) — read by the snapshot builder to
## pack the lean flags for remote clients.
func lean_sign() -> int:
	if _lean_target > 0.5:
		return 1
	if _lean_target < -0.5:
		return -1
	return 0


# ── Footsteps ─────────────────────────────────────────────────────────────
## Bake a short scuff/thump once (shared by every player). Filtered noise + a
## low thump under a fast-decay envelope. 16-bit mono PCM (statically
## sampleable — same reason proc_audio uses AudioStreamWAV, no mixer warnings).
static func _get_footstep_wav() -> AudioStreamWAV:
	if _footstep_wav != null:
		return _footstep_wav
	# Realistic hard-surface footstep: a soft low-passed noise "scuff" (the
	# sole grinding grit) layered with a quick low-frequency "body" thump (the
	# weight landing) and a crisp initial transient (the tap). The old version
	# was a near-pure 95Hz sine which read as a synthetic beep. Lowpassing the
	# noise (1-pole) warms it from hiss into a believable thud.
	var rate: int = 32000
	var n: int = int(rate * 0.14)
	var data: PackedByteArray = PackedByteArray()
	data.resize(n * 2)
	var lcg: int = 0x2545F49
	var lp: float = 0.0           # 1-pole lowpass state for the noise
	var lp2: float = 0.0          # second pole — steeper rolloff, softer thud
	for i in n:
		var t: float = float(i) / float(rate)
		# Two-stage envelope: very fast attack (~1.5ms), then a punchy body
		# decay plus a longer soft tail so it doesn't click off abruptly.
		var attack: float = clampf(t / 0.0015, 0.0, 1.0)
		var body: float = exp(-t * 42.0)
		var tail: float = exp(-t * 14.0) * 0.35
		var env: float = attack * maxf(body, tail)
		# White noise → 2-pole lowpass (cutoff ~ a/(1-a)·rate, a=0.45 ≈ warm).
		lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF
		var white: float = float(lcg) / 1073741823.0 - 1.0
		lp += 0.45 * (white - lp)
		lp2 += 0.45 * (lp - lp2)
		var scuff: float = lp2
		# Low body thump, pitch drops slightly over the hit for a "stomp".
		var thump: float = sin(TAU * (78.0 - t * 90.0) * t)
		# Crisp initial tap (broadband, only in the first few ms).
		var tap: float = white * exp(-t * 600.0) * 0.4
		var s: float = (scuff * 0.62 + thump * 0.30 + tap) * env * 0.85
		var v: int = int(clampf(s, -1.0, 1.0) * 32767.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	_footstep_wav = wav
	return wav


## Bake a mechanical "cha-chunk" reload sound once: two short noise clicks
## (mag out / mag in) under fast-decay envelopes. Shared across players.
static func _get_reload_wav() -> AudioStreamWAV:
	if _reload_wav != null:
		return _reload_wav
	var rate: int = 22050
	var n: int = int(rate * 0.28)
	var data: PackedByteArray = PackedByteArray()
	data.resize(n * 2)
	var lcg: int = 0x9E3779B
	for i in n:
		var t: float = float(i) / float(rate)
		# Two clicks: one at t≈0, one at t≈0.16s.
		var e1: float = exp(-t * 55.0)
		var e2: float = exp(-maxf(0.0, t - 0.16) * 60.0) if t >= 0.16 else 0.0
		var env: float = maxf(e1, e2 * 0.85)
		lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF
		var noise: float = float(lcg) / 1073741823.0 - 1.0
		var s: float = (noise * 0.7 + sin(TAU * 140.0 * t) * 0.3) * env * 0.45
		var v: int = int(clampf(s, -1.0, 1.0) * 32767.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	_reload_wav = wav
	return wav


func _play_reload_sound() -> void:
	if NetProtocol.is_dedicated_server_boot():
		return
	var s: AudioStream = weapon_def.reload_sound if (weapon_def != null and weapon_def.reload_sound != null) else _get_reload_wav()
	_play_3d(s)


func _setup_footstep_audio() -> void:
	if NetProtocol.is_dedicated_server_boot():
		return   # headless server makes no sound
	_foot_audio = AudioStreamPlayer3D.new()
	_foot_audio.stream = _get_footstep_wav()
	_foot_audio.unit_size = 6.0          # full volume within ~6m, audible ~15m
	_foot_audio.max_distance = 28.0
	# Own steps subtle; enemy steps carry so you can hear them coming.
	_foot_audio.volume_db = -15.0 if (is_local and is_human_input) else -3.0
	add_child(_foot_audio)


## Distance-accumulator footsteps — a step every FOOTSTEP_STRIDE metres of
## horizontal travel (longer stride when crouch-sneaking). Runs on every
## instance so remote enemies' steps play at their world position.
func _step_footsteps(_delta: float) -> void:
	var here: Vector2 = Vector2(global_position.x, global_position.z)
	var moved: float = here.distance_to(_foot_prev_xz)
	_foot_prev_xz = here
	if moved > 3.0:
		return   # teleport / respawn — don't count it as a stride
	_foot_accum += moved
	var stride: float = FOOTSTEP_STRIDE * (1.7 if _is_crouching else 1.0)
	if _foot_accum >= stride:
		_foot_accum = 0.0
		footstep_count += 1
		if _foot_audio != null:
			_foot_audio.pitch_scale = randf_range(0.9, 1.12)
			_foot_audio.play()


# ── Audio helpers ─────────────────────────────────────────────────────────
func _play_3d(stream: AudioStream) -> void:
	if audio_3d == null or stream == null:
		return
	audio_3d.pitch_scale = 1.0
	audio_3d.stream = stream
	audio_3d.play()


func _play_3d_pitched(stream: AudioStream, pitch: float) -> void:
	if audio_3d == null or stream == null:
		return
	audio_3d.pitch_scale = clampf(pitch, 0.5, 2.0)
	audio_3d.stream = stream
	audio_3d.play()


## Per-weapon fire sound. Uses weapon_def.fire_sound if an asset is assigned;
## otherwise gives the shared SFX_SHOOT weapon IDENTITY by pitch — fast guns
## (SMG, low fire_interval) snap higher, slow heavy guns (sniper) boom lower —
## so every weapon sounds distinct without per-weapon audio files.
func _play_shoot_sound() -> void:
	if weapon_def != null and weapon_def.fire_sound != null:
		_play_3d(weapon_def.fire_sound)
		return
	var pitch: float = 1.0
	if weapon_def != null:
		var ms: float = float(weapon_def.fire_interval_ms)
		pitch = clampf(remap(ms, 60.0, 600.0, 1.32, 0.72), 0.72, 1.35)
	_play_3d_pitched(SFX_SHOOT, pitch * randf_range(0.97, 1.03))


func _play_hit_sound() -> void:
	_play_3d(SFX_HIT)


# DS-client local POV crouch. Snapshot-only mode never runs _step_movement,
# so the local player's own camera wouldn't dip. This mirrors just the
# head-height ease (no movement / hitbox — server owns those).
func _apply_local_crouch_visual(delta: float) -> void:
	if head == null:
		return
	var want: bool = Input.is_action_pressed(&"crouch")
	var target_y: float = CROUCH_HEAD_Y if want else STAND_HEAD_Y
	head.position.y = lerpf(head.position.y, target_y, clampf(CROUCH_LERP * delta, 0.0, 1.0))


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
	var crouch_pressed: bool = false
	var ads_pressed: bool = false
	var lean_dir: float = 0.0
	if use_remote_input:
		var bits: int = _remote_input_bits
		input_x = float((bits & NetProtocol.INPUT_RIGHT) != 0) - float((bits & NetProtocol.INPUT_LEFT) != 0)
		input_z = float((bits & NetProtocol.INPUT_BACK) != 0) - float((bits & NetProtocol.INPUT_FORWARD) != 0)
		jump_pressed = (bits & NetProtocol.INPUT_JUMP) != 0
		sprint_pressed = (bits & NetProtocol.INPUT_SPRINT) != 0
		crouch_pressed = (bits & NetProtocol.INPUT_CROUCH) != 0
		ads_pressed = (bits & NetProtocol.INPUT_ADS) != 0
		lean_dir = float((bits & NetProtocol.INPUT_LEAN_RIGHT) != 0) - float((bits & NetProtocol.INPUT_LEAN_LEFT) != 0)
	elif is_human_input:
		input_x = float(Input.is_action_pressed(&"move_right")) - float(Input.is_action_pressed(&"move_left"))
		input_z = float(Input.is_action_pressed(&"move_back")) - float(Input.is_action_pressed(&"move_forward"))
		jump_pressed = Input.is_action_pressed(&"jump")
		sprint_pressed = Input.is_action_pressed(&"sprint")
		crouch_pressed = Input.is_action_pressed(&"crouch")
		ads_pressed = Input.is_action_pressed(&"ads")
		lean_dir = float(Input.is_action_pressed(&"lean_right")) - float(Input.is_action_pressed(&"lean_left"))

	# Mirror the ADS flag on the authoritative side so fire_resolver can read
	# it for spread. (_step_local_feel also sets it for the local human's FOV.)
	_is_ads = ads_pressed

	# Slide trigger: crouch TAPPED (edge) while sprinting and moving fast on the
	# ground fires a slide. Edge-detected per instance so holding crouch is a
	# normal crouch, not a slide loop. Computed before _is_crouching so the head
	# dips on the same frame the slide starts.
	_slide_cooldown = maxf(0.0, _slide_cooldown - delta)
	var crouch_just: bool = crouch_pressed and not _slide_crouch_was_down
	var horiz_speed_now: float = Vector2(velocity.x, velocity.z).length()
	if _slide_timer <= 0.0 and crouch_just and sprint_pressed and is_on_floor() \
			and horiz_speed_now > move_speed * SLIDE_ENTRY_FRAC and _slide_cooldown <= 0.0:
		_slide_timer = SLIDE_DURATION
		var vdir: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
		_slide_dir = vdir.normalized() if vdir.length() > 0.1 else (-transform.basis.z)
	_slide_crouch_was_down = crouch_pressed
	var is_sliding: bool = _slide_timer > 0.0

	# Lean intent — peek left/right, but not while sprinting or sliding (you're
	# committed to moving then) or airborne. _apply_lean smooths + applies it.
	if is_sliding or sprint_pressed or not is_on_floor():
		_lean_target = 0.0
	else:
		_lean_target = lean_dir

	# Can't jump while crouching (you'd un-crouch first). Crouch also wins
	# over sprint — you move slow when hunkered down. A slide also lowers the
	# profile (low head + small hitbox) for its duration.
	_is_crouching = is_sliding or (crouch_pressed and is_on_floor())
	# Jumping out of a slide cancels it (slide-jump / lurch — feels good and
	# lets you bail early). Normal crouch still blocks the jump.
	if jump_pressed and is_on_floor() and (is_sliding or not _is_crouching):
		velocity.y = jump_velocity
		_slide_timer = 0.0
		_slide_cooldown = SLIDE_COOLDOWN
		is_sliding = false
		_is_crouching = crouch_pressed and is_on_floor()

	# Ease the head/camera down when crouched, up when standing. Runs on
	# every instance (local sees own POV drop; remote peers see the enemy's
	# head dip, which matters for aiming at a crouched target).
	if head != null:
		var target_y: float = CROUCH_HEAD_Y if _is_crouching else STAND_HEAD_Y
		var ease: float = clampf(CROUCH_LERP * delta, 0.0, 1.0)
		head.position.y = lerpf(head.position.y, target_y, ease)
		# Keep the headshot hitbox glued to the visible head so a crouched
		# enemy's head can still be hit where it's drawn (hitbox is a root
		# sibling, doesn't auto-follow Head). Server resolves hits against
		# this, so syncing it on the authoritative side is what counts.
		if head_hitbox != null:
			head_hitbox.position.y = lerpf(head_hitbox.position.y, target_y, ease)

	if is_sliding:
		# Slide overrides normal accel: drive a fixed direction at a speed that
		# decays from SLIDE_SPEED_MULT down to crouch speed over its duration, so
		# it starts as a fast lunge and eases into a low crouch-walk.
		_slide_timer = maxf(0.0, _slide_timer - delta)
		var ratio: float = clampf(_slide_timer / SLIDE_DURATION, 0.0, 1.0)
		var slide_mult: float = lerpf(CROUCH_SPEED_MULT, SLIDE_SPEED_MULT, ratio)
		var slide_speed: float = move_speed * move_speed_multiplier * slide_mult
		velocity.x = _slide_dir.x * slide_speed
		velocity.z = _slide_dir.z * slide_speed
		if _slide_timer <= 0.0:
			_slide_cooldown = SLIDE_COOLDOWN   # arm the gate for the next slide
		move_and_slide()
	else:
		var dir: Vector3 = (transform.basis * Vector3(input_x, 0, input_z))
		if dir.length() > 0.001:
			dir = dir.normalized()
		var speed: float = move_speed * move_speed_multiplier
		if _is_crouching:
			speed *= CROUCH_SPEED_MULT
		elif _is_ads:
			speed *= ADS_MOVE_MULT          # aiming = slow, steady walk
		elif sprint_pressed:
			speed *= sprint_multiplier
		var target_vx: float = dir.x * speed
		var target_vz: float = dir.z * speed
		# Smooth blending toward target velocity so oil/ice zones feel slippy.
		var alpha: float = clampf(ground_friction * delta, 0.0, 1.0)
		velocity.x = lerpf(velocity.x, target_vx, alpha)
		velocity.z = lerpf(velocity.z, target_vz, alpha)
		move_and_slide()
	# Anti-cheat speed monitor — server-side only. Log a warning if a remote
	# peer's horizontal speed exceeds SUSPECT_HORIZ_SPEED. Throttled to 1
	# log every 5s per peer so a sustained speedhack doesn't spam the log.
	if use_remote_input and _is_networked() and multiplayer.is_server():
		var horiz: float = Vector2(velocity.x, velocity.z).length()
		if horiz > NetProtocol.SUSPECT_HORIZ_SPEED:
			var now_ms: int = Time.get_ticks_msec()
			if now_ms - _last_speed_warn_ms > 5000:
				_last_speed_warn_ms = now_ms
				var msg: String = "peer %d horiz speed=%.1f m/s exceeds %.1f" % \
					[get_multiplayer_authority(), horiz, NetProtocol.SUSPECT_HORIZ_SPEED]
				push_warning("[anticheat] " + msg)
				# Mirror into anticheat.log via ProfileService.
				var ps: Node = get_tree().root.get_node_or_null(^"ProfileService")
				if ps != null and ps.has_method(&"_anticheat_log"):
					ps._anticheat_log("speed", msg)


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
	if Input.is_action_just_pressed(&"melee"):
		try_melee()
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


# Close-range melee strike. Returns true if the swing happened (regardless of
# hit). Damage is resolved only on the authority (server mirror, or offline /
# practice); on a DS client this just plays the swing feedback and the
# INPUT_MELEE bit drives the server's mirror to resolve the actual hit.
func try_melee() -> bool:
	if is_dead:
		return false
	var now: float = Time.get_ticks_msec() / 1000.0
	if now < _melee_until:
		return false
	_melee_until = now + MELEE_COOLDOWN
	# Local swing feedback.
	if is_local:
		_play_3d_pitched(SFX_SHOOT, 0.55)   # heavy thunk
		if is_human_input:
			_vm_kick = minf(1.0, _vm_kick + 0.8)
	# Only the authority deals damage.
	if _is_networked() and not multiplayer.is_server():
		return true
	if camera == null:
		return true
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return true
	var from: Vector3 = camera.global_position
	var to: Vector3 = from - camera.global_transform.basis.z * MELEE_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.collision_mask = MELEE_HITBOX_MASK
	q.exclude = [head_hitbox.get_rid(), body_hitbox.get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return true
	var col: Node = hit.get("collider")
	if col == null or not col.has_meta(&"owner_player"):
		return true
	var victim: Node = col.get_meta(&"owner_player")
	if victim == null or victim == self or not victim.has_method(&"apply_damage"):
		return true
	if "is_dead" in victim and victim.is_dead:
		return true
	var is_head: bool = col.get_meta(&"is_head", false)
	victim.apply_damage(MELEE_DAMAGE * (1.4 if is_head else 1.0), self)
	return true


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
			# Send our CLIENT camera position too — under prediction (+ latency)
			# it's offset from the server's lagged mirror, and raycasting from the
			# mirror sends point-blank shots into the scenery (severe on mobile).
			# The server clamps it so it can't be abused.
			var shoot_origin: Vector3 = camera.global_position if camera != null else global_position + Vector3(0, 1, 0)
			if multiplayer.is_server():
				# call_remote excludes self, so emit the signal directly so the
				# host's GameController handler still picks it up. We pass this
				# player's *authority* peer (the human pulling the trigger), not
				# multiplayer.get_unique_id() which on a dedicated server is 1.
				net_rpc.client_fire_received.emit(get_multiplayer_authority(), weapon_def.id, _aim_yaw, _aim_pitch, shoot_origin)
			else:
				net_rpc.client_fire.rpc_id(1, weapon_def.id, _aim_yaw, _aim_pitch, shoot_origin)
		# Local hit-feedback only — actual HP change waits for server broadcast.
	elif "is_throwable" in weapon_def and weapon_def.is_throwable:
		# Practice / offline throwable: server isn't running, so spawn the
		# projectile locally. Re-uses the server's throwable_projectile.gd
		# (it falls back to the main scene's world when no shooter-specific
		# room exists) — same arc / AoE / fuse logic as MP.
		_spawn_local_throwable()
	elif not hit_info.is_empty():
		# Practice / offline mode: apply hit immediately.
		_apply_local_hit(hit_info)
	return true


# Practice-mode equivalent of fire_resolver._spawn_throwable. The server
# code path requires multiplayer.is_server() so it doesn't run in pure
# offline; this mirrors that logic so practice players can throw grenades.
# The same throwable_projectile.gd script runs the simulation + AoE
# damage; the only difference is no spawn / explode RPC broadcasts (no
# clients to broadcast to).
func _spawn_local_throwable() -> void:
	var proj_script = load("res://server/scripts/throwable_projectile.gd")
	var proj: Node3D = Node3D.new()
	proj.set_script(proj_script)
	proj.weapon = weapon_def
	proj.shooter = self
	var origin: Vector3 = camera.global_position if camera != null else global_position + Vector3(0, 1, 0)
	var pitch: float = _aim_pitch + weapon_def.throw_arc_pitch
	pitch = clampf(pitch, -PI * 0.49, PI * 0.49)
	var dir := Vector3(-sin(_aim_yaw) * cos(pitch), sin(pitch), -cos(_aim_yaw) * cos(pitch))
	proj.velocity = dir.normalized() * weapon_def.throw_speed
	# Add to the tree FIRST, THEN set global_position. Setting global_position
	# on a not-yet-parented Node3D errors ("!is_inside_tree()") and lands the
	# projectile at the wrong spot. Parent = the game controller so the
	# projectile lives in the main scene's world (matches where players are).
	var game: Node = get_tree().root.get_node_or_null(^"Game")
	if game != null:
		game.add_child(proj)
	else:
		get_tree().root.add_child(proj)
	proj.global_position = origin


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
	_play_reload_sound()


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
	if dmg > 0.0 and attacker != null:
		took_damage.emit(attacker)
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
	collision_layer = 0
	collision_mask = 0
	head_hitbox.monitoring = false
	body_hitbox.monitoring = false
	_play_3d(SFX_DEATH)
	# Play the death animation and leave the corpse for a beat instead of
	# vanishing instantly — the classic "drop". _physics_process early-returns
	# on is_dead so it won't drive the skin anymore; kick the die anim directly
	# (AnimationPlayer plays it out on its own). Hidden after CORPSE_LINGER
	# unless we respawn first (the timer re-checks is_dead).
	if _skin != null:
		_skin.play_anim(&"die")
	# Procedural death collapse (ragdoll substitute — the GLB skins aren't
	# rigged with physical bones, so we tip the whole body over + drop it
	# toward the floor instead of a real physics ragdoll). Runs on every client
	# (each runs _die locally), so all viewers see the corpse fall. Falls away
	# from the killer when known; a little random roll keeps deaths from looking
	# identical. Local player's Visuals are hidden first-person, so this is for
	# everyone watching the kill.
	var vis: Node3D = get_node_or_null(^"Visuals") as Node3D
	if vis != null:
		var tip_dir: float = 1.0
		if last_attacker != null and is_instance_valid(last_attacker) and last_attacker is Node3D:
			# Pushed away from the attacker: tip forward if shot from behind, back if from front.
			var to_me: Vector3 = global_position - (last_attacker as Node3D).global_position
			tip_dir = 1.0 if to_me.dot(-transform.basis.z) >= 0.0 else -1.0
		var roll: float = (float(get_instance_id() % 7) - 3.0) * 0.06
		var fall := create_tween()
		fall.set_parallel(true)
		fall.tween_property(vis, "rotation:x", 1.45 * tip_dir, 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		fall.tween_property(vis, "rotation:z", roll, 0.55)
		fall.tween_property(vis, "position:y", -0.55, 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var tree: SceneTree = get_tree()
	if tree != null:
		var t: SceneTreeTimer = tree.create_timer(CORPSE_LINGER)
		t.timeout.connect(func() -> void:
			if is_instance_valid(self) and is_dead:
				visible = false)
	else:
		visible = false
	died.emit(last_attacker)


func respawn(at: Vector3) -> void:
	global_position = at
	velocity = Vector3.ZERO
	hp = max_hp
	is_reloading = false
	time_until_next_shot = 0.0
	# Never respawn mid-peek — reset lean + its applied offsets immediately.
	_lean = 0.0
	_lean_target = 0.0
	if head != null:
		head.position.x = 0.0
		head.rotation.z = 0.0
	if head_hitbox != null:
		head_hitbox.position.x = 0.0
	var _vis: Node3D = get_node_or_null(^"Visuals") as Node3D
	if _vis != null:
		_vis.rotation = Vector3.ZERO     # undo any death-collapse tip/roll
		_vis.position.y = 0.0
	_slide_timer = 0.0
	_slide_cooldown = 0.0
	# Reset remote-input tick baseline so a client that just reconnected
	# (re-entered the game scene after match-end / Play Again) gets a fresh
	# input stream accepted. Without this, push_remote_input rejects all the
	# new client's tick=1,2,3 frames as "tick <= last_seen (~1500)" and the
	# server-simulated player ignores every fire/move bit forever.
	_remote_input_tick = -1
	_remote_input_bits = 0
	_remote_input_just_pressed = 0
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
	collision_mask = (1 << 0) | (1 << 1)
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


## Client-side prediction reconciliation (DS-client local human only).
## After we predict our own movement with _step_movement, compare where the
## server says we are (the buffered snapshot) and correct ONLY on genuine
## divergence. The deadzone is the whole point: in normal play our prediction
## matches the server (identical code + map), and the snapshot is naturally
## ~150ms stale, so a small position gap is EXPECTED and must NOT be
## "corrected" or the player rubber-bands. We only act when the gap is too big
## to be latency: ease it in past PRED_SOFT_M, hard-snap past PRED_HARD_M
## (respawn / teleport / a mispredicted collision that actually diverged).
func _reconcile_prediction(_delta: float) -> void:
	if _interpolator == null:
		return
	var sample = _interpolator.sample(0, float(Time.get_ticks_msec()))
	if sample == null:
		return   # no authoritative data yet — predict freely from spawn
	var auth: Vector3 = sample.pos
	var d: float = auth.distance_to(global_position)
	if d >= PRED_HARD_M:
		# Too far to be latency — snap. Kill velocity so we don't keep
		# integrating away from the corrected spot.
		global_position = auth
		velocity = Vector3.ZERO
	elif d > PRED_SOFT_M:
		# Drifting beyond the trust band — ease toward the server smoothly so
		# the correction reads as a gentle pull, not a teleport.
		var t: float = clampf(PRED_EASE_RATE * _delta, 0.0, 1.0)
		global_position = global_position.lerp(auth, t)
	# else: within PRED_SOFT_M → trust local prediction entirely. No correction.


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
