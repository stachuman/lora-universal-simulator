#!/usr/bin/env python3
# Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
"""Locate the ONE canonical DM/channel delivery analysis — never a local copy.

The analysis engine lives in the MeshRoute firmware repo as
`tools/dm_delivery_breakdown.py`, where it is maintained and gated
(`simulation/BASELINE.md`). This repo used to carry two stale FORKS of it — a
`tools/dm_delivery_breakdown.py` copy and a second copy inlined into
`webapp/server/services/dm_breakdown.py` — which drifted until they were
missing whole classes of measurement: no cross-layer accounting at all
(`tx_enqueue_xl` / `xl_orig`: zero occurrences), no fail-loud denominator
(BASELINE 2026-07-25d), no layer-aware keying (BASELINE 2026-07-25g).
Owner ruling 2026-07-25: *"webapp should use the same dm delivery script — not
a local copy" / "One source of truth."*

So this module does NOT vendor, copy, sync or cache that file. It only answers
**where it is**, and it FAILS LOUD when it is not there (C2): a missing source
of truth must be an obvious error, never a silent fallback to a built-in copy
and never a quiet zero — that is exactly how three copies came about.

Resolution:
  1. ``$MESHROUTE_ROOT``  — explicit override. **Authoritative: if it is set and
     the tool is not under it, that is a hard error.** It must NOT quietly fall
     through to some other checkout — a wrong-but-plausible source of truth is
     the failure mode this whole slice exists to remove.
  2. otherwise ``<parent of this repo>/MeshRoute`` — the conventional sibling
     checkout, derived from this file's location (no user home is hardcoded).

Consumers:
  * ``tools/s15_route_convergence_sweep.py`` — needs the PATH (it subprocesses
    the tool, whose ``--run`` / ``--failures`` surface is unchanged).
  * ``webapp/server/services/dm_breakdown.py`` — needs the MODULE (it calls the
    analysis in-process, as its fork did, and keeps its own caching/threading).
"""

from __future__ import annotations

import importlib.util
import os
import sys
import threading
from pathlib import Path

ENV_VAR = "MESHROUTE_ROOT"
TOOL_RELPATH = Path("tools") / "dm_delivery_breakdown.py"
SIBLING_DIRNAME = "MeshRoute"


class CanonicalToolMissing(RuntimeError):
    """The canonical delivery analysis could not be located.

    Raised instead of degrading to a local copy or returning empty results.
    """


def _sim_repo_root() -> Path:
    """This repo's root — this file is <root>/tools/meshroute_canonical.py."""
    return Path(__file__).resolve().parent.parent


def candidate_tool_paths() -> list[tuple[str, Path]]:
    """[(where-it-came-from, path)] to try, for the error message.

    An explicit `$MESHROUTE_ROOT` is the ONLY candidate when set — see the module
    docstring: an override that misses must fail, not fall back.
    """
    env = os.environ.get(ENV_VAR)
    if env:
        return [(f"${ENV_VAR}={env}", Path(env).expanduser() / TOOL_RELPATH)]
    return [("sibling checkout",
             _sim_repo_root().parent / SIBLING_DIRNAME / TOOL_RELPATH)]


def canonical_tool_path() -> Path:
    """Absolute path of the canonical `dm_delivery_breakdown.py`.

    Raises `CanonicalToolMissing` — naming every location tried and how to point
    at the right one — rather than falling back to anything local.
    """
    cands = candidate_tool_paths()
    for _label, path in cands:
        if path.is_file():
            return path
    tried = "\n".join(f"    {label}: {path}" for label, path in cands)
    raise CanonicalToolMissing(
        "cannot find the canonical DM delivery analysis "
        f"({TOOL_RELPATH.as_posix()} in the MeshRoute repo).\n"
        f"  Looked for:\n{tried}\n"
        f"  Point at your MeshRoute checkout with {ENV_VAR}=/path/to/MeshRoute\n"
        "  (this simulator deliberately keeps NO local copy of the analysis — "
        "one source of truth)."
    )


_MODULE_LOCK = threading.Lock()
_MODULE_CACHE: dict[str, object] = {}


def load_canonical(module_name: str = "meshroute_dm_delivery_breakdown"):
    """Import the canonical tool as a module, from wherever it actually lives.

    Loaded by explicit file path (`importlib.util.spec_from_file_location`) so
    nothing is mutated on `sys.path` and no copy exists here. The tool guards its
    CLI behind `if __name__ == "__main__"`, so importing it has no side effects.
    Memoized per interpreter — the file is parsed once, then re-resolved only if
    the module is dropped from the cache.
    """
    with _MODULE_LOCK:
        cached = _MODULE_CACHE.get(module_name)
        if cached is not None:
            return cached
        path = canonical_tool_path()
        spec = importlib.util.spec_from_file_location(module_name, str(path))
        if spec is None or spec.loader is None:
            raise CanonicalToolMissing(
                f"found {path} but could not load it as a Python module")
        module = importlib.util.module_from_spec(spec)
        # Registered before exec so the module's own `from __future__`/dataclass
        # style self-references resolve the same way a normal import would.
        sys.modules[module_name] = module
        try:
            spec.loader.exec_module(module)
        except Exception:
            sys.modules.pop(module_name, None)
            raise
        _MODULE_CACHE[module_name] = module
        return module


if __name__ == "__main__":
    # `python3 tools/meshroute_canonical.py` — print the resolved path, or the
    # loud failure. Handy when a consumer reports it cannot find the analysis.
    try:
        print(canonical_tool_path())
    except CanonicalToolMissing as exc:
        raise SystemExit(f"meshroute_canonical: {exc}")
