extends Node
## Autoload — persistent player preferences (name, skin, audio volume).
## Backed by user://settings.cfg via ConfigFile. Pattern adapted from
## arena-shooter-3d/scripts/network_manager.gd save/load helpers.

const FILE := "user://settings.cfg"

signal changed()

var player_name: String = ""
var skin_index: int = 0
var master_volume: float = 0.8   # 0..1 linear
var credits: int = 500           # in-game currency, starter grant
var fragments: int = 0           # weapon-unlock currency
var purchased: Array = []        # weapon IDs the player owns (besides free starters)
var common_chests: int = 0       # owned but unopened chests
var rare_chests: int = 0
# weapon_id → {dmg_lvl, mag_lvl, reload_lvl} — 0..3 per stat
var upgrades: Dictionary = {}
var last_free_spin_iso: String = ""   # ISO date string

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
		save_to_disk()


func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(FILE) != OK:
		return
	player_name = cfg.get_value("player", "name", player_name)
	skin_index = cfg.get_value("player", "skin", skin_index)
	master_volume = cfg.get_value("audio", "master", master_volume)
	credits = cfg.get_value("economy", "credits", credits)
	fragments = cfg.get_value("economy", "fragments", fragments)
	purchased = cfg.get_value("economy", "purchased", purchased)
	common_chests = cfg.get_value("economy", "common_chests", common_chests)
	rare_chests = cfg.get_value("economy", "rare_chests", rare_chests)
	upgrades = cfg.get_value("economy", "upgrades", upgrades)
	last_free_spin_iso = cfg.get_value("economy", "last_free_spin", last_free_spin_iso)


func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "skin", skin_index)
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("economy", "credits", credits)
	cfg.set_value("economy", "fragments", fragments)
	cfg.set_value("economy", "purchased", purchased)
	cfg.set_value("economy", "common_chests", common_chests)
	cfg.set_value("economy", "rare_chests", rare_chests)
	cfg.set_value("economy", "upgrades", upgrades)
	cfg.set_value("economy", "last_free_spin", last_free_spin_iso)
	cfg.save(FILE)
	changed.emit()


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


func bump_upgrade(weapon_id: String, stat: StringName) -> bool:
	var rec: Dictionary = upgrades.get(weapon_id, {})
	var cur: int = int(rec.get(stat, 0))
	if cur >= 3:
		return false
	# Per-stat cost ladder mirrors original pvp-game (30 / 60 / 120 fragments).
	var cost: int = [30, 60, 120][cur]
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
