# Codex Review

> 把 Codex / 其它 reviewer 给的代码审查意见贴在这里，按时间倒序。
> Claude 读这个文件时按 P0 → P1 → P2 顺序修复，每修一条标 `[x]` 并写明改了哪些文件。
> 用完后归档到 `codexreview-archive/`。

---

## 格式模板

```
## YYYY-MM-DD HH:MM — reviewer name

### [P0/P1/P2] 一句话标题
**文件**：path:line
**问题**：xxx
**建议**：xxx

### [x] 已修复 — 改了 path1, path2，commit abc1234
```

---

## 待修复

## 2026-06-02 02:02 +08 — Codex

**摘要**

- 本轮复审当前 `HEAD` = `5ba4c1b`（上一轮 review report commit）。`git log --since=2026-05-31T18:00:48Z -- . ':(exclude).agent/codexreview.md'` 没有新的项目代码提交，所以重点是复验上一轮开放项和轻量门禁。
- 未发现新的 P0/P1 gameplay / networking 破坏；RoomManager、RoomWorld、Database、main-menu compression 均通过。
- 仍有 3 个 P2 开放：`run_quick.sh` 的 boot gate 仍红、线上 wheel cooldown/付费文案仍和服务器规则漂移、自定义 loadout 默认第 4 槽仍与实战默认不一致。

### [P2] `run_boot_test.sh` 仍误报 macOS CA stderr，`run_quick.sh` 红灯
**文件**：`tests/run_boot_test.sh:30`

**问题**：`run_quick.sh` 本轮仍是 9 passed / 1 failed，唯一失败是 `boot_test`。过滤逻辑只删掉包含 `certificat|get_system_ca` 的行，但 macOS Godot 输出仍是两行：第一行 `ERROR: Condition "ret != noErr" is true. Returning: ""` 不包含 certificate 关键字，第二行才是 `get_system_ca_certificates`，所以第 30 行仍把第一行当项目错误。

**为什么重要**：轻量门禁继续红灯，后续 reviewer/CI 仍要人工判断“项目坏了还是 macOS 证书噪声”。这会降低 `run_quick.sh` 对真实 boot/runtime regressions 的信任度。

**建议**：把 macOS CA 事件按上下文过滤，而不是逐行 keyword 过滤。可用 `awk`/状态机在看到下一行 `get_system_ca_certificates` 时同时丢弃前一条 generic `ERROR:`；或者改成只匹配项目级错误（`SCRIPT ERROR|Parse Error|Failed to load script|Node not found`）并保留 dedicated allowlist 测试。

### [P2] 线上 wheel cooldown 没同步到客户端，UI 仍暗示可付费继续抽
**文件**：`client/scripts/persistence/settings.gd:230`、`client/scripts/persistence/settings.gd:440`、`client/scripts/ui/shop.gd:522`、`client/scripts/ui/shop.gd:526`、`client/scripts/ui/main_menu.gd:1133`、`client/scripts/ui/main_menu.gd:1168`、`server/scripts/profile_service.gd:386`

**问题**：`ProfileService._build_profile()` 已下发 `last_free_spin_ms`，但 `Settings._apply_server_profile()` 仍没有保存该字段；`has_free_spin_today()` 只看本地 `last_free_spin_iso`。Shop 根据这个本地 ISO 显示 `FREE SPIN` 或 `$100` paid spin，MainMenu 每次打开 wheel dialog 又直接 `wheel_spin.disabled = false`。服务器端 `_on_spin_wheel()` 在 24h cooldown 内只 `_ack("spin", false, "wait N hours")`，没有 paid-spin 扣费路径，`NetProtocol.WHEEL_PAID_COST` 也仍未被服务器使用。

**为什么重要**：在线玩家抽完一次后，客户端可能继续显示可抽或付费抽；点击后服务器只拒绝，表现像按钮坏了或经济扣费规则不一致。Shop 的 `_show_wheel_reward()` 还会在 profile push 后重新 enable 按钮，进一步制造重复点击/重复拒绝。

**建议**：在 `Settings` 增加 `last_free_spin_ms` 或 `can_free_spin_at_ms`，从 server profile 写入并让 Shop/MainMenu 都按服务器 cooldown 渲染。产品上二选一：支持 paid spin 就让 RPC 携带 paid/free 意图并由服务器扣 `NetProtocol.WHEEL_PAID_COST` 后发奖；不支持 paid spin 就移除 `$100` 文案/常量并在 cooldown 内禁用按钮、显示剩余时间。

### [P2] 自定义 loadout 默认值仍和运行时默认不一致
**文件**：`client/scripts/game_controller.gd:21`、`client/scripts/ui/main_menu.gd:1011`、`client/scripts/ui/main_menu.gd:1434`、`client/scripts/ui/main_menu.gd:1468`

**问题**：实战 `GameController.DEFAULT_LOADOUT` 是 `[AK20, SG8, SRX, RAILGUN]`，Loadout picker 文案也写 `AK20 · SG8 · SRX · RAILGUN`；但自定义编辑器无保存值时和 Reset 时仍使用 `["ak20", "sg8", "srx", "grenade"]`。

**为什么重要**：玩家点默认/Reset 时会在不同入口拿到不同第 4 槽。保存自定义后还会把原本 railgun 默认覆盖成 grenade 版本，导致菜单文案、持久化设置、实战装备互相不一致。

**建议**：提一个共享默认 ID 数组（至少 `main_menu.gd` 内单一常量），并与 `GameController.DEFAULT_LOADOUT` 对齐为 `["ak20", "sg8", "srx", "railgun"]`；或如果产品决定默认第 4 槽是 grenade，就同步改 `DEFAULT_LOADOUT` 和 picker 文案。

### [x] 已修复（2026-06-03，Claude）—— 本批 3 个 P2 全部闭环（含 06-01 批次的同名重复项）

**P2-1 boot_test 误报 macOS CA stderr** —— 改了 `tests/run_boot_test.sh`。根因：CA
事件是**两行**（第一行裸 `ERROR: Condition "ret != noErr"...` 不含关键字，第二行
`at: get_system_ca_certificates`），原来的逐行 `grep -viE` 只删得掉第二行，第一行漏网
当成项目错误。做法：用 awk 状态机做**上下文过滤**——凡某行的*下一行*命中
`get_system_ca|certificat`，就连同那一行（错误头）一起丢弃，再保留原 keyword 兜底。
保留 `@onready Node-not-found / SCRIPT ERROR / Parse Error` 覆盖。本机模拟两行 CA 日志
验证：CA 事件双行被吞、真 `SCRIPT ERROR` 仍命中。

**P2-2 线上 wheel cooldown 没服务器驱动** —— 改了 `client/scripts/persistence/settings.gd`、
`client/scripts/ui/shop.gd`、`client/scripts/ui/main_menu.gd`、
`shared/scripts/network/net_protocol.gd`、`server/scripts/profile_service.gd`。根因：服务器
profile 已下发 `last_free_spin_ms`，但 `Settings._apply_server_profile()` 从没保存它，
`has_free_spin_today()` 只看本地 ISO；线上玩家抽完后 UI 还显示 FREE / `$100` 付费抽，但
服务端只有 24h 免费冷却、**根本没有付费抽扣费路径**（`WHEEL_PAID_COST` 是死常量），点了
只会被拒，像按钮坏了。产品取向：**线上只有免费冷却，不做付费抽**（offline 仍保留本地
`$100` 付费抽，那条是合法的本地经济）。做法：① `Settings` 新增 `last_free_spin_ms`
字段（持久化 + 从 server profile 写入），`has_free_spin_today()` 在 `_server_authoritative()`
时改走 24h wall-clock 冷却，新增 `free_spin_cooldown_remaining_ms()` /
`free_spin_cooldown_label()`；② `NetProtocol` 加 `WHEEL_FREE_COOLDOWN_MS`（client+server
单一来源），删掉死常量 `WHEEL_PAID_COST`；③ Shop `_refresh_wheel_hint` 线上冷却态改成
禁用按钮 + 显示倒计时（不再显示 `$100`），`_show_wheel_reward` 线上不再无脑 re-enable，
并接 `profile_synced` 在 profile 落地后重渲倒计时（解决 reward 先于 profile 到达的竞态）；
④ MainMenu `_on_open_wheel` 不再无条件 enable，按服务器冷却禁用 + 显示剩余时间。
**需人工验证**：实机连服务器抽一次后，确认 Shop / MainMenu 两处按钮都进倒计时禁用态、
24h 后恢复（无 Godot 单测覆盖 wheel UI，逻辑路径已随全套测试 parse/boot 通过）。

**P2-3 自定义 loadout 默认第 4 槽与实战默认不一致** —— 改了
`client/scripts/ui/main_menu.gd`。根因：实战 `GameController.DEFAULT_LOADOUT` 与 picker
文案都是 `...RAILGUN`，但自定义编辑器无保存值预选 + Reset 硬编码 `grenade`。做法：在
`main_menu.gd` 新增单一常量 `DEFAULT_LOADOUT_IDS = ["ak20","sg8","srx","railgun"]`，
编辑器预选（旧 1434 行）与 Reset（旧 1468 行）都改读它，对齐 railgun。

**回归**：`GODOT_BIN=Godot_v4.6 bash tests/run_all.sh` → **50 passed / 0 failed**（本容器
无 7777 端口冲突，连 multiplayer_integration 也过）；`run_boot_test.sh` PASS、
`run_database_test.sh` 13/13 PASS。

### 验证

- `git status --short`：仅有无关 untracked `.claude/scheduled_tasks.lock`，未触碰。
- `git log --since='2026-05-31T18:00:48Z' -- . ':(exclude).agent/codexreview.md'`：无新的项目代码提交。
- `HOME=/private/tmp/godot-home bash tests/run_quick.sh`
  - 9 passed / 1 failed in 13s
  - 唯一失败：`boot_test` 仍误报 macOS `get_system_ca_certificates` 前一行 generic `ERROR`
- `HOME=/private/tmp/godot-home bash tests/run_database_test.sh` PASS（13/13）
- `HOME=/private/tmp/godot-home bash tests/run_room_manager_test.sh` PASS
- `HOME=/private/tmp/godot-home bash tests/run_room_world_test.sh` PASS
- `HOME=/private/tmp/godot-home bash tests/run_main_menu_compression_test.sh` PASS（LeftCard min 816 < 860）

### 推荐下一步

1. 先修 boot-test CA 上下文过滤，让 `run_quick.sh` 恢复可信绿灯。
2. 明确 wheel 产品规则并把客户端 cooldown/付费状态改为服务器驱动。
3. 统一默认 loadout 第 4 槽，避免 Reset/Save 悄悄覆盖实战默认。

---

## 2026-06-01 02:04 +08 — Codex

**摘要**

- 本轮复审 `aa678a8..HEAD`（05-31 复审修复、UI design system、shop/wheel polish、spawn clearance fix/test）。
- 旧的高风险项多数已闭环：bot cleanup、Shop upgrade 服务器路径、match history start time、deploy dirty-source fail-fast、main-menu compression、spawn clearance 相关验证均通过。
- 没发现新的 P0/P1 线上玩法破坏；但还有 3 个会影响测试门禁或玩家经济/UI 可信度的 P2 问题。

### [P2] `run_boot_test.sh` 的 macOS CA whitelist 仍会让 `run_quick.sh` 失败
**文件**：`tests/run_boot_test.sh:30`

**问题**：本轮 `HOME=/private/tmp/godot-home bash tests/run_quick.sh` 仍是 9 passed / 1 failed，唯一失败仍是 `boot_test`。当前 filter 只排除了包含 `certificat|get_system_ca` 的行，但 Godot/macOS 输出是两行：第一行 `ERROR: Condition "ret != noErr"...` 没有 certificate 关键字，第二行才是 `get_system_ca_certificates`，所以第 30 行的 grep 仍把第一行当项目错误。

**为什么重要**：这会让轻量门禁继续红灯，后续 reviewer/CI 仍要人工判断“项目坏了还是 macOS 证书噪声”。旧 finding 标成已修，但实际没有闭环。

**建议**：不要逐行 grep 后再丢 certificate 行；改成上下文过滤，例如 `grep -B1 get_system_ca_certificates` 一起豁免前一行，或先只匹配项目级错误（`SCRIPT ERROR|Parse Error|Failed to load script|Node not found`）。保留真正 `ERROR` 覆盖时，需要显式排除这组两行 macOS CA 事件。

### [P2] 线上 wheel 没同步 server cooldown，UI 会反复显示可免费/付费 spin 但服务器只拒绝
**文件**：`client/scripts/persistence/settings.gd:230`、`client/scripts/persistence/settings.gd:440`、`client/scripts/ui/shop.gd:522`、`client/scripts/ui/shop.gd:526`、`server/scripts/profile_service.gd:386`

**问题**：服务器 profile 已下发 `last_free_spin_ms`，但 `Settings._apply_server_profile()` 只留了注释，没有保存这个字段；`has_free_spin_today()` 仍只看本地 `last_free_spin_iso`。线上 `Shop` 又根据 `has_free_spin_today()` 显示 `FREE SPIN` 或 `$100` paid spin，但 `ProfileService._on_spin_wheel()` 对 24h 内的第二次请求只 `_ack("spin", false, "wait N hours")`，没有任何 paid-spin 扣费路径，`NetProtocol.WHEEL_PAID_COST` 也没有被服务端使用。

**为什么重要**：玩家在线抽完一次后，客户端可能继续显示可抽/付费抽；点击只会服务器拒绝，像是按钮坏了或经济扣费规则不一致。Shop 里 `_show_wheel_reward()` 还会重新 enable 按钮，进一步放大重复点击/重复拒绝。

**建议**：在 Settings 增加 `last_free_spin_ms` 并从 server profile 写入；线上 `has_free_spin_today()` 应按服务器 wall-clock cooldown 判断，或由 profile 直接下发 `can_free_spin_at_ms`。同时二选一：如果要 paid spin，RPC 需要携带 paid/free 意图，服务端在 cooldown 内扣 `NetProtocol.WHEEL_PAID_COST` 后发奖；如果不要 paid spin，移除 `$100` 文案和 `WHEEL_PAID_COST` 暗示，按钮在 cooldown 内禁用并显示剩余时间。

### [P2] 自定义 loadout 默认值仍和运行时默认不一致
**文件**：`client/scripts/game_controller.gd:21`、`client/scripts/ui/main_menu.gd:1011`、`client/scripts/ui/main_menu.gd:1434`、`client/scripts/ui/main_menu.gd:1468`

**问题**：运行时 `DEFAULT_LOADOUT` 是 `[AK20, SG8, SRX, RAILGUN]`，Loadout picker 文案也写 `AK20 · SG8 · SRX · RAILGUN`；但自定义编辑器打开无保存值时、以及 Reset 时都使用 `["ak20", "sg8", "srx", "grenade"]`。

**为什么重要**：玩家点“默认 / reset”在不同入口拿到不同第 4 槽：实际默认是 railgun，编辑器默认是 grenade。保存后还会把原本的默认覆盖为自定义 grenade 版本，造成菜单文案、持久化设置、实战装备互相打架。

**建议**：把默认 loadout ID 提成一个共享常量（至少在 `main_menu.gd` 内统一数组），并与 `GameController.DEFAULT_LOADOUT` 对齐为 railgun；或者如果产品决定默认第 4 槽就是 grenade，就同时改 `DEFAULT_LOADOUT` 和 picker 文案。

### [x] 已修复（2026-06-03，Claude）—— 与 06-02 批次为同名重复项，已一并修复，详见上方 06-02 批次的「已修复」段。

### 验证

- `HOME=/private/tmp/godot-home bash tests/run_quick.sh`
  - 9 passed / 1 failed in 12s
  - 唯一失败：`boot_test` 仍误报 macOS `get_system_ca_certificates` 前一行 `ERROR`
  - `smoke_test` 全量 parse 通过，未见旧 `NetProtocol` 编译错误
- `HOME=/private/tmp/godot-home bash tests/run_main_menu_compression_test.sh` PASS（LeftCard min 816 < 860）
- `HOME=/private/tmp/godot-home /Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/longmao/projects/godot-pvp tests/spawn_clearance_test.tscn` PASS（8 maps）
- `HOME=/private/tmp/godot-home bash tests/run_database_test.sh` PASS（13/13）
- `HOME=/private/tmp/godot-home bash tests/run_room_manager_test.sh` PASS
- `HOME=/private/tmp/godot-home bash tests/run_room_world_test.sh` PASS
- `HOME=/private/tmp/godot-home bash tests/run_replay_player_test.sh` PASS
- `HOME=/private/tmp/godot-home bash tests/run_bot_map_engage_test.sh` PASS（4 maps）

### 推荐下一步

1. 先修 boot-test whitelist，让 `run_quick.sh` 恢复可信绿灯。
2. 明确线上 wheel 规则：支持 paid spin 就补服务器扣费路径；不支持就移除客户端 paid/free 错误文案。
3. 统一默认 loadout 第 4 槽，避免保存/Reset 把 railgun 默认悄悄改成 grenade。

---

## 2026-05-31 02:02 +08 — Codex

**摘要**

- 本轮复审当前 `HEAD`（最近变更集中在 web perf/deploy、NetProtocol 冷启动编译、replay fire bit、DB/profile hardening、bot/rematch 房间流）。
- `smoke_test` 本轮没有再出现旧的裸 `NetProtocol` 编译错误，说明 2026-05-30 的 false-green 根因修复已基本生效。
- 仍有几处会直接影响线上玩法/运营可信度：MP bot rematch 状态泄漏、Shop 升级仍绕过服务器、match history 开始时间恒为 0、deploy 可以导出脏代码但不提交对应源码。

### [x] [P1] MP bots 被加入 `room.players` 后没有在 match teardown 清理，rematch 会累积旧 bot
**文件**：`client/scripts/game_controller.gd:1849`、`client/scripts/game_controller.gd:1882`、`client/scripts/game_controller.gd:1888`、`client/scripts/game_controller.gd:1891`、`client/scripts/game_controller.gd:2111`  
**关联文件**：`server/scripts/room_manager.gd:362`、`server/scripts/room.gd:23`

**问题**：`_spawn_room_bots()` 给每个 bot 分配负 peer id，并写入 `bots`、`players_by_peer`、`RoomManager.peer_to_room`，还把 bot id 直接 append 到 `room.players`。但 `_tear_down_match_world()` 只把 `RoomWorld` 下的 children reparent 回全局 `players_root`，没有删除这些 bot，也没有从 `room.players` / `peer_to_room` / `players_by_peer` / `bots` 中清掉负 peer id。`RoomManager.end_match()` 也只清 ready 和 K/D，没有剔除 bot。

**为什么重要**：一局结束回 lobby 后，旧 bot 仍是活的 `PlayerController`，还在 `room.players` 里。下一次 START 会把旧 bot 当成房间成员一起 respawn/reparent，然后 `_spawn_room_bots()` 再追加一批新 bot。结果是 lobby 人数/scoreboard 会污染、rematch bot 数量逐轮增长，甚至 bot 可能在 lobby 间隙继续 tick/攻击服务器侧玩家。

**建议**：给 bot id 建立房间级 ownership。match teardown 时遍历该 room 的负 peer id：`queue_free()` bot、从 `players_by_peer` / `bots` / `peer_to_room` / `room.players` / `room.profiles` / K/D 中删除。更干净的做法是新增 `Room.add_bot/remove_bot` 或让 RoomManager 暴露专门的 synthetic-peer cleanup API，避免 GameController 直接改 RoomManager 内部字典。

### [x] [P1] Shop 升级按钮仍走本地 `bump_upgrade()`，线上升级不会持久到服务器
**文件**：`client/scripts/ui/shop.gd:580`、`client/scripts/ui/shop.gd:584`、`client/scripts/ui/shop.gd:586`、`client/scripts/ui/shop.gd:588`  
**关联文件**：`client/scripts/persistence/settings.gd:301`、`client/scripts/persistence/settings.gd:422`、`server/scripts/profile_service.gd:341`

**问题**：Shop 的 Upgrades tab 仍显示 `lvl %d/3` 和本地 30/60/120 cost，并在点击时直接调用 `s.bump_upgrade(...)`。这条路径只改 `Settings` 本地 ConfigFile；线上应走 `Settings.request_apply_upgrade()` → `NetRpc.client_apply_upgrade` → `ProfileService._on_apply_upgrade()`。服务端规则目前是 0..10 级、每级 5 fragments，与 Shop UI/本地逻辑也不一致。

**为什么重要**：在线玩家点升级时会看到本地资源/等级变化，但下一次 `server_profile` 会把它覆盖回服务器旧状态。更糟的是 UI 展示的经济规则和服务端真实规则不同，玩家会以为被扣错/升级丢失。

**建议**：Shop 在线模式下按钮调用 `request_apply_upgrade(weapon_id, stat, lvl + 1)`，等待 `server_action("upgrade", ...)` 和后续 profile push 刷新 UI；同时把 UI 的 max level/cost 文案改成读取服务端共享常量，或先把服务端规则回调成 3 级 30/60/120，避免规则漂移。离线路径如需保留，再显式分支调用 `bump_upgrade()`。

### [x] [P1] `match_history.started_ms` 仍然硬写 0，赛后记录无法按真实开局时间审计
**文件**：`client/scripts/game_controller.gd:1704`、`client/scripts/game_controller.gd:1705`  
**关联文件**：`server/scripts/database.gd:149`、`server/scripts/profile_service.gd:664`、`server/scripts/room_manager.gd:345`

**问题**：DS match end 写库时调用 `record_match_end(..., 0, ended_ms, ...)`，所以 `match_history.started_ms` 永远是 0。Room 只有 `created_at_ms`，没有“本局真正开始”的时间戳；`start_match()` 也没有保存 match start ms。

**为什么重要**：后续 replay、反作弊、留存/时长统计都会依赖 match history。开始时间为 1970/0 会让排序、区间查询、单局时长、异常局审计全部失真。

**建议**：在 `Room` 上新增 `match_started_ms`，在 `RoomManager.start_match()` 用 `Time.get_unix_time_from_system() * 1000` 写入；`GameController._on_match_ended()` 传该字段给 `ProfileService.record_match_end()`。`created_at_ms` 是进程 tick，不适合直接入库做 wall-clock history。

### [x] [P2] `deploy.sh` 会检测到脏源码并重新 export，但 commit 阶段只 stage 少数文件
**文件**：`deploy.sh:90`、`deploy.sh:104`、`deploy.sh:113`、`deploy.sh:224`

**问题**：脚本用 `SRC_PATHS` 检测 `client/server/shared/assets/...` 的未提交改动，并会基于这些脏源码重新导出 web build。但后面的 `git add` 只 stage `export_presets.cfg server.json .gitignore client/scripts/build_info.gd`，不会提交实际源码改动。

**为什么重要**：如果开发者带着未提交的 gameplay/server 改动跑 deploy，web `docs/` 可能来自脏工作树并被 rsync 到 VPS；但 `git push` 不包含对应源码，VPS `git pull` 后的 dedicated server 仍是旧代码。结果是 web client 和 DS 代码版本不一致，尤其 RPC schema / weapon logic / map data 改动会变成线上难查的客户端-服务器错版。

**建议**：二选一：要么 `git add "${SRC_PATHS[@]}"`（排除 `docs/`、`.godot/` 和不应提交的生成物）并真实提交源码；要么在发现 `DIRTY` 时 fail fast，要求先手动提交。不要允许“脏源码 export + 干净源码 push”的半部署。

### [x] [P2] 轻量测试还有环境/断言噪声，容易掩盖真实结果
**文件**：`tests/run_boot_test.sh:1`、`tests/run_input_rpc_test.sh:22`、`tests/main_menu_compression_test.gd:1`

**问题**：`run_quick.sh` 本轮 9 过 1 失败，唯一失败是 `boot_test` 把 macOS Godot 的 `get_system_ca_certificates` stderr 当成项目错误。`run_input_rpc_test.sh` 本轮因固定端口 9102 bind 失败而缺少 spawn/final 日志，属于环境占用，不是输入管线结论。`main_menu_compression_test` 仍真实失败：LeftCard min height 906 > budget 860。

**为什么重要**：现在 reviewer/CI 看到红灯需要人工判断“是项目回归、环境噪声、还是真实 UI 回归”。这会降低后续测试门禁的信任度，尤其在多人并发跑 DS 测试时固定端口碰撞会反复出现。

**建议**：`boot_test` 对这条 macOS CA stderr 做平台限定豁免，或只 grep `SCRIPT ERROR|Parse Error|Failed to load script` 这类项目错误。DS 多进程测试改为动态端口或先探测空闲端口。`main_menu_compression` 按测试要求压缩 LeftCard 内容高度，或显式调整预算/滚动契约。

### 验证

- `HOME=/private/tmp/godot-home bash tests/run_quick.sh`
  - 9 passed / 1 failed in 13s
  - `smoke_test` PASS，未见旧的 `Identifier not found: NetProtocol` 编译错误
  - `boot_test` FAIL，仅因 macOS `get_system_ca_certificates` stderr 被 grep 为 error
- `HOME=/private/tmp/godot-home bash tests/run_database_test.sh` PASS（13/13）
- `HOME=/private/tmp/godot-home bash tests/run_replay_player_test.sh` PASS（fire bit 统计为 2 fires）
- `HOME=/private/tmp/godot-home bash tests/run_bot_map_engage_test.sh` PASS（4 maps checked）
- `HOME=/private/tmp/godot-home bash tests/run_room_manager_test.sh` PASS
- `HOME=/private/tmp/godot-home bash tests/run_main_menu_compression_test.sh` FAIL（LeftCard min height 906 > 860）
- `HOME=/private/tmp/godot-home bash tests/run_input_rpc_test.sh` inconclusive：server failed to bind fixed port 9102, client could not connect

### 推荐下一步

1. 先修 MP bot cleanup，否则 rematch 越打越脏，且会污染 lobby state / scoreboard。
2. 把 Shop Upgrades tab 接回服务器 RPC，并统一升级规则。
3. 修 deploy 的脏源码提交策略，避免 web/client 与 DS 线上错版。
4. 清理测试噪声：macOS CA stderr whitelist、动态端口、main menu 高度回归。

---

### [x] 已修复（2026-05-31，Claude）— 5 项全部处理 + 实测

**P1-1 MP bot rematch 泄漏** — 根因:`_spawn_room_bots` 把 bot(合成负 peer id)写进
`bots[]`/`players_by_peer`/`peer_to_room`/`room.players`,但 `_tear_down_match_world`
只 reparent 人类 + free RoomWorld,四个注册表的 bot id 全没清 → rematch 累积。
修:新增 `RoomManager.remove_bot()`(清 peer_to_room + room.players/profiles/K-D)+
`GameController._cleanup_room_bots()`(清 players_by_peer/bots[] + free 节点 + 调
remove_bot),在 `_tear_down_match_world` free rw **之前**调,server-only。
验:run_all 的 room_manager/room_rpc/concurrent_match/rematch_reject/room_world 全过。

**P1-2 Shop 升级走本地不持久 + 规则漂移** — 根因:Shop Upgrades tab 显示 /3 +
[30,60,120]、点击走本地 `bump_upgrade`;但服务端是 0..10 级 + 5 碎片/级,且 NetProtocol
常量(3/[30,60,120])无人用=死常量。修:① NetProtocol 常量改成真实规则
(`MAX_UPGRADE_LEVELS_PER_WEAPON=10`、`UPGRADE_COST_PER_LEVEL=5`)当唯一来源;
② settings.bump_upgrade(离线)+ profile_service._on_apply_upgrade(服务端)+ shop UI
全部读这俩常量;③ shop 升级按钮在线走 `request_apply_upgrade` RPC、离线才 fallback
`bump_upgrade`(和 weapons_dialog_builder 主菜单图鉴一致)。改了 net_protocol /
settings / shop / profile_service 四处。

**P1-3 match_history.started_ms 硬写 0** — 修:Room 加 `match_started_ms` 字段,
`RoomManager.start_match()` 用 `Time.get_unix_time_from_system()*1000` 写入,
`GameController._on_match_ended` 传它给 `record_match_end`(原来硬写 0)。验:database
13/13(含 match history)过。

**P2-4 deploy.sh 脏源码 export 但不提交** — 改 `deploy.sh` step 2b:有未提交的
**会进 DS 的源码**(client/server/shared/addons/project.godot,排除 build_info.gd /
*.uid / 纯 web 的 assets / 自动提交的 config)就 **fail-fast 拒绝部署**。不选 auto-`git
add`(多 session 共用工作树会扫进别 session 的在途文件)。

**P2-5 测试噪声(3 子项)**:
- boot_test:grep 排除 macOS `get_system_ca_certificates` / certificate 平台噪声
  (保留 @onready Node-not-found 等真错覆盖)。
- input_rpc:固定端口 9102/9103 → 随机高位端口(消除 bind 冲突,现在能 conclusive 跑)。
- main_menu_compression:LeftCard 906 压到 **844 < 860**(V separation 5→4、logo
  84→52、FunFact 32→26;不删任何按钮/功能)。run_all 现已 PASS。

**回归**:`bash tests/run_all.sh` → **48 pass / 1 fail**(对比修复前 47/49:净修好了
main_menu_compression)。

**唯一残留 — input_rpc_test forward 子测试(根因已坐实,非生产 bug,非本轮引入)**:
端口修复后能 conclusive 跑了,但 forward 仍 `dz=0.088`。查 DS 日志:player spawn 在
(0,1,0) 后 **Y 恒为 1.000**(连重力都没落)→ 它的 `_step_movement` 根本没跑。根因:
input_rpc 用「裸 peer 不 join room」的 **legacy 路径**,roomless player 进全局
`players_root`,不在 room_world 的物理世界 → 不被模拟。房间重构(F3-M*)后真实客户端
都 join room,**这条 legacy 路径已死**;真实输入→移动由 two_client / three_client /
real_aim(全过)覆盖。**这是过时测试,不是生产 bug。已按用户决定退役**:从
`tests/run_all.sh` 的 specs 移除,`run_input_rpc_test.sh` 加 RETIRED 横幅 + 早退 0
(harness `headless_input_client.gd` 保留,供日后改成 room-flow 测试复活)。退役后
**run_all = 48/48 全绿**。详见 test.md 同日。

> **归档**：2026-05-30 及更早的已闭环 review 已移至
> `.agent/codexreview-archive/resolved-2026-05.md`（1612 行，全部 [x]/已解决）。
> 本文件只保留**当前开放**项。
