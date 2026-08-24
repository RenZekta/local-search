#!/usr/bin/env bash
# Update the Local Search stack: pull latest images and recreate containers.
# Data volumes are preserved. Edits to .env (ports, LLM) are also applied.
set -u
cd "$(dirname "$0")" || exit 1

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker is not installed." >&2; exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "[ERROR] Docker engine is not running. Start Docker first." >&2; exit 1
fi
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else echo "[ERROR] Docker Compose not found." >&2; exit 1; fi

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found. Run install-local-search.sh first." >&2; exit 1
fi

echo "Updating Local Search..."
echo
echo "[1/2] Pulling latest images..."
$DC pull || echo "[WARNING] Some images failed to pull. Continuing."

echo
echo "[2/2] Recreating containers with updated images (data is preserved)..."
$DC up -d || { echo "[ERROR] Failed to recreate containers." >&2; exit 1; }

echo
echo "Update complete. Data volumes were preserved."
echo "  - Port / LLM changes in .env are now applied."
echo "  - To update the SearXNG settings.yml or docker-compose.yml template,"
echo "    re-run install-local-search.sh (it backs up your current .env)."
