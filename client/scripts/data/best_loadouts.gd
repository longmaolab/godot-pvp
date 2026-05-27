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
		"desc": "万金油配置 — 突击 + 散弹 + 狙击 + 重火,新手先用这套熟手感。",
		"slots": ["ak20", "sg8", "srx", "railgun"],
	},
	{
		"id": "rush",
		"name": "压上贴脸 / RUSH",
		"desc": "全近距武器,适合小图 1v1 / 抢点。鸟枪开路,贴脸刀切。",
		"slots": ["auto_shotgun", "sg8", "flamethrower", "desert_eagle"],
	},
	{
		"id": "sniper",
		"name": "纯狙 / SNIPER ONLY",
		"desc": "远距硬控,适合大图。卡视线 + 一枪一个,但近距很弱。",
		"slots": ["srx", "barrett", "amr", "crossbow"],
	},
	{
		"id": "rifleman",
		"name": "步枪手 / RIFLEMAN",
		"desc": "中距通吃 — AK 主战、AN94 点射、Burst 连发、AK30 备用。",
		"slots": ["ak20", "an94", "burst", "ak30"],
	},
	{
		"id": "trickshot",
		"name": "炫技流 / TRICKSHOT",
		"desc": "投射 / 抛物线武器为主。Crossbow 一击致命,Boombow 范围杀。手感要求高。",
		"slots": ["crossbow", "boombow", "railgun", "flare"],
	},
	{
		"id": "sidearm",
		"name": "副武器流 / PISTOL MAIN",
		"desc": "全副武器配置 — 鹰、五七、左轮、EMP。低 TTK 但反应快、移动快。",
		"slots": ["desert_eagle", "five_seven", "auto_revolver", "emp_pistol"],
	},
	{
		"id": "explosive",
		"name": "爆破 / DEMO",
		"desc": "AoE + 范围杀。Airburst / Boombow / 烟花 / 飞镖,蹲点房子神器。",
		"slots": ["airburst_projector", "boombow", "firework_launcher", "flechette"],
	},
	{
		"id": "energy",
		"name": "电能流 / ENERGY",
		"desc": "Arc / Coil / 电磁脉冲组合 — 连锁伤害 + 麻痹 buff debuff 战术。",
		"slots": ["arc_rifle", "arc_torrent", "coilgun", "emp_pistol"],
	},
	{
		"id": "stealth",
		"name": "潜行 / STEALTH",
		"desc": "无声远距 — Dart / Crossbow / Air Rifle / Flechette,LMG 听不到也看不到。",
		"slots": ["dart_gun", "crossbow", "air_rifle", "flechette"],
	},
	{
		"id": "rng",
		"name": "随机娱乐 / WILDCARD",
		"desc": "彩蛋武器组合 — Coin Gun / Flame / Cycler / Coil。打输不亏,打赢炫耀。",
		"slots": ["coin_gun", "flamethrower", "cycler", "coilgun"],
	},
]


## Returns the loadout dict matching `id`, or null if not found.
static func by_id(id: String) -> Variant:
	for entry in LOADOUTS:
		if entry.get("id", "") == id:
			return entry
	return null
