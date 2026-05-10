# Path-Loss "none" + Asymmetric-Link Orchestrator Adoption — Design

Status: design (awaiting user review)
Author: 2026-05-10 session
Companion: `2026-05-09-srtm-itm-topology-design.md` (the topology-
generation side that produces the asymmetric `topology.links[]`
this spec wires into the runtime).

## Background

Plan 3 (SRTM+ITM topology) produces `topology.links[]` with
directional entries: each pair is two `bidir: false` rows carrying
per-direction `snr` / `rssi` / `snr_std_dev` derived from ITM's
median + reliability bracket. The runtime side already handles
this format correctly for *listed* pairs:

- `MatrixLinkModel::setLink(sender, receiver, ...)` is per-directed-
  pair (one (i,j) cell at a time).
- `SimController::initialize()` loops `topology.links[]` and only
  calls `setLink(b, a, ...)` when `l.bidir == true` — so explicit
  asymmetric entries land in their respective cells.
- `LinkFadingState` is keyed by directed pair; `snr_std_dev` (now
  the corrected 1σ from commit 1c9c21e) drives per-direction
  Ornstein-Uhlenbeck fading independently.

Two gaps remain:

1. **Path-loss baseline always runs.** Today
   `SimController::initialize()` first invokes `PathLossModel` to
   write a log-distance baseline for every (i,j) pair, then lets
   `topology.links[]` *override* listed pairs. With an SRTM-derived
   topology where ITM determined some pairs are unreachable (SRTM
   miss, below `min_snr_db`, or simply outside the kept top-K),
   those unlisted pairs silently fall back to a log-distance number
   that contradicts ITM's terrain-aware verdict. Result: a pair ITM
   said couldn't see each other still delivers in the simulation.

2. **No test exercises the asymmetric-delivery path.** All current
   integration tests use `bidir: true` (or rely on the path-loss
   baseline). A flight where A→B is fine but B→A is below the
   SF12 floor (so the ACK never gets back) has no coverage; future
   regressions in the per-directed-link fading or collision-
   evaluation code would slip through.

## Goal

Two changes that close the loop between Plan 3's topology generator
and the runtime:

1. Add a `simulation.path_loss.model = "none"` value that suppresses
   the log-distance baseline. With this set, `getLink(i, j)` returns
   `false` for any pair not explicitly listed in `topology.links[]`,
   and the runtime cleanly skips it (no rx event, no drop, just
   silence — exactly as if the two nodes were out of range).

2. Add two new integration scenarios under `test/` that exercise
   the asymmetric + sparse-explicit paths. Existing scenarios stay
   as-is (they use `bidir: true` and `model: "log_distance"`; both
   continue to behave byte-identically).

## Scope

- C++ runtime: parse + accept `model: "none"`; gate `PathLossModel`
  construction + the per-pair baseline loop on it. ~30 LOC across
  three files.
- Validator: accept `"none"` as a recognized model value.
- Two test scenario JSONs under `test/`.
- One paragraph in `docs/CONFIG_FORMAT.md` documenting the new
  value and `bidir: false` semantics.

## Out of scope

- Changing the default model. `model` defaults to `"log_distance"`
  unchanged; `"none"` is opt-in.
- Converting existing tests to asymmetric form. Per the
  brainstorming-question answer, existing `bidir: true` tests are
  left untouched.
- Webapp pydantic schema. The simulation-side `PathLossModel`
  pydantic class doesn't validate `model`'s string value today
  (it's just `str`); accepting `"none"` works without code change.
- Lua-script-visible API. Scripts don't read `path_loss.model`;
  this is purely orchestrator plumbing.

## Schema change

`core/topology/JsonConfig.h` — `PathLossSpec.model` is already
`std::string`. Two values are now recognized:

- `"log_distance"` (default, unchanged): runs `PathLossModel` and
  writes a baseline for every pair.
- `"none"` (new): does NOT run `PathLossModel`. Only pairs in
  `topology.links[]` populate the link matrix; unlisted pairs leave
  `getLink` returning `false` (the runtime contract for
  "no link" — `deliverReceptionsForStep` already handles it
  correctly via the existing `if (!_links->getLink(...)) continue;`
  guard).

Any other value on `simulation.path_loss.model` is now a validation
error (today the field is parsed but its value isn't checked).

## Runtime behaviour

`orchestrator/runtime/SimController.cpp::initialize()` (around the
existing `_path_loss = std::make_unique<PathLossModel>(...)` block,
and the `for (int i = 0; i < n; ++i)` baseline loop that follows):

```cpp
const bool baseline_enabled =
    (_cfg.simulation.path_loss.model != "none");

if (baseline_enabled) {
    _path_loss = std::make_unique<PathLossModel>(plc, _rng);
    _path_loss->initializeNodes(n);
    // ... existing per-pair setLink loop ...
}
// else: _path_loss stays nullptr; setLink loop never runs.
```

The asymmetry-coherence rebuild path (`rebuildLinksFromPathLoss`,
called every `asymmetry_coherence_ms`) must also no-op when the
baseline is off — already trivially safe because it gates on
`_path_loss != nullptr`, but the spec calls it out so the
implementer doesn't introduce a UB null-deref.

The existing `topology.links[]` loop runs unchanged regardless of
`model`; explicit links are always honoured.

## Validation

`core/topology/JsonConfig.cpp::validate(...)`: append a check to
the existing path-loss validation block:

```cpp
const auto& m = cfg.simulation.path_loss.model;
if (m != "log_distance" && m != "none") {
    errors.push_back(
        "simulation.path_loss.model must be \"log_distance\" or \"none\""
        " (got \"" + m + "\")");
}
```

This rejects typos that would previously silently fall back to the
log-distance default.

## Test scenarios

### `test/t27_asymmetric_link.json`

Two-node A↔B scenario with explicit asymmetric links: A→B at SNR
high enough that DATA decodes at SF7 fine, but B→A at SNR below
the SF12 floor (around -25 dB). Originator at A, sends to B.

Expectation: A's RTS reaches B (A→B link viable). B's CTS goes out
on B→A — never decodes at A (drop_weak). A retries RTS some times,
hits `rts_giveup`. Asserts:

- `event_count` for `drop_weak` to A from B ≥ 1.
- `script_emit_contains` at A with `emit_type=rts_giveup`.
- `script_emit_contains` at B with `emit_type=delivered` is **not**
  present (use the absence by checking `event_count` for that
  script-emit type stays at 0).

This test uses `path_loss.model: "log_distance"` (the default) and
overrides the two-node link with explicit asymmetric `bidir: false`
entries — proving the override path works on its own.

### `test/t28_path_loss_none_sparse.json`

Three-node line `alice` — `bob` — `carol` with `path_loss.model:
"none"`. Explicit `topology.links[]` lists ONLY `alice↔bob` and
`bob↔carol` (no `alice↔carol`). alice sends to carol (must hop
through bob since alice↔carol has no link).

Expectation: under `model: "none"`, the alice↔carol pair returns
`false` from `getLink` so alice never receives carol's beacons or
direct messages and vice versa. Asserts:

- `script_emit_contains` at carol with `emit_type=delivered` and
  payload from alice — proves the multi-hop path works.
- No `rx` event with `from=alice, to=carol` or `from=carol,
  to=alice` — proves the unlisted pair is truly silent (model=none
  did its job).

Both scenarios use `examples/flooder.lua` (or a similar minimal
script) to keep the test surface small; the asymmetric-link
behaviour is the C++ runtime's responsibility, not the script's.

## Documentation

`docs/CONFIG_FORMAT.md`:

- Note that `simulation.path_loss.model` accepts `"log_distance"`
  (default) or `"none"`. A short paragraph on what `"none"` does
  and when it's useful (operator authored a complete topology;
  doesn't want log-distance leakage).
- Note that `topology.links[].bidir: false` is supported and that
  pairs of asymmetric directional entries are how the SRTM
  generator emits its output.

## Risks

- **Existing scenarios.** All current scenarios either use the
  `log_distance` default explicitly or omit `model` entirely (also
  defaults to `log_distance`). The new validator rejection of
  unrecognized values could break a scenario someone hand-authored
  with a typo — flagged as a feature not a bug, since today it
  would silently default.
- **Empty links + `model: "none"`.** A scenario with `model: "none"`
  AND empty `topology.links[]` would have no link matrix at all —
  every pair returns `getLink → false`. Simulation still runs (just
  silent). Worth a note in the validator? **No** — that's exactly
  what the operator asked for; no warning needed.
- **`PathLossModel` pointer guard.** Several places consult
  `_path_loss` (e.g., the asymmetry coherence resample code).
  Every read must be `if (_path_loss) ...`. The implementation
  task lists the call sites; no other surface change needed.
- **Webapp pydantic compatibility.** The pydantic `PathLossModel`
  class today has `model: str` with no enum constraint, so the
  saved-topology / generate-srtm responses with `model: "none"`
  round-trip cleanly through pydantic without schema work.

## Acceptance criteria

- `cmake --build build -j` succeeds (no warnings, no errors).
- `simulation.path_loss.model = "none"` parses cleanly.
- `simulation.path_loss.model = "garbage"` produces a validator
  error pointing at the field.
- `bash test/run_tests.sh` reports 35/35 passed (was 33 + t27 + t28).
- Existing 33 tests continue to pass byte-identically (no behaviour
  change for `model: "log_distance"` or omitted-model paths).
- `docs/CONFIG_FORMAT.md` documents the new `"none"` value and
  `bidir: false` semantics.
