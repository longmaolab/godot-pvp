@tool
class_name WeaponDef extends Resource

# Single source of truth for weapon data. Read by both client and server.
# Original JS reference: /Users/longmao/projects/pvp-game/public/game.js WEAPONS array (line 6).

const SLOT_PRIMARY   := &"primary"
const SLOT_SECONDARY := &"secondary"
const SLOT_MELEE     := &"melee"
const SLOT_SUPPORT   := &"support"

@export_group("Identity")
@export var id: StringName = &""
@export var display_name: String = ""
@export var type_label: String = ""        # e.g. "AR", "Shotgun+", "Sniper"
@export var slot: StringName = SLOT_PRIMARY
@export_multiline var description: String = ""   # shown to user in menus

@export_group("Damage")
@export var damage: float = 25.0
@export var headshot_multiplier: float = 2.0
@export var instakill_headshot: bool = false   # replaces INSTAKILL_HS_WEAPONS set

@export_group("Magazine / Reload")
@export var magazine: int = 30
@export var reserve: int = 90
## Milliseconds between shots. Matches semantics of `fireRate` in original
## /Users/longmao/projects/pvp-game/public/game.js WEAPONS (line 9).
@export_range(1, 10000) var fire_interval_ms: int = 150
@export var reload_time_ms: int = 2000
@export var no_reload: bool = false        # LMG-style infinite reserve

@export_group("Ballistics")
@export var auto: bool = true
@export var pellets: int = 1
@export_range(0.0, 1.0) var spread: float = 0.0
@export var bullet_speed: float = 120.0    # 0 = hitscan
@export_range(5.0, 120.0) var ads_zoom_fov: float = 45.0

@export_group("Throwable / AoE")
## When true, this weapon spawns a parabolic projectile (server-simulated)
## that explodes on contact OR when fuse_seconds elapses, dealing damage
## to all players inside `explode_radius` with linear distance falloff.
## Bypasses the hitscan raycast path in fire_resolver.
@export var is_throwable: bool = false
## Initial velocity magnitude (m/s) when the projectile leaves the hand.
@export var throw_speed: float = 18.0
## Extra upward pitch added to the aim direction so a flat throw still
## arcs nicely. Radians.
@export_range(0.0, 1.0) var throw_arc_pitch: float = 0.18
## 0 = explode on contact (impact grenade). >0 = explode after this many
## seconds OR on contact, whichever comes first (timed grenade).
@export_range(0.0, 10.0) var fuse_seconds: float = 1.5
## AoE radius in meters at explosion time. Players inside take damage
## with linear distance falloff (full at center, 0 at the edge).
@export var explode_radius: float = 4.0
## Max damage at center of explosion. Falls off to 0 at `explode_radius`.
## Headshot multiplier does NOT apply.
@export var explode_damage: float = 80.0

@export_group("Economy")
@export var price_credits: int = 0
@export var fragment_unlock_cost: int = 100
@export var free_starter: bool = false     # replaces FREE_WEAPONS set
@export var admin_only: bool = false       # replaces admin items (unlock code or Admin Pass)

@export_group("AI hints")
@export var scary_close: bool = false      # bots flee when target wields this (SCARY_CLOSE_WEAPONS)

@export_group("Ability")
@export var ability: AbilityDef

@export_group("Presentation")
@export var model_scene: PackedScene       # held weapon visual (shared/scenes/weapon_visual variants)
@export var fire_sound: AudioStream
@export var reload_sound: AudioStream
@export var bullet_color: Color = Color(1.0, 0.7, 0.2)


func fire_interval_seconds() -> float:
	return float(maxi(1, fire_interval_ms)) / 1000.0


func shots_per_second() -> float:
	return 1000.0 / float(maxi(1, fire_interval_ms))


func is_hitscan() -> bool:
	return bullet_speed <= 0.0
