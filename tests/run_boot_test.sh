#!/usr/bin/env bash
# Boots the actual main scene (main_menu.tscn) for a few seconds with FULL
# stderr captured. Surfaces runtime errors that pure-parse smoke tests miss:
# bad @onready node paths, autoload init failures, _ready() crashes, etc.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/boot.log"

echo "=== boot test (main_menu.tscn for 3s, watching stderr) ==="
"$GODOT" --headless --path "$PROJ" --quit-after 180 >"$LOG" 2>&1
RC=$?

echo "--- last 30 lines of boot output ---"
tail -30 "$LOG"
echo "--- result ---"

ok=true
if [ "$RC" -ne 0 ]; then
    echo "godot exit code: $RC (want 0)"; ok=false
fi
# Any "ERROR" / "SCRIPT ERROR" / "Parse Error" lines = real failure — EXCEPT
# macOS Godot's TLS/CA-cert stderr (system cert-store access). That's platform
# noise, never a project bug, and was tripping this gate on some macOS setups
# (codexreview 05-31). Real project errors don't mention certificates, so the
# keyword filter keeps @onready "Node not found" / SCRIPT ERROR coverage intact.
ERRS="$(grep -E "ERROR:|Parse Error|SCRIPT ERROR|Failed to" "$LOG" | grep -viE "certificat|get_system_ca")"
if [ -n "$ERRS" ]; then
    echo "FAIL — error lines detected:"
    echo "$ERRS" | head -20
    ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
