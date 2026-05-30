# DADABOOM (godot-pvp) — Claude 工作流约定

> 游戏展示名 = **DADABOOM**。代码仓库 / 目录 / 线上 URL / systemd 服务
> 仍用 `godot-pvp` 这个 slug（基础设施未迁移，改 slug 要动 DNS/VPS/tunnel）。
> 玩家看到的标题、窗口名、产品名都是 DADABOOM。


## `.agent/` 三件套

所有跨会话的工作状态放在 `.agent/`，**Claude 每次新对话先扫一遍这三个文件**，不要凭记忆做事：

| 文件 | 谁写 | Claude 做什么 |
|---|---|---|
| `.agent/todo.md` | 用户 + Claude | 按 P0 → P1 → P2 → P3 顺序消化，做完打 `[x]` |
| `.agent/codexreview.md` | 用户贴 Codex review | 按 P 级修代码，每条修完追加「已修复」段说明改了哪些文件 |
| `.agent/test.md` | 用户贴手动实测 bug / 日志 | 找 root cause（不要 pattern-match！），追加「已修复」段写清楚根因 |

**触发词**：用户说「读 test.md」/「读 codexreview.md」/「看 todo」就去 `.agent/` 里找对应文件。

## 修 bug 的硬性要求（来自用户反复强调）

1. **不要盲目加保险机制** —— 找根因，不要套 try/except 把症状盖掉
2. **代码质量要高，自己充分验证** —— 改完跑 `bash tests/run_all.sh`，看 23/24 是不是过（multiplayer_integration 端口冲突可忽略）
3. **不要谎报修好** —— 没复现的 bug 不要说「应该 ok 了」，要么有测试覆盖要么说明用户需要手动验证哪一步
4. **比对 arena-shooter-3d** —— 如果 arena-shooter-3d 没这个问题，那就是这边的 bug，别甩锅给 macOS/Godot

## 项目位置

实际代码在 `~/projects/godot-pvp/`（不是在 pvp-game worktree 里）。

## 测试入口

```bash
cd ~/projects/godot-pvp
bash tests/run_all.sh
```

24 项测试，正常应该 23 pass / 1 fail（multiplayer_integration 因为 7777 端口被用户跑的 Godot 占了）。

## 当前架构状态

- DS-M1 ~ M6 主线已完成（服务器世界 / 输入 RPC / 快照广播 / 权威开火 + lag comp / 死亡重生 / 砍范围）
- Combat juice Round 1 + 2 完成
- 详见 `.agent/todo.md` 的「已完成」段落

## 生产环境（已上线）

| 项 | 值 |
|---|---|
| 公开入口 | https://game.boobank.com/godot-pvp/ |
| WebSocket | wss://game.boobank.com/godot-pvp/ws |
| VPS 路径 | `/opt/games/godot-pvp/` |
| systemd 服务 | `godot-pvp-game.service` |
| DS 端口 | 7778（arena-shooter 占 7777） |
| SSH | `ssh root@207.148.98.206` |

**部署流程**：

```bash
./deploy.sh        # 自动 export web → commit + push → ssh VPS → pull + import + restart
```

`deploy.sh` 改自 arena-shooter-3d,智能跳过未改动的 export 步骤。

**Caddy 注意**：Caddyfile 写了 `admin off`,改配置后必须用 `systemctl restart caddy`,**`systemctl reload caddy` 永远失败**(走 admin API)。

**只看日志 / 重启服务**：

```bash
ssh root@207.148.98.206 'journalctl -u godot-pvp-game -f'
ssh root@207.148.98.206 'systemctl restart godot-pvp-game'
```
