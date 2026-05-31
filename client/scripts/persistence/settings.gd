extends Node
## Autoload — persistent player preferences (name, skin, audio volume) plus
## cross-device economy (credits, fragments, owned weapons, upgrades).
## Local copy is a write-through cache of the server-authoritative row;
## ConfigFile @ user://settings.cfg keeps the last known snapshot so an
## offline launch still has SOMETHING to render.
##
## Server sync (P-M3+): on first connect to a DS, _request_server_profile
## fires client_request_profile with our device_id. Server returns the
## canonical row via server_profile, _apply_server_profile mirrors it
## locally. Subsequent mutations (set_player_name / award_credits / …)
## prefer the RPC path when `multiplayer.is_server() == false` and a
## peer is live; offline-mode fallback writes ConfigFile directly so
## practice mode still works.

const FILE := "user://settings.cfg"

# NetProtocol reached via the preloaded script class, not the autoload global,
# so this file compiles in standalone `--script` loads (smoke test).
const NetProtocol = preload("res://shared/scripts/network/net_protocol.gd")

signal changed()

var player_name: String = ""
var skin_index: int = 0
var master_volume: float = 0.8   # 0..1 linear (device-local, never server-side)
var credits: int = 500           # in-game currency, starter grant
var fragments: int = 0           # weapon-unlock currency
var purchased: Array = []        # weapon IDs the player owns (besides free starters)
# Active 4-weapon loadout (slot 1/2/3/4). Strings of weapon ids matching
# shared/data/weapons/*.tres filenames. Empty = use GameController's
# DEFAULT_LOADOUT. Picked in menu via the Best Loadouts dropdown.
var loadout_ids: Array = []
var common_chests: int = 0       # owned but unopened chests
var rare_chests: int = 0
# weapon_id → {dmg_lvl, mag_lvl, reload_lvl} — 0..10 per stat (P-M4 raised cap)
var upgrades: Dictionary = {}
var last_free_spin_iso: String = ""   # ISO date string

# ── Server sync state (P-M3+) ────────────────────────────────────────────
# Stable device identifier — randomly generated on first run, persisted
# locally. Bound to the server-side anonymous account so reconnecting from
# the same browser/install resumes the same row. NOT a cross-device login;
# real accounts (P-M7) use handle/password and merge by device_id.
var device_id: String = ""
# P0-1: server-issued bearer token. Sent alongside device_id on every
# request_profile; server validates it against the stored hash. Without a
# matching token, knowing the device_id is no longer enough to inherit
# someone else's account / credits / weapons.
var auth_token: String = ""
# Set after server_profile_received; 0 means "not yet bound on this session".
var account_id: int = 0
# True once we've round-tripped server_profile at least once this session.
var synced_with_server: bool = false
signal profile_synced()
signal server_action(action: String, ok: bool, reason: String)
signal reward_received(kind: String, reward: Dictionary)
signal leaderboard_received(rows: Array)

# ── Lobby handoff (not persisted to disk; lives only in-memory) ────────────
# When the user clicks JOIN-to-DS in main_menu and lands on room_browser,
# main_menu writes the picker selections here so the browser/lobby scenes
# can read them without needing direct refs to the now-freed menu. Same
# pattern for the initial room state delivered with server_room_joined —
# stash here so room_lobby can pick it up after change_scene_to_file.
var pending_room_map: String = ""
var pending_room_mode: String = ""
var pending_room_state: Dictionary = {}

signal credits_changed(new_total: int)
signal fragments_changed(new_total: int)
signal purchased_changed()
signal chests_changed()
signal upgrades_changed()


func _ready() -> void:
	# C7: on the dedicated server, Settings is a client-only concept.
	# Skip disk I/O so the DS doesn't read/write the developer's local
	# settings.cfg (currency, purchased weapons, etc.) every boot.
	if NetProtocol.is_dedicated_server_boot():
		return
	load_from_disk()
	if player_name.is_empty():
		# First run — generate a friendly default so the kid isn't forced to
		# type something just to play.
		player_name = _pick_random_default_name()
		skin_index = randi() % 18
		flush_now()   # identity bootstrap must persist even if user quits in 1s


func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(FILE) != OK:
		# Brand-new install — generate device_id so this run can bind to
		# a fresh server account on first sync.
		device_id = _generate_device_id()
		flush_now()   # identity bootstrap must persist even if user quits in 1s
		return
	device_id = cfg.get_value("identity", "device_id", "")
	if device_id.is_empty():
		device_id = _generate_device_id()
	auth_token = cfg.get_value("identity", "auth_token", "")
	player_name = cfg.get_value("player", "name", player_name)
	skin_index = cfg.get_value("player", "skin", skin_index)
	master_volume = cfg.get_value("audio", "master", master_volume)
	credits = cfg.get_value("economy", "credits", credits)
	fragments = cfg.get_value("economy", "fragments", fragments)
	purchased = cfg.get_value("economy", "purchased", purchased)
	loadout_ids = cfg.get_value("player", "loadout_ids", loadout_ids)
	common_chests = cfg.get_value("economy", "common_chests", common_chests)
	rare_chests = cfg.get_value("economy", "rare_chests", rare_chests)
	upgrades = cfg.get_value("economy", "upgrades", upgrades)
	last_free_spin_iso = cfg.get_value("economy", "last_free_spin", last_free_spin_iso)


# Debounce window for save_to_disk(). Rapid mutations (e.g. award_credits
# fires on every kill in a 5-second engagement) are coalesced into ONE
# disk write at the trailing edge of this window. On web, user:// is
# IndexedDB; a sync write costs 5-50ms, so 30 kills uncoalesced ≈ 1.5s
# of stuttering. With coalescing it's a single write per burst.
const SAVE_DEBOUNCE_S := 1.0
var _save_pending: bool = false


func save_to_disk() -> void:
	# Coalesce rapid calls. The trailing flush sees the LATEST field
	# values, since we read straight from `self` at flush time.
	if _save_pending:
		return
	_save_pending = true
	var t: SceneTreeTimer = get_tree().create_timer(SAVE_DEBOUNCE_S)
	# Capture instance_id (not `self` reference) so the timer doesn't
	# keep the autoload alive past project teardown. Mirrors the
	# proc_audio cleanup pattern.
	var node_id: int = get_instance_id()
	t.timeout.connect(
		func():
			var n: Object = instance_from_id(node_id)
			if n != null and is_instance_valid(n):
				n._flush_to_disk()
	)


## Immediate disk write — bypasses debounce. Use for one-shot situations
## like initial device_id generation or settings-page changes where the
## user expects "saved" to mean saved.
func flush_now() -> void:
	_flush_to_disk()


# Catch process / window shutdown so the trailing edge of the save-debounce
# never gets dropped on quit. Without this, `award_credits()` (or any other
# mutation) within the last SAVE_DEBOUNCE_S seconds before exit is lost: the
# SceneTreeTimer is freed before its timeout fires, and `_save_pending=true`
# is meaningless once we're gone. Web tab-close also hits NOTIFICATION_PREDELETE
# during teardown, so the same handler covers both paths.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		if _save_pending:
			_flush_to_disk()


func _flush_to_disk() -> void:
	_save_pending = false
	var cfg := ConfigFile.new()
	cfg.set_value("identity", "device_id", device_id)
	cfg.set_value("identity", "auth_token", auth_token)
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "skin", skin_index)
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("economy", "credits", credits)
	cfg.set_value("economy", "fragments", fragments)
	cfg.set_value("economy", "purchased", purchased)
	cfg.set_value("player", "loadout_ids", loadout_ids)
	cfg.set_value("economy", "common_chests", common_chests)
	cfg.set_value("economy", "rare_chests", rare_chests)
	cfg.set_value("economy", "upgrades", upgrades)
	cfg.set_value("economy", "last_free_spin", last_free_spin_iso)
	cfg.save(FILE)
	changed.emit()


# ── Server sync (P-M3+) ──────────────────────────────────────────────────

## Called by main_menu / room_browser / room_lobby once they've established
## a NetRpc peer to the DS. Wires up server_profile_received and fires the
## bootstrap RPC carrying our local snapshot as defaults (server creates
## the account row with these on first contact; later visits reuse).
func sync_with_server() -> void:
	if not has_node(^"/root/NetRpc"):
		return
	var net_rpc: Node = get_node(^"/root/NetRpc")
	# Idempotent wiring — connect() guards if already connected.
	if not net_rpc.server_profile_received.is_connected(_apply_server_profile):
		net_rpc.server_profile_received.connect(_apply_server_profile)
	if not net_rpc.server_action_result_received.is_connected(_on_server_action):
		net_rpc.server_action_result_received.connect(_on_server_action)
	if not net_rpc.server_reward_received.is_connected(_on_server_reward):
		net_rpc.server_reward_received.connect(_on_server_reward)
	if not net_rpc.server_leaderboard_received.is_connected(_on_server_leaderboard):
		net_rpc.server_leaderboard_received.connect(_on_server_leaderboard)
	if device_id.is_empty():
		device_id = _generate_device_id()
		save_to_disk()
	# P0-1: send our cached auth_token alongside device_id. Empty on first
	# contact ever or after a wipe → server issues a fresh one in the
	# server_profile reply, which _apply_server_profile persists.
	net_rpc.client_request_profile.rpc_id(1, device_id, auth_token, player_name, skin_index)


func _apply_server_profile(profile: Dictionary) -> void:
	# Server is canonical for these fields — replace local copies.
	account_id = int(profile.get("account_id", 0))
	player_name = String(profile.get("player_name", player_name))
	skin_index = int(profile.get("skin_index", skin_index))
	credits = int(profile.get("credits", credits))
	fragments = int(profile.get("fragments", fragments))
	purchased = Array(profile.get("owned", purchased))
	common_chests = int(profile.get("common_chests", common_chests))
	rare_chests = int(profile.get("rare_chests", rare_chests))
	upgrades = Dictionary(profile.get("upgrades", upgrades))
	# P0-1: server-issued bearer token. Present only when the server JUST
	# issued one (first contact ever, or first contact after the migration
	# stamped our existing account). Subsequent server_profile pushes
	# omit it because the cached token is still valid.
	var issued_token: String = String(profile.get("auth_token", ""))
	if not issued_token.is_empty():
		auth_token = issued_token
	# last_free_spin is server-ms now; keep iso fallback for offline-only render
	save_to_disk()
	synced_with_server = true
	profile_synced.emit()
	credits_changed.emit(credits)
	fragments_changed.emit(fragments)
	purchased_changed.emit()
	chests_changed.emit()
	upgrades_changed.emit()


func _on_server_action(action: String, ok: bool, reason: String) -> void:
	server_action.emit(action, ok, reason)


func _on_server_reward(kind: String, reward: Dictionary) -> void:
	reward_received.emit(kind, reward)


func _on_server_leaderboard(rows: Array) -> void:
	leaderboard_received.emit(rows)


## Returns true if a server peer is reachable AND we've already synced.
## Mutations route through RPC when this is true; else write local-only.
func _server_authoritative() -> bool:
	if not synced_with_server or account_id == 0:
		return false
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return false
	return not multiplayer.is_server()


func _generate_device_id() -> String:
	# 16 random hex chars. Crypto-grade since this is auth-adjacent.
	var bytes: PackedByteArray = Crypto.new().generate_random_bytes(16)
	var hex: String = ""
	for b in bytes:
		hex += "%02x" % b
	return hex


# ── Mutation methods route through server when synced ────────────────────

func request_leaderboard() -> void:
	if not has_node(^"/root/NetRpc"):
		return
	get_node(^"/root/NetRpc").client_request_leaderboard.rpc_id(1)


func request_purchase_weapon(weapon_id: String, price: int) -> bool:
	if not _server_authoritative():
		# Offline fallback — old behavior
		if not spend_credits(price):
			return false
		mark_purchased(weapon_id)
		return true
	get_node(^"/root/NetRpc").client_purchase_weapon.rpc_id(1, weapon_id, price)
	return true   # ack via server_action_result


func request_open_chest(kind: String) -> bool:
	if not _server_authoritative():
		# Offline fallback removed — chest rewards must be server-authoritative
		# (else clients can re-roll). Block instead.
		return false
	get_node(^"/root/NetRpc").client_open_chest.rpc_id(1, kind)
	return true


func request_apply_upgrade(weapon_id: String, stat: String, level: int) -> bool:
	if not _server_authoritative():
		return false
	get_node(^"/root/NetRpc").client_apply_upgrade.rpc_id(1, weapon_id, stat, level)
	return true


func request_spin_wheel() -> bool:
	if not _server_authoritative():
		return false
	get_node(^"/root/NetRpc").client_spin_wheel.rpc_id(1)
	return true


func request_register_account(handle: String, password: String) -> void:
	if not has_node(^"/root/NetRpc"):
		return
	get_node(^"/root/NetRpc").client_register_account.rpc_id(1, device_id, handle, password)


func request_login(handle: String, password: String) -> void:
	if not has_node(^"/root/NetRpc"):
		return
	get_node(^"/root/NetRpc").client_login.rpc_id(1, handle, password)


## Cheat / unlock code redemption. Listen for `server_action("redeem_code",
## ok, reason)` to know the outcome.
func request_redeem_code(code: String) -> void:
	if not has_node(^"/root/NetRpc"):
		return
	get_node(^"/root/NetRpc").client_redeem_code.rpc_id(1, code)


## Award currency for a kill (or any positive event). Matches the original
## pvp-game/server.js economy: kills earn `credits_per_kill`, wins earn extra
## via record_match_end. Saves on every change so a crash mid-match doesn't
## wipe progress.
func award_credits(amount: int) -> void:
	if amount <= 0:
		return
	credits += amount
	credits_changed.emit(credits)
	save_to_disk()


func award_fragments(amount: int) -> void:
	if amount <= 0:
		return
	fragments += amount
	fragments_changed.emit(fragments)
	save_to_disk()


# ── Shop ops ────────────────────────────────────────────────────────────
func can_afford_credits(cost: int) -> bool:
	return credits >= cost


func can_afford_fragments(cost: int) -> bool:
	return fragments >= cost


func spend_credits(cost: int) -> bool:
	if not can_afford_credits(cost):
		return false
	credits -= cost
	credits_changed.emit(credits)
	save_to_disk()
	return true


func spend_fragments(cost: int) -> bool:
	if not can_afford_fragments(cost):
		return false
	fragments -= cost
	fragments_changed.emit(fragments)
	save_to_disk()
	return true


func is_owned(weapon_id: String) -> bool:
	return weapon_id in purchased


func mark_purchased(weapon_id: String) -> void:
	if weapon_id in purchased:
		return
	purchased.append(weapon_id)
	purchased_changed.emit()
	save_to_disk()


func add_chest(kind: StringName, count: int = 1) -> void:
	if kind == &"common":
		common_chests += count
	else:
		rare_chests += count
	chests_changed.emit()
	save_to_disk()


func consume_chest(kind: StringName) -> bool:
	if kind == &"common" and common_chests > 0:
		common_chests -= 1
		chests_changed.emit()
		save_to_disk()
		return true
	if kind == &"rare" and rare_chests > 0:
		rare_chests -= 1
		chests_changed.emit()
		save_to_disk()
		return true
	return false


func get_upgrade(weapon_id: String, stat: StringName) -> int:
	var rec: Dictionary = upgrades.get(weapon_id, {})
	return int(rec.get(stat, 0))


## OFFLINE-ONLY local upgrade (practice / no server). Online play must route
## through request_apply_upgrade → server. Rule mirrors NetProtocol (the shared
## source of truth) + ProfileService so offline and online behave identically.
func bump_upgrade(weapon_id: String, stat: StringName) -> bool:
	var rec: Dictionary = upgrades.get(weapon_id, {})
	var cur: int = int(rec.get(stat, 0))
	if cur >= NetProtocol.MAX_UPGRADE_LEVELS_PER_WEAPON:
		return false
	var cost: int = NetProtocol.UPGRADE_COST_PER_LEVEL
	if not spend_fragments(cost):
		return false
	rec[stat] = cur + 1
	upgrades[weapon_id] = rec
	upgrades_changed.emit()
	save_to_disk()
	return true


func has_free_spin_today() -> bool:
	var today: String = Time.get_date_string_from_system(true)
	return last_free_spin_iso != today


func record_free_spin() -> void:
	last_free_spin_iso = Time.get_date_string_from_system(true)
	save_to_disk()


func set_skin(idx: int) -> void:
	skin_index = clampi(idx, 0, 17)
	save_to_disk()


## Renamed from set_name to set_player_name because Node already defines
## set_name(StringName) and overriding it confuses the engine.
func set_player_name(n: String) -> void:
	player_name = n.strip_edges().left(16)
	save_to_disk()


func _pick_random_default_name() -> String:
	var candidates: Array = [
		"Ace", "Bolt", "Crash", "Dash", "Echo", "Flash", "Gale", "Hawk",
		"Iron", "Jade", "Knox", "Luna", "Maze", "Nova", "Onyx", "Pixel",
		"Quark", "Ranger", "Storm", "Tango", "Vortex", "Wisp", "Xeno", "Zen",
	]
	return candidates[randi() % candidates.size()]
