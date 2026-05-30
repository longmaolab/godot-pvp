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

## 2026-05-31 02:02 +08 — Codex

**摘要**

- 本轮复审当前 `HEAD`（最近变更集中在 web perf/deploy、NetProtocol 冷启动编译、replay fire bit、DB/profile hardening、bot/rematch 房间流）。
- `smoke_test` 本轮没有再出现旧的裸 `NetProtocol` 编译错误，说明 2026-05-30 的 false-green 根因修复已基本生效。
- 仍有几处会直接影响线上玩法/运营可信度：MP bot rematch 状态泄漏、Shop 升级仍绕过服务器、match history 开始时间恒为 0、deploy 可以导出脏代码但不提交对应源码。

### [P1] MP bots 被加入 `room.players` 后没有在 match teardown 清理，rematch 会累积旧 bot
**文件**：`client/scripts/game_controller.gd:1849`、`client/scripts/game_controller.gd:1882`、`client/scripts/game_controller.gd:1888`、`client/scripts/game_controller.gd:1891`、`client/scripts/game_controller.gd:2111`  
**关联文件**：`server/scripts/room_manager.gd:362`、`server/scripts/room.gd:23`

**问题**：`_spawn_room_bots()` 给每个 bot 分配负 peer id，并写入 `bots`、`players_by_peer`、`RoomManager.peer_to_room`，还把 bot id 直接 append 到 `room.players`。但 `_tear_down_match_world()` 只把 `RoomWorld` 下的 children reparent 回全局 `players_root`，没有删除这些 bot，也没有从 `room.players` / `peer_to_room` / `players_by_peer` / `bots` 中清掉负 peer id。`RoomManager.end_match()` 也只清 ready 和 K/D，没有剔除 bot。

**为什么重要**：一局结束回 lobby 后，旧 bot 仍是活的 `PlayerController`，还在 `room.players` 里。下一次 START 会把旧 bot 当成房间成员一起 respawn/reparent，然后 `_spawn_room_bots()` 再追加一批新 bot。结果是 lobby 人数/scoreboard 会污染、rematch bot 数量逐轮增长，甚至 bot 可能在 lobby 间隙继续 tick/攻击服务器侧玩家。

**建议**：给 bot id 建立房间级 ownership。match teardown 时遍历该 room 的负 peer id：`queue_free()` bot、从 `players_by_peer` / `bots` / `peer_to_room` / `room.players` / `room.profiles` / K/D 中删除。更干净的做法是新增 `Room.add_bot/remove_bot` 或让 RoomManager 暴露专门的 synthetic-peer cleanup API，避免 GameController 直接改 RoomManager 内部字典。

### [P1] Shop 升级按钮仍走本地 `bump_upgrade()`，线上升级不会持久到服务器
**文件**：`client/scripts/ui/shop.gd:580`、`client/scripts/ui/shop.gd:584`、`client/scripts/ui/shop.gd:586`、`client/scripts/ui/shop.gd:588`  
**关联文件**：`client/scripts/persistence/settings.gd:301`、`client/scripts/persistence/settings.gd:422`、`server/scripts/profile_service.gd:341`

**问题**：Shop 的 Upgrades tab 仍显示 `lvl %d/3` 和本地 30/60/120 cost，并在点击时直接调用 `s.bump_upgrade(...)`。这条路径只改 `Settings` 本地 ConfigFile；线上应走 `Settings.request_apply_upgrade()` → `NetRpc.client_apply_upgrade` → `ProfileService._on_apply_upgrade()`。服务端规则目前是 0..10 级、每级 5 fragments，与 Shop UI/本地逻辑也不一致。

**为什么重要**：在线玩家点升级时会看到本地资源/等级变化，但下一次 `server_profile` 会把它覆盖回服务器旧状态。更糟的是 UI 展示的经济规则和服务端真实规则不同，玩家会以为被扣错/升级丢失。

**建议**：Shop 在线模式下按钮调用 `request_apply_upgrade(weapon_id, stat, lvl + 1)`，等待 `server_action("upgrade", ...)` 和后续 profile push 刷新 UI；同时把 UI 的 max level/cost 文案改成读取服务端共享常量，或先把服务端规则回调成 3 级 30/60/120，避免规则漂移。离线路径如需保留，再显式分支调用 `bump_upgrade()`。

### [P1] `match_history.started_ms` 仍然硬写 0，赛后记录无法按真实开局时间审计
**文件**：`client/scripts/game_controller.gd:1704`、`client/scripts/game_controller.gd:1705`  
**关联文件**：`server/scripts/database.gd:149`、`server/scripts/profile_service.gd:664`、`server/scripts/room_manager.gd:345`

**问题**：DS match end 写库时调用 `record_match_end(..., 0, ended_ms, ...)`，所以 `match_history.started_ms` 永远是 0。Room 只有 `created_at_ms`，没有“本局真正开始”的时间戳；`start_match()` 也没有保存 match start ms。

**为什么重要**：后续 replay、反作弊、留存/时长统计都会依赖 match history。开始时间为 1970/0 会让排序、区间查询、单局时长、异常局审计全部失真。

**建议**：在 `Room` 上新增 `match_started_ms`，在 `RoomManager.start_match()` 用 `Time.get_unix_time_from_system() * 1000` 写入；`GameController._on_match_ended()` 传该字段给 `ProfileService.record_match_end()`。`created_at_ms` 是进程 tick，不适合直接入库做 wall-clock history。

### [P2] `deploy.sh` 会检测到脏源码并重新 export，但 commit 阶段只 stage 少数文件
**文件**：`deploy.sh:90`、`deploy.sh:104`、`deploy.sh:113`、`deploy.sh:224`

**问题**：脚本用 `SRC_PATHS` 检测 `client/server/shared/assets/...` 的未提交改动，并会基于这些脏源码重新导出 web build。但后面的 `git add` 只 stage `export_presets.cfg server.json .gitignore client/scripts/build_info.gd`，不会提交实际源码改动。

**为什么重要**：如果开发者带着未提交的 gameplay/server 改动跑 deploy，web `docs/` 可能来自脏工作树并被 rsync 到 VPS；但 `git push` 不包含对应源码，VPS `git pull` 后的 dedicated server 仍是旧代码。结果是 web client 和 DS 代码版本不一致，尤其 RPC schema / weapon logic / map data 改动会变成线上难查的客户端-服务器错版。

**建议**：二选一：要么 `git add "${SRC_PATHS[@]}"`（排除 `docs/`、`.godot/` 和不应提交的生成物）并真实提交源码；要么在发现 `DIRTY` 时 fail fast，要求先手动提交。不要允许“脏源码 export + 干净源码 push”的半部署。

### [P2] 轻量测试还有环境/断言噪声，容易掩盖真实结果
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

> **归档**：2026-05-30 及更早的已闭环 review 已移至
> `.agent/codexreview-archive/resolved-2026-05.md`（1612 行，全部 [x]/已解决）。
> 本文件只保留**当前开放**项。

