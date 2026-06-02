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
    done < <( { ls "$SCRIPT_DIR"/t*.json 2>/dev/null; ls "$REPO_ROOT"/scenarios/s*.json 2>/dev/null; } | sort )
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

# ---- lua-vs-meshroute delivery differentials (engine-neutral) -------------
# These run lus TWICE per scenario (lua REFERENCE, then meshroute) and compare
# delivery, so the base scenarios are engine-neutral and CANNOT be discovered as
# plain t*/s* configs (the runner above would error on them). Run them here, only
# on a full sweep (no explicit configs), when python3 is available.
run_diff() {              # $1 = display name, $2.. = command
    local name="$1"; shift
    local pad=$((40 - ${#name})); [ "$pad" -lt 1 ] && pad=1
    if ( cd "$REPO_ROOT" && "$@" ) >/dev/null 2>&1; then
        printf "  %s%*sPASS\n" "$name" "$pad" ""; passed=$((passed + 1))
    else
        printf "  %s%*sFAIL\n" "$name" "$pad" ""; failed=$((failed + 1))
    fi
}
if [ $# -eq 0 ] && command -v python3 >/dev/null 2>&1; then
    echo ""
    echo "lua-vs-meshroute differentials:"
    # R3: exact (dst,payload) parity on the idle/lossless gate.
    run_diff "dm_diff:r3_data_diff" \
        python3 "$REPO_ROOT/tools/dm_diff.py" scenarios/r3_data_diff.json --build "$BUILD_DIR"
    # R3.x: forced single retry -> per-pair delivery must match exactly (band 0)
    # AND hit the floor on both engines (--min-delivery full, so a common-mode
    # collapse to 0/N on BOTH engines can't pass with delta=0). --expect-drops 1
    # is LOAD-BEARING (MUST NOT REMOVE): it confirms the forced drop actually
    # fired, so a mis-labelled/typo'd directive that drops nothing fails loudly
    # instead of passing green-but-vacuous. The funnel diverges by wire-airtime
    # design, so it is reported, not asserted.
    run_diff "dm_diff_band:r4_forced" \
        python3 "$REPO_ROOT/tools/dm_diff_band.py" scenarios/r4_data_diff_forced.json \
        --build "$BUILD_DIR" --band 0 --funnel report --expect-drops 1 --min-delivery full
    # Cascade-to-alt: CTS-drop forces alice to walk relay_p -> relay_a -> relay_b
    # (full K=3); both engines deliver via the 2nd alternate. dm_diff_band only
    # (s3_diff's beacon-tx parity is too strict here: the retry activity shifts the
    # discovery-beacon interleaving); the alt-PICK is covered by the unit tests.
    # --expect-drops 6 = both relays' CTS dropped across all 3 sends (2x3): proves the
    # FULL two-step walk fired, so a silently-unmatched relay_a directive (label drift)
    # would drop only 3 and fail the gate.
    run_diff "dm_diff_band:r5_cascade" \
        python3 "$REPO_ROOT/tools/dm_diff_band.py" scenarios/r5_cascade_alt_diff.json \
        --build "$BUILD_DIR" --band 0 --funnel report --expect-drops 6 --min-delivery full
    # HOP_BUDGET: a 6-hop chain delivers N/N (budget min(31,6+3)=9 covers the path, the five
    # forwarders decrement 9->4, dest exempt). LOAD-BEARING (review #02): at SIX hops a per-hop
    # decrement scaled >=2x exhausts the last forwarder (9->7->5->3->1->-1 -> NACK, 0/1) and a
    # budget under-computed by >=5 also fails -> the band trips. It does NOT assert a single-off
    # decrement (the +3 slack + exempt-dst keep a valid route delivering) — that exact per-hop
    # value is the UNIT tests' job (test_node_r3.cpp 'forwarder decrements' asserts hops_remaining
    # on the forwarded DATA). Budget enforcement is purely subtractive, so no delivery gate can be
    # tight on one decrement; this proves delivery-NEUTRALITY + catches gross regressions. The
    # exhaustion+NACK terminal direction is unit-tested (no delivery to band-compare).
    run_diff "dm_diff_band:hop_budget_chain" \
        python3 "$REPO_ROOT/tools/dm_diff_band.py" scenarios/hop_budget_chain_diff.json \
        --build "$BUILD_DIR" --band 0 --funnel report --min-delivery full
    # R4.0/R4.1 budget integration: a relay with a GENEROUS duty_cycle (0.1) stays HEALTHY, so
    # compute_budget_tier runs on REAL sim airtime and returns HEALTHY -> normal CTS, NO spurious
    # BUDGET NACK, delivery 1/1 identical. Proves the enabled-but-healthy tier path is inert.
    # The BUDGET NACK emit + blind+requeue react are UNIT-tested (test_node_r3.cpp R4.0/R4.1): a
    # forced-CRITICAL DELIVERY gate is structurally impossible here — the NACK only changes the
    # PATH (the rts_timeout cascade reroutes anyway, so delivery is 1/1 with or without it), AND
    # the sim hard-enforces duty at the same per-node duty_cycle (SimController.cpp:1347) so a
    # budget tiny enough to reach CRITICAL also blocks the node's own beacons.
    run_diff "dm_diff_band:r6_budget_healthy" \
        python3 "$REPO_ROOT/tools/dm_diff_band.py" scenarios/r6_nack_budget_diff.json \
        --build "$BUILD_DIR" --band 0 --funnel report --min-delivery full
    # R4.5/R4.5b lbt_enabled=true NEUTRALITY: a single alice->relay->bob flow + a 900ms beacon 'spammer' keeping
    # the channel busy. ASSERTS lbt_enabled=true is delivery-NEUTRAL cross-engine (band 0 + min-delivery full: both
    # deliver 1/1, no LBT-induced loss). EXERCISES the R4.5a firmware LBT pre-check (tx_lbt_defer x2 on BOTH engines,
    # seed 42). Robust band-0 full across a 10-seed sweep (single flow + 60s window => alice always completes); the
    # funnel diverges by wire-airtime so it is reported, not asserted. It does NOT exercise meshroute's R4.5b
    # on_radio_busy (the pre-check absorbs the busy channel first; meshroute emits ZERO radio_busy) — and that is
    # FUNDAMENTAL: the contention needed to force a retry-eligible frame into on_radio_busy also makes delivery
    # non-deterministic cross-engine (a 150ms spammer fires on_radio_busy but diverges delivery on 3/6 seeds; a
    # 2-sender race resolved meshroute 2/2 vs lua 1/2, neither buggy). So the R4.5b on_radio_busy retry mechanics
    # (stash retry, retries_left->giveup, one draw/retry, the blocked-RTS re-RTS + DATA ACK-re-arm PORT DIVERGENCE
    # FIXES) are validated by DETERMINISTIC UNIT TESTS (test_node_r3.cpp R4.5b), not by this gate.
    run_diff "dm_diff_band:r7_lbt_neutral" \
        python3 "$REPO_ROOT/tools/dm_diff_band.py" scenarios/r7_lbt_busy_diff.json \
        --build "$BUILD_DIR" --band 0 --funnel report --min-delivery full
fi

echo ""
echo "$passed/$((passed + failed)) passed"
[ "$failed" -eq 0 ]
