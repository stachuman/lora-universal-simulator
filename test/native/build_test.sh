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

# Like run(), but passes a single positional argument to the test binary.
# Useful for tests that take a config/data path.
test_with_arg() {
    local name="$1"; shift
    local arg="$1"; shift
    local out="$SCRIPT_DIR/$name.bin"
    echo "[build] $name"
    $CXX $CXXFLAGS $INCLUDES "$@" -o "$out"
    echo "[run]   $name $arg"
    "$out" "$arg"
}

run test_clock    "$SCRIPT_DIR/test_clock.cpp"
run test_link     "$SCRIPT_DIR/test_link.cpp"     "$REPO_ROOT/core/link/LinkModel.cpp"
run test_eventlog "$SCRIPT_DIR/test_eventlog.cpp" "$REPO_ROOT/core/events/EventLog.cpp"
run test_simradio "$SCRIPT_DIR/test_simradio.cpp" "$REPO_ROOT/core/radio/SimRadio.cpp"
run test_physics  "$SCRIPT_DIR/test_physics.cpp"  \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp"

run test_cross_sf_orthogonality "$SCRIPT_DIR/test_cross_sf_orthogonality.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp"

test_with_arg test_jsonconfig "$SCRIPT_DIR/sample_config.json" \
    "$SCRIPT_DIR/test_jsonconfig.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp"

run test_timerwheel "$SCRIPT_DIR/test_timerwheel.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp"

LUA_CFLAGS="$(pkg-config --cflags lua5.4)"
LUA_LIBS="$(pkg-config --libs lua5.4)"

run test_sim_controller "$SCRIPT_DIR/test_sim_controller.cpp" \
    "$REPO_ROOT/orchestrator/runtime/SimController.cpp" \
    "$REPO_ROOT/orchestrator/runtime/LuaHost.cpp" \
    "$REPO_ROOT/orchestrator/runtime/ScriptedNode.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp" \
    "$REPO_ROOT/orchestrator/test_runner/ExpectRunner.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp" \
    "$REPO_ROOT/core/link/LinkModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/events/EventLog.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp" \
    $LUA_CFLAGS $LUA_LIBS

echo "[ok] all tests passed"
