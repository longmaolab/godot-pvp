extends RefCounted
## A single Room — the unit of isolation between concurrent matches on
## one DS process. Holds map/mode/players state. Lives in RoomManager's
## dict, keyed by `room_id`.
##
## State machine:
##   LOBBY  — created, host can configure, waiting for START
##   MATCH  — match in progress; gameplay RPCs scoped to this room only
##   ENDED  — match over, returning to LOBBY (transient; rarely seen)
##
## Phase 1 keeps this lean: no chat, no ready state, no in-lobby map
## changes. Host picks map/mode at create time; if they want to change,
## they leave + create a new room. See .agent/lobby_plan.md.

const STATE_LOBBY := 0
const STATE_MATCH := 1
const STATE_ENDED := 2

var room_id: String = ""           # 4-char alphanumeric, e.g. "AXJ7"
var host_peer: int = 0             # peer that created the room
var map_path: String = ""          # full res:// path
var mode_def_path: String = ""     # full res:// path, "" = no mode (FFA practice-ish)
var players: Array[int] = []       # peer_ids in this room (host first)
var state: int = STATE_LOBBY
var created_at_ms: int = 0
var max_players: int = 4           # Phase 1: locked at 4 per .agent/lobby_plan.md
# Phase 2: per-peer lobby identity + ready state. Keyed by peer_id (int).
# Each value is {"name": String, "skin": int, "ready": bool}. Defaults are
# filled on add_player so the dict is never missing an entry for a present
# player — joiners can overwrite via set_profile + set_ready RPCs.
var profiles: Dictionary = {}


## Serialize to a plain Dictionary for RPC payload + browser display.
## Caller decides which fields to include in the wire format.
func to_dict() -> Dictionary:
	# Profiles need a deep-ish copy so the RPC receiver can't mutate our
	# server-side state by mutating the dict it receives. Duplicate the
	# outer dict; the inner small dicts are still shared refs but that's
	# fine because the RPC channel serializes by value anyway.
	var profiles_copy: Dictionary = {}
	for k in profiles.keys():
		profiles_copy[k] = (profiles[k] as Dictionary).duplicate()
	return {
		"id":     room_id,
		"host":   host_peer,
		"map":    map_path,
		"mode":   mode_def_path,
		"players":players.duplicate(),
		"state":  state,
		"max":    max_players,
		"profiles": profiles_copy,
	}


## Browser-list summary — strip per-peer details we don't need for the
## list view (we only want id / map / mode / count / state).
func to_summary() -> Dictionary:
	return {
		"id":      room_id,
		"map":     map_path,
		"mode":    mode_def_path,
		"count":   players.size(),
		"max":     max_players,
		"state":   state,
	}


func has_player(peer_id: int) -> bool:
	return peer_id in players


func add_player(peer_id: int) -> bool:
	if has_player(peer_id):
		return false
	if players.size() >= max_players:
		return false
	players.append(peer_id)
	# Default profile so to_dict() always has a row for every present
	# player — even if they never send set_lobby_profile before the first
	# state broadcast goes out.
	profiles[peer_id] = {"name": "", "skin": 0, "ready": false}
	return true


func remove_player(peer_id: int) -> bool:
	var idx: int = players.find(peer_id)
	if idx < 0:
		return false
	players.remove_at(idx)
	profiles.erase(peer_id)
	return true


## Update name + skin for `peer_id`. Returns true if anything changed
## (caller uses this to skip redundant broadcasts).
func set_profile(peer_id: int, name: String, skin: int) -> bool:
	if not has_player(peer_id):
		return false
	var cur: Dictionary = profiles.get(peer_id, {"name": "", "skin": 0, "ready": false})
	# Clamp the inputs so a malicious peer can't push a 10MB display name.
	var clean_name: String = name.strip_edges().substr(0, 24)
	var clean_skin: int = clampi(skin, 0, 17)   # PlayerController has 18 skins
	if String(cur.get("name", "")) == clean_name and int(cur.get("skin", 0)) == clean_skin:
		return false
	cur["name"] = clean_name
	cur["skin"] = clean_skin
	profiles[peer_id] = cur
	return true


## Toggle a player's ready bit. Returns true if changed.
func set_ready(peer_id: int, ready: bool) -> bool:
	if not has_player(peer_id):
		return false
	var cur: Dictionary = profiles.get(peer_id, {"name": "", "skin": 0, "ready": false})
	if bool(cur.get("ready", false)) == ready:
		return false
	cur["ready"] = ready
	profiles[peer_id] = cur
	return true


## Clear every joiner's ready bit. Called when a match ends so the next
## round forces an explicit re-ready — otherwise stale "ready" sticks
## across rounds and the host can't see who actually wants to play again.
func clear_ready_bits() -> void:
	for k in profiles.keys():
		var p: Dictionary = profiles[k]
		p["ready"] = false
		profiles[k] = p


func is_full() -> bool:
	return players.size() >= max_players


func is_empty() -> bool:
	return players.is_empty()
