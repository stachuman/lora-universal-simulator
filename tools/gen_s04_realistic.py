#!/usr/bin/env python3
"""tools/gen_s04_realistic.py — generate scenarios/s04_seattle_realistic.json

Session-based traffic on top of s03's Seattle topology. Models realistic
LoRa-mesh chatter rather than i.i.d. random pings:

  • 3 h duration (10_800_000 ms)
  • 16 active identities (4 corner companions + 12 sampled named repeaters)
  • Five session kinds mixed by share:
      conversation (60%) — 2 nodes alternate 4-8 msgs (occasional 10-12),
                           inter-message gaps ~exp(mean 20 s)
                           clipped to [3 s, 90 s], `send_e2e` throughout
      ping        (20%) — single fire-and-forget `send`, random pair
      group       (10%) — 3-4 nodes, 6-10 msgs round-robin-ish, `send_e2e`
      telemetry    (5%) — 2 designated stations report to a corner gateway
                          every ~6 min ± 15% jitter, `send` (no ACK)
      burst        (5%) — event-driven peaks every ~30 min (4-6 senders
                          within ~5 s), `send`
  • Reproducible via --seed (default 42)

Run:
    python3 tools/gen_s04_realistic.py
    build/orchestrator/lus scenarios/s04_seattle_realistic.json
    tools/analyze.py scenarios/s04_seattle_realistic.json --run

Why session-based: i.i.d. random (origin, dst) per send under-engages
node pairs and produces no bidirectional flows. Real LoRa traffic is
clustered: hikers chat, nets check in, sensors report. Sessions exercise
the routing fabric the way real deployments do — and bidirectional A↔B
exposes asymmetric-link bugs that one-way traffic masks.
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
    pool = [r["name"] for r in repeaters if r["name"] not in picks]
    rng.shuffle(pool)
    while len(picks) < n and pool:
        picks.append(pool.pop())
    return picks[:n]


# ---- session generators ---------------------------------------------------
#
# Each generator returns a list of (at_ms, origin, dst, verb, tag) tuples
# where verb is "send" or "send_e2e" and tag is a single letter used in
# the payload prefix so trace tools can cheaply identify the pattern.


def pick_msg_count(rng: random.Random) -> int:
    """Conversation length: mean ~5, occasional 10-12.
    80% normal: uniform 4-7. 20% chatty: uniform 8-12.
    """
    if rng.random() < 0.20:
        return rng.randint(8, 12)
    return rng.randint(4, 7)


def gen_conversation(rng: random.Random, identities: list[str],
                     start_ms: int, end_cap_ms: int) -> list[tuple]:
    """Two-party chat. Strict alternation 85% of the time (the other 15%
    one speaker takes a second turn — a follow-up clarification). All
    messages use `send_e2e` because chat naturally wants delivery
    confirmation. Truncates at end_cap_ms.
    """
    a, b = rng.sample(identities, 2)
    n_msgs = pick_msg_count(rng)
    cmds = []
    t = start_ms
    speaker, listener = a, b
    for _ in range(n_msgs):
        if t >= end_cap_ms:
            break
        cmds.append((t, speaker, listener, "send_e2e", "c"))
        gap = max(3000, min(90000, int(rng.expovariate(1.0 / 20000))))
        t += gap
        if rng.random() < 0.85:
            speaker, listener = listener, speaker
    return cmds


def gen_group(rng: random.Random, identities: list[str],
              start_ms: int, end_cap_ms: int) -> list[tuple]:
    """Small-group chat (3-4 participants, 6-10 messages). Each "message"
    is unicast from one participant to another — there's no broadcast
    in the underlying DV-mesh, so a group chat is N parallel unicasts
    or one-to-one round-robin. We model the round-robin form: pick
    a speaker (≠ last speaker), pick an addressee (≠ speaker) from
    the group, send.
    """
    n_participants = rng.randint(3, 4)
    if len(identities) < n_participants:
        return []
    participants = rng.sample(identities, n_participants)
    n_msgs = rng.randint(6, 10)
    cmds = []
    t = start_ms
    last_speaker = None
    for _ in range(n_msgs):
        if t >= end_cap_ms:
            break
        candidates = [p for p in participants if p != last_speaker] or participants
        speaker = rng.choice(candidates)
        addressee = rng.choice([p for p in participants if p != speaker])
        cmds.append((t, speaker, addressee, "send_e2e", "g"))
        gap = max(2000, min(60000, int(rng.expovariate(1.0 / 12000))))
        t += gap
        last_speaker = speaker
    return cmds


def gen_ping(rng: random.Random, identities: list[str],
             at_ms: int) -> list[tuple]:
    """Single fire-and-forget `send` between two random nodes."""
    a, b = rng.sample(identities, 2)
    return [(at_ms, a, b, "send", "p")]


def gen_telemetry(rng: random.Random, station: str, gateway: str,
                  start_ms: int, end_ms: int,
                  period_ms: int) -> list[tuple]:
    """Periodic reports from `station` → `gateway` every ~period_ms with
    ±15% jitter. Models a sensor / weather station / mobile tracker
    beaconing position or telemetry. Uses `send` because telemetry can
    tolerate occasional loss — it'll re-report on the next cycle.
    """
    cmds = []
    t = start_ms + rng.randint(0, period_ms)
    jitter = int(period_ms * 0.15)
    while t < end_ms:
        cmds.append((t, station, gateway, "send", "t"))
        t += period_ms + rng.randint(-jitter, jitter)
    return cmds


def gen_burst(rng: random.Random, identities: list[str],
              center_ms: int, n_sends: int, window_ms: int) -> list[tuple]:
    """N unrelated nodes send within ±window_ms/2 of center_ms — event-
    driven peak. Each is a `send` (would-be self-reports about an event)."""
    cmds = []
    for _ in range(n_sends):
        a, b = rng.sample(identities, 2)
        t = center_ms + rng.randint(-window_ms // 2, window_ms // 2)
        cmds.append((t, a, b, "send", "b"))
    return cmds


# ---- scheduler ------------------------------------------------------------


def build_commands(identities: list[str], rng: random.Random,
                   warmup_ms: int, duration_ms: int,
                   mean_session_gap_ms: int,
                   conv_share: int, ping_share: int, group_share: int,
                   telemetry_specs: list[tuple[str, str, int]],
                   bursts: list[tuple[int, int, int]]) -> list[dict]:
    """Compose session-based traffic into a sorted command list.

    `telemetry_specs`: list of (station_name, gateway_name, period_ms).
    `bursts`:          list of (center_ms, n_sends, window_ms).
    `*_share`:         integer weights for choices.choices over sessions.
    """
    end_cap_ms = duration_ms - 60_000  # 1 min tail slack
    raw: list[tuple] = []

    # Sessions on a Poisson schedule. Each session picks a kind by
    # weighted choice; conversation/group span multiple messages,
    # ping is single-shot.
    kinds = ["conversation", "ping", "group"]
    weights = [conv_share, ping_share, group_share]
    t = warmup_ms
    while t < end_cap_ms:
        kind = rng.choices(kinds, weights=weights, k=1)[0]
        if kind == "conversation":
            raw.extend(gen_conversation(rng, identities, t, end_cap_ms))
        elif kind == "group":
            raw.extend(gen_group(rng, identities, t, end_cap_ms))
        else:
            raw.extend(gen_ping(rng, identities, t))
        gap = max(5000, int(rng.expovariate(1.0 / mean_session_gap_ms)))
        t += gap

    # Telemetry stations beacon independently.
    for station, gateway, period in telemetry_specs:
        raw.extend(gen_telemetry(rng, station, gateway, warmup_ms,
                                  end_cap_ms, period))

    # Event bursts at fixed times.
    for center, n_sends, window in bursts:
        raw.extend(gen_burst(rng, identities, center, n_sends, window))

    raw = [r for r in raw if warmup_ms <= r[0] < end_cap_ms]
    raw.sort(key=lambda x: x[0])

    seq_by_origin: dict[str, int] = {}
    cmds: list[dict] = []
    for at_ms, origin, dst, verb, tag in raw:
        seq_by_origin[origin] = seq_by_origin.get(origin, 0) + 1
        seq = seq_by_origin[origin]
        cmds.append({
            "at_ms":   at_ms,
            "node":    origin,
            "command": f"{verb} {dst} {tag}{seq} {origin}->{dst}",
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
    p.add_argument("--duration-ms", type=int, default=10_800_000,
                   help="Total sim duration (default 3 h = 10_800_000 ms).")
    p.add_argument("--warmup-ms", type=int, default=30_000,
                   help="Min warmup before first send (default 30 s). The actual "
                        "warmup is auto-extended to max(warmup_ms, "
                        "node_startup_jitter_ms + 30 s) so even the latest-starting "
                        "node gets a full warmup-period beacon phase.")
    p.add_argument("--mean-session-gap-ms", type=int, default=60_000,
                   help="Mean inter-session gap (default 60 s). Sessions are "
                        "Poisson-scheduled; each is one of conversation / ping / "
                        "group per --*-share weights.")
    p.add_argument("--repeater-senders", type=int, default=12,
                   help="Number of named repeaters added to the active "
                        "sender/receiver pool (default 12)")
    # The shares below weight SESSION selection. Because a conversation
    # produces ~6 messages, a group ~8, and a ping 1, the defaults are
    # tuned so the resulting MESSAGE-LEVEL distribution lands near
    # 60% conversation / 20% ping / 10% group (with the remaining ~10%
    # spread across telemetry + burst). Override per --*-share if you
    # want a different mix.
    p.add_argument("--conv-share",  type=int, default=32,
                   help="Session weight for conversations (default 32; "
                        "yields ~60%% of messages given mean 6 msgs/session)")
    p.add_argument("--ping-share",  type=int, default=64,
                   help="Session weight for single pings (default 64; "
                        "yields ~20%% of messages — pings are 1 msg/session)")
    p.add_argument("--group-share", type=int, default=4,
                   help="Session weight for group chats (default 4; "
                        "yields ~10%% of messages given mean 8 msgs/session)")
    p.add_argument("--telemetry-period-ms", type=int, default=360_000,
                   help="Period between telemetry reports per station "
                        "(default 360 s = 6 min, ±15%% jitter).")
    p.add_argument("--n-telemetry-stations", type=int, default=2,
                   help="Number of repeaters designated as telemetry "
                        "stations reporting to a corner gateway (default 2).")
    p.add_argument("--node-startup-jitter-ms", type=int, default=60_000,
                   help="Per-node random delay on on_init in [0, JITTER] (default 60 s).")
    args = p.parse_args()

    src_path = Path(args.src)
    if not src_path.exists():
        raise SystemExit(f"source scenario not found: {src_path}")
    with src_path.open() as f:
        cfg = json.load(f)

    rng = random.Random(args.seed)

    repeaters = sample_repeaters(cfg["nodes"], args.repeater_senders, rng)
    identities = sorted(set(repeaters) | set(CORNER_NAMES))

    # Telemetry: pick N stations from the non-corner repeaters, each
    # paired with a random corner gateway. Fixed at gen time so the
    # pairs are stable across the run (a real telemetry station has
    # one home base).
    non_corner = [r for r in repeaters if r not in CORNER_NAMES]
    rng.shuffle(non_corner)
    telemetry_specs: list[tuple[str, str, int]] = []
    for i in range(min(args.n_telemetry_stations, len(non_corner))):
        station = non_corner[i]
        gateway = rng.choice(CORNER_NAMES)
        telemetry_specs.append((station, gateway, args.telemetry_period_ms))

    # Event bursts every ~30 min: 4-6 senders within ~5 s window.
    bursts: list[tuple[int, int, int]] = []
    t_burst = 10 * 60_000
    while t_burst < args.duration_ms - 90_000:
        n_burst = rng.randint(4, 6)
        bursts.append((t_burst, n_burst, 5000))
        t_burst += 30 * 60_000

    effective_warmup_ms = max(args.warmup_ms, args.node_startup_jitter_ms + 30_000)

    cmds = build_commands(
        identities, rng,
        warmup_ms=effective_warmup_ms,
        duration_ms=args.duration_ms,
        mean_session_gap_ms=args.mean_session_gap_ms,
        conv_share=args.conv_share,
        ping_share=args.ping_share,
        group_share=args.group_share,
        telemetry_specs=telemetry_specs,
        bursts=bursts,
    )

    cfg["_name"] = "s04_seattle_realistic"
    tele_str = ", ".join(f"{s}→{g}" for s, g, _ in telemetry_specs) or "none"
    cfg["_desc"] = (
        "Seattle topology (s03 reference, 134 ITM repeaters + 4 corners), "
        f"extended to {args.duration_ms // 60_000} min with session-based traffic. "
        f"{len(cmds)} sends across {len(identities)} active identities. "
        f"Session mix: conversation {args.conv_share}% / ping {args.ping_share}% / "
        f"group {args.group_share}%. Telemetry stations ({tele_str}) report every "
        f"{args.telemetry_period_ms // 1000}s. {len(bursts)} event bursts every 30 min. "
        f"Per-node startup jitter [0, {args.node_startup_jitter_ms}] ms desyncs the "
        "warmup phase. Goal: realistic LoRa-mesh chatter exercising bidirectional "
        "flows, conversation patterns, and event peaks."
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
    by_verb: Counter = Counter(c["command"].split()[0] for c in cmds)
    by_tag: Counter = Counter(c["command"].split()[2][0] for c in cmds)
    print(f"# wrote {out_path}")
    print(f"# duration: {args.duration_ms} ms ({args.duration_ms//60_000} min)")
    print(f"# sends:    {len(cmds)} total")
    print(f"# verbs:    {dict(by_verb)}")
    tag_names = {"c": "conversation", "p": "ping", "g": "group",
                 "t": "telemetry",    "b": "burst"}
    by_pattern = {tag_names.get(k, k): v for k, v in by_tag.items()}
    print(f"# patterns: {by_pattern}")
    print(f"# active identities: {len(identities)}")
    print(f"# telemetry: {tele_str}")
    print(f"# top-5 origins: {dict(by_origin.most_common(5))}")
    print(f"# top-5 dsts:    {dict(by_dst.most_common(5))}")


if __name__ == "__main__":
    main()
