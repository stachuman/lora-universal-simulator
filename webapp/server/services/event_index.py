"""EventIndex service — loads NDJSON event files and provides query methods.

Extracted from visualization/visualize.py for use by the FastAPI webapp backend.
MeshCore-specific packet helpers (relay chain tracing, message extraction) stripped;
protocol-agnostic core retained.
"""

import array
import json
import logging
import mmap
import os
import threading
from bisect import bisect_left, bisect_right
from collections import OrderedDict

logger = logging.getLogger(__name__)


class EventIndex:
    """Memory-mapped index of simulation events for fast viewport queries.

    Memory-budget design: only event-INDEX data lives in Python objects
    (offsets, line lengths, times — all packed in array.array). The
    actual NDJSON event lines live in the OS page cache via mmap, so
    cache memory is amortized across the kernel's working-set logic
    rather than duplicated into Python dicts. For 1M events the
    in-Python footprint is ~25 MB (vs ~250 MB if every event were
    parsed into a dict at load).
    """

    def __init__(self, path: str):
        self.path: str = path
        # Per-event index arrays (packed). Indices into these arrays
        # match the integer indices stored in by_node, by_pkt,
        # cmd_replies. They cover only "regular" events — sim_start,
        # sim_end, node_ready, sim_summary, assertions, node_stats are
        # consumed during scan into their own metadata fields.
        self.times: array.array = array.array("Q")          # uint64 ms
        self.offsets: array.array = array.array("Q")        # uint64 byte offset of NDJSON line
        self.line_lengths: array.array = array.array("I")   # uint32 byte length (incl. trailing newline)

        # by_node uses string node names ("alice"); _index_event coerces
        # integer ids (which lus emits on script_log/script_emit) to names
        # via id_to_name when possible, otherwise falls back to str(id).
        self.by_node: dict[str, list[int]] = {}
        self.by_pkt: dict[str, list[int]] = {}   # pkt hash -> event indices
        self.nodes: list[dict] = []          # node metadata from node_ready
        self.node_set: dict[str, dict] = {}  # name -> metadata
        self.id_to_name: dict[int, str] = {}  # int id -> name (built from node_ready order)
        self.time_min: int = 0
        self.time_max: int = 0
        self.sim_info: dict = {}
        self.cmd_replies: list[int] = []     # indices of cmd_reply events
        # In lus, every node_stats event carries stats_type so all of them
        # land in repeater_stats. self.stats is retained for compatibility
        # with the meshcore_real_sim shape but stays empty in lus.
        self.stats: list[dict] = []
        self.repeater_stats: list[dict] = []
        self.summary: dict = {}              # sim_summary event (radio, delivery, acks, fate)
        self.assertions: dict = {}           # assertions event (pass/fail results)

        self._fd = None
        self._mmap: mmap.mmap | None = None

        self._load(path)

    def close(self) -> None:
        """Release the mmap and underlying file descriptor."""
        try:
            if self._mmap is not None:
                self._mmap.close()
        finally:
            self._mmap = None
        try:
            if self._fd is not None:
                self._fd.close()
        finally:
            self._fd = None

    def __del__(self):
        # Best-effort cleanup; errors during interpreter shutdown are silent.
        try:
            self.close()
        except Exception:
            pass

    def _load(self, path: str):
        logger.info("Loading %s...", path)
        parse_errors = 0
        # Open the file and mmap it. Reads cost zero RAM — they go
        # through the OS page cache. The fd is held by self until close().
        self._fd = open(path, "rb")
        try:
            file_size = os.fstat(self._fd.fileno()).st_size
            if file_size == 0:
                # mmap doesn't accept length=0; nothing to index.
                return
            self._mmap = mmap.mmap(self._fd.fileno(), 0, access=mmap.ACCESS_READ)
        except Exception:
            self._fd.close()
            self._fd = None
            raise

        mm = self._mmap
        size = mm.size()
        offset = 0
        while offset < size:
            nl = mm.find(b"\n", offset)
            if nl < 0:
                line_end = size
                line_len = size - offset
            else:
                line_end = nl
                line_len = nl - offset + 1   # include trailing \n
            line_bytes = mm[offset:line_end]
            if line_bytes:
                try:
                    ev = json.loads(line_bytes)
                    self._index_event(ev, offset, line_len)
                except json.JSONDecodeError:
                    parse_errors += 1
            offset += line_len

        if parse_errors:
            logger.warning("Skipped %d malformed JSON lines", parse_errors)

        if len(self.times):
            self.time_min = int(self.times[0])
            self.time_max = int(self.times[-1])

        # Infer roles for old event files that lack role in node_ready
        companion_names = {s["node"] for s in self.stats}
        for n in self.nodes:
            if n.get("role", "repeater") == "repeater" and n["name"] in companion_names:
                n["role"] = "companion"

        logger.info(
            "Loaded %d events, %d nodes, time range %d-%dms (%.1fs)",
            len(self.times), len(self.node_set),
            self.time_min, self.time_max,
            (self.time_max - self.time_min) / 1000,
        )

    def _index_event(self, ev: dict, offset: int, line_len: int):
        etype = ev.get("type", "")
        time_ms = ev.get("time_ms", 0)

        if etype == "sim_start":
            self.sim_info = ev
            return
        if etype == "sim_end":
            self.sim_info["end_ms"] = time_ms
            return
        if etype == "warmup_end":
            # Authoritative warmup-boundary marker emitted by the C++
            # runtime when _now_ms first crosses simulation.warmup_ms.
            # Surface it on sim_info so visualize.html can place its
            # overlay using the actual event time rather than the
            # configured value (the two should be equal but the event
            # is the source of truth).
            self.sim_info["warmup_end_ms"] = time_ms
            return
        if etype == "node_ready":
            name = ev["node"]
            meta = {"name": name, "role": ev.get("role", "script")}
            if "lat" in ev:
                meta["lat"] = ev["lat"]
                meta["lon"] = ev["lon"]
            self.node_set[name] = meta
            self.nodes.append(meta)
            # Map the implicit numeric id (registration order) to the name
            # so script_log / script_emit events that carry int node ids
            # can be re-indexed under the canonical string name.
            self.id_to_name[len(self.nodes) - 1] = name
            # Don't store as regular event — metadata only
            return
        if etype == "sim_summary":
            self.summary = ev
            return
        if etype == "assertions":
            self.assertions = ev
            return
        if etype == "node_stats":
            if "stats_type" in ev:
                self.repeater_stats.append(ev)
            else:
                self.stats.append(ev)
            return

        # Regular event — store a position pointer and a couple of indices.
        # The full dict is NOT retained; query methods re-parse on demand.
        idx = len(self.times)
        self.offsets.append(offset)
        self.line_lengths.append(line_len)
        self.times.append(time_ms)

        # Index by node(s) involved. lus's tx/rx events use string names
        # (`"node": "alice"`), but script_log/script_emit use the integer
        # id (`"node": 0`). Resolve to canonical string name via id_to_name
        # so query_node_range("alice", ...) matches both shapes.
        for key in ("node", "from", "to"):
            if key in ev:
                ident = ev[key]
                if isinstance(ident, int):
                    name = self.id_to_name.get(ident, str(ident))
                else:
                    name = ident
                if name not in self.by_node:
                    self.by_node[name] = []
                self.by_node[name].append(idx)

        # Index by packet fingerprint
        if "pkt" in ev:
            pkt = ev["pkt"]
            if pkt not in self.by_pkt:
                self.by_pkt[pkt] = []
            self.by_pkt[pkt].append(idx)

        if etype == "cmd_reply":
            self.cmd_replies.append(idx)

    # ── Lazy event-line reads via mmap ──────────────────────────────────
    def _read_event(self, idx: int) -> dict:
        """Read and parse a single event by index."""
        if self._mmap is None:
            raise RuntimeError("EventIndex._read_event after close()")
        off = self.offsets[idx]
        ln = self.line_lengths[idx]
        return json.loads(self._mmap[off:off + ln])

    # Event types that _index_event consumed into metadata fields and
    # didn't store an offset for. _read_contiguous walks the raw byte
    # range — which can contain these metadata lines wedged between
    # indexed events — so it must drop them on the way out.
    _METADATA_TYPES = frozenset((
        "sim_start", "sim_end", "warmup_end", "node_ready",
        "node_started", "node_died",
        "sim_summary", "assertions", "node_stats",
    ))

    def _read_contiguous(self, lo: int, hi: int) -> list[dict]:
        """Bulk-read a contiguous index range [lo, hi).

        Walks the mmap line-by-line via in-place find(), slicing only
        the bytes for each individual line. The earlier "one big slice
        + split" approach forced a multi-hundred-MB Python `bytes`
        copy of the underlying file region — which doubled peak memory
        on /events queries against 1M+-event sims.
        """
        if hi <= lo:
            return []
        if self._mmap is None:
            raise RuntimeError("EventIndex._read_contiguous after close()")
        start = self.offsets[lo]
        last = hi - 1
        end = self.offsets[last] + self.line_lengths[last]
        mm = self._mmap
        meta = self._METADATA_TYPES
        out: list[dict] = []
        cursor = start
        while cursor < end:
            nl = mm.find(b"\n", cursor, end)
            if nl < 0:
                line = mm[cursor:end]   # ~250 byte per-line slice
                cursor = end
            else:
                line = mm[cursor:nl]
                cursor = nl + 1
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue   # skip silently, matching _load's tolerance
            if ev.get("type") in meta:
                continue   # metadata line wedged between indexed events
            out.append(ev)
        return out

    def _read_indices(self, indices) -> list[dict]:
        """Read events at the given (possibly non-contiguous) indices."""
        return [self._read_event(i) for i in indices]

    # ── Public query API ────────────────────────────────────────────────
    def query_time_range(self, from_ms: int, to_ms: int, max_events: int = 20000) -> list[dict]:
        """Return events in [from_ms, to_ms]."""
        lo = bisect_left(self.times, from_ms)
        hi = bisect_right(self.times, to_ms)
        if hi - lo > max_events:
            # Subsample to avoid overwhelming the browser
            step = (hi - lo) // max_events
            return self._read_indices(range(lo, hi, step))
        return self._read_contiguous(lo, hi)

    def query_pkt(self, pkt: str) -> list[dict]:
        """Return all events for a packet fingerprint."""
        return self._read_indices(self.by_pkt.get(pkt, []))

    def query_node_range(self, node: str, from_ms: int, to_ms: int) -> list[dict]:
        """Return events involving a node in a time range."""
        indices = self.by_node.get(node, [])
        # by_node lists are appended in scan order, which is time order,
        # so we can short-circuit on the first index past to_ms.
        wanted: list[int] = []
        for i in indices:
            t = self.times[i]
            if t < from_ms:
                continue
            if t > to_ms:
                break
            wanted.append(i)
        return self._read_indices(wanted)

    def density(self, from_ms: int, to_ms: int, bucket_ms: int = 1000) -> dict:
        """Return per-node event density in time buckets (for zoomed-out view)."""
        lo = bisect_left(self.times, from_ms)
        hi = bisect_right(self.times, to_ms)

        n_buckets = max(1, (to_ms - from_ms + bucket_ms - 1) // bucket_ms)
        # node -> list of bucket counts by event category
        result: dict[str, dict[str, list[int]]] = {}

        # Density iterates a possibly-wide window. _read_contiguous reads
        # the full byte range once and parses line-by-line — much faster
        # than per-event reads.
        events = self._read_contiguous(lo, hi)
        for ev in events:
            t = ev.get("time_ms", 0)
            bucket = min((t - from_ms) // bucket_ms, n_buckets - 1)
            etype = ev["type"]

            # Categorize
            if etype == "tx":
                cat = "tx"
                node = ev["node"]
            elif etype == "rx":
                cat = "rx"
                node = ev["to"]
            elif etype.startswith("collision"):
                cat = "collision"
                node = ev["to"]
            elif etype.startswith("drop"):
                cat = "drop"
                node = ev.get("to", ev.get("node", ""))
            elif etype == "cmd_reply":
                cat = "cmd"
                node = ev["node"]
            else:
                continue

            if node not in result:
                result[node] = {}
            if cat not in result[node]:
                result[node][cat] = [0] * n_buckets
            result[node][cat][bucket] += 1

        return {
            "from_ms": from_ms,
            "to_ms": to_ms,
            "bucket_ms": bucket_ms,
            "n_buckets": n_buckets,
            "nodes": result,
        }

    def find_msg_tx(self, node: str, after_ms: int) -> dict | None:
        """Find the first TX from a node after a given time (for cmd_reply->TX correlation)."""
        indices = self.by_node.get(node, [])
        for i in indices:
            if self.times[i] < after_ms:
                continue
            ev = self._read_event(i)
            if ev.get("type") == "tx":
                return ev
        return None

    def get_meta(self) -> dict:
        return {
            "nodes": self.nodes,
            "time_min": self.time_min,
            "time_max": self.time_max,
            "event_count": len(self.times),
            "sim": self.sim_info,
            "stats": self.stats,
            "repeater_stats": self.repeater_stats,
            "summary": self.summary,
            "assertions": self.assertions,
        }


def load_topology(path: str) -> dict:
    """Load topology from config JSON for map view."""
    logger.info("Loading topology from %s...", path)
    with open(path, "r") as f:
        config = json.load(f)

    nodes = []
    has_geo = False
    for n in config.get("nodes", []):
        node = {"name": n["name"], "role": n.get("role", "repeater")}
        if "lat" in n and "lon" in n:
            node["lat"] = n["lat"]
            node["lon"] = n["lon"]
            has_geo = True
        else:
            node["lat"] = None
            node["lon"] = None
        nodes.append(node)

    links = []
    topo = config.get("topology", {})
    for link in topo.get("links", []):
        entry = {
            "from": link["from"],
            "to": link["to"],
            "snr": link.get("snr", 0),
            "rssi": link.get("rssi", 0),
            "snr_std_dev": link.get("snr_std_dev", 0),
            "loss": link.get("loss", 0),
            "bidir": link.get("bidir", False),
        }
        links.append(entry)
        if entry["bidir"]:
            rev = dict(entry)
            rev["from"], rev["to"] = rev["to"], rev["from"]
            links.append(rev)

    logger.info("Topology: %d nodes, %d links, geo=%s", len(nodes), len(links), has_geo)
    return {"nodes": nodes, "links": links, "has_geo": has_geo}


class EventIndexCache:
    """LRU cache for EventIndex instances, limiting memory usage.

    The EventIndex is memory-intensive (~50MB per 100k events), so this
    cache limits the number of concurrently loaded indexes by evicting
    the least-recently-used entry when the cache is full.

    Uses per-sim_id locks to prevent duplicate concurrent loads of the
    same simulation file.
    """

    def __init__(self, max_size: int = 5):
        self._max_size = max_size
        self._cache: OrderedDict[str, EventIndex] = OrderedDict()
        self._lock = threading.Lock()
        self._loading: dict[str, threading.Lock] = {}  # per-sim load locks

    def get(self, sim_id: str, events_path: str) -> EventIndex:
        """Get an EventIndex for a simulation, loading it if necessary.

        Moves the accessed entry to the end (most-recently-used position).
        If the cache is full and a new entry must be loaded, the
        least-recently-used entry is evicted first.  Per-sim_id locks
        prevent duplicate concurrent loads of the same file.

        If the events file has been modified since the cached index was
        built (sim was still running on first load and has since written
        more events), the cached entry is evicted and reloaded. Without
        this, opening map_live during a long sim caches a partial index
        and re-reads always return the partial view.
        """
        try:
            current_mtime_ns = os.stat(events_path).st_mtime_ns
        except OSError:
            current_mtime_ns = 0

        with self._lock:
            if sim_id in self._cache:
                cached = self._cache[sim_id]
                if getattr(cached, "_loaded_mtime_ns", 0) >= current_mtime_ns:
                    self._cache.move_to_end(sim_id)
                    return cached
                # File grew or changed since the index was built — evict.
                logger.info(
                    "EventIndexCache: file mtime changed for sim_id=%s; reloading",
                    sim_id,
                )
                self._cache.pop(sim_id).close()
            # Get or create a per-sim load lock
            if sim_id not in self._loading:
                self._loading[sim_id] = threading.Lock()
            load_lock = self._loading[sim_id]

        # Serialize loads of the same sim_id (but allow different sims in parallel)
        with load_lock:
            # Re-check after acquiring load lock — another thread may have loaded it
            with self._lock:
                if sim_id in self._cache:
                    cached = self._cache[sim_id]
                    if getattr(cached, "_loaded_mtime_ns", 0) >= current_mtime_ns:
                        self._cache.move_to_end(sim_id)
                        self._loading.pop(sim_id, None)
                        return cached
                    del self._cache[sim_id]

            logger.info("EventIndexCache: loading sim_id=%s from %s", sim_id, events_path)
            try:
                index = EventIndex(events_path)
                index._loaded_mtime_ns = current_mtime_ns
            except Exception:
                # Ensure the per-sim load lock doesn't stay in _loading forever
                # if EventIndex construction fails (corrupted NDJSON, I/O error
                # etc). Without this, every subsequent get() for this sim_id
                # re-uses a stale lock AND _loading grows without bound.
                with self._lock:
                    self._loading.pop(sim_id, None)
                raise

            with self._lock:
                # Evict LRU entries if at capacity
                while len(self._cache) >= self._max_size:
                    evicted_id, evicted_idx = self._cache.popitem(last=False)
                    evicted_idx.close()
                    logger.info("EventIndexCache: evicted sim_id=%s", evicted_id)

                self._cache[sim_id] = index
                self._loading.pop(sim_id, None)
                return index

    def evict(self, sim_id: str) -> None:
        """Remove a specific simulation's index from the cache."""
        with self._lock:
            evicted = self._cache.pop(sim_id, None)
            if evicted is not None:
                evicted.close()
                logger.info("EventIndexCache: evicted sim_id=%s", sim_id)
