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
# Wire-format pin for all 11 drop_* emitters (5 of them fire in NO scenario, so
# stream byte-identity proves nothing about them) + the shared-builder overflow
# contract. Guards the dropCommon()/DropLine refactor. The 11th is
# drop_tx_settling (Wave-4 6.1.2, TX->RX turnaround deafness).
run test_eventlog_drops "$SCRIPT_DIR/test_eventlog_drops.cpp" \
    "$REPO_ROOT/core/events/EventLog.cpp"
run test_simradio "$SCRIPT_DIR/test_simradio.cpp" "$REPO_ROOT/core/radio/SimRadio.cpp"
run test_physics  "$SCRIPT_DIR/test_physics.cpp"  \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp"

run test_cross_sf_orthogonality "$SCRIPT_DIR/test_cross_sf_orthogonality.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp"

run test_multi_sf_reception "$SCRIPT_DIR/test_multi_sf_reception.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp"

run test_preamble_override "$SCRIPT_DIR/test_preamble_override.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp"

run test_fading_applied "$SCRIPT_DIR/test_fading_applied.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp"

test_with_arg test_jsonconfig "$SCRIPT_DIR/sample_config.json" \
    "$SCRIPT_DIR/test_jsonconfig.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp"

test_with_arg test_path_loss_config "$SCRIPT_DIR/sample_path_loss.json" \
    "$SCRIPT_DIR/test_path_loss_config.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp"

run test_sf_rx_set_parsing "$SCRIPT_DIR/test_sf_rx_set_parsing.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp"

# Wave 1 (2026-07-20 realism review): bw double-parse, required-key refusal, SF5/6 airtime, tx-power delta.
run test_wave1_config "$SCRIPT_DIR/test_wave1_config.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp"

run test_snr_report_shaping "$SCRIPT_DIR/test_snr_report_shaping.cpp"

# Wave 4 (2026-07-21 realism review) Slice C: per-node/per-link RNG streams.
run test_rng_streams "$SCRIPT_DIR/test_rng_streams.cpp"

# Wave 2a (2026-07-21 realism ruling): metal turnaround/slop defaults + duty percent unit.
run test_wave2_config "$SCRIPT_DIR/test_wave2_config.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp"

run test_timerwheel "$SCRIPT_DIR/test_timerwheel.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp"

run test_path_loss "$SCRIPT_DIR/test_path_loss.cpp" \
    "$REPO_ROOT/core/link/PathLossModel.cpp"

run test_path_loss_asymmetry "$SCRIPT_DIR/test_path_loss_asymmetry.cpp" \
    "$REPO_ROOT/core/link/PathLossModel.cpp"

LUA_CFLAGS="$(pkg-config --cflags lua5.4)"
LUA_LIBS="$(pkg-config --libs lua5.4)"

# Wave 4 (2026-07-20 realism review §6.1.1): BW-mismatch delivery gating.
test_with_arg test_bw_mismatch "$SCRIPT_DIR/test_bw_mismatch.json" \
    "$SCRIPT_DIR/test_bw_mismatch.cpp" \
    "$REPO_ROOT/orchestrator/runtime/SimController.cpp" \
    "$REPO_ROOT/orchestrator/runtime/LuaHost.cpp" \
    "$REPO_ROOT/orchestrator/runtime/ScriptedNode.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp" \
    "$REPO_ROOT/orchestrator/test_runner/ExpectRunner.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp" \
    "$REPO_ROOT/core/link/LinkModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp" \
    "$REPO_ROOT/core/link/PathLossModel.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/events/EventLog.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp" \
    $LUA_CFLAGS $LUA_LIBS

# F-BW-TX (test_bw_tx_follows_retune) was DELETED 2026-07-25 by owner ruling: the
# dual-BW gateway probe carries that proof instead, and the test drove its retune
# through the now-deprecated Lua engine.

# ★ The deprecated-Lua contract (2026-07-25 ruling): default engine "meshroute",
# a "lua" node REFUSED at initialize(), the config/CLI opt-in that sanctions it.
test_with_arg test_lua_deprecated "$SCRIPT_DIR/test_lua_deprecated.json" \
    "$SCRIPT_DIR/test_lua_deprecated.cpp" \
    "$REPO_ROOT/orchestrator/runtime/SimController.cpp" \
    "$REPO_ROOT/orchestrator/runtime/LuaHost.cpp" \
    "$REPO_ROOT/orchestrator/runtime/ScriptedNode.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp" \
    "$REPO_ROOT/orchestrator/test_runner/ExpectRunner.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp" \
    "$REPO_ROOT/core/link/LinkModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp" \
    "$REPO_ROOT/core/link/PathLossModel.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/events/EventLog.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp" \
    $LUA_CFLAGS $LUA_LIBS

# ★ The send-by-name resolution contract: `send <name>` resolves on the SENDER'S
# layer, and REFUSES when sender and addressee share none (or the sender is itself a
# multi-layer gateway). The corpus has ZERO commands on any refusal path, so suite
# byte-identity pins none of this -- see the test's header for the window-phase bug it
# guards (MeshRoute simulation/BASELINE.md note 2026-07-25d).
run test_send_by_name_layer "$SCRIPT_DIR/test_send_by_name_layer.cpp" \
    "$REPO_ROOT/orchestrator/runtime/SimController.cpp" \
    "$REPO_ROOT/orchestrator/runtime/LuaHost.cpp" \
    "$REPO_ROOT/orchestrator/runtime/ScriptedNode.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp" \
    "$REPO_ROOT/orchestrator/test_runner/ExpectRunner.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp" \
    "$REPO_ROOT/core/link/LinkModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp" \
    "$REPO_ROOT/core/link/PathLossModel.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/events/EventLog.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp" \
    $LUA_CFLAGS $LUA_LIBS

# Wave 4 (2026-07-20 realism review 6.1.2) -- TX->RX turnaround.
# nodes[].tx_fail_prob reaching the radio at all: the corpus sets it NOWHERE, so
# suite byte-identity is evidence the prob-0 guard WORKS and can never show it is
# needed. Unit half proves prob 0 is draw-free; controller half proves the key is
# plumbed and a failed arm drops the frame visibly (tx_fail).
test_with_arg test_tx_fail_prob "$SCRIPT_DIR/test_tx_fail_prob.json" \
    "$SCRIPT_DIR/test_tx_fail_prob.cpp" \
    "$REPO_ROOT/orchestrator/runtime/SimController.cpp" \
    "$REPO_ROOT/orchestrator/runtime/LuaHost.cpp" \
    "$REPO_ROOT/orchestrator/runtime/ScriptedNode.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp" \
    "$REPO_ROOT/orchestrator/test_runner/ExpectRunner.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp" \
    "$REPO_ROOT/core/link/LinkModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp" \
    "$REPO_ROOT/core/link/PathLossModel.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/events/EventLog.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp" \
    $LUA_CFLAGS $LUA_LIBS

# A node is DEAF for tx_to_rx_delay_ms after its own TX ends (LNA + PLL relock).
# Drives the knob at 0 / 8 / 100 ms over one fixture: a frame inside the window
# drops (drop_tx_settling), one after it is received, and the boundary + the
# verdict track the config -- none of which stream byte-identity can pin.
test_with_arg test_tx_settling "$SCRIPT_DIR/test_tx_settling.json" \
    "$SCRIPT_DIR/test_tx_settling.cpp" \
    "$REPO_ROOT/orchestrator/runtime/SimController.cpp" \
    "$REPO_ROOT/orchestrator/runtime/LuaHost.cpp" \
    "$REPO_ROOT/orchestrator/runtime/ScriptedNode.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp" \
    "$REPO_ROOT/orchestrator/test_runner/ExpectRunner.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp" \
    "$REPO_ROOT/core/link/LinkModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp" \
    "$REPO_ROOT/core/link/PathLossModel.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/events/EventLog.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp" \
    $LUA_CFLAGS $LUA_LIBS

run test_sim_controller "$SCRIPT_DIR/test_sim_controller.cpp" \
    "$REPO_ROOT/orchestrator/runtime/SimController.cpp" \
    "$REPO_ROOT/orchestrator/runtime/LuaHost.cpp" \
    "$REPO_ROOT/orchestrator/runtime/ScriptedNode.cpp" \
    "$REPO_ROOT/orchestrator/runtime/TimerWheel.cpp" \
    "$REPO_ROOT/orchestrator/test_runner/ExpectRunner.cpp" \
    "$REPO_ROOT/core/radio/SimRadio.cpp" \
    "$REPO_ROOT/core/link/LinkModel.cpp" \
    "$REPO_ROOT/core/link/LinkFadingState.cpp" \
    "$REPO_ROOT/core/link/PathLossModel.cpp" \
    "$REPO_ROOT/core/physics/CollisionModel.cpp" \
    "$REPO_ROOT/core/physics/LbtModel.cpp" \
    "$REPO_ROOT/core/events/EventLog.cpp" \
    "$REPO_ROOT/core/topology/JsonConfig.cpp" \
    $LUA_CFLAGS $LUA_LIBS

echo "[ok] all tests passed"
