# Read-only log endpoint for daily Routine smoke

Lets a Claude Code Routine running in Anthropic's cloud fetch the last 24h
of `godot-pvp-game` logs without us shipping an SSH key out there. Pairs
with the daily HTTP smoke routine described in `.agent/test.md`.

```
┌─────────┐    GET /godot-pvp/_logs              ┌──────────┐
│ Routine │ ───── Authorization: Bearer XXX ───▶ │  Caddy   │
└─────────┘                                       └────┬─────┘
                                                       │ reverse_proxy
                                                       ▼
                                                ┌──────────────┐
                                                │ Python server│
                                                │   :7779      │ ──▶  journalctl -u godot-pvp-game --since 24h
                                                └──────────────┘
```

## One-time VPS setup (`ssh root@207.148.98.206`)

```bash
# 1. Pull latest repo to /opt/games/godot-pvp (you already do this in ./deploy.sh).

# 2. Generate the token; keep a copy locally — you'll paste it into the
#    Routine config in Anthropic's web UI later.
TOKEN=$(openssl rand -hex 32)
echo "$TOKEN"                                                # save this somewhere safe

# 3. Install the systemd unit and set the token.
cp /opt/games/godot-pvp/ops/log_endpoint/godot-pvp-logs.service \
   /etc/systemd/system/godot-pvp-logs.service
sed -i "s|PASTE_TOKEN_HERE|$TOKEN|" /etc/systemd/system/godot-pvp-logs.service
systemctl daemon-reload
systemctl enable --now godot-pvp-logs
systemctl status godot-pvp-logs                              # should be active (running)

# 4. Add the Caddy route. Edit /etc/caddy/Caddyfile; inside the
#    `game.boobank.com { ... }` block insert the snippet from
#    ops/log_endpoint/caddy-snippet.conf BEFORE the existing
#    `handle_path /godot-pvp/*` block.
nano /etc/caddy/Caddyfile

# 5. Restart Caddy (NOT reload — Caddyfile has `admin off`, reload always fails).
systemctl restart caddy
systemctl is-active caddy                                    # active

# 6. Smoke from your laptop:
curl -H "Authorization: Bearer $TOKEN" https://game.boobank.com/godot-pvp/_logs | head -50
# Should print recent journalctl lines. With a wrong token: "unauthorized".
```

## Token rotation

Bad token? Generate a new one and update both sides:

```bash
NEW_TOKEN=$(openssl rand -hex 32)
sed -i "s|LOG_TOKEN=.*|LOG_TOKEN=$NEW_TOKEN|" /etc/systemd/system/godot-pvp-logs.service
systemctl daemon-reload && systemctl restart godot-pvp-logs
```

Then update the routine config at https://claude.ai/code/routines (replace
the `LOG_TOKEN` env var or whatever the Routine uses).

## Security notes

- 256-bit random token. Compare via `secrets.compare_digest` to defeat
  timing attacks.
- Endpoint binds to `127.0.0.1` so only Caddy can reach it. Don't `ufw
  allow 7779` — Caddy is the only legit caller.
- Read-only by design: no path traversal, no parameter injection, no
  shell-out beyond a fixed `journalctl` argv.
- Rate limit at Caddy if you ever expose this beyond the routine:
  ```
  handle /godot-pvp/_logs {
      rate_limit { zone logs { window 60s events 30 } }
      reverse_proxy localhost:7779
  }
  ```
  (Needs `xcaddy build` with `caddyserver/rate-limit` — skip unless
  there's evidence of abuse.)
- Logs may contain peer-id / IP fragments from `journalctl` — that's
  the same info `journalctl -u godot-pvp-game` shows to anyone with SSH.
  Equivalent risk surface, narrower attack surface.

## Why HTTP, not SSH

Routines run in Anthropic's cloud and don't carry your `~/.ssh/id_rsa`.
Setting up SSH would either need:
- Ship a private key into the Routine config (bad — anyone with read
  access to the routine can SSH in)
- A second host that does have the key and proxies SSH commands (over-
  engineered for what's basically `journalctl | grep ERROR`)

HTTP + bearer token is the smallest thing that works.
