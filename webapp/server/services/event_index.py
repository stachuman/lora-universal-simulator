"""EventIndex service — loads NDJSON event files and provides query methods.

Extracted from visualization/visualize.py for use by the FastAPI webapp backend.
MeshCore-specific packet helpers (relay chain tracing, message extraction) stripped;
protocol-agnostic core retained.
"""

import json
import logging
import threading
from bisect import bisect_left, bisect_right
from collections import OrderedDict

logger = logging.getLogger(__name__)


class EventIndex:
    """In-memory index of simulation events for fast viewport queries."""

    def __init__(self, path: str):
        self.events: list[dict] = []
        self.times: list[int] = []          # parallel to events, for bisect
        self.by_node: dict[str, list[int]] = {}  # node -> event indices
        self.by_pkt: dict[str, list[int]] = {}   # pkt hash -> event indices
        self.nodes: list[dict] = []          # node metadata from node_ready
        self.node_set: dict[str, dict] = {}  # name -> metadata
        self.time_min: int = 0
        self.time_max: int = 0
        self.sim_info: dict = {}
        self.cmd_replies: list[int] = []     # indices of cmd_reply events
        self.stats: list[dict] = []          # companion node_stats events
        self.repeater_stats: list[dict] = []  # repeater node_stats (with stats_type)
        self.summary: dict = {}              # sim_summary event (radio, delivery, acks, fate)
        self.assertions: dict = {}           # assertions event (pass/fail results)

        self._load(path)

    def _load(self, path: str):
        logger.info("Loading %s...", path)
        parse_errors = 0
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    parse_errors += 1
                    continue
                self._index_event(ev)

        if parse_errors:
            logger.warning("Skipped %d malformed JSON lines", parse_errors)

        if self.events:
            self.time_min = self.times[0]
            self.time_max = self.times[-1]

        # Infer roles for old event files that lack role in node_ready
        companion_names = {s["node"] for s in self.stats}
        for n in self.nodes:
            if n.get("role", "repeater") == "repeater" and n["name"] in companion_names:
                n["role"] = "companion"

        logger.info(
            "Loaded %d events, %d nodes, time range %d-%dms (%.1fs)",
            len(self.events), len(self.node_set),
            self.time_min, self.time_max,
            (self.time_max - self.time_min) / 1000,
        )

    def _index_event(self, ev: dict):
        etype = ev.get("type", "")
        time_ms = ev.get("time_ms", 0)

        if etype == "sim_start":
            self.sim_info = ev
            return
        if etype == "sim_end":
            self.sim_info["end_ms"] = time_ms
            return
        if etype == "node_ready":
            meta = {"name": ev["node"], "pub": ev.get("pub", ""),
                    "role": ev.get("role", "repeater")}
            if "lat" in ev:
                meta["lat"] = ev["lat"]
                meta["lon"] = ev["lon"]
            self.node_set[ev["node"]] = meta
            self.nodes.append(meta)
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

        idx = len(self.events)
        self.events.append(ev)
        self.times.append(time_ms)

        # Index by node(s) involved
        for key in ("node", "from", "to"):
            if key in ev:
                name = ev[key]
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

    def query_time_range(self, from_ms: int, to_ms: int, max_events: int = 20000) -> list[dict]:
        """Return events in [from_ms, to_ms]."""
        lo = bisect_left(self.times, from_ms)
        hi = bisect_right(self.times, to_ms)
        if hi - lo > max_events:
            # Subsample to avoid overwhelming the browser
            step = (hi - lo) // max_events
            return [self.events[i] for i in range(lo, hi, step)]
        return self.events[lo:hi]

    def query_pkt(self, pkt: str) -> list[dict]:
        """Return all events for a packet fingerprint."""
        indices = self.by_pkt.get(pkt, [])
        return [self.events[i] for i in indices]

    def query_node_range(self, node: str, from_ms: int, to_ms: int) -> list[dict]:
        """Return events involving a node in a time range."""
        indices = self.by_node.get(node, [])
        result = []
        for i in indices:
            t = self.times[i]
            if t < from_ms:
                continue
            if t > to_ms:
                break
            result.append(self.events[i])
        return result

    def density(self, from_ms: int, to_ms: int, bucket_ms: int = 1000) -> dict:
        """Return per-node event density in time buckets (for zoomed-out view)."""
        lo = bisect_left(self.times, from_ms)
        hi = bisect_right(self.times, to_ms)

        n_buckets = max(1, (to_ms - from_ms + bucket_ms - 1) // bucket_ms)
        # node -> list of bucket counts by event category
        result: dict[str, dict[str, list[int]]] = {}

        for i in range(lo, hi):
            ev = self.events[i]
            t = self.times[i]
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
            ev = self.events[i]
            if self.times[i] >= after_ms and ev["type"] == "tx":
                return ev
        return None

    def get_meta(self) -> dict:
        return {
            "nodes": self.nodes,
            "time_min": self.time_min,
            "time_max": self.time_max,
            "event_count": len(self.events),
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
        """
        with self._lock:
            if sim_id in self._cache:
                self._cache.move_to_end(sim_id)
                return self._cache[sim_id]
            # Get or create a per-sim load lock
            if sim_id not in self._loading:
                self._loading[sim_id] = threading.Lock()
            load_lock = self._loading[sim_id]

        # Serialize loads of the same sim_id (but allow different sims in parallel)
        with load_lock:
            # Re-check after acquiring load lock — another thread may have loaded it
            with self._lock:
                if sim_id in self._cache:
                    self._cache.move_to_end(sim_id)
                    self._loading.pop(sim_id, None)
                    return self._cache[sim_id]

            logger.info("EventIndexCache: loading sim_id=%s from %s", sim_id, events_path)
            try:
                index = EventIndex(events_path)
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
                    evicted_id, _ = self._cache.popitem(last=False)
                    logger.info("EventIndexCache: evicted sim_id=%s", evicted_id)

                self._cache[sim_id] = index
                self._loading.pop(sim_id, None)
                return index

    def evict(self, sim_id: str) -> None:
        """Remove a specific simulation's index from the cache."""
        with self._lock:
            if sim_id in self._cache:
                del self._cache[sim_id]
                logger.info("EventIndexCache: evicted sim_id=%s", sim_id)
