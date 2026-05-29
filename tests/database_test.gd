extends SceneTree
## Unit test for the Database autoload + ProfileService end-to-end.
## Boots the Database autoload manually with GODOT_PVP_FORCE_DB=1 simulated
## by directly calling _ready logic, then exercises the DAO surface.
##
## Run: bash tests/run_database_test.sh

const Database = preload("res://server/scripts/database.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Clean prior test DB so each run starts fresh.
	var test_db_path: String = "user://test_db.db"
	if FileAccess.file_exists(test_db_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_db_path))

	if not ClassDB.class_exists("SQLite"):
		print("  FAIL — godot-sqlite gdextension not registered. Open Godot editor once to register, then re-run.")
		quit(1)
		return

	# Instantiate Database directly (don't depend on autoload here — autoload
	# behavior is exercised by the boot test).
	var db = Database.new()
	root.add_child(db)
	# Override path to test sandbox
	db.db = ClassDB.instantiate("SQLite")
	db.db.path = test_db_path
	db.db.foreign_keys = true
	db.db.open_db()
	db.db.query("PRAGMA journal_mode=WAL")
	db._create_tables()
	db._ready_for_queries = true
	# P1-9: run the migration framework so auth_token_hash (v2) lands on the
	# test DB. Without this, bind_account's INSERT fails on a missing column.
	db._migrate()

	# --- 1. Account creation: new device_id → row created with defaults
	var alice: Dictionary = db.get_or_create_account("device-alice", "Alice", 5)
	if alice.is_empty():
		failures.append("get_or_create_account returned empty for new device")
	elif int(alice.get("id", 0)) <= 0:
		failures.append("created account has no id")
	if String(alice.get("player_name", "")) != "Alice":
		failures.append("default name not applied: %s" % alice.get("player_name"))
	if int(alice.get("skin_index", -1)) != 5:
		failures.append("default skin not applied: %s" % alice.get("skin_index"))

	# --- 2. Idempotent: same device_id → same row (no new account)
	var alice_again: Dictionary = db.get_or_create_account("device-alice", "Alice2", 9)
	if int(alice_again.get("id", -1)) != int(alice.id):
		failures.append("re-lookup created NEW account instead of returning existing")
	if String(alice_again.get("player_name", "")) != "Alice":
		failures.append("re-lookup overwrote existing player_name with default")

	# --- 3. Economy starter values
	var econ: Dictionary = db.get_economy(int(alice.id))
	if int(econ.get("credits", 0)) != 500:
		failures.append("starter credits != 500: got %d" % int(econ.get("credits", 0)))
	if int(econ.get("fragments", 0)) != 0:
		failures.append("starter fragments != 0")

	# --- 4. Spend credits: success when affordable, fail when not
	if not db.spend_credits(int(alice.id), 300):
		failures.append("spend_credits 300 of 500 should succeed")
	if db.spend_credits(int(alice.id), 9999):
		failures.append("spend_credits 9999 should fail (only 200 left)")
	econ = db.get_economy(int(alice.id))
	if int(econ.credits) != 200:
		failures.append("credits should be 200 after spending 300: got %d" % int(econ.credits))

	# --- 5. Award fragments + spend
	db.award_fragments(int(alice.id), 50)
	econ = db.get_economy(int(alice.id))
	if int(econ.fragments) != 50:
		failures.append("fragments should be 50: got %d" % int(econ.fragments))
	if not db.spend_fragments(int(alice.id), 20):
		failures.append("spend_fragments 20 of 50 should succeed")
	if db.spend_fragments(int(alice.id), 100):
		failures.append("spend_fragments 100 of 30 should fail")

	# --- 6. Weapon ownership
	db.grant_weapon(int(alice.id), "ak20")
	db.grant_weapon(int(alice.id), "srx")
	# Duplicate grant should be a no-op (no error, no extra row)
	db.grant_weapon(int(alice.id), "ak20")
	var owned: Array = db.list_owned_weapons(int(alice.id))
	if owned.size() != 2:
		failures.append("owned weapons count != 2 after 3 grants (1 dup): got %d" % owned.size())

	# --- 7. Weapon upgrades
	db.set_upgrade_level(int(alice.id), "ak20", "damage", 3)
	db.set_upgrade_level(int(alice.id), "ak20", "mag", 1)
	db.set_upgrade_level(int(alice.id), "srx", "damage", 7)
	var ak_upgrades: Dictionary = db.get_upgrades(int(alice.id), "ak20")
	if int(ak_upgrades.get("damage", -1)) != 3:
		failures.append("ak20 damage upgrade level wrong: %s" % ak_upgrades)
	if int(ak_upgrades.get("mag", -1)) != 1:
		failures.append("ak20 mag upgrade level wrong: %s" % ak_upgrades)
	# Upsert: set damage to 5
	db.set_upgrade_level(int(alice.id), "ak20", "damage", 5)
	ak_upgrades = db.get_upgrades(int(alice.id), "ak20")
	if int(ak_upgrades.get("damage", -1)) != 5:
		failures.append("upsert damage 3→5 failed: %s" % ak_upgrades)

	# --- 8. Lifetime stats record_kill
	var bob: Dictionary = db.get_or_create_account("device-bob", "Bob", 0)
	db.record_kill(int(alice.id), int(bob.id))
	db.record_kill(int(alice.id), int(bob.id))
	db.record_kill(int(bob.id), int(alice.id))
	# Self-kills don't credit
	db.record_kill(int(alice.id), int(alice.id))
	var lb: Array = db.get_leaderboard(10)
	if lb.size() != 2:
		failures.append("leaderboard should have 2 rows: got %d" % lb.size())
	# Alice has 2 kills, Bob has 1
	var alice_row: Dictionary = {}
	var bob_row: Dictionary = {}
	for row in lb:
		if String(row.player_name) == "Alice":
			alice_row = row
		elif String(row.player_name) == "Bob":
			bob_row = row
	if int(alice_row.get("kills", 0)) != 2:
		failures.append("Alice kills should be 2: %s" % alice_row)
	if int(bob_row.get("kills", 0)) != 1:
		failures.append("Bob kills should be 1: %s" % bob_row)
	# Alice's deaths: 1 (from Bob) + 1 (from suicide) = 2. Real FPS rules
	# count suicides as deaths even though the killer doesn't get a kill.
	if int(alice_row.get("deaths", 0)) != 2:
		failures.append("Alice deaths should be 2 (1 from Bob + 1 suicide): %s" % alice_row)

	# --- 9. Match history
	db.append_match_history("ABCD", "ffa_kill5", "blank", 1000, 2000, int(alice.id),
		{"alice": 5, "bob": 2})
	db.db.query("SELECT COUNT(*) AS c FROM match_history")
	if int(db.db.query_result[0].c) != 1:
		failures.append("match_history insert failed")

	# --- 10. Password hash + verify
	var hash1: String = db.hash_password("hunter2")
	if hash1.is_empty() or not "$" in hash1:
		failures.append("hash_password returned malformed: %s" % hash1)
	if not db.verify_password("hunter2", hash1):
		failures.append("verify_password correct didn't return true")
	if db.verify_password("wrong", hash1):
		failures.append("verify_password incorrect returned true (security hole)")
	# Two hashes of same password should differ (salt)
	var hash2: String = db.hash_password("hunter2")
	if hash1 == hash2:
		failures.append("two hash_password calls returned same value — salt not random")
	# P2-19: new hashes are PBKDF2 format
	if not hash1.begins_with("pbkdf2$"):
		failures.append("hash_password not using PBKDF2 format: %s" % hash1)
	if db.is_legacy_hash(hash1):
		failures.append("PBKDF2 hash misdetected as legacy")
	# P2-19: legacy single-round SHA-256 hashes must still verify (backward compat)
	var legacy_salt: PackedByteArray = Crypto.new().generate_random_bytes(16)
	var lh: HashingContext = HashingContext.new()
	lh.start(HashingContext.HASH_SHA256)
	lh.update(legacy_salt)
	lh.update("hunter2".to_utf8_buffer())
	var legacy_hash: String = "%s$%s" % [Marshalls.raw_to_base64(legacy_salt), Marshalls.raw_to_base64(lh.finish())]
	if not db.is_legacy_hash(legacy_hash):
		failures.append("legacy hash not detected as legacy")
	if not db.verify_password("hunter2", legacy_hash):
		failures.append("legacy hash failed to verify correct password (broke backward compat)")
	if db.verify_password("wrong", legacy_hash):
		failures.append("legacy hash verified WRONG password (security hole)")

	# --- 11. P0-1 bind_account: fresh device → issues token
	var bind1: Dictionary = db.bind_account("device-charlie", "", "Charlie", 3)
	if bind1.is_empty():
		failures.append("bind_account empty for fresh device")
	if String(bind1.get("issued_token", "")).is_empty():
		failures.append("bind_account didn't issue token for fresh device")
	var charlie_token: String = String(bind1.get("issued_token"))
	var charlie_id: int = int(bind1.get("account_id"))
	# Reconnect with correct token → bind succeeds, no new token issued
	var bind2: Dictionary = db.bind_account("device-charlie", charlie_token, "Charlie", 3)
	if int(bind2.get("account_id", -1)) != charlie_id:
		failures.append("bind_account with correct token returned wrong account")
	if not String(bind2.get("issued_token", "")).is_empty():
		failures.append("bind_account re-issued token to already-valid client")
	# Attacker with wrong token → empty (refuse bind)
	var bind3: Dictionary = db.bind_account("device-charlie", "wrong-token-here", "Evil", 0)
	if not bind3.is_empty():
		failures.append("bind_account accepted WRONG token — account hijack possible")
	# Attacker with no token (legacy-flow exploit) → empty (refuse bind)
	var bind4: Dictionary = db.bind_account("device-charlie", "", "Evil", 0)
	if not bind4.is_empty():
		failures.append("bind_account accepted EMPTY token on account that already has one — hijack possible")
	# --- 12. account_is_registered
	if db.account_is_registered(charlie_id):
		failures.append("anon account flagged as registered")
	db.db.query_with_bindings("UPDATE accounts SET handle = ?, pass_hash = ? WHERE id = ?",
		["charliehandle", db.hash_password("pw"), charlie_id])
	if not db.account_is_registered(charlie_id):
		failures.append("registered account flagged as anonymous")

	# --- 13. P2-18 name_is_clean: charset + profanity
	for good in ["Alice", "玩家小明", "Pro_Gamer-1", "Cool.Kid!", "日本語 name"]:
		if not db.name_is_clean(good):
			failures.append("name_is_clean rejected valid name: %s" % good)
	for bad in ["", "   ", "fuck", "sh1t", "f u c k", "a$$hole", "<script>", "name​with​zwsp", "way_too_long_name_exceeding_24_chars"]:
		if db.name_is_clean(bad):
			failures.append("name_is_clean accepted invalid/blocked name: %s" % bad)

	# --- Done
	db.db.close_db()

	if failures.is_empty():
		print("  PASS — 13/13 Database DAO assertions (accounts, economy, weapons, upgrades, stats, leaderboard, match history, password hash, bind_account, account_is_registered, name_is_clean)")
		quit(0)
	else:
		for f in failures:
			print("  FAIL: %s" % f)
		quit(1)
