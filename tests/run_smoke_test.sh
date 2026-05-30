#!/usr/bin/env bash
# smoke_test.gd uses load_threaded status, which only proves "the loader
# returned something", not "the script compiled cleanly". A compile error
# (`SCRIPT ERROR: Compile Error: ...`) still prints to stdout while the test
# returns PASS. This wrapper greps the engine-side error patterns and turns
# them into hard fails.
#
# There is NO whitelist. Earlier this wrapper excluded "Identifier not found:
# NetProtocol/NetRpc/..." because those autoload globals don't resolve under
# `--script` (no autoloads loaded). That root cause is fixed: every script that
# referenced an autoload global at compile time now reaches it via an explicit
# `const X = preload(...)` class reference (and is_dedicated_server_boot() is
# static), so they all compile clean standalone. With the false positives gone,
# ANY engine compile error here is a real regression — including a genuine typo
# in a file the old whitelist would have masked.

set -u
GODOT="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJ/tests/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/smoke.log"

"$GODOT" --headless --path "$PROJ" --script tests/smoke_test.gd \
	>"$LOG" 2>&1
GODOT_EXIT=$?

# Smoke test's own PASS line.
SMOKE_PASS=0
if grep -q "=== result: PASS" "$LOG"; then
	SMOKE_PASS=1
fi

# Any engine-level script-load failure is a hard fail — no exclusions.
ENGINE_ERRORS=$(grep -E "SCRIPT ERROR|Parse Error|Failed to load script|Invalid assignment of property" "$LOG" \
	| wc -l | tr -d ' ')

echo "--- log tail ---"
tail -25 "$LOG"
echo "--- result ---"
echo "godot exit: $GODOT_EXIT  smoke PASS line: $SMOKE_PASS  engine script-errors: $ENGINE_ERRORS"

if [ "$SMOKE_PASS" -ne 1 ]; then
	echo "FAIL — smoke_test.gd did not print PASS"
	exit 1
fi
if [ "$ENGINE_ERRORS" -gt 0 ]; then
	echo "FAIL — engine reported $ENGINE_ERRORS script-load error(s) (see log)"
	grep -nE "SCRIPT ERROR|Parse Error|Failed to load script|Invalid assignment of property" "$LOG" | head -10
	exit 1
fi
echo "PASS"
exit 0
