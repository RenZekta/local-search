#!/usr/bin/env bash
# =============================================================================
#  Local Search Installer  (Firecrawl + SearXNG + local-web-search skill)
#                        -  Linux & macOS
# =============================================================================
#  Self-contained: every file the installer needs is embedded below as a
#  quoted heredoc. If a source file is missing from this script's folder
#  (e.g. you only downloaded this one .sh), the embedded copy is used.
#  After installing the stack it also copies the bundled local-web-search agent
#  skill into ~/.agents/skills/local-web-search.
#  If the Docker engine is not running, the installer tries to start it
#  automatically (Docker Desktop on macOS, systemctl/service on Linux)
#  and waits for it before pulling images.
# =============================================================================

set -u

BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
say()  { printf "%b\n" "$1"; }
err()  { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2; }
ok()   { printf "%b[OK]%b %s\n" "$GREEN" "$RESET" "$1"; }
hdr()  { printf "\n%b--- %s ---%b\n" "$CYAN" "$1" "$RESET"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }  # bash-3.2 (macOS) safe

cat <<'BANNER'
============================================================
  Local Search Installer  (Firecrawl + SearXNG + local-web-search)
  A local web-browsing system for AI models.
============================================================
BANNER

if ! command -v docker >/dev/null 2>&1; then
  err "Docker was not found on your PATH."
  say ""
  say "Install Docker Engine (Linux) or Docker Desktop (macOS):"
  say "  Linux:   https://docs.docker.com/engine/install/"
  say "  macOS:   https://www.docker.com/products/docker-desktop/"
  say "Then re-run this installer."
  exit 1
fi
# How long to wait for a just-launched Docker engine (seconds).
DOCKER_WAIT_TIMEOUT="${LOCAL_SEARCH_DOCKER_TIMEOUT:-300}"
ENGINE_LAUNCHED=0
if ! docker info >/dev/null 2>&1; then
  say "  ${YELLOW}[!]${RESET} The Docker engine is not running - trying to start it..."
  ENGINE_STARTED=0
  if [ "$(uname)" = "Darwin" ]; then
    # macOS: launch Docker Desktop if it is installed
    if command -v open >/dev/null 2>&1 \
       && { [ -d "/Applications/Docker.app" ] || [ -d "$HOME/Applications/Docker.app" ]; }; then
      open -a Docker >/dev/null 2>&1 && ENGINE_STARTED=1
    fi
  else
    # Linux: systemd units (Docker Desktop uses docker-desktop, the
    # classic engine uses docker), then service(1). Non-interactive
    # sudo only - an installer never prompts for a password.
    if command -v systemctl >/dev/null 2>&1; then
      for unit in docker-desktop docker; do
        if systemctl start "$unit" >/dev/null 2>&1; then ENGINE_STARTED=1; break; fi
        if command -v sudo >/dev/null 2>&1 \
           && sudo -n systemctl start "$unit" >/dev/null 2>&1; then
          ENGINE_STARTED=1; break
        fi
      done
    fi
    if [ "$ENGINE_STARTED" -ne 1 ] && command -v service >/dev/null 2>&1; then
      if service docker start >/dev/null 2>&1; then ENGINE_STARTED=1
      elif command -v sudo >/dev/null 2>&1 \
         && sudo -n service docker start >/dev/null 2>&1; then
        ENGINE_STARTED=1
      fi
    fi
  fi
  if [ "$ENGINE_STARTED" -ne 1 ]; then
    err "Could not start the Docker engine automatically."
    say ""
    say "Start it manually, then re-run this installer:"
    say "  Linux:  sudo systemctl start docker    (or launch Docker Desktop)"
    say "          permission denied from docker? add yourself to the docker"
    say "          group:  sudo usermod -aG docker $USER  (log out and back in)"
    say "  macOS:  open -a Docker"
    exit 1
  fi
  ENGINE_LAUNCHED=1
  say "  Launched Docker in the background. Answer the next questions while"
  say "  it boots - the installer waits for the engine before pulling images."
fi
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else err "Docker Compose was not found. Install the 'docker compose' plugin (v2)."; exit 1; fi
ok "Docker and Docker Compose are available ($DC)."

SRC="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_TARGET="$HOME/local-search"
hdr "Step 1 of 4: Install location"
say "  Default: $DEFAULT_TARGET"
printf "  Target folder [press Enter for default]: "
read -r TARGET
[ -z "$TARGET" ] && TARGET="$DEFAULT_TARGET"
if [ "${TARGET#\~}" != "$TARGET" ]; then TARGET="$HOME${TARGET#\~}"; fi  # POSIX tilde expansion
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
say "  Using: $TARGET"

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [ "$p" -ge 1 ] 2>/dev/null || return 1
  [ "$p" -le 65535 ] 2>/dev/null || return 1
  return 0
}

hdr "Step 2 of 4: SearXNG port (default 9990)"
while true; do
  printf "  Port for SearXNG [press Enter for 9990]: "
  read -r SEARXNG_PORT
  [ -z "$SEARXNG_PORT" ] && SEARXNG_PORT=9990
  if validate_port "$SEARXNG_PORT"; then break; fi
  say "  ${YELLOW}[!]${RESET} '$SEARXNG_PORT' is not a valid port (1-65535)."
done

hdr "Step 3 of 4: Firecrawl port (default 9991)"
while true; do
  printf "  Port for Firecrawl [press Enter for 9991]: "
  read -r FIRECRAWL_PORT
  [ -z "$FIRECRAWL_PORT" ] && FIRECRAWL_PORT=9991
  if ! validate_port "$FIRECRAWL_PORT"; then
    say "  ${YELLOW}[!]${RESET} '$FIRECRAWL_PORT' is not a valid port (1-65535)."
    continue
  fi
  if [ "$FIRECRAWL_PORT" = "$SEARXNG_PORT" ]; then
    say "  ${YELLOW}[!]${RESET} Firecrawl port must differ from SearXNG port."
    continue
  fi
  break
done

hdr "Step 4 of 4: Local LLM (optional)"
say "  Lets Firecrawl do AI extraction (/v1/extract) and summaries."
say "  Recommended: LM Studio -> http://localhost:1234/v1"
printf "  Connect a local LLM now? [y/N]: "
read -r USE_LLM
OPENAI_BASE_URL=""; OPENAI_API_KEY=""; MODEL_NAME=""
if [ "$(lower "$USE_LLM")" = "y" ]; then
  printf "    LM Studio server URL (as shown in LM Studio) [press Enter for http://localhost:1234/v1]: "
  read -r LLM_URL
  [ -z "$LLM_URL" ] && LLM_URL="http://localhost:1234/v1"
  printf "    Model name (id loaded in LM Studio) [press Enter to skip]: "
  read -r LLM_MODEL
  OPENAI_BASE_URL="${LLM_URL/http:\/\/localhost/http:\/\/host.docker.internal}"
  OPENAI_BASE_URL="${OPENAI_BASE_URL/http:\/\/127.0.0.1/http:\/\/host.docker.internal}"
  OPENAI_API_KEY="lm-studio"
  [ -n "$LLM_MODEL" ] && MODEL_NAME="$LLM_MODEL"
  say "    (Container will reach it at: $OPENAI_BASE_URL)"
  say "    (Make sure LM Studio has 'Serve on local network' enabled.)"
fi

echo
say "${BOLD}============================================================${RESET}"
say "${BOLD}  Summary${RESET}"
say "  Folder:         $TARGET"
say "  SearXNG port:   $SEARXNG_PORT"
say "  Firecrawl port: $FIRECRAWL_PORT"
say "  Agent skill:    $HOME/.agents/skills/local-web-search"
if [ -n "$OPENAI_BASE_URL" ]; then
  say "  LLM endpoint:   $OPENAI_BASE_URL  $MODEL_NAME"
else
  say "  LLM endpoint:   (none - enable later by editing .env)"
fi
say "${BOLD}============================================================${RESET}"
printf "Proceed with install? [Y/n]: "
read -r CONFIRM
if [ "$(lower "$CONFIRM")" = "n" ]; then say "Install cancelled."; exit 0; fi

mkdir -p "$TARGET/config/searxng" "$TARGET/local-web-search/scripts"

if [ -f "$TARGET/.env" ]; then
  LDT="$(date +%Y%m%d%H%M%S)"
  cp "$TARGET/.env" "$TARGET/.env.bak.$LDT"
  say "  Backed up existing .env to .env.bak.$LDT"
fi

say "Copying all project files..."

# --- config/searxng/settings.yml ---
if [ -f "$SRC/config/searxng/settings.yml" ]; then
  cp "$SRC/config/searxng/settings.yml" "$TARGET/config/searxng/settings.yml"
else
  say "  [embedded] config/searxng/settings.yml  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/config/searxng/settings.yml" <<'EOF_CONFIG_SEARXNG_SETTINGS_YML'
# =============================================================================
#  SearXNG settings for local-search
# =============================================================================
#  Pre-configured for AI / local-model use:
#    * search.formats includes "json"  -> lets models query the JSON API
#    * server.limiter: false           -> no rate-limiting on API calls
#    * server.public_instance: false   -> private instance defaults
#    * secret_key placeholder          -> installer replaces with a random key
#
#  "use_default_settings: true" inherits all upstream defaults (engines,
#  plugins, etc.) so only the overrides below take effect.
# =============================================================================

use_default_settings: true

general:
  debug: false
  instance_name: "Local Search"
  privacypolicy_url: false
  contact_link: false

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"
  formats:
    - html
    - json

server:
  secret_key: "32645fb30c6d4cbe217c67956d3db00d377b4fded18455497b073b3b0dc4253c"
  bind_address: "0.0.0.0"
  port: 8080
  image_proxy: true
  limiter: false
  public_instance: false

ui:
  static_use_hash: true

outgoing:
  request_timeout: 10.0
  max_request_timeout: 15.0
EOF_CONFIG_SEARXNG_SETTINGS_YML
fi

# --- docker-compose.yml ---
if [ -f "$SRC/docker-compose.yml" ]; then
  cp "$SRC/docker-compose.yml" "$TARGET/docker-compose.yml"
else
  say "  [embedded] docker-compose.yml  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/docker-compose.yml" <<'EOF_DOCKER_COMPOSE_YML'
# =============================================================================
#  Local Search — Firecrawl + SearXNG (local web-browsing system for AI models)
# =============================================================================
#  This Compose file is consumed by the installers (install-local-search.bat /
#  install-local-search.sh). The host ports and credentials are injected from
#  the generated .env file (created at install time).
#
#  Services:
#    searxng          metasearch + JSON API        -> host ${SEARXNG_PORT}
#    firecrawl        scrape/crawl/search/map API  -> host ${FIRECRAWL_PORT}
#    playwright-service  JS rendering for Firecrawl
#    redis               queue for Firecrawl
#    rabbitmq            message broker for Firecrawl
#    nuq-postgres        job state DB for Firecrawl
#
#  Only the two host ports below are published. Everything else stays on the
#  private "local-search-net" bridge network.
# =============================================================================

name: local-search

services:

  # --------------------------------------------------------------------------
  # SearXNG — privacy-respecting metasearch engine, exposed as a JSON API.
  # Powers both your AI models (direct JSON queries) and Firecrawl's /v1/search.
  # --------------------------------------------------------------------------
  searxng:
    image: searxng/searxng:latest
    container_name: local-search-searxng
    ports:
      - "${SEARXNG_PORT:-9990}:8080"
    volumes:
      - ./config/searxng:/etc/searxng:rw
    environment:
      - SEARXNG_BASE_URL=http://localhost:${SEARXNG_PORT:-9990}/
      - UWSGI_WORKERS=4
      - UWSGI_THREADS=4
      - SEARXNG_SECRET=${SEARXNG_SECRET}
    restart: unless-stopped
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # Firecrawl API server (the public-facing scraping/crawl/search service).
  # --------------------------------------------------------------------------
  firecrawl:
    image: ghcr.io/firecrawl/firecrawl:latest
    container_name: local-search-firecrawl
    ports:
      - "${FIRECRAWL_PORT:-9991}:3002"
    environment:
      - PORT=3002
      - HOST=0.0.0.0
      - ENV=local
      - REDIS_URL=redis://redis:6379
      - REDIS_RATE_LIMIT_URL=redis://redis:6379
      - PLAYWRIGHT_MICROSERVICE_URL=http://playwright-service:3000/scrape
      - USE_DB_AUTHENTICATION=false
      - BULL_AUTH_KEY=${BULL_AUTH_KEY}
      - LOGGING_LEVEL=${LOGGING_LEVEL:-info}
      - BLOCK_MEDIA=false
      - ALLOW_LOCAL_WEBHOOKS=false
      - SEARXNG_ENDPOINT=http://searxng:8080
      - POSTGRES_HOST=nuq-postgres
      - POSTGRES_PORT=5432
      - POSTGRES_DB=${POSTGRES_DB:-firecrawl}
      - POSTGRES_USER=${POSTGRES_USER:-firecrawl}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - NUQ_RABBITMQ_URL=amqp://${RABBITMQ_USER:-firecrawl}:${RABBITMQ_PASSWORD}@rabbitmq:5672
      # ---- Optional AI features (set in .env to enable /v1/extract + summary) ----
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
      - OPENAI_BASE_URL=${OPENAI_BASE_URL:-}
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-}
      - MODEL_NAME=${MODEL_NAME:-}
      - MODEL_EMBEDDING_NAME=${MODEL_EMBEDDING_NAME:-}
    command: ["node", "dist/src/harness.js", "--start-docker"]
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    extra_hosts:
      - "host.docker.internal:host-gateway"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
        compress: "true"
    depends_on:
      redis:
        condition: service_started
      playwright-service:
        condition: service_started
      searxng:
        condition: service_started
      nuq-postgres:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # Playwright headless browser service — does the actual JS-rendered fetching.
  # --------------------------------------------------------------------------
  playwright-service:
    image: ghcr.io/firecrawl/playwright-service:latest
    container_name: local-search-playwright
    environment:
      - PORT=3000
      - BLOCK_MEDIA=false
      - ALLOW_LOCAL_WEBHOOKS=false
      - MAX_CONCURRENT_PAGES=10
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # Redis — Firecrawl queue / rate-limiting store.
  # --------------------------------------------------------------------------
  redis:
    image: redis:alpine
    container_name: local-search-redis
    volumes:
      - redis-data:/data
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # RabbitMQ — message broker used by Firecrawl's job workers.
  # --------------------------------------------------------------------------
  rabbitmq:
    image: rabbitmq:3-management
    container_name: local-search-rabbitmq
    environment:
      - RABBITMQ_DEFAULT_USER=${RABBITMQ_USER:-firecrawl}
      - RABBITMQ_DEFAULT_PASS=${RABBITMQ_PASSWORD}
    volumes:
      - rabbitmq-data:/var/lib/rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "ping"]
      interval: 5s
      timeout: 10s
      retries: 10
      start_period: 30s
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # nuq-postgres — Firecrawl job-state database (pg_cron enabled image).
  # --------------------------------------------------------------------------
  nuq-postgres:
    image: ghcr.io/firecrawl/nuq-postgres:latest
    container_name: local-search-postgres
    command: postgres -c cron.database_name=${POSTGRES_DB:-firecrawl}
    environment:
      - POSTGRES_DB=${POSTGRES_DB:-firecrawl}
      - POSTGRES_USER=${POSTGRES_USER:-firecrawl}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-firecrawl} -d ${POSTGRES_DB:-firecrawl}"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s
    restart: unless-stopped
    networks:
      - local-search-net

networks:
  local-search-net:
    driver: bridge

volumes:
  redis-data:
  postgres-data:
  rabbitmq-data:
EOF_DOCKER_COMPOSE_YML
fi

# --- .env.example ---
if [ -f "$SRC/.env.example" ]; then
  cp "$SRC/.env.example" "$TARGET/.env.example"
else
  say "  [embedded] .env.example  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/.env.example" <<'EOF__ENV_EXAMPLE'
# =============================================================================
#  Local Search — example environment file
# =============================================================================
#  The installer (install-local-search.bat / install-local-search.sh) generates
#  a REAL .env file at install time with:
#    * the host ports you chose
#    * cryptographically-random passwords/keys (do NOT use the values below
#      in production — they are placeholders only)
#
#  This file is documentation. To change settings after install, edit the .env
#  in your install folder, then run Update.bat / update.sh (or restart).
# =============================================================================

# ---- Host ports (what you connect to from your machine) ----
SEARXNG_PORT=9990
FIRECRAWL_PORT=9991

# ---- SearXNG instance secret (random — installer generates) ----
SEARXNG_SECRET=replace-with-64-char-random-hex

# ---- Firecrawl internal credentials (installer generates random values) ----
BULL_AUTH_KEY=replace-with-64-char-random-hex
POSTGRES_DB=firecrawl
POSTGRES_USER=firecrawl
POSTGRES_PASSWORD=replace-with-64-char-random-hex
RABBITMQ_USER=firecrawl
RABBITMQ_PASSWORD=replace-with-64-char-random-hex

# ---- Logging ----
LOGGING_LEVEL=info

# =============================================================================
#  Optional: connect a local (or remote) LLM so Firecrawl's /v1/extract and
#  "summary" features work. Any OpenAI-compatible endpoint will do.
#  LM Studio is the recommended default (priority over Ollama).
# =============================================================================

# ---- Option A (RECOMMENDED): LM Studio / any OpenAI-compatible local server ----
#   1. In LM Studio: Developer tab > "Start Server" on port 1234, load a model,
#      and ENABLE "Serve on local network" so the Firecrawl container can reach it.
#   2. NOTE: OPENAI_BASE_URL is read INSIDE the Firecrawl container. From there,
#      your host machine is "host.docker.internal", NOT "localhost". So use:
# OPENAI_BASE_URL=http://host.docker.internal:1234/v1
# OPENAI_API_KEY=lm-studio          # any non-empty string; LM Studio ignores it
# MODEL_NAME=local-model            # the model id loaded in LM Studio

# ---- Option B: remote OpenAI-compatible server (vLLM, llama.cpp server, etc.) ----
# OPENAI_BASE_URL=http://192.168.1.50:8000/v1
# OPENAI_API_KEY=placeholder
# MODEL_NAME=your-model-id

# ---- Option C (fallback): Ollama on the same host as Docker ----
# OLLAMA_BASE_URL=http://host.docker.internal:11434/api
# MODEL_NAME=qwen2.5:7b
# MODEL_EMBEDDING_NAME=nomic-embed-text
EOF__ENV_EXAMPLE
fi

# --- README.md ---
if [ -f "$SRC/README.md" ]; then
  cp "$SRC/README.md" "$TARGET/README.md"
else
  say "  [embedded] README.md  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/README.md" <<'EOF_README_MD'
# 🔍 Local Search — a private web-browsing system for AI models

**SearXNG + Firecrawl + the local-web-search agent skill, running entirely on your machine, behind two local ports.**

Give any LLM — a local model in LM Studio, a cloud model, an agent, an MCP
client, or a plain chat UI — the ability to **search the web and read pages**
without sending a single request to a paid scraping API. Everything runs in
Docker on your computer; your queries, results, and page contents never leave
your network.

| What | URL (default) | Purpose |
|------|---------------|---------|
| **SearXNG**  | `http://localhost:9990` | Metasearch + JSON API. Aggregates Google/Bing/DuckDuckGo/etc. |
| **Firecrawl** | `http://localhost:9991` | Scrape / crawl / map / search / extract — returns clean Markdown. |
| **local-web-search** | `~/.agents/skills/local-web-search` | Bundled agent skill: search + read + auto-start the stack. |

> Both ports are fully configurable at install time. The defaults (`9990` and
> `9991`) are chosen to avoid clashing with common dev servers.

---

## Table of contents

1. [What you get](#what-you-get)
2. [Requirements](#requirements)
3. [Quick start (one-click install)](#quick-start-one-click-install)
4. [Managing the stack](#managing-the-stack)
5. [How it fits together](#how-it-fits-together)
6. [Using it with AI models](#using-it-with-ai-models)
   - [A. The bundled local-web-search skill (recommended)](#a-the-bundled-local-web-search-skill-recommended)
   - [B. Direct SearXNG JSON API](#b-direct-searxng-json-api)
   - [C. Direct Firecrawl REST API](#c-direct-firecrawl-rest-api)
   - [D. Connect a local LLM (LM Studio, etc.)](#d-connect-a-local-llm-lm-studio-etc)
   - [E. Via an MCP server](#e-via-an-mcp-server)
   - [F. Via prompting (any chat UI)](#f-via-prompting-any-chat-ui)
   - [G. GUI integrations](#g-gui-integrations)
7. [Configuration reference](#configuration-reference)
8. [Troubleshooting](#troubleshooting)
9. [Updating & uninstalling](#updating--uninstalling)
10. [Security notes](#security-notes)
11. [Credits & licenses](#credits--licenses)

---

## What you get

A single Docker Compose stack of six services on a private bridge network,
**plus** a ready-made agent skill that ties it all together:

| Service | Image | Role |
|---------|-------|------|
| **searxng** | `searxng/searxng:latest` | Metasearch engine with **JSON output enabled** and the rate-limiter **disabled**, so models can query it programmatically. |
| **firecrawl** | `ghcr.io/firecrawl/firecrawl:latest` | The scraping/crawling/search API. Runs with `USE_DB_AUTHENTICATION=false` → **no API key needed** for local use. |
| **playwright-service** | `ghcr.io/firecrawl/playwright-service:latest` | Headless Chromium for JavaScript-rendered pages. |
| **redis** | `redis:alpine` | Firecrawl job queue. |
| **rabbitmq** | `rabbitmq:3-management` | Firecrawl message broker. |
| **nuq-postgres** | `ghcr.io/firecrawl/nuq-postgres:latest` | Firecrawl job-state DB (pg_cron enabled). |

On top of the containers, the installer bundles **local-web-search** — a skill for
agents that load skills from `~/.agents/skills/` (`C:\Users\You\.agents\skills\`
on Windows). It gives the agent a complete web-research workflow: search via
SearXNG, read pages via Firecrawl, and even start the Docker stack
automatically when it's down. See [section A](#a-the-bundled-local-web-search-skill-recommended).

Only **two host ports** are published (`9990` and `9991` by default). Everything
else stays on the private `local-search-net` bridge network. Firecrawl's
`/v1/search` endpoint is automatically wired to SearXNG internally, so a single
Firecrawl call can both search *and* fetch full page content.

---

## Requirements

- **Docker** with the **Compose v2 plugin** (`docker compose`).
  - Windows / macOS: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
  - Linux: [Docker Engine](https://docs.docker.com/engine/install/) + the `docker-compose-plugin` package. Add your user to the `docker` group so you don't need `sudo`.
- **~5 GB free disk** for images and data.
- **8 GB RAM / 4 CPU cores** recommended (the Firecrawl + Playwright stack is the heavy part; reduce resource limits in `docker-compose.yml` for smaller hosts).
- **Python 3.8+** for the bundled local-web-search skill scripts (optional but recommended — it's the easiest way to use the stack).
- *(Optional, for Firecrawl AI features)* **LM Studio** or any OpenAI-compatible local server — see [section D](#d-connect-a-local-llm-lm-studio-etc).
- *(Optional, for MCP)* **Node.js 18+** so `npx firecrawl-mcp` works.

Verify Docker is ready:

```bash
docker info            # engine is running
docker compose version # v2 is installed
```

---

## Quick start (one-click install)

> **The installer is self-contained.** Every file it needs (`docker-compose.yml`,
> `config/searxng/settings.yml`, `.env.example`, the bundled `local-web-search` skill,
> all the run/stop/update/uninstall scripts, this README, and even the *other*
> platform's installer) is embedded inside it. You can download **just
> `install-local-search.bat`** (Windows) or **just `install-local-search.sh`**
> (Linux/macOS) on its own and the installer will still produce a complete,
> working folder. Downloading the whole `local-search` folder or the zip just
> makes the install a little faster (it copies files instead of decoding them).

Run **one** installer for your platform. It will ask you a few things — install
folder, SearXNG port, Firecrawl port, (optionally) a local LLM — with sensible
defaults you can accept by pressing **Enter**. It then generates
cryptographically-secure credentials, writes your `.env`, **installs the
local-web-search skill**, pulls the images, and starts the stack.

> **Docker isn't running?** No problem — the installer starts it for you: it
> launches Docker Desktop (Windows/macOS) or the Docker service
> (`systemctl`/`service`, Linux) and waits up to 5 minutes for the engine while
> you answer the prompts. (Override the wait with the
> `LOCAL_SEARCH_DOCKER_TIMEOUT` env var, in seconds.)

### Windows

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) — no need to open it first; the installer launches it automatically.
2. Double-click **`install-local-search.bat`** (or run it from a terminal).

```
--- Step 1 of 4: Install location ----------
  Target folder [press Enter for default]:            # C:\Users\You\local-search
--- Step 2 of 4: SearXNG port (default 9990) ------
  Port for SearXNG [press Enter for 9990]: 9990
--- Step 3 of 4: Firecrawl port (default 9991) ----
  Port for Firecrawl [press Enter for 9991]: 9991
--- Step 4 of 4: Local LLM (optional) -------------
  Connect a local LLM now? [y/N]:                       # optional, see section D
```

### Linux & macOS

```bash
chmod +x install-local-search.sh
./install-local-search.sh
```

The prompts are the same. Defaults: install to `~/local-search`, SearXNG on
`9990`, Firecrawl on `9991`. A stopped Docker engine is started automatically
(Docker Desktop on macOS, `systemctl`/`service` on Linux).

> **First run downloads ~3–4 GB of Docker images** (the Playwright image bundles
> a full Chromium). Subsequent starts are a few seconds.

When it finishes you'll see:

```
SearXNG  (search + JSON API):  http://localhost:9990
Firecrawl (scrape/crawl API): http://localhost:9991
Agent skill: C:\Users\You\.agents\skills\local-web-search   (or ~/.agents/skills/local-web-search)
```

Open `http://localhost:9990` in a browser to see the SearXNG search UI — or,
if your agent loads skills from `~/.agents/skills/`, just ask it to research
something current and it will use **local-web-search** automatically (see
[section A](#a-the-bundled-local-web-search-skill-recommended)).

---

## Managing the stack

After install, the management scripts live **in your install folder**
(`C:\Users\You\local-search` on Windows, `~/local-search` on Linux/macOS).
They auto-detect their own location, so you can run them from anywhere by
double-clicking or `./`-ing them.

| Action | Windows | Linux / macOS |
|--------|---------|---------------|
| **Start** the stack | `Run.bat` | `./run.sh` |
| **Stop** (keep data) | `Stop.bat` | `./stop.sh` |
| **Update** images + apply `.env` changes + **re-sync the skill** | `Update.bat` | `./update.sh` |
| **Uninstall** (containers + volumes + skill, optional folder delete) | `Uninstall.bat` | `./uninstall.sh` |

- **Stop** only removes containers; your data volumes (Firecrawl job state,
  redis cache, rabbitmq/postgres data) are preserved.
- **Update** runs `docker compose pull` then `docker compose up -d`, so it
  both upgrades images **and** applies any port/LLM edits you made to `.env`;
  it also re-copies the bundled `local-web-search` skill into `~/.agents/skills/`.
- **Uninstall** runs `docker compose down -v` (deletes volumes + data),
  removes the `local-web-search` skill from `~/.agents/skills/local-web-search`, then
  optionally deletes the install folder. Pulled images are kept; reclaim them
  with `docker image prune -a` if desired.

---

## How it fits together

```
        your AI model / agent (local-web-search skill) / MCP client / chat UI
                      │
   ┌──────────────────┼─────────────────────┐
   ▼                                       ▼
http://localhost:9990            http://localhost:9991
   │ SearXNG                            │ Firecrawl API
   │  - /search?q=...&format=json       │  - /v1/scrape   (one URL -> markdown)
   │  - aggregates ~70 engines           │  - /v1/crawl    (whole site, async)
   │                                     │  - /v1/map      (site URL tree)
   │                                     │  - /v1/search   (-> uses SearXNG!)
   │                                     │  - /v1/extract  (-> uses your LLM)
   │◄────────── wired together ──────────┤  SEARXNG_ENDPOINT=http://searxng:8080
   │                                     │
   └─────── private docker network ──────┘
                 local-search-net
   also on it: playwright-service (Chromium), redis, rabbitmq, nuq-postgres
```

Three key wiring decisions the installer makes for you:

1. **SearXNG JSON + no limiter** — `config/searxng/settings.yml` sets
   `search.formats: [html, json]` and `server.limiter: false`, so models can hit
   `/search?format=json` without being blocked as a bot.
2. **Firecrawl → SearXNG** — the Firecrawl container sets
   `SEARXNG_ENDPOINT=http://searxng:8080`, so Firecrawl's `/v1/search` uses your
   local SearXNG instead of needing a third-party search provider.
3. **local-web-search skill auto-install** — the installer copies the bundled skill to
   `~/.agents/skills/local-web-search/` (add/override) and records the install path in
   an `install-dir.txt` hint inside the skill, so the skill finds the stack even
   if you installed to a custom folder and Docker isn't running yet.

---

## Using it with AI models

There are **seven** ways to use this system, from lowest to highest
integration. Pick what fits your stack — you can mix and match.

### A. The bundled local-web-search skill (recommended)

The installer ships with **local-web-search**, an agent skill that turns any
skill-loading agent into a web researcher with zero configuration. If your
agent reads skills from `~/.agents/skills/`
(`C:\Users\You\.agents\skills\` on Windows), it's already available after
install — restart the agent if it was running.

The installer:
- puts a copy in `<install folder>/local-web-search/`, and
- **automatically installs (add/override)** it into
  `~/.agents/skills/local-web-search/`.

What the skill does for the agent:

- **Finds the stack automatically.** It reads the real ports from your `.env`
  (so custom install-time ports just work) and locates the install folder via
  the compose labels on the running containers, the installer-recorded
  `install-dir.txt` hint, or `~/local-search` — no hardcoded anything.
- **Self-heals a down stack — no warm-up step.** If the Docker engine or the
  containers are down when a search/scrape runs, the script boots the engine
  (Docker Desktop / `systemctl start docker`), runs the same `docker compose
  up -d` that `Run.bat` / `run.sh` use, waits for the endpoints, and retries
  the request — so the agent calls the search/scrape scripts directly, even
  in an old conversation where the stack has since gone down
  (`ensure_stack.py` remains available as an optional pre-flight check). The
  stack is **never stopped** by the scripts (stopping is your job, via
  `Stop.bat` / `stop.sh`).
- **Searches the web.** `web_search.py "query"` prints the top results as
  `title / url / snippet`, with `--limit`, `--time-range day|week|month`, and
  `--categories it,news,general` options.
- **Reads pages.** `web_scrape.py <url>` returns the page as clean Markdown
  (truncated at 20,000 chars; raise with `--max-chars`).

Manual usage (exactly what the agent runs — no separate start step needed):

```bash
python ~/.agents/skills/local-web-search/scripts/web_search.py "latest python release"
python ~/.agents/skills/local-web-search/scripts/web_scrape.py "https://example.com"
# optional pre-flight check / status report:
python ~/.agents/skills/local-web-search/scripts/ensure_stack.py --check
```

The full agent-facing instructions live in the skill's `SKILL.md`. Keeping the
skill fresh is automatic: `Update.bat` / `./update.sh` re-syncs it, and
re-running the installer overwrites it. Uninstalling removes it.

> The skill only needs **Python 3.8+** on the host — no pip packages, no API
> keys, no MCP support required from the agent.

---

### B. Direct SearXNG JSON API

The simplest possible integration: hit SearXNG's JSON endpoint and feed the
results into any model's context. No SDK, no key, no MCP.

```bash
# Search the web, return JSON, show the top 5 results
curl -s "http://localhost:9990/search?q=latest+AI+news&format=json" \
  | jq '.results[:5] | .[] | {title, url, content}'
```

Useful query params: `&pageno=2`, `&categories=it,images`, `&time_range=day`,
`&language=en`, `&engines=google,bing,duckduckgo`.

In Python:

```python
import requests
r = requests.get("http://localhost:9990/search", params={
    "q": "rust async runtime tokio",
    "format": "json",
    "language": "en",
}).json()
for hit in r["results"][:5]:
    print(hit["title"], "->", hit["url"])
    print(hit.get("content", "")[:200])
```

> SearXNG returns titles, URLs, and short content snippets — perfect for a
> "search then summarize" agent loop. For **full page text**, use Firecrawl (C).

---

### C. Direct Firecrawl REST API

Firecrawl turns any URL into clean Markdown/HTML/JSON — ideal for RAG. Because
the self-hosted instance runs with `USE_DB_AUTHENTICATION=false`, **no API key
is required** (you can send any `Authorization: Bearer …` header, or none).

#### Scrape a single page → Markdown

```bash
curl -s -X POST http://localhost:9991/v1/scrape \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","formats":["markdown"]}' \
  | jq '.data.markdown'
```

#### Search the web (uses your SearXNG internally) + return full content

```bash
curl -s -X POST http://localhost:9991/v1/search \
  -H "Content-Type: application/json" \
  -d '{"query":"what is rust programming language","limit":5}' \
  | jq '.data[:3] | .[] | {title, url, markdown}'
```

#### Crawl a whole site (async)

```bash
# 1) start the crawl
JOB=$(curl -s -X POST http://localhost:9991/v1/crawl \
  -H "Content-Type: application/json" \
  -d '{"url":"https://docs.example.com","limit":20}' | jq -r .id)

# 2) poll until status == "completed"
curl -s "http://localhost:9991/v1/crawl/$JOB" | jq '{status, completed, total}'
```

#### Map a site's URL tree (fast, no scraping)

```bash
curl -s -X POST http://localhost:9991/v1/map \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","limit":50}' | jq '.links'
```

#### Extract structured data with an LLM (needs section D configured)

```bash
curl -s -X POST http://localhost:9991/v1/extract \
  -H "Content-Type: application/json" \
  -d '{"urls":["https://example.com"],"prompt":"Extract the company name and a contact email"}' \
  | jq '.data'
```

#### Using the Firecrawl SDKs (Node / Python)

Self-host works with the official SDKs — point them at your local URL and pass
any non-empty string as the key:

**Node.js**
```js
import Firecrawl from "@mendable/firecrawl-js";

const fc = new Firecrawl({
  apiKey: "fc-local",              // any non-empty string; self-host doesn't validate
  apiUrl: "http://localhost:9991", // <-- point at your local instance
});

const { data } = await fc.scrapeUrl("https://example.com", { formats: ["markdown"] });
console.log(data.markdown);
```

**Python**
```python
from firecrawl import FirecrawlApp

fc = FirecrawlApp(api_key="fc-local", api_url="http://localhost:9991")
result = fc.scrape_url("https://example.com", params={"formats": ["markdown"]})
print(result["markdown"])
```

---

### D. Connect a local LLM (LM Studio, etc.)

By default, Firecrawl's `/v1/scrape`, `/v1/crawl`, `/v1/map`, and `/v1/search`
work **without any LLM**. To unlock **`/v1/extract`** (AI extraction) and the
`summary` output format, point Firecrawl at any **OpenAI-compatible** endpoint.
**LM Studio is the recommended default** (priority over Ollama).

#### Recommended: LM Studio

1. Install [LM Studio](https://lmstudio.ai/), download a model (e.g. `Qwen2.5-7B-Instruct`).
2. Go to the **Developer** tab → **Start Server** on port `1234` (default).
3. **Enable "Serve on local network"** (required — Firecrawl runs in a container
   and reaches your host via `host.docker.internal`, which is your LAN IP, not
   `127.0.0.1`).
4. Either:
   - re-run the installer and answer **y** to *"Connect a local LLM now?"* — it
     auto-converts `http://localhost:1234/v1` → `http://host.docker.internal:1234/v1`
     and writes it into `.env`; **or**
   - edit `.env` directly and set:
     ```env
     OPENAI_BASE_URL=http://host.docker.internal:1234/v1
     OPENAI_API_KEY=lm-studio
     MODEL_NAME=<the model id loaded in LM Studio>
     ```
5. Apply with `Update.bat` / `./update.sh`.

#### Other OpenAI-compatible servers (vLLM, llama.cpp `server`, text-generation-inference, LocalAI, …)

```env
OPENAI_BASE_URL=http://<host-or-ip>:<port>/v1
OPENAI_API_KEY=placeholder      # any non-empty string if your server ignores it
MODEL_NAME=<model id from GET /v1/models>
```

For a remote server on another machine, use its IP directly (e.g.
`http://192.168.1.50:8000/v1`). For a server on the **same host as Docker**, use
`http://host.docker.internal:<port>/v1`.

#### Fallback: Ollama

If you prefer Ollama, set (Firecrawl reads `OLLAMA_BASE_URL`):

```env
OLLAMA_BASE_URL=http://host.docker.internal:11434/api
MODEL_NAME=qwen2.5:7b
MODEL_EMBEDDING_NAME=nomic-embed-text
```

Restart with `Update.bat` / `./update.sh`, then `/v1/extract` routes to Ollama.

---

### E. Via an MCP server

The official [**Firecrawl MCP server**](https://github.com/firecrawl/firecrawl-mcp-server)
exposes `firecrawl_search`, `firecrawl_scrape`, `firecrawl_crawl`, `firecrawl_map`,
`firecrawl_extract`, and research tools to any MCP-compatible client. Point it at
your local Firecrawl with `FIRECRAWL_API_URL`.

#### Claude Desktop (`claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "firecrawl": {
      "command": "npx",
      "args": ["-y", "firecrawl-mcp"],
      "env": {
        "FIRECRAWL_API_URL": "http://localhost:9991",
        "FIRECRAWL_API_KEY": "fc-local"
      }
    }
  }
}
```

#### Cursor, VS Code, Windsurf, Continue, Cline, etc.

Same shape — add an `mcpServers` entry to that tool's config file
(`~/.cursor/mcp.json`, `.vscode/mcp.json`, `./codeium/windsurf/model_config.json`, …).

```json
{
  "mcpServers": {
    "firecrawl": {
      "command": "npx",
      "args": ["-y", "firecrawl-mcp"],
      "env": {
        "FIRECRAWL_API_URL": "http://localhost:9991",
        "FIRECRAWL_API_KEY": "fc-local"
      }
    }
  }
}
```

> The MCP server runs on your host (not in Docker), so it reaches Firecrawl at
> `http://localhost:9991`. **No real API key is needed** — `fc-local` is a
> placeholder; the self-hosted Firecrawl doesn't validate it. Requires Node.js
> 18+ for `npx`.

> **Note for local llama.cpp servers:** the Firecrawl MCP server ships very
> large tool definitions, which can exceed some local inference servers'
> limits (e.g. llama.cpp's `MAX_REPETITION_THRESHOLD` of 2000). If your local
> model fails to load the MCP tools, use the bundled **local-web-search skill**
> ([section A](#a-the-bundled-local-web-search-skill-recommended)) instead — it works
> with any model that can run a shell command, and is the recommended path for
> local setups anyway.

#### Run the MCP server over HTTP (optional)

```bash
HTTP_STREAMABLE_SERVER=true \
FIRECRAWL_API_URL=http://localhost:9991 \
FIRECRAWL_API_KEY=fc-local \
npx -y firecrawl-mcp
# -> http://localhost:3000/mcp
```

---

### F. Via prompting (any chat UI)

No MCP, no SDK, no code — just tell the model where the tools are. Paste this
system prompt into **LM Studio's chat**, **Open WebUI**, **ChatBox**, or any UI
that lets you set a system prompt and has a "web request"/function/tool feature:

```
You have two local web tools running on this machine. Use them whenever the
user asks about anything current or anything you're unsure about.

1) SEARCH the web (returns JSON: title, url, content for each hit):
   GET http://localhost:9990/search?q=<URL-ENCODED-QUERY>&format=json&language=en
   Read .results[] (each has .title, .url, .content).

2) READ a web page as clean Markdown (no API key needed):
   POST http://localhost:9991/v1/scrape   Content-Type: application/json
   body: {"url":"<URL>","formats":["markdown"]}
   Read .data.markdown.

Workflow: SEARCH to find URLs, then SCRAPE the most relevant 1–3 URLs for full
text, then answer with citations. If a search or scrape fails, retry once with a
different query/URL. Never invent URLs — only use ones returned by SearXNG.
```

For UIs that only let you paste URLs (no tool calling), the model can still
emit `curl` commands or instruct you to run them; or you can wire the endpoints
behind a tiny proxy. The point is: the moment a model can issue HTTP GET/POST to
`localhost:9990` and `localhost:9991`, it has full web access.

---

### G. GUI integrations

| App | How |
|-----|-----|
| **Open WebUI** | Settings → Web Search → SearXNG. Set base URL `http://localhost:9990`. Enable "Search the web" in chats. (For page reading, add the SearXNG results to context or use a Firecrawl tool.) |
| **AnythingLLM** | "Web Search" provider = SearXNG, endpoint `http://localhost:9990`. |
| **Dify / Flowise / Langflow** | Add a SearXNG tool node and a Firecrawl HTTP-request tool node (URL `http://localhost:9991/v1/scrape`). |
| **n8n / Zapier-ish** | HTTP Request nodes to the two endpoints. |
| **LangChain / LlamaIndex** | Use a `RequestsToolkit` / custom tool that GETs/POSTs the two URLs. |

---

## Configuration reference

All runtime config lives in **`.env`** in your install folder (generated by the
installer; documented in `.env.example`). Edit it, then run `Update.bat` /
`./update.sh` to apply.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SEARXNG_PORT` | `9990` | Host port for the SearXNG UI + JSON API. |
| `FIRECRAWL_PORT` | `9991` | Host port for the Firecrawl API. |
| `SEARXNG_SECRET` | *(random)* | SearXNG session secret — also injected into `config/searxng/settings.yml`. |
| `BULL_AUTH_KEY` | *(random)* | Protects the (disabled-by-default) Firecrawl queue admin UI. |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | `firecrawl` / `firecrawl` / *(random)* | Firecrawl job-state DB credentials. |
| `RABBITMQ_USER` / `RABBITMQ_PASSWORD` | `firecrawl` / *(random)* | Firecrawl message-broker credentials. |
| `LOGGING_LEVEL` | `info` | Firecrawl log verbosity (`debug`/`info`/`warn`/`error`). |
| `OPENAI_BASE_URL` | *(unset)* | OpenAI-compatible LLM endpoint for `/v1/extract` + summaries. For a same-host server use `http://host.docker.internal:<port>/v1`. |
| `OPENAI_API_KEY` | *(unset)* | Any non-empty string (most local servers ignore it). |
| `MODEL_NAME` | *(unset)* | The model id to use. |
| `OLLAMA_BASE_URL` | *(unset)* | Use instead of `OPENAI_*` for an Ollama backend. |

SearXNG behaviour (engines, formats, limiter) is tuned in
`config/searxng/settings.yml`. The defaults enable JSON output and disable the
bot limiter. To add/remove engines, edit that file and run `Update.bat` /
`./update.sh` (the container reads it at start).

The local-web-search skill needs no configuration: it reads the same `.env` at
runtime. The only extra file it uses is `install-dir.txt` (written by the
installer next to the skill's `SKILL.md`), which records the install folder so
the skill can start the stack even from a non-default location. To point the
skill at a different folder, set the `LOCAL_SEARCH_DIR` environment variable.

---

## Troubleshooting

**The installer says the Docker engine "did not come online".**
The installer launches Docker Desktop / the docker service when the engine is
down, then waits up to 5 minutes (override with the `LOCAL_SEARCH_DOCKER_TIMEOUT`
env var, in seconds). If it times out, start Docker yourself, wait until it
reports "running", and re-run the installer — anything it already wrote is
safely overwritten.

**`docker compose up` fails with a port already in use.**
Re-run the installer and pick different ports, or stop whatever's using 9990/9991.

**SearXNG returns `429 Too Many Requests` or blocks requests.**
You're hitting an external engine's rate limit (not SearXNG itself). Wait a
minute, or in `config/searxng/settings.yml` remove the offending engine under
`engines:`. The internal limiter is already disabled for local use.

**`/v1/extract` returns an error / "model not configured".**
You haven't connected an LLM — see [section D](#d-connect-a-local-llm-lm-studio-etc).
`/v1/scrape`, `/v1/crawl`, `/v1/map`, `/v1/search` work without one.

**Firecrawl can't reach your LM Studio.**
From inside the Firecrawl container your host is `host.docker.internal`, **not**
`localhost`. Make sure (a) LM Studio has **"Serve on local network"** enabled,
and (b) `.env` has `OPENAI_BASE_URL=http://host.docker.internal:1234/v1`
(the installer does this conversion automatically). Test from the host first:
`curl http://localhost:1234/v1/models`.

**The local-web-search skill can't find the install folder.**
The skill looks for the compose folder via (1) the `LOCAL_SEARCH_DIR` env var,
(2) the compose labels on the running containers, (3) the `install-dir.txt`
hint the installer wrote next to the skill, and (4) `~/local-search`. If you
moved the install folder, re-run the installer or `Update.bat` / `./update.sh`
to refresh the hint — or export `LOCAL_SEARCH_DIR=/path/to/local-search`.

**The agent doesn't see the skill after install.**
Skills are usually scanned at agent startup — restart the agent. Also check the
skill actually landed at `~/.agents/skills/local-web-search/SKILL.md` (the installer
prints where it put it).

**First `docker compose pull` is slow / hits a GHCR 401.**
The Firecrawl images are public, but rate-limited. Authenticate:
`echo "$GITHUB_PAT" | docker login ghcr.io -u YOUR_GH_USER --password-stdin`
(token needs `read:packages`), then re-run `Update.bat` / `./update.sh`.

**Containers keep restarting.**
Check logs: `docker compose logs firecrawl` (or `searxng`). The most common
cause is a missing/empty `.env` value (e.g. `RABBITMQ_PASSWORD`). Re-run the
installer to regenerate a clean `.env`.

**SearXNG UI loads but `/search?format=json` returns HTML.**
The JSON format isn't enabled. Your `config/searxng/settings.yml` must contain
`search: formats: [html, json]` (the shipped config does). Restart with
`Update.bat` / `./update.sh` after editing.

**Reset everything to defaults.**
Run `Uninstall.bat` / `./uninstall.sh` (deletes volumes + data + the skill),
then run the installer again.

---

## Updating & uninstalling

- **Update images & apply config changes & re-sync the skill:** `Update.bat` /
  `./update.sh` (`docker compose pull && docker compose up -d`, then re-copy
  `local-web-search` into `~/.agents/skills/`). Data is preserved.
- **Update the SearXNG `settings.yml` / `docker-compose.yml` template:** re-run
  the installer — it copies the latest template over, refreshes the
  `local-web-search` skill, and backs up your existing `.env` to `.env.bak.<timestamp>`.
- **Uninstall:** `Uninstall.bat` / `./uninstall.sh`. Removes containers + Docker
  volumes (all Firecrawl/SearXNG data) + the `local-web-search` skill from
  `~/.agents/skills/local-web-search`, then asks whether to delete the install folder.
  Pulled images remain; reclaim with `docker image prune -a`.

---

## Security notes

- This stack is designed for **local / trusted-network use**. Firecrawl's API is
  **unauthenticated** (`USE_DB_AUTHENTICATION=false`) so your models can call it
  without a key. **Do not expose ports 9990/9991 to the public internet.**
- All credentials (`SEARXNG_SECRET`, `BULL_AUTH_KEY`, `POSTGRES_PASSWORD`,
  `RABBITMQ_PASSWORD`) are generated as 256-bit random hex at install time and
  stored only in your local `.env`.
- SearXNG's bot limiter is disabled and JSON output is enabled so models can
  query it — this is intentional for local use. On a public instance you'd want
  the limiter back on.
- Your search queries and scraped page contents never leave your machine
  (except the outbound fetches SearXNG/Firecrawl make to the public web, which
  is the whole point).

---

## Credits & licenses

This project is licensed under the **MPL-2.0** license — see [LICENSE](LICENSE)
(it covers the bundled [local-web-search](local-web-search) skill too).

- [**SearXNG**](https://github.com/searxng/searxng) — AGPL-3.0, privacy-respecting metasearch engine.
- [**Firecrawl**](https://github.com/firecrawl/firecrawl) — AGPL-3.0, the context API for web scraping/crawling/search.
- [**Firecrawl MCP server**](https://github.com/firecrawl/firecrawl-mcp-server) — MIT.
- The upstream projects retain their own licenses — please respect them.
  Nothing from them is bundled in this repository; the installer only pulls
  their official container images at install time.

---

<sub>Built so any local model — in LM Studio or otherwise — can search and read
the web without a paid API key. Contributions welcome.</sub>
EOF_README_MD
fi

# --- LICENSE ---
if [ -f "$SRC/LICENSE" ]; then
  cp "$SRC/LICENSE" "$TARGET/LICENSE"
else
  say "  [embedded] LICENSE  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/LICENSE" <<'EOF_LICENSE'
Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at https://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.
EOF_LICENSE
fi

# --- .gitignore ---
if [ -f "$SRC/.gitignore" ]; then
  cp "$SRC/.gitignore" "$TARGET/.gitignore"
else
  say "  [embedded] .gitignore  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/.gitignore" <<'EOF__GITIGNORE'
# ---- Generated at install time (contains your ports and secrets) ----
.env
.env.bak.*

# ---- Written by the installer into installed skill copies ----
# (the source copy in the repo must stay clean; the installer records the
#  install path here when it copies the skill to ~/.agents/skills/local-web)
local-web/install-dir.txt

# ---- Python bytecode (skill scripts) ----
__pycache__/
*.pyc

# ---- OS junk ----
.DS_Store
Thumbs.db
desktop.ini

# ---- Logs ----
*.log
EOF__GITIGNORE
fi

# --- .gitattributes ---
if [ -f "$SRC/.gitattributes" ]; then
  cp "$SRC/.gitattributes" "$TARGET/.gitattributes"
else
  say "  [embedded] .gitattributes  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/.gitattributes" <<'EOF__GITATTRIBUTES'
# Normalize text files in the repo; keep platform-native line endings on checkout
* text=auto

# Windows batch files must keep CRLF working copies
*.bat text eol=crlf
*.cmd text eol=crlf
*.ps1 text eol=crlf

# Unix scripts must stay LF
*.sh text eol=lf
*.py text eol=lf
*.yml text eol=lf
*.yaml text eol=lf

# Docs
*.md text
LICENSE text
EOF__GITATTRIBUTES
fi

# --- Run.bat ---
if [ -f "$SRC/Run.bat" ]; then
  cp "$SRC/Run.bat" "$TARGET/Run.bat"
else
  say "  [embedded] Run.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/Run.bat" <<'EOF_RUN_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Run

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH. Install Docker Desktop first.
  pause
  exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker engine is not running. Start Docker Desktop first.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder.
  echo   Run install-local-search.bat first to create the configuration.
  pause
  exit /b 1
)

echo Starting Local Search (Firecrawl + SearXNG)...
docker compose up -d
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to start. See messages above.
  pause
  exit /b 1
)

echo.
echo Local Search is running:
echo   SearXNG:   http://localhost:9990      ^(change in .env^)
echo   Firecrawl: http://localhost:9991      ^(change in .env^)
echo.
echo Open the SearXNG UI in your browser, or query the JSON API from your models.
echo Use Stop.bat to stop the stack.
echo.
pause
exit /b 0
EOF_RUN_BAT
fi

# --- Stop.bat ---
if [ -f "$SRC/Stop.bat" ]; then
  cp "$SRC/Stop.bat" "$TARGET/Stop.bat"
else
  say "  [embedded] Stop.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/Stop.bat" <<'EOF_STOP_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Stop

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder. Nothing to stop.
  pause
  exit /b 1
)

echo Stopping Local Search containers (data is preserved)...
docker compose down
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to stop. See messages above.
  pause
  exit /b 1
)

echo.
echo Local Search stopped. Data is preserved in Docker volumes.
echo Run Run.bat to start it again.
echo.
pause
exit /b 0
EOF_STOP_BAT
fi

# --- Update.bat ---
if [ -f "$SRC/Update.bat" ]; then
  cp "$SRC/Update.bat" "$TARGET/Update.bat"
else
  say "  [embedded] Update.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/Update.bat" <<'EOF_UPDATE_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Update

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH.
  pause
  exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker engine is not running. Start Docker Desktop first.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder.
  echo   Run install-local-search.bat first to create the configuration.
  pause
  exit /b 1
)

echo Updating Local Search...
echo.
echo [1/3] Pulling latest images...
docker compose pull
if errorlevel 1 (
  echo.
  echo [WARNING] Some images failed to pull. Continuing with what is available.
)

echo.
echo [2/3] Recreating containers with updated images (data is preserved)...
docker compose up -d
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to recreate containers. See messages above.
  pause
  exit /b 1
)

echo.
echo [3/3] Refreshing the local-web-search agent skill...
if exist "%~dp0local-web-search\SKILL.md" (
  set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web-search"
  if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"
  if not exist "%USERPROFILE%\.agents\skills" mkdir "%USERPROFILE%\.agents\skills"
  xcopy /E /I /Y /Q "%~dp0local-web-search" "!SKILL_DIR!" >nul
  if errorlevel 1 (
    echo   [WARNING] Could not copy the skill to !SKILL_DIR!.
  ) else (
    > "!SKILL_DIR!\install-dir.txt" echo %~dp0
    echo   Skill refreshed at !SKILL_DIR!
  )
) else (
  echo   local-web-search skill source not found in this folder - skipping.
)

echo.
echo Update complete. Data volumes were preserved.
echo   - If you changed ports or LLM settings in .env, they are now applied.
echo   - The local-web-search skill was re-synced from this folder.
echo   - To update the SearXNG settings.yml or docker-compose.yml template,
echo     re-run install-local-search.bat (it backs up your current .env).
echo.
pause
exit /b 0
EOF_UPDATE_BAT
fi

# --- Uninstall.bat ---
if [ -f "$SRC/Uninstall.bat" ]; then
  cp "$SRC/Uninstall.bat" "$TARGET/Uninstall.bat"
else
  say "  [embedded] Uninstall.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/Uninstall.bat" <<'EOF_UNINSTALL_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Uninstall

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH.
  echo   You can manually delete this folder to remove the files.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder. Nothing to uninstall.
  pause
  exit /b 1
)

echo ============================================================
echo   Uninstall Local Search
echo ============================================================
echo This will:
echo   1. Stop and remove all Local Search containers.
echo   2. Remove the Docker VOLUMES (Firecrawl job state, redis cache,
echo      rabbitmq/postgres data). This deletes all stored data.
echo   3. Remove the local-web-search agent skill from
echo      %USERPROFILE%\.agents\skills\local-web-search
echo   4. (Optional) Delete the install folder and all its files.
echo.
echo   Pulled Docker images are NOT removed (use "docker image prune" to
echo   reclaim that disk space separately).
echo.
set "CONFIRM="
set /p CONFIRM="Continue with uninstall? [y/N]: "
if /i not "!CONFIRM!"=="y" ( echo Uninstall cancelled. & pause & exit /b 0 )

echo.
echo Stopping and removing containers + volumes...
docker compose down -v --remove-orphans
if errorlevel 1 (
  echo.
  echo [WARNING] docker compose down reported errors.
  echo   You may need to remove leftover containers manually, e.g.:
  echo     docker rm -f local-search-firecrawl local-search-searxng
  echo     docker rm -f local-search-redis local-search-rabbitmq
  echo     docker rm -f local-search-postgres local-search-playwright
)

echo.
echo Containers and volumes removed.
echo.
echo Removing the local-web-search agent skill...
set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web-search"
if exist "!SKILL_DIR!" (
  rd /s /q "!SKILL_DIR!"
  echo   Removed !SKILL_DIR!
) else (
  echo   Skill not found ^(already removed^) - nothing to do.
)
echo.
set "DELFILES="
set /p DELFILES="Also delete the install folder and ALL its files? [y/N]: "
if /i not "!DELFILES!"=="y" (
  echo.
  echo Uninstall finished. The folder was kept:
  echo   %CD%
  echo   You can delete it manually if you no longer need the scripts.
  echo.
  pause
  exit /b 0
)

cd /d "%USERPROFILE%"
echo Deleting install folder: %~dp0
rd /s /q "%~dp0"
echo.
echo Uninstall complete. Goodbye!
echo.
pause
exit /b 0
EOF_UNINSTALL_BAT
fi

# --- run.sh ---
if [ -f "$SRC/run.sh" ]; then
  cp "$SRC/run.sh" "$TARGET/run.sh"
else
  say "  [embedded] run.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/run.sh" <<'EOF_RUN_SH'
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
EOF_RUN_SH
fi

# --- stop.sh ---
if [ -f "$SRC/stop.sh" ]; then
  cp "$SRC/stop.sh" "$TARGET/stop.sh"
else
  say "  [embedded] stop.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/stop.sh" <<'EOF_STOP_SH'
#!/usr/bin/env bash
# Stop the Local Search stack (containers removed, data preserved).
set -u
cd "$(dirname "$0")" || exit 1

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker is not installed." >&2; exit 1
fi
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else echo "[ERROR] Docker Compose not found." >&2; exit 1; fi

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found. Nothing to stop." >&2; exit 1
fi

echo "Stopping Local Search containers (data is preserved)..."
$DC down || { echo "[ERROR] Failed to stop." >&2; exit 1; }

echo
echo "Local Search stopped. Data is preserved in Docker volumes."
echo "Run ./run.sh to start it again."
EOF_STOP_SH
fi

# --- update.sh ---
if [ -f "$SRC/update.sh" ]; then
  cp "$SRC/update.sh" "$TARGET/update.sh"
else
  say "  [embedded] update.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/update.sh" <<'EOF_UPDATE_SH'
#!/usr/bin/env bash
# Update the Local Search stack: pull latest images, recreate containers,
# and re-sync the local-web-search agent skill. Data volumes are preserved. Edits
# to .env (ports, LLM) are also applied.
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
  echo "[ERROR] No .env file found. Run install-local-search.sh first." >&2
  exit 1
fi

echo "Updating Local Search..."
echo
echo "[1/3] Pulling latest images..."
$DC pull || echo "[WARNING] Some images failed to pull. Continuing."

echo
echo "[2/3] Recreating containers with updated images (data is preserved)..."
$DC up -d || { echo "[ERROR] Failed to recreate containers." >&2; exit 1; }

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
echo "Update complete. Data volumes were preserved."
echo "  - Port / LLM changes in .env are now applied."
echo "  - The local-web-search skill was re-synced from this folder."
echo "  - To update the SearXNG settings.yml or docker-compose.yml template,"
echo "    re-run install-local-search.sh (it backs up your current .env)."
EOF_UPDATE_SH
fi

# --- uninstall.sh ---
if [ -f "$SRC/uninstall.sh" ]; then
  cp "$SRC/uninstall.sh" "$TARGET/uninstall.sh"
else
  say "  [embedded] uninstall.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/uninstall.sh" <<'EOF_UNINSTALL_SH'
#!/usr/bin/env bash
# Uninstall the Local Search stack.
#   - stops & removes containers
#   - removes Docker volumes (Firecrawl job state, redis, rabbitmq, postgres)
#   - removes the local-web-search agent skill (~/.agents/skills/local-web-search)
#   - optionally deletes the install folder
set -u
cd "$(dirname "$0")" || exit 1
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }  # bash-3.2 (macOS) safe

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker is not installed. You can delete this folder manually." >&2
  exit 1
fi
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else echo "[ERROR] Docker Compose not found." >&2; exit 1; fi

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found. Nothing to uninstall." >&2; exit 1
fi

cat <<'MSG'
============================================================
  Uninstall Local Search
============================================================
This will:
  1. Stop and remove all Local Search containers.
  2. Remove the Docker VOLUMES (Firecrawl job state, redis cache,
     rabbitmq/postgres data). This deletes all stored data.
  3. Remove the local-web-search agent skill from
     ~/.agents/skills/local-web-search
  4. (Optional) Delete the install folder and all its files.

  Pulled Docker images are NOT removed (use 'docker image prune'
  to reclaim that disk space separately).
MSG
echo
printf "Continue with uninstall? [y/N]: "
read -r CONFIRM
if [ "$(lower "$CONFIRM")" != "y" ]; then echo "Uninstall cancelled."; exit 0; fi

echo
echo "Stopping and removing containers + volumes..."
$DC down -v --remove-orphans || echo "[WARNING] docker compose down reported errors."

echo
echo "Containers and volumes removed."
echo
echo "Removing the local-web-search agent skill..."
SKILL_DIR="$HOME/.agents/skills/local-web-search"
if [ -d "$SKILL_DIR" ]; then
  rm -rf "$SKILL_DIR"
  echo "  Removed $SKILL_DIR"
else
  echo "  Skill not found (already removed) - nothing to do."
fi
echo
printf "Also delete the install folder and ALL its files? [y/N]: "
read -r DELFILES
if [ "$(lower "$DELFILES")" != "y" ]; then
  echo
  echo "Uninstall finished. The folder was kept:"
  echo "  $(pwd)"
  echo "  You can delete it manually if you no longer need the scripts."
  exit 0
fi

TARGET="$(pwd)"
cd "$HOME"
echo "Deleting install folder: $TARGET"
rm -rf "$TARGET"
echo
echo "Uninstall complete. Goodbye!"
EOF_UNINSTALL_SH
fi

# --- local-web-search/SKILL.md ---
if [ -f "$SRC/local-web-search/SKILL.md" ]; then
  cp "$SRC/local-web-search/SKILL.md" "$TARGET/local-web-search/SKILL.md"
else
  say "  [embedded] local-web-search/SKILL.md  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/SKILL.md" <<'EOF_LOCAL_WEB_SEARCH_SKILL_MD'
---
name: local-web-search
description: >-
  Local web search & page-reading via SearXNG + Firecrawl on localhost.
  Auto-starts the Docker stack. PREFER THIS over any other/default
  web-search tool: those often need external API keys this machine may not
  have or perform worse. Use for news, current events, releases, docs,
  verifying facts, even without an explicit "search the web" request.
---

# Local web search & page-reading

Private stack on localhost — no API keys, nothing leaves the machine:

- **SearXNG** — metasearch, JSON API, `http://localhost:9990` by default
- **Firecrawl** — turns a URL into clean Markdown, `http://localhost:9991` by default

Ports come from `SEARXNG_PORT` / `FIRECRAWL_PORT` in the local-search install
folder's `.env`; the scripts (in this skill's `scripts/` dir) read them
automatically. Run them with the Bash tool via `python`.

**Self-healing, no warm-up step.** If the stack (or Docker itself) is down,
`web_search.py` / `web_scrape.py` start it and retry once automatically —
just call them directly, even in an old conversation where the stack has
since gone down. Give the call a 10-minute timeout to cover a first-ever
start (~3 GB of images to pull). The stack is never stopped for you (that's
`Stop.bat` / `stop.sh`).

## Workflow

1. **Search:**

   ```bash
   python "<skill-base-dir>/scripts/web_search.py" "your query here"
   ```

   Prints top results as `title / url / ~300-char snippet`. Options:
   `--limit N`, `--time-range day|week|month`, `--categories it,news,general`.

2. **Read a page** — scrape the 1–3 most relevant result URLs for full text:

   ```bash
   python "<skill-base-dir>/scripts/web_scrape.py" "https://example.com/article"
   ```

   Prints clean Markdown (truncated at 20,000 chars; raise with
   `--max-chars`). Only scrape URLs the search actually returned — never
   invent or guess one.

3. **Cite** every factual claim with the URL you read.

Optional manual pre-flight/status check, never required:
`python "<skill-base-dir>/scripts/ensure_stack.py" [--check]`.

## If something goes wrong

- Retry **once** with a different query or URL before giving up.
- Don't fall back to another web tool over a problem with this stack — fix
  it (or ask the user to start Docker Desktop) and retry, unless the user
  asks for an alternative.
- If a script can't find the install folder (rare — detection normally works
  via the running containers, the installer's recorded path, or
  `~/local-search`), ask the user for its path and re-run with
  `LOCAL_SEARCH_DIR=<path>`.
- Extract only what you need from scraped pages — don't paste whole pages
  back to the user.
EOF_LOCAL_WEB_SEARCH_SKILL_MD
fi

# --- local-web-search/scripts/config.py ---
if [ -f "$SRC/local-web-search/scripts/config.py" ]; then
  cp "$SRC/local-web-search/scripts/config.py" "$TARGET/local-web-search/scripts/config.py"
else
  say "  [embedded] local-web-search/scripts/config.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/config.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_CONFIG_PY'
"""Shared helpers for the local-web-search scripts: locating the local-search
install folder and the endpoints it is actually listening on.

The ports are NOT assumed: they are read from the install folder's .env
file (the same one the compose setup and Run.bat / Update.bat use), so if
the user picked custom ports during setup, every script follows them.
Defaults mirror the compose file's ${VAR:-default} fallbacks:
SearXNG 9990, Firecrawl 9991.
"""
import os
import subprocess
import sys

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252). config.py is imported first by every entry-point
# script, so this covers the process even if this module is ever imported
# on its own. Skipped if PYTHONIOENCODING is already set — an explicit
# override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

# Compose file names accepted as "this is the install folder".
_COMPOSE_FILES = ("docker-compose.yml", "docker-compose.yaml",
                  "compose.yml", "compose.yaml")

# .env key -> default port (matches the defaults in docker-compose.yml).
_PORT_KEYS = {
    "searxng": ("SEARXNG_PORT", "9990"),
    "firecrawl": ("FIRECRAWL_PORT", "9991"),
}


def _has_compose_file(d):
    return d is not None and any(
        os.path.isfile(os.path.join(d, f)) for f in _COMPOSE_FILES
    )


def _docker_labeled_install_dir():
    """The install folder per the compose label on the containers. Compose
    tags each container with the directory it was started from, so this
    finds the folder even though the skill itself lives elsewhere. The
    Docker engine must be running."""
    try:
        res = subprocess.run(
            ["docker", "container", "ls", "-a", "-q",
             "--filter", "label=com.docker.compose.service=searxng"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        ids = res.stdout.split()[:3]
    except (OSError, FileNotFoundError):
        return None
    for cid in ids:
        try:
            out = subprocess.run(
                ["docker", "container", "inspect", cid,
                 "--format",
                 '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except (OSError, FileNotFoundError):
            continue
        p = out.stdout.strip()
        if p and os.path.isdir(p):
            return p
    return None


def _hinted_install_dir():
    """The install path recorded by the local-search installer when it
    copied this skill (install-dir.txt next to SKILL.md). This works even
    when the Docker engine is down and the install folder is not in the
    default location. Returns None when there is no hint file (e.g. the
    skill was installed standalone from the local-web-search repo)."""
    hint_file = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             os.pardir, "install-dir.txt")
    try:
        with open(hint_file, encoding="utf-8") as fh:
            path = fh.read().strip().rstrip("\\/").strip()
        return path or None
    except OSError:
        return None


def find_install_dir():
    """The local-search install folder (holds the compose file), or None.

    Looked up in order:
      1. the LOCAL_SEARCH_DIR env var (explicit override),
      2. the compose label on the containers (engine must be running),
      3. install-dir.txt recorded by the local-search installer,
      4. ~/local-search (the installer's default location).
    """
    for d in (os.environ.get("LOCAL_SEARCH_DIR"),
              _docker_labeled_install_dir(),
              _hinted_install_dir(),
              os.path.expanduser("~/local-search")):
        if d and _has_compose_file(d):
            return d
    return None


def load_env(install_dir):
    """The install folder's .env as a dict (empty dict if missing/invalid)."""
    values = {}
    if not install_dir:
        return values
    try:
        with open(os.path.join(install_dir, ".env"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                values[key.strip()] = val.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def endpoints(install_dir=None):
    """{'searxng': 'http://localhost:<port>', 'firecrawl': '...'}, with the
    ports taken from the install folder's .env (defaults 9990/9991)."""
    values = load_env(install_dir)
    urls = {}
    for name, (key, default) in _PORT_KEYS.items():
        port = values.get(key)
        if not port or not port.isdigit():
            port = default
        urls[name] = "http://localhost:{}".format(port)
    return urls
EOF_LOCAL_WEB_SEARCH_SCRIPTS_CONFIG_PY
fi

# --- local-web-search/scripts/ensure_stack.py ---
if [ -f "$SRC/local-web-search/scripts/ensure_stack.py" ]; then
  cp "$SRC/local-web-search/scripts/ensure_stack.py" "$TARGET/local-web-search/scripts/ensure_stack.py"
else
  say "  [embedded] local-web-search/scripts/ensure_stack.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/ensure_stack.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_ENSURE_STACK_PY'
#!/usr/bin/env python3
"""Ensure the local-search stack is running before any web research.

Two ways to use it:

  1. As a CLI pre-flight check (OPTIONAL — the other scripts self-heal):
         python ensure_stack.py [--check]
     Exit codes: 0 ready, 1 down / could not be brought up, 2 prerequisites
     missing (no install folder, no Docker, no compose).

  2. As a module (used by web_search.py / web_scrape.py for self-healing):
         import ensure_stack
         ok, message, code = ensure_stack.ensure_ready()
     When a search/scrape request fails with a connection error, those
     scripts call ensure_ready() automatically, then retry the request
     once — so the agent can call them directly with no warm-up step.

Behaviour (both CLI and module):
  * Both endpoints answering -> return immediately (fast path, < 1 s).
  * Otherwise: make sure the Docker engine is running (if it is down, launch
    Docker Desktop / the docker service and wait for the daemon), then start
    the containers with `docker compose up -d` in the install folder (the
    same command Run.bat / run.sh run, without the interactive `pause`) and
    wait until both endpoints answer again.
    The stack is NEVER stopped by this script.

The readiness timeout defaults to 240 s and can be overridden with the
LOCAL_SEARCH_READY_TIMEOUT env var (seconds) — used by the test suite to
exercise the failure path quickly.

The install folder (holds docker-compose.yml) is found by config.py, in order:
    1. the LOCAL_SEARCH_DIR env var (explicit override),
    2. the compose label on the containers — compose tags each container with
       the directory it was started from (engine must be up),
    3. install-dir.txt — the path recorded by the local-search installer
       when it copied this skill,
    4. ~/local-search.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so status/progress messages never crash with a
# UnicodeEncodeError. Skipped if PYTHONIOENCODING is already set — an
# explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

READY_TIMEOUT = int(os.environ.get("LOCAL_SEARCH_READY_TIMEOUT", "240") or 240)
POLL_EVERY = 3
DISPLAY = {"searxng": "SearXNG", "firecrawl": "Firecrawl"}


def endpoint_up(url, timeout=4):
    """True if the endpoint accepts connections (any HTTP status counts)."""
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=timeout):
            return True
    except urllib.error.HTTPError:
        return True  # got an HTTP response (even 4xx/5xx) = service is up
    except Exception:
        return False  # connection refused / reset / timeout = down


def port_of(url):
    return url.rsplit(":", 1)[1]


def status(endpoints):
    return {name: endpoint_up(url) for name, url in endpoints.items()}


def ready_message(endpoints):
    return "Stack is ready (SearXNG :{0}, Firecrawl :{1}).".format(
        port_of(endpoints["searxng"]), port_of(endpoints["firecrawl"]))


def compose_command():
    if shutil.which("docker"):
        rc = subprocess.run(
            ["docker", "compose", "version"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if rc.returncode == 0:
            return ["docker", "compose"]
    if shutil.which("docker-compose"):
        return ["docker-compose"]
    return None


def docker_engine_up():
    try:
        return subprocess.run(
            ["docker", "info"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode == 0
    except (OSError, FileNotFoundError):
        return False


def find_docker_desktop_exe():
    candidates = [
        r"C:\Program Files\Docker\Docker\Docker Desktop.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe"),
    ]
    for p in candidates:
        if os.path.isfile(p):
            return p
    return None


def start_docker_engine():
    """Try to launch the Docker engine for this OS. True if the launch was
    initiated (not that it became ready — that's wait_for_engine's job)."""
    import platform
    system = platform.system()
    if system == "Windows":
        exe = find_docker_desktop_exe()
        if not exe:
            return False
        try:
            subprocess.Popen([exe],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except OSError:
            return False
    if system == "Darwin":
        try:
            subprocess.Popen(["open", "--background", "-a", "Docker"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except OSError:
            return False
    # Linux: best effort without an interactive password prompt.
    try:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            return subprocess.run(["systemctl", "start", "docker"],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL).returncode == 0
        return subprocess.run(["sudo", "-n", "systemctl", "start", "docker"],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, FileNotFoundError):
        return False


def wait_for_engine(timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if docker_engine_up():
            return True
        time.sleep(3)
    return False


def ensure_ready(check_only=False, ready_timeout=None, poll_every=None):
    """Bring the local-search stack to a ready state. NEVER stops it.

    Returns (ok, message, exit_code):
        ok         True when both endpoints answer.
        message    human-readable status / guidance (progress is printed to
                   stderr along the way).
        exit_code  0 ready, 1 down/could not bring up, 2 prerequisites
                   missing (matches the CLI exit codes).
    """
    if ready_timeout is None:
        ready_timeout = READY_TIMEOUT
    if poll_every is None:
        poll_every = POLL_EVERY

    endpoints = config.endpoints(config.find_install_dir())
    st = status(endpoints)
    if all(st.values()):
        return True, ready_message(endpoints), 0

    print("Local-search stack is DOWN:", file=sys.stderr)
    for name, url in endpoints.items():
        mark = "OK  " if st[name] else "DOWN"
        print(f"  [{mark}] {DISPLAY[name]} :{port_of(url)}", file=sys.stderr)
    if check_only:
        return False, "Stack is down (--check: nothing was started).", 1

    if not docker_engine_up():
        print("Docker engine is not running — trying to start it ...",
              file=sys.stderr)
        if not start_docker_engine():
            return False, ("Could not start the Docker engine automatically "
                           "(Docker Desktop not found in the usual locations?). "
                           "Start it manually, then re-run this script."), 2
        print("Waiting for the Docker engine to come up ...", file=sys.stderr)
        if not wait_for_engine(timeout=180):
            return False, ("The Docker engine was launched but did not answer within "
                           "180 s. Check Docker Desktop, then re-run this script."), 2

    # Recomputed now that the engine is up: the compose-label lookup (which
    # needs the engine) can find the install dir where the other methods
    # could not.
    install_dir = config.find_install_dir()
    if not install_dir:
        return False, ("Could not find the local-search install folder "
                       "(no docker-compose.yml found). Ask the user where their "
                       "local-search folder is, then re-run this script with "
                       "LOCAL_SEARCH_DIR set to that path, or start the stack manually "
                       "(Run.bat / run.sh)."), 2

    compose = compose_command()
    if not compose:
        return False, "Neither 'docker compose' nor 'docker-compose' is available.", 2

    print(f"Starting stack in {install_dir} ...", file=sys.stderr)
    proc = subprocess.run(compose + ["up", "-d"], cwd=install_dir)
    if proc.returncode != 0:
        return False, "'docker compose up -d' failed — see output above.", 1

    print("Waiting for endpoints ...", file=sys.stderr)
    deadline = time.time() + ready_timeout
    while time.time() < deadline:
        st = status(endpoints)
        if all(st.values()):
            return True, ready_message(endpoints), 0
        time.sleep(poll_every)

    for name, url in endpoints.items():
        mark = "OK  " if st[name] else "DOWN"
        print(f"  [{mark}] {DISPLAY[name]} :{port_of(url)}", file=sys.stderr)
    return False, (f"Stack did not become ready within {ready_timeout}s. Inspect with:\n"
                   f"    cd {install_dir} && docker compose logs --tail 50"), 1


def main():
    ap = argparse.ArgumentParser(description="Ensure the local-search Docker stack is running.")
    ap.add_argument("--check", action="store_true",
                    help="only report status; never start anything")
    args = ap.parse_args()

    ok, message, code = ensure_ready(check_only=args.check)
    if ok:
        print(message)
        return 0
    print(message, file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_ENSURE_STACK_PY
fi

# --- local-web-search/scripts/web_search.py ---
if [ -f "$SRC/local-web-search/scripts/web_search.py" ]; then
  cp "$SRC/local-web-search/scripts/web_search.py" "$TARGET/local-web-search/scripts/web_search.py"
else
  say "  [embedded] local-web-search/scripts/web_search.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_search.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SEARCH_PY'
#!/usr/bin/env python3
"""Search the web via the local SearXNG instance and print compact results.

Usage:
    python web_search.py "your query" [--limit 8] [--time-range day|week|month]
                                  [--categories it,news,general]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the search once. You do NOT need
to run ensure_stack.py first — just run the search.

Prints up to `limit` results, each as:
    N. <title>
       <url>
       <snippet>
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so search results with non-ASCII text never crash
# with a UnicodeEncodeError. Skipped if PYTHONIOENCODING is already set —
# an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Port comes from SEARXNG_PORT in the install folder's .env (default 9990).
BASE = config.endpoints(config.find_install_dir())["searxng"] + "/search"

TIMEOUT = 30  # seconds per HTTP attempt


def fetch(url):
    """GET the SearXNG JSON API. Raises HTTPError when the service answered
    with an error status (service is UP), URLError-family on connection
    problems (service is DOWN)."""
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def selfheal():
    """Start the Docker engine + the containers if they are down (the same
    logic as ensure_stack.py). Import is deferred so the fast path (stack
    already up) pays nothing. Returns (ok, message)."""
    try:
        import ensure_stack
        ok, message, _code = ensure_stack.ensure_ready()
        return ok, message
    except Exception as e:  # unexpected self-heal failure: degrade gracefully
        return False, "self-heal failed unexpectedly: {}".format(e)


def main() -> int:
    args = sys.argv[1:]
    limit, time_range, categories = 8, None, None
    query_parts = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--limit":
            i += 1
            limit = int(args[i])
        elif a == "--time-range":
            i += 1
            time_range = args[i]
        elif a == "--categories":
            i += 1
            categories = args[i]
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            query_parts.append(a)
        i += 1
    query = " ".join(query_parts).strip()
    if not query:
        print('usage: web_search.py "query" [--limit N] [--time-range R] [--categories C]', file=sys.stderr)
        return 2

    params = {"q": query, "format": "json", "language": "en"}
    if time_range:
        params["time_range"] = time_range
    if categories:
        params["categories"] = categories
    url = BASE + "?" + urllib.parse.urlencode(params)

    data = None
    try:
        data = fetch(url)
    except urllib.error.HTTPError as e:
        # The service ANSWERED (even with an error status) -> it is up;
        # starting containers would not help.
        print(f"SEARCH FAILED: {e}", file=sys.stderr)
        print("SearXNG answered with an error status (the stack is running). "
              "Retry once with a different query, or inspect the stack with: "
              "cd <install folder> && docker compose logs --tail 50 searxng",
              file=sys.stderr)
        return 1
    except Exception as e:
        # Connection error: the stack is (probably) down -> self-heal once,
        # then retry the search.
        print(f"Stack unreachable ({e}) — starting it automatically ...",
              file=sys.stderr)
        ok, message = selfheal()
        if not ok:
            print(message, file=sys.stderr)
            print("SEARCH FAILED: the local-search stack could not be started. "
                  "Resolve the stack (or ask the user to start Docker Desktop) "
                  "and retry — do NOT fall back to other web tools unless the "
                  "user asks.", file=sys.stderr)
            return 1
        try:
            data = fetch(url)
        except Exception as e2:
            print(f"SEARCH FAILED after the stack was started: {e2}", file=sys.stderr)
            return 1

    results = data.get("results", [])[:limit]
    if not results:
        print("(no results)")
        return 0
    for n, hit in enumerate(results, 1):
        title = (hit.get("title") or "").strip()
        result_url = hit.get("url") or ""
        content = (hit.get("content") or "").strip().replace("\n", " ")
        if len(content) > 300:
            content = content[:300] + "…"
        print(f"{n}. {title}")
        print(f"   {result_url}")
        if content:
            print(f"   {content}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SEARCH_PY
fi

# --- local-web-search/scripts/web_scrape.py ---
if [ -f "$SRC/local-web-search/scripts/web_scrape.py" ]; then
  cp "$SRC/local-web-search/scripts/web_scrape.py" "$TARGET/local-web-search/scripts/web_scrape.py"
else
  say "  [embedded] local-web-search/scripts/web_scrape.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_scrape.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SCRAPE_PY'
#!/usr/bin/env python3
"""Read a web page as clean Markdown via the local Firecrawl instance.

Usage:
    python web_scrape.py <url> [--max-chars 20000]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the scrape once. You do NOT need
to run ensure_stack.py first — just run the scrape.

Prints the page's Markdown to stdout, truncated at --max-chars.
"""
import json
import os
import sys
import urllib.error
import urllib.request

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so scraped page content with non-ASCII text never
# crashes with a UnicodeEncodeError. Skipped if PYTHONIOENCODING is already
# set — an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Port comes from FIRECRAWL_PORT in the install folder's .env (default 9991).
ENDPOINT = config.endpoints(config.find_install_dir())["firecrawl"] + "/v1/scrape"

TIMEOUT = 90  # seconds per HTTP attempt


def fetch(url):
    """POST the scrape request. Raises HTTPError when the service answered
    with an error status (service is UP), URLError-family on connection
    problems (service is DOWN)."""
    body = json.dumps({"url": url, "formats": ["markdown"]}).encode()
    req = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def selfheal():
    """Start the Docker engine + the containers if they are down (the same
    logic as ensure_stack.py). Import is deferred so the fast path (stack
    already up) pays nothing. Returns (ok, message)."""
    try:
        import ensure_stack
        ok, message, _code = ensure_stack.ensure_ready()
        return ok, message
    except Exception as e:  # unexpected self-heal failure: degrade gracefully
        return False, "self-heal failed unexpectedly: {}".format(e)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_scrape.py <url> [--max-chars N]", file=sys.stderr)
        return 2
    url = args[0]
    max_chars = 20000
    i = 1
    while i < len(args):
        if args[i] == "--max-chars" and i + 1 < len(args):
            max_chars = int(args[i + 1])
            i += 2
        else:
            i += 1

    data = None
    try:
        data = fetch(url)
    except urllib.error.HTTPError as e:
        # The service ANSWERED (even with an error status) -> it is up;
        # starting containers would not help.
        print(f"SCRAPE FAILED for {url}: {e}", file=sys.stderr)
        print("Firecrawl answered with an error status (the stack is running). "
              "Retry once with a different result URL, or inspect the stack "
              "with: cd <install folder> && docker compose logs --tail 50 "
              "firecrawl", file=sys.stderr)
        return 1
    except Exception as e:
        # Connection error: the stack is (probably) down -> self-heal once,
        # then retry the scrape.
        print(f"Stack unreachable ({e}) — starting it automatically ...",
              file=sys.stderr)
        ok, message = selfheal()
        if not ok:
            print(message, file=sys.stderr)
            print("SCRAPE FAILED for {}: the local-search stack could not be "
                  "started. Resolve the stack (or ask the user to start Docker "
                  "Desktop) and retry — do NOT fall back to other web tools "
                  "unless the user asks.".format(url), file=sys.stderr)
            return 1
        try:
            data = fetch(url)
        except Exception as e2:
            print(f"SCRAPE FAILED for {url} after the stack was started: {e2}",
                  file=sys.stderr)
            return 1

    payload = data.get("data") or {}
    markdown = payload.get("markdown") or "" if isinstance(payload, dict) else ""
    if not markdown:
        print("SCRAPE RETURNED NO MARKDOWN for", url, file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1

    if len(markdown) > max_chars:
        markdown = markdown[:max_chars] + f"\n\n[... truncated at {max_chars} chars ...]"
    print(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SCRAPE_PY
fi

# --- install-local-search.bat ---
if [ -f "$SRC/install-local-search.bat" ]; then
  cp "$SRC/install-local-search.bat" "$TARGET/install-local-search.bat"
else
  say "  [embedded] install-local-search.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/install-local-search.bat" <<'EOF_INSTALL_LOCAL_SEARCH_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Installer

REM ===========================================================================
REM  Local Search Installer  (Firecrawl + SearXNG + local-web-search skill)  -  Windows
REM ===========================================================================
REM  Self-contained: every file the installer needs is embedded below as
REM  base64. If a source file is missing from this script's folder (e.g. you
REM  only downloaded this one .bat), the embedded copy is used instead.
REM  After installing the stack it also copies the bundled local-web-search agent
REM  skill into %USERPROFILE%\.agents\skills\local-web-search.
REM  If the Docker engine is not running, the installer launches Docker
REM  Desktop automatically and waits for it before pulling images.
REM ===========================================================================

echo ============================================================
echo   Local Search Installer  (Firecrawl + SearXNG + local-web-search)
echo   A local web-browsing system for AI models.
echo ============================================================
echo.

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker was not found on your PATH.
  echo   Install Docker Desktop: https://www.docker.com/products/docker-desktop/
  echo   Then re-run this installer.
  pause & exit /b 1
)
docker info >nul 2>&1
if not errorlevel 1 goto docker_ok
echo [NOTE] The Docker engine is not running - trying to start Docker Desktop...
set "DD_EXE="
if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" set "DD_EXE=%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
if not defined DD_EXE if exist "%ProgramFiles(x86)%\Docker\Docker\Docker Desktop.exe" set "DD_EXE=%ProgramFiles(x86)%\Docker\Docker\Docker Desktop.exe"
if not defined DD_EXE if exist "%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe" set "DD_EXE=%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe"
if not defined DD_EXE (
  echo [ERROR] Docker Desktop was not found in the usual install locations.
  echo   Start it manually, wait until it says "running", then re-run
  echo   this installer.
  pause & exit /b 1
)
echo     Launching: "!DD_EXE!"
start "" "!DD_EXE!"
set "DD_LAUNCHED=1"
echo     Docker Desktop is starting in the background. Answer the next
echo     questions while it boots - the installer waits for the engine
echo     before pulling images.
:docker_ok
if not defined DD_LAUNCHED echo [OK] Docker is running.
echo.

set "SRC=%~dp0"
if "!SRC:~-1!"=="\" set "SRC=!SRC:~0,-1!"

set "DEFAULT_TARGET=%USERPROFILE%\local-search"

echo --- Step 1 of 4: Install location --------------------------
echo   Default: %DEFAULT_TARGET%
set "TARGET="
set /p TARGET="  Target folder [press Enter for default]: "
if "!TARGET!"=="" set "TARGET=%DEFAULT_TARGET%"
set "TARGET=!TARGET:"=!"
for %%I in ("!TARGET!") do set "TARGET=%%~fI"
echo   Using: !TARGET!
echo.

:ask_searxng
echo --- Step 2 of 4: SearXNG port (default 9990) --------------
set "SEARXNG_PORT="
set /p SEARXNG_PORT="  Port for SearXNG [press Enter for 9990]: "
if "!SEARXNG_PORT!"=="" set "SEARXNG_PORT=9990"
call :validate_port "!SEARXNG_PORT!"
if !errorlevel! neq 0 ( echo   [WARNING] "!SEARXNG_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_searxng )

:ask_firecrawl
echo --- Step 3 of 4: Firecrawl port (default 9991) ------------
set "FIRECRAWL_PORT="
set /p FIRECRAWL_PORT="  Port for Firecrawl [press Enter for 9991]: "
if "!FIRECRAWL_PORT!"=="" set "FIRECRAWL_PORT=9991"
call :validate_port "!FIRECRAWL_PORT!"
if !errorlevel! neq 0 ( echo   [WARNING] "!FIRECRAWL_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_firecrawl )
if /i "!FIRECRAWL_PORT!"=="!SEARXNG_PORT!" ( echo   [WARNING] Firecrawl port must differ from SearXNG port. & echo. & goto ask_firecrawl )

echo.
echo --- Step 4 of 4: Local LLM (optional) ---------------------
echo   Lets Firecrawl do AI extraction (/v1/extract) and summaries.
echo   Recommended: LM Studio  -^>  http://localhost:1234/v1
set "USE_LLM="
set /p USE_LLM="  Connect a local LLM now? [y/N]: "
set "OPENAI_BASE_URL="
set "OPENAI_API_KEY="
set "MODEL_NAME="
if /i "!USE_LLM!"=="y" (
  set "LLM_URL="
  set /p LLM_URL="    LM Studio server URL as shown in LM Studio [Enter = http://localhost:1234/v1]: "
  if "!LLM_URL!"=="" set "LLM_URL=http://localhost:1234/v1"
  set "LLM_MODEL="
  set /p LLM_MODEL="    Model name loaded in LM Studio [Enter to skip]: "
  set "OPENAI_BASE_URL=!LLM_URL!"
  set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://localhost=http://host.docker.internal!"
  set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://127.0.0.1=http://host.docker.internal!"
  set "OPENAI_API_KEY=lm-studio"
  if not "!LLM_MODEL!"=="" set "MODEL_NAME=!LLM_MODEL!"
  echo     ^(Container will reach it at: !OPENAI_BASE_URL!^)
  echo     ^(Make sure LM Studio has "Serve on local network" enabled.^)
)

echo.
echo ============================================================
echo   Summary
echo   Folder:         !TARGET!
echo   SearXNG port:   !SEARXNG_PORT!
echo   Firecrawl port: !FIRECRAWL_PORT!
echo   Agent skill:    %USERPROFILE%\.agents\skills\local-web-search
if defined OPENAI_BASE_URL (
  echo   LLM endpoint:   !OPENAI_BASE_URL!  !MODEL_NAME!
) else (
  echo   LLM endpoint:   ^(none - enable later by editing .env^)
)
echo ============================================================
set "CONFIRM="
set /p CONFIRM="Proceed with install? [Y/n]: "
if /i "!CONFIRM!"=="n" ( echo Install cancelled. & pause & exit /b 0 )

if not exist "!TARGET!" mkdir "!TARGET!"
if not exist "!TARGET!\config\searxng" mkdir "!TARGET!\config\searxng"
if not exist "!TARGET!\local-web-search\scripts" mkdir "!TARGET!\local-web-search\scripts"

if exist "!TARGET!\.env" (
  for /f "usebackq delims=" %%t in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMddHHmmss"`) do set "LDT=%%t"
  copy /Y "!TARGET!\.env" "!TARGET!\.env.bak.!LDT!" >nul
  echo   Backed up existing .env to .env.bak.!LDT!
)

echo Copying files...

REM --- config/searxng/settings.yml ---
set "NEED_B64=1"
if exist "!SRC!\config\searxng\settings.yml" (
  copy /Y "!SRC!\config\searxng\settings.yml" "!TARGET!\config\searxng\settings.yml" >nul 2>&1
  if exist "!TARGET!\config\searxng\settings.yml" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] config/searxng/settings.yml  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3594602951.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBTZWFyWE5HIHNldHRpbmdzIGZvciBsb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2gKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PQojICBQcmUtY29uZmlndXJlZCBmb3IgQUkgLyBsb2Nh
  >> "!B64TMP!" echo bC1tb2RlbCB1c2U6CiMgICAgKiBzZWFyY2guZm9ybWF0cyBpbmNsdWRlcyAianNvbiIgIC0+IGxl
  >> "!B64TMP!" echo dHMgbW9kZWxzIHF1ZXJ5IHRoZSBKU09OIEFQSQojICAgICogc2VydmVyLmxpbWl0ZXI6IGZhbHNl
  >> "!B64TMP!" echo ICAgICAgICAgICAtPiBubyByYXRlLWxpbWl0aW5nIG9uIEFQSSBjYWxscwojICAgICogc2VydmVy
  >> "!B64TMP!" echo LnB1YmxpY19pbnN0YW5jZTogZmFsc2UgICAtPiBwcml2YXRlIGluc3RhbmNlIGRlZmF1bHRzCiMg
  >> "!B64TMP!" echo ICAgKiBzZWNyZXRfa2V5IHBsYWNlaG9sZGVyICAgICAgICAgIC0+IGluc3RhbGxlciByZXBsYWNl
  >> "!B64TMP!" echo cyB3aXRoIGEgcmFuZG9tIGtleQojCiMgICJ1c2VfZGVmYXVsdF9zZXR0aW5nczogdHJ1ZSIgaW5o
  >> "!B64TMP!" echo ZXJpdHMgYWxsIHVwc3RyZWFtIGRlZmF1bHRzIChlbmdpbmVzLAojICBwbHVnaW5zLCBldGMuKSBz
  >> "!B64TMP!" echo byBvbmx5IHRoZSBvdmVycmlkZXMgYmVsb3cgdGFrZSBlZmZlY3QuCiMgPT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT0KCnVzZV9kZWZhdWx0X3NldHRpbmdzOiB0cnVlCgpnZW5lcmFsOgogIGRlYnVnOiBmYWxz
  >> "!B64TMP!" echo ZQogIGluc3RhbmNlX25hbWU6ICJMb2NhbCBTZWFyY2giCiAgcHJpdmFjeXBvbGljeV91cmw6IGZh
  >> "!B64TMP!" echo bHNlCiAgY29udGFjdF9saW5rOiBmYWxzZQoKc2VhcmNoOgogIHNhZmVfc2VhcmNoOiAwCiAgYXV0
  >> "!B64TMP!" echo b2NvbXBsZXRlOiAiIgogIGRlZmF1bHRfbGFuZzogImVuIgogIGZvcm1hdHM6CiAgICAtIGh0bWwK
  >> "!B64TMP!" echo ICAgIC0ganNvbgoKc2VydmVyOgogIHNlY3JldF9rZXk6ICIzMjY0NWZiMzBjNmQ0Y2JlMjE3YzY3
  >> "!B64TMP!" echo OTU2ZDNkYjAwZDM3N2I0ZmRlZDE4NDU1NDk3YjA3M2IzYjBkYzQyNTNjIgogIGJpbmRfYWRkcmVz
  >> "!B64TMP!" echo czogIjAuMC4wLjAiCiAgcG9ydDogODA4MAogIGltYWdlX3Byb3h5OiB0cnVlCiAgbGltaXRlcjog
  >> "!B64TMP!" echo ZmFsc2UKICBwdWJsaWNfaW5zdGFuY2U6IGZhbHNlCgp1aToKICBzdGF0aWNfdXNlX2hhc2g6IHRy
  >> "!B64TMP!" echo dWUKCm91dGdvaW5nOgogIHJlcXVlc3RfdGltZW91dDogMTAuMAogIG1heF9yZXF1ZXN0X3RpbWVv
  >> "!B64TMP!" echo dXQ6IDE1LjAK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\config\searxng\settings.yml"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- docker-compose.yml ---
set "NEED_B64=1"
if exist "!SRC!\docker-compose.yml" (
  copy /Y "!SRC!\docker-compose.yml" "!TARGET!\docker-compose.yml" >nul 2>&1
  if exist "!TARGET!\docker-compose.yml" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] docker-compose.yml  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS548588679.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBMb2NhbCBTZWFyY2gg4oCUIEZpcmVjcmF3bCArIFNl
  >> "!B64TMP!" echo YXJYTkcgKGxvY2FsIHdlYi1icm93c2luZyBzeXN0ZW0gZm9yIEFJIG1vZGVscykKIyA9PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PQojICBUaGlzIENvbXBvc2UgZmlsZSBpcyBjb25zdW1lZCBieSB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbGVycyAoaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IC8KIyAgaW5zdGFsbC1sb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2guc2gpLiBUaGUgaG9zdCBwb3J0cyBhbmQgY3JlZGVudGlhbHMgYXJlIGluamVjdGVkIGZyb20K
  >> "!B64TMP!" echo IyAgdGhlIGdlbmVyYXRlZCAuZW52IGZpbGUgKGNyZWF0ZWQgYXQgaW5zdGFsbCB0aW1lKS4KIwoj
  >> "!B64TMP!" echo ICBTZXJ2aWNlczoKIyAgICBzZWFyeG5nICAgICAgICAgIG1ldGFzZWFyY2ggKyBKU09OIEFQSSAg
  >> "!B64TMP!" echo ICAgICAgLT4gaG9zdCAke1NFQVJYTkdfUE9SVH0KIyAgICBmaXJlY3Jhd2wgICAgICAgIHNjcmFw
  >> "!B64TMP!" echo ZS9jcmF3bC9zZWFyY2gvbWFwIEFQSSAgLT4gaG9zdCAke0ZJUkVDUkFXTF9QT1JUfQojICAgIHBs
  >> "!B64TMP!" echo YXl3cmlnaHQtc2VydmljZSAgSlMgcmVuZGVyaW5nIGZvciBGaXJlY3Jhd2wKIyAgICByZWRpcyAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIHF1ZXVlIGZvciBGaXJlY3Jhd2wKIyAgICByYWJiaXRtcSAgICAgICAgICAg
  >> "!B64TMP!" echo IG1lc3NhZ2UgYnJva2VyIGZvciBGaXJlY3Jhd2wKIyAgICBudXEtcG9zdGdyZXMgICAgICAgIGpv
  >> "!B64TMP!" echo YiBzdGF0ZSBEQiBmb3IgRmlyZWNyYXdsCiMKIyAgT25seSB0aGUgdHdvIGhvc3QgcG9ydHMgYmVs
  >> "!B64TMP!" echo b3cgYXJlIHB1Ymxpc2hlZC4gRXZlcnl0aGluZyBlbHNlIHN0YXlzIG9uIHRoZQojICBwcml2YXRl
  >> "!B64TMP!" echo ICJsb2NhbC1zZWFyY2gtbmV0IiBicmlkZ2UgbmV0d29yay4KIyA9PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PQoKbmFtZTogbG9jYWwtc2VhcmNoCgpzZXJ2aWNlczoKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQog
  >> "!B64TMP!" echo ICMgU2VhclhORyDigJQgcHJpdmFjeS1yZXNwZWN0aW5nIG1ldGFzZWFyY2ggZW5naW5lLCBleHBv
  >> "!B64TMP!" echo c2VkIGFzIGEgSlNPTiBBUEkuCiAgIyBQb3dlcnMgYm90aCB5b3VyIEFJIG1vZGVscyAoZGlyZWN0
  >> "!B64TMP!" echo IEpTT04gcXVlcmllcykgYW5kIEZpcmVjcmF3bCdzIC92MS9zZWFyY2guCiAgIyAtLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLQogIHNlYXJ4bmc6CiAgICBpbWFnZTogc2VhcnhuZy9zZWFyeG5nOmxhdGVzdAogICAg
  >> "!B64TMP!" echo Y29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1zZWFyeG5nCiAgICBwb3J0czoKICAgICAgLSAi
  >> "!B64TMP!" echo JHtTRUFSWE5HX1BPUlQ6LTk5OTB9OjgwODAiCiAgICB2b2x1bWVzOgogICAgICAtIC4vY29uZmln
  >> "!B64TMP!" echo L3NlYXJ4bmc6L2V0Yy9zZWFyeG5nOnJ3CiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBTRUFSWE5H
  >> "!B64TMP!" echo X0JBU0VfVVJMPWh0dHA6Ly9sb2NhbGhvc3Q6JHtTRUFSWE5HX1BPUlQ6LTk5OTB9LwogICAgICAt
  >> "!B64TMP!" echo IFVXU0dJX1dPUktFUlM9NAogICAgICAtIFVXU0dJX1RIUkVBRFM9NAogICAgICAtIFNFQVJYTkdf
  >> "!B64TMP!" echo U0VDUkVUPSR7U0VBUlhOR19TRUNSRVR9CiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAg
  >> "!B64TMP!" echo Y2FwX2Ryb3A6CiAgICAgIC0gQUxMCiAgICBjYXBfYWRkOgogICAgICAtIENIT1dOCiAgICAgIC0g
  >> "!B64TMP!" echo U0VUR0lECiAgICAgIC0gU0VUVUlECiAgICBuZXR3b3JrczoKICAgICAgLSBsb2NhbC1zZWFyY2gt
  >> "!B64TMP!" echo bmV0CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIEZpcmVjcmF3bCBBUEkgc2VydmVyICh0aGUg
  >> "!B64TMP!" echo cHVibGljLWZhY2luZyBzY3JhcGluZy9jcmF3bC9zZWFyY2ggc2VydmljZSkuCiAgIyAtLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLQogIGZpcmVjcmF3bDoKICAgIGltYWdlOiBnaGNyLmlvL2ZpcmVjcmF3bC9maXJl
  >> "!B64TMP!" echo Y3Jhd2w6bGF0ZXN0CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLWZpcmVjcmF3bAog
  >> "!B64TMP!" echo ICAgcG9ydHM6CiAgICAgIC0gIiR7RklSRUNSQVdMX1BPUlQ6LTk5OTF9OjMwMDIiCiAgICBlbnZp
  >> "!B64TMP!" echo cm9ubWVudDoKICAgICAgLSBQT1JUPTMwMDIKICAgICAgLSBIT1NUPTAuMC4wLjAKICAgICAgLSBF
  >> "!B64TMP!" echo TlY9bG9jYWwKICAgICAgLSBSRURJU19VUkw9cmVkaXM6Ly9yZWRpczo2Mzc5CiAgICAgIC0gUkVE
  >> "!B64TMP!" echo SVNfUkFURV9MSU1JVF9VUkw9cmVkaXM6Ly9yZWRpczo2Mzc5CiAgICAgIC0gUExBWVdSSUdIVF9N
  >> "!B64TMP!" echo SUNST1NFUlZJQ0VfVVJMPWh0dHA6Ly9wbGF5d3JpZ2h0LXNlcnZpY2U6MzAwMC9zY3JhcGUKICAg
  >> "!B64TMP!" echo ICAgLSBVU0VfREJfQVVUSEVOVElDQVRJT049ZmFsc2UKICAgICAgLSBCVUxMX0FVVEhfS0VZPSR7
  >> "!B64TMP!" echo QlVMTF9BVVRIX0tFWX0KICAgICAgLSBMT0dHSU5HX0xFVkVMPSR7TE9HR0lOR19MRVZFTDotaW5m
  >> "!B64TMP!" echo b30KICAgICAgLSBCTE9DS19NRURJQT1mYWxzZQogICAgICAtIEFMTE9XX0xPQ0FMX1dFQkhPT0tT
  >> "!B64TMP!" echo PWZhbHNlCiAgICAgIC0gU0VBUlhOR19FTkRQT0lOVD1odHRwOi8vc2VhcnhuZzo4MDgwCiAgICAg
  >> "!B64TMP!" echo IC0gUE9TVEdSRVNfSE9TVD1udXEtcG9zdGdyZXMKICAgICAgLSBQT1NUR1JFU19QT1JUPTU0MzIK
  >> "!B64TMP!" echo ICAgICAgLSBQT1NUR1JFU19EQj0ke1BPU1RHUkVTX0RCOi1maXJlY3Jhd2x9CiAgICAgIC0gUE9T
  >> "!B64TMP!" echo VEdSRVNfVVNFUj0ke1BPU1RHUkVTX1VTRVI6LWZpcmVjcmF3bH0KICAgICAgLSBQT1NUR1JFU19Q
  >> "!B64TMP!" echo QVNTV09SRD0ke1BPU1RHUkVTX1BBU1NXT1JEfQogICAgICAtIE5VUV9SQUJCSVRNUV9VUkw9YW1x
  >> "!B64TMP!" echo cDovLyR7UkFCQklUTVFfVVNFUjotZmlyZWNyYXdsfToke1JBQkJJVE1RX1BBU1NXT1JEfUByYWJi
  >> "!B64TMP!" echo aXRtcTo1NjcyCiAgICAgICMgLS0tLSBPcHRpb25hbCBBSSBmZWF0dXJlcyAoc2V0IGluIC5lbnYg
  >> "!B64TMP!" echo dG8gZW5hYmxlIC92MS9leHRyYWN0ICsgc3VtbWFyeSkgLS0tLQogICAgICAtIE9QRU5BSV9BUElf
  >> "!B64TMP!" echo S0VZPSR7T1BFTkFJX0FQSV9LRVk6LX0KICAgICAgLSBPUEVOQUlfQkFTRV9VUkw9JHtPUEVOQUlf
  >> "!B64TMP!" echo QkFTRV9VUkw6LX0KICAgICAgLSBPTExBTUFfQkFTRV9VUkw9JHtPTExBTUFfQkFTRV9VUkw6LX0K
  >> "!B64TMP!" echo ICAgICAgLSBNT0RFTF9OQU1FPSR7TU9ERUxfTkFNRTotfQogICAgICAtIE1PREVMX0VNQkVERElO
  >> "!B64TMP!" echo R19OQU1FPSR7TU9ERUxfRU1CRURESU5HX05BTUU6LX0KICAgIGNvbW1hbmQ6IFsibm9kZSIsICJk
  >> "!B64TMP!" echo aXN0L3NyYy9oYXJuZXNzLmpzIiwgIi0tc3RhcnQtZG9ja2VyIl0KICAgIHVsaW1pdHM6CiAgICAg
  >> "!B64TMP!" echo IG5vZmlsZToKICAgICAgICBzb2Z0OiA2NTUzNQogICAgICAgIGhhcmQ6IDY1NTM1CiAgICBleHRy
  >> "!B64TMP!" echo YV9ob3N0czoKICAgICAgLSAiaG9zdC5kb2NrZXIuaW50ZXJuYWw6aG9zdC1nYXRld2F5IgogICAg
  >> "!B64TMP!" echo bG9nZ2luZzoKICAgICAgZHJpdmVyOiAianNvbi1maWxlIgogICAgICBvcHRpb25zOgogICAgICAg
  >> "!B64TMP!" echo IG1heC1zaXplOiAiMTBtIgogICAgICAgIG1heC1maWxlOiAiMyIKICAgICAgICBjb21wcmVzczog
  >> "!B64TMP!" echo InRydWUiCiAgICBkZXBlbmRzX29uOgogICAgICByZWRpczoKICAgICAgICBjb25kaXRpb246IHNl
  >> "!B64TMP!" echo cnZpY2Vfc3RhcnRlZAogICAgICBwbGF5d3JpZ2h0LXNlcnZpY2U6CiAgICAgICAgY29uZGl0aW9u
  >> "!B64TMP!" echo OiBzZXJ2aWNlX3N0YXJ0ZWQKICAgICAgc2VhcnhuZzoKICAgICAgICBjb25kaXRpb246IHNlcnZp
  >> "!B64TMP!" echo Y2Vfc3RhcnRlZAogICAgICBudXEtcG9zdGdyZXM6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNl
  >> "!B64TMP!" echo X2hlYWx0aHkKICAgICAgcmFiYml0bXE6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNlX2hlYWx0
  >> "!B64TMP!" echo aHkKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBuZXR3b3JrczoKICAgICAgLSBsb2Nh
  >> "!B64TMP!" echo bC1zZWFyY2gtbmV0CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIFBsYXl3cmlnaHQgaGVhZGxl
  >> "!B64TMP!" echo c3MgYnJvd3NlciBzZXJ2aWNlIOKAlCBkb2VzIHRoZSBhY3R1YWwgSlMtcmVuZGVyZWQgZmV0Y2hp
  >> "!B64TMP!" echo bmcuCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIHBsYXl3cmlnaHQtc2VydmljZToKICAgIGltYWdl
  >> "!B64TMP!" echo OiBnaGNyLmlvL2ZpcmVjcmF3bC9wbGF5d3JpZ2h0LXNlcnZpY2U6bGF0ZXN0CiAgICBjb250YWlu
  >> "!B64TMP!" echo ZXJfbmFtZTogbG9jYWwtc2VhcmNoLXBsYXl3cmlnaHQKICAgIGVudmlyb25tZW50OgogICAgICAt
  >> "!B64TMP!" echo IFBPUlQ9MzAwMAogICAgICAtIEJMT0NLX01FRElBPWZhbHNlCiAgICAgIC0gQUxMT1dfTE9DQUxf
  >> "!B64TMP!" echo V0VCSE9PS1M9ZmFsc2UKICAgICAgLSBNQVhfQ09OQ1VSUkVOVF9QQUdFUz0xMAogICAgcmVzdGFy
  >> "!B64TMP!" echo dDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQK
  >> "!B64TMP!" echo CiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgUmVkaXMg4oCUIEZpcmVjcmF3bCBxdWV1ZSAvIHJh
  >> "!B64TMP!" echo dGUtbGltaXRpbmcgc3RvcmUuCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIHJlZGlzOgogICAgaW1h
  >> "!B64TMP!" echo Z2U6IHJlZGlzOmFscGluZQogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1yZWRpcwog
  >> "!B64TMP!" echo ICAgdm9sdW1lczoKICAgICAgLSByZWRpcy1kYXRhOi9kYXRhCiAgICByZXN0YXJ0OiB1bmxlc3Mt
  >> "!B64TMP!" echo c3RvcHBlZAogICAgbmV0d29ya3M6CiAgICAgIC0gbG9jYWwtc2VhcmNoLW5ldAoKICAjIC0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tCiAgIyBSYWJiaXRNUSDigJQgbWVzc2FnZSBicm9rZXIgdXNlZCBieSBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wncyBqb2Igd29ya2Vycy4KICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgcmFiYml0bXE6CiAg
  >> "!B64TMP!" echo ICBpbWFnZTogcmFiYml0bXE6My1tYW5hZ2VtZW50CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoLXJhYmJpdG1xCiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBSQUJCSVRNUV9ERUZBVUxU
  >> "!B64TMP!" echo X1VTRVI9JHtSQUJCSVRNUV9VU0VSOi1maXJlY3Jhd2x9CiAgICAgIC0gUkFCQklUTVFfREVGQVVM
  >> "!B64TMP!" echo VF9QQVNTPSR7UkFCQklUTVFfUEFTU1dPUkR9CiAgICB2b2x1bWVzOgogICAgICAtIHJhYmJpdG1x
  >> "!B64TMP!" echo LWRhdGE6L3Zhci9saWIvcmFiYml0bXEKICAgIGhlYWx0aGNoZWNrOgogICAgICB0ZXN0OiBbIkNN
  >> "!B64TMP!" echo RCIsICJyYWJiaXRtcS1kaWFnbm9zdGljcyIsICJwaW5nIl0KICAgICAgaW50ZXJ2YWw6IDVzCiAg
  >> "!B64TMP!" echo ICAgIHRpbWVvdXQ6IDEwcwogICAgICByZXRyaWVzOiAxMAogICAgICBzdGFydF9wZXJpb2Q6IDMw
  >> "!B64TMP!" echo cwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC1uZXQKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgbnVxLXBvc3RncmVzIOKAlCBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgam9iLXN0YXRlIGRhdGFiYXNlIChwZ19jcm9uIGVuYWJsZWQgaW1hZ2UpLgogICMg
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0KICBudXEtcG9zdGdyZXM6CiAgICBpbWFnZTogZ2hjci5pby9maXJl
  >> "!B64TMP!" echo Y3Jhd2wvbnVxLXBvc3RncmVzOmxhdGVzdAogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aC1wb3N0Z3JlcwogICAgY29tbWFuZDogcG9zdGdyZXMgLWMgY3Jvbi5kYXRhYmFzZV9uYW1lPSR7
  >> "!B64TMP!" echo UE9TVEdSRVNfREI6LWZpcmVjcmF3bH0KICAgIGVudmlyb25tZW50OgogICAgICAtIFBPU1RHUkVT
  >> "!B64TMP!" echo X0RCPSR7UE9TVEdSRVNfREI6LWZpcmVjcmF3bH0KICAgICAgLSBQT1NUR1JFU19VU0VSPSR7UE9T
  >> "!B64TMP!" echo VEdSRVNfVVNFUjotZmlyZWNyYXdsfQogICAgICAtIFBPU1RHUkVTX1BBU1NXT1JEPSR7UE9TVEdS
  >> "!B64TMP!" echo RVNfUEFTU1dPUkR9CiAgICB2b2x1bWVzOgogICAgICAtIHBvc3RncmVzLWRhdGE6L3Zhci9saWIv
  >> "!B64TMP!" echo cG9zdGdyZXNxbC9kYXRhCiAgICBoZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQtU0hFTEwi
  >> "!B64TMP!" echo LCAicGdfaXNyZWFkeSAtVSAke1BPU1RHUkVTX1VTRVI6LWZpcmVjcmF3bH0gLWQgJHtQT1NUR1JF
  >> "!B64TMP!" echo U19EQjotZmlyZWNyYXdsfSJdCiAgICAgIGludGVydmFsOiA1cwogICAgICB0aW1lb3V0OiA1cwog
  >> "!B64TMP!" echo ICAgICByZXRyaWVzOiAxMAogICAgICBzdGFydF9wZXJpb2Q6IDMwcwogICAgcmVzdGFydDogdW5s
  >> "!B64TMP!" echo ZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCm5ldHdv
  >> "!B64TMP!" echo cmtzOgogIGxvY2FsLXNlYXJjaC1uZXQ6CiAgICBkcml2ZXI6IGJyaWRnZQoKdm9sdW1lczoKICBy
  >> "!B64TMP!" echo ZWRpcy1kYXRhOgogIHBvc3RncmVzLWRhdGE6CiAgcmFiYml0bXEtZGF0YToK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\docker-compose.yml"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .env.example ---
set "NEED_B64=1"
if exist "!SRC!\.env.example" (
  copy /Y "!SRC!\.env.example" "!TARGET!\.env.example" >nul 2>&1
  if exist "!TARGET!\.env.example" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .env.example  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4173156074.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBMb2NhbCBTZWFyY2gg4oCUIGV4YW1wbGUgZW52aXJv
  >> "!B64TMP!" echo bm1lbnQgZmlsZQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIFRoZSBpbnN0YWxsZXIgKGluc3Rh
  >> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLmJhdCAvIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoKSBnZW5lcmF0ZXMK
  >> "!B64TMP!" echo IyAgYSBSRUFMIC5lbnYgZmlsZSBhdCBpbnN0YWxsIHRpbWUgd2l0aDoKIyAgICAqIHRoZSBob3N0
  >> "!B64TMP!" echo IHBvcnRzIHlvdSBjaG9zZQojICAgICogY3J5cHRvZ3JhcGhpY2FsbHktcmFuZG9tIHBhc3N3b3Jk
  >> "!B64TMP!" echo cy9rZXlzIChkbyBOT1QgdXNlIHRoZSB2YWx1ZXMgYmVsb3cKIyAgICAgIGluIHByb2R1Y3Rpb24g
  >> "!B64TMP!" echo 4oCUIHRoZXkgYXJlIHBsYWNlaG9sZGVycyBvbmx5KQojCiMgIFRoaXMgZmlsZSBpcyBkb2N1bWVu
  >> "!B64TMP!" echo dGF0aW9uLiBUbyBjaGFuZ2Ugc2V0dGluZ3MgYWZ0ZXIgaW5zdGFsbCwgZWRpdCB0aGUgLmVudgoj
  >> "!B64TMP!" echo ICBpbiB5b3VyIGluc3RhbGwgZm9sZGVyLCB0aGVuIHJ1biBVcGRhdGUuYmF0IC8gdXBkYXRlLnNo
  >> "!B64TMP!" echo IChvciByZXN0YXJ0KS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKIyAtLS0tIEhvc3QgcG9ydHMg
  >> "!B64TMP!" echo KHdoYXQgeW91IGNvbm5lY3QgdG8gZnJvbSB5b3VyIG1hY2hpbmUpIC0tLS0KU0VBUlhOR19QT1JU
  >> "!B64TMP!" echo PTk5OTAKRklSRUNSQVdMX1BPUlQ9OTk5MQoKIyAtLS0tIFNlYXJYTkcgaW5zdGFuY2Ugc2VjcmV0
  >> "!B64TMP!" echo IChyYW5kb20g4oCUIGluc3RhbGxlciBnZW5lcmF0ZXMpIC0tLS0KU0VBUlhOR19TRUNSRVQ9cmVw
  >> "!B64TMP!" echo bGFjZS13aXRoLTY0LWNoYXItcmFuZG9tLWhleAoKIyAtLS0tIEZpcmVjcmF3bCBpbnRlcm5hbCBj
  >> "!B64TMP!" echo cmVkZW50aWFscyAoaW5zdGFsbGVyIGdlbmVyYXRlcyByYW5kb20gdmFsdWVzKSAtLS0tCkJVTExf
  >> "!B64TMP!" echo QVVUSF9LRVk9cmVwbGFjZS13aXRoLTY0LWNoYXItcmFuZG9tLWhleApQT1NUR1JFU19EQj1maXJl
  >> "!B64TMP!" echo Y3Jhd2wKUE9TVEdSRVNfVVNFUj1maXJlY3Jhd2wKUE9TVEdSRVNfUEFTU1dPUkQ9cmVwbGFjZS13
  >> "!B64TMP!" echo aXRoLTY0LWNoYXItcmFuZG9tLWhleApSQUJCSVRNUV9VU0VSPWZpcmVjcmF3bApSQUJCSVRNUV9Q
  >> "!B64TMP!" echo QVNTV09SRD1yZXBsYWNlLXdpdGgtNjQtY2hhci1yYW5kb20taGV4CgojIC0tLS0gTG9nZ2luZyAt
  >> "!B64TMP!" echo LS0tCkxPR0dJTkdfTEVWRUw9aW5mbwoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojICBPcHRpb25h
  >> "!B64TMP!" echo bDogY29ubmVjdCBhIGxvY2FsIChvciByZW1vdGUpIExMTSBzbyBGaXJlY3Jhd2wncyAvdjEvZXh0
  >> "!B64TMP!" echo cmFjdCBhbmQKIyAgInN1bW1hcnkiIGZlYXR1cmVzIHdvcmsuIEFueSBPcGVuQUktY29tcGF0aWJs
  >> "!B64TMP!" echo ZSBlbmRwb2ludCB3aWxsIGRvLgojICBMTSBTdHVkaW8gaXMgdGhlIHJlY29tbWVuZGVkIGRlZmF1
  >> "!B64TMP!" echo bHQgKHByaW9yaXR5IG92ZXIgT2xsYW1hKS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKIyAtLS0t
  >> "!B64TMP!" echo IE9wdGlvbiBBIChSRUNPTU1FTkRFRCk6IExNIFN0dWRpbyAvIGFueSBPcGVuQUktY29tcGF0aWJs
  >> "!B64TMP!" echo ZSBsb2NhbCBzZXJ2ZXIgLS0tLQojICAgMS4gSW4gTE0gU3R1ZGlvOiBEZXZlbG9wZXIgdGFiID4g
  >> "!B64TMP!" echo IlN0YXJ0IFNlcnZlciIgb24gcG9ydCAxMjM0LCBsb2FkIGEgbW9kZWwsCiMgICAgICBhbmQgRU5B
  >> "!B64TMP!" echo QkxFICJTZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrIiBzbyB0aGUgRmlyZWNyYXdsIGNvbnRhaW5lciBj
  >> "!B64TMP!" echo YW4gcmVhY2ggaXQuCiMgICAyLiBOT1RFOiBPUEVOQUlfQkFTRV9VUkwgaXMgcmVhZCBJTlNJREUg
  >> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCBjb250YWluZXIuIEZyb20gdGhlcmUsCiMgICAgICB5b3VyIGhvc3QgbWFj
  >> "!B64TMP!" echo aGluZSBpcyAiaG9zdC5kb2NrZXIuaW50ZXJuYWwiLCBOT1QgImxvY2FsaG9zdCIuIFNvIHVzZToK
  >> "!B64TMP!" echo IyBPUEVOQUlfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQvdjEKIyBP
  >> "!B64TMP!" echo UEVOQUlfQVBJX0tFWT1sbS1zdHVkaW8gICAgICAgICAgIyBhbnkgbm9uLWVtcHR5IHN0cmluZzsg
  >> "!B64TMP!" echo TE0gU3R1ZGlvIGlnbm9yZXMgaXQKIyBNT0RFTF9OQU1FPWxvY2FsLW1vZGVsICAgICAgICAgICAg
  >> "!B64TMP!" echo IyB0aGUgbW9kZWwgaWQgbG9hZGVkIGluIExNIFN0dWRpbwoKIyAtLS0tIE9wdGlvbiBCOiByZW1v
  >> "!B64TMP!" echo dGUgT3BlbkFJLWNvbXBhdGlibGUgc2VydmVyICh2TExNLCBsbGFtYS5jcHAgc2VydmVyLCBldGMu
  >> "!B64TMP!" echo KSAtLS0tCiMgT1BFTkFJX0JBU0VfVVJMPWh0dHA6Ly8xOTIuMTY4LjEuNTA6ODAwMC92MQojIE9Q
  >> "!B64TMP!" echo RU5BSV9BUElfS0VZPXBsYWNlaG9sZGVyCiMgTU9ERUxfTkFNRT15b3VyLW1vZGVsLWlkCgojIC0t
  >> "!B64TMP!" echo LS0gT3B0aW9uIEMgKGZhbGxiYWNrKTogT2xsYW1hIG9uIHRoZSBzYW1lIGhvc3QgYXMgRG9ja2Vy
  >> "!B64TMP!" echo IC0tLS0KIyBPTExBTUFfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjExNDM0
  >> "!B64TMP!" echo L2FwaQojIE1PREVMX05BTUU9cXdlbjIuNTo3YgojIE1PREVMX0VNQkVERElOR19OQU1FPW5vbWlj
  >> "!B64TMP!" echo LWVtYmVkLXRleHQK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.env.example"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- README.md ---
set "NEED_B64=1"
if exist "!SRC!\README.md" (
  copy /Y "!SRC!\README.md" "!TARGET!\README.md" >nul 2>&1
  if exist "!TARGET!\README.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] README.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS160655574.b64"
  > "!B64TMP!" echo IyDwn5SNIExvY2FsIFNlYXJjaCDigJQgYSBwcml2YXRlIHdlYi1icm93c2luZyBzeXN0ZW0gZm9y
  >> "!B64TMP!" echo IEFJIG1vZGVscwoKKipTZWFyWE5HICsgRmlyZWNyYXdsICsgdGhlIGxvY2FsLXdlYi1zZWFyY2gg
  >> "!B64TMP!" echo YWdlbnQgc2tpbGwsIHJ1bm5pbmcgZW50aXJlbHkgb24geW91ciBtYWNoaW5lLCBiZWhpbmQgdHdv
  >> "!B64TMP!" echo IGxvY2FsIHBvcnRzLioqCgpHaXZlIGFueSBMTE0g4oCUIGEgbG9jYWwgbW9kZWwgaW4gTE0gU3R1
  >> "!B64TMP!" echo ZGlvLCBhIGNsb3VkIG1vZGVsLCBhbiBhZ2VudCwgYW4gTUNQCmNsaWVudCwgb3IgYSBwbGFpbiBj
  >> "!B64TMP!" echo aGF0IFVJIOKAlCB0aGUgYWJpbGl0eSB0byAqKnNlYXJjaCB0aGUgd2ViIGFuZCByZWFkIHBhZ2Vz
  >> "!B64TMP!" echo KioKd2l0aG91dCBzZW5kaW5nIGEgc2luZ2xlIHJlcXVlc3QgdG8gYSBwYWlkIHNjcmFwaW5nIEFQ
  >> "!B64TMP!" echo SS4gRXZlcnl0aGluZyBydW5zIGluCkRvY2tlciBvbiB5b3VyIGNvbXB1dGVyOyB5b3VyIHF1ZXJp
  >> "!B64TMP!" echo ZXMsIHJlc3VsdHMsIGFuZCBwYWdlIGNvbnRlbnRzIG5ldmVyIGxlYXZlCnlvdXIgbmV0d29yay4K
  >> "!B64TMP!" echo CnwgV2hhdCB8IFVSTCAoZGVmYXVsdCkgfCBQdXJwb3NlIHwKfC0tLS0tLXwtLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS18LS0tLS0tLS0tfAp8ICoqU2VhclhORyoqICB8IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIHwg
  >> "!B64TMP!" echo TWV0YXNlYXJjaCArIEpTT04gQVBJLiBBZ2dyZWdhdGVzIEdvb2dsZS9CaW5nL0R1Y2tEdWNrR28v
  >> "!B64TMP!" echo ZXRjLiB8CnwgKipGaXJlY3Jhd2wqKiB8IGBodHRwOi8vbG9jYWxob3N0Ojk5OTFgIHwgU2NyYXBl
  >> "!B64TMP!" echo IC8gY3Jhd2wgLyBtYXAgLyBzZWFyY2ggLyBleHRyYWN0IOKAlCByZXR1cm5zIGNsZWFuIE1hcmtk
  >> "!B64TMP!" echo b3duLiB8CnwgKipsb2NhbC13ZWItc2VhcmNoKiogfCBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoYCB8IEJ1bmRsZWQgYWdlbnQgc2tpbGw6IHNlYXJjaCArIHJlYWQgKyBhdXRvLXN0
  >> "!B64TMP!" echo YXJ0IHRoZSBzdGFjay4gfAoKPiBCb3RoIHBvcnRzIGFyZSBmdWxseSBjb25maWd1cmFibGUgYXQg
  >> "!B64TMP!" echo aW5zdGFsbCB0aW1lLiBUaGUgZGVmYXVsdHMgKGA5OTkwYCBhbmQKPiBgOTk5MWApIGFyZSBjaG9z
  >> "!B64TMP!" echo ZW4gdG8gYXZvaWQgY2xhc2hpbmcgd2l0aCBjb21tb24gZGV2IHNlcnZlcnMuCgotLS0KCiMjIFRh
  >> "!B64TMP!" echo YmxlIG9mIGNvbnRlbnRzCgoxLiBbV2hhdCB5b3UgZ2V0XSgjd2hhdC15b3UtZ2V0KQoyLiBbUmVx
  >> "!B64TMP!" echo dWlyZW1lbnRzXSgjcmVxdWlyZW1lbnRzKQozLiBbUXVpY2sgc3RhcnQgKG9uZS1jbGljayBpbnN0
  >> "!B64TMP!" echo YWxsKV0oI3F1aWNrLXN0YXJ0LW9uZS1jbGljay1pbnN0YWxsKQo0LiBbTWFuYWdpbmcgdGhlIHN0
  >> "!B64TMP!" echo YWNrXSgjbWFuYWdpbmctdGhlLXN0YWNrKQo1LiBbSG93IGl0IGZpdHMgdG9nZXRoZXJdKCNob3ct
  >> "!B64TMP!" echo aXQtZml0cy10b2dldGhlcikKNi4gW1VzaW5nIGl0IHdpdGggQUkgbW9kZWxzXSgjdXNpbmctaXQt
  >> "!B64TMP!" echo d2l0aC1haS1tb2RlbHMpCiAgIC0gW0EuIFRoZSBidW5kbGVkIGxvY2FsLXdlYi1zZWFyY2ggc2tp
  >> "!B64TMP!" echo bGwgKHJlY29tbWVuZGVkKV0oI2EtdGhlLWJ1bmRsZWQtbG9jYWwtd2ViLXNlYXJjaC1za2lsbC1y
  >> "!B64TMP!" echo ZWNvbW1lbmRlZCkKICAgLSBbQi4gRGlyZWN0IFNlYXJYTkcgSlNPTiBBUEldKCNiLWRpcmVjdC1z
  >> "!B64TMP!" echo ZWFyeG5nLWpzb24tYXBpKQogICAtIFtDLiBEaXJlY3QgRmlyZWNyYXdsIFJFU1QgQVBJXSgjYy1k
  >> "!B64TMP!" echo aXJlY3QtZmlyZWNyYXdsLXJlc3QtYXBpKQogICAtIFtELiBDb25uZWN0IGEgbG9jYWwgTExNIChM
  >> "!B64TMP!" echo TSBTdHVkaW8sIGV0Yy4pXSgjZC1jb25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1ldGMpCiAg
  >> "!B64TMP!" echo IC0gW0UuIFZpYSBhbiBNQ1Agc2VydmVyXSgjZS12aWEtYW4tbWNwLXNlcnZlcikKICAgLSBbRi4g
  >> "!B64TMP!" echo VmlhIHByb21wdGluZyAoYW55IGNoYXQgVUkpXSgjZi12aWEtcHJvbXB0aW5nLWFueS1jaGF0LXVp
  >> "!B64TMP!" echo KQogICAtIFtHLiBHVUkgaW50ZWdyYXRpb25zXSgjZy1ndWktaW50ZWdyYXRpb25zKQo3LiBbQ29u
  >> "!B64TMP!" echo ZmlndXJhdGlvbiByZWZlcmVuY2VdKCNjb25maWd1cmF0aW9uLXJlZmVyZW5jZSkKOC4gW1Ryb3Vi
  >> "!B64TMP!" echo bGVzaG9vdGluZ10oI3Ryb3VibGVzaG9vdGluZykKOS4gW1VwZGF0aW5nICYgdW5pbnN0YWxsaW5n
  >> "!B64TMP!" echo XSgjdXBkYXRpbmctLXVuaW5zdGFsbGluZykKMTAuIFtTZWN1cml0eSBub3Rlc10oI3NlY3VyaXR5
  >> "!B64TMP!" echo LW5vdGVzKQoxMS4gW0NyZWRpdHMgJiBsaWNlbnNlc10oI2NyZWRpdHMtLWxpY2Vuc2VzKQoKLS0t
  >> "!B64TMP!" echo CgojIyBXaGF0IHlvdSBnZXQKCkEgc2luZ2xlIERvY2tlciBDb21wb3NlIHN0YWNrIG9mIHNpeCBz
  >> "!B64TMP!" echo ZXJ2aWNlcyBvbiBhIHByaXZhdGUgYnJpZGdlIG5ldHdvcmssCioqcGx1cyoqIGEgcmVhZHktbWFk
  >> "!B64TMP!" echo ZSBhZ2VudCBza2lsbCB0aGF0IHRpZXMgaXQgYWxsIHRvZ2V0aGVyOgoKfCBTZXJ2aWNlIHwgSW1h
  >> "!B64TMP!" echo Z2UgfCBSb2xlIHwKfC0tLS0tLS0tLXwtLS0tLS0tfC0tLS0tLXwKfCAqKnNlYXJ4bmcqKiB8IGBz
  >> "!B64TMP!" echo ZWFyeG5nL3NlYXJ4bmc6bGF0ZXN0YCB8IE1ldGFzZWFyY2ggZW5naW5lIHdpdGggKipKU09OIG91
  >> "!B64TMP!" echo dHB1dCBlbmFibGVkKiogYW5kIHRoZSByYXRlLWxpbWl0ZXIgKipkaXNhYmxlZCoqLCBzbyBtb2Rl
  >> "!B64TMP!" echo bHMgY2FuIHF1ZXJ5IGl0IHByb2dyYW1tYXRpY2FsbHkuIHwKfCAqKmZpcmVjcmF3bCoqIHwgYGdo
  >> "!B64TMP!" echo Y3IuaW8vZmlyZWNyYXdsL2ZpcmVjcmF3bDpsYXRlc3RgIHwgVGhlIHNjcmFwaW5nL2NyYXdsaW5n
  >> "!B64TMP!" echo L3NlYXJjaCBBUEkuIFJ1bnMgd2l0aCBgVVNFX0RCX0FVVEhFTlRJQ0FUSU9OPWZhbHNlYCDihpIg
  >> "!B64TMP!" echo KipubyBBUEkga2V5IG5lZWRlZCoqIGZvciBsb2NhbCB1c2UuIHwKfCAqKnBsYXl3cmlnaHQtc2Vy
  >> "!B64TMP!" echo dmljZSoqIHwgYGdoY3IuaW8vZmlyZWNyYXdsL3BsYXl3cmlnaHQtc2VydmljZTpsYXRlc3RgIHwg
  >> "!B64TMP!" echo SGVhZGxlc3MgQ2hyb21pdW0gZm9yIEphdmFTY3JpcHQtcmVuZGVyZWQgcGFnZXMuIHwKfCAqKnJl
  >> "!B64TMP!" echo ZGlzKiogfCBgcmVkaXM6YWxwaW5lYCB8IEZpcmVjcmF3bCBqb2IgcXVldWUuIHwKfCAqKnJhYmJp
  >> "!B64TMP!" echo dG1xKiogfCBgcmFiYml0bXE6My1tYW5hZ2VtZW50YCB8IEZpcmVjcmF3bCBtZXNzYWdlIGJyb2tl
  >> "!B64TMP!" echo ci4gfAp8ICoqbnVxLXBvc3RncmVzKiogfCBgZ2hjci5pby9maXJlY3Jhd2wvbnVxLXBvc3RncmVz
  >> "!B64TMP!" echo OmxhdGVzdGAgfCBGaXJlY3Jhd2wgam9iLXN0YXRlIERCIChwZ19jcm9uIGVuYWJsZWQpLiB8CgpP
  >> "!B64TMP!" echo biB0b3Agb2YgdGhlIGNvbnRhaW5lcnMsIHRoZSBpbnN0YWxsZXIgYnVuZGxlcyAqKmxvY2FsLXdl
  >> "!B64TMP!" echo Yi1zZWFyY2gqKiDigJQgYSBza2lsbCBmb3IKYWdlbnRzIHRoYXQgbG9hZCBza2lsbHMgZnJvbSBg
  >> "!B64TMP!" echo fi8uYWdlbnRzL3NraWxscy9gIChgQzpcVXNlcnNcWW91XC5hZ2VudHNcc2tpbGxzXGAKb24gV2lu
  >> "!B64TMP!" echo ZG93cykuIEl0IGdpdmVzIHRoZSBhZ2VudCBhIGNvbXBsZXRlIHdlYi1yZXNlYXJjaCB3b3JrZmxv
  >> "!B64TMP!" echo dzogc2VhcmNoIHZpYQpTZWFyWE5HLCByZWFkIHBhZ2VzIHZpYSBGaXJlY3Jhd2wsIGFuZCBldmVu
  >> "!B64TMP!" echo IHN0YXJ0IHRoZSBEb2NrZXIgc3RhY2sKYXV0b21hdGljYWxseSB3aGVuIGl0J3MgZG93bi4gU2Vl
  >> "!B64TMP!" echo IFtzZWN0aW9uIEFdKCNhLXRoZS1idW5kbGVkLWxvY2FsLXdlYi1zZWFyY2gtc2tpbGwtcmVjb21t
  >> "!B64TMP!" echo ZW5kZWQpLgoKT25seSAqKnR3byBob3N0IHBvcnRzKiogYXJlIHB1Ymxpc2hlZCAoYDk5OTBgIGFu
  >> "!B64TMP!" echo ZCBgOTk5MWAgYnkgZGVmYXVsdCkuIEV2ZXJ5dGhpbmcKZWxzZSBzdGF5cyBvbiB0aGUgcHJpdmF0
  >> "!B64TMP!" echo ZSBgbG9jYWwtc2VhcmNoLW5ldGAgYnJpZGdlIG5ldHdvcmsuIEZpcmVjcmF3bCdzCmAvdjEvc2Vh
  >> "!B64TMP!" echo cmNoYCBlbmRwb2ludCBpcyBhdXRvbWF0aWNhbGx5IHdpcmVkIHRvIFNlYXJYTkcgaW50ZXJuYWxs
  >> "!B64TMP!" echo eSwgc28gYSBzaW5nbGUKRmlyZWNyYXdsIGNhbGwgY2FuIGJvdGggc2VhcmNoICphbmQqIGZldGNo
  >> "!B64TMP!" echo IGZ1bGwgcGFnZSBjb250ZW50LgoKLS0tCgojIyBSZXF1aXJlbWVudHMKCi0gKipEb2NrZXIqKiB3
  >> "!B64TMP!" echo aXRoIHRoZSAqKkNvbXBvc2UgdjIgcGx1Z2luKiogKGBkb2NrZXIgY29tcG9zZWApLgogIC0gV2lu
  >> "!B64TMP!" echo ZG93cyAvIG1hY09TOiBbRG9ja2VyIERlc2t0b3BdKGh0dHBzOi8vd3d3LmRvY2tlci5jb20vcHJv
  >> "!B64TMP!" echo ZHVjdHMvZG9ja2VyLWRlc2t0b3AvKQogIC0gTGludXg6IFtEb2NrZXIgRW5naW5lXShodHRwczov
  >> "!B64TMP!" echo L2RvY3MuZG9ja2VyLmNvbS9lbmdpbmUvaW5zdGFsbC8pICsgdGhlIGBkb2NrZXItY29tcG9zZS1w
  >> "!B64TMP!" echo bHVnaW5gIHBhY2thZ2UuIEFkZCB5b3VyIHVzZXIgdG8gdGhlIGBkb2NrZXJgIGdyb3VwIHNvIHlv
  >> "!B64TMP!" echo dSBkb24ndCBuZWVkIGBzdWRvYC4KLSAqKn41IEdCIGZyZWUgZGlzayoqIGZvciBpbWFnZXMgYW5k
  >> "!B64TMP!" echo IGRhdGEuCi0gKio4IEdCIFJBTSAvIDQgQ1BVIGNvcmVzKiogcmVjb21tZW5kZWQgKHRoZSBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wgKyBQbGF5d3JpZ2h0IHN0YWNrIGlzIHRoZSBoZWF2eSBwYXJ0OyByZWR1Y2UgcmVzb3Vy
  >> "!B64TMP!" echo Y2UgbGltaXRzIGluIGBkb2NrZXItY29tcG9zZS55bWxgIGZvciBzbWFsbGVyIGhvc3RzKS4KLSAq
  >> "!B64TMP!" echo KlB5dGhvbiAzLjgrKiogZm9yIHRoZSBidW5kbGVkIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgc2Ny
  >> "!B64TMP!" echo aXB0cyAob3B0aW9uYWwgYnV0IHJlY29tbWVuZGVkIOKAlCBpdCdzIHRoZSBlYXNpZXN0IHdheSB0
  >> "!B64TMP!" echo byB1c2UgdGhlIHN0YWNrKS4KLSAqKE9wdGlvbmFsLCBmb3IgRmlyZWNyYXdsIEFJIGZlYXR1cmVz
  >> "!B64TMP!" echo KSogKipMTSBTdHVkaW8qKiBvciBhbnkgT3BlbkFJLWNvbXBhdGlibGUgbG9jYWwgc2VydmVyIOKA
  >> "!B64TMP!" echo lCBzZWUgW3NlY3Rpb24gRF0oI2QtY29ubmVjdC1hLWxvY2FsLWxsbS1sbS1zdHVkaW8tZXRjKS4K
  >> "!B64TMP!" echo LSAqKE9wdGlvbmFsLCBmb3IgTUNQKSogKipOb2RlLmpzIDE4KyoqIHNvIGBucHggZmlyZWNyYXds
  >> "!B64TMP!" echo LW1jcGAgd29ya3MuCgpWZXJpZnkgRG9ja2VyIGlzIHJlYWR5OgoKYGBgYmFzaApkb2NrZXIgaW5m
  >> "!B64TMP!" echo byAgICAgICAgICAgICMgZW5naW5lIGlzIHJ1bm5pbmcKZG9ja2VyIGNvbXBvc2UgdmVyc2lvbiAj
  >> "!B64TMP!" echo IHYyIGlzIGluc3RhbGxlZApgYGAKCi0tLQoKIyMgUXVpY2sgc3RhcnQgKG9uZS1jbGljayBpbnN0
  >> "!B64TMP!" echo YWxsKQoKPiAqKlRoZSBpbnN0YWxsZXIgaXMgc2VsZi1jb250YWluZWQuKiogRXZlcnkgZmlsZSBp
  >> "!B64TMP!" echo dCBuZWVkcyAoYGRvY2tlci1jb21wb3NlLnltbGAsCj4gYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdz
  >> "!B64TMP!" echo LnltbGAsIGAuZW52LmV4YW1wbGVgLCB0aGUgYnVuZGxlZCBgbG9jYWwtd2ViLXNlYXJjaGAgc2tp
  >> "!B64TMP!" echo bGwsCj4gYWxsIHRoZSBydW4vc3RvcC91cGRhdGUvdW5pbnN0YWxsIHNjcmlwdHMsIHRoaXMgUkVB
  >> "!B64TMP!" echo RE1FLCBhbmQgZXZlbiB0aGUgKm90aGVyKgo+IHBsYXRmb3JtJ3MgaW5zdGFsbGVyKSBpcyBlbWJl
  >> "!B64TMP!" echo ZGRlZCBpbnNpZGUgaXQuIFlvdSBjYW4gZG93bmxvYWQgKipqdXN0Cj4gYGluc3RhbGwtbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoLmJhdGAqKiAoV2luZG93cykgb3IgKipqdXN0IGBpbnN0YWxsLWxvY2FsLXNlYXJjaC5z
  >> "!B64TMP!" echo aGAqKgo+IChMaW51eC9tYWNPUykgb24gaXRzIG93biBhbmQgdGhlIGluc3RhbGxlciB3aWxsIHN0
  >> "!B64TMP!" echo aWxsIHByb2R1Y2UgYSBjb21wbGV0ZSwKPiB3b3JraW5nIGZvbGRlci4gRG93bmxvYWRpbmcgdGhl
  >> "!B64TMP!" echo IHdob2xlIGBsb2NhbC1zZWFyY2hgIGZvbGRlciBvciB0aGUgemlwIGp1c3QKPiBtYWtlcyB0aGUg
  >> "!B64TMP!" echo aW5zdGFsbCBhIGxpdHRsZSBmYXN0ZXIgKGl0IGNvcGllcyBmaWxlcyBpbnN0ZWFkIG9mIGRlY29k
  >> "!B64TMP!" echo aW5nIHRoZW0pLgoKUnVuICoqb25lKiogaW5zdGFsbGVyIGZvciB5b3VyIHBsYXRmb3JtLiBJdCB3
  >> "!B64TMP!" echo aWxsIGFzayB5b3UgYSBmZXcgdGhpbmdzIOKAlCBpbnN0YWxsCmZvbGRlciwgU2VhclhORyBwb3J0
  >> "!B64TMP!" echo LCBGaXJlY3Jhd2wgcG9ydCwgKG9wdGlvbmFsbHkpIGEgbG9jYWwgTExNIOKAlCB3aXRoIHNlbnNp
  >> "!B64TMP!" echo YmxlCmRlZmF1bHRzIHlvdSBjYW4gYWNjZXB0IGJ5IHByZXNzaW5nICoqRW50ZXIqKi4gSXQgdGhl
  >> "!B64TMP!" echo biBnZW5lcmF0ZXMKY3J5cHRvZ3JhcGhpY2FsbHktc2VjdXJlIGNyZWRlbnRpYWxzLCB3cml0ZXMg
  >> "!B64TMP!" echo eW91ciBgLmVudmAsICoqaW5zdGFsbHMgdGhlCmxvY2FsLXdlYi1zZWFyY2ggc2tpbGwqKiwgcHVs
  >> "!B64TMP!" echo bHMgdGhlIGltYWdlcywgYW5kIHN0YXJ0cyB0aGUgc3RhY2suCgo+ICoqRG9ja2VyIGlzbid0IHJ1
  >> "!B64TMP!" echo bm5pbmc/KiogTm8gcHJvYmxlbSDigJQgdGhlIGluc3RhbGxlciBzdGFydHMgaXQgZm9yIHlvdTog
  >> "!B64TMP!" echo aXQKPiBsYXVuY2hlcyBEb2NrZXIgRGVza3RvcCAoV2luZG93cy9tYWNPUykgb3IgdGhlIERvY2tl
  >> "!B64TMP!" echo ciBzZXJ2aWNlCj4gKGBzeXN0ZW1jdGxgL2BzZXJ2aWNlYCwgTGludXgpIGFuZCB3YWl0cyB1cCB0
  >> "!B64TMP!" echo byA1IG1pbnV0ZXMgZm9yIHRoZSBlbmdpbmUgd2hpbGUKPiB5b3UgYW5zd2VyIHRoZSBwcm9tcHRz
  >> "!B64TMP!" echo LiAoT3ZlcnJpZGUgdGhlIHdhaXQgd2l0aCB0aGUKPiBgTE9DQUxfU0VBUkNIX0RPQ0tFUl9USU1F
  >> "!B64TMP!" echo T1VUYCBlbnYgdmFyLCBpbiBzZWNvbmRzLikKCiMjIyBXaW5kb3dzCgoxLiBJbnN0YWxsIFtEb2Nr
  >> "!B64TMP!" echo ZXIgRGVza3RvcF0oaHR0cHM6Ly93d3cuZG9ja2VyLmNvbS9wcm9kdWN0cy9kb2NrZXItZGVza3Rv
  >> "!B64TMP!" echo cC8pIOKAlCBubyBuZWVkIHRvIG9wZW4gaXQgZmlyc3Q7IHRoZSBpbnN0YWxsZXIgbGF1bmNoZXMg
  >> "!B64TMP!" echo aXQgYXV0b21hdGljYWxseS4KMi4gRG91YmxlLWNsaWNrICoqYGluc3RhbGwtbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo LmJhdGAqKiAob3IgcnVuIGl0IGZyb20gYSB0ZXJtaW5hbCkuCgpgYGAKLS0tIFN0ZXAgMSBvZiA0
  >> "!B64TMP!" echo OiBJbnN0YWxsIGxvY2F0aW9uIC0tLS0tLS0tLS0KICBUYXJnZXQgZm9sZGVyIFtwcmVzcyBFbnRl
  >> "!B64TMP!" echo ciBmb3IgZGVmYXVsdF06ICAgICAgICAgICAgIyBDOlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNoCi0t
  >> "!B64TMP!" echo LSBTdGVwIDIgb2YgNDogU2VhclhORyBwb3J0IChkZWZhdWx0IDk5OTApIC0tLS0tLQogIFBvcnQg
  >> "!B64TMP!" echo Zm9yIFNlYXJYTkcgW3ByZXNzIEVudGVyIGZvciA5OTkwXTogOTk5MAotLS0gU3RlcCAzIG9mIDQ6
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBwb3J0IChkZWZhdWx0IDk5OTEpIC0tLS0KICBQb3J0IGZvciBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo W3ByZXNzIEVudGVyIGZvciA5OTkxXTogOTk5MQotLS0gU3RlcCA0IG9mIDQ6IExvY2FsIExMTSAo
  >> "!B64TMP!" echo b3B0aW9uYWwpIC0tLS0tLS0tLS0tLS0KICBDb25uZWN0IGEgbG9jYWwgTExNIG5vdz8gW3kvTl06
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAjIG9wdGlvbmFsLCBzZWUgc2VjdGlvbiBECmBgYAoKIyMj
  >> "!B64TMP!" echo IExpbnV4ICYgbWFjT1MKCmBgYGJhc2gKY2htb2QgK3ggaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gK
  >> "!B64TMP!" echo Li9pbnN0YWxsLWxvY2FsLXNlYXJjaC5zaApgYGAKClRoZSBwcm9tcHRzIGFyZSB0aGUgc2FtZS4g
  >> "!B64TMP!" echo RGVmYXVsdHM6IGluc3RhbGwgdG8gYH4vbG9jYWwtc2VhcmNoYCwgU2VhclhORyBvbgpgOTk5MGAs
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBvbiBgOTk5MWAuIEEgc3RvcHBlZCBEb2NrZXIgZW5naW5lIGlzIHN0YXJ0ZWQg
  >> "!B64TMP!" echo YXV0b21hdGljYWxseQooRG9ja2VyIERlc2t0b3Agb24gbWFjT1MsIGBzeXN0ZW1jdGxgL2BzZXJ2
  >> "!B64TMP!" echo aWNlYCBvbiBMaW51eCkuCgo+ICoqRmlyc3QgcnVuIGRvd25sb2FkcyB+M+KAkzQgR0Igb2YgRG9j
  >> "!B64TMP!" echo a2VyIGltYWdlcyoqICh0aGUgUGxheXdyaWdodCBpbWFnZSBidW5kbGVzCj4gYSBmdWxsIENocm9t
  >> "!B64TMP!" echo aXVtKS4gU3Vic2VxdWVudCBzdGFydHMgYXJlIGEgZmV3IHNlY29uZHMuCgpXaGVuIGl0IGZpbmlz
  >> "!B64TMP!" echo aGVzIHlvdSdsbCBzZWU6CgpgYGAKU2VhclhORyAgKHNlYXJjaCArIEpTT04gQVBJKTogIGh0dHA6
  >> "!B64TMP!" echo Ly9sb2NhbGhvc3Q6OTk5MApGaXJlY3Jhd2wgKHNjcmFwZS9jcmF3bCBBUEkpOiBodHRwOi8vbG9j
  >> "!B64TMP!" echo YWxob3N0Ojk5OTEKQWdlbnQgc2tpbGw6IEM6XFVzZXJzXFlvdVwuYWdlbnRzXHNraWxsc1xsb2Nh
  >> "!B64TMP!" echo bC13ZWItc2VhcmNoICAgKG9yIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaCkKYGBg
  >> "!B64TMP!" echo CgpPcGVuIGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIGluIGEgYnJvd3NlciB0byBzZWUgdGhlIFNl
  >> "!B64TMP!" echo YXJYTkcgc2VhcmNoIFVJIOKAlCBvciwKaWYgeW91ciBhZ2VudCBsb2FkcyBza2lsbHMgZnJvbSBg
  >> "!B64TMP!" echo fi8uYWdlbnRzL3NraWxscy9gLCBqdXN0IGFzayBpdCB0byByZXNlYXJjaApzb21ldGhpbmcgY3Vy
  >> "!B64TMP!" echo cmVudCBhbmQgaXQgd2lsbCB1c2UgKipsb2NhbC13ZWItc2VhcmNoKiogYXV0b21hdGljYWxseSAo
  >> "!B64TMP!" echo c2VlCltzZWN0aW9uIEFdKCNhLXRoZS1idW5kbGVkLWxvY2FsLXdlYi1zZWFyY2gtc2tpbGwtcmVj
  >> "!B64TMP!" echo b21tZW5kZWQpKS4KCi0tLQoKIyMgTWFuYWdpbmcgdGhlIHN0YWNrCgpBZnRlciBpbnN0YWxsLCB0
  >> "!B64TMP!" echo aGUgbWFuYWdlbWVudCBzY3JpcHRzIGxpdmUgKippbiB5b3VyIGluc3RhbGwgZm9sZGVyKioKKGBD
  >> "!B64TMP!" echo OlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNoYCBvbiBXaW5kb3dzLCBgfi9sb2NhbC1zZWFyY2hgIG9u
  >> "!B64TMP!" echo IExpbnV4L21hY09TKS4KVGhleSBhdXRvLWRldGVjdCB0aGVpciBvd24gbG9jYXRpb24sIHNvIHlv
  >> "!B64TMP!" echo dSBjYW4gcnVuIHRoZW0gZnJvbSBhbnl3aGVyZSBieQpkb3VibGUtY2xpY2tpbmcgb3IgYC4vYC1p
  >> "!B64TMP!" echo bmcgdGhlbS4KCnwgQWN0aW9uIHwgV2luZG93cyB8IExpbnV4IC8gbWFjT1MgfAp8LS0tLS0tLS18
  >> "!B64TMP!" echo LS0tLS0tLS0tfC0tLS0tLS0tLS0tLS0tLXwKfCAqKlN0YXJ0KiogdGhlIHN0YWNrIHwgYFJ1bi5i
  >> "!B64TMP!" echo YXRgIHwgYC4vcnVuLnNoYCB8CnwgKipTdG9wKiogKGtlZXAgZGF0YSkgfCBgU3RvcC5iYXRgIHwg
  >> "!B64TMP!" echo YC4vc3RvcC5zaGAgfAp8ICoqVXBkYXRlKiogaW1hZ2VzICsgYXBwbHkgYC5lbnZgIGNoYW5nZXMg
  >> "!B64TMP!" echo KyAqKnJlLXN5bmMgdGhlIHNraWxsKiogfCBgVXBkYXRlLmJhdGAgfCBgLi91cGRhdGUuc2hgIHwK
  >> "!B64TMP!" echo fCAqKlVuaW5zdGFsbCoqIChjb250YWluZXJzICsgdm9sdW1lcyArIHNraWxsLCBvcHRpb25hbCBm
  >> "!B64TMP!" echo b2xkZXIgZGVsZXRlKSB8IGBVbmluc3RhbGwuYmF0YCB8IGAuL3VuaW5zdGFsbC5zaGAgfAoKLSAq
  >> "!B64TMP!" echo KlN0b3AqKiBvbmx5IHJlbW92ZXMgY29udGFpbmVyczsgeW91ciBkYXRhIHZvbHVtZXMgKEZpcmVj
  >> "!B64TMP!" echo cmF3bCBqb2Igc3RhdGUsCiAgcmVkaXMgY2FjaGUsIHJhYmJpdG1xL3Bvc3RncmVzIGRhdGEpIGFy
  >> "!B64TMP!" echo ZSBwcmVzZXJ2ZWQuCi0gKipVcGRhdGUqKiBydW5zIGBkb2NrZXIgY29tcG9zZSBwdWxsYCB0aGVu
  >> "!B64TMP!" echo IGBkb2NrZXIgY29tcG9zZSB1cCAtZGAsIHNvIGl0CiAgYm90aCB1cGdyYWRlcyBpbWFnZXMgKiph
  >> "!B64TMP!" echo bmQqKiBhcHBsaWVzIGFueSBwb3J0L0xMTSBlZGl0cyB5b3UgbWFkZSB0byBgLmVudmA7CiAgaXQg
  >> "!B64TMP!" echo YWxzbyByZS1jb3BpZXMgdGhlIGJ1bmRsZWQgYGxvY2FsLXdlYi1zZWFyY2hgIHNraWxsIGludG8g
  >> "!B64TMP!" echo YH4vLmFnZW50cy9za2lsbHMvYC4KLSAqKlVuaW5zdGFsbCoqIHJ1bnMgYGRvY2tlciBjb21wb3Nl
  >> "!B64TMP!" echo IGRvd24gLXZgIChkZWxldGVzIHZvbHVtZXMgKyBkYXRhKSwKICByZW1vdmVzIHRoZSBgbG9jYWwt
  >> "!B64TMP!" echo d2ViLXNlYXJjaGAgc2tpbGwgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNo
  >> "!B64TMP!" echo YCwgdGhlbgogIG9wdGlvbmFsbHkgZGVsZXRlcyB0aGUgaW5zdGFsbCBmb2xkZXIuIFB1bGxlZCBp
  >> "!B64TMP!" echo bWFnZXMgYXJlIGtlcHQ7IHJlY2xhaW0gdGhlbQogIHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAt
  >> "!B64TMP!" echo YWAgaWYgZGVzaXJlZC4KCi0tLQoKIyMgSG93IGl0IGZpdHMgdG9nZXRoZXIKCmBgYAogICAgICAg
  >> "!B64TMP!" echo IHlvdXIgQUkgbW9kZWwgLyBhZ2VudCAobG9jYWwtd2ViLXNlYXJjaCBza2lsbCkgLyBNQ1AgY2xp
  >> "!B64TMP!" echo ZW50IC8gY2hhdCBVSQogICAgICAgICAgICAgICAgICAgICAg4pSCCiAgIOKUjOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUvOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUkAog
  >> "!B64TMP!" echo ICDilrwgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilrwKaHR0cDovL2xv
  >> "!B64TMP!" echo Y2FsaG9zdDo5OTkwICAgICAgICAgICAgaHR0cDovL2xvY2FsaG9zdDo5OTkxCiAgIOKUgiBTZWFy
  >> "!B64TMP!" echo WE5HICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUgiBGaXJlY3Jhd2wgQVBJCiAgIOKUgiAg
  >> "!B64TMP!" echo LSAvc2VhcmNoP3E9Li4uJmZvcm1hdD1qc29uICAgICAgIOKUgiAgLSAvdjEvc2NyYXBlICAgKG9u
  >> "!B64TMP!" echo ZSBVUkwgLT4gbWFya2Rvd24pCiAgIOKUgiAgLSBhZ2dyZWdhdGVzIH43MCBlbmdpbmVzICAgICAg
  >> "!B64TMP!" echo ICAgICDilIIgIC0gL3YxL2NyYXdsICAgICh3aG9sZSBzaXRlLCBhc3luYykKICAg4pSCICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUgiAgLSAvdjEvbWFwICAgICAgKHNpdGUg
  >> "!B64TMP!" echo VVJMIHRyZWUpCiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIg
  >> "!B64TMP!" echo IC0gL3YxL3NlYXJjaCAgICgtPiB1c2VzIFNlYXJYTkchKQogICDilIIgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAg4pSCICAtIC92MS9leHRyYWN0ICAoLT4gdXNlcyB5b3VyIExM
  >> "!B64TMP!" echo TSkKICAg4pSC4peE4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIHdpcmVkIHRvZ2V0aGVy
  >> "!B64TMP!" echo IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUpCAgU0VBUlhOR19FTkRQT0lOVD1odHRw
  >> "!B64TMP!" echo Oi8vc2VhcnhuZzo4MDgwCiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICDilIIKICAg4pSU4pSA4pSA4pSA4pSA4pSA4pSA4pSAIHByaXZhdGUgZG9ja2VyIG5ldHdvcmsg
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pSA4pSYCiAgICAgICAgICAgICAgICAgbG9jYWwtc2VhcmNoLW5ldAog
  >> "!B64TMP!" echo ICBhbHNvIG9uIGl0OiBwbGF5d3JpZ2h0LXNlcnZpY2UgKENocm9taXVtKSwgcmVkaXMsIHJhYmJp
  >> "!B64TMP!" echo dG1xLCBudXEtcG9zdGdyZXMKYGBgCgpUaHJlZSBrZXkgd2lyaW5nIGRlY2lzaW9ucyB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbGVyIG1ha2VzIGZvciB5b3U6CgoxLiAqKlNlYXJYTkcgSlNPTiArIG5vIGxpbWl0ZXIqKiDi
  >> "!B64TMP!" echo gJQgYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAgc2V0cwogICBgc2VhcmNoLmZvcm1hdHM6
  >> "!B64TMP!" echo IFtodG1sLCBqc29uXWAgYW5kIGBzZXJ2ZXIubGltaXRlcjogZmFsc2VgLCBzbyBtb2RlbHMgY2Fu
  >> "!B64TMP!" echo IGhpdAogICBgL3NlYXJjaD9mb3JtYXQ9anNvbmAgd2l0aG91dCBiZWluZyBibG9ja2VkIGFzIGEg
  >> "!B64TMP!" echo Ym90LgoyLiAqKkZpcmVjcmF3bCDihpIgU2VhclhORyoqIOKAlCB0aGUgRmlyZWNyYXdsIGNvbnRh
  >> "!B64TMP!" echo aW5lciBzZXRzCiAgIGBTRUFSWE5HX0VORFBPSU5UPWh0dHA6Ly9zZWFyeG5nOjgwODBgLCBzbyBG
  >> "!B64TMP!" echo aXJlY3Jhd2wncyBgL3YxL3NlYXJjaGAgdXNlcyB5b3VyCiAgIGxvY2FsIFNlYXJYTkcgaW5zdGVh
  >> "!B64TMP!" echo ZCBvZiBuZWVkaW5nIGEgdGhpcmQtcGFydHkgc2VhcmNoIHByb3ZpZGVyLgozLiAqKmxvY2FsLXdl
  >> "!B64TMP!" echo Yi1zZWFyY2ggc2tpbGwgYXV0by1pbnN0YWxsKiog4oCUIHRoZSBpbnN0YWxsZXIgY29waWVzIHRo
  >> "!B64TMP!" echo ZSBidW5kbGVkIHNraWxsIHRvCiAgIGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gv
  >> "!B64TMP!" echo YCAoYWRkL292ZXJyaWRlKSBhbmQgcmVjb3JkcyB0aGUgaW5zdGFsbCBwYXRoIGluCiAgIGFuIGBp
  >> "!B64TMP!" echo bnN0YWxsLWRpci50eHRgIGhpbnQgaW5zaWRlIHRoZSBza2lsbCwgc28gdGhlIHNraWxsIGZpbmRz
  >> "!B64TMP!" echo IHRoZSBzdGFjayBldmVuCiAgIGlmIHlvdSBpbnN0YWxsZWQgdG8gYSBjdXN0b20gZm9sZGVyIGFu
  >> "!B64TMP!" echo ZCBEb2NrZXIgaXNuJ3QgcnVubmluZyB5ZXQuCgotLS0KCiMjIFVzaW5nIGl0IHdpdGggQUkgbW9k
  >> "!B64TMP!" echo ZWxzCgpUaGVyZSBhcmUgKipzZXZlbioqIHdheXMgdG8gdXNlIHRoaXMgc3lzdGVtLCBmcm9tIGxv
  >> "!B64TMP!" echo d2VzdCB0byBoaWdoZXN0CmludGVncmF0aW9uLiBQaWNrIHdoYXQgZml0cyB5b3VyIHN0YWNrIOKA
  >> "!B64TMP!" echo lCB5b3UgY2FuIG1peCBhbmQgbWF0Y2guCgojIyMgQS4gVGhlIGJ1bmRsZWQgbG9jYWwtd2ViLXNl
  >> "!B64TMP!" echo YXJjaCBza2lsbCAocmVjb21tZW5kZWQpCgpUaGUgaW5zdGFsbGVyIHNoaXBzIHdpdGggKipsb2Nh
  >> "!B64TMP!" echo bC13ZWItc2VhcmNoKiosIGFuIGFnZW50IHNraWxsIHRoYXQgdHVybnMgYW55CnNraWxsLWxvYWRp
  >> "!B64TMP!" echo bmcgYWdlbnQgaW50byBhIHdlYiByZXNlYXJjaGVyIHdpdGggemVybyBjb25maWd1cmF0aW9uLiBJ
  >> "!B64TMP!" echo ZiB5b3VyCmFnZW50IHJlYWRzIHNraWxscyBmcm9tIGB+Ly5hZ2VudHMvc2tpbGxzL2AKKGBDOlxV
  >> "!B64TMP!" echo c2Vyc1xZb3VcLmFnZW50c1xza2lsbHNcYCBvbiBXaW5kb3dzKSwgaXQncyBhbHJlYWR5IGF2YWls
  >> "!B64TMP!" echo YWJsZSBhZnRlcgppbnN0YWxsIOKAlCByZXN0YXJ0IHRoZSBhZ2VudCBpZiBpdCB3YXMgcnVubmlu
  >> "!B64TMP!" echo Zy4KClRoZSBpbnN0YWxsZXI6Ci0gcHV0cyBhIGNvcHkgaW4gYDxpbnN0YWxsIGZvbGRlcj4vbG9j
  >> "!B64TMP!" echo YWwtd2ViLXNlYXJjaC9gLCBhbmQKLSAqKmF1dG9tYXRpY2FsbHkgaW5zdGFsbHMgKGFkZC9vdmVy
  >> "!B64TMP!" echo cmlkZSkqKiBpdCBpbnRvCiAgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaC9gLgoK
  >> "!B64TMP!" echo V2hhdCB0aGUgc2tpbGwgZG9lcyBmb3IgdGhlIGFnZW50OgoKLSAqKkZpbmRzIHRoZSBzdGFjayBh
  >> "!B64TMP!" echo dXRvbWF0aWNhbGx5LioqIEl0IHJlYWRzIHRoZSByZWFsIHBvcnRzIGZyb20geW91ciBgLmVudmAK
  >> "!B64TMP!" echo ICAoc28gY3VzdG9tIGluc3RhbGwtdGltZSBwb3J0cyBqdXN0IHdvcmspIGFuZCBsb2NhdGVzIHRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlciB2aWEKICB0aGUgY29tcG9zZSBsYWJlbHMgb24gdGhlIHJ1bm5pbmcg
  >> "!B64TMP!" echo Y29udGFpbmVycywgdGhlIGluc3RhbGxlci1yZWNvcmRlZAogIGBpbnN0YWxsLWRpci50eHRgIGhp
  >> "!B64TMP!" echo bnQsIG9yIGB+L2xvY2FsLXNlYXJjaGAg4oCUIG5vIGhhcmRjb2RlZCBhbnl0aGluZy4KLSAqKlNl
  >> "!B64TMP!" echo bGYtaGVhbHMgYSBkb3duIHN0YWNrIOKAlCBubyB3YXJtLXVwIHN0ZXAuKiogSWYgdGhlIERvY2tl
  >> "!B64TMP!" echo ciBlbmdpbmUgb3IgdGhlCiAgY29udGFpbmVycyBhcmUgZG93biB3aGVuIGEgc2VhcmNoL3NjcmFw
  >> "!B64TMP!" echo ZSBydW5zLCB0aGUgc2NyaXB0IGJvb3RzIHRoZSBlbmdpbmUKICAoRG9ja2VyIERlc2t0b3AgLyBg
  >> "!B64TMP!" echo c3lzdGVtY3RsIHN0YXJ0IGRvY2tlcmApLCBydW5zIHRoZSBzYW1lIGBkb2NrZXIgY29tcG9zZQog
  >> "!B64TMP!" echo IHVwIC1kYCB0aGF0IGBSdW4uYmF0YCAvIGBydW4uc2hgIHVzZSwgd2FpdHMgZm9yIHRoZSBlbmRw
  >> "!B64TMP!" echo b2ludHMsIGFuZCByZXRyaWVzCiAgdGhlIHJlcXVlc3Qg4oCUIHNvIHRoZSBhZ2VudCBjYWxscyB0
  >> "!B64TMP!" echo aGUgc2VhcmNoL3NjcmFwZSBzY3JpcHRzIGRpcmVjdGx5LCBldmVuCiAgaW4gYW4gb2xkIGNvbnZl
  >> "!B64TMP!" echo cnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzIHNpbmNlIGdvbmUgZG93bgogIChgZW5zdXJlX3N0
  >> "!B64TMP!" echo YWNrLnB5YCByZW1haW5zIGF2YWlsYWJsZSBhcyBhbiBvcHRpb25hbCBwcmUtZmxpZ2h0IGNoZWNr
  >> "!B64TMP!" echo KS4gVGhlCiAgc3RhY2sgaXMgKipuZXZlciBzdG9wcGVkKiogYnkgdGhlIHNjcmlwdHMgKHN0b3Bw
  >> "!B64TMP!" echo aW5nIGlzIHlvdXIgam9iLCB2aWEKICBgU3RvcC5iYXRgIC8gYHN0b3Auc2hgKS4KLSAqKlNlYXJj
  >> "!B64TMP!" echo aGVzIHRoZSB3ZWIuKiogYHdlYl9zZWFyY2gucHkgInF1ZXJ5ImAgcHJpbnRzIHRoZSB0b3AgcmVz
  >> "!B64TMP!" echo dWx0cyBhcwogIGB0aXRsZSAvIHVybCAvIHNuaXBwZXRgLCB3aXRoIGAtLWxpbWl0YCwgYC0tdGlt
  >> "!B64TMP!" echo ZS1yYW5nZSBkYXl8d2Vla3xtb250aGAsIGFuZAogIGAtLWNhdGVnb3JpZXMgaXQsbmV3cyxnZW5l
  >> "!B64TMP!" echo cmFsYCBvcHRpb25zLgotICoqUmVhZHMgcGFnZXMuKiogYHdlYl9zY3JhcGUucHkgPHVybD5gIHJl
  >> "!B64TMP!" echo dHVybnMgdGhlIHBhZ2UgYXMgY2xlYW4gTWFya2Rvd24KICAodHJ1bmNhdGVkIGF0IDIwLDAwMCBj
  >> "!B64TMP!" echo aGFyczsgcmFpc2Ugd2l0aCBgLS1tYXgtY2hhcnNgKS4KCk1hbnVhbCB1c2FnZSAoZXhhY3RseSB3
  >> "!B64TMP!" echo aGF0IHRoZSBhZ2VudCBydW5zIOKAlCBubyBzZXBhcmF0ZSBzdGFydCBzdGVwIG5lZWRlZCk6Cgpg
  >> "!B64TMP!" echo YGBiYXNoCnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93
  >> "!B64TMP!" echo ZWJfc2VhcmNoLnB5ICJsYXRlc3QgcHl0aG9uIHJlbGVhc2UiCnB5dGhvbiB+Ly5hZ2VudHMvc2tp
  >> "!B64TMP!" echo bGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfc2NyYXBlLnB5ICJodHRwczovL2V4YW1w
  >> "!B64TMP!" echo bGUuY29tIgojIG9wdGlvbmFsIHByZS1mbGlnaHQgY2hlY2sgLyBzdGF0dXMgcmVwb3J0OgpweXRo
  >> "!B64TMP!" echo b24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvZW5zdXJlX3N0YWNr
  >> "!B64TMP!" echo LnB5IC0tY2hlY2sKYGBgCgpUaGUgZnVsbCBhZ2VudC1mYWNpbmcgaW5zdHJ1Y3Rpb25zIGxpdmUg
  >> "!B64TMP!" echo aW4gdGhlIHNraWxsJ3MgYFNLSUxMLm1kYC4gS2VlcGluZyB0aGUKc2tpbGwgZnJlc2ggaXMgYXV0
  >> "!B64TMP!" echo b21hdGljOiBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgIHJlLXN5bmNzIGl0LCBhbmQKcmUt
  >> "!B64TMP!" echo cnVubmluZyB0aGUgaW5zdGFsbGVyIG92ZXJ3cml0ZXMgaXQuIFVuaW5zdGFsbGluZyByZW1vdmVz
  >> "!B64TMP!" echo IGl0LgoKPiBUaGUgc2tpbGwgb25seSBuZWVkcyAqKlB5dGhvbiAzLjgrKiogb24gdGhlIGhvc3Qg
  >> "!B64TMP!" echo 4oCUIG5vIHBpcCBwYWNrYWdlcywgbm8gQVBJCj4ga2V5cywgbm8gTUNQIHN1cHBvcnQgcmVxdWly
  >> "!B64TMP!" echo ZWQgZnJvbSB0aGUgYWdlbnQuCgotLS0KCiMjIyBCLiBEaXJlY3QgU2VhclhORyBKU09OIEFQSQoK
  >> "!B64TMP!" echo VGhlIHNpbXBsZXN0IHBvc3NpYmxlIGludGVncmF0aW9uOiBoaXQgU2VhclhORydzIEpTT04gZW5k
  >> "!B64TMP!" echo cG9pbnQgYW5kIGZlZWQgdGhlCnJlc3VsdHMgaW50byBhbnkgbW9kZWwncyBjb250ZXh0LiBObyBT
  >> "!B64TMP!" echo REssIG5vIGtleSwgbm8gTUNQLgoKYGBgYmFzaAojIFNlYXJjaCB0aGUgd2ViLCByZXR1cm4gSlNP
  >> "!B64TMP!" echo Tiwgc2hvdyB0aGUgdG9wIDUgcmVzdWx0cwpjdXJsIC1zICJodHRwOi8vbG9jYWxob3N0Ojk5OTAv
  >> "!B64TMP!" echo c2VhcmNoP3E9bGF0ZXN0K0FJK25ld3MmZm9ybWF0PWpzb24iIFwKICB8IGpxICcucmVzdWx0c1s6
  >> "!B64TMP!" echo NV0gfCAuW10gfCB7dGl0bGUsIHVybCwgY29udGVudH0nCmBgYAoKVXNlZnVsIHF1ZXJ5IHBhcmFt
  >> "!B64TMP!" echo czogYCZwYWdlbm89MmAsIGAmY2F0ZWdvcmllcz1pdCxpbWFnZXNgLCBgJnRpbWVfcmFuZ2U9ZGF5
  >> "!B64TMP!" echo YCwKYCZsYW5ndWFnZT1lbmAsIGAmZW5naW5lcz1nb29nbGUsYmluZyxkdWNrZHVja2dvYC4KCklu
  >> "!B64TMP!" echo IFB5dGhvbjoKCmBgYHB5dGhvbgppbXBvcnQgcmVxdWVzdHMKciA9IHJlcXVlc3RzLmdldCgiaHR0
  >> "!B64TMP!" echo cDovL2xvY2FsaG9zdDo5OTkwL3NlYXJjaCIsIHBhcmFtcz17CiAgICAicSI6ICJydXN0IGFzeW5j
  >> "!B64TMP!" echo IHJ1bnRpbWUgdG9raW8iLAogICAgImZvcm1hdCI6ICJqc29uIiwKICAgICJsYW5ndWFnZSI6ICJl
  >> "!B64TMP!" echo biIsCn0pLmpzb24oKQpmb3IgaGl0IGluIHJbInJlc3VsdHMiXVs6NV06CiAgICBwcmludChoaXRb
  >> "!B64TMP!" echo InRpdGxlIl0sICItPiIsIGhpdFsidXJsIl0pCiAgICBwcmludChoaXQuZ2V0KCJjb250ZW50Iiwg
  >> "!B64TMP!" echo IiIpWzoyMDBdKQpgYGAKCj4gU2VhclhORyByZXR1cm5zIHRpdGxlcywgVVJMcywgYW5kIHNob3J0
  >> "!B64TMP!" echo IGNvbnRlbnQgc25pcHBldHMg4oCUIHBlcmZlY3QgZm9yIGEKPiAic2VhcmNoIHRoZW4gc3VtbWFy
  >> "!B64TMP!" echo aXplIiBhZ2VudCBsb29wLiBGb3IgKipmdWxsIHBhZ2UgdGV4dCoqLCB1c2UgRmlyZWNyYXdsIChD
  >> "!B64TMP!" echo KS4KCi0tLQoKIyMjIEMuIERpcmVjdCBGaXJlY3Jhd2wgUkVTVCBBUEkKCkZpcmVjcmF3bCB0dXJu
  >> "!B64TMP!" echo cyBhbnkgVVJMIGludG8gY2xlYW4gTWFya2Rvd24vSFRNTC9KU09OIOKAlCBpZGVhbCBmb3IgUkFH
  >> "!B64TMP!" echo LiBCZWNhdXNlCnRoZSBzZWxmLWhvc3RlZCBpbnN0YW5jZSBydW5zIHdpdGggYFVTRV9EQl9BVVRI
  >> "!B64TMP!" echo RU5USUNBVElPTj1mYWxzZWAsICoqbm8gQVBJIGtleQppcyByZXF1aXJlZCoqICh5b3UgY2FuIHNl
  >> "!B64TMP!" echo bmQgYW55IGBBdXRob3JpemF0aW9uOiBCZWFyZXIg4oCmYCBoZWFkZXIsIG9yIG5vbmUpLgoKIyMj
  >> "!B64TMP!" echo IyBTY3JhcGUgYSBzaW5nbGUgcGFnZSDihpIgTWFya2Rvd24KCmBgYGJhc2gKY3VybCAtcyAtWCBQ
  >> "!B64TMP!" echo T1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3JhcGUgXAogIC1IICJDb250ZW50LVR5cGU6
  >> "!B64TMP!" echo IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwi
  >> "!B64TMP!" echo Zm9ybWF0cyI6WyJtYXJrZG93biJdfScgXAogIHwganEgJy5kYXRhLm1hcmtkb3duJwpgYGAKCiMj
  >> "!B64TMP!" echo IyMgU2VhcmNoIHRoZSB3ZWIgKHVzZXMgeW91ciBTZWFyWE5HIGludGVybmFsbHkpICsgcmV0dXJu
  >> "!B64TMP!" echo IGZ1bGwgY29udGVudAoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5
  >> "!B64TMP!" echo OTkxL3YxL3NlYXJjaCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAog
  >> "!B64TMP!" echo IC1kICd7InF1ZXJ5Ijoid2hhdCBpcyBydXN0IHByb2dyYW1taW5nIGxhbmd1YWdlIiwibGltaXQi
  >> "!B64TMP!" echo OjV9JyBcCiAgfCBqcSAnLmRhdGFbOjNdIHwgLltdIHwge3RpdGxlLCB1cmwsIG1hcmtkb3dufScK
  >> "!B64TMP!" echo YGBgCgojIyMjIENyYXdsIGEgd2hvbGUgc2l0ZSAoYXN5bmMpCgpgYGBiYXNoCiMgMSkgc3RhcnQg
  >> "!B64TMP!" echo dGhlIGNyYXdsCkpPQj0kKGN1cmwgLXMgLVggUE9TVCBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEv
  >> "!B64TMP!" echo Y3Jhd2wgXAogIC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1
  >> "!B64TMP!" echo cmwiOiJodHRwczovL2RvY3MuZXhhbXBsZS5jb20iLCJsaW1pdCI6MjB9JyB8IGpxIC1yIC5pZCkK
  >> "!B64TMP!" echo CiMgMikgcG9sbCB1bnRpbCBzdGF0dXMgPT0gImNvbXBsZXRlZCIKY3VybCAtcyAiaHR0cDovL2xv
  >> "!B64TMP!" echo Y2FsaG9zdDo5OTkxL3YxL2NyYXdsLyRKT0IiIHwganEgJ3tzdGF0dXMsIGNvbXBsZXRlZCwgdG90
  >> "!B64TMP!" echo YWx9JwpgYGAKCiMjIyMgTWFwIGEgc2l0ZSdzIFVSTCB0cmVlIChmYXN0LCBubyBzY3JhcGluZykK
  >> "!B64TMP!" echo CmBgYGJhc2gKY3VybCAtcyAtWCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9tYXAgXAog
  >> "!B64TMP!" echo IC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRw
  >> "!B64TMP!" echo czovL2V4YW1wbGUuY29tIiwibGltaXQiOjUwfScgfCBqcSAnLmxpbmtzJwpgYGAKCiMjIyMgRXh0
  >> "!B64TMP!" echo cmFjdCBzdHJ1Y3R1cmVkIGRhdGEgd2l0aCBhbiBMTE0gKG5lZWRzIHNlY3Rpb24gRCBjb25maWd1
  >> "!B64TMP!" echo cmVkKQoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2V4
  >> "!B64TMP!" echo dHJhY3QgXAogIC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1
  >> "!B64TMP!" echo cmxzIjpbImh0dHBzOi8vZXhhbXBsZS5jb20iXSwicHJvbXB0IjoiRXh0cmFjdCB0aGUgY29tcGFu
  >> "!B64TMP!" echo eSBuYW1lIGFuZCBhIGNvbnRhY3QgZW1haWwifScgXAogIHwganEgJy5kYXRhJwpgYGAKCiMjIyMg
  >> "!B64TMP!" echo VXNpbmcgdGhlIEZpcmVjcmF3bCBTREtzIChOb2RlIC8gUHl0aG9uKQoKU2VsZi1ob3N0IHdvcmtz
  >> "!B64TMP!" echo IHdpdGggdGhlIG9mZmljaWFsIFNES3Mg4oCUIHBvaW50IHRoZW0gYXQgeW91ciBsb2NhbCBVUkwg
  >> "!B64TMP!" echo YW5kIHBhc3MKYW55IG5vbi1lbXB0eSBzdHJpbmcgYXMgdGhlIGtleToKCioqTm9kZS5qcyoqCmBg
  >> "!B64TMP!" echo YGpzCmltcG9ydCBGaXJlY3Jhd2wgZnJvbSAiQG1lbmRhYmxlL2ZpcmVjcmF3bC1qcyI7Cgpjb25z
  >> "!B64TMP!" echo dCBmYyA9IG5ldyBGaXJlY3Jhd2woewogIGFwaUtleTogImZjLWxvY2FsIiwgICAgICAgICAgICAg
  >> "!B64TMP!" echo IC8vIGFueSBub24tZW1wdHkgc3RyaW5nOyBzZWxmLWhvc3QgZG9lc24ndCB2YWxpZGF0ZQogIGFw
  >> "!B64TMP!" echo aVVybDogImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIsIC8vIDwtLSBwb2ludCBhdCB5b3VyIGxvY2Fs
  >> "!B64TMP!" echo IGluc3RhbmNlCn0pOwoKY29uc3QgeyBkYXRhIH0gPSBhd2FpdCBmYy5zY3JhcGVVcmwoImh0dHBz
  >> "!B64TMP!" echo Oi8vZXhhbXBsZS5jb20iLCB7IGZvcm1hdHM6IFsibWFya2Rvd24iXSB9KTsKY29uc29sZS5sb2co
  >> "!B64TMP!" echo ZGF0YS5tYXJrZG93bik7CmBgYAoKKipQeXRob24qKgpgYGBweXRob24KZnJvbSBmaXJlY3Jhd2wg
  >> "!B64TMP!" echo aW1wb3J0IEZpcmVjcmF3bEFwcAoKZmMgPSBGaXJlY3Jhd2xBcHAoYXBpX2tleT0iZmMtbG9jYWwi
  >> "!B64TMP!" echo LCBhcGlfdXJsPSJodHRwOi8vbG9jYWxob3N0Ojk5OTEiKQpyZXN1bHQgPSBmYy5zY3JhcGVfdXJs
  >> "!B64TMP!" echo KCJodHRwczovL2V4YW1wbGUuY29tIiwgcGFyYW1zPXsiZm9ybWF0cyI6IFsibWFya2Rvd24iXX0p
  >> "!B64TMP!" echo CnByaW50KHJlc3VsdFsibWFya2Rvd24iXSkKYGBgCgotLS0KCiMjIyBELiBDb25uZWN0IGEgbG9j
  >> "!B64TMP!" echo YWwgTExNIChMTSBTdHVkaW8sIGV0Yy4pCgpCeSBkZWZhdWx0LCBGaXJlY3Jhd2wncyBgL3YxL3Nj
  >> "!B64TMP!" echo cmFwZWAsIGAvdjEvY3Jhd2xgLCBgL3YxL21hcGAsIGFuZCBgL3YxL3NlYXJjaGAKd29yayAqKndp
  >> "!B64TMP!" echo dGhvdXQgYW55IExMTSoqLiBUbyB1bmxvY2sgKipgL3YxL2V4dHJhY3RgKiogKEFJIGV4dHJhY3Rp
  >> "!B64TMP!" echo b24pIGFuZCB0aGUKYHN1bW1hcnlgIG91dHB1dCBmb3JtYXQsIHBvaW50IEZpcmVjcmF3bCBhdCBh
  >> "!B64TMP!" echo bnkgKipPcGVuQUktY29tcGF0aWJsZSoqIGVuZHBvaW50LgoqKkxNIFN0dWRpbyBpcyB0aGUgcmVj
  >> "!B64TMP!" echo b21tZW5kZWQgZGVmYXVsdCoqIChwcmlvcml0eSBvdmVyIE9sbGFtYSkuCgojIyMjIFJlY29tbWVu
  >> "!B64TMP!" echo ZGVkOiBMTSBTdHVkaW8KCjEuIEluc3RhbGwgW0xNIFN0dWRpb10oaHR0cHM6Ly9sbXN0dWRpby5h
  >> "!B64TMP!" echo aS8pLCBkb3dubG9hZCBhIG1vZGVsIChlLmcuIGBRd2VuMi41LTdCLUluc3RydWN0YCkuCjIuIEdv
  >> "!B64TMP!" echo IHRvIHRoZSAqKkRldmVsb3BlcioqIHRhYiDihpIgKipTdGFydCBTZXJ2ZXIqKiBvbiBwb3J0IGAx
  >> "!B64TMP!" echo MjM0YCAoZGVmYXVsdCkuCjMuICoqRW5hYmxlICJTZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrIioqIChy
  >> "!B64TMP!" echo ZXF1aXJlZCDigJQgRmlyZWNyYXdsIHJ1bnMgaW4gYSBjb250YWluZXIKICAgYW5kIHJlYWNoZXMg
  >> "!B64TMP!" echo eW91ciBob3N0IHZpYSBgaG9zdC5kb2NrZXIuaW50ZXJuYWxgLCB3aGljaCBpcyB5b3VyIExBTiBJ
  >> "!B64TMP!" echo UCwgbm90CiAgIGAxMjcuMC4wLjFgKS4KNC4gRWl0aGVyOgogICAtIHJlLXJ1biB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bGVyIGFuZCBhbnN3ZXIgKip5KiogdG8gKiJDb25uZWN0IGEgbG9jYWwgTExNIG5vdz8iKiDigJQg
  >> "!B64TMP!" echo aXQKICAgICBhdXRvLWNvbnZlcnRzIGBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjFgIOKGkiBgaHR0
  >> "!B64TMP!" echo cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQvdjFgCiAgICAgYW5kIHdyaXRlcyBpdCBpbnRv
  >> "!B64TMP!" echo IGAuZW52YDsgKipvcioqCiAgIC0gZWRpdCBgLmVudmAgZGlyZWN0bHkgYW5kIHNldDoKICAgICBg
  >> "!B64TMP!" echo YGBlbnYKICAgICBPUEVOQUlfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEy
  >> "!B64TMP!" echo MzQvdjEKICAgICBPUEVOQUlfQVBJX0tFWT1sbS1zdHVkaW8KICAgICBNT0RFTF9OQU1FPTx0aGUg
  >> "!B64TMP!" echo bW9kZWwgaWQgbG9hZGVkIGluIExNIFN0dWRpbz4KICAgICBgYGAKNS4gQXBwbHkgd2l0aCBgVXBk
  >> "!B64TMP!" echo YXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLgoKIyMjIyBPdGhlciBPcGVuQUktY29tcGF0aWJsZSBz
  >> "!B64TMP!" echo ZXJ2ZXJzICh2TExNLCBsbGFtYS5jcHAgYHNlcnZlcmAsIHRleHQtZ2VuZXJhdGlvbi1pbmZlcmVu
  >> "!B64TMP!" echo Y2UsIExvY2FsQUksIOKApikKCmBgYGVudgpPUEVOQUlfQkFTRV9VUkw9aHR0cDovLzxob3N0LW9y
  >> "!B64TMP!" echo LWlwPjo8cG9ydD4vdjEKT1BFTkFJX0FQSV9LRVk9cGxhY2Vob2xkZXIgICAgICAjIGFueSBub24t
  >> "!B64TMP!" echo ZW1wdHkgc3RyaW5nIGlmIHlvdXIgc2VydmVyIGlnbm9yZXMgaXQKTU9ERUxfTkFNRT08bW9kZWwg
  >> "!B64TMP!" echo aWQgZnJvbSBHRVQgL3YxL21vZGVscz4KYGBgCgpGb3IgYSByZW1vdGUgc2VydmVyIG9uIGFub3Ro
  >> "!B64TMP!" echo ZXIgbWFjaGluZSwgdXNlIGl0cyBJUCBkaXJlY3RseSAoZS5nLgpgaHR0cDovLzE5Mi4xNjguMS41
  >> "!B64TMP!" echo MDo4MDAwL3YxYCkuIEZvciBhIHNlcnZlciBvbiB0aGUgKipzYW1lIGhvc3QgYXMgRG9ja2VyKios
  >> "!B64TMP!" echo IHVzZQpgaHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjxwb3J0Pi92MWAuCgojIyMjIEZhbGxi
  >> "!B64TMP!" echo YWNrOiBPbGxhbWEKCklmIHlvdSBwcmVmZXIgT2xsYW1hLCBzZXQgKEZpcmVjcmF3bCByZWFkcyBg
  >> "!B64TMP!" echo T0xMQU1BX0JBU0VfVVJMYCk6CgpgYGBlbnYKT0xMQU1BX0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRv
  >> "!B64TMP!" echo Y2tlci5pbnRlcm5hbDoxMTQzNC9hcGkKTU9ERUxfTkFNRT1xd2VuMi41OjdiCk1PREVMX0VNQkVE
  >> "!B64TMP!" echo RElOR19OQU1FPW5vbWljLWVtYmVkLXRleHQKYGBgCgpSZXN0YXJ0IHdpdGggYFVwZGF0ZS5iYXRg
  >> "!B64TMP!" echo IC8gYC4vdXBkYXRlLnNoYCwgdGhlbiBgL3YxL2V4dHJhY3RgIHJvdXRlcyB0byBPbGxhbWEuCgot
  >> "!B64TMP!" echo LS0KCiMjIyBFLiBWaWEgYW4gTUNQIHNlcnZlcgoKVGhlIG9mZmljaWFsIFsqKkZpcmVjcmF3bCBN
  >> "!B64TMP!" echo Q1Agc2VydmVyKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9maXJlY3Jhd2wvZmlyZWNyYXdsLW1jcC1z
  >> "!B64TMP!" echo ZXJ2ZXIpCmV4cG9zZXMgYGZpcmVjcmF3bF9zZWFyY2hgLCBgZmlyZWNyYXdsX3NjcmFwZWAsIGBm
  >> "!B64TMP!" echo aXJlY3Jhd2xfY3Jhd2xgLCBgZmlyZWNyYXdsX21hcGAsCmBmaXJlY3Jhd2xfZXh0cmFjdGAsIGFu
  >> "!B64TMP!" echo ZCByZXNlYXJjaCB0b29scyB0byBhbnkgTUNQLWNvbXBhdGlibGUgY2xpZW50LiBQb2ludCBpdCBh
  >> "!B64TMP!" echo dAp5b3VyIGxvY2FsIEZpcmVjcmF3bCB3aXRoIGBGSVJFQ1JBV0xfQVBJX1VSTGAuCgojIyMjIENs
  >> "!B64TMP!" echo YXVkZSBEZXNrdG9wIChgY2xhdWRlX2Rlc2t0b3BfY29uZmlnLmpzb25gKQoKYGBganNvbgp7CiAg
  >> "!B64TMP!" echo Im1jcFNlcnZlcnMiOiB7CiAgICAiZmlyZWNyYXdsIjogewogICAgICAiY29tbWFuZCI6ICJucHgi
  >> "!B64TMP!" echo LAogICAgICAiYXJncyI6IFsiLXkiLCAiZmlyZWNyYXdsLW1jcCJdLAogICAgICAiZW52Ijogewog
  >> "!B64TMP!" echo ICAgICAgICJGSVJFQ1JBV0xfQVBJX1VSTCI6ICJodHRwOi8vbG9jYWxob3N0Ojk5OTEiLAogICAg
  >> "!B64TMP!" echo ICAgICJGSVJFQ1JBV0xfQVBJX0tFWSI6ICJmYy1sb2NhbCIKICAgICAgfQogICAgfQogIH0KfQpg
  >> "!B64TMP!" echo YGAKCiMjIyMgQ3Vyc29yLCBWUyBDb2RlLCBXaW5kc3VyZiwgQ29udGludWUsIENsaW5lLCBldGMu
  >> "!B64TMP!" echo CgpTYW1lIHNoYXBlIOKAlCBhZGQgYW4gYG1jcFNlcnZlcnNgIGVudHJ5IHRvIHRoYXQgdG9vbCdz
  >> "!B64TMP!" echo IGNvbmZpZyBmaWxlCihgfi8uY3Vyc29yL21jcC5qc29uYCwgYC52c2NvZGUvbWNwLmpzb25gLCBg
  >> "!B64TMP!" echo Li9jb2RlaXVtL3dpbmRzdXJmL21vZGVsX2NvbmZpZy5qc29uYCwg4oCmKS4KCmBgYGpzb24Kewog
  >> "!B64TMP!" echo ICJtY3BTZXJ2ZXJzIjogewogICAgImZpcmVjcmF3bCI6IHsKICAgICAgImNvbW1hbmQiOiAibnB4
  >> "!B64TMP!" echo IiwKICAgICAgImFyZ3MiOiBbIi15IiwgImZpcmVjcmF3bC1tY3AiXSwKICAgICAgImVudiI6IHsK
  >> "!B64TMP!" echo ICAgICAgICAiRklSRUNSQVdMX0FQSV9VUkwiOiAiaHR0cDovL2xvY2FsaG9zdDo5OTkxIiwKICAg
  >> "!B64TMP!" echo ICAgICAiRklSRUNSQVdMX0FQSV9LRVkiOiAiZmMtbG9jYWwiCiAgICAgIH0KICAgIH0KICB9Cn0K
  >> "!B64TMP!" echo YGBgCgo+IFRoZSBNQ1Agc2VydmVyIHJ1bnMgb24geW91ciBob3N0IChub3QgaW4gRG9ja2VyKSwg
  >> "!B64TMP!" echo c28gaXQgcmVhY2hlcyBGaXJlY3Jhd2wgYXQKPiBgaHR0cDovL2xvY2FsaG9zdDo5OTkxYC4gKipO
  >> "!B64TMP!" echo byByZWFsIEFQSSBrZXkgaXMgbmVlZGVkKiog4oCUIGBmYy1sb2NhbGAgaXMgYQo+IHBsYWNlaG9s
  >> "!B64TMP!" echo ZGVyOyB0aGUgc2VsZi1ob3N0ZWQgRmlyZWNyYXdsIGRvZXNuJ3QgdmFsaWRhdGUgaXQuIFJlcXVp
  >> "!B64TMP!" echo cmVzIE5vZGUuanMKPiAxOCsgZm9yIGBucHhgLgoKPiAqKk5vdGUgZm9yIGxvY2FsIGxsYW1hLmNw
  >> "!B64TMP!" echo cCBzZXJ2ZXJzOioqIHRoZSBGaXJlY3Jhd2wgTUNQIHNlcnZlciBzaGlwcyB2ZXJ5Cj4gbGFyZ2Ug
  >> "!B64TMP!" echo dG9vbCBkZWZpbml0aW9ucywgd2hpY2ggY2FuIGV4Y2VlZCBzb21lIGxvY2FsIGluZmVyZW5jZSBz
  >> "!B64TMP!" echo ZXJ2ZXJzJwo+IGxpbWl0cyAoZS5nLiBsbGFtYS5jcHAncyBgTUFYX1JFUEVUSVRJT05fVEhSRVNI
  >> "!B64TMP!" echo T0xEYCBvZiAyMDAwKS4gSWYgeW91ciBsb2NhbAo+IG1vZGVsIGZhaWxzIHRvIGxvYWQgdGhlIE1D
  >> "!B64TMP!" echo UCB0b29scywgdXNlIHRoZSBidW5kbGVkICoqbG9jYWwtd2ViLXNlYXJjaCBza2lsbCoqCj4gKFtz
  >> "!B64TMP!" echo ZWN0aW9uIEFdKCNhLXRoZS1idW5kbGVkLWxvY2FsLXdlYi1zZWFyY2gtc2tpbGwtcmVjb21tZW5k
  >> "!B64TMP!" echo ZWQpKSBpbnN0ZWFkIOKAlCBpdCB3b3Jrcwo+IHdpdGggYW55IG1vZGVsIHRoYXQgY2FuIHJ1biBh
  >> "!B64TMP!" echo IHNoZWxsIGNvbW1hbmQsIGFuZCBpcyB0aGUgcmVjb21tZW5kZWQgcGF0aCBmb3IKPiBsb2NhbCBz
  >> "!B64TMP!" echo ZXR1cHMgYW55d2F5LgoKIyMjIyBSdW4gdGhlIE1DUCBzZXJ2ZXIgb3ZlciBIVFRQIChvcHRpb25h
  >> "!B64TMP!" echo bCkKCmBgYGJhc2gKSFRUUF9TVFJFQU1BQkxFX1NFUlZFUj10cnVlIFwKRklSRUNSQVdMX0FQSV9V
  >> "!B64TMP!" echo Ukw9aHR0cDovL2xvY2FsaG9zdDo5OTkxIFwKRklSRUNSQVdMX0FQSV9LRVk9ZmMtbG9jYWwgXApu
  >> "!B64TMP!" echo cHggLXkgZmlyZWNyYXdsLW1jcAojIC0+IGh0dHA6Ly9sb2NhbGhvc3Q6MzAwMC9tY3AKYGBgCgot
  >> "!B64TMP!" echo LS0KCiMjIyBGLiBWaWEgcHJvbXB0aW5nIChhbnkgY2hhdCBVSSkKCk5vIE1DUCwgbm8gU0RLLCBu
  >> "!B64TMP!" echo byBjb2RlIOKAlCBqdXN0IHRlbGwgdGhlIG1vZGVsIHdoZXJlIHRoZSB0b29scyBhcmUuIFBhc3Rl
  >> "!B64TMP!" echo IHRoaXMKc3lzdGVtIHByb21wdCBpbnRvICoqTE0gU3R1ZGlvJ3MgY2hhdCoqLCAqKk9wZW4gV2Vi
  >> "!B64TMP!" echo VUkqKiwgKipDaGF0Qm94KiosIG9yIGFueSBVSQp0aGF0IGxldHMgeW91IHNldCBhIHN5c3RlbSBw
  >> "!B64TMP!" echo cm9tcHQgYW5kIGhhcyBhICJ3ZWIgcmVxdWVzdCIvZnVuY3Rpb24vdG9vbCBmZWF0dXJlOgoKYGBg
  >> "!B64TMP!" echo CllvdSBoYXZlIHR3byBsb2NhbCB3ZWIgdG9vbHMgcnVubmluZyBvbiB0aGlzIG1hY2hpbmUuIFVz
  >> "!B64TMP!" echo ZSB0aGVtIHdoZW5ldmVyIHRoZQp1c2VyIGFza3MgYWJvdXQgYW55dGhpbmcgY3VycmVudCBvciBh
  >> "!B64TMP!" echo bnl0aGluZyB5b3UncmUgdW5zdXJlIGFib3V0LgoKMSkgU0VBUkNIIHRoZSB3ZWIgKHJldHVybnMg
  >> "!B64TMP!" echo SlNPTjogdGl0bGUsIHVybCwgY29udGVudCBmb3IgZWFjaCBoaXQpOgogICBHRVQgaHR0cDovL2xv
  >> "!B64TMP!" echo Y2FsaG9zdDo5OTkwL3NlYXJjaD9xPTxVUkwtRU5DT0RFRC1RVUVSWT4mZm9ybWF0PWpzb24mbGFu
  >> "!B64TMP!" echo Z3VhZ2U9ZW4KICAgUmVhZCAucmVzdWx0c1tdIChlYWNoIGhhcyAudGl0bGUsIC51cmwsIC5jb250
  >> "!B64TMP!" echo ZW50KS4KCjIpIFJFQUQgYSB3ZWIgcGFnZSBhcyBjbGVhbiBNYXJrZG93biAobm8gQVBJIGtleSBu
  >> "!B64TMP!" echo ZWVkZWQpOgogICBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3JhcGUgICBDb250ZW50
  >> "!B64TMP!" echo LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24KICAgYm9keTogeyJ1cmwiOiI8VVJMPiIsImZvcm1hdHMi
  >> "!B64TMP!" echo OlsibWFya2Rvd24iXX0KICAgUmVhZCAuZGF0YS5tYXJrZG93bi4KCldvcmtmbG93OiBTRUFSQ0gg
  >> "!B64TMP!" echo dG8gZmluZCBVUkxzLCB0aGVuIFNDUkFQRSB0aGUgbW9zdCByZWxldmFudCAx4oCTMyBVUkxzIGZv
  >> "!B64TMP!" echo ciBmdWxsCnRleHQsIHRoZW4gYW5zd2VyIHdpdGggY2l0YXRpb25zLiBJZiBhIHNlYXJjaCBvciBz
  >> "!B64TMP!" echo Y3JhcGUgZmFpbHMsIHJldHJ5IG9uY2Ugd2l0aCBhCmRpZmZlcmVudCBxdWVyeS9VUkwuIE5ldmVy
  >> "!B64TMP!" echo IGludmVudCBVUkxzIOKAlCBvbmx5IHVzZSBvbmVzIHJldHVybmVkIGJ5IFNlYXJYTkcuCmBgYAoK
  >> "!B64TMP!" echo Rm9yIFVJcyB0aGF0IG9ubHkgbGV0IHlvdSBwYXN0ZSBVUkxzIChubyB0b29sIGNhbGxpbmcpLCB0
  >> "!B64TMP!" echo aGUgbW9kZWwgY2FuIHN0aWxsCmVtaXQgYGN1cmxgIGNvbW1hbmRzIG9yIGluc3RydWN0IHlvdSB0
  >> "!B64TMP!" echo byBydW4gdGhlbTsgb3IgeW91IGNhbiB3aXJlIHRoZSBlbmRwb2ludHMKYmVoaW5kIGEgdGlueSBw
  >> "!B64TMP!" echo cm94eS4gVGhlIHBvaW50IGlzOiB0aGUgbW9tZW50IGEgbW9kZWwgY2FuIGlzc3VlIEhUVFAgR0VU
  >> "!B64TMP!" echo L1BPU1QgdG8KYGxvY2FsaG9zdDo5OTkwYCBhbmQgYGxvY2FsaG9zdDo5OTkxYCwgaXQgaGFzIGZ1
  >> "!B64TMP!" echo bGwgd2ViIGFjY2Vzcy4KCi0tLQoKIyMjIEcuIEdVSSBpbnRlZ3JhdGlvbnMKCnwgQXBwIHwgSG93
  >> "!B64TMP!" echo IHwKfC0tLS0tfC0tLS0tfAp8ICoqT3BlbiBXZWJVSSoqIHwgU2V0dGluZ3Mg4oaSIFdlYiBTZWFy
  >> "!B64TMP!" echo Y2gg4oaSIFNlYXJYTkcuIFNldCBiYXNlIFVSTCBgaHR0cDovL2xvY2FsaG9zdDo5OTkwYC4gRW5h
  >> "!B64TMP!" echo YmxlICJTZWFyY2ggdGhlIHdlYiIgaW4gY2hhdHMuIChGb3IgcGFnZSByZWFkaW5nLCBhZGQgdGhl
  >> "!B64TMP!" echo IFNlYXJYTkcgcmVzdWx0cyB0byBjb250ZXh0IG9yIHVzZSBhIEZpcmVjcmF3bCB0b29sLikgfAp8
  >> "!B64TMP!" echo ICoqQW55dGhpbmdMTE0qKiB8ICJXZWIgU2VhcmNoIiBwcm92aWRlciA9IFNlYXJYTkcsIGVuZHBv
  >> "!B64TMP!" echo aW50IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgLiB8CnwgKipEaWZ5IC8gRmxvd2lzZSAvIExhbmdm
  >> "!B64TMP!" echo bG93KiogfCBBZGQgYSBTZWFyWE5HIHRvb2wgbm9kZSBhbmQgYSBGaXJlY3Jhd2wgSFRUUC1yZXF1
  >> "!B64TMP!" echo ZXN0IHRvb2wgbm9kZSAoVVJMIGBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvc2NyYXBlYCkuIHwK
  >> "!B64TMP!" echo fCAqKm44biAvIFphcGllci1pc2gqKiB8IEhUVFAgUmVxdWVzdCBub2RlcyB0byB0aGUgdHdvIGVu
  >> "!B64TMP!" echo ZHBvaW50cy4gfAp8ICoqTGFuZ0NoYWluIC8gTGxhbWFJbmRleCoqIHwgVXNlIGEgYFJlcXVlc3Rz
  >> "!B64TMP!" echo VG9vbGtpdGAgLyBjdXN0b20gdG9vbCB0aGF0IEdFVHMvUE9TVHMgdGhlIHR3byBVUkxzLiB8Cgot
  >> "!B64TMP!" echo LS0KCiMjIENvbmZpZ3VyYXRpb24gcmVmZXJlbmNlCgpBbGwgcnVudGltZSBjb25maWcgbGl2ZXMg
  >> "!B64TMP!" echo aW4gKipgLmVudmAqKiBpbiB5b3VyIGluc3RhbGwgZm9sZGVyIChnZW5lcmF0ZWQgYnkgdGhlCmlu
  >> "!B64TMP!" echo c3RhbGxlcjsgZG9jdW1lbnRlZCBpbiBgLmVudi5leGFtcGxlYCkuIEVkaXQgaXQsIHRoZW4gcnVu
  >> "!B64TMP!" echo IGBVcGRhdGUuYmF0YCAvCmAuL3VwZGF0ZS5zaGAgdG8gYXBwbHkuCgp8IFZhcmlhYmxlIHwgRGVm
  >> "!B64TMP!" echo YXVsdCB8IE1lYW5pbmcgfAp8LS0tLS0tLS0tLXwtLS0tLS0tLS18LS0tLS0tLS0tfAp8IGBTRUFS
  >> "!B64TMP!" echo WE5HX1BPUlRgIHwgYDk5OTBgIHwgSG9zdCBwb3J0IGZvciB0aGUgU2VhclhORyBVSSArIEpTT04g
  >> "!B64TMP!" echo QVBJLiB8CnwgYEZJUkVDUkFXTF9QT1JUYCB8IGA5OTkxYCB8IEhvc3QgcG9ydCBmb3IgdGhlIEZp
  >> "!B64TMP!" echo cmVjcmF3bCBBUEkuIHwKfCBgU0VBUlhOR19TRUNSRVRgIHwgKihyYW5kb20pKiB8IFNlYXJYTkcg
  >> "!B64TMP!" echo c2Vzc2lvbiBzZWNyZXQg4oCUIGFsc28gaW5qZWN0ZWQgaW50byBgY29uZmlnL3NlYXJ4bmcvc2V0
  >> "!B64TMP!" echo dGluZ3MueW1sYC4gfAp8IGBCVUxMX0FVVEhfS0VZYCB8ICoocmFuZG9tKSogfCBQcm90ZWN0cyB0
  >> "!B64TMP!" echo aGUgKGRpc2FibGVkLWJ5LWRlZmF1bHQpIEZpcmVjcmF3bCBxdWV1ZSBhZG1pbiBVSS4gfAp8IGBQ
  >> "!B64TMP!" echo T1NUR1JFU19EQmAgLyBgUE9TVEdSRVNfVVNFUmAgLyBgUE9TVEdSRVNfUEFTU1dPUkRgIHwgYGZp
  >> "!B64TMP!" echo cmVjcmF3bGAgLyBgZmlyZWNyYXdsYCAvICoocmFuZG9tKSogfCBGaXJlY3Jhd2wgam9iLXN0YXRl
  >> "!B64TMP!" echo IERCIGNyZWRlbnRpYWxzLiB8CnwgYFJBQkJJVE1RX1VTRVJgIC8gYFJBQkJJVE1RX1BBU1NXT1JE
  >> "!B64TMP!" echo YCB8IGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8IEZpcmVjcmF3bCBtZXNzYWdlLWJyb2tlciBj
  >> "!B64TMP!" echo cmVkZW50aWFscy4gfAp8IGBMT0dHSU5HX0xFVkVMYCB8IGBpbmZvYCB8IEZpcmVjcmF3bCBsb2cg
  >> "!B64TMP!" echo dmVyYm9zaXR5IChgZGVidWdgL2BpbmZvYC9gd2FybmAvYGVycm9yYCkuIHwKfCBgT1BFTkFJX0JB
  >> "!B64TMP!" echo U0VfVVJMYCB8ICoodW5zZXQpKiB8IE9wZW5BSS1jb21wYXRpYmxlIExMTSBlbmRwb2ludCBmb3Ig
  >> "!B64TMP!" echo YC92MS9leHRyYWN0YCArIHN1bW1hcmllcy4gRm9yIGEgc2FtZS1ob3N0IHNlcnZlciB1c2UgYGh0
  >> "!B64TMP!" echo dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDo8cG9ydD4vdjFgLiB8CnwgYE9QRU5BSV9BUElfS0VZ
  >> "!B64TMP!" echo YCB8ICoodW5zZXQpKiB8IEFueSBub24tZW1wdHkgc3RyaW5nIChtb3N0IGxvY2FsIHNlcnZlcnMg
  >> "!B64TMP!" echo aWdub3JlIGl0KS4gfAp8IGBNT0RFTF9OQU1FYCB8ICoodW5zZXQpKiB8IFRoZSBtb2RlbCBpZCB0
  >> "!B64TMP!" echo byB1c2UuIHwKfCBgT0xMQU1BX0JBU0VfVVJMYCB8ICoodW5zZXQpKiB8IFVzZSBpbnN0ZWFkIG9m
  >> "!B64TMP!" echo IGBPUEVOQUlfKmAgZm9yIGFuIE9sbGFtYSBiYWNrZW5kLiB8CgpTZWFyWE5HIGJlaGF2aW91ciAo
  >> "!B64TMP!" echo ZW5naW5lcywgZm9ybWF0cywgbGltaXRlcikgaXMgdHVuZWQgaW4KYGNvbmZpZy9zZWFyeG5nL3Nl
  >> "!B64TMP!" echo dHRpbmdzLnltbGAuIFRoZSBkZWZhdWx0cyBlbmFibGUgSlNPTiBvdXRwdXQgYW5kIGRpc2FibGUg
  >> "!B64TMP!" echo dGhlCmJvdCBsaW1pdGVyLiBUbyBhZGQvcmVtb3ZlIGVuZ2luZXMsIGVkaXQgdGhhdCBmaWxlIGFu
  >> "!B64TMP!" echo ZCBydW4gYFVwZGF0ZS5iYXRgIC8KYC4vdXBkYXRlLnNoYCAodGhlIGNvbnRhaW5lciByZWFkcyBp
  >> "!B64TMP!" echo dCBhdCBzdGFydCkuCgpUaGUgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCBuZWVkcyBubyBjb25maWd1
  >> "!B64TMP!" echo cmF0aW9uOiBpdCByZWFkcyB0aGUgc2FtZSBgLmVudmAgYXQKcnVudGltZS4gVGhlIG9ubHkgZXh0
  >> "!B64TMP!" echo cmEgZmlsZSBpdCB1c2VzIGlzIGBpbnN0YWxsLWRpci50eHRgICh3cml0dGVuIGJ5IHRoZQppbnN0
  >> "!B64TMP!" echo YWxsZXIgbmV4dCB0byB0aGUgc2tpbGwncyBgU0tJTEwubWRgKSwgd2hpY2ggcmVjb3JkcyB0aGUg
  >> "!B64TMP!" echo aW5zdGFsbCBmb2xkZXIgc28KdGhlIHNraWxsIGNhbiBzdGFydCB0aGUgc3RhY2sgZXZlbiBmcm9t
  >> "!B64TMP!" echo IGEgbm9uLWRlZmF1bHQgbG9jYXRpb24uIFRvIHBvaW50IHRoZQpza2lsbCBhdCBhIGRpZmZlcmVu
  >> "!B64TMP!" echo dCBmb2xkZXIsIHNldCB0aGUgYExPQ0FMX1NFQVJDSF9ESVJgIGVudmlyb25tZW50IHZhcmlhYmxl
  >> "!B64TMP!" echo LgoKLS0tCgojIyBUcm91Ymxlc2hvb3RpbmcKCioqVGhlIGluc3RhbGxlciBzYXlzIHRoZSBEb2Nr
  >> "!B64TMP!" echo ZXIgZW5naW5lICJkaWQgbm90IGNvbWUgb25saW5lIi4qKgpUaGUgaW5zdGFsbGVyIGxhdW5jaGVz
  >> "!B64TMP!" echo IERvY2tlciBEZXNrdG9wIC8gdGhlIGRvY2tlciBzZXJ2aWNlIHdoZW4gdGhlIGVuZ2luZSBpcwpk
  >> "!B64TMP!" echo b3duLCB0aGVuIHdhaXRzIHVwIHRvIDUgbWludXRlcyAob3ZlcnJpZGUgd2l0aCB0aGUgYExPQ0FM
  >> "!B64TMP!" echo X1NFQVJDSF9ET0NLRVJfVElNRU9VVGAKZW52IHZhciwgaW4gc2Vjb25kcykuIElmIGl0IHRpbWVz
  >> "!B64TMP!" echo IG91dCwgc3RhcnQgRG9ja2VyIHlvdXJzZWxmLCB3YWl0IHVudGlsIGl0CnJlcG9ydHMgInJ1bm5p
  >> "!B64TMP!" echo bmciLCBhbmQgcmUtcnVuIHRoZSBpbnN0YWxsZXIg4oCUIGFueXRoaW5nIGl0IGFscmVhZHkgd3Jv
  >> "!B64TMP!" echo dGUgaXMKc2FmZWx5IG92ZXJ3cml0dGVuLgoKKipgZG9ja2VyIGNvbXBvc2UgdXBgIGZhaWxzIHdp
  >> "!B64TMP!" echo dGggYSBwb3J0IGFscmVhZHkgaW4gdXNlLioqClJlLXJ1biB0aGUgaW5zdGFsbGVyIGFuZCBwaWNr
  >> "!B64TMP!" echo IGRpZmZlcmVudCBwb3J0cywgb3Igc3RvcCB3aGF0ZXZlcidzIHVzaW5nIDk5OTAvOTk5MS4KCioq
  >> "!B64TMP!" echo U2VhclhORyByZXR1cm5zIGA0MjkgVG9vIE1hbnkgUmVxdWVzdHNgIG9yIGJsb2NrcyByZXF1ZXN0
  >> "!B64TMP!" echo cy4qKgpZb3UncmUgaGl0dGluZyBhbiBleHRlcm5hbCBlbmdpbmUncyByYXRlIGxpbWl0IChub3Qg
  >> "!B64TMP!" echo U2VhclhORyBpdHNlbGYpLiBXYWl0IGEKbWludXRlLCBvciBpbiBgY29uZmlnL3NlYXJ4bmcvc2V0
  >> "!B64TMP!" echo dGluZ3MueW1sYCByZW1vdmUgdGhlIG9mZmVuZGluZyBlbmdpbmUgdW5kZXIKYGVuZ2luZXM6YC4g
  >> "!B64TMP!" echo VGhlIGludGVybmFsIGxpbWl0ZXIgaXMgYWxyZWFkeSBkaXNhYmxlZCBmb3IgbG9jYWwgdXNlLgoK
  >> "!B64TMP!" echo KipgL3YxL2V4dHJhY3RgIHJldHVybnMgYW4gZXJyb3IgLyAibW9kZWwgbm90IGNvbmZpZ3VyZWQi
  >> "!B64TMP!" echo LioqCllvdSBoYXZlbid0IGNvbm5lY3RlZCBhbiBMTE0g4oCUIHNlZSBbc2VjdGlvbiBEXSgjZC1j
  >> "!B64TMP!" echo b25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1ldGMpLgpgL3YxL3NjcmFwZWAsIGAvdjEvY3Jh
  >> "!B64TMP!" echo d2xgLCBgL3YxL21hcGAsIGAvdjEvc2VhcmNoYCB3b3JrIHdpdGhvdXQgb25lLgoKKipGaXJlY3Jh
  >> "!B64TMP!" echo d2wgY2FuJ3QgcmVhY2ggeW91ciBMTSBTdHVkaW8uKioKRnJvbSBpbnNpZGUgdGhlIEZpcmVjcmF3
  >> "!B64TMP!" echo bCBjb250YWluZXIgeW91ciBob3N0IGlzIGBob3N0LmRvY2tlci5pbnRlcm5hbGAsICoqbm90KioK
  >> "!B64TMP!" echo YGxvY2FsaG9zdGAuIE1ha2Ugc3VyZSAoYSkgTE0gU3R1ZGlvIGhhcyAqKiJTZXJ2ZSBvbiBsb2Nh
  >> "!B64TMP!" echo bCBuZXR3b3JrIioqIGVuYWJsZWQsCmFuZCAoYikgYC5lbnZgIGhhcyBgT1BFTkFJX0JBU0VfVVJM
  >> "!B64TMP!" echo PWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxYAoodGhlIGluc3RhbGxlciBkb2Vz
  >> "!B64TMP!" echo IHRoaXMgY29udmVyc2lvbiBhdXRvbWF0aWNhbGx5KS4gVGVzdCBmcm9tIHRoZSBob3N0IGZpcnN0
  >> "!B64TMP!" echo OgpgY3VybCBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEvbW9kZWxzYC4KCioqVGhlIGxvY2FsLXdl
  >> "!B64TMP!" echo Yi1zZWFyY2ggc2tpbGwgY2FuJ3QgZmluZCB0aGUgaW5zdGFsbCBmb2xkZXIuKioKVGhlIHNraWxs
  >> "!B64TMP!" echo IGxvb2tzIGZvciB0aGUgY29tcG9zZSBmb2xkZXIgdmlhICgxKSB0aGUgYExPQ0FMX1NFQVJDSF9E
  >> "!B64TMP!" echo SVJgIGVudiB2YXIsCigyKSB0aGUgY29tcG9zZSBsYWJlbHMgb24gdGhlIHJ1bm5pbmcgY29udGFp
  >> "!B64TMP!" echo bmVycywgKDMpIHRoZSBgaW5zdGFsbC1kaXIudHh0YApoaW50IHRoZSBpbnN0YWxsZXIgd3JvdGUg
  >> "!B64TMP!" echo bmV4dCB0byB0aGUgc2tpbGwsIGFuZCAoNCkgYH4vbG9jYWwtc2VhcmNoYC4gSWYgeW91Cm1vdmVk
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsIGZvbGRlciwgcmUtcnVuIHRoZSBpbnN0YWxsZXIgb3IgYFVwZGF0ZS5iYXRg
  >> "!B64TMP!" echo IC8gYC4vdXBkYXRlLnNoYAp0byByZWZyZXNoIHRoZSBoaW50IOKAlCBvciBleHBvcnQgYExPQ0FM
  >> "!B64TMP!" echo X1NFQVJDSF9ESVI9L3BhdGgvdG8vbG9jYWwtc2VhcmNoYC4KCioqVGhlIGFnZW50IGRvZXNuJ3Qg
  >> "!B64TMP!" echo c2VlIHRoZSBza2lsbCBhZnRlciBpbnN0YWxsLioqClNraWxscyBhcmUgdXN1YWxseSBzY2FubmVk
  >> "!B64TMP!" echo IGF0IGFnZW50IHN0YXJ0dXAg4oCUIHJlc3RhcnQgdGhlIGFnZW50LiBBbHNvIGNoZWNrIHRoZQpz
  >> "!B64TMP!" echo a2lsbCBhY3R1YWxseSBsYW5kZWQgYXQgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJj
  >> "!B64TMP!" echo aC9TS0lMTC5tZGAgKHRoZSBpbnN0YWxsZXIKcHJpbnRzIHdoZXJlIGl0IHB1dCBpdCkuCgoqKkZp
  >> "!B64TMP!" echo cnN0IGBkb2NrZXIgY29tcG9zZSBwdWxsYCBpcyBzbG93IC8gaGl0cyBhIEdIQ1IgNDAxLioqClRo
  >> "!B64TMP!" echo ZSBGaXJlY3Jhd2wgaW1hZ2VzIGFyZSBwdWJsaWMsIGJ1dCByYXRlLWxpbWl0ZWQuIEF1dGhlbnRp
  >> "!B64TMP!" echo Y2F0ZToKYGVjaG8gIiRHSVRIVUJfUEFUIiB8IGRvY2tlciBsb2dpbiBnaGNyLmlvIC11IFlPVVJf
  >> "!B64TMP!" echo R0hfVVNFUiAtLXBhc3N3b3JkLXN0ZGluYAoodG9rZW4gbmVlZHMgYHJlYWQ6cGFja2FnZXNgKSwg
  >> "!B64TMP!" echo dGhlbiByZS1ydW4gYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYC4KCioqQ29udGFpbmVycyBr
  >> "!B64TMP!" echo ZWVwIHJlc3RhcnRpbmcuKioKQ2hlY2sgbG9nczogYGRvY2tlciBjb21wb3NlIGxvZ3MgZmlyZWNy
  >> "!B64TMP!" echo YXdsYCAob3IgYHNlYXJ4bmdgKS4gVGhlIG1vc3QgY29tbW9uCmNhdXNlIGlzIGEgbWlzc2luZy9l
  >> "!B64TMP!" echo bXB0eSBgLmVudmAgdmFsdWUgKGUuZy4gYFJBQkJJVE1RX1BBU1NXT1JEYCkuIFJlLXJ1biB0aGUK
  >> "!B64TMP!" echo aW5zdGFsbGVyIHRvIHJlZ2VuZXJhdGUgYSBjbGVhbiBgLmVudmAuCgoqKlNlYXJYTkcgVUkgbG9h
  >> "!B64TMP!" echo ZHMgYnV0IGAvc2VhcmNoP2Zvcm1hdD1qc29uYCByZXR1cm5zIEhUTUwuKioKVGhlIEpTT04gZm9y
  >> "!B64TMP!" echo bWF0IGlzbid0IGVuYWJsZWQuIFlvdXIgYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAgbXVz
  >> "!B64TMP!" echo dCBjb250YWluCmBzZWFyY2g6IGZvcm1hdHM6IFtodG1sLCBqc29uXWAgKHRoZSBzaGlwcGVkIGNv
  >> "!B64TMP!" echo bmZpZyBkb2VzKS4gUmVzdGFydCB3aXRoCmBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAgYWZ0
  >> "!B64TMP!" echo ZXIgZWRpdGluZy4KCioqUmVzZXQgZXZlcnl0aGluZyB0byBkZWZhdWx0cy4qKgpSdW4gYFVuaW5z
  >> "!B64TMP!" echo dGFsbC5iYXRgIC8gYC4vdW5pbnN0YWxsLnNoYCAoZGVsZXRlcyB2b2x1bWVzICsgZGF0YSArIHRo
  >> "!B64TMP!" echo ZSBza2lsbCksCnRoZW4gcnVuIHRoZSBpbnN0YWxsZXIgYWdhaW4uCgotLS0KCiMjIFVwZGF0aW5n
  >> "!B64TMP!" echo ICYgdW5pbnN0YWxsaW5nCgotICoqVXBkYXRlIGltYWdlcyAmIGFwcGx5IGNvbmZpZyBjaGFuZ2Vz
  >> "!B64TMP!" echo ICYgcmUtc3luYyB0aGUgc2tpbGw6KiogYFVwZGF0ZS5iYXRgIC8KICBgLi91cGRhdGUuc2hgIChg
  >> "!B64TMP!" echo ZG9ja2VyIGNvbXBvc2UgcHVsbCAmJiBkb2NrZXIgY29tcG9zZSB1cCAtZGAsIHRoZW4gcmUtY29w
  >> "!B64TMP!" echo eQogIGBsb2NhbC13ZWItc2VhcmNoYCBpbnRvIGB+Ly5hZ2VudHMvc2tpbGxzL2ApLiBEYXRhIGlz
  >> "!B64TMP!" echo IHByZXNlcnZlZC4KLSAqKlVwZGF0ZSB0aGUgU2VhclhORyBgc2V0dGluZ3MueW1sYCAvIGBkb2Nr
  >> "!B64TMP!" echo ZXItY29tcG9zZS55bWxgIHRlbXBsYXRlOioqIHJlLXJ1bgogIHRoZSBpbnN0YWxsZXIg4oCUIGl0
  >> "!B64TMP!" echo IGNvcGllcyB0aGUgbGF0ZXN0IHRlbXBsYXRlIG92ZXIsIHJlZnJlc2hlcyB0aGUKICBgbG9jYWwt
  >> "!B64TMP!" echo d2ViLXNlYXJjaGAgc2tpbGwsIGFuZCBiYWNrcyB1cCB5b3VyIGV4aXN0aW5nIGAuZW52YCB0byBg
  >> "!B64TMP!" echo LmVudi5iYWsuPHRpbWVzdGFtcD5gLgotICoqVW5pbnN0YWxsOioqIGBVbmluc3RhbGwuYmF0YCAv
  >> "!B64TMP!" echo IGAuL3VuaW5zdGFsbC5zaGAuIFJlbW92ZXMgY29udGFpbmVycyArIERvY2tlcgogIHZvbHVtZXMg
  >> "!B64TMP!" echo KGFsbCBGaXJlY3Jhd2wvU2VhclhORyBkYXRhKSArIHRoZSBgbG9jYWwtd2ViLXNlYXJjaGAgc2tp
  >> "!B64TMP!" echo bGwgZnJvbQogIGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2hgLCB0aGVuIGFza3Mg
  >> "!B64TMP!" echo d2hldGhlciB0byBkZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyLgogIFB1bGxlZCBpbWFnZXMgcmVt
  >> "!B64TMP!" echo YWluOyByZWNsYWltIHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAtYWAuCgotLS0KCiMjIFNlY3Vy
  >> "!B64TMP!" echo aXR5IG5vdGVzCgotIFRoaXMgc3RhY2sgaXMgZGVzaWduZWQgZm9yICoqbG9jYWwgLyB0cnVzdGVk
  >> "!B64TMP!" echo LW5ldHdvcmsgdXNlKiouIEZpcmVjcmF3bCdzIEFQSSBpcwogICoqdW5hdXRoZW50aWNhdGVkKiog
  >> "!B64TMP!" echo KGBVU0VfREJfQVVUSEVOVElDQVRJT049ZmFsc2VgKSBzbyB5b3VyIG1vZGVscyBjYW4gY2FsbCBp
  >> "!B64TMP!" echo dAogIHdpdGhvdXQgYSBrZXkuICoqRG8gbm90IGV4cG9zZSBwb3J0cyA5OTkwLzk5OTEgdG8gdGhl
  >> "!B64TMP!" echo IHB1YmxpYyBpbnRlcm5ldC4qKgotIEFsbCBjcmVkZW50aWFscyAoYFNFQVJYTkdfU0VDUkVUYCwg
  >> "!B64TMP!" echo YEJVTExfQVVUSF9LRVlgLCBgUE9TVEdSRVNfUEFTU1dPUkRgLAogIGBSQUJCSVRNUV9QQVNTV09S
  >> "!B64TMP!" echo RGApIGFyZSBnZW5lcmF0ZWQgYXMgMjU2LWJpdCByYW5kb20gaGV4IGF0IGluc3RhbGwgdGltZSBh
  >> "!B64TMP!" echo bmQKICBzdG9yZWQgb25seSBpbiB5b3VyIGxvY2FsIGAuZW52YC4KLSBTZWFyWE5HJ3MgYm90IGxp
  >> "!B64TMP!" echo bWl0ZXIgaXMgZGlzYWJsZWQgYW5kIEpTT04gb3V0cHV0IGlzIGVuYWJsZWQgc28gbW9kZWxzIGNh
  >> "!B64TMP!" echo bgogIHF1ZXJ5IGl0IOKAlCB0aGlzIGlzIGludGVudGlvbmFsIGZvciBsb2NhbCB1c2UuIE9uIGEg
  >> "!B64TMP!" echo cHVibGljIGluc3RhbmNlIHlvdSdkIHdhbnQKICB0aGUgbGltaXRlciBiYWNrIG9uLgotIFlvdXIg
  >> "!B64TMP!" echo c2VhcmNoIHF1ZXJpZXMgYW5kIHNjcmFwZWQgcGFnZSBjb250ZW50cyBuZXZlciBsZWF2ZSB5b3Vy
  >> "!B64TMP!" echo IG1hY2hpbmUKICAoZXhjZXB0IHRoZSBvdXRib3VuZCBmZXRjaGVzIFNlYXJYTkcvRmlyZWNyYXds
  >> "!B64TMP!" echo IG1ha2UgdG8gdGhlIHB1YmxpYyB3ZWIsIHdoaWNoCiAgaXMgdGhlIHdob2xlIHBvaW50KS4KCi0t
  >> "!B64TMP!" echo LQoKIyMgQ3JlZGl0cyAmIGxpY2Vuc2VzCgpUaGlzIHByb2plY3QgaXMgbGljZW5zZWQgdW5kZXIg
  >> "!B64TMP!" echo dGhlICoqTVBMLTIuMCoqIGxpY2Vuc2Ug4oCUIHNlZSBbTElDRU5TRV0oTElDRU5TRSkKKGl0IGNv
  >> "!B64TMP!" echo dmVycyB0aGUgYnVuZGxlZCBbbG9jYWwtd2ViLXNlYXJjaF0obG9jYWwtd2ViLXNlYXJjaCkgc2tp
  >> "!B64TMP!" echo bGwgdG9vKS4KCi0gWyoqU2VhclhORyoqXShodHRwczovL2dpdGh1Yi5jb20vc2VhcnhuZy9zZWFy
  >> "!B64TMP!" echo eG5nKSDigJQgQUdQTC0zLjAsIHByaXZhY3ktcmVzcGVjdGluZyBtZXRhc2VhcmNoIGVuZ2luZS4K
  >> "!B64TMP!" echo LSBbKipGaXJlY3Jhd2wqKl0oaHR0cHM6Ly9naXRodWIuY29tL2ZpcmVjcmF3bC9maXJlY3Jhd2wp
  >> "!B64TMP!" echo IOKAlCBBR1BMLTMuMCwgdGhlIGNvbnRleHQgQVBJIGZvciB3ZWIgc2NyYXBpbmcvY3Jhd2xpbmcv
  >> "!B64TMP!" echo c2VhcmNoLgotIFsqKkZpcmVjcmF3bCBNQ1Agc2VydmVyKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9m
  >> "!B64TMP!" echo aXJlY3Jhd2wvZmlyZWNyYXdsLW1jcC1zZXJ2ZXIpIOKAlCBNSVQuCi0gVGhlIHVwc3RyZWFtIHBy
  >> "!B64TMP!" echo b2plY3RzIHJldGFpbiB0aGVpciBvd24gbGljZW5zZXMg4oCUIHBsZWFzZSByZXNwZWN0IHRoZW0u
  >> "!B64TMP!" echo CiAgTm90aGluZyBmcm9tIHRoZW0gaXMgYnVuZGxlZCBpbiB0aGlzIHJlcG9zaXRvcnk7IHRoZSBp
  >> "!B64TMP!" echo bnN0YWxsZXIgb25seSBwdWxscwogIHRoZWlyIG9mZmljaWFsIGNvbnRhaW5lciBpbWFnZXMgYXQg
  >> "!B64TMP!" echo aW5zdGFsbCB0aW1lLgoKLS0tCgo8c3ViPkJ1aWx0IHNvIGFueSBsb2NhbCBtb2RlbCDigJQgaW4g
  >> "!B64TMP!" echo TE0gU3R1ZGlvIG9yIG90aGVyd2lzZSDigJQgY2FuIHNlYXJjaCBhbmQgcmVhZAp0aGUgd2ViIHdp
  >> "!B64TMP!" echo dGhvdXQgYSBwYWlkIEFQSSBrZXkuIENvbnRyaWJ1dGlvbnMgd2VsY29tZS48L3N1Yj4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\README.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- LICENSE ---
set "NEED_B64=1"
if exist "!SRC!\LICENSE" (
  copy /Y "!SRC!\LICENSE" "!TARGET!\LICENSE" >nul 2>&1
  if exist "!TARGET!\LICENSE" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] LICENSE  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1747782147.b64"
  > "!B64TMP!" echo TW96aWxsYSBQdWJsaWMgTGljZW5zZSBWZXJzaW9uIDIuMAo9PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09CgoxLiBEZWZpbml0aW9ucwotLS0tLS0tLS0tLS0tLQoKMS4xLiAiQ29udHJp
  >> "!B64TMP!" echo YnV0b3IiCiAgICBtZWFucyBlYWNoIGluZGl2aWR1YWwgb3IgbGVnYWwgZW50aXR5IHRoYXQgY3Jl
  >> "!B64TMP!" echo YXRlcywgY29udHJpYnV0ZXMgdG8KICAgIHRoZSBjcmVhdGlvbiBvZiwgb3Igb3ducyBDb3ZlcmVk
  >> "!B64TMP!" echo IFNvZnR3YXJlLgoKMS4yLiAiQ29udHJpYnV0b3IgVmVyc2lvbiIKICAgIG1lYW5zIHRoZSBjb21i
  >> "!B64TMP!" echo aW5hdGlvbiBvZiB0aGUgQ29udHJpYnV0aW9ucyBvZiBvdGhlcnMgKGlmIGFueSkgdXNlZAogICAg
  >> "!B64TMP!" echo YnkgYSBDb250cmlidXRvciBhbmQgdGhhdCBwYXJ0aWN1bGFyIENvbnRyaWJ1dG9yJ3MgQ29udHJp
  >> "!B64TMP!" echo YnV0aW9uLgoKMS4zLiAiQ29udHJpYnV0aW9uIgogICAgbWVhbnMgQ292ZXJlZCBTb2Z0d2FyZSBv
  >> "!B64TMP!" echo ZiBhIHBhcnRpY3VsYXIgQ29udHJpYnV0b3IuCgoxLjQuICJDb3ZlcmVkIFNvZnR3YXJlIgogICAg
  >> "!B64TMP!" echo bWVhbnMgU291cmNlIENvZGUgRm9ybSB0byB3aGljaCB0aGUgaW5pdGlhbCBDb250cmlidXRvciBo
  >> "!B64TMP!" echo YXMgYXR0YWNoZWQKICAgIHRoZSBub3RpY2UgaW4gRXhoaWJpdCBBLCB0aGUgRXhlY3V0YWJsZSBG
  >> "!B64TMP!" echo b3JtIG9mIHN1Y2ggU291cmNlIENvZGUKICAgIEZvcm0sIGFuZCBNb2RpZmljYXRpb25zIG9mIHN1
  >> "!B64TMP!" echo Y2ggU291cmNlIENvZGUgRm9ybSwgaW4gZWFjaCBjYXNlCiAgICBpbmNsdWRpbmcgcG9ydGlvbnMg
  >> "!B64TMP!" echo dGhlcmVvZi4KCjEuNS4gIkluY29tcGF0aWJsZSBXaXRoIFNlY29uZGFyeSBMaWNlbnNlcyIKICAg
  >> "!B64TMP!" echo IG1lYW5zCgogICAgKGEpIHRoYXQgdGhlIGluaXRpYWwgQ29udHJpYnV0b3IgaGFzIGF0dGFjaGVk
  >> "!B64TMP!" echo IHRoZSBub3RpY2UgZGVzY3JpYmVkCiAgICAgICAgaW4gRXhoaWJpdCBCIHRvIHRoZSBDb3ZlcmVk
  >> "!B64TMP!" echo IFNvZnR3YXJlOyBvcgoKICAgIChiKSB0aGF0IHRoZSBDb3ZlcmVkIFNvZnR3YXJlIHdhcyBtYWRl
  >> "!B64TMP!" echo IGF2YWlsYWJsZSB1bmRlciB0aGUgdGVybXMgb2YKICAgICAgICB2ZXJzaW9uIDEuMSBvciBlYXJs
  >> "!B64TMP!" echo aWVyIG9mIHRoZSBMaWNlbnNlLCBidXQgbm90IGFsc28gdW5kZXIgdGhlCiAgICAgICAgdGVybXMg
  >> "!B64TMP!" echo b2YgYSBTZWNvbmRhcnkgTGljZW5zZS4KCjEuNi4gIkV4ZWN1dGFibGUgRm9ybSIKICAgIG1lYW5z
  >> "!B64TMP!" echo IGFueSBmb3JtIG9mIHRoZSB3b3JrIG90aGVyIHRoYW4gU291cmNlIENvZGUgRm9ybS4KCjEuNy4g
  >> "!B64TMP!" echo IkxhcmdlciBXb3JrIgogICAgbWVhbnMgYSB3b3JrIHRoYXQgY29tYmluZXMgQ292ZXJlZCBTb2Z0
  >> "!B64TMP!" echo d2FyZSB3aXRoIG90aGVyIG1hdGVyaWFsLCBpbgogICAgYSBzZXBhcmF0ZSBmaWxlIG9yIGZpbGVz
  >> "!B64TMP!" echo LCB0aGF0IGlzIG5vdCBDb3ZlcmVkIFNvZnR3YXJlLgoKMS44LiAiTGljZW5zZSIKICAgIG1lYW5z
  >> "!B64TMP!" echo IHRoaXMgZG9jdW1lbnQuCgoxLjkuICJMaWNlbnNhYmxlIgogICAgbWVhbnMgaGF2aW5nIHRoZSBy
  >> "!B64TMP!" echo aWdodCB0byBncmFudCwgdG8gdGhlIG1heGltdW0gZXh0ZW50IHBvc3NpYmxlLAogICAgd2hldGhl
  >> "!B64TMP!" echo ciBhdCB0aGUgdGltZSBvZiB0aGUgaW5pdGlhbCBncmFudCBvciBzdWJzZXF1ZW50bHksIGFueSBh
  >> "!B64TMP!" echo bmQKICAgIGFsbCBvZiB0aGUgcmlnaHRzIGNvbnZleWVkIGJ5IHRoaXMgTGljZW5zZS4KCjEuMTAu
  >> "!B64TMP!" echo ICJNb2RpZmljYXRpb25zIgogICAgbWVhbnMgYW55IG9mIHRoZSBmb2xsb3dpbmc6CgogICAgKGEp
  >> "!B64TMP!" echo IGFueSBmaWxlIGluIFNvdXJjZSBDb2RlIEZvcm0gdGhhdCByZXN1bHRzIGZyb20gYW4gYWRkaXRp
  >> "!B64TMP!" echo b24gdG8sCiAgICAgICAgZGVsZXRpb24gZnJvbSwgb3IgbW9kaWZpY2F0aW9uIG9mIHRoZSBjb250
  >> "!B64TMP!" echo ZW50cyBvZiBDb3ZlcmVkCiAgICAgICAgU29mdHdhcmU7IG9yCgogICAgKGIpIGFueSBuZXcgZmls
  >> "!B64TMP!" echo ZSBpbiBTb3VyY2UgQ29kZSBGb3JtIHRoYXQgY29udGFpbnMgYW55IENvdmVyZWQKICAgICAgICBT
  >> "!B64TMP!" echo b2Z0d2FyZS4KCjEuMTEuICJQYXRlbnQgQ2xhaW1zIiBvZiBhIENvbnRyaWJ1dG9yCiAgICBtZWFu
  >> "!B64TMP!" echo cyBhbnkgcGF0ZW50IGNsYWltKHMpLCBpbmNsdWRpbmcgd2l0aG91dCBsaW1pdGF0aW9uLCBtZXRo
  >> "!B64TMP!" echo b2QsCiAgICBwcm9jZXNzLCBhbmQgYXBwYXJhdHVzIGNsYWltcywgaW4gYW55IHBhdGVudCBMaWNl
  >> "!B64TMP!" echo bnNhYmxlIGJ5IHN1Y2gKICAgIENvbnRyaWJ1dG9yIHRoYXQgd291bGQgYmUgaW5mcmluZ2VkLCBi
  >> "!B64TMP!" echo dXQgZm9yIHRoZSBncmFudCBvZiB0aGUKICAgIExpY2Vuc2UsIGJ5IHRoZSBtYWtpbmcsIHVzaW5n
  >> "!B64TMP!" echo LCBzZWxsaW5nLCBvZmZlcmluZyBmb3Igc2FsZSwgaGF2aW5nCiAgICBtYWRlLCBpbXBvcnQsIG9y
  >> "!B64TMP!" echo IHRyYW5zZmVyIG9mIGVpdGhlciBpdHMgQ29udHJpYnV0aW9ucyBvciBpdHMKICAgIENvbnRyaWJ1
  >> "!B64TMP!" echo dG9yIFZlcnNpb24uCgoxLjEyLiAiU2Vjb25kYXJ5IExpY2Vuc2UiCiAgICBtZWFucyBlaXRoZXIg
  >> "!B64TMP!" echo dGhlIEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlLCBWZXJzaW9uIDIuMCwgdGhlIEdOVQogICAg
  >> "!B64TMP!" echo TGVzc2VyIEdlbmVyYWwgUHVibGljIExpY2Vuc2UsIFZlcnNpb24gMi4xLCB0aGUgR05VIEFmZmVy
  >> "!B64TMP!" echo byBHZW5lcmFsCiAgICBQdWJsaWMgTGljZW5zZSwgVmVyc2lvbiAzLjAsIG9yIGFueSBsYXRlciB2
  >> "!B64TMP!" echo ZXJzaW9ucyBvZiB0aG9zZQogICAgbGljZW5zZXMuCgoxLjEzLiAiU291cmNlIENvZGUgRm9ybSIK
  >> "!B64TMP!" echo ICAgIG1lYW5zIHRoZSBmb3JtIG9mIHRoZSB3b3JrIHByZWZlcnJlZCBmb3IgbWFraW5nIG1vZGlm
  >> "!B64TMP!" echo aWNhdGlvbnMuCgoxLjE0LiAiWW91IiAob3IgIllvdXIiKQogICAgbWVhbnMgYW4gaW5kaXZpZHVh
  >> "!B64TMP!" echo bCBvciBhIGxlZ2FsIGVudGl0eSBleGVyY2lzaW5nIHJpZ2h0cyB1bmRlciB0aGlzCiAgICBMaWNl
  >> "!B64TMP!" echo bnNlLiBGb3IgbGVnYWwgZW50aXRpZXMsICJZb3UiIGluY2x1ZGVzIGFueSBlbnRpdHkgdGhhdAog
  >> "!B64TMP!" echo ICAgY29udHJvbHMsIGlzIGNvbnRyb2xsZWQgYnksIG9yIGlzIHVuZGVyIGNvbW1vbiBjb250cm9s
  >> "!B64TMP!" echo IHdpdGggWW91LiBGb3IKICAgIHB1cnBvc2VzIG9mIHRoaXMgZGVmaW5pdGlvbiwgImNvbnRyb2wi
  >> "!B64TMP!" echo IG1lYW5zIChhKSB0aGUgcG93ZXIsIGRpcmVjdAogICAgb3IgaW5kaXJlY3QsIHRvIGNhdXNlIHRo
  >> "!B64TMP!" echo ZSBkaXJlY3Rpb24gb3IgbWFuYWdlbWVudCBvZiBzdWNoIGVudGl0eSwKICAgIHdoZXRoZXIgYnkg
  >> "!B64TMP!" echo Y29udHJhY3Qgb3Igb3RoZXJ3aXNlLCBvciAoYikgb3duZXJzaGlwIG9mIG1vcmUgdGhhbgogICAg
  >> "!B64TMP!" echo ZmlmdHkgcGVyY2VudCAoNTAlKSBvZiB0aGUgb3V0c3RhbmRpbmcgc2hhcmVzIG9yIGJlbmVmaWNp
  >> "!B64TMP!" echo YWwKICAgIG93bmVyc2hpcCBvZiBzdWNoIGVudGl0eS4KCjIuIExpY2Vuc2UgR3JhbnRzIGFuZCBD
  >> "!B64TMP!" echo b25kaXRpb25zCi0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgoyLjEuIEdyYW50cwoK
  >> "!B64TMP!" echo RWFjaCBDb250cmlidXRvciBoZXJlYnkgZ3JhbnRzIFlvdSBhIHdvcmxkLXdpZGUsIHJveWFsdHkt
  >> "!B64TMP!" echo ZnJlZSwKbm9uLWV4Y2x1c2l2ZSBsaWNlbnNlOgoKKGEpIHVuZGVyIGludGVsbGVjdHVhbCBwcm9w
  >> "!B64TMP!" echo ZXJ0eSByaWdodHMgKG90aGVyIHRoYW4gcGF0ZW50IG9yIHRyYWRlbWFyaykKICAgIExpY2Vuc2Fi
  >> "!B64TMP!" echo bGUgYnkgc3VjaCBDb250cmlidXRvciB0byB1c2UsIHJlcHJvZHVjZSwgbWFrZSBhdmFpbGFibGUs
  >> "!B64TMP!" echo CiAgICBtb2RpZnksIGRpc3BsYXksIHBlcmZvcm0sIGRpc3RyaWJ1dGUsIGFuZCBvdGhlcndpc2Ug
  >> "!B64TMP!" echo ZXhwbG9pdCBpdHMKICAgIENvbnRyaWJ1dGlvbnMsIGVpdGhlciBvbiBhbiB1bm1vZGlmaWVkIGJh
  >> "!B64TMP!" echo c2lzLCB3aXRoIE1vZGlmaWNhdGlvbnMsIG9yCiAgICBhcyBwYXJ0IG9mIGEgTGFyZ2VyIFdvcms7
  >> "!B64TMP!" echo IGFuZAoKKGIpIHVuZGVyIFBhdGVudCBDbGFpbXMgb2Ygc3VjaCBDb250cmlidXRvciB0byBtYWtl
  >> "!B64TMP!" echo LCB1c2UsIHNlbGwsIG9mZmVyCiAgICBmb3Igc2FsZSwgaGF2ZSBtYWRlLCBpbXBvcnQsIGFuZCBv
  >> "!B64TMP!" echo dGhlcndpc2UgdHJhbnNmZXIgZWl0aGVyIGl0cwogICAgQ29udHJpYnV0aW9ucyBvciBpdHMgQ29u
  >> "!B64TMP!" echo dHJpYnV0b3IgVmVyc2lvbi4KCjIuMi4gRWZmZWN0aXZlIERhdGUKClRoZSBsaWNlbnNlcyBncmFu
  >> "!B64TMP!" echo dGVkIGluIFNlY3Rpb24gMi4xIHdpdGggcmVzcGVjdCB0byBhbnkgQ29udHJpYnV0aW9uCmJlY29t
  >> "!B64TMP!" echo ZSBlZmZlY3RpdmUgZm9yIGVhY2ggQ29udHJpYnV0aW9uIG9uIHRoZSBkYXRlIHRoZSBDb250cmli
  >> "!B64TMP!" echo dXRvciBmaXJzdApkaXN0cmlidXRlcyBzdWNoIENvbnRyaWJ1dGlvbi4KCjIuMy4gTGltaXRhdGlv
  >> "!B64TMP!" echo bnMgb24gR3JhbnQgU2NvcGUKClRoZSBsaWNlbnNlcyBncmFudGVkIGluIHRoaXMgU2VjdGlvbiAy
  >> "!B64TMP!" echo IGFyZSB0aGUgb25seSByaWdodHMgZ3JhbnRlZCB1bmRlcgp0aGlzIExpY2Vuc2UuIE5vIGFkZGl0
  >> "!B64TMP!" echo aW9uYWwgcmlnaHRzIG9yIGxpY2Vuc2VzIHdpbGwgYmUgaW1wbGllZCBmcm9tIHRoZQpkaXN0cmli
  >> "!B64TMP!" echo dXRpb24gb3IgbGljZW5zaW5nIG9mIENvdmVyZWQgU29mdHdhcmUgdW5kZXIgdGhpcyBMaWNlbnNl
  >> "!B64TMP!" echo LgpOb3R3aXRoc3RhbmRpbmcgU2VjdGlvbiAyLjEoYikgYWJvdmUsIG5vIHBhdGVudCBsaWNlbnNl
  >> "!B64TMP!" echo IGlzIGdyYW50ZWQgYnkgYQpDb250cmlidXRvcjoKCihhKSBmb3IgYW55IGNvZGUgdGhhdCBhIENv
  >> "!B64TMP!" echo bnRyaWJ1dG9yIGhhcyByZW1vdmVkIGZyb20gQ292ZXJlZCBTb2Z0d2FyZTsKICAgIG9yCgooYikg
  >> "!B64TMP!" echo Zm9yIGluZnJpbmdlbWVudHMgY2F1c2VkIGJ5OiAoaSkgWW91ciBhbmQgYW55IG90aGVyIHRoaXJk
  >> "!B64TMP!" echo IHBhcnR5J3MKICAgIG1vZGlmaWNhdGlvbnMgb2YgQ292ZXJlZCBTb2Z0d2FyZSwgb3IgKGlpKSB0
  >> "!B64TMP!" echo aGUgY29tYmluYXRpb24gb2YgaXRzCiAgICBDb250cmlidXRpb25zIHdpdGggb3RoZXIgc29mdHdh
  >> "!B64TMP!" echo cmUgKGV4Y2VwdCBhcyBwYXJ0IG9mIGl0cyBDb250cmlidXRvcgogICAgVmVyc2lvbik7IG9yCgoo
  >> "!B64TMP!" echo YykgdW5kZXIgUGF0ZW50IENsYWltcyBpbmZyaW5nZWQgYnkgQ292ZXJlZCBTb2Z0d2FyZSBpbiB0
  >> "!B64TMP!" echo aGUgYWJzZW5jZSBvZgogICAgaXRzIENvbnRyaWJ1dGlvbnMuCgpUaGlzIExpY2Vuc2UgZG9lcyBu
  >> "!B64TMP!" echo b3QgZ3JhbnQgYW55IHJpZ2h0cyBpbiB0aGUgdHJhZGVtYXJrcywgc2VydmljZSBtYXJrcywKb3Ig
  >> "!B64TMP!" echo bG9nb3Mgb2YgYW55IENvbnRyaWJ1dG9yIChleGNlcHQgYXMgbWF5IGJlIG5lY2Vzc2FyeSB0byBj
  >> "!B64TMP!" echo b21wbHkgd2l0aAp0aGUgbm90aWNlIHJlcXVpcmVtZW50cyBpbiBTZWN0aW9uIDMuNCkuCgoyLjQu
  >> "!B64TMP!" echo IFN1YnNlcXVlbnQgTGljZW5zZXMKCk5vIENvbnRyaWJ1dG9yIG1ha2VzIGFkZGl0aW9uYWwgZ3Jh
  >> "!B64TMP!" echo bnRzIGFzIGEgcmVzdWx0IG9mIFlvdXIgY2hvaWNlIHRvCmRpc3RyaWJ1dGUgdGhlIENvdmVyZWQg
  >> "!B64TMP!" echo U29mdHdhcmUgdW5kZXIgYSBzdWJzZXF1ZW50IHZlcnNpb24gb2YgdGhpcwpMaWNlbnNlIChzZWUg
  >> "!B64TMP!" echo U2VjdGlvbiAxMC4yKSBvciB1bmRlciB0aGUgdGVybXMgb2YgYSBTZWNvbmRhcnkgTGljZW5zZSAo
  >> "!B64TMP!" echo aWYKcGVybWl0dGVkIHVuZGVyIHRoZSB0ZXJtcyBvZiBTZWN0aW9uIDMuMykuCgoyLjUuIFJlcHJl
  >> "!B64TMP!" echo c2VudGF0aW9uCgpFYWNoIENvbnRyaWJ1dG9yIHJlcHJlc2VudHMgdGhhdCB0aGUgQ29udHJpYnV0
  >> "!B64TMP!" echo b3IgYmVsaWV2ZXMgaXRzCkNvbnRyaWJ1dGlvbnMgYXJlIGl0cyBvcmlnaW5hbCBjcmVhdGlvbihz
  >> "!B64TMP!" echo KSBvciBpdCBoYXMgc3VmZmljaWVudCByaWdodHMKdG8gZ3JhbnQgdGhlIHJpZ2h0cyB0byBpdHMg
  >> "!B64TMP!" echo Q29udHJpYnV0aW9ucyBjb252ZXllZCBieSB0aGlzIExpY2Vuc2UuCgoyLjYuIEZhaXIgVXNlCgpU
  >> "!B64TMP!" echo aGlzIExpY2Vuc2UgaXMgbm90IGludGVuZGVkIHRvIGxpbWl0IGFueSByaWdodHMgWW91IGhhdmUg
  >> "!B64TMP!" echo dW5kZXIKYXBwbGljYWJsZSBjb3B5cmlnaHQgZG9jdHJpbmVzIG9mIGZhaXIgdXNlLCBmYWlyIGRl
  >> "!B64TMP!" echo YWxpbmcsIG9yIG90aGVyCmVxdWl2YWxlbnRzLgoKMi43LiBDb25kaXRpb25zCgpTZWN0aW9ucyAz
  >> "!B64TMP!" echo LjEsIDMuMiwgMy4zLCBhbmQgMy40IGFyZSBjb25kaXRpb25zIG9mIHRoZSBsaWNlbnNlcyBncmFu
  >> "!B64TMP!" echo dGVkCmluIFNlY3Rpb24gMi4xLgoKMy4gUmVzcG9uc2liaWxpdGllcwotLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tCgozLjEuIERpc3RyaWJ1dGlvbiBvZiBTb3VyY2UgRm9ybQoKQWxsIGRpc3RyaWJ1dGlvbiBv
  >> "!B64TMP!" echo ZiBDb3ZlcmVkIFNvZnR3YXJlIGluIFNvdXJjZSBDb2RlIEZvcm0sIGluY2x1ZGluZyBhbnkKTW9k
  >> "!B64TMP!" echo aWZpY2F0aW9ucyB0aGF0IFlvdSBjcmVhdGUgb3IgdG8gd2hpY2ggWW91IGNvbnRyaWJ1dGUsIG11
  >> "!B64TMP!" echo c3QgYmUgdW5kZXIKdGhlIHRlcm1zIG9mIHRoaXMgTGljZW5zZS4gWW91IG11c3QgaW5mb3JtIHJl
  >> "!B64TMP!" echo Y2lwaWVudHMgdGhhdCB0aGUgU291cmNlCkNvZGUgRm9ybSBvZiB0aGUgQ292ZXJlZCBTb2Z0d2Fy
  >> "!B64TMP!" echo ZSBpcyBnb3Zlcm5lZCBieSB0aGUgdGVybXMgb2YgdGhpcwpMaWNlbnNlLCBhbmQgaG93IHRoZXkg
  >> "!B64TMP!" echo Y2FuIG9idGFpbiBhIGNvcHkgb2YgdGhpcyBMaWNlbnNlLiBZb3UgbWF5IG5vdAphdHRlbXB0IHRv
  >> "!B64TMP!" echo IGFsdGVyIG9yIHJlc3RyaWN0IHRoZSByZWNpcGllbnRzJyByaWdodHMgaW4gdGhlIFNvdXJjZSBD
  >> "!B64TMP!" echo b2RlCkZvcm0uCgozLjIuIERpc3RyaWJ1dGlvbiBvZiBFeGVjdXRhYmxlIEZvcm0KCklmIFlvdSBk
  >> "!B64TMP!" echo aXN0cmlidXRlIENvdmVyZWQgU29mdHdhcmUgaW4gRXhlY3V0YWJsZSBGb3JtIHRoZW46CgooYSkg
  >> "!B64TMP!" echo c3VjaCBDb3ZlcmVkIFNvZnR3YXJlIG11c3QgYWxzbyBiZSBtYWRlIGF2YWlsYWJsZSBpbiBTb3Vy
  >> "!B64TMP!" echo Y2UgQ29kZQogICAgRm9ybSwgYXMgZGVzY3JpYmVkIGluIFNlY3Rpb24gMy4xLCBhbmQgWW91IG11
  >> "!B64TMP!" echo c3QgaW5mb3JtIHJlY2lwaWVudHMgb2YKICAgIHRoZSBFeGVjdXRhYmxlIEZvcm0gaG93IHRoZXkg
  >> "!B64TMP!" echo Y2FuIG9idGFpbiBhIGNvcHkgb2Ygc3VjaCBTb3VyY2UgQ29kZQogICAgRm9ybSBieSByZWFzb25h
  >> "!B64TMP!" echo YmxlIG1lYW5zIGluIGEgdGltZWx5IG1hbm5lciwgYXQgYSBjaGFyZ2Ugbm8gbW9yZQogICAgdGhh
  >> "!B64TMP!" echo biB0aGUgY29zdCBvZiBkaXN0cmlidXRpb24gdG8gdGhlIHJlY2lwaWVudDsgYW5kCgooYikgWW91
  >> "!B64TMP!" echo IG1heSBkaXN0cmlidXRlIHN1Y2ggRXhlY3V0YWJsZSBGb3JtIHVuZGVyIHRoZSB0ZXJtcyBvZiB0
  >> "!B64TMP!" echo aGlzCiAgICBMaWNlbnNlLCBvciBzdWJsaWNlbnNlIGl0IHVuZGVyIGRpZmZlcmVudCB0ZXJtcywg
  >> "!B64TMP!" echo cHJvdmlkZWQgdGhhdCB0aGUKICAgIGxpY2Vuc2UgZm9yIHRoZSBFeGVjdXRhYmxlIEZvcm0gZG9l
  >> "!B64TMP!" echo cyBub3QgYXR0ZW1wdCB0byBsaW1pdCBvciBhbHRlcgogICAgdGhlIHJlY2lwaWVudHMnIHJpZ2h0
  >> "!B64TMP!" echo cyBpbiB0aGUgU291cmNlIENvZGUgRm9ybSB1bmRlciB0aGlzIExpY2Vuc2UuCgozLjMuIERpc3Ry
  >> "!B64TMP!" echo aWJ1dGlvbiBvZiBhIExhcmdlciBXb3JrCgpZb3UgbWF5IGNyZWF0ZSBhbmQgZGlzdHJpYnV0ZSBh
  >> "!B64TMP!" echo IExhcmdlciBXb3JrIHVuZGVyIHRlcm1zIG9mIFlvdXIgY2hvaWNlLApwcm92aWRlZCB0aGF0IFlv
  >> "!B64TMP!" echo dSBhbHNvIGNvbXBseSB3aXRoIHRoZSByZXF1aXJlbWVudHMgb2YgdGhpcyBMaWNlbnNlIGZvcgp0
  >> "!B64TMP!" echo aGUgQ292ZXJlZCBTb2Z0d2FyZS4gSWYgdGhlIExhcmdlciBXb3JrIGlzIGEgY29tYmluYXRpb24g
  >> "!B64TMP!" echo b2YgQ292ZXJlZApTb2Z0d2FyZSB3aXRoIGEgd29yayBnb3Zlcm5lZCBieSBvbmUgb3IgbW9yZSBT
  >> "!B64TMP!" echo ZWNvbmRhcnkgTGljZW5zZXMsIGFuZCB0aGUKQ292ZXJlZCBTb2Z0d2FyZSBpcyBub3QgSW5jb21w
  >> "!B64TMP!" echo YXRpYmxlIFdpdGggU2Vjb25kYXJ5IExpY2Vuc2VzLCB0aGlzCkxpY2Vuc2UgcGVybWl0cyBZb3Ug
  >> "!B64TMP!" echo dG8gYWRkaXRpb25hbGx5IGRpc3RyaWJ1dGUgc3VjaCBDb3ZlcmVkIFNvZnR3YXJlCnVuZGVyIHRo
  >> "!B64TMP!" echo ZSB0ZXJtcyBvZiBzdWNoIFNlY29uZGFyeSBMaWNlbnNlKHMpLCBzbyB0aGF0IHRoZSByZWNpcGll
  >> "!B64TMP!" echo bnQgb2YKdGhlIExhcmdlciBXb3JrIG1heSwgYXQgdGhlaXIgb3B0aW9uLCBmdXJ0aGVyIGRpc3Ry
  >> "!B64TMP!" echo aWJ1dGUgdGhlIENvdmVyZWQKU29mdHdhcmUgdW5kZXIgdGhlIHRlcm1zIG9mIGVpdGhlciB0aGlz
  >> "!B64TMP!" echo IExpY2Vuc2Ugb3Igc3VjaCBTZWNvbmRhcnkKTGljZW5zZShzKS4KCjMuNC4gTm90aWNlcwoKWW91
  >> "!B64TMP!" echo IG1heSBub3QgcmVtb3ZlIG9yIGFsdGVyIHRoZSBzdWJzdGFuY2Ugb2YgYW55IGxpY2Vuc2Ugbm90
  >> "!B64TMP!" echo aWNlcwooaW5jbHVkaW5nIGNvcHlyaWdodCBub3RpY2VzLCBwYXRlbnQgbm90aWNlcywgZGlzY2xh
  >> "!B64TMP!" echo aW1lcnMgb2Ygd2FycmFudHksCm9yIGxpbWl0YXRpb25zIG9mIGxpYWJpbGl0eSkgY29udGFpbmVk
  >> "!B64TMP!" echo IHdpdGhpbiB0aGUgU291cmNlIENvZGUgRm9ybSBvZgp0aGUgQ292ZXJlZCBTb2Z0d2FyZSwgZXhj
  >> "!B64TMP!" echo ZXB0IHRoYXQgWW91IG1heSBhbHRlciBhbnkgbGljZW5zZSBub3RpY2VzIHRvCnRoZSBleHRlbnQg
  >> "!B64TMP!" echo cmVxdWlyZWQgdG8gcmVtZWR5IGtub3duIGZhY3R1YWwgaW5hY2N1cmFjaWVzLgoKMy41LiBBcHBs
  >> "!B64TMP!" echo aWNhdGlvbiBvZiBBZGRpdGlvbmFsIFRlcm1zCgpZb3UgbWF5IGNob29zZSB0byBvZmZlciwgYW5k
  >> "!B64TMP!" echo IHRvIGNoYXJnZSBhIGZlZSBmb3IsIHdhcnJhbnR5LCBzdXBwb3J0LAppbmRlbW5pdHkgb3IgbGlh
  >> "!B64TMP!" echo YmlsaXR5IG9ibGlnYXRpb25zIHRvIG9uZSBvciBtb3JlIHJlY2lwaWVudHMgb2YgQ292ZXJlZApT
  >> "!B64TMP!" echo b2Z0d2FyZS4gSG93ZXZlciwgWW91IG1heSBkbyBzbyBvbmx5IG9uIFlvdXIgb3duIGJlaGFsZiwg
  >> "!B64TMP!" echo YW5kIG5vdCBvbgpiZWhhbGYgb2YgYW55IENvbnRyaWJ1dG9yLiBZb3UgbXVzdCBtYWtlIGl0IGFi
  >> "!B64TMP!" echo c29sdXRlbHkgY2xlYXIgdGhhdCBhbnkKc3VjaCB3YXJyYW50eSwgc3VwcG9ydCwgaW5kZW1uaXR5
  >> "!B64TMP!" echo LCBvciBsaWFiaWxpdHkgb2JsaWdhdGlvbiBpcyBvZmZlcmVkIGJ5CllvdSBhbG9uZSwgYW5kIFlv
  >> "!B64TMP!" echo dSBoZXJlYnkgYWdyZWUgdG8gaW5kZW1uaWZ5IGV2ZXJ5IENvbnRyaWJ1dG9yIGZvciBhbnkKbGlh
  >> "!B64TMP!" echo YmlsaXR5IGluY3VycmVkIGJ5IHN1Y2ggQ29udHJpYnV0b3IgYXMgYSByZXN1bHQgb2Ygd2FycmFu
  >> "!B64TMP!" echo dHksIHN1cHBvcnQsCmluZGVtbml0eSBvciBsaWFiaWxpdHkgdGVybXMgWW91IG9mZmVyLiBZb3Ug
  >> "!B64TMP!" echo bWF5IGluY2x1ZGUgYWRkaXRpb25hbApkaXNjbGFpbWVycyBvZiB3YXJyYW50eSBhbmQgbGltaXRh
  >> "!B64TMP!" echo dGlvbnMgb2YgbGlhYmlsaXR5IHNwZWNpZmljIHRvIGFueQpqdXJpc2RpY3Rpb24uCgo0LiBJbmFi
  >> "!B64TMP!" echo aWxpdHkgdG8gQ29tcGx5IER1ZSB0byBTdGF0dXRlIG9yIFJlZ3VsYXRpb24KLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgpJZiBpdCBpcyBpbXBvc3Np
  >> "!B64TMP!" echo YmxlIGZvciBZb3UgdG8gY29tcGx5IHdpdGggYW55IG9mIHRoZSB0ZXJtcyBvZiB0aGlzCkxpY2Vu
  >> "!B64TMP!" echo c2Ugd2l0aCByZXNwZWN0IHRvIHNvbWUgb3IgYWxsIG9mIHRoZSBDb3ZlcmVkIFNvZnR3YXJlIGR1
  >> "!B64TMP!" echo ZSB0bwpzdGF0dXRlLCBqdWRpY2lhbCBvcmRlciwgb3IgcmVndWxhdGlvbiB0aGVuIFlvdSBtdXN0
  >> "!B64TMP!" echo OiAoYSkgY29tcGx5IHdpdGgKdGhlIHRlcm1zIG9mIHRoaXMgTGljZW5zZSB0byB0aGUgbWF4aW11
  >> "!B64TMP!" echo bSBleHRlbnQgcG9zc2libGU7IGFuZCAoYikKZGVzY3JpYmUgdGhlIGxpbWl0YXRpb25zIGFuZCB0
  >> "!B64TMP!" echo aGUgY29kZSB0aGV5IGFmZmVjdC4gU3VjaCBkZXNjcmlwdGlvbiBtdXN0CmJlIHBsYWNlZCBpbiBh
  >> "!B64TMP!" echo IHRleHQgZmlsZSBpbmNsdWRlZCB3aXRoIGFsbCBkaXN0cmlidXRpb25zIG9mIHRoZSBDb3ZlcmVk
  >> "!B64TMP!" echo ClNvZnR3YXJlIHVuZGVyIHRoaXMgTGljZW5zZS4gRXhjZXB0IHRvIHRoZSBleHRlbnQgcHJvaGli
  >> "!B64TMP!" echo aXRlZCBieSBzdGF0dXRlCm9yIHJlZ3VsYXRpb24sIHN1Y2ggZGVzY3JpcHRpb24gbXVzdCBiZSBz
  >> "!B64TMP!" echo dWZmaWNpZW50bHkgZGV0YWlsZWQgZm9yIGEKcmVjaXBpZW50IG9mIG9yZGluYXJ5IHNraWxsIHRv
  >> "!B64TMP!" echo IGJlIGFibGUgdG8gdW5kZXJzdGFuZCBpdC4KCjUuIFRlcm1pbmF0aW9uCi0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo Cgo1LjEuIFRoZSByaWdodHMgZ3JhbnRlZCB1bmRlciB0aGlzIExpY2Vuc2Ugd2lsbCB0ZXJtaW5h
  >> "!B64TMP!" echo dGUgYXV0b21hdGljYWxseQppZiBZb3UgZmFpbCB0byBjb21wbHkgd2l0aCBhbnkgb2YgaXRzIHRl
  >> "!B64TMP!" echo cm1zLiBIb3dldmVyLCBpZiBZb3UgYmVjb21lCmNvbXBsaWFudCwgdGhlbiB0aGUgcmlnaHRzIGdy
  >> "!B64TMP!" echo YW50ZWQgdW5kZXIgdGhpcyBMaWNlbnNlIGZyb20gYSBwYXJ0aWN1bGFyCkNvbnRyaWJ1dG9yIGFy
  >> "!B64TMP!" echo ZSByZWluc3RhdGVkIChhKSBwcm92aXNpb25hbGx5LCB1bmxlc3MgYW5kIHVudGlsIHN1Y2gKQ29u
  >> "!B64TMP!" echo dHJpYnV0b3IgZXhwbGljaXRseSBhbmQgZmluYWxseSB0ZXJtaW5hdGVzIFlvdXIgZ3JhbnRzLCBh
  >> "!B64TMP!" echo bmQgKGIpIG9uIGFuCm9uZ29pbmcgYmFzaXMsIGlmIHN1Y2ggQ29udHJpYnV0b3IgZmFpbHMgdG8g
  >> "!B64TMP!" echo bm90aWZ5IFlvdSBvZiB0aGUKbm9uLWNvbXBsaWFuY2UgYnkgc29tZSByZWFzb25hYmxlIG1lYW5z
  >> "!B64TMP!" echo IHByaW9yIHRvIDYwIGRheXMgYWZ0ZXIgWW91IGhhdmUKY29tZSBiYWNrIGludG8gY29tcGxpYW5j
  >> "!B64TMP!" echo ZS4gTW9yZW92ZXIsIFlvdXIgZ3JhbnRzIGZyb20gYSBwYXJ0aWN1bGFyCkNvbnRyaWJ1dG9yIGFy
  >> "!B64TMP!" echo ZSByZWluc3RhdGVkIG9uIGFuIG9uZ29pbmcgYmFzaXMgaWYgc3VjaCBDb250cmlidXRvcgpub3Rp
  >> "!B64TMP!" echo ZmllcyBZb3Ugb2YgdGhlIG5vbi1jb21wbGlhbmNlIGJ5IHNvbWUgcmVhc29uYWJsZSBtZWFucywg
  >> "!B64TMP!" echo dGhpcyBpcyB0aGUKZmlyc3QgdGltZSBZb3UgaGF2ZSByZWNlaXZlZCBub3RpY2Ugb2Ygbm9uLWNv
  >> "!B64TMP!" echo bXBsaWFuY2Ugd2l0aCB0aGlzIExpY2Vuc2UKZnJvbSBzdWNoIENvbnRyaWJ1dG9yLCBhbmQgWW91
  >> "!B64TMP!" echo IGJlY29tZSBjb21wbGlhbnQgcHJpb3IgdG8gMzAgZGF5cyBhZnRlcgpZb3VyIHJlY2VpcHQgb2Yg
  >> "!B64TMP!" echo dGhlIG5vdGljZS4KCjUuMi4gSWYgWW91IGluaXRpYXRlIGxpdGlnYXRpb24gYWdhaW5zdCBhbnkg
  >> "!B64TMP!" echo ZW50aXR5IGJ5IGFzc2VydGluZyBhIHBhdGVudAppbmZyaW5nZW1lbnQgY2xhaW0gKGV4Y2x1ZGlu
  >> "!B64TMP!" echo ZyBkZWNsYXJhdG9yeSBqdWRnbWVudCBhY3Rpb25zLApjb3VudGVyLWNsYWltcywgYW5kIGNyb3Nz
  >> "!B64TMP!" echo LWNsYWltcykgYWxsZWdpbmcgdGhhdCBhIENvbnRyaWJ1dG9yIFZlcnNpb24KZGlyZWN0bHkgb3Ig
  >> "!B64TMP!" echo aW5kaXJlY3RseSBpbmZyaW5nZXMgYW55IHBhdGVudCwgdGhlbiB0aGUgcmlnaHRzIGdyYW50ZWQg
  >> "!B64TMP!" echo dG8KWW91IGJ5IGFueSBhbmQgYWxsIENvbnRyaWJ1dG9ycyBmb3IgdGhlIENvdmVyZWQgU29mdHdh
  >> "!B64TMP!" echo cmUgdW5kZXIgU2VjdGlvbgoyLjEgb2YgdGhpcyBMaWNlbnNlIHNoYWxsIHRlcm1pbmF0ZS4KCjUu
  >> "!B64TMP!" echo My4gSW4gdGhlIGV2ZW50IG9mIHRlcm1pbmF0aW9uIHVuZGVyIFNlY3Rpb25zIDUuMSBvciA1LjIg
  >> "!B64TMP!" echo YWJvdmUsIGFsbAplbmQgdXNlciBsaWNlbnNlIGFncmVlbWVudHMgKGV4Y2x1ZGluZyBkaXN0cmli
  >> "!B64TMP!" echo dXRvcnMgYW5kIHJlc2VsbGVycykgd2hpY2gKaGF2ZSBiZWVuIHZhbGlkbHkgZ3JhbnRlZCBieSBZ
  >> "!B64TMP!" echo b3Ugb3IgWW91ciBkaXN0cmlidXRvcnMgdW5kZXIgdGhpcyBMaWNlbnNlCnByaW9yIHRvIHRlcm1p
  >> "!B64TMP!" echo bmF0aW9uIHNoYWxsIHN1cnZpdmUgdGVybWluYXRpb24uCgoqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioKKiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAqCiogIDYuIERpc2NsYWltZXIgb2YgV2FycmFudHkgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgKgoqICAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAq
  >> "!B64TMP!" echo CiogIENvdmVyZWQgU29mdHdhcmUgaXMgcHJvdmlkZWQgdW5kZXIgdGhpcyBMaWNlbnNlIG9uIGFu
  >> "!B64TMP!" echo ICJhcyBpcyIgICAgICAgKgoqICBiYXNpcywgd2l0aG91dCB3YXJyYW50eSBvZiBhbnkga2luZCwg
  >> "!B64TMP!" echo ZWl0aGVyIGV4cHJlc3NlZCwgaW1wbGllZCwgb3IgICoKKiAgc3RhdHV0b3J5LCBpbmNsdWRpbmcs
  >> "!B64TMP!" echo IHdpdGhvdXQgbGltaXRhdGlvbiwgd2FycmFudGllcyB0aGF0IHRoZSAgICAgICAqCiogIENvdmVy
  >> "!B64TMP!" echo ZWQgU29mdHdhcmUgaXMgZnJlZSBvZiBkZWZlY3RzLCBtZXJjaGFudGFibGUsIGZpdCBmb3IgYSAg
  >> "!B64TMP!" echo ICAgICAgKgoqICBwYXJ0aWN1bGFyIHB1cnBvc2Ugb3Igbm9uLWluZnJpbmdpbmcuIFRoZSBlbnRp
  >> "!B64TMP!" echo cmUgcmlzayBhcyB0byB0aGUgICAgICoKKiAgcXVhbGl0eSBhbmQgcGVyZm9ybWFuY2Ugb2YgdGhl
  >> "!B64TMP!" echo IENvdmVyZWQgU29mdHdhcmUgaXMgd2l0aCBZb3UuICAgICAgICAqCiogIFNob3VsZCBhbnkgQ292
  >> "!B64TMP!" echo ZXJlZCBTb2Z0d2FyZSBwcm92ZSBkZWZlY3RpdmUgaW4gYW55IHJlc3BlY3QsIFlvdSAgICAgKgoq
  >> "!B64TMP!" echo ICAobm90IGFueSBDb250cmlidXRvcikgYXNzdW1lIHRoZSBjb3N0IG9mIGFueSBuZWNlc3Nhcnkg
  >> "!B64TMP!" echo c2VydmljaW5nLCAgICoKKiAgcmVwYWlyLCBvciBjb3JyZWN0aW9uLiBUaGlzIGRpc2NsYWltZXIg
  >> "!B64TMP!" echo b2Ygd2FycmFudHkgY29uc3RpdHV0ZXMgYW4gICAqCiogIGVzc2VudGlhbCBwYXJ0IG9mIHRoaXMg
  >> "!B64TMP!" echo TGljZW5zZS4gTm8gdXNlIG9mIGFueSBDb3ZlcmVkIFNvZnR3YXJlIGlzICAgKgoqICBhdXRob3Jp
  >> "!B64TMP!" echo emVkIHVuZGVyIHRoaXMgTGljZW5zZSBleGNlcHQgdW5kZXIgdGhpcyBkaXNjbGFpbWVyLiAgICAg
  >> "!B64TMP!" echo ICAgICoKKiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAqCioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKgoKKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqCiog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgKgoqICA3LiBMaW1pdGF0aW9uIG9mIExpYWJpbGl0eSAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKiAgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAqCiogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgKgoqICBVbmRlciBubyBjaXJjdW1zdGFuY2VzIGFuZCB1bmRlciBubyBsZWdhbCB0aGVvcnks
  >> "!B64TMP!" echo IHdoZXRoZXIgdG9ydCAgICAgICoKKiAgKGluY2x1ZGluZyBuZWdsaWdlbmNlKSwgY29udHJhY3Qs
  >> "!B64TMP!" echo IG9yIG90aGVyd2lzZSwgc2hhbGwgYW55ICAgICAgICAgICAqCiogIENvbnRyaWJ1dG9yLCBvciBh
  >> "!B64TMP!" echo bnlvbmUgd2hvIGRpc3RyaWJ1dGVzIENvdmVyZWQgU29mdHdhcmUgYXMgICAgICAgICAgKgoqICBw
  >> "!B64TMP!" echo ZXJtaXR0ZWQgYWJvdmUsIGJlIGxpYWJsZSB0byBZb3UgZm9yIGFueSBkaXJlY3QsIGluZGlyZWN0
  >> "!B64TMP!" echo LCAgICAgICAgICoKKiAgc3BlY2lhbCwgaW5jaWRlbnRhbCwgb3IgY29uc2VxdWVudGlhbCBkYW1h
  >> "!B64TMP!" echo Z2VzIG9mIGFueSBjaGFyYWN0ZXIgICAgICAqCiogIGluY2x1ZGluZywgd2l0aG91dCBsaW1pdGF0
  >> "!B64TMP!" echo aW9uLCBkYW1hZ2VzIGZvciBsb3N0IHByb2ZpdHMsIGxvc3Mgb2YgICAgKgoqICBnb29kd2lsbCwg
  >> "!B64TMP!" echo d29yayBzdG9wcGFnZSwgY29tcHV0ZXIgZmFpbHVyZSBvciBtYWxmdW5jdGlvbiwgb3IgYW55ICAg
  >> "!B64TMP!" echo ICoKKiAgYW5kIGFsbCBvdGhlciBjb21tZXJjaWFsIGRhbWFnZXMgb3IgbG9zc2VzLCBldmVuIGlm
  >> "!B64TMP!" echo IHN1Y2ggcGFydHkgICAgICAqCiogIHNoYWxsIGhhdmUgYmVlbiBpbmZvcm1lZCBvZiB0aGUgcG9z
  >> "!B64TMP!" echo c2liaWxpdHkgb2Ygc3VjaCBkYW1hZ2VzLiBUaGlzICAgKgoqICBsaW1pdGF0aW9uIG9mIGxpYWJp
  >> "!B64TMP!" echo bGl0eSBzaGFsbCBub3QgYXBwbHkgdG8gbGlhYmlsaXR5IGZvciBkZWF0aCBvciAgICoKKiAgcGVy
  >> "!B64TMP!" echo c29uYWwgaW5qdXJ5IHJlc3VsdGluZyBmcm9tIHN1Y2ggcGFydHkncyBuZWdsaWdlbmNlIHRvIHRo
  >> "!B64TMP!" echo ZSAgICAgICAqCiogIGV4dGVudCBhcHBsaWNhYmxlIGxhdyBwcm9oaWJpdHMgc3VjaCBsaW1pdGF0
  >> "!B64TMP!" echo aW9uLiBTb21lICAgICAgICAgICAgICAgKgoqICBqdXJpc2RpY3Rpb25zIGRvIG5vdCBhbGxvdyB0
  >> "!B64TMP!" echo aGUgZXhjbHVzaW9uIG9yIGxpbWl0YXRpb24gb2YgICAgICAgICAgICoKKiAgaW5jaWRlbnRhbCBv
  >> "!B64TMP!" echo ciBjb25zZXF1ZW50aWFsIGRhbWFnZXMsIHNvIHRoaXMgZXhjbHVzaW9uIGFuZCAgICAgICAgICAq
  >> "!B64TMP!" echo CiogIGxpbWl0YXRpb24gbWF5IG5vdCBhcHBseSB0byBZb3UuICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgKgoqICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKioqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqCgo4LiBMaXRp
  >> "!B64TMP!" echo Z2F0aW9uCi0tLS0tLS0tLS0tLS0KCkFueSBsaXRpZ2F0aW9uIHJlbGF0aW5nIHRvIHRoaXMgTGlj
  >> "!B64TMP!" echo ZW5zZSBtYXkgYmUgYnJvdWdodCBvbmx5IGluIHRoZQpjb3VydHMgb2YgYSBqdXJpc2RpY3Rpb24g
  >> "!B64TMP!" echo d2hlcmUgdGhlIGRlZmVuZGFudCBtYWludGFpbnMgaXRzIHByaW5jaXBhbApwbGFjZSBvZiBidXNp
  >> "!B64TMP!" echo bmVzcyBhbmQgc3VjaCBsaXRpZ2F0aW9uIHNoYWxsIGJlIGdvdmVybmVkIGJ5IGxhd3Mgb2YgdGhh
  >> "!B64TMP!" echo dApqdXJpc2RpY3Rpb24sIHdpdGhvdXQgcmVmZXJlbmNlIHRvIGl0cyBjb25mbGljdC1vZi1sYXcg
  >> "!B64TMP!" echo cHJvdmlzaW9ucy4KTm90aGluZyBpbiB0aGlzIFNlY3Rpb24gc2hhbGwgcHJldmVudCBhIHBhcnR5
  >> "!B64TMP!" echo J3MgYWJpbGl0eSB0byBicmluZwpjcm9zcy1jbGFpbXMgb3IgY291bnRlci1jbGFpbXMuCgo5LiBN
  >> "!B64TMP!" echo aXNjZWxsYW5lb3VzCi0tLS0tLS0tLS0tLS0tLS0KClRoaXMgTGljZW5zZSByZXByZXNlbnRzIHRo
  >> "!B64TMP!" echo ZSBjb21wbGV0ZSBhZ3JlZW1lbnQgY29uY2VybmluZyB0aGUgc3ViamVjdAptYXR0ZXIgaGVyZW9m
  >> "!B64TMP!" echo LiBJZiBhbnkgcHJvdmlzaW9uIG9mIHRoaXMgTGljZW5zZSBpcyBoZWxkIHRvIGJlCnVuZW5mb3Jj
  >> "!B64TMP!" echo ZWFibGUsIHN1Y2ggcHJvdmlzaW9uIHNoYWxsIGJlIHJlZm9ybWVkIG9ubHkgdG8gdGhlIGV4dGVu
  >> "!B64TMP!" echo dApuZWNlc3NhcnkgdG8gbWFrZSBpdCBlbmZvcmNlYWJsZS4gQW55IGxhdyBvciByZWd1bGF0aW9u
  >> "!B64TMP!" echo IHdoaWNoIHByb3ZpZGVzCnRoYXQgdGhlIGxhbmd1YWdlIG9mIGEgY29udHJhY3Qgc2hhbGwgYmUg
  >> "!B64TMP!" echo Y29uc3RydWVkIGFnYWluc3QgdGhlIGRyYWZ0ZXIKc2hhbGwgbm90IGJlIHVzZWQgdG8gY29uc3Ry
  >> "!B64TMP!" echo dWUgdGhpcyBMaWNlbnNlIGFnYWluc3QgYSBDb250cmlidXRvci4KCjEwLiBWZXJzaW9ucyBvZiB0
  >> "!B64TMP!" echo aGUgTGljZW5zZQotLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCjEwLjEuIE5ldyBWZXJzaW9u
  >> "!B64TMP!" echo cwoKTW96aWxsYSBGb3VuZGF0aW9uIGlzIHRoZSBsaWNlbnNlIHN0ZXdhcmQuIEV4Y2VwdCBhcyBw
  >> "!B64TMP!" echo cm92aWRlZCBpbiBTZWN0aW9uCjEwLjMsIG5vIG9uZSBvdGhlciB0aGFuIHRoZSBsaWNlbnNlIHN0
  >> "!B64TMP!" echo ZXdhcmQgaGFzIHRoZSByaWdodCB0byBtb2RpZnkgb3IKcHVibGlzaCBuZXcgdmVyc2lvbnMgb2Yg
  >> "!B64TMP!" echo dGhpcyBMaWNlbnNlLiBFYWNoIHZlcnNpb24gd2lsbCBiZSBnaXZlbiBhCmRpc3Rpbmd1aXNoaW5n
  >> "!B64TMP!" echo IHZlcnNpb24gbnVtYmVyLgoKMTAuMi4gRWZmZWN0IG9mIE5ldyBWZXJzaW9ucwoKWW91IG1heSBk
  >> "!B64TMP!" echo aXN0cmlidXRlIHRoZSBDb3ZlcmVkIFNvZnR3YXJlIHVuZGVyIHRoZSB0ZXJtcyBvZiB0aGUgdmVy
  >> "!B64TMP!" echo c2lvbgpvZiB0aGUgTGljZW5zZSB1bmRlciB3aGljaCBZb3Ugb3JpZ2luYWxseSByZWNlaXZlZCB0
  >> "!B64TMP!" echo aGUgQ292ZXJlZCBTb2Z0d2FyZSwKb3IgdW5kZXIgdGhlIHRlcm1zIG9mIGFueSBzdWJzZXF1ZW50
  >> "!B64TMP!" echo IHZlcnNpb24gcHVibGlzaGVkIGJ5IHRoZSBsaWNlbnNlCnN0ZXdhcmQuCgoxMC4zLiBNb2RpZmll
  >> "!B64TMP!" echo ZCBWZXJzaW9ucwoKSWYgeW91IGNyZWF0ZSBzb2Z0d2FyZSBub3QgZ292ZXJuZWQgYnkgdGhpcyBM
  >> "!B64TMP!" echo aWNlbnNlLCBhbmQgeW91IHdhbnQgdG8KY3JlYXRlIGEgbmV3IGxpY2Vuc2UgZm9yIHN1Y2ggc29m
  >> "!B64TMP!" echo dHdhcmUsIHlvdSBtYXkgY3JlYXRlIGFuZCB1c2UgYQptb2RpZmllZCB2ZXJzaW9uIG9mIHRoaXMg
  >> "!B64TMP!" echo TGljZW5zZSBpZiB5b3UgcmVuYW1lIHRoZSBsaWNlbnNlIGFuZCByZW1vdmUKYW55IHJlZmVyZW5j
  >> "!B64TMP!" echo ZXMgdG8gdGhlIG5hbWUgb2YgdGhlIGxpY2Vuc2Ugc3Rld2FyZCAoZXhjZXB0IHRvIG5vdGUgdGhh
  >> "!B64TMP!" echo dApzdWNoIG1vZGlmaWVkIGxpY2Vuc2UgZGlmZmVycyBmcm9tIHRoaXMgTGljZW5zZSkuCgoxMC40
  >> "!B64TMP!" echo LiBEaXN0cmlidXRpbmcgU291cmNlIENvZGUgRm9ybSB0aGF0IGlzIEluY29tcGF0aWJsZSBXaXRo
  >> "!B64TMP!" echo IFNlY29uZGFyeQpMaWNlbnNlcwoKSWYgWW91IGNob29zZSB0byBkaXN0cmlidXRlIFNvdXJjZSBD
  >> "!B64TMP!" echo b2RlIEZvcm0gdGhhdCBpcyBJbmNvbXBhdGlibGUgV2l0aApTZWNvbmRhcnkgTGljZW5zZXMgdW5k
  >> "!B64TMP!" echo ZXIgdGhlIHRlcm1zIG9mIHRoaXMgdmVyc2lvbiBvZiB0aGUgTGljZW5zZSwgdGhlCm5vdGljZSBk
  >> "!B64TMP!" echo ZXNjcmliZWQgaW4gRXhoaWJpdCBCIG9mIHRoaXMgTGljZW5zZSBtdXN0IGJlIGF0dGFjaGVkLgoK
  >> "!B64TMP!" echo RXhoaWJpdCBBIC0gU291cmNlIENvZGUgRm9ybSBMaWNlbnNlIE5vdGljZQotLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgogIFRoaXMgU291cmNlIENvZGUgRm9ybSBp
  >> "!B64TMP!" echo cyBzdWJqZWN0IHRvIHRoZSB0ZXJtcyBvZiB0aGUgTW96aWxsYSBQdWJsaWMKICBMaWNlbnNlLCB2
  >> "!B64TMP!" echo LiAyLjAuIElmIGEgY29weSBvZiB0aGUgTVBMIHdhcyBub3QgZGlzdHJpYnV0ZWQgd2l0aCB0aGlz
  >> "!B64TMP!" echo CiAgZmlsZSwgWW91IGNhbiBvYnRhaW4gb25lIGF0IGh0dHBzOi8vbW96aWxsYS5vcmcvTVBMLzIu
  >> "!B64TMP!" echo MC8uCgpJZiBpdCBpcyBub3QgcG9zc2libGUgb3IgZGVzaXJhYmxlIHRvIHB1dCB0aGUgbm90aWNl
  >> "!B64TMP!" echo IGluIGEgcGFydGljdWxhcgpmaWxlLCB0aGVuIFlvdSBtYXkgaW5jbHVkZSB0aGUgbm90aWNlIGlu
  >> "!B64TMP!" echo IGEgbG9jYXRpb24gKHN1Y2ggYXMgYSBMSUNFTlNFCmZpbGUgaW4gYSByZWxldmFudCBkaXJlY3Rv
  >> "!B64TMP!" echo cnkpIHdoZXJlIGEgcmVjaXBpZW50IHdvdWxkIGJlIGxpa2VseSB0byBsb29rCmZvciBzdWNoIGEg
  >> "!B64TMP!" echo bm90aWNlLgoKWW91IG1heSBhZGQgYWRkaXRpb25hbCBhY2N1cmF0ZSBub3RpY2VzIG9mIGNvcHly
  >> "!B64TMP!" echo aWdodCBvd25lcnNoaXAuCgpFeGhpYml0IEIgLSAiSW5jb21wYXRpYmxlIFdpdGggU2Vjb25kYXJ5
  >> "!B64TMP!" echo IExpY2Vuc2VzIiBOb3RpY2UKLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tCgogIFRoaXMgU291cmNlIENvZGUgRm9ybSBpcyAiSW5jb21wYXRp
  >> "!B64TMP!" echo YmxlIFdpdGggU2Vjb25kYXJ5IExpY2Vuc2VzIiwgYXMKICBkZWZpbmVkIGJ5IHRoZSBNb3ppbGxh
  >> "!B64TMP!" echo IFB1YmxpYyBMaWNlbnNlLCB2LiAyLjAuCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\LICENSE"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .gitignore ---
set "NEED_B64=1"
if exist "!SRC!\.gitignore" (
  copy /Y "!SRC!\.gitignore" "!TARGET!\.gitignore" >nul 2>&1
  if exist "!TARGET!\.gitignore" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .gitignore  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3788869521.b64"
  > "!B64TMP!" echo IyAtLS0tIEdlbmVyYXRlZCBhdCBpbnN0YWxsIHRpbWUgKGNvbnRhaW5zIHlvdXIgcG9ydHMgYW5k
  >> "!B64TMP!" echo IHNlY3JldHMpIC0tLS0KLmVudgouZW52LmJhay4qCgojIC0tLS0gV3JpdHRlbiBieSB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbGVyIGludG8gaW5zdGFsbGVkIHNraWxsIGNvcGllcyAtLS0tCiMgKHRoZSBzb3VyY2UgY29w
  >> "!B64TMP!" echo eSBpbiB0aGUgcmVwbyBtdXN0IHN0YXkgY2xlYW47IHRoZSBpbnN0YWxsZXIgcmVjb3JkcyB0aGUK
  >> "!B64TMP!" echo IyAgaW5zdGFsbCBwYXRoIGhlcmUgd2hlbiBpdCBjb3BpZXMgdGhlIHNraWxsIHRvIH4vLmFnZW50
  >> "!B64TMP!" echo cy9za2lsbHMvbG9jYWwtd2ViKQpsb2NhbC13ZWIvaW5zdGFsbC1kaXIudHh0CgojIC0tLS0gUHl0
  >> "!B64TMP!" echo aG9uIGJ5dGVjb2RlIChza2lsbCBzY3JpcHRzKSAtLS0tCl9fcHljYWNoZV9fLwoqLnB5YwoKIyAt
  >> "!B64TMP!" echo LS0tIE9TIGp1bmsgLS0tLQouRFNfU3RvcmUKVGh1bWJzLmRiCmRlc2t0b3AuaW5pCgojIC0tLS0g
  >> "!B64TMP!" echo TG9ncyAtLS0tCioubG9nCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.gitignore"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .gitattributes ---
set "NEED_B64=1"
if exist "!SRC!\.gitattributes" (
  copy /Y "!SRC!\.gitattributes" "!TARGET!\.gitattributes" >nul 2>&1
  if exist "!TARGET!\.gitattributes" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .gitattributes  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2379549047.b64"
  > "!B64TMP!" echo IyBOb3JtYWxpemUgdGV4dCBmaWxlcyBpbiB0aGUgcmVwbzsga2VlcCBwbGF0Zm9ybS1uYXRpdmUg
  >> "!B64TMP!" echo bGluZSBlbmRpbmdzIG9uIGNoZWNrb3V0CiogdGV4dD1hdXRvCgojIFdpbmRvd3MgYmF0Y2ggZmls
  >> "!B64TMP!" echo ZXMgbXVzdCBrZWVwIENSTEYgd29ya2luZyBjb3BpZXMKKi5iYXQgdGV4dCBlb2w9Y3JsZgoqLmNt
  >> "!B64TMP!" echo ZCB0ZXh0IGVvbD1jcmxmCioucHMxIHRleHQgZW9sPWNybGYKCiMgVW5peCBzY3JpcHRzIG11c3Qg
  >> "!B64TMP!" echo c3RheSBMRgoqLnNoIHRleHQgZW9sPWxmCioucHkgdGV4dCBlb2w9bGYKKi55bWwgdGV4dCBlb2w9
  >> "!B64TMP!" echo bGYKKi55YW1sIHRleHQgZW9sPWxmCgojIERvY3MKKi5tZCB0ZXh0CkxJQ0VOU0UgdGV4dAo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.gitattributes"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Run.bat ---
set "NEED_B64=1"
if exist "!SRC!\Run.bat" (
  copy /Y "!SRC!\Run.bat" "!TARGET!\Run.bat" >nul 2>&1
  if exist "!TARGET!\Run.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Run.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1962629694.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFJ1bg0KDQpjZCAvZCAiJX5kcDAiDQoNCndoZXJlIGRv
  >> "!B64TMP!" echo Y2tlciA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2NrZXIg
  >> "!B64TMP!" echo aXMgbm90IGluc3RhbGxlZCBvciBub3Qgb24gUEFUSC4gSW5zdGFsbCBEb2NrZXIgRGVza3RvcCBm
  >> "!B64TMP!" echo aXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQpkb2NrZXIgaW5mbyA+bnVsIDI+JjENCmlm
  >> "!B64TMP!" echo IGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5u
  >> "!B64TMP!" echo aW5nLiBTdGFydCBEb2NrZXIgRGVza3RvcCBmaXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQop
  >> "!B64TMP!" echo DQoNCmlmIG5vdCBleGlzdCAiLmVudiIgKA0KICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZv
  >> "!B64TMP!" echo dW5kIGluIHRoaXMgZm9sZGVyLg0KICBlY2hvICAgUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJh
  >> "!B64TMP!" echo dCBmaXJzdCB0byBjcmVhdGUgdGhlIGNvbmZpZ3VyYXRpb24uDQogIHBhdXNlDQogIGV4aXQgL2Ig
  >> "!B64TMP!" echo MQ0KKQ0KDQplY2hvIFN0YXJ0aW5nIExvY2FsIFNlYXJjaCAoRmlyZWNyYXdsICsgU2VhclhORyku
  >> "!B64TMP!" echo Li4NCmRvY2tlciBjb21wb3NlIHVwIC1kDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBl
  >> "!B64TMP!" echo Y2hvIFtFUlJPUl0gRmFpbGVkIHRvIHN0YXJ0LiBTZWUgbWVzc2FnZXMgYWJvdmUuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvLg0KZWNobyBMb2NhbCBTZWFyY2ggaXMgcnVubmluZzoN
  >> "!B64TMP!" echo CmVjaG8gICBTZWFyWE5HOiAgIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MCAgICAgIF4oY2hhbmdlIGlu
  >> "!B64TMP!" echo IC5lbnZeKQ0KZWNobyAgIEZpcmVjcmF3bDogaHR0cDovL2xvY2FsaG9zdDo5OTkxICAgICAgXihj
  >> "!B64TMP!" echo aGFuZ2UgaW4gLmVudl4pDQplY2hvLg0KZWNobyBPcGVuIHRoZSBTZWFyWE5HIFVJIGluIHlvdXIg
  >> "!B64TMP!" echo YnJvd3Nlciwgb3IgcXVlcnkgdGhlIEpTT04gQVBJIGZyb20geW91ciBtb2RlbHMuDQplY2hvIFVz
  >> "!B64TMP!" echo ZSBTdG9wLmJhdCB0byBzdG9wIHRoZSBzdGFjay4NCmVjaG8uDQpwYXVzZQ0KZXhpdCAvYiAwDQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Run.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Stop.bat ---
set "NEED_B64=1"
if exist "!SRC!\Stop.bat" (
  copy /Y "!SRC!\Stop.bat" "!TARGET!\Stop.bat" >nul 2>&1
  if exist "!TARGET!\Stop.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Stop.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2263657140.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFN0b3ANCg0KY2QgL2QgIiV+ZHAwIg0KDQp3aGVyZSBk
  >> "!B64TMP!" echo b2NrZXIgPm51bCAyPiYxDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvIFtFUlJPUl0gRG9ja2Vy
  >> "!B64TMP!" echo IGlzIG5vdCBpbnN0YWxsZWQgb3Igbm90IG9uIFBBVEguDQogIHBhdXNlDQogIGV4aXQgL2IgMQ0K
  >> "!B64TMP!" echo KQ0KDQppZiBub3QgZXhpc3QgIi5lbnYiICgNCiAgZWNobyBbRVJST1JdIE5vIC5lbnYgZmlsZSBm
  >> "!B64TMP!" echo b3VuZCBpbiB0aGlzIGZvbGRlci4gTm90aGluZyB0byBzdG9wLg0KICBwYXVzZQ0KICBleGl0IC9i
  >> "!B64TMP!" echo IDENCikNCg0KZWNobyBTdG9wcGluZyBMb2NhbCBTZWFyY2ggY29udGFpbmVycyAoZGF0YSBpcyBw
  >> "!B64TMP!" echo cmVzZXJ2ZWQpLi4uDQpkb2NrZXIgY29tcG9zZSBkb3duDQppZiBlcnJvcmxldmVsIDEgKA0KICBl
  >> "!B64TMP!" echo Y2hvLg0KICBlY2hvIFtFUlJPUl0gRmFpbGVkIHRvIHN0b3AuIFNlZSBtZXNzYWdlcyBhYm92ZS4N
  >> "!B64TMP!" echo CiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQoNCmVjaG8uDQplY2hvIExvY2FsIFNlYXJjaCBzdG9w
  >> "!B64TMP!" echo cGVkLiBEYXRhIGlzIHByZXNlcnZlZCBpbiBEb2NrZXIgdm9sdW1lcy4NCmVjaG8gUnVuIFJ1bi5i
  >> "!B64TMP!" echo YXQgdG8gc3RhcnQgaXQgYWdhaW4uDQplY2hvLg0KcGF1c2UNCmV4aXQgL2IgMA0K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Stop.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Update.bat ---
set "NEED_B64=1"
if exist "!SRC!\Update.bat" (
  copy /Y "!SRC!\Update.bat" "!TARGET!\Update.bat" >nul 2>&1
  if exist "!TARGET!\Update.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Update.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3559231701.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFVwZGF0ZQ0KDQpjZCAvZCAiJX5kcDAiDQoNCndoZXJl
  >> "!B64TMP!" echo IGRvY2tlciA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2Nr
  >> "!B64TMP!" echo ZXIgaXMgbm90IGluc3RhbGxlZCBvciBub3Qgb24gUEFUSC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAx
  >> "!B64TMP!" echo DQopDQpkb2NrZXIgaW5mbyA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VS
  >> "!B64TMP!" echo Uk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nLiBTdGFydCBEb2NrZXIgRGVza3RvcCBm
  >> "!B64TMP!" echo aXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQoNCmlmIG5vdCBleGlzdCAiLmVudiIgKA0K
  >> "!B64TMP!" echo ICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kIGluIHRoaXMgZm9sZGVyLg0KICBlY2hv
  >> "!B64TMP!" echo ICAgUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCBmaXJzdCB0byBjcmVhdGUgdGhlIGNvbmZp
  >> "!B64TMP!" echo Z3VyYXRpb24uDQogIHBhdXNlDQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvIFVwZGF0aW5nIExvY2Fs
  >> "!B64TMP!" echo IFNlYXJjaC4uLg0KZWNoby4NCmVjaG8gWzEvM10gUHVsbGluZyBsYXRlc3QgaW1hZ2VzLi4uDQpk
  >> "!B64TMP!" echo b2NrZXIgY29tcG9zZSBwdWxsDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBlY2hvIFtX
  >> "!B64TMP!" echo QVJOSU5HXSBTb21lIGltYWdlcyBmYWlsZWQgdG8gcHVsbC4gQ29udGludWluZyB3aXRoIHdoYXQg
  >> "!B64TMP!" echo aXMgYXZhaWxhYmxlLg0KKQ0KDQplY2hvLg0KZWNobyBbMi8zXSBSZWNyZWF0aW5nIGNvbnRhaW5l
  >> "!B64TMP!" echo cnMgd2l0aCB1cGRhdGVkIGltYWdlcyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uDQpkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZSB1cCAtZA0KaWYgZXJyb3JsZXZlbCAxICgNCiAgZWNoby4NCiAgZWNobyBbRVJST1JdIEZh
  >> "!B64TMP!" echo aWxlZCB0byByZWNyZWF0ZSBjb250YWluZXJzLiBTZWUgbWVzc2FnZXMgYWJvdmUuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvLg0KZWNobyBbMy8zXSBSZWZyZXNoaW5nIHRoZSBsb2Nh
  >> "!B64TMP!" echo bC13ZWItc2VhcmNoIGFnZW50IHNraWxsLi4uDQppZiBleGlzdCAiJX5kcDBsb2NhbC13ZWItc2Vh
  >> "!B64TMP!" echo cmNoXFNLSUxMLm1kIiAoDQogIHNldCAiU0tJTExfRElSPSVVU0VSUFJPRklMRSVcLmFnZW50c1xz
  >> "!B64TMP!" echo a2lsbHNcbG9jYWwtd2ViLXNlYXJjaCINCiAgaWYgZXhpc3QgIiFTS0lMTF9ESVIhIiByZCAvcyAv
  >> "!B64TMP!" echo cSAiIVNLSUxMX0RJUiEiDQogIGlmIG5vdCBleGlzdCAiJVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNr
  >> "!B64TMP!" echo aWxscyIgbWtkaXIgIiVVU0VSUFJPRklMRSVcLmFnZW50c1xza2lsbHMiDQogIHhjb3B5IC9FIC9J
  >> "!B64TMP!" echo IC9ZIC9RICIlfmRwMGxvY2FsLXdlYi1zZWFyY2giICIhU0tJTExfRElSISIgPm51bA0KICBpZiBl
  >> "!B64TMP!" echo cnJvcmxldmVsIDEgKA0KICAgIGVjaG8gICBbV0FSTklOR10gQ291bGQgbm90IGNvcHkgdGhlIHNr
  >> "!B64TMP!" echo aWxsIHRvICFTS0lMTF9ESVIhLg0KICApIGVsc2UgKA0KICAgID4gIiFTS0lMTF9ESVIhXGluc3Rh
  >> "!B64TMP!" echo bGwtZGlyLnR4dCIgZWNobyAlfmRwMA0KICAgIGVjaG8gICBTa2lsbCByZWZyZXNoZWQgYXQgIVNL
  >> "!B64TMP!" echo SUxMX0RJUiENCiAgKQ0KKSBlbHNlICgNCiAgZWNobyAgIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwg
  >> "!B64TMP!" echo c291cmNlIG5vdCBmb3VuZCBpbiB0aGlzIGZvbGRlciAtIHNraXBwaW5nLg0KKQ0KDQplY2hvLg0K
  >> "!B64TMP!" echo ZWNobyBVcGRhdGUgY29tcGxldGUuIERhdGEgdm9sdW1lcyB3ZXJlIHByZXNlcnZlZC4NCmVjaG8g
  >> "!B64TMP!" echo ICAtIElmIHlvdSBjaGFuZ2VkIHBvcnRzIG9yIExMTSBzZXR0aW5ncyBpbiAuZW52LCB0aGV5IGFy
  >> "!B64TMP!" echo ZSBub3cgYXBwbGllZC4NCmVjaG8gICAtIFRoZSBsb2NhbC13ZWItc2VhcmNoIHNraWxsIHdhcyBy
  >> "!B64TMP!" echo ZS1zeW5jZWQgZnJvbSB0aGlzIGZvbGRlci4NCmVjaG8gICAtIFRvIHVwZGF0ZSB0aGUgU2VhclhO
  >> "!B64TMP!" echo RyBzZXR0aW5ncy55bWwgb3IgZG9ja2VyLWNvbXBvc2UueW1sIHRlbXBsYXRlLA0KZWNobyAgICAg
  >> "!B64TMP!" echo cmUtcnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCAoaXQgYmFja3MgdXAgeW91ciBjdXJyZW50
  >> "!B64TMP!" echo IC5lbnYpLg0KZWNoby4NCnBhdXNlDQpleGl0IC9iIDANCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Update.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Uninstall.bat ---
set "NEED_B64=1"
if exist "!SRC!\Uninstall.bat" (
  copy /Y "!SRC!\Uninstall.bat" "!TARGET!\Uninstall.bat" >nul 2>&1
  if exist "!TARGET!\Uninstall.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Uninstall.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4046764878.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFVuaW5zdGFsbA0KDQpjZCAvZCAiJX5kcDAiDQoNCndo
  >> "!B64TMP!" echo ZXJlIGRvY2tlciA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBE
  >> "!B64TMP!" echo b2NrZXIgaXMgbm90IGluc3RhbGxlZCBvciBub3Qgb24gUEFUSC4NCiAgZWNobyAgIFlvdSBjYW4g
  >> "!B64TMP!" echo bWFudWFsbHkgZGVsZXRlIHRoaXMgZm9sZGVyIHRvIHJlbW92ZSB0aGUgZmlsZXMuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQppZiBub3QgZXhpc3QgIi5lbnYiICgNCiAgZWNobyBbRVJST1Jd
  >> "!B64TMP!" echo IE5vIC5lbnYgZmlsZSBmb3VuZCBpbiB0aGlzIGZvbGRlci4gTm90aGluZyB0byB1bmluc3RhbGwu
  >> "!B64TMP!" echo DQogIHBhdXNlDQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvID09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQ0KZWNobyAgIFVuaW5zdGFsbCBM
  >> "!B64TMP!" echo b2NhbCBTZWFyY2gNCmVjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09DQplY2hvIFRoaXMgd2lsbDoNCmVjaG8gICAxLiBTdG9wIGFu
  >> "!B64TMP!" echo ZCByZW1vdmUgYWxsIExvY2FsIFNlYXJjaCBjb250YWluZXJzLg0KZWNobyAgIDIuIFJlbW92ZSB0
  >> "!B64TMP!" echo aGUgRG9ja2VyIFZPTFVNRVMgKEZpcmVjcmF3bCBqb2Igc3RhdGUsIHJlZGlzIGNhY2hlLA0KZWNo
  >> "!B64TMP!" echo byAgICAgIHJhYmJpdG1xL3Bvc3RncmVzIGRhdGEpLiBUaGlzIGRlbGV0ZXMgYWxsIHN0b3JlZCBk
  >> "!B64TMP!" echo YXRhLg0KZWNobyAgIDMuIFJlbW92ZSB0aGUgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBza2lsbCBm
  >> "!B64TMP!" echo cm9tDQplY2hvICAgICAgJVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNraWxsc1xsb2NhbC13ZWItc2Vh
  >> "!B64TMP!" echo cmNoDQplY2hvICAgNC4gKE9wdGlvbmFsKSBEZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyIGFuZCBh
  >> "!B64TMP!" echo bGwgaXRzIGZpbGVzLg0KZWNoby4NCmVjaG8gICBQdWxsZWQgRG9ja2VyIGltYWdlcyBhcmUgTk9U
  >> "!B64TMP!" echo IHJlbW92ZWQgKHVzZSAiZG9ja2VyIGltYWdlIHBydW5lIiB0bw0KZWNobyAgIHJlY2xhaW0gdGhh
  >> "!B64TMP!" echo dCBkaXNrIHNwYWNlIHNlcGFyYXRlbHkpLg0KZWNoby4NCnNldCAiQ09ORklSTT0iDQpzZXQgL3Ag
  >> "!B64TMP!" echo Q09ORklSTT0iQ29udGludWUgd2l0aCB1bmluc3RhbGw/IFt5L05dOiAiDQppZiAvaSBub3QgIiFD
  >> "!B64TMP!" echo T05GSVJNISI9PSJ5IiAoIGVjaG8gVW5pbnN0YWxsIGNhbmNlbGxlZC4gJiBwYXVzZSAmIGV4aXQg
  >> "!B64TMP!" echo L2IgMCApDQoNCmVjaG8uDQplY2hvIFN0b3BwaW5nIGFuZCByZW1vdmluZyBjb250YWluZXJzICsg
  >> "!B64TMP!" echo dm9sdW1lcy4uLg0KZG9ja2VyIGNvbXBvc2UgZG93biAtdiAtLXJlbW92ZS1vcnBoYW5zDQppZiBl
  >> "!B64TMP!" echo cnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBlY2hvIFtXQVJOSU5HXSBkb2NrZXIgY29tcG9zZSBk
  >> "!B64TMP!" echo b3duIHJlcG9ydGVkIGVycm9ycy4NCiAgZWNobyAgIFlvdSBtYXkgbmVlZCB0byByZW1vdmUgbGVm
  >> "!B64TMP!" echo dG92ZXIgY29udGFpbmVycyBtYW51YWxseSwgZS5nLjoNCiAgZWNobyAgICAgZG9ja2VyIHJtIC1m
  >> "!B64TMP!" echo IGxvY2FsLXNlYXJjaC1maXJlY3Jhd2wgbG9jYWwtc2VhcmNoLXNlYXJ4bmcNCiAgZWNobyAgICAg
  >> "!B64TMP!" echo ZG9ja2VyIHJtIC1mIGxvY2FsLXNlYXJjaC1yZWRpcyBsb2NhbC1zZWFyY2gtcmFiYml0bXENCiAg
  >> "!B64TMP!" echo ZWNobyAgICAgZG9ja2VyIHJtIC1mIGxvY2FsLXNlYXJjaC1wb3N0Z3JlcyBsb2NhbC1zZWFyY2gt
  >> "!B64TMP!" echo cGxheXdyaWdodA0KKQ0KDQplY2hvLg0KZWNobyBDb250YWluZXJzIGFuZCB2b2x1bWVzIHJlbW92
  >> "!B64TMP!" echo ZWQuDQplY2hvLg0KZWNobyBSZW1vdmluZyB0aGUgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBza2ls
  >> "!B64TMP!" echo bC4uLg0Kc2V0ICJTS0lMTF9ESVI9JVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNraWxsc1xsb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoIg0KaWYgZXhpc3QgIiFTS0lMTF9ESVIhIiAoDQogIHJkIC9zIC9xICIhU0tJTExf
  >> "!B64TMP!" echo RElSISINCiAgZWNobyAgIFJlbW92ZWQgIVNLSUxMX0RJUiENCikgZWxzZSAoDQogIGVjaG8gICBT
  >> "!B64TMP!" echo a2lsbCBub3QgZm91bmQgXihhbHJlYWR5IHJlbW92ZWReKSAtIG5vdGhpbmcgdG8gZG8uDQopDQpl
  >> "!B64TMP!" echo Y2hvLg0Kc2V0ICJERUxGSUxFUz0iDQpzZXQgL3AgREVMRklMRVM9IkFsc28gZGVsZXRlIHRoZSBp
  >> "!B64TMP!" echo bnN0YWxsIGZvbGRlciBhbmQgQUxMIGl0cyBmaWxlcz8gW3kvTl06ICINCmlmIC9pIG5vdCAiIURF
  >> "!B64TMP!" echo TEZJTEVTISI9PSJ5IiAoDQogIGVjaG8uDQogIGVjaG8gVW5pbnN0YWxsIGZpbmlzaGVkLiBUaGUg
  >> "!B64TMP!" echo Zm9sZGVyIHdhcyBrZXB0Og0KICBlY2hvICAgJUNEJQ0KICBlY2hvICAgWW91IGNhbiBkZWxldGUg
  >> "!B64TMP!" echo aXQgbWFudWFsbHkgaWYgeW91IG5vIGxvbmdlciBuZWVkIHRoZSBzY3JpcHRzLg0KICBlY2hvLg0K
  >> "!B64TMP!" echo ICBwYXVzZQ0KICBleGl0IC9iIDANCikNCg0KY2QgL2QgIiVVU0VSUFJPRklMRSUiDQplY2hvIERl
  >> "!B64TMP!" echo bGV0aW5nIGluc3RhbGwgZm9sZGVyOiAlfmRwMA0KcmQgL3MgL3EgIiV+ZHAwIg0KZWNoby4NCmVj
  >> "!B64TMP!" echo aG8gVW5pbnN0YWxsIGNvbXBsZXRlLiBHb29kYnllIQ0KZWNoby4NCnBhdXNlDQpleGl0IC9iIDAN
  >> "!B64TMP!" echo Cg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Uninstall.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- run.sh ---
set "NEED_B64=1"
if exist "!SRC!\run.sh" (
  copy /Y "!SRC!\run.sh" "!TARGET!\run.sh" >nul 2>&1
  if exist "!TARGET!\run.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] run.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1749764691.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFN0YXJ0IHRoZSBMb2NhbCBTZWFyY2ggc3RhY2sgKEZpcmVj
  >> "!B64TMP!" echo cmF3bCArIFNlYXJYTkcpLgpzZXQgLXUKY2QgIiQoZGlybmFtZSAiJDAiKSIgfHwgZXhpdCAxCgpp
  >> "!B64TMP!" echo ZiAhIGNvbW1hbmQgLXYgZG9ja2VyID4vZGV2L251bGwgMj4mMTsgdGhlbgogIGVjaG8gIltFUlJP
  >> "!B64TMP!" echo Ul0gRG9ja2VyIGlzIG5vdCBpbnN0YWxsZWQuIFNlZSBSRUFETUUubWQuIiA+JjI7IGV4aXQgMQpm
  >> "!B64TMP!" echo aQppZiAhIGRvY2tlciBpbmZvID4vZGV2L251bGwgMj4mMTsgdGhlbgogIGVjaG8gIltFUlJPUl0g
  >> "!B64TMP!" echo RG9ja2VyIGVuZ2luZSBpcyBub3QgcnVubmluZy4gU3RhcnQgRG9ja2VyIGZpcnN0LiIgPiYyOyBl
  >> "!B64TMP!" echo eGl0IDEKZmkKaWYgZG9ja2VyIGNvbXBvc2UgdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4g
  >> "!B64TMP!" echo REM9ImRvY2tlciBjb21wb3NlIgplbGlmIGNvbW1hbmQgLXYgZG9ja2VyLWNvbXBvc2UgPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuIERDPSJkb2NrZXItY29tcG9zZSIKZWxzZSBlY2hvICJbRVJST1JdIERv
  >> "!B64TMP!" echo Y2tlciBDb21wb3NlIG5vdCBmb3VuZC4iID4mMjsgZXhpdCAxOyBmaQoKaWYgWyAhIC1mICIuZW52
  >> "!B64TMP!" echo IiBdOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBObyAuZW52IGZpbGUgZm91bmQgaW4gdGhpcyBmb2xk
  >> "!B64TMP!" echo ZXIuIFJ1biBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCBmaXJzdC4iID4mMgogIGV4aXQgMQpmaQoK
  >> "!B64TMP!" echo ZWNobyAiU3RhcnRpbmcgTG9jYWwgU2VhcmNoIChGaXJlY3Jhd2wgKyBTZWFyWE5HKS4uLiIKJERD
  >> "!B64TMP!" echo IHVwIC1kIHx8IHsgZWNobyAiW0VSUk9SXSBGYWlsZWQgdG8gc3RhcnQuIiA+JjI7IGV4aXQgMTsg
  >> "!B64TMP!" echo fQoKZWNobwplY2hvICJMb2NhbCBTZWFyY2ggaXMgcnVubmluZy4iCmVjaG8gIiAgU2VhclhORzog
  >> "!B64TMP!" echo ICBodHRwOi8vbG9jYWxob3N0OiR7U0VBUlhOR19QT1JUOi05OTkwfSIKZWNobyAiICBGaXJlY3Jh
  >> "!B64TMP!" echo d2w6IGh0dHA6Ly9sb2NhbGhvc3Q6JHtGSVJFQ1JBV0xfUE9SVDotOTk5MX0iCmVjaG8gIlJ1biAu
  >> "!B64TMP!" echo L3N0b3Auc2ggdG8gc3RvcCB0aGUgc3RhY2suIgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\run.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- stop.sh ---
set "NEED_B64=1"
if exist "!SRC!\stop.sh" (
  copy /Y "!SRC!\stop.sh" "!TARGET!\stop.sh" >nul 2>&1
  if exist "!TARGET!\stop.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] stop.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3584733866.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFN0b3AgdGhlIExvY2FsIFNlYXJjaCBzdGFjayAoY29udGFp
  >> "!B64TMP!" echo bmVycyByZW1vdmVkLCBkYXRhIHByZXNlcnZlZCkuCnNldCAtdQpjZCAiJChkaXJuYW1lICIkMCIp
  >> "!B64TMP!" echo IiB8fCBleGl0IDEKCmlmICEgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYvbnVsbCAyPiYxOyB0aGVu
  >> "!B64TMP!" echo CiAgZWNobyAiW0VSUk9SXSBEb2NrZXIgaXMgbm90IGluc3RhbGxlZC4iID4mMjsgZXhpdCAxCmZp
  >> "!B64TMP!" echo CmlmIGRvY2tlciBjb21wb3NlIHZlcnNpb24gPi9kZXYvbnVsbCAyPiYxOyB0aGVuIERDPSJkb2Nr
  >> "!B64TMP!" echo ZXIgY29tcG9zZSIKZWxpZiBjb21tYW5kIC12IGRvY2tlci1jb21wb3NlID4vZGV2L251bGwgMj4m
  >> "!B64TMP!" echo MTsgdGhlbiBEQz0iZG9ja2VyLWNvbXBvc2UiCmVsc2UgZWNobyAiW0VSUk9SXSBEb2NrZXIgQ29t
  >> "!B64TMP!" echo cG9zZSBub3QgZm91bmQuIiA+JjI7IGV4aXQgMTsgZmkKCmlmIFsgISAtZiAiLmVudiIgXTsgdGhl
  >> "!B64TMP!" echo bgogIGVjaG8gIltFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kLiBOb3RoaW5nIHRvIHN0b3AuIiA+
  >> "!B64TMP!" echo JjI7IGV4aXQgMQpmaQoKZWNobyAiU3RvcHBpbmcgTG9jYWwgU2VhcmNoIGNvbnRhaW5lcnMgKGRh
  >> "!B64TMP!" echo dGEgaXMgcHJlc2VydmVkKS4uLiIKJERDIGRvd24gfHwgeyBlY2hvICJbRVJST1JdIEZhaWxlZCB0
  >> "!B64TMP!" echo byBzdG9wLiIgPiYyOyBleGl0IDE7IH0KCmVjaG8KZWNobyAiTG9jYWwgU2VhcmNoIHN0b3BwZWQu
  >> "!B64TMP!" echo IERhdGEgaXMgcHJlc2VydmVkIGluIERvY2tlciB2b2x1bWVzLiIKZWNobyAiUnVuIC4vcnVuLnNo
  >> "!B64TMP!" echo IHRvIHN0YXJ0IGl0IGFnYWluLiIK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\stop.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- update.sh ---
set "NEED_B64=1"
if exist "!SRC!\update.sh" (
  copy /Y "!SRC!\update.sh" "!TARGET!\update.sh" >nul 2>&1
  if exist "!TARGET!\update.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] update.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS960388646.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFVwZGF0ZSB0aGUgTG9jYWwgU2VhcmNoIHN0YWNrOiBwdWxs
  >> "!B64TMP!" echo IGxhdGVzdCBpbWFnZXMsIHJlY3JlYXRlIGNvbnRhaW5lcnMsCiMgYW5kIHJlLXN5bmMgdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2ggYWdlbnQgc2tpbGwuIERhdGEgdm9sdW1lcyBhcmUgcHJlc2VydmVkLiBF
  >> "!B64TMP!" echo ZGl0cwojIHRvIC5lbnYgKHBvcnRzLCBMTE0pIGFyZSBhbHNvIGFwcGxpZWQuCnNldCAtdQpjZCAi
  >> "!B64TMP!" echo JChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKCmlmICEgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBEb2NrZXIgaXMgbm90IGluc3RhbGxlZC4i
  >> "!B64TMP!" echo ID4mMjsgZXhpdCAxCmZpCmlmICEgZG9ja2VyIGluZm8gPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAg
  >> "!B64TMP!" echo ZWNobyAiW0VSUk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nLiBTdGFydCBEb2NrZXIg
  >> "!B64TMP!" echo Zmlyc3QuIiA+JjI7IGV4aXQgMQpmaQppZiBkb2NrZXIgY29tcG9zZSB2ZXJzaW9uID4vZGV2L251
  >> "!B64TMP!" echo bGwgMj4mMTsgdGhlbiBEQz0iZG9ja2VyIGNvbXBvc2UiCmVsaWYgY29tbWFuZCAtdiBkb2NrZXIt
  >> "!B64TMP!" echo Y29tcG9zZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlci1jb21wb3NlIgplbHNlIGVj
  >> "!B64TMP!" echo aG8gIltFUlJPUl0gRG9ja2VyIENvbXBvc2Ugbm90IGZvdW5kLiIgPiYyOyBleGl0IDE7IGZpCgpp
  >> "!B64TMP!" echo ZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJST1JdIE5vIC5lbnYgZmlsZSBmb3Vu
  >> "!B64TMP!" echo ZC4gUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGZpcnN0LiIgPiYyCiAgZXhpdCAxCmZpCgpl
  >> "!B64TMP!" echo Y2hvICJVcGRhdGluZyBMb2NhbCBTZWFyY2guLi4iCmVjaG8KZWNobyAiWzEvM10gUHVsbGluZyBs
  >> "!B64TMP!" echo YXRlc3QgaW1hZ2VzLi4uIgokREMgcHVsbCB8fCBlY2hvICJbV0FSTklOR10gU29tZSBpbWFnZXMg
  >> "!B64TMP!" echo ZmFpbGVkIHRvIHB1bGwuIENvbnRpbnVpbmcuIgoKZWNobwplY2hvICJbMi8zXSBSZWNyZWF0aW5n
  >> "!B64TMP!" echo IGNvbnRhaW5lcnMgd2l0aCB1cGRhdGVkIGltYWdlcyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uIgok
  >> "!B64TMP!" echo REMgdXAgLWQgfHwgeyBlY2hvICJbRVJST1JdIEZhaWxlZCB0byByZWNyZWF0ZSBjb250YWluZXJz
  >> "!B64TMP!" echo LiIgPiYyOyBleGl0IDE7IH0KCmVjaG8KZWNobyAiWzMvM10gUmVmcmVzaGluZyB0aGUgbG9jYWwt
  >> "!B64TMP!" echo d2ViLXNlYXJjaCBhZ2VudCBza2lsbC4uLiIKaWYgWyAtZiAiLi9sb2NhbC13ZWItc2VhcmNoL1NL
  >> "!B64TMP!" echo SUxMLm1kIiBdOyB0aGVuCiAgU0tJTExfRElSPSIkSE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoIgogIHJtIC1yZiAiJFNLSUxMX0RJUiIKICBta2RpciAtcCAiJEhPTUUvLmFnZW50
  >> "!B64TMP!" echo cy9za2lsbHMiCiAgaWYgY3AgLXIgLi9sb2NhbC13ZWItc2VhcmNoICIkU0tJTExfRElSIjsgdGhl
  >> "!B64TMP!" echo bgogICAgcHJpbnRmICclc1xuJyAiJChwd2QpIiA+ICIkU0tJTExfRElSL2luc3RhbGwtZGlyLnR4
  >> "!B64TMP!" echo dCIKICAgIGVjaG8gIiAgU2tpbGwgcmVmcmVzaGVkIGF0ICRTS0lMTF9ESVIiCiAgZWxzZQogICAg
  >> "!B64TMP!" echo ZWNobyAiICBbV0FSTklOR10gQ291bGQgbm90IGNvcHkgdGhlIHNraWxsIHRvICRTS0lMTF9ESVIu
  >> "!B64TMP!" echo IgogIGZpCmVsc2UKICBlY2hvICIgIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgc291cmNlIG5vdCBm
  >> "!B64TMP!" echo b3VuZCBpbiB0aGlzIGZvbGRlciAtIHNraXBwaW5nLiIKZmkKCmVjaG8KZWNobyAiVXBkYXRlIGNv
  >> "!B64TMP!" echo bXBsZXRlLiBEYXRhIHZvbHVtZXMgd2VyZSBwcmVzZXJ2ZWQuIgplY2hvICIgIC0gUG9ydCAvIExM
  >> "!B64TMP!" echo TSBjaGFuZ2VzIGluIC5lbnYgYXJlIG5vdyBhcHBsaWVkLiIKZWNobyAiICAtIFRoZSBsb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoIHNraWxsIHdhcyByZS1zeW5jZWQgZnJvbSB0aGlzIGZvbGRlci4iCmVjaG8gIiAg
  >> "!B64TMP!" echo LSBUbyB1cGRhdGUgdGhlIFNlYXJYTkcgc2V0dGluZ3MueW1sIG9yIGRvY2tlci1jb21wb3NlLnlt
  >> "!B64TMP!" echo bCB0ZW1wbGF0ZSwiCmVjaG8gIiAgICByZS1ydW4gaW5zdGFsbC1sb2NhbC1zZWFyY2guc2ggKGl0
  >> "!B64TMP!" echo IGJhY2tzIHVwIHlvdXIgY3VycmVudCAuZW52KS4iCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\update.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- uninstall.sh ---
set "NEED_B64=1"
if exist "!SRC!\uninstall.sh" (
  copy /Y "!SRC!\uninstall.sh" "!TARGET!\uninstall.sh" >nul 2>&1
  if exist "!TARGET!\uninstall.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] uninstall.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3708239055.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFVuaW5zdGFsbCB0aGUgTG9jYWwgU2VhcmNoIHN0YWNrLgoj
  >> "!B64TMP!" echo ICAgLSBzdG9wcyAmIHJlbW92ZXMgY29udGFpbmVycwojICAgLSByZW1vdmVzIERvY2tlciB2b2x1
  >> "!B64TMP!" echo bWVzIChGaXJlY3Jhd2wgam9iIHN0YXRlLCByZWRpcywgcmFiYml0bXEsIHBvc3RncmVzKQojICAg
  >> "!B64TMP!" echo LSByZW1vdmVzIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsICh+Ly5hZ2VudHMvc2tp
  >> "!B64TMP!" echo bGxzL2xvY2FsLXdlYi1zZWFyY2gpCiMgICAtIG9wdGlvbmFsbHkgZGVsZXRlcyB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bCBmb2xkZXIKc2V0IC11CmNkICIkKGRpcm5hbWUgIiQwIikiIHx8IGV4aXQgMQpsb3dlcigpIHsg
  >> "!B64TMP!" echo cHJpbnRmICclcycgIiQxIiB8IHRyICdbOnVwcGVyOl0nICdbOmxvd2VyOl0nOyB9ICAjIGJhc2gt
  >> "!B64TMP!" echo My4yIChtYWNPUykgc2FmZQoKaWYgISBjb21tYW5kIC12IGRvY2tlciA+L2Rldi9udWxsIDI+JjE7
  >> "!B64TMP!" echo IHRoZW4KICBlY2hvICJbRVJST1JdIERvY2tlciBpcyBub3QgaW5zdGFsbGVkLiBZb3UgY2FuIGRl
  >> "!B64TMP!" echo bGV0ZSB0aGlzIGZvbGRlciBtYW51YWxseS4iID4mMgogIGV4aXQgMQpmaQppZiBkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZSB2ZXJzaW9uID4vZGV2L251bGwgMj4mMTsgdGhlbiBEQz0iZG9ja2VyIGNvbXBvc2UiCmVs
  >> "!B64TMP!" echo aWYgY29tbWFuZCAtdiBkb2NrZXItY29tcG9zZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRv
  >> "!B64TMP!" echo Y2tlci1jb21wb3NlIgplbHNlIGVjaG8gIltFUlJPUl0gRG9ja2VyIENvbXBvc2Ugbm90IGZvdW5k
  >> "!B64TMP!" echo LiIgPiYyOyBleGl0IDE7IGZpCgppZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJS
  >> "!B64TMP!" echo T1JdIE5vIC5lbnYgZmlsZSBmb3VuZC4gTm90aGluZyB0byB1bmluc3RhbGwuIiA+JjI7IGV4aXQg
  >> "!B64TMP!" echo MQpmaQoKY2F0IDw8J01TRycKPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09CiAgVW5pbnN0YWxsIExvY2FsIFNlYXJjaAo9PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KVGhpcyB3
  >> "!B64TMP!" echo aWxsOgogIDEuIFN0b3AgYW5kIHJlbW92ZSBhbGwgTG9jYWwgU2VhcmNoIGNvbnRhaW5lcnMuCiAg
  >> "!B64TMP!" echo Mi4gUmVtb3ZlIHRoZSBEb2NrZXIgVk9MVU1FUyAoRmlyZWNyYXdsIGpvYiBzdGF0ZSwgcmVkaXMg
  >> "!B64TMP!" echo Y2FjaGUsCiAgICAgcmFiYml0bXEvcG9zdGdyZXMgZGF0YSkuIFRoaXMgZGVsZXRlcyBhbGwgc3Rv
  >> "!B64TMP!" echo cmVkIGRhdGEuCiAgMy4gUmVtb3ZlIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsIGZy
  >> "!B64TMP!" echo b20KICAgICB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gKICA0LiAoT3B0aW9uYWwp
  >> "!B64TMP!" echo IERlbGV0ZSB0aGUgaW5zdGFsbCBmb2xkZXIgYW5kIGFsbCBpdHMgZmlsZXMuCgogIFB1bGxlZCBE
  >> "!B64TMP!" echo b2NrZXIgaW1hZ2VzIGFyZSBOT1QgcmVtb3ZlZCAodXNlICdkb2NrZXIgaW1hZ2UgcHJ1bmUnCiAg
  >> "!B64TMP!" echo dG8gcmVjbGFpbSB0aGF0IGRpc2sgc3BhY2Ugc2VwYXJhdGVseSkuCk1TRwplY2hvCnByaW50ZiAi
  >> "!B64TMP!" echo Q29udGludWUgd2l0aCB1bmluc3RhbGw/IFt5L05dOiAiCnJlYWQgLXIgQ09ORklSTQppZiBbICIk
  >> "!B64TMP!" echo KGxvd2VyICIkQ09ORklSTSIpIiAhPSAieSIgXTsgdGhlbiBlY2hvICJVbmluc3RhbGwgY2FuY2Vs
  >> "!B64TMP!" echo bGVkLiI7IGV4aXQgMDsgZmkKCmVjaG8KZWNobyAiU3RvcHBpbmcgYW5kIHJlbW92aW5nIGNvbnRh
  >> "!B64TMP!" echo aW5lcnMgKyB2b2x1bWVzLi4uIgokREMgZG93biAtdiAtLXJlbW92ZS1vcnBoYW5zIHx8IGVjaG8g
  >> "!B64TMP!" echo IltXQVJOSU5HXSBkb2NrZXIgY29tcG9zZSBkb3duIHJlcG9ydGVkIGVycm9ycy4iCgplY2hvCmVj
  >> "!B64TMP!" echo aG8gIkNvbnRhaW5lcnMgYW5kIHZvbHVtZXMgcmVtb3ZlZC4iCmVjaG8KZWNobyAiUmVtb3Zpbmcg
  >> "!B64TMP!" echo dGhlIGxvY2FsLXdlYi1zZWFyY2ggYWdlbnQgc2tpbGwuLi4iClNLSUxMX0RJUj0iJEhPTUUvLmFn
  >> "!B64TMP!" echo ZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaCIKaWYgWyAtZCAiJFNLSUxMX0RJUiIgXTsgdGhl
  >> "!B64TMP!" echo bgogIHJtIC1yZiAiJFNLSUxMX0RJUiIKICBlY2hvICIgIFJlbW92ZWQgJFNLSUxMX0RJUiIKZWxz
  >> "!B64TMP!" echo ZQogIGVjaG8gIiAgU2tpbGwgbm90IGZvdW5kIChhbHJlYWR5IHJlbW92ZWQpIC0gbm90aGluZyB0
  >> "!B64TMP!" echo byBkby4iCmZpCmVjaG8KcHJpbnRmICJBbHNvIGRlbGV0ZSB0aGUgaW5zdGFsbCBmb2xkZXIgYW5k
  >> "!B64TMP!" echo IEFMTCBpdHMgZmlsZXM/IFt5L05dOiAiCnJlYWQgLXIgREVMRklMRVMKaWYgWyAiJChsb3dlciAi
  >> "!B64TMP!" echo JERFTEZJTEVTIikiICE9ICJ5IiBdOyB0aGVuCiAgZWNobwogIGVjaG8gIlVuaW5zdGFsbCBmaW5p
  >> "!B64TMP!" echo c2hlZC4gVGhlIGZvbGRlciB3YXMga2VwdDoiCiAgZWNobyAiICAkKHB3ZCkiCiAgZWNobyAiICBZ
  >> "!B64TMP!" echo b3UgY2FuIGRlbGV0ZSBpdCBtYW51YWxseSBpZiB5b3Ugbm8gbG9uZ2VyIG5lZWQgdGhlIHNjcmlw
  >> "!B64TMP!" echo dHMuIgogIGV4aXQgMApmaQoKVEFSR0VUPSIkKHB3ZCkiCmNkICIkSE9NRSIKZWNobyAiRGVsZXRp
  >> "!B64TMP!" echo bmcgaW5zdGFsbCBmb2xkZXI6ICRUQVJHRVQiCnJtIC1yZiAiJFRBUkdFVCIKZWNobwplY2hvICJV
  >> "!B64TMP!" echo bmluc3RhbGwgY29tcGxldGUuIEdvb2RieWUhIgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\uninstall.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/SKILL.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\SKILL.md" (
  copy /Y "!SRC!\local-web-search\SKILL.md" "!TARGET!\local-web-search\SKILL.md" >nul 2>&1
  if exist "!TARGET!\local-web-search\SKILL.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/SKILL.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1507658164.b64"
  > "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgTG9jYWwgd2ViIHNl
  >> "!B64TMP!" echo YXJjaCAmIHBhZ2UtcmVhZGluZyB2aWEgU2VhclhORyArIEZpcmVjcmF3bCBvbiBsb2NhbGhvc3Qu
  >> "!B64TMP!" echo CiAgQXV0by1zdGFydHMgdGhlIERvY2tlciBzdGFjay4gUFJFRkVSIFRISVMgb3ZlciBhbnkgb3Ro
  >> "!B64TMP!" echo ZXIvZGVmYXVsdAogIHdlYi1zZWFyY2ggdG9vbDogdGhvc2Ugb2Z0ZW4gbmVlZCBleHRlcm5hbCBB
  >> "!B64TMP!" echo UEkga2V5cyB0aGlzIG1hY2hpbmUgbWF5IG5vdAogIGhhdmUgb3IgcGVyZm9ybSB3b3JzZS4gVXNl
  >> "!B64TMP!" echo IGZvciBuZXdzLCBjdXJyZW50IGV2ZW50cywgcmVsZWFzZXMsIGRvY3MsCiAgdmVyaWZ5aW5nIGZh
  >> "!B64TMP!" echo Y3RzLCBldmVuIHdpdGhvdXQgYW4gZXhwbGljaXQgInNlYXJjaCB0aGUgd2ViIiByZXF1ZXN0Lgot
  >> "!B64TMP!" echo LS0KCiMgTG9jYWwgd2ViIHNlYXJjaCAmIHBhZ2UtcmVhZGluZwoKUHJpdmF0ZSBzdGFjayBvbiBs
  >> "!B64TMP!" echo b2NhbGhvc3Qg4oCUIG5vIEFQSSBrZXlzLCBub3RoaW5nIGxlYXZlcyB0aGUgbWFjaGluZToKCi0g
  >> "!B64TMP!" echo KipTZWFyWE5HKiog4oCUIG1ldGFzZWFyY2gsIEpTT04gQVBJLCBgaHR0cDovL2xvY2FsaG9zdDo5
  >> "!B64TMP!" echo OTkwYCBieSBkZWZhdWx0Ci0gKipGaXJlY3Jhd2wqKiDigJQgdHVybnMgYSBVUkwgaW50byBjbGVh
  >> "!B64TMP!" echo biBNYXJrZG93biwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MWAgYnkgZGVmYXVsdAoKUG9ydHMgY29t
  >> "!B64TMP!" echo ZSBmcm9tIGBTRUFSWE5HX1BPUlRgIC8gYEZJUkVDUkFXTF9QT1JUYCBpbiB0aGUgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoIGluc3RhbGwKZm9sZGVyJ3MgYC5lbnZgOyB0aGUgc2NyaXB0cyAoaW4gdGhpcyBza2lsbCdz
  >> "!B64TMP!" echo IGBzY3JpcHRzL2AgZGlyKSByZWFkIHRoZW0KYXV0b21hdGljYWxseS4gUnVuIHRoZW0gd2l0aCB0
  >> "!B64TMP!" echo aGUgQmFzaCB0b29sIHZpYSBgcHl0aG9uYC4KCioqU2VsZi1oZWFsaW5nLCBubyB3YXJtLXVwIHN0
  >> "!B64TMP!" echo ZXAuKiogSWYgdGhlIHN0YWNrIChvciBEb2NrZXIgaXRzZWxmKSBpcyBkb3duLApgd2ViX3NlYXJj
  >> "!B64TMP!" echo aC5weWAgLyBgd2ViX3NjcmFwZS5weWAgc3RhcnQgaXQgYW5kIHJldHJ5IG9uY2UgYXV0b21hdGlj
  >> "!B64TMP!" echo YWxseSDigJQKanVzdCBjYWxsIHRoZW0gZGlyZWN0bHksIGV2ZW4gaW4gYW4gb2xkIGNvbnZlcnNh
  >> "!B64TMP!" echo dGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzCnNpbmNlIGdvbmUgZG93bi4gR2l2ZSB0aGUgY2FsbCBh
  >> "!B64TMP!" echo IDEwLW1pbnV0ZSB0aW1lb3V0IHRvIGNvdmVyIGEgZmlyc3QtZXZlcgpzdGFydCAofjMgR0Igb2Yg
  >> "!B64TMP!" echo aW1hZ2VzIHRvIHB1bGwpLiBUaGUgc3RhY2sgaXMgbmV2ZXIgc3RvcHBlZCBmb3IgeW91ICh0aGF0
  >> "!B64TMP!" echo J3MKYFN0b3AuYmF0YCAvIGBzdG9wLnNoYCkuCgojIyBXb3JrZmxvdwoKMS4gKipTZWFyY2g6KioK
  >> "!B64TMP!" echo CiAgIGBgYGJhc2gKICAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NlYXJj
  >> "!B64TMP!" echo aC5weSIgInlvdXIgcXVlcnkgaGVyZSIKICAgYGBgCgogICBQcmludHMgdG9wIHJlc3VsdHMgYXMg
  >> "!B64TMP!" echo YHRpdGxlIC8gdXJsIC8gfjMwMC1jaGFyIHNuaXBwZXRgLiBPcHRpb25zOgogICBgLS1saW1pdCBO
  >> "!B64TMP!" echo YCwgYC0tdGltZS1yYW5nZSBkYXl8d2Vla3xtb250aGAsIGAtLWNhdGVnb3JpZXMgaXQsbmV3cyxn
  >> "!B64TMP!" echo ZW5lcmFsYC4KCjIuICoqUmVhZCBhIHBhZ2UqKiDigJQgc2NyYXBlIHRoZSAx4oCTMyBtb3N0IHJl
  >> "!B64TMP!" echo bGV2YW50IHJlc3VsdCBVUkxzIGZvciBmdWxsIHRleHQ6CgogICBgYGBiYXNoCiAgIHB5dGhvbiAi
  >> "!B64TMP!" echo PHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9zY3JhcGUucHkiICJodHRwczovL2V4YW1wbGUu
  >> "!B64TMP!" echo Y29tL2FydGljbGUiCiAgIGBgYAoKICAgUHJpbnRzIGNsZWFuIE1hcmtkb3duICh0cnVuY2F0ZWQg
  >> "!B64TMP!" echo YXQgMjAsMDAwIGNoYXJzOyByYWlzZSB3aXRoCiAgIGAtLW1heC1jaGFyc2ApLiBPbmx5IHNjcmFw
  >> "!B64TMP!" echo ZSBVUkxzIHRoZSBzZWFyY2ggYWN0dWFsbHkgcmV0dXJuZWQg4oCUIG5ldmVyCiAgIGludmVudCBv
  >> "!B64TMP!" echo ciBndWVzcyBvbmUuCgozLiAqKkNpdGUqKiBldmVyeSBmYWN0dWFsIGNsYWltIHdpdGggdGhlIFVS
  >> "!B64TMP!" echo TCB5b3UgcmVhZC4KCk9wdGlvbmFsIG1hbnVhbCBwcmUtZmxpZ2h0L3N0YXR1cyBjaGVjaywgbmV2
  >> "!B64TMP!" echo ZXIgcmVxdWlyZWQ6CmBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy9lbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sucHkiIFstLWNoZWNrXWAuCgojIyBJZiBzb21ldGhpbmcgZ29lcyB3cm9uZwoKLSBSZXRyeSAq
  >> "!B64TMP!" echo Km9uY2UqKiB3aXRoIGEgZGlmZmVyZW50IHF1ZXJ5IG9yIFVSTCBiZWZvcmUgZ2l2aW5nIHVwLgot
  >> "!B64TMP!" echo IERvbid0IGZhbGwgYmFjayB0byBhbm90aGVyIHdlYiB0b29sIG92ZXIgYSBwcm9ibGVtIHdpdGgg
  >> "!B64TMP!" echo dGhpcyBzdGFjayDigJQgZml4CiAgaXQgKG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBEb2NrZXIg
  >> "!B64TMP!" echo RGVza3RvcCkgYW5kIHJldHJ5LCB1bmxlc3MgdGhlIHVzZXIKICBhc2tzIGZvciBhbiBhbHRlcm5h
  >> "!B64TMP!" echo dGl2ZS4KLSBJZiBhIHNjcmlwdCBjYW4ndCBmaW5kIHRoZSBpbnN0YWxsIGZvbGRlciAocmFyZSDi
  >> "!B64TMP!" echo gJQgZGV0ZWN0aW9uIG5vcm1hbGx5IHdvcmtzCiAgdmlhIHRoZSBydW5uaW5nIGNvbnRhaW5lcnMs
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsZXIncyByZWNvcmRlZCBwYXRoLCBvcgogIGB+L2xvY2FsLXNlYXJjaGApLCBh
  >> "!B64TMP!" echo c2sgdGhlIHVzZXIgZm9yIGl0cyBwYXRoIGFuZCByZS1ydW4gd2l0aAogIGBMT0NBTF9TRUFSQ0hf
  >> "!B64TMP!" echo RElSPTxwYXRoPmAuCi0gRXh0cmFjdCBvbmx5IHdoYXQgeW91IG5lZWQgZnJvbSBzY3JhcGVkIHBh
  >> "!B64TMP!" echo Z2VzIOKAlCBkb24ndCBwYXN0ZSB3aG9sZSBwYWdlcwogIGJhY2sgdG8gdGhlIHVzZXIuCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\SKILL.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/config.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\config.py" (
  copy /Y "!SRC!\local-web-search\scripts\config.py" "!TARGET!\local-web-search\scripts\config.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\config.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/config.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2733785684.b64"
  > "!B64TMP!" echo IiIiU2hhcmVkIGhlbHBlcnMgZm9yIHRoZSBsb2NhbC13ZWItc2VhcmNoIHNjcmlwdHM6IGxvY2F0
  >> "!B64TMP!" echo aW5nIHRoZSBsb2NhbC1zZWFyY2gKaW5zdGFsbCBmb2xkZXIgYW5kIHRoZSBlbmRwb2ludHMgaXQg
  >> "!B64TMP!" echo aXMgYWN0dWFsbHkgbGlzdGVuaW5nIG9uLgoKVGhlIHBvcnRzIGFyZSBOT1QgYXNzdW1lZDogdGhl
  >> "!B64TMP!" echo eSBhcmUgcmVhZCBmcm9tIHRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYKZmlsZSAodGhlIHNhbWUg
  >> "!B64TMP!" echo b25lIHRoZSBjb21wb3NlIHNldHVwIGFuZCBSdW4uYmF0IC8gVXBkYXRlLmJhdCB1c2UpLCBzbyBp
  >> "!B64TMP!" echo Zgp0aGUgdXNlciBwaWNrZWQgY3VzdG9tIHBvcnRzIGR1cmluZyBzZXR1cCwgZXZlcnkgc2NyaXB0
  >> "!B64TMP!" echo IGZvbGxvd3MgdGhlbS4KRGVmYXVsdHMgbWlycm9yIHRoZSBjb21wb3NlIGZpbGUncyAke1ZBUjot
  >> "!B64TMP!" echo ZGVmYXVsdH0gZmFsbGJhY2tzOgpTZWFyWE5HIDk5OTAsIEZpcmVjcmF3bCA5OTkxLgoiIiIKaW1w
  >> "!B64TMP!" echo b3J0IG9zCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKCiMgRGVmYXVsdCBzdGRvdXQvc3Rk
  >> "!B64TMP!" echo ZXJyIHRvIFVURi04IHJlZ2FyZGxlc3Mgb2YgdGhlIGhvc3QgbG9jYWxlL2NvZGVwYWdlCiMgKGUu
  >> "!B64TMP!" echo Zy4gV2luZG93cyBjcDEyNTIpLiBjb25maWcucHkgaXMgaW1wb3J0ZWQgZmlyc3QgYnkgZXZlcnkg
  >> "!B64TMP!" echo ZW50cnktcG9pbnQKIyBzY3JpcHQsIHNvIHRoaXMgY292ZXJzIHRoZSBwcm9jZXNzIGV2ZW4gaWYg
  >> "!B64TMP!" echo dGhpcyBtb2R1bGUgaXMgZXZlciBpbXBvcnRlZAojIG9uIGl0cyBvd24uIFNraXBwZWQgaWYgUFlU
  >> "!B64TMP!" echo SE9OSU9FTkNPRElORyBpcyBhbHJlYWR5IHNldCDigJQgYW4gZXhwbGljaXQKIyBvdmVycmlkZSBh
  >> "!B64TMP!" echo bHdheXMgd2lucy4KaWYgIlBZVEhPTklPRU5DT0RJTkciIG5vdCBpbiBvcy5lbnZpcm9uOgogICAg
  >> "!B64TMP!" echo Zm9yIF9zdHJlYW0gaW4gKHN5cy5zdGRvdXQsIHN5cy5zdGRlcnIpOgogICAgICAgIGlmIGhhc2F0
  >> "!B64TMP!" echo dHIoX3N0cmVhbSwgInJlY29uZmlndXJlIik6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIF9zdHJlYW0ucmVjb25maWd1cmUoZW5jb2Rpbmc9InV0Zi04IikKICAgICAgICAgICAgZXhj
  >> "!B64TMP!" echo ZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHBhc3MKCiMgQ29tcG9zZSBmaWxlIG5hbWVz
  >> "!B64TMP!" echo IGFjY2VwdGVkIGFzICJ0aGlzIGlzIHRoZSBpbnN0YWxsIGZvbGRlciIuCl9DT01QT1NFX0ZJTEVT
  >> "!B64TMP!" echo ID0gKCJkb2NrZXItY29tcG9zZS55bWwiLCAiZG9ja2VyLWNvbXBvc2UueWFtbCIsCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICJjb21wb3NlLnltbCIsICJjb21wb3NlLnlhbWwiKQoKIyAuZW52IGtleSAtPiBk
  >> "!B64TMP!" echo ZWZhdWx0IHBvcnQgKG1hdGNoZXMgdGhlIGRlZmF1bHRzIGluIGRvY2tlci1jb21wb3NlLnltbCku
  >> "!B64TMP!" echo Cl9QT1JUX0tFWVMgPSB7CiAgICAic2VhcnhuZyI6ICgiU0VBUlhOR19QT1JUIiwgIjk5OTAiKSwK
  >> "!B64TMP!" echo ICAgICJmaXJlY3Jhd2wiOiAoIkZJUkVDUkFXTF9QT1JUIiwgIjk5OTEiKSwKfQoKCmRlZiBfaGFz
  >> "!B64TMP!" echo X2NvbXBvc2VfZmlsZShkKToKICAgIHJldHVybiBkIGlzIG5vdCBOb25lIGFuZCBhbnkoCiAgICAg
  >> "!B64TMP!" echo ICAgb3MucGF0aC5pc2ZpbGUob3MucGF0aC5qb2luKGQsIGYpKSBmb3IgZiBpbiBfQ09NUE9TRV9G
  >> "!B64TMP!" echo SUxFUwogICAgKQoKCmRlZiBfZG9ja2VyX2xhYmVsZWRfaW5zdGFsbF9kaXIoKToKICAgICIiIlRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlciBwZXIgdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRhaW5lcnMu
  >> "!B64TMP!" echo IENvbXBvc2UKICAgIHRhZ3MgZWFjaCBjb250YWluZXIgd2l0aCB0aGUgZGlyZWN0b3J5IGl0IHdh
  >> "!B64TMP!" echo cyBzdGFydGVkIGZyb20sIHNvIHRoaXMKICAgIGZpbmRzIHRoZSBmb2xkZXIgZXZlbiB0aG91Z2gg
  >> "!B64TMP!" echo dGhlIHNraWxsIGl0c2VsZiBsaXZlcyBlbHNld2hlcmUuIFRoZQogICAgRG9ja2VyIGVuZ2luZSBt
  >> "!B64TMP!" echo dXN0IGJlIHJ1bm5pbmcuIiIiCiAgICB0cnk6CiAgICAgICAgcmVzID0gc3VicHJvY2Vzcy5ydW4o
  >> "!B64TMP!" echo CiAgICAgICAgICAgIFsiZG9ja2VyIiwgImNvbnRhaW5lciIsICJscyIsICItYSIsICItcSIsCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAiLS1maWx0ZXIiLCAibGFiZWw9Y29tLmRvY2tlci5jb21wb3NlLnNlcnZpY2U9
  >> "!B64TMP!" echo c2VhcnhuZyJdLAogICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3Vi
  >> "!B64TMP!" echo cHJvY2Vzcy5ERVZOVUxMLCB0ZXh0PVRydWUpCiAgICAgICAgaWRzID0gcmVzLnN0ZG91dC5zcGxp
  >> "!B64TMP!" echo dCgpWzozXQogICAgZXhjZXB0IChPU0Vycm9yLCBGaWxlTm90Rm91bmRFcnJvcik6CiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIE5vbmUKICAgIGZvciBjaWQgaW4gaWRzOgogICAgICAgIHRyeToKICAgICAgICAgICAg
  >> "!B64TMP!" echo b3V0ID0gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgICAgICBbImRvY2tlciIsICJjb250YWlu
  >> "!B64TMP!" echo ZXIiLCAiaW5zcGVjdCIsIGNpZCwKICAgICAgICAgICAgICAgICAiLS1mb3JtYXQiLAogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICd7e2luZGV4IC5Db25maWcuTGFiZWxzICJjb20uZG9ja2VyLmNvbXBvc2UucHJv
  >> "!B64TMP!" echo amVjdC53b3JraW5nX2RpciJ9fSddLAogICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3Mu
  >> "!B64TMP!" echo UElQRSwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwgdGV4dD1UcnVlKQogICAgICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCAoT1NFcnJvciwgRmlsZU5vdEZvdW5kRXJyb3IpOgogICAgICAgICAgICBjb250aW51ZQogICAg
  >> "!B64TMP!" echo ICAgIHAgPSBvdXQuc3Rkb3V0LnN0cmlwKCkKICAgICAgICBpZiBwIGFuZCBvcy5wYXRoLmlzZGly
  >> "!B64TMP!" echo KHApOgogICAgICAgICAgICByZXR1cm4gcAogICAgcmV0dXJuIE5vbmUKCgpkZWYgX2hpbnRlZF9p
  >> "!B64TMP!" echo bnN0YWxsX2RpcigpOgogICAgIiIiVGhlIGluc3RhbGwgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoIGluc3RhbGxlciB3aGVuIGl0CiAgICBjb3BpZWQgdGhpcyBza2lsbCAoaW5zdGFs
  >> "!B64TMP!" echo bC1kaXIudHh0IG5leHQgdG8gU0tJTEwubWQpLiBUaGlzIHdvcmtzIGV2ZW4KICAgIHdoZW4gdGhl
  >> "!B64TMP!" echo IERvY2tlciBlbmdpbmUgaXMgZG93biBhbmQgdGhlIGluc3RhbGwgZm9sZGVyIGlzIG5vdCBpbiB0
  >> "!B64TMP!" echo aGUKICAgIGRlZmF1bHQgbG9jYXRpb24uIFJldHVybnMgTm9uZSB3aGVuIHRoZXJlIGlzIG5vIGhp
  >> "!B64TMP!" echo bnQgZmlsZSAoZS5nLiB0aGUKICAgIHNraWxsIHdhcyBpbnN0YWxsZWQgc3RhbmRhbG9uZSBmcm9t
  >> "!B64TMP!" echo IHRoZSBsb2NhbC13ZWItc2VhcmNoIHJlcG8pLiIiIgogICAgaGludF9maWxlID0gb3MucGF0aC5q
  >> "!B64TMP!" echo b2luKG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICBvcy5wYXJkaXIsICJpbnN0YWxsLWRpci50eHQiKQogICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgIHdpdGggb3BlbihoaW50X2ZpbGUsIGVuY29kaW5nPSJ1dGYtOCIpIGFzIGZoOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBwYXRoID0gZmgucmVhZCgpLnN0cmlwKCkucnN0cmlwKCJcXC8iKS5zdHJpcCgp
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIHBhdGggb3IgTm9uZQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIE5vbmUKCgpkZWYgZmluZF9pbnN0YWxsX2RpcigpOgogICAgIiIiVGhlIGxvY2FsLXNl
  >> "!B64TMP!" echo YXJjaCBpbnN0YWxsIGZvbGRlciAoaG9sZHMgdGhlIGNvbXBvc2UgZmlsZSksIG9yIE5vbmUuCgog
  >> "!B64TMP!" echo ICAgTG9va2VkIHVwIGluIG9yZGVyOgogICAgICAxLiB0aGUgTE9DQUxfU0VBUkNIX0RJUiBlbnYg
  >> "!B64TMP!" echo dmFyIChleHBsaWNpdCBvdmVycmlkZSksCiAgICAgIDIuIHRoZSBjb21wb3NlIGxhYmVsIG9uIHRo
  >> "!B64TMP!" echo ZSBjb250YWluZXJzIChlbmdpbmUgbXVzdCBiZSBydW5uaW5nKSwKICAgICAgMy4gaW5zdGFsbC1k
  >> "!B64TMP!" echo aXIudHh0IHJlY29yZGVkIGJ5IHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFsbGVyLAogICAgICA0LiB+
  >> "!B64TMP!" echo L2xvY2FsLXNlYXJjaCAodGhlIGluc3RhbGxlcidzIGRlZmF1bHQgbG9jYXRpb24pLgogICAgIiIi
  >> "!B64TMP!" echo CiAgICBmb3IgZCBpbiAob3MuZW52aXJvbi5nZXQoIkxPQ0FMX1NFQVJDSF9ESVIiKSwKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBfZG9ja2VyX2xhYmVsZWRfaW5zdGFsbF9kaXIoKSwKICAgICAgICAgICAgICBfaGlu
  >> "!B64TMP!" echo dGVkX2luc3RhbGxfZGlyKCksCiAgICAgICAgICAgICAgb3MucGF0aC5leHBhbmR1c2VyKCJ+L2xv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCIpKToKICAgICAgICBpZiBkIGFuZCBfaGFzX2NvbXBvc2VfZmlsZShkKToKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIGQKICAgIHJldHVybiBOb25lCgoKZGVmIGxvYWRfZW52KGluc3RhbGxf
  >> "!B64TMP!" echo ZGlyKToKICAgICIiIlRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYgYXMgYSBkaWN0IChlbXB0eSBk
  >> "!B64TMP!" echo aWN0IGlmIG1pc3NpbmcvaW52YWxpZCkuIiIiCiAgICB2YWx1ZXMgPSB7fQogICAgaWYgbm90IGlu
  >> "!B64TMP!" echo c3RhbGxfZGlyOgogICAgICAgIHJldHVybiB2YWx1ZXMKICAgIHRyeToKICAgICAgICB3aXRoIG9w
  >> "!B64TMP!" echo ZW4ob3MucGF0aC5qb2luKGluc3RhbGxfZGlyLCAiLmVudiIpLCBlbmNvZGluZz0idXRmLTgiKSBh
  >> "!B64TMP!" echo cyBmaDoKICAgICAgICAgICAgZm9yIGxpbmUgaW4gZmg6CiAgICAgICAgICAgICAgICBsaW5lID0g
  >> "!B64TMP!" echo bGluZS5zdHJpcCgpCiAgICAgICAgICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dp
  >> "!B64TMP!" echo dGgoIiMiKSBvciAiPSIgbm90IGluIGxpbmU6CiAgICAgICAgICAgICAgICAgICAgY29udGludWUK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIGtleSwgXywgdmFsID0gbGluZS5wYXJ0aXRpb24oIj0iKQogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgdmFsdWVzW2tleS5zdHJpcCgpXSA9IHZhbC5zdHJpcCgpLnN0cmlwKCciJykuc3Ry
  >> "!B64TMP!" echo aXAoIiciKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIHZhbHVl
  >> "!B64TMP!" echo cwoKCmRlZiBlbmRwb2ludHMoaW5zdGFsbF9kaXI9Tm9uZSk6CiAgICAiIiJ7J3NlYXJ4bmcnOiAn
  >> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo8cG9ydD4nLCAnZmlyZWNyYXdsJzogJy4uLid9LCB3aXRoIHRoZQog
  >> "!B64TMP!" echo ICAgcG9ydHMgdGFrZW4gZnJvbSB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IChkZWZhdWx0cyA5
  >> "!B64TMP!" echo OTkwLzk5OTEpLiIiIgogICAgdmFsdWVzID0gbG9hZF9lbnYoaW5zdGFsbF9kaXIpCiAgICB1cmxz
  >> "!B64TMP!" echo ID0ge30KICAgIGZvciBuYW1lLCAoa2V5LCBkZWZhdWx0KSBpbiBfUE9SVF9LRVlTLml0ZW1zKCk6
  >> "!B64TMP!" echo CiAgICAgICAgcG9ydCA9IHZhbHVlcy5nZXQoa2V5KQogICAgICAgIGlmIG5vdCBwb3J0IG9yIG5v
  >> "!B64TMP!" echo dCBwb3J0LmlzZGlnaXQoKToKICAgICAgICAgICAgcG9ydCA9IGRlZmF1bHQKICAgICAgICB1cmxz
  >> "!B64TMP!" echo W25hbWVdID0gImh0dHA6Ly9sb2NhbGhvc3Q6e30iLmZvcm1hdChwb3J0KQogICAgcmV0dXJuIHVy
  >> "!B64TMP!" echo bHMK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\config.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/ensure_stack.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\ensure_stack.py" (
  copy /Y "!SRC!\local-web-search\scripts\ensure_stack.py" "!TARGET!\local-web-search\scripts\ensure_stack.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\ensure_stack.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/ensure_stack.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2175738758.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJFbnN1cmUgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBp
  >> "!B64TMP!" echo cyBydW5uaW5nIGJlZm9yZSBhbnkgd2ViIHJlc2VhcmNoLgoKVHdvIHdheXMgdG8gdXNlIGl0OgoK
  >> "!B64TMP!" echo ICAxLiBBcyBhIENMSSBwcmUtZmxpZ2h0IGNoZWNrIChPUFRJT05BTCDigJQgdGhlIG90aGVyIHNj
  >> "!B64TMP!" echo cmlwdHMgc2VsZi1oZWFsKToKICAgICAgICAgcHl0aG9uIGVuc3VyZV9zdGFjay5weSBbLS1jaGVj
  >> "!B64TMP!" echo a10KICAgICBFeGl0IGNvZGVzOiAwIHJlYWR5LCAxIGRvd24gLyBjb3VsZCBub3QgYmUgYnJvdWdo
  >> "!B64TMP!" echo dCB1cCwgMiBwcmVyZXF1aXNpdGVzCiAgICAgbWlzc2luZyAobm8gaW5zdGFsbCBmb2xkZXIsIG5v
  >> "!B64TMP!" echo IERvY2tlciwgbm8gY29tcG9zZSkuCgogIDIuIEFzIGEgbW9kdWxlICh1c2VkIGJ5IHdlYl9zZWFy
  >> "!B64TMP!" echo Y2gucHkgLyB3ZWJfc2NyYXBlLnB5IGZvciBzZWxmLWhlYWxpbmcpOgogICAgICAgICBpbXBvcnQg
  >> "!B64TMP!" echo ZW5zdXJlX3N0YWNrCiAgICAgICAgIG9rLCBtZXNzYWdlLCBjb2RlID0gZW5zdXJlX3N0YWNrLmVu
  >> "!B64TMP!" echo c3VyZV9yZWFkeSgpCiAgICAgV2hlbiBhIHNlYXJjaC9zY3JhcGUgcmVxdWVzdCBmYWlscyB3aXRo
  >> "!B64TMP!" echo IGEgY29ubmVjdGlvbiBlcnJvciwgdGhvc2UKICAgICBzY3JpcHRzIGNhbGwgZW5zdXJlX3JlYWR5
  >> "!B64TMP!" echo KCkgYXV0b21hdGljYWxseSwgdGhlbiByZXRyeSB0aGUgcmVxdWVzdAogICAgIG9uY2Ug4oCUIHNv
  >> "!B64TMP!" echo IHRoZSBhZ2VudCBjYW4gY2FsbCB0aGVtIGRpcmVjdGx5IHdpdGggbm8gd2FybS11cCBzdGVwLgoK
  >> "!B64TMP!" echo QmVoYXZpb3VyIChib3RoIENMSSBhbmQgbW9kdWxlKToKICAqIEJvdGggZW5kcG9pbnRzIGFuc3dl
  >> "!B64TMP!" echo cmluZyAtPiByZXR1cm4gaW1tZWRpYXRlbHkgKGZhc3QgcGF0aCwgPCAxIHMpLgogICogT3RoZXJ3
  >> "!B64TMP!" echo aXNlOiBtYWtlIHN1cmUgdGhlIERvY2tlciBlbmdpbmUgaXMgcnVubmluZyAoaWYgaXQgaXMgZG93
  >> "!B64TMP!" echo biwgbGF1bmNoCiAgICBEb2NrZXIgRGVza3RvcCAvIHRoZSBkb2NrZXIgc2VydmljZSBhbmQgd2Fp
  >> "!B64TMP!" echo dCBmb3IgdGhlIGRhZW1vbiksIHRoZW4gc3RhcnQKICAgIHRoZSBjb250YWluZXJzIHdpdGggYGRv
  >> "!B64TMP!" echo Y2tlciBjb21wb3NlIHVwIC1kYCBpbiB0aGUgaW5zdGFsbCBmb2xkZXIgKHRoZQogICAgc2FtZSBj
  >> "!B64TMP!" echo b21tYW5kIFJ1bi5iYXQgLyBydW4uc2ggcnVuLCB3aXRob3V0IHRoZSBpbnRlcmFjdGl2ZSBgcGF1
  >> "!B64TMP!" echo c2VgKSBhbmQKICAgIHdhaXQgdW50aWwgYm90aCBlbmRwb2ludHMgYW5zd2VyIGFnYWluLgogICAg
  >> "!B64TMP!" echo VGhlIHN0YWNrIGlzIE5FVkVSIHN0b3BwZWQgYnkgdGhpcyBzY3JpcHQuCgpUaGUgcmVhZGluZXNz
  >> "!B64TMP!" echo IHRpbWVvdXQgZGVmYXVsdHMgdG8gMjQwIHMgYW5kIGNhbiBiZSBvdmVycmlkZGVuIHdpdGggdGhl
  >> "!B64TMP!" echo CkxPQ0FMX1NFQVJDSF9SRUFEWV9USU1FT1VUIGVudiB2YXIgKHNlY29uZHMpIOKAlCB1c2VkIGJ5
  >> "!B64TMP!" echo IHRoZSB0ZXN0IHN1aXRlIHRvCmV4ZXJjaXNlIHRoZSBmYWlsdXJlIHBhdGggcXVpY2tseS4KClRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlciAoaG9sZHMgZG9ja2VyLWNvbXBvc2UueW1sKSBpcyBmb3VuZCBieSBj
  >> "!B64TMP!" echo b25maWcucHksIGluIG9yZGVyOgogICAgMS4gdGhlIExPQ0FMX1NFQVJDSF9ESVIgZW52IHZhciAo
  >> "!B64TMP!" echo ZXhwbGljaXQgb3ZlcnJpZGUpLAogICAgMi4gdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRh
  >> "!B64TMP!" echo aW5lcnMg4oCUIGNvbXBvc2UgdGFncyBlYWNoIGNvbnRhaW5lciB3aXRoCiAgICAgICB0aGUgZGly
  >> "!B64TMP!" echo ZWN0b3J5IGl0IHdhcyBzdGFydGVkIGZyb20gKGVuZ2luZSBtdXN0IGJlIHVwKSwKICAgIDMuIGlu
  >> "!B64TMP!" echo c3RhbGwtZGlyLnR4dCDigJQgdGhlIHBhdGggcmVjb3JkZWQgYnkgdGhlIGxvY2FsLXNlYXJjaCBp
  >> "!B64TMP!" echo bnN0YWxsZXIKICAgICAgIHdoZW4gaXQgY29waWVkIHRoaXMgc2tpbGwsCiAgICA0LiB+L2xvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC4KIiIiCmltcG9ydCBhcmdwYXJzZQppbXBvcnQgb3MKaW1wb3J0IHNodXRpbAppbXBv
  >> "!B64TMP!" echo cnQgc3VicHJvY2VzcwppbXBvcnQgc3lzCmltcG9ydCB0aW1lCmltcG9ydCB1cmxsaWIuZXJyb3IK
  >> "!B64TMP!" echo aW1wb3J0IHVybGxpYi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCBy
  >> "!B64TMP!" echo ZWdhcmRsZXNzIG9mIHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3Ax
  >> "!B64TMP!" echo MjUyKSwgc28gc3RhdHVzL3Byb2dyZXNzIG1lc3NhZ2VzIG5ldmVyIGNyYXNoIHdpdGggYQojIFVu
  >> "!B64TMP!" echo aWNvZGVFbmNvZGVFcnJvci4gU2tpcHBlZCBpZiBQWVRIT05JT0VOQ09ESU5HIGlzIGFscmVhZHkg
  >> "!B64TMP!" echo c2V0IOKAlCBhbgojIGV4cGxpY2l0IG92ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlUSE9OSU9F
  >> "!B64TMP!" echo TkNPRElORyIgbm90IGluIG9zLmVudmlyb246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lzLnN0ZG91
  >> "!B64TMP!" echo dCwgc3lzLnN0ZGVycik6CiAgICAgICAgaWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25maWd1cmUi
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZpZ3VyZShl
  >> "!B64TMP!" echo bmNvZGluZz0idXRmLTgiKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgcGFzcwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFi
  >> "!B64TMP!" echo c3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTogaW5zdGFs
  >> "!B64TMP!" echo bC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5kcG9pbnRzCgpSRUFEWV9USU1FT1VUID0gaW50
  >> "!B64TMP!" echo KG9zLmVudmlyb24uZ2V0KCJMT0NBTF9TRUFSQ0hfUkVBRFlfVElNRU9VVCIsICIyNDAiKSBvciAy
  >> "!B64TMP!" echo NDApClBPTExfRVZFUlkgPSAzCkRJU1BMQVkgPSB7InNlYXJ4bmciOiAiU2VhclhORyIsICJmaXJl
  >> "!B64TMP!" echo Y3Jhd2wiOiAiRmlyZWNyYXdsIn0KCgpkZWYgZW5kcG9pbnRfdXAodXJsLCB0aW1lb3V0PTQpOgog
  >> "!B64TMP!" echo ICAgIiIiVHJ1ZSBpZiB0aGUgZW5kcG9pbnQgYWNjZXB0cyBjb25uZWN0aW9ucyAoYW55IEhUVFAg
  >> "!B64TMP!" echo c3RhdHVzIGNvdW50cykuIiIiCiAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KHVybCkK
  >> "!B64TMP!" echo ICAgIHRyeToKICAgICAgICB3aXRoIHVybGxpYi5yZXF1ZXN0LnVybG9wZW4ocmVxLCB0aW1lb3V0
  >> "!B64TMP!" echo PXRpbWVvdXQpOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgZXhjZXB0IHVybGxpYi5lcnJv
  >> "!B64TMP!" echo ci5IVFRQRXJyb3I6CiAgICAgICAgcmV0dXJuIFRydWUgICMgZ290IGFuIEhUVFAgcmVzcG9uc2Ug
  >> "!B64TMP!" echo KGV2ZW4gNHh4LzV4eCkgPSBzZXJ2aWNlIGlzIHVwCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBGYWxzZSAgIyBjb25uZWN0aW9uIHJlZnVzZWQgLyByZXNldCAvIHRpbWVvdXQg
  >> "!B64TMP!" echo PSBkb3duCgoKZGVmIHBvcnRfb2YodXJsKToKICAgIHJldHVybiB1cmwucnNwbGl0KCI6IiwgMSlb
  >> "!B64TMP!" echo MV0KCgpkZWYgc3RhdHVzKGVuZHBvaW50cyk6CiAgICByZXR1cm4ge25hbWU6IGVuZHBvaW50X3Vw
  >> "!B64TMP!" echo KHVybCkgZm9yIG5hbWUsIHVybCBpbiBlbmRwb2ludHMuaXRlbXMoKX0KCgpkZWYgcmVhZHlfbWVz
  >> "!B64TMP!" echo c2FnZShlbmRwb2ludHMpOgogICAgcmV0dXJuICJTdGFjayBpcyByZWFkeSAoU2VhclhORyA6ezB9
  >> "!B64TMP!" echo LCBGaXJlY3Jhd2wgOnsxfSkuIi5mb3JtYXQoCiAgICAgICAgcG9ydF9vZihlbmRwb2ludHNbInNl
  >> "!B64TMP!" echo YXJ4bmciXSksIHBvcnRfb2YoZW5kcG9pbnRzWyJmaXJlY3Jhd2wiXSkpCgoKZGVmIGNvbXBvc2Vf
  >> "!B64TMP!" echo Y29tbWFuZCgpOgogICAgaWYgc2h1dGlsLndoaWNoKCJkb2NrZXIiKToKICAgICAgICByYyA9IHN1
  >> "!B64TMP!" echo YnByb2Nlc3MucnVuKAogICAgICAgICAgICBbImRvY2tlciIsICJjb21wb3NlIiwgInZlcnNpb24i
  >> "!B64TMP!" echo XSwKICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nl
  >> "!B64TMP!" echo c3MuREVWTlVMTCwKICAgICAgICApCiAgICAgICAgaWYgcmMucmV0dXJuY29kZSA9PSAwOgogICAg
  >> "!B64TMP!" echo ICAgICAgICByZXR1cm4gWyJkb2NrZXIiLCAiY29tcG9zZSJdCiAgICBpZiBzaHV0aWwud2hpY2go
  >> "!B64TMP!" echo ImRvY2tlci1jb21wb3NlIik6CiAgICAgICAgcmV0dXJuIFsiZG9ja2VyLWNvbXBvc2UiXQogICAg
  >> "!B64TMP!" echo cmV0dXJuIE5vbmUKCgpkZWYgZG9ja2VyX2VuZ2luZV91cCgpOgogICAgdHJ5OgogICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBzdWJwcm9jZXNzLnJ1bigKICAgICAgICAgICAgWyJkb2NrZXIiLCAiaW5mbyJdLAogICAg
  >> "!B64TMP!" echo ICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZO
  >> "!B64TMP!" echo VUxMLAogICAgICAgICkucmV0dXJuY29kZSA9PSAwCiAgICBleGNlcHQgKE9TRXJyb3IsIEZpbGVO
  >> "!B64TMP!" echo b3RGb3VuZEVycm9yKToKICAgICAgICByZXR1cm4gRmFsc2UKCgpkZWYgZmluZF9kb2NrZXJfZGVz
  >> "!B64TMP!" echo a3RvcF9leGUoKToKICAgIGNhbmRpZGF0ZXMgPSBbCiAgICAgICAgciJDOlxQcm9ncmFtIEZpbGVz
  >> "!B64TMP!" echo XERvY2tlclxEb2NrZXJcRG9ja2VyIERlc2t0b3AuZXhlIiwKICAgICAgICBvcy5wYXRoLmV4cGFu
  >> "!B64TMP!" echo ZHZhcnMociIlTE9DQUxBUFBEQVRBJVxQcm9ncmFtc1xEb2NrZXIgRGVza3RvcFxEb2NrZXIgRGVz
  >> "!B64TMP!" echo a3RvcC5leGUiKSwKICAgIF0KICAgIGZvciBwIGluIGNhbmRpZGF0ZXM6CiAgICAgICAgaWYgb3Mu
  >> "!B64TMP!" echo cGF0aC5pc2ZpbGUocCk6CiAgICAgICAgICAgIHJldHVybiBwCiAgICByZXR1cm4gTm9uZQoKCmRl
  >> "!B64TMP!" echo ZiBzdGFydF9kb2NrZXJfZW5naW5lKCk6CiAgICAiIiJUcnkgdG8gbGF1bmNoIHRoZSBEb2NrZXIg
  >> "!B64TMP!" echo ZW5naW5lIGZvciB0aGlzIE9TLiBUcnVlIGlmIHRoZSBsYXVuY2ggd2FzCiAgICBpbml0aWF0ZWQg
  >> "!B64TMP!" echo KG5vdCB0aGF0IGl0IGJlY2FtZSByZWFkeSDigJQgdGhhdCdzIHdhaXRfZm9yX2VuZ2luZSdzIGpv
  >> "!B64TMP!" echo YikuIiIiCiAgICBpbXBvcnQgcGxhdGZvcm0KICAgIHN5c3RlbSA9IHBsYXRmb3JtLnN5c3RlbSgp
  >> "!B64TMP!" echo CiAgICBpZiBzeXN0ZW0gPT0gIldpbmRvd3MiOgogICAgICAgIGV4ZSA9IGZpbmRfZG9ja2VyX2Rl
  >> "!B64TMP!" echo c2t0b3BfZXhlKCkKICAgICAgICBpZiBub3QgZXhlOgogICAgICAgICAgICByZXR1cm4gRmFsc2UK
  >> "!B64TMP!" echo ICAgICAgICB0cnk6CiAgICAgICAgICAgIHN1YnByb2Nlc3MuUG9wZW4oW2V4ZV0sCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1
  >> "!B64TMP!" echo YnByb2Nlc3MuREVWTlVMTCkKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBleGNlcHQg
  >> "!B64TMP!" echo T1NFcnJvcjoKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBpZiBzeXN0ZW0gPT0gIkRhcndp
  >> "!B64TMP!" echo biI6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzdWJwcm9jZXNzLlBvcGVuKFsib3BlbiIsICIt
  >> "!B64TMP!" echo LWJhY2tncm91bmQiLCAiLWEiLCAiRG9ja2VyIl0sCiAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCkK
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIEZhbHNlCiAgICAjIExpbnV4OiBiZXN0IGVmZm9ydCB3aXRob3V0IGFuIGludGVy
  >> "!B64TMP!" echo YWN0aXZlIHBhc3N3b3JkIHByb21wdC4KICAgIHRyeToKICAgICAgICBpZiBoYXNhdHRyKG9zLCAi
  >> "!B64TMP!" echo Z2V0ZXVpZCIpIGFuZCBvcy5nZXRldWlkKCkgPT0gMDoKICAgICAgICAgICAgcmV0dXJuIHN1YnBy
  >> "!B64TMP!" echo b2Nlc3MucnVuKFsic3lzdGVtY3RsIiwgInN0YXJ0IiwgImRvY2tlciJdLAogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpLnJldHVy
  >> "!B64TMP!" echo bmNvZGUgPT0gMAogICAgICAgIHJldHVybiBzdWJwcm9jZXNzLnJ1bihbInN1ZG8iLCAiLW4iLCAi
  >> "!B64TMP!" echo c3lzdGVtY3RsIiwgInN0YXJ0IiwgImRvY2tlciJdLAogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLAogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKS5yZXR1cm5jb2RlID09IDAKICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCAoT1NFcnJvciwgRmlsZU5vdEZvdW5kRXJyb3IpOgogICAgICAgIHJldHVybiBGYWxzZQoKCmRl
  >> "!B64TMP!" echo ZiB3YWl0X2Zvcl9lbmdpbmUodGltZW91dD0xODApOgogICAgZGVhZGxpbmUgPSB0aW1lLnRpbWUo
  >> "!B64TMP!" echo KSArIHRpbWVvdXQKICAgIHdoaWxlIHRpbWUudGltZSgpIDwgZGVhZGxpbmU6CiAgICAgICAgaWYg
  >> "!B64TMP!" echo ZG9ja2VyX2VuZ2luZV91cCgpOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgICAgIHRpbWUu
  >> "!B64TMP!" echo c2xlZXAoMykKICAgIHJldHVybiBGYWxzZQoKCmRlZiBlbnN1cmVfcmVhZHkoY2hlY2tfb25seT1G
  >> "!B64TMP!" echo YWxzZSwgcmVhZHlfdGltZW91dD1Ob25lLCBwb2xsX2V2ZXJ5PU5vbmUpOgogICAgIiIiQnJpbmcg
  >> "!B64TMP!" echo dGhlIGxvY2FsLXNlYXJjaCBzdGFjayB0byBhIHJlYWR5IHN0YXRlLiBORVZFUiBzdG9wcyBpdC4K
  >> "!B64TMP!" echo CiAgICBSZXR1cm5zIChvaywgbWVzc2FnZSwgZXhpdF9jb2RlKToKICAgICAgICBvayAgICAgICAg
  >> "!B64TMP!" echo IFRydWUgd2hlbiBib3RoIGVuZHBvaW50cyBhbnN3ZXIuCiAgICAgICAgbWVzc2FnZSAgICBodW1h
  >> "!B64TMP!" echo bi1yZWFkYWJsZSBzdGF0dXMgLyBndWlkYW5jZSAocHJvZ3Jlc3MgaXMgcHJpbnRlZCB0bwogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgc3RkZXJyIGFsb25nIHRoZSB3YXkpLgogICAgICAgIGV4aXRfY29kZSAg
  >> "!B64TMP!" echo MCByZWFkeSwgMSBkb3duL2NvdWxkIG5vdCBicmluZyB1cCwgMiBwcmVyZXF1aXNpdGVzCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBtaXNzaW5nIChtYXRjaGVzIHRoZSBDTEkgZXhpdCBjb2RlcykuCiAgICAi
  >> "!B64TMP!" echo IiIKICAgIGlmIHJlYWR5X3RpbWVvdXQgaXMgTm9uZToKICAgICAgICByZWFkeV90aW1lb3V0ID0g
  >> "!B64TMP!" echo UkVBRFlfVElNRU9VVAogICAgaWYgcG9sbF9ldmVyeSBpcyBOb25lOgogICAgICAgIHBvbGxfZXZl
  >> "!B64TMP!" echo cnkgPSBQT0xMX0VWRVJZCgogICAgZW5kcG9pbnRzID0gY29uZmlnLmVuZHBvaW50cyhjb25maWcu
  >> "!B64TMP!" echo ZmluZF9pbnN0YWxsX2RpcigpKQogICAgc3QgPSBzdGF0dXMoZW5kcG9pbnRzKQogICAgaWYgYWxs
  >> "!B64TMP!" echo KHN0LnZhbHVlcygpKToKICAgICAgICByZXR1cm4gVHJ1ZSwgcmVhZHlfbWVzc2FnZShlbmRwb2lu
  >> "!B64TMP!" echo dHMpLCAwCgogICAgcHJpbnQoIkxvY2FsLXNlYXJjaCBzdGFjayBpcyBET1dOOiIsIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgIGZvciBuYW1lLCB1cmwgaW4gZW5kcG9pbnRzLml0ZW1zKCk6CiAgICAgICAg
  >> "!B64TMP!" echo bWFyayA9ICJPSyAgIiBpZiBzdFtuYW1lXSBlbHNlICJET1dOIgogICAgICAgIHByaW50KGYiICBb
  >> "!B64TMP!" echo e21hcmt9XSB7RElTUExBWVtuYW1lXX0gOntwb3J0X29mKHVybCl9IiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgaWYgY2hlY2tfb25seToKICAgICAgICByZXR1cm4gRmFsc2UsICJTdGFjayBpcyBkb3du
  >> "!B64TMP!" echo ICgtLWNoZWNrOiBub3RoaW5nIHdhcyBzdGFydGVkKS4iLCAxCgogICAgaWYgbm90IGRvY2tlcl9l
  >> "!B64TMP!" echo bmdpbmVfdXAoKToKICAgICAgICBwcmludCgiRG9ja2VyIGVuZ2luZSBpcyBub3QgcnVubmluZyDi
  >> "!B64TMP!" echo gJQgdHJ5aW5nIHRvIHN0YXJ0IGl0IC4uLiIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgICAgIGlmIG5vdCBzdGFydF9kb2NrZXJfZW5naW5lKCk6CiAgICAgICAgICAgIHJldHVy
  >> "!B64TMP!" echo biBGYWxzZSwgKCJDb3VsZCBub3Qgc3RhcnQgdGhlIERvY2tlciBlbmdpbmUgYXV0b21hdGljYWxs
  >> "!B64TMP!" echo eSAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICIoRG9ja2VyIERlc2t0b3Agbm90IGZvdW5k
  >> "!B64TMP!" echo IGluIHRoZSB1c3VhbCBsb2NhdGlvbnM/KS4gIgogICAgICAgICAgICAgICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo U3RhcnQgaXQgbWFudWFsbHksIHRoZW4gcmUtcnVuIHRoaXMgc2NyaXB0LiIpLCAyCiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoIldhaXRpbmcgZm9yIHRoZSBEb2NrZXIgZW5naW5lIHRvIGNvbWUgdXAgLi4uIiwgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgICAgIGlmIG5vdCB3YWl0X2Zvcl9lbmdpbmUodGltZW91dD0xODAp
  >> "!B64TMP!" echo OgogICAgICAgICAgICByZXR1cm4gRmFsc2UsICgiVGhlIERvY2tlciBlbmdpbmUgd2FzIGxhdW5j
  >> "!B64TMP!" echo aGVkIGJ1dCBkaWQgbm90IGFuc3dlciB3aXRoaW4gIgogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiMTgwIHMuIENoZWNrIERvY2tlciBEZXNrdG9wLCB0aGVuIHJlLXJ1biB0aGlzIHNjcmlwdC4i
  >> "!B64TMP!" echo KSwgMgoKICAgICMgUmVjb21wdXRlZCBub3cgdGhhdCB0aGUgZW5naW5lIGlzIHVwOiB0aGUgY29t
  >> "!B64TMP!" echo cG9zZS1sYWJlbCBsb29rdXAgKHdoaWNoCiAgICAjIG5lZWRzIHRoZSBlbmdpbmUpIGNhbiBmaW5k
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsIGRpciB3aGVyZSB0aGUgb3RoZXIgbWV0aG9kcwogICAgIyBjb3VsZCBub3Qu
  >> "!B64TMP!" echo CiAgICBpbnN0YWxsX2RpciA9IGNvbmZpZy5maW5kX2luc3RhbGxfZGlyKCkKICAgIGlmIG5vdCBp
  >> "!B64TMP!" echo bnN0YWxsX2RpcjoKICAgICAgICByZXR1cm4gRmFsc2UsICgiQ291bGQgbm90IGZpbmQgdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCBpbnN0YWxsIGZvbGRlciAiCiAgICAgICAgICAgICAgICAgICAgICAgIihubyBk
  >> "!B64TMP!" echo b2NrZXItY29tcG9zZS55bWwgZm91bmQpLiBBc2sgdGhlIHVzZXIgd2hlcmUgdGhlaXIgIgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICJsb2NhbC1zZWFyY2ggZm9sZGVyIGlzLCB0aGVuIHJlLXJ1biB0
  >> "!B64TMP!" echo aGlzIHNjcmlwdCB3aXRoICIKICAgICAgICAgICAgICAgICAgICAgICAiTE9DQUxfU0VBUkNIX0RJ
  >> "!B64TMP!" echo UiBzZXQgdG8gdGhhdCBwYXRoLCBvciBzdGFydCB0aGUgc3RhY2sgbWFudWFsbHkgIgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICIoUnVuLmJhdCAvIHJ1bi5zaCkuIiksIDIKCiAgICBjb21wb3NlID0g
  >> "!B64TMP!" echo Y29tcG9zZV9jb21tYW5kKCkKICAgIGlmIG5vdCBjb21wb3NlOgogICAgICAgIHJldHVybiBGYWxz
  >> "!B64TMP!" echo ZSwgIk5laXRoZXIgJ2RvY2tlciBjb21wb3NlJyBub3IgJ2RvY2tlci1jb21wb3NlJyBpcyBhdmFp
  >> "!B64TMP!" echo bGFibGUuIiwgMgoKICAgIHByaW50KGYiU3RhcnRpbmcgc3RhY2sgaW4ge2luc3RhbGxfZGlyfSAu
  >> "!B64TMP!" echo Li4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oY29tcG9zZSAr
  >> "!B64TMP!" echo IFsidXAiLCAiLWQiXSwgY3dkPWluc3RhbGxfZGlyKQogICAgaWYgcHJvYy5yZXR1cm5jb2RlICE9
  >> "!B64TMP!" echo IDA6CiAgICAgICAgcmV0dXJuIEZhbHNlLCAiJ2RvY2tlciBjb21wb3NlIHVwIC1kJyBmYWlsZWQg
  >> "!B64TMP!" echo 4oCUIHNlZSBvdXRwdXQgYWJvdmUuIiwgMQoKICAgIHByaW50KCJXYWl0aW5nIGZvciBlbmRwb2lu
  >> "!B64TMP!" echo dHMgLi4uIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgZGVhZGxpbmUgPSB0aW1lLnRpbWUoKSArIHJl
  >> "!B64TMP!" echo YWR5X3RpbWVvdXQKICAgIHdoaWxlIHRpbWUudGltZSgpIDwgZGVhZGxpbmU6CiAgICAgICAgc3Qg
  >> "!B64TMP!" echo PSBzdGF0dXMoZW5kcG9pbnRzKQogICAgICAgIGlmIGFsbChzdC52YWx1ZXMoKSk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBUcnVlLCByZWFkeV9tZXNzYWdlKGVuZHBvaW50cyksIDAKICAgICAgICB0aW1l
  >> "!B64TMP!" echo LnNsZWVwKHBvbGxfZXZlcnkpCgogICAgZm9yIG5hbWUsIHVybCBpbiBlbmRwb2ludHMuaXRlbXMo
  >> "!B64TMP!" echo KToKICAgICAgICBtYXJrID0gIk9LICAiIGlmIHN0W25hbWVdIGVsc2UgIkRPV04iCiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoZiIgIFt7bWFya31dIHtESVNQTEFZW25hbWVdfSA6e3BvcnRfb2YodXJsKX0iLCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICByZXR1cm4gRmFsc2UsIChmIlN0YWNrIGRpZCBub3QgYmVjb21lIHJl
  >> "!B64TMP!" echo YWR5IHdpdGhpbiB7cmVhZHlfdGltZW91dH1zLiBJbnNwZWN0IHdpdGg6XG4iCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBmIiAgICBjZCB7aW5zdGFsbF9kaXJ9ICYmIGRvY2tlciBjb21wb3NlIGxvZ3MgLS10
  >> "!B64TMP!" echo YWlsIDUwIiksIDEKCgpkZWYgbWFpbigpOgogICAgYXAgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNl
  >> "!B64TMP!" echo cihkZXNjcmlwdGlvbj0iRW5zdXJlIHRoZSBsb2NhbC1zZWFyY2ggRG9ja2VyIHN0YWNrIGlzIHJ1
  >> "!B64TMP!" echo bm5pbmcuIikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1jaGVjayIsIGFjdGlvbj0ic3RvcmVfdHJ1
  >> "!B64TMP!" echo ZSIsCiAgICAgICAgICAgICAgICAgICAgaGVscD0ib25seSByZXBvcnQgc3RhdHVzOyBuZXZlciBz
  >> "!B64TMP!" echo dGFydCBhbnl0aGluZyIpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCgogICAgb2ssIG1lc3Nh
  >> "!B64TMP!" echo Z2UsIGNvZGUgPSBlbnN1cmVfcmVhZHkoY2hlY2tfb25seT1hcmdzLmNoZWNrKQogICAgaWYgb2s6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQobWVzc2FnZSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQobWVzc2Fn
  >> "!B64TMP!" echo ZSwgZmlsZT1zeXMuc3RkZXJyKQogICAgcmV0dXJuIGNvZGUKCgppZiBfX25hbWVfXyA9PSAiX19t
  >> "!B64TMP!" echo YWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\ensure_stack.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_search.py" "!TARGET!\local-web-search\scripts\web_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1822793958.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggdGhlIHdlYiB2aWEgdGhlIGxvY2FsIFNl
  >> "!B64TMP!" echo YXJYTkcgaW5zdGFuY2UgYW5kIHByaW50IGNvbXBhY3QgcmVzdWx0cy4KClVzYWdlOgogICAgcHl0
  >> "!B64TMP!" echo aG9uIHdlYl9zZWFyY2gucHkgInlvdXIgcXVlcnkiIFstLWxpbWl0IDhdIFstLXRpbWUtcmFuZ2Ug
  >> "!B64TMP!" echo ZGF5fHdlZWt8bW9udGhdCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBbLS1jYXRl
  >> "!B64TMP!" echo Z29yaWVzIGl0LG5ld3MsZ2VuZXJhbF0KClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBh
  >> "!B64TMP!" echo cmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1l
  >> "!B64TMP!" echo IGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSBzZWFy
  >> "!B64TMP!" echo Y2ggb25jZS4gWW91IGRvIE5PVCBuZWVkCnRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCU
  >> "!B64TMP!" echo IGp1c3QgcnVuIHRoZSBzZWFyY2guCgpQcmludHMgdXAgdG8gYGxpbWl0YCByZXN1bHRzLCBlYWNo
  >> "!B64TMP!" echo IGFzOgogICAgTi4gPHRpdGxlPgogICAgICAgPHVybD4KICAgICAgIDxzbmlwcGV0PgoiIiIKaW1w
  >> "!B64TMP!" echo b3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMKaW1wb3J0IHVybGxpYi5lcnJvcgppbXBvcnQg
  >> "!B64TMP!" echo dXJsbGliLnBhcnNlCmltcG9ydCB1cmxsaWIucmVxdWVzdAoKIyBEZWZhdWx0IHN0ZG91dC9zdGRl
  >> "!B64TMP!" echo cnIgdG8gVVRGLTggcmVnYXJkbGVzcyBvZiB0aGUgaG9zdCBsb2NhbGUvY29kZXBhZ2UKIyAoZS5n
  >> "!B64TMP!" echo LiBXaW5kb3dzIGNwMTI1MiksIHNvIHNlYXJjaCByZXN1bHRzIHdpdGggbm9uLUFTQ0lJIHRleHQg
  >> "!B64TMP!" echo bmV2ZXIgY3Jhc2gKIyB3aXRoIGEgVW5pY29kZUVuY29kZUVycm9yLiBTa2lwcGVkIGlmIFBZVEhP
  >> "!B64TMP!" echo TklPRU5DT0RJTkcgaXMgYWxyZWFkeSBzZXQg4oCUCiMgYW4gZXhwbGljaXQgb3ZlcnJpZGUgYWx3
  >> "!B64TMP!" echo YXlzIHdpbnMuCmlmICJQWVRIT05JT0VOQ09ESU5HIiBub3QgaW4gb3MuZW52aXJvbjoKICAgIGZv
  >> "!B64TMP!" echo ciBfc3RyZWFtIGluIChzeXMuc3Rkb3V0LCBzeXMuc3RkZXJyKToKICAgICAgICBpZiBoYXNhdHRy
  >> "!B64TMP!" echo KF9zdHJlYW0sICJyZWNvbmZpZ3VyZSIpOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBfc3RyZWFtLnJlY29uZmlndXJlKGVuY29kaW5nPSJ1dGYtOCIpCiAgICAgICAgICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3Mu
  >> "!B64TMP!" echo cGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgY29uZmlnICAj
  >> "!B64TMP!" echo IHNpYmxpbmcgbW9kdWxlOiBpbnN0YWxsLWRpciBsb29rdXAgKyAuZW52LWRyaXZlbiBlbmRwb2lu
  >> "!B64TMP!" echo dHMKCiMgUG9ydCBjb21lcyBmcm9tIFNFQVJYTkdfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xkZXIn
  >> "!B64TMP!" echo cyAuZW52IChkZWZhdWx0IDk5OTApLgpCQVNFID0gY29uZmlnLmVuZHBvaW50cyhjb25maWcuZmlu
  >> "!B64TMP!" echo ZF9pbnN0YWxsX2RpcigpKVsic2VhcnhuZyJdICsgIi9zZWFyY2giCgpUSU1FT1VUID0gMzAgICMg
  >> "!B64TMP!" echo c2Vjb25kcyBwZXIgSFRUUCBhdHRlbXB0CgoKZGVmIGZldGNoKHVybCk6CiAgICAiIiJHRVQgdGhl
  >> "!B64TMP!" echo IFNlYXJYTkcgSlNPTiBBUEkuIFJhaXNlcyBIVFRQRXJyb3Igd2hlbiB0aGUgc2VydmljZSBhbnN3
  >> "!B64TMP!" echo ZXJlZAogICAgd2l0aCBhbiBlcnJvciBzdGF0dXMgKHNlcnZpY2UgaXMgVVApLCBVUkxFcnJvci1m
  >> "!B64TMP!" echo YW1pbHkgb24gY29ubmVjdGlvbgogICAgcHJvYmxlbXMgKHNlcnZpY2UgaXMgRE9XTikuIiIiCiAg
  >> "!B64TMP!" echo ICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KHVybCkKICAgIHdpdGggdXJsbGliLnJlcXVl
  >> "!B64TMP!" echo c3QudXJsb3BlbihyZXEsIHRpbWVvdXQ9VElNRU9VVCkgYXMgcjoKICAgICAgICByZXR1cm4ganNv
  >> "!B64TMP!" echo bi5sb2FkKHIpCgoKZGVmIHNlbGZoZWFsKCk6CiAgICAiIiJTdGFydCB0aGUgRG9ja2VyIGVuZ2lu
  >> "!B64TMP!" echo ZSArIHRoZSBjb250YWluZXJzIGlmIHRoZXkgYXJlIGRvd24gKHRoZSBzYW1lCiAgICBsb2dpYyBh
  >> "!B64TMP!" echo cyBlbnN1cmVfc3RhY2sucHkpLiBJbXBvcnQgaXMgZGVmZXJyZWQgc28gdGhlIGZhc3QgcGF0aCAo
  >> "!B64TMP!" echo c3RhY2sKICAgIGFscmVhZHkgdXApIHBheXMgbm90aGluZy4gUmV0dXJucyAob2ssIG1lc3NhZ2Up
  >> "!B64TMP!" echo LiIiIgogICAgdHJ5OgogICAgICAgIGltcG9ydCBlbnN1cmVfc3RhY2sKICAgICAgICBvaywgbWVz
  >> "!B64TMP!" echo c2FnZSwgX2NvZGUgPSBlbnN1cmVfc3RhY2suZW5zdXJlX3JlYWR5KCkKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo b2ssIG1lc3NhZ2UKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgdW5leHBlY3RlZCBzZWxm
  >> "!B64TMP!" echo LWhlYWwgZmFpbHVyZTogZGVncmFkZSBncmFjZWZ1bGx5CiAgICAgICAgcmV0dXJuIEZhbHNlLCAi
  >> "!B64TMP!" echo c2VsZi1oZWFsIGZhaWxlZCB1bmV4cGVjdGVkbHk6IHt9Ii5mb3JtYXQoZSkKCgpkZWYgbWFpbigp
  >> "!B64TMP!" echo IC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGxpbWl0LCB0aW1lX3JhbmdlLCBj
  >> "!B64TMP!" echo YXRlZ29yaWVzID0gOCwgTm9uZSwgTm9uZQogICAgcXVlcnlfcGFydHMgPSBbXQogICAgaSA9IDAK
  >> "!B64TMP!" echo ICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAgICBpZiBh
  >> "!B64TMP!" echo ID09ICItLWxpbWl0IjoKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGxpbWl0ID0gaW50
  >> "!B64TMP!" echo KGFyZ3NbaV0pCiAgICAgICAgZWxpZiBhID09ICItLXRpbWUtcmFuZ2UiOgogICAgICAgICAgICBp
  >> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgdGltZV9yYW5nZSA9IGFyZ3NbaV0KICAgICAgICBlbGlmIGEgPT0g
  >> "!B64TMP!" echo Ii0tY2F0ZWdvcmllcyI6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBjYXRlZ29yaWVz
  >> "!B64TMP!" echo ID0gYXJnc1tpXQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgICAgICBw
  >> "!B64TMP!" echo cmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAg
  >> "!B64TMP!" echo IHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcXVlcnlfcGFydHMuYXBwZW5kKGEp
  >> "!B64TMP!" echo CiAgICAgICAgaSArPSAxCiAgICBxdWVyeSA9ICIgIi5qb2luKHF1ZXJ5X3BhcnRzKS5zdHJpcCgp
  >> "!B64TMP!" echo CiAgICBpZiBub3QgcXVlcnk6CiAgICAgICAgcHJpbnQoJ3VzYWdlOiB3ZWJfc2VhcmNoLnB5ICJx
  >> "!B64TMP!" echo dWVyeSIgWy0tbGltaXQgTl0gWy0tdGltZS1yYW5nZSBSXSBbLS1jYXRlZ29yaWVzIENdJywgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCgogICAgcGFyYW1zID0geyJxIjogcXVlcnks
  >> "!B64TMP!" echo ICJmb3JtYXQiOiAianNvbiIsICJsYW5ndWFnZSI6ICJlbiJ9CiAgICBpZiB0aW1lX3JhbmdlOgog
  >> "!B64TMP!" echo ICAgICAgIHBhcmFtc1sidGltZV9yYW5nZSJdID0gdGltZV9yYW5nZQogICAgaWYgY2F0ZWdvcmll
  >> "!B64TMP!" echo czoKICAgICAgICBwYXJhbXNbImNhdGVnb3JpZXMiXSA9IGNhdGVnb3JpZXMKICAgIHVybCA9IEJB
  >> "!B64TMP!" echo U0UgKyAiPyIgKyB1cmxsaWIucGFyc2UudXJsZW5jb2RlKHBhcmFtcykKCiAgICBkYXRhID0gTm9u
  >> "!B64TMP!" echo ZQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmZXRjaCh1cmwpCiAgICBleGNlcHQgdXJsbGliLmVy
  >> "!B64TMP!" echo cm9yLkhUVFBFcnJvciBhcyBlOgogICAgICAgICMgVGhlIHNlcnZpY2UgQU5TV0VSRUQgKGV2ZW4g
  >> "!B64TMP!" echo d2l0aCBhbiBlcnJvciBzdGF0dXMpIC0+IGl0IGlzIHVwOwogICAgICAgICMgc3RhcnRpbmcgY29u
  >> "!B64TMP!" echo dGFpbmVycyB3b3VsZCBub3QgaGVscC4KICAgICAgICBwcmludChmIlNFQVJDSCBGQUlMRUQ6IHtl
  >> "!B64TMP!" echo fSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludCgiU2VhclhORyBhbnN3ZXJlZCB3aXRo
  >> "!B64TMP!" echo IGFuIGVycm9yIHN0YXR1cyAodGhlIHN0YWNrIGlzIHJ1bm5pbmcpLiAiCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IlJldHJ5IG9uY2Ugd2l0aCBhIGRpZmZlcmVudCBxdWVyeSwgb3IgaW5zcGVjdCB0aGUgc3RhY2sg
  >> "!B64TMP!" echo d2l0aDogIgogICAgICAgICAgICAgICJjZCA8aW5zdGFsbCBmb2xkZXI+ICYmIGRvY2tlciBjb21w
  >> "!B64TMP!" echo b3NlIGxvZ3MgLS10YWlsIDUwIHNlYXJ4bmciLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICByZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMg
  >> "!B64TMP!" echo Q29ubmVjdGlvbiBlcnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhl
  >> "!B64TMP!" echo YWwgb25jZSwKICAgICAgICAjIHRoZW4gcmV0cnkgdGhlIHNlYXJjaC4KICAgICAgICBwcmludChm
  >> "!B64TMP!" echo IlN0YWNrIHVucmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4u
  >> "!B64TMP!" echo LiIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0g
  >> "!B64TMP!" echo c2VsZmhlYWwoKQogICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwg
  >> "!B64TMP!" echo ZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBwcmludCgiU0VBUkNIIEZBSUxFRDogdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCBzdGFjayBjb3VsZCBub3QgYmUgc3RhcnRlZC4gIgogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiUmVzb2x2ZSB0aGUgc3RhY2sgKG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBEb2NrZXIgRGVz
  >> "!B64TMP!" echo a3RvcCkgIgogICAgICAgICAgICAgICAgICAiYW5kIHJldHJ5IOKAlCBkbyBOT1QgZmFsbCBiYWNr
  >> "!B64TMP!" echo IHRvIG90aGVyIHdlYiB0b29scyB1bmxlc3MgdGhlICIKICAgICAgICAgICAgICAgICAgInVzZXIg
  >> "!B64TMP!" echo YXNrcy4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAxCiAgICAgICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgICAgICBkYXRhID0gZmV0Y2godXJsKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24g
  >> "!B64TMP!" echo YXMgZTI6CiAgICAgICAgICAgIHByaW50KGYiU0VBUkNIIEZBSUxFRCBhZnRlciB0aGUgc3RhY2sg
  >> "!B64TMP!" echo d2FzIHN0YXJ0ZWQ6IHtlMn0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAx
  >> "!B64TMP!" echo CgogICAgcmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIiwgW10pWzpsaW1pdF0KICAgIGlmIG5v
  >> "!B64TMP!" echo dCByZXN1bHRzOgogICAgICAgIHByaW50KCIobm8gcmVzdWx0cykiKQogICAgICAgIHJldHVybiAw
  >> "!B64TMP!" echo CiAgICBmb3IgbiwgaGl0IGluIGVudW1lcmF0ZShyZXN1bHRzLCAxKToKICAgICAgICB0aXRsZSA9
  >> "!B64TMP!" echo IChoaXQuZ2V0KCJ0aXRsZSIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgcmVzdWx0X3VybCA9IGhp
  >> "!B64TMP!" echo dC5nZXQoInVybCIpIG9yICIiCiAgICAgICAgY29udGVudCA9IChoaXQuZ2V0KCJjb250ZW50Iikg
  >> "!B64TMP!" echo b3IgIiIpLnN0cmlwKCkucmVwbGFjZSgiXG4iLCAiICIpCiAgICAgICAgaWYgbGVuKGNvbnRlbnQp
  >> "!B64TMP!" echo ID4gMzAwOgogICAgICAgICAgICBjb250ZW50ID0gY29udGVudFs6MzAwXSArICLigKYiCiAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQoZiJ7bn0uIHt0aXRsZX0iKQogICAgICAgIHByaW50KGYiICAge3Jlc3VsdF91cmx9
  >> "!B64TMP!" echo IikKICAgICAgICBpZiBjb250ZW50OgogICAgICAgICAgICBwcmludChmIiAgIHtjb250ZW50fSIp
  >> "!B64TMP!" echo CiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdCht
  >> "!B64TMP!" echo YWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_scrape.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_scrape.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_scrape.py" "!TARGET!\local-web-search\scripts\web_scrape.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_scrape.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_scrape.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2895407752.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZWFkIGEgd2ViIHBhZ2UgYXMgY2xlYW4gTWFya2Rv
  >> "!B64TMP!" echo d24gdmlhIHRoZSBsb2NhbCBGaXJlY3Jhd2wgaW5zdGFuY2UuCgpVc2FnZToKICAgIHB5dGhvbiB3
  >> "!B64TMP!" echo ZWJfc2NyYXBlLnB5IDx1cmw+IFstLW1heC1jaGFycyAyMDAwMF0KClNlbGYtaGVhbGluZzogaWYg
  >> "!B64TMP!" echo dGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0
  >> "!B64TMP!" echo aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRz
  >> "!B64TMP!" echo IHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCBy
  >> "!B64TMP!" echo ZXRyaWVzIHRoZSBzY3JhcGUgb25jZS4gWW91IGRvIE5PVCBuZWVkCnRvIHJ1biBlbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JhcGUuCgpQcmludHMgdGhlIHBhZ2UncyBN
  >> "!B64TMP!" echo YXJrZG93biB0byBzdGRvdXQsIHRydW5jYXRlZCBhdCAtLW1heC1jaGFycy4KIiIiCmltcG9ydCBq
  >> "!B64TMP!" echo c29uCmltcG9ydCBvcwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIuZXJyb3IKaW1wb3J0IHVybGxp
  >> "!B64TMP!" echo Yi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCByZWdhcmRsZXNzIG9m
  >> "!B64TMP!" echo IHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3AxMjUyKSwgc28gc2Ny
  >> "!B64TMP!" echo YXBlZCBwYWdlIGNvbnRlbnQgd2l0aCBub24tQVNDSUkgdGV4dCBuZXZlcgojIGNyYXNoZXMgd2l0
  >> "!B64TMP!" echo aCBhIFVuaWNvZGVFbmNvZGVFcnJvci4gU2tpcHBlZCBpZiBQWVRIT05JT0VOQ09ESU5HIGlzIGFs
  >> "!B64TMP!" echo cmVhZHkKIyBzZXQg4oCUIGFuIGV4cGxpY2l0IG92ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlU
  >> "!B64TMP!" echo SE9OSU9FTkNPRElORyIgbm90IGluIG9zLmVudmlyb246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lz
  >> "!B64TMP!" echo LnN0ZG91dCwgc3lzLnN0ZGVycik6CiAgICAgICAgaWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25m
  >> "!B64TMP!" echo aWd1cmUiKToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZp
  >> "!B64TMP!" echo Z3VyZShlbmNvZGluZz0idXRmLTgiKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcGFzcwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5w
  >> "!B64TMP!" echo YXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTog
  >> "!B64TMP!" echo aW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5kcG9pbnRzCgojIFBvcnQgY29tZXMg
  >> "!B64TMP!" echo ZnJvbSBGSVJFQ1JBV0xfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IChkZWZhdWx0
  >> "!B64TMP!" echo IDk5OTEpLgpFTkRQT0lOVCA9IGNvbmZpZy5lbmRwb2ludHMoY29uZmlnLmZpbmRfaW5zdGFsbF9k
  >> "!B64TMP!" echo aXIoKSlbImZpcmVjcmF3bCJdICsgIi92MS9zY3JhcGUiCgpUSU1FT1VUID0gOTAgICMgc2Vjb25k
  >> "!B64TMP!" echo cyBwZXIgSFRUUCBhdHRlbXB0CgoKZGVmIGZldGNoKHVybCk6CiAgICAiIiJQT1NUIHRoZSBzY3Jh
  >> "!B64TMP!" echo cGUgcmVxdWVzdC4gUmFpc2VzIEhUVFBFcnJvciB3aGVuIHRoZSBzZXJ2aWNlIGFuc3dlcmVkCiAg
  >> "!B64TMP!" echo ICB3aXRoIGFuIGVycm9yIHN0YXR1cyAoc2VydmljZSBpcyBVUCksIFVSTEVycm9yLWZhbWlseSBv
  >> "!B64TMP!" echo biBjb25uZWN0aW9uCiAgICBwcm9ibGVtcyAoc2VydmljZSBpcyBET1dOKS4iIiIKICAgIGJvZHkg
  >> "!B64TMP!" echo PSBqc29uLmR1bXBzKHsidXJsIjogdXJsLCAiZm9ybWF0cyI6IFsibWFya2Rvd24iXX0pLmVuY29k
  >> "!B64TMP!" echo ZSgpCiAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KAogICAgICAgIEVORFBPSU5ULAog
  >> "!B64TMP!" echo ICAgICAgIGRhdGE9Ym9keSwKICAgICAgICBoZWFkZXJzPXsiQ29udGVudC1UeXBlIjogImFwcGxp
  >> "!B64TMP!" echo Y2F0aW9uL2pzb24ifSwKICAgICAgICBtZXRob2Q9IlBPU1QiLAogICAgKQogICAgd2l0aCB1cmxs
  >> "!B64TMP!" echo aWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGltZW91dD1USU1FT1VUKSBhcyByOgogICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBqc29uLmxvYWQocikKCgpkZWYgc2VsZmhlYWwoKToKICAgICIiIlN0YXJ0IHRoZSBEb2Nr
  >> "!B64TMP!" echo ZXIgZW5naW5lICsgdGhlIGNvbnRhaW5lcnMgaWYgdGhleSBhcmUgZG93biAodGhlIHNhbWUKICAg
  >> "!B64TMP!" echo IGxvZ2ljIGFzIGVuc3VyZV9zdGFjay5weSkuIEltcG9ydCBpcyBkZWZlcnJlZCBzbyB0aGUgZmFz
  >> "!B64TMP!" echo dCBwYXRoIChzdGFjawogICAgYWxyZWFkeSB1cCkgcGF5cyBub3RoaW5nLiBSZXR1cm5zIChvaywg
  >> "!B64TMP!" echo bWVzc2FnZSkuIiIiCiAgICB0cnk6CiAgICAgICAgaW1wb3J0IGVuc3VyZV9zdGFjawogICAgICAg
  >> "!B64TMP!" echo IG9rLCBtZXNzYWdlLCBfY29kZSA9IGVuc3VyZV9zdGFjay5lbnN1cmVfcmVhZHkoKQogICAgICAg
  >> "!B64TMP!" echo IHJldHVybiBvaywgbWVzc2FnZQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOiAgIyB1bmV4cGVj
  >> "!B64TMP!" echo dGVkIHNlbGYtaGVhbCBmYWlsdXJlOiBkZWdyYWRlIGdyYWNlZnVsbHkKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo RmFsc2UsICJzZWxmLWhlYWwgZmFpbGVkIHVuZXhwZWN0ZWRseToge30iLmZvcm1hdChlKQoKCmRl
  >> "!B64TMP!" echo ZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mg
  >> "!B64TMP!" echo b3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX3Nj
  >> "!B64TMP!" echo cmFwZS5weSA8dXJsPiBbLS1tYXgtY2hhcnMgTl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIDIKICAgIHVybCA9IGFyZ3NbMF0KICAgIG1heF9jaGFycyA9IDIwMDAwCiAgICBpID0g
  >> "!B64TMP!" echo MQogICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAgICAgICBpZiBhcmdzW2ldID09ICItLW1heC1j
  >> "!B64TMP!" echo aGFycyIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQo
  >> "!B64TMP!" echo YXJnc1tpICsgMV0pCiAgICAgICAgICAgIGkgKz0gMgogICAgICAgIGVsc2U6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IGkgKz0gMQoKICAgIGRhdGEgPSBOb25lCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZldGNoKHVy
  >> "!B64TMP!" echo bCkKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3IuSFRUUEVycm9yIGFzIGU6CiAgICAgICAgIyBUaGUg
  >> "!B64TMP!" echo c2VydmljZSBBTlNXRVJFRCAoZXZlbiB3aXRoIGFuIGVycm9yIHN0YXR1cykgLT4gaXQgaXMgdXA7
  >> "!B64TMP!" echo CiAgICAgICAgIyBzdGFydGluZyBjb250YWluZXJzIHdvdWxkIG5vdCBoZWxwLgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGYiU0NSQVBFIEZBSUxFRCBmb3Ige3VybH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICBwcmludCgiRmlyZWNyYXdsIGFuc3dlcmVkIHdpdGggYW4gZXJyb3Igc3RhdHVzICh0aGUg
  >> "!B64TMP!" echo c3RhY2sgaXMgcnVubmluZykuICIKICAgICAgICAgICAgICAiUmV0cnkgb25jZSB3aXRoIGEgZGlm
  >> "!B64TMP!" echo ZmVyZW50IHJlc3VsdCBVUkwsIG9yIGluc3BlY3QgdGhlIHN0YWNrICIKICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo d2l0aDogY2QgPGluc3RhbGwgZm9sZGVyPiAmJiBkb2NrZXIgY29tcG9zZSBsb2dzIC0tdGFpbCA1
  >> "!B64TMP!" echo MCAiCiAgICAgICAgICAgICAgImZpcmVjcmF3bCIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMgQ29ubmVjdGlvbiBl
  >> "!B64TMP!" echo cnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhlYWwgb25jZSwKICAg
  >> "!B64TMP!" echo ICAgICAjIHRoZW4gcmV0cnkgdGhlIHNjcmFwZS4KICAgICAgICBwcmludChmIlN0YWNrIHVucmVh
  >> "!B64TMP!" echo Y2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0gc2VsZmhlYWwoKQog
  >> "!B64TMP!" echo ICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgICAgICBwcmludCgiU0NSQVBFIEZBSUxFRCBmb3Ige306IHRoZSBsb2NhbC1z
  >> "!B64TMP!" echo ZWFyY2ggc3RhY2sgY291bGQgbm90IGJlICIKICAgICAgICAgICAgICAgICAgInN0YXJ0ZWQuIFJl
  >> "!B64TMP!" echo c29sdmUgdGhlIHN0YWNrIChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgRG9ja2VyICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIkRlc2t0b3ApIGFuZCByZXRyeSDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBv
  >> "!B64TMP!" echo dGhlciB3ZWIgdG9vbHMgIgogICAgICAgICAgICAgICAgICAidW5sZXNzIHRoZSB1c2VyIGFza3Mu
  >> "!B64TMP!" echo Ii5mb3JtYXQodXJsKSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMQogICAg
  >> "!B64TMP!" echo ICAgIHRyeToKICAgICAgICAgICAgZGF0YSA9IGZldGNoKHVybCkKICAgICAgICBleGNlcHQgRXhj
  >> "!B64TMP!" echo ZXB0aW9uIGFzIGUyOgogICAgICAgICAgICBwcmludChmIlNDUkFQRSBGQUlMRUQgZm9yIHt1cmx9
  >> "!B64TMP!" echo IGFmdGVyIHRoZSBzdGFjayB3YXMgc3RhcnRlZDoge2UyfSIsCiAgICAgICAgICAgICAgICAgIGZp
  >> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDEKCiAgICBwYXlsb2FkID0gZGF0YS5n
  >> "!B64TMP!" echo ZXQoImRhdGEiKSBvciB7fQogICAgbWFya2Rvd24gPSBwYXlsb2FkLmdldCgibWFya2Rvd24iKSBv
  >> "!B64TMP!" echo ciAiIiBpZiBpc2luc3RhbmNlKHBheWxvYWQsIGRpY3QpIGVsc2UgIiIKICAgIGlmIG5vdCBtYXJr
  >> "!B64TMP!" echo ZG93bjoKICAgICAgICBwcmludCgiU0NSQVBFIFJFVFVSTkVEIE5PIE1BUktET1dOIGZvciIsIHVy
  >> "!B64TMP!" echo bCwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0YSlbOjgwMF0s
  >> "!B64TMP!" echo IGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGxlbihtYXJrZG93bikg
  >> "!B64TMP!" echo PiBtYXhfY2hhcnM6CiAgICAgICAgbWFya2Rvd24gPSBtYXJrZG93bls6bWF4X2NoYXJzXSArIGYi
  >> "!B64TMP!" echo XG5cblsuLi4gdHJ1bmNhdGVkIGF0IHttYXhfY2hhcnN9IGNoYXJzIC4uLl0iCiAgICBwcmludCht
  >> "!B64TMP!" echo YXJrZG93bikKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5
  >> "!B64TMP!" echo cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_scrape.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)
if exist "!SRC!\install-local-search.bat" copy /Y "!SRC!\install-local-search.bat" "!TARGET!\install-local-search.bat" >nul 2>&1
if exist "!SRC!\install-local-search.sh"  copy /Y "!SRC!\install-local-search.sh"  "!TARGET!\install-local-search.sh"  >nul 2>&1
REM Always also drop the *current* installer (this script) into target, even if
REM the source copy above was skipped (e.g. user ran a renamed copy of the bat).
copy /Y "%~f0" "!TARGET!\install-local-search.bat" >nul 2>&1

echo Generating secure credentials...
call :genkey SECRET
call :genkey BULL
call :genkey PGPASS
call :genkey RABPASS

echo Writing .env ...
> "!TARGET!\.env" echo # Local Search configuration - generated by install-local-search.bat
>> "!TARGET!\.env" echo # Edit ports/LLM here, then run Update.bat to apply.
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Host ports ----
>> "!TARGET!\.env" echo SEARXNG_PORT=!SEARXNG_PORT!
>> "!TARGET!\.env" echo FIRECRAWL_PORT=!FIRECRAWL_PORT!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- SearXNG instance secret ----
>> "!TARGET!\.env" echo SEARXNG_SECRET=!SECRET!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Firecrawl internal credentials ----
>> "!TARGET!\.env" echo BULL_AUTH_KEY=!BULL!
>> "!TARGET!\.env" echo POSTGRES_DB=firecrawl
>> "!TARGET!\.env" echo POSTGRES_USER=firecrawl
>> "!TARGET!\.env" echo POSTGRES_PASSWORD=!PGPASS!
>> "!TARGET!\.env" echo RABBITMQ_USER=firecrawl
>> "!TARGET!\.env" echo RABBITMQ_PASSWORD=!RABPASS!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo LOGGING_LEVEL=info
if defined OPENAI_BASE_URL (
  >> "!TARGET!\.env" echo.
  >> "!TARGET!\.env" echo # ---- Local LLM for Firecrawl AI features ----
  >> "!TARGET!\.env" echo OPENAI_BASE_URL=!OPENAI_BASE_URL!
  >> "!TARGET!\.env" echo OPENAI_API_KEY=!OPENAI_API_KEY!
  if defined MODEL_NAME >> "!TARGET!\.env" echo MODEL_NAME=!MODEL_NAME!
)

echo Injecting SearXNG secret into settings.yml ...
powershell -NoProfile -Command "(Get-Content -Raw '!TARGET!\config\searxng\settings.yml') -replace '__SEARXNG_SECRET_PLACEHOLDER__', '!SECRET!' | Set-Content -NoNewline '!TARGET!\config\searxng\settings.yml'"

echo Installing the local-web-search agent skill...
set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web-search"
if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"
if not exist "%USERPROFILE%\.agents\skills" mkdir "%USERPROFILE%\.agents\skills"
xcopy /E /I /Y /Q "!TARGET!\local-web-search" "!SKILL_DIR!" >nul
if errorlevel 1 (
  echo   [WARNING] Could not copy the local-web-search skill to !SKILL_DIR!.
) else (
  > "!TARGET!\local-web-search\install-dir.txt" echo !TARGET!
  > "!SKILL_DIR!\install-dir.txt" echo !TARGET!
  echo   Agent skill installed: !SKILL_DIR!
)

REM How long to wait for a just-launched Docker engine to come online (seconds).
set "DD_TIMEOUT=300"
if defined LOCAL_SEARCH_DOCKER_TIMEOUT set "DD_TIMEOUT=!LOCAL_SEARCH_DOCKER_TIMEOUT!"
if not defined DD_LAUNCHED goto docker_engine_ready
echo Waiting for the Docker engine to come online - up to !DD_TIMEOUT! seconds...
set /a DD_WAIT=0
:docker_wait
timeout /t 5 /nobreak >nul 2>&1
if errorlevel 1 ping -n 6 127.0.0.1 >nul 2>&1
set /a DD_WAIT+=5
docker info >nul 2>&1
if not errorlevel 1 goto docker_engine_ready
if !DD_WAIT! geq !DD_TIMEOUT! (
  echo [ERROR] The Docker engine did not come online within !DD_TIMEOUT! seconds.
  echo   Check Docker Desktop for errors, wait until it says "running",
  echo   then re-run this installer.
  pause & exit /b 1
)
set /a "DD_MOD=DD_WAIT %% 15"
if !DD_MOD! equ 0 echo     ... still waiting !DD_WAIT!s
goto docker_wait
:docker_engine_ready
if defined DD_LAUNCHED echo [OK] Docker engine is online after !DD_WAIT!s.

echo.
echo Pulling Docker images (first run downloads ~3-4 GB, please be patient)...
pushd "!TARGET!"
docker compose pull
if !errorlevel! neq 0 ( echo   [WARNING] docker compose pull reported errors. Trying to start anyway... )
echo Starting services...
docker compose up -d
set "UP_RC=!errorlevel!"
popd
if !UP_RC! neq 0 (
  echo.
  echo [ERROR] docker compose up failed. See messages above.
  echo   Common fixes:
  echo     - Make sure Docker Desktop is running.
  echo     - Make sure ports !SEARXNG_PORT! and !FIRECRAWL_PORT! are not in use.
  echo     - Re-run this installer or run Update.bat after fixing.
  echo.
  pause & exit /b 1
)

echo.
echo ============================================================
echo   Installation complete!
echo.
echo   SearXNG  (search + JSON API):  http://localhost:!SEARXNG_PORT!
echo   Firecrawl (scrape/crawl API): http://localhost:!FIRECRAWL_PORT!
echo   local-web-search skill:              %USERPROFILE%\.agents\skills\local-web-search
echo.
echo   If your agent was already running, restart it so it picks up
echo   the new skill.
echo.
echo   Manage the stack with the .bat files in:
echo     !TARGET!
echo       Run.bat   Stop.bat   Update.bat   Uninstall.bat
echo.
echo   See README.md for how to connect this to your AI models
echo   (local-web-search skill, LM Studio, MCP server, direct prompting, etc.).
echo ============================================================
echo.
pause
exit /b 0

REM ===========================================================================
REM  Subroutines
REM ===========================================================================

:validate_port
echo %~1| findstr /r /c:"^[0-9][0-9]*$" >nul
if errorlevel 1 exit /b 1
if %~1 lss 1 exit /b 1
if %~1 gtr 65535 exit /b 1
exit /b 0

:genkey
set "KFILE=%TEMP%\local_search_key.tmp"
powershell -NoProfile -Command "$rng=[Security.Cryptography.RandomNumberGenerator]::Create(); $r=New-Object byte[] 32; $rng.GetBytes($r); -join ($r | ForEach-Object { $_.ToString('x2') })" > "%KFILE%"
set /p "%~1=" < "%KFILE%"
del "%KFILE%" >nul 2>&1
exit /b 0

:decode_b64
REM  %1 = path to a .b64 text file, %2 = output binary path (may not exist yet)
REM  Pass paths via PS variables to survive spaces / quotes in TARGET.
powershell -NoProfile -Command "$in=$env:LS_B64_IN; $out=$env:LS_B64_OUT; [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String(((Get-Content -Raw $in) -replace '\s','')))"
exit /b 0
EOF_INSTALL_LOCAL_SEARCH_BAT
fi
[ -f "$SRC/install-local-search.sh" ] && cp "$SRC/install-local-search.sh" "$TARGET/install-local-search.sh"
[ -f "$SRC/install-local-search.bat" ] && cp "$SRC/install-local-search.bat" "$TARGET/install-local-search.bat"
# Always also drop the *current* installer (this script) into target, even
# if it was renamed (the check above looks for the canonical name).
cp -f "$0" "$TARGET/install-local-search.sh" 2>/dev/null || true
chmod +x "$TARGET"/*.sh 2>/dev/null || true

for f in "$TARGET"/*.bat; do
  [ -f "$f" ] || continue
  if command -v awk >/dev/null 2>&1; then
    awk '{sub(/\r$/,""); printf "%s\r\n", $0}' "$f" > "$f.crlf" 2>/dev/null && mv "$f.crlf" "$f" || rm -f "$f.crlf"
  fi
done

say "Generating secure credentials..."
genkey() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}
SECRET="$(genkey)"; BULL="$(genkey)"; PGPASS="$(genkey)"; RABPASS="$(genkey)"

say "Writing .env ..."
{
  echo "# Local Search configuration - generated by install-local-search.sh"
  echo "# Edit ports/LLM here, then run update.sh to apply."
  echo
  echo "# ---- Host ports ----"
  echo "SEARXNG_PORT=$SEARXNG_PORT"
  echo "FIRECRAWL_PORT=$FIRECRAWL_PORT"
  echo
  echo "# ---- SearXNG instance secret ----"
  echo "SEARXNG_SECRET=$SECRET"
  echo
  echo "# ---- Firecrawl internal credentials ----"
  echo "BULL_AUTH_KEY=$BULL"
  echo "POSTGRES_DB=firecrawl"
  echo "POSTGRES_USER=firecrawl"
  echo "POSTGRES_PASSWORD=$PGPASS"
  echo "RABBITMQ_USER=firecrawl"
  echo "RABBITMQ_PASSWORD=$RABPASS"
  echo
  echo "LOGGING_LEVEL=info"
  if [ -n "$OPENAI_BASE_URL" ]; then
    echo
    echo "# ---- Local LLM for Firecrawl AI features ----"
    echo "OPENAI_BASE_URL=$OPENAI_BASE_URL"
    echo "OPENAI_API_KEY=$OPENAI_API_KEY"
    [ -n "$MODEL_NAME" ] && echo "MODEL_NAME=$MODEL_NAME"
  fi
} > "$TARGET/.env"

say "Injecting SearXNG secret into settings.yml ..."
SFILE="$TARGET/config/searxng/settings.yml"
sed "s/__SEARXNG_SECRET_PLACEHOLDER__/$SECRET/" "$SFILE" > "$SFILE.tmp" && mv "$SFILE.tmp" "$SFILE"

say "Installing the local-web-search agent skill..."
SKILL_DIR="$HOME/.agents/skills/local-web-search"
rm -rf "$SKILL_DIR"
mkdir -p "$HOME/.agents/skills"
if cp -r "$TARGET/local-web-search" "$SKILL_DIR"; then
  printf '%s\n' "$TARGET" > "$TARGET/local-web-search/install-dir.txt"
  printf '%s\n' "$TARGET" > "$SKILL_DIR/install-dir.txt"
  say "  Agent skill installed: $SKILL_DIR"
else
  say "  ${YELLOW}[WARNING]${RESET} could not copy the local-web-search skill to $SKILL_DIR"
fi

if [ "$ENGINE_LAUNCHED" = "1" ]; then
  say "Waiting for the Docker engine to come online - up to ${DOCKER_WAIT_TIMEOUT}s..."
  DD_WAIT=0
  while ! docker info >/dev/null 2>&1; do
    sleep 5
    DD_WAIT=$((DD_WAIT + 5))
    if [ "$DD_WAIT" -ge "$DOCKER_WAIT_TIMEOUT" ]; then
      err "The Docker engine did not come online within ${DOCKER_WAIT_TIMEOUT}s."
      say "  Check Docker Desktop or: sudo systemctl status docker"
      say "  Linux permission denied from docker info? add yourself to the"
      say "  docker group:  sudo usermod -aG docker $USER  (log out and back in)"
      say "  then start Docker and re-run this installer."
      exit 1
    fi
    if [ $((DD_WAIT % 15)) -eq 0 ]; then say "  ... still waiting, ${DD_WAIT}s elapsed"; fi
  done
  ok "Docker engine is online after ${DD_WAIT}s."
fi

echo
say "Pulling Docker images (first run downloads ~3-4 GB, please be patient)..."
cd "$TARGET"
$DC pull || say "${YELLOW}[WARNING]${RESET} some images failed to pull; trying to start anyway."
say "Starting services..."
if ! $DC up -d; then
  err "docker compose up failed. See messages above."
  say "  Common fixes:"
  say "    - Make sure Docker is running (and your user is in the 'docker' group on Linux)."
  say "    - Make sure ports $SEARXNG_PORT and $FIRECRAWL_PORT are not in use."
  say "    - Re-run this installer or run update.sh after fixing."
  exit 1
fi

echo
say "${GREEN}============================================================${RESET}"
say "${GREEN}  Installation complete!${RESET}"
echo
say "  SearXNG  (search + JSON API):  http://localhost:$SEARXNG_PORT"
say "  Firecrawl (scrape/crawl API): http://localhost:$FIRECRAWL_PORT"
say "  local-web-search skill:              $HOME/.agents/skills/local-web-search"
echo
say "  If your agent was already running, restart it so it picks up"
say "  the new skill."
echo
say "  Manage the stack with the scripts in:"
say "    $TARGET"
say "      ./run.sh   ./stop.sh   ./update.sh   ./uninstall.sh"
echo
say "  See README.md for how to connect this to your AI models"
say "  (local-web-search skill, LM Studio, MCP server, direct prompting, etc.)."
say "${GREEN}============================================================${RESET}"
