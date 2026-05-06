# lora-universal-simulator webapp
#
# Build (requires lus binary already compiled):
#   cmake -S . -B build && cmake --build build --target lus
#   cd webapp && docker compose build
#
# Run (local):
#   docker compose up
#
# Deploy to another machine:
#   docker save lus-webapp:latest | gzip > lus-webapp.tar.gz
#   scp lus-webapp.tar.gz user@host:/path/
#   # On target:
#   docker load < lus-webapp.tar.gz
#   docker run -d --name lus-webapp \
#       -p 8000:8000 \
#       -v lus-data:/app/data \
#       --restart unless-stopped \
#       lus-webapp:latest

FROM python:3.11-slim

# Runtime deps for the lus binary (libstdc++, liblua5.4)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 liblua5.4-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Python dependencies (cached layer — only busts when requirements.txt changes)
COPY webapp/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-built lus binary (bind-mounted at runtime via docker-compose; copied here
# so the image is self-contained for deploy scenarios)
COPY build/orchestrator/lus /app/lus
RUN chmod +x /app/lus

# Webapp source (no __pycache__ — excluded by .dockerignore)
COPY webapp/server/ ./server/
COPY webapp/static/ ./static/
COPY scenarios/ ./scenarios/

# Non-root user for runtime
RUN useradd --system --create-home --home-dir /home/app app \
    && mkdir -p data/simulations data/interactive \
    && chown -R app:app /app /home/app
USER app

ENV ORCHESTRATOR_PATH=/app/lus
ENV LUS_CWD=/app
ENV DATA_DIR=/app/data
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

EXPOSE 8000
CMD ["uvicorn", "server.main:app", "--host", "0.0.0.0", "--port", "8000"]
