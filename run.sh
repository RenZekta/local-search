#!/usr/bin/env bash
# Start the Local Search stack (Firecrawl + SearXNG).
# Uses Podman when it is installed, otherwise Docker (see engine.sh; override
# with LOCAL_SEARCH_ENGINE=podman|docker or the same line in .env).
set -u
cd "$(dirname "$0")" || exit 1

[ -f "./engine.sh" ] || {
  echo "[ERROR] engine.sh is missing from this folder. Re-run install-local-search.sh." >&2; exit 1; }
# shellcheck source=engine.sh
. ./engine.sh
ls_pause_on_exit          # keep a launcher-opened window open at the end
ls_require_engine running

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found in this folder. Run install-local-search.sh first." >&2
  exit 1
fi

echo "Starting Local Search (Firecrawl + SearXNG) with $ENGINE_NAME..."
$DC up -d || { echo "[ERROR] Failed to start." >&2; exit 1; }

SEARXNG_PORT="$(ls_env_value .env SEARXNG_PORT)"; SEARXNG_PORT="${SEARXNG_PORT:-9990}"
FIRECRAWL_PORT="$(ls_env_value .env FIRECRAWL_PORT)"; FIRECRAWL_PORT="${FIRECRAWL_PORT:-9991}"
echo
ls_verify_searxng "$SEARXNG_PORT" || exit 1
ls_fix_container_proxy "$SEARXNG_PORT" || exit 1

echo
echo "Local Search is running."
echo "  SearXNG:   http://localhost:${SEARXNG_PORT}"
echo "  Firecrawl: http://localhost:${FIRECRAWL_PORT}"
echo "Run ./stop.sh to stop the stack."
