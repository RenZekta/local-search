#!/usr/bin/env bash
# Start the Local Search stack (Firecrawl + SearXNG).
set -u
cd "$(dirname "$0")" || exit 1

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker is not installed. See README.md." >&2; exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "[ERROR] Docker engine is not running. Start Docker first." >&2; exit 1
fi
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else echo "[ERROR] Docker Compose not found." >&2; exit 1; fi

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found in this folder. Run install-local-search.sh first." >&2
  exit 1
fi

echo "Starting Local Search (Firecrawl + SearXNG)..."
$DC up -d || { echo "[ERROR] Failed to start." >&2; exit 1; }

echo
echo "Local Search is running."
echo "  SearXNG:   http://localhost:${SEARXNG_PORT:-9990}"
echo "  Firecrawl: http://localhost:${FIRECRAWL_PORT:-9991}"
echo "Run ./stop.sh to stop the stack."
