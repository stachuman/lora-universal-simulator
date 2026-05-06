"""FastAPI app entry point.

Mounts static files, registers routers (added in later tasks), and creates
the data directories on startup.
"""

from __future__ import annotations

import pathlib
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from server.config import Settings
from server.routers import interactive, simulations, topologies, topo_creator
from server.services.event_index import EventIndexCache
from server.services.interactive_manager import InteractiveSessionManager
from server.services.sim_manager import SimManager


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = Settings.get()
    for sub in ("simulations", "interactive", "topologies"):
        (settings.DATA_DIR / sub).mkdir(parents=True, exist_ok=True)
    app.state.sim_manager = SimManager(
        data_dir=settings.DATA_DIR,
        orchestrator_path=str(settings.ORCHESTRATOR_PATH),
        max_concurrent=settings.MAX_CONCURRENT_SIMS,
        cwd=settings.LUS_CWD,
    )
    app.state.event_cache = EventIndexCache(max_size=5)
    app.state.interactive_manager = InteractiveSessionManager(
        data_dir=settings.DATA_DIR,
        orchestrator_path=str(settings.ORCHESTRATOR_PATH),
        max_sessions=settings.MAX_INTERACTIVE_SESSIONS,
        idle_timeout_s=settings.INTERACTIVE_IDLE_TIMEOUT_S,
        cwd=settings.LUS_CWD,
    )
    app.state.interactive_manager.start_cleanup_loop()
    yield
    await app.state.interactive_manager.shutdown()


app = FastAPI(title="lora-universal-simulator", lifespan=lifespan)
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

app.include_router(simulations.router, prefix="/api/sims", tags=["sims"])
app.include_router(interactive.router, prefix="/api/interactive", tags=["interactive"])
app.include_router(topologies.router, prefix="/api/topologies", tags=["topologies"])
app.include_router(topo_creator.router, prefix="/api/topo-creator", tags=["topo-creator"])

# Static mount — served from webapp/static/.
_static = pathlib.Path(__file__).resolve().parent.parent / "static"
app.mount("/static", StaticFiles(directory=_static), name="static")


@app.get("/", include_in_schema=False)
def root():
    return FileResponse(_static / "index.html")


@app.get("/health", include_in_schema=False)
def health():
    return {"status": "ok"}
