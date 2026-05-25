#!/usr/bin/env node
// Read /Users/longmao/projects/pvp-game/public/game.js, find the WEAPONS array,
// emit a Godot 4 .tres file for every weapon NOT already in
// /Users/longmao/projects/godot-pvp/shared/data/weapons/.
//
// Run from the godot-pvp root:  node scripts/extract_weapons.mjs
//
// This is data-only: the WeaponDef Resource schema in
// shared/data/weapons/_weapon_def.gd already accepts everything we emit here.

import fs from "node:fs";
import path from "node:path";

const ORIG_GAME_JS = "/Users/longmao/projects/pvp-game/public/game.js";
const OUT_DIR = path.resolve(
	"/Users/longmao/projects/godot-pvp/shared/data/weapons"
);

const SCARY_CLOSE_DEFAULT = new Set([
	"sg8", "sg100", "auto_shotgun", "incendiary_shotgun", "spas12",
	"flamethrower", "sticker_blaster", "shorty", "sawed_off",
]);
const INSTAKILL_HS_WEAPONS = new Set([
	"srx", "railgun", "lever", "boombow", "boombow_ab", "boombow_c1",
	"railgun_ab", "amr", "harpoon_gun",
]);

// Tactical descriptions (Chinese) for each weapon family. Kept short for menus.
const DESCRIPTIONS = {
	ak30: "AR+ 升级版自动步枪，45 发大弹匣 + 装甲穿透技能：4 秒内 +50% 伤害无视距离衰减。中距离持续输出王者。",
	mp40: "经典 SMG，40 发弹匣，开火极快（80ms 间隔）。Piercing Round 技能让全弹匣以 3× 速度倾泻。",
	p90: "高阶 SMG，50 发弹匣 + 0.05 散布，火力倾泻。技能稳定弹道 + 暴击。",
	rpd: "重机枪。300 发巨型弹链 + 无需换弹，火力 6.7 发/秒持续输出。Overclock 大招：5 秒射速翻倍。",
	revolver: "经典左轮副武器。6 发，单发威力高，慢节奏精准射击。",
	flare: "信号枪副武器。85 伤害爆裂弹，弹道明显但威力惊人。",
	pistol: "标准副武器手枪。12 发，平衡攻防。",
	shorty: "袖珍霰弹副武器，近战救命。",
	cycler: "循环副武器，独特弹道。",
	hand_cannon: "重型左轮，高单发伤害，慢射速。",
	machine_pistol: "全自动微型冲锋枪副武器，火力压制。",
	sawed_off: "锯短双管，近战极致威力，2 发。",
	minigun: "重型加特林，弹匣海量，转动后倾泻，移动慢。",
	flamethrower: "近距离喷火器。多发火舌，伤害随燃烧累积，AI 见你拿出来会撤退。",
	grenade_launcher: "榴弹发射器，弹道抛物线，区域爆炸。",
	freeze_gun: "冻结射线，命中减速 + 累计冻住。",
	boombow: "爆炸弓，箭簇爆炸，头爆秒杀。",
	lever: "杠杆步枪，10 发，慢节奏 marksman，头爆秒杀。",
	auto_shotgun: "全自动霰弹枪，火力恐怖。",
	burst: "三连发突击步枪，节奏感强。",
	an94: "高速双发突击步枪。",
	spas12: "战术霰弹枪，泵动 + 自动可切换。",
	m1_garand: "二战经典战斗步枪，8 发弹夹，单发威力高。",
	paintball: "彩弹枪。低伤害但散布小，乐子武器。",
	vector: "Vector 冲锋枪，超高射速。",
	plasma_carbine: "等离子卡宾枪，能量弹道。",
	arc_rifle: "电弧步枪，命中连锁电击。",
	railgun: "（详见 railgun.tres，已存在）",
	crossbow: "（详见 crossbow.tres，已存在）",
	srx: "（详见 srx.tres，已存在）",
};

const raw = fs.readFileSync(ORIG_GAME_JS, "utf8");

// Locate the WEAPONS array and read until matching `];`
const startMarker = "const WEAPONS = [";
const startIdx = raw.indexOf(startMarker);
if (startIdx < 0) {
	console.error("Could not find WEAPONS array marker");
	process.exit(1);
}
const arrStart = startIdx + startMarker.length;
let depth = 1;
let i = arrStart;
while (i < raw.length && depth > 0) {
	const c = raw[i];
	if (c === "[") depth++;
	else if (c === "]") depth--;
	i++;
}
const arrText = raw.slice(arrStart, i - 1);

// Build an evaluable JS expression: wrap the body in array brackets again, then
// eval. The original WEAPONS entries are plain object literals with JS comments
// stripped — they should eval cleanly.
let weapons;
try {
	weapons = eval("[" + arrText + "]");
} catch (e) {
	console.error("eval failed:", e.message);
	process.exit(1);
}

console.log(`extracted ${weapons.length} weapon entries from game.js`);

// Find what's already in the output directory.
const existing = new Set(
	fs.readdirSync(OUT_DIR)
		.filter((f) => f.endsWith(".tres") && !f.startsWith("_"))
		.map((f) => f.replace(/\.tres$/, ""))
);
console.log(`already ported: ${[...existing].sort().join(", ")}`);

let written = 0;
let skipped = 0;
for (const w of weapons) {
	if (!w || !w.id) continue;
	if (existing.has(w.id)) {
		skipped++;
		continue;
	}
	const tresText = renderWeaponTres(w);
	const outPath = path.join(OUT_DIR, `${w.id}.tres`);
	fs.writeFileSync(outPath, tresText);
	written++;
	console.log(`  wrote ${w.id}.tres`);
}
console.log(`\nDONE — wrote ${written} new, skipped ${skipped} existing`);

// ─────────────────────────────────────────────────────────────────────────────
function renderWeaponTres(w) {
	const id = w.id;
	const ability = w.ability || {};
	const hasAbility = !!ability.name;
	const damage = numOr(w.damage, 25);
	const pellets = intOr(w.pellets, 1);
	const spread = numOr(w.spread, 0);
	const mag = intOr(w.mag, 30);
	const reserve = intOr(w.reserve, mag * 3);
	const fireInterval = intOr(w.fireRate, 150);
	const reloadMs = intOr(w.reloadTime, 2000);
	const bulletSpeed = numOr(w.bulletSpeed, 120);
	const ads = numOr(w.adsZoom, 45);
	const auto = w.auto !== false && w.auto !== undefined ? !!w.auto : false;
	const noReload = !!w.noReload;
	const slot = w.slot || "primary";
	const typeLabel = w.type || "";
	const displayName = w.name || id;
	const isAdmin = (w.type || "").toLowerCase().startsWith("admin");
	const free = ["ak20", "sg8", "mp40", "burst", "lever", "paintball", "pistol", "revolver", "flare"].includes(id);
	const scaryClose = SCARY_CLOSE_DEFAULT.has(id);
	const instakillHs = INSTAKILL_HS_WEAPONS.has(id);
	const desc = (DESCRIPTIONS[id] || `${typeLabel || "武器"}: ${displayName} — 详见原版手感。`).replace(/"/g, '\\"');
	const colorPick = pickColor(id, typeLabel);

	const loadSteps = hasAbility ? 3 : 2;

	let extResources = `[ext_resource type="Script" path="res://shared/data/weapons/_weapon_def.gd" id="1"]`;
	let abilityBlock = "";
	let abilityField = "";
	if (hasAbility) {
		extResources += `\n[ext_resource type="Script" path="res://shared/data/weapons/_ability_def.gd" id="2"]`;
		const abType = mapAbilityType(ability.type || "");
		abilityBlock = [
			`[sub_resource type="Resource" id="ability_${sanitize(id)}"]`,
			`script = ExtResource("2")`,
			`name = "${escapeStr(ability.name || "Ability")}"`,
			`description = "${escapeStr(ability.desc || ability.description || "")}"`,
			`type = &"${abType}"`,
			`cooldown_ms = ${intOr(ability.cd, 10000)}`,
			`duration_ms = ${intOr(ability.duration, 0)}`,
			`damage_mult = ${numOr(ability.dmgMult, 1)}`,
			`spread_mult = ${numOr(ability.spreadMult, 1)}`,
			`speed_mult = ${numOr(ability.speedMult, 1)}`,
			`pellets = ${intOr(ability.pellets, 0)}`,
			`grid_w = ${intOr(ability.gridW || ability.grid, 0)}`,
			`grid_h = ${intOr(ability.gridH || ability.grid, 0)}`,
			`delay_ms = ${intOr(ability.delay, 0)}`,
			`radius = ${numOr(ability.radius, 0)}`,
			`disables_ads = ${!!ability.noADS}`,
			"",
		].join("\n");
		abilityField = `ability = SubResource("ability_${sanitize(id)}")\n`;
	}

	const body = [
		`[gd_resource type="Resource" script_class="WeaponDef" load_steps=${loadSteps} format=3]`,
		"",
		extResources,
		"",
		abilityBlock,
		`[resource]`,
		`script = ExtResource("1")`,
		`id = &"${id}"`,
		`display_name = "${escapeStr(displayName)}"`,
		`type_label = "${escapeStr(typeLabel)}"`,
		`slot = &"${slot}"`,
		`description = "${desc}"`,
		`damage = ${damage}`,
		`headshot_multiplier = 2.0`,
		`instakill_headshot = ${instakillHs}`,
		`magazine = ${mag}`,
		`reserve = ${reserve}`,
		`fire_interval_ms = ${fireInterval}`,
		`reload_time_ms = ${reloadMs}`,
		`no_reload = ${noReload}`,
		`auto = ${auto}`,
		`pellets = ${pellets}`,
		`spread = ${spread}`,
		`bullet_speed = ${bulletSpeed}`,
		`ads_zoom_fov = ${ads}`,
		`price_credits = ${defaultPrice(w)}`,
		`fragment_unlock_cost = 100`,
		`free_starter = ${free}`,
		`admin_only = ${isAdmin}`,
		`scary_close = ${scaryClose}`,
		abilityField,
		`bullet_color = ${colorPick}`,
	];
	return body.join("\n") + "\n";
}

function mapAbilityType(t) {
	switch ((t || "").toLowerCase()) {
		case "buff":            return "buff";
		case "powershot":       return "powershot";
		case "bulletwave":      return "bulletwave";
		case "fanfire_all":     return "fanfire_all";
		case "throwbomb":       return "throwbomb";
		case "aoe":             return "aoe";
		case "blink":           return "blink";
		case "freeze":          return "freeze";
		case "heal":            return "heal";
		case "shield":          return "shield";
		case "drone":           return "drone";
		case "charge":          return "charge";
		case "multishot":       return "multishot";
		default:                return "buff";
	}
}

function defaultPrice(w) {
	if (w.slot === "secondary") return 180;
	if ((w.type || "").startsWith("Admin")) return 0;
	const d = w.damage || 25;
	return Math.max(120, Math.min(2500, d * 12));
}

function pickColor(id, typeLabel) {
	const t = (typeLabel || "").toLowerCase();
	if (t.includes("sniper") || t.includes("marksman")) return "Color(0.4, 0.85, 1, 1)";
	if (t.includes("shotgun")) return "Color(1, 0.85, 0.3, 1)";
	if (t.includes("smg")) return "Color(0.6, 0.85, 0.4, 1)";
	if (t.includes("lmg") || t.includes("heavy")) return "Color(0.9, 0.4, 0.3, 1)";
	if (t.includes("energy") || t.includes("plasma") || t.includes("sci")) return "Color(0.7, 0.4, 1, 1)";
	if (t.includes("fire") || t.includes("flame") || t.includes("incendiary")) return "Color(1, 0.5, 0.15, 1)";
	if (t.includes("explosive") || t.includes("launcher")) return "Color(1, 0.7, 0.2, 1)";
	if (t.includes("electric") || t.includes("lightning") || t.includes("arc")) return "Color(0.5, 0.85, 1, 1)";
	if (t.includes("admin")) return "Color(1, 0.3, 0.5, 1)";
	return "Color(1, 0.7, 0.2, 1)";
}

function escapeStr(s) {
	return String(s || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}
function sanitize(id) {
	return String(id).replace(/[^a-z0-9_]/gi, "_");
}
function intOr(v, def) {
	const n = Number(v);
	return Number.isFinite(n) ? Math.round(n) : def;
}
function numOr(v, def) {
	const n = Number(v);
	return Number.isFinite(n) ? n : def;
}
