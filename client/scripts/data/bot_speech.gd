extends RefCounted
## Bot trash-talk phrase pool. game_controller wires this into _on_bot_died
## (DEATH lines) and _on_any_player_died when killer is a bot (KILL lines).
## Single-player practice was eerily silent — now bots react when they
## die or score a kill so the kid isn't shooting at mannequins.

const DEATH: Array[String] = [
	"哎呀!",
	"再来!",
	"运气好!",
	"下次注意。",
	"你赢这把。",
	"卡 bug 了吧!",
	"网卡了……",
	"不服!",
	"还能再战。",
	"GG。",
]

const KILL: Array[String] = [
	"干掉一个!",
	"easy.",
	"看招!",
	"GG ez。",
	"练练再来。",
	"瞄准要稳啊。",
	"+1。",
	"爽!",
	"哈哈哈。",
	"下一个!",
]


static func random_death() -> String:
	if DEATH.is_empty():
		return ""
	return DEATH[randi() % DEATH.size()]


static func random_kill() -> String:
	if KILL.is_empty():
		return ""
	return KILL[randi() % KILL.size()]
