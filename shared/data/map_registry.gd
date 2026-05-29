extends Object
class_name MapRegistry
## Shared map metadata — used by both main_menu (picker) and room_lobby
## (description display). Single source of truth so the lobby's "what are
## the rules" panel matches what the picker advertised.

const MAPS := [
	{
		"name": "Blank — 空旷方形",
		"path": "res://shared/scenes/maps/blank.tscn",
		"desc": "60×60 米的开阔场地，两个矮障碍。适合熟悉操作、纯走位练习。无地形优势，纯枪法。",
	},
	{
		"name": "Battlefield — 平原工事",
		"path": "res://shared/scenes/maps/battlefield.tscn",
		"desc": "100×100 大地图，散落木箱、长墙、矮掩体。中远距离对枪 + 卡点对枪都好用。AR 和狙击都适合。",
	},
	{
		"name": "KOTH — 中央高地",
		"path": "res://shared/scenes/maps/koth.tscn",
		"desc": "80×80 场地，正中三层圆形小山是制高点。四个角落有小掩体。占山为王，视野压制。",
	},
	{
		"name": "Trenches — WW1 战壕",
		"path": "res://shared/scenes/maps/trenches.tscn",
		"desc": "南北双线战壕，中间无人区下沉。带战争雾化，限制远距离。突破或防守的攻防博弈。",
	},
	{
		"name": "Skydock — 立体平台",
		"path": "res://shared/scenes/maps/skydock.tscn",
		"desc": "三层垂直结构：底层 + 南北中层平台 + 顶层指挥台。斜坡互联。垂直作战、上下夹击。",
	},
	{
		"name": "Crossfire — 室内近战",
		"path": "res://shared/scenes/maps/crossfire.tscn",
		"desc": "46×46 室内十字楼：中央带四门的方形建筑 + 外圈走廊掩体。贴脸近战、卡门、滑铲拐角。霰弹/冲锋枪天堂。",
	},
	{
		"name": "Longshot — 狙击长廊",
		"path": "res://shared/scenes/maps/longshot.tscn",
		"desc": "96 米双线长廊，中央长墙分割南北两道、三处缺口可换线。超长视野，狙击与 AR 架枪、控点拉距离。",
	},
	{
		"name": "Foundry — 熔炉竞技场",
		"path": "res://shared/scenes/maps/foundry.tscn",
		"desc": "70×70 八角竞技场：中央高台 + 四角立柱 + 四向集装箱。绕柱转点、抢占中央高地，近中距离混战。",
	},
]


## Return {name, desc} for a map file path. Falls back to {name=basename, desc=""}
## so callers don't have to special-case unknown paths.
static func info_for(path: String) -> Dictionary:
	for m in MAPS:
		if m.path == path:
			return {"name": m.name, "desc": m.desc}
	return {"name": path.get_file().get_basename(), "desc": ""}
