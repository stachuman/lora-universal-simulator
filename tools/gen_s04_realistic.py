#!/usr/bin/env python3
"""tools/gen_s04_realistic.py — generate scenarios/s04_seattle_realistic.json

Builds a longer, denser traffic pattern on top of s03's existing topology:

  • 30 min duration (vs s03's ~15 min)
  • 16 active sender/receiver identities (4 corner companions + 12 sampled
    named repeaters spread across the lat/lon range), vs s03's 4 corners
  • Better-distributed sends: a baseline ~10s-mean Poisson-ish drumbeat
    plus 3 burst windows at 5 / 15 / 25 minutes (5 sends within 3s each)
    so steady-state and peak behavior are both exercised
  • Reproducible via --seed (default 42)

Run:
    python3 tools/gen_s04_realistic.py
    build/orchestrator/lus scenarios/s04_seattle_realistic.json
    tools/analyze.py scenarios/s04_seattle_realistic.json --run

Why s04 and not just edit s03: s03 is a stable reference with known
analyzer numbers from the baseline → A+B+C measurement series. Keep
both scenarios so comparisons across protocol changes stay anchored to
a known scenario, while s04 adds the longer-window / more-traffic
diagnostic surface the realism review asked for.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
from pathlib import Path


CORNER_NAMES = ("alice", "bob", "carol", "dave")


def sample_repeaters(nodes: list[dict], n: int, rng: random.Random) -> list[str]:
    """Pick `n` named repeaters spread across the lat/lon bounding box.

    Strategy: split the bbox into a sqrt(n) × sqrt(n) grid, pick one
    repeater from each grid cell (random within the cell). Falls back
    to plain random sampling if some cells are empty. This avoids the
    "all 12 picked repeaters are in Capitol Hill" failure mode that a
    naive random-sample over a non-uniform geographic distribution
    would produce.
    """
    repeaters = [n_ for n_ in nodes if n_.get("name") not in CORNER_NAMES
                                       and n_.get("lat") is not None]
    if len(repeaters) <= n:
        return [r["name"] for r in repeaters]
    lats = [r["lat"] for r in repeaters]
    lons = [r["lon"] for r in repeaters]
    lat_min, lat_max = min(lats), max(lats)
    lon_min, lon_max = min(lons), max(lons)
    # Rough sqrt(n) split; round up so we have at least n cells.
    side = max(2, int(math.ceil(math.sqrt(n))))
    cells: dict[tuple[int, int], list[dict]] = {}
    for r in repeaters:
        ci = min(side - 1, int((r["lat"] - lat_min) / (lat_max - lat_min) * side))
        cj = min(side - 1, int((r["lon"] - lon_min) / (lon_max - lon_min) * side))
        cells.setdefault((ci, cj), []).append(r)

    picks: list[str] = []
    cell_keys = list(cells.keys())
    rng.shuffle(cell_keys)
    for k in cell_keys:
        if len(picks) >= n:
            break
        picks.append(rng.choice(cells[k])["name"])
    # Fallback if fewer cells than requested
    pool = [r["name"] for r in repeaters if r["name"] not in picks]
    rng.shuffle(pool)
    while len(picks) < n and pool:
        picks.append(pool.pop())
    return picks[:n]


def baseline_times(rng: random.Random, start_ms: int, end_ms: int,
                   mean_interval_ms: int) -> list[int]:
    """Generate a Poisson-ish (exponential inter-arrival) sequence of send
    times in [start_ms, end_ms]. Uses rng.expovariate so two runs with the
    same seed produce the exact same sequence."""
    out: list[int] = []
    t = start_ms
    while t < end_ms:
        gap = max(1, int(rng.expovariate(1.0 / mean_interval_ms)))
        t += gap
        if t < end_ms:
            out.append(t)
    return out


def burst_times(rng: random.Random, center_ms: int, n_sends: int,
                window_ms: int) -> list[int]:
    """Drop `n_sends` send timestamps clustered around `center_ms`,
    each within ±window_ms/2. Models real-world peaks (an
    announcement, a network-stress event)."""
    return sorted(rng.randint(center_ms - window_ms // 2,
                              center_ms + window_ms // 2)
                  for _ in range(n_sends))


def pick_pair(rng: random.Random, identities: list[str],
              corner_share: float) -> tuple[str, str]:
    """Pick (origin, dst). With probability corner_share the originator is
    a corner; the receiver is sampled from the rest. Avoids origin == dst.

    Mix targets:
      • corner→repeater: long-haul, exercises the routing fabric
      • repeater→corner: peripheral injection
      • repeater→repeater: in-fabric traffic between mid-network nodes
      • corner→corner: end-to-end across the whole topology (rare-ish)
    """
    corners = [n for n in identities if n in CORNER_NAMES]
    repeaters = [n for n in identities if n not in CORNER_NAMES]
    if rng.random() < corner_share or not repeaters:
        origin = rng.choice(corners) if corners else rng.choice(identities)
    else:
        origin = rng.choice(repeaters)
    dst_pool = [n for n in identities if n != origin]
    return origin, rng.choice(dst_pool)


def build_commands(identities: list[str], rng: random.Random,
                   warmup_ms: int, duration_ms: int,
                   mean_interval_ms: int, corner_share: float,
                   bursts: list[tuple[int, int, int]]) -> list[dict]:
    """Combine baseline + burst times into a sorted command list.

    bursts: list of (center_ms, n_sends, window_ms) tuples.
    Each command becomes
        { at_ms, node, command: "send <dst> b<seq> <origin>-><dst>" }
    The origin-seq counter is per-originator (mirrors s03 style so
    delivered events can be matched by (origin, origin_seq)). Payload
    text is human-readable for trace inspection.
    """
    times: list[int] = baseline_times(rng, warmup_ms, duration_ms,
                                       mean_interval_ms)
    for center, n_sends, window in bursts:
        times.extend(burst_times(rng, center, n_sends, window))
    times = sorted(t for t in times if warmup_ms <= t < duration_ms)

    seq_by_origin: dict[str, int] = {}
    cmds: list[dict] = []
    for at_ms in times:
        origin, dst = pick_pair(rng, identities, corner_share)
        seq_by_origin[origin] = seq_by_origin.get(origin, 0) + 1
        seq = seq_by_origin[origin]
        # Tag burst sends so the analyzer can spot them in the cold-start
        # curve / per-bucket breakdown if it ever cares about that label.
        tag = "b" if any(abs(at_ms - c) <= w // 2 for c, _, w in bursts) else "s"
        cmds.append({
            "at_ms":   at_ms,
            "node":    origin,
            "command": f"send {dst} {tag}{seq} {origin}->{dst}",
        })
    return cmds


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--src",
                   default="scenarios/s03_seattle_medium.json",
                   help="Topology source scenario")
    p.add_argument("--out",
                   default="scenarios/s04_seattle_realistic.json",
                   help="Output scenario path")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--duration-ms", type=int, default=1_800_000,
                   help="Total sim duration (default 30 min)")
    p.add_argument("--warmup-ms", type=int, default=30_000,
                   help="Min warmup before first send (default 30 s). The actual "
                        "warmup is auto-extended to max(warmup_ms, "
                        "node_startup_jitter_ms + 30 s) so that even the latest-"
                        "starting node gets ~30 s of warmup-period beacons before "
                        "the global warmup_ms gate switches it to operational rate.")
    p.add_argument("--mean-interval-ms", type=int, default=10_000,
                   help="Baseline mean inter-send interval (default 10 s)")
    p.add_argument("--repeater-senders", type=int, default=12,
                   help="Number of named repeaters added to the active "
                        "sender/receiver pool (default 12)")
    p.add_argument("--corner-share", type=float, default=0.30,
                   help="Probability the originator is a corner companion "
                        "(default 0.30 → 30%% from corners, 70%% from repeaters)")
    p.add_argument("--node-startup-jitter-ms", type=int, default=60_000,
                   help="Per-node random delay on on_init in [0, JITTER] (default 60 s). "
                        "Desynchronizes the warmup phase so routes don't age out in lockstep "
                        "and the channel doesn't see a synchronized BCN burst at boot.")
    args = p.parse_args()

    src_path = Path(args.src)
    if not src_path.exists():
        raise SystemExit(f"source scenario not found: {src_path}")
    with src_path.open() as f:
        cfg = json.load(f)

    rng = random.Random(args.seed)

    # 12 spread repeaters + 4 corner companions = 16 active identities
    repeaters = sample_repeaters(cfg["nodes"], args.repeater_senders, rng)
    identities = sorted(set(repeaters) | set(CORNER_NAMES))

    # Three burst windows at 5 / 15 / 25 min — early/mid/late so the
    # cold-start curve (analyzer §12) shows whether the network can
    # absorb peaks at different convergence stages.
    five_min = 5 * 60_000
    bursts = [
        (5  * 60_000, 5, 3000),
        (15 * 60_000, 5, 3000),
        (25 * 60_000, 5, 3000),
    ]

    # Auto-extend warmup so even the latest-starting node gets a full
    # warmup-period beacon phase. The runtime gates beacon cadence on a
    # GLOBAL `now() < warmup_ms` check, not a per-node "since on_init"
    # check, so a node that starts at t=jitter_max with the default
    # warmup_ms=30s would skip warmup-period beacons entirely.
    effective_warmup_ms = max(args.warmup_ms, args.node_startup_jitter_ms + 30_000)

    cmds = build_commands(
        identities, rng,
        warmup_ms=effective_warmup_ms, duration_ms=args.duration_ms,
        mean_interval_ms=args.mean_interval_ms,
        corner_share=args.corner_share, bursts=bursts,
    )

    # Carry over s03's nodes / topology / path_loss verbatim. Override
    # only the sim duration, the commands, and the scenario name/desc.
    cfg["_name"] = "s04_seattle_realistic"
    cfg["_desc"] = (
        "Seattle topology (s03 reference, 134 ITM repeaters + 4 corners), "
        f"extended to {args.duration_ms // 60_000} min with {len(cmds)} sends "
        f"distributed across {len(identities)} active identities ({len(repeaters)} "
        f"named repeaters + 4 corners). Baseline mean inter-send {args.mean_interval_ms}ms "
        "+ 3 burst windows at 5/15/25 min (5 sends in ~3s each). "
        f"Per-node startup jitter [0, {args.node_startup_jitter_ms}] ms so the warmup "
        "phase isn't synchronized — desyncs initial route-aging so the network doesn't "
        "collapse in lockstep at the global TTL boundary. Goal: surface time-windowed "
        "congestion and steady-state behavior past the s03 cold-start phase."
    )
    cfg["simulation"]["duration_ms"] = args.duration_ms
    cfg["simulation"]["warmup_ms"]   = effective_warmup_ms
    cfg["simulation"]["node_startup_jitter_ms"] = args.node_startup_jitter_ms
    cfg["commands"] = cmds

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(cfg, f, indent=2)

    # Brief stats so the operator sees what was generated.
    from collections import Counter
    by_origin: Counter = Counter(c["node"] for c in cmds)
    by_dst: Counter = Counter(c["command"].split()[1] for c in cmds)
    by_minute: Counter = Counter(c["at_ms"] // 60_000 for c in cmds)
    print(f"# wrote {out_path}")
    print(f"# duration: {args.duration_ms} ms ({args.duration_ms//60_000} min)")
    print(f"# sends:    {len(cmds)} total  (corners: "
          f"{sum(by_origin[n] for n in CORNER_NAMES)} | repeaters: "
          f"{sum(by_origin[n] for n in repeaters)})")
    print(f"# active identities: {len(identities)}")
    print(f"# sends per minute (top 6 minutes):")
    for m, n in by_minute.most_common(6):
        print(f"#   minute {m:>2}: {n}")
    print(f"# top-5 origins: {dict(by_origin.most_common(5))}")
    print(f"# top-5 dsts:    {dict(by_dst.most_common(5))}")


if __name__ == "__main__":
    main()
