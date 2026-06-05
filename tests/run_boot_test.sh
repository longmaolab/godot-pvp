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
# (codexreview 05-31 / 06-01 / 06-02).
#
# The CA event spans TWO lines, e.g.:
#     ERROR: Condition "ret != noErr" is true. Returning: ""
#        at: get_system_ca_certificates (platform/.../tls_context_mbedtls.cpp:NN)
# The keyword filter only matched the 2nd line, so the bare generic "ERROR:"
# first line still tripped the gate. Drop the whole event by context: an awk
# state machine discards any line whose *next* line names the CA call (the
# error header sitting right above its own "at:" frame), then we still keyword-
# filter the "at:" line itself. This keeps @onready "Node not found" / SCRIPT
# ERROR coverage intact while exempting only the macOS CA two-line event.
CLEAN="$(awk '
    NR > 1 { if ($0 ~ /get_system_ca|certificat/) { hold = ""; next } if (hold != "") print hold }
    { hold = $0 }
    END { if (hold != "") print hold }
' "$LOG")"
ERRS="$(printf "%s\n" "$CLEAN" | grep -E "ERROR:|Parse Error|SCRIPT ERROR|Failed to" | grep -viE "certificat|get_system_ca")"
if [ -n "$ERRS" ]; then
    echo "FAIL — error lines detected:"
    echo "$ERRS" | head -20
    ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
