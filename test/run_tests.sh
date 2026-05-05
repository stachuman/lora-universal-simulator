#!/usr/bin/env bash
#
# test/run_tests.sh
#
# Drives `lus` over one or more scenario JSONs and reports PASS/FAIL based
# on the exit code (which is 0 iff zero assertion failures). Mirrors the
# pattern from meshcore_real_sim/test/run_tests.sh.
#
# Usage:
#     bash test/run_tests.sh                          # run every test/t*.json
#     bash test/run_tests.sh test/t01_flooder.json    # run one test
#     BUILD_DIR=/path/to/build bash test/run_tests.sh # custom build dir
#
# Each scenario's NDJSON output goes to test/<name>_events.ndjson so a
# failing run can be inspected without re-running.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
LUS="$BUILD_DIR/orchestrator/lus"

if [ ! -x "$LUS" ]; then
    echo "ERROR: lus binary not found at $LUS"
    echo "Run: cmake --build $BUILD_DIR -j 4"
    exit 1
fi

CONFIGS=("$@")
if [ ${#CONFIGS[@]} -eq 0 ]; then
    while IFS= read -r f; do
        CONFIGS+=("$f")
    done < <(ls "$SCRIPT_DIR"/t*.json 2>/dev/null | sort)
fi

if [ ${#CONFIGS[@]} -eq 0 ]; then
    echo "no test configs found in $SCRIPT_DIR"
    exit 1
fi

passed=0
failed=0
for cfg in "${CONFIGS[@]}"; do
    name="$(basename "$cfg" .json)"
    out="$SCRIPT_DIR/${name}_events.ndjson"
    pad_to=40
    pad=$((pad_to - ${#name}))
    [ "$pad" -lt 1 ] && pad=1
    if "$LUS" "$cfg" "$out" 2>/dev/null; then
        printf "  %s%*sPASS\n" "$name" "$pad" ""
        passed=$((passed + 1))
    else
        printf "  %s%*sFAIL\n" "$name" "$pad" ""
        failed=$((failed + 1))
    fi
done

echo ""
echo "$passed/$((passed + failed)) passed"
[ "$failed" -eq 0 ]
