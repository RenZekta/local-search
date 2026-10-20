#!/usr/bin/env bash
# Update the Local Search stack: pull latest images, recreate containers,
# and re-sync the local-web-search agent skill. Data volumes are preserved. Edits
# to .env (ports, LLM) are also applied.
set -u
cd "$(dirname "$0")" || exit 1

[ -f "./engine.sh" ] || {
  echo "[ERROR] engine.sh is missing from this folder. Re-run install-local-search.sh." >&2; exit 1; }
# shellcheck source=engine.sh
. ./engine.sh
ls_pause_on_exit
ls_require_engine running

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found. Run install-local-search.sh first." >&2
  exit 1
fi

echo "Updating Local Search (using $ENGINE_NAME)..."
echo
echo "[1/3] Pulling latest images..."
$DC pull || echo "[WARNING] Some images failed to pull. Continuing."

echo
echo "[2/3] Recreating containers with updated images (data is preserved)..."
$DC up -d || { echo "[ERROR] Failed to recreate containers." >&2; exit 1; }
SEARXNG_PORT="$(ls_env_value .env SEARXNG_PORT)"; SEARXNG_PORT="${SEARXNG_PORT:-9990}"
ls_verify_searxng "$SEARXNG_PORT"; VERIFY_RC=$?
if [ "$VERIFY_RC" -eq 0 ]; then ls_fix_container_proxy "$SEARXNG_PORT"; VERIFY_RC=$?; fi

echo
echo "[3/3] Refreshing the local-web-search agent skill..."
if [ -f "./local-web-search/SKILL.md" ]; then
  SKILL_DIR="$HOME/.agents/skills/local-web-search"
  rm -rf "$SKILL_DIR"
  mkdir -p "$HOME/.agents/skills"
  if cp -r ./local-web-search "$SKILL_DIR"; then
    printf '%s\n' "$(pwd)" > "$SKILL_DIR/install-dir.txt"
    echo "  Skill refreshed at $SKILL_DIR"
  else
    echo "  [WARNING] Could not copy the skill to $SKILL_DIR."
  fi
else
  echo "  local-web-search skill source not found in this folder - skipping."
fi

echo
if [ "$VERIFY_RC" -ne 0 ]; then
  echo "Update finished, but SearXNG or the containers' proxy settings need attention - see the details above." >&2
  exit 1
fi
echo "Update complete. Data volumes were preserved."
echo "  - Port / LLM changes in .env are now applied."
echo "  - The local-web-search skill was re-synced from this folder."
echo "  - To update the SearXNG settings.yml or docker-compose.yml template,"
echo "    re-run install-local-search.sh (it backs up your current .env)."
