@tool
class_name ModeDef extends Resource

# One ModeDef per game mode. Server reads team sizes and rule script.
# Mirrors MODE_TEAM_SIZES + arcade map in /Users/longmao/projects/pvp-game/server.js (line 541).

const FAMILY_ELIM   := &"elim"     # best-of-3 rounds, HP-sum wins
const FAMILY_RACE   := &"race"     # first to kill goal
const FAMILY_FFA    := &"ffa"      # last standing
const FAMILY_KOTH   := &"koth"     # hold the hill
const FAMILY_BR     := &"br"       # battle royale w/ shrinking zone
const FAMILY_DDAY   := &"dday"     # defend bunker waves
const FAMILY_FRONT  := &"frontlines"
const FAMILY_LSTAND := &"laststand"
const FAMILY_ARCADE := &"arcade"   # gungame/oitc/jugg/infect/sniper_only/speedrun

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""   # shown to user in menus
@export var family: StringName = FAMILY_ELIM
@export var humans_per_team: int = 1     # 1 = 1v1; 0 = solo FFA
@export var team_count: int = 2
@export var default_bots_per_side: int = 0

@export_group("Match rules")
@export var rounds_to_win: int = 2       # best-of-3 → 2
@export var round_seconds: int = 60
@export var kill_goal: int = 0           # 0 = not race-style
@export var lives_per_player: int = -1   # -1 = infinite respawn

@export_group("Reward shaping")
@export var credits_per_kill: int = 5
@export var credits_per_win: int = 50
@export var credits_per_loss: int = 20
@export var credit_cap_per_match: int = 250

@export_group("Map binding")
@export var fixed_map: PackedScene       # null = any map allowed
@export var allowed_maps: Array[PackedScene] = []

@export_group("Custom rule script")
@export var rule_script: Script          # optional server-side override (e.g. KOTH hill ticking)
