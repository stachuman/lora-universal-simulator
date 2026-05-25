# s14 — Realistic Debug Scenario

**Date:** 2026-05-22
**Goal:** A small, debuggable, realistic scenario for isolating
delivery-rate problems before re-testing against s12 (6h dense).
Clean baseline — no priority, no abuse, no mobility.

## 1. Goal & non-goals

**Goal.** Produce a 40-minute, 21-node two-layer scenario that exercises
the realistic traffic mix (back-and-forth DM chat + public channel
posts) under explicit link definitions and per-layer routing-SF
separation. The scenario must be small enough to debug by reading
the trace, and structured enough to attribute delivery failures to a
specific protocol path.

**Non-goals.**
- Not a replacement for s12 (the long realistic stress test).
- Not a regression scenario (s13 plays that role for pull storms).
- Not a mobility test (s07/s08 cover that).
- Not a priority/abuse test (that's a later layer once baseline is clean).

## 2. Topology

21 nodes: 10 in L1 + 10 in L2 + 1 dual-layer bridge. Names are
chat-friendly first-letter codes so logs read like a conversation.

Visual aid (link list in Section 8 is the source of truth):

```
L1 (alice cluster, 10 nodes, routing SF8, data [7,9])
─────────────────────────────────────────────────────
        alice ── bob
       /  \    /
    carol─dave─eve
     │    │  \   \
   frank─grace─heidi
           │ \   /
         ivan─judy
              │
          [bridge]   ← dual-layer, home=L1, visits L2
              │
         quinn─sam
         /  \   \
      peter─ned─tina
       │    │ \  │
      mia  olga─rosa
        \   │
         leo─kate
L2 (kate cluster, 10 nodes, routing SF9, data [6,10])
```

L2 is a position-mirror of L1: alice↔kate, bob↔leo, carol↔mia,
dave↔ned, eve↔olga, frank↔peter, grace↔quinn, heidi↔rosa,
ivan↔sam, judy↔tina.

### Conversation pairs (DM topology)

| Pair             | Layer       | Expected hops | Notes                                  |
|------------------|-------------|---------------|----------------------------------------|
| alice ↔ bob      | L1          | 1             | 1-hop baseline                         |
| carol ↔ heidi    | L1          | 3             | multi-hop, one asymmetric link in path |
| leo ↔ rosa       | L2          | 3             | multi-hop L2                           |
| dave ↔ peter     | cross-layer | 4             | L1 → bridge → L2; tests gateway path   |

### Channel posters (channel 7)

| Poster | Layer |
|--------|-------|
| eve    | L1    |
| grace  | L1    |
| mia    | L2    |
| quinn  | L2    |

### Link plan

- Intra-L1: 15 undirected pairs → 30 directed (~3 neighbours/node)
- Intra-L2: 15 undirected pairs → 30 directed (~3 neighbours/node)
- Bridge: 2 contacts per layer — bridge ↔ grace, bridge ↔ ivan on L1;
  bridge ↔ quinn, bridge ↔ sam on L2 (= L1-mirror positions) → 8 directed
- ~30% of intra-layer links **asymmetric** (one direction strong
  ~14-18 dB, reverse ~5-8 dB). Exposes routing/link-quality bugs per
  established memory.
- All other links **symmetric** at ~14-20 dB SNR.

Total: 68 directed links. All defined explicitly (no path-loss
model — per memory).

## 3. Timeline & phases

```
t=0:00 ───────────────► 10:00   QUIET (BCN exchange under full physics)
                                no injects; routing tables converge

t=10:00 ──────────────► 18:00   PHASE 1: DM-only (8 min)
                                4 pairs, back-and-forth bursts
                                staggered ~2 min apart

t=18:00 ──────────────► 28:00   PHASE 2: Channel-only (10 min)
                                4 waves of channel-7 posts
                                ~3 min between waves, 30s offset
                                between posters within a wave

t=28:00 ──────────────► 40:00   PHASE 3: Mixed (12 min)
                                round-2 DM bursts interleaved with
                                additional channel posts
```

Total wall-clock estimate: ~30–60 s for the 40-min simulated run.

## 4. Inject schedule

### Phase 1 — DM-only (t=600s → 1080s)

| t (s) | from   | to     | text         |
|-------|--------|--------|--------------|
| 600   | alice  | bob    | hi           |
| 612   | bob    | alice  | hey          |
| 628   | alice  | bob    | any updates? |
| 645   | bob    | alice  | all green    |
| 665   | alice  | bob    | good         |
| 685   | bob    | alice  | ttyl         |
| 720   | carol  | heidi  | ping         |
| 738   | heidi  | carol  | pong         |
| 765   | carol  | heidi  | how's signal?|
| 792   | heidi  | carol  | weak north   |
| 820   | carol  | heidi  | ack          |
| 845   | heidi  | carol  | 73           |
| 840   | leo    | rosa   | yo           |
| 860   | rosa   | leo    | yo back      |
| 890   | leo    | rosa   | test test    |
| 920   | rosa   | leo    | 5/5          |
| 950   | leo    | rosa   | out          |
| 975   | rosa   | leo    | 73           |
| 960   | dave   | peter  | bridge test  |
| 995   | peter  | dave   | got it       |
| 1030  | dave   | peter  | round-trip ok|
| 1060  | peter  | dave   | confirmed    |

**Phase 1 total: 22 DMs.**

### Phase 2 — Channel-only (t=1080s → 1680s)

| t (s) | poster | channel | text         |
|-------|--------|---------|--------------|
| 1080  | eve    | 7       | L1-news-1    |
| 1110  | grace  | 7       | L1-event-1   |
| 1140  | mia    | 7       | L2-news-1    |
| 1170  | quinn  | 7       | L2-event-1   |
| 1260  | eve    | 7       | L1-news-2    |
| 1290  | grace  | 7       | L1-event-2   |
| 1320  | mia    | 7       | L2-news-2    |
| 1350  | quinn  | 7       | L2-event-2   |
| 1440  | eve    | 7       | L1-news-3    |
| 1470  | grace  | 7       | L1-event-3   |
| 1500  | mia    | 7       | L2-news-3    |
| 1530  | quinn  | 7       | L2-event-3   |
| 1620  | eve    | 7       | L1-news-4    |

**Phase 2 total: 13 channel posts.**

### Phase 3 — Mixed (t=1680s → 2400s)

| t (s) | from   | to / chan | text         |
|-------|--------|-----------|--------------|
| 1680  | alice  | bob       | round 2      |
| 1690  | mia    | ch 7      | L2-news-5    |
| 1710  | bob    | alice     | ack          |
| 1730  | carol  | heidi     | hey again    |
| 1755  | grace  | ch 7      | L1-event-5   |
| 1770  | heidi  | carol     | still here   |
| 1800  | leo    | rosa      | second pass  |
| 1830  | rosa   | leo       | yep          |
| 1860  | dave   | peter     | stress test  |
| 1890  | eve    | ch 7      | L1-news-6    |
| 1920  | peter  | dave      | loud and clear|
| 1950  | alice  | bob       | burst+       |
| 1980  | quinn  | ch 7      | L2-event-6   |
| 2010  | carol  | heidi     | burst+       |
| 2050  | heidi  | carol     | burst+       |
| 2100  | leo    | rosa      | final        |
| 2130  | mia    | ch 7      | L2-news-7    |
| 2160  | rosa   | leo       | 73           |
| 2200  | dave   | peter     | final        |
| 2230  | peter  | dave      | out          |
| 2260  | grace  | ch 7      | L1-event-7   |
| 2300  | alice  | bob       | out          |
| 2330  | bob    | alice     | 73 all       |

**Phase 3 total: 18 DMs + 6 channel posts = 24 injects.**

### Grand totals

| | Count |
|---|---|
| DMs | 40 |
| Channel posts | 19 |
| Total injects | 59 |

## 5. Per-node config

### L1 nodes (alice, bob, carol, dave, eve, frank, grace, heidi, ivan, judy)

```json
{
  "layer_id": 1,
  "routing_sf": 8,
  "allowed_data_sfs": [7, 9],
  "beacon_period_ms": 30000,
  "discovery_beacon_period_ms": 4000,
  "state_snapshot_period_ms": 60000,
  "quiet_threshold_ms": 0
}
```

### L2 nodes (kate, leo, mia, ned, olga, peter, quinn, rosa, sam, tina)

```json
{
  "layer_id": 2,
  "routing_sf": 9,
  "allowed_data_sfs": [6, 10],
  "beacon_period_ms": 30000,
  "discovery_beacon_period_ms": 4000,
  "state_snapshot_period_ms": 60000,
  "quiet_threshold_ms": 0
}
```

### Bridge (dual-layer gateway, home = L1)

```json
{
  "layer_id": 1,
  "is_gateway": true,
  "routing_sf": 8,
  "allowed_data_sfs": [7, 9],
  "gateway_layers": [
    {
      "layer_id": 2,
      "routing_sf": 9,
      "allowed_data_sfs": [6, 10],
      "period_ms": 30000,
      "duration_ms": 15000,
      "offset_ms": 15000
    }
  ],
  "beacon_period_ms": 30000,
  "discovery_beacon_period_ms": 4000,
  "state_snapshot_period_ms": 60000,
  "quiet_threshold_ms": 0
}
```

Bridge schedule: 50/50 split with 30 s period — first 15 s on home
(L1, SF8), second 15 s on visiting (L2, SF9). Pattern matches s09/s10.

### Notes on SF coexistence

SF9 is **L1-data** *and* **L2-routing**. When L1 nodes broadcast
DATA-M at SF9 (channel-gossip 2B-broadcast picks
`max(allowed_data_sfs)` = 9 for L1), L2 nodes listening on SF9
receive bits but discard them as malformed routing frames. The L1
channel content stays in L1 (**Principle 11 holds** — semantic
isolation is intact), but the airtime collision is cross-layer:
L1 channel broadcasts interfere with L2 routing-plane airtime.
This is realistic — production deployments need to handle it —
and is one of the patterns we want to observe.

## 6. Simulation block

```json
"simulation": {
  "duration_ms": 2400000,
  "step_ms": 1,
  "warmup_ms": 0,
  "seed": 1422,
  "node_startup_jitter_ms": 5000,
  "radio": {
    "sf": 8,
    "bw": 62.5,
    "cr": 5,
    "max_packet_bytes": 255,
    "snr_coherence_ms": 0,
    "duty_cycle": 0.01
  }
}
```

`warmup_ms = 0` per the design decision: BCN exchange must converge
under real physics (collision detection + duty cycle active throughout).

## 7. Debug window

Whole simulation traced:

```json
"config": {
  "debug_start_ms": 0,
  "debug_end_ms": 2400000
}
```

## 8. Topology block (link definitions)

Explicit static-static links with per-direction SNR (no path-loss
model). Symmetric links by default; asymmetric links called out
explicitly.

### L1 intra-layer (15 undirected pairs, all spelled out)

| from   | to     | SNR (dB) | reverse SNR | asym |
|--------|--------|----------|-------------|------|
| alice  | bob    | 18       | 18          | no   |
| alice  | carol  | 16       | 16          | no   |
| alice  | dave   | 13       | 13          | no   |
| bob    | dave   | 17       | 17          | no   |
| carol  | dave   | 15       | 15          | no   |
| carol  | frank  | 14       |  6          | YES  |
| dave   | eve    | 16       |  7          | YES  |
| dave   | grace  | 18       | 18          | no   |
| eve    | heidi  | 14       | 14          | no   |
| frank  | grace  | 15       | 15          | no   |
| grace  | heidi  | 17       | 17          | no   |
| grace  | ivan   | 16       |  8          | YES  |
| grace  | judy   | 18       | 18          | no   |
| heidi  | judy   | 14       | 14          | no   |
| ivan   | judy   | 15       | 15          | no   |

Asymmetric pairs: carol↔frank, dave↔eve, grace↔ivan (3 of 15 = 20%).
Degrees: alice 3, bob 2, carol 3, dave 5, eve 2, frank 2, grace 5,
heidi 3, ivan 2, judy 3. Mean 3.0.

### L2 intra-layer (15 undirected pairs, mirror of L1)

| from   | to     | SNR (dB) | reverse SNR | asym | mirrors          |
|--------|--------|----------|-------------|------|------------------|
| kate   | leo    | 18       | 18          | no   | alice↔bob        |
| kate   | mia    | 16       | 16          | no   | alice↔carol      |
| kate   | ned    | 13       | 13          | no   | alice↔dave       |
| leo    | ned    | 17       | 17          | no   | bob↔dave         |
| mia    | ned    | 15       | 15          | no   | carol↔dave       |
| mia    | peter  | 14       |  6          | YES  | carol↔frank      |
| ned    | olga   | 16       |  7          | YES  | dave↔eve         |
| ned    | quinn  | 18       | 18          | no   | dave↔grace       |
| olga   | rosa   | 14       | 14          | no   | eve↔heidi        |
| peter  | quinn  | 15       | 15          | no   | frank↔grace      |
| quinn  | rosa   | 17       | 17          | no   | grace↔heidi      |
| quinn  | sam    | 16       |  8          | YES  | grace↔ivan       |
| quinn  | tina   | 18       | 18          | no   | grace↔judy       |
| rosa   | tina   | 14       | 14          | no   | heidi↔judy       |
| sam    | tina   | 15       | 15          | no   | ivan↔judy        |

Asymmetric pairs: mia↔peter, ned↔olga, quinn↔sam.

### Bridge links (4 undirected pairs, all symmetric)

| from   | to     | SNR (dB) | layer |
|--------|--------|----------|-------|
| bridge | grace  | 16       | L1    |
| bridge | ivan   | 14       | L1    |
| bridge | quinn  | 16       | L2    |
| bridge | sam    | 14       | L2    |

Bridge's L2 contacts (quinn, sam) are the mirror positions of its
L1 contacts (grace, ivan). This gives the cross-layer DM pair
dave↔peter a 4-hop path: dave → grace → bridge → quinn → peter.

## 9. File layout

- **Scenario:** `scenarios/s14_realistic_debug.json`
- **Header `_desc`:** contains topology ASCII diagram (Section 2),
  conversation pair table, poster table, phase timeline summary,
  SF-coexistence note. Inject table is *not* inlined in `_desc`
  (it's in the `inject` block itself).

## 10. Expected metrics

After the run, via `tools/analyze.py`:

1. **DM delivery rate split by pair / hop count / layer** — separate
   1-hop, multi-hop, cross-layer numbers so we can attribute failures
   to a specific routing pattern.
2. **Channel reach** — for each post, % of same-layer non-poster
   nodes that received within X seconds (X = 60 s pull window + jitter).
3. **Per-phase counters** — DM% and channel% in phase 1, 2, 3
   separately. Mixed-phase regression (phase 3 worse than 1+2) would
   indicate contention between planes.
4. **Asymmetric-link routing choice** — for each asymmetric link, did
   routing pick the strong direction? Wrong-direction picks point at
   link-quality estimation bugs.
5. **Principle 11 check** — zero cross-layer channel msgs (must be 0).
6. **SF9 cross-layer airtime contention** — count of L2 routing
   frames (BCN/Q/RTS) lost to collision with L1 channel broadcasts on
   SF9. This is a new signal not visible in s12 (which used same
   routing SF for both layers).

## 11. Open questions / future work

- Whether L1 channel-broadcast SF9 collisions noticeably hurt L2
  routing — if yes, the answer is probably to change L1 data SFs to
  exclude 9 in production. This scenario is the way to find out.
- Whether the bridge time-share is a delivery bottleneck for cross-
  layer DM. If dave↔peter delivery is much worse than intra-layer
  multi-hop, the bridge schedule is the suspect.

## 12. Implementation notes

- The JSON will be machine-generated from this spec to keep link
  counts honest. A small Python helper that takes node names + an
  edge list and produces the directed-link block is the right shape.
- Use `seed=1422` (s14 series) for reproducibility.
- All names lowercase to match interactive-REPL conventions.
