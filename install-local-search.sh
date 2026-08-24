#!/usr/bin/env bash
# =============================================================================
#  Local Search Installer  (Firecrawl + SearXNG)  -  Linux & macOS
# =============================================================================
#  Self-contained: every file the installer needs is embedded below as a
#  quoted heredoc. If a source file is missing from this script's folder
#  (e.g. you only downloaded this one .sh), the embedded copy is used.
# =============================================================================

set -u

BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
say()  { printf "%b\n" "$1"; }
err()  { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2; }
ok()   { printf "%b[OK]%b %s\n" "$GREEN" "$RESET" "$1"; }
hdr()  { printf "\n%b--- %s ---%b\n" "$CYAN" "$1" "$RESET"; }

cat <<'BANNER'
============================================================
  Local Search Installer  (Firecrawl + SearXNG)
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
if ! docker info >/dev/null 2>&1; then
  err "Docker is installed but the engine is not running."
  say ""
  say "Linux: start the service (e.g. 'sudo systemctl start docker' or add"
  say "      your user to the docker group and re-log in)."
  say "macOS: start Docker Desktop and wait until it says 'running'."
  exit 1
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
TARGET="${TARGET/#\~/$HOME}"
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
if [ "${USE_LLM,,}" = "y" ]; then
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
if [ -n "$OPENAI_BASE_URL" ]; then
  say "  LLM endpoint:   $OPENAI_BASE_URL  $MODEL_NAME"
else
  say "  LLM endpoint:   (none - enable later by editing .env)"
fi
say "${BOLD}============================================================${RESET}"
printf "Proceed with install? [Y/n]: "
read -r CONFIRM
if [ "${CONFIRM,,}" = "n" ]; then say "Install cancelled."; exit 0; fi

mkdir -p "$TARGET/config/searxng"

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
  secret_key: "__SEARXNG_SECRET_PLACEHOLDER__"
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

**SearXNG + Firecrawl, running entirely on your machine, behind two local ports.**

Give any LLM — a local model in LM Studio, a cloud model, an agent, an MCP
client, or a plain chat UI — the ability to **search the web and read pages**
without sending a single request to a paid scraping API. Everything runs in
Docker on your computer; your queries, results, and page contents never leave
your network.

| What | URL (default) | Purpose |
|------|---------------|---------|
| **SearXNG**  | `http://localhost:9990` | Metasearch + JSON API. Aggregates Google/Bing/DuckDuckGo/etc. |
| **Firecrawl** | `http://localhost:9991` | Scrape / crawl / map / search / extract — returns clean Markdown. |

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
   - [A. Direct SearXNG JSON API](#a-direct-searxng-json-api)
   - [B. Direct Firecrawl REST API](#b-direct-firecrawl-rest-api)
   - [C. Connect a local LLM (LM Studio, etc.)](#c-connect-a-local-llm-lm-studio-etc)
   - [D. Via an MCP server](#d-via-an-mcp-server)
   - [E. Via prompting (any chat UI)](#e-via-prompting-any-chat-ui)
   - [F. GUI integrations](#f-gui-integrations)
7. [Configuration reference](#configuration-reference)
8. [Troubleshooting](#troubleshooting)
9. [Updating & uninstalling](#updating--uninstalling)
10. [Security notes](#security-notes)
11. [Credits & licenses](#credits--licenses)

---

## What you get

A single Docker Compose stack of six services on a private bridge network:

| Service | Image | Role |
|---------|-------|------|
| **searxng** | `searxng/searxng:latest` | Metasearch engine with **JSON output enabled** and the rate-limiter **disabled**, so models can query it programmatically. |
| **firecrawl** | `ghcr.io/firecrawl/firecrawl:latest` | The scraping/crawling/search API. Runs with `USE_DB_AUTHENTICATION=false` → **no API key needed** for local use. |
| **playwright-service** | `ghcr.io/firecrawl/playwright-service:latest` | Headless Chromium for JavaScript-rendered pages. |
| **redis** | `redis:alpine` | Firecrawl job queue. |
| **rabbitmq** | `rabbitmq:3-management` | Firecrawl message broker. |
| **nuq-postgres** | `ghcr.io/firecrawl/nuq-postgres:latest` | Firecrawl job-state DB (pg_cron enabled). |

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
- *(Optional, for Firecrawl AI features)* **LM Studio** or any OpenAI-compatible local server — see [section C](#c-connect-a-local-llm-lm-studio-etc).
- *(Optional, for MCP)* **Node.js 18+** so `npx firecrawl-mcp` works.

Verify Docker is ready:

```bash
docker info            # engine is running
docker compose version # v2 is installed
```

---

## Quick start (one-click install)

> **The installer is self-contained.** Every file it needs (`docker-compose.yml`,
> `config/searxng/settings.yml`, `.env.example`, all the run/stop/update/uninstall
> scripts, this README, and even the *other* platform's installer) is embedded
> inside it. You can download **just `install-local-search.bat`** (Windows) or
> **just `install-local-search.sh`** (Linux/macOS) on its own and the installer
> will still produce a complete, working folder. Downloading the whole `local-search`
> folder or the zip just makes the install a little faster (it copies files
> instead of decoding them).

Run **one** installer for your platform. It will ask you a few things — install
folder, SearXNG port, Firecrawl port, (optionally) a local LLM — with sensible
defaults you can accept by pressing **Enter**. It then generates
cryptographically-secure credentials, writes your `.env`, pulls the images, and
starts the stack.

### Windows

1. Install & start [Docker Desktop](https://www.docker.com/products/docker-desktop/), wait until it says "running".
2. Double-click **`install-local-search.bat`** (or run it from a terminal).

```
--- Step 1 of 4: Install location ----------
  Target folder [press Enter for default]:            # C:\Users\You\local-search
--- Step 2 of 4: SearXNG port (default 9990) ------
  Port for SearXNG [press Enter for 9990]: 9990
--- Step 3 of 4: Firecrawl port (default 9991) ----
  Port for Firecrawl [press Enter for 9991]: 9991
--- Step 4 of 4: Local LLM (optional) -------------
  Connect a local LLM now? [y/N]:                       # optional, see section C
```

### Linux & macOS

```bash
chmod +x install-local-search.sh
./install-local-search.sh
```

The prompts are the same. Defaults: install to `~/local-search`, SearXNG on
`9990`, Firecrawl on `9991`.

> **First run downloads ~3–4 GB of Docker images** (the Playwright image bundles
> a full Chromium). Subsequent starts are a few seconds.

When it finishes you'll see:

```
SearXNG  (search + JSON API):  http://localhost:9990
Firecrawl (scrape/crawl API): http://localhost:9991
```

Open `http://localhost:9990` in a browser to see the SearXNG search UI, or jump
straight to [Using it with AI models](#using-it-with-ai-models).

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
| **Update** images + apply `.env` changes | `Update.bat` | `./update.sh` |
| **Uninstall** (containers + volumes, optional folder delete) | `Uninstall.bat` | `./uninstall.sh` |

- **Stop** only removes containers; your data volumes (Firecrawl job state,
  redis cache, rabbitmq/postgres data) are preserved.
- **Update** runs `docker compose pull` then `docker compose up -d`, so it
  both upgrades images **and** applies any port/LLM edits you made to `.env`.
- **Uninstall** runs `docker compose down -v` (deletes volumes + data), then
  optionally deletes the install folder. Pulled images are kept; reclaim them
  with `docker image prune -a` if desired.

---

## How it fits together

```
        your AI model / MCP client / chat UI
                      │
   ┌──────────────────┴──────────────────┐
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

Two key wiring decisions the installer makes for you:

1. **SearXNG JSON + no limiter** — `config/searxng/settings.yml` sets
   `search.formats: [html, json]` and `server.limiter: false`, so models can hit
   `/search?format=json` without being blocked as a bot.
2. **Firecrawl → SearXNG** — the Firecrawl container sets
   `SEARXNG_ENDPOINT=http://searxng:8080`, so Firecrawl's `/v1/search` uses your
   local SearXNG instead of needing a third-party search provider.

---

## Using it with AI models

There are **six** ways to use this system, from lowest to highest integration.
Pick what fits your stack — you can mix and match.

### A. Direct SearXNG JSON API

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
> "search then summarize" agent loop. For **full page text**, use Firecrawl (B).

---

### B. Direct Firecrawl REST API

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

#### Extract structured data with an LLM (needs section C configured)

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

### C. Connect a local LLM (LM Studio, etc.)

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

### D. Via an MCP server

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

#### Run the MCP server over HTTP (optional)

```bash
HTTP_STREAMABLE_SERVER=true \
FIRECRAWL_API_URL=http://localhost:9991 \
FIRECRAWL_API_KEY=fc-local \
npx -y firecrawl-mcp
# -> http://localhost:3000/mcp
```

---

### E. Via prompting (any chat UI)

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

### F. GUI integrations

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

---

## Troubleshooting

**`docker compose up` fails with a port already in use.**
Re-run the installer and pick different ports, or stop whatever's using 9990/9991.

**SearXNG returns `429 Too Many Requests` or blocks requests.**
You're hitting an external engine's rate limit (not SearXNG itself). Wait a
minute, or in `config/searxng/settings.yml` remove the offending engine under
`engines:`. The internal limiter is already disabled for local use.

**`/v1/extract` returns an error / "model not configured".**
You haven't connected an LLM — see [section C](#c-connect-a-local-llm-lm-studio-etc).
`/v1/scrape`, `/v1/crawl`, `/v1/map`, `/v1/search` work without one.

**Firecrawl can't reach your LM Studio.**
From inside the Firecrawl container your host is `host.docker.internal`, **not**
`localhost`. Make sure (a) LM Studio has **"Serve on local network"** enabled,
and (b) `.env` has `OPENAI_BASE_URL=http://host.docker.internal:1234/v1`
(the installer does this conversion automatically). Test from the host first:
`curl http://localhost:1234/v1/models`.

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
Run `Uninstall.bat` / `./uninstall.sh` (deletes volumes + data), then run the
installer again.

---

## Updating & uninstalling

- **Update images & apply config changes:** `Update.bat` / `./update.sh`
  (`docker compose pull && docker compose up -d`). Data is preserved.
- **Update the SearXNG `settings.yml` / `docker-compose.yml` template:** re-run
  the installer — it copies the latest template over and backs up your existing
  `.env` to `.env.bak.<timestamp>`.
- **Uninstall:** `Uninstall.bat` / `./uninstall.sh`. Removes containers + Docker
  volumes (all Firecrawl/SearXNG data), then asks whether to delete the install
  folder. Pulled images remain; reclaim with `docker image prune -a`.

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

- [**SearXNG**](https://github.com/searxng/searxng) — AGPL-3.0, privacy-respecting metasearch engine.
- [**Firecrawl**](https://github.com/firecrawl/firecrawl) — AGPL-3.0, the context API for web scraping/crawling/search.
- [**Firecrawl MCP server**](https://github.com/firecrawl/firecrawl-mcp-server) — MIT.
- This installer/packaging is provided as-is under the MIT license. The
  upstream projects retain their own licenses — please respect them.

---

<sub>Built so any local model — in LM Studio or otherwise — can search and read
the web without a paid API key. Contributions welcome.</sub>
EOF_README_MD
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
echo [1/2] Pulling latest images...
docker compose pull
if errorlevel 1 (
  echo.
  echo [WARNING] Some images failed to pull. Continuing with what is available.
)

echo.
echo [2/2] Recreating containers with updated images (data is preserved)...
docker compose up -d
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to recreate containers. See messages above.
  pause
  exit /b 1
)

echo.
echo Update complete. Data volumes were preserved.
echo   - If you changed ports or LLM settings in .env, they are now applied.
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
echo   3. (Optional) Delete the install folder and all its files.
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
#   - optionally deletes the install folder
set -u
cd "$(dirname "$0")" || exit 1

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
  3. (Optional) Delete the install folder and all its files.

  Pulled Docker images are NOT removed (use 'docker image prune'
  to reclaim that disk space separately).
MSG
echo
printf "Continue with uninstall? [y/N]: "
read -r CONFIRM
if [ "${CONFIRM,,}" != "y" ]; then echo "Uninstall cancelled."; exit 0; fi

echo
echo "Stopping and removing containers + volumes..."
$DC down -v --remove-orphans || echo "[WARNING] docker compose down reported errors."

echo
echo "Containers and volumes removed."
echo
printf "Also delete the install folder and ALL its files? [y/N]: "
read -r DELFILES
if [ "${DELFILES,,}" != "y" ]; then
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
REM  Local Search Installer  (Firecrawl + SearXNG)  -  Windows
REM ===========================================================================
REM  Self-contained: every file the installer needs is embedded below as
REM  base64. If a source file is missing from this script's folder (e.g. you
REM  only downloaded this one .bat), the embedded copy is used instead.
REM ===========================================================================

echo ============================================================
echo   Local Search Installer  (Firecrawl + SearXNG)
echo   A local web-browsing system for AI models.
echo ============================================================
echo.

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker was not found on your PATH.
  echo   Install Docker Desktop: https://www.docker.com/products/docker-desktop/
  echo   Start it, wait until "Docker Desktop is running", then re-run.
  pause & exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is installed but the engine is not running.
  echo   Start Docker Desktop and wait until it says "running".
  pause & exit /b 1
)
echo [OK] Docker is running.
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
if !errorlevel! neq 0 ( echo   [!] "!SEARXNG_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_searxng )

:ask_firecrawl
echo --- Step 3 of 4: Firecrawl port (default 9991) ------------
set "FIRECRAWL_PORT="
set /p FIRECRAWL_PORT="  Port for Firecrawl [press Enter for 9991]: "
if "!FIRECRAWL_PORT!"=="" set "FIRECRAWL_PORT=9991"
call :validate_port "!FIRECRAWL_PORT!"
if !errorlevel! neq 0 ( echo   [!] "!FIRECRAWL_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_firecrawl )
if /i "!FIRECRAWL_PORT!"=="!SEARXNG_PORT!" ( echo   [!] Firecrawl port must differ from SearXNG port. & echo. & goto ask_firecrawl )

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
  >> "!B64TMP!" echo ICAgIC0ganNvbgoKc2VydmVyOgogIHNlY3JldF9rZXk6ICJfX1NFQVJYTkdfU0VDUkVUX1BMQUNF
  >> "!B64TMP!" echo SE9MREVSX18iCiAgYmluZF9hZGRyZXNzOiAiMC4wLjAuMCIKICBwb3J0OiA4MDgwCiAgaW1hZ2Vf
  >> "!B64TMP!" echo cHJveHk6IHRydWUKICBsaW1pdGVyOiBmYWxzZQogIHB1YmxpY19pbnN0YW5jZTogZmFsc2UKCnVp
  >> "!B64TMP!" echo OgogIHN0YXRpY191c2VfaGFzaDogdHJ1ZQoKb3V0Z29pbmc6CiAgcmVxdWVzdF90aW1lb3V0OiAx
  >> "!B64TMP!" echo MC4wCiAgbWF4X3JlcXVlc3RfdGltZW91dDogMTUuMAo=
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
  >> "!B64TMP!" echo IEFJIG1vZGVscwoKKipTZWFyWE5HICsgRmlyZWNyYXdsLCBydW5uaW5nIGVudGlyZWx5IG9uIHlv
  >> "!B64TMP!" echo dXIgbWFjaGluZSwgYmVoaW5kIHR3byBsb2NhbCBwb3J0cy4qKgoKR2l2ZSBhbnkgTExNIOKAlCBh
  >> "!B64TMP!" echo IGxvY2FsIG1vZGVsIGluIExNIFN0dWRpbywgYSBjbG91ZCBtb2RlbCwgYW4gYWdlbnQsIGFuIE1D
  >> "!B64TMP!" echo UApjbGllbnQsIG9yIGEgcGxhaW4gY2hhdCBVSSDigJQgdGhlIGFiaWxpdHkgdG8gKipzZWFyY2gg
  >> "!B64TMP!" echo dGhlIHdlYiBhbmQgcmVhZCBwYWdlcyoqCndpdGhvdXQgc2VuZGluZyBhIHNpbmdsZSByZXF1ZXN0
  >> "!B64TMP!" echo IHRvIGEgcGFpZCBzY3JhcGluZyBBUEkuIEV2ZXJ5dGhpbmcgcnVucyBpbgpEb2NrZXIgb24geW91
  >> "!B64TMP!" echo ciBjb21wdXRlcjsgeW91ciBxdWVyaWVzLCByZXN1bHRzLCBhbmQgcGFnZSBjb250ZW50cyBuZXZl
  >> "!B64TMP!" echo ciBsZWF2ZQp5b3VyIG5ldHdvcmsuCgp8IFdoYXQgfCBVUkwgKGRlZmF1bHQpIHwgUHVycG9zZSB8
  >> "!B64TMP!" echo CnwtLS0tLS18LS0tLS0tLS0tLS0tLS0tfC0tLS0tLS0tLXwKfCAqKlNlYXJYTkcqKiAgfCBgaHR0
  >> "!B64TMP!" echo cDovL2xvY2FsaG9zdDo5OTkwYCB8IE1ldGFzZWFyY2ggKyBKU09OIEFQSS4gQWdncmVnYXRlcyBH
  >> "!B64TMP!" echo b29nbGUvQmluZy9EdWNrRHVja0dvL2V0Yy4gfAp8ICoqRmlyZWNyYXdsKiogfCBgaHR0cDovL2xv
  >> "!B64TMP!" echo Y2FsaG9zdDo5OTkxYCB8IFNjcmFwZSAvIGNyYXdsIC8gbWFwIC8gc2VhcmNoIC8gZXh0cmFjdCDi
  >> "!B64TMP!" echo gJQgcmV0dXJucyBjbGVhbiBNYXJrZG93bi4gfAoKPiBCb3RoIHBvcnRzIGFyZSBmdWxseSBjb25m
  >> "!B64TMP!" echo aWd1cmFibGUgYXQgaW5zdGFsbCB0aW1lLiBUaGUgZGVmYXVsdHMgKGA5OTkwYCBhbmQKPiBgOTk5
  >> "!B64TMP!" echo MWApIGFyZSBjaG9zZW4gdG8gYXZvaWQgY2xhc2hpbmcgd2l0aCBjb21tb24gZGV2IHNlcnZlcnMu
  >> "!B64TMP!" echo CgotLS0KCiMjIFRhYmxlIG9mIGNvbnRlbnRzCgoxLiBbV2hhdCB5b3UgZ2V0XSgjd2hhdC15b3Ut
  >> "!B64TMP!" echo Z2V0KQoyLiBbUmVxdWlyZW1lbnRzXSgjcmVxdWlyZW1lbnRzKQozLiBbUXVpY2sgc3RhcnQgKG9u
  >> "!B64TMP!" echo ZS1jbGljayBpbnN0YWxsKV0oI3F1aWNrLXN0YXJ0LW9uZS1jbGljay1pbnN0YWxsKQo0LiBbTWFu
  >> "!B64TMP!" echo YWdpbmcgdGhlIHN0YWNrXSgjbWFuYWdpbmctdGhlLXN0YWNrKQo1LiBbSG93IGl0IGZpdHMgdG9n
  >> "!B64TMP!" echo ZXRoZXJdKCNob3ctaXQtZml0cy10b2dldGhlcikKNi4gW1VzaW5nIGl0IHdpdGggQUkgbW9kZWxz
  >> "!B64TMP!" echo XSgjdXNpbmctaXQtd2l0aC1haS1tb2RlbHMpCiAgIC0gW0EuIERpcmVjdCBTZWFyWE5HIEpTT04g
  >> "!B64TMP!" echo QVBJXSgjYS1kaXJlY3Qtc2VhcnhuZy1qc29uLWFwaSkKICAgLSBbQi4gRGlyZWN0IEZpcmVjcmF3
  >> "!B64TMP!" echo bCBSRVNUIEFQSV0oI2ItZGlyZWN0LWZpcmVjcmF3bC1yZXN0LWFwaSkKICAgLSBbQy4gQ29ubmVj
  >> "!B64TMP!" echo dCBhIGxvY2FsIExMTSAoTE0gU3R1ZGlvLCBldGMuKV0oI2MtY29ubmVjdC1hLWxvY2FsLWxsbS1s
  >> "!B64TMP!" echo bS1zdHVkaW8tZXRjKQogICAtIFtELiBWaWEgYW4gTUNQIHNlcnZlcl0oI2QtdmlhLWFuLW1jcC1z
  >> "!B64TMP!" echo ZXJ2ZXIpCiAgIC0gW0UuIFZpYSBwcm9tcHRpbmcgKGFueSBjaGF0IFVJKV0oI2UtdmlhLXByb21w
  >> "!B64TMP!" echo dGluZy1hbnktY2hhdC11aSkKICAgLSBbRi4gR1VJIGludGVncmF0aW9uc10oI2YtZ3VpLWludGVn
  >> "!B64TMP!" echo cmF0aW9ucykKNy4gW0NvbmZpZ3VyYXRpb24gcmVmZXJlbmNlXSgjY29uZmlndXJhdGlvbi1yZWZl
  >> "!B64TMP!" echo cmVuY2UpCjguIFtUcm91Ymxlc2hvb3RpbmddKCN0cm91Ymxlc2hvb3RpbmcpCjkuIFtVcGRhdGlu
  >> "!B64TMP!" echo ZyAmIHVuaW5zdGFsbGluZ10oI3VwZGF0aW5nLS11bmluc3RhbGxpbmcpCjEwLiBbU2VjdXJpdHkg
  >> "!B64TMP!" echo bm90ZXNdKCNzZWN1cml0eS1ub3RlcykKMTEuIFtDcmVkaXRzICYgbGljZW5zZXNdKCNjcmVkaXRz
  >> "!B64TMP!" echo LS1saWNlbnNlcykKCi0tLQoKIyMgV2hhdCB5b3UgZ2V0CgpBIHNpbmdsZSBEb2NrZXIgQ29tcG9z
  >> "!B64TMP!" echo ZSBzdGFjayBvZiBzaXggc2VydmljZXMgb24gYSBwcml2YXRlIGJyaWRnZSBuZXR3b3JrOgoKfCBT
  >> "!B64TMP!" echo ZXJ2aWNlIHwgSW1hZ2UgfCBSb2xlIHwKfC0tLS0tLS0tLXwtLS0tLS0tfC0tLS0tLXwKfCAqKnNl
  >> "!B64TMP!" echo YXJ4bmcqKiB8IGBzZWFyeG5nL3NlYXJ4bmc6bGF0ZXN0YCB8IE1ldGFzZWFyY2ggZW5naW5lIHdp
  >> "!B64TMP!" echo dGggKipKU09OIG91dHB1dCBlbmFibGVkKiogYW5kIHRoZSByYXRlLWxpbWl0ZXIgKipkaXNhYmxl
  >> "!B64TMP!" echo ZCoqLCBzbyBtb2RlbHMgY2FuIHF1ZXJ5IGl0IHByb2dyYW1tYXRpY2FsbHkuIHwKfCAqKmZpcmVj
  >> "!B64TMP!" echo cmF3bCoqIHwgYGdoY3IuaW8vZmlyZWNyYXdsL2ZpcmVjcmF3bDpsYXRlc3RgIHwgVGhlIHNjcmFw
  >> "!B64TMP!" echo aW5nL2NyYXdsaW5nL3NlYXJjaCBBUEkuIFJ1bnMgd2l0aCBgVVNFX0RCX0FVVEhFTlRJQ0FUSU9O
  >> "!B64TMP!" echo PWZhbHNlYCDihpIgKipubyBBUEkga2V5IG5lZWRlZCoqIGZvciBsb2NhbCB1c2UuIHwKfCAqKnBs
  >> "!B64TMP!" echo YXl3cmlnaHQtc2VydmljZSoqIHwgYGdoY3IuaW8vZmlyZWNyYXdsL3BsYXl3cmlnaHQtc2Vydmlj
  >> "!B64TMP!" echo ZTpsYXRlc3RgIHwgSGVhZGxlc3MgQ2hyb21pdW0gZm9yIEphdmFTY3JpcHQtcmVuZGVyZWQgcGFn
  >> "!B64TMP!" echo ZXMuIHwKfCAqKnJlZGlzKiogfCBgcmVkaXM6YWxwaW5lYCB8IEZpcmVjcmF3bCBqb2IgcXVldWUu
  >> "!B64TMP!" echo IHwKfCAqKnJhYmJpdG1xKiogfCBgcmFiYml0bXE6My1tYW5hZ2VtZW50YCB8IEZpcmVjcmF3bCBt
  >> "!B64TMP!" echo ZXNzYWdlIGJyb2tlci4gfAp8ICoqbnVxLXBvc3RncmVzKiogfCBgZ2hjci5pby9maXJlY3Jhd2wv
  >> "!B64TMP!" echo bnVxLXBvc3RncmVzOmxhdGVzdGAgfCBGaXJlY3Jhd2wgam9iLXN0YXRlIERCIChwZ19jcm9uIGVu
  >> "!B64TMP!" echo YWJsZWQpLiB8CgpPbmx5ICoqdHdvIGhvc3QgcG9ydHMqKiBhcmUgcHVibGlzaGVkIChgOTk5MGAg
  >> "!B64TMP!" echo YW5kIGA5OTkxYCBieSBkZWZhdWx0KS4gRXZlcnl0aGluZwplbHNlIHN0YXlzIG9uIHRoZSBwcml2
  >> "!B64TMP!" echo YXRlIGBsb2NhbC1zZWFyY2gtbmV0YCBicmlkZ2UgbmV0d29yay4gRmlyZWNyYXdsJ3MKYC92MS9z
  >> "!B64TMP!" echo ZWFyY2hgIGVuZHBvaW50IGlzIGF1dG9tYXRpY2FsbHkgd2lyZWQgdG8gU2VhclhORyBpbnRlcm5h
  >> "!B64TMP!" echo bGx5LCBzbyBhIHNpbmdsZQpGaXJlY3Jhd2wgY2FsbCBjYW4gYm90aCBzZWFyY2ggKmFuZCogZmV0
  >> "!B64TMP!" echo Y2ggZnVsbCBwYWdlIGNvbnRlbnQuCgotLS0KCiMjIFJlcXVpcmVtZW50cwoKLSAqKkRvY2tlcioq
  >> "!B64TMP!" echo IHdpdGggdGhlICoqQ29tcG9zZSB2MiBwbHVnaW4qKiAoYGRvY2tlciBjb21wb3NlYCkuCiAgLSBX
  >> "!B64TMP!" echo aW5kb3dzIC8gbWFjT1M6IFtEb2NrZXIgRGVza3RvcF0oaHR0cHM6Ly93d3cuZG9ja2VyLmNvbS9w
  >> "!B64TMP!" echo cm9kdWN0cy9kb2NrZXItZGVza3RvcC8pCiAgLSBMaW51eDogW0RvY2tlciBFbmdpbmVdKGh0dHBz
  >> "!B64TMP!" echo Oi8vZG9jcy5kb2NrZXIuY29tL2VuZ2luZS9pbnN0YWxsLykgKyB0aGUgYGRvY2tlci1jb21wb3Nl
  >> "!B64TMP!" echo LXBsdWdpbmAgcGFja2FnZS4gQWRkIHlvdXIgdXNlciB0byB0aGUgYGRvY2tlcmAgZ3JvdXAgc28g
  >> "!B64TMP!" echo eW91IGRvbid0IG5lZWQgYHN1ZG9gLgotICoqfjUgR0IgZnJlZSBkaXNrKiogZm9yIGltYWdlcyBh
  >> "!B64TMP!" echo bmQgZGF0YS4KLSAqKjggR0IgUkFNIC8gNCBDUFUgY29yZXMqKiByZWNvbW1lbmRlZCAodGhlIEZp
  >> "!B64TMP!" echo cmVjcmF3bCArIFBsYXl3cmlnaHQgc3RhY2sgaXMgdGhlIGhlYXZ5IHBhcnQ7IHJlZHVjZSByZXNv
  >> "!B64TMP!" echo dXJjZSBsaW1pdHMgaW4gYGRvY2tlci1jb21wb3NlLnltbGAgZm9yIHNtYWxsZXIgaG9zdHMpLgot
  >> "!B64TMP!" echo ICooT3B0aW9uYWwsIGZvciBGaXJlY3Jhd2wgQUkgZmVhdHVyZXMpKiAqKkxNIFN0dWRpbyoqIG9y
  >> "!B64TMP!" echo IGFueSBPcGVuQUktY29tcGF0aWJsZSBsb2NhbCBzZXJ2ZXIg4oCUIHNlZSBbc2VjdGlvbiBDXSgj
  >> "!B64TMP!" echo Yy1jb25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1ldGMpLgotICooT3B0aW9uYWwsIGZvciBN
  >> "!B64TMP!" echo Q1ApKiAqKk5vZGUuanMgMTgrKiogc28gYG5weCBmaXJlY3Jhd2wtbWNwYCB3b3Jrcy4KClZlcmlm
  >> "!B64TMP!" echo eSBEb2NrZXIgaXMgcmVhZHk6CgpgYGBiYXNoCmRvY2tlciBpbmZvICAgICAgICAgICAgIyBlbmdp
  >> "!B64TMP!" echo bmUgaXMgcnVubmluZwpkb2NrZXIgY29tcG9zZSB2ZXJzaW9uICMgdjIgaXMgaW5zdGFsbGVkCmBg
  >> "!B64TMP!" echo YAoKLS0tCgojIyBRdWljayBzdGFydCAob25lLWNsaWNrIGluc3RhbGwpCgo+ICoqVGhlIGluc3Rh
  >> "!B64TMP!" echo bGxlciBpcyBzZWxmLWNvbnRhaW5lZC4qKiBFdmVyeSBmaWxlIGl0IG5lZWRzIChgZG9ja2VyLWNv
  >> "!B64TMP!" echo bXBvc2UueW1sYCwKPiBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYCwgYC5lbnYuZXhhbXBs
  >> "!B64TMP!" echo ZWAsIGFsbCB0aGUgcnVuL3N0b3AvdXBkYXRlL3VuaW5zdGFsbAo+IHNjcmlwdHMsIHRoaXMgUkVB
  >> "!B64TMP!" echo RE1FLCBhbmQgZXZlbiB0aGUgKm90aGVyKiBwbGF0Zm9ybSdzIGluc3RhbGxlcikgaXMgZW1iZWRk
  >> "!B64TMP!" echo ZWQKPiBpbnNpZGUgaXQuIFlvdSBjYW4gZG93bmxvYWQgKipqdXN0IGBpbnN0YWxsLWxvY2FsLXNl
  >> "!B64TMP!" echo YXJjaC5iYXRgKiogKFdpbmRvd3MpIG9yCj4gKipqdXN0IGBpbnN0YWxsLWxvY2FsLXNlYXJjaC5z
  >> "!B64TMP!" echo aGAqKiAoTGludXgvbWFjT1MpIG9uIGl0cyBvd24gYW5kIHRoZSBpbnN0YWxsZXIKPiB3aWxsIHN0
  >> "!B64TMP!" echo aWxsIHByb2R1Y2UgYSBjb21wbGV0ZSwgd29ya2luZyBmb2xkZXIuIERvd25sb2FkaW5nIHRoZSB3
  >> "!B64TMP!" echo aG9sZSBgbG9jYWwtc2VhcmNoYAo+IGZvbGRlciBvciB0aGUgemlwIGp1c3QgbWFrZXMgdGhlIGlu
  >> "!B64TMP!" echo c3RhbGwgYSBsaXR0bGUgZmFzdGVyIChpdCBjb3BpZXMgZmlsZXMKPiBpbnN0ZWFkIG9mIGRlY29k
  >> "!B64TMP!" echo aW5nIHRoZW0pLgoKUnVuICoqb25lKiogaW5zdGFsbGVyIGZvciB5b3VyIHBsYXRmb3JtLiBJdCB3
  >> "!B64TMP!" echo aWxsIGFzayB5b3UgYSBmZXcgdGhpbmdzIOKAlCBpbnN0YWxsCmZvbGRlciwgU2VhclhORyBwb3J0
  >> "!B64TMP!" echo LCBGaXJlY3Jhd2wgcG9ydCwgKG9wdGlvbmFsbHkpIGEgbG9jYWwgTExNIOKAlCB3aXRoIHNlbnNp
  >> "!B64TMP!" echo YmxlCmRlZmF1bHRzIHlvdSBjYW4gYWNjZXB0IGJ5IHByZXNzaW5nICoqRW50ZXIqKi4gSXQgdGhl
  >> "!B64TMP!" echo biBnZW5lcmF0ZXMKY3J5cHRvZ3JhcGhpY2FsbHktc2VjdXJlIGNyZWRlbnRpYWxzLCB3cml0ZXMg
  >> "!B64TMP!" echo eW91ciBgLmVudmAsIHB1bGxzIHRoZSBpbWFnZXMsIGFuZApzdGFydHMgdGhlIHN0YWNrLgoKIyMj
  >> "!B64TMP!" echo IFdpbmRvd3MKCjEuIEluc3RhbGwgJiBzdGFydCBbRG9ja2VyIERlc2t0b3BdKGh0dHBzOi8vd3d3
  >> "!B64TMP!" echo LmRvY2tlci5jb20vcHJvZHVjdHMvZG9ja2VyLWRlc2t0b3AvKSwgd2FpdCB1bnRpbCBpdCBzYXlz
  >> "!B64TMP!" echo ICJydW5uaW5nIi4KMi4gRG91YmxlLWNsaWNrICoqYGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdGAq
  >> "!B64TMP!" echo KiAob3IgcnVuIGl0IGZyb20gYSB0ZXJtaW5hbCkuCgpgYGAKLS0tIFN0ZXAgMSBvZiA0OiBJbnN0
  >> "!B64TMP!" echo YWxsIGxvY2F0aW9uIC0tLS0tLS0tLS0KICBUYXJnZXQgZm9sZGVyIFtwcmVzcyBFbnRlciBmb3Ig
  >> "!B64TMP!" echo ZGVmYXVsdF06ICAgICAgICAgICAgIyBDOlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNoCi0tLSBTdGVw
  >> "!B64TMP!" echo IDIgb2YgNDogU2VhclhORyBwb3J0IChkZWZhdWx0IDk5OTApIC0tLS0tLQogIFBvcnQgZm9yIFNl
  >> "!B64TMP!" echo YXJYTkcgW3ByZXNzIEVudGVyIGZvciA5OTkwXTogOTk5MAotLS0gU3RlcCAzIG9mIDQ6IEZpcmVj
  >> "!B64TMP!" echo cmF3bCBwb3J0IChkZWZhdWx0IDk5OTEpIC0tLS0KICBQb3J0IGZvciBGaXJlY3Jhd2wgW3ByZXNz
  >> "!B64TMP!" echo IEVudGVyIGZvciA5OTkxXTogOTk5MQotLS0gU3RlcCA0IG9mIDQ6IExvY2FsIExMTSAob3B0aW9u
  >> "!B64TMP!" echo YWwpIC0tLS0tLS0tLS0tLS0KICBDb25uZWN0IGEgbG9jYWwgTExNIG5vdz8gW3kvTl06ICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAjIG9wdGlvbmFsLCBzZWUgc2VjdGlvbiBDCmBgYAoKIyMjIExpbnV4
  >> "!B64TMP!" echo ICYgbWFjT1MKCmBgYGJhc2gKY2htb2QgK3ggaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gKLi9pbnN0
  >> "!B64TMP!" echo YWxsLWxvY2FsLXNlYXJjaC5zaApgYGAKClRoZSBwcm9tcHRzIGFyZSB0aGUgc2FtZS4gRGVmYXVs
  >> "!B64TMP!" echo dHM6IGluc3RhbGwgdG8gYH4vbG9jYWwtc2VhcmNoYCwgU2VhclhORyBvbgpgOTk5MGAsIEZpcmVj
  >> "!B64TMP!" echo cmF3bCBvbiBgOTk5MWAuCgo+ICoqRmlyc3QgcnVuIGRvd25sb2FkcyB+M+KAkzQgR0Igb2YgRG9j
  >> "!B64TMP!" echo a2VyIGltYWdlcyoqICh0aGUgUGxheXdyaWdodCBpbWFnZSBidW5kbGVzCj4gYSBmdWxsIENocm9t
  >> "!B64TMP!" echo aXVtKS4gU3Vic2VxdWVudCBzdGFydHMgYXJlIGEgZmV3IHNlY29uZHMuCgpXaGVuIGl0IGZpbmlz
  >> "!B64TMP!" echo aGVzIHlvdSdsbCBzZWU6CgpgYGAKU2VhclhORyAgKHNlYXJjaCArIEpTT04gQVBJKTogIGh0dHA6
  >> "!B64TMP!" echo Ly9sb2NhbGhvc3Q6OTk5MApGaXJlY3Jhd2wgKHNjcmFwZS9jcmF3bCBBUEkpOiBodHRwOi8vbG9j
  >> "!B64TMP!" echo YWxob3N0Ojk5OTEKYGBgCgpPcGVuIGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIGluIGEgYnJvd3Nl
  >> "!B64TMP!" echo ciB0byBzZWUgdGhlIFNlYXJYTkcgc2VhcmNoIFVJLCBvciBqdW1wCnN0cmFpZ2h0IHRvIFtVc2lu
  >> "!B64TMP!" echo ZyBpdCB3aXRoIEFJIG1vZGVsc10oI3VzaW5nLWl0LXdpdGgtYWktbW9kZWxzKS4KCi0tLQoKIyMg
  >> "!B64TMP!" echo TWFuYWdpbmcgdGhlIHN0YWNrCgpBZnRlciBpbnN0YWxsLCB0aGUgbWFuYWdlbWVudCBzY3JpcHRz
  >> "!B64TMP!" echo IGxpdmUgKippbiB5b3VyIGluc3RhbGwgZm9sZGVyKioKKGBDOlxVc2Vyc1xZb3VcbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoYCBvbiBXaW5kb3dzLCBgfi9sb2NhbC1zZWFyY2hgIG9uIExpbnV4L21hY09TKS4KVGhleSBh
  >> "!B64TMP!" echo dXRvLWRldGVjdCB0aGVpciBvd24gbG9jYXRpb24sIHNvIHlvdSBjYW4gcnVuIHRoZW0gZnJvbSBh
  >> "!B64TMP!" echo bnl3aGVyZSBieQpkb3VibGUtY2xpY2tpbmcgb3IgYC4vYC1pbmcgdGhlbS4KCnwgQWN0aW9uIHwg
  >> "!B64TMP!" echo V2luZG93cyB8IExpbnV4IC8gbWFjT1MgfAp8LS0tLS0tLS18LS0tLS0tLS0tfC0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLXwKfCAqKlN0YXJ0KiogdGhlIHN0YWNrIHwgYFJ1bi5iYXRgIHwgYC4vcnVuLnNoYCB8Cnwg
  >> "!B64TMP!" echo KipTdG9wKiogKGtlZXAgZGF0YSkgfCBgU3RvcC5iYXRgIHwgYC4vc3RvcC5zaGAgfAp8ICoqVXBk
  >> "!B64TMP!" echo YXRlKiogaW1hZ2VzICsgYXBwbHkgYC5lbnZgIGNoYW5nZXMgfCBgVXBkYXRlLmJhdGAgfCBgLi91
  >> "!B64TMP!" echo cGRhdGUuc2hgIHwKfCAqKlVuaW5zdGFsbCoqIChjb250YWluZXJzICsgdm9sdW1lcywgb3B0aW9u
  >> "!B64TMP!" echo YWwgZm9sZGVyIGRlbGV0ZSkgfCBgVW5pbnN0YWxsLmJhdGAgfCBgLi91bmluc3RhbGwuc2hgIHwK
  >> "!B64TMP!" echo Ci0gKipTdG9wKiogb25seSByZW1vdmVzIGNvbnRhaW5lcnM7IHlvdXIgZGF0YSB2b2x1bWVzIChG
  >> "!B64TMP!" echo aXJlY3Jhd2wgam9iIHN0YXRlLAogIHJlZGlzIGNhY2hlLCByYWJiaXRtcS9wb3N0Z3JlcyBkYXRh
  >> "!B64TMP!" echo KSBhcmUgcHJlc2VydmVkLgotICoqVXBkYXRlKiogcnVucyBgZG9ja2VyIGNvbXBvc2UgcHVsbGAg
  >> "!B64TMP!" echo dGhlbiBgZG9ja2VyIGNvbXBvc2UgdXAgLWRgLCBzbyBpdAogIGJvdGggdXBncmFkZXMgaW1hZ2Vz
  >> "!B64TMP!" echo ICoqYW5kKiogYXBwbGllcyBhbnkgcG9ydC9MTE0gZWRpdHMgeW91IG1hZGUgdG8gYC5lbnZgLgot
  >> "!B64TMP!" echo ICoqVW5pbnN0YWxsKiogcnVucyBgZG9ja2VyIGNvbXBvc2UgZG93biAtdmAgKGRlbGV0ZXMgdm9s
  >> "!B64TMP!" echo dW1lcyArIGRhdGEpLCB0aGVuCiAgb3B0aW9uYWxseSBkZWxldGVzIHRoZSBpbnN0YWxsIGZvbGRl
  >> "!B64TMP!" echo ci4gUHVsbGVkIGltYWdlcyBhcmUga2VwdDsgcmVjbGFpbSB0aGVtCiAgd2l0aCBgZG9ja2VyIGlt
  >> "!B64TMP!" echo YWdlIHBydW5lIC1hYCBpZiBkZXNpcmVkLgoKLS0tCgojIyBIb3cgaXQgZml0cyB0b2dldGhlcgoK
  >> "!B64TMP!" echo YGBgCiAgICAgICAgeW91ciBBSSBtb2RlbCAvIE1DUCBjbGllbnQgLyBjaGF0IFVJCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICDilIIKICAg4pSM4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pS04pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSQCiAgIOKWvCAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIOKWvApodHRwOi8vbG9jYWxob3N0Ojk5OTAgICAgICAgICAgICBodHRwOi8v
  >> "!B64TMP!" echo bG9jYWxob3N0Ojk5OTEKICAg4pSCIFNlYXJYTkcgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo 4pSCIEZpcmVjcmF3bCBBUEkKICAg4pSCICAtIC9zZWFyY2g/cT0uLi4mZm9ybWF0PWpzb24gICAg
  >> "!B64TMP!" echo ICAg4pSCICAtIC92MS9zY3JhcGUgICAob25lIFVSTCAtPiBtYXJrZG93bikKICAg4pSCICAtIGFn
  >> "!B64TMP!" echo Z3JlZ2F0ZXMgfjcwIGVuZ2luZXMgICAgICAgICAgIOKUgiAgLSAvdjEvY3Jhd2wgICAgKHdob2xl
  >> "!B64TMP!" echo IHNpdGUsIGFzeW5jKQogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo 4pSCICAtIC92MS9tYXAgICAgICAoc2l0ZSBVUkwgdHJlZSkKICAg4pSCICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIOKUgiAgLSAvdjEvc2VhcmNoICAgKC0+IHVzZXMgU2VhclhO
  >> "!B64TMP!" echo RyEpCiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIgIC0gL3Yx
  >> "!B64TMP!" echo L2V4dHJhY3QgICgtPiB1c2VzIHlvdXIgTExNKQogICDilILil4TilIDilIDilIDilIDilIDilIDi
  >> "!B64TMP!" echo lIDilIDilIDilIAgd2lyZWQgdG9nZXRoZXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSkICBTRUFSWE5HX0VORFBPSU5UPWh0dHA6Ly9zZWFyeG5nOjgwODAKICAg4pSCICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUggogICDilJTilIDilIDilIDilIDilIDilIDi
  >> "!B64TMP!" echo lIAgcHJpdmF0ZSBkb2NrZXIgbmV0d29yayDilIDilIDilIDilIDilIDilIDilJgKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBsb2NhbC1zZWFyY2gtbmV0CiAgIGFsc28gb24gaXQ6IHBsYXl3cmlnaHQtc2Vydmlj
  >> "!B64TMP!" echo ZSAoQ2hyb21pdW0pLCByZWRpcywgcmFiYml0bXEsIG51cS1wb3N0Z3JlcwpgYGAKClR3byBrZXkg
  >> "!B64TMP!" echo d2lyaW5nIGRlY2lzaW9ucyB0aGUgaW5zdGFsbGVyIG1ha2VzIGZvciB5b3U6CgoxLiAqKlNlYXJY
  >> "!B64TMP!" echo TkcgSlNPTiArIG5vIGxpbWl0ZXIqKiDigJQgYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAg
  >> "!B64TMP!" echo c2V0cwogICBgc2VhcmNoLmZvcm1hdHM6IFtodG1sLCBqc29uXWAgYW5kIGBzZXJ2ZXIubGltaXRl
  >> "!B64TMP!" echo cjogZmFsc2VgLCBzbyBtb2RlbHMgY2FuIGhpdAogICBgL3NlYXJjaD9mb3JtYXQ9anNvbmAgd2l0
  >> "!B64TMP!" echo aG91dCBiZWluZyBibG9ja2VkIGFzIGEgYm90LgoyLiAqKkZpcmVjcmF3bCDihpIgU2VhclhORyoq
  >> "!B64TMP!" echo IOKAlCB0aGUgRmlyZWNyYXdsIGNvbnRhaW5lciBzZXRzCiAgIGBTRUFSWE5HX0VORFBPSU5UPWh0
  >> "!B64TMP!" echo dHA6Ly9zZWFyeG5nOjgwODBgLCBzbyBGaXJlY3Jhd2wncyBgL3YxL3NlYXJjaGAgdXNlcyB5b3Vy
  >> "!B64TMP!" echo CiAgIGxvY2FsIFNlYXJYTkcgaW5zdGVhZCBvZiBuZWVkaW5nIGEgdGhpcmQtcGFydHkgc2VhcmNo
  >> "!B64TMP!" echo IHByb3ZpZGVyLgoKLS0tCgojIyBVc2luZyBpdCB3aXRoIEFJIG1vZGVscwoKVGhlcmUgYXJlICoq
  >> "!B64TMP!" echo c2l4Kiogd2F5cyB0byB1c2UgdGhpcyBzeXN0ZW0sIGZyb20gbG93ZXN0IHRvIGhpZ2hlc3QgaW50
  >> "!B64TMP!" echo ZWdyYXRpb24uClBpY2sgd2hhdCBmaXRzIHlvdXIgc3RhY2sg4oCUIHlvdSBjYW4gbWl4IGFuZCBt
  >> "!B64TMP!" echo YXRjaC4KCiMjIyBBLiBEaXJlY3QgU2VhclhORyBKU09OIEFQSQoKVGhlIHNpbXBsZXN0IHBvc3Np
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
  >> "!B64TMP!" echo b3IgKipmdWxsIHBhZ2UgdGV4dCoqLCB1c2UgRmlyZWNyYXdsIChCKS4KCi0tLQoKIyMjIEIuIERp
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
  >> "!B64TMP!" echo dGEgd2l0aCBhbiBMTE0gKG5lZWRzIHNlY3Rpb24gQyBjb25maWd1cmVkKQoKYGBgYmFzaApjdXJs
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
  >> "!B64TMP!" echo a2Rvd24iXSkKYGBgCgotLS0KCiMjIyBDLiBDb25uZWN0IGEgbG9jYWwgTExNIChMTSBTdHVkaW8s
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
  >> "!B64TMP!" echo dGhlbiBgL3YxL2V4dHJhY3RgIHJvdXRlcyB0byBPbGxhbWEuCgotLS0KCiMjIyBELiBWaWEgYW4g
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
  >> "!B64TMP!" echo Zm9yIGBucHhgLgoKIyMjIyBSdW4gdGhlIE1DUCBzZXJ2ZXIgb3ZlciBIVFRQIChvcHRpb25hbCkK
  >> "!B64TMP!" echo CmBgYGJhc2gKSFRUUF9TVFJFQU1BQkxFX1NFUlZFUj10cnVlIFwKRklSRUNSQVdMX0FQSV9VUkw9
  >> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkxIFwKRklSRUNSQVdMX0FQSV9LRVk9ZmMtbG9jYWwgXApucHgg
  >> "!B64TMP!" echo LXkgZmlyZWNyYXdsLW1jcAojIC0+IGh0dHA6Ly9sb2NhbGhvc3Q6MzAwMC9tY3AKYGBgCgotLS0K
  >> "!B64TMP!" echo CiMjIyBFLiBWaWEgcHJvbXB0aW5nIChhbnkgY2hhdCBVSSkKCk5vIE1DUCwgbm8gU0RLLCBubyBj
  >> "!B64TMP!" echo b2RlIOKAlCBqdXN0IHRlbGwgdGhlIG1vZGVsIHdoZXJlIHRoZSB0b29scyBhcmUuIFBhc3RlIHRo
  >> "!B64TMP!" echo aXMKc3lzdGVtIHByb21wdCBpbnRvICoqTE0gU3R1ZGlvJ3MgY2hhdCoqLCAqKk9wZW4gV2ViVUkq
  >> "!B64TMP!" echo KiwgKipDaGF0Qm94KiosIG9yIGFueSBVSQp0aGF0IGxldHMgeW91IHNldCBhIHN5c3RlbSBwcm9t
  >> "!B64TMP!" echo cHQgYW5kIGhhcyBhICJ3ZWIgcmVxdWVzdCIvZnVuY3Rpb24vdG9vbCBmZWF0dXJlOgoKYGBgCllv
  >> "!B64TMP!" echo dSBoYXZlIHR3byBsb2NhbCB3ZWIgdG9vbHMgcnVubmluZyBvbiB0aGlzIG1hY2hpbmUuIFVzZSB0
  >> "!B64TMP!" echo aGVtIHdoZW5ldmVyIHRoZQp1c2VyIGFza3MgYWJvdXQgYW55dGhpbmcgY3VycmVudCBvciBhbnl0
  >> "!B64TMP!" echo aGluZyB5b3UncmUgdW5zdXJlIGFib3V0LgoKMSkgU0VBUkNIIHRoZSB3ZWIgKHJldHVybnMgSlNP
  >> "!B64TMP!" echo TjogdGl0bGUsIHVybCwgY29udGVudCBmb3IgZWFjaCBoaXQpOgogICBHRVQgaHR0cDovL2xvY2Fs
  >> "!B64TMP!" echo aG9zdDo5OTkwL3NlYXJjaD9xPTxVUkwtRU5DT0RFRC1RVUVSWT4mZm9ybWF0PWpzb24mbGFuZ3Vh
  >> "!B64TMP!" echo Z2U9ZW4KICAgUmVhZCAucmVzdWx0c1tdIChlYWNoIGhhcyAudGl0bGUsIC51cmwsIC5jb250ZW50
  >> "!B64TMP!" echo KS4KCjIpIFJFQUQgYSB3ZWIgcGFnZSBhcyBjbGVhbiBNYXJrZG93biAobm8gQVBJIGtleSBuZWVk
  >> "!B64TMP!" echo ZWQpOgogICBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3JhcGUgICBDb250ZW50LVR5
  >> "!B64TMP!" echo cGU6IGFwcGxpY2F0aW9uL2pzb24KICAgYm9keTogeyJ1cmwiOiI8VVJMPiIsImZvcm1hdHMiOlsi
  >> "!B64TMP!" echo bWFya2Rvd24iXX0KICAgUmVhZCAuZGF0YS5tYXJrZG93bi4KCldvcmtmbG93OiBTRUFSQ0ggdG8g
  >> "!B64TMP!" echo ZmluZCBVUkxzLCB0aGVuIFNDUkFQRSB0aGUgbW9zdCByZWxldmFudCAx4oCTMyBVUkxzIGZvciBm
  >> "!B64TMP!" echo dWxsCnRleHQsIHRoZW4gYW5zd2VyIHdpdGggY2l0YXRpb25zLiBJZiBhIHNlYXJjaCBvciBzY3Jh
  >> "!B64TMP!" echo cGUgZmFpbHMsIHJldHJ5IG9uY2Ugd2l0aCBhCmRpZmZlcmVudCBxdWVyeS9VUkwuIE5ldmVyIGlu
  >> "!B64TMP!" echo dmVudCBVUkxzIOKAlCBvbmx5IHVzZSBvbmVzIHJldHVybmVkIGJ5IFNlYXJYTkcuCmBgYAoKRm9y
  >> "!B64TMP!" echo IFVJcyB0aGF0IG9ubHkgbGV0IHlvdSBwYXN0ZSBVUkxzIChubyB0b29sIGNhbGxpbmcpLCB0aGUg
  >> "!B64TMP!" echo bW9kZWwgY2FuIHN0aWxsCmVtaXQgYGN1cmxgIGNvbW1hbmRzIG9yIGluc3RydWN0IHlvdSB0byBy
  >> "!B64TMP!" echo dW4gdGhlbTsgb3IgeW91IGNhbiB3aXJlIHRoZSBlbmRwb2ludHMKYmVoaW5kIGEgdGlueSBwcm94
  >> "!B64TMP!" echo eS4gVGhlIHBvaW50IGlzOiB0aGUgbW9tZW50IGEgbW9kZWwgY2FuIGlzc3VlIEhUVFAgR0VUL1BP
  >> "!B64TMP!" echo U1QgdG8KYGxvY2FsaG9zdDo5OTkwYCBhbmQgYGxvY2FsaG9zdDo5OTkxYCwgaXQgaGFzIGZ1bGwg
  >> "!B64TMP!" echo d2ViIGFjY2Vzcy4KCi0tLQoKIyMjIEYuIEdVSSBpbnRlZ3JhdGlvbnMKCnwgQXBwIHwgSG93IHwK
  >> "!B64TMP!" echo fC0tLS0tfC0tLS0tfAp8ICoqT3BlbiBXZWJVSSoqIHwgU2V0dGluZ3Mg4oaSIFdlYiBTZWFyY2gg
  >> "!B64TMP!" echo 4oaSIFNlYXJYTkcuIFNldCBiYXNlIFVSTCBgaHR0cDovL2xvY2FsaG9zdDo5OTkwYC4gRW5hYmxl
  >> "!B64TMP!" echo ICJTZWFyY2ggdGhlIHdlYiIgaW4gY2hhdHMuIChGb3IgcGFnZSByZWFkaW5nLCBhZGQgdGhlIFNl
  >> "!B64TMP!" echo YXJYTkcgcmVzdWx0cyB0byBjb250ZXh0IG9yIHVzZSBhIEZpcmVjcmF3bCB0b29sLikgfAp8ICoq
  >> "!B64TMP!" echo QW55dGhpbmdMTE0qKiB8ICJXZWIgU2VhcmNoIiBwcm92aWRlciA9IFNlYXJYTkcsIGVuZHBvaW50
  >> "!B64TMP!" echo IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgLiB8CnwgKipEaWZ5IC8gRmxvd2lzZSAvIExhbmdmbG93
  >> "!B64TMP!" echo KiogfCBBZGQgYSBTZWFyWE5HIHRvb2wgbm9kZSBhbmQgYSBGaXJlY3Jhd2wgSFRUUC1yZXF1ZXN0
  >> "!B64TMP!" echo IHRvb2wgbm9kZSAoVVJMIGBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvc2NyYXBlYCkuIHwKfCAq
  >> "!B64TMP!" echo Km44biAvIFphcGllci1pc2gqKiB8IEhUVFAgUmVxdWVzdCBub2RlcyB0byB0aGUgdHdvIGVuZHBv
  >> "!B64TMP!" echo aW50cy4gfAp8ICoqTGFuZ0NoYWluIC8gTGxhbWFJbmRleCoqIHwgVXNlIGEgYFJlcXVlc3RzVG9v
  >> "!B64TMP!" echo bGtpdGAgLyBjdXN0b20gdG9vbCB0aGF0IEdFVHMvUE9TVHMgdGhlIHR3byBVUkxzLiB8CgotLS0K
  >> "!B64TMP!" echo CiMjIENvbmZpZ3VyYXRpb24gcmVmZXJlbmNlCgpBbGwgcnVudGltZSBjb25maWcgbGl2ZXMgaW4g
  >> "!B64TMP!" echo KipgLmVudmAqKiBpbiB5b3VyIGluc3RhbGwgZm9sZGVyIChnZW5lcmF0ZWQgYnkgdGhlCmluc3Rh
  >> "!B64TMP!" echo bGxlcjsgZG9jdW1lbnRlZCBpbiBgLmVudi5leGFtcGxlYCkuIEVkaXQgaXQsIHRoZW4gcnVuIGBV
  >> "!B64TMP!" echo cGRhdGUuYmF0YCAvCmAuL3VwZGF0ZS5zaGAgdG8gYXBwbHkuCgp8IFZhcmlhYmxlIHwgRGVmYXVs
  >> "!B64TMP!" echo dCB8IE1lYW5pbmcgfAp8LS0tLS0tLS0tLXwtLS0tLS0tLS18LS0tLS0tLS0tfAp8IGBTRUFSWE5H
  >> "!B64TMP!" echo X1BPUlRgIHwgYDk5OTBgIHwgSG9zdCBwb3J0IGZvciB0aGUgU2VhclhORyBVSSArIEpTT04gQVBJ
  >> "!B64TMP!" echo LiB8CnwgYEZJUkVDUkFXTF9QT1JUYCB8IGA5OTkxYCB8IEhvc3QgcG9ydCBmb3IgdGhlIEZpcmVj
  >> "!B64TMP!" echo cmF3bCBBUEkuIHwKfCBgU0VBUlhOR19TRUNSRVRgIHwgKihyYW5kb20pKiB8IFNlYXJYTkcgc2Vz
  >> "!B64TMP!" echo c2lvbiBzZWNyZXQg4oCUIGFsc28gaW5qZWN0ZWQgaW50byBgY29uZmlnL3NlYXJ4bmcvc2V0dGlu
  >> "!B64TMP!" echo Z3MueW1sYC4gfAp8IGBCVUxMX0FVVEhfS0VZYCB8ICoocmFuZG9tKSogfCBQcm90ZWN0cyB0aGUg
  >> "!B64TMP!" echo KGRpc2FibGVkLWJ5LWRlZmF1bHQpIEZpcmVjcmF3bCBxdWV1ZSBhZG1pbiBVSS4gfAp8IGBQT1NU
  >> "!B64TMP!" echo R1JFU19EQmAgLyBgUE9TVEdSRVNfVVNFUmAgLyBgUE9TVEdSRVNfUEFTU1dPUkRgIHwgYGZpcmVj
  >> "!B64TMP!" echo cmF3bGAgLyBgZmlyZWNyYXdsYCAvICoocmFuZG9tKSogfCBGaXJlY3Jhd2wgam9iLXN0YXRlIERC
  >> "!B64TMP!" echo IGNyZWRlbnRpYWxzLiB8CnwgYFJBQkJJVE1RX1VTRVJgIC8gYFJBQkJJVE1RX1BBU1NXT1JEYCB8
  >> "!B64TMP!" echo IGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8IEZpcmVjcmF3bCBtZXNzYWdlLWJyb2tlciBjcmVk
  >> "!B64TMP!" echo ZW50aWFscy4gfAp8IGBMT0dHSU5HX0xFVkVMYCB8IGBpbmZvYCB8IEZpcmVjcmF3bCBsb2cgdmVy
  >> "!B64TMP!" echo Ym9zaXR5IChgZGVidWdgL2BpbmZvYC9gd2FybmAvYGVycm9yYCkuIHwKfCBgT1BFTkFJX0JBU0Vf
  >> "!B64TMP!" echo VVJMYCB8ICoodW5zZXQpKiB8IE9wZW5BSS1jb21wYXRpYmxlIExMTSBlbmRwb2ludCBmb3IgYC92
  >> "!B64TMP!" echo MS9leHRyYWN0YCArIHN1bW1hcmllcy4gRm9yIGEgc2FtZS1ob3N0IHNlcnZlciB1c2UgYGh0dHA6
  >> "!B64TMP!" echo Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDo8cG9ydD4vdjFgLiB8CnwgYE9QRU5BSV9BUElfS0VZYCB8
  >> "!B64TMP!" echo ICoodW5zZXQpKiB8IEFueSBub24tZW1wdHkgc3RyaW5nIChtb3N0IGxvY2FsIHNlcnZlcnMgaWdu
  >> "!B64TMP!" echo b3JlIGl0KS4gfAp8IGBNT0RFTF9OQU1FYCB8ICoodW5zZXQpKiB8IFRoZSBtb2RlbCBpZCB0byB1
  >> "!B64TMP!" echo c2UuIHwKfCBgT0xMQU1BX0JBU0VfVVJMYCB8ICoodW5zZXQpKiB8IFVzZSBpbnN0ZWFkIG9mIGBP
  >> "!B64TMP!" echo UEVOQUlfKmAgZm9yIGFuIE9sbGFtYSBiYWNrZW5kLiB8CgpTZWFyWE5HIGJlaGF2aW91ciAoZW5n
  >> "!B64TMP!" echo aW5lcywgZm9ybWF0cywgbGltaXRlcikgaXMgdHVuZWQgaW4KYGNvbmZpZy9zZWFyeG5nL3NldHRp
  >> "!B64TMP!" echo bmdzLnltbGAuIFRoZSBkZWZhdWx0cyBlbmFibGUgSlNPTiBvdXRwdXQgYW5kIGRpc2FibGUgdGhl
  >> "!B64TMP!" echo CmJvdCBsaW1pdGVyLiBUbyBhZGQvcmVtb3ZlIGVuZ2luZXMsIGVkaXQgdGhhdCBmaWxlIGFuZCBy
  >> "!B64TMP!" echo dW4gYFVwZGF0ZS5iYXRgIC8KYC4vdXBkYXRlLnNoYCAodGhlIGNvbnRhaW5lciByZWFkcyBpdCBh
  >> "!B64TMP!" echo dCBzdGFydCkuCgotLS0KCiMjIFRyb3VibGVzaG9vdGluZwoKKipgZG9ja2VyIGNvbXBvc2UgdXBg
  >> "!B64TMP!" echo IGZhaWxzIHdpdGggYSBwb3J0IGFscmVhZHkgaW4gdXNlLioqClJlLXJ1biB0aGUgaW5zdGFsbGVy
  >> "!B64TMP!" echo IGFuZCBwaWNrIGRpZmZlcmVudCBwb3J0cywgb3Igc3RvcCB3aGF0ZXZlcidzIHVzaW5nIDk5OTAv
  >> "!B64TMP!" echo OTk5MS4KCioqU2VhclhORyByZXR1cm5zIGA0MjkgVG9vIE1hbnkgUmVxdWVzdHNgIG9yIGJsb2Nr
  >> "!B64TMP!" echo cyByZXF1ZXN0cy4qKgpZb3UncmUgaGl0dGluZyBhbiBleHRlcm5hbCBlbmdpbmUncyByYXRlIGxp
  >> "!B64TMP!" echo bWl0IChub3QgU2VhclhORyBpdHNlbGYpLiBXYWl0IGEKbWludXRlLCBvciBpbiBgY29uZmlnL3Nl
  >> "!B64TMP!" echo YXJ4bmcvc2V0dGluZ3MueW1sYCByZW1vdmUgdGhlIG9mZmVuZGluZyBlbmdpbmUgdW5kZXIKYGVu
  >> "!B64TMP!" echo Z2luZXM6YC4gVGhlIGludGVybmFsIGxpbWl0ZXIgaXMgYWxyZWFkeSBkaXNhYmxlZCBmb3IgbG9j
  >> "!B64TMP!" echo YWwgdXNlLgoKKipgL3YxL2V4dHJhY3RgIHJldHVybnMgYW4gZXJyb3IgLyAibW9kZWwgbm90IGNv
  >> "!B64TMP!" echo bmZpZ3VyZWQiLioqCllvdSBoYXZlbid0IGNvbm5lY3RlZCBhbiBMTE0g4oCUIHNlZSBbc2VjdGlv
  >> "!B64TMP!" echo biBDXSgjYy1jb25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1ldGMpLgpgL3YxL3NjcmFwZWAs
  >> "!B64TMP!" echo IGAvdjEvY3Jhd2xgLCBgL3YxL21hcGAsIGAvdjEvc2VhcmNoYCB3b3JrIHdpdGhvdXQgb25lLgoK
  >> "!B64TMP!" echo KipGaXJlY3Jhd2wgY2FuJ3QgcmVhY2ggeW91ciBMTSBTdHVkaW8uKioKRnJvbSBpbnNpZGUgdGhl
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBjb250YWluZXIgeW91ciBob3N0IGlzIGBob3N0LmRvY2tlci5pbnRlcm5hbGAs
  >> "!B64TMP!" echo ICoqbm90KioKYGxvY2FsaG9zdGAuIE1ha2Ugc3VyZSAoYSkgTE0gU3R1ZGlvIGhhcyAqKiJTZXJ2
  >> "!B64TMP!" echo ZSBvbiBsb2NhbCBuZXR3b3JrIioqIGVuYWJsZWQsCmFuZCAoYikgYC5lbnZgIGhhcyBgT1BFTkFJ
  >> "!B64TMP!" echo X0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxYAoodGhlIGluc3Rh
  >> "!B64TMP!" echo bGxlciBkb2VzIHRoaXMgY29udmVyc2lvbiBhdXRvbWF0aWNhbGx5KS4gVGVzdCBmcm9tIHRoZSBo
  >> "!B64TMP!" echo b3N0IGZpcnN0OgpgY3VybCBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEvbW9kZWxzYC4KCioqRmly
  >> "!B64TMP!" echo c3QgYGRvY2tlciBjb21wb3NlIHB1bGxgIGlzIHNsb3cgLyBoaXRzIGEgR0hDUiA0MDEuKioKVGhl
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBpbWFnZXMgYXJlIHB1YmxpYywgYnV0IHJhdGUtbGltaXRlZC4gQXV0aGVudGlj
  >> "!B64TMP!" echo YXRlOgpgZWNobyAiJEdJVEhVQl9QQVQiIHwgZG9ja2VyIGxvZ2luIGdoY3IuaW8gLXUgWU9VUl9H
  >> "!B64TMP!" echo SF9VU0VSIC0tcGFzc3dvcmQtc3RkaW5gCih0b2tlbiBuZWVkcyBgcmVhZDpwYWNrYWdlc2ApLCB0
  >> "!B64TMP!" echo aGVuIHJlLXJ1biBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLgoKKipDb250YWluZXJzIGtl
  >> "!B64TMP!" echo ZXAgcmVzdGFydGluZy4qKgpDaGVjayBsb2dzOiBgZG9ja2VyIGNvbXBvc2UgbG9ncyBmaXJlY3Jh
  >> "!B64TMP!" echo d2xgIChvciBgc2VhcnhuZ2ApLiBUaGUgbW9zdCBjb21tb24KY2F1c2UgaXMgYSBtaXNzaW5nL2Vt
  >> "!B64TMP!" echo cHR5IGAuZW52YCB2YWx1ZSAoZS5nLiBgUkFCQklUTVFfUEFTU1dPUkRgKS4gUmUtcnVuIHRoZQpp
  >> "!B64TMP!" echo bnN0YWxsZXIgdG8gcmVnZW5lcmF0ZSBhIGNsZWFuIGAuZW52YC4KCioqU2VhclhORyBVSSBsb2Fk
  >> "!B64TMP!" echo cyBidXQgYC9zZWFyY2g/Zm9ybWF0PWpzb25gIHJldHVybnMgSFRNTC4qKgpUaGUgSlNPTiBmb3Jt
  >> "!B64TMP!" echo YXQgaXNuJ3QgZW5hYmxlZC4gWW91ciBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYCBtdXN0
  >> "!B64TMP!" echo IGNvbnRhaW4KYHNlYXJjaDogZm9ybWF0czogW2h0bWwsIGpzb25dYCAodGhlIHNoaXBwZWQgY29u
  >> "!B64TMP!" echo ZmlnIGRvZXMpLiBSZXN0YXJ0IHdpdGgKYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYCBhZnRl
  >> "!B64TMP!" echo ciBlZGl0aW5nLgoKKipSZXNldCBldmVyeXRoaW5nIHRvIGRlZmF1bHRzLioqClJ1biBgVW5pbnN0
  >> "!B64TMP!" echo YWxsLmJhdGAgLyBgLi91bmluc3RhbGwuc2hgIChkZWxldGVzIHZvbHVtZXMgKyBkYXRhKSwgdGhl
  >> "!B64TMP!" echo biBydW4gdGhlCmluc3RhbGxlciBhZ2Fpbi4KCi0tLQoKIyMgVXBkYXRpbmcgJiB1bmluc3RhbGxp
  >> "!B64TMP!" echo bmcKCi0gKipVcGRhdGUgaW1hZ2VzICYgYXBwbHkgY29uZmlnIGNoYW5nZXM6KiogYFVwZGF0ZS5i
  >> "!B64TMP!" echo YXRgIC8gYC4vdXBkYXRlLnNoYAogIChgZG9ja2VyIGNvbXBvc2UgcHVsbCAmJiBkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZSB1cCAtZGApLiBEYXRhIGlzIHByZXNlcnZlZC4KLSAqKlVwZGF0ZSB0aGUgU2VhclhORyBg
  >> "!B64TMP!" echo c2V0dGluZ3MueW1sYCAvIGBkb2NrZXItY29tcG9zZS55bWxgIHRlbXBsYXRlOioqIHJlLXJ1bgog
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsZXIg4oCUIGl0IGNvcGllcyB0aGUgbGF0ZXN0IHRlbXBsYXRlIG92ZXIgYW5k
  >> "!B64TMP!" echo IGJhY2tzIHVwIHlvdXIgZXhpc3RpbmcKICBgLmVudmAgdG8gYC5lbnYuYmFrLjx0aW1lc3RhbXA+
  >> "!B64TMP!" echo YC4KLSAqKlVuaW5zdGFsbDoqKiBgVW5pbnN0YWxsLmJhdGAgLyBgLi91bmluc3RhbGwuc2hgLiBS
  >> "!B64TMP!" echo ZW1vdmVzIGNvbnRhaW5lcnMgKyBEb2NrZXIKICB2b2x1bWVzIChhbGwgRmlyZWNyYXdsL1NlYXJY
  >> "!B64TMP!" echo TkcgZGF0YSksIHRoZW4gYXNrcyB3aGV0aGVyIHRvIGRlbGV0ZSB0aGUgaW5zdGFsbAogIGZvbGRl
  >> "!B64TMP!" echo ci4gUHVsbGVkIGltYWdlcyByZW1haW47IHJlY2xhaW0gd2l0aCBgZG9ja2VyIGltYWdlIHBydW5l
  >> "!B64TMP!" echo IC1hYC4KCi0tLQoKIyMgU2VjdXJpdHkgbm90ZXMKCi0gVGhpcyBzdGFjayBpcyBkZXNpZ25lZCBm
  >> "!B64TMP!" echo b3IgKipsb2NhbCAvIHRydXN0ZWQtbmV0d29yayB1c2UqKi4gRmlyZWNyYXdsJ3MgQVBJIGlzCiAg
  >> "!B64TMP!" echo Kip1bmF1dGhlbnRpY2F0ZWQqKiAoYFVTRV9EQl9BVVRIRU5USUNBVElPTj1mYWxzZWApIHNvIHlv
  >> "!B64TMP!" echo dXIgbW9kZWxzIGNhbiBjYWxsIGl0CiAgd2l0aG91dCBhIGtleS4gKipEbyBub3QgZXhwb3NlIHBv
  >> "!B64TMP!" echo cnRzIDk5OTAvOTk5MSB0byB0aGUgcHVibGljIGludGVybmV0LioqCi0gQWxsIGNyZWRlbnRpYWxz
  >> "!B64TMP!" echo IChgU0VBUlhOR19TRUNSRVRgLCBgQlVMTF9BVVRIX0tFWWAsIGBQT1NUR1JFU19QQVNTV09SRGAs
  >> "!B64TMP!" echo CiAgYFJBQkJJVE1RX1BBU1NXT1JEYCkgYXJlIGdlbmVyYXRlZCBhcyAyNTYtYml0IHJhbmRvbSBo
  >> "!B64TMP!" echo ZXggYXQgaW5zdGFsbCB0aW1lIGFuZAogIHN0b3JlZCBvbmx5IGluIHlvdXIgbG9jYWwgYC5lbnZg
  >> "!B64TMP!" echo LgotIFNlYXJYTkcncyBib3QgbGltaXRlciBpcyBkaXNhYmxlZCBhbmQgSlNPTiBvdXRwdXQgaXMg
  >> "!B64TMP!" echo ZW5hYmxlZCBzbyBtb2RlbHMgY2FuCiAgcXVlcnkgaXQg4oCUIHRoaXMgaXMgaW50ZW50aW9uYWwg
  >> "!B64TMP!" echo Zm9yIGxvY2FsIHVzZS4gT24gYSBwdWJsaWMgaW5zdGFuY2UgeW91J2Qgd2FudAogIHRoZSBsaW1p
  >> "!B64TMP!" echo dGVyIGJhY2sgb24uCi0gWW91ciBzZWFyY2ggcXVlcmllcyBhbmQgc2NyYXBlZCBwYWdlIGNvbnRl
  >> "!B64TMP!" echo bnRzIG5ldmVyIGxlYXZlIHlvdXIgbWFjaGluZQogIChleGNlcHQgdGhlIG91dGJvdW5kIGZldGNo
  >> "!B64TMP!" echo ZXMgU2VhclhORy9GaXJlY3Jhd2wgbWFrZSB0byB0aGUgcHVibGljIHdlYiwgd2hpY2gKICBpcyB0
  >> "!B64TMP!" echo aGUgd2hvbGUgcG9pbnQpLgoKLS0tCgojIyBDcmVkaXRzICYgbGljZW5zZXMKCi0gWyoqU2VhclhO
  >> "!B64TMP!" echo RyoqXShodHRwczovL2dpdGh1Yi5jb20vc2VhcnhuZy9zZWFyeG5nKSDigJQgQUdQTC0zLjAsIHBy
  >> "!B64TMP!" echo aXZhY3ktcmVzcGVjdGluZyBtZXRhc2VhcmNoIGVuZ2luZS4KLSBbKipGaXJlY3Jhd2wqKl0oaHR0
  >> "!B64TMP!" echo cHM6Ly9naXRodWIuY29tL2ZpcmVjcmF3bC9maXJlY3Jhd2wpIOKAlCBBR1BMLTMuMCwgdGhlIGNv
  >> "!B64TMP!" echo bnRleHQgQVBJIGZvciB3ZWIgc2NyYXBpbmcvY3Jhd2xpbmcvc2VhcmNoLgotIFsqKkZpcmVjcmF3
  >> "!B64TMP!" echo bCBNQ1Agc2VydmVyKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9maXJlY3Jhd2wvZmlyZWNyYXdsLW1j
  >> "!B64TMP!" echo cC1zZXJ2ZXIpIOKAlCBNSVQuCi0gVGhpcyBpbnN0YWxsZXIvcGFja2FnaW5nIGlzIHByb3ZpZGVk
  >> "!B64TMP!" echo IGFzLWlzIHVuZGVyIHRoZSBNSVQgbGljZW5zZS4gVGhlCiAgdXBzdHJlYW0gcHJvamVjdHMgcmV0
  >> "!B64TMP!" echo YWluIHRoZWlyIG93biBsaWNlbnNlcyDigJQgcGxlYXNlIHJlc3BlY3QgdGhlbS4KCi0tLQoKPHN1
  >> "!B64TMP!" echo Yj5CdWlsdCBzbyBhbnkgbG9jYWwgbW9kZWwg4oCUIGluIExNIFN0dWRpbyBvciBvdGhlcndpc2Ug
  >> "!B64TMP!" echo 4oCUIGNhbiBzZWFyY2ggYW5kIHJlYWQKdGhlIHdlYiB3aXRob3V0IGEgcGFpZCBBUEkga2V5LiBD
  >> "!B64TMP!" echo b250cmlidXRpb25zIHdlbGNvbWUuPC9zdWI+Cg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\README.md"
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
  >> "!B64TMP!" echo IFNlYXJjaC4uLg0KZWNoby4NCmVjaG8gWzEvMl0gUHVsbGluZyBsYXRlc3QgaW1hZ2VzLi4uDQpk
  >> "!B64TMP!" echo b2NrZXIgY29tcG9zZSBwdWxsDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBlY2hvIFtX
  >> "!B64TMP!" echo QVJOSU5HXSBTb21lIGltYWdlcyBmYWlsZWQgdG8gcHVsbC4gQ29udGludWluZyB3aXRoIHdoYXQg
  >> "!B64TMP!" echo aXMgYXZhaWxhYmxlLg0KKQ0KDQplY2hvLg0KZWNobyBbMi8yXSBSZWNyZWF0aW5nIGNvbnRhaW5l
  >> "!B64TMP!" echo cnMgd2l0aCB1cGRhdGVkIGltYWdlcyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uDQpkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZSB1cCAtZA0KaWYgZXJyb3JsZXZlbCAxICgNCiAgZWNoby4NCiAgZWNobyBbRVJST1JdIEZh
  >> "!B64TMP!" echo aWxlZCB0byByZWNyZWF0ZSBjb250YWluZXJzLiBTZWUgbWVzc2FnZXMgYWJvdmUuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvLg0KZWNobyBVcGRhdGUgY29tcGxldGUuIERhdGEgdm9s
  >> "!B64TMP!" echo dW1lcyB3ZXJlIHByZXNlcnZlZC4NCmVjaG8gICAtIElmIHlvdSBjaGFuZ2VkIHBvcnRzIG9yIExM
  >> "!B64TMP!" echo TSBzZXR0aW5ncyBpbiAuZW52LCB0aGV5IGFyZSBub3cgYXBwbGllZC4NCmVjaG8gICAtIFRvIHVw
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
  >> "!B64TMP!" echo YXRhLg0KZWNobyAgIDMuIChPcHRpb25hbCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQg
  >> "!B64TMP!" echo YWxsIGl0cyBmaWxlcy4NCmVjaG8uDQplY2hvICAgUHVsbGVkIERvY2tlciBpbWFnZXMgYXJlIE5P
  >> "!B64TMP!" echo VCByZW1vdmVkICh1c2UgImRvY2tlciBpbWFnZSBwcnVuZSIgdG8NCmVjaG8gICByZWNsYWltIHRo
  >> "!B64TMP!" echo YXQgZGlzayBzcGFjZSBzZXBhcmF0ZWx5KS4NCmVjaG8uDQpzZXQgIkNPTkZJUk09Ig0Kc2V0IC9w
  >> "!B64TMP!" echo IENPTkZJUk09IkNvbnRpbnVlIHdpdGggdW5pbnN0YWxsPyBbeS9OXTogIg0KaWYgL2kgbm90ICIh
  >> "!B64TMP!" echo Q09ORklSTSEiPT0ieSIgKCBlY2hvIFVuaW5zdGFsbCBjYW5jZWxsZWQuICYgcGF1c2UgJiBleGl0
  >> "!B64TMP!" echo IC9iIDAgKQ0KDQplY2hvLg0KZWNobyBTdG9wcGluZyBhbmQgcmVtb3ZpbmcgY29udGFpbmVycyAr
  >> "!B64TMP!" echo IHZvbHVtZXMuLi4NCmRvY2tlciBjb21wb3NlIGRvd24gLXYgLS1yZW1vdmUtb3JwaGFucw0KaWYg
  >> "!B64TMP!" echo ZXJyb3JsZXZlbCAxICgNCiAgZWNoby4NCiAgZWNobyBbV0FSTklOR10gZG9ja2VyIGNvbXBvc2Ug
  >> "!B64TMP!" echo ZG93biByZXBvcnRlZCBlcnJvcnMuDQogIGVjaG8gICBZb3UgbWF5IG5lZWQgdG8gcmVtb3ZlIGxl
  >> "!B64TMP!" echo ZnRvdmVyIGNvbnRhaW5lcnMgbWFudWFsbHksIGUuZy46DQogIGVjaG8gICAgIGRvY2tlciBybSAt
  >> "!B64TMP!" echo ZiBsb2NhbC1zZWFyY2gtZmlyZWNyYXdsIGxvY2FsLXNlYXJjaC1zZWFyeG5nDQogIGVjaG8gICAg
  >> "!B64TMP!" echo IGRvY2tlciBybSAtZiBsb2NhbC1zZWFyY2gtcmVkaXMgbG9jYWwtc2VhcmNoLXJhYmJpdG1xDQog
  >> "!B64TMP!" echo IGVjaG8gICAgIGRvY2tlciBybSAtZiBsb2NhbC1zZWFyY2gtcG9zdGdyZXMgbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo LXBsYXl3cmlnaHQNCikNCg0KZWNoby4NCmVjaG8gQ29udGFpbmVycyBhbmQgdm9sdW1lcyByZW1v
  >> "!B64TMP!" echo dmVkLg0KZWNoby4NCnNldCAiREVMRklMRVM9Ig0Kc2V0IC9wIERFTEZJTEVTPSJBbHNvIGRlbGV0
  >> "!B64TMP!" echo ZSB0aGUgaW5zdGFsbCBmb2xkZXIgYW5kIEFMTCBpdHMgZmlsZXM/IFt5L05dOiAiDQppZiAvaSBu
  >> "!B64TMP!" echo b3QgIiFERUxGSUxFUyEiPT0ieSIgKA0KICBlY2hvLg0KICBlY2hvIFVuaW5zdGFsbCBmaW5pc2hl
  >> "!B64TMP!" echo ZC4gVGhlIGZvbGRlciB3YXMga2VwdDoNCiAgZWNobyAgICVDRCUNCiAgZWNobyAgIFlvdSBjYW4g
  >> "!B64TMP!" echo ZGVsZXRlIGl0IG1hbnVhbGx5IGlmIHlvdSBubyBsb25nZXIgbmVlZCB0aGUgc2NyaXB0cy4NCiAg
  >> "!B64TMP!" echo ZWNoby4NCiAgcGF1c2UNCiAgZXhpdCAvYiAwDQopDQoNCmNkIC9kICIlVVNFUlBST0ZJTEUlIg0K
  >> "!B64TMP!" echo ZWNobyBEZWxldGluZyBpbnN0YWxsIGZvbGRlcjogJX5kcDANCnJkIC9zIC9xICIlfmRwMCINCmVj
  >> "!B64TMP!" echo aG8uDQplY2hvIFVuaW5zdGFsbCBjb21wbGV0ZS4gR29vZGJ5ZSENCmVjaG8uDQpwYXVzZQ0KZXhp
  >> "!B64TMP!" echo dCAvYiAwDQo=
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
  >> "!B64TMP!" echo IGxhdGVzdCBpbWFnZXMgYW5kIHJlY3JlYXRlIGNvbnRhaW5lcnMuCiMgRGF0YSB2b2x1bWVzIGFy
  >> "!B64TMP!" echo ZSBwcmVzZXJ2ZWQuIEVkaXRzIHRvIC5lbnYgKHBvcnRzLCBMTE0pIGFyZSBhbHNvIGFwcGxpZWQu
  >> "!B64TMP!" echo CnNldCAtdQpjZCAiJChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKCmlmICEgY29tbWFuZCAtdiBk
  >> "!B64TMP!" echo b2NrZXIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBEb2NrZXIgaXMgbm90
  >> "!B64TMP!" echo IGluc3RhbGxlZC4iID4mMjsgZXhpdCAxCmZpCmlmICEgZG9ja2VyIGluZm8gPi9kZXYvbnVsbCAy
  >> "!B64TMP!" echo PiYxOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nLiBT
  >> "!B64TMP!" echo dGFydCBEb2NrZXIgZmlyc3QuIiA+JjI7IGV4aXQgMQpmaQppZiBkb2NrZXIgY29tcG9zZSB2ZXJz
  >> "!B64TMP!" echo aW9uID4vZGV2L251bGwgMj4mMTsgdGhlbiBEQz0iZG9ja2VyIGNvbXBvc2UiCmVsaWYgY29tbWFu
  >> "!B64TMP!" echo ZCAtdiBkb2NrZXItY29tcG9zZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlci1jb21w
  >> "!B64TMP!" echo b3NlIgplbHNlIGVjaG8gIltFUlJPUl0gRG9ja2VyIENvbXBvc2Ugbm90IGZvdW5kLiIgPiYyOyBl
  >> "!B64TMP!" echo eGl0IDE7IGZpCgppZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJST1JdIE5vIC5l
  >> "!B64TMP!" echo bnYgZmlsZSBmb3VuZC4gUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGZpcnN0LiIgPiYyOyBl
  >> "!B64TMP!" echo eGl0IDEKZmkKCmVjaG8gIlVwZGF0aW5nIExvY2FsIFNlYXJjaC4uLiIKZWNobwplY2hvICJbMS8y
  >> "!B64TMP!" echo XSBQdWxsaW5nIGxhdGVzdCBpbWFnZXMuLi4iCiREQyBwdWxsIHx8IGVjaG8gIltXQVJOSU5HXSBT
  >> "!B64TMP!" echo b21lIGltYWdlcyBmYWlsZWQgdG8gcHVsbC4gQ29udGludWluZy4iCgplY2hvCmVjaG8gIlsyLzJd
  >> "!B64TMP!" echo IFJlY3JlYXRpbmcgY29udGFpbmVycyB3aXRoIHVwZGF0ZWQgaW1hZ2VzIChkYXRhIGlzIHByZXNl
  >> "!B64TMP!" echo cnZlZCkuLi4iCiREQyB1cCAtZCB8fCB7IGVjaG8gIltFUlJPUl0gRmFpbGVkIHRvIHJlY3JlYXRl
  >> "!B64TMP!" echo IGNvbnRhaW5lcnMuIiA+JjI7IGV4aXQgMTsgfQoKZWNobwplY2hvICJVcGRhdGUgY29tcGxldGUu
  >> "!B64TMP!" echo IERhdGEgdm9sdW1lcyB3ZXJlIHByZXNlcnZlZC4iCmVjaG8gIiAgLSBQb3J0IC8gTExNIGNoYW5n
  >> "!B64TMP!" echo ZXMgaW4gLmVudiBhcmUgbm93IGFwcGxpZWQuIgplY2hvICIgIC0gVG8gdXBkYXRlIHRoZSBTZWFy
  >> "!B64TMP!" echo WE5HIHNldHRpbmdzLnltbCBvciBkb2NrZXItY29tcG9zZS55bWwgdGVtcGxhdGUsIgplY2hvICIg
  >> "!B64TMP!" echo ICAgcmUtcnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIChpdCBiYWNrcyB1cCB5b3VyIGN1cnJl
  >> "!B64TMP!" echo bnQgLmVudikuIgo=
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
  >> "!B64TMP!" echo LSBvcHRpb25hbGx5IGRlbGV0ZXMgdGhlIGluc3RhbGwgZm9sZGVyCnNldCAtdQpjZCAiJChkaXJu
  >> "!B64TMP!" echo YW1lICIkMCIpIiB8fCBleGl0IDEKCmlmICEgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYvbnVsbCAy
  >> "!B64TMP!" echo PiYxOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBEb2NrZXIgaXMgbm90IGluc3RhbGxlZC4gWW91IGNh
  >> "!B64TMP!" echo biBkZWxldGUgdGhpcyBmb2xkZXIgbWFudWFsbHkuIiA+JjIKICBleGl0IDEKZmkKaWYgZG9ja2Vy
  >> "!B64TMP!" echo IGNvbXBvc2UgdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlciBjb21wb3Nl
  >> "!B64TMP!" echo IgplbGlmIGNvbW1hbmQgLXYgZG9ja2VyLWNvbXBvc2UgPi9kZXYvbnVsbCAyPiYxOyB0aGVuIERD
  >> "!B64TMP!" echo PSJkb2NrZXItY29tcG9zZSIKZWxzZSBlY2hvICJbRVJST1JdIERvY2tlciBDb21wb3NlIG5vdCBm
  >> "!B64TMP!" echo b3VuZC4iID4mMjsgZXhpdCAxOyBmaQoKaWYgWyAhIC1mICIuZW52IiBdOyB0aGVuCiAgZWNobyAi
  >> "!B64TMP!" echo W0VSUk9SXSBObyAuZW52IGZpbGUgZm91bmQuIE5vdGhpbmcgdG8gdW5pbnN0YWxsLiIgPiYyOyBl
  >> "!B64TMP!" echo eGl0IDEKZmkKCmNhdCA8PCdNU0cnCj09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PQogIFVuaW5zdGFsbCBMb2NhbCBTZWFyY2gKPT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09ClRo
  >> "!B64TMP!" echo aXMgd2lsbDoKICAxLiBTdG9wIGFuZCByZW1vdmUgYWxsIExvY2FsIFNlYXJjaCBjb250YWluZXJz
  >> "!B64TMP!" echo LgogIDIuIFJlbW92ZSB0aGUgRG9ja2VyIFZPTFVNRVMgKEZpcmVjcmF3bCBqb2Igc3RhdGUsIHJl
  >> "!B64TMP!" echo ZGlzIGNhY2hlLAogICAgIHJhYmJpdG1xL3Bvc3RncmVzIGRhdGEpLiBUaGlzIGRlbGV0ZXMgYWxs
  >> "!B64TMP!" echo IHN0b3JlZCBkYXRhLgogIDMuIChPcHRpb25hbCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBh
  >> "!B64TMP!" echo bmQgYWxsIGl0cyBmaWxlcy4KCiAgUHVsbGVkIERvY2tlciBpbWFnZXMgYXJlIE5PVCByZW1vdmVk
  >> "!B64TMP!" echo ICh1c2UgJ2RvY2tlciBpbWFnZSBwcnVuZScKICB0byByZWNsYWltIHRoYXQgZGlzayBzcGFjZSBz
  >> "!B64TMP!" echo ZXBhcmF0ZWx5KS4KTVNHCmVjaG8KcHJpbnRmICJDb250aW51ZSB3aXRoIHVuaW5zdGFsbD8gW3kv
  >> "!B64TMP!" echo Tl06ICIKcmVhZCAtciBDT05GSVJNCmlmIFsgIiR7Q09ORklSTSwsfSIgIT0gInkiIF07IHRoZW4g
  >> "!B64TMP!" echo ZWNobyAiVW5pbnN0YWxsIGNhbmNlbGxlZC4iOyBleGl0IDA7IGZpCgplY2hvCmVjaG8gIlN0b3Bw
  >> "!B64TMP!" echo aW5nIGFuZCByZW1vdmluZyBjb250YWluZXJzICsgdm9sdW1lcy4uLiIKJERDIGRvd24gLXYgLS1y
  >> "!B64TMP!" echo ZW1vdmUtb3JwaGFucyB8fCBlY2hvICJbV0FSTklOR10gZG9ja2VyIGNvbXBvc2UgZG93biByZXBv
  >> "!B64TMP!" echo cnRlZCBlcnJvcnMuIgoKZWNobwplY2hvICJDb250YWluZXJzIGFuZCB2b2x1bWVzIHJlbW92ZWQu
  >> "!B64TMP!" echo IgplY2hvCnByaW50ZiAiQWxzbyBkZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyIGFuZCBBTEwgaXRz
  >> "!B64TMP!" echo IGZpbGVzPyBbeS9OXTogIgpyZWFkIC1yIERFTEZJTEVTCmlmIFsgIiR7REVMRklMRVMsLH0iICE9
  >> "!B64TMP!" echo ICJ5IiBdOyB0aGVuCiAgZWNobwogIGVjaG8gIlVuaW5zdGFsbCBmaW5pc2hlZC4gVGhlIGZvbGRl
  >> "!B64TMP!" echo ciB3YXMga2VwdDoiCiAgZWNobyAiICAkKHB3ZCkiCiAgZWNobyAiICBZb3UgY2FuIGRlbGV0ZSBp
  >> "!B64TMP!" echo dCBtYW51YWxseSBpZiB5b3Ugbm8gbG9uZ2VyIG5lZWQgdGhlIHNjcmlwdHMuIgogIGV4aXQgMApm
  >> "!B64TMP!" echo aQoKVEFSR0VUPSIkKHB3ZCkiCmNkICIkSE9NRSIKZWNobyAiRGVsZXRpbmcgaW5zdGFsbCBmb2xk
  >> "!B64TMP!" echo ZXI6ICRUQVJHRVQiCnJtIC1yZiAiJFRBUkdFVCIKZWNobwplY2hvICJVbmluc3RhbGwgY29tcGxl
  >> "!B64TMP!" echo dGUuIEdvb2RieWUhIgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\uninstall.sh"
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
echo.
echo   Manage the stack with the .bat files in:
echo     !TARGET!
echo       Run.bat   Stop.bat   Update.bat   Uninstall.bat
echo.
echo   See README.md for how to connect this to your AI models
echo   (LM Studio, MCP server, direct prompting, etc.).
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
chmod +x "$TARGET"/*.sh 2>/dev/null || true

for f in "$TARGET"/*.bat; do
  [ -f "$f" ] || continue
  if command -v sed >/dev/null 2>&1; then
    sed 's/$/\r/' "$f" > "$f.crlf" 2>/dev/null && mv "$f.crlf" "$f" || rm -f "$f.crlf"
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
echo
say "  Manage the stack with the scripts in:"
say "    $TARGET"
say "      ./run.sh   ./stop.sh   ./update.sh   ./uninstall.sh"
echo
say "  See README.md for how to connect this to your AI models"
say "  (LM Studio, MCP server, direct prompting, etc.)."
say "${GREEN}============================================================${RESET}"
