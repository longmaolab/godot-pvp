#!/usr/bin/env node
// Generate the remaining ModeDef .tres files from the MODE_TEAM_SIZES table
// in /Users/longmao/projects/pvp-game/server.js. Skip modes that already
// exist. Run from godot-pvp root:  node scripts/extract_modes.mjs

import fs from "node:fs";
import path from "node:path";

const OUT_DIR = path.resolve(
	"/Users/longmao/projects/godot-pvp/shared/data/modes"
);

// id => { display, family, ally, enemy, rounds_to_win, round_seconds, kill_goal,
//          lives, desc }
const MODES = {
	"1v1":         { display: "1v1 — best of 3", family: "elim", ally: 1, enemy: 1, rounds_to_win: 2, round_seconds: 60, kill_goal: 0, lives: 1,
		desc: "单挑淘汰赛（同 elim_1v1）。三局两胜，每回合 60 秒。对手倒地立刻赢，时间到血量高者赢。" },
	"2v2":         { display: "2v2 — best of 3", family: "elim", ally: 2, enemy: 2, rounds_to_win: 2, round_seconds: 60, kill_goal: 0, lives: 1,
		desc: "双人小队三局两胜。每回合 60 秒，对方全队倒下或时间到血量高者赢。配合 + 站位关键。" },
	"3v3":         { display: "3v3 — best of 3", family: "elim", ally: 3, enemy: 3, rounds_to_win: 2, round_seconds: 60, kill_goal: 0, lives: 1,
		desc: "三人小队三局两胜。空间感和角色定位（突击 / 火力 / 狙击）的小型团队战。" },
	"5v5":         { display: "5v5 — race to 25", family: "race", ally: 5, enemy: 5, rounds_to_win: 1, round_seconds: 0, kill_goal: 25, lives: -1,
		desc: "团队竞技 5 人队，先到 25 击杀获胜。无回合、可重生，节奏快。需要队伍分工和支援。" },
	"10v10":       { display: "10v10 — race to 50", family: "race", ally: 10, enemy: 10, rounds_to_win: 1, round_seconds: 0, kill_goal: 50, lives: -1,
		desc: "大型 10 人队对抗。先到 50 击杀获胜。地图大，分散与集结的拉锯战。" },
	"ffa5":        { display: "FFA — 1 + 5 bots", family: "ffa", ally: 1, enemy: 5, rounds_to_win: 1, round_seconds: 0, kill_goal: 10, lives: -1,
		desc: "1 个真人 + 5 个 bot 的小型自由竞技。先到 10 击杀获胜。新手适合的练手。" },
	"ffa15":       { display: "FFA — 1 + 15 bots", family: "ffa", ally: 1, enemy: 15, rounds_to_win: 1, round_seconds: 0, kill_goal: 20, lives: -1,
		desc: "1 个真人 + 15 个 bot 的混战。先到 20 击杀获胜。考验持续作战能力。" },
	"koth":        { display: "KOTH — hold the hill", family: "koth", ally: 1, enemy: 9, rounds_to_win: 1, round_seconds: 180, kill_goal: 0, lives: -1,
		desc: "占山为王。中央高地是制高点，长时间占据者获胜（计分制）。配合 KOTH 地图最佳。" },
	"gungame":     { display: "Gun Game — 武器轮换", family: "arcade", ally: 1, enemy: 7, rounds_to_win: 1, round_seconds: 0, kill_goal: 0, lives: -1,
		desc: "每击杀一人，自动切换到下一把武器。从冲锋枪一路换到拳头，最先用拳头杀死最后一人者获胜。" },
	"oitc":        { display: "OITC — 一发入魂", family: "arcade", ally: 1, enemy: 5, rounds_to_win: 1, round_seconds: 0, kill_goal: 10, lives: -1,
		desc: "One in the Chamber：每人只有 1 发子弹，命中击杀对方补 1 发。极致紧张的精准对决。" },
	"juggernaut":  { display: "Juggernaut — 巨人之战", family: "arcade", ally: 1, enemy: 5, rounds_to_win: 1, round_seconds: 0, kill_goal: 15, lives: -1,
		desc: "一个玩家变身巨人：3 倍血量 + 重武器。其他玩家联手击败他。击败巨人者成为新巨人。" },
	"infection":   { display: "Infection — 感染模式", family: "arcade", ally: 1, enemy: 5, rounds_to_win: 1, round_seconds: 120, kill_goal: 0, lives: 1,
		desc: "1 个感染者 vs 全员幸存者。感染者击杀 → 受害者变感染者。最后剩下的幸存者获胜，或全员感染则感染方获胜。" },
	"sniper_only": { display: "Sniper Only — 全员狙击", family: "arcade", ally: 1, enemy: 5, rounds_to_win: 1, round_seconds: 0, kill_goal: 10, lives: -1,
		desc: "所有人只能用狙击枪 + 副武器。考验远距离瞄准、走位预判。常用于 Trenches / Battlefield 大地图。" },
	"speedrun":    { display: "Speedrun — 1 vs 20", family: "arcade", ally: 1, enemy: 20, rounds_to_win: 1, round_seconds: 0, kill_goal: 20, lives: -1,
		desc: "1 个真人对抗 20 个 bot。能撑多久？能杀多少？纯抗压测试。建议用 Railgun + Crossbow。" },
};

const existing = new Set(
	fs.readdirSync(OUT_DIR)
		.filter((f) => f.endsWith(".tres") && !f.startsWith("_"))
		.map((f) => f.replace(/\.tres$/, ""))
);
console.log(`existing modes: ${[...existing].sort().join(", ")}`);

let written = 0;
for (const [id, m] of Object.entries(MODES)) {
	const fileId = sanitize(id);
	if (existing.has(fileId) || existing.has(toFileId(id, m))) continue;
	const tres = renderModeTres(fileId, m);
	const outPath = path.join(OUT_DIR, `${fileId}.tres`);
	fs.writeFileSync(outPath, tres);
	written++;
	console.log(`  wrote ${fileId}.tres`);
}
console.log(`\nDONE — wrote ${written} new modes`);

function toFileId(id, m) {
	// Some existing files use richer names like ffa_kill5.tres for ffa5.
	if (id === "ffa5") return "ffa_kill5";
	if (id === "1v1") return "elim_1v1";
	if (id === "5v5") return "tdm_kill10";   // not a real alias; left to skip if present
	return sanitize(id);
}

function sanitize(s) {
	return String(s).replace(/[^a-z0-9_]/gi, "_");
}

function renderModeTres(fileId, m) {
	return [
		`[gd_resource type="Resource" script_class="ModeDef" load_steps=2 format=3]`,
		"",
		`[ext_resource type="Script" path="res://shared/data/modes/_mode_def.gd" id="1"]`,
		"",
		`[resource]`,
		`script = ExtResource("1")`,
		`id = &"${fileId}"`,
		`display_name = "${esc(m.display)}"`,
		`description = "${esc(m.desc)}"`,
		`family = &"${m.family}"`,
		`humans_per_team = ${m.ally}`,
		`team_count = 2`,
		`default_bots_per_side = ${Math.max(0, m.enemy - m.ally)}`,
		`rounds_to_win = ${m.rounds_to_win}`,
		`round_seconds = ${m.round_seconds}`,
		`kill_goal = ${m.kill_goal}`,
		`lives_per_player = ${m.lives}`,
		`credits_per_kill = ${m.family === "elim" ? 10 : 5}`,
		`credits_per_win = ${m.family === "elim" ? 80 : 50}`,
		`credits_per_loss = 20`,
		`credit_cap_per_match = 250`,
		"",
	].join("\n");
}

function esc(s) {
	return String(s || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}
