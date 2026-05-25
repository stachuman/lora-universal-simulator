#!/usr/bin/env python3
"""Multi-seed s15 sweep to measure the DM route-non-convergence bucket.

s15 cross-layer metrics are noise-dominated (3 msgs/pair), so a single run
can't judge a firmware change — sweep several seeds and aggregate. For each
seed this regenerates the s15 config with that seed, runs lus, and parses
`dm_delivery_breakdown.py --failures` to pull out the overall DM delivery
rate and the per-mechanism failure counts (the bucket the 'F' route-Find
flood targets is "SL: origin no route (requery failed)").

Usage:
  python3 tools/s15_route_convergence_sweep.py 1522 7 13 101 777 2026 4242 9001
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE_CONFIG = os.path.join(REPO, "scenarios", "s15_three_layer.json")
DM_TOOL = os.path.join(REPO, "tools", "dm_delivery_breakdown.py")

DELIV_RE = re.compile(r"delivered\s+(\d+)/(\d+)\s*=\s*([\d.]+)%;\s*(\d+)\s+failed")
CAT_RE = re.compile(r"^\s*(\d+)\s*\(\s*[\d.]+%\s*of fails\)\s+(.*\S)\s*$")


def run_seed(seed):
    with open(BASE_CONFIG) as f:
        cfg = json.load(f)
    cfg["simulation"]["seed"] = seed
    tmp_cfg = os.path.join(tempfile.gettempdir(), f"s15_seed_{seed}.json")
    with open(tmp_cfg, "w") as f:
        json.dump(cfg, f)
    events = os.path.join(tempfile.gettempdir(), f"s15_seed_{seed}.ndjson")
    out = subprocess.run(
        [sys.executable, DM_TOOL, tmp_cfg, events, "--run",
         "--mode", "dm", "--failures"],
        cwd=REPO, capture_output=True, text=True).stdout

    delivered = total = failed = None
    cats = Counter()
    for line in out.splitlines():
        m = DELIV_RE.search(line)
        if m:
            delivered, total, _pct, failed = (
                int(m.group(1)), int(m.group(2)), None, int(m.group(4)))
            continue
        m = CAT_RE.match(line)
        if m and "of fails" in line:
            cats[m.group(2)] += int(m.group(1))
    return delivered, total, failed, cats


def main():
    seeds = [int(s) for s in sys.argv[1:]] or [1522, 7, 13, 101, 777, 2026, 4242, 9001]
    tot_deliv = tot_total = 0
    agg = Counter()
    print(f"{'seed':>6} {'deliv':>7} {'pct':>6}  {'SL-no-route':>11}  failures-by-mechanism")
    print("-" * 96)
    for seed in seeds:
        d, t, f, cats = run_seed(seed)
        if d is None:
            print(f"{seed:>6}  PARSE-FAIL")
            continue
        tot_deliv += d
        tot_total += t
        agg.update(cats)
        sl = cats.get("SL: origin no route (requery failed)", 0)
        extras = "; ".join(f"{v}×{k}" for k, v in cats.most_common())
        print(f"{seed:>6} {d:>3}/{t:<3} {100*d/t:>5.1f}% {sl:>11}  {extras}")
    print("-" * 96)
    pct = 100 * tot_deliv / tot_total if tot_total else 0
    print(f"AGGREGATE  {tot_deliv}/{tot_total} = {pct:.1f}% delivered "
          f"across {len(seeds)} seeds")
    print("failure totals by mechanism (across all seeds):")
    for k, v in agg.most_common():
        print(f"  {v:>4}  {k}")


if __name__ == "__main__":
    main()
