#!/usr/bin/bash
cd "$(dirname "$0")"
exec uvicorn server.main:app --port 8008 --host 0.0.0.0 --reload
