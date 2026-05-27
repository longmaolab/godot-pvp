#!/usr/bin/env python3
"""Tiny token-gated HTTP log endpoint.

Runs on localhost:7779 (behind Caddy). On GET / with the right
`Authorization: Bearer <token>` header, runs `journalctl -u godot-pvp-game
--since "24 hours ago"` and streams the output. Anything else → 401.

Why this exists: a Routine in Anthropic's cloud can't SSH into the VPS
without us shipping a private key out there. Instead the VPS exposes a
read-only HTTP view of the game's logs, gated by a 256-bit token. The
Routine curls it once a day, greps for ERROR / stack traces / OOM.

NOT meant to be reached from the public internet directly. Caddy is the
only reverse-proxy that should hit 127.0.0.1:7779.
"""
import http.server
import os
import subprocess
import sys

TOKEN = os.environ.get("LOG_TOKEN", "").strip()
if not TOKEN or len(TOKEN) < 32:
    print("LOG_TOKEN env var required (>=32 chars)", file=sys.stderr)
    sys.exit(1)

UNIT = os.environ.get("LOG_UNIT", "godot-pvp-game")
SINCE = os.environ.get("LOG_SINCE", "24 hours ago")
PORT = int(os.environ.get("LOG_PORT", "7779"))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Constant-time-ish token comparison via secrets.compare_digest
        import secrets
        sent = self.headers.get("Authorization", "")
        expected = "Bearer " + TOKEN
        if not secrets.compare_digest(sent, expected):
            self.send_response(401)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"unauthorized\n")
            return
        try:
            r = subprocess.run(
                ["journalctl", "-u", UNIT, "--since", SINCE, "--no-pager"],
                capture_output=True, text=True, timeout=30,
            )
        except subprocess.TimeoutExpired:
            self.send_response(504)
            self.end_headers()
            self.wfile.write(b"journalctl timed out\n")
            return
        body = r.stdout.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Quiet — systemd journal will capture stderr; we don't want
        # every request flooding /var/log.
        pass


def main():
    addr = ("127.0.0.1", PORT)
    httpd = http.server.HTTPServer(addr, Handler)
    print(f"log endpoint listening on {addr[0]}:{addr[1]} for unit={UNIT}", file=sys.stderr)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
