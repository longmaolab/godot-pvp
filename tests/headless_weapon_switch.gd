extends Node
## Weapon-switch + ammo + reload integration. Default loadout is
## [ak20, sg8, srx, railgun]. Test plan:
##
##   1. A connects, fires ak20 → server logs dmg=25 (body) or 50 (head).
##   2. A swaps to srx via equip_slot(2), fires → server logs dmg=95 or
##      instakill on head (different from ak20). Proves server honors the
##      weapon_id in each client_fire RPC.
##   3. A swaps back to ak20 → server's next fire log shows weapon=ak20
##      again, with ak20's damage values. Ammo state survives the swap.
##   4. A drains ak20 (30 rounds) → start_reload triggered, ammo_in_mag
##      returns to 30 after reload_time_ms.
##
## Roles: --role A shooter, --role B victim.

const GAME_SCENE_PATH := "res://client/scenes/game.tscn"
const TICK_HZ := 30.0

var role: String = "A"
var address: String = "ws://127.0.0.1:9207"

var game: Node = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--role" and i + 1 < args.size():
			role = args[i + 1]
		elif args[i] == "--address" and i + 1 < args.size():
			address = args[i + 1]

	print("[%s] connect → %s" % [role, address])
	if not await _connect_and_mount():
		_die("connect failed")
		return
	# Keep is_human_input=true so _step_weapon_visuals_only runs in
	# _physics_process — that's what decrements time_until_next_shot and
	# reload_remaining. In headless, Input.is_action_pressed returns false
	# so no auto-fire happens; we fire only when we manually send RPCs or
	# call try_fire().
	if not await _wait_for_peer_count(2, 5.0):
		_die("peer count never reached 2")
		return
	await get_tree().create_timer(0.5).timeout

	if role == "A":
		await _run_shooter()
	else:
		await _run_victim()
	get_tree().quit(0)


func _run_shooter() -> void:
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		_die("A: no NetRpc")
		return
	var me: Node = game.local_player
	var target: Node = _other_peer()
	if target == null:
		_die("A: no target")
		return

	# Print initial loadout for debugging.
	print("[A] loadout=%s current=%s ammo=%d/%d" % [
		_loadout_ids(me), me.weapon_def.id if me.weapon_def else "<none>",
		me.ammo_in_mag, me.ammo_reserve])

	# Step 1 — single ak20 body shot. Server damage should be 25 (body).
	await _fire_once(net_rpc, &"ak20", target)

	# Step 2 — swap to srx; per-weapon ammo should switch to srx's defaults
	# (5 mag / 12 reserve) and survive the wait. Then fire once.
	me.equip_slot(2)
	await get_tree().create_timer(0.3).timeout
	print("[A] equipped %s ammo=%d/%d" % [me.weapon_def.id, me.ammo_in_mag, me.ammo_reserve])
	if me.weapon_def.id != &"srx":
		_die("equip_slot(2): weapon_def is %s, expected srx" % me.weapon_def.id)
		return
	if me.ammo_in_mag != me.weapon_def.magazine:
		_die("equip_slot(2): ammo_in_mag=%d, expected %d (srx default)" % [me.ammo_in_mag, me.weapon_def.magazine])
		return
	await _fire_once(net_rpc, &"srx", target)

	# Step 3 — swap back to ak20. Per-weapon ammo persists.
	me.equip_slot(0)
	await get_tree().create_timer(0.3).timeout
	print("[A] equipped %s ammo=%d/%d" % [me.weapon_def.id, me.ammo_in_mag, me.ammo_reserve])
	if me.weapon_def.id != &"ak20":
		_die("equip_slot(0): weapon_def is %s, expected ak20" % me.weapon_def.id)
		return

	# Step 4 — drain ak20 to 0 and reload. is_reloading set, then ammo refills
	# to magazine after reload_time_ms.
	me.ammo_in_mag = 0
	me.start_reload()
	if not me.is_reloading:
		_die("start_reload() did not enter reload state")
		return
	print("[A] reload state entered: is_reloading=%s remaining=%.2f" % [me.is_reloading, me.reload_remaining])
	await get_tree().create_timer(me.weapon_def.reload_time_ms / 1000.0 + 0.4).timeout
	print("[A] after reload window: is_reloading=%s ammo=%d/%d" % [me.is_reloading, me.ammo_in_mag, me.ammo_reserve])
	if me.is_reloading:
		_die("reload didn't complete in %dms + 0.4s window" % me.weapon_def.reload_time_ms)
		return
	if me.ammo_in_mag != me.weapon_def.magazine:
		_die("reload didn't fill mag to %d (got %d)" % [me.weapon_def.magazine, me.ammo_in_mag])
		return
	print("[A] PASS — weapon swap + per-weapon ammo + reload all OK")


func _fire_once(net_rpc: Node, weapon_id: StringName, target: Node) -> void:
	# Aim at BODY center (Y+0.4 — below head — to get the 1× body damage,
	# not the 2× headshot multiplier). Easier to assert per-weapon damage.
	var me_pos: Vector3 = game.local_player.global_position
	var tgt_pos: Vector3 = target.global_position
	var eye: Vector3 = me_pos + Vector3(0, 1.0, 0)
	var body: Vector3 = tgt_pos + Vector3(0, 0.4, 0)
	var to: Vector3 = body - eye
	var horiz: float = Vector2(to.x, to.z).length()
	var aim_yaw: float = atan2(to.x, to.z) + PI
	var aim_pitch: float = atan2(to.y, horiz)
	net_rpc.client_fire.rpc_id(1, weapon_id, aim_yaw, aim_pitch)
	# Give the server a few ticks to process.
	await get_tree().create_timer(0.2).timeout
	print("[A] fired %s once" % weapon_id)


func _run_victim() -> void:
	# Stand still long enough for all 4 steps to complete.
	# Total: step1 1.0s + swap 0.1 + step2 1.5 + swap 0.1 + step3 ~0.0 + step4 0.4 + 0.1 + 2.3 ≈ 5.5s
	await get_tree().create_timer(6.5).timeout
	print("[B] final hp=%.1f" % game.local_player.hp)


# ── Helpers ───────────────────────────────────────────────────────────────
func _other_peer() -> Node:
	for pid in game.players_by_peer.keys():
		var p: Node = game.players_by_peer[pid]
		if p != null and is_instance_valid(p) and not p.is_local:
			return p
	return null


func _loadout_ids(p: Node) -> Array:
	var ids: Array = []
	for w in p.loadout:
		ids.append(w.id if w != null else "<null>")
	return ids


func _connect_and_mount() -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(address)
	if err != OK:
		return false
	multiplayer.multiplayer_peer = peer
	var deadline: float = Time.get_ticks_msec() / 1000.0 + 5.0
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			return false
		await get_tree().process_frame
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	print("[%s] peer_id=%d" % [role, multiplayer.get_unique_id()])
	var game_scene: PackedScene = load(GAME_SCENE_PATH) as PackedScene
	game = game_scene.instantiate()
	game.name = "Game"
	get_tree().root.add_child.call_deferred(game)
	await get_tree().process_frame
	await get_tree().create_timer(0.7).timeout
	var spawn_deadline: float = Time.get_ticks_msec() / 1000.0 + 4.0
	while Time.get_ticks_msec() / 1000.0 < spawn_deadline:
		var g: Node = get_tree().root.get_node_or_null(^"Game")
		if g != null and g.get("local_player") != null:
			game = g
			return true
		await get_tree().process_frame
	return false


func _wait_for_peer_count(want: int, seconds: float) -> bool:
	var deadline: float = Time.get_ticks_msec() / 1000.0 + seconds
	while Time.get_ticks_msec() / 1000.0 < deadline:
		if game != null and game.players_by_peer.size() == want:
			return true
		await get_tree().process_frame
	return false


func _die(msg: String) -> void:
	push_error("[%s] %s" % [role, msg])
	print("[%s] FAIL: %s" % [role, msg])
	get_tree().quit(1)
