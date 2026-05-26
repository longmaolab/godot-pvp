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
	_ready_for_queries = true
	print("[Database] ready at %s (WAL mode, foreign_keys=ON)" % db.path)


## True for dedicated server boot. Uses NetProtocol's helper (which
## checks `--server` in cmdline_USER_args; engine args are passed before
## the `--` separator, --server lives after it). Don't roll our own —
## get_cmdline_args() returns only engine args, get_cmdline_user_args()
## returns post-`--` args. NetProtocol.is_dedicated_server_boot wraps
## the right one.
func _should_open_db() -> bool:
	if OS.has_environment("GODOT_PVP_FORCE_DB"):
		return true
	var np: Node = get_node_or_null(^"/root/NetProtocol")
	if np != null and np.has_method(&"is_dedicated_server_boot"):
		return np.is_dedicated_server_boot()
	return false


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
	# Create
	var safe_name: String = (default_name if not default_name.strip_edges().is_empty() else "Player").substr(0, 24)
	var safe_skin: int = clampi(default_skin, 0, 17)
	db.query_with_bindings("""
		INSERT INTO accounts (device_id, created_ms, last_seen_ms, player_name, skin_index)
		VALUES (?, ?, ?, ?, ?)
	""", [device_id, now, now, safe_name, safe_skin])
	var account_id: int = db.last_insert_rowid
	# Bootstrap economy row
	db.query_with_bindings("INSERT INTO economy (account_id) VALUES (?)", [account_id])
	db.query_with_bindings("INSERT INTO stats_lifetime (account_id) VALUES (?)", [account_id])
	db.query_with_bindings("SELECT * FROM accounts WHERE id = ?", [account_id])
	return db.query_result[0] if not db.query_result.is_empty() else {}


func update_account_name(account_id: int, name: String) -> bool:
	if not _ready_for_queries:
		return false
	var clean: String = name.strip_edges().substr(0, 24)
	if clean.is_empty():
		return false
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


# ── Utility ─────────────────────────────────────────────────────────────

func _now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


## M7: bcrypt password hash + verify. Real account upgrade — uses Godot's
## Crypto to do a salted SHA256 since bcrypt isn't built-in. NOT the
## same security level as bcrypt; flagged for upgrade if/when we add a
## bcrypt gdextension. For Phase 1 anonymous-token flow this is unused.
func hash_password(password: String) -> String:
	var salt: PackedByteArray = Crypto.new().generate_random_bytes(16)
	var h: HashingContext = HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(salt)
	h.update(password.to_utf8_buffer())
	var digest: PackedByteArray = h.finish()
	return "%s$%s" % [Marshalls.raw_to_base64(salt), Marshalls.raw_to_base64(digest)]


func verify_password(password: String, stored: String) -> bool:
	var parts: PackedStringArray = stored.split("$", false)
	if parts.size() != 2:
		return false
	var salt: PackedByteArray = Marshalls.base64_to_raw(parts[0])
	var expected: PackedByteArray = Marshalls.base64_to_raw(parts[1])
	var h: HashingContext = HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(salt)
	h.update(password.to_utf8_buffer())
	var got: PackedByteArray = h.finish()
	return got == expected
