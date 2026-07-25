#!/usr/bin/env python3
"""Webapp ADAPTER onto the canonical DM/channel delivery analysis.

★ This file contains NO analysis. It used to: it was a 1610-line copy of
MeshRoute's `tools/dm_delivery_breakdown.py`, taken by the 2026-05-23 plan
("Copy the CLI tool into webapp/server/services/dm_breakdown.py"), and it went
stale — no cross-layer accounting at all (`tx_enqueue_xl` / `xl_orig`: zero
occurrences, so the webapp's Delivery panel reported DM numbers with the whole
cross-layer class MISSING), no fail-loud denominator (BASELINE 2026-07-25d), no
layer-aware keying (BASELINE 2026-07-25g). Owner ruling 2026-07-25: *"webapp
should use the same dm delivery script — not a local copy" / "One source of
truth."*

So the analysis now comes from the canonical module, located by
`tools/meshroute_canonical.py` and executed as-is. What stays HERE is only what
is genuinely the webapp's own concern:

  * `compute_breakdown()` — unchanged signature/argument surface, still returns
    the payload dict the `/api/sims/{id}/dm_breakdown` route and the Delivery
    sidebar consume (`summary` / `messages` / `channels`).
  * `DmBreakdownCache` — the mtime-invalidated LRU + its lock (unchanged).
  * capturing the canonical tool's stdout diagnostics into the payload instead
    of letting them leak onto the server's stdout (see `warnings` below).

Running `lus` is NOT this file's job and never was on the webapp path — the
fork's `maybe_run()` was dead CLI code. The webapp spawns lus in
`server/services/sim_manager.py`; that is untouched.

Payload keys, relative to the canonical CLI's `--json --mode all --detail`:
  * `summary`, `messages`, `channels` — identical (pinned by
    `webapp/tests/test_dm_breakdown_service.py`).
  * `cross_layer` — ADDED. The authoritative cross-layer delivery metric
    (`tx_enqueue_xl` + the `(origin,ctr,target_layer)`-matched `delivered`;
    BASELINE "cross-layer DMs: X/Y"). The canonical `--json` mode cannot express
    it — `render_json()` emits only `summary`/`messages`, and `xl_stats` is
    consumed solely by the CLI's text branch — which is why this adapter calls
    the analysis in-process rather than shelling out to `--json`.
  * `warnings` — ADDED. Human-readable diagnostic lines. The ambiguous-short-id
    warning is derived from the canonical module's STRUCTURED `ALIASED_IDS` dict
    (see `_aliasing_warnings`), not scraped from its printed text — the tool emits
    that block to stderr for humans and points programmatic consumers at the dict.
    Anything the tool ever writes to stdout is appended as a catch-all, so no
    diagnostic can vanish unnoticed.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import threading
from collections import OrderedDict, defaultdict
from pathlib import Path

# The resolver lives in this repo's `tools/` (one home for "where is MeshRoute"),
# loaded by explicit path: `tools/` is not a package and must NOT go on sys.path
# (it holds `test_analyze.py`, `topology.py`, ... which would shadow/confuse
# collection). Import failure here is fatal on purpose — C2, no silent fallback.
_REPO_ROOT = Path(__file__).resolve().parents[3]
_RESOLVER_PATH = _REPO_ROOT / "tools" / "meshroute_canonical.py"


def _load_resolver():
    if not _RESOLVER_PATH.is_file():
        raise RuntimeError(
            f"dm_breakdown: the canonical-tool resolver is missing at "
            f"{_RESOLVER_PATH} — the delivery analysis cannot be located and this "
            f"service deliberately holds no copy of it.")
    spec = importlib.util.spec_from_file_location(
        "meshroute_canonical", str(_RESOLVER_PATH))
    if spec is None or spec.loader is None:
        raise RuntimeError(
            f"dm_breakdown: cannot load the canonical-tool resolver at "
            f"{_RESOLVER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_resolver = _load_resolver()
CanonicalToolMissing = _resolver.CanonicalToolMissing

# The canonical module keeps `ALIASED_IDS` as a MODULE-LEVEL global (set by
# load_config, read by fmt_node), so two concurrent computes over DIFFERENT
# configs could render one run's rows with the other's aliases. Serialise them:
# the cache below already computes outside its own lock and calls a concurrent
# double-compute "harmless", which stops being true with shared module state.
_ANALYSIS_LOCK = threading.Lock()


def compute_breakdown(config_path, events_path, *, mode="all",
                      detail=False, pair=None, post=None):
    """Run the canonical analysis and return the payload dict.

    mode: "dm" | "channel" | "all". For "all"/"channel" the result has a
    "channels" key; for "all"/"dm" it has "summary" (+ "messages" if detail),
    plus "cross_layer". "warnings" is always present (possibly empty).

    Raises `CanonicalToolMissing` if the MeshRoute checkout holding the analysis
    cannot be found — deliberately loud, never an empty or zeroed result.
    """
    canonical = _resolver.load_canonical()
    with _ANALYSIS_LOCK:
        return _compute(canonical, config_path, events_path,
                        mode, detail, pair, post)


def _aliasing_warnings(M, cfg):
    """The ambiguous-short-id warning, built from `ALIASED_IDS` — never scraped.

    `ALIASED_IDS` ({short id: [node names]}) is the canonical module's STRUCTURED
    record of ids shared by several nodes, populated by `load_config`; the tool
    prints an equivalent block for humans and directs programmatic consumers here.
    Reading the dict means a future wording change, or a move between stdout and
    stderr, cannot silently empty this warning — which is exactly what happened
    when the canonical block moved to stderr and text-scraping went quiet.

    ★ Must be called INSIDE the compute critical section: `ALIASED_IDS` is a
    module-level global that each `load_config` overwrites.
    """
    aliased = getattr(M, "ALIASED_IDS", None) or {}
    if not aliased:
        return []
    layer_of = {n["name"]: (n.get("config") or {}).get("layer_id")
                for n in cfg.get("nodes", [])}
    lines = ["!! AMBIGUOUS NODE IDS — a short id is unique only WITHIN a layer, so rows "
             "keyed on these ids may merge or mislabel:"]
    for nid, names in sorted(aliased.items()):
        who = ", ".join(f"{nm} (layer {layer_of.get(nm)})" for nm in names)
        lines.append(f"     id {nid}: {who}")
    return lines


def _compute(M, config_path, events_path, mode, detail, pair, post):
    """The canonical tool's own `main()` call sequence, minus argparse/printing.

    ★ Mirrors `dm_delivery_breakdown.py:main()` step for step and adds NO
    analysis of its own. `webapp/tests/test_dm_breakdown_service.py` compares
    this payload against that CLI's `--json --detail` output, so a drift in
    either direction is a test failure rather than a silent divergence.
    """
    # Catch-all: anything the canonical tool ever prints to stdout becomes a
    # payload `warning` rather than server stdout noise (and rather than being
    # dropped). Normally empty -- its named diagnostics go to stderr, and the
    # ambiguous-id one is read STRUCTURALLY below, not scraped from here.
    diag = io.StringIO()
    with contextlib.redirect_stdout(diag):
        cfg, id_to_name, name_to_id, slot_to_id, hash_layer_to_name, id_to_layer \
            = M.load_config(config_path)
        # Read ALIASED_IDS immediately after the load_config that sets it, inside
        # this same critical section -- it is a module-level global (see the lock).
        warnings = _aliasing_warnings(M, cfg)
        msgs, arrival_by_payload, drops, gw_giveup, gw_layers, second_leg, xl_stats \
            = M.analyse(events_path, slot_to_id, hash_layer_to_name, id_to_layer)
        gw_home, gw_visit = M.gateway_layers(cfg)

        # Post-pass: resolve cross-layer target_id + arrival_at_target_ms
        # (needs name_to_id, which analyse() does not have).
        for r in msgs.values():
            if not r.get("via_gateway"):
                continue
            t_layer = r.get("target_layer_id")
            t_hash = r.get("dst_key_hash32")
            if t_layer is None or t_hash is None:
                continue
            t_name = hash_layer_to_name.get((t_layer, t_hash))
            if t_name is None:
                continue
            t_id = name_to_id.get(t_name)
            if t_id is None:
                continue
            r["target_id"] = t_id
            if r["payload"] is not None:
                r["arrival_at_target_ms"] = arrival_by_payload.get(
                    (t_id, r["payload"]))
            if (r["arrived_ms"] is not None and not M._arrived(r)
                    and (r["origin"], r.get("dst_key_hash32")) not in gw_giveup):
                r["second_leg"], r["second_leg_loc"] = M.classify_second_leg(
                    r, second_leg, gw_home, gw_visit, id_to_layer)

        # Cross-layer sends dropped for want of a gateway route still count
        # toward the honest denominator.
        no_gw_by_pair = defaultdict(int)
        for dp in drops:
            t_name = hash_layer_to_name.get(
                (dp["target_layer_id"], dp["dst_key_hash32"]))
            t_id = name_to_id.get(t_name) if t_name else None
            if t_id is not None:
                no_gw_by_pair[(dp["origin"], t_id)] += 1

        # Explicit pair filter wins; else the scenario's configured commands,
        # which also yield the fail-loud `intended` denominator (BASELINE 25d).
        # (No `--all` equivalent: this service has never exposed one.)
        explicit = M.parse_pair_filter(pair, name_to_id)
        intended = None
        if explicit is not None:
            pair_filter = explicit
        else:
            pair_filter, intended = M.configured_pairs(cfg, name_to_id,
                                                       hash_layer_to_name)

        rows = M.summarise(msgs, pair_filter, id_to_name, no_gw_by_pair, intended)

        channel_rows = None
        if mode in ("channel", "all"):
            posts_meta = M.configured_channel_posts(cfg, name_to_id)
            M.analyse_channel(events_path, slot_to_id, posts_meta, name_to_id)
            rows_for_summary = posts_meta
            if post:
                pat = post.lower()
                rows_for_summary = [
                    p for p in posts_meta
                    if pat in (p.get("payload") or "").lower()
                ]
            channel_rows = M.summarise_channel(rows_for_summary, cfg, id_to_name)

    warnings += [ln for ln in diag.getvalue().splitlines() if ln.strip()]

    if mode == "channel":
        return {"channels": channel_rows or [], "warnings": warnings}

    # The canonical tool has no pure payload BUILDER — `render_json()` prints.
    # Capture it exactly as the tool's own `main()` does for `--mode all`
    # (dm_delivery_breakdown.py:2608-2618) rather than re-deriving the shape.
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        M.render_json(rows, msgs, pair_filter, id_to_name, detail)
    payload = json.loads(buf.getvalue())

    if mode == "all":
        payload["channels"] = channel_rows or []
    payload["cross_layer"] = dict(xl_stats)
    payload["warnings"] = warnings
    return payload


class DmBreakdownCache:
    """mtime-invalidated LRU memo of the full (mode=all, detail=True)
    breakdown payload, keyed by sim_id. The payload is small plain JSON,
    so unlike EventIndexCache this keeps the computed dict, not an index."""

    def __init__(self, max_size: int = 8):
        self._max_size = max_size
        self._cache: "OrderedDict[str, tuple[int, dict]]" = OrderedDict()
        self._lock = threading.Lock()

    def get(self, sim_id: str, config_path: str, events_path: str) -> dict:
        try:
            mtime = os.stat(events_path).st_mtime_ns
        except OSError:
            mtime = 0
        with self._lock:
            hit = self._cache.get(sim_id)
            if hit is not None and hit[0] >= mtime:
                self._cache.move_to_end(sim_id)
                return hit[1]
        # Compute outside the lock (idempotent; a concurrent double-compute
        # is harmless and cheaper than holding the lock through a file walk).
        payload = compute_breakdown(config_path, events_path,
                                    mode="all", detail=True)
        with self._lock:
            self._cache[sim_id] = (mtime, payload)
            self._cache.move_to_end(sim_id)
            while len(self._cache) > self._max_size:
                self._cache.popitem(last=False)
        return payload

    def evict(self, sim_id: str) -> None:
        with self._lock:
            self._cache.pop(sim_id, None)
