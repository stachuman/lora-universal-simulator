# lus Config Format

The `lus` CLI reads a single JSON file (the *scenario*) that defines the
network topology, radio physics, per-node Lua scripts, and a test plan.

## Minimal Example

```json
{
  "simulation": {
    "duration_ms": 15000,
    "step_ms": 1,
    "radio": { "sf": 7, "bw": 250, "cr": 5 }
  },
  "config": {
    "debug_start_ms": 5000,
    "debug_end_ms": 10000
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua", "config": { "role": "originator" } },
    { "name": "bob",   "script": "examples/flooder.lua", "config": { "role": "forwarder"  } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob", "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 5000, "node": "alice", "command": "send hello" }
  ]
}
```

Run it:

```bash
./build/orchestrator/lus path/to/scenario.json events.ndjson
```

The simulator writes NDJSON events to `events.ndjson` and prints a short
summary to stderr.

---

## Differences from `meshcore_real_sim`

| MeshCore concept | lus equivalent |
|---|---|
| `firmware`, `role`, `_requires_plugins` | dropped — every node runs a Lua script |
| `nodes[i].firmware`, `nodes[i].role` | `nodes[i].script` (path) + `nodes[i].config` (table) |
| `simulation.firmware`, `simulation.hot_start` | dropped |
| `simulation.radio.cr` ∈ {1..4} (Semtech) | accepts any positive integer; lus does not enforce a CR set |
| Hard-coded MeshCore packet decoders | scripts emit their own `script_log` / `script_emit` events |
| ITM + SRTM terrain modeling | log-distance + haversine path-loss (`simulation.path_loss`) |

If you have a MeshCore config, the validator will reject it with a clear
"MeshCore-specific" message naming the offending field.

---

## Metadata Fields (optional)

Top-level fields prefixed with `_` are metadata — ignored by the
orchestrator but useful for the test runner and webapp.

| Field | Type | Description |
|-------|------|-------------|
| `_name` | string | Human-readable scenario name |
| `_desc` | string | Test description / purpose |

---

## Sections

### `simulation`

Drives the simulator's clock, default radio, and (optionally) the path-loss model.

### `config`

Optional scenario-wide Lua script config defaults. The runtime merges this
object into every node's `on_init` config first, then applies
`nodes[i].config` on top. Use it for knobs that should apply to all nodes,
such as debug windows:

```json
"config": {
  "debug_start_ms": 120000,
  "debug_end_ms": 180000
}
```

Per-node config can still override a global value when a scenario needs one
node to behave differently.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `duration_ms` | int | required | Total simulated time. Sim ends when `now ≥ duration_ms`. |
| `step_ms` | int | 1 | Simulator clock advance per tick. Currently must be ≥ 1; sub-millisecond requires a future µs-clock refactor. |
| `warmup_ms` | int | 0 | Duration at the start during which packets deliver instantly (no physics). Useful for converging routing tables before "real" traffic. |
| `seed` | int | 42 | Seed for the per-sim PRNG (used by `self:rand`, jitter, `sigma_db` shadowing, link-loss draws, startup-jitter draws, etc.). Pinned by default so reruns are bit-identical. |
| `epoch_start` | int | 1700000000 | Unix epoch the virtual clock counts from. |
| `node_startup_jitter_ms` | int | 0 | Per-node `on_init` is staged at a uniform random offset in `[0, node_startup_jitter_ms]` drawn from the seeded PRNG, modeling real-hardware boot variability. Until `on_init` fires, `on_recv` / `on_command` / `on_radio_busy` are dropped silently (radio "off"). `node_ready` event time reflects actual init time. Default 0 = synchronous init at t=0 (legacy). |
| `radio` | object | required | Default LoRa parameters; per-node overrides allowed. See below. |
| `path_loss` | object | none | Optional log-distance path-loss model. When present, link SNR/RSSI is computed from per-node `lat`/`lon`. See below. |

#### `simulation.radio`

| Field | Type | Default | Range | Description |
|---|---|---|---|---|
| `sf` | int | required | 5..12 | Default LoRa spreading factor |
| `bw` | int | required | typically 7..500 | LoRa bandwidth in **kHz** |
| `cr` | int | required | 5..8 | LoRa coding rate. RadioLib/MeshCore convention: 5 = CR4/5, 6 = CR4/6, 7 = CR4/7, 8 = CR4/8. The value is the airtime-formula multiplier directly (no `+4` shift). Validated at config load. |
| `cad_miss_prob` | float | 0.0 | 0.0..1.0 | Probability a CAD/LBT check misses a busy channel. `1.0` effectively disables LBT. |
| `cad_reliable_snr` | float | 0.0 | any | SNR above which CAD is "reliable" (low miss probability). |
| `cad_marginal_snr` | float | -10.0 | any | SNR below which CAD is "marginal" (≈100% miss). Linear interpolation in between. |
| `snr_coherence_ms` | float | 0.0 | ≥ 0 | OU-style fading coherence time. `0` = i.i.d. shadowing per packet. |
| `capture_locked_db` | float | 6.0 | ≥ 0 | dB margin under which a stronger ongoing signal *captures* (preserves) over a weaker new arrival. |
| `capture_unlocked_db` | float | 4.0 | ≥ 0 | dB margin for not-yet-locked captures. |
| `duty_cycle` | float | 0.01 | (0, 1] | Fraction of `duty_cycle_window_ms` allowed as cumulative TX airtime. Default 1% matches ETSI EN 300 220 (European 868 MHz ISM sub-band g1). |
| `duty_cycle_window_ms` | uint64 | 3600000 | > 0 | Length of the sliding window the duty-cycle limit is enforced over, in ms. Default 1 h matches ETSI. Test scenarios commonly tighten this to a few seconds to exercise the mechanism in short runs. |

The runtime tracks per-node TX airtime in a sliding window of `duty_cycle_window_ms`. If a fresh TX would push the window's airtime sum past `duty_cycle * window_ms`, it is deferred via `on_radio_busy(reason="duty_cycle_exceeded")` — same mechanism as LBT defers. Lua scripts may also self-regulate using the same window via `self:airtime_used_ms(window_ms)` and `self:oldest_tx_end_ms()` (both backed by the runtime's tracker). The `dv_dual_sf.lua` protocol does this pre-TX in `tx_with_retry` and `tx_flood`, emitting `duty_cycle_blocked` for telemetry. Per-node override via `nodes[].config.duty_cycle` and `nodes[].config.duty_cycle_window_ms`; the radio-block defaults are also injected into each node's config table as `_sim_duty_cycle` / `_sim_duty_cycle_window_ms` so scripts that want the inherited default can fall back to those.

#### `simulation.radio.hardware` (optional)

Per-radio TX/RX turnaround delays. Sub-millisecond on real LoRa modems
and below the current `step_ms=1` resolution; mostly informational at
this granularity.

| Field | Type | Default | Range | Description |
|---|---|---|---|---|
| `rx_to_tx_delay_ms` | int | 0 | ≥ 0 | Delay between leaving RX mode and entering TX mode |
| `tx_to_rx_delay_ms` | int | 0 | ≥ 0 | Delay between leaving TX mode and entering RX mode |

#### `simulation.path_loss`

Log-distance + log-normal shadowing with haversine inter-node distance.
When present (and node coordinates exist), link SNR/RSSI is computed at
sim init from positions; explicit `topology.links` entries override
path-loss output for the specific pair.

```
SNR(d_m) = tx_power_dbm − [ref_loss_db + 10·alpha·log10(d_m / ref_distance_m)] − noise_floor_db
         + N(0, sigma_db)        # per-pair shadowing draw, sigma_db>0 only
```

| Field | Type | Default | Range | Description |
|---|---|---|---|---|
| `model` | string | `"log_distance"` | `"log_distance"` or `"none"` | `"log_distance"` runs the per-pair baseline below; `"none"` skips it entirely so only explicit `topology.links[]` populate the link matrix and unlisted pairs return `getLink → false` (the runtime treats them as out of range). Use `"none"` when the operator has authored a complete topology — e.g., the SRTM+ITM webapp generator's directional output — and doesn't want log-distance fallback for unlisted pairs. |
| `alpha` | float | required | 1.0..6.0 (typical) | Path-loss exponent. 2 = free-space, 3 = suburban, 3.5 = urban, ≥4 = dense urban / heavy obstruction. |
| `sigma_db` | float | required | 0.0..20.0 | Log-normal shadowing standard deviation. `0.0` = deterministic. |
| `ref_distance_m` | float | required | > 0 | Reference distance d₀. |
| `ref_loss_db` | float | required | any | Path loss at `ref_distance_m`. Anchor for the model. |
| `noise_floor_db` | float | required | any | Receiver noise floor in dBm. |
| `tx_power_dbm` | float | required | any | Transmit power in dBm. |

A typical "Suburban" preset for ~1 km LoRa links: `alpha=3, sigma=0,
ref_distance_m=1, ref_loss_db=40, noise_floor=-120, tx_power=14`.

---

### `nodes`

An array of node definitions. Every entry needs `name` and `script`.

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Unique identifier. Used in `topology.links`, `commands`, expects, and event NDJSON. |
| `script` | string | required | Path to the Lua script (relative to `lus`'s working directory; the webapp passes the repo root via `LUS_CWD`). |
| `config` | object | `{}` | Arbitrary table passed to `on_init(self, config)`. |
| `lat` | float | none | WGS84 latitude (degrees). Required if `simulation.path_loss` is set and you want this node to participate in path-loss-driven links. |
| `lon` | float | none | WGS84 longitude (degrees). |
| `sf` | int | from `simulation.radio.sf` | Per-node SF override. |
| `bw` | int | from `simulation.radio.bw` | Per-node bandwidth override (kHz). |
| `cr` | int | from `simulation.radio.cr` | Per-node coding-rate override. |
| `sf_rx_set` | int[] | `[node.sf]` | Per-node receive-SF set. The default is single-SF reception (matches real Semtech hardware). Specify e.g. `[7,8,9,10,11,12]` for paper-style multi-SF reception. SF values are clamped to `[5, 12]`; out-of-range entries warn-and-clamp. |
| `tx_fail_prob` | float | 0.0 | (Y2 todo) Per-node probability a TX fails to leave the radio. Currently unused. |

The Lua script can call `self:set_rx_sf(sf)` or `self:set_rx_sf_set({sf...})`
at runtime to change `sf_rx_set` dynamically — see R.1.8.

---

### `topology.links` (optional)

Explicit per-pair link parameters. When `simulation.path_loss` is set,
links are computed from coordinates by default; entries here override
the computed value for the specific pair.

```json
"topology": {
  "links": [
    { "from": "alice", "to": "bob", "snr": 8.0, "rssi": -80.0, "bidir": true,
      "snr_std_dev": 1.5, "snr_coherence_ms": 200, "loss": 0.0 }
  ]
}
```

| Field | Type | Default | Description |
|---|---|---|---|
| `from` | string | required | Source node name |
| `to` | string | required | Destination node name |
| `snr` | float | required | Mean SNR in dB at the receiver |
| `rssi` | float | required | Mean RSSI in dBm at the receiver |
| `bidir` | bool | true | If true, the entry's snr/rssi/snr_std_dev applies to BOTH directions of the pair (`from → to` AND `to → from`). When false, only the `from → to` direction is set; the reverse is unaffected. Asymmetric topologies (e.g., the SRTM+ITM generator's default output) emit two `bidir: false` entries per pair, one for each direction, with potentially different SNR/RSSI per direction. |
| `snr_std_dev` | float | 0.0 | Per-packet log-normal shadowing on this link |
| `snr_coherence_ms` | int | 0 | Optional fading coherence; 0 = i.i.d. |
| `loss` | float | 0.0 | Probability the packet is dropped (in addition to SNR-based loss) |

If neither `topology.links` nor `simulation.path_loss` defines a link
between two nodes, they cannot hear each other.

---

### `commands` (optional)

Schedule script-driven actions during the run.

Two variants — exactly one of `command` / `lua` per entry:

```json
"commands": [
  { "at_ms": 5000,  "node": "alice", "command": "send dave hello" },
  { "at_ms": 10000, "lua":  "print(sim:time())" }
]
```

| Field | Type | Description |
|---|---|---|
| `at_ms` | int | Sim time at which the command fires |
| `node` | string | (with `command`) name of the node whose `on_command(self, cmd_str)` fires |
| `command` | string | (with `node`) text passed to `on_command` |
| `lua` | string | (alone) Lua snippet evaluated in the orchestrator's REPL context (sim:* available) |

---

### `expect` (optional)

Assertions evaluated at sim end. Each assertion has a `type`; the
remaining keys are type-specific. The runner exit code is 0 iff every
assertion passes.

```json
"expect": [
  { "type": "event_count_min", "event_type": "rx", "node": "bob", "min": 1 },
  { "type": "event_count",     "event_type": "drop_sf_mismatch", "node": "bob", "min": 0, "max": 0 },
  { "type": "script_emit_contains", "node": "bob", "emit_type": "delivered", "value": "hello-world" }
]
```

| Type | Required keys | Behavior |
|---|---|---|
| `event_count` | `event_type`, `min`, `max` | Count of matching events must be in `[min, max]`. `node` (optional) restricts by `from`/`to`/`node` field. |
| `event_count_min` | `event_type`, `min` | Count must be `≥ min`. |
| `event_count_max` | `event_type`, `max` | Count must be `≤ max`. |
| `script_emit_contains` | `node`, `emit_type`, `value` | At least one `script_emit` from `node` with the given `emit_type` whose JSON-serialized `data` contains `value` as a substring. Empty `value` matches any data. |
| `cmd_reply_contains` | `node`, `value` | Some `cmd_reply` from `node` contains `value` substring. |
| `cmd_reply_not_contains` | `node`, `value` | No `cmd_reply` from `node` contains `value`. |
| `airtime_total` | `node`, `min`, `max` | Sum of `airtime_ms` over `tx` events from `node` is in `[min, max]`. |

---

## Event vocabulary (NDJSON output)

Events written to the events file (one JSON object per line). Every
event has `type` and `time_ms`. Common additional fields below.

### Lifecycle
- `sim_start` — first line; carries `node_count`, `step_ms`, `warmup_ms`, `hot_start`.
- `node_ready` — once per node at init: `name`, `pub`, `role` (always `"script"` for lus), optional `lat`/`lon`.
- `sim_summary` — emitted once at end (counts, duration).
- `sim_end` — last line.
- `assertions` — per-expect verdict.

### Radio events
- `tx` — sender starts transmitting. Fields: `node`, `pkt` (FNV hash), `hex`, `airtime_ms`, optional script-supplied `label` and `info`.
- `rx` — receiver delivers a successfully-decoded packet. Fields: `from`, `to`, `snr`, `rssi`, `pkt`, `airtime_ms`. **`time_ms` is end-of-reception** (TX-start + airtime).
- `drop_weak` — RX dropped: SNR below SF threshold. Fields: `from`, `to`, `snr`, `threshold`, `pkt`.
- `drop_sf_mismatch` — RX dropped: receiver's `sf_rx_set` doesn't include the packet's SF. Fields: `from`, `to`, `packet_sf`, `rx_sf`, `pkt`.
- `drop_halfduplex` — RX dropped because the receiver was transmitting during the incoming packet's airtime. Fields: `from`, `to`, `pkt`, `airtime_ms`.
- `collision` — RX dropped due to a stronger interferer. Fields: `from`, `to`, `interferer`, `interferer_snr`, `snr_margin`, `pkt`.
- `tx_deferred` — TX deferred by LBT (`reason=channel_busy`) or by half-duplex (`reason=self_tx_in_flight`). Fields: `node`, `len`, `reason`, `sf`, `label`, `tx_info`, `busy_until_ms`. `label`/`tx_info` are echoed from the deferred `self:tx({label,info})` annotation; `busy_until_ms` is when the obstacle clears (LBT `_busy_until` for `channel_busy`, own-TX `end_ms` for `self_tx_in_flight`). The same payload is delivered to the script's `on_radio_busy(self, info)` callback.

### Script events
- `cmd_reply` — return value of `on_command`. Fields: `node`, `command`, `reply`.
- `script_log` — `self:log(...)` output. Fields: `node` (integer id), `msg`.
- `script_emit` — `self:emit(type, data)` output. Fields: `node`, `emit_type`, `data` (object).

#### Flight-tracking convention (debug observability)

Scripts that implement multi-hop flights (e.g. `scenarios/dv_dual_sf.lua`) include two fields in every flight-related `script_emit`'s `data` object so that visualizers and post-hoc analysis can group events end-to-end:

| Field | Type | Meaning |
|---|---|---|
| `origin` | int | Originator's node id (preserved across hops). |
| `payload` | string | The user message bytes (preserved across hops). Omitted at receiver-side events that fire BEFORE the DATA frame arrives (`rts_rx`, `cts_tx`, `rts_rx_dup`, `rts_already_acked`, `nack_tx`) — those frames don't carry the payload. |

The tuple `(origin, payload)` identifies a single end-to-end flight. This is debug-only metadata — it is **not** in the wire format; the script reads `origin` from the RTS/DATA frame and `payload` from the DATA frame (or its own state on the originator side). Real-hardware deployments would include the same data verbatim if the firmware port keeps these `:emit` calls intact.
- `node_stats` — (Y2 todo) per-node summary at sim end.

---

## Stderr summary

After the run, lus prints one line to stderr:

```
lus: 540 events emitted, 0 assertion failure(s)
```

Exit code is 0 iff `assertion failure(s)` is 0.

---

## Field rejection (validator behavior)

The webapp config validator rejects MeshCore-specific fields with
explicit error messages, so users porting MeshCore configs see clear
guidance:

```
{
  "errors": [
    "top-level field 'firmware' is MeshCore-specific and not accepted by lus",
    "nodes[0].'role' is MeshCore-specific; use 'script' + 'config' instead"
  ]
}
```

The C++ side of `lus` is more permissive — it ignores unknown top-level
fields silently — but the validator catches them at the HTTP layer.

---

## See also

- `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md`
  — the canonical Y1 design with rationale for each field
- `scenarios/dv_dual_sf.lua` and `scenarios/s01_dv_dual_sf.json`
  — a non-trivial protocol scenario exercising path-loss, multi-hop
  routing, dual-SF data delivery, and assertions
- `examples/flooder.lua`, `examples/sf_picker.lua`
  — minimal per-feature demos
