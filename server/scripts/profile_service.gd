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
const _WEAPON_REGISTRY = preload("res://shared/scripts/weapon_registry.gd")

# Lazy-built once per process; canonical source for weapon pricing on the
# server side. Client-sent `price` arg is ignored.
var _weapon_registry: Node = null


func _get_weapon_registry() -> Node:
	if _weapon_registry == null:
		_weapon_registry = _WEAPON_REGISTRY.new()
	return _weapon_registry

# Anti-spam: per-peer rate windows for the heavier RPCs (purchase / chest
# open / wheel spin). Stops a malicious client from draining the DB.
const RATE_WINDOW_MS := 1000
const RATE_MAX_PER_WINDOW := 8
var _peer_rate: Dictionary = {}   # peer_id → { window_start_ms: int, count: int }

# Each connected peer's bound account_id. Empty until they client_request_profile.
var _peer_account: Dictionary = {}   # peer_id (int) → account_id (int)

# P0-1: token issued by bind_account but not yet pushed to client. Consumed
# by the next _push_profile call so the client's persistence layer can save
# it to user://settings.cfg for the next session.
var _pending_issued_token: Dictionary = {}   # peer_id → token String

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
	net_rpc.client_redeem_code_received.connect(_on_redeem_code)
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
	_pending_issued_token.erase(peer_id)


# ── Bootstrap ────────────────────────────────────────────────────────────

func _on_request_profile(peer_id: int, device_id: String, auth_token: String, local_name: String, local_skin: int) -> void:
	if not _is_authoritative_server():
		return
	if device_id.length() > 64:
		_ack(peer_id, "request_profile", false, "bad device_id")
		return
	if auth_token.length() > 128:
		_ack(peer_id, "request_profile", false, "bad token")
		return
	var db: Node = get_node(^"/root/Database")
	# P0-1: server-issued bearer token replaces "device_id alone == auth".
	# bind_account returns {} if the supplied token doesn't match the
	# account's stored hash — refuse the bind rather than letting an
	# attacker with a stolen device_id inherit credits / weapons.
	var bind: Dictionary = db.bind_account(device_id, auth_token, local_name, local_skin)
	if bind.is_empty():
		_ack(peer_id, "request_profile", false, "auth failed")
		return
	_peer_account[peer_id] = int(bind.account_id)
	# Stash any newly-issued token so _push_profile attaches it to the
	# server_profile payload. Empty = "you already had a valid token".
	_pending_issued_token[peer_id] = String(bind.get("issued_token", ""))
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
	# Attach freshly-issued token (if any) — client persists it for the
	# next session. Empty string means "your existing token is still good,
	# don't touch what you have stored".
	var token: String = String(_pending_issued_token.get(peer_id, ""))
	if not token.is_empty():
		profile["auth_token"] = token
		_pending_issued_token.erase(peer_id)
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

func _on_purchase_weapon(peer_id: int, weapon_id: String, _price: int) -> void:
	# Client-sent `_price` is intentionally ignored — the server looks up the
	# canonical price_credits on the WeaponDef resource. Reject unknown ids
	# and zero-priced (non-buyable) weapons rather than silently floor-ing.
	if not _is_authoritative_server() or not _peer_account.has(peer_id):
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "purchase", false, "rate limited")
		return
	var weapon: Resource = _get_weapon_registry().get_weapon(StringName(weapon_id))
	if weapon == null:
		_ack(peer_id, "purchase", false, "unknown weapon")
		return
	var actual_price: int = int(weapon.price_credits)
	if actual_price <= 0:
		_ack(peer_id, "purchase", false, "not for sale")
		return
	var account_id: int = _peer_account[peer_id]
	var db: Node = get_node(^"/root/Database")
	# Already owned?
	var owned: Array = db.list_owned_weapons(account_id)
	if weapon_id in owned:
		_ack(peer_id, "purchase", false, "already owned")
		return
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
	# Whitelist kind — column names cannot be parameterised in SQL, so we
	# never interpolate the client string into the query. Each kind has its
	# own hard-coded SELECT/UPDATE branch below.
	if kind != "common" and kind != "rare":
		_ack(peer_id, "open_chest", false, "bad chest kind")
		return
	var account_id: int = _peer_account[peer_id]
	var db: Node = get_node(^"/root/Database")
	# Wrap the whole "spend chest-or-credits + roll reward + award credits +
	# award fragments" sequence in a single transaction. Without this, a
	# crash between "spent chest" and "awarded reward" leaves the player
	# with -1 chest and zero compensation; or worse, the chest survives but
	# the reward already got partially credited.
	if not db.begin_transaction():
		_ack(peer_id, "open_chest", false, "db busy")
		return
	# Two paths: spend a chest from inventory, or buy + open in one shot.
	if kind == "common":
		db.db.query_with_bindings("SELECT common_chests AS qty, credits FROM economy WHERE account_id = ?", [account_id])
	else:
		db.db.query_with_bindings("SELECT rare_chests AS qty, credits FROM economy WHERE account_id = ?", [account_id])
	if db.db.query_result.is_empty():
		db.rollback()
		_ack(peer_id, "open_chest", false, "no economy row")
		return
	var row: Dictionary = db.db.query_result[0]
	var qty: int = int(row.get("qty", 0))
	var credits: int = int(row.get("credits", 0))
	if qty > 0:
		if kind == "common":
			db.db.query_with_bindings("UPDATE economy SET common_chests = common_chests - 1 WHERE account_id = ?", [account_id])
		else:
			db.db.query_with_bindings("UPDATE economy SET rare_chests = rare_chests - 1 WHERE account_id = ?", [account_id])
	else:
		var price: int = int(CHEST_PRICE.get(kind, 9999))
		if credits < price:
			db.rollback()
			_ack(peer_id, "open_chest", false, "insufficient credits")
			return
		if not db.spend_credits(account_id, price):
			db.rollback()
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
	db.commit()
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
	# Atomic: stamp last_free_spin_ms + credit reward in one transaction.
	# Without this, a crash mid-spin could either credit the reward without
	# stamping the cooldown (= infinite free spins) or stamp without
	# crediting (= player loses their reward).
	if not db.begin_transaction():
		_ack(peer_id, "spin", false, "db busy")
		return
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
	db.commit()
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
	# (a) peer already has anonymous account by device_id → upgrade it,
	#     but ONLY if the account isn't already claimed by someone else's
	#     prior register (P0-1 hardening — without this an attacker who
	#     bound to a victim's anon device_id could silently overwrite the
	#     victim's handle + pass_hash and lock them out).
	# (b) brand-new → create
	if _peer_account.has(peer_id):
		var acct_id: int = _peer_account[peer_id]
		if db.account_is_registered(acct_id):
			_ack(peer_id, "register", false, "account already registered")
			return
		db.db.query_with_bindings("UPDATE accounts SET handle = ?, pass_hash = ? WHERE id = ?", [h, pass_hash, acct_id])
		_ack(peer_id, "register", true, "")
		_push_profile(peer_id)
		return
	# Brand-new (no device_id binding yet) — bootstrap via bind_account so
	# the new account also gets an auth_token; otherwise it'd be stuck on
	# the legacy "device_id alone" auth path forever.
	var bind: Dictionary = db.bind_account(device_id, "", h, 0)
	if bind.is_empty():
		_ack(peer_id, "register", false, "db error")
		return
	var account: Dictionary = bind.account
	if db.account_is_registered(int(account.id)):
		# Race: someone else bound to this device_id and registered between
		# our bind and the registration. Refuse to overwrite their handle.
		_ack(peer_id, "register", false, "account already registered")
		return
	db.db.query_with_bindings("UPDATE accounts SET handle = ?, pass_hash = ? WHERE id = ?", [h, pass_hash, account.id])
	_peer_account[peer_id] = int(account.id)
	_pending_issued_token[peer_id] = String(bind.get("issued_token", ""))
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


# Cheat / unlock code redemption — looks code up in unlock_codes.gd,
# applies the reward atomically. Server-canonical; client just types
# the string. Each code can be redeemed once per account.
const _UNLOCK_CODES := preload("res://client/scripts/data/unlock_codes.gd")


func _on_redeem_code(peer_id: int, code: String) -> void:
	if not _is_authoritative_server() or not _peer_account.has(peer_id):
		return
	if not _peer_ok_for_action(peer_id):
		_ack(peer_id, "redeem_code", false, "rate limited")
		return
	var reward: Variant = _UNLOCK_CODES.reward_for(code)
	if reward == null:
		_ack(peer_id, "redeem_code", false, "unknown code")
		return
	var account_id: int = _peer_account[peer_id]
	var db: Node = get_node(^"/root/Database")
	# Idempotency: track redeemed codes per account so the same code can't
	# be reused. Stored as a TEXT JSON array in accounts.redeemed_codes.
	# If the column doesn't exist yet, the first redemption ALTER-adds it.
	if not db.has_method(&"is_code_redeemed") or not db.has_method(&"mark_code_redeemed"):
		_ack(peer_id, "redeem_code", false, "db schema out of date")
		return
	var key: String = code.strip_edges().to_lower()
	if db.is_code_redeemed(account_id, key):
		_ack(peer_id, "redeem_code", false, "already redeemed")
		return
	# Apply the reward.
	var r: Dictionary = reward
	if r.has("weapon"):
		db.grant_weapon(account_id, String(r["weapon"]))
	if r.has("credits"):
		db.award_credits(account_id, int(r["credits"]))
	if r.has("fragments"):
		db.award_fragments(account_id, int(r["fragments"]))
	if r.has("admin_pass"):
		# Grant ALL weapons (the way pvp-game does it). Walk the weapon
		# directory + grant each id.
		var dir := DirAccess.open("res://shared/data/weapons/")
		if dir != null:
			dir.list_dir_begin()
			var fname: String = dir.get_next()
			while fname != "":
				if fname.ends_with(".tres") and not fname.begins_with("_"):
					db.grant_weapon(account_id, fname.replace(".tres", ""))
				fname = dir.get_next()
	if r.has("all_weapons_minutes"):
		# Temporary unlock — same as admin_pass but caller is expected
		# to enforce expiry. MVP: treat as permanent grant (cheaper).
		var dir2 := DirAccess.open("res://shared/data/weapons/")
		if dir2 != null:
			dir2.list_dir_begin()
			var fn2: String = dir2.get_next()
			while fn2 != "":
				if fn2.ends_with(".tres") and not fn2.begins_with("_"):
					db.grant_weapon(account_id, fn2.replace(".tres", ""))
				fn2 = dir2.get_next()
	db.mark_code_redeemed(account_id, key)
	_ack(peer_id, "redeem_code", true, "redeemed: " + key)
	_push_profile(peer_id)


# ── Public helpers for other server systems ─────────────────────────────

# Anti-cheat: per-peer running headshot-ratio counters, kept in memory
# for the lifetime of the DS process. Reset on peer_disconnect.
var _peer_kills: Dictionary = {}        # peer_id → int
var _peer_headshots: Dictionary = {}    # peer_id → int
var _peer_hs_warned: Dictionary = {}    # peer_id → bool (only warn once per session)


## Called by GameController._on_any_player_died on the DS so the death/kill
## also ticks the cross-match `stats_lifetime` table for leaderboards.
func record_death(killer_peer: int, victim_peer: int) -> void:
	if not _is_authoritative_server():
		return
	var killer_id: int = int(_peer_account.get(killer_peer, 0))
	var victim_id: int = int(_peer_account.get(victim_peer, 0))
	var db: Node = get_node(^"/root/Database")
	db.record_kill(killer_id, victim_id)


## fire_resolver calls this when a fatal headshot lands. Tracks running
## ratio per peer; if a peer's HS / kills > threshold AND kills >= sample
## floor, push_warning so a human reviewer notices. Warn-only — false
## positives on a streak of legit clutch shots would frustrate real players.
func record_headshot_kill(killer_peer: int) -> void:
	if killer_peer <= 0:
		return
	_peer_kills[killer_peer] = int(_peer_kills.get(killer_peer, 0)) + 1
	_peer_headshots[killer_peer] = int(_peer_headshots.get(killer_peer, 0)) + 1
	_maybe_alert_headshot_ratio(killer_peer)


## fire_resolver also calls this for non-head kills so the denominator is
## accurate. Headshot ratio = hs / (hs + body) = hs / total_kills.
func record_body_kill(killer_peer: int) -> void:
	if killer_peer <= 0:
		return
	_peer_kills[killer_peer] = int(_peer_kills.get(killer_peer, 0)) + 1
	_maybe_alert_headshot_ratio(killer_peer)


func _maybe_alert_headshot_ratio(peer_id: int) -> void:
	if _peer_hs_warned.get(peer_id, false):
		return   # only one warning per peer per session
	var kills: int = int(_peer_kills.get(peer_id, 0))
	if kills < NetProtocol.SUSPECT_HEADSHOT_MIN_KILLS:
		return
	var heads: int = int(_peer_headshots.get(peer_id, 0))
	var ratio: float = float(heads) / float(kills)
	if ratio > NetProtocol.SUSPECT_HEADSHOT_RATIO:
		_peer_hs_warned[peer_id] = true
		var line: String = "peer %d headshot ratio %.2f (%d/%d) exceeds %.2f — possible aimbot" % \
			[peer_id, ratio, heads, kills, NetProtocol.SUSPECT_HEADSHOT_RATIO]
		push_warning("[anticheat] " + line)
		_anticheat_log("headshot_ratio", line)


# Admin dashboard MVP — every push_warning() from the anti-cheat layer also
# appends a JSON line to `user://anticheat.log`. SSH onto the VPS and
# `tail -f /root/.local/share/godot/app_userdata/godot-pvp/anticheat.log`
# to monitor in real time. Future: surface via an RPC + admin client UI.
func _anticheat_log(category: String, message: String) -> void:
	var line: Dictionary = {
		"ts_ms": int(Time.get_unix_time_from_system() * 1000.0),
		"category": category,
		"message": message,
	}
	var f := FileAccess.open("user://anticheat.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://anticheat.log", FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(JSON.stringify(line))
	f.close()


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
