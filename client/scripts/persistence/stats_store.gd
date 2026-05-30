extends Node
## Autoload — persistent player stats (kills / deaths / wins / games).
## Ported from arena-shooter-3d/scripts/stats_store.gd with minor naming
## tweaks to fit godot-pvp's namespace.
##
## On the dedicated server: writes the canonical user://stats.json.
## On clients: holds an in-memory cache the server pushes via RPC, persisted
## locally so the menu has a leaderboard before the next connect.

signal leaderboard_updated(rows: Array)

const STATS_FILE := "user://stats.json"
const CLIENT_CACHE_FILE := "user://lb_cache.json"
const LEADERBOARD_TOP_N := 10
# Reach NetProtocol via preload (the script class) not the autoload global so
# is_dedicated_server_boot() resolves under smoke test --script loading.
const NetProtocol = preload("res://shared/scripts/network/net_protocol.gd")

var stats: Dictionary = {}
var cached_leaderboard: Array = []


func _ready() -> void:
	# C7: split server vs client persistence on boot. The DS owns
	# user://stats.json; clients keep an in-memory leaderboard cache backed
	# by user://lb_cache.json. Loading both on both sides was harmless
	# functionally but mixed two distinct namespaces in the same process —
	# making it easy for a future feature to write the wrong file from the
	# wrong role.
	if NetProtocol.is_dedicated_server_boot():
		_load_server_stats()
	else:
		_load_client_cache()


# ── Server side ─────────────────────────────────────────────────────────
func _load_server_stats() -> void:
	if not FileAccess.file_exists(STATS_FILE):
		return
	var f := FileAccess.open(STATS_FILE, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		stats = parsed


func _save_server_stats() -> void:
	var f := FileAccess.open(STATS_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(stats, "  "))


func _ensure_player(player_name: String) -> void:
	if not stats.has(player_name):
		stats[player_name] = {"kills": 0, "deaths": 0, "wins": 0, "games": 0}


func record_kill(attacker_name: String, victim_name: String) -> void:
	if attacker_name != victim_name and attacker_name != "":
		_ensure_player(attacker_name)
		stats[attacker_name]["kills"] = int(stats[attacker_name].get("kills", 0)) + 1
	if victim_name != "":
		_ensure_player(victim_name)
		stats[victim_name]["deaths"] = int(stats[victim_name].get("deaths", 0)) + 1


func record_match_end(winner_name: String, participant_names: Array) -> void:
	if winner_name != "":
		_ensure_player(winner_name)
		stats[winner_name]["wins"] = int(stats[winner_name].get("wins", 0)) + 1
	for n in participant_names:
		_ensure_player(n)
		stats[n]["games"] = int(stats[n].get("games", 0)) + 1
	_save_server_stats()


func get_top(n: int = LEADERBOARD_TOP_N) -> Array:
	var rows: Array = []
	for player_name in stats.keys():
		var s: Dictionary = stats[player_name]
		rows.append({
			"name": player_name,
			"kills": int(s.get("kills", 0)),
			"deaths": int(s.get("deaths", 0)),
			"wins": int(s.get("wins", 0)),
			"games": int(s.get("games", 0)),
		})
	rows.sort_custom(func(a, b):
		if a["wins"] != b["wins"]:
			return a["wins"] > b["wins"]
		return a["kills"] > b["kills"])
	return rows.slice(0, n)


# ── Client side ─────────────────────────────────────────────────────────
func update_cached_leaderboard(rows: Array) -> void:
	cached_leaderboard = rows
	_save_client_cache()
	leaderboard_updated.emit(rows)


func _save_client_cache() -> void:
	var f := FileAccess.open(CLIENT_CACHE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(cached_leaderboard))


func _load_client_cache() -> void:
	if not FileAccess.file_exists(CLIENT_CACHE_FILE):
		return
	var f := FileAccess.open(CLIENT_CACHE_FILE, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_ARRAY:
		cached_leaderboard = parsed
