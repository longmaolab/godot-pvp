extends RefCounted
## Curated 4-weapon loadout recipes — port from pvp-game's BEST_LOADOUTS
## (public/game.js:13128). Player picks one in the menu side panel; we
## write the weapon-id array into Settings.loadout, GameController reads
## it at spawn time.
##
## Each entry:
##   id    — kebab-case stable key (saved into settings.cfg if we ever
##           remember "last selected loadout"; not used yet)
##   name  — short bilingual label shown on the chip
##   desc  — one-sentence rationale for new players
##   slots — 4 weapon ids, matching .tres filenames in
##           shared/data/weapons/. They auto-bind to slot 1/2/3/4.
##
## Adding new recipes: grep `shared/data/weapons/` for available ids,
## append a Dictionary, done. No code changes needed elsewhere.

const LOADOUTS: Array[Dictionary] = [
	{
		"id": "starter",
		"name": "新手三件套 / STARTER",
		"desc": "万金油配置 — 突击 + 散弹 + 狙击 + 手雷,新手先用这套熟手感。",
		"slots": ["ak20", "sg8", "srx", "grenade"],
	},
	{
		"id": "rush",
		"name": "压上贴脸 / RUSH",
		"desc": "全近距 — 鸟枪 + SG8 + 火焰枪 + 飞斧。冲脸抢点,贴脸 1HKO。",
		"slots": ["auto_shotgun", "sg8", "flamethrower", "hatchet"],
	},
	{
		"id": "sniper",
		"name": "纯狙 / SNIPER ONLY",
		"desc": "远距硬控 — SRX + 巴雷特 + AMR + 高抛雷绕掩体。卡视线一枪一个。",
		"slots": ["srx", "barrett", "amr", "air_grenade"],
	},
	{
		"id": "rifleman",
		"name": "步枪手 / RIFLEMAN",
		"desc": "中距通吃 — AK20 主战 + AN94 点射 + Burst 连发 + 手雷开局丢一个。",
		"slots": ["ak20", "an94", "burst", "grenade"],
	},
	{
		"id": "trickshot",
		"name": "炫技流 / TRICKSHOT",
		"desc": "投射 + 抛物线 — Crossbow + Boombow + Railgun + 忍者飞镖。手感要求高。",
		"slots": ["crossbow", "boombow", "railgun", "shuriken"],
	},
	{
		"id": "sidearm",
		"name": "副武器流 / PISTOL MAIN",
		"desc": "全副武器 + 手雷救命 — 鹰 + 五七 + 左轮 + 手雷。低 TTK 但反应快、移动快。",
		"slots": ["desert_eagle", "five_seven", "auto_revolver", "grenade"],
	},
	{
		"id": "explosive",
		"name": "爆破 / DEMO",
		"desc": "AoE 之王 — Airburst + Boombow + 烟花 + 粘性炸药。布雷蹲点终极版。",
		"slots": ["airburst_projector", "boombow", "firework_launcher", "sticky_charge"],
	},
	{
		"id": "energy",
		"name": "电能流 / ENERGY",
		"desc": "Arc + Coil + EMP + 高抛雷打掩体后。连锁伤害 + 麻痹 + AoE 拐角杀。",
		"slots": ["arc_rifle", "arc_torrent", "coilgun", "air_grenade"],
	},
	{
		"id": "stealth",
		"name": "潜行 / STEALTH",
		"desc": "无声远距 — Dart + Crossbow + 气步枪 + 飞镖。安静秒杀,不暴露位置。",
		"slots": ["dart_gun", "crossbow", "air_rifle", "shuriken"],
	},
	{
		"id": "rng",
		"name": "随机娱乐 / WILDCARD",
		"desc": "彩蛋组合 — 投币枪 + 火焰枪 + Cycler + 便携火箭。打输不亏,打赢炫耀。",
		"slots": ["coin_gun", "flamethrower", "cycler", "pocket_rocket_throw"],
	},
]


## Returns the loadout dict matching `id`, or null if not found.
static func by_id(id: String) -> Variant:
	for entry in LOADOUTS:
		if entry.get("id", "") == id:
			return entry
	return null
