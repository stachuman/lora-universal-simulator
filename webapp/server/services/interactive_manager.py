"""InteractiveSessionManager -- manages lus -i subprocess lifecycle
for WebSocket-based interactive simulation control.

Each session spawns a ``lus -i config.json`` subprocess and provides:
- Command serialization (asyncio.Lock per session)
- Stdout classification (JSON line = event; ``[t=N] > ...`` = response; else continuation)
- Event persistence to ``events.ndjson``
- WebSocket client registration + broadcast
- Idle timeout cleanup
- Export to ``data/simulations/`` for visualization compatibility

lus interactive stdout format (piped):
  - NDJSON event lines during initialization and after steps (parseable as JSON)
  - ``lus interactive — :help for commands, Ctrl-D to exit`` — banner (drop)
  - Prompt+response merged on one line: ``[t=N] > <first response line>``
  - Continuation lines starting with ``  `` (two spaces): rest of multi-line output
  - Readiness is detected by parsing the node-list lines from ``:nodes``
"""

import asyncio
import json
import logging
import re
import shutil
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from fastapi import WebSocket

logger = logging.getLogger(__name__)

# Matches the merged prompt+response line: ``[t=N] > <rest>``
_PROMPT_RE = re.compile(r"^\[t=\d+\] > (.*)")
# Matches a node-list line from ``:nodes``: ``  N  name  script_path``
_NODE_LINE_RE = re.compile(r"^\s{2}(\d+)\s{2}(\S+)\s+(\S+)")


@dataclass
class InteractiveSession:
    """In-memory record of an interactive session."""

    id: str
    status: str  # starting, ready, closed
    created_at: float
    config: dict = field(default_factory=dict)
    last_activity: float = 0.0
    time_ms: int = 0
    step_ms: int = 5
    nodes: list = field(default_factory=list)
    error: Optional[str] = None


class InteractiveSessionManager:
    """Manages interactive lus sessions with WebSocket relay."""

    def __init__(
        self,
        data_dir: Path,
        orchestrator_path: str,
        max_sessions: int = 4,
        idle_timeout_s: int = 300,
        cwd: Optional[Path] = None,
    ):
        self.data_dir = data_dir
        self.orchestrator_path = orchestrator_path
        self.max_sessions = max_sessions
        self.idle_timeout_s = idle_timeout_s
        self.cwd = cwd  # working directory for lus subprocess (None = inherit)

        self._sessions: dict[str, InteractiveSession] = {}
        self._processes: dict[str, asyncio.subprocess.Process] = {}
        self._ws_clients: dict[str, list[WebSocket]] = {}
        self._response_queues: dict[str, asyncio.Queue] = {}
        self._cmd_locks: dict[str, asyncio.Lock] = {}
        self._reader_tasks: dict[str, asyncio.Task] = {}
        self._event_files: dict[str, object] = {}  # open file handles
        # Accumulate text-response lines between prompt occurrences
        self._pending_response: dict[str, list[str]] = {}
        self._cleanup_task: Optional[asyncio.Task] = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start_cleanup_loop(self) -> None:
        self._cleanup_task = asyncio.create_task(self._cleanup_loop())

    async def shutdown(self) -> None:
        if self._cleanup_task:
            self._cleanup_task.cancel()
            try:
                await self._cleanup_task
            except asyncio.CancelledError:
                pass
        for sid in list(self._sessions):
            await self.close_session(sid, reason="shutdown")

    # ------------------------------------------------------------------
    # Session CRUD
    # ------------------------------------------------------------------

    async def create_session(self, config: dict) -> InteractiveSession:
        """Create a new interactive session, spawn lus -i."""
        active = sum(
            1 for s in self._sessions.values() if s.status != "closed"
        )
        if active >= self.max_sessions:
            raise RuntimeError(
                f"Maximum interactive sessions ({self.max_sessions}) reached"
            )

        sid = uuid.uuid4().hex[:12]
        sess_dir = self._session_dir(sid)
        sess_dir.mkdir(parents=True, exist_ok=True)

        config_path = sess_dir / "config.json"
        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)

        step_ms = config.get("simulation", {}).get("step_ms", 5)
        session = InteractiveSession(
            id=sid,
            status="starting",
            created_at=time.time(),
            last_activity=time.time(),
            config=config,
            step_ms=step_ms,
        )
        self._sessions[sid] = session
        self._ws_clients[sid] = []
        self._response_queues[sid] = asyncio.Queue()
        self._cmd_locks[sid] = asyncio.Lock()
        self._pending_response[sid] = []

        # Spawn lus -i.
        # Any exception between here and the probe completion must release
        # the event file, kill the process, and clean up per-session state;
        # otherwise repeated startup failures leak FDs and zombie procs.
        try:
            proc = await asyncio.create_subprocess_exec(
                self.orchestrator_path,
                "-e", "meshroute",   # webapp ALWAYS runs the meshroute engine (2026-07-22)
                "-i",
                str(config_path),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self.cwd,
            )
            self._processes[sid] = proc

            # Open events file for append
            self._event_files[sid] = open(sess_dir / "events.ndjson", "w")

            # Start stdout + stderr readers
            self._reader_tasks[sid] = asyncio.create_task(
                self._read_stdout(sid)
            )
            asyncio.create_task(self._read_stderr(sid))

            # Probe with ':nodes' then ':time' to detect readiness.
            # lus outputs node lines after init completes; ':time' ensures
            # another newline-terminated line arrives so the stdout reader
            # can detect the end of the nodes list and transition to 'ready'.
            proc.stdin.write(b":nodes\n:time\n")
            await proc.stdin.drain()

        except FileNotFoundError:
            session.status = "closed"
            session.error = f"lus not found: {self.orchestrator_path}"
            await self._cleanup_failed_startup(sid)
            raise RuntimeError(session.error)
        except Exception as e:
            session.status = "closed"
            session.error = str(e)
            await self._cleanup_failed_startup(sid)
            raise

        return session

    async def _cleanup_failed_startup(self, sid: str) -> None:
        """Release resources reserved by create_session when startup fails."""
        ef = self._event_files.pop(sid, None)
        if ef:
            try:
                ef.close()
            except OSError:
                pass
        proc = self._processes.pop(sid, None)
        if proc and proc.returncode is None:
            try:
                proc.terminate()
                await asyncio.wait_for(proc.wait(), timeout=2)
            except (asyncio.TimeoutError, ProcessLookupError):
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
        task = self._reader_tasks.pop(sid, None)
        if task and not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._response_queues.pop(sid, None)
        self._cmd_locks.pop(sid, None)
        self._ws_clients.pop(sid, None)
        self._pending_response.pop(sid, None)

    def get_session(self, sid: str) -> Optional[InteractiveSession]:
        return self._sessions.get(sid)

    def list_sessions(self) -> list[InteractiveSession]:
        return sorted(
            self._sessions.values(), key=lambda s: s.created_at, reverse=True
        )

    async def close_session(self, sid: str, reason: str = "closed") -> bool:
        session = self._sessions.get(sid)
        if not session:
            return False

        if session.status == "closed":
            return True

        session.status = "closed"

        # Kill process
        proc = self._processes.pop(sid, None)
        if proc and proc.returncode is None:
            try:
                proc.stdin.write(b":quit\n")
                await proc.stdin.drain()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            try:
                proc.terminate()
                await asyncio.wait_for(proc.wait(), timeout=3)
            except (asyncio.TimeoutError, ProcessLookupError):
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass

        # Cancel reader task
        task = self._reader_tasks.pop(sid, None)
        if task and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        # Close event file
        ef = self._event_files.pop(sid, None)
        if ef:
            try:
                ef.close()
            except OSError:
                pass

        # Broadcast close to WS clients
        await self._broadcast(sid, {"type": "closed", "reason": reason})

        # Clean up per-session state
        self._response_queues.pop(sid, None)
        self._cmd_locks.pop(sid, None)
        self._pending_response.pop(sid, None)

        return True

    async def delete_session(self, sid: str) -> bool:
        await self.close_session(sid, reason="deleted")
        if sid not in self._sessions:
            return False
        sess_dir = self._session_dir(sid)
        if sess_dir.exists():
            shutil.rmtree(sess_dir)
        self._sessions.pop(sid, None)
        self._ws_clients.pop(sid, None)
        return True

    async def export_session(self, sid: str) -> Optional[str]:
        """Copy session events to data/simulations/ for visualization."""
        session = self._sessions.get(sid)
        if not session:
            return None

        sess_dir = self._session_dir(sid)
        events_src = sess_dir / "events.ndjson"
        config_src = sess_dir / "config.json"

        if not events_src.exists():
            return None

        sim_id = uuid.uuid4().hex[:12]
        sim_dir = self.data_dir / "simulations" / sim_id
        sim_dir.mkdir(parents=True, exist_ok=True)

        # Close event file if still open (to flush)
        ef = self._event_files.get(sid)
        if ef:
            try:
                ef.flush()
            except OSError:
                pass

        shutil.copy2(events_src, sim_dir / "events.ndjson")
        if config_src.exists():
            shutil.copy2(config_src, sim_dir / "config.json")

        # Write status.json
        status = {
            "status": "completed",
            "created_at": session.created_at,
            "completed_at": time.time(),
            "error": None,
        }
        with open(sim_dir / "status.json", "w") as f:
            json.dump(status, f, indent=2)

        return sim_id

    # ------------------------------------------------------------------
    # Command dispatch
    # ------------------------------------------------------------------

    async def send_command(self, sid: str, raw_cmd: str) -> dict:
        """Send a raw lus command (e.g. ':step 1') to the subprocess, wait for response.

        Uses a per-session lock to serialize commands (only one at a time).
        """
        session = self._sessions.get(sid)
        if not session or session.status == "closed":
            return {"error": "Session closed"}

        proc = self._processes.get(sid)
        if not proc or proc.returncode is not None:
            return {"error": "Process not running"}

        lock = self._cmd_locks.get(sid)
        if not lock:
            return {"error": "Session not initialized"}

        queue = self._response_queues.get(sid)
        if not queue:
            return {"error": "Session not initialized"}

        # Drain any stale responses
        while not queue.empty():
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                break

        async with lock:
            session.last_activity = time.time()
            try:
                proc.stdin.write((raw_cmd + "\n").encode())
                await proc.stdin.drain()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return {"error": "Process stdin broken"}

            try:
                response = await asyncio.wait_for(queue.get(), timeout=60)
                return response
            except asyncio.TimeoutError:
                return {"error": "Command timed out (60s)"}

    # ------------------------------------------------------------------
    # WebSocket management
    # ------------------------------------------------------------------

    async def register_ws(self, sid: str, ws: WebSocket) -> None:
        clients = self._ws_clients.get(sid)
        if clients is not None:
            clients.append(ws)

        session = self._sessions.get(sid)
        if session:
            session.last_activity = time.time()

    async def unregister_ws(self, sid: str, ws: WebSocket) -> None:
        clients = self._ws_clients.get(sid)
        if clients:
            try:
                clients.remove(ws)
            except ValueError:
                pass

    async def _broadcast(self, sid: str, msg: dict) -> None:
        clients = self._ws_clients.get(sid, [])
        dead = []
        for ws in clients:
            try:
                await ws.send_json(msg)
            except Exception:
                dead.append(ws)
        for ws in dead:
            try:
                clients.remove(ws)
            except ValueError:
                pass

    # ------------------------------------------------------------------
    # Stdout reader (core event loop)
    # ------------------------------------------------------------------

    async def _read_stdout(self, sid: str) -> None:
        """Continuously read lus stdout, classify lines, persist events + broadcast.

        lus interactive stdout format (all on stdout when piped):
        1. JSON NDJSON event lines during init (sim_start, node_ready, …)
        2. Banner: ``lus interactive — :help for commands, Ctrl-D to exit``
        3. Prompt merged with first response line: ``[t=N] > <first response line>``
        4. Multi-line response continuation lines (``  0  name  script``, ``  -> …``)
        5. JSON event lines during steps (tx/rx/…)

        Probe phase (session.status == "starting"):
          We send ``:nodes\\n:time\\n`` at startup.  Text output during "starting"
          is consumed silently: node lines build ``probe_nodes``, and the first
          non-node prompt line (the :time response) triggers ``_finalize_readiness``.
          Nothing is put on the command-response queue during probe phase.

        Normal phase (session.status == "ready"):
          Each response line is parsed immediately when the prompt+response line
          arrives (``[t=N] > <response>``).  Single-line responses (step, run,
          next, time, cmd) are put on the queue right away.  Multi-line responses
          (e.g. :events) accumulate in ``pending`` and are flushed on the next
          prompt line.
        """
        proc = self._processes.get(sid)
        session = self._sessions.get(sid)
        queue = self._response_queues.get(sid)

        if not proc or not session or not queue:
            return

        # Accumulate multi-line response parts between prompts.
        pending: list[str] = self._pending_response.setdefault(sid, [])
        # Nodes collected during the probe phase
        probe_nodes: list[dict] = []

        def _parse_response(lines: list[str]) -> dict:
            """Parse a list of text lines into a structured response dict."""
            data: dict = {"lines": lines}
            for line in lines:
                # Step / run / next: ``  -> t=Nms (+M events)[end]``
                step_m = re.match(
                    r"\s*->\s*t=(\d+)ms\s+\(\+(\d+) events\)(.*)", line
                )
                if step_m:
                    data["stepped_to_ms"] = int(step_m.group(1))
                    data["new_events"] = int(step_m.group(2))
                    data["ended"] = bool(step_m.group(3).strip())
                    break
                # :time response — bare integer
                time_m = re.match(r"^(\d+)$", line.strip())
                if time_m:
                    data["time_ms"] = int(time_m.group(1))
                    break
                # :cmd reply: ``  <- <text>``
                cmd_m = re.match(r"\s*<-\s*(.*)", line)
                if cmd_m:
                    data["reply"] = cmd_m.group(1)
                    break
            return data

        def _is_terminal_response(rest: str) -> bool:
            """Return True if ``rest`` is a complete single-line response."""
            return bool(
                re.match(r"\s*->", rest)      # step/run/next
                or re.match(r"^(\d+)$", rest.strip())  # time
                or re.match(r"\s*<-", rest)   # cmd reply
                or re.match(r"^\? ", rest)    # error/unknown command
            )

        def _flush_pending() -> None:
            """Flush accumulated multi-line response lines to the queue."""
            if not pending:
                return
            lines = list(pending)
            pending.clear()
            try:
                queue.put_nowait(_parse_response(lines))
            except asyncio.QueueFull:
                pass

        try:
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break  # EOF = process exited

                text = line.decode("utf-8", errors="replace").rstrip()
                if not text:
                    continue

                # ----------------------------------------------------------
                # 1. Try to parse as JSON (NDJSON event line)
                # ----------------------------------------------------------
                try:
                    event = json.loads(text)
                    ef = self._event_files.get(sid)
                    if ef:
                        try:
                            ef.write(text + "\n")
                            ef.flush()
                        except OSError:
                            pass
                    await self._broadcast(sid, {"type": "event", "data": event})
                    continue
                except json.JSONDecodeError:
                    pass

                # ----------------------------------------------------------
                # 2. Banner line (drop)
                # ----------------------------------------------------------
                if text.startswith("lus interactive"):
                    continue

                # ----------------------------------------------------------
                # 3. Prompt+response merged line: ``[t=N] > <rest>``
                # ----------------------------------------------------------
                prompt_m = _PROMPT_RE.match(text)
                if prompt_m:
                    rest = prompt_m.group(1)

                    # ---- Probe phase ----
                    if session.status == "starting":
                        if rest:
                            node_m = _NODE_LINE_RE.match(rest)
                            if node_m:
                                probe_nodes.append({
                                    "id": int(node_m.group(1)),
                                    "name": node_m.group(2),
                                    "script": node_m.group(3),
                                })
                                continue
                            else:
                                # Non-node text (the :time response or similar)
                                # signals end of probe.
                                if probe_nodes:
                                    await self._finalize_readiness(
                                        sid, session, probe_nodes
                                    )
                                    probe_nodes = []
                                # Drop the probe :time value — don't queue it
                                continue
                        else:
                            # Empty rest while probing — discard
                            continue

                    # ---- Normal phase ----
                    # Flush any accumulated multi-line pending from previous cmd
                    _flush_pending()

                    if rest:
                        if _is_terminal_response(rest):
                            # Single-line response: enqueue immediately so
                            # send_command doesn't have to wait for next prompt.
                            try:
                                queue.put_nowait(_parse_response([rest]))
                            except asyncio.QueueFull:
                                pass
                        else:
                            # Start accumulating multi-line response
                            pending.append(rest)
                    continue

                # ----------------------------------------------------------
                # 4. Continuation lines
                # ----------------------------------------------------------
                if session.status == "starting":
                    # Probe-phase continuation: collect node lines, drop rest
                    node_m = _NODE_LINE_RE.match(text)
                    if node_m:
                        probe_nodes.append({
                            "id": int(node_m.group(1)),
                            "name": node_m.group(2),
                            "script": node_m.group(3),
                        })
                    continue

                # Normal continuation: accumulate
                pending.append(text)

        except asyncio.CancelledError:
            return
        except Exception:
            logger.exception("Stdout reader for session %s crashed", sid)
        finally:
            _flush_pending()

            if session.status != "closed":
                reason = "process_exited"
                rc = proc.returncode
                if rc and rc != 0:
                    reason = "crashed"
                logger.warning(
                    "lus[%s] process exited (returncode=%s, status was '%s')",
                    sid, rc, session.status,
                )
                await self.close_session(sid, reason=reason)

    async def _finalize_readiness(
        self,
        sid: str,
        session: InteractiveSession,
        probe_nodes: list[dict],
    ) -> None:
        """Transition session to 'ready' after :nodes/:time probe completes."""
        session.nodes = list(probe_nodes)
        session.status = "ready"
        session.time_ms = 0
        logger.info(
            "lus[%s] ready, %d node(s)", sid, len(probe_nodes)
        )
        await self._broadcast(sid, {
            "type": "ready",
            "nodes": session.nodes,
            "time_ms": 0,
            "step_ms": session.step_ms,
        })

    async def _read_stderr(self, sid: str) -> None:
        """Drain lus stderr; store last 50 lines for diagnostics."""
        proc = self._processes.get(sid)
        if not proc or not proc.stderr:
            return
        last_lines: list[str] = []
        try:
            while True:
                line = await proc.stderr.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").rstrip()
                if text:
                    last_lines.append(text)
                    if len(last_lines) > 50:
                        last_lines.pop(0)
                    logger.debug("lus[%s] stderr: %s", sid, text)
        except asyncio.CancelledError:
            return
        except Exception:
            pass
        finally:
            if last_lines:
                logger.info("lus[%s] stderr summary: %s", sid, last_lines[-1])

    # ------------------------------------------------------------------
    # Cleanup loop
    # ------------------------------------------------------------------

    async def _cleanup_loop(self) -> None:
        """Periodically kill sessions that are idle with no WS clients."""
        try:
            while True:
                await asyncio.sleep(60)
                now = time.time()
                for sid, session in list(self._sessions.items()):
                    if session.status == "closed":
                        continue
                    clients = self._ws_clients.get(sid, [])
                    idle = now - session.last_activity
                    if not clients and idle > self.idle_timeout_s:
                        logger.info(
                            "Closing idle session %s (idle %.0fs)", sid, idle
                        )
                        await self.close_session(sid, reason="idle")
        except asyncio.CancelledError:
            return

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _session_dir(self, sid: str) -> Path:
        return self.data_dir / "interactive" / sid
