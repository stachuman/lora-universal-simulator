#!/usr/bin/env python3
"""Static NDJSON swim-lane visualizer for the lora-universal-simulator.

Reads an NDJSON event log, embeds it inside ``visualize.html`` next to this
script, writes a temporary self-contained HTML file, and opens it in the
default browser.

Usage::

    python3 tools/visualize.py path/to/events.ndjson [--output out.html]
                                                     [--no-open]

The viewer is purely client-side: no HTTP server, no API. The Python wrapper
is little more than a glue layer that loads the NDJSON, embeds it as a JSON
literal inside the HTML template, and hands the file off to the browser.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import webbrowser
from pathlib import Path

PLACEHOLDER = "/*__EVENTS_JSON__*/null"


def load_events(path: str) -> list[dict]:
    """Read an NDJSON file and return one dict per non-empty line.

    Malformed lines are skipped with a warning to stderr.
    """
    events: list[dict] = []
    parse_errors = 0
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                parse_errors += 1
                continue

    if parse_errors:
        print(
            f"WARNING: skipped {parse_errors} malformed JSON lines",
            file=sys.stderr,
        )
    return events


def build_html(template_path: Path, events: list[dict]) -> str:
    """Inline ``events`` as a JSON literal into the HTML template."""
    template = template_path.read_text(encoding="utf-8")
    if PLACEHOLDER not in template:
        raise RuntimeError(
            f"Template {template_path} is missing the {PLACEHOLDER!r} marker"
        )
    # JSON is a strict subset of JavaScript object literal syntax for these
    # values, so we can splice it directly. </script> would break out of the
    # surrounding <script> block — escape that one sequence defensively.
    payload = json.dumps(events).replace("</", "<\\/")
    return template.replace(PLACEHOLDER, payload, 1)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Static NDJSON swim-lane visualizer"
    )
    parser.add_argument("input", help="NDJSON event log file")
    parser.add_argument(
        "--output",
        help="Where to write the generated HTML (default: a temp file)",
    )
    parser.add_argument(
        "--no-open",
        action="store_true",
        help="Don't open the resulting HTML in a browser",
    )
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"Error: {args.input} not found", file=sys.stderr)
        return 1

    template_path = Path(__file__).parent / "visualize.html"
    if not template_path.exists():
        print(f"Error: template {template_path} not found", file=sys.stderr)
        return 1

    events = load_events(args.input)
    print(f"Loaded {len(events)} events from {args.input}", file=sys.stderr)

    html = build_html(template_path, events)

    if args.output:
        out_path = Path(args.output)
        out_path.write_text(html, encoding="utf-8")
    else:
        # Persist a temp file so the browser can keep reading it after we exit.
        tmp = tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            suffix=".html",
            prefix="lora_sim_view_",
            delete=False,
        )
        tmp.write(html)
        tmp.close()
        out_path = Path(tmp.name)

    print(f"Wrote {out_path}", file=sys.stderr)

    if not args.no_open:
        try:
            webbrowser.open(out_path.as_uri())
        except Exception as exc:  # noqa: BLE001 — best-effort browser launch
            print(f"WARNING: could not open browser: {exc}", file=sys.stderr)
            print(f"Open manually: {out_path}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
