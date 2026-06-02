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
# macOS Godot's TLS/CA-cert stderr. That event is TWO lines and the keyword
# only lands on the SECOND one:
#     ERROR: Condition "ret != noErr" is true. Returning: ""
#        at: get_system_ca_certificates (...)
# A per-line keyword filter (the old `grep -v certificat`) drops the `at:`
# line but keeps the generic `ERROR:` line above it, so the gate stayed red
# (codexreview 05-31/06-01/06-02). Filter by CONTEXT instead: buffer each
# candidate error line and discard it if the very next line is the CA frame.
# Real project errors (@onready "Node not found", SCRIPT ERROR, Parse Error)
# are never followed by that frame, so their coverage is intact.
ERRS="$(awk '
    buffered != "" {
        if ($0 ~ /get_system_ca_certificates/ || $0 ~ /certificat/) {
            buffered = ""          # drop the macOS CA 2-line event
        } else {
            print buffered         # real error, its follow-up is unrelated
            buffered = ""
        }
    }
    /ERROR:|Parse Error|SCRIPT ERROR|Failed to/ {
        if ($0 ~ /certificat|get_system_ca/) next   # single-line CA noise
        buffered = $0
        next
    }
    END { if (buffered != "") print buffered }
' "$LOG")"
if [ -n "$ERRS" ]; then
    echo "FAIL — error lines detected:"
    echo "$ERRS" | head -20
    ok=false
fi

if $ok; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
