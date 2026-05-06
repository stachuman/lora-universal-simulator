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


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = Settings.get()
    for sub in ("simulations", "interactive"):
        (settings.DATA_DIR / sub).mkdir(parents=True, exist_ok=True)
    yield


app = FastAPI(title="lora-universal-simulator", lifespan=lifespan)
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# Static mount — served from webapp/static/.
_static = pathlib.Path(__file__).resolve().parent.parent / "static"
app.mount("/static", StaticFiles(directory=_static), name="static")


@app.get("/", include_in_schema=False)
def root():
    return FileResponse(_static / "index.html")


@app.get("/health", include_in_schema=False)
def health():
    return {"status": "ok"}
