#!/usr/bin/env bash
# Stop the Local Search stack (containers removed, data preserved).
set -u
cd "$(dirname "$0")" || exit 1

[ -f "./engine.sh" ] || {
  echo "[ERROR] engine.sh is missing from this folder. Re-run install-local-search.sh." >&2; exit 1; }
# shellcheck source=engine.sh
. ./engine.sh
ls_pause_on_exit
ls_require_engine

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found. Nothing to stop." >&2; exit 1
fi

echo "Stopping Local Search containers (data is preserved)..."
$DC down || { echo "[ERROR] Failed to stop." >&2; exit 1; }

echo
echo "Local Search stopped. Data is preserved in $ENGINE_NAME volumes."
echo "Run ./run.sh to start it again."
