#!/usr/bin/env python3
"""R3.x lossy-gate differential — per-pair delivery-% BAND + retry-funnel parity.

Sibling of tools/dm_diff.py. dm_diff asserts EXACT (dst,payload) set-parity on an
idle+lossless scenario, where lua==meshroute is deterministic. That gate exercises
ZERO rand under loss. This tool gates the RETRY paths instead: it runs a LOSSY
scenario under the Lua engine (REFERENCE) and the meshroute engine and compares

  (1) per-(origin,dst) delivery-%  within BAND  (default 10 pp), and
  (2) the retry/funnel event counts within K     (default 2),

so the timing divergence that loss + retries introduce is tolerated, while a real
delivery or retry-alignment regression still trips.

Two regimes (P1 = both):
  * forced_drops scenario (deterministic single retry): run with --band 0
    --funnel report --expect-drops 1 --min-delivery full — the dropped frame
    fires one retry on both engines, so per-pair DELIVERY is N/N on both. The
    retry FUNNEL, however, diverges by wire-airtime design (the Lua emits a retry
    as the distinct RTS-rty event — invisible to the rts_tx key — while meshroute
    re-emits rts_tx on every retry), so the funnel is REPORTED, not asserted.
    --min-delivery full enforces the N/N contract absolutely (not just cross-engine
    parity), and --expect-drops 1 confirms the drop actually fired. The strong,
    wired gate.
  * Bernoulli-loss scenario (distribution sample): run with --band <calibrated>
    --funnel report — the shared-_rng loss stream diverges across engines, so only
    the delivery-% band applies; the funnel is reported. Calibrate the band from a
    multi-seed run before locking (P2). NOT wired (a diagnostic tool).

Per-pair delivery-% is computed HERE, by `per_pair()` below, straight from each
run's delivery events. It does NOT share code with MeshRoute's canonical
`tools/dm_delivery_breakdown.py` — an earlier version of this line claimed it
"reuses the canonical ...summarise", and there is no import and no call — and it
is deliberately lighter: no gateway/cross-layer reconstruction, no fail-loud
denominator. Use the canonical tool for a delivery verdict; this is a
cross-engine differential.

Usage:
    tools/dm_diff_band.py scenarios/r4_data_diff_forced.json \\
        --band 0 --funnel report --expect-drops 1 --min-delivery full
    tools/dm_diff_band.py scenarios/r4_data_diff_bernoulli.json --band 20 --funnel report
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections import defaultdict

# Retry/funnel keys. rts_tx beyond the first per send == a retry fired; rts_giveup
# == a send abandoned; drop_forced == the deterministic gate drop (must match).
FUNNEL_KEYS = ("tx_enqueue", "rts_tx", "cts_rx", "data_tx", "data_rx",
               "ack_rx", "delivered", "rts_giveup", "drop_forced")


def make_variant(base, engine):
    """Patch every node onto one engine (mirrors tools/dm_diff.make_variant)."""
    s = json.loads(json.dumps(base))
    for node in s["nodes"]:
        node.pop("engine", None)
        node.pop("script", None)
        if engine == "lua":
            node["script"] = "scenarios/dv_dual_sf.lua"
            # ★ 2026-07-25 deprecation ruling: the engine must be named EXPLICITLY.
            # "meshroute" is now the DEFAULT, so omitting the key (as this did) would
            # silently make the "lua REFERENCE" variant a second meshroute run and turn
            # the whole differential vacuous. The generated variant also carries the
            # deprecated-Lua opt-in, since a Lua run is otherwise refused outright.
            node["engine"] = "lua"
        else:
            node["engine"] = "meshroute"
    if engine == "lua":
        s.setdefault("simulation", {})["allow_deprecated_lua"] = True
    return s


def run_lus(lus, scenario_path, ndjson_path):
    subprocess.run([lus, scenario_path, ndjson_path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def funnel(ndjson_path):
    c = defaultdict(int)
    with open(ndjson_path) as f:
        for line in f:
            try:
                ev = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            t = ev.get("type")
            if t == "drop_forced":
                c["drop_forced"] += 1
            elif t == "script_emit":
                et = ev.get("emit_type")
                if et in FUNNEL_KEYS:
                    c[et] += 1
    return c


def per_pair(ndjson_path):
    """{(origin, dst): {sent, arrived}} straight from the delivery events.

    Both `tx_enqueue` and `delivered` carry origin+dst (node.cpp do_send /
    do_post_ack), so per-pair delivery is computable without the heavyweight
    lifecycle analyzer — and robustly across the lua + meshroute event schemas.
    Each message is enqueued once (a retry does NOT re-enqueue) and the seen-
    origin dedup prevents double-delivery, so counts == distinct messages.
    """
    sent = defaultdict(int)
    arrived = defaultdict(int)
    with open(ndjson_path) as f:
        for line in f:
            try:
                ev = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if ev.get("type") != "script_emit":
                continue
            et = ev.get("emit_type")
            d = ev.get("data", {}) or {}
            if et == "tx_enqueue":
                sent[(d.get("origin"), d.get("dst"))] += 1
            elif et == "delivered":
                arrived[(d.get("origin"), d.get("dst"))] += 1
    return {k: {"sent": sent.get(k, 0), "arrived": arrived.get(k, 0)}
            for k in (set(sent) | set(arrived))}


def pct(row):
    return (100.0 * row["arrived"] / row["sent"]) if row["sent"] else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--build", default="build")
    ap.add_argument("--band", type=float, default=10.0,
                    help="per-pair delivery-%% tolerance in percentage points")
    ap.add_argument("--k", type=int, default=2,
                    help="retry/funnel count tolerance (only when --funnel strict)")
    ap.add_argument("--funnel", choices=("strict", "report"), default="strict",
                    help="strict: assert funnel within K; report: print only")
    ap.add_argument("--expect-drops", type=int, default=0,
                    help="assert each engine's drop_forced >= N (guards against a "
                         "vacuous pass: confirms the forced drop actually fired so "
                         "the retry path was exercised)")
    ap.add_argument("--min-delivery", choices=("none", "one", "full"), default="none",
                    help="absolute per-pair delivery floor on EACH engine (not just "
                         "cross-engine parity): none = no floor; one = arrived>=1; "
                         "full = arrived==sent. Closes the vacuous-pass hole where a "
                         "common-mode regression delivers 0/N on both engines (delta=0).")
    args = ap.parse_args()

    lus = os.path.join(args.build, "orchestrator", "lus")
    if not os.path.exists(lus):
        print(f"ERROR: lus not found at {lus}", file=sys.stderr); sys.exit(2)
    with open(args.scenario) as f:
        base = json.load(f)

    res = {}
    with tempfile.TemporaryDirectory() as td:
        for engine in ("lua", "meshroute"):
            sp = os.path.join(td, f"{engine}.json")
            npth = os.path.join(td, f"{engine}.ndjson")
            with open(sp, "w") as f:
                json.dump(make_variant(base, engine), f)
            run_lus(lus, sp, npth)
            res[engine] = {"pairs": per_pair(npth), "funnel": funnel(npth)}

    lua, mr = res["lua"], res["meshroute"]
    ok = True

    # ---- forced-drop sanity (don't pass vacuously) -------------------------
    if args.expect_drops > 0:
        for eng, r in (("lua", lua), ("meshroute", mr)):
            got = r["funnel"].get("drop_forced", 0)
            if got < args.expect_drops:
                ok = False
                print(f"  EXPECT-DROPS: {eng} drop_forced={got} < {args.expect_drops} "
                      f"(the forced drop did not fire -> the retry path was not exercised)")
        print()

    # ---- funnel table ------------------------------------------------------
    print(f"{'event':>11}  {'lua':>4} {'meshroute':>9}  {'dlt':>4}")
    print("-" * 34)
    for et in FUNNEL_KEYS:
        lv, mv = lua["funnel"].get(et, 0), mr["funnel"].get(et, 0)
        flag = ""
        if args.funnel == "strict" and abs(lv - mv) > args.k:
            flag = "  <-- DELTA > K"
            ok = False
        print(f"{et:>11}  {lv:>4} {mv:>9}  {mv - lv:>+4}{flag}")
    print()

    # ---- per-pair delivery-% band ------------------------------------------
    all_pairs = sorted(set(lua["pairs"]) | set(mr["pairs"]))
    if not all_pairs:
        print("  (no configured pairs found on either engine)")
        ok = False
    def floor_ok(row):
        # An engine meets the floor if it delivered enough of what it sent. A
        # pair with sent==0 is vacuous either way; treat it as not-meeting any
        # floor stricter than "none" so a sent-nothing collapse can't pass.
        if args.min_delivery == "none":
            return True
        if not row or row["sent"] == 0:
            return False
        if args.min_delivery == "one":
            return row["arrived"] >= 1
        return row["arrived"] == row["sent"]      # "full"

    for key in all_pairs:
        lr, mr_ = lua["pairs"].get(key), mr["pairs"].get(key)
        lp = pct(lr) if lr else 0.0
        mp = pct(mr_) if mr_ else 0.0
        delta = abs(lp - mp)
        within = delta <= args.band
        floored = floor_ok(lr) and floor_ok(mr_)     # absolute floor on BOTH engines
        ok = ok and within and floored
        ls = f"{lr['arrived']}/{lr['sent']}" if lr else "0/0"
        ms = f"{mr_['arrived']}/{mr_['sent']}" if mr_ else "0/0"
        verdict = "OK" if (within and floored) else ("FLOOR MISSED" if within else "BAND EXCEEDED")
        print(f"  {key[0]} -> {key[1]}: lua {lp:5.1f}% ({ls})  meshroute {mp:5.1f}% ({ms})  "
              f"|d|={delta:4.1f}pp  {verdict}")
    print()

    if ok:
        print(f"R3.x lossy DIFFERENTIAL: PASS — per-pair delivery within "
              f"{args.band:g}pp" + (f" and funnel within {args.k}" if args.funnel == 'strict' else "")
              + ".")
        sys.exit(0)
    print("R3.x lossy DIFFERENTIAL: REGRESSION vs the Lua reference — investigate.")
    sys.exit(1)


if __name__ == "__main__":
    main()
