"""SimManager service -- manages lus subprocess lifecycle and simulation data
storage.

Bridges the web frontend and the lus binary:
1. Writes config JSON to disk
2. Spawns lus as a subprocess: lus <config.json> <events.ndjson>
3. lus writes NDJSON events directly to the events file (stdout unused)
4. Drains stderr into a last_stderr buffer for diagnostics
5. Streams status to SSE subscribers via asyncio.Queue
6. Manages simulation lifecycle (create, list, cancel, delete)
"""

import asyncio
import json
import logging
import os
import shutil
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


def _truncate_preserve_ends(s: str, head: int = 800, tail: int = 1200) -> str:
    """Truncate a long string keeping both ends.

    lus stderr typically has useful context near the start AND the summary
    line at the end. Pure tail truncation loses the first half of that context.
    """
    if s is None:
        return ""
    if len(s) <= head + tail:
        return s
    omitted = len(s) - head - tail
    return f"{s[:head]}\n... [{omitted} bytes truncated] ...\n{s[-tail:]}"


@dataclass
class SimRecord:
    """In-memory record of a simulation's state."""

    id: str
    status: str  # pending, running, completed, failed, cancelled
    created_at: float
    completed_at: Optional[float] = None
    config: dict = field(default_factory=dict)
    error: Optional[str] = None
    pid: Optional[int] = None
    progress_pct: int = 0
    progress_detail: str = ""
    last_stderr: str = ""


class SimManager:
    """Manages lus subprocess lifecycle and simulation data."""

    def __init__(
        self,
        data_dir: Path,
        orchestrator_path: str,
        max_concurrent: int = 4,
        cwd: Optional[Path] = None,
    ):
        self.data_dir = data_dir
        self.orchestrator_path = orchestrator_path
        self.cwd = cwd  # working directory for lus subprocess (None = inherit)
        self._semaphore = asyncio.Semaphore(max_concurrent)
        self._sims: dict[str, SimRecord] = {}  # in-memory registry
        self._processes: dict[str, asyncio.subprocess.Process] = {}
        self._progress_subscribers: dict[str, list[asyncio.Queue]] = {}
        self._scan_existing()  # load completed sims from disk on startup

    # ------------------------------------------------------------------
    # Startup scan
    # ------------------------------------------------------------------

    def _scan_existing(self) -> None:
        """Scan data_dir/simulations/ for existing simulation directories.

        Populates the in-memory registry with any simulations that were
        previously run (completed, failed, or cancelled).  Running/pending
        sims from a prior process are marked as failed since the subprocess
        is no longer alive.
        """
        sims_dir = self.data_dir / "simulations"
        if not sims_dir.exists():
            return

        for entry in sorted(sims_dir.iterdir()):
            if not entry.is_dir():
                continue

            sim_id = entry.name
            config_path = entry / "config.json"
            events_path = entry / "events.ndjson"
            status_path = entry / "status.json"

            if not status_path.exists():
                # No status file -- infer from presence of events
                status = "completed" if events_path.exists() else "failed"
                created_at = os.path.getctime(str(entry))
                config = self._load_json(config_path)
                self._sims[sim_id] = SimRecord(
                    id=sim_id,
                    status=status,
                    created_at=created_at,
                    config=config,
                )
                continue

            status_data = self._load_json(status_path)
            config = self._load_json(config_path)

            raw_status = status_data.get("status", "failed")
            # If a previous server died while a sim was running/pending,
            # mark it as failed since the subprocess no longer exists.
            if raw_status in ("running", "pending"):
                raw_status = "failed"
                status_data["error"] = status_data.get(
                    "error", "Server restarted while simulation was in progress"
                )

            self._sims[sim_id] = SimRecord(
                id=sim_id,
                status=raw_status,
                created_at=status_data.get(
                    "created_at", os.path.getctime(str(entry))
                ),
                completed_at=status_data.get("completed_at"),
                config=config,
                error=status_data.get("error"),
            )

        logger.info(
            "Scanned %d existing simulation(s) from %s", len(self._sims), sims_dir
        )

    # ------------------------------------------------------------------
    # Path helpers
    # ------------------------------------------------------------------

    def _sim_dir(self, sim_id: str) -> Path:
        return self.data_dir / "simulations" / sim_id

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def create_sim(self, config: dict) -> str:
        """Create a new simulation, write config, start lus subprocess.

        Returns the newly generated simulation ID.
        """
        sim_id = self._generate_id()
        sim_dir = self._sim_dir(sim_id)
        sim_dir.mkdir(parents=True, exist_ok=True)

        # Write config to disk
        config_path = sim_dir / "config.json"
        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)

        record = SimRecord(
            id=sim_id,
            status="pending",
            created_at=time.time(),
            config=config,
        )
        self._sims[sim_id] = record
        self._save_status(sim_id)

        # Start lus in the background
        asyncio.create_task(self._run_sim(sim_id))
        return sim_id

    def get_sim(self, sim_id: str) -> Optional[SimRecord]:
        """Return the SimRecord for a simulation, or None."""
        return self._sims.get(sim_id)

    def list_sims(self) -> list[SimRecord]:
        """Return all simulations, newest first."""
        return sorted(self._sims.values(), key=lambda s: s.created_at, reverse=True)

    async def cancel_sim(self, sim_id: str) -> bool:
        """Cancel a running simulation by terminating its subprocess.

        Returns True if the process was found and terminated.
        """
        proc = self._processes.get(sim_id)
        if proc is None:
            return False

        proc.terminate()
        record = self._sims.get(sim_id)
        if record:
            record.status = "cancelled"
            record.completed_at = time.time()
            self._save_status(sim_id)
            self._notify_progress(sim_id, {"status": "cancelled"})
            self._notify_progress(sim_id, None)  # sentinel for SSE close
        return True

    async def delete_sim(self, sim_id: str) -> bool:
        """Delete a simulation and all its data from disk.

        Cancels the simulation first if it is still running.
        Returns True if the simulation existed.
        """
        if sim_id not in self._sims:
            return False

        await self.cancel_sim(sim_id)

        sim_dir = self._sim_dir(sim_id)
        if sim_dir.exists():
            shutil.rmtree(sim_dir)

        self._sims.pop(sim_id, None)
        self._progress_subscribers.pop(sim_id, None)
        return True

    def get_events_path(self, sim_id: str) -> Optional[Path]:
        """Return path to events.ndjson if it exists on disk."""
        p = self._sim_dir(sim_id) / "events.ndjson"
        return p if p.exists() else None

    def get_config_path(self, sim_id: str) -> Optional[Path]:
        """Return path to config.json if it exists on disk."""
        p = self._sim_dir(sim_id) / "config.json"
        return p if p.exists() else None

    # ------------------------------------------------------------------
    # SSE progress subscription
    # ------------------------------------------------------------------

    def subscribe_progress(self, sim_id: str) -> asyncio.Queue:
        """Subscribe to progress updates for a simulation.

        Returns an asyncio.Queue that will receive dicts with progress
        information.  A ``None`` sentinel signals the end of updates.
        """
        q: asyncio.Queue = asyncio.Queue(maxsize=100)
        self._progress_subscribers.setdefault(sim_id, []).append(q)

        # If simulation already finished, send final state immediately
        record = self._sims.get(sim_id)
        if record and record.status in ("completed", "failed", "cancelled"):
            try:
                q.put_nowait({"status": record.status, "progress": record.progress_pct / 100.0})
                q.put_nowait(None)
            except asyncio.QueueFull:
                pass
        return q

    def unsubscribe_progress(self, sim_id: str, q: asyncio.Queue) -> None:
        """Remove a progress subscriber queue."""
        queues = self._progress_subscribers.get(sim_id, [])
        try:
            queues.remove(q)
        except ValueError:
            pass
        # Clean up empty subscriber lists
        if not queues:
            self._progress_subscribers.pop(sim_id, None)

    # ------------------------------------------------------------------
    # Subprocess management (private)
    # ------------------------------------------------------------------

    async def _run_sim(self, sim_id: str) -> None:
        """Run lus as subprocess: lus <config> <events>, drain stderr."""
        record = self._sims[sim_id]
        sim_dir = self._sim_dir(sim_id)
        config_path = sim_dir / "config.json"
        events_path = sim_dir / "events.ndjson"

        async with self._semaphore:
            record.status = "running"
            self._save_status(sim_id)
            self._notify_progress(sim_id, {
                "status": "running",
                "progress": 0,
                "phase": "init",
                "message": "Starting lus...",
            })

            try:
                # lus writes NDJSON events directly to events_path;
                # stdout is unused (DEVNULL). stderr carries a one-line summary.
                proc = await asyncio.create_subprocess_exec(
                    str(self.orchestrator_path),
                    str(config_path),
                    str(events_path),
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                    cwd=self.cwd,
                )
                self._processes[sim_id] = proc
                record.pid = proc.pid

                # Drain stderr for diagnostics
                stderr_task = asyncio.create_task(
                    self._drain_stderr(proc, sim_id)
                )

                await proc.wait()
                await stderr_task

                if proc.returncode == 0:
                    record.status = "completed"
                    record.progress_pct = 100
                    self._notify_progress(
                        sim_id, {"status": "completed", "progress": 1.0}
                    )
                elif record.status == "cancelled":
                    # Already handled by cancel_sim
                    pass
                else:
                    record.status = "failed"
                    record.error = (
                        _truncate_preserve_ends(record.last_stderr, head=800, tail=1200)
                        if record.last_stderr else "Unknown error"
                    )
                    self._notify_progress(
                        sim_id, {"status": "failed", "error": record.error}
                    )

            except FileNotFoundError:
                msg = f"lus binary not found: {self.orchestrator_path}"
                logger.error(msg)
                record.status = "failed"
                record.error = msg
                self._notify_progress(sim_id, {"status": "failed", "error": msg})
            except Exception as e:
                logger.exception("Simulation %s failed with unexpected error", sim_id)
                record.status = "failed"
                record.error = str(e)
                self._notify_progress(
                    sim_id, {"status": "failed", "error": str(e)}
                )
            finally:
                record.completed_at = time.time()
                self._processes.pop(sim_id, None)
                self._save_status(sim_id)
                # Send sentinel to close all SSE connections
                self._notify_progress(sim_id, None)

    async def _drain_stderr(self, proc, sim_id: str) -> None:
        """Drain stderr; capture last 50 lines for diagnostics."""
        buf: list[str] = []
        if proc.stderr is None:
            return
        async for line in proc.stderr:
            text = line.decode(errors="replace").rstrip()
            buf.append(text)
            if len(buf) > 50:
                buf.pop(0)
            sess = self._sims.get(sim_id)
            if sess is not None:
                sess.last_stderr = "\n".join(buf)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _save_status(self, sim_id: str) -> None:
        """Persist simulation status to disk as status.json."""
        record = self._sims.get(sim_id)
        if not record:
            return
        status_path = self._sim_dir(sim_id) / "status.json"
        status_data = {
            "status": record.status,
            "created_at": record.created_at,
            "completed_at": record.completed_at,
            "error": record.error,
        }
        try:
            with open(status_path, "w") as f:
                json.dump(status_data, f, indent=2)
        except OSError:
            logger.exception("Failed to save status for sim %s", sim_id)

    def _notify_progress(self, sim_id: str, data) -> None:
        """Push progress update to all SSE subscriber queues.

        A ``None`` data value acts as a sentinel, signaling that no more
        updates will follow (SSE endpoint should close).
        """
        queues = self._progress_subscribers.get(sim_id, [])
        for q in queues:
            try:
                q.put_nowait(data)
            except asyncio.QueueFull:
                # Slow subscriber — drop update but log so stuck progress
                # bars are diagnosable. Rate-limit by only logging on full
                # queue (won't flood on steady-state slowness).
                logger.warning(
                    "SSE queue full for sim_id=%s; dropping progress update "
                    "(slow client?)", sim_id
                )

    @staticmethod
    def _load_json(path: Path) -> dict:
        """Load a JSON file, returning an empty dict on any error."""
        if not path.exists():
            return {}
        try:
            with open(path) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            # Don't fail the whole scan on one bad record, but surface it
            # so corruption is visible in the server log.
            logger.warning("sim_manager: cannot parse %s (%s) — treating as empty", path, e)
            return {}

    @staticmethod
    def _generate_id() -> str:
        """Generate a short unique simulation ID (12 hex chars)."""
        return uuid.uuid4().hex[:12]
