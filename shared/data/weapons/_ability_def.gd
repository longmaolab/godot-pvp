@tool
class_name AbilityDef extends Resource

# Ability types mirror /Users/longmao/projects/pvp-game/public/game.js WEAPONS[].ability.type.
# Each weapon's special skill triggered by E or RMB depending on context.
const TYPE_NONE        := &"none"
const TYPE_BUFF        := &"buff"         # focus_fire, armor_pierce, overclock
const TYPE_POWERSHOT   := &"powershot"    # next bullet stronger/faster
const TYPE_BULLETWAVE  := &"bulletwave"   # grid of bullets
const TYPE_FAN_FIRE    := &"fanfire_all"  # rapidly dump magazine
const TYPE_THROWBOMB   := &"throwbomb"    # lobbed projectile
const TYPE_AOE         := &"aoe"          # flame burst, propane
const TYPE_BLINK       := &"blink"        # teleport forward
const TYPE_FREEZE      := &"freeze"       # stun target
const TYPE_HEAL        := &"heal"         # stim, medkit
const TYPE_SHIELD      := &"shield"       # parry, deflector
const TYPE_DRONE       := &"drone"        # deploy hunter drone
const TYPE_CHARGE      := &"charge"       # hold-to-charge (crossbow, railgun overcharge)
const TYPE_MULTISHOT   := &"multishot"    # piercing round, focus burst

@export var name: String = ""
@export var description: String = ""
@export var type: StringName = TYPE_NONE
@export var cooldown_ms: int = 0
@export var duration_ms: int = 0

# Generic numeric tuning (interpretation depends on type).
@export var damage_mult: float = 1.0
@export var spread_mult: float = 1.0
@export var speed_mult: float = 1.0
@export var pellets: int = 0           # 0 = use weapon default
@export var grid_w: int = 0            # bulletwave grid width
@export var grid_h: int = 0
@export var delay_ms: int = 0          # fanfire inter-shot delay
@export var radius: float = 0.0        # aoe / shield radius

# Some abilities suppress ADS (shotgun spam, fan fire).
@export var disables_ads: bool = false
