extends SubViewport
## One room's isolated 3D world. Owns its own World3D — and therefore
## its own PhysicsDirectSpaceState3D — so once map + players + match
## logic move under it (M3+), physics queries from one room can't reach
## into another's.
##
## Created by GameController._boot_match_for_room when a room flips to
## MATCH state; freed by _tear_down_match_world (or when the parent
## RoomWorld is freed for any reason — host-leave, match end, scene
## teardown).
##
## M1 scope (current): just the container + lifecycle. Map, players, and
## MatchController continue to live on GameController as before. M2 will
## host per-room MatchAuthority here; M3 will reparent map + players.
##
## On the dedicated server (--headless) this SubViewport allocates no
## render target (UPDATE_DISABLED). The World3D + physics space are still
## fully functional — that's what we actually need.

const FALLBACK_MAP := "res://shared/scenes/maps/blank.tscn"

var room_id: String = ""
# Filled in by future milestones — kept as fields here so callers can
# probe RoomWorld without knowing which milestone landed last.
var map_root: Node3D = null
var players_root: Node3D = null
var match_controller: Node = null


func _init() -> void:
	# The whole point of this class — without own_world_3d=true, this
	# viewport shares the default world's physics space and the isolation
	# we're refactoring toward is meaningless.
	own_world_3d = true
	# Headless DS never renders. Even on listen-host we don't render this
	# viewport directly (the top-level Window renders the active room via
	# a SubViewportContainer in a later milestone). Disable update so the
	# DS doesn't burn cycles allocating render targets it never draws.
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	# size must be > 0 even when UPDATE_DISABLED — 0×0 trips an engine
	# warning on some platforms. 1×1 is the smallest legal value.
	size = Vector2i(1, 1)


func _ready() -> void:
	# Pre-allocate the players container — empty until M3 starts reparenting
	# room players into here. Named "Players" to mirror GameController.players_root.
	players_root = Node3D.new()
	players_root.name = "Players"
	add_child(players_root)


## Load the room's map as a child of this viewport. Replaces any existing
## map. Returns the new map root (or null on hard failure where even the
## fallback blank map couldn't load — should never happen in practice).
##
## Not called by M1 callers — present so M3 can wire it up without
## reshaping the class.
func load_map(map_path: String) -> Node3D:
	# Guard with ResourceLoader.exists first so a bad path doesn't dump
	# a scary "Cannot open file" stack trace into the server log. Bad
	# paths fall through to the blank fallback silently.
	var scene: PackedScene = null
	if ResourceLoader.exists(map_path):
		scene = load(map_path) as PackedScene
	if scene == null:
		scene = load(FALLBACK_MAP) as PackedScene
	if scene == null:
		return null
	if map_root != null:
		map_root.queue_free()
	map_root = scene.instantiate() as Node3D
	if map_root == null:
		return null
	add_child(map_root)
	return map_root
