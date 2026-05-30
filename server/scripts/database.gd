extends Node
## Server-side SQLite persistence. Loaded as autoload, but DB is only
## opened on the DS — clients (web export, listen-host) skip db init and
## treat all DAO methods as no-ops. All cross-device-persistent state
## (accounts, economy, weapon ownership, upgrades, lifetime stats, match
## history) lives here; per-device prefs (volume, sensitivity) stay in
## the existing Settings ConfigFile.
##
## Design plan: .agent/persistence_plan.md
## Library: godot-sqlite GDExtension v4.7 (addons/godot-sqlite/)

# DB file path on the DS host. systemd service runs as root so this
# directory is writable. Local dev uses user:// for convenience.
const DB_PATH_LINUX := "/var/lib/godot-pvp/godot-pvp.db"
const DB_PATH_FALLBACK := "user://godot-pvp.db"
# Reach NetProtocol via preload (the script class) so is_dedicated_server_boot()
# is a static call that doesn't depend on autoload load order or registration.
const NetProtocol = preload("res://shared/scripts/network/net_protocol.gd")

# Schema version. Bumped EACH time the schema needs ALTER. _migrate() runs
# every boot, applies any `_MIGRATIONS[v]` entry whose key is > the DB's
# stored `PRAGMA user_version`, and stamps the new version. `_CURRENT_SCHEMA_VERSION`
# must equal the highest key in `_MIGRATIONS` (asserted at boot).
#
# Existing fresh-boot DBs (made via `CREATE TABLE IF NOT EXISTS` before
# this framework existed) start at user_version=0; the v1 entry is a
# no-op that just stamps them as "schema v1 = matches current CREATE
# block". Future column additions add v2, v3, ... with the ALTER text.
const _CURRENT_SCHEMA_VERSION := 2
const _MIGRATIONS := {
	1: "",   # baseline — CREATE TABLE IF NOT EXISTS already shipped this schema
	2: "ALTER TABLE accounts ADD COLUMN auth_token_hash TEXT",
	# 3: "..."
}

var db: Object = null   # SQLite instance (godot-sqlite gdextension)
var _ready_for_queries: bool = false


func _ready() -> void:
	# Only the DS opens the DB. Clients (web export, listen-host without
	# --server flag) share the same autoload script but skip init.
	if not _should_open_db():
		print("[Database] client-side autoload — skipping DB init")
		return
	if not ClassDB.class_exists("SQLite"):
		push_error("[Database] godot-sqlite gdextension not loaded — DB unavailable")
		return
	db = ClassDB.instantiate("SQLite")
	db.path = _resolve_db_path()
	db.foreign_keys = true
	# Verbose errors during dev; flip to false in production once stable.
	db.verbosity_level = 1
	if not db.open_db():
		push_error("[Database] failed to open %s" % db.path)
		db = null
		return
	# WAL mode = better crash safety + concurrent reads
	db.query("PRAGMA journal_mode=WAL")
	db.query("PRAGMA synchronous=NORMAL")
	_create_tables()
	_migrate()
	_ready_for_queries = true
	print("[Database] ready at %s (WAL mode, foreign_keys=ON, schema v%d)" % [db.path, _read_schema_version()])


## True for dedicated server boot. Uses NetProtocol's helper (which
## checks `--server` in cmdline_USER_args; engine args are passed before
## the `--` separator, --server lives after it). Don't roll our own —
## get_cmdline_args() returns only engine args, get_cmdline_user_args()
## returns post-`--` args. NetProtocol.is_dedicated_server_boot wraps
## the right one.
func _should_open_db() -> bool:
	if OS.has_environment("GODOT_PVP_FORCE_DB"):
		return true
	return NetProtocol.is_dedicated_server_boot()


func _resolve_db_path() -> String:
	# Production VPS: write to /var/lib/godot-pvp/. Locally / non-Linux:
	# fall back to user:// so devs can run --server without root permissions.
	if OS.get_name() == "Linux":
		var dir := DirAccess.open("/var/lib/godot-pvp")
		if dir != null:
			return DB_PATH_LINUX
		# Try create
		DirAccess.make_dir_recursive_absolute("/var/lib/godot-pvp")
		if DirAccess.dir_exists_absolute("/var/lib/godot-pvp"):
			return DB_PATH_LINUX
	return DB_PATH_FALLBACK


func _create_tables() -> void:
	# Idempotent — CREATE IF NOT EXISTS. Schema doc: .agent/persistence_plan.md §3.
	db.query("""
		CREATE TABLE IF NOT EXISTS accounts (
			id              INTEGER PRIMARY KEY AUTOINCREMENT,
			device_id       TEXT UNIQUE,
			handle          TEXT UNIQUE COLLATE NOCASE,
			pass_hash       TEXT,
			created_ms      INTEGER NOT NULL,
			last_seen_ms    INTEGER NOT NULL,
			player_name     TEXT NOT NULL DEFAULT 'Player',
			skin_index      INTEGER NOT NULL DEFAULT 0
		)
	""")
	db.query("CREATE INDEX IF NOT EXISTS idx_accounts_device ON accounts(device_id)")
	db.query("""
		CREATE TABLE IF NOT EXISTS economy (
			account_id          INTEGER PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
			credits             INTEGER NOT NULL DEFAULT 500,
			fragments           INTEGER NOT NULL DEFAULT 0,
			common_chests       INTEGER NOT NULL DEFAULT 0,
			rare_chests         INTEGER NOT NULL DEFAULT 0,
			last_free_spin_ms   INTEGER NOT NULL DEFAULT 0
		)
	""")
	db.query("""
		CREATE TABLE IF NOT EXISTS weapons_owned (
			account_id      INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
			weapon_id       TEXT NOT NULL,
			PRIMARY KEY (account_id, weapon_id)
		)
	""")
	db.query("""
		CREATE TABLE IF NOT EXISTS weapon_upgrades (
			account_id      INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
			weapon_id       TEXT NOT NULL,
			stat            TEXT NOT NULL,
			level           INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (account_id, weapon_id, stat)
		)
	""")
	db.query("""
		CREATE TABLE IF NOT EXISTS stats_lifetime (
			account_id      INTEGER PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
			kills           INTEGER NOT NULL DEFAULT 0,
			deaths          INTEGER NOT NULL DEFAULT 0,
			matches_won     INTEGER NOT NULL DEFAULT 0,
			matches_lost    INTEGER NOT NULL DEFAULT 0
		)
	""")
	db.query("CREATE INDEX IF NOT EXISTS idx_stats_kills_desc ON stats_lifetime(kills DESC)")
	db.query("""
		CREATE TABLE IF NOT EXISTS match_history (
			id              INTEGER PRIMARY KEY AUTOINCREMENT,
			room_id         TEXT NOT NULL,
			mode_id         TEXT NOT NULL,
			map_id          TEXT NOT NULL,
			started_ms      INTEGER NOT NULL,
			ended_ms        INTEGER NOT NULL,
			winner_id       INTEGER REFERENCES accounts(id),
			final_scores    TEXT
		)
	""")
	db.query("CREATE INDEX IF NOT EXISTS idx_match_started ON match_history(started_ms DESC)")


# ── Accounts DAO ─────────────────────────────────────────────────────────

## Find an existing anonymous account by device_id or create one. If
## name/skin provided, used as defaults for new accounts only — existing
## accounts keep their canonical values.
func get_or_create_account(device_id: String, default_name: String = "Player", default_skin: int = 0) -> Dictionary:
	if not _ready_for_queries:
		return {}
	var now: int = _now_ms()
	# Try lookup first
	db.query_with_bindings("SELECT * FROM accounts WHERE device_id = ?", [device_id])
	if not db.query_result.is_empty():
		var row: Dictionary = db.query_result[0]
		# Touch last_seen
		db.query_with_bindings("UPDATE accounts SET last_seen_ms = ? WHERE id = ?", [now, row.id])
		row["last_seen_ms"] = now
		return row
	# Create — wrap the 3 INSERTs + readback in a transaction so a crash
	# between the INSERTs can't leave an account with no economy row (which
	# made `get_economy` return {} → user shown 0 credits forever).
	var safe_name: String = (default_name if not default_name.strip_edges().is_empty() else "Player").substr(0, 24)
	var safe_skin: int = clampi(default_skin, 0, 17)
	if not begin_transaction():
		return {}
	var ok: bool = db.query_with_bindings("""
		INSERT INTO accounts (device_id, created_ms, last_seen_ms, player_name, skin_index)
		VALUES (?, ?, ?, ?, ?)
	""", [device_id, now, now, safe_name, safe_skin])
	var account_id: int = db.last_insert_rowid
	if ok:
		ok = db.query_with_bindings("INSERT INTO economy (account_id) VALUES (?)", [account_id])
	if ok:
		ok = db.query_with_bindings("INSERT INTO stats_lifetime (account_id) VALUES (?)", [account_id])
	if not ok:
		rollback()
		push_error("[Database] get_or_create_account: bootstrap INSERTs failed; rolled back")
		return {}
	commit()
	db.query_with_bindings("SELECT * FROM accounts WHERE id = ?", [account_id])
	return db.query_result[0] if not db.query_result.is_empty() else {}


## Auth-token bootstrap / verification. Replaces the old "device_id alone is
## proof of identity" model — knowing device_id is no longer enough to
## inherit an account.
##
## Returns a Dictionary with `account_id`, `account` (full row), and
## `issued_token` (non-empty when the server just generated a token and the
## client must persist it). On token mismatch returns {} — caller should
## refuse the bind.
##
## Flow:
##   - device_id empty / unknown → create new anon account + new token. Returns
##     {account_id, account, issued_token}.
##   - device_id known + account has no token yet (legacy account from
##     pre-token build) → adopt the supplied token if any; otherwise issue a
##     fresh one. Returns {account_id, account, issued_token} (caller saves it).
##   - device_id known + account has a stored hash + supplied token hashes
##     to the stored value → bind, no new token. Returns {account_id, account,
##     issued_token=""}.
##   - device_id known + supplied token mismatch → return {} (refuse bind).
##     The caller can fall back to "create new anon" or just reject.
func bind_account(device_id: String, supplied_token: String, default_name: String = "Player", default_skin: int = 0) -> Dictionary:
	if not _ready_for_queries:
		return {}
	var now: int = _now_ms()
	# Empty device_id → always fresh anon. Caller (profile_service) only
	# does this when client has no prior session.
	if device_id.is_empty():
		var new_token: String = _generate_token()
		var acct: Dictionary = _create_anon_account("", default_name, default_skin, _hash_token(new_token))
		if acct.is_empty():
			return {}
		return {"account_id": int(acct.id), "account": acct, "issued_token": new_token}
	# Lookup
	db.query_with_bindings("SELECT * FROM accounts WHERE device_id = ?", [device_id])
	if db.query_result.is_empty():
		# Unknown device_id → create new anon and issue token
		var new_token2: String = _generate_token()
		var acct2: Dictionary = _create_anon_account(device_id, default_name, default_skin, _hash_token(new_token2))
		if acct2.is_empty():
			return {}
		return {"account_id": int(acct2.id), "account": acct2, "issued_token": new_token2}
	var row: Dictionary = db.query_result[0]
	var stored_hash: String = _s(row.get("auth_token_hash"), "")
	# Always touch last_seen so the row reflects the visit even on auth fail.
	db.query_with_bindings("UPDATE accounts SET last_seen_ms = ? WHERE id = ?", [now, row.id])
	row["last_seen_ms"] = now
	if stored_hash.is_empty():
		# Legacy account (pre-token) — first contact in the new model.
		# Adopt supplied token if non-empty; otherwise issue fresh. Either
		# way, write the hash and return it to client so future contacts
		# can verify. Locks the account to whoever shows up first AFTER
		# this PR ships — acceptable trade-off documented in CLAUDE.md.
		var token_to_use: String = supplied_token if not supplied_token.is_empty() else _generate_token()
		db.query_with_bindings("UPDATE accounts SET auth_token_hash = ? WHERE id = ?",
			[_hash_token(token_to_use), row.id])
		row["auth_token_hash"] = _hash_token(token_to_use)
		# If client supplied the token we adopted, no need to re-issue.
		var to_return: String = "" if not supplied_token.is_empty() else token_to_use
		return {"account_id": int(row.id), "account": row, "issued_token": to_return}
	# Account has a stored hash — supplied token MUST verify.
	if supplied_token.is_empty():
		return {}   # caller treats as auth failure
	if _hash_token(supplied_token) != stored_hash:
		return {}
	return {"account_id": int(row.id), "account": row, "issued_token": ""}


## Helper for bind_account — wraps the anon-create path in a transaction
## (just like get_or_create_account's create branch). `token_hash` may be
## "" if the caller hasn't set up tokens yet.
func _create_anon_account(device_id: String, default_name: String, default_skin: int, token_hash: String) -> Dictionary:
	var now: int = _now_ms()
	var safe_name: String = (default_name if not default_name.strip_edges().is_empty() else "Player").substr(0, 24)
	var safe_skin: int = clampi(default_skin, 0, 17)
	if not begin_transaction():
		return {}
	var ok: bool = db.query_with_bindings("""
		INSERT INTO accounts (device_id, created_ms, last_seen_ms, player_name, skin_index, auth_token_hash)
		VALUES (?, ?, ?, ?, ?, ?)
	""", [device_id if not device_id.is_empty() else null, now, now, safe_name, safe_skin,
		token_hash if not token_hash.is_empty() else null])
	var account_id: int = db.last_insert_rowid
	if ok:
		ok = db.query_with_bindings("INSERT INTO economy (account_id) VALUES (?)", [account_id])
	if ok:
		ok = db.query_with_bindings("INSERT INTO stats_lifetime (account_id) VALUES (?)", [account_id])
	if not ok:
		rollback()
		push_error("[Database] _create_anon_account: INSERTs failed")
		return {}
	commit()
	db.query_with_bindings("SELECT * FROM accounts WHERE id = ?", [account_id])
	return db.query_result[0] if not db.query_result.is_empty() else {}


# Token = 24 random bytes → base64 → ~32 char string. The DB stores SHA-256
# of this so a DB-only leak doesn't immediately compromise live sessions
# (attacker still needs to brute-force 192 bits, infeasible).
func _generate_token() -> String:
	return Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(24))


func _hash_token(token: String) -> String:
	var h: HashingContext = HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(token.to_utf8_buffer())
	return Marshalls.raw_to_base64(h.finish())


## Returns the "is this account already claimed (has handle+pass)" check.
## Used by _on_register_account to refuse second-claim of an existing
## anonymous account that someone else previously bound to.
func account_is_registered(account_id: int) -> bool:
	if not _ready_for_queries:
		return false
	db.query_with_bindings("SELECT handle, pass_hash FROM accounts WHERE id = ?", [account_id])
	if db.query_result.is_empty():
		return false
	var row: Dictionary = db.query_result[0]
	# Either handle or pass_hash being set means someone claimed it.
	return not _s(row.get("handle"), "").is_empty() or not _s(row.get("pass_hash"), "").is_empty()


# Null-safe string conversion. Local helper so account_is_registered /
# bind_account don't depend on profile_service's _s. Mirrors that function.
static func _s(v, default: String = "") -> String:
	if v == null:
		return default
	return str(v)


# P2-18: name / handle content validation. Kid-friendly game with a public
# leaderboard, so reject control chars, zero-width tricks, weird symbol
# spam, and an English profanity blocklist. CJK / accented letters are
# allowed (bilingual EN/CN player base) via the \p{L} unicode class.
const _PROFANITY := [
	"fuck", "shit", "bitch", "cunt", "nigger", "nigga", "faggot", "rape",
	"pussy", "asshole", "whore", "slut", "dick", "cock", "penis", "vagina",
	"retard", "kys", "nazi", "hitler",
]
var _name_regex: RegEx = null


## Returns true if `name` passes charset + profanity checks. Shared by
## update_account_name (player_name) and the register handle path.
func name_is_clean(name: String) -> bool:
	var trimmed: String = name.strip_edges()
	if trimmed.is_empty() or trimmed.length() > 24:
		return false
	if _name_regex == null:
		_name_regex = RegEx.new()
		# Letters (any script), numbers, space, and a small punctuation set.
		_name_regex.compile("^[\\p{L}\\p{N} _.\\-!]{1,24}$")
	if _name_regex.search(trimmed) == null:
		return false
	# Profanity substring match on a leet-normalized lowercase form so
	# "sh1t" / "f u c k" don't trivially slip through.
	var norm: String = trimmed.to_lower()
	norm = norm.replace("0", "o").replace("1", "i").replace("3", "e") \
		.replace("4", "a").replace("5", "s").replace("@", "a").replace("$", "s")
	var collapsed: String = norm.replace(" ", "").replace("_", "").replace(".", "").replace("-", "")
	for bad in _PROFANITY:
		if bad in norm or bad in collapsed:
			return false
	return true


func update_account_name(account_id: int, name: String) -> bool:
	if not _ready_for_queries:
		return false
	if not name_is_clean(name):
		return false
	var clean: String = name.strip_edges().substr(0, 24)
	return db.query_with_bindings("UPDATE accounts SET player_name = ? WHERE id = ?", [clean, account_id])


func update_account_skin(account_id: int, skin: int) -> bool:
	if not _ready_for_queries:
		return false
	return db.query_with_bindings("UPDATE accounts SET skin_index = ? WHERE id = ?", [clampi(skin, 0, 17), account_id])


# ── Economy DAO ──────────────────────────────────────────────────────────

func get_economy(account_id: int) -> Dictionary:
	if not _ready_for_queries:
		return {}
	db.query_with_bindings("SELECT * FROM economy WHERE account_id = ?", [account_id])
	return db.query_result[0] if not db.query_result.is_empty() else {}


## Atomic: spend `cost` credits if balance >= cost, return true. Else
## false and balance unchanged.
func spend_credits(account_id: int, cost: int) -> bool:
	if not _ready_for_queries:
		return false
	db.query_with_bindings("""
		UPDATE economy SET credits = credits - ?
		WHERE account_id = ? AND credits >= ?
	""", [cost, account_id, cost])
	# SQLite reports rows affected via changes()
	db.query("SELECT changes()")
	var changed: int = 0
	if not db.query_result.is_empty():
		changed = int(db.query_result[0].get("changes()", 0))
	return changed > 0


func award_credits(account_id: int, amount: int) -> bool:
	if not _ready_for_queries:
		return false
	return db.query_with_bindings("UPDATE economy SET credits = credits + ? WHERE account_id = ?", [amount, account_id])


func award_fragments(account_id: int, amount: int) -> bool:
	if not _ready_for_queries:
		return false
	return db.query_with_bindings("UPDATE economy SET fragments = fragments + ? WHERE account_id = ?", [amount, account_id])


func spend_fragments(account_id: int, cost: int) -> bool:
	if not _ready_for_queries:
		return false
	db.query_with_bindings("""
		UPDATE economy SET fragments = fragments - ?
		WHERE account_id = ? AND fragments >= ?
	""", [cost, account_id, cost])
	db.query("SELECT changes()")
	return not db.query_result.is_empty() and int(db.query_result[0].get("changes()", 0)) > 0


# ── Weapons DAO ──────────────────────────────────────────────────────────

func list_owned_weapons(account_id: int) -> Array:
	if not _ready_for_queries:
		return []
	db.query_with_bindings("SELECT weapon_id FROM weapons_owned WHERE account_id = ?", [account_id])
	var out: Array = []
	for row in db.query_result:
		out.append(String(row.weapon_id))
	return out


func grant_weapon(account_id: int, weapon_id: String) -> bool:
	if not _ready_for_queries:
		return false
	return db.query_with_bindings("INSERT OR IGNORE INTO weapons_owned (account_id, weapon_id) VALUES (?, ?)", [account_id, weapon_id])


# ── Unlock code redemption (server-only) ─────────────────────────────────
# Redeemed codes are tracked in a stand-alone table keyed by (account_id,
# code). UNIQUE constraint enforces "redeem once per account". Created
# lazily on first query so deployments without the table get migrated
# transparently — saves us writing a separate migration script.
func _ensure_redeemed_codes_table() -> void:
	if not _ready_for_queries:
		return
	db.query("""
		CREATE TABLE IF NOT EXISTS redeemed_codes (
			account_id INTEGER NOT NULL,
			code TEXT NOT NULL,
			redeemed_at INTEGER NOT NULL,
			PRIMARY KEY (account_id, code),
			FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
		)
	""")


func is_code_redeemed(account_id: int, code: String) -> bool:
	if not _ready_for_queries:
		return false
	_ensure_redeemed_codes_table()
	db.query_with_bindings("SELECT 1 FROM redeemed_codes WHERE account_id = ? AND code = ?", [account_id, code])
	return not db.query_result.is_empty()


func mark_code_redeemed(account_id: int, code: String) -> bool:
	if not _ready_for_queries:
		return false
	_ensure_redeemed_codes_table()
	var now_ms: int = int(Time.get_unix_time_from_system() * 1000.0)
	return db.query_with_bindings(
		"INSERT OR IGNORE INTO redeemed_codes (account_id, code, redeemed_at) VALUES (?, ?, ?)",
		[account_id, code, now_ms])


func get_upgrades(account_id: int, weapon_id: String) -> Dictionary:
	if not _ready_for_queries:
		return {}
	db.query_with_bindings("SELECT stat, level FROM weapon_upgrades WHERE account_id = ? AND weapon_id = ?", [account_id, weapon_id])
	var out: Dictionary = {}
	for row in db.query_result:
		out[String(row.stat)] = int(row.level)
	return out


func set_upgrade_level(account_id: int, weapon_id: String, stat: String, level: int) -> bool:
	if not _ready_for_queries:
		return false
	var l: int = clampi(level, 0, 10)
	return db.query_with_bindings("""
		INSERT INTO weapon_upgrades (account_id, weapon_id, stat, level) VALUES (?, ?, ?, ?)
		ON CONFLICT (account_id, weapon_id, stat) DO UPDATE SET level = excluded.level
	""", [account_id, weapon_id, stat, l])


# ── Stats / leaderboard DAO ───────────────────────────────────────────────

func record_kill(killer_account_id: int, victim_account_id: int) -> void:
	if not _ready_for_queries:
		return
	if killer_account_id > 0 and killer_account_id != victim_account_id:
		db.query_with_bindings("UPDATE stats_lifetime SET kills = kills + 1 WHERE account_id = ?", [killer_account_id])
	if victim_account_id > 0:
		db.query_with_bindings("UPDATE stats_lifetime SET deaths = deaths + 1 WHERE account_id = ?", [victim_account_id])


func record_match_result(winner_account_id: int, participant_ids: Array) -> void:
	if not _ready_for_queries:
		return
	for pid in participant_ids:
		if int(pid) == winner_account_id and winner_account_id > 0:
			db.query_with_bindings("UPDATE stats_lifetime SET matches_won = matches_won + 1 WHERE account_id = ?", [pid])
		else:
			db.query_with_bindings("UPDATE stats_lifetime SET matches_lost = matches_lost + 1 WHERE account_id = ?", [pid])


## Top-N leaderboard by kills. Returns Array of {player_name, kills, deaths,
## matches_won}. Pre-joined with accounts so client doesn't need a second query.
func get_leaderboard(limit: int = 20) -> Array:
	if not _ready_for_queries:
		return []
	db.query_with_bindings("""
		SELECT a.player_name, a.skin_index, s.kills, s.deaths, s.matches_won
		FROM stats_lifetime s
		JOIN accounts a ON a.id = s.account_id
		ORDER BY s.kills DESC, s.deaths ASC
		LIMIT ?
	""", [clampi(limit, 1, 100)])
	return db.query_result.duplicate()


## Save a finished match to history table for replay / observation. Phase 2
## work; for now we just write the summary so future replays have an anchor.
func append_match_history(room_id: String, mode_id: String, map_id: String,
		started_ms: int, ended_ms: int, winner_id: int, final_scores: Dictionary) -> void:
	if not _ready_for_queries:
		return
	db.query_with_bindings("""
		INSERT INTO match_history (room_id, mode_id, map_id, started_ms, ended_ms, winner_id, final_scores)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	""", [room_id, mode_id, map_id, started_ms, ended_ms, winner_id, JSON.stringify(final_scores)])


# ── Migrations ─────────────────────────────────────────────────────────

func _read_schema_version() -> int:
	db.query("PRAGMA user_version")
	if db.query_result.is_empty():
		return 0
	return int(db.query_result[0].get("user_version", 0))


func _migrate() -> void:
	# Apply every migration with key > current stored version, in ascending
	# order, inside a single transaction per step. Bumps user_version after
	# each step succeeds. Anything fails → ROLLBACK and leave the DB
	# untouched, so a bad migration doesn't half-apply.
	var stored: int = _read_schema_version()
	if stored == _CURRENT_SCHEMA_VERSION:
		return
	if stored > _CURRENT_SCHEMA_VERSION:
		# DB came from a newer build (downgrade); refuse rather than risk
		# data loss from unknown columns.
		push_error("[Database] DB schema v%d > app's v%d — refusing to run" % [stored, _CURRENT_SCHEMA_VERSION])
		return
	var versions: Array = _MIGRATIONS.keys()
	versions.sort()
	for v in versions:
		if int(v) <= stored:
			continue
		var sql: String = String(_MIGRATIONS[v])
		print("[Database] migrating to schema v%d" % int(v))
		db.query("BEGIN IMMEDIATE")
		var ok: bool = true
		if not sql.is_empty():
			ok = db.query(sql)
		# user_version takes a literal; can't use bindings.
		if ok:
			ok = db.query("PRAGMA user_version = %d" % int(v))
		if not ok:
			db.query("ROLLBACK")
			push_error("[Database] migration to v%d failed; rolled back" % int(v))
			return
		db.query("COMMIT")


# ── Transactions ───────────────────────────────────────────────────────
# Public helpers for multi-statement DAO sequences (e.g. account bootstrap,
# chest open). Always paired BEGIN / (COMMIT | ROLLBACK). Nested calls are
# NOT supported — SQLite doesn't allow nested transactions without
# SAVEPOINT, which we don't need yet. Callers must not double-begin.

func begin_transaction() -> bool:
	if not _ready_for_queries:
		return false
	return db.query("BEGIN IMMEDIATE")


func commit() -> bool:
	if not _ready_for_queries:
		return false
	return db.query("COMMIT")


func rollback() -> bool:
	if not _ready_for_queries:
		return false
	return db.query("ROLLBACK")


# ── Utility ─────────────────────────────────────────────────────────────

func _now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


## P2-19: PBKDF2-HMAC-SHA256 password hashing. Replaces the old single-round
## salted SHA-256 (too fast → cheap offline brute-force after a DB leak).
##
## Stored formats:
##   new:  "pbkdf2$<iterations>$<salt_b64>$<hash_b64>"   (4 $-parts)
##   old:  "<salt_b64>$<hash_b64>"                        (2 $-parts, legacy)
##
## verify_password handles both; legacy hashes are transparently rehashed to
## PBKDF2 on the next successful login (see ProfileService._on_login →
## rehash_password_if_legacy). bcrypt/argon2 would be stronger still but
## aren't available without a gdextension — PBKDF2 at 120k iterations is a
## big step up and uses only built-in Crypto.
const _PBKDF2_ITERATIONS := 120_000

func hash_password(password: String) -> String:
	var salt: PackedByteArray = Crypto.new().generate_random_bytes(16)
	var digest: PackedByteArray = _pbkdf2_sha256(password.to_utf8_buffer(), salt, _PBKDF2_ITERATIONS)
	return "pbkdf2$%d$%s$%s" % [_PBKDF2_ITERATIONS, Marshalls.raw_to_base64(salt), Marshalls.raw_to_base64(digest)]


func verify_password(password: String, stored: String) -> bool:
	var parts: PackedStringArray = stored.split("$", false)
	if parts.size() == 4 and parts[0] == "pbkdf2":
		# New format.
		var iterations: int = int(parts[1])
		var salt: PackedByteArray = Marshalls.base64_to_raw(parts[2])
		var expected: PackedByteArray = Marshalls.base64_to_raw(parts[3])
		var got: PackedByteArray = _pbkdf2_sha256(password.to_utf8_buffer(), salt, iterations)
		return _constant_time_eq(got, expected)
	if parts.size() == 2:
		# Legacy single-round salted SHA-256.
		var lsalt: PackedByteArray = Marshalls.base64_to_raw(parts[0])
		var lexpected: PackedByteArray = Marshalls.base64_to_raw(parts[1])
		var h: HashingContext = HashingContext.new()
		h.start(HashingContext.HASH_SHA256)
		h.update(lsalt)
		h.update(password.to_utf8_buffer())
		return _constant_time_eq(h.finish(), lexpected)
	return false


## Returns true if a stored hash is in the legacy format (caller should
## rehash after a successful verify).
func is_legacy_hash(stored: String) -> bool:
	return stored.split("$", false).size() == 2


## Rewrite an account's password hash to the current format. Called after a
## successful login that verified against a legacy hash.
func rehash_password(account_id: int, new_hash: String) -> bool:
	if not _ready_for_queries:
		return false
	return db.query_with_bindings("UPDATE accounts SET pass_hash = ? WHERE id = ?", [new_hash, account_id])


# PBKDF2-HMAC-SHA256, single 32-byte output block (dkLen = hLen = 32, so
# only block index 1 is needed). T = U1 ^ U2 ^ ... ^ U_iterations, where
# U1 = HMAC(pw, salt || 0x00000001) and U_i = HMAC(pw, U_{i-1}).
func _pbkdf2_sha256(password: PackedByteArray, salt: PackedByteArray, iterations: int) -> PackedByteArray:
	var crypto := Crypto.new()
	var block_index := PackedByteArray([0, 0, 0, 1])   # INT_32_BE(1)
	var salted: PackedByteArray = salt.duplicate()
	salted.append_array(block_index)
	var u: PackedByteArray = crypto.hmac_digest(HashingContext.HASH_SHA256, password, salted)
	var t: PackedByteArray = u.duplicate()
	for _i in range(iterations - 1):
		u = crypto.hmac_digest(HashingContext.HASH_SHA256, password, u)
		for j in t.size():
			t[j] = t[j] ^ u[j]
	return t


# Length-independent compare to avoid leaking match length via timing. Both
# sides are fixed-length digests so this is belt-and-suspenders.
func _constant_time_eq(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff: int = 0
	for i in a.size():
		diff |= a[i] ^ b[i]
	return diff == 0
