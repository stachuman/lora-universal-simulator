# Import Existing Run (config + result file, no lus) — Design

**Date:** 2026-05-27
**Status:** Approved (verbal), spec for implementation planning

## Problem

Today the only way to get a viewable timeline in the webapp is to POST a
scenario `config_json` to `/api/sims`, which runs `lus` to produce
`events.ndjson`. When a run already exists on disk (e.g. the
`/tmp/<stem>_analyze.ndjson` file produced by `analyze.py --run`, or any
prior lus output), there is no way to view it in the webapp without
re-simulating. This is wasteful for long runs and breaks the iterate-on-tooling
workflow where lus has already been executed out-of-band.

## Goal

Add an **import** option: point the webapp at a config JSON (already supported
via the New Simulation form's textarea / "Load from file") **and** a
server-side **result file path**. When a result path is given, the webapp
registers a *completed* sim from those files and skips lus entirely. The
imported sim is then indistinguishable from a normally-run completed sim for
every downstream view (`/events`, `/meta`, `/density`, `/dm_breakdown`,
visualize, map_live).

## Decisions (from brainstorming)

- **File source:** server-side filesystem paths (not browser upload). The
  webapp runs locally; this avoids pushing large events files (e.g. s12 6h
  runs) through an HTTP body and matches the existing analyze.py workflow.
- **UI surface:** extend the existing New Simulation form with one optional
  "Result file path" field. No separate import page.
- **Backend shape (Approach A):** a dedicated `SimManager.import_sim()` method
  and `POST /api/sims/import` endpoint — kept separate from the run path so
  each method has a single responsibility and the existing run tests are
  untouched.
- **Copy, not reference:** the result file is copied into
  `sim_dir/events.ndjson` so the sim directory is self-contained and every
  existing reader works unchanged (they all read `sim_dir/events.ndjson` /
  `sim_dir/config.json`). This also matches the startup-scan model, which
  already treats any sim dir containing `events.ndjson` as completed.

## Architecture

### Backend

**`SimManager.import_sim(config: dict, events_path: str) -> str`** (new)
1. Generate sim id, `mkdir` the sim dir (same as `create_sim`).
2. Write `config.json` (same as `create_sim`).
3. Copy the source events file to `sim_dir/events.ndjson` (`shutil.copyfile`).
4. Build a `SimRecord` with `status="completed"`, `created_at=now`,
   `completed_at=now`; register it and `_save_status()`.
5. Return the sim id. No background task, no lus subprocess.

The events-path validation (existence, regular file, non-empty, first
non-blank line parses as JSON) lives in the **router** (HTTP 400 surface),
not in `import_sim`, mirroring how `create_sim` leaves config validation to
the router. `import_sim` may assume a readable path.

**`POST /api/sims/import`** (new endpoint in `simulations.py`)
- Request body: `{ "config_json": dict, "events_path": str }`.
- Validate `config_json` with the **same** `validate_lus_config` used by the
  run path (so the viewer's assumptions hold); on error return `400` with the
  existing error shape.
- Validate `events_path`:
  - resolve the path; must be an existing **regular file** → else `400`;
  - must be **non-empty** → else `400`;
  - first non-blank line must `json.loads` cleanly → else `400`
    ("not an NDJSON events file").
- Call `sim_manager.import_sim(parsed_config, events_path)`; return
  `{"id": sim_id}` with `201` (matching `create_sim`'s status code).

Path handling: local single-user tool, so beyond "existing regular file" no
sandboxing is applied. The path is read server-side as given.

### Frontend (`static/simulation.html`)

- Add one optional input to the New Simulation form, near the file-row:
  **"Result file path (skip lus)"** with a short hint
  ("Server path to an existing events.ndjson; leave blank to run lus").
- `submitSim()`:
  - read the trimmed result-path value;
  - parse the config textarea exactly as today;
  - if result path is **empty** → POST `/api/sims` `{config_json}` (unchanged);
  - if result path is **non-empty** → POST `/api/sims/import`
    `{config_json, events_path}`;
  - on success, redirect to `simulation.html?id=<id>` exactly as today. The
    per-sim page already handles a completed sim (shows View Timeline / View
    Map), so no further UI branching is needed.

## Data flow

```
New Simulation form
  ├─ result path empty → POST /api/sims        → create_sim → lus → events.ndjson (completed)
  └─ result path set   → POST /api/sims/import → import_sim → copy events.ndjson (completed)
                                                       │
                                redirect → simulation.html?id=… (existing completed-sim view)
                                                       │
                          existing readers: /events /meta /density /dm_breakdown
```

## Error handling

| Condition | Result |
|-----------|--------|
| `config_json` fails `validate_lus_config` | `400` (existing validation error shape) |
| `events_path` missing / not a regular file | `400` "events file not found: <path>" |
| `events_path` empty file | `400` "events file is empty" |
| first non-blank line not valid JSON | `400` "not an NDJSON events file: <path>" |
| copy fails (I/O) | propagates as `500` |

The frontend surfaces any non-2xx response text in the existing `#form-error`
div (same as the current run path).

## Testing

1. **`SimManager.import_sim` unit test** — given a fixture config dict + a
   small events.ndjson file, `import_sim` returns an id; the sim dir contains
   `config.json` and `events.ndjson`; `get_sim(id).status == "completed"`;
   `get_events_path(id)` and `get_config_path(id)` resolve.
2. **Endpoint integration test** — `POST /api/sims/import` with a real config
   (s13) and a pre-generated events file → `201`; `GET /api/sims/{id}` is
   `completed`; `GET /api/sims/{id}/events` returns events. Plus negative
   cases: nonexistent path → `400`; empty file → `400`; non-JSON first line →
   `400`.
3. **HTML presence test** — `simulation.html` contains the result-path field
   and the `/api/sims/import` POST wiring (string-presence guard; behavior is
   manual).

## Out of scope (YAGNI)

- Browser upload of files.
- Referencing the events file in place (we copy).
- Importing a config *path* (config still flows as JSON content via the
  textarea, which already supports "Load from file").
- Any path sandboxing beyond "existing regular file".
- Re-deriving/validating events against the config (trust the run that
  produced them).
