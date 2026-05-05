#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CXX="${CXX:-g++}"
CXXFLAGS="-std=c++17 -Wall -Wextra -O0 -g"
INCLUDES="-I $REPO_ROOT -I $REPO_ROOT/third_party"

run() {
    local name="$1"; shift
    local out="$SCRIPT_DIR/$name.bin"
    echo "[build] $name"
    $CXX $CXXFLAGS $INCLUDES "$@" -o "$out"
    echo "[run]   $name"
    "$out"
}

run test_clock    "$SCRIPT_DIR/test_clock.cpp"
run test_link     "$SCRIPT_DIR/test_link.cpp"     "$REPO_ROOT/core/link/LinkModel.cpp"
run test_eventlog "$SCRIPT_DIR/test_eventlog.cpp" "$REPO_ROOT/core/events/EventLog.cpp"
run test_simradio "$SCRIPT_DIR/test_simradio.cpp" "$REPO_ROOT/core/radio/SimRadio.cpp"
run test_physics  "$SCRIPT_DIR/test_physics.cpp"  \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp"

echo "[ok] all tests passed"
