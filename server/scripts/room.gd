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


## Serialize to a plain Dictionary for RPC payload + browser display.
## Caller decides which fields to include in the wire format.
func to_dict() -> Dictionary:
	return {
		"id":     room_id,
		"host":   host_peer,
		"map":    map_path,
		"mode":   mode_def_path,
		"players":players.duplicate(),
		"state":  state,
		"max":    max_players,
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
	return true


func remove_player(peer_id: int) -> bool:
	var idx: int = players.find(peer_id)
	if idx < 0:
		return false
	players.remove_at(idx)
	return true


func is_full() -> bool:
	return players.size() >= max_players


func is_empty() -> bool:
	return players.is_empty()
