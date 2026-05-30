# DADABOOM

A fast, server-authoritative multiplayer arena shooter built in **Godot 4.6**.
Jump in from any browser — no install, no account required.

🎮 **Play now:** https://game.boobank.com/dadaboom/

---

## English

### What is DADABOOM?

DADABOOM is a first-person multiplayer arena shooter. Pick a character, pick a
weapon, pick a mode, and fight — solo against bots, 1v1 duels, or full 10v10
team battles. Every shot is resolved by an authoritative dedicated server with
lag compensation, so hits are fair regardless of your ping. It runs natively in
the browser via WebSocket, and also exports to desktop (macOS / Windows).

### How to play

1. Open https://game.boobank.com/dadaboom/ in any modern browser.
2. Set your **name** and pick a **character skin** (18 to choose from).
3. Choose a **map** and a **mode**.
4. Hit **PRACTICE** for instant solo play vs AI, or **CREATE ROOM / JOIN** to
   play online with friends (share the 4-letter room code).

**Controls:** `WASD` move · mouse look · left-click fire · `R` reload ·
`Space` jump · `Shift` sprint · `1-4` switch weapon · `Q` ability · `Esc` pause.

### Game modes (18)

| Mode | One-liner |
|---|---|
| **FFA** (first to 5 / 1+15 bots) | Free-for-all, no teammates, fastest fragger wins |
| **1v1 / 2v2 / 3v3** | Best-of-3 elimination duels and small-squad fights |
| **TDM** (first team to 10) | Classic team deathmatch |
| **10v10 — race to 50** | Large-scale two-team war |
| **KOTH** | King of the hill — hold the central point |
| **Battle Royale** | Shrinking safe zone, last one standing |
| **Gun Game** | Every kill swaps your weapon up the ladder |
| **Infection** | Infected hunt survivors; the dead switch sides |
| **Juggernaut** | One super-tanky giant vs everyone |
| **One in the Chamber** | One bullet each — a hit refills it |
| **Sniper Only** | Long-range scoped duels |
| **D-Day / Frontlines** | Asymmetric attack-defend & line-push objectives |
| **Last Stand / Speedrun** | Survive escalating bot waves |

### Features

- **96 weapons** — assault rifles, snipers, shotguns, SMGs, energy/laser beams,
  explosive bows, throwables, melee — each with its own handling, ability and feel.
- **8 arenas** — open fields, trenches, a floating sky dock, king-of-the-hill
  layouts and more.
- **18 character skins.**
- **Server-authoritative netcode** with lag compensation and client-side
  snapshot interpolation — fair hit registration, smooth remote players.
- **Bots with real AI** — fill any mode solo; bots chase, aim and take cover.
- **Weapon abilities** — focus-fire buffs, power shots, bullet-wave bursts (`Q`).
- **Economy & progression** — earn credits per kill, open weapon chests, spin
  the daily wheel, and apply weapon upgrades. Backed by per-account persistence.
- **Room system** — create a public room or join by 4-letter code; LAN host too.
- **Browser-native** — Godot Web export over WebSocket, plus desktop builds.

### Tech

- Engine: Godot 4.6 (GDScript), Jolt physics.
- Netcode: dedicated server simulates every player from input RPCs, broadcasts
  snapshots at 30 Hz; clients render ~100 ms behind for smoothness; rewind-based
  lag compensation for fire resolution.
- Persistence: SQLite-backed accounts, economy and stats.
- Hosting: Caddy reverse proxy → Godot dedicated server, Cloudflare tunnel.

---

## 中文

### DADABOOM 是什么？

DADABOOM 是一款用 **Godot 4.6** 制作的快节奏多人竞技 FPS。选角色、选武器、选模式
就能开打 —— 单人打 bot、1v1 单挑，或者完整的 10v10 团战。每一枪都由权威专用服务器
配合延迟补偿来判定，无论你 ping 多高命中都公平。游戏通过 WebSocket 直接在浏览器里
运行，同时也能导出到桌面端（macOS / Windows）。

🎮 **直接玩：** https://game.boobank.com/dadaboom/

### 怎么玩

1. 任意现代浏览器打开 https://game.boobank.com/dadaboom/
2. 设置**名字**、挑一个**角色皮肤**（18 个可选）
3. 选**地图**和**模式**
4. 点 **PRACTICE** 立刻单人对战 AI，或 **CREATE ROOM / JOIN** 和朋友联机
   （分享 4 位房间码即可）

**操作：** `WASD` 移动 · 鼠标转视角 · 左键开火 · `R` 换弹 · `空格` 跳 ·
`Shift` 冲刺 · `1-4` 切武器 · `Q` 技能 · `Esc` 暂停。

### 游戏模式（18 种）

| 模式 | 一句话 |
|---|---|
| **自由对战 FFA**（先到 5 / 1+15 bot） | 无队友混战，谁先杀够谁赢 |
| **1v1 / 2v2 / 3v3** | 三局两胜的单挑与小队对决 |
| **团队竞技 TDM**（先到 10） | 经典团队死斗 |
| **10v10 — 先到 50** | 大规模双队拉锯战 |
| **占点 KOTH** | 占住中央高地者获胜 |
| **大逃杀 BR** | 安全区缩圈，活到最后 |
| **军备竞赛 Gun Game** | 每杀一人自动换下一把武器 |
| **感染模式 Infection** | 感染者猎杀幸存者，死者倒戈 |
| **巨人之战 Juggernaut** | 一个超肉巨人对抗全场 |
| **一发入魂 OITC** | 每人一发子弹，命中补一发 |
| **全员狙击 Sniper Only** | 纯远程瞄准对决 |
| **D-Day / 推线 Frontlines** | 非对称攻防 + 推线占点 |
| **抗波 Last Stand / Speedrun** | 扛住越来越强的 bot 波次 |

### 特色

- **96 把武器** —— 突击步枪、狙击枪、霰弹枪、冲锋枪、能量/激光束、爆炸弩、投掷物、
  近战，每把手感、技能、节奏都不同。
- **8 张地图** —— 开阔战场、战壕、漂浮的太空船坞、占点高地等。
- **18 个角色皮肤。**
- **服务器权威网络** —— 延迟补偿 + 客户端快照插值，命中判定公平、远端玩家移动顺滑。
- **真 AI 的 bot** —— 任何模式都能单人填满；bot 会追击、瞄准、找掩体。
- **武器技能** —— 集火增益、强力射击、弹幕齐射（`Q` 键释放）。
- **经济与成长** —— 击杀赚信用点，开武器宝箱，每日转盘，武器升级；账号数据持久化保存。
- **房间系统** —— 开公开房间或用 4 位房间码加入，也支持局域网直连。
- **浏览器原生** —— Godot Web 导出 + WebSocket，另有桌面端构建。

### 技术

- 引擎：Godot 4.6（GDScript）+ Jolt 物理。
- 网络：专用服务器用输入 RPC 模拟每个玩家，30 Hz 广播快照；客户端延迟约 100ms 渲染
  以保证平滑；开火判定用回溯式延迟补偿。
- 持久化：SQLite 存储账号、经济与战绩。
- 部署：Caddy 反向代理 → Godot 专用服务器，Cloudflare tunnel。

---

> *DADABOOM 是展示名；公开 URL 为 `/dadaboom/`，代码仓库 / 目录 / 服务名仍为 `godot-pvp`。*
> *CC0 art assets from ambientCG, Poly Haven, and Kenney.*
