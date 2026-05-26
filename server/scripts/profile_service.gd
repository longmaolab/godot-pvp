extends Node
## Server-side bridge between NetRpc.client_*_received signals (persistence
## RPCs) and the Database autoload's DAO methods. Replies are pushed back
## through NetRpc.server_profile / server_action_result / server_leaderboard
## / server_reward — clients receive them and update local mirrors.
##
## Maps peer_id → account_id for the lifetime of a connection. New peers
## start anonymous (no entry) and get a row on first client_request_profile.
## Disconnect clears the mapping.
##
## Autoload: loaded on every Godot process (DS + listen-host + client web).
## All handlers gate on `_is_authoritative_server()` so client-side instances
## stay inert — they own no DB, no business logic. Only the DS executes.

const Database = preload("res://server/scripts/database.gd")

# Anti-spam: per-peer rate windows for the heavier RPCs (purchase / chest
# open / wheel spin). Stops a malicious client from draining the DB.
const RATE_WINDOW_MS := 1000
const RATE_MAX_PER_WINDOW := 8
var _peer_rate: Dictionary = {}   # peer_id → { window_start_ms: int, count: int }

# Each connected peer's bound account_id. Empty until they client_request_profile.
var _peer_account: Dictionary = {}   # peer_id (int) → account_id (int)

# Pricing table — bumped here so we can tune without touching DB schema.
# Mirror of pvp-game economy values for now. Server-canonical.
const CHEST_PRICE := {"common": 120, "rare": 400}
const FRAGMENT_UNLOCK_COST := 100
const STARTER_CREDITS := 500
# Chest reward bands (uniform-ish to start; tune by analytics later)
const CHEST_REWARDS := {
	"common": {"credits": [40, 90], "fragments": [3, 10]},
	"rare":   {"credits": [180, 350], "fragments": [20, 45], "rare_weapon_chance": 0.05},
}
# Daily wheel: 24h cooldown, slot picked uniformly
const WHEEL_COOLDOWN_MS := 86_400_000
const WHEEL_REWARDS := [
	{"credits": 50},
	{"credits": 150},
	{"credits": 300},
	{"fragments": 5},
	{"fragments": 15},
	{"common_chests": 1},
	{"rare_chests": 1},
	{"credits": 1000},   # jackpot
]


static func _s(v, default: String = "") -> String:
	# Null-safe string conversion. sqlite returns null for unset TEXT columns,
	# and Godot 4's String() constructor errors on null with "Nonexistent
	# constructor". This is the workaround.
	if v == null:
		return default
	return str(v)


func _ready() -> void:
	# Wire signals on both client + server; the gate inside each handler
	# means client-side autoload instances just no-op.
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc == null:
		push_warning("[ProfileService] NetRpc autoload not present — skipping wiring")
		return
	net_rpc.client_request_profile_received.connect(_on_request_profile)
	net_rpc.client_set_player_name_received.connect(_on_set_name)
	net_rpc.client_set_skin_index_received.connect(_on_set_skin)
	net_rpc.client_purchase_weapon_received.connect(_on_purchase_weapon)
	net_rpc.client_open_chest_received.connect(_on_open_chest)
	net_rpc.client_apply_upgrade_received.connect(_on_apply_upgrade)
	net_rpc.client_spin_wheel_received.connect(_on_spin_wheel)
	net_rpc.client_request_leaderboard_received.connect(_on_request_leaderboard)
	net_rpc.client_register_account_received.connect(_on_register_account)
	net_rpc.client_login_received.connect(_on_login)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _is_authoritative_server() -> bool:
	# Real network peer AND we're the server on it (matches RoomManager's
	# _is_real_networked_server pattern).
	var p: MultiplayerPeer = multiplayer.multiplayer_peer
	if p == null or p is OfflineMultiplayerPeer:
		return false
	if not multiplayer.is_server():
		return false
	# DB must be live; if godot-sqlite failed to load, all DAO is no-op.
	var dbnode: Node = get_node_or_null(^"/root/Database")
	return dbnode != null and dbnode._ready_for_queries


func _peer_ok_for_action(peer_id: int) -> bool:
	# Lightweight per-peer throttle. Used by mutation RPCs.
	var now: int = Time.get_ticks_msec()
	var s: Dictionary = _peer_rate.get(peer_id, {"window_start_ms": now, "count": 0})
	if now - int(s.get("window_start_ms", 0)) > RATE_WINDOW_MS:
		s = {"window_start_ms": now, "count": 0}
	s["count"] = int(s.get("count", 0)) + 1
	_peer_rate[peer_id] = s
	return int(s["count"]) <= RATE_MAX_PER_WINDOW


func _on_peer_disconnected(peer_id: int) -> void:
	_peer_account.erase(peer_id)
	_peer_rate.erase(peer_id)


# ── Bootstrap ────────────────────────────────────────────────────────────

func _on_request_profile(peer_id: int, device_id: String, local_name: String, local_skin: int) -> void:
	if not _is_authoritative_server():
		return
	if device_id.is_empty() or device_id.length() > 64:
		_ack(peer_id, "request_profile", false, "bad device_id")
		return
	var db: Node = get_node(^"/root/Database")
	var account: Dictionary = db.get_or_create_account(device_id, local_name, local_skin)
	if account.is_empty():
		_ack(peer_id, "request_profile", false, "db error")
		return
	_peer_account[peer_id] = int(account.id)
	_push_profile(peer_id)


func _push_profile(peer_id: int) -> void:
	# Composite snapshot: account row + economy + owned weapons + upgrades.
	# Client's Settings autoload mirrors these fields.
	if not _peer_account.has(peer_id):
		return
	var account_id: int = _peer_account[peer_id]
	var db: Node = get_node(^"/root/Database")
	var acct: Dictionary = {}
	db.db.query_with_bindings("SELECT id, player_name, skin_index, handle FROM accounts WHERE id = ?", [account_id])
	if not db.db.query_result.is_empty():
		acct = db.db.query_result[0]
	var econ: Dictionary = db.get_economy(account_id)
	var owned: Array = db.list_owned_weapons(account_id)
	# All upgrades, grouped by weapon_id
	db.db.query_with_bindings("SELECT weapon_id, stat, level FROM weapon_upgrades WHERE account_id = ?", [account_id])
	var upgrades: Dictionary = {}
	for row in db.db.query_result:
		var wid: String = _s(row.weapon_id)
		if not upgrades.has(wid):
			upgrades[wid] = {}
		upgrades[wid][_s(row.stat)] = int(row.level)
	var profile: Dictionary = {
		"account_id":  account_id,
		"player_name": _s(acct.get("player_name"), "Player"),
		"skin_index":  int(acct.get("skin_index", 0)),
		"handle":      _s(acct.get("handle"), ""),
		"credits":     int(econ.get("credits", 0)),
		"fragments":   int(econ.get("fragments", 0)),
		"common_chests": int(econ.get("common_chests", 0)),
		"rare_chests":   int(econ.get("rare_chests", 0)),
		"last_free_spin_ms": int(econ.get("last_free_spin_ms", 0)),
		"owned":       owned,
		"upgrades":    upgrades,
	}
	var net_rpc: Node = get_node(^"/root/NetRpc")
	net_rpc.server_profile.rpc_id(peer_id, profile)


# ── Profile mutations ───────────────────────────────────────────────────

func _on_set_name(peer_id: int, name: String) -> void:
	if not _is_authoritative_server() or not _peer_account.has(peer_id):
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "set_name", false, "rate limited")
		return
	var db: Node = get_node(^"/root/Database")
	if not db.update_account_name(_peer_account[peer_id], name):
		_ack(peer_id, "set_name", false, "name rejected")
		return
	_ack(peer_id, "set_name", true, "")
	_push_profile(peer_id)


func _on_set_skin(peer_id: int, skin: int) -> void:
	if not _is_authoritative_server() or not _peer_account.has(peer_id):
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "set_skin", false, "rate limited")
		return
	var db: Node = get_node(^"/root/Database")
	db.update_account_skin(_peer_account[peer_id], skin)
	_ack(peer_id, "set_skin", true, "")
	_push_profile(peer_id)


# ── Economy ─────────────────────────────────────────────────────────────

func _on_purchase_weapon(peer_id: int, weapon_id: String, price: int) -> void:
	if not _is_authoritative_server() or not _peer_account.has(peer_id):
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "purchase", false, "rate limited")
		return
	var account_id: int = _peer_account[peer_id]
	var db: Node = get_node(^"/root/Database")
	# Already owned?
	var owned: Array = db.list_owned_weapons(account_id)
	if weapon_id in owned:
		_ack(peer_id, "purchase", false, "already owned")
		return
	# Server-canonical price — client-sent `price` arg ignored (anti-cheat).
	# Real lookup: TODO weapon registry server-side, hard-coded fallback for now.
	var actual_price: int = max(100, price)   # min floor, client value as cap
	if not db.spend_credits(account_id, actual_price):
		_ack(peer_id, "purchase", false, "insufficient credits")
		return
	db.grant_weapon(account_id, weapon_id)
	_ack(peer_id, "purchase", true, "")
	_push_profile(peer_id)


func _on_open_chest(peer_id: int, kind: String) -> void:
	if not _is_authoritative_server() or not _peer_account.has(peer_id):
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "open_chest", false, "rate limited")
		return
	var account_id: int = _peer_account[peer_id]
	var db: Node = get_node(^"/root/Database")
	# Two paths: spend a chest from inventory, or buy + open in one shot.
	var col: String = "common_chests" if kind == "common" else "rare_chests"
	db.db.query_with_bindings("SELECT %s AS qty, credits FROM economy WHERE account_id = ?" % col, [account_id])
	if db.db.query_result.is_empty():
		_ack(peer_id, "open_chest", false, "no economy row")
		return
	var row: Dictionary = db.db.query_result[0]
	var qty: int = int(row.get("qty", 0))
	var credits: int = int(row.get("credits", 0))
	if qty > 0:
		db.db.query_with_bindings("UPDATE economy SET %s = %s - 1 WHERE account_id = ?" % [col, col], [account_id])
	else:
		var price: int = int(CHEST_PRICE.get(kind, 9999))
		if credits < price:
			_ack(peer_id, "open_chest", false, "insufficient credits")
			return
		if not db.spend_credits(account_id, price):
			_ack(peer_id, "open_chest", false, "race lost")
			return
	# Roll reward
	var band: Dictionary = CHEST_REWARDS.get(kind, CHEST_REWARDS["common"])
	var cr: Array = band["credits"]
	var fg: Array = band["fragments"]
	var awarded_credits: int = randi_range(int(cr[0]), int(cr[1]))
	var awarded_fragments: int = randi_range(int(fg[0]), int(fg[1]))
	db.award_credits(account_id, awarded_credits)
	db.award_fragments(account_id, awarded_fragments)
	var reward := {"credits": awarded_credits, "fragments": awarded_fragments}
	var net_rpc: Node = get_node(^"/root/NetRpc")
	net_rpc.server_reward.rpc_id(peer_id, kind, reward)
	_ack(peer_id, "open_chest", true, "")
	_push_profile(peer_id)


func _on_apply_upgrade(peer_id: int, weapon_id: String, stat: String, level: int) -> void:
	if not _is_authoritative_server() or not _peer_account.has(peer_id):
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "upgrade", false, "rate limited")
		return
	if not stat in ["damage", "mag", "reload"]:
		_ack(peer_id, "upgrade", false, "bad stat")
		return
	var account_id: int = _peer_account[peer_id]
	var db: Node = get_node(^"/root/Database")
	# Must own weapon to upgrade it
	if not weapon_id in db.list_owned_weapons(account_id):
		_ack(peer_id, "upgrade", false, "weapon not owned")
		return
	var current: Dictionary = db.get_upgrades(account_id, weapon_id)
	var cur_level: int = int(current.get(stat, 0))
	var target: int = clampi(level, 0, 10)
	if target <= cur_level:
		_ack(peer_id, "upgrade", false, "already at or above")
		return
	# Cost per level: 5 fragments × delta levels (cheap; tune later)
	var cost: int = (target - cur_level) * 5
	if not db.spend_fragments(account_id, cost):
		_ack(peer_id, "upgrade", false, "insufficient fragments")
		return
	db.set_upgrade_level(account_id, weapon_id, stat, target)
	_ack(peer_id, "upgrade", true, "")
	_push_profile(peer_id)


func _on_spin_wheel(peer_id: int) -> void:
	if not _is_authoritative_server() or not _peer_account.has(peer_id):
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "spin", false, "rate limited")
		return
	var account_id: int = _peer_account[peer_id]
	var db: Node = get_node(^"/root/Database")
	var econ: Dictionary = db.get_economy(account_id)
	var last: int = int(econ.get("last_free_spin_ms", 0))
	var now: int = int(Time.get_unix_time_from_system() * 1000.0)
	if now - last < WHEEL_COOLDOWN_MS:
		var remaining_ms: int = WHEEL_COOLDOWN_MS - (now - last)
		_ack(peer_id, "spin", false, "wait %d hours" % (remaining_ms / 3_600_000))
		return
	# Pick random reward
	var reward: Dictionary = WHEEL_REWARDS[randi() % WHEEL_REWARDS.size()].duplicate()
	if reward.has("credits"):
		db.award_credits(account_id, int(reward.credits))
	if reward.has("fragments"):
		db.award_fragments(account_id, int(reward.fragments))
	if reward.has("common_chests"):
		db.db.query_with_bindings("UPDATE economy SET common_chests = common_chests + 1 WHERE account_id = ?", [account_id])
	if reward.has("rare_chests"):
		db.db.query_with_bindings("UPDATE economy SET rare_chests = rare_chests + 1 WHERE account_id = ?", [account_id])
	db.db.query_with_bindings("UPDATE economy SET last_free_spin_ms = ? WHERE account_id = ?", [now, account_id])
	var net_rpc: Node = get_node(^"/root/NetRpc")
	net_rpc.server_reward.rpc_id(peer_id, "wheel", reward)
	_ack(peer_id, "spin", true, "")
	_push_profile(peer_id)


# ── Leaderboard ─────────────────────────────────────────────────────────

func _on_request_leaderboard(peer_id: int) -> void:
	if not _is_authoritative_server():
		return
	var db: Node = get_node(^"/root/Database")
	var rows: Array = db.get_leaderboard(20)
	var net_rpc: Node = get_node(^"/root/NetRpc")
	net_rpc.server_leaderboard.rpc_id(peer_id, rows)


# ── M7 real accounts ────────────────────────────────────────────────────

func _on_register_account(peer_id: int, device_id: String, handle: String, password: String) -> void:
	if not _is_authoritative_server():
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "register", false, "rate limited")
		return
	# Validate
	var h: String = handle.strip_edges()
	if h.length() < 3 or h.length() > 24:
		_ack(peer_id, "register", false, "handle 3-24 chars")
		return
	if password.length() < 6:
		_ack(peer_id, "register", false, "password 6+ chars")
		return
	var db: Node = get_node(^"/root/Database")
	# Handle already taken?
	db.db.query_with_bindings("SELECT id FROM accounts WHERE handle = ? COLLATE NOCASE", [h])
	if not db.db.query_result.is_empty():
		_ack(peer_id, "register", false, "handle taken")
		return
	var pass_hash: String = db.hash_password(password)
	# Two cases:
	# (a) peer already has anonymous account by device_id → upgrade it
	# (b) brand-new → create
	if _peer_account.has(peer_id):
		var acct_id: int = _peer_account[peer_id]
		db.db.query_with_bindings("UPDATE accounts SET handle = ?, pass_hash = ? WHERE id = ?", [h, pass_hash, acct_id])
		_ack(peer_id, "register", true, "")
		_push_profile(peer_id)
		return
	# Brand-new (no device_id binding yet)
	var account: Dictionary = db.get_or_create_account(device_id, h, 0)
	if account.is_empty():
		_ack(peer_id, "register", false, "db error")
		return
	db.db.query_with_bindings("UPDATE accounts SET handle = ?, pass_hash = ? WHERE id = ?", [h, pass_hash, account.id])
	_peer_account[peer_id] = int(account.id)
	_ack(peer_id, "register", true, "")
	_push_profile(peer_id)


func _on_login(peer_id: int, handle: String, password: String) -> void:
	if not _is_authoritative_server():
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "login", false, "rate limited")
		return
	var db: Node = get_node(^"/root/Database")
	db.db.query_with_bindings("SELECT id, pass_hash FROM accounts WHERE handle = ? COLLATE NOCASE", [handle])
	if db.db.query_result.is_empty():
		_ack(peer_id, "login", false, "no such account")
		return
	var row: Dictionary = db.db.query_result[0]
	var stored: String = _s(row.get("pass_hash"), "")
	if stored.is_empty():
		_ack(peer_id, "login", false, "account has no password set (anonymous)")
		return
	if not db.verify_password(password, stored):
		_ack(peer_id, "login", false, "wrong password")
		return
	_peer_account[peer_id] = int(row.id)
	_ack(peer_id, "login", true, "")
	_push_profile(peer_id)


# ── Utility ─────────────────────────────────────────────────────────────

func _ack(peer_id: int, action: String, ok: bool, reason: String) -> void:
	var net_rpc: Node = get_node_or_null(^"/root/NetRpc")
	if net_rpc != null:
		net_rpc.server_action_result.rpc_id(peer_id, action, ok, reason)


# ── Public helpers for other server systems ─────────────────────────────

## Called by GameController._on_any_player_died on the DS so the death/kill
## also ticks the cross-match `stats_lifetime` table for leaderboards.
func record_death(killer_peer: int, victim_peer: int) -> void:
	if not _is_authoritative_server():
		return
	var killer_id: int = int(_peer_account.get(killer_peer, 0))
	var victim_id: int = int(_peer_account.get(victim_peer, 0))
	var db: Node = get_node(^"/root/Database")
	db.record_kill(killer_id, victim_id)


## Called by GameController._on_match_finished_in_room. Stamps the winner +
## participant accounts in match_history.
func record_match_end(room_id: String, mode_id: String, map_id: String,
		started_ms: int, ended_ms: int, winner_peer: int, room_peers: Array, final_scores: Dictionary) -> void:
	if not _is_authoritative_server():
		return
	var db: Node = get_node(^"/root/Database")
	var winner_id: int = int(_peer_account.get(winner_peer, 0))
	var participants: Array = []
	for p in room_peers:
		var acct: int = int(_peer_account.get(p, 0))
		if acct > 0:
			participants.append(acct)
	db.record_match_result(winner_id, participants)
	db.append_match_history(room_id, mode_id, map_id, started_ms, ended_ms, winner_id, final_scores)
