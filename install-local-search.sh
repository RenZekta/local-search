#!/usr/bin/env bash
# =============================================================================
#  Local Search Installer  (Firecrawl + SearXNG + local-web skill)
#                        -  Linux & macOS
# =============================================================================
#  Self-contained: every file the installer needs is embedded below as a
#  quoted heredoc. If a source file is missing from this script's folder
#  (e.g. you only downloaded this one .sh), the embedded copy is used.
#  After installing the stack it also copies the bundled local-web agent
#  skill into ~/.agents/skills/local-web.
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
  Local Search Installer  (Firecrawl + SearXNG + local-web)
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
say "  Agent skill:    $HOME/.agents/skills/local-web"
if [ -n "$OPENAI_BASE_URL" ]; then
  say "  LLM endpoint:   $OPENAI_BASE_URL  $MODEL_NAME"
else
  say "  LLM endpoint:   (none - enable later by editing .env)"
fi
say "${BOLD}============================================================${RESET}"
printf "Proceed with install? [Y/n]: "
read -r CONFIRM
if [ "$(lower "$CONFIRM")" = "n" ]; then say "Install cancelled."; exit 0; fi

mkdir -p "$TARGET/config/searxng" "$TARGET/local-web/scripts"

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

**SearXNG + Firecrawl + the local-web agent skill, running entirely on your machine, behind two local ports.**

Give any LLM — a local model in LM Studio, a cloud model, an agent, an MCP
client, or a plain chat UI — the ability to **search the web and read pages**
without sending a single request to a paid scraping API. Everything runs in
Docker on your computer; your queries, results, and page contents never leave
your network.

| What | URL (default) | Purpose |
|------|---------------|---------|
| **SearXNG**  | `http://localhost:9990` | Metasearch + JSON API. Aggregates Google/Bing/DuckDuckGo/etc. |
| **Firecrawl** | `http://localhost:9991` | Scrape / crawl / map / search / extract — returns clean Markdown. |
| **local-web** | `~/.agents/skills/local-web` | Bundled agent skill: search + read + auto-start the stack. |

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
   - [A. The bundled local-web skill (recommended)](#a-the-bundled-local-web-skill-recommended)
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

On top of the containers, the installer bundles **local-web** — a skill for
agents that load skills from `~/.agents/skills/` (`C:\Users\You\.agents\skills\`
on Windows). It gives the agent a complete web-research workflow: search via
SearXNG, read pages via Firecrawl, and even start the Docker stack
automatically when it's down. See [section A](#a-the-bundled-local-web-skill-recommended).

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
- **Python 3.8+** for the bundled local-web skill scripts (optional but recommended — it's the easiest way to use the stack).
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
> `config/searxng/settings.yml`, `.env.example`, the bundled `local-web` skill,
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
local-web skill**, pulls the images, and starts the stack.

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
Agent skill: C:\Users\You\.agents\skills\local-web   (or ~/.agents/skills/local-web)
```

Open `http://localhost:9990` in a browser to see the SearXNG search UI — or,
if your agent loads skills from `~/.agents/skills/`, just ask it to research
something current and it will use **local-web** automatically (see
[section A](#a-the-bundled-local-web-skill-recommended)).

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
  it also re-copies the bundled `local-web` skill into `~/.agents/skills/`.
- **Uninstall** runs `docker compose down -v` (deletes volumes + data),
  removes the `local-web` skill from `~/.agents/skills/local-web`, then
  optionally deletes the install folder. Pulled images are kept; reclaim them
  with `docker image prune -a` if desired.

---

## How it fits together

```
        your AI model / agent (local-web skill) / MCP client / chat UI
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
3. **local-web skill auto-install** — the installer copies the bundled skill to
   `~/.agents/skills/local-web/` (add/override) and records the install path in
   an `install-dir.txt` hint inside the skill, so the skill finds the stack even
   if you installed to a custom folder and Docker isn't running yet.

---

## Using it with AI models

There are **seven** ways to use this system, from lowest to highest
integration. Pick what fits your stack — you can mix and match.

### A. The bundled local-web skill (recommended)

The installer ships with **local-web**, an agent skill that turns any
skill-loading agent into a web researcher with zero configuration. If your
agent reads skills from `~/.agents/skills/`
(`C:\Users\You\.agents\skills\` on Windows), it's already available after
install — restart the agent if it was running.

The installer:
- puts a copy in `<install folder>/local-web/`, and
- **automatically installs (add/override)** it into
  `~/.agents/skills/local-web/`.

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
python ~/.agents/skills/local-web/scripts/web_search.py "latest python release"
python ~/.agents/skills/local-web/scripts/web_scrape.py "https://example.com"
# optional pre-flight check / status report:
python ~/.agents/skills/local-web/scripts/ensure_stack.py --check
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
> model fails to load the MCP tools, use the bundled **local-web skill**
> ([section A](#a-the-bundled-local-web-skill-recommended)) instead — it works
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

The local-web skill needs no configuration: it reads the same `.env` at
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

**The local-web skill can't find the install folder.**
The skill looks for the compose folder via (1) the `LOCAL_SEARCH_DIR` env var,
(2) the compose labels on the running containers, (3) the `install-dir.txt`
hint the installer wrote next to the skill, and (4) `~/local-search`. If you
moved the install folder, re-run the installer or `Update.bat` / `./update.sh`
to refresh the hint — or export `LOCAL_SEARCH_DIR=/path/to/local-search`.

**The agent doesn't see the skill after install.**
Skills are usually scanned at agent startup — restart the agent. Also check the
skill actually landed at `~/.agents/skills/local-web/SKILL.md` (the installer
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
  `local-web` into `~/.agents/skills/`). Data is preserved.
- **Update the SearXNG `settings.yml` / `docker-compose.yml` template:** re-run
  the installer — it copies the latest template over, refreshes the
  `local-web` skill, and backs up your existing `.env` to `.env.bak.<timestamp>`.
- **Uninstall:** `Uninstall.bat` / `./uninstall.sh`. Removes containers + Docker
  volumes (all Firecrawl/SearXNG data) + the `local-web` skill from
  `~/.agents/skills/local-web`, then asks whether to delete the install folder.
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
(it covers the bundled [local-web](local-web) skill too).

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
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.

----------------------------------------------------------------------

NOTE: This project is configuration glue plus a small agent skill
(local-web); it bundles no upstream source code. When you run the
installer, Docker pulls the official images of the following
third-party projects, each governed by its own license:

  - SearXNG        https://github.com/searxng/searxng        (AGPL-3.0)
  - Firecrawl      https://github.com/firecrawl/firecrawl   (AGPL-3.0
                  with a commercial option for the hosted service)
  - Redis          https://redis.io                          (RSALv2/SSPL)
  - Playwright     https://github.com/firecrawl/firecrawl
                  playwright-service                        (AGPL-3.0)

By using this installer you also accept the licenses of those
upstream projects.
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
echo [3/3] Refreshing the local-web agent skill...
if exist "%~dp0local-web\SKILL.md" (
  set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web"
  if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"
  if not exist "%USERPROFILE%\.agents\skills" mkdir "%USERPROFILE%\.agents\skills"
  xcopy /E /I /Y /Q "%~dp0local-web" "!SKILL_DIR!" >nul
  if errorlevel 1 (
    echo   [WARNING] Could not copy the skill to !SKILL_DIR!.
  ) else (
    > "!SKILL_DIR!\install-dir.txt" echo %~dp0
    echo   Skill refreshed at !SKILL_DIR!
  )
) else (
  echo   local-web skill source not found in this folder - skipping.
)

echo.
echo Update complete. Data volumes were preserved.
echo   - If you changed ports or LLM settings in .env, they are now applied.
echo   - The local-web skill was re-synced from this folder.
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
echo   3. Remove the local-web agent skill from
echo      %USERPROFILE%\.agents\skills\local-web
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
echo Removing the local-web agent skill...
set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web"
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
# and re-sync the local-web agent skill. Data volumes are preserved. Edits
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
echo "[3/3] Refreshing the local-web agent skill..."
if [ -f "./local-web/SKILL.md" ]; then
  SKILL_DIR="$HOME/.agents/skills/local-web"
  rm -rf "$SKILL_DIR"
  mkdir -p "$HOME/.agents/skills"
  if cp -r ./local-web "$SKILL_DIR"; then
    printf '%s\n' "$(pwd)" > "$SKILL_DIR/install-dir.txt"
    echo "  Skill refreshed at $SKILL_DIR"
  else
    echo "  [WARNING] Could not copy the skill to $SKILL_DIR."
  fi
else
  echo "  local-web skill source not found in this folder - skipping."
fi

echo
echo "Update complete. Data volumes were preserved."
echo "  - Port / LLM changes in .env are now applied."
echo "  - The local-web skill was re-synced from this folder."
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
#   - removes the local-web agent skill (~/.agents/skills/local-web)
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
  3. Remove the local-web agent skill from
     ~/.agents/skills/local-web
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
echo "Removing the local-web agent skill..."
SKILL_DIR="$HOME/.agents/skills/local-web"
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

# --- local-web/SKILL.md ---
if [ -f "$SRC/local-web/SKILL.md" ]; then
  cp "$SRC/local-web/SKILL.md" "$TARGET/local-web/SKILL.md"
else
  say "  [embedded] local-web/SKILL.md  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web/SKILL.md" <<'EOF_LOCAL_WEB_SKILL_MD'
---
name: local-web
description: >-
  Search the web and read web pages through the local private stack — SearXNG and Firecrawl on localhost (ports read from the local-search .env, defaults 9990/9991). No API keys, no external services, no MCP tools. The scripts auto-start the local Docker stack when it is down. Use whenever the user asks about anything current, recent, or you are unsure about: news, events, latest versions or releases, documentation, facts to verify, "what do you know about X" questions — even when they don't explicitly say "search the web".
---

# Local web research

This machine runs a private web-research stack on localhost:

- **SearXNG** — metasearch with a JSON API, at `http://localhost:9990` by default
- **Firecrawl** — turns any URL into clean Markdown, at `http://localhost:9991` by default

Everything stays local; no API keys are needed. The actual ports are read
from `SEARXNG_PORT` / `FIRECRAWL_PORT` in the local-search install folder's
`.env` (the same file the compose setup uses), so if custom ports were picked
at setup time, the scripts follow them automatically. Helper scripts (in this
skill's `scripts/` directory) do the HTTP and Docker work for you — run them
with the Bash tool using `python`. The services live in Docker containers.

**No warm-up step is needed.** If the stack is down, the scripts start the
Docker engine (if it's off) and the containers automatically (the same
command Run.bat / run.sh run), wait for them, and retry — they never stop
the stack (stopping is the user's job, via Stop.bat / stop.sh). Even in an
old conversation where the stack has since gone down, just call the search
or scrape script directly; it will bring everything back by itself.

## Workflow

1. **Search the web** — go straight ahead:

   ```bash
   python "<skill-base-dir>/scripts/web_search.py" "your query here"
   ```

   Prints the top results as `title / url / ~300-char snippet`.
   Useful options: `--limit 10`, `--time-range day|week|month`,
   `--categories it,news,general`.

   If the stack is down, the script reports `Stack unreachable ... starting
   it automatically` on stderr, boots it, and retries. Give the Bash call a
   10-minute timeout to allow for that (engine boot + container boot); only
   a first-ever start (pulling ~3 GB of images) can exceed it.

2. **Read the pages** — scrape the 1–3 most relevant result URLs for full text:

   ```bash
   python "<skill-base-dir>/scripts/web_scrape.py" "https://example.com/article"
   ```

   Prints clean Markdown (truncated at 20,000 chars by default; raise with
   `--max-chars`). Self-heals a down stack the same way. Only ever scrape
   URLs that the search results actually returned — never invent or guess
   URLs.

3. **Answer with citations** — back each factual claim with the URL you read.

`ensure_stack.py` is still available as an optional pre-flight check or
status report (`python "<skill-base-dir>/scripts/ensure_stack.py"`, add
`--check` to only report status and never start anything), but it is NOT
required before searching — the search/scrape scripts handle a down stack
themselves.

## Error handling

- If a search or scrape fails, retry **once** with a different query (search)
  or a different result URL (scrape).
- Connection errors are handled for you: the scripts start the Docker engine
  and the containers automatically, wait until they answer, and retry the
  request once. Only if a script reports it could not launch the engine at
  all (or the stack did not become ready) should you ask the user to start
  Docker Desktop manually, then retry.
- **Do not fall back to built-in or alternative web tools** when this stack
  has a problem — fix the stack (or ask the user) and retry, unless the user
  explicitly asks for an alternative.
- Only if a script reports it could not find the local-search install
  folder: ask the user where that folder is, then re-run the script with
  `LOCAL_SEARCH_DIR=<that path>`. Don't do this preemptively — the folder is
  normally detected automatically (from the compose label on the running
  containers, the path recorded by the local-search installer, or from
  ~/local-search).
- Scrape output is long. Extract only the parts you need for the answer; don't
  paste whole pages back to the user.
EOF_LOCAL_WEB_SKILL_MD
fi

# --- local-web/scripts/config.py ---
if [ -f "$SRC/local-web/scripts/config.py" ]; then
  cp "$SRC/local-web/scripts/config.py" "$TARGET/local-web/scripts/config.py"
else
  say "  [embedded] local-web/scripts/config.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web/scripts/config.py" <<'EOF_LOCAL_WEB_SCRIPTS_CONFIG_PY'
"""Shared helpers for the local-web scripts: locating the local-search
install folder and the endpoints it is actually listening on.

The ports are NOT assumed: they are read from the install folder's .env
file (the same one the compose setup and Run.bat / Update.bat use), so if
the user picked custom ports during setup, every script follows them.
Defaults mirror the compose file's ${VAR:-default} fallbacks:
SearXNG 9990, Firecrawl 9991.
"""
import os
import subprocess

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
    skill was installed standalone from the local-web repo)."""
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
EOF_LOCAL_WEB_SCRIPTS_CONFIG_PY
fi

# --- local-web/scripts/ensure_stack.py ---
if [ -f "$SRC/local-web/scripts/ensure_stack.py" ]; then
  cp "$SRC/local-web/scripts/ensure_stack.py" "$TARGET/local-web/scripts/ensure_stack.py"
else
  say "  [embedded] local-web/scripts/ensure_stack.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web/scripts/ensure_stack.py" <<'EOF_LOCAL_WEB_SCRIPTS_ENSURE_STACK_PY'
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

READY_TIMEOUT = int(os.environ.get("LOCAL_SEARCH_READY_TIMEOUT", "240") or 240)
POLL_EVERY = 3
DISPLAY = {"searxng": "SearXNG", "firecrawl": "Firecrawl"}


def endpoint_up(url, timeout=4):
    """True if the endpoint accepts connections (any HTTP status counts)."""
    req = urllib.request.Request(url, headers={"User-Agent": "zcode-local-web/1.0"})
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
EOF_LOCAL_WEB_SCRIPTS_ENSURE_STACK_PY
fi

# --- local-web/scripts/web_search.py ---
if [ -f "$SRC/local-web/scripts/web_search.py" ]; then
  cp "$SRC/local-web/scripts/web_search.py" "$TARGET/local-web/scripts/web_search.py"
else
  say "  [embedded] local-web/scripts/web_search.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web/scripts/web_search.py" <<'EOF_LOCAL_WEB_SCRIPTS_WEB_SEARCH_PY'
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Port comes from SEARXNG_PORT in the install folder's .env (default 9990).
BASE = config.endpoints(config.find_install_dir())["searxng"] + "/search"

TIMEOUT = 30  # seconds per HTTP attempt


def fetch(url):
    """GET the SearXNG JSON API. Raises HTTPError when the service answered
    with an error status (service is UP), URLError-family on connection
    problems (service is DOWN)."""
    req = urllib.request.Request(url, headers={"User-Agent": "zcode-local-web/1.0"})
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
EOF_LOCAL_WEB_SCRIPTS_WEB_SEARCH_PY
fi

# --- local-web/scripts/web_scrape.py ---
if [ -f "$SRC/local-web/scripts/web_scrape.py" ]; then
  cp "$SRC/local-web/scripts/web_scrape.py" "$TARGET/local-web/scripts/web_scrape.py"
else
  say "  [embedded] local-web/scripts/web_scrape.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web/scripts/web_scrape.py" <<'EOF_LOCAL_WEB_SCRIPTS_WEB_SCRAPE_PY'
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
        headers={"Content-Type": "application/json", "User-Agent": "zcode-local-web/1.0"},
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
EOF_LOCAL_WEB_SCRIPTS_WEB_SCRAPE_PY
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
REM  Local Search Installer  (Firecrawl + SearXNG + local-web skill)  -  Windows
REM ===========================================================================
REM  Self-contained: every file the installer needs is embedded below as
REM  base64. If a source file is missing from this script's folder (e.g. you
REM  only downloaded this one .bat), the embedded copy is used instead.
REM  After installing the stack it also copies the bundled local-web agent
REM  skill into %USERPROFILE%\.agents\skills\local-web.
REM  If the Docker engine is not running, the installer launches Docker
REM  Desktop automatically and waits for it before pulling images.
REM ===========================================================================

echo ============================================================
echo   Local Search Installer  (Firecrawl + SearXNG + local-web)
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
echo   Agent skill:    %USERPROFILE%\.agents\skills\local-web
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
if not exist "!TARGET!\local-web\scripts" mkdir "!TARGET!\local-web\scripts"

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
  >> "!B64TMP!" echo IEFJIG1vZGVscwoKKipTZWFyWE5HICsgRmlyZWNyYXdsICsgdGhlIGxvY2FsLXdlYiBhZ2VudCBz
  >> "!B64TMP!" echo a2lsbCwgcnVubmluZyBlbnRpcmVseSBvbiB5b3VyIG1hY2hpbmUsIGJlaGluZCB0d28gbG9jYWwg
  >> "!B64TMP!" echo cG9ydHMuKioKCkdpdmUgYW55IExMTSDigJQgYSBsb2NhbCBtb2RlbCBpbiBMTSBTdHVkaW8sIGEg
  >> "!B64TMP!" echo Y2xvdWQgbW9kZWwsIGFuIGFnZW50LCBhbiBNQ1AKY2xpZW50LCBvciBhIHBsYWluIGNoYXQgVUkg
  >> "!B64TMP!" echo 4oCUIHRoZSBhYmlsaXR5IHRvICoqc2VhcmNoIHRoZSB3ZWIgYW5kIHJlYWQgcGFnZXMqKgp3aXRo
  >> "!B64TMP!" echo b3V0IHNlbmRpbmcgYSBzaW5nbGUgcmVxdWVzdCB0byBhIHBhaWQgc2NyYXBpbmcgQVBJLiBFdmVy
  >> "!B64TMP!" echo eXRoaW5nIHJ1bnMgaW4KRG9ja2VyIG9uIHlvdXIgY29tcHV0ZXI7IHlvdXIgcXVlcmllcywgcmVz
  >> "!B64TMP!" echo dWx0cywgYW5kIHBhZ2UgY29udGVudHMgbmV2ZXIgbGVhdmUKeW91ciBuZXR3b3JrLgoKfCBXaGF0
  >> "!B64TMP!" echo IHwgVVJMIChkZWZhdWx0KSB8IFB1cnBvc2UgfAp8LS0tLS0tfC0tLS0tLS0tLS0tLS0tLXwtLS0t
  >> "!B64TMP!" echo LS0tLS18CnwgKipTZWFyWE5HKiogIHwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAgfCBNZXRhc2Vh
  >> "!B64TMP!" echo cmNoICsgSlNPTiBBUEkuIEFnZ3JlZ2F0ZXMgR29vZ2xlL0JpbmcvRHVja0R1Y2tHby9ldGMuIHwK
  >> "!B64TMP!" echo fCAqKkZpcmVjcmF3bCoqIHwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MWAgfCBTY3JhcGUgLyBjcmF3
  >> "!B64TMP!" echo bCAvIG1hcCAvIHNlYXJjaCAvIGV4dHJhY3Qg4oCUIHJldHVybnMgY2xlYW4gTWFya2Rvd24uIHwK
  >> "!B64TMP!" echo fCAqKmxvY2FsLXdlYioqIHwgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViYCB8IEJ1bmRsZWQg
  >> "!B64TMP!" echo YWdlbnQgc2tpbGw6IHNlYXJjaCArIHJlYWQgKyBhdXRvLXN0YXJ0IHRoZSBzdGFjay4gfAoKPiBC
  >> "!B64TMP!" echo b3RoIHBvcnRzIGFyZSBmdWxseSBjb25maWd1cmFibGUgYXQgaW5zdGFsbCB0aW1lLiBUaGUgZGVm
  >> "!B64TMP!" echo YXVsdHMgKGA5OTkwYCBhbmQKPiBgOTk5MWApIGFyZSBjaG9zZW4gdG8gYXZvaWQgY2xhc2hpbmcg
  >> "!B64TMP!" echo d2l0aCBjb21tb24gZGV2IHNlcnZlcnMuCgotLS0KCiMjIFRhYmxlIG9mIGNvbnRlbnRzCgoxLiBb
  >> "!B64TMP!" echo V2hhdCB5b3UgZ2V0XSgjd2hhdC15b3UtZ2V0KQoyLiBbUmVxdWlyZW1lbnRzXSgjcmVxdWlyZW1l
  >> "!B64TMP!" echo bnRzKQozLiBbUXVpY2sgc3RhcnQgKG9uZS1jbGljayBpbnN0YWxsKV0oI3F1aWNrLXN0YXJ0LW9u
  >> "!B64TMP!" echo ZS1jbGljay1pbnN0YWxsKQo0LiBbTWFuYWdpbmcgdGhlIHN0YWNrXSgjbWFuYWdpbmctdGhlLXN0
  >> "!B64TMP!" echo YWNrKQo1LiBbSG93IGl0IGZpdHMgdG9nZXRoZXJdKCNob3ctaXQtZml0cy10b2dldGhlcikKNi4g
  >> "!B64TMP!" echo W1VzaW5nIGl0IHdpdGggQUkgbW9kZWxzXSgjdXNpbmctaXQtd2l0aC1haS1tb2RlbHMpCiAgIC0g
  >> "!B64TMP!" echo W0EuIFRoZSBidW5kbGVkIGxvY2FsLXdlYiBza2lsbCAocmVjb21tZW5kZWQpXSgjYS10aGUtYnVu
  >> "!B64TMP!" echo ZGxlZC1sb2NhbC13ZWItc2tpbGwtcmVjb21tZW5kZWQpCiAgIC0gW0IuIERpcmVjdCBTZWFyWE5H
  >> "!B64TMP!" echo IEpTT04gQVBJXSgjYi1kaXJlY3Qtc2VhcnhuZy1qc29uLWFwaSkKICAgLSBbQy4gRGlyZWN0IEZp
  >> "!B64TMP!" echo cmVjcmF3bCBSRVNUIEFQSV0oI2MtZGlyZWN0LWZpcmVjcmF3bC1yZXN0LWFwaSkKICAgLSBbRC4g
  >> "!B64TMP!" echo Q29ubmVjdCBhIGxvY2FsIExMTSAoTE0gU3R1ZGlvLCBldGMuKV0oI2QtY29ubmVjdC1hLWxvY2Fs
  >> "!B64TMP!" echo LWxsbS1sbS1zdHVkaW8tZXRjKQogICAtIFtFLiBWaWEgYW4gTUNQIHNlcnZlcl0oI2UtdmlhLWFu
  >> "!B64TMP!" echo LW1jcC1zZXJ2ZXIpCiAgIC0gW0YuIFZpYSBwcm9tcHRpbmcgKGFueSBjaGF0IFVJKV0oI2Ytdmlh
  >> "!B64TMP!" echo LXByb21wdGluZy1hbnktY2hhdC11aSkKICAgLSBbRy4gR1VJIGludGVncmF0aW9uc10oI2ctZ3Vp
  >> "!B64TMP!" echo LWludGVncmF0aW9ucykKNy4gW0NvbmZpZ3VyYXRpb24gcmVmZXJlbmNlXSgjY29uZmlndXJhdGlv
  >> "!B64TMP!" echo bi1yZWZlcmVuY2UpCjguIFtUcm91Ymxlc2hvb3RpbmddKCN0cm91Ymxlc2hvb3RpbmcpCjkuIFtV
  >> "!B64TMP!" echo cGRhdGluZyAmIHVuaW5zdGFsbGluZ10oI3VwZGF0aW5nLS11bmluc3RhbGxpbmcpCjEwLiBbU2Vj
  >> "!B64TMP!" echo dXJpdHkgbm90ZXNdKCNzZWN1cml0eS1ub3RlcykKMTEuIFtDcmVkaXRzICYgbGljZW5zZXNdKCNj
  >> "!B64TMP!" echo cmVkaXRzLS1saWNlbnNlcykKCi0tLQoKIyMgV2hhdCB5b3UgZ2V0CgpBIHNpbmdsZSBEb2NrZXIg
  >> "!B64TMP!" echo Q29tcG9zZSBzdGFjayBvZiBzaXggc2VydmljZXMgb24gYSBwcml2YXRlIGJyaWRnZSBuZXR3b3Jr
  >> "!B64TMP!" echo LAoqKnBsdXMqKiBhIHJlYWR5LW1hZGUgYWdlbnQgc2tpbGwgdGhhdCB0aWVzIGl0IGFsbCB0b2dl
  >> "!B64TMP!" echo dGhlcjoKCnwgU2VydmljZSB8IEltYWdlIHwgUm9sZSB8CnwtLS0tLS0tLS18LS0tLS0tLXwtLS0t
  >> "!B64TMP!" echo LS18CnwgKipzZWFyeG5nKiogfCBgc2VhcnhuZy9zZWFyeG5nOmxhdGVzdGAgfCBNZXRhc2VhcmNo
  >> "!B64TMP!" echo IGVuZ2luZSB3aXRoICoqSlNPTiBvdXRwdXQgZW5hYmxlZCoqIGFuZCB0aGUgcmF0ZS1saW1pdGVy
  >> "!B64TMP!" echo ICoqZGlzYWJsZWQqKiwgc28gbW9kZWxzIGNhbiBxdWVyeSBpdCBwcm9ncmFtbWF0aWNhbGx5LiB8
  >> "!B64TMP!" echo CnwgKipmaXJlY3Jhd2wqKiB8IGBnaGNyLmlvL2ZpcmVjcmF3bC9maXJlY3Jhd2w6bGF0ZXN0YCB8
  >> "!B64TMP!" echo IFRoZSBzY3JhcGluZy9jcmF3bGluZy9zZWFyY2ggQVBJLiBSdW5zIHdpdGggYFVTRV9EQl9BVVRI
  >> "!B64TMP!" echo RU5USUNBVElPTj1mYWxzZWAg4oaSICoqbm8gQVBJIGtleSBuZWVkZWQqKiBmb3IgbG9jYWwgdXNl
  >> "!B64TMP!" echo LiB8CnwgKipwbGF5d3JpZ2h0LXNlcnZpY2UqKiB8IGBnaGNyLmlvL2ZpcmVjcmF3bC9wbGF5d3Jp
  >> "!B64TMP!" echo Z2h0LXNlcnZpY2U6bGF0ZXN0YCB8IEhlYWRsZXNzIENocm9taXVtIGZvciBKYXZhU2NyaXB0LXJl
  >> "!B64TMP!" echo bmRlcmVkIHBhZ2VzLiB8CnwgKipyZWRpcyoqIHwgYHJlZGlzOmFscGluZWAgfCBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo am9iIHF1ZXVlLiB8CnwgKipyYWJiaXRtcSoqIHwgYHJhYmJpdG1xOjMtbWFuYWdlbWVudGAgfCBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgbWVzc2FnZSBicm9rZXIuIHwKfCAqKm51cS1wb3N0Z3JlcyoqIHwgYGdoY3IuaW8v
  >> "!B64TMP!" echo ZmlyZWNyYXdsL251cS1wb3N0Z3JlczpsYXRlc3RgIHwgRmlyZWNyYXdsIGpvYi1zdGF0ZSBEQiAo
  >> "!B64TMP!" echo cGdfY3JvbiBlbmFibGVkKS4gfAoKT24gdG9wIG9mIHRoZSBjb250YWluZXJzLCB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bGVyIGJ1bmRsZXMgKipsb2NhbC13ZWIqKiDigJQgYSBza2lsbCBmb3IKYWdlbnRzIHRoYXQgbG9h
  >> "!B64TMP!" echo ZCBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gIChgQzpcVXNlcnNcWW91XC5hZ2VudHNc
  >> "!B64TMP!" echo c2tpbGxzXGAKb24gV2luZG93cykuIEl0IGdpdmVzIHRoZSBhZ2VudCBhIGNvbXBsZXRlIHdlYi1y
  >> "!B64TMP!" echo ZXNlYXJjaCB3b3JrZmxvdzogc2VhcmNoIHZpYQpTZWFyWE5HLCByZWFkIHBhZ2VzIHZpYSBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wsIGFuZCBldmVuIHN0YXJ0IHRoZSBEb2NrZXIgc3RhY2sKYXV0b21hdGljYWxseSB3aGVu
  >> "!B64TMP!" echo IGl0J3MgZG93bi4gU2VlIFtzZWN0aW9uIEFdKCNhLXRoZS1idW5kbGVkLWxvY2FsLXdlYi1za2ls
  >> "!B64TMP!" echo bC1yZWNvbW1lbmRlZCkuCgpPbmx5ICoqdHdvIGhvc3QgcG9ydHMqKiBhcmUgcHVibGlzaGVkIChg
  >> "!B64TMP!" echo OTk5MGAgYW5kIGA5OTkxYCBieSBkZWZhdWx0KS4gRXZlcnl0aGluZwplbHNlIHN0YXlzIG9uIHRo
  >> "!B64TMP!" echo ZSBwcml2YXRlIGBsb2NhbC1zZWFyY2gtbmV0YCBicmlkZ2UgbmV0d29yay4gRmlyZWNyYXdsJ3MK
  >> "!B64TMP!" echo YC92MS9zZWFyY2hgIGVuZHBvaW50IGlzIGF1dG9tYXRpY2FsbHkgd2lyZWQgdG8gU2VhclhORyBp
  >> "!B64TMP!" echo bnRlcm5hbGx5LCBzbyBhIHNpbmdsZQpGaXJlY3Jhd2wgY2FsbCBjYW4gYm90aCBzZWFyY2ggKmFu
  >> "!B64TMP!" echo ZCogZmV0Y2ggZnVsbCBwYWdlIGNvbnRlbnQuCgotLS0KCiMjIFJlcXVpcmVtZW50cwoKLSAqKkRv
  >> "!B64TMP!" echo Y2tlcioqIHdpdGggdGhlICoqQ29tcG9zZSB2MiBwbHVnaW4qKiAoYGRvY2tlciBjb21wb3NlYCku
  >> "!B64TMP!" echo CiAgLSBXaW5kb3dzIC8gbWFjT1M6IFtEb2NrZXIgRGVza3RvcF0oaHR0cHM6Ly93d3cuZG9ja2Vy
  >> "!B64TMP!" echo LmNvbS9wcm9kdWN0cy9kb2NrZXItZGVza3RvcC8pCiAgLSBMaW51eDogW0RvY2tlciBFbmdpbmVd
  >> "!B64TMP!" echo KGh0dHBzOi8vZG9jcy5kb2NrZXIuY29tL2VuZ2luZS9pbnN0YWxsLykgKyB0aGUgYGRvY2tlci1j
  >> "!B64TMP!" echo b21wb3NlLXBsdWdpbmAgcGFja2FnZS4gQWRkIHlvdXIgdXNlciB0byB0aGUgYGRvY2tlcmAgZ3Jv
  >> "!B64TMP!" echo dXAgc28geW91IGRvbid0IG5lZWQgYHN1ZG9gLgotICoqfjUgR0IgZnJlZSBkaXNrKiogZm9yIGlt
  >> "!B64TMP!" echo YWdlcyBhbmQgZGF0YS4KLSAqKjggR0IgUkFNIC8gNCBDUFUgY29yZXMqKiByZWNvbW1lbmRlZCAo
  >> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCArIFBsYXl3cmlnaHQgc3RhY2sgaXMgdGhlIGhlYXZ5IHBhcnQ7IHJlZHVj
  >> "!B64TMP!" echo ZSByZXNvdXJjZSBsaW1pdHMgaW4gYGRvY2tlci1jb21wb3NlLnltbGAgZm9yIHNtYWxsZXIgaG9z
  >> "!B64TMP!" echo dHMpLgotICoqUHl0aG9uIDMuOCsqKiBmb3IgdGhlIGJ1bmRsZWQgbG9jYWwtd2ViIHNraWxsIHNj
  >> "!B64TMP!" echo cmlwdHMgKG9wdGlvbmFsIGJ1dCByZWNvbW1lbmRlZCDigJQgaXQncyB0aGUgZWFzaWVzdCB3YXkg
  >> "!B64TMP!" echo dG8gdXNlIHRoZSBzdGFjaykuCi0gKihPcHRpb25hbCwgZm9yIEZpcmVjcmF3bCBBSSBmZWF0dXJl
  >> "!B64TMP!" echo cykqICoqTE0gU3R1ZGlvKiogb3IgYW55IE9wZW5BSS1jb21wYXRpYmxlIGxvY2FsIHNlcnZlciDi
  >> "!B64TMP!" echo gJQgc2VlIFtzZWN0aW9uIERdKCNkLWNvbm5lY3QtYS1sb2NhbC1sbG0tbG0tc3R1ZGlvLWV0Yyku
  >> "!B64TMP!" echo Ci0gKihPcHRpb25hbCwgZm9yIE1DUCkqICoqTm9kZS5qcyAxOCsqKiBzbyBgbnB4IGZpcmVjcmF3
  >> "!B64TMP!" echo bC1tY3BgIHdvcmtzLgoKVmVyaWZ5IERvY2tlciBpcyByZWFkeToKCmBgYGJhc2gKZG9ja2VyIGlu
  >> "!B64TMP!" echo Zm8gICAgICAgICAgICAjIGVuZ2luZSBpcyBydW5uaW5nCmRvY2tlciBjb21wb3NlIHZlcnNpb24g
  >> "!B64TMP!" echo IyB2MiBpcyBpbnN0YWxsZWQKYGBgCgotLS0KCiMjIFF1aWNrIHN0YXJ0IChvbmUtY2xpY2sgaW5z
  >> "!B64TMP!" echo dGFsbCkKCj4gKipUaGUgaW5zdGFsbGVyIGlzIHNlbGYtY29udGFpbmVkLioqIEV2ZXJ5IGZpbGUg
  >> "!B64TMP!" echo aXQgbmVlZHMgKGBkb2NrZXItY29tcG9zZS55bWxgLAo+IGBjb25maWcvc2VhcnhuZy9zZXR0aW5n
  >> "!B64TMP!" echo cy55bWxgLCBgLmVudi5leGFtcGxlYCwgdGhlIGJ1bmRsZWQgYGxvY2FsLXdlYmAgc2tpbGwsCj4g
  >> "!B64TMP!" echo YWxsIHRoZSBydW4vc3RvcC91cGRhdGUvdW5pbnN0YWxsIHNjcmlwdHMsIHRoaXMgUkVBRE1FLCBh
  >> "!B64TMP!" echo bmQgZXZlbiB0aGUgKm90aGVyKgo+IHBsYXRmb3JtJ3MgaW5zdGFsbGVyKSBpcyBlbWJlZGRlZCBp
  >> "!B64TMP!" echo bnNpZGUgaXQuIFlvdSBjYW4gZG93bmxvYWQgKipqdXN0Cj4gYGluc3RhbGwtbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo LmJhdGAqKiAoV2luZG93cykgb3IgKipqdXN0IGBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaGAqKgo+
  >> "!B64TMP!" echo IChMaW51eC9tYWNPUykgb24gaXRzIG93biBhbmQgdGhlIGluc3RhbGxlciB3aWxsIHN0aWxsIHBy
  >> "!B64TMP!" echo b2R1Y2UgYSBjb21wbGV0ZSwKPiB3b3JraW5nIGZvbGRlci4gRG93bmxvYWRpbmcgdGhlIHdob2xl
  >> "!B64TMP!" echo IGBsb2NhbC1zZWFyY2hgIGZvbGRlciBvciB0aGUgemlwIGp1c3QKPiBtYWtlcyB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bCBhIGxpdHRsZSBmYXN0ZXIgKGl0IGNvcGllcyBmaWxlcyBpbnN0ZWFkIG9mIGRlY29kaW5nIHRo
  >> "!B64TMP!" echo ZW0pLgoKUnVuICoqb25lKiogaW5zdGFsbGVyIGZvciB5b3VyIHBsYXRmb3JtLiBJdCB3aWxsIGFz
  >> "!B64TMP!" echo ayB5b3UgYSBmZXcgdGhpbmdzIOKAlCBpbnN0YWxsCmZvbGRlciwgU2VhclhORyBwb3J0LCBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wgcG9ydCwgKG9wdGlvbmFsbHkpIGEgbG9jYWwgTExNIOKAlCB3aXRoIHNlbnNpYmxlCmRl
  >> "!B64TMP!" echo ZmF1bHRzIHlvdSBjYW4gYWNjZXB0IGJ5IHByZXNzaW5nICoqRW50ZXIqKi4gSXQgdGhlbiBnZW5l
  >> "!B64TMP!" echo cmF0ZXMKY3J5cHRvZ3JhcGhpY2FsbHktc2VjdXJlIGNyZWRlbnRpYWxzLCB3cml0ZXMgeW91ciBg
  >> "!B64TMP!" echo LmVudmAsICoqaW5zdGFsbHMgdGhlCmxvY2FsLXdlYiBza2lsbCoqLCBwdWxscyB0aGUgaW1hZ2Vz
  >> "!B64TMP!" echo LCBhbmQgc3RhcnRzIHRoZSBzdGFjay4KCj4gKipEb2NrZXIgaXNuJ3QgcnVubmluZz8qKiBObyBw
  >> "!B64TMP!" echo cm9ibGVtIOKAlCB0aGUgaW5zdGFsbGVyIHN0YXJ0cyBpdCBmb3IgeW91OiBpdAo+IGxhdW5jaGVz
  >> "!B64TMP!" echo IERvY2tlciBEZXNrdG9wIChXaW5kb3dzL21hY09TKSBvciB0aGUgRG9ja2VyIHNlcnZpY2UKPiAo
  >> "!B64TMP!" echo YHN5c3RlbWN0bGAvYHNlcnZpY2VgLCBMaW51eCkgYW5kIHdhaXRzIHVwIHRvIDUgbWludXRlcyBm
  >> "!B64TMP!" echo b3IgdGhlIGVuZ2luZSB3aGlsZQo+IHlvdSBhbnN3ZXIgdGhlIHByb21wdHMuIChPdmVycmlkZSB0
  >> "!B64TMP!" echo aGUgd2FpdCB3aXRoIHRoZQo+IGBMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVRgIGVudiB2YXIs
  >> "!B64TMP!" echo IGluIHNlY29uZHMuKQoKIyMjIFdpbmRvd3MKCjEuIEluc3RhbGwgW0RvY2tlciBEZXNrdG9wXSho
  >> "!B64TMP!" echo dHRwczovL3d3dy5kb2NrZXIuY29tL3Byb2R1Y3RzL2RvY2tlci1kZXNrdG9wLykg4oCUIG5vIG5l
  >> "!B64TMP!" echo ZWQgdG8gb3BlbiBpdCBmaXJzdDsgdGhlIGluc3RhbGxlciBsYXVuY2hlcyBpdCBhdXRvbWF0aWNh
  >> "!B64TMP!" echo bGx5LgoyLiBEb3VibGUtY2xpY2sgKipgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0YCoqIChvciBy
  >> "!B64TMP!" echo dW4gaXQgZnJvbSBhIHRlcm1pbmFsKS4KCmBgYAotLS0gU3RlcCAxIG9mIDQ6IEluc3RhbGwgbG9j
  >> "!B64TMP!" echo YXRpb24gLS0tLS0tLS0tLQogIFRhcmdldCBmb2xkZXIgW3ByZXNzIEVudGVyIGZvciBkZWZhdWx0
  >> "!B64TMP!" echo XTogICAgICAgICAgICAjIEM6XFVzZXJzXFlvdVxsb2NhbC1zZWFyY2gKLS0tIFN0ZXAgMiBvZiA0
  >> "!B64TMP!" echo OiBTZWFyWE5HIHBvcnQgKGRlZmF1bHQgOTk5MCkgLS0tLS0tCiAgUG9ydCBmb3IgU2VhclhORyBb
  >> "!B64TMP!" echo cHJlc3MgRW50ZXIgZm9yIDk5OTBdOiA5OTkwCi0tLSBTdGVwIDMgb2YgNDogRmlyZWNyYXdsIHBv
  >> "!B64TMP!" echo cnQgKGRlZmF1bHQgOTk5MSkgLS0tLQogIFBvcnQgZm9yIEZpcmVjcmF3bCBbcHJlc3MgRW50ZXIg
  >> "!B64TMP!" echo Zm9yIDk5OTFdOiA5OTkxCi0tLSBTdGVwIDQgb2YgNDogTG9jYWwgTExNIChvcHRpb25hbCkgLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLQogIENvbm5lY3QgYSBsb2NhbCBMTE0gbm93PyBbeS9OXTogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICMgb3B0aW9uYWwsIHNlZSBzZWN0aW9uIEQKYGBgCgojIyMgTGludXggJiBtYWNP
  >> "!B64TMP!" echo UwoKYGBgYmFzaApjaG1vZCAreCBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaAouL2luc3RhbGwtbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoLnNoCmBgYAoKVGhlIHByb21wdHMgYXJlIHRoZSBzYW1lLiBEZWZhdWx0czogaW5z
  >> "!B64TMP!" echo dGFsbCB0byBgfi9sb2NhbC1zZWFyY2hgLCBTZWFyWE5HIG9uCmA5OTkwYCwgRmlyZWNyYXdsIG9u
  >> "!B64TMP!" echo IGA5OTkxYC4gQSBzdG9wcGVkIERvY2tlciBlbmdpbmUgaXMgc3RhcnRlZCBhdXRvbWF0aWNhbGx5
  >> "!B64TMP!" echo CihEb2NrZXIgRGVza3RvcCBvbiBtYWNPUywgYHN5c3RlbWN0bGAvYHNlcnZpY2VgIG9uIExpbnV4
  >> "!B64TMP!" echo KS4KCj4gKipGaXJzdCBydW4gZG93bmxvYWRzIH4z4oCTNCBHQiBvZiBEb2NrZXIgaW1hZ2VzKiog
  >> "!B64TMP!" echo KHRoZSBQbGF5d3JpZ2h0IGltYWdlIGJ1bmRsZXMKPiBhIGZ1bGwgQ2hyb21pdW0pLiBTdWJzZXF1
  >> "!B64TMP!" echo ZW50IHN0YXJ0cyBhcmUgYSBmZXcgc2Vjb25kcy4KCldoZW4gaXQgZmluaXNoZXMgeW91J2xsIHNl
  >> "!B64TMP!" echo ZToKCmBgYApTZWFyWE5HICAoc2VhcmNoICsgSlNPTiBBUEkpOiAgaHR0cDovL2xvY2FsaG9zdDo5
  >> "!B64TMP!" echo OTkwCkZpcmVjcmF3bCAoc2NyYXBlL2NyYXdsIEFQSSk6IGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MQpB
  >> "!B64TMP!" echo Z2VudCBza2lsbDogQzpcVXNlcnNcWW91XC5hZ2VudHNcc2tpbGxzXGxvY2FsLXdlYiAgIChvciB+
  >> "!B64TMP!" echo Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYikKYGBgCgpPcGVuIGBodHRwOi8vbG9jYWxob3N0Ojk5
  >> "!B64TMP!" echo OTBgIGluIGEgYnJvd3NlciB0byBzZWUgdGhlIFNlYXJYTkcgc2VhcmNoIFVJIOKAlCBvciwKaWYg
  >> "!B64TMP!" echo eW91ciBhZ2VudCBsb2FkcyBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gLCBqdXN0IGFz
  >> "!B64TMP!" echo ayBpdCB0byByZXNlYXJjaApzb21ldGhpbmcgY3VycmVudCBhbmQgaXQgd2lsbCB1c2UgKipsb2Nh
  >> "!B64TMP!" echo bC13ZWIqKiBhdXRvbWF0aWNhbGx5IChzZWUKW3NlY3Rpb24gQV0oI2EtdGhlLWJ1bmRsZWQtbG9j
  >> "!B64TMP!" echo YWwtd2ViLXNraWxsLXJlY29tbWVuZGVkKSkuCgotLS0KCiMjIE1hbmFnaW5nIHRoZSBzdGFjawoK
  >> "!B64TMP!" echo QWZ0ZXIgaW5zdGFsbCwgdGhlIG1hbmFnZW1lbnQgc2NyaXB0cyBsaXZlICoqaW4geW91ciBpbnN0
  >> "!B64TMP!" echo YWxsIGZvbGRlcioqCihgQzpcVXNlcnNcWW91XGxvY2FsLXNlYXJjaGAgb24gV2luZG93cywgYH4v
  >> "!B64TMP!" echo bG9jYWwtc2VhcmNoYCBvbiBMaW51eC9tYWNPUykuClRoZXkgYXV0by1kZXRlY3QgdGhlaXIgb3du
  >> "!B64TMP!" echo IGxvY2F0aW9uLCBzbyB5b3UgY2FuIHJ1biB0aGVtIGZyb20gYW55d2hlcmUgYnkKZG91YmxlLWNs
  >> "!B64TMP!" echo aWNraW5nIG9yIGAuL2AtaW5nIHRoZW0uCgp8IEFjdGlvbiB8IFdpbmRvd3MgfCBMaW51eCAvIG1h
  >> "!B64TMP!" echo Y09TIHwKfC0tLS0tLS0tfC0tLS0tLS0tLXwtLS0tLS0tLS0tLS0tLS18CnwgKipTdGFydCoqIHRo
  >> "!B64TMP!" echo ZSBzdGFjayB8IGBSdW4uYmF0YCB8IGAuL3J1bi5zaGAgfAp8ICoqU3RvcCoqIChrZWVwIGRhdGEp
  >> "!B64TMP!" echo IHwgYFN0b3AuYmF0YCB8IGAuL3N0b3Auc2hgIHwKfCAqKlVwZGF0ZSoqIGltYWdlcyArIGFwcGx5
  >> "!B64TMP!" echo IGAuZW52YCBjaGFuZ2VzICsgKipyZS1zeW5jIHRoZSBza2lsbCoqIHwgYFVwZGF0ZS5iYXRgIHwg
  >> "!B64TMP!" echo YC4vdXBkYXRlLnNoYCB8CnwgKipVbmluc3RhbGwqKiAoY29udGFpbmVycyArIHZvbHVtZXMgKyBz
  >> "!B64TMP!" echo a2lsbCwgb3B0aW9uYWwgZm9sZGVyIGRlbGV0ZSkgfCBgVW5pbnN0YWxsLmJhdGAgfCBgLi91bmlu
  >> "!B64TMP!" echo c3RhbGwuc2hgIHwKCi0gKipTdG9wKiogb25seSByZW1vdmVzIGNvbnRhaW5lcnM7IHlvdXIgZGF0
  >> "!B64TMP!" echo YSB2b2x1bWVzIChGaXJlY3Jhd2wgam9iIHN0YXRlLAogIHJlZGlzIGNhY2hlLCByYWJiaXRtcS9w
  >> "!B64TMP!" echo b3N0Z3JlcyBkYXRhKSBhcmUgcHJlc2VydmVkLgotICoqVXBkYXRlKiogcnVucyBgZG9ja2VyIGNv
  >> "!B64TMP!" echo bXBvc2UgcHVsbGAgdGhlbiBgZG9ja2VyIGNvbXBvc2UgdXAgLWRgLCBzbyBpdAogIGJvdGggdXBn
  >> "!B64TMP!" echo cmFkZXMgaW1hZ2VzICoqYW5kKiogYXBwbGllcyBhbnkgcG9ydC9MTE0gZWRpdHMgeW91IG1hZGUg
  >> "!B64TMP!" echo dG8gYC5lbnZgOwogIGl0IGFsc28gcmUtY29waWVzIHRoZSBidW5kbGVkIGBsb2NhbC13ZWJgIHNr
  >> "!B64TMP!" echo aWxsIGludG8gYH4vLmFnZW50cy9za2lsbHMvYC4KLSAqKlVuaW5zdGFsbCoqIHJ1bnMgYGRvY2tl
  >> "!B64TMP!" echo ciBjb21wb3NlIGRvd24gLXZgIChkZWxldGVzIHZvbHVtZXMgKyBkYXRhKSwKICByZW1vdmVzIHRo
  >> "!B64TMP!" echo ZSBgbG9jYWwtd2ViYCBza2lsbCBmcm9tIGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYmAsIHRo
  >> "!B64TMP!" echo ZW4KICBvcHRpb25hbGx5IGRlbGV0ZXMgdGhlIGluc3RhbGwgZm9sZGVyLiBQdWxsZWQgaW1hZ2Vz
  >> "!B64TMP!" echo IGFyZSBrZXB0OyByZWNsYWltIHRoZW0KICB3aXRoIGBkb2NrZXIgaW1hZ2UgcHJ1bmUgLWFgIGlm
  >> "!B64TMP!" echo IGRlc2lyZWQuCgotLS0KCiMjIEhvdyBpdCBmaXRzIHRvZ2V0aGVyCgpgYGAKICAgICAgICB5b3Vy
  >> "!B64TMP!" echo IEFJIG1vZGVsIC8gYWdlbnQgKGxvY2FsLXdlYiBza2lsbCkgLyBNQ1AgY2xpZW50IC8gY2hhdCBV
  >> "!B64TMP!" echo SQogICAgICAgICAgICAgICAgICAgICAg4pSCCiAgIOKUjOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUvOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUkAogICDilrwgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilrwKaHR0cDovL2xvY2FsaG9zdDo5OTkw
  >> "!B64TMP!" echo ICAgICAgICAgICAgaHR0cDovL2xvY2FsaG9zdDo5OTkxCiAgIOKUgiBTZWFyWE5HICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgIOKUgiBGaXJlY3Jhd2wgQVBJCiAgIOKUgiAgLSAvc2VhcmNoP3E9
  >> "!B64TMP!" echo Li4uJmZvcm1hdD1qc29uICAgICAgIOKUgiAgLSAvdjEvc2NyYXBlICAgKG9uZSBVUkwgLT4gbWFy
  >> "!B64TMP!" echo a2Rvd24pCiAgIOKUgiAgLSBhZ2dyZWdhdGVzIH43MCBlbmdpbmVzICAgICAgICAgICDilIIgIC0g
  >> "!B64TMP!" echo L3YxL2NyYXdsICAgICh3aG9sZSBzaXRlLCBhc3luYykKICAg4pSCICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgIOKUgiAgLSAvdjEvbWFwICAgICAgKHNpdGUgVVJMIHRyZWUpCiAg
  >> "!B64TMP!" echo IOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIgIC0gL3YxL3NlYXJj
  >> "!B64TMP!" echo aCAgICgtPiB1c2VzIFNlYXJYTkchKQogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAg4pSCICAtIC92MS9leHRyYWN0ICAoLT4gdXNlcyB5b3VyIExMTSkKICAg4pSC4peE
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIHdpcmVkIHRvZ2V0aGVyIOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUgOKUgOKUpCAgU0VBUlhOR19FTkRQT0lOVD1odHRwOi8vc2VhcnhuZzo4
  >> "!B64TMP!" echo MDgwCiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIKICAg4pSU
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pSA4pSAIHByaXZhdGUgZG9ja2VyIG5ldHdvcmsg4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSA4pSYCiAgICAgICAgICAgICAgICAgbG9jYWwtc2VhcmNoLW5ldAogICBhbHNvIG9uIGl0
  >> "!B64TMP!" echo OiBwbGF5d3JpZ2h0LXNlcnZpY2UgKENocm9taXVtKSwgcmVkaXMsIHJhYmJpdG1xLCBudXEtcG9z
  >> "!B64TMP!" echo dGdyZXMKYGBgCgpUaHJlZSBrZXkgd2lyaW5nIGRlY2lzaW9ucyB0aGUgaW5zdGFsbGVyIG1ha2Vz
  >> "!B64TMP!" echo IGZvciB5b3U6CgoxLiAqKlNlYXJYTkcgSlNPTiArIG5vIGxpbWl0ZXIqKiDigJQgYGNvbmZpZy9z
  >> "!B64TMP!" echo ZWFyeG5nL3NldHRpbmdzLnltbGAgc2V0cwogICBgc2VhcmNoLmZvcm1hdHM6IFtodG1sLCBqc29u
  >> "!B64TMP!" echo XWAgYW5kIGBzZXJ2ZXIubGltaXRlcjogZmFsc2VgLCBzbyBtb2RlbHMgY2FuIGhpdAogICBgL3Nl
  >> "!B64TMP!" echo YXJjaD9mb3JtYXQ9anNvbmAgd2l0aG91dCBiZWluZyBibG9ja2VkIGFzIGEgYm90LgoyLiAqKkZp
  >> "!B64TMP!" echo cmVjcmF3bCDihpIgU2VhclhORyoqIOKAlCB0aGUgRmlyZWNyYXdsIGNvbnRhaW5lciBzZXRzCiAg
  >> "!B64TMP!" echo IGBTRUFSWE5HX0VORFBPSU5UPWh0dHA6Ly9zZWFyeG5nOjgwODBgLCBzbyBGaXJlY3Jhd2wncyBg
  >> "!B64TMP!" echo L3YxL3NlYXJjaGAgdXNlcyB5b3VyCiAgIGxvY2FsIFNlYXJYTkcgaW5zdGVhZCBvZiBuZWVkaW5n
  >> "!B64TMP!" echo IGEgdGhpcmQtcGFydHkgc2VhcmNoIHByb3ZpZGVyLgozLiAqKmxvY2FsLXdlYiBza2lsbCBhdXRv
  >> "!B64TMP!" echo LWluc3RhbGwqKiDigJQgdGhlIGluc3RhbGxlciBjb3BpZXMgdGhlIGJ1bmRsZWQgc2tpbGwgdG8K
  >> "!B64TMP!" echo ICAgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViL2AgKGFkZC9vdmVycmlkZSkgYW5kIHJlY29y
  >> "!B64TMP!" echo ZHMgdGhlIGluc3RhbGwgcGF0aCBpbgogICBhbiBgaW5zdGFsbC1kaXIudHh0YCBoaW50IGluc2lk
  >> "!B64TMP!" echo ZSB0aGUgc2tpbGwsIHNvIHRoZSBza2lsbCBmaW5kcyB0aGUgc3RhY2sgZXZlbgogICBpZiB5b3Ug
  >> "!B64TMP!" echo aW5zdGFsbGVkIHRvIGEgY3VzdG9tIGZvbGRlciBhbmQgRG9ja2VyIGlzbid0IHJ1bm5pbmcgeWV0
  >> "!B64TMP!" echo LgoKLS0tCgojIyBVc2luZyBpdCB3aXRoIEFJIG1vZGVscwoKVGhlcmUgYXJlICoqc2V2ZW4qKiB3
  >> "!B64TMP!" echo YXlzIHRvIHVzZSB0aGlzIHN5c3RlbSwgZnJvbSBsb3dlc3QgdG8gaGlnaGVzdAppbnRlZ3JhdGlv
  >> "!B64TMP!" echo bi4gUGljayB3aGF0IGZpdHMgeW91ciBzdGFjayDigJQgeW91IGNhbiBtaXggYW5kIG1hdGNoLgoK
  >> "!B64TMP!" echo IyMjIEEuIFRoZSBidW5kbGVkIGxvY2FsLXdlYiBza2lsbCAocmVjb21tZW5kZWQpCgpUaGUgaW5z
  >> "!B64TMP!" echo dGFsbGVyIHNoaXBzIHdpdGggKipsb2NhbC13ZWIqKiwgYW4gYWdlbnQgc2tpbGwgdGhhdCB0dXJu
  >> "!B64TMP!" echo cyBhbnkKc2tpbGwtbG9hZGluZyBhZ2VudCBpbnRvIGEgd2ViIHJlc2VhcmNoZXIgd2l0aCB6ZXJv
  >> "!B64TMP!" echo IGNvbmZpZ3VyYXRpb24uIElmIHlvdXIKYWdlbnQgcmVhZHMgc2tpbGxzIGZyb20gYH4vLmFnZW50
  >> "!B64TMP!" echo cy9za2lsbHMvYAooYEM6XFVzZXJzXFlvdVwuYWdlbnRzXHNraWxsc1xgIG9uIFdpbmRvd3MpLCBp
  >> "!B64TMP!" echo dCdzIGFscmVhZHkgYXZhaWxhYmxlIGFmdGVyCmluc3RhbGwg4oCUIHJlc3RhcnQgdGhlIGFnZW50
  >> "!B64TMP!" echo IGlmIGl0IHdhcyBydW5uaW5nLgoKVGhlIGluc3RhbGxlcjoKLSBwdXRzIGEgY29weSBpbiBgPGlu
  >> "!B64TMP!" echo c3RhbGwgZm9sZGVyPi9sb2NhbC13ZWIvYCwgYW5kCi0gKiphdXRvbWF0aWNhbGx5IGluc3RhbGxz
  >> "!B64TMP!" echo IChhZGQvb3ZlcnJpZGUpKiogaXQgaW50bwogIGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi9g
  >> "!B64TMP!" echo LgoKV2hhdCB0aGUgc2tpbGwgZG9lcyBmb3IgdGhlIGFnZW50OgoKLSAqKkZpbmRzIHRoZSBzdGFj
  >> "!B64TMP!" echo ayBhdXRvbWF0aWNhbGx5LioqIEl0IHJlYWRzIHRoZSByZWFsIHBvcnRzIGZyb20geW91ciBgLmVu
  >> "!B64TMP!" echo dmAKICAoc28gY3VzdG9tIGluc3RhbGwtdGltZSBwb3J0cyBqdXN0IHdvcmspIGFuZCBsb2NhdGVz
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsIGZvbGRlciB2aWEKICB0aGUgY29tcG9zZSBsYWJlbHMgb24gdGhlIHJ1bm5p
  >> "!B64TMP!" echo bmcgY29udGFpbmVycywgdGhlIGluc3RhbGxlci1yZWNvcmRlZAogIGBpbnN0YWxsLWRpci50eHRg
  >> "!B64TMP!" echo IGhpbnQsIG9yIGB+L2xvY2FsLXNlYXJjaGAg4oCUIG5vIGhhcmRjb2RlZCBhbnl0aGluZy4KLSAq
  >> "!B64TMP!" echo KlNlbGYtaGVhbHMgYSBkb3duIHN0YWNrIOKAlCBubyB3YXJtLXVwIHN0ZXAuKiogSWYgdGhlIERv
  >> "!B64TMP!" echo Y2tlciBlbmdpbmUgb3IgdGhlCiAgY29udGFpbmVycyBhcmUgZG93biB3aGVuIGEgc2VhcmNoL3Nj
  >> "!B64TMP!" echo cmFwZSBydW5zLCB0aGUgc2NyaXB0IGJvb3RzIHRoZSBlbmdpbmUKICAoRG9ja2VyIERlc2t0b3Ag
  >> "!B64TMP!" echo LyBgc3lzdGVtY3RsIHN0YXJ0IGRvY2tlcmApLCBydW5zIHRoZSBzYW1lIGBkb2NrZXIgY29tcG9z
  >> "!B64TMP!" echo ZQogIHVwIC1kYCB0aGF0IGBSdW4uYmF0YCAvIGBydW4uc2hgIHVzZSwgd2FpdHMgZm9yIHRoZSBl
  >> "!B64TMP!" echo bmRwb2ludHMsIGFuZCByZXRyaWVzCiAgdGhlIHJlcXVlc3Qg4oCUIHNvIHRoZSBhZ2VudCBjYWxs
  >> "!B64TMP!" echo cyB0aGUgc2VhcmNoL3NjcmFwZSBzY3JpcHRzIGRpcmVjdGx5LCBldmVuCiAgaW4gYW4gb2xkIGNv
  >> "!B64TMP!" echo bnZlcnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzIHNpbmNlIGdvbmUgZG93bgogIChgZW5zdXJl
  >> "!B64TMP!" echo X3N0YWNrLnB5YCByZW1haW5zIGF2YWlsYWJsZSBhcyBhbiBvcHRpb25hbCBwcmUtZmxpZ2h0IGNo
  >> "!B64TMP!" echo ZWNrKS4gVGhlCiAgc3RhY2sgaXMgKipuZXZlciBzdG9wcGVkKiogYnkgdGhlIHNjcmlwdHMgKHN0
  >> "!B64TMP!" echo b3BwaW5nIGlzIHlvdXIgam9iLCB2aWEKICBgU3RvcC5iYXRgIC8gYHN0b3Auc2hgKS4KLSAqKlNl
  >> "!B64TMP!" echo YXJjaGVzIHRoZSB3ZWIuKiogYHdlYl9zZWFyY2gucHkgInF1ZXJ5ImAgcHJpbnRzIHRoZSB0b3Ag
  >> "!B64TMP!" echo cmVzdWx0cyBhcwogIGB0aXRsZSAvIHVybCAvIHNuaXBwZXRgLCB3aXRoIGAtLWxpbWl0YCwgYC0t
  >> "!B64TMP!" echo dGltZS1yYW5nZSBkYXl8d2Vla3xtb250aGAsIGFuZAogIGAtLWNhdGVnb3JpZXMgaXQsbmV3cyxn
  >> "!B64TMP!" echo ZW5lcmFsYCBvcHRpb25zLgotICoqUmVhZHMgcGFnZXMuKiogYHdlYl9zY3JhcGUucHkgPHVybD5g
  >> "!B64TMP!" echo IHJldHVybnMgdGhlIHBhZ2UgYXMgY2xlYW4gTWFya2Rvd24KICAodHJ1bmNhdGVkIGF0IDIwLDAw
  >> "!B64TMP!" echo MCBjaGFyczsgcmFpc2Ugd2l0aCBgLS1tYXgtY2hhcnNgKS4KCk1hbnVhbCB1c2FnZSAoZXhhY3Rs
  >> "!B64TMP!" echo eSB3aGF0IHRoZSBhZ2VudCBydW5zIOKAlCBubyBzZXBhcmF0ZSBzdGFydCBzdGVwIG5lZWRlZCk6
  >> "!B64TMP!" echo CgpgYGBiYXNoCnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi9zY3JpcHRzL3dlYl9z
  >> "!B64TMP!" echo ZWFyY2gucHkgImxhdGVzdCBweXRob24gcmVsZWFzZSIKcHl0aG9uIH4vLmFnZW50cy9za2lsbHMv
  >> "!B64TMP!" echo bG9jYWwtd2ViL3NjcmlwdHMvd2ViX3NjcmFwZS5weSAiaHR0cHM6Ly9leGFtcGxlLmNvbSIKIyBv
  >> "!B64TMP!" echo cHRpb25hbCBwcmUtZmxpZ2h0IGNoZWNrIC8gc3RhdHVzIHJlcG9ydDoKcHl0aG9uIH4vLmFnZW50
  >> "!B64TMP!" echo cy9za2lsbHMvbG9jYWwtd2ViL3NjcmlwdHMvZW5zdXJlX3N0YWNrLnB5IC0tY2hlY2sKYGBgCgpU
  >> "!B64TMP!" echo aGUgZnVsbCBhZ2VudC1mYWNpbmcgaW5zdHJ1Y3Rpb25zIGxpdmUgaW4gdGhlIHNraWxsJ3MgYFNL
  >> "!B64TMP!" echo SUxMLm1kYC4gS2VlcGluZyB0aGUKc2tpbGwgZnJlc2ggaXMgYXV0b21hdGljOiBgVXBkYXRlLmJh
  >> "!B64TMP!" echo dGAgLyBgLi91cGRhdGUuc2hgIHJlLXN5bmNzIGl0LCBhbmQKcmUtcnVubmluZyB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bGVyIG92ZXJ3cml0ZXMgaXQuIFVuaW5zdGFsbGluZyByZW1vdmVzIGl0LgoKPiBUaGUgc2tpbGwg
  >> "!B64TMP!" echo b25seSBuZWVkcyAqKlB5dGhvbiAzLjgrKiogb24gdGhlIGhvc3Qg4oCUIG5vIHBpcCBwYWNrYWdl
  >> "!B64TMP!" echo cywgbm8gQVBJCj4ga2V5cywgbm8gTUNQIHN1cHBvcnQgcmVxdWlyZWQgZnJvbSB0aGUgYWdlbnQu
  >> "!B64TMP!" echo CgotLS0KCiMjIyBCLiBEaXJlY3QgU2VhclhORyBKU09OIEFQSQoKVGhlIHNpbXBsZXN0IHBvc3Np
  >> "!B64TMP!" echo YmxlIGludGVncmF0aW9uOiBoaXQgU2VhclhORydzIEpTT04gZW5kcG9pbnQgYW5kIGZlZWQgdGhl
  >> "!B64TMP!" echo CnJlc3VsdHMgaW50byBhbnkgbW9kZWwncyBjb250ZXh0LiBObyBTREssIG5vIGtleSwgbm8gTUNQ
  >> "!B64TMP!" echo LgoKYGBgYmFzaAojIFNlYXJjaCB0aGUgd2ViLCByZXR1cm4gSlNPTiwgc2hvdyB0aGUgdG9wIDUg
  >> "!B64TMP!" echo cmVzdWx0cwpjdXJsIC1zICJodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoP3E9bGF0ZXN0K0FJ
  >> "!B64TMP!" echo K25ld3MmZm9ybWF0PWpzb24iIFwKICB8IGpxICcucmVzdWx0c1s6NV0gfCAuW10gfCB7dGl0bGUs
  >> "!B64TMP!" echo IHVybCwgY29udGVudH0nCmBgYAoKVXNlZnVsIHF1ZXJ5IHBhcmFtczogYCZwYWdlbm89MmAsIGAm
  >> "!B64TMP!" echo Y2F0ZWdvcmllcz1pdCxpbWFnZXNgLCBgJnRpbWVfcmFuZ2U9ZGF5YCwKYCZsYW5ndWFnZT1lbmAs
  >> "!B64TMP!" echo IGAmZW5naW5lcz1nb29nbGUsYmluZyxkdWNrZHVja2dvYC4KCkluIFB5dGhvbjoKCmBgYHB5dGhv
  >> "!B64TMP!" echo bgppbXBvcnQgcmVxdWVzdHMKciA9IHJlcXVlc3RzLmdldCgiaHR0cDovL2xvY2FsaG9zdDo5OTkw
  >> "!B64TMP!" echo L3NlYXJjaCIsIHBhcmFtcz17CiAgICAicSI6ICJydXN0IGFzeW5jIHJ1bnRpbWUgdG9raW8iLAog
  >> "!B64TMP!" echo ICAgImZvcm1hdCI6ICJqc29uIiwKICAgICJsYW5ndWFnZSI6ICJlbiIsCn0pLmpzb24oKQpmb3Ig
  >> "!B64TMP!" echo aGl0IGluIHJbInJlc3VsdHMiXVs6NV06CiAgICBwcmludChoaXRbInRpdGxlIl0sICItPiIsIGhp
  >> "!B64TMP!" echo dFsidXJsIl0pCiAgICBwcmludChoaXQuZ2V0KCJjb250ZW50IiwgIiIpWzoyMDBdKQpgYGAKCj4g
  >> "!B64TMP!" echo U2VhclhORyByZXR1cm5zIHRpdGxlcywgVVJMcywgYW5kIHNob3J0IGNvbnRlbnQgc25pcHBldHMg
  >> "!B64TMP!" echo 4oCUIHBlcmZlY3QgZm9yIGEKPiAic2VhcmNoIHRoZW4gc3VtbWFyaXplIiBhZ2VudCBsb29wLiBG
  >> "!B64TMP!" echo b3IgKipmdWxsIHBhZ2UgdGV4dCoqLCB1c2UgRmlyZWNyYXdsIChDKS4KCi0tLQoKIyMjIEMuIERp
  >> "!B64TMP!" echo cmVjdCBGaXJlY3Jhd2wgUkVTVCBBUEkKCkZpcmVjcmF3bCB0dXJucyBhbnkgVVJMIGludG8gY2xl
  >> "!B64TMP!" echo YW4gTWFya2Rvd24vSFRNTC9KU09OIOKAlCBpZGVhbCBmb3IgUkFHLiBCZWNhdXNlCnRoZSBzZWxm
  >> "!B64TMP!" echo LWhvc3RlZCBpbnN0YW5jZSBydW5zIHdpdGggYFVTRV9EQl9BVVRIRU5USUNBVElPTj1mYWxzZWAs
  >> "!B64TMP!" echo ICoqbm8gQVBJIGtleQppcyByZXF1aXJlZCoqICh5b3UgY2FuIHNlbmQgYW55IGBBdXRob3JpemF0
  >> "!B64TMP!" echo aW9uOiBCZWFyZXIg4oCmYCBoZWFkZXIsIG9yIG5vbmUpLgoKIyMjIyBTY3JhcGUgYSBzaW5nbGUg
  >> "!B64TMP!" echo cGFnZSDihpIgTWFya2Rvd24KCmBgYGJhc2gKY3VybCAtcyAtWCBQT1NUIGh0dHA6Ly9sb2NhbGhv
  >> "!B64TMP!" echo c3Q6OTk5MS92MS9zY3JhcGUgXAogIC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24i
  >> "!B64TMP!" echo IFwKICAtZCAneyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwiZm9ybWF0cyI6WyJtYXJrZG93
  >> "!B64TMP!" echo biJdfScgXAogIHwganEgJy5kYXRhLm1hcmtkb3duJwpgYGAKCiMjIyMgU2VhcmNoIHRoZSB3ZWIg
  >> "!B64TMP!" echo KHVzZXMgeW91ciBTZWFyWE5HIGludGVybmFsbHkpICsgcmV0dXJuIGZ1bGwgY29udGVudAoKYGBg
  >> "!B64TMP!" echo YmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NlYXJjaCBcCiAg
  >> "!B64TMP!" echo LUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogIC1kICd7InF1ZXJ5Ijoid2hh
  >> "!B64TMP!" echo dCBpcyBydXN0IHByb2dyYW1taW5nIGxhbmd1YWdlIiwibGltaXQiOjV9JyBcCiAgfCBqcSAnLmRh
  >> "!B64TMP!" echo dGFbOjNdIHwgLltdIHwge3RpdGxlLCB1cmwsIG1hcmtkb3dufScKYGBgCgojIyMjIENyYXdsIGEg
  >> "!B64TMP!" echo d2hvbGUgc2l0ZSAoYXN5bmMpCgpgYGBiYXNoCiMgMSkgc3RhcnQgdGhlIGNyYXdsCkpPQj0kKGN1
  >> "!B64TMP!" echo cmwgLXMgLVggUE9TVCBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvY3Jhd2wgXAogIC1IICJDb250
  >> "!B64TMP!" echo ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2RvY3Mu
  >> "!B64TMP!" echo ZXhhbXBsZS5jb20iLCJsaW1pdCI6MjB9JyB8IGpxIC1yIC5pZCkKCiMgMikgcG9sbCB1bnRpbCBz
  >> "!B64TMP!" echo dGF0dXMgPT0gImNvbXBsZXRlZCIKY3VybCAtcyAiaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2Ny
  >> "!B64TMP!" echo YXdsLyRKT0IiIHwganEgJ3tzdGF0dXMsIGNvbXBsZXRlZCwgdG90YWx9JwpgYGAKCiMjIyMgTWFw
  >> "!B64TMP!" echo IGEgc2l0ZSdzIFVSTCB0cmVlIChmYXN0LCBubyBzY3JhcGluZykKCmBgYGJhc2gKY3VybCAtcyAt
  >> "!B64TMP!" echo WCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9tYXAgXAogIC1IICJDb250ZW50LVR5cGU6
  >> "!B64TMP!" echo IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwi
  >> "!B64TMP!" echo bGltaXQiOjUwfScgfCBqcSAnLmxpbmtzJwpgYGAKCiMjIyMgRXh0cmFjdCBzdHJ1Y3R1cmVkIGRh
  >> "!B64TMP!" echo dGEgd2l0aCBhbiBMTE0gKG5lZWRzIHNlY3Rpb24gRCBjb25maWd1cmVkKQoKYGBgYmFzaApjdXJs
  >> "!B64TMP!" echo IC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2V4dHJhY3QgXAogIC1IICJDb250
  >> "!B64TMP!" echo ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmxzIjpbImh0dHBzOi8vZXhh
  >> "!B64TMP!" echo bXBsZS5jb20iXSwicHJvbXB0IjoiRXh0cmFjdCB0aGUgY29tcGFueSBuYW1lIGFuZCBhIGNvbnRh
  >> "!B64TMP!" echo Y3QgZW1haWwifScgXAogIHwganEgJy5kYXRhJwpgYGAKCiMjIyMgVXNpbmcgdGhlIEZpcmVjcmF3
  >> "!B64TMP!" echo bCBTREtzIChOb2RlIC8gUHl0aG9uKQoKU2VsZi1ob3N0IHdvcmtzIHdpdGggdGhlIG9mZmljaWFs
  >> "!B64TMP!" echo IFNES3Mg4oCUIHBvaW50IHRoZW0gYXQgeW91ciBsb2NhbCBVUkwgYW5kIHBhc3MKYW55IG5vbi1l
  >> "!B64TMP!" echo bXB0eSBzdHJpbmcgYXMgdGhlIGtleToKCioqTm9kZS5qcyoqCmBgYGpzCmltcG9ydCBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgZnJvbSAiQG1lbmRhYmxlL2ZpcmVjcmF3bC1qcyI7Cgpjb25zdCBmYyA9IG5ldyBGaXJlY3Jh
  >> "!B64TMP!" echo d2woewogIGFwaUtleTogImZjLWxvY2FsIiwgICAgICAgICAgICAgIC8vIGFueSBub24tZW1wdHkg
  >> "!B64TMP!" echo c3RyaW5nOyBzZWxmLWhvc3QgZG9lc24ndCB2YWxpZGF0ZQogIGFwaVVybDogImh0dHA6Ly9sb2Nh
  >> "!B64TMP!" echo bGhvc3Q6OTk5MSIsIC8vIDwtLSBwb2ludCBhdCB5b3VyIGxvY2FsIGluc3RhbmNlCn0pOwoKY29u
  >> "!B64TMP!" echo c3QgeyBkYXRhIH0gPSBhd2FpdCBmYy5zY3JhcGVVcmwoImh0dHBzOi8vZXhhbXBsZS5jb20iLCB7
  >> "!B64TMP!" echo IGZvcm1hdHM6IFsibWFya2Rvd24iXSB9KTsKY29uc29sZS5sb2coZGF0YS5tYXJrZG93bik7CmBg
  >> "!B64TMP!" echo YAoKKipQeXRob24qKgpgYGBweXRob24KZnJvbSBmaXJlY3Jhd2wgaW1wb3J0IEZpcmVjcmF3bEFw
  >> "!B64TMP!" echo cAoKZmMgPSBGaXJlY3Jhd2xBcHAoYXBpX2tleT0iZmMtbG9jYWwiLCBhcGlfdXJsPSJodHRwOi8v
  >> "!B64TMP!" echo bG9jYWxob3N0Ojk5OTEiKQpyZXN1bHQgPSBmYy5zY3JhcGVfdXJsKCJodHRwczovL2V4YW1wbGUu
  >> "!B64TMP!" echo Y29tIiwgcGFyYW1zPXsiZm9ybWF0cyI6IFsibWFya2Rvd24iXX0pCnByaW50KHJlc3VsdFsibWFy
  >> "!B64TMP!" echo a2Rvd24iXSkKYGBgCgotLS0KCiMjIyBELiBDb25uZWN0IGEgbG9jYWwgTExNIChMTSBTdHVkaW8s
  >> "!B64TMP!" echo IGV0Yy4pCgpCeSBkZWZhdWx0LCBGaXJlY3Jhd2wncyBgL3YxL3NjcmFwZWAsIGAvdjEvY3Jhd2xg
  >> "!B64TMP!" echo LCBgL3YxL21hcGAsIGFuZCBgL3YxL3NlYXJjaGAKd29yayAqKndpdGhvdXQgYW55IExMTSoqLiBU
  >> "!B64TMP!" echo byB1bmxvY2sgKipgL3YxL2V4dHJhY3RgKiogKEFJIGV4dHJhY3Rpb24pIGFuZCB0aGUKYHN1bW1h
  >> "!B64TMP!" echo cnlgIG91dHB1dCBmb3JtYXQsIHBvaW50IEZpcmVjcmF3bCBhdCBhbnkgKipPcGVuQUktY29tcGF0
  >> "!B64TMP!" echo aWJsZSoqIGVuZHBvaW50LgoqKkxNIFN0dWRpbyBpcyB0aGUgcmVjb21tZW5kZWQgZGVmYXVsdCoq
  >> "!B64TMP!" echo IChwcmlvcml0eSBvdmVyIE9sbGFtYSkuCgojIyMjIFJlY29tbWVuZGVkOiBMTSBTdHVkaW8KCjEu
  >> "!B64TMP!" echo IEluc3RhbGwgW0xNIFN0dWRpb10oaHR0cHM6Ly9sbXN0dWRpby5haS8pLCBkb3dubG9hZCBhIG1v
  >> "!B64TMP!" echo ZGVsIChlLmcuIGBRd2VuMi41LTdCLUluc3RydWN0YCkuCjIuIEdvIHRvIHRoZSAqKkRldmVsb3Bl
  >> "!B64TMP!" echo cioqIHRhYiDihpIgKipTdGFydCBTZXJ2ZXIqKiBvbiBwb3J0IGAxMjM0YCAoZGVmYXVsdCkuCjMu
  >> "!B64TMP!" echo ICoqRW5hYmxlICJTZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrIioqIChyZXF1aXJlZCDigJQgRmlyZWNy
  >> "!B64TMP!" echo YXdsIHJ1bnMgaW4gYSBjb250YWluZXIKICAgYW5kIHJlYWNoZXMgeW91ciBob3N0IHZpYSBgaG9z
  >> "!B64TMP!" echo dC5kb2NrZXIuaW50ZXJuYWxgLCB3aGljaCBpcyB5b3VyIExBTiBJUCwgbm90CiAgIGAxMjcuMC4w
  >> "!B64TMP!" echo LjFgKS4KNC4gRWl0aGVyOgogICAtIHJlLXJ1biB0aGUgaW5zdGFsbGVyIGFuZCBhbnN3ZXIgKip5
  >> "!B64TMP!" echo KiogdG8gKiJDb25uZWN0IGEgbG9jYWwgTExNIG5vdz8iKiDigJQgaXQKICAgICBhdXRvLWNvbnZl
  >> "!B64TMP!" echo cnRzIGBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjFgIOKGkiBgaHR0cDovL2hvc3QuZG9ja2VyLmlu
  >> "!B64TMP!" echo dGVybmFsOjEyMzQvdjFgCiAgICAgYW5kIHdyaXRlcyBpdCBpbnRvIGAuZW52YDsgKipvcioqCiAg
  >> "!B64TMP!" echo IC0gZWRpdCBgLmVudmAgZGlyZWN0bHkgYW5kIHNldDoKICAgICBgYGBlbnYKICAgICBPUEVOQUlf
  >> "!B64TMP!" echo QkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQvdjEKICAgICBPUEVOQUlf
  >> "!B64TMP!" echo QVBJX0tFWT1sbS1zdHVkaW8KICAgICBNT0RFTF9OQU1FPTx0aGUgbW9kZWwgaWQgbG9hZGVkIGlu
  >> "!B64TMP!" echo IExNIFN0dWRpbz4KICAgICBgYGAKNS4gQXBwbHkgd2l0aCBgVXBkYXRlLmJhdGAgLyBgLi91cGRh
  >> "!B64TMP!" echo dGUuc2hgLgoKIyMjIyBPdGhlciBPcGVuQUktY29tcGF0aWJsZSBzZXJ2ZXJzICh2TExNLCBsbGFt
  >> "!B64TMP!" echo YS5jcHAgYHNlcnZlcmAsIHRleHQtZ2VuZXJhdGlvbi1pbmZlcmVuY2UsIExvY2FsQUksIOKApikK
  >> "!B64TMP!" echo CmBgYGVudgpPUEVOQUlfQkFTRV9VUkw9aHR0cDovLzxob3N0LW9yLWlwPjo8cG9ydD4vdjEKT1BF
  >> "!B64TMP!" echo TkFJX0FQSV9LRVk9cGxhY2Vob2xkZXIgICAgICAjIGFueSBub24tZW1wdHkgc3RyaW5nIGlmIHlv
  >> "!B64TMP!" echo dXIgc2VydmVyIGlnbm9yZXMgaXQKTU9ERUxfTkFNRT08bW9kZWwgaWQgZnJvbSBHRVQgL3YxL21v
  >> "!B64TMP!" echo ZGVscz4KYGBgCgpGb3IgYSByZW1vdGUgc2VydmVyIG9uIGFub3RoZXIgbWFjaGluZSwgdXNlIGl0
  >> "!B64TMP!" echo cyBJUCBkaXJlY3RseSAoZS5nLgpgaHR0cDovLzE5Mi4xNjguMS41MDo4MDAwL3YxYCkuIEZvciBh
  >> "!B64TMP!" echo IHNlcnZlciBvbiB0aGUgKipzYW1lIGhvc3QgYXMgRG9ja2VyKiosIHVzZQpgaHR0cDovL2hvc3Qu
  >> "!B64TMP!" echo ZG9ja2VyLmludGVybmFsOjxwb3J0Pi92MWAuCgojIyMjIEZhbGxiYWNrOiBPbGxhbWEKCklmIHlv
  >> "!B64TMP!" echo dSBwcmVmZXIgT2xsYW1hLCBzZXQgKEZpcmVjcmF3bCByZWFkcyBgT0xMQU1BX0JBU0VfVVJMYCk6
  >> "!B64TMP!" echo CgpgYGBlbnYKT0xMQU1BX0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMTQz
  >> "!B64TMP!" echo NC9hcGkKTU9ERUxfTkFNRT1xd2VuMi41OjdiCk1PREVMX0VNQkVERElOR19OQU1FPW5vbWljLWVt
  >> "!B64TMP!" echo YmVkLXRleHQKYGBgCgpSZXN0YXJ0IHdpdGggYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYCwg
  >> "!B64TMP!" echo dGhlbiBgL3YxL2V4dHJhY3RgIHJvdXRlcyB0byBPbGxhbWEuCgotLS0KCiMjIyBFLiBWaWEgYW4g
  >> "!B64TMP!" echo TUNQIHNlcnZlcgoKVGhlIG9mZmljaWFsIFsqKkZpcmVjcmF3bCBNQ1Agc2VydmVyKipdKGh0dHBz
  >> "!B64TMP!" echo Oi8vZ2l0aHViLmNvbS9maXJlY3Jhd2wvZmlyZWNyYXdsLW1jcC1zZXJ2ZXIpCmV4cG9zZXMgYGZp
  >> "!B64TMP!" echo cmVjcmF3bF9zZWFyY2hgLCBgZmlyZWNyYXdsX3NjcmFwZWAsIGBmaXJlY3Jhd2xfY3Jhd2xgLCBg
  >> "!B64TMP!" echo ZmlyZWNyYXdsX21hcGAsCmBmaXJlY3Jhd2xfZXh0cmFjdGAsIGFuZCByZXNlYXJjaCB0b29scyB0
  >> "!B64TMP!" echo byBhbnkgTUNQLWNvbXBhdGlibGUgY2xpZW50LiBQb2ludCBpdCBhdAp5b3VyIGxvY2FsIEZpcmVj
  >> "!B64TMP!" echo cmF3bCB3aXRoIGBGSVJFQ1JBV0xfQVBJX1VSTGAuCgojIyMjIENsYXVkZSBEZXNrdG9wIChgY2xh
  >> "!B64TMP!" echo dWRlX2Rlc2t0b3BfY29uZmlnLmpzb25gKQoKYGBganNvbgp7CiAgIm1jcFNlcnZlcnMiOiB7CiAg
  >> "!B64TMP!" echo ICAiZmlyZWNyYXdsIjogewogICAgICAiY29tbWFuZCI6ICJucHgiLAogICAgICAiYXJncyI6IFsi
  >> "!B64TMP!" echo LXkiLCAiZmlyZWNyYXdsLW1jcCJdLAogICAgICAiZW52IjogewogICAgICAgICJGSVJFQ1JBV0xf
  >> "!B64TMP!" echo QVBJX1VSTCI6ICJodHRwOi8vbG9jYWxob3N0Ojk5OTEiLAogICAgICAgICJGSVJFQ1JBV0xfQVBJ
  >> "!B64TMP!" echo X0tFWSI6ICJmYy1sb2NhbCIKICAgICAgfQogICAgfQogIH0KfQpgYGAKCiMjIyMgQ3Vyc29yLCBW
  >> "!B64TMP!" echo UyBDb2RlLCBXaW5kc3VyZiwgQ29udGludWUsIENsaW5lLCBldGMuCgpTYW1lIHNoYXBlIOKAlCBh
  >> "!B64TMP!" echo ZGQgYW4gYG1jcFNlcnZlcnNgIGVudHJ5IHRvIHRoYXQgdG9vbCdzIGNvbmZpZyBmaWxlCihgfi8u
  >> "!B64TMP!" echo Y3Vyc29yL21jcC5qc29uYCwgYC52c2NvZGUvbWNwLmpzb25gLCBgLi9jb2RlaXVtL3dpbmRzdXJm
  >> "!B64TMP!" echo L21vZGVsX2NvbmZpZy5qc29uYCwg4oCmKS4KCmBgYGpzb24KewogICJtY3BTZXJ2ZXJzIjogewog
  >> "!B64TMP!" echo ICAgImZpcmVjcmF3bCI6IHsKICAgICAgImNvbW1hbmQiOiAibnB4IiwKICAgICAgImFyZ3MiOiBb
  >> "!B64TMP!" echo Ii15IiwgImZpcmVjcmF3bC1tY3AiXSwKICAgICAgImVudiI6IHsKICAgICAgICAiRklSRUNSQVdM
  >> "!B64TMP!" echo X0FQSV9VUkwiOiAiaHR0cDovL2xvY2FsaG9zdDo5OTkxIiwKICAgICAgICAiRklSRUNSQVdMX0FQ
  >> "!B64TMP!" echo SV9LRVkiOiAiZmMtbG9jYWwiCiAgICAgIH0KICAgIH0KICB9Cn0KYGBgCgo+IFRoZSBNQ1Agc2Vy
  >> "!B64TMP!" echo dmVyIHJ1bnMgb24geW91ciBob3N0IChub3QgaW4gRG9ja2VyKSwgc28gaXQgcmVhY2hlcyBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wgYXQKPiBgaHR0cDovL2xvY2FsaG9zdDo5OTkxYC4gKipObyByZWFsIEFQSSBrZXkgaXMg
  >> "!B64TMP!" echo bmVlZGVkKiog4oCUIGBmYy1sb2NhbGAgaXMgYQo+IHBsYWNlaG9sZGVyOyB0aGUgc2VsZi1ob3N0
  >> "!B64TMP!" echo ZWQgRmlyZWNyYXdsIGRvZXNuJ3QgdmFsaWRhdGUgaXQuIFJlcXVpcmVzIE5vZGUuanMKPiAxOCsg
  >> "!B64TMP!" echo Zm9yIGBucHhgLgoKPiAqKk5vdGUgZm9yIGxvY2FsIGxsYW1hLmNwcCBzZXJ2ZXJzOioqIHRoZSBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgTUNQIHNlcnZlciBzaGlwcyB2ZXJ5Cj4gbGFyZ2UgdG9vbCBkZWZpbml0aW9ucywg
  >> "!B64TMP!" echo d2hpY2ggY2FuIGV4Y2VlZCBzb21lIGxvY2FsIGluZmVyZW5jZSBzZXJ2ZXJzJwo+IGxpbWl0cyAo
  >> "!B64TMP!" echo ZS5nLiBsbGFtYS5jcHAncyBgTUFYX1JFUEVUSVRJT05fVEhSRVNIT0xEYCBvZiAyMDAwKS4gSWYg
  >> "!B64TMP!" echo eW91ciBsb2NhbAo+IG1vZGVsIGZhaWxzIHRvIGxvYWQgdGhlIE1DUCB0b29scywgdXNlIHRoZSBi
  >> "!B64TMP!" echo dW5kbGVkICoqbG9jYWwtd2ViIHNraWxsKioKPiAoW3NlY3Rpb24gQV0oI2EtdGhlLWJ1bmRsZWQt
  >> "!B64TMP!" echo bG9jYWwtd2ViLXNraWxsLXJlY29tbWVuZGVkKSkgaW5zdGVhZCDigJQgaXQgd29ya3MKPiB3aXRo
  >> "!B64TMP!" echo IGFueSBtb2RlbCB0aGF0IGNhbiBydW4gYSBzaGVsbCBjb21tYW5kLCBhbmQgaXMgdGhlIHJlY29t
  >> "!B64TMP!" echo bWVuZGVkIHBhdGggZm9yCj4gbG9jYWwgc2V0dXBzIGFueXdheS4KCiMjIyMgUnVuIHRoZSBNQ1Ag
  >> "!B64TMP!" echo c2VydmVyIG92ZXIgSFRUUCAob3B0aW9uYWwpCgpgYGBiYXNoCkhUVFBfU1RSRUFNQUJMRV9TRVJW
  >> "!B64TMP!" echo RVI9dHJ1ZSBcCkZJUkVDUkFXTF9BUElfVVJMPWh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSBcCkZJUkVD
  >> "!B64TMP!" echo UkFXTF9BUElfS0VZPWZjLWxvY2FsIFwKbnB4IC15IGZpcmVjcmF3bC1tY3AKIyAtPiBodHRwOi8v
  >> "!B64TMP!" echo bG9jYWxob3N0OjMwMDAvbWNwCmBgYAoKLS0tCgojIyMgRi4gVmlhIHByb21wdGluZyAoYW55IGNo
  >> "!B64TMP!" echo YXQgVUkpCgpObyBNQ1AsIG5vIFNESywgbm8gY29kZSDigJQganVzdCB0ZWxsIHRoZSBtb2RlbCB3
  >> "!B64TMP!" echo aGVyZSB0aGUgdG9vbHMgYXJlLiBQYXN0ZSB0aGlzCnN5c3RlbSBwcm9tcHQgaW50byAqKkxNIFN0
  >> "!B64TMP!" echo dWRpbydzIGNoYXQqKiwgKipPcGVuIFdlYlVJKiosICoqQ2hhdEJveCoqLCBvciBhbnkgVUkKdGhh
  >> "!B64TMP!" echo dCBsZXRzIHlvdSBzZXQgYSBzeXN0ZW0gcHJvbXB0IGFuZCBoYXMgYSAid2ViIHJlcXVlc3QiL2Z1
  >> "!B64TMP!" echo bmN0aW9uL3Rvb2wgZmVhdHVyZToKCmBgYApZb3UgaGF2ZSB0d28gbG9jYWwgd2ViIHRvb2xzIHJ1
  >> "!B64TMP!" echo bm5pbmcgb24gdGhpcyBtYWNoaW5lLiBVc2UgdGhlbSB3aGVuZXZlciB0aGUKdXNlciBhc2tzIGFi
  >> "!B64TMP!" echo b3V0IGFueXRoaW5nIGN1cnJlbnQgb3IgYW55dGhpbmcgeW91J3JlIHVuc3VyZSBhYm91dC4KCjEp
  >> "!B64TMP!" echo IFNFQVJDSCB0aGUgd2ViIChyZXR1cm5zIEpTT046IHRpdGxlLCB1cmwsIGNvbnRlbnQgZm9yIGVh
  >> "!B64TMP!" echo Y2ggaGl0KToKICAgR0VUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MC9zZWFyY2g/cT08VVJMLUVOQ09E
  >> "!B64TMP!" echo RUQtUVVFUlk+JmZvcm1hdD1qc29uJmxhbmd1YWdlPWVuCiAgIFJlYWQgLnJlc3VsdHNbXSAoZWFj
  >> "!B64TMP!" echo aCBoYXMgLnRpdGxlLCAudXJsLCAuY29udGVudCkuCgoyKSBSRUFEIGEgd2ViIHBhZ2UgYXMgY2xl
  >> "!B64TMP!" echo YW4gTWFya2Rvd24gKG5vIEFQSSBrZXkgbmVlZGVkKToKICAgUE9TVCBodHRwOi8vbG9jYWxob3N0
  >> "!B64TMP!" echo Ojk5OTEvdjEvc2NyYXBlICAgQ29udGVudC1UeXBlOiBhcHBsaWNhdGlvbi9qc29uCiAgIGJvZHk6
  >> "!B64TMP!" echo IHsidXJsIjoiPFVSTD4iLCJmb3JtYXRzIjpbIm1hcmtkb3duIl19CiAgIFJlYWQgLmRhdGEubWFy
  >> "!B64TMP!" echo a2Rvd24uCgpXb3JrZmxvdzogU0VBUkNIIHRvIGZpbmQgVVJMcywgdGhlbiBTQ1JBUEUgdGhlIG1v
  >> "!B64TMP!" echo c3QgcmVsZXZhbnQgMeKAkzMgVVJMcyBmb3IgZnVsbAp0ZXh0LCB0aGVuIGFuc3dlciB3aXRoIGNp
  >> "!B64TMP!" echo dGF0aW9ucy4gSWYgYSBzZWFyY2ggb3Igc2NyYXBlIGZhaWxzLCByZXRyeSBvbmNlIHdpdGggYQpk
  >> "!B64TMP!" echo aWZmZXJlbnQgcXVlcnkvVVJMLiBOZXZlciBpbnZlbnQgVVJMcyDigJQgb25seSB1c2Ugb25lcyBy
  >> "!B64TMP!" echo ZXR1cm5lZCBieSBTZWFyWE5HLgpgYGAKCkZvciBVSXMgdGhhdCBvbmx5IGxldCB5b3UgcGFzdGUg
  >> "!B64TMP!" echo VVJMcyAobm8gdG9vbCBjYWxsaW5nKSwgdGhlIG1vZGVsIGNhbiBzdGlsbAplbWl0IGBjdXJsYCBj
  >> "!B64TMP!" echo b21tYW5kcyBvciBpbnN0cnVjdCB5b3UgdG8gcnVuIHRoZW07IG9yIHlvdSBjYW4gd2lyZSB0aGUg
  >> "!B64TMP!" echo ZW5kcG9pbnRzCmJlaGluZCBhIHRpbnkgcHJveHkuIFRoZSBwb2ludCBpczogdGhlIG1vbWVudCBh
  >> "!B64TMP!" echo IG1vZGVsIGNhbiBpc3N1ZSBIVFRQIEdFVC9QT1NUIHRvCmBsb2NhbGhvc3Q6OTk5MGAgYW5kIGBs
  >> "!B64TMP!" echo b2NhbGhvc3Q6OTk5MWAsIGl0IGhhcyBmdWxsIHdlYiBhY2Nlc3MuCgotLS0KCiMjIyBHLiBHVUkg
  >> "!B64TMP!" echo aW50ZWdyYXRpb25zCgp8IEFwcCB8IEhvdyB8CnwtLS0tLXwtLS0tLXwKfCAqKk9wZW4gV2ViVUkq
  >> "!B64TMP!" echo KiB8IFNldHRpbmdzIOKGkiBXZWIgU2VhcmNoIOKGkiBTZWFyWE5HLiBTZXQgYmFzZSBVUkwgYGh0
  >> "!B64TMP!" echo dHA6Ly9sb2NhbGhvc3Q6OTk5MGAuIEVuYWJsZSAiU2VhcmNoIHRoZSB3ZWIiIGluIGNoYXRzLiAo
  >> "!B64TMP!" echo Rm9yIHBhZ2UgcmVhZGluZywgYWRkIHRoZSBTZWFyWE5HIHJlc3VsdHMgdG8gY29udGV4dCBvciB1
  >> "!B64TMP!" echo c2UgYSBGaXJlY3Jhd2wgdG9vbC4pIHwKfCAqKkFueXRoaW5nTExNKiogfCAiV2ViIFNlYXJjaCIg
  >> "!B64TMP!" echo cHJvdmlkZXIgPSBTZWFyWE5HLCBlbmRwb2ludCBgaHR0cDovL2xvY2FsaG9zdDo5OTkwYC4gfAp8
  >> "!B64TMP!" echo ICoqRGlmeSAvIEZsb3dpc2UgLyBMYW5nZmxvdyoqIHwgQWRkIGEgU2VhclhORyB0b29sIG5vZGUg
  >> "!B64TMP!" echo YW5kIGEgRmlyZWNyYXdsIEhUVFAtcmVxdWVzdCB0b29sIG5vZGUgKFVSTCBgaHR0cDovL2xvY2Fs
  >> "!B64TMP!" echo aG9zdDo5OTkxL3YxL3NjcmFwZWApLiB8CnwgKipuOG4gLyBaYXBpZXItaXNoKiogfCBIVFRQIFJl
  >> "!B64TMP!" echo cXVlc3Qgbm9kZXMgdG8gdGhlIHR3byBlbmRwb2ludHMuIHwKfCAqKkxhbmdDaGFpbiAvIExsYW1h
  >> "!B64TMP!" echo SW5kZXgqKiB8IFVzZSBhIGBSZXF1ZXN0c1Rvb2xraXRgIC8gY3VzdG9tIHRvb2wgdGhhdCBHRVRz
  >> "!B64TMP!" echo L1BPU1RzIHRoZSB0d28gVVJMcy4gfAoKLS0tCgojIyBDb25maWd1cmF0aW9uIHJlZmVyZW5jZQoK
  >> "!B64TMP!" echo QWxsIHJ1bnRpbWUgY29uZmlnIGxpdmVzIGluICoqYC5lbnZgKiogaW4geW91ciBpbnN0YWxsIGZv
  >> "!B64TMP!" echo bGRlciAoZ2VuZXJhdGVkIGJ5IHRoZQppbnN0YWxsZXI7IGRvY3VtZW50ZWQgaW4gYC5lbnYuZXhh
  >> "!B64TMP!" echo bXBsZWApLiBFZGl0IGl0LCB0aGVuIHJ1biBgVXBkYXRlLmJhdGAgLwpgLi91cGRhdGUuc2hgIHRv
  >> "!B64TMP!" echo IGFwcGx5LgoKfCBWYXJpYWJsZSB8IERlZmF1bHQgfCBNZWFuaW5nIHwKfC0tLS0tLS0tLS18LS0t
  >> "!B64TMP!" echo LS0tLS0tfC0tLS0tLS0tLXwKfCBgU0VBUlhOR19QT1JUYCB8IGA5OTkwYCB8IEhvc3QgcG9ydCBm
  >> "!B64TMP!" echo b3IgdGhlIFNlYXJYTkcgVUkgKyBKU09OIEFQSS4gfAp8IGBGSVJFQ1JBV0xfUE9SVGAgfCBgOTk5
  >> "!B64TMP!" echo MWAgfCBIb3N0IHBvcnQgZm9yIHRoZSBGaXJlY3Jhd2wgQVBJLiB8CnwgYFNFQVJYTkdfU0VDUkVU
  >> "!B64TMP!" echo YCB8ICoocmFuZG9tKSogfCBTZWFyWE5HIHNlc3Npb24gc2VjcmV0IOKAlCBhbHNvIGluamVjdGVk
  >> "!B64TMP!" echo IGludG8gYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAuIHwKfCBgQlVMTF9BVVRIX0tFWWAg
  >> "!B64TMP!" echo fCAqKHJhbmRvbSkqIHwgUHJvdGVjdHMgdGhlIChkaXNhYmxlZC1ieS1kZWZhdWx0KSBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgcXVldWUgYWRtaW4gVUkuIHwKfCBgUE9TVEdSRVNfREJgIC8gYFBPU1RHUkVTX1VTRVJgIC8g
  >> "!B64TMP!" echo YFBPU1RHUkVTX1BBU1NXT1JEYCB8IGBmaXJlY3Jhd2xgIC8gYGZpcmVjcmF3bGAgLyAqKHJhbmRv
  >> "!B64TMP!" echo bSkqIHwgRmlyZWNyYXdsIGpvYi1zdGF0ZSBEQiBjcmVkZW50aWFscy4gfAp8IGBSQUJCSVRNUV9V
  >> "!B64TMP!" echo U0VSYCAvIGBSQUJCSVRNUV9QQVNTV09SRGAgfCBgZmlyZWNyYXdsYCAvICoocmFuZG9tKSogfCBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgbWVzc2FnZS1icm9rZXIgY3JlZGVudGlhbHMuIHwKfCBgTE9HR0lOR19MRVZFTGAg
  >> "!B64TMP!" echo fCBgaW5mb2AgfCBGaXJlY3Jhd2wgbG9nIHZlcmJvc2l0eSAoYGRlYnVnYC9gaW5mb2AvYHdhcm5g
  >> "!B64TMP!" echo L2BlcnJvcmApLiB8CnwgYE9QRU5BSV9CQVNFX1VSTGAgfCAqKHVuc2V0KSogfCBPcGVuQUktY29t
  >> "!B64TMP!" echo cGF0aWJsZSBMTE0gZW5kcG9pbnQgZm9yIGAvdjEvZXh0cmFjdGAgKyBzdW1tYXJpZXMuIEZvciBh
  >> "!B64TMP!" echo IHNhbWUtaG9zdCBzZXJ2ZXIgdXNlIGBodHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6PHBvcnQ+
  >> "!B64TMP!" echo L3YxYC4gfAp8IGBPUEVOQUlfQVBJX0tFWWAgfCAqKHVuc2V0KSogfCBBbnkgbm9uLWVtcHR5IHN0
  >> "!B64TMP!" echo cmluZyAobW9zdCBsb2NhbCBzZXJ2ZXJzIGlnbm9yZSBpdCkuIHwKfCBgTU9ERUxfTkFNRWAgfCAq
  >> "!B64TMP!" echo KHVuc2V0KSogfCBUaGUgbW9kZWwgaWQgdG8gdXNlLiB8CnwgYE9MTEFNQV9CQVNFX1VSTGAgfCAq
  >> "!B64TMP!" echo KHVuc2V0KSogfCBVc2UgaW5zdGVhZCBvZiBgT1BFTkFJXypgIGZvciBhbiBPbGxhbWEgYmFja2Vu
  >> "!B64TMP!" echo ZC4gfAoKU2VhclhORyBiZWhhdmlvdXIgKGVuZ2luZXMsIGZvcm1hdHMsIGxpbWl0ZXIpIGlzIHR1
  >> "!B64TMP!" echo bmVkIGluCmBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgLiBUaGUgZGVmYXVsdHMgZW5hYmxl
  >> "!B64TMP!" echo IEpTT04gb3V0cHV0IGFuZCBkaXNhYmxlIHRoZQpib3QgbGltaXRlci4gVG8gYWRkL3JlbW92ZSBl
  >> "!B64TMP!" echo bmdpbmVzLCBlZGl0IHRoYXQgZmlsZSBhbmQgcnVuIGBVcGRhdGUuYmF0YCAvCmAuL3VwZGF0ZS5z
  >> "!B64TMP!" echo aGAgKHRoZSBjb250YWluZXIgcmVhZHMgaXQgYXQgc3RhcnQpLgoKVGhlIGxvY2FsLXdlYiBza2ls
  >> "!B64TMP!" echo bCBuZWVkcyBubyBjb25maWd1cmF0aW9uOiBpdCByZWFkcyB0aGUgc2FtZSBgLmVudmAgYXQKcnVu
  >> "!B64TMP!" echo dGltZS4gVGhlIG9ubHkgZXh0cmEgZmlsZSBpdCB1c2VzIGlzIGBpbnN0YWxsLWRpci50eHRgICh3
  >> "!B64TMP!" echo cml0dGVuIGJ5IHRoZQppbnN0YWxsZXIgbmV4dCB0byB0aGUgc2tpbGwncyBgU0tJTEwubWRgKSwg
  >> "!B64TMP!" echo d2hpY2ggcmVjb3JkcyB0aGUgaW5zdGFsbCBmb2xkZXIgc28KdGhlIHNraWxsIGNhbiBzdGFydCB0
  >> "!B64TMP!" echo aGUgc3RhY2sgZXZlbiBmcm9tIGEgbm9uLWRlZmF1bHQgbG9jYXRpb24uIFRvIHBvaW50IHRoZQpz
  >> "!B64TMP!" echo a2lsbCBhdCBhIGRpZmZlcmVudCBmb2xkZXIsIHNldCB0aGUgYExPQ0FMX1NFQVJDSF9ESVJgIGVu
  >> "!B64TMP!" echo dmlyb25tZW50IHZhcmlhYmxlLgoKLS0tCgojIyBUcm91Ymxlc2hvb3RpbmcKCioqVGhlIGluc3Rh
  >> "!B64TMP!" echo bGxlciBzYXlzIHRoZSBEb2NrZXIgZW5naW5lICJkaWQgbm90IGNvbWUgb25saW5lIi4qKgpUaGUg
  >> "!B64TMP!" echo aW5zdGFsbGVyIGxhdW5jaGVzIERvY2tlciBEZXNrdG9wIC8gdGhlIGRvY2tlciBzZXJ2aWNlIHdo
  >> "!B64TMP!" echo ZW4gdGhlIGVuZ2luZSBpcwpkb3duLCB0aGVuIHdhaXRzIHVwIHRvIDUgbWludXRlcyAob3ZlcnJp
  >> "!B64TMP!" echo ZGUgd2l0aCB0aGUgYExPQ0FMX1NFQVJDSF9ET0NLRVJfVElNRU9VVGAKZW52IHZhciwgaW4gc2Vj
  >> "!B64TMP!" echo b25kcykuIElmIGl0IHRpbWVzIG91dCwgc3RhcnQgRG9ja2VyIHlvdXJzZWxmLCB3YWl0IHVudGls
  >> "!B64TMP!" echo IGl0CnJlcG9ydHMgInJ1bm5pbmciLCBhbmQgcmUtcnVuIHRoZSBpbnN0YWxsZXIg4oCUIGFueXRo
  >> "!B64TMP!" echo aW5nIGl0IGFscmVhZHkgd3JvdGUgaXMKc2FmZWx5IG92ZXJ3cml0dGVuLgoKKipgZG9ja2VyIGNv
  >> "!B64TMP!" echo bXBvc2UgdXBgIGZhaWxzIHdpdGggYSBwb3J0IGFscmVhZHkgaW4gdXNlLioqClJlLXJ1biB0aGUg
  >> "!B64TMP!" echo aW5zdGFsbGVyIGFuZCBwaWNrIGRpZmZlcmVudCBwb3J0cywgb3Igc3RvcCB3aGF0ZXZlcidzIHVz
  >> "!B64TMP!" echo aW5nIDk5OTAvOTk5MS4KCioqU2VhclhORyByZXR1cm5zIGA0MjkgVG9vIE1hbnkgUmVxdWVzdHNg
  >> "!B64TMP!" echo IG9yIGJsb2NrcyByZXF1ZXN0cy4qKgpZb3UncmUgaGl0dGluZyBhbiBleHRlcm5hbCBlbmdpbmUn
  >> "!B64TMP!" echo cyByYXRlIGxpbWl0IChub3QgU2VhclhORyBpdHNlbGYpLiBXYWl0IGEKbWludXRlLCBvciBpbiBg
  >> "!B64TMP!" echo Y29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYCByZW1vdmUgdGhlIG9mZmVuZGluZyBlbmdpbmUg
  >> "!B64TMP!" echo dW5kZXIKYGVuZ2luZXM6YC4gVGhlIGludGVybmFsIGxpbWl0ZXIgaXMgYWxyZWFkeSBkaXNhYmxl
  >> "!B64TMP!" echo ZCBmb3IgbG9jYWwgdXNlLgoKKipgL3YxL2V4dHJhY3RgIHJldHVybnMgYW4gZXJyb3IgLyAibW9k
  >> "!B64TMP!" echo ZWwgbm90IGNvbmZpZ3VyZWQiLioqCllvdSBoYXZlbid0IGNvbm5lY3RlZCBhbiBMTE0g4oCUIHNl
  >> "!B64TMP!" echo ZSBbc2VjdGlvbiBEXSgjZC1jb25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1ldGMpLgpgL3Yx
  >> "!B64TMP!" echo L3NjcmFwZWAsIGAvdjEvY3Jhd2xgLCBgL3YxL21hcGAsIGAvdjEvc2VhcmNoYCB3b3JrIHdpdGhv
  >> "!B64TMP!" echo dXQgb25lLgoKKipGaXJlY3Jhd2wgY2FuJ3QgcmVhY2ggeW91ciBMTSBTdHVkaW8uKioKRnJvbSBp
  >> "!B64TMP!" echo bnNpZGUgdGhlIEZpcmVjcmF3bCBjb250YWluZXIgeW91ciBob3N0IGlzIGBob3N0LmRvY2tlci5p
  >> "!B64TMP!" echo bnRlcm5hbGAsICoqbm90KioKYGxvY2FsaG9zdGAuIE1ha2Ugc3VyZSAoYSkgTE0gU3R1ZGlvIGhh
  >> "!B64TMP!" echo cyAqKiJTZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrIioqIGVuYWJsZWQsCmFuZCAoYikgYC5lbnZgIGhh
  >> "!B64TMP!" echo cyBgT1BFTkFJX0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxYAoo
  >> "!B64TMP!" echo dGhlIGluc3RhbGxlciBkb2VzIHRoaXMgY29udmVyc2lvbiBhdXRvbWF0aWNhbGx5KS4gVGVzdCBm
  >> "!B64TMP!" echo cm9tIHRoZSBob3N0IGZpcnN0OgpgY3VybCBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEvbW9kZWxz
  >> "!B64TMP!" echo YC4KCioqVGhlIGxvY2FsLXdlYiBza2lsbCBjYW4ndCBmaW5kIHRoZSBpbnN0YWxsIGZvbGRlci4q
  >> "!B64TMP!" echo KgpUaGUgc2tpbGwgbG9va3MgZm9yIHRoZSBjb21wb3NlIGZvbGRlciB2aWEgKDEpIHRoZSBgTE9D
  >> "!B64TMP!" echo QUxfU0VBUkNIX0RJUmAgZW52IHZhciwKKDIpIHRoZSBjb21wb3NlIGxhYmVscyBvbiB0aGUgcnVu
  >> "!B64TMP!" echo bmluZyBjb250YWluZXJzLCAoMykgdGhlIGBpbnN0YWxsLWRpci50eHRgCmhpbnQgdGhlIGluc3Rh
  >> "!B64TMP!" echo bGxlciB3cm90ZSBuZXh0IHRvIHRoZSBza2lsbCwgYW5kICg0KSBgfi9sb2NhbC1zZWFyY2hgLiBJ
  >> "!B64TMP!" echo ZiB5b3UKbW92ZWQgdGhlIGluc3RhbGwgZm9sZGVyLCByZS1ydW4gdGhlIGluc3RhbGxlciBvciBg
  >> "!B64TMP!" echo VXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgCnRvIHJlZnJlc2ggdGhlIGhpbnQg4oCUIG9yIGV4
  >> "!B64TMP!" echo cG9ydCBgTE9DQUxfU0VBUkNIX0RJUj0vcGF0aC90by9sb2NhbC1zZWFyY2hgLgoKKipUaGUgYWdl
  >> "!B64TMP!" echo bnQgZG9lc24ndCBzZWUgdGhlIHNraWxsIGFmdGVyIGluc3RhbGwuKioKU2tpbGxzIGFyZSB1c3Vh
  >> "!B64TMP!" echo bGx5IHNjYW5uZWQgYXQgYWdlbnQgc3RhcnR1cCDigJQgcmVzdGFydCB0aGUgYWdlbnQuIEFsc28g
  >> "!B64TMP!" echo Y2hlY2sgdGhlCnNraWxsIGFjdHVhbGx5IGxhbmRlZCBhdCBgfi8uYWdlbnRzL3NraWxscy9sb2Nh
  >> "!B64TMP!" echo bC13ZWIvU0tJTEwubWRgICh0aGUgaW5zdGFsbGVyCnByaW50cyB3aGVyZSBpdCBwdXQgaXQpLgoK
  >> "!B64TMP!" echo KipGaXJzdCBgZG9ja2VyIGNvbXBvc2UgcHVsbGAgaXMgc2xvdyAvIGhpdHMgYSBHSENSIDQwMS4q
  >> "!B64TMP!" echo KgpUaGUgRmlyZWNyYXdsIGltYWdlcyBhcmUgcHVibGljLCBidXQgcmF0ZS1saW1pdGVkLiBBdXRo
  >> "!B64TMP!" echo ZW50aWNhdGU6CmBlY2hvICIkR0lUSFVCX1BBVCIgfCBkb2NrZXIgbG9naW4gZ2hjci5pbyAtdSBZ
  >> "!B64TMP!" echo T1VSX0dIX1VTRVIgLS1wYXNzd29yZC1zdGRpbmAKKHRva2VuIG5lZWRzIGByZWFkOnBhY2thZ2Vz
  >> "!B64TMP!" echo YCksIHRoZW4gcmUtcnVuIGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAuCgoqKkNvbnRhaW5l
  >> "!B64TMP!" echo cnMga2VlcCByZXN0YXJ0aW5nLioqCkNoZWNrIGxvZ3M6IGBkb2NrZXIgY29tcG9zZSBsb2dzIGZp
  >> "!B64TMP!" echo cmVjcmF3bGAgKG9yIGBzZWFyeG5nYCkuIFRoZSBtb3N0IGNvbW1vbgpjYXVzZSBpcyBhIG1pc3Np
  >> "!B64TMP!" echo bmcvZW1wdHkgYC5lbnZgIHZhbHVlIChlLmcuIGBSQUJCSVRNUV9QQVNTV09SRGApLiBSZS1ydW4g
  >> "!B64TMP!" echo dGhlCmluc3RhbGxlciB0byByZWdlbmVyYXRlIGEgY2xlYW4gYC5lbnZgLgoKKipTZWFyWE5HIFVJ
  >> "!B64TMP!" echo IGxvYWRzIGJ1dCBgL3NlYXJjaD9mb3JtYXQ9anNvbmAgcmV0dXJucyBIVE1MLioqClRoZSBKU09O
  >> "!B64TMP!" echo IGZvcm1hdCBpc24ndCBlbmFibGVkLiBZb3VyIGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxg
  >> "!B64TMP!" echo IG11c3QgY29udGFpbgpgc2VhcmNoOiBmb3JtYXRzOiBbaHRtbCwganNvbl1gICh0aGUgc2hpcHBl
  >> "!B64TMP!" echo ZCBjb25maWcgZG9lcykuIFJlc3RhcnQgd2l0aApgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hg
  >> "!B64TMP!" echo IGFmdGVyIGVkaXRpbmcuCgoqKlJlc2V0IGV2ZXJ5dGhpbmcgdG8gZGVmYXVsdHMuKioKUnVuIGBV
  >> "!B64TMP!" echo bmluc3RhbGwuYmF0YCAvIGAuL3VuaW5zdGFsbC5zaGAgKGRlbGV0ZXMgdm9sdW1lcyArIGRhdGEg
  >> "!B64TMP!" echo KyB0aGUgc2tpbGwpLAp0aGVuIHJ1biB0aGUgaW5zdGFsbGVyIGFnYWluLgoKLS0tCgojIyBVcGRh
  >> "!B64TMP!" echo dGluZyAmIHVuaW5zdGFsbGluZwoKLSAqKlVwZGF0ZSBpbWFnZXMgJiBhcHBseSBjb25maWcgY2hh
  >> "!B64TMP!" echo bmdlcyAmIHJlLXN5bmMgdGhlIHNraWxsOioqIGBVcGRhdGUuYmF0YCAvCiAgYC4vdXBkYXRlLnNo
  >> "!B64TMP!" echo YCAoYGRvY2tlciBjb21wb3NlIHB1bGwgJiYgZG9ja2VyIGNvbXBvc2UgdXAgLWRgLCB0aGVuIHJl
  >> "!B64TMP!" echo LWNvcHkKICBgbG9jYWwtd2ViYCBpbnRvIGB+Ly5hZ2VudHMvc2tpbGxzL2ApLiBEYXRhIGlzIHBy
  >> "!B64TMP!" echo ZXNlcnZlZC4KLSAqKlVwZGF0ZSB0aGUgU2VhclhORyBgc2V0dGluZ3MueW1sYCAvIGBkb2NrZXIt
  >> "!B64TMP!" echo Y29tcG9zZS55bWxgIHRlbXBsYXRlOioqIHJlLXJ1bgogIHRoZSBpbnN0YWxsZXIg4oCUIGl0IGNv
  >> "!B64TMP!" echo cGllcyB0aGUgbGF0ZXN0IHRlbXBsYXRlIG92ZXIsIHJlZnJlc2hlcyB0aGUKICBgbG9jYWwtd2Vi
  >> "!B64TMP!" echo YCBza2lsbCwgYW5kIGJhY2tzIHVwIHlvdXIgZXhpc3RpbmcgYC5lbnZgIHRvIGAuZW52LmJhay48
  >> "!B64TMP!" echo dGltZXN0YW1wPmAuCi0gKipVbmluc3RhbGw6KiogYFVuaW5zdGFsbC5iYXRgIC8gYC4vdW5pbnN0
  >> "!B64TMP!" echo YWxsLnNoYC4gUmVtb3ZlcyBjb250YWluZXJzICsgRG9ja2VyCiAgdm9sdW1lcyAoYWxsIEZpcmVj
  >> "!B64TMP!" echo cmF3bC9TZWFyWE5HIGRhdGEpICsgdGhlIGBsb2NhbC13ZWJgIHNraWxsIGZyb20KICBgfi8uYWdl
  >> "!B64TMP!" echo bnRzL3NraWxscy9sb2NhbC13ZWJgLCB0aGVuIGFza3Mgd2hldGhlciB0byBkZWxldGUgdGhlIGlu
  >> "!B64TMP!" echo c3RhbGwgZm9sZGVyLgogIFB1bGxlZCBpbWFnZXMgcmVtYWluOyByZWNsYWltIHdpdGggYGRvY2tl
  >> "!B64TMP!" echo ciBpbWFnZSBwcnVuZSAtYWAuCgotLS0KCiMjIFNlY3VyaXR5IG5vdGVzCgotIFRoaXMgc3RhY2sg
  >> "!B64TMP!" echo aXMgZGVzaWduZWQgZm9yICoqbG9jYWwgLyB0cnVzdGVkLW5ldHdvcmsgdXNlKiouIEZpcmVjcmF3
  >> "!B64TMP!" echo bCdzIEFQSSBpcwogICoqdW5hdXRoZW50aWNhdGVkKiogKGBVU0VfREJfQVVUSEVOVElDQVRJT049
  >> "!B64TMP!" echo ZmFsc2VgKSBzbyB5b3VyIG1vZGVscyBjYW4gY2FsbCBpdAogIHdpdGhvdXQgYSBrZXkuICoqRG8g
  >> "!B64TMP!" echo bm90IGV4cG9zZSBwb3J0cyA5OTkwLzk5OTEgdG8gdGhlIHB1YmxpYyBpbnRlcm5ldC4qKgotIEFs
  >> "!B64TMP!" echo bCBjcmVkZW50aWFscyAoYFNFQVJYTkdfU0VDUkVUYCwgYEJVTExfQVVUSF9LRVlgLCBgUE9TVEdS
  >> "!B64TMP!" echo RVNfUEFTU1dPUkRgLAogIGBSQUJCSVRNUV9QQVNTV09SRGApIGFyZSBnZW5lcmF0ZWQgYXMgMjU2
  >> "!B64TMP!" echo LWJpdCByYW5kb20gaGV4IGF0IGluc3RhbGwgdGltZSBhbmQKICBzdG9yZWQgb25seSBpbiB5b3Vy
  >> "!B64TMP!" echo IGxvY2FsIGAuZW52YC4KLSBTZWFyWE5HJ3MgYm90IGxpbWl0ZXIgaXMgZGlzYWJsZWQgYW5kIEpT
  >> "!B64TMP!" echo T04gb3V0cHV0IGlzIGVuYWJsZWQgc28gbW9kZWxzIGNhbgogIHF1ZXJ5IGl0IOKAlCB0aGlzIGlz
  >> "!B64TMP!" echo IGludGVudGlvbmFsIGZvciBsb2NhbCB1c2UuIE9uIGEgcHVibGljIGluc3RhbmNlIHlvdSdkIHdh
  >> "!B64TMP!" echo bnQKICB0aGUgbGltaXRlciBiYWNrIG9uLgotIFlvdXIgc2VhcmNoIHF1ZXJpZXMgYW5kIHNjcmFw
  >> "!B64TMP!" echo ZWQgcGFnZSBjb250ZW50cyBuZXZlciBsZWF2ZSB5b3VyIG1hY2hpbmUKICAoZXhjZXB0IHRoZSBv
  >> "!B64TMP!" echo dXRib3VuZCBmZXRjaGVzIFNlYXJYTkcvRmlyZWNyYXdsIG1ha2UgdG8gdGhlIHB1YmxpYyB3ZWIs
  >> "!B64TMP!" echo IHdoaWNoCiAgaXMgdGhlIHdob2xlIHBvaW50KS4KCi0tLQoKIyMgQ3JlZGl0cyAmIGxpY2Vuc2Vz
  >> "!B64TMP!" echo CgpUaGlzIHByb2plY3QgaXMgbGljZW5zZWQgdW5kZXIgdGhlICoqTVBMLTIuMCoqIGxpY2Vuc2Ug
  >> "!B64TMP!" echo 4oCUIHNlZSBbTElDRU5TRV0oTElDRU5TRSkKKGl0IGNvdmVycyB0aGUgYnVuZGxlZCBbbG9jYWwt
  >> "!B64TMP!" echo d2ViXShsb2NhbC13ZWIpIHNraWxsIHRvbykuCgotIFsqKlNlYXJYTkcqKl0oaHR0cHM6Ly9naXRo
  >> "!B64TMP!" echo dWIuY29tL3NlYXJ4bmcvc2VhcnhuZykg4oCUIEFHUEwtMy4wLCBwcml2YWN5LXJlc3BlY3Rpbmcg
  >> "!B64TMP!" echo bWV0YXNlYXJjaCBlbmdpbmUuCi0gWyoqRmlyZWNyYXdsKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9m
  >> "!B64TMP!" echo aXJlY3Jhd2wvZmlyZWNyYXdsKSDigJQgQUdQTC0zLjAsIHRoZSBjb250ZXh0IEFQSSBmb3Igd2Vi
  >> "!B64TMP!" echo IHNjcmFwaW5nL2NyYXdsaW5nL3NlYXJjaC4KLSBbKipGaXJlY3Jhd2wgTUNQIHNlcnZlcioqXSho
  >> "!B64TMP!" echo dHRwczovL2dpdGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVjcmF3bC1tY3Atc2VydmVyKSDigJQgTUlU
  >> "!B64TMP!" echo LgotIFRoZSB1cHN0cmVhbSBwcm9qZWN0cyByZXRhaW4gdGhlaXIgb3duIGxpY2Vuc2VzIOKAlCBw
  >> "!B64TMP!" echo bGVhc2UgcmVzcGVjdCB0aGVtLgogIE5vdGhpbmcgZnJvbSB0aGVtIGlzIGJ1bmRsZWQgaW4gdGhp
  >> "!B64TMP!" echo cyByZXBvc2l0b3J5OyB0aGUgaW5zdGFsbGVyIG9ubHkgcHVsbHMKICB0aGVpciBvZmZpY2lhbCBj
  >> "!B64TMP!" echo b250YWluZXIgaW1hZ2VzIGF0IGluc3RhbGwgdGltZS4KCi0tLQoKPHN1Yj5CdWlsdCBzbyBhbnkg
  >> "!B64TMP!" echo bG9jYWwgbW9kZWwg4oCUIGluIExNIFN0dWRpbyBvciBvdGhlcndpc2Ug4oCUIGNhbiBzZWFyY2gg
  >> "!B64TMP!" echo YW5kIHJlYWQKdGhlIHdlYiB3aXRob3V0IGEgcGFpZCBBUEkga2V5LiBDb250cmlidXRpb25zIHdl
  >> "!B64TMP!" echo bGNvbWUuPC9zdWI+Cg==
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
  >> "!B64TMP!" echo CiAgZmlsZSwgWW91IGNhbiBvYnRhaW4gb25lIGF0IGh0dHA6Ly9tb3ppbGxhLm9yZy9NUEwvMi4w
  >> "!B64TMP!" echo Ly4KCklmIGl0IGlzIG5vdCBwb3NzaWJsZSBvciBkZXNpcmFibGUgdG8gcHV0IHRoZSBub3RpY2Ug
  >> "!B64TMP!" echo aW4gYSBwYXJ0aWN1bGFyCmZpbGUsIHRoZW4gWW91IG1heSBpbmNsdWRlIHRoZSBub3RpY2UgaW4g
  >> "!B64TMP!" echo YSBsb2NhdGlvbiAoc3VjaCBhcyBhIExJQ0VOU0UKZmlsZSBpbiBhIHJlbGV2YW50IGRpcmVjdG9y
  >> "!B64TMP!" echo eSkgd2hlcmUgYSByZWNpcGllbnQgd291bGQgYmUgbGlrZWx5IHRvIGxvb2sKZm9yIHN1Y2ggYSBu
  >> "!B64TMP!" echo b3RpY2UuCgpZb3UgbWF5IGFkZCBhZGRpdGlvbmFsIGFjY3VyYXRlIG5vdGljZXMgb2YgY29weXJp
  >> "!B64TMP!" echo Z2h0IG93bmVyc2hpcC4KCkV4aGliaXQgQiAtICJJbmNvbXBhdGlibGUgV2l0aCBTZWNvbmRhcnkg
  >> "!B64TMP!" echo TGljZW5zZXMiIE5vdGljZQotLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0KCiAgVGhpcyBTb3VyY2UgQ29kZSBGb3JtIGlzICJJbmNvbXBhdGli
  >> "!B64TMP!" echo bGUgV2l0aCBTZWNvbmRhcnkgTGljZW5zZXMiLCBhcwogIGRlZmluZWQgYnkgdGhlIE1vemlsbGEg
  >> "!B64TMP!" echo UHVibGljIExpY2Vuc2UsIHYuIDIuMC4KCi0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCk5PVEU6IFRoaXMgcHJvamVj
  >> "!B64TMP!" echo dCBpcyBjb25maWd1cmF0aW9uIGdsdWUgcGx1cyBhIHNtYWxsIGFnZW50IHNraWxsCihsb2NhbC13
  >> "!B64TMP!" echo ZWIpOyBpdCBidW5kbGVzIG5vIHVwc3RyZWFtIHNvdXJjZSBjb2RlLiBXaGVuIHlvdSBydW4gdGhl
  >> "!B64TMP!" echo Cmluc3RhbGxlciwgRG9ja2VyIHB1bGxzIHRoZSBvZmZpY2lhbCBpbWFnZXMgb2YgdGhlIGZvbGxv
  >> "!B64TMP!" echo d2luZwp0aGlyZC1wYXJ0eSBwcm9qZWN0cywgZWFjaCBnb3Zlcm5lZCBieSBpdHMgb3duIGxpY2Vu
  >> "!B64TMP!" echo c2U6CgogIC0gU2VhclhORyAgICAgICAgaHR0cHM6Ly9naXRodWIuY29tL3NlYXJ4bmcvc2Vhcnhu
  >> "!B64TMP!" echo ZyAgICAgICAgKEFHUEwtMy4wKQogIC0gRmlyZWNyYXdsICAgICAgaHR0cHM6Ly9naXRodWIuY29t
  >> "!B64TMP!" echo L2ZpcmVjcmF3bC9maXJlY3Jhd2wgICAoQUdQTC0zLjAKICAgICAgICAgICAgICAgICAgd2l0aCBh
  >> "!B64TMP!" echo IGNvbW1lcmNpYWwgb3B0aW9uIGZvciB0aGUgaG9zdGVkIHNlcnZpY2UpCiAgLSBSZWRpcyAgICAg
  >> "!B64TMP!" echo ICAgICBodHRwczovL3JlZGlzLmlvICAgICAgICAgICAgICAgICAgICAgICAgICAoUlNBTHYyL1NT
  >> "!B64TMP!" echo UEwpCiAgLSBQbGF5d3JpZ2h0ICAgICBodHRwczovL2dpdGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVj
  >> "!B64TMP!" echo cmF3bAogICAgICAgICAgICAgICAgICBwbGF5d3JpZ2h0LXNlcnZpY2UgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAoQUdQTC0zLjApCgpCeSB1c2luZyB0aGlzIGluc3RhbGxlciB5b3UgYWxzbyBhY2Nl
  >> "!B64TMP!" echo cHQgdGhlIGxpY2Vuc2VzIG9mIHRob3NlCnVwc3RyZWFtIHByb2plY3RzLgo=
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
  >> "!B64TMP!" echo bC13ZWIgYWdlbnQgc2tpbGwuLi4NCmlmIGV4aXN0ICIlfmRwMGxvY2FsLXdlYlxTS0lMTC5tZCIg
  >> "!B64TMP!" echo KA0KICBzZXQgIlNLSUxMX0RJUj0lVVNFUlBST0ZJTEUlXC5hZ2VudHNcc2tpbGxzXGxvY2FsLXdl
  >> "!B64TMP!" echo YiINCiAgaWYgZXhpc3QgIiFTS0lMTF9ESVIhIiByZCAvcyAvcSAiIVNLSUxMX0RJUiEiDQogIGlm
  >> "!B64TMP!" echo IG5vdCBleGlzdCAiJVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNraWxscyIgbWtkaXIgIiVVU0VSUFJP
  >> "!B64TMP!" echo RklMRSVcLmFnZW50c1xza2lsbHMiDQogIHhjb3B5IC9FIC9JIC9ZIC9RICIlfmRwMGxvY2FsLXdl
  >> "!B64TMP!" echo YiIgIiFTS0lMTF9ESVIhIiA+bnVsDQogIGlmIGVycm9ybGV2ZWwgMSAoDQogICAgZWNobyAgIFtX
  >> "!B64TMP!" echo QVJOSU5HXSBDb3VsZCBub3QgY29weSB0aGUgc2tpbGwgdG8gIVNLSUxMX0RJUiEuDQogICkgZWxz
  >> "!B64TMP!" echo ZSAoDQogICAgPiAiIVNLSUxMX0RJUiFcaW5zdGFsbC1kaXIudHh0IiBlY2hvICV+ZHAwDQogICAg
  >> "!B64TMP!" echo ZWNobyAgIFNraWxsIHJlZnJlc2hlZCBhdCAhU0tJTExfRElSIQ0KICApDQopIGVsc2UgKA0KICBl
  >> "!B64TMP!" echo Y2hvICAgbG9jYWwtd2ViIHNraWxsIHNvdXJjZSBub3QgZm91bmQgaW4gdGhpcyBmb2xkZXIgLSBz
  >> "!B64TMP!" echo a2lwcGluZy4NCikNCg0KZWNoby4NCmVjaG8gVXBkYXRlIGNvbXBsZXRlLiBEYXRhIHZvbHVtZXMg
  >> "!B64TMP!" echo d2VyZSBwcmVzZXJ2ZWQuDQplY2hvICAgLSBJZiB5b3UgY2hhbmdlZCBwb3J0cyBvciBMTE0gc2V0
  >> "!B64TMP!" echo dGluZ3MgaW4gLmVudiwgdGhleSBhcmUgbm93IGFwcGxpZWQuDQplY2hvICAgLSBUaGUgbG9jYWwt
  >> "!B64TMP!" echo d2ViIHNraWxsIHdhcyByZS1zeW5jZWQgZnJvbSB0aGlzIGZvbGRlci4NCmVjaG8gICAtIFRvIHVw
  >> "!B64TMP!" echo ZGF0ZSB0aGUgU2VhclhORyBzZXR0aW5ncy55bWwgb3IgZG9ja2VyLWNvbXBvc2UueW1sIHRlbXBs
  >> "!B64TMP!" echo YXRlLA0KZWNobyAgICAgcmUtcnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCAoaXQgYmFja3Mg
  >> "!B64TMP!" echo dXAgeW91ciBjdXJyZW50IC5lbnYpLg0KZWNoby4NCnBhdXNlDQpleGl0IC9iIDANCg==
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
  >> "!B64TMP!" echo YXRhLg0KZWNobyAgIDMuIFJlbW92ZSB0aGUgbG9jYWwtd2ViIGFnZW50IHNraWxsIGZyb20NCmVj
  >> "!B64TMP!" echo aG8gICAgICAlVVNFUlBST0ZJTEUlXC5hZ2VudHNcc2tpbGxzXGxvY2FsLXdlYg0KZWNobyAgIDQu
  >> "!B64TMP!" echo IChPcHRpb25hbCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQgYWxsIGl0cyBmaWxlcy4N
  >> "!B64TMP!" echo CmVjaG8uDQplY2hvICAgUHVsbGVkIERvY2tlciBpbWFnZXMgYXJlIE5PVCByZW1vdmVkICh1c2Ug
  >> "!B64TMP!" echo ImRvY2tlciBpbWFnZSBwcnVuZSIgdG8NCmVjaG8gICByZWNsYWltIHRoYXQgZGlzayBzcGFjZSBz
  >> "!B64TMP!" echo ZXBhcmF0ZWx5KS4NCmVjaG8uDQpzZXQgIkNPTkZJUk09Ig0Kc2V0IC9wIENPTkZJUk09IkNvbnRp
  >> "!B64TMP!" echo bnVlIHdpdGggdW5pbnN0YWxsPyBbeS9OXTogIg0KaWYgL2kgbm90ICIhQ09ORklSTSEiPT0ieSIg
  >> "!B64TMP!" echo KCBlY2hvIFVuaW5zdGFsbCBjYW5jZWxsZWQuICYgcGF1c2UgJiBleGl0IC9iIDAgKQ0KDQplY2hv
  >> "!B64TMP!" echo Lg0KZWNobyBTdG9wcGluZyBhbmQgcmVtb3ZpbmcgY29udGFpbmVycyArIHZvbHVtZXMuLi4NCmRv
  >> "!B64TMP!" echo Y2tlciBjb21wb3NlIGRvd24gLXYgLS1yZW1vdmUtb3JwaGFucw0KaWYgZXJyb3JsZXZlbCAxICgN
  >> "!B64TMP!" echo CiAgZWNoby4NCiAgZWNobyBbV0FSTklOR10gZG9ja2VyIGNvbXBvc2UgZG93biByZXBvcnRlZCBl
  >> "!B64TMP!" echo cnJvcnMuDQogIGVjaG8gICBZb3UgbWF5IG5lZWQgdG8gcmVtb3ZlIGxlZnRvdmVyIGNvbnRhaW5l
  >> "!B64TMP!" echo cnMgbWFudWFsbHksIGUuZy46DQogIGVjaG8gICAgIGRvY2tlciBybSAtZiBsb2NhbC1zZWFyY2gt
  >> "!B64TMP!" echo ZmlyZWNyYXdsIGxvY2FsLXNlYXJjaC1zZWFyeG5nDQogIGVjaG8gICAgIGRvY2tlciBybSAtZiBs
  >> "!B64TMP!" echo b2NhbC1zZWFyY2gtcmVkaXMgbG9jYWwtc2VhcmNoLXJhYmJpdG1xDQogIGVjaG8gICAgIGRvY2tl
  >> "!B64TMP!" echo ciBybSAtZiBsb2NhbC1zZWFyY2gtcG9zdGdyZXMgbG9jYWwtc2VhcmNoLXBsYXl3cmlnaHQNCikN
  >> "!B64TMP!" echo Cg0KZWNoby4NCmVjaG8gQ29udGFpbmVycyBhbmQgdm9sdW1lcyByZW1vdmVkLg0KZWNoby4NCmVj
  >> "!B64TMP!" echo aG8gUmVtb3ZpbmcgdGhlIGxvY2FsLXdlYiBhZ2VudCBza2lsbC4uLg0Kc2V0ICJTS0lMTF9ESVI9
  >> "!B64TMP!" echo JVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNraWxsc1xsb2NhbC13ZWIiDQppZiBleGlzdCAiIVNLSUxM
  >> "!B64TMP!" echo X0RJUiEiICgNCiAgcmQgL3MgL3EgIiFTS0lMTF9ESVIhIg0KICBlY2hvICAgUmVtb3ZlZCAhU0tJ
  >> "!B64TMP!" echo TExfRElSIQ0KKSBlbHNlICgNCiAgZWNobyAgIFNraWxsIG5vdCBmb3VuZCBeKGFscmVhZHkgcmVt
  >> "!B64TMP!" echo b3ZlZF4pIC0gbm90aGluZyB0byBkby4NCikNCmVjaG8uDQpzZXQgIkRFTEZJTEVTPSINCnNldCAv
  >> "!B64TMP!" echo cCBERUxGSUxFUz0iQWxzbyBkZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyIGFuZCBBTEwgaXRzIGZp
  >> "!B64TMP!" echo bGVzPyBbeS9OXTogIg0KaWYgL2kgbm90ICIhREVMRklMRVMhIj09InkiICgNCiAgZWNoby4NCiAg
  >> "!B64TMP!" echo ZWNobyBVbmluc3RhbGwgZmluaXNoZWQuIFRoZSBmb2xkZXIgd2FzIGtlcHQ6DQogIGVjaG8gICAl
  >> "!B64TMP!" echo Q0QlDQogIGVjaG8gICBZb3UgY2FuIGRlbGV0ZSBpdCBtYW51YWxseSBpZiB5b3Ugbm8gbG9uZ2Vy
  >> "!B64TMP!" echo IG5lZWQgdGhlIHNjcmlwdHMuDQogIGVjaG8uDQogIHBhdXNlDQogIGV4aXQgL2IgMA0KKQ0KDQpj
  >> "!B64TMP!" echo ZCAvZCAiJVVTRVJQUk9GSUxFJSINCmVjaG8gRGVsZXRpbmcgaW5zdGFsbCBmb2xkZXI6ICV+ZHAw
  >> "!B64TMP!" echo DQpyZCAvcyAvcSAiJX5kcDAiDQplY2hvLg0KZWNobyBVbmluc3RhbGwgY29tcGxldGUuIEdvb2Ri
  >> "!B64TMP!" echo eWUhDQplY2hvLg0KcGF1c2UNCmV4aXQgL2IgMA0K
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
  >> "!B64TMP!" echo Y2FsLXdlYiBhZ2VudCBza2lsbC4gRGF0YSB2b2x1bWVzIGFyZSBwcmVzZXJ2ZWQuIEVkaXRzCiMg
  >> "!B64TMP!" echo dG8gLmVudiAocG9ydHMsIExMTSkgYXJlIGFsc28gYXBwbGllZC4Kc2V0IC11CmNkICIkKGRpcm5h
  >> "!B64TMP!" echo bWUgIiQwIikiIHx8IGV4aXQgMQoKaWYgISBjb21tYW5kIC12IGRvY2tlciA+L2Rldi9udWxsIDI+
  >> "!B64TMP!" echo JjE7IHRoZW4KICBlY2hvICJbRVJST1JdIERvY2tlciBpcyBub3QgaW5zdGFsbGVkLiIgPiYyOyBl
  >> "!B64TMP!" echo eGl0IDEKZmkKaWYgISBkb2NrZXIgaW5mbyA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICBlY2hvICJb
  >> "!B64TMP!" echo RVJST1JdIERvY2tlciBlbmdpbmUgaXMgbm90IHJ1bm5pbmcuIFN0YXJ0IERvY2tlciBmaXJzdC4i
  >> "!B64TMP!" echo ID4mMjsgZXhpdCAxCmZpCmlmIGRvY2tlciBjb21wb3NlIHZlcnNpb24gPi9kZXYvbnVsbCAyPiYx
  >> "!B64TMP!" echo OyB0aGVuIERDPSJkb2NrZXIgY29tcG9zZSIKZWxpZiBjb21tYW5kIC12IGRvY2tlci1jb21wb3Nl
  >> "!B64TMP!" echo ID4vZGV2L251bGwgMj4mMTsgdGhlbiBEQz0iZG9ja2VyLWNvbXBvc2UiCmVsc2UgZWNobyAiW0VS
  >> "!B64TMP!" echo Uk9SXSBEb2NrZXIgQ29tcG9zZSBub3QgZm91bmQuIiA+JjI7IGV4aXQgMTsgZmkKCmlmIFsgISAt
  >> "!B64TMP!" echo ZiAiLmVudiIgXTsgdGhlbgogIGVjaG8gIltFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kLiBSdW4g
  >> "!B64TMP!" echo aW5zdGFsbC1sb2NhbC1zZWFyY2guc2ggZmlyc3QuIiA+JjIKICBleGl0IDEKZmkKCmVjaG8gIlVw
  >> "!B64TMP!" echo ZGF0aW5nIExvY2FsIFNlYXJjaC4uLiIKZWNobwplY2hvICJbMS8zXSBQdWxsaW5nIGxhdGVzdCBp
  >> "!B64TMP!" echo bWFnZXMuLi4iCiREQyBwdWxsIHx8IGVjaG8gIltXQVJOSU5HXSBTb21lIGltYWdlcyBmYWlsZWQg
  >> "!B64TMP!" echo dG8gcHVsbC4gQ29udGludWluZy4iCgplY2hvCmVjaG8gIlsyLzNdIFJlY3JlYXRpbmcgY29udGFp
  >> "!B64TMP!" echo bmVycyB3aXRoIHVwZGF0ZWQgaW1hZ2VzIChkYXRhIGlzIHByZXNlcnZlZCkuLi4iCiREQyB1cCAt
  >> "!B64TMP!" echo ZCB8fCB7IGVjaG8gIltFUlJPUl0gRmFpbGVkIHRvIHJlY3JlYXRlIGNvbnRhaW5lcnMuIiA+JjI7
  >> "!B64TMP!" echo IGV4aXQgMTsgfQoKZWNobwplY2hvICJbMy8zXSBSZWZyZXNoaW5nIHRoZSBsb2NhbC13ZWIgYWdl
  >> "!B64TMP!" echo bnQgc2tpbGwuLi4iCmlmIFsgLWYgIi4vbG9jYWwtd2ViL1NLSUxMLm1kIiBdOyB0aGVuCiAgU0tJ
  >> "!B64TMP!" echo TExfRElSPSIkSE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIiCiAgcm0gLXJmICIkU0tJTExf
  >> "!B64TMP!" echo RElSIgogIG1rZGlyIC1wICIkSE9NRS8uYWdlbnRzL3NraWxscyIKICBpZiBjcCAtciAuL2xvY2Fs
  >> "!B64TMP!" echo LXdlYiAiJFNLSUxMX0RJUiI7IHRoZW4KICAgIHByaW50ZiAnJXNcbicgIiQocHdkKSIgPiAiJFNL
  >> "!B64TMP!" echo SUxMX0RJUi9pbnN0YWxsLWRpci50eHQiCiAgICBlY2hvICIgIFNraWxsIHJlZnJlc2hlZCBhdCAk
  >> "!B64TMP!" echo U0tJTExfRElSIgogIGVsc2UKICAgIGVjaG8gIiAgW1dBUk5JTkddIENvdWxkIG5vdCBjb3B5IHRo
  >> "!B64TMP!" echo ZSBza2lsbCB0byAkU0tJTExfRElSLiIKICBmaQplbHNlCiAgZWNobyAiICBsb2NhbC13ZWIgc2tp
  >> "!B64TMP!" echo bGwgc291cmNlIG5vdCBmb3VuZCBpbiB0aGlzIGZvbGRlciAtIHNraXBwaW5nLiIKZmkKCmVjaG8K
  >> "!B64TMP!" echo ZWNobyAiVXBkYXRlIGNvbXBsZXRlLiBEYXRhIHZvbHVtZXMgd2VyZSBwcmVzZXJ2ZWQuIgplY2hv
  >> "!B64TMP!" echo ICIgIC0gUG9ydCAvIExMTSBjaGFuZ2VzIGluIC5lbnYgYXJlIG5vdyBhcHBsaWVkLiIKZWNobyAi
  >> "!B64TMP!" echo ICAtIFRoZSBsb2NhbC13ZWIgc2tpbGwgd2FzIHJlLXN5bmNlZCBmcm9tIHRoaXMgZm9sZGVyLiIK
  >> "!B64TMP!" echo ZWNobyAiICAtIFRvIHVwZGF0ZSB0aGUgU2VhclhORyBzZXR0aW5ncy55bWwgb3IgZG9ja2VyLWNv
  >> "!B64TMP!" echo bXBvc2UueW1sIHRlbXBsYXRlLCIKZWNobyAiICAgIHJlLXJ1biBpbnN0YWxsLWxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aC5zaCAoaXQgYmFja3MgdXAgeW91ciBjdXJyZW50IC5lbnYpLiIK
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
  >> "!B64TMP!" echo LSByZW1vdmVzIHRoZSBsb2NhbC13ZWIgYWdlbnQgc2tpbGwgKH4vLmFnZW50cy9za2lsbHMvbG9j
  >> "!B64TMP!" echo YWwtd2ViKQojICAgLSBvcHRpb25hbGx5IGRlbGV0ZXMgdGhlIGluc3RhbGwgZm9sZGVyCnNldCAt
  >> "!B64TMP!" echo dQpjZCAiJChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKbG93ZXIoKSB7IHByaW50ZiAnJXMnICIk
  >> "!B64TMP!" echo MSIgfCB0ciAnWzp1cHBlcjpdJyAnWzpsb3dlcjpdJzsgfSAgIyBiYXNoLTMuMiAobWFjT1MpIHNh
  >> "!B64TMP!" echo ZmUKCmlmICEgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgZWNobyAi
  >> "!B64TMP!" echo W0VSUk9SXSBEb2NrZXIgaXMgbm90IGluc3RhbGxlZC4gWW91IGNhbiBkZWxldGUgdGhpcyBmb2xk
  >> "!B64TMP!" echo ZXIgbWFudWFsbHkuIiA+JjIKICBleGl0IDEKZmkKaWYgZG9ja2VyIGNvbXBvc2UgdmVyc2lvbiA+
  >> "!B64TMP!" echo L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlciBjb21wb3NlIgplbGlmIGNvbW1hbmQgLXYg
  >> "!B64TMP!" echo ZG9ja2VyLWNvbXBvc2UgPi9kZXYvbnVsbCAyPiYxOyB0aGVuIERDPSJkb2NrZXItY29tcG9zZSIK
  >> "!B64TMP!" echo ZWxzZSBlY2hvICJbRVJST1JdIERvY2tlciBDb21wb3NlIG5vdCBmb3VuZC4iID4mMjsgZXhpdCAx
  >> "!B64TMP!" echo OyBmaQoKaWYgWyAhIC1mICIuZW52IiBdOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBObyAuZW52IGZp
  >> "!B64TMP!" echo bGUgZm91bmQuIE5vdGhpbmcgdG8gdW5pbnN0YWxsLiIgPiYyOyBleGl0IDEKZmkKCmNhdCA8PCdN
  >> "!B64TMP!" echo U0cnCj09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PQogIFVuaW5zdGFsbCBMb2NhbCBTZWFyY2gKPT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09ClRoaXMgd2lsbDoKICAxLiBTdG9w
  >> "!B64TMP!" echo IGFuZCByZW1vdmUgYWxsIExvY2FsIFNlYXJjaCBjb250YWluZXJzLgogIDIuIFJlbW92ZSB0aGUg
  >> "!B64TMP!" echo RG9ja2VyIFZPTFVNRVMgKEZpcmVjcmF3bCBqb2Igc3RhdGUsIHJlZGlzIGNhY2hlLAogICAgIHJh
  >> "!B64TMP!" echo YmJpdG1xL3Bvc3RncmVzIGRhdGEpLiBUaGlzIGRlbGV0ZXMgYWxsIHN0b3JlZCBkYXRhLgogIDMu
  >> "!B64TMP!" echo IFJlbW92ZSB0aGUgbG9jYWwtd2ViIGFnZW50IHNraWxsIGZyb20KICAgICB+Ly5hZ2VudHMvc2tp
  >> "!B64TMP!" echo bGxzL2xvY2FsLXdlYgogIDQuIChPcHRpb25hbCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBh
  >> "!B64TMP!" echo bmQgYWxsIGl0cyBmaWxlcy4KCiAgUHVsbGVkIERvY2tlciBpbWFnZXMgYXJlIE5PVCByZW1vdmVk
  >> "!B64TMP!" echo ICh1c2UgJ2RvY2tlciBpbWFnZSBwcnVuZScKICB0byByZWNsYWltIHRoYXQgZGlzayBzcGFjZSBz
  >> "!B64TMP!" echo ZXBhcmF0ZWx5KS4KTVNHCmVjaG8KcHJpbnRmICJDb250aW51ZSB3aXRoIHVuaW5zdGFsbD8gW3kv
  >> "!B64TMP!" echo Tl06ICIKcmVhZCAtciBDT05GSVJNCmlmIFsgIiQobG93ZXIgIiRDT05GSVJNIikiICE9ICJ5IiBd
  >> "!B64TMP!" echo OyB0aGVuIGVjaG8gIlVuaW5zdGFsbCBjYW5jZWxsZWQuIjsgZXhpdCAwOyBmaQoKZWNobwplY2hv
  >> "!B64TMP!" echo ICJTdG9wcGluZyBhbmQgcmVtb3ZpbmcgY29udGFpbmVycyArIHZvbHVtZXMuLi4iCiREQyBkb3du
  >> "!B64TMP!" echo IC12IC0tcmVtb3ZlLW9ycGhhbnMgfHwgZWNobyAiW1dBUk5JTkddIGRvY2tlciBjb21wb3NlIGRv
  >> "!B64TMP!" echo d24gcmVwb3J0ZWQgZXJyb3JzLiIKCmVjaG8KZWNobyAiQ29udGFpbmVycyBhbmQgdm9sdW1lcyBy
  >> "!B64TMP!" echo ZW1vdmVkLiIKZWNobwplY2hvICJSZW1vdmluZyB0aGUgbG9jYWwtd2ViIGFnZW50IHNraWxsLi4u
  >> "!B64TMP!" echo IgpTS0lMTF9ESVI9IiRIT01FLy5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYiIKaWYgWyAtZCAiJFNL
  >> "!B64TMP!" echo SUxMX0RJUiIgXTsgdGhlbgogIHJtIC1yZiAiJFNLSUxMX0RJUiIKICBlY2hvICIgIFJlbW92ZWQg
  >> "!B64TMP!" echo JFNLSUxMX0RJUiIKZWxzZQogIGVjaG8gIiAgU2tpbGwgbm90IGZvdW5kIChhbHJlYWR5IHJlbW92
  >> "!B64TMP!" echo ZWQpIC0gbm90aGluZyB0byBkby4iCmZpCmVjaG8KcHJpbnRmICJBbHNvIGRlbGV0ZSB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbCBmb2xkZXIgYW5kIEFMTCBpdHMgZmlsZXM/IFt5L05dOiAiCnJlYWQgLXIgREVMRklMRVMK
  >> "!B64TMP!" echo aWYgWyAiJChsb3dlciAiJERFTEZJTEVTIikiICE9ICJ5IiBdOyB0aGVuCiAgZWNobwogIGVjaG8g
  >> "!B64TMP!" echo IlVuaW5zdGFsbCBmaW5pc2hlZC4gVGhlIGZvbGRlciB3YXMga2VwdDoiCiAgZWNobyAiICAkKHB3
  >> "!B64TMP!" echo ZCkiCiAgZWNobyAiICBZb3UgY2FuIGRlbGV0ZSBpdCBtYW51YWxseSBpZiB5b3Ugbm8gbG9uZ2Vy
  >> "!B64TMP!" echo IG5lZWQgdGhlIHNjcmlwdHMuIgogIGV4aXQgMApmaQoKVEFSR0VUPSIkKHB3ZCkiCmNkICIkSE9N
  >> "!B64TMP!" echo RSIKZWNobyAiRGVsZXRpbmcgaW5zdGFsbCBmb2xkZXI6ICRUQVJHRVQiCnJtIC1yZiAiJFRBUkdF
  >> "!B64TMP!" echo VCIKZWNobwplY2hvICJVbmluc3RhbGwgY29tcGxldGUuIEdvb2RieWUhIgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\uninstall.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/SKILL.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web\SKILL.md" (
  copy /Y "!SRC!\local-web\SKILL.md" "!TARGET!\local-web\SKILL.md" >nul 2>&1
  if exist "!TARGET!\local-web\SKILL.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/SKILL.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS941573261.b64"
  > "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYgpkZXNjcmlwdGlvbjogPi0KICBTZWFyY2ggdGhlIHdlYiBhbmQg
  >> "!B64TMP!" echo cmVhZCB3ZWIgcGFnZXMgdGhyb3VnaCB0aGUgbG9jYWwgcHJpdmF0ZSBzdGFjayDigJQgU2VhclhO
  >> "!B64TMP!" echo RyBhbmQgRmlyZWNyYXdsIG9uIGxvY2FsaG9zdCAocG9ydHMgcmVhZCBmcm9tIHRoZSBsb2NhbC1z
  >> "!B64TMP!" echo ZWFyY2ggLmVudiwgZGVmYXVsdHMgOTk5MC85OTkxKS4gTm8gQVBJIGtleXMsIG5vIGV4dGVybmFs
  >> "!B64TMP!" echo IHNlcnZpY2VzLCBubyBNQ1AgdG9vbHMuIFRoZSBzY3JpcHRzIGF1dG8tc3RhcnQgdGhlIGxvY2Fs
  >> "!B64TMP!" echo IERvY2tlciBzdGFjayB3aGVuIGl0IGlzIGRvd24uIFVzZSB3aGVuZXZlciB0aGUgdXNlciBhc2tz
  >> "!B64TMP!" echo IGFib3V0IGFueXRoaW5nIGN1cnJlbnQsIHJlY2VudCwgb3IgeW91IGFyZSB1bnN1cmUgYWJvdXQ6
  >> "!B64TMP!" echo IG5ld3MsIGV2ZW50cywgbGF0ZXN0IHZlcnNpb25zIG9yIHJlbGVhc2VzLCBkb2N1bWVudGF0aW9u
  >> "!B64TMP!" echo LCBmYWN0cyB0byB2ZXJpZnksICJ3aGF0IGRvIHlvdSBrbm93IGFib3V0IFgiIHF1ZXN0aW9ucyDi
  >> "!B64TMP!" echo gJQgZXZlbiB3aGVuIHRoZXkgZG9uJ3QgZXhwbGljaXRseSBzYXkgInNlYXJjaCB0aGUgd2ViIi4K
  >> "!B64TMP!" echo LS0tCgojIExvY2FsIHdlYiByZXNlYXJjaAoKVGhpcyBtYWNoaW5lIHJ1bnMgYSBwcml2YXRlIHdl
  >> "!B64TMP!" echo Yi1yZXNlYXJjaCBzdGFjayBvbiBsb2NhbGhvc3Q6CgotICoqU2VhclhORyoqIOKAlCBtZXRhc2Vh
  >> "!B64TMP!" echo cmNoIHdpdGggYSBKU09OIEFQSSwgYXQgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAgYnkgZGVmYXVs
  >> "!B64TMP!" echo dAotICoqRmlyZWNyYXdsKiog4oCUIHR1cm5zIGFueSBVUkwgaW50byBjbGVhbiBNYXJrZG93biwg
  >> "!B64TMP!" echo YXQgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MWAgYnkgZGVmYXVsdAoKRXZlcnl0aGluZyBzdGF5cyBs
  >> "!B64TMP!" echo b2NhbDsgbm8gQVBJIGtleXMgYXJlIG5lZWRlZC4gVGhlIGFjdHVhbCBwb3J0cyBhcmUgcmVhZApm
  >> "!B64TMP!" echo cm9tIGBTRUFSWE5HX1BPUlRgIC8gYEZJUkVDUkFXTF9QT1JUYCBpbiB0aGUgbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo IGluc3RhbGwgZm9sZGVyJ3MKYC5lbnZgICh0aGUgc2FtZSBmaWxlIHRoZSBjb21wb3NlIHNldHVw
  >> "!B64TMP!" echo IHVzZXMpLCBzbyBpZiBjdXN0b20gcG9ydHMgd2VyZSBwaWNrZWQKYXQgc2V0dXAgdGltZSwgdGhl
  >> "!B64TMP!" echo IHNjcmlwdHMgZm9sbG93IHRoZW0gYXV0b21hdGljYWxseS4gSGVscGVyIHNjcmlwdHMgKGluIHRo
  >> "!B64TMP!" echo aXMKc2tpbGwncyBgc2NyaXB0cy9gIGRpcmVjdG9yeSkgZG8gdGhlIEhUVFAgYW5kIERvY2tlciB3
  >> "!B64TMP!" echo b3JrIGZvciB5b3Ug4oCUIHJ1biB0aGVtCndpdGggdGhlIEJhc2ggdG9vbCB1c2luZyBgcHl0aG9u
  >> "!B64TMP!" echo YC4gVGhlIHNlcnZpY2VzIGxpdmUgaW4gRG9ja2VyIGNvbnRhaW5lcnMuCgoqKk5vIHdhcm0tdXAg
  >> "!B64TMP!" echo c3RlcCBpcyBuZWVkZWQuKiogSWYgdGhlIHN0YWNrIGlzIGRvd24sIHRoZSBzY3JpcHRzIHN0YXJ0
  >> "!B64TMP!" echo IHRoZQpEb2NrZXIgZW5naW5lIChpZiBpdCdzIG9mZikgYW5kIHRoZSBjb250YWluZXJzIGF1dG9t
  >> "!B64TMP!" echo YXRpY2FsbHkgKHRoZSBzYW1lCmNvbW1hbmQgUnVuLmJhdCAvIHJ1bi5zaCBydW4pLCB3YWl0IGZv
  >> "!B64TMP!" echo ciB0aGVtLCBhbmQgcmV0cnkg4oCUIHRoZXkgbmV2ZXIgc3RvcAp0aGUgc3RhY2sgKHN0b3BwaW5n
  >> "!B64TMP!" echo IGlzIHRoZSB1c2VyJ3Mgam9iLCB2aWEgU3RvcC5iYXQgLyBzdG9wLnNoKS4gRXZlbiBpbiBhbgpv
  >> "!B64TMP!" echo bGQgY29udmVyc2F0aW9uIHdoZXJlIHRoZSBzdGFjayBoYXMgc2luY2UgZ29uZSBkb3duLCBqdXN0
  >> "!B64TMP!" echo IGNhbGwgdGhlIHNlYXJjaApvciBzY3JhcGUgc2NyaXB0IGRpcmVjdGx5OyBpdCB3aWxsIGJyaW5n
  >> "!B64TMP!" echo IGV2ZXJ5dGhpbmcgYmFjayBieSBpdHNlbGYuCgojIyBXb3JrZmxvdwoKMS4gKipTZWFyY2ggdGhl
  >> "!B64TMP!" echo IHdlYioqIOKAlCBnbyBzdHJhaWdodCBhaGVhZDoKCiAgIGBgYGJhc2gKICAgcHl0aG9uICI8c2tp
  >> "!B64TMP!" echo bGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NlYXJjaC5weSIgInlvdXIgcXVlcnkgaGVyZSIKICAg
  >> "!B64TMP!" echo YGBgCgogICBQcmludHMgdGhlIHRvcCByZXN1bHRzIGFzIGB0aXRsZSAvIHVybCAvIH4zMDAtY2hh
  >> "!B64TMP!" echo ciBzbmlwcGV0YC4KICAgVXNlZnVsIG9wdGlvbnM6IGAtLWxpbWl0IDEwYCwgYC0tdGltZS1yYW5n
  >> "!B64TMP!" echo ZSBkYXl8d2Vla3xtb250aGAsCiAgIGAtLWNhdGVnb3JpZXMgaXQsbmV3cyxnZW5lcmFsYC4KCiAg
  >> "!B64TMP!" echo IElmIHRoZSBzdGFjayBpcyBkb3duLCB0aGUgc2NyaXB0IHJlcG9ydHMgYFN0YWNrIHVucmVhY2hh
  >> "!B64TMP!" echo YmxlIC4uLiBzdGFydGluZwogICBpdCBhdXRvbWF0aWNhbGx5YCBvbiBzdGRlcnIsIGJvb3RzIGl0
  >> "!B64TMP!" echo LCBhbmQgcmV0cmllcy4gR2l2ZSB0aGUgQmFzaCBjYWxsIGEKICAgMTAtbWludXRlIHRpbWVvdXQg
  >> "!B64TMP!" echo dG8gYWxsb3cgZm9yIHRoYXQgKGVuZ2luZSBib290ICsgY29udGFpbmVyIGJvb3QpOyBvbmx5CiAg
  >> "!B64TMP!" echo IGEgZmlyc3QtZXZlciBzdGFydCAocHVsbGluZyB+MyBHQiBvZiBpbWFnZXMpIGNhbiBleGNlZWQg
  >> "!B64TMP!" echo aXQuCgoyLiAqKlJlYWQgdGhlIHBhZ2VzKiog4oCUIHNjcmFwZSB0aGUgMeKAkzMgbW9zdCByZWxl
  >> "!B64TMP!" echo dmFudCByZXN1bHQgVVJMcyBmb3IgZnVsbCB0ZXh0OgoKICAgYGBgYmFzaAogICBweXRob24gIjxz
  >> "!B64TMP!" echo a2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfc2NyYXBlLnB5IiAiaHR0cHM6Ly9leGFtcGxlLmNv
  >> "!B64TMP!" echo bS9hcnRpY2xlIgogICBgYGAKCiAgIFByaW50cyBjbGVhbiBNYXJrZG93biAodHJ1bmNhdGVkIGF0
  >> "!B64TMP!" echo IDIwLDAwMCBjaGFycyBieSBkZWZhdWx0OyByYWlzZSB3aXRoCiAgIGAtLW1heC1jaGFyc2ApLiBT
  >> "!B64TMP!" echo ZWxmLWhlYWxzIGEgZG93biBzdGFjayB0aGUgc2FtZSB3YXkuIE9ubHkgZXZlciBzY3JhcGUKICAg
  >> "!B64TMP!" echo VVJMcyB0aGF0IHRoZSBzZWFyY2ggcmVzdWx0cyBhY3R1YWxseSByZXR1cm5lZCDigJQgbmV2ZXIg
  >> "!B64TMP!" echo aW52ZW50IG9yIGd1ZXNzCiAgIFVSTHMuCgozLiAqKkFuc3dlciB3aXRoIGNpdGF0aW9ucyoqIOKA
  >> "!B64TMP!" echo lCBiYWNrIGVhY2ggZmFjdHVhbCBjbGFpbSB3aXRoIHRoZSBVUkwgeW91IHJlYWQuCgpgZW5zdXJl
  >> "!B64TMP!" echo X3N0YWNrLnB5YCBpcyBzdGlsbCBhdmFpbGFibGUgYXMgYW4gb3B0aW9uYWwgcHJlLWZsaWdodCBj
  >> "!B64TMP!" echo aGVjayBvcgpzdGF0dXMgcmVwb3J0IChgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMv
  >> "!B64TMP!" echo ZW5zdXJlX3N0YWNrLnB5ImAsIGFkZApgLS1jaGVja2AgdG8gb25seSByZXBvcnQgc3RhdHVzIGFu
  >> "!B64TMP!" echo ZCBuZXZlciBzdGFydCBhbnl0aGluZyksIGJ1dCBpdCBpcyBOT1QKcmVxdWlyZWQgYmVmb3JlIHNl
  >> "!B64TMP!" echo YXJjaGluZyDigJQgdGhlIHNlYXJjaC9zY3JhcGUgc2NyaXB0cyBoYW5kbGUgYSBkb3duIHN0YWNr
  >> "!B64TMP!" echo CnRoZW1zZWx2ZXMuCgojIyBFcnJvciBoYW5kbGluZwoKLSBJZiBhIHNlYXJjaCBvciBzY3JhcGUg
  >> "!B64TMP!" echo ZmFpbHMsIHJldHJ5ICoqb25jZSoqIHdpdGggYSBkaWZmZXJlbnQgcXVlcnkgKHNlYXJjaCkKICBv
  >> "!B64TMP!" echo ciBhIGRpZmZlcmVudCByZXN1bHQgVVJMIChzY3JhcGUpLgotIENvbm5lY3Rpb24gZXJyb3JzIGFy
  >> "!B64TMP!" echo ZSBoYW5kbGVkIGZvciB5b3U6IHRoZSBzY3JpcHRzIHN0YXJ0IHRoZSBEb2NrZXIgZW5naW5lCiAg
  >> "!B64TMP!" echo YW5kIHRoZSBjb250YWluZXJzIGF1dG9tYXRpY2FsbHksIHdhaXQgdW50aWwgdGhleSBhbnN3ZXIs
  >> "!B64TMP!" echo IGFuZCByZXRyeSB0aGUKICByZXF1ZXN0IG9uY2UuIE9ubHkgaWYgYSBzY3JpcHQgcmVwb3J0cyBp
  >> "!B64TMP!" echo dCBjb3VsZCBub3QgbGF1bmNoIHRoZSBlbmdpbmUgYXQKICBhbGwgKG9yIHRoZSBzdGFjayBkaWQg
  >> "!B64TMP!" echo bm90IGJlY29tZSByZWFkeSkgc2hvdWxkIHlvdSBhc2sgdGhlIHVzZXIgdG8gc3RhcnQKICBEb2Nr
  >> "!B64TMP!" echo ZXIgRGVza3RvcCBtYW51YWxseSwgdGhlbiByZXRyeS4KLSAqKkRvIG5vdCBmYWxsIGJhY2sgdG8g
  >> "!B64TMP!" echo YnVpbHQtaW4gb3IgYWx0ZXJuYXRpdmUgd2ViIHRvb2xzKiogd2hlbiB0aGlzIHN0YWNrCiAgaGFz
  >> "!B64TMP!" echo IGEgcHJvYmxlbSDigJQgZml4IHRoZSBzdGFjayAob3IgYXNrIHRoZSB1c2VyKSBhbmQgcmV0cnks
  >> "!B64TMP!" echo IHVubGVzcyB0aGUgdXNlcgogIGV4cGxpY2l0bHkgYXNrcyBmb3IgYW4gYWx0ZXJuYXRpdmUuCi0g
  >> "!B64TMP!" echo T25seSBpZiBhIHNjcmlwdCByZXBvcnRzIGl0IGNvdWxkIG5vdCBmaW5kIHRoZSBsb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2ggaW5zdGFsbAogIGZvbGRlcjogYXNrIHRoZSB1c2VyIHdoZXJlIHRoYXQgZm9sZGVyIGlzLCB0
  >> "!B64TMP!" echo aGVuIHJlLXJ1biB0aGUgc2NyaXB0IHdpdGgKICBgTE9DQUxfU0VBUkNIX0RJUj08dGhhdCBwYXRo
  >> "!B64TMP!" echo PmAuIERvbid0IGRvIHRoaXMgcHJlZW1wdGl2ZWx5IOKAlCB0aGUgZm9sZGVyIGlzCiAgbm9ybWFs
  >> "!B64TMP!" echo bHkgZGV0ZWN0ZWQgYXV0b21hdGljYWxseSAoZnJvbSB0aGUgY29tcG9zZSBsYWJlbCBvbiB0aGUg
  >> "!B64TMP!" echo cnVubmluZwogIGNvbnRhaW5lcnMsIHRoZSBwYXRoIHJlY29yZGVkIGJ5IHRoZSBsb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2ggaW5zdGFsbGVyLCBvciBmcm9tCiAgfi9sb2NhbC1zZWFyY2gpLgotIFNjcmFwZSBvdXRwdXQg
  >> "!B64TMP!" echo aXMgbG9uZy4gRXh0cmFjdCBvbmx5IHRoZSBwYXJ0cyB5b3UgbmVlZCBmb3IgdGhlIGFuc3dlcjsg
  >> "!B64TMP!" echo ZG9uJ3QKICBwYXN0ZSB3aG9sZSBwYWdlcyBiYWNrIHRvIHRoZSB1c2VyLgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\SKILL.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/scripts/config.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web\scripts\config.py" (
  copy /Y "!SRC!\local-web\scripts\config.py" "!TARGET!\local-web\scripts\config.py" >nul 2>&1
  if exist "!TARGET!\local-web\scripts\config.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/scripts/config.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS181580220.b64"
  > "!B64TMP!" echo IiIiU2hhcmVkIGhlbHBlcnMgZm9yIHRoZSBsb2NhbC13ZWIgc2NyaXB0czogbG9jYXRpbmcgdGhl
  >> "!B64TMP!" echo IGxvY2FsLXNlYXJjaAppbnN0YWxsIGZvbGRlciBhbmQgdGhlIGVuZHBvaW50cyBpdCBpcyBhY3R1
  >> "!B64TMP!" echo YWxseSBsaXN0ZW5pbmcgb24uCgpUaGUgcG9ydHMgYXJlIE5PVCBhc3N1bWVkOiB0aGV5IGFyZSBy
  >> "!B64TMP!" echo ZWFkIGZyb20gdGhlIGluc3RhbGwgZm9sZGVyJ3MgLmVudgpmaWxlICh0aGUgc2FtZSBvbmUgdGhl
  >> "!B64TMP!" echo IGNvbXBvc2Ugc2V0dXAgYW5kIFJ1bi5iYXQgLyBVcGRhdGUuYmF0IHVzZSksIHNvIGlmCnRoZSB1
  >> "!B64TMP!" echo c2VyIHBpY2tlZCBjdXN0b20gcG9ydHMgZHVyaW5nIHNldHVwLCBldmVyeSBzY3JpcHQgZm9sbG93
  >> "!B64TMP!" echo cyB0aGVtLgpEZWZhdWx0cyBtaXJyb3IgdGhlIGNvbXBvc2UgZmlsZSdzICR7VkFSOi1kZWZhdWx0
  >> "!B64TMP!" echo fSBmYWxsYmFja3M6ClNlYXJYTkcgOTk5MCwgRmlyZWNyYXdsIDk5OTEuCiIiIgppbXBvcnQgb3MK
  >> "!B64TMP!" echo aW1wb3J0IHN1YnByb2Nlc3MKCiMgQ29tcG9zZSBmaWxlIG5hbWVzIGFjY2VwdGVkIGFzICJ0aGlz
  >> "!B64TMP!" echo IGlzIHRoZSBpbnN0YWxsIGZvbGRlciIuCl9DT01QT1NFX0ZJTEVTID0gKCJkb2NrZXItY29tcG9z
  >> "!B64TMP!" echo ZS55bWwiLCAiZG9ja2VyLWNvbXBvc2UueWFtbCIsCiAgICAgICAgICAgICAgICAgICJjb21wb3Nl
  >> "!B64TMP!" echo LnltbCIsICJjb21wb3NlLnlhbWwiKQoKIyAuZW52IGtleSAtPiBkZWZhdWx0IHBvcnQgKG1hdGNo
  >> "!B64TMP!" echo ZXMgdGhlIGRlZmF1bHRzIGluIGRvY2tlci1jb21wb3NlLnltbCkuCl9QT1JUX0tFWVMgPSB7CiAg
  >> "!B64TMP!" echo ICAic2VhcnhuZyI6ICgiU0VBUlhOR19QT1JUIiwgIjk5OTAiKSwKICAgICJmaXJlY3Jhd2wiOiAo
  >> "!B64TMP!" echo IkZJUkVDUkFXTF9QT1JUIiwgIjk5OTEiKSwKfQoKCmRlZiBfaGFzX2NvbXBvc2VfZmlsZShkKToK
  >> "!B64TMP!" echo ICAgIHJldHVybiBkIGlzIG5vdCBOb25lIGFuZCBhbnkoCiAgICAgICAgb3MucGF0aC5pc2ZpbGUo
  >> "!B64TMP!" echo b3MucGF0aC5qb2luKGQsIGYpKSBmb3IgZiBpbiBfQ09NUE9TRV9GSUxFUwogICAgKQoKCmRlZiBf
  >> "!B64TMP!" echo ZG9ja2VyX2xhYmVsZWRfaW5zdGFsbF9kaXIoKToKICAgICIiIlRoZSBpbnN0YWxsIGZvbGRlciBw
  >> "!B64TMP!" echo ZXIgdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRhaW5lcnMuIENvbXBvc2UKICAgIHRhZ3Mg
  >> "!B64TMP!" echo ZWFjaCBjb250YWluZXIgd2l0aCB0aGUgZGlyZWN0b3J5IGl0IHdhcyBzdGFydGVkIGZyb20sIHNv
  >> "!B64TMP!" echo IHRoaXMKICAgIGZpbmRzIHRoZSBmb2xkZXIgZXZlbiB0aG91Z2ggdGhlIHNraWxsIGl0c2VsZiBs
  >> "!B64TMP!" echo aXZlcyBlbHNld2hlcmUuIFRoZQogICAgRG9ja2VyIGVuZ2luZSBtdXN0IGJlIHJ1bm5pbmcuIiIi
  >> "!B64TMP!" echo CiAgICB0cnk6CiAgICAgICAgcmVzID0gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgIFsiZG9j
  >> "!B64TMP!" echo a2VyIiwgImNvbnRhaW5lciIsICJscyIsICItYSIsICItcSIsCiAgICAgICAgICAgICAiLS1maWx0
  >> "!B64TMP!" echo ZXIiLCAibGFiZWw9Y29tLmRvY2tlci5jb21wb3NlLnNlcnZpY2U9c2VhcnhuZyJdLAogICAgICAg
  >> "!B64TMP!" echo ICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCB0
  >> "!B64TMP!" echo ZXh0PVRydWUpCiAgICAgICAgaWRzID0gcmVzLnN0ZG91dC5zcGxpdCgpWzozXQogICAgZXhjZXB0
  >> "!B64TMP!" echo IChPU0Vycm9yLCBGaWxlTm90Rm91bmRFcnJvcik6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIGZv
  >> "!B64TMP!" echo ciBjaWQgaW4gaWRzOgogICAgICAgIHRyeToKICAgICAgICAgICAgb3V0ID0gc3VicHJvY2Vzcy5y
  >> "!B64TMP!" echo dW4oCiAgICAgICAgICAgICAgICBbImRvY2tlciIsICJjb250YWluZXIiLCAiaW5zcGVjdCIsIGNp
  >> "!B64TMP!" echo ZCwKICAgICAgICAgICAgICAgICAiLS1mb3JtYXQiLAogICAgICAgICAgICAgICAgICd7e2luZGV4
  >> "!B64TMP!" echo IC5Db25maWcuTGFiZWxzICJjb20uZG9ja2VyLmNvbXBvc2UucHJvamVjdC53b3JraW5nX2RpciJ9
  >> "!B64TMP!" echo fSddLAogICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuUElQRSwgc3RkZXJyPXN1YnBy
  >> "!B64TMP!" echo b2Nlc3MuREVWTlVMTCwgdGV4dD1UcnVlKQogICAgICAgIGV4Y2VwdCAoT1NFcnJvciwgRmlsZU5v
  >> "!B64TMP!" echo dEZvdW5kRXJyb3IpOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIHAgPSBvdXQuc3Rkb3V0
  >> "!B64TMP!" echo LnN0cmlwKCkKICAgICAgICBpZiBwIGFuZCBvcy5wYXRoLmlzZGlyKHApOgogICAgICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gcAogICAgcmV0dXJuIE5vbmUKCgpkZWYgX2hpbnRlZF9pbnN0YWxsX2RpcigpOgogICAg
  >> "!B64TMP!" echo IiIiVGhlIGluc3RhbGwgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9jYWwtc2VhcmNoIGluc3RhbGxl
  >> "!B64TMP!" echo ciB3aGVuIGl0CiAgICBjb3BpZWQgdGhpcyBza2lsbCAoaW5zdGFsbC1kaXIudHh0IG5leHQgdG8g
  >> "!B64TMP!" echo U0tJTEwubWQpLiBUaGlzIHdvcmtzIGV2ZW4KICAgIHdoZW4gdGhlIERvY2tlciBlbmdpbmUgaXMg
  >> "!B64TMP!" echo ZG93biBhbmQgdGhlIGluc3RhbGwgZm9sZGVyIGlzIG5vdCBpbiB0aGUKICAgIGRlZmF1bHQgbG9j
  >> "!B64TMP!" echo YXRpb24uIFJldHVybnMgTm9uZSB3aGVuIHRoZXJlIGlzIG5vIGhpbnQgZmlsZSAoZS5nLiB0aGUK
  >> "!B64TMP!" echo ICAgIHNraWxsIHdhcyBpbnN0YWxsZWQgc3RhbmRhbG9uZSBmcm9tIHRoZSBsb2NhbC13ZWIgcmVw
  >> "!B64TMP!" echo bykuIiIiCiAgICBoaW50X2ZpbGUgPSBvcy5wYXRoLmpvaW4ob3MucGF0aC5kaXJuYW1lKG9zLnBh
  >> "!B64TMP!" echo dGguYWJzcGF0aChfX2ZpbGVfXykpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIG9zLnBh
  >> "!B64TMP!" echo cmRpciwgImluc3RhbGwtZGlyLnR4dCIpCiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKGhpbnRf
  >> "!B64TMP!" echo ZmlsZSwgZW5jb2Rpbmc9InV0Zi04IikgYXMgZmg6CiAgICAgICAgICAgIHBhdGggPSBmaC5yZWFk
  >> "!B64TMP!" echo KCkuc3RyaXAoKS5yc3RyaXAoIlxcLyIpLnN0cmlwKCkKICAgICAgICByZXR1cm4gcGF0aCBvciBO
  >> "!B64TMP!" echo b25lCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICByZXR1cm4gTm9uZQoKCmRlZiBmaW5kX2lu
  >> "!B64TMP!" echo c3RhbGxfZGlyKCk6CiAgICAiIiJUaGUgbG9jYWwtc2VhcmNoIGluc3RhbGwgZm9sZGVyIChob2xk
  >> "!B64TMP!" echo cyB0aGUgY29tcG9zZSBmaWxlKSwgb3IgTm9uZS4KCiAgICBMb29rZWQgdXAgaW4gb3JkZXI6CiAg
  >> "!B64TMP!" echo ICAgIDEuIHRoZSBMT0NBTF9TRUFSQ0hfRElSIGVudiB2YXIgKGV4cGxpY2l0IG92ZXJyaWRlKSwK
  >> "!B64TMP!" echo ICAgICAgMi4gdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRhaW5lcnMgKGVuZ2luZSBtdXN0
  >> "!B64TMP!" echo IGJlIHJ1bm5pbmcpLAogICAgICAzLiBpbnN0YWxsLWRpci50eHQgcmVjb3JkZWQgYnkgdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCBpbnN0YWxsZXIsCiAgICAgIDQuIH4vbG9jYWwtc2VhcmNoICh0aGUgaW5zdGFs
  >> "!B64TMP!" echo bGVyJ3MgZGVmYXVsdCBsb2NhdGlvbikuCiAgICAiIiIKICAgIGZvciBkIGluIChvcy5lbnZpcm9u
  >> "!B64TMP!" echo LmdldCgiTE9DQUxfU0VBUkNIX0RJUiIpLAogICAgICAgICAgICAgIF9kb2NrZXJfbGFiZWxlZF9p
  >> "!B64TMP!" echo bnN0YWxsX2RpcigpLAogICAgICAgICAgICAgIF9oaW50ZWRfaW5zdGFsbF9kaXIoKSwKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBvcy5wYXRoLmV4cGFuZHVzZXIoIn4vbG9jYWwtc2VhcmNoIikpOgogICAgICAgIGlm
  >> "!B64TMP!" echo IGQgYW5kIF9oYXNfY29tcG9zZV9maWxlKGQpOgogICAgICAgICAgICByZXR1cm4gZAogICAgcmV0
  >> "!B64TMP!" echo dXJuIE5vbmUKCgpkZWYgbG9hZF9lbnYoaW5zdGFsbF9kaXIpOgogICAgIiIiVGhlIGluc3RhbGwg
  >> "!B64TMP!" echo Zm9sZGVyJ3MgLmVudiBhcyBhIGRpY3QgKGVtcHR5IGRpY3QgaWYgbWlzc2luZy9pbnZhbGlkKS4i
  >> "!B64TMP!" echo IiIKICAgIHZhbHVlcyA9IHt9CiAgICBpZiBub3QgaW5zdGFsbF9kaXI6CiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IHZhbHVlcwogICAgdHJ5OgogICAgICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4oaW5zdGFsbF9k
  >> "!B64TMP!" echo aXIsICIuZW52IiksIGVuY29kaW5nPSJ1dGYtOCIpIGFzIGZoOgogICAgICAgICAgICBmb3IgbGlu
  >> "!B64TMP!" echo ZSBpbiBmaDoKICAgICAgICAgICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpIG9yICI9IiBub3QgaW4gbGlu
  >> "!B64TMP!" echo ZToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAga2V5LCBfLCB2
  >> "!B64TMP!" echo YWwgPSBsaW5lLnBhcnRpdGlvbigiPSIpCiAgICAgICAgICAgICAgICB2YWx1ZXNba2V5LnN0cmlw
  >> "!B64TMP!" echo KCldID0gdmFsLnN0cmlwKCkuc3RyaXAoJyInKS5zdHJpcCgiJyIpCiAgICBleGNlcHQgT1NFcnJv
  >> "!B64TMP!" echo cjoKICAgICAgICBwYXNzCiAgICByZXR1cm4gdmFsdWVzCgoKZGVmIGVuZHBvaW50cyhpbnN0YWxs
  >> "!B64TMP!" echo X2Rpcj1Ob25lKToKICAgICIiInsnc2VhcnhuZyc6ICdodHRwOi8vbG9jYWxob3N0Ojxwb3J0Pics
  >> "!B64TMP!" echo ICdmaXJlY3Jhd2wnOiAnLi4uJ30sIHdpdGggdGhlCiAgICBwb3J0cyB0YWtlbiBmcm9tIHRoZSBp
  >> "!B64TMP!" echo bnN0YWxsIGZvbGRlcidzIC5lbnYgKGRlZmF1bHRzIDk5OTAvOTk5MSkuIiIiCiAgICB2YWx1ZXMg
  >> "!B64TMP!" echo PSBsb2FkX2VudihpbnN0YWxsX2RpcikKICAgIHVybHMgPSB7fQogICAgZm9yIG5hbWUsIChrZXks
  >> "!B64TMP!" echo IGRlZmF1bHQpIGluIF9QT1JUX0tFWVMuaXRlbXMoKToKICAgICAgICBwb3J0ID0gdmFsdWVzLmdl
  >> "!B64TMP!" echo dChrZXkpCiAgICAgICAgaWYgbm90IHBvcnQgb3Igbm90IHBvcnQuaXNkaWdpdCgpOgogICAgICAg
  >> "!B64TMP!" echo ICAgICBwb3J0ID0gZGVmYXVsdAogICAgICAgIHVybHNbbmFtZV0gPSAiaHR0cDovL2xvY2FsaG9z
  >> "!B64TMP!" echo dDp7fSIuZm9ybWF0KHBvcnQpCiAgICByZXR1cm4gdXJscwo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\scripts\config.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/scripts/ensure_stack.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web\scripts\ensure_stack.py" (
  copy /Y "!SRC!\local-web\scripts\ensure_stack.py" "!TARGET!\local-web\scripts\ensure_stack.py" >nul 2>&1
  if exist "!TARGET!\local-web\scripts\ensure_stack.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/scripts/ensure_stack.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS58012418.b64"
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
  >> "!B64TMP!" echo aW1wb3J0IHVybGxpYi5yZXF1ZXN0CgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1l
  >> "!B64TMP!" echo KG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgY29uZmlnICAjIHNpYmxpbmcgbW9k
  >> "!B64TMP!" echo dWxlOiBpbnN0YWxsLWRpciBsb29rdXAgKyAuZW52LWRyaXZlbiBlbmRwb2ludHMKClJFQURZX1RJ
  >> "!B64TMP!" echo TUVPVVQgPSBpbnQob3MuZW52aXJvbi5nZXQoIkxPQ0FMX1NFQVJDSF9SRUFEWV9USU1FT1VUIiwg
  >> "!B64TMP!" echo IjI0MCIpIG9yIDI0MCkKUE9MTF9FVkVSWSA9IDMKRElTUExBWSA9IHsic2VhcnhuZyI6ICJTZWFy
  >> "!B64TMP!" echo WE5HIiwgImZpcmVjcmF3bCI6ICJGaXJlY3Jhd2wifQoKCmRlZiBlbmRwb2ludF91cCh1cmwsIHRp
  >> "!B64TMP!" echo bWVvdXQ9NCk6CiAgICAiIiJUcnVlIGlmIHRoZSBlbmRwb2ludCBhY2NlcHRzIGNvbm5lY3Rpb25z
  >> "!B64TMP!" echo IChhbnkgSFRUUCBzdGF0dXMgY291bnRzKS4iIiIKICAgIHJlcSA9IHVybGxpYi5yZXF1ZXN0LlJl
  >> "!B64TMP!" echo cXVlc3QodXJsLCBoZWFkZXJzPXsiVXNlci1BZ2VudCI6ICJ6Y29kZS1sb2NhbC13ZWIvMS4wIn0p
  >> "!B64TMP!" echo CiAgICB0cnk6CiAgICAgICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGltZW91
  >> "!B64TMP!" echo dD10aW1lb3V0KToKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgIGV4Y2VwdCB1cmxsaWIuZXJy
  >> "!B64TMP!" echo b3IuSFRUUEVycm9yOgogICAgICAgIHJldHVybiBUcnVlICAjIGdvdCBhbiBIVFRQIHJlc3BvbnNl
  >> "!B64TMP!" echo IChldmVuIDR4eC81eHgpID0gc2VydmljZSBpcyB1cAogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gRmFsc2UgICMgY29ubmVjdGlvbiByZWZ1c2VkIC8gcmVzZXQgLyB0aW1lb3V0
  >> "!B64TMP!" echo ID0gZG93bgoKCmRlZiBwb3J0X29mKHVybCk6CiAgICByZXR1cm4gdXJsLnJzcGxpdCgiOiIsIDEp
  >> "!B64TMP!" echo WzFdCgoKZGVmIHN0YXR1cyhlbmRwb2ludHMpOgogICAgcmV0dXJuIHtuYW1lOiBlbmRwb2ludF91
  >> "!B64TMP!" echo cCh1cmwpIGZvciBuYW1lLCB1cmwgaW4gZW5kcG9pbnRzLml0ZW1zKCl9CgoKZGVmIHJlYWR5X21l
  >> "!B64TMP!" echo c3NhZ2UoZW5kcG9pbnRzKToKICAgIHJldHVybiAiU3RhY2sgaXMgcmVhZHkgKFNlYXJYTkcgOnsw
  >> "!B64TMP!" echo fSwgRmlyZWNyYXdsIDp7MX0pLiIuZm9ybWF0KAogICAgICAgIHBvcnRfb2YoZW5kcG9pbnRzWyJz
  >> "!B64TMP!" echo ZWFyeG5nIl0pLCBwb3J0X29mKGVuZHBvaW50c1siZmlyZWNyYXdsIl0pKQoKCmRlZiBjb21wb3Nl
  >> "!B64TMP!" echo X2NvbW1hbmQoKToKICAgIGlmIHNodXRpbC53aGljaCgiZG9ja2VyIik6CiAgICAgICAgcmMgPSBz
  >> "!B64TMP!" echo dWJwcm9jZXNzLnJ1bigKICAgICAgICAgICAgWyJkb2NrZXIiLCAiY29tcG9zZSIsICJ2ZXJzaW9u
  >> "!B64TMP!" echo Il0sCiAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9j
  >> "!B64TMP!" echo ZXNzLkRFVk5VTEwsCiAgICAgICAgKQogICAgICAgIGlmIHJjLnJldHVybmNvZGUgPT0gMDoKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIFsiZG9ja2VyIiwgImNvbXBvc2UiXQogICAgaWYgc2h1dGlsLndoaWNo
  >> "!B64TMP!" echo KCJkb2NrZXItY29tcG9zZSIpOgogICAgICAgIHJldHVybiBbImRvY2tlci1jb21wb3NlIl0KICAg
  >> "!B64TMP!" echo IHJldHVybiBOb25lCgoKZGVmIGRvY2tlcl9lbmdpbmVfdXAoKToKICAgIHRyeToKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgIFsiZG9ja2VyIiwgImluZm8iXSwKICAg
  >> "!B64TMP!" echo ICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nlc3MuREVW
  >> "!B64TMP!" echo TlVMTCwKICAgICAgICApLnJldHVybmNvZGUgPT0gMAogICAgZXhjZXB0IChPU0Vycm9yLCBGaWxl
  >> "!B64TMP!" echo Tm90Rm91bmRFcnJvcik6CiAgICAgICAgcmV0dXJuIEZhbHNlCgoKZGVmIGZpbmRfZG9ja2VyX2Rl
  >> "!B64TMP!" echo c2t0b3BfZXhlKCk6CiAgICBjYW5kaWRhdGVzID0gWwogICAgICAgIHIiQzpcUHJvZ3JhbSBGaWxl
  >> "!B64TMP!" echo c1xEb2NrZXJcRG9ja2VyXERvY2tlciBEZXNrdG9wLmV4ZSIsCiAgICAgICAgb3MucGF0aC5leHBh
  >> "!B64TMP!" echo bmR2YXJzKHIiJUxPQ0FMQVBQREFUQSVcUHJvZ3JhbXNcRG9ja2VyIERlc2t0b3BcRG9ja2VyIERl
  >> "!B64TMP!" echo c2t0b3AuZXhlIiksCiAgICBdCiAgICBmb3IgcCBpbiBjYW5kaWRhdGVzOgogICAgICAgIGlmIG9z
  >> "!B64TMP!" echo LnBhdGguaXNmaWxlKHApOgogICAgICAgICAgICByZXR1cm4gcAogICAgcmV0dXJuIE5vbmUKCgpk
  >> "!B64TMP!" echo ZWYgc3RhcnRfZG9ja2VyX2VuZ2luZSgpOgogICAgIiIiVHJ5IHRvIGxhdW5jaCB0aGUgRG9ja2Vy
  >> "!B64TMP!" echo IGVuZ2luZSBmb3IgdGhpcyBPUy4gVHJ1ZSBpZiB0aGUgbGF1bmNoIHdhcwogICAgaW5pdGlhdGVk
  >> "!B64TMP!" echo IChub3QgdGhhdCBpdCBiZWNhbWUgcmVhZHkg4oCUIHRoYXQncyB3YWl0X2Zvcl9lbmdpbmUncyBq
  >> "!B64TMP!" echo b2IpLiIiIgogICAgaW1wb3J0IHBsYXRmb3JtCiAgICBzeXN0ZW0gPSBwbGF0Zm9ybS5zeXN0ZW0o
  >> "!B64TMP!" echo KQogICAgaWYgc3lzdGVtID09ICJXaW5kb3dzIjoKICAgICAgICBleGUgPSBmaW5kX2RvY2tlcl9k
  >> "!B64TMP!" echo ZXNrdG9wX2V4ZSgpCiAgICAgICAgaWYgbm90IGV4ZToKICAgICAgICAgICAgcmV0dXJuIEZhbHNl
  >> "!B64TMP!" echo CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzdWJwcm9jZXNzLlBvcGVuKFtleGVdLAogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1z
  >> "!B64TMP!" echo dWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgZXhjZXB0
  >> "!B64TMP!" echo IE9TRXJyb3I6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgc3lzdGVtID09ICJEYXJ3
  >> "!B64TMP!" echo aW4iOgogICAgICAgIHRyeToKICAgICAgICAgICAgc3VicHJvY2Vzcy5Qb3BlbihbIm9wZW4iLCAi
  >> "!B64TMP!" echo LS1iYWNrZ3JvdW5kIiwgIi1hIiwgIkRvY2tlciJdLAogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBGYWxzZQogICAgIyBMaW51eDogYmVzdCBlZmZvcnQgd2l0aG91dCBhbiBpbnRl
  >> "!B64TMP!" echo cmFjdGl2ZSBwYXNzd29yZCBwcm9tcHQuCiAgICB0cnk6CiAgICAgICAgaWYgaGFzYXR0cihvcywg
  >> "!B64TMP!" echo ImdldGV1aWQiKSBhbmQgb3MuZ2V0ZXVpZCgpID09IDA6CiAgICAgICAgICAgIHJldHVybiBzdWJw
  >> "!B64TMP!" echo cm9jZXNzLnJ1bihbInN5c3RlbWN0bCIsICJzdGFydCIsICJkb2NrZXIiXSwKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKS5yZXR1
  >> "!B64TMP!" echo cm5jb2RlID09IDAKICAgICAgICByZXR1cm4gc3VicHJvY2Vzcy5ydW4oWyJzdWRvIiwgIi1uIiwg
  >> "!B64TMP!" echo InN5c3RlbWN0bCIsICJzdGFydCIsICJkb2NrZXIiXSwKICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwKICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCkucmV0dXJuY29kZSA9PSAwCiAgICBleGNl
  >> "!B64TMP!" echo cHQgKE9TRXJyb3IsIEZpbGVOb3RGb3VuZEVycm9yKToKICAgICAgICByZXR1cm4gRmFsc2UKCgpk
  >> "!B64TMP!" echo ZWYgd2FpdF9mb3JfZW5naW5lKHRpbWVvdXQ9MTgwKToKICAgIGRlYWRsaW5lID0gdGltZS50aW1l
  >> "!B64TMP!" echo KCkgKyB0aW1lb3V0CiAgICB3aGlsZSB0aW1lLnRpbWUoKSA8IGRlYWRsaW5lOgogICAgICAgIGlm
  >> "!B64TMP!" echo IGRvY2tlcl9lbmdpbmVfdXAoKToKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICB0aW1l
  >> "!B64TMP!" echo LnNsZWVwKDMpCiAgICByZXR1cm4gRmFsc2UKCgpkZWYgZW5zdXJlX3JlYWR5KGNoZWNrX29ubHk9
  >> "!B64TMP!" echo RmFsc2UsIHJlYWR5X3RpbWVvdXQ9Tm9uZSwgcG9sbF9ldmVyeT1Ob25lKToKICAgICIiIkJyaW5n
  >> "!B64TMP!" echo IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgdG8gYSByZWFkeSBzdGF0ZS4gTkVWRVIgc3RvcHMgaXQu
  >> "!B64TMP!" echo CgogICAgUmV0dXJucyAob2ssIG1lc3NhZ2UsIGV4aXRfY29kZSk6CiAgICAgICAgb2sgICAgICAg
  >> "!B64TMP!" echo ICBUcnVlIHdoZW4gYm90aCBlbmRwb2ludHMgYW5zd2VyLgogICAgICAgIG1lc3NhZ2UgICAgaHVt
  >> "!B64TMP!" echo YW4tcmVhZGFibGUgc3RhdHVzIC8gZ3VpZGFuY2UgKHByb2dyZXNzIGlzIHByaW50ZWQgdG8KICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHN0ZGVyciBhbG9uZyB0aGUgd2F5KS4KICAgICAgICBleGl0X2NvZGUg
  >> "!B64TMP!" echo IDAgcmVhZHksIDEgZG93bi9jb3VsZCBub3QgYnJpbmcgdXAsIDIgcHJlcmVxdWlzaXRlcwogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgbWlzc2luZyAobWF0Y2hlcyB0aGUgQ0xJIGV4aXQgY29kZXMpLgogICAg
  >> "!B64TMP!" echo IiIiCiAgICBpZiByZWFkeV90aW1lb3V0IGlzIE5vbmU6CiAgICAgICAgcmVhZHlfdGltZW91dCA9
  >> "!B64TMP!" echo IFJFQURZX1RJTUVPVVQKICAgIGlmIHBvbGxfZXZlcnkgaXMgTm9uZToKICAgICAgICBwb2xsX2V2
  >> "!B64TMP!" echo ZXJ5ID0gUE9MTF9FVkVSWQoKICAgIGVuZHBvaW50cyA9IGNvbmZpZy5lbmRwb2ludHMoY29uZmln
  >> "!B64TMP!" echo LmZpbmRfaW5zdGFsbF9kaXIoKSkKICAgIHN0ID0gc3RhdHVzKGVuZHBvaW50cykKICAgIGlmIGFs
  >> "!B64TMP!" echo bChzdC52YWx1ZXMoKSk6CiAgICAgICAgcmV0dXJuIFRydWUsIHJlYWR5X21lc3NhZ2UoZW5kcG9p
  >> "!B64TMP!" echo bnRzKSwgMAoKICAgIHByaW50KCJMb2NhbC1zZWFyY2ggc3RhY2sgaXMgRE9XTjoiLCBmaWxlPXN5
  >> "!B64TMP!" echo cy5zdGRlcnIpCiAgICBmb3IgbmFtZSwgdXJsIGluIGVuZHBvaW50cy5pdGVtcygpOgogICAgICAg
  >> "!B64TMP!" echo IG1hcmsgPSAiT0sgICIgaWYgc3RbbmFtZV0gZWxzZSAiRE9XTiIKICAgICAgICBwcmludChmIiAg
  >> "!B64TMP!" echo W3ttYXJrfV0ge0RJU1BMQVlbbmFtZV19IDp7cG9ydF9vZih1cmwpfSIsIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgIGlmIGNoZWNrX29ubHk6CiAgICAgICAgcmV0dXJuIEZhbHNlLCAiU3RhY2sgaXMgZG93
  >> "!B64TMP!" echo biAoLS1jaGVjazogbm90aGluZyB3YXMgc3RhcnRlZCkuIiwgMQoKICAgIGlmIG5vdCBkb2NrZXJf
  >> "!B64TMP!" echo ZW5naW5lX3VwKCk6CiAgICAgICAgcHJpbnQoIkRvY2tlciBlbmdpbmUgaXMgbm90IHJ1bm5pbmcg
  >> "!B64TMP!" echo 4oCUIHRyeWluZyB0byBzdGFydCBpdCAuLi4iLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICBpZiBub3Qgc3RhcnRfZG9ja2VyX2VuZ2luZSgpOgogICAgICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gRmFsc2UsICgiQ291bGQgbm90IHN0YXJ0IHRoZSBEb2NrZXIgZW5naW5lIGF1dG9tYXRpY2Fs
  >> "!B64TMP!" echo bHkgIgogICAgICAgICAgICAgICAgICAgICAgICAgICAiKERvY2tlciBEZXNrdG9wIG5vdCBmb3Vu
  >> "!B64TMP!" echo ZCBpbiB0aGUgdXN1YWwgbG9jYXRpb25zPykuICIKICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IlN0YXJ0IGl0IG1hbnVhbGx5LCB0aGVuIHJlLXJ1biB0aGlzIHNjcmlwdC4iKSwgMgogICAgICAg
  >> "!B64TMP!" echo IHByaW50KCJXYWl0aW5nIGZvciB0aGUgRG9ja2VyIGVuZ2luZSB0byBjb21lIHVwIC4uLiIsIGZp
  >> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICBpZiBub3Qgd2FpdF9mb3JfZW5naW5lKHRpbWVvdXQ9MTgw
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlLCAoIlRoZSBEb2NrZXIgZW5naW5lIHdhcyBsYXVu
  >> "!B64TMP!" echo Y2hlZCBidXQgZGlkIG5vdCBhbnN3ZXIgd2l0aGluICIKICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIjE4MCBzLiBDaGVjayBEb2NrZXIgRGVza3RvcCwgdGhlbiByZS1ydW4gdGhpcyBzY3JpcHQu
  >> "!B64TMP!" echo IiksIDIKCiAgICAjIFJlY29tcHV0ZWQgbm93IHRoYXQgdGhlIGVuZ2luZSBpcyB1cDogdGhlIGNv
  >> "!B64TMP!" echo bXBvc2UtbGFiZWwgbG9va3VwICh3aGljaAogICAgIyBuZWVkcyB0aGUgZW5naW5lKSBjYW4gZmlu
  >> "!B64TMP!" echo ZCB0aGUgaW5zdGFsbCBkaXIgd2hlcmUgdGhlIG90aGVyIG1ldGhvZHMKICAgICMgY291bGQgbm90
  >> "!B64TMP!" echo LgogICAgaW5zdGFsbF9kaXIgPSBjb25maWcuZmluZF9pbnN0YWxsX2RpcigpCiAgICBpZiBub3Qg
  >> "!B64TMP!" echo aW5zdGFsbF9kaXI6CiAgICAgICAgcmV0dXJuIEZhbHNlLCAoIkNvdWxkIG5vdCBmaW5kIHRoZSBs
  >> "!B64TMP!" echo b2NhbC1zZWFyY2ggaW5zdGFsbCBmb2xkZXIgIgogICAgICAgICAgICAgICAgICAgICAgICIobm8g
  >> "!B64TMP!" echo ZG9ja2VyLWNvbXBvc2UueW1sIGZvdW5kKS4gQXNrIHRoZSB1c2VyIHdoZXJlIHRoZWlyICIKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAibG9jYWwtc2VhcmNoIGZvbGRlciBpcywgdGhlbiByZS1ydW4g
  >> "!B64TMP!" echo dGhpcyBzY3JpcHQgd2l0aCAiCiAgICAgICAgICAgICAgICAgICAgICAgIkxPQ0FMX1NFQVJDSF9E
  >> "!B64TMP!" echo SVIgc2V0IHRvIHRoYXQgcGF0aCwgb3Igc3RhcnQgdGhlIHN0YWNrIG1hbnVhbGx5ICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAiKFJ1bi5iYXQgLyBydW4uc2gpLiIpLCAyCgogICAgY29tcG9zZSA9
  >> "!B64TMP!" echo IGNvbXBvc2VfY29tbWFuZCgpCiAgICBpZiBub3QgY29tcG9zZToKICAgICAgICByZXR1cm4gRmFs
  >> "!B64TMP!" echo c2UsICJOZWl0aGVyICdkb2NrZXIgY29tcG9zZScgbm9yICdkb2NrZXItY29tcG9zZScgaXMgYXZh
  >> "!B64TMP!" echo aWxhYmxlLiIsIDIKCiAgICBwcmludChmIlN0YXJ0aW5nIHN0YWNrIGluIHtpbnN0YWxsX2Rpcn0g
  >> "!B64TMP!" echo Li4uIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgcHJvYyA9IHN1YnByb2Nlc3MucnVuKGNvbXBvc2Ug
  >> "!B64TMP!" echo KyBbInVwIiwgIi1kIl0sIGN3ZD1pbnN0YWxsX2RpcikKICAgIGlmIHByb2MucmV0dXJuY29kZSAh
  >> "!B64TMP!" echo PSAwOgogICAgICAgIHJldHVybiBGYWxzZSwgIidkb2NrZXIgY29tcG9zZSB1cCAtZCcgZmFpbGVk
  >> "!B64TMP!" echo IOKAlCBzZWUgb3V0cHV0IGFib3ZlLiIsIDEKCiAgICBwcmludCgiV2FpdGluZyBmb3IgZW5kcG9p
  >> "!B64TMP!" echo bnRzIC4uLiIsIGZpbGU9c3lzLnN0ZGVycikKICAgIGRlYWRsaW5lID0gdGltZS50aW1lKCkgKyBy
  >> "!B64TMP!" echo ZWFkeV90aW1lb3V0CiAgICB3aGlsZSB0aW1lLnRpbWUoKSA8IGRlYWRsaW5lOgogICAgICAgIHN0
  >> "!B64TMP!" echo ID0gc3RhdHVzKGVuZHBvaW50cykKICAgICAgICBpZiBhbGwoc3QudmFsdWVzKCkpOgogICAgICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gVHJ1ZSwgcmVhZHlfbWVzc2FnZShlbmRwb2ludHMpLCAwCiAgICAgICAgdGlt
  >> "!B64TMP!" echo ZS5zbGVlcChwb2xsX2V2ZXJ5KQoKICAgIGZvciBuYW1lLCB1cmwgaW4gZW5kcG9pbnRzLml0ZW1z
  >> "!B64TMP!" echo KCk6CiAgICAgICAgbWFyayA9ICJPSyAgIiBpZiBzdFtuYW1lXSBlbHNlICJET1dOIgogICAgICAg
  >> "!B64TMP!" echo IHByaW50KGYiICBbe21hcmt9XSB7RElTUExBWVtuYW1lXX0gOntwb3J0X29mKHVybCl9IiwgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgcmV0dXJuIEZhbHNlLCAoZiJTdGFjayBkaWQgbm90IGJlY29tZSBy
  >> "!B64TMP!" echo ZWFkeSB3aXRoaW4ge3JlYWR5X3RpbWVvdXR9cy4gSW5zcGVjdCB3aXRoOlxuIgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZiIgICAgY2Qge2luc3RhbGxfZGlyfSAmJiBkb2NrZXIgY29tcG9zZSBsb2dzIC0t
  >> "!B64TMP!" echo dGFpbCA1MCIpLCAxCgoKZGVmIG1haW4oKToKICAgIGFwID0gYXJncGFyc2UuQXJndW1lbnRQYXJz
  >> "!B64TMP!" echo ZXIoZGVzY3JpcHRpb249IkVuc3VyZSB0aGUgbG9jYWwtc2VhcmNoIERvY2tlciBzdGFjayBpcyBy
  >> "!B64TMP!" echo dW5uaW5nLiIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tY2hlY2siLCBhY3Rpb249InN0b3JlX3Ry
  >> "!B64TMP!" echo dWUiLAogICAgICAgICAgICAgICAgICAgIGhlbHA9Im9ubHkgcmVwb3J0IHN0YXR1czsgbmV2ZXIg
  >> "!B64TMP!" echo c3RhcnQgYW55dGhpbmciKQogICAgYXJncyA9IGFwLnBhcnNlX2FyZ3MoKQoKICAgIG9rLCBtZXNz
  >> "!B64TMP!" echo YWdlLCBjb2RlID0gZW5zdXJlX3JlYWR5KGNoZWNrX29ubHk9YXJncy5jaGVjaykKICAgIGlmIG9r
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KG1lc3NhZ2UpCiAgICAgICAgcmV0dXJuIDAKICAgIHByaW50KG1lc3Nh
  >> "!B64TMP!" echo Z2UsIGZpbGU9c3lzLnN0ZGVycikKICAgIHJldHVybiBjb2RlCgoKaWYgX19uYW1lX18gPT0gIl9f
  >> "!B64TMP!" echo bWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\scripts\ensure_stack.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/scripts/web_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web\scripts\web_search.py" (
  copy /Y "!SRC!\local-web\scripts\web_search.py" "!TARGET!\local-web\scripts\web_search.py" >nul 2>&1
  if exist "!TARGET!\local-web\scripts\web_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/scripts/web_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2237991872.b64"
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
  >> "!B64TMP!" echo dXJsbGliLnBhcnNlCmltcG9ydCB1cmxsaWIucmVxdWVzdAoKc3lzLnBhdGguaW5zZXJ0KDAsIG9z
  >> "!B64TMP!" echo LnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZpZyAg
  >> "!B64TMP!" echo IyBzaWJsaW5nIG1vZHVsZTogaW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5kcG9p
  >> "!B64TMP!" echo bnRzCgojIFBvcnQgY29tZXMgZnJvbSBTRUFSWE5HX1BPUlQgaW4gdGhlIGluc3RhbGwgZm9sZGVy
  >> "!B64TMP!" echo J3MgLmVudiAoZGVmYXVsdCA5OTkwKS4KQkFTRSA9IGNvbmZpZy5lbmRwb2ludHMoY29uZmlnLmZp
  >> "!B64TMP!" echo bmRfaW5zdGFsbF9kaXIoKSlbInNlYXJ4bmciXSArICIvc2VhcmNoIgoKVElNRU9VVCA9IDMwICAj
  >> "!B64TMP!" echo IHNlY29uZHMgcGVyIEhUVFAgYXR0ZW1wdAoKCmRlZiBmZXRjaCh1cmwpOgogICAgIiIiR0VUIHRo
  >> "!B64TMP!" echo ZSBTZWFyWE5HIEpTT04gQVBJLiBSYWlzZXMgSFRUUEVycm9yIHdoZW4gdGhlIHNlcnZpY2UgYW5z
  >> "!B64TMP!" echo d2VyZWQKICAgIHdpdGggYW4gZXJyb3Igc3RhdHVzIChzZXJ2aWNlIGlzIFVQKSwgVVJMRXJyb3It
  >> "!B64TMP!" echo ZmFtaWx5IG9uIGNvbm5lY3Rpb24KICAgIHByb2JsZW1zIChzZXJ2aWNlIGlzIERPV04pLiIiIgog
  >> "!B64TMP!" echo ICAgcmVxID0gdXJsbGliLnJlcXVlc3QuUmVxdWVzdCh1cmwsIGhlYWRlcnM9eyJVc2VyLUFnZW50
  >> "!B64TMP!" echo IjogInpjb2RlLWxvY2FsLXdlYi8xLjAifSkKICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3Bl
  >> "!B64TMP!" echo bihyZXEsIHRpbWVvdXQ9VElNRU9VVCkgYXMgcjoKICAgICAgICByZXR1cm4ganNvbi5sb2FkKHIp
  >> "!B64TMP!" echo CgoKZGVmIHNlbGZoZWFsKCk6CiAgICAiIiJTdGFydCB0aGUgRG9ja2VyIGVuZ2luZSArIHRoZSBj
  >> "!B64TMP!" echo b250YWluZXJzIGlmIHRoZXkgYXJlIGRvd24gKHRoZSBzYW1lCiAgICBsb2dpYyBhcyBlbnN1cmVf
  >> "!B64TMP!" echo c3RhY2sucHkpLiBJbXBvcnQgaXMgZGVmZXJyZWQgc28gdGhlIGZhc3QgcGF0aCAoc3RhY2sKICAg
  >> "!B64TMP!" echo IGFscmVhZHkgdXApIHBheXMgbm90aGluZy4gUmV0dXJucyAob2ssIG1lc3NhZ2UpLiIiIgogICAg
  >> "!B64TMP!" echo dHJ5OgogICAgICAgIGltcG9ydCBlbnN1cmVfc3RhY2sKICAgICAgICBvaywgbWVzc2FnZSwgX2Nv
  >> "!B64TMP!" echo ZGUgPSBlbnN1cmVfc3RhY2suZW5zdXJlX3JlYWR5KCkKICAgICAgICByZXR1cm4gb2ssIG1lc3Nh
  >> "!B64TMP!" echo Z2UKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgdW5leHBlY3RlZCBzZWxmLWhlYWwgZmFp
  >> "!B64TMP!" echo bHVyZTogZGVncmFkZSBncmFjZWZ1bGx5CiAgICAgICAgcmV0dXJuIEZhbHNlLCAic2VsZi1oZWFs
  >> "!B64TMP!" echo IGZhaWxlZCB1bmV4cGVjdGVkbHk6IHt9Ii5mb3JtYXQoZSkKCgpkZWYgbWFpbigpIC0+IGludDoK
  >> "!B64TMP!" echo ICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGxpbWl0LCB0aW1lX3JhbmdlLCBjYXRlZ29yaWVz
  >> "!B64TMP!" echo ID0gOCwgTm9uZSwgTm9uZQogICAgcXVlcnlfcGFydHMgPSBbXQogICAgaSA9IDAKICAgIHdoaWxl
  >> "!B64TMP!" echo IGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAgICBpZiBhID09ICItLWxp
  >> "!B64TMP!" echo bWl0IjoKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGxpbWl0ID0gaW50KGFyZ3NbaV0p
  >> "!B64TMP!" echo CiAgICAgICAgZWxpZiBhID09ICItLXRpbWUtcmFuZ2UiOgogICAgICAgICAgICBpICs9IDEKICAg
  >> "!B64TMP!" echo ICAgICAgICAgdGltZV9yYW5nZSA9IGFyZ3NbaV0KICAgICAgICBlbGlmIGEgPT0gIi0tY2F0ZWdv
  >> "!B64TMP!" echo cmllcyI6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBjYXRlZ29yaWVzID0gYXJnc1tp
  >> "!B64TMP!" echo XQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgICAgICBwcmludChmInVu
  >> "!B64TMP!" echo a25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAy
  >> "!B64TMP!" echo CiAgICAgICAgZWxzZToKICAgICAgICAgICAgcXVlcnlfcGFydHMuYXBwZW5kKGEpCiAgICAgICAg
  >> "!B64TMP!" echo aSArPSAxCiAgICBxdWVyeSA9ICIgIi5qb2luKHF1ZXJ5X3BhcnRzKS5zdHJpcCgpCiAgICBpZiBu
  >> "!B64TMP!" echo b3QgcXVlcnk6CiAgICAgICAgcHJpbnQoJ3VzYWdlOiB3ZWJfc2VhcmNoLnB5ICJxdWVyeSIgWy0t
  >> "!B64TMP!" echo bGltaXQgTl0gWy0tdGltZS1yYW5nZSBSXSBbLS1jYXRlZ29yaWVzIENdJywgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgIHJldHVybiAyCgogICAgcGFyYW1zID0geyJxIjogcXVlcnksICJmb3JtYXQi
  >> "!B64TMP!" echo OiAianNvbiIsICJsYW5ndWFnZSI6ICJlbiJ9CiAgICBpZiB0aW1lX3JhbmdlOgogICAgICAgIHBh
  >> "!B64TMP!" echo cmFtc1sidGltZV9yYW5nZSJdID0gdGltZV9yYW5nZQogICAgaWYgY2F0ZWdvcmllczoKICAgICAg
  >> "!B64TMP!" echo ICBwYXJhbXNbImNhdGVnb3JpZXMiXSA9IGNhdGVnb3JpZXMKICAgIHVybCA9IEJBU0UgKyAiPyIg
  >> "!B64TMP!" echo KyB1cmxsaWIucGFyc2UudXJsZW5jb2RlKHBhcmFtcykKCiAgICBkYXRhID0gTm9uZQogICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgIGRhdGEgPSBmZXRjaCh1cmwpCiAgICBleGNlcHQgdXJsbGliLmVycm9yLkhUVFBF
  >> "!B64TMP!" echo cnJvciBhcyBlOgogICAgICAgICMgVGhlIHNlcnZpY2UgQU5TV0VSRUQgKGV2ZW4gd2l0aCBhbiBl
  >> "!B64TMP!" echo cnJvciBzdGF0dXMpIC0+IGl0IGlzIHVwOwogICAgICAgICMgc3RhcnRpbmcgY29udGFpbmVycyB3
  >> "!B64TMP!" echo b3VsZCBub3QgaGVscC4KICAgICAgICBwcmludChmIlNFQVJDSCBGQUlMRUQ6IHtlfSIsIGZpbGU9
  >> "!B64TMP!" echo c3lzLnN0ZGVycikKICAgICAgICBwcmludCgiU2VhclhORyBhbnN3ZXJlZCB3aXRoIGFuIGVycm9y
  >> "!B64TMP!" echo IHN0YXR1cyAodGhlIHN0YWNrIGlzIHJ1bm5pbmcpLiAiCiAgICAgICAgICAgICAgIlJldHJ5IG9u
  >> "!B64TMP!" echo Y2Ugd2l0aCBhIGRpZmZlcmVudCBxdWVyeSwgb3IgaW5zcGVjdCB0aGUgc3RhY2sgd2l0aDogIgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICJjZCA8aW5zdGFsbCBmb2xkZXI+ICYmIGRvY2tlciBjb21wb3NlIGxvZ3Mg
  >> "!B64TMP!" echo LS10YWlsIDUwIHNlYXJ4bmciLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMgQ29ubmVjdGlv
  >> "!B64TMP!" echo biBlcnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhlYWwgb25jZSwK
  >> "!B64TMP!" echo ICAgICAgICAjIHRoZW4gcmV0cnkgdGhlIHNlYXJjaC4KICAgICAgICBwcmludChmIlN0YWNrIHVu
  >> "!B64TMP!" echo cmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0gc2VsZmhlYWwo
  >> "!B64TMP!" echo KQogICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgICAgICBwcmludCgiU0VBUkNIIEZBSUxFRDogdGhlIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aCBzdGFjayBjb3VsZCBub3QgYmUgc3RhcnRlZC4gIgogICAgICAgICAgICAgICAgICAiUmVzb2x2
  >> "!B64TMP!" echo ZSB0aGUgc3RhY2sgKG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBEb2NrZXIgRGVza3RvcCkgIgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAiYW5kIHJldHJ5IOKAlCBkbyBOT1QgZmFsbCBiYWNrIHRvIG90aGVy
  >> "!B64TMP!" echo IHdlYiB0b29scyB1bmxlc3MgdGhlICIKICAgICAgICAgICAgICAgICAgInVzZXIgYXNrcy4iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAxCiAgICAgICAgdHJ5OgogICAgICAg
  >> "!B64TMP!" echo ICAgICBkYXRhID0gZmV0Y2godXJsKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTI6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHByaW50KGYiU0VBUkNIIEZBSUxFRCBhZnRlciB0aGUgc3RhY2sgd2FzIHN0YXJ0
  >> "!B64TMP!" echo ZWQ6IHtlMn0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAxCgogICAgcmVz
  >> "!B64TMP!" echo dWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIiwgW10pWzpsaW1pdF0KICAgIGlmIG5vdCByZXN1bHRz
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KCIobm8gcmVzdWx0cykiKQogICAgICAgIHJldHVybiAwCiAgICBmb3Ig
  >> "!B64TMP!" echo biwgaGl0IGluIGVudW1lcmF0ZShyZXN1bHRzLCAxKToKICAgICAgICB0aXRsZSA9IChoaXQuZ2V0
  >> "!B64TMP!" echo KCJ0aXRsZSIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgcmVzdWx0X3VybCA9IGhpdC5nZXQoInVy
  >> "!B64TMP!" echo bCIpIG9yICIiCiAgICAgICAgY29udGVudCA9IChoaXQuZ2V0KCJjb250ZW50Iikgb3IgIiIpLnN0
  >> "!B64TMP!" echo cmlwKCkucmVwbGFjZSgiXG4iLCAiICIpCiAgICAgICAgaWYgbGVuKGNvbnRlbnQpID4gMzAwOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBjb250ZW50ID0gY29udGVudFs6MzAwXSArICLigKYiCiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo ZiJ7bn0uIHt0aXRsZX0iKQogICAgICAgIHByaW50KGYiICAge3Jlc3VsdF91cmx9IikKICAgICAg
  >> "!B64TMP!" echo ICBpZiBjb250ZW50OgogICAgICAgICAgICBwcmludChmIiAgIHtjb250ZW50fSIpCiAgICByZXR1
  >> "!B64TMP!" echo cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\scripts\web_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/scripts/web_scrape.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web\scripts\web_scrape.py" (
  copy /Y "!SRC!\local-web\scripts\web_scrape.py" "!TARGET!\local-web\scripts\web_scrape.py" >nul 2>&1
  if exist "!TARGET!\local-web\scripts\web_scrape.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/scripts/web_scrape.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1163182510.b64"
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
  >> "!B64TMP!" echo Yi5yZXF1ZXN0CgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJz
  >> "!B64TMP!" echo cGF0aChfX2ZpbGVfXykpKQppbXBvcnQgY29uZmlnICAjIHNpYmxpbmcgbW9kdWxlOiBpbnN0YWxs
  >> "!B64TMP!" echo LWRpciBsb29rdXAgKyAuZW52LWRyaXZlbiBlbmRwb2ludHMKCiMgUG9ydCBjb21lcyBmcm9tIEZJ
  >> "!B64TMP!" echo UkVDUkFXTF9QT1JUIGluIHRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYgKGRlZmF1bHQgOTk5MSku
  >> "!B64TMP!" echo CkVORFBPSU5UID0gY29uZmlnLmVuZHBvaW50cyhjb25maWcuZmluZF9pbnN0YWxsX2RpcigpKVsi
  >> "!B64TMP!" echo ZmlyZWNyYXdsIl0gKyAiL3YxL3NjcmFwZSIKClRJTUVPVVQgPSA5MCAgIyBzZWNvbmRzIHBlciBI
  >> "!B64TMP!" echo VFRQIGF0dGVtcHQKCgpkZWYgZmV0Y2godXJsKToKICAgICIiIlBPU1QgdGhlIHNjcmFwZSByZXF1
  >> "!B64TMP!" echo ZXN0LiBSYWlzZXMgSFRUUEVycm9yIHdoZW4gdGhlIHNlcnZpY2UgYW5zd2VyZWQKICAgIHdpdGgg
  >> "!B64TMP!" echo YW4gZXJyb3Igc3RhdHVzIChzZXJ2aWNlIGlzIFVQKSwgVVJMRXJyb3ItZmFtaWx5IG9uIGNvbm5l
  >> "!B64TMP!" echo Y3Rpb24KICAgIHByb2JsZW1zIChzZXJ2aWNlIGlzIERPV04pLiIiIgogICAgYm9keSA9IGpzb24u
  >> "!B64TMP!" echo ZHVtcHMoeyJ1cmwiOiB1cmwsICJmb3JtYXRzIjogWyJtYXJrZG93biJdfSkuZW5jb2RlKCkKICAg
  >> "!B64TMP!" echo IHJlcSA9IHVybGxpYi5yZXF1ZXN0LlJlcXVlc3QoCiAgICAgICAgRU5EUE9JTlQsCiAgICAgICAg
  >> "!B64TMP!" echo ZGF0YT1ib2R5LAogICAgICAgIGhlYWRlcnM9eyJDb250ZW50LVR5cGUiOiAiYXBwbGljYXRpb24v
  >> "!B64TMP!" echo anNvbiIsICJVc2VyLUFnZW50IjogInpjb2RlLWxvY2FsLXdlYi8xLjAifSwKICAgICAgICBtZXRo
  >> "!B64TMP!" echo b2Q9IlBPU1QiLAogICAgKQogICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGlt
  >> "!B64TMP!" echo ZW91dD1USU1FT1VUKSBhcyByOgogICAgICAgIHJldHVybiBqc29uLmxvYWQocikKCgpkZWYgc2Vs
  >> "!B64TMP!" echo ZmhlYWwoKToKICAgICIiIlN0YXJ0IHRoZSBEb2NrZXIgZW5naW5lICsgdGhlIGNvbnRhaW5lcnMg
  >> "!B64TMP!" echo aWYgdGhleSBhcmUgZG93biAodGhlIHNhbWUKICAgIGxvZ2ljIGFzIGVuc3VyZV9zdGFjay5weSku
  >> "!B64TMP!" echo IEltcG9ydCBpcyBkZWZlcnJlZCBzbyB0aGUgZmFzdCBwYXRoIChzdGFjawogICAgYWxyZWFkeSB1
  >> "!B64TMP!" echo cCkgcGF5cyBub3RoaW5nLiBSZXR1cm5zIChvaywgbWVzc2FnZSkuIiIiCiAgICB0cnk6CiAgICAg
  >> "!B64TMP!" echo ICAgaW1wb3J0IGVuc3VyZV9zdGFjawogICAgICAgIG9rLCBtZXNzYWdlLCBfY29kZSA9IGVuc3Vy
  >> "!B64TMP!" echo ZV9zdGFjay5lbnN1cmVfcmVhZHkoKQogICAgICAgIHJldHVybiBvaywgbWVzc2FnZQogICAgZXhj
  >> "!B64TMP!" echo ZXB0IEV4Y2VwdGlvbiBhcyBlOiAgIyB1bmV4cGVjdGVkIHNlbGYtaGVhbCBmYWlsdXJlOiBkZWdy
  >> "!B64TMP!" echo YWRlIGdyYWNlZnVsbHkKICAgICAgICByZXR1cm4gRmFsc2UsICJzZWxmLWhlYWwgZmFpbGVkIHVu
  >> "!B64TMP!" echo ZXhwZWN0ZWRseToge30iLmZvcm1hdChlKQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9
  >> "!B64TMP!" echo IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIp
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX3NjcmFwZS5weSA8dXJsPiBbLS1tYXgtY2hhcnMg
  >> "!B64TMP!" echo Tl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIHVybCA9IGFyZ3NbMF0K
  >> "!B64TMP!" echo ICAgIG1heF9jaGFycyA9IDIwMDAwCiAgICBpID0gMQogICAgd2hpbGUgaSA8IGxlbihhcmdzKToK
  >> "!B64TMP!" echo ICAgICAgICBpZiBhcmdzW2ldID09ICItLW1heC1jaGFycyIgYW5kIGkgKyAxIDwgbGVuKGFyZ3Mp
  >> "!B64TMP!" echo OgogICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQoYXJnc1tpICsgMV0pCiAgICAgICAgICAgIGkg
  >> "!B64TMP!" echo Kz0gMgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGkgKz0gMQoKICAgIGRhdGEgPSBOb25lCiAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgZGF0YSA9IGZldGNoKHVybCkKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3Iu
  >> "!B64TMP!" echo SFRUUEVycm9yIGFzIGU6CiAgICAgICAgIyBUaGUgc2VydmljZSBBTlNXRVJFRCAoZXZlbiB3aXRo
  >> "!B64TMP!" echo IGFuIGVycm9yIHN0YXR1cykgLT4gaXQgaXMgdXA7CiAgICAgICAgIyBzdGFydGluZyBjb250YWlu
  >> "!B64TMP!" echo ZXJzIHdvdWxkIG5vdCBoZWxwLgogICAgICAgIHByaW50KGYiU0NSQVBFIEZBSUxFRCBmb3Ige3Vy
  >> "!B64TMP!" echo bH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludCgiRmlyZWNyYXdsIGFuc3dl
  >> "!B64TMP!" echo cmVkIHdpdGggYW4gZXJyb3Igc3RhdHVzICh0aGUgc3RhY2sgaXMgcnVubmluZykuICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAiUmV0cnkgb25jZSB3aXRoIGEgZGlmZmVyZW50IHJlc3VsdCBVUkwsIG9yIGluc3Bl
  >> "!B64TMP!" echo Y3QgdGhlIHN0YWNrICIKICAgICAgICAgICAgICAid2l0aDogY2QgPGluc3RhbGwgZm9sZGVyPiAm
  >> "!B64TMP!" echo JiBkb2NrZXIgY29tcG9zZSBsb2dzIC0tdGFpbCA1MCAiCiAgICAgICAgICAgICAgImZpcmVjcmF3
  >> "!B64TMP!" echo bCIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlv
  >> "!B64TMP!" echo biBhcyBlOgogICAgICAgICMgQ29ubmVjdGlvbiBlcnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJs
  >> "!B64TMP!" echo eSkgZG93biAtPiBzZWxmLWhlYWwgb25jZSwKICAgICAgICAjIHRoZW4gcmV0cnkgdGhlIHNjcmFw
  >> "!B64TMP!" echo ZS4KICAgICAgICBwcmludChmIlN0YWNrIHVucmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBp
  >> "!B64TMP!" echo dCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgIG9rLCBtZXNzYWdlID0gc2VsZmhlYWwoKQogICAgICAgIGlmIG5vdCBvazoKICAgICAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQobWVzc2FnZSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBwcmludCgiU0NS
  >> "!B64TMP!" echo QVBFIEZBSUxFRCBmb3Ige306IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgY291bGQgbm90IGJlICIK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgInN0YXJ0ZWQuIFJlc29sdmUgdGhlIHN0YWNrIChvciBhc2sgdGhl
  >> "!B64TMP!" echo IHVzZXIgdG8gc3RhcnQgRG9ja2VyICIKICAgICAgICAgICAgICAgICAgIkRlc2t0b3ApIGFuZCBy
  >> "!B64TMP!" echo ZXRyeSDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBvdGhlciB3ZWIgdG9vbHMgIgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAidW5sZXNzIHRoZSB1c2VyIGFza3MuIi5mb3JtYXQodXJsKSwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgICAgICByZXR1cm4gMQogICAgICAgIHRyeToKICAgICAgICAgICAgZGF0YSA9
  >> "!B64TMP!" echo IGZldGNoKHVybCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGUyOgogICAgICAgICAgICBw
  >> "!B64TMP!" echo cmludChmIlNDUkFQRSBGQUlMRUQgZm9yIHt1cmx9IGFmdGVyIHRoZSBzdGFjayB3YXMgc3RhcnRl
  >> "!B64TMP!" echo ZDoge2UyfSIsCiAgICAgICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIDEKCiAgICBwYXlsb2FkID0gZGF0YS5nZXQoImRhdGEiKSBvciB7fQogICAgbWFya2Rv
  >> "!B64TMP!" echo d24gPSBwYXlsb2FkLmdldCgibWFya2Rvd24iKSBvciAiIiBpZiBpc2luc3RhbmNlKHBheWxvYWQs
  >> "!B64TMP!" echo IGRpY3QpIGVsc2UgIiIKICAgIGlmIG5vdCBtYXJrZG93bjoKICAgICAgICBwcmludCgiU0NSQVBF
  >> "!B64TMP!" echo IFJFVFVSTkVEIE5PIE1BUktET1dOIGZvciIsIHVybCwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAg
  >> "!B64TMP!" echo IHByaW50KGpzb24uZHVtcHMoZGF0YSlbOjgwMF0sIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMQoKICAgIGlmIGxlbihtYXJrZG93bikgPiBtYXhfY2hhcnM6CiAgICAgICAgbWFya2Rv
  >> "!B64TMP!" echo d24gPSBtYXJrZG93bls6bWF4X2NoYXJzXSArIGYiXG5cblsuLi4gdHJ1bmNhdGVkIGF0IHttYXhf
  >> "!B64TMP!" echo Y2hhcnN9IGNoYXJzIC4uLl0iCiAgICBwcmludChtYXJrZG93bikKICAgIHJldHVybiAwCgoKaWYg
  >> "!B64TMP!" echo X19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\scripts\web_scrape.py"
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

echo Installing the local-web agent skill...
set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web"
if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"
if not exist "%USERPROFILE%\.agents\skills" mkdir "%USERPROFILE%\.agents\skills"
xcopy /E /I /Y /Q "!TARGET!\local-web" "!SKILL_DIR!" >nul
if errorlevel 1 (
  echo   [WARNING] Could not copy the local-web skill to !SKILL_DIR!.
) else (
  > "!TARGET!\local-web\install-dir.txt" echo !TARGET!
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
echo   local-web skill:              %USERPROFILE%\.agents\skills\local-web
echo.
echo   If your agent was already running, restart it so it picks up
echo   the new skill.
echo.
echo   Manage the stack with the .bat files in:
echo     !TARGET!
echo       Run.bat   Stop.bat   Update.bat   Uninstall.bat
echo.
echo   See README.md for how to connect this to your AI models
echo   (local-web skill, LM Studio, MCP server, direct prompting, etc.).
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

say "Installing the local-web agent skill..."
SKILL_DIR="$HOME/.agents/skills/local-web"
rm -rf "$SKILL_DIR"
mkdir -p "$HOME/.agents/skills"
if cp -r "$TARGET/local-web" "$SKILL_DIR"; then
  printf '%s\n' "$TARGET" > "$TARGET/local-web/install-dir.txt"
  printf '%s\n' "$TARGET" > "$SKILL_DIR/install-dir.txt"
  say "  Agent skill installed: $SKILL_DIR"
else
  say "  ${YELLOW}[WARNING]${RESET} could not copy the local-web skill to $SKILL_DIR"
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
say "  local-web skill:              $HOME/.agents/skills/local-web"
echo
say "  If your agent was already running, restart it so it picks up"
say "  the new skill."
echo
say "  Manage the stack with the scripts in:"
say "    $TARGET"
say "      ./run.sh   ./stop.sh   ./update.sh   ./uninstall.sh"
echo
say "  See README.md for how to connect this to your AI models"
say "  (local-web skill, LM Studio, MCP server, direct prompting, etc.)."
say "${GREEN}============================================================${RESET}"
