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
# =============================================================================

set -u

BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
say()  { printf "%b\n" "$1"; }
err()  { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2; }
ok()   { printf "%b[OK]%b %s\n" "$GREEN" "$RESET" "$1"; }
hdr()  { printf "\n%b--- %s ---%b\n" "$CYAN" "$1" "$RESET"; }

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
say "  Agent skill:    $HOME/.agents/skills/local-web"
if [ -n "$OPENAI_BASE_URL" ]; then
  say "  LLM endpoint:   $OPENAI_BASE_URL  $MODEL_NAME"
else
  say "  LLM endpoint:   (none - enable later by editing .env)"
fi
say "${BOLD}============================================================${RESET}"
printf "Proceed with install? [Y/n]: "
read -r CONFIRM
if [ "${CONFIRM,,}" = "n" ]; then say "Install cancelled."; exit 0; fi

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
  Connect a local LLM now? [y/N]:                       # optional, see section D
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
- **Starts the stack when it's down.** `ensure_stack.py` even boots the Docker
  engine (Docker Desktop / `systemctl start docker`) if needed, then runs the
  same `docker compose up -d` that `Run.bat` / `run.sh` use — and it **never
  stops the stack** (stopping is your job, via `Stop.bat` / `stop.sh`).
- **Searches the web.** `web_search.py "query"` prints the top results as
  `title / url / snippet`, with `--limit`, `--time-range day|week|month`, and
  `--categories it,news,general` options.
- **Reads pages.** `web_scrape.py <url>` returns the page as clean Markdown
  (truncated at 20,000 chars; raise with `--max-chars`).

Manual usage (the agent does exactly this under the hood):

```bash
python ~/.agents/skills/local-web/scripts/ensure_stack.py
python ~/.agents/skills/local-web/scripts/web_search.py "latest python release"
python ~/.agents/skills/local-web/scripts/web_scrape.py "https://example.com"
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

This project is licensed under the **MPL-2.0** license — see [LICENSE](LICENSE).
The bundled [local-web](local-web) skill is also MPL-2.0.

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
if [ "${CONFIRM,,}" != "y" ]; then echo "Uninstall cancelled."; exit 0; fi

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

# --- local-web/SKILL.md ---
if [ -f "$SRC/local-web/SKILL.md" ]; then
  cp "$SRC/local-web/SKILL.md" "$TARGET/local-web/SKILL.md"
else
  say "  [embedded] local-web/SKILL.md  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web/SKILL.md" <<'EOF_LOCAL_WEB_SKILL_MD'
---
name: local-web
description: Search the web and read web pages through the local private stack — SearXNG and Firecrawl on localhost (ports read from the local-search .env, defaults 9990/9991). No API keys, no external services, no MCP tools. Use whenever the user asks about anything current, recent, or you are unsure about: news, events, latest versions or releases, documentation, facts to verify, "what do you know about X" questions — even when they don't explicitly say "search the web".
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
with the Bash tool using `python`. The services live in Docker containers;
`ensure_stack.py` starts the Docker engine and the containers automatically
if they aren't running (and never stops them — stopping is the user's job,
via Stop.bat / stop.sh).

## Workflow

1. **Make sure the stack is running** — do this once before the first search:

   ```bash
   python "<skill-base-dir>/scripts/ensure_stack.py"
   ```

   This is fast when the stack is already up. If it's down, the script starts
   the Docker engine (if it's off) and the containers (the same command
   Run.bat / run.sh run) and waits until both endpoints answer. Give the Bash
   call a 10-minute timeout (engine boot + container boot); only a first-ever
   start (pulling ~3 GB of images) can exceed that. If the script reports it
   could not launch the Docker engine at all, ask the user to start Docker
   Desktop, then re-run the script.

2. **Find URLs** — search the web:

   ```bash
   python "<skill-base-dir>/scripts/web_search.py" "your query here"
   ```

   Prints the top results as `title / url / ~300-char snippet`.
   Useful options: `--limit 10`, `--time-range day|week|month`,
   `--categories it,news,general`.

3. **Read the pages** — scrape the 1–3 most relevant result URLs for full text:

   ```bash
   python "<skill-base-dir>/scripts/web_scrape.py" "https://example.com/article"
   ```

   Prints clean Markdown (truncated at 20,000 chars by default; raise with
   `--max-chars`). Only ever scrape URLs that the search results actually
   returned — never invent or guess URLs.

4. **Answer with citations** — back each factual claim with the URL you read.

## Error handling

- If a search or scrape fails, retry **once** with a different query (search)
  or a different result URL (scrape).
- If requests fail with connection errors, the stack isn't running (or went
  down). Run `python "<skill-base-dir>/scripts/ensure_stack.py"` — it starts
  the Docker engine (if needed) and the containers, and waits until they
  answer — then retry the failed operation once. Only if the script reports
  it could not launch the engine at all should you ask the user to start
  Docker Desktop manually.
- Only if the script reports it could not find the local-search install
  folder: ask the user where that folder is, then re-run the script with
  `LOCAL_SEARCH_DIR=<that path>`. Don't do this preemptively — the folder is
  normally detected automatically (from the compose label on the running
  containers, the path recorded by the local-search installer, or from
  ~/local-search).
- Scrape output is long. Extract only the parts you need for the answer; don't
  paste whole pages back to the user.
EOF_LOCAL_WEB_SKILL_MD
fi

# --- local-web/LICENSE ---
if [ -f "$SRC/local-web/LICENSE" ]; then
  cp "$SRC/local-web/LICENSE" "$TARGET/local-web/LICENSE"
else
  say "  [embedded] local-web/LICENSE  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web/LICENSE" <<'EOF_LOCAL_WEB_LICENSE'
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
EOF_LOCAL_WEB_LICENSE
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

The stack is a set of Docker containers (docker-compose.yml in the
local-search install folder). The endpoints are NOT hardcoded here:
config.py reads SEARXNG_PORT / FIRECRAWL_PORT from the install folder's
.env (the same file the compose setup uses; defaults 9990 / 9991), so
custom ports picked at setup time are respected.

Default mode:
  * Both endpoints answering -> print status, exit 0 (fast path, < 1 s).
  * Otherwise: make sure the Docker engine is running (if it is down, launch
    Docker Desktop / the docker service and wait for the daemon), then start
    the containers with `docker compose up -d` in the install folder (the
    same command Run.bat / run.sh run, without the interactive `pause`) and
    wait until both endpoints answer again.
    The stack is NEVER stopped by this script.

Options:
    --check   Only report status; never start anything.

Exit codes:
    0  stack is ready (was already up, or was just started)
    1  stack is down and could not be brought up
    2  prerequisites missing (install folder, Docker, compose)

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

READY_TIMEOUT = 240  # seconds to wait for the stack after `compose up -d`
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


def main():
    ap = argparse.ArgumentParser(description="Ensure the local-search Docker stack is running.")
    ap.add_argument("--check", action="store_true",
                    help="only report status; never start anything")
    args = ap.parse_args()

    endpoints = config.endpoints(config.find_install_dir())
    st = status(endpoints)
    if all(st.values()):
        print(ready_message(endpoints))
        return 0

    print("Local-search stack is DOWN:", file=sys.stderr)
    for name, url in endpoints.items():
        mark = "OK  " if st[name] else "DOWN"
        print(f"  [{mark}] {DISPLAY[name]} :{port_of(url)}", file=sys.stderr)
    if args.check:
        return 1

    if not docker_engine_up():
        print("Docker engine is not running — trying to start it ...",
              file=sys.stderr)
        if not start_docker_engine():
            print("Could not start the Docker engine automatically "
                  "(Docker Desktop not found in the usual locations?). "
                  "Start it manually, then re-run this script.", file=sys.stderr)
            return 2
        print("Waiting for the Docker engine to come up ...", file=sys.stderr)
        if not wait_for_engine(timeout=180):
            print("The Docker engine was launched but did not answer within "
                  "180 s. Check Docker Desktop, then re-run this script.",
                  file=sys.stderr)
            return 2

    # Recomputed now that the engine is up: the compose-label lookup (which
    # needs the engine) can find the install dir where the other methods
    # could not.
    install_dir = config.find_install_dir()
    if not install_dir:
        print("Could not find the local-search install folder "
              "(no docker-compose.yml found). Ask the user where their "
              "local-search folder is, then re-run this script with "
              "LOCAL_SEARCH_DIR set to that path, or start the stack manually "
              "(Run.bat / run.sh).", file=sys.stderr)
        return 2

    compose = compose_command()
    if not compose:
        print("Neither 'docker compose' nor 'docker-compose' is available.",
              file=sys.stderr)
        return 2

    print(f"Starting stack in {install_dir} ...", file=sys.stderr)
    proc = subprocess.run(compose + ["up", "-d"], cwd=install_dir)
    if proc.returncode != 0:
        print("'docker compose up -d' failed — see output above.", file=sys.stderr)
        return 1

    print("Waiting for endpoints ...", file=sys.stderr)
    deadline = time.time() + READY_TIMEOUT
    while time.time() < deadline:
        st = status(endpoints)
        if all(st.values()):
            print(ready_message(endpoints))
            return 0
        time.sleep(POLL_EVERY)

    for name, url in endpoints.items():
        mark = "OK  " if st[name] else "DOWN"
        print(f"  [{mark}] {DISPLAY[name]} :{port_of(url)}", file=sys.stderr)
    print(f"Stack did not become ready within {READY_TIMEOUT}s. Inspect with:\n"
          f"    cd {install_dir} && docker compose logs --tail 50", file=sys.stderr)
    return 1


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

Prints up to `limit` results, each as:
    N. <title>
       <url>
       <snippet>
"""
import json
import os
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Port comes from SEARXNG_PORT in the install folder's .env (default 9990).
BASE = config.endpoints(config.find_install_dir())["searxng"] + "/search"


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
    req = urllib.request.Request(url, headers={"User-Agent": "zcode-local-web/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except Exception as e:
        print(f"SEARCH FAILED: {e}", file=sys.stderr)
        print("Is the local-search stack running? Run scripts/ensure_stack.py "
              "(it starts the Docker containers if needed), then retry.", file=sys.stderr)
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

Prints the page's Markdown to stdout, truncated at --max-chars.
"""
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Port comes from FIRECRAWL_PORT in the install folder's .env (default 9991).
ENDPOINT = config.endpoints(config.find_install_dir())["firecrawl"] + "/v1/scrape"


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

    body = json.dumps({"url": url, "formats": ["markdown"]}).encode()
    req = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "zcode-local-web/1.0"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            data = json.load(r)
    except Exception as e:
        print(f"SCRAPE FAILED for {url}: {e}", file=sys.stderr)
        print("Is the local-search stack running? Run scripts/ensure_stack.py "
              "(it starts the Docker containers if needed), then retry.", file=sys.stderr)
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
  >> "!B64TMP!" echo LCBhbmQgc3RhcnRzIHRoZSBzdGFjay4KCiMjIyBXaW5kb3dzCgoxLiBJbnN0YWxsICYgc3RhcnQg
  >> "!B64TMP!" echo W0RvY2tlciBEZXNrdG9wXShodHRwczovL3d3dy5kb2NrZXIuY29tL3Byb2R1Y3RzL2RvY2tlci1k
  >> "!B64TMP!" echo ZXNrdG9wLyksIHdhaXQgdW50aWwgaXQgc2F5cyAicnVubmluZyIuCjIuIERvdWJsZS1jbGljayAq
  >> "!B64TMP!" echo KmBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXRgKiogKG9yIHJ1biBpdCBmcm9tIGEgdGVybWluYWwp
  >> "!B64TMP!" echo LgoKYGBgCi0tLSBTdGVwIDEgb2YgNDogSW5zdGFsbCBsb2NhdGlvbiAtLS0tLS0tLS0tCiAgVGFy
  >> "!B64TMP!" echo Z2V0IGZvbGRlciBbcHJlc3MgRW50ZXIgZm9yIGRlZmF1bHRdOiAgICAgICAgICAgICMgQzpcVXNl
  >> "!B64TMP!" echo cnNcWW91XGxvY2FsLXNlYXJjaAotLS0gU3RlcCAyIG9mIDQ6IFNlYXJYTkcgcG9ydCAoZGVmYXVs
  >> "!B64TMP!" echo dCA5OTkwKSAtLS0tLS0KICBQb3J0IGZvciBTZWFyWE5HIFtwcmVzcyBFbnRlciBmb3IgOTk5MF06
  >> "!B64TMP!" echo IDk5OTAKLS0tIFN0ZXAgMyBvZiA0OiBGaXJlY3Jhd2wgcG9ydCAoZGVmYXVsdCA5OTkxKSAtLS0t
  >> "!B64TMP!" echo CiAgUG9ydCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBFbnRlciBmb3IgOTk5MV06IDk5OTEKLS0tIFN0
  >> "!B64TMP!" echo ZXAgNCBvZiA0OiBMb2NhbCBMTE0gKG9wdGlvbmFsKSAtLS0tLS0tLS0tLS0tCiAgQ29ubmVjdCBh
  >> "!B64TMP!" echo IGxvY2FsIExMTSBub3c/IFt5L05dOiAgICAgICAgICAgICAgICAgICAgICAgIyBvcHRpb25hbCwg
  >> "!B64TMP!" echo c2VlIHNlY3Rpb24gRApgYGAKCiMjIyBMaW51eCAmIG1hY09TCgpgYGBiYXNoCmNobW9kICt4IGlu
  >> "!B64TMP!" echo c3RhbGwtbG9jYWwtc2VhcmNoLnNoCi4vaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gKYGBgCgpUaGUg
  >> "!B64TMP!" echo cHJvbXB0cyBhcmUgdGhlIHNhbWUuIERlZmF1bHRzOiBpbnN0YWxsIHRvIGB+L2xvY2FsLXNlYXJj
  >> "!B64TMP!" echo aGAsIFNlYXJYTkcgb24KYDk5OTBgLCBGaXJlY3Jhd2wgb24gYDk5OTFgLgoKPiAqKkZpcnN0IHJ1
  >> "!B64TMP!" echo biBkb3dubG9hZHMgfjPigJM0IEdCIG9mIERvY2tlciBpbWFnZXMqKiAodGhlIFBsYXl3cmlnaHQg
  >> "!B64TMP!" echo aW1hZ2UgYnVuZGxlcwo+IGEgZnVsbCBDaHJvbWl1bSkuIFN1YnNlcXVlbnQgc3RhcnRzIGFyZSBh
  >> "!B64TMP!" echo IGZldyBzZWNvbmRzLgoKV2hlbiBpdCBmaW5pc2hlcyB5b3UnbGwgc2VlOgoKYGBgClNlYXJYTkcg
  >> "!B64TMP!" echo IChzZWFyY2ggKyBKU09OIEFQSSk6ICBodHRwOi8vbG9jYWxob3N0Ojk5OTAKRmlyZWNyYXdsIChz
  >> "!B64TMP!" echo Y3JhcGUvY3Jhd2wgQVBJKTogaHR0cDovL2xvY2FsaG9zdDo5OTkxCkFnZW50IHNraWxsOiBDOlxV
  >> "!B64TMP!" echo c2Vyc1xZb3VcLmFnZW50c1xza2lsbHNcbG9jYWwtd2ViICAgKG9yIH4vLmFnZW50cy9za2lsbHMv
  >> "!B64TMP!" echo bG9jYWwtd2ViKQpgYGAKCk9wZW4gYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAgaW4gYSBicm93c2Vy
  >> "!B64TMP!" echo IHRvIHNlZSB0aGUgU2VhclhORyBzZWFyY2ggVUkg4oCUIG9yLAppZiB5b3VyIGFnZW50IGxvYWRz
  >> "!B64TMP!" echo IHNraWxscyBmcm9tIGB+Ly5hZ2VudHMvc2tpbGxzL2AsIGp1c3QgYXNrIGl0IHRvIHJlc2VhcmNo
  >> "!B64TMP!" echo CnNvbWV0aGluZyBjdXJyZW50IGFuZCBpdCB3aWxsIHVzZSAqKmxvY2FsLXdlYioqIGF1dG9tYXRp
  >> "!B64TMP!" echo Y2FsbHkgKHNlZQpbc2VjdGlvbiBBXSgjYS10aGUtYnVuZGxlZC1sb2NhbC13ZWItc2tpbGwtcmVj
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
  >> "!B64TMP!" echo YWxzbyByZS1jb3BpZXMgdGhlIGJ1bmRsZWQgYGxvY2FsLXdlYmAgc2tpbGwgaW50byBgfi8uYWdl
  >> "!B64TMP!" echo bnRzL3NraWxscy9gLgotICoqVW5pbnN0YWxsKiogcnVucyBgZG9ja2VyIGNvbXBvc2UgZG93biAt
  >> "!B64TMP!" echo dmAgKGRlbGV0ZXMgdm9sdW1lcyArIGRhdGEpLAogIHJlbW92ZXMgdGhlIGBsb2NhbC13ZWJgIHNr
  >> "!B64TMP!" echo aWxsIGZyb20gYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViYCwgdGhlbgogIG9wdGlvbmFsbHkg
  >> "!B64TMP!" echo ZGVsZXRlcyB0aGUgaW5zdGFsbCBmb2xkZXIuIFB1bGxlZCBpbWFnZXMgYXJlIGtlcHQ7IHJlY2xh
  >> "!B64TMP!" echo aW0gdGhlbQogIHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAtYWAgaWYgZGVzaXJlZC4KCi0tLQoK
  >> "!B64TMP!" echo IyMgSG93IGl0IGZpdHMgdG9nZXRoZXIKCmBgYAogICAgICAgIHlvdXIgQUkgbW9kZWwgLyBhZ2Vu
  >> "!B64TMP!" echo dCAobG9jYWwtd2ViIHNraWxsKSAvIE1DUCBjbGllbnQgLyBjaGF0IFVJCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICDilIIKICAg4pSM4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pS84pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSQCiAgIOKWvCAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIOKWvApodHRwOi8vbG9jYWxob3N0Ojk5OTAgICAgICAgICAgICBodHRw
  >> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTEKICAg4pSCIFNlYXJYTkcgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAg4pSCIEZpcmVjcmF3bCBBUEkKICAg4pSCICAtIC9zZWFyY2g/cT0uLi4mZm9ybWF0PWpzb24g
  >> "!B64TMP!" echo ICAgICAg4pSCICAtIC92MS9zY3JhcGUgICAob25lIFVSTCAtPiBtYXJrZG93bikKICAg4pSCICAt
  >> "!B64TMP!" echo IGFnZ3JlZ2F0ZXMgfjcwIGVuZ2luZXMgICAgICAgICAgIOKUgiAgLSAvdjEvY3Jhd2wgICAgKHdo
  >> "!B64TMP!" echo b2xlIHNpdGUsIGFzeW5jKQogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAg4pSCICAtIC92MS9tYXAgICAgICAoc2l0ZSBVUkwgdHJlZSkKICAg4pSCICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgIOKUgiAgLSAvdjEvc2VhcmNoICAgKC0+IHVzZXMgU2Vh
  >> "!B64TMP!" echo clhORyEpCiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIgIC0g
  >> "!B64TMP!" echo L3YxL2V4dHJhY3QgICgtPiB1c2VzIHlvdXIgTExNKQogICDilILil4TilIDilIDilIDilIDilIDi
  >> "!B64TMP!" echo lIDilIDilIDilIDilIAgd2lyZWQgdG9nZXRoZXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSkICBTRUFSWE5HX0VORFBPSU5UPWh0dHA6Ly9zZWFyeG5nOjgwODAKICAg4pSCICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUggogICDilJTilIDilIDilIDilIDilIDi
  >> "!B64TMP!" echo lIDilIAgcHJpdmF0ZSBkb2NrZXIgbmV0d29yayDilIDilIDilIDilIDilIDilIDilJgKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBsb2NhbC1zZWFyY2gtbmV0CiAgIGFsc28gb24gaXQ6IHBsYXl3cmlnaHQtc2Vy
  >> "!B64TMP!" echo dmljZSAoQ2hyb21pdW0pLCByZWRpcywgcmFiYml0bXEsIG51cS1wb3N0Z3JlcwpgYGAKClRocmVl
  >> "!B64TMP!" echo IGtleSB3aXJpbmcgZGVjaXNpb25zIHRoZSBpbnN0YWxsZXIgbWFrZXMgZm9yIHlvdToKCjEuICoq
  >> "!B64TMP!" echo U2VhclhORyBKU09OICsgbm8gbGltaXRlcioqIOKAlCBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3Mu
  >> "!B64TMP!" echo eW1sYCBzZXRzCiAgIGBzZWFyY2guZm9ybWF0czogW2h0bWwsIGpzb25dYCBhbmQgYHNlcnZlci5s
  >> "!B64TMP!" echo aW1pdGVyOiBmYWxzZWAsIHNvIG1vZGVscyBjYW4gaGl0CiAgIGAvc2VhcmNoP2Zvcm1hdD1qc29u
  >> "!B64TMP!" echo YCB3aXRob3V0IGJlaW5nIGJsb2NrZWQgYXMgYSBib3QuCjIuICoqRmlyZWNyYXdsIOKGkiBTZWFy
  >> "!B64TMP!" echo WE5HKiog4oCUIHRoZSBGaXJlY3Jhd2wgY29udGFpbmVyIHNldHMKICAgYFNFQVJYTkdfRU5EUE9J
  >> "!B64TMP!" echo TlQ9aHR0cDovL3NlYXJ4bmc6ODA4MGAsIHNvIEZpcmVjcmF3bCdzIGAvdjEvc2VhcmNoYCB1c2Vz
  >> "!B64TMP!" echo IHlvdXIKICAgbG9jYWwgU2VhclhORyBpbnN0ZWFkIG9mIG5lZWRpbmcgYSB0aGlyZC1wYXJ0eSBz
  >> "!B64TMP!" echo ZWFyY2ggcHJvdmlkZXIuCjMuICoqbG9jYWwtd2ViIHNraWxsIGF1dG8taW5zdGFsbCoqIOKAlCB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyIGNvcGllcyB0aGUgYnVuZGxlZCBza2lsbCB0bwogICBgfi8uYWdlbnRzL3Nr
  >> "!B64TMP!" echo aWxscy9sb2NhbC13ZWIvYCAoYWRkL292ZXJyaWRlKSBhbmQgcmVjb3JkcyB0aGUgaW5zdGFsbCBw
  >> "!B64TMP!" echo YXRoIGluCiAgIGFuIGBpbnN0YWxsLWRpci50eHRgIGhpbnQgaW5zaWRlIHRoZSBza2lsbCwgc28g
  >> "!B64TMP!" echo dGhlIHNraWxsIGZpbmRzIHRoZSBzdGFjayBldmVuCiAgIGlmIHlvdSBpbnN0YWxsZWQgdG8gYSBj
  >> "!B64TMP!" echo dXN0b20gZm9sZGVyIGFuZCBEb2NrZXIgaXNuJ3QgcnVubmluZyB5ZXQuCgotLS0KCiMjIFVzaW5n
  >> "!B64TMP!" echo IGl0IHdpdGggQUkgbW9kZWxzCgpUaGVyZSBhcmUgKipzZXZlbioqIHdheXMgdG8gdXNlIHRoaXMg
  >> "!B64TMP!" echo c3lzdGVtLCBmcm9tIGxvd2VzdCB0byBoaWdoZXN0CmludGVncmF0aW9uLiBQaWNrIHdoYXQgZml0
  >> "!B64TMP!" echo cyB5b3VyIHN0YWNrIOKAlCB5b3UgY2FuIG1peCBhbmQgbWF0Y2guCgojIyMgQS4gVGhlIGJ1bmRs
  >> "!B64TMP!" echo ZWQgbG9jYWwtd2ViIHNraWxsIChyZWNvbW1lbmRlZCkKClRoZSBpbnN0YWxsZXIgc2hpcHMgd2l0
  >> "!B64TMP!" echo aCAqKmxvY2FsLXdlYioqLCBhbiBhZ2VudCBza2lsbCB0aGF0IHR1cm5zIGFueQpza2lsbC1sb2Fk
  >> "!B64TMP!" echo aW5nIGFnZW50IGludG8gYSB3ZWIgcmVzZWFyY2hlciB3aXRoIHplcm8gY29uZmlndXJhdGlvbi4g
  >> "!B64TMP!" echo SWYgeW91cgphZ2VudCByZWFkcyBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gCihgQzpc
  >> "!B64TMP!" echo VXNlcnNcWW91XC5hZ2VudHNcc2tpbGxzXGAgb24gV2luZG93cyksIGl0J3MgYWxyZWFkeSBhdmFp
  >> "!B64TMP!" echo bGFibGUgYWZ0ZXIKaW5zdGFsbCDigJQgcmVzdGFydCB0aGUgYWdlbnQgaWYgaXQgd2FzIHJ1bm5p
  >> "!B64TMP!" echo bmcuCgpUaGUgaW5zdGFsbGVyOgotIHB1dHMgYSBjb3B5IGluIGA8aW5zdGFsbCBmb2xkZXI+L2xv
  >> "!B64TMP!" echo Y2FsLXdlYi9gLCBhbmQKLSAqKmF1dG9tYXRpY2FsbHkgaW5zdGFsbHMgKGFkZC9vdmVycmlkZSkq
  >> "!B64TMP!" echo KiBpdCBpbnRvCiAgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViL2AuCgpXaGF0IHRoZSBza2ls
  >> "!B64TMP!" echo bCBkb2VzIGZvciB0aGUgYWdlbnQ6CgotICoqRmluZHMgdGhlIHN0YWNrIGF1dG9tYXRpY2FsbHku
  >> "!B64TMP!" echo KiogSXQgcmVhZHMgdGhlIHJlYWwgcG9ydHMgZnJvbSB5b3VyIGAuZW52YAogIChzbyBjdXN0b20g
  >> "!B64TMP!" echo aW5zdGFsbC10aW1lIHBvcnRzIGp1c3Qgd29yaykgYW5kIGxvY2F0ZXMgdGhlIGluc3RhbGwgZm9s
  >> "!B64TMP!" echo ZGVyIHZpYQogIHRoZSBjb21wb3NlIGxhYmVscyBvbiB0aGUgcnVubmluZyBjb250YWluZXJzLCB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyLXJlY29yZGVkCiAgYGluc3RhbGwtZGlyLnR4dGAgaGludCwgb3IgYH4vbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoYCDigJQgbm8gaGFyZGNvZGVkIGFueXRoaW5nLgotICoqU3RhcnRzIHRoZSBzdGFj
  >> "!B64TMP!" echo ayB3aGVuIGl0J3MgZG93bi4qKiBgZW5zdXJlX3N0YWNrLnB5YCBldmVuIGJvb3RzIHRoZSBEb2Nr
  >> "!B64TMP!" echo ZXIKICBlbmdpbmUgKERvY2tlciBEZXNrdG9wIC8gYHN5c3RlbWN0bCBzdGFydCBkb2NrZXJgKSBp
  >> "!B64TMP!" echo ZiBuZWVkZWQsIHRoZW4gcnVucyB0aGUKICBzYW1lIGBkb2NrZXIgY29tcG9zZSB1cCAtZGAgdGhh
  >> "!B64TMP!" echo dCBgUnVuLmJhdGAgLyBgcnVuLnNoYCB1c2Ug4oCUIGFuZCBpdCAqKm5ldmVyCiAgc3RvcHMgdGhl
  >> "!B64TMP!" echo IHN0YWNrKiogKHN0b3BwaW5nIGlzIHlvdXIgam9iLCB2aWEgYFN0b3AuYmF0YCAvIGBzdG9wLnNo
  >> "!B64TMP!" echo YCkuCi0gKipTZWFyY2hlcyB0aGUgd2ViLioqIGB3ZWJfc2VhcmNoLnB5ICJxdWVyeSJgIHByaW50
  >> "!B64TMP!" echo cyB0aGUgdG9wIHJlc3VsdHMgYXMKICBgdGl0bGUgLyB1cmwgLyBzbmlwcGV0YCwgd2l0aCBgLS1s
  >> "!B64TMP!" echo aW1pdGAsIGAtLXRpbWUtcmFuZ2UgZGF5fHdlZWt8bW9udGhgLCBhbmQKICBgLS1jYXRlZ29yaWVz
  >> "!B64TMP!" echo IGl0LG5ld3MsZ2VuZXJhbGAgb3B0aW9ucy4KLSAqKlJlYWRzIHBhZ2VzLioqIGB3ZWJfc2NyYXBl
  >> "!B64TMP!" echo LnB5IDx1cmw+YCByZXR1cm5zIHRoZSBwYWdlIGFzIGNsZWFuIE1hcmtkb3duCiAgKHRydW5jYXRl
  >> "!B64TMP!" echo ZCBhdCAyMCwwMDAgY2hhcnM7IHJhaXNlIHdpdGggYC0tbWF4LWNoYXJzYCkuCgpNYW51YWwgdXNh
  >> "!B64TMP!" echo Z2UgKHRoZSBhZ2VudCBkb2VzIGV4YWN0bHkgdGhpcyB1bmRlciB0aGUgaG9vZCk6CgpgYGBiYXNo
  >> "!B64TMP!" echo CnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi9zY3JpcHRzL2Vuc3VyZV9zdGFjay5w
  >> "!B64TMP!" echo eQpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIvc2NyaXB0cy93ZWJfc2VhcmNoLnB5
  >> "!B64TMP!" echo ICJsYXRlc3QgcHl0aG9uIHJlbGVhc2UiCnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdl
  >> "!B64TMP!" echo Yi9zY3JpcHRzL3dlYl9zY3JhcGUucHkgImh0dHBzOi8vZXhhbXBsZS5jb20iCmBgYAoKVGhlIGZ1
  >> "!B64TMP!" echo bGwgYWdlbnQtZmFjaW5nIGluc3RydWN0aW9ucyBsaXZlIGluIHRoZSBza2lsbCdzIGBTS0lMTC5t
  >> "!B64TMP!" echo ZGAuIEtlZXBpbmcgdGhlCnNraWxsIGZyZXNoIGlzIGF1dG9tYXRpYzogYFVwZGF0ZS5iYXRgIC8g
  >> "!B64TMP!" echo YC4vdXBkYXRlLnNoYCByZS1zeW5jcyBpdCwgYW5kCnJlLXJ1bm5pbmcgdGhlIGluc3RhbGxlciBv
  >> "!B64TMP!" echo dmVyd3JpdGVzIGl0LiBVbmluc3RhbGxpbmcgcmVtb3ZlcyBpdC4KCj4gVGhlIHNraWxsIG9ubHkg
  >> "!B64TMP!" echo bmVlZHMgKipQeXRob24gMy44KyoqIG9uIHRoZSBob3N0IOKAlCBubyBwaXAgcGFja2FnZXMsIG5v
  >> "!B64TMP!" echo IEFQSQo+IGtleXMsIG5vIE1DUCBzdXBwb3J0IHJlcXVpcmVkIGZyb20gdGhlIGFnZW50LgoKLS0t
  >> "!B64TMP!" echo CgojIyMgQi4gRGlyZWN0IFNlYXJYTkcgSlNPTiBBUEkKClRoZSBzaW1wbGVzdCBwb3NzaWJsZSBp
  >> "!B64TMP!" echo bnRlZ3JhdGlvbjogaGl0IFNlYXJYTkcncyBKU09OIGVuZHBvaW50IGFuZCBmZWVkIHRoZQpyZXN1
  >> "!B64TMP!" echo bHRzIGludG8gYW55IG1vZGVsJ3MgY29udGV4dC4gTm8gU0RLLCBubyBrZXksIG5vIE1DUC4KCmBg
  >> "!B64TMP!" echo YGJhc2gKIyBTZWFyY2ggdGhlIHdlYiwgcmV0dXJuIEpTT04sIHNob3cgdGhlIHRvcCA1IHJlc3Vs
  >> "!B64TMP!" echo dHMKY3VybCAtcyAiaHR0cDovL2xvY2FsaG9zdDo5OTkwL3NlYXJjaD9xPWxhdGVzdCtBSStuZXdz
  >> "!B64TMP!" echo JmZvcm1hdD1qc29uIiBcCiAgfCBqcSAnLnJlc3VsdHNbOjVdIHwgLltdIHwge3RpdGxlLCB1cmws
  >> "!B64TMP!" echo IGNvbnRlbnR9JwpgYGAKClVzZWZ1bCBxdWVyeSBwYXJhbXM6IGAmcGFnZW5vPTJgLCBgJmNhdGVn
  >> "!B64TMP!" echo b3JpZXM9aXQsaW1hZ2VzYCwgYCZ0aW1lX3JhbmdlPWRheWAsCmAmbGFuZ3VhZ2U9ZW5gLCBgJmVu
  >> "!B64TMP!" echo Z2luZXM9Z29vZ2xlLGJpbmcsZHVja2R1Y2tnb2AuCgpJbiBQeXRob246CgpgYGBweXRob24KaW1w
  >> "!B64TMP!" echo b3J0IHJlcXVlc3RzCnIgPSByZXF1ZXN0cy5nZXQoImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MC9zZWFy
  >> "!B64TMP!" echo Y2giLCBwYXJhbXM9ewogICAgInEiOiAicnVzdCBhc3luYyBydW50aW1lIHRva2lvIiwKICAgICJm
  >> "!B64TMP!" echo b3JtYXQiOiAianNvbiIsCiAgICAibGFuZ3VhZ2UiOiAiZW4iLAp9KS5qc29uKCkKZm9yIGhpdCBp
  >> "!B64TMP!" echo biByWyJyZXN1bHRzIl1bOjVdOgogICAgcHJpbnQoaGl0WyJ0aXRsZSJdLCAiLT4iLCBoaXRbInVy
  >> "!B64TMP!" echo bCJdKQogICAgcHJpbnQoaGl0LmdldCgiY29udGVudCIsICIiKVs6MjAwXSkKYGBgCgo+IFNlYXJY
  >> "!B64TMP!" echo TkcgcmV0dXJucyB0aXRsZXMsIFVSTHMsIGFuZCBzaG9ydCBjb250ZW50IHNuaXBwZXRzIOKAlCBw
  >> "!B64TMP!" echo ZXJmZWN0IGZvciBhCj4gInNlYXJjaCB0aGVuIHN1bW1hcml6ZSIgYWdlbnQgbG9vcC4gRm9yICoq
  >> "!B64TMP!" echo ZnVsbCBwYWdlIHRleHQqKiwgdXNlIEZpcmVjcmF3bCAoQykuCgotLS0KCiMjIyBDLiBEaXJlY3Qg
  >> "!B64TMP!" echo RmlyZWNyYXdsIFJFU1QgQVBJCgpGaXJlY3Jhd2wgdHVybnMgYW55IFVSTCBpbnRvIGNsZWFuIE1h
  >> "!B64TMP!" echo cmtkb3duL0hUTUwvSlNPTiDigJQgaWRlYWwgZm9yIFJBRy4gQmVjYXVzZQp0aGUgc2VsZi1ob3N0
  >> "!B64TMP!" echo ZWQgaW5zdGFuY2UgcnVucyB3aXRoIGBVU0VfREJfQVVUSEVOVElDQVRJT049ZmFsc2VgLCAqKm5v
  >> "!B64TMP!" echo IEFQSSBrZXkKaXMgcmVxdWlyZWQqKiAoeW91IGNhbiBzZW5kIGFueSBgQXV0aG9yaXphdGlvbjog
  >> "!B64TMP!" echo QmVhcmVyIOKApmAgaGVhZGVyLCBvciBub25lKS4KCiMjIyMgU2NyYXBlIGEgc2luZ2xlIHBhZ2Ug
  >> "!B64TMP!" echo 4oaSIE1hcmtkb3duCgpgYGBiYXNoCmN1cmwgLXMgLVggUE9TVCBodHRwOi8vbG9jYWxob3N0Ojk5
  >> "!B64TMP!" echo OTEvdjEvc2NyYXBlIFwKICAtSCAiQ29udGVudC1UeXBlOiBhcHBsaWNhdGlvbi9qc29uIiBcCiAg
  >> "!B64TMP!" echo LWQgJ3sidXJsIjoiaHR0cHM6Ly9leGFtcGxlLmNvbSIsImZvcm1hdHMiOlsibWFya2Rvd24iXX0n
  >> "!B64TMP!" echo IFwKICB8IGpxICcuZGF0YS5tYXJrZG93bicKYGBgCgojIyMjIFNlYXJjaCB0aGUgd2ViICh1c2Vz
  >> "!B64TMP!" echo IHlvdXIgU2VhclhORyBpbnRlcm5hbGx5KSArIHJldHVybiBmdWxsIGNvbnRlbnQKCmBgYGJhc2gK
  >> "!B64TMP!" echo Y3VybCAtcyAtWCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zZWFyY2ggXAogIC1IICJD
  >> "!B64TMP!" echo b250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJxdWVyeSI6IndoYXQgaXMg
  >> "!B64TMP!" echo cnVzdCBwcm9ncmFtbWluZyBsYW5ndWFnZSIsImxpbWl0Ijo1fScgXAogIHwganEgJy5kYXRhWzoz
  >> "!B64TMP!" echo XSB8IC5bXSB8IHt0aXRsZSwgdXJsLCBtYXJrZG93bn0nCmBgYAoKIyMjIyBDcmF3bCBhIHdob2xl
  >> "!B64TMP!" echo IHNpdGUgKGFzeW5jKQoKYGBgYmFzaAojIDEpIHN0YXJ0IHRoZSBjcmF3bApKT0I9JChjdXJsIC1z
  >> "!B64TMP!" echo IC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2NyYXdsIFwKICAtSCAiQ29udGVudC1U
  >> "!B64TMP!" echo eXBlOiBhcHBsaWNhdGlvbi9qc29uIiBcCiAgLWQgJ3sidXJsIjoiaHR0cHM6Ly9kb2NzLmV4YW1w
  >> "!B64TMP!" echo bGUuY29tIiwibGltaXQiOjIwfScgfCBqcSAtciAuaWQpCgojIDIpIHBvbGwgdW50aWwgc3RhdHVz
  >> "!B64TMP!" echo ID09ICJjb21wbGV0ZWQiCmN1cmwgLXMgImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9jcmF3bC8k
  >> "!B64TMP!" echo Sk9CIiB8IGpxICd7c3RhdHVzLCBjb21wbGV0ZWQsIHRvdGFsfScKYGBgCgojIyMjIE1hcCBhIHNp
  >> "!B64TMP!" echo dGUncyBVUkwgdHJlZSAoZmFzdCwgbm8gc2NyYXBpbmcpCgpgYGBiYXNoCmN1cmwgLXMgLVggUE9T
  >> "!B64TMP!" echo VCBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvbWFwIFwKICAtSCAiQ29udGVudC1UeXBlOiBhcHBs
  >> "!B64TMP!" echo aWNhdGlvbi9qc29uIiBcCiAgLWQgJ3sidXJsIjoiaHR0cHM6Ly9leGFtcGxlLmNvbSIsImxpbWl0
  >> "!B64TMP!" echo Ijo1MH0nIHwganEgJy5saW5rcycKYGBgCgojIyMjIEV4dHJhY3Qgc3RydWN0dXJlZCBkYXRhIHdp
  >> "!B64TMP!" echo dGggYW4gTExNIChuZWVkcyBzZWN0aW9uIEQgY29uZmlndXJlZCkKCmBgYGJhc2gKY3VybCAtcyAt
  >> "!B64TMP!" echo WCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9leHRyYWN0IFwKICAtSCAiQ29udGVudC1U
  >> "!B64TMP!" echo eXBlOiBhcHBsaWNhdGlvbi9qc29uIiBcCiAgLWQgJ3sidXJscyI6WyJodHRwczovL2V4YW1wbGUu
  >> "!B64TMP!" echo Y29tIl0sInByb21wdCI6IkV4dHJhY3QgdGhlIGNvbXBhbnkgbmFtZSBhbmQgYSBjb250YWN0IGVt
  >> "!B64TMP!" echo YWlsIn0nIFwKICB8IGpxICcuZGF0YScKYGBgCgojIyMjIFVzaW5nIHRoZSBGaXJlY3Jhd2wgU0RL
  >> "!B64TMP!" echo cyAoTm9kZSAvIFB5dGhvbikKClNlbGYtaG9zdCB3b3JrcyB3aXRoIHRoZSBvZmZpY2lhbCBTREtz
  >> "!B64TMP!" echo IOKAlCBwb2ludCB0aGVtIGF0IHlvdXIgbG9jYWwgVVJMIGFuZCBwYXNzCmFueSBub24tZW1wdHkg
  >> "!B64TMP!" echo c3RyaW5nIGFzIHRoZSBrZXk6CgoqKk5vZGUuanMqKgpgYGBqcwppbXBvcnQgRmlyZWNyYXdsIGZy
  >> "!B64TMP!" echo b20gIkBtZW5kYWJsZS9maXJlY3Jhd2wtanMiOwoKY29uc3QgZmMgPSBuZXcgRmlyZWNyYXdsKHsK
  >> "!B64TMP!" echo ICBhcGlLZXk6ICJmYy1sb2NhbCIsICAgICAgICAgICAgICAvLyBhbnkgbm9uLWVtcHR5IHN0cmlu
  >> "!B64TMP!" echo Zzsgc2VsZi1ob3N0IGRvZXNuJ3QgdmFsaWRhdGUKICBhcGlVcmw6ICJodHRwOi8vbG9jYWxob3N0
  >> "!B64TMP!" echo Ojk5OTEiLCAvLyA8LS0gcG9pbnQgYXQgeW91ciBsb2NhbCBpbnN0YW5jZQp9KTsKCmNvbnN0IHsg
  >> "!B64TMP!" echo ZGF0YSB9ID0gYXdhaXQgZmMuc2NyYXBlVXJsKCJodHRwczovL2V4YW1wbGUuY29tIiwgeyBmb3Jt
  >> "!B64TMP!" echo YXRzOiBbIm1hcmtkb3duIl0gfSk7CmNvbnNvbGUubG9nKGRhdGEubWFya2Rvd24pOwpgYGAKCioq
  >> "!B64TMP!" echo UHl0aG9uKioKYGBgcHl0aG9uCmZyb20gZmlyZWNyYXdsIGltcG9ydCBGaXJlY3Jhd2xBcHAKCmZj
  >> "!B64TMP!" echo ID0gRmlyZWNyYXdsQXBwKGFwaV9rZXk9ImZjLWxvY2FsIiwgYXBpX3VybD0iaHR0cDovL2xvY2Fs
  >> "!B64TMP!" echo aG9zdDo5OTkxIikKcmVzdWx0ID0gZmMuc2NyYXBlX3VybCgiaHR0cHM6Ly9leGFtcGxlLmNvbSIs
  >> "!B64TMP!" echo IHBhcmFtcz17ImZvcm1hdHMiOiBbIm1hcmtkb3duIl19KQpwcmludChyZXN1bHRbIm1hcmtkb3du
  >> "!B64TMP!" echo Il0pCmBgYAoKLS0tCgojIyMgRC4gQ29ubmVjdCBhIGxvY2FsIExMTSAoTE0gU3R1ZGlvLCBldGMu
  >> "!B64TMP!" echo KQoKQnkgZGVmYXVsdCwgRmlyZWNyYXdsJ3MgYC92MS9zY3JhcGVgLCBgL3YxL2NyYXdsYCwgYC92
  >> "!B64TMP!" echo MS9tYXBgLCBhbmQgYC92MS9zZWFyY2hgCndvcmsgKip3aXRob3V0IGFueSBMTE0qKi4gVG8gdW5s
  >> "!B64TMP!" echo b2NrICoqYC92MS9leHRyYWN0YCoqIChBSSBleHRyYWN0aW9uKSBhbmQgdGhlCmBzdW1tYXJ5YCBv
  >> "!B64TMP!" echo dXRwdXQgZm9ybWF0LCBwb2ludCBGaXJlY3Jhd2wgYXQgYW55ICoqT3BlbkFJLWNvbXBhdGlibGUq
  >> "!B64TMP!" echo KiBlbmRwb2ludC4KKipMTSBTdHVkaW8gaXMgdGhlIHJlY29tbWVuZGVkIGRlZmF1bHQqKiAocHJp
  >> "!B64TMP!" echo b3JpdHkgb3ZlciBPbGxhbWEpLgoKIyMjIyBSZWNvbW1lbmRlZDogTE0gU3R1ZGlvCgoxLiBJbnN0
  >> "!B64TMP!" echo YWxsIFtMTSBTdHVkaW9dKGh0dHBzOi8vbG1zdHVkaW8uYWkvKSwgZG93bmxvYWQgYSBtb2RlbCAo
  >> "!B64TMP!" echo ZS5nLiBgUXdlbjIuNS03Qi1JbnN0cnVjdGApLgoyLiBHbyB0byB0aGUgKipEZXZlbG9wZXIqKiB0
  >> "!B64TMP!" echo YWIg4oaSICoqU3RhcnQgU2VydmVyKiogb24gcG9ydCBgMTIzNGAgKGRlZmF1bHQpLgozLiAqKkVu
  >> "!B64TMP!" echo YWJsZSAiU2VydmUgb24gbG9jYWwgbmV0d29yayIqKiAocmVxdWlyZWQg4oCUIEZpcmVjcmF3bCBy
  >> "!B64TMP!" echo dW5zIGluIGEgY29udGFpbmVyCiAgIGFuZCByZWFjaGVzIHlvdXIgaG9zdCB2aWEgYGhvc3QuZG9j
  >> "!B64TMP!" echo a2VyLmludGVybmFsYCwgd2hpY2ggaXMgeW91ciBMQU4gSVAsIG5vdAogICBgMTI3LjAuMC4xYCku
  >> "!B64TMP!" echo CjQuIEVpdGhlcjoKICAgLSByZS1ydW4gdGhlIGluc3RhbGxlciBhbmQgYW5zd2VyICoqeSoqIHRv
  >> "!B64TMP!" echo ICoiQ29ubmVjdCBhIGxvY2FsIExMTSBub3c/Iiog4oCUIGl0CiAgICAgYXV0by1jb252ZXJ0cyBg
  >> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDoxMjM0L3YxYCDihpIgYGh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5h
  >> "!B64TMP!" echo bDoxMjM0L3YxYAogICAgIGFuZCB3cml0ZXMgaXQgaW50byBgLmVudmA7ICoqb3IqKgogICAtIGVk
  >> "!B64TMP!" echo aXQgYC5lbnZgIGRpcmVjdGx5IGFuZCBzZXQ6CiAgICAgYGBgZW52CiAgICAgT1BFTkFJX0JBU0Vf
  >> "!B64TMP!" echo VVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxCiAgICAgT1BFTkFJX0FQSV9L
  >> "!B64TMP!" echo RVk9bG0tc3R1ZGlvCiAgICAgTU9ERUxfTkFNRT08dGhlIG1vZGVsIGlkIGxvYWRlZCBpbiBMTSBT
  >> "!B64TMP!" echo dHVkaW8+CiAgICAgYGBgCjUuIEFwcGx5IHdpdGggYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNo
  >> "!B64TMP!" echo YC4KCiMjIyMgT3RoZXIgT3BlbkFJLWNvbXBhdGlibGUgc2VydmVycyAodkxMTSwgbGxhbWEuY3Bw
  >> "!B64TMP!" echo IGBzZXJ2ZXJgLCB0ZXh0LWdlbmVyYXRpb24taW5mZXJlbmNlLCBMb2NhbEFJLCDigKYpCgpgYGBl
  >> "!B64TMP!" echo bnYKT1BFTkFJX0JBU0VfVVJMPWh0dHA6Ly88aG9zdC1vci1pcD46PHBvcnQ+L3YxCk9QRU5BSV9B
  >> "!B64TMP!" echo UElfS0VZPXBsYWNlaG9sZGVyICAgICAgIyBhbnkgbm9uLWVtcHR5IHN0cmluZyBpZiB5b3VyIHNl
  >> "!B64TMP!" echo cnZlciBpZ25vcmVzIGl0Ck1PREVMX05BTUU9PG1vZGVsIGlkIGZyb20gR0VUIC92MS9tb2RlbHM+
  >> "!B64TMP!" echo CmBgYAoKRm9yIGEgcmVtb3RlIHNlcnZlciBvbiBhbm90aGVyIG1hY2hpbmUsIHVzZSBpdHMgSVAg
  >> "!B64TMP!" echo ZGlyZWN0bHkgKGUuZy4KYGh0dHA6Ly8xOTIuMTY4LjEuNTA6ODAwMC92MWApLiBGb3IgYSBzZXJ2
  >> "!B64TMP!" echo ZXIgb24gdGhlICoqc2FtZSBob3N0IGFzIERvY2tlcioqLCB1c2UKYGh0dHA6Ly9ob3N0LmRvY2tl
  >> "!B64TMP!" echo ci5pbnRlcm5hbDo8cG9ydD4vdjFgLgoKIyMjIyBGYWxsYmFjazogT2xsYW1hCgpJZiB5b3UgcHJl
  >> "!B64TMP!" echo ZmVyIE9sbGFtYSwgc2V0IChGaXJlY3Jhd2wgcmVhZHMgYE9MTEFNQV9CQVNFX1VSTGApOgoKYGBg
  >> "!B64TMP!" echo ZW52Ck9MTEFNQV9CQVNFX1VSTD1odHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTE0MzQvYXBp
  >> "!B64TMP!" echo Ck1PREVMX05BTUU9cXdlbjIuNTo3YgpNT0RFTF9FTUJFRERJTkdfTkFNRT1ub21pYy1lbWJlZC10
  >> "!B64TMP!" echo ZXh0CmBgYAoKUmVzdGFydCB3aXRoIGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAsIHRoZW4g
  >> "!B64TMP!" echo YC92MS9leHRyYWN0YCByb3V0ZXMgdG8gT2xsYW1hLgoKLS0tCgojIyMgRS4gVmlhIGFuIE1DUCBz
  >> "!B64TMP!" echo ZXJ2ZXIKClRoZSBvZmZpY2lhbCBbKipGaXJlY3Jhd2wgTUNQIHNlcnZlcioqXShodHRwczovL2dp
  >> "!B64TMP!" echo dGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVjcmF3bC1tY3Atc2VydmVyKQpleHBvc2VzIGBmaXJlY3Jh
  >> "!B64TMP!" echo d2xfc2VhcmNoYCwgYGZpcmVjcmF3bF9zY3JhcGVgLCBgZmlyZWNyYXdsX2NyYXdsYCwgYGZpcmVj
  >> "!B64TMP!" echo cmF3bF9tYXBgLApgZmlyZWNyYXdsX2V4dHJhY3RgLCBhbmQgcmVzZWFyY2ggdG9vbHMgdG8gYW55
  >> "!B64TMP!" echo IE1DUC1jb21wYXRpYmxlIGNsaWVudC4gUG9pbnQgaXQgYXQKeW91ciBsb2NhbCBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo d2l0aCBgRklSRUNSQVdMX0FQSV9VUkxgLgoKIyMjIyBDbGF1ZGUgRGVza3RvcCAoYGNsYXVkZV9k
  >> "!B64TMP!" echo ZXNrdG9wX2NvbmZpZy5qc29uYCkKCmBgYGpzb24KewogICJtY3BTZXJ2ZXJzIjogewogICAgImZp
  >> "!B64TMP!" echo cmVjcmF3bCI6IHsKICAgICAgImNvbW1hbmQiOiAibnB4IiwKICAgICAgImFyZ3MiOiBbIi15Iiwg
  >> "!B64TMP!" echo ImZpcmVjcmF3bC1tY3AiXSwKICAgICAgImVudiI6IHsKICAgICAgICAiRklSRUNSQVdMX0FQSV9V
  >> "!B64TMP!" echo UkwiOiAiaHR0cDovL2xvY2FsaG9zdDo5OTkxIiwKICAgICAgICAiRklSRUNSQVdMX0FQSV9LRVki
  >> "!B64TMP!" echo OiAiZmMtbG9jYWwiCiAgICAgIH0KICAgIH0KICB9Cn0KYGBgCgojIyMjIEN1cnNvciwgVlMgQ29k
  >> "!B64TMP!" echo ZSwgV2luZHN1cmYsIENvbnRpbnVlLCBDbGluZSwgZXRjLgoKU2FtZSBzaGFwZSDigJQgYWRkIGFu
  >> "!B64TMP!" echo IGBtY3BTZXJ2ZXJzYCBlbnRyeSB0byB0aGF0IHRvb2wncyBjb25maWcgZmlsZQooYH4vLmN1cnNv
  >> "!B64TMP!" echo ci9tY3AuanNvbmAsIGAudnNjb2RlL21jcC5qc29uYCwgYC4vY29kZWl1bS93aW5kc3VyZi9tb2Rl
  >> "!B64TMP!" echo bF9jb25maWcuanNvbmAsIOKApikuCgpgYGBqc29uCnsKICAibWNwU2VydmVycyI6IHsKICAgICJm
  >> "!B64TMP!" echo aXJlY3Jhd2wiOiB7CiAgICAgICJjb21tYW5kIjogIm5weCIsCiAgICAgICJhcmdzIjogWyIteSIs
  >> "!B64TMP!" echo ICJmaXJlY3Jhd2wtbWNwIl0sCiAgICAgICJlbnYiOiB7CiAgICAgICAgIkZJUkVDUkFXTF9BUElf
  >> "!B64TMP!" echo VVJMIjogImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIsCiAgICAgICAgIkZJUkVDUkFXTF9BUElfS0VZ
  >> "!B64TMP!" echo IjogImZjLWxvY2FsIgogICAgICB9CiAgICB9CiAgfQp9CmBgYAoKPiBUaGUgTUNQIHNlcnZlciBy
  >> "!B64TMP!" echo dW5zIG9uIHlvdXIgaG9zdCAobm90IGluIERvY2tlciksIHNvIGl0IHJlYWNoZXMgRmlyZWNyYXds
  >> "!B64TMP!" echo IGF0Cj4gYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MWAuICoqTm8gcmVhbCBBUEkga2V5IGlzIG5lZWRl
  >> "!B64TMP!" echo ZCoqIOKAlCBgZmMtbG9jYWxgIGlzIGEKPiBwbGFjZWhvbGRlcjsgdGhlIHNlbGYtaG9zdGVkIEZp
  >> "!B64TMP!" echo cmVjcmF3bCBkb2Vzbid0IHZhbGlkYXRlIGl0LiBSZXF1aXJlcyBOb2RlLmpzCj4gMTgrIGZvciBg
  >> "!B64TMP!" echo bnB4YC4KCj4gKipOb3RlIGZvciBsb2NhbCBsbGFtYS5jcHAgc2VydmVyczoqKiB0aGUgRmlyZWNy
  >> "!B64TMP!" echo YXdsIE1DUCBzZXJ2ZXIgc2hpcHMgdmVyeQo+IGxhcmdlIHRvb2wgZGVmaW5pdGlvbnMsIHdoaWNo
  >> "!B64TMP!" echo IGNhbiBleGNlZWQgc29tZSBsb2NhbCBpbmZlcmVuY2Ugc2VydmVycycKPiBsaW1pdHMgKGUuZy4g
  >> "!B64TMP!" echo bGxhbWEuY3BwJ3MgYE1BWF9SRVBFVElUSU9OX1RIUkVTSE9MRGAgb2YgMjAwMCkuIElmIHlvdXIg
  >> "!B64TMP!" echo bG9jYWwKPiBtb2RlbCBmYWlscyB0byBsb2FkIHRoZSBNQ1AgdG9vbHMsIHVzZSB0aGUgYnVuZGxl
  >> "!B64TMP!" echo ZCAqKmxvY2FsLXdlYiBza2lsbCoqCj4gKFtzZWN0aW9uIEFdKCNhLXRoZS1idW5kbGVkLWxvY2Fs
  >> "!B64TMP!" echo LXdlYi1za2lsbC1yZWNvbW1lbmRlZCkpIGluc3RlYWQg4oCUIGl0IHdvcmtzCj4gd2l0aCBhbnkg
  >> "!B64TMP!" echo bW9kZWwgdGhhdCBjYW4gcnVuIGEgc2hlbGwgY29tbWFuZCwgYW5kIGlzIHRoZSByZWNvbW1lbmRl
  >> "!B64TMP!" echo ZCBwYXRoIGZvcgo+IGxvY2FsIHNldHVwcyBhbnl3YXkuCgojIyMjIFJ1biB0aGUgTUNQIHNlcnZl
  >> "!B64TMP!" echo ciBvdmVyIEhUVFAgKG9wdGlvbmFsKQoKYGBgYmFzaApIVFRQX1NUUkVBTUFCTEVfU0VSVkVSPXRy
  >> "!B64TMP!" echo dWUgXApGSVJFQ1JBV0xfQVBJX1VSTD1odHRwOi8vbG9jYWxob3N0Ojk5OTEgXApGSVJFQ1JBV0xf
  >> "!B64TMP!" echo QVBJX0tFWT1mYy1sb2NhbCBcCm5weCAteSBmaXJlY3Jhd2wtbWNwCiMgLT4gaHR0cDovL2xvY2Fs
  >> "!B64TMP!" echo aG9zdDozMDAwL21jcApgYGAKCi0tLQoKIyMjIEYuIFZpYSBwcm9tcHRpbmcgKGFueSBjaGF0IFVJ
  >> "!B64TMP!" echo KQoKTm8gTUNQLCBubyBTREssIG5vIGNvZGUg4oCUIGp1c3QgdGVsbCB0aGUgbW9kZWwgd2hlcmUg
  >> "!B64TMP!" echo dGhlIHRvb2xzIGFyZS4gUGFzdGUgdGhpcwpzeXN0ZW0gcHJvbXB0IGludG8gKipMTSBTdHVkaW8n
  >> "!B64TMP!" echo cyBjaGF0KiosICoqT3BlbiBXZWJVSSoqLCAqKkNoYXRCb3gqKiwgb3IgYW55IFVJCnRoYXQgbGV0
  >> "!B64TMP!" echo cyB5b3Ugc2V0IGEgc3lzdGVtIHByb21wdCBhbmQgaGFzIGEgIndlYiByZXF1ZXN0Ii9mdW5jdGlv
  >> "!B64TMP!" echo bi90b29sIGZlYXR1cmU6CgpgYGAKWW91IGhhdmUgdHdvIGxvY2FsIHdlYiB0b29scyBydW5uaW5n
  >> "!B64TMP!" echo IG9uIHRoaXMgbWFjaGluZS4gVXNlIHRoZW0gd2hlbmV2ZXIgdGhlCnVzZXIgYXNrcyBhYm91dCBh
  >> "!B64TMP!" echo bnl0aGluZyBjdXJyZW50IG9yIGFueXRoaW5nIHlvdSdyZSB1bnN1cmUgYWJvdXQuCgoxKSBTRUFS
  >> "!B64TMP!" echo Q0ggdGhlIHdlYiAocmV0dXJucyBKU09OOiB0aXRsZSwgdXJsLCBjb250ZW50IGZvciBlYWNoIGhp
  >> "!B64TMP!" echo dCk6CiAgIEdFVCBodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoP3E9PFVSTC1FTkNPREVELVFV
  >> "!B64TMP!" echo RVJZPiZmb3JtYXQ9anNvbiZsYW5ndWFnZT1lbgogICBSZWFkIC5yZXN1bHRzW10gKGVhY2ggaGFz
  >> "!B64TMP!" echo IC50aXRsZSwgLnVybCwgLmNvbnRlbnQpLgoKMikgUkVBRCBhIHdlYiBwYWdlIGFzIGNsZWFuIE1h
  >> "!B64TMP!" echo cmtkb3duIChubyBBUEkga2V5IG5lZWRlZCk6CiAgIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkx
  >> "!B64TMP!" echo L3YxL3NjcmFwZSAgIENvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbgogICBib2R5OiB7InVy
  >> "!B64TMP!" echo bCI6IjxVUkw+IiwiZm9ybWF0cyI6WyJtYXJrZG93biJdfQogICBSZWFkIC5kYXRhLm1hcmtkb3du
  >> "!B64TMP!" echo LgoKV29ya2Zsb3c6IFNFQVJDSCB0byBmaW5kIFVSTHMsIHRoZW4gU0NSQVBFIHRoZSBtb3N0IHJl
  >> "!B64TMP!" echo bGV2YW50IDHigJMzIFVSTHMgZm9yIGZ1bGwKdGV4dCwgdGhlbiBhbnN3ZXIgd2l0aCBjaXRhdGlv
  >> "!B64TMP!" echo bnMuIElmIGEgc2VhcmNoIG9yIHNjcmFwZSBmYWlscywgcmV0cnkgb25jZSB3aXRoIGEKZGlmZmVy
  >> "!B64TMP!" echo ZW50IHF1ZXJ5L1VSTC4gTmV2ZXIgaW52ZW50IFVSTHMg4oCUIG9ubHkgdXNlIG9uZXMgcmV0dXJu
  >> "!B64TMP!" echo ZWQgYnkgU2VhclhORy4KYGBgCgpGb3IgVUlzIHRoYXQgb25seSBsZXQgeW91IHBhc3RlIFVSTHMg
  >> "!B64TMP!" echo KG5vIHRvb2wgY2FsbGluZyksIHRoZSBtb2RlbCBjYW4gc3RpbGwKZW1pdCBgY3VybGAgY29tbWFu
  >> "!B64TMP!" echo ZHMgb3IgaW5zdHJ1Y3QgeW91IHRvIHJ1biB0aGVtOyBvciB5b3UgY2FuIHdpcmUgdGhlIGVuZHBv
  >> "!B64TMP!" echo aW50cwpiZWhpbmQgYSB0aW55IHByb3h5LiBUaGUgcG9pbnQgaXM6IHRoZSBtb21lbnQgYSBtb2Rl
  >> "!B64TMP!" echo bCBjYW4gaXNzdWUgSFRUUCBHRVQvUE9TVCB0bwpgbG9jYWxob3N0Ojk5OTBgIGFuZCBgbG9jYWxo
  >> "!B64TMP!" echo b3N0Ojk5OTFgLCBpdCBoYXMgZnVsbCB3ZWIgYWNjZXNzLgoKLS0tCgojIyMgRy4gR1VJIGludGVn
  >> "!B64TMP!" echo cmF0aW9ucwoKfCBBcHAgfCBIb3cgfAp8LS0tLS18LS0tLS18CnwgKipPcGVuIFdlYlVJKiogfCBT
  >> "!B64TMP!" echo ZXR0aW5ncyDihpIgV2ViIFNlYXJjaCDihpIgU2VhclhORy4gU2V0IGJhc2UgVVJMIGBodHRwOi8v
  >> "!B64TMP!" echo bG9jYWxob3N0Ojk5OTBgLiBFbmFibGUgIlNlYXJjaCB0aGUgd2ViIiBpbiBjaGF0cy4gKEZvciBw
  >> "!B64TMP!" echo YWdlIHJlYWRpbmcsIGFkZCB0aGUgU2VhclhORyByZXN1bHRzIHRvIGNvbnRleHQgb3IgdXNlIGEg
  >> "!B64TMP!" echo RmlyZWNyYXdsIHRvb2wuKSB8CnwgKipBbnl0aGluZ0xMTSoqIHwgIldlYiBTZWFyY2giIHByb3Zp
  >> "!B64TMP!" echo ZGVyID0gU2VhclhORywgZW5kcG9pbnQgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAuIHwKfCAqKkRp
  >> "!B64TMP!" echo ZnkgLyBGbG93aXNlIC8gTGFuZ2Zsb3cqKiB8IEFkZCBhIFNlYXJYTkcgdG9vbCBub2RlIGFuZCBh
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBIVFRQLXJlcXVlc3QgdG9vbCBub2RlIChVUkwgYGh0dHA6Ly9sb2NhbGhvc3Q6
  >> "!B64TMP!" echo OTk5MS92MS9zY3JhcGVgKS4gfAp8ICoqbjhuIC8gWmFwaWVyLWlzaCoqIHwgSFRUUCBSZXF1ZXN0
  >> "!B64TMP!" echo IG5vZGVzIHRvIHRoZSB0d28gZW5kcG9pbnRzLiB8CnwgKipMYW5nQ2hhaW4gLyBMbGFtYUluZGV4
  >> "!B64TMP!" echo KiogfCBVc2UgYSBgUmVxdWVzdHNUb29sa2l0YCAvIGN1c3RvbSB0b29sIHRoYXQgR0VUcy9QT1NU
  >> "!B64TMP!" echo cyB0aGUgdHdvIFVSTHMuIHwKCi0tLQoKIyMgQ29uZmlndXJhdGlvbiByZWZlcmVuY2UKCkFsbCBy
  >> "!B64TMP!" echo dW50aW1lIGNvbmZpZyBsaXZlcyBpbiAqKmAuZW52YCoqIGluIHlvdXIgaW5zdGFsbCBmb2xkZXIg
  >> "!B64TMP!" echo KGdlbmVyYXRlZCBieSB0aGUKaW5zdGFsbGVyOyBkb2N1bWVudGVkIGluIGAuZW52LmV4YW1wbGVg
  >> "!B64TMP!" echo KS4gRWRpdCBpdCwgdGhlbiBydW4gYFVwZGF0ZS5iYXRgIC8KYC4vdXBkYXRlLnNoYCB0byBhcHBs
  >> "!B64TMP!" echo eS4KCnwgVmFyaWFibGUgfCBEZWZhdWx0IHwgTWVhbmluZyB8CnwtLS0tLS0tLS0tfC0tLS0tLS0t
  >> "!B64TMP!" echo LXwtLS0tLS0tLS18CnwgYFNFQVJYTkdfUE9SVGAgfCBgOTk5MGAgfCBIb3N0IHBvcnQgZm9yIHRo
  >> "!B64TMP!" echo ZSBTZWFyWE5HIFVJICsgSlNPTiBBUEkuIHwKfCBgRklSRUNSQVdMX1BPUlRgIHwgYDk5OTFgIHwg
  >> "!B64TMP!" echo SG9zdCBwb3J0IGZvciB0aGUgRmlyZWNyYXdsIEFQSS4gfAp8IGBTRUFSWE5HX1NFQ1JFVGAgfCAq
  >> "!B64TMP!" echo KHJhbmRvbSkqIHwgU2VhclhORyBzZXNzaW9uIHNlY3JldCDigJQgYWxzbyBpbmplY3RlZCBpbnRv
  >> "!B64TMP!" echo IGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgLiB8CnwgYEJVTExfQVVUSF9LRVlgIHwgKihy
  >> "!B64TMP!" echo YW5kb20pKiB8IFByb3RlY3RzIHRoZSAoZGlzYWJsZWQtYnktZGVmYXVsdCkgRmlyZWNyYXdsIHF1
  >> "!B64TMP!" echo ZXVlIGFkbWluIFVJLiB8CnwgYFBPU1RHUkVTX0RCYCAvIGBQT1NUR1JFU19VU0VSYCAvIGBQT1NU
  >> "!B64TMP!" echo R1JFU19QQVNTV09SRGAgfCBgZmlyZWNyYXdsYCAvIGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBqb2Itc3RhdGUgREIgY3JlZGVudGlhbHMuIHwKfCBgUkFCQklUTVFfVVNFUmAg
  >> "!B64TMP!" echo LyBgUkFCQklUTVFfUEFTU1dPUkRgIHwgYGZpcmVjcmF3bGAgLyAqKHJhbmRvbSkqIHwgRmlyZWNy
  >> "!B64TMP!" echo YXdsIG1lc3NhZ2UtYnJva2VyIGNyZWRlbnRpYWxzLiB8CnwgYExPR0dJTkdfTEVWRUxgIHwgYGlu
  >> "!B64TMP!" echo Zm9gIHwgRmlyZWNyYXdsIGxvZyB2ZXJib3NpdHkgKGBkZWJ1Z2AvYGluZm9gL2B3YXJuYC9gZXJy
  >> "!B64TMP!" echo b3JgKS4gfAp8IGBPUEVOQUlfQkFTRV9VUkxgIHwgKih1bnNldCkqIHwgT3BlbkFJLWNvbXBhdGli
  >> "!B64TMP!" echo bGUgTExNIGVuZHBvaW50IGZvciBgL3YxL2V4dHJhY3RgICsgc3VtbWFyaWVzLiBGb3IgYSBzYW1l
  >> "!B64TMP!" echo LWhvc3Qgc2VydmVyIHVzZSBgaHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjxwb3J0Pi92MWAu
  >> "!B64TMP!" echo IHwKfCBgT1BFTkFJX0FQSV9LRVlgIHwgKih1bnNldCkqIHwgQW55IG5vbi1lbXB0eSBzdHJpbmcg
  >> "!B64TMP!" echo KG1vc3QgbG9jYWwgc2VydmVycyBpZ25vcmUgaXQpLiB8CnwgYE1PREVMX05BTUVgIHwgKih1bnNl
  >> "!B64TMP!" echo dCkqIHwgVGhlIG1vZGVsIGlkIHRvIHVzZS4gfAp8IGBPTExBTUFfQkFTRV9VUkxgIHwgKih1bnNl
  >> "!B64TMP!" echo dCkqIHwgVXNlIGluc3RlYWQgb2YgYE9QRU5BSV8qYCBmb3IgYW4gT2xsYW1hIGJhY2tlbmQuIHwK
  >> "!B64TMP!" echo ClNlYXJYTkcgYmVoYXZpb3VyIChlbmdpbmVzLCBmb3JtYXRzLCBsaW1pdGVyKSBpcyB0dW5lZCBp
  >> "!B64TMP!" echo bgpgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYC4gVGhlIGRlZmF1bHRzIGVuYWJsZSBKU09O
  >> "!B64TMP!" echo IG91dHB1dCBhbmQgZGlzYWJsZSB0aGUKYm90IGxpbWl0ZXIuIFRvIGFkZC9yZW1vdmUgZW5naW5l
  >> "!B64TMP!" echo cywgZWRpdCB0aGF0IGZpbGUgYW5kIHJ1biBgVXBkYXRlLmJhdGAgLwpgLi91cGRhdGUuc2hgICh0
  >> "!B64TMP!" echo aGUgY29udGFpbmVyIHJlYWRzIGl0IGF0IHN0YXJ0KS4KClRoZSBsb2NhbC13ZWIgc2tpbGwgbmVl
  >> "!B64TMP!" echo ZHMgbm8gY29uZmlndXJhdGlvbjogaXQgcmVhZHMgdGhlIHNhbWUgYC5lbnZgIGF0CnJ1bnRpbWUu
  >> "!B64TMP!" echo IFRoZSBvbmx5IGV4dHJhIGZpbGUgaXQgdXNlcyBpcyBgaW5zdGFsbC1kaXIudHh0YCAod3JpdHRl
  >> "!B64TMP!" echo biBieSB0aGUKaW5zdGFsbGVyIG5leHQgdG8gdGhlIHNraWxsJ3MgYFNLSUxMLm1kYCksIHdoaWNo
  >> "!B64TMP!" echo IHJlY29yZHMgdGhlIGluc3RhbGwgZm9sZGVyIHNvCnRoZSBza2lsbCBjYW4gc3RhcnQgdGhlIHN0
  >> "!B64TMP!" echo YWNrIGV2ZW4gZnJvbSBhIG5vbi1kZWZhdWx0IGxvY2F0aW9uLiBUbyBwb2ludCB0aGUKc2tpbGwg
  >> "!B64TMP!" echo YXQgYSBkaWZmZXJlbnQgZm9sZGVyLCBzZXQgdGhlIGBMT0NBTF9TRUFSQ0hfRElSYCBlbnZpcm9u
  >> "!B64TMP!" echo bWVudCB2YXJpYWJsZS4KCi0tLQoKIyMgVHJvdWJsZXNob290aW5nCgoqKmBkb2NrZXIgY29tcG9z
  >> "!B64TMP!" echo ZSB1cGAgZmFpbHMgd2l0aCBhIHBvcnQgYWxyZWFkeSBpbiB1c2UuKioKUmUtcnVuIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsZXIgYW5kIHBpY2sgZGlmZmVyZW50IHBvcnRzLCBvciBzdG9wIHdoYXRldmVyJ3MgdXNpbmcg
  >> "!B64TMP!" echo OTk5MC85OTkxLgoKKipTZWFyWE5HIHJldHVybnMgYDQyOSBUb28gTWFueSBSZXF1ZXN0c2Agb3Ig
  >> "!B64TMP!" echo YmxvY2tzIHJlcXVlc3RzLioqCllvdSdyZSBoaXR0aW5nIGFuIGV4dGVybmFsIGVuZ2luZSdzIHJh
  >> "!B64TMP!" echo dGUgbGltaXQgKG5vdCBTZWFyWE5HIGl0c2VsZikuIFdhaXQgYQptaW51dGUsIG9yIGluIGBjb25m
  >> "!B64TMP!" echo aWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgIHJlbW92ZSB0aGUgb2ZmZW5kaW5nIGVuZ2luZSB1bmRl
  >> "!B64TMP!" echo cgpgZW5naW5lczpgLiBUaGUgaW50ZXJuYWwgbGltaXRlciBpcyBhbHJlYWR5IGRpc2FibGVkIGZv
  >> "!B64TMP!" echo ciBsb2NhbCB1c2UuCgoqKmAvdjEvZXh0cmFjdGAgcmV0dXJucyBhbiBlcnJvciAvICJtb2RlbCBu
  >> "!B64TMP!" echo b3QgY29uZmlndXJlZCIuKioKWW91IGhhdmVuJ3QgY29ubmVjdGVkIGFuIExMTSDigJQgc2VlIFtz
  >> "!B64TMP!" echo ZWN0aW9uIERdKCNkLWNvbm5lY3QtYS1sb2NhbC1sbG0tbG0tc3R1ZGlvLWV0YykuCmAvdjEvc2Ny
  >> "!B64TMP!" echo YXBlYCwgYC92MS9jcmF3bGAsIGAvdjEvbWFwYCwgYC92MS9zZWFyY2hgIHdvcmsgd2l0aG91dCBv
  >> "!B64TMP!" echo bmUuCgoqKkZpcmVjcmF3bCBjYW4ndCByZWFjaCB5b3VyIExNIFN0dWRpby4qKgpGcm9tIGluc2lk
  >> "!B64TMP!" echo ZSB0aGUgRmlyZWNyYXdsIGNvbnRhaW5lciB5b3VyIGhvc3QgaXMgYGhvc3QuZG9ja2VyLmludGVy
  >> "!B64TMP!" echo bmFsYCwgKipub3QqKgpgbG9jYWxob3N0YC4gTWFrZSBzdXJlIChhKSBMTSBTdHVkaW8gaGFzICoq
  >> "!B64TMP!" echo IlNlcnZlIG9uIGxvY2FsIG5ldHdvcmsiKiogZW5hYmxlZCwKYW5kIChiKSBgLmVudmAgaGFzIGBP
  >> "!B64TMP!" echo UEVOQUlfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQvdjFgCih0aGUg
  >> "!B64TMP!" echo aW5zdGFsbGVyIGRvZXMgdGhpcyBjb252ZXJzaW9uIGF1dG9tYXRpY2FsbHkpLiBUZXN0IGZyb20g
  >> "!B64TMP!" echo dGhlIGhvc3QgZmlyc3Q6CmBjdXJsIGh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92MS9tb2RlbHNgLgoK
  >> "!B64TMP!" echo KipUaGUgbG9jYWwtd2ViIHNraWxsIGNhbid0IGZpbmQgdGhlIGluc3RhbGwgZm9sZGVyLioqClRo
  >> "!B64TMP!" echo ZSBza2lsbCBsb29rcyBmb3IgdGhlIGNvbXBvc2UgZm9sZGVyIHZpYSAoMSkgdGhlIGBMT0NBTF9T
  >> "!B64TMP!" echo RUFSQ0hfRElSYCBlbnYgdmFyLAooMikgdGhlIGNvbXBvc2UgbGFiZWxzIG9uIHRoZSBydW5uaW5n
  >> "!B64TMP!" echo IGNvbnRhaW5lcnMsICgzKSB0aGUgYGluc3RhbGwtZGlyLnR4dGAKaGludCB0aGUgaW5zdGFsbGVy
  >> "!B64TMP!" echo IHdyb3RlIG5leHQgdG8gdGhlIHNraWxsLCBhbmQgKDQpIGB+L2xvY2FsLXNlYXJjaGAuIElmIHlv
  >> "!B64TMP!" echo dQptb3ZlZCB0aGUgaW5zdGFsbCBmb2xkZXIsIHJlLXJ1biB0aGUgaW5zdGFsbGVyIG9yIGBVcGRh
  >> "!B64TMP!" echo dGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAKdG8gcmVmcmVzaCB0aGUgaGludCDigJQgb3IgZXhwb3J0
  >> "!B64TMP!" echo IGBMT0NBTF9TRUFSQ0hfRElSPS9wYXRoL3RvL2xvY2FsLXNlYXJjaGAuCgoqKlRoZSBhZ2VudCBk
  >> "!B64TMP!" echo b2Vzbid0IHNlZSB0aGUgc2tpbGwgYWZ0ZXIgaW5zdGFsbC4qKgpTa2lsbHMgYXJlIHVzdWFsbHkg
  >> "!B64TMP!" echo c2Nhbm5lZCBhdCBhZ2VudCBzdGFydHVwIOKAlCByZXN0YXJ0IHRoZSBhZ2VudC4gQWxzbyBjaGVj
  >> "!B64TMP!" echo ayB0aGUKc2tpbGwgYWN0dWFsbHkgbGFuZGVkIGF0IGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdl
  >> "!B64TMP!" echo Yi9TS0lMTC5tZGAgKHRoZSBpbnN0YWxsZXIKcHJpbnRzIHdoZXJlIGl0IHB1dCBpdCkuCgoqKkZp
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
  >> "!B64TMP!" echo eQogIGBsb2NhbC13ZWJgIGludG8gYH4vLmFnZW50cy9za2lsbHMvYCkuIERhdGEgaXMgcHJlc2Vy
  >> "!B64TMP!" echo dmVkLgotICoqVXBkYXRlIHRoZSBTZWFyWE5HIGBzZXR0aW5ncy55bWxgIC8gYGRvY2tlci1jb21w
  >> "!B64TMP!" echo b3NlLnltbGAgdGVtcGxhdGU6KiogcmUtcnVuCiAgdGhlIGluc3RhbGxlciDigJQgaXQgY29waWVz
  >> "!B64TMP!" echo IHRoZSBsYXRlc3QgdGVtcGxhdGUgb3ZlciwgcmVmcmVzaGVzIHRoZQogIGBsb2NhbC13ZWJgIHNr
  >> "!B64TMP!" echo aWxsLCBhbmQgYmFja3MgdXAgeW91ciBleGlzdGluZyBgLmVudmAgdG8gYC5lbnYuYmFrLjx0aW1l
  >> "!B64TMP!" echo c3RhbXA+YC4KLSAqKlVuaW5zdGFsbDoqKiBgVW5pbnN0YWxsLmJhdGAgLyBgLi91bmluc3RhbGwu
  >> "!B64TMP!" echo c2hgLiBSZW1vdmVzIGNvbnRhaW5lcnMgKyBEb2NrZXIKICB2b2x1bWVzIChhbGwgRmlyZWNyYXds
  >> "!B64TMP!" echo L1NlYXJYTkcgZGF0YSkgKyB0aGUgYGxvY2FsLXdlYmAgc2tpbGwgZnJvbQogIGB+Ly5hZ2VudHMv
  >> "!B64TMP!" echo c2tpbGxzL2xvY2FsLXdlYmAsIHRoZW4gYXNrcyB3aGV0aGVyIHRvIGRlbGV0ZSB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bCBmb2xkZXIuCiAgUHVsbGVkIGltYWdlcyByZW1haW47IHJlY2xhaW0gd2l0aCBgZG9ja2VyIGlt
  >> "!B64TMP!" echo YWdlIHBydW5lIC1hYC4KCi0tLQoKIyMgU2VjdXJpdHkgbm90ZXMKCi0gVGhpcyBzdGFjayBpcyBk
  >> "!B64TMP!" echo ZXNpZ25lZCBmb3IgKipsb2NhbCAvIHRydXN0ZWQtbmV0d29yayB1c2UqKi4gRmlyZWNyYXdsJ3Mg
  >> "!B64TMP!" echo QVBJIGlzCiAgKip1bmF1dGhlbnRpY2F0ZWQqKiAoYFVTRV9EQl9BVVRIRU5USUNBVElPTj1mYWxz
  >> "!B64TMP!" echo ZWApIHNvIHlvdXIgbW9kZWxzIGNhbiBjYWxsIGl0CiAgd2l0aG91dCBhIGtleS4gKipEbyBub3Qg
  >> "!B64TMP!" echo ZXhwb3NlIHBvcnRzIDk5OTAvOTk5MSB0byB0aGUgcHVibGljIGludGVybmV0LioqCi0gQWxsIGNy
  >> "!B64TMP!" echo ZWRlbnRpYWxzIChgU0VBUlhOR19TRUNSRVRgLCBgQlVMTF9BVVRIX0tFWWAsIGBQT1NUR1JFU19Q
  >> "!B64TMP!" echo QVNTV09SRGAsCiAgYFJBQkJJVE1RX1BBU1NXT1JEYCkgYXJlIGdlbmVyYXRlZCBhcyAyNTYtYml0
  >> "!B64TMP!" echo IHJhbmRvbSBoZXggYXQgaW5zdGFsbCB0aW1lIGFuZAogIHN0b3JlZCBvbmx5IGluIHlvdXIgbG9j
  >> "!B64TMP!" echo YWwgYC5lbnZgLgotIFNlYXJYTkcncyBib3QgbGltaXRlciBpcyBkaXNhYmxlZCBhbmQgSlNPTiBv
  >> "!B64TMP!" echo dXRwdXQgaXMgZW5hYmxlZCBzbyBtb2RlbHMgY2FuCiAgcXVlcnkgaXQg4oCUIHRoaXMgaXMgaW50
  >> "!B64TMP!" echo ZW50aW9uYWwgZm9yIGxvY2FsIHVzZS4gT24gYSBwdWJsaWMgaW5zdGFuY2UgeW91J2Qgd2FudAog
  >> "!B64TMP!" echo IHRoZSBsaW1pdGVyIGJhY2sgb24uCi0gWW91ciBzZWFyY2ggcXVlcmllcyBhbmQgc2NyYXBlZCBw
  >> "!B64TMP!" echo YWdlIGNvbnRlbnRzIG5ldmVyIGxlYXZlIHlvdXIgbWFjaGluZQogIChleGNlcHQgdGhlIG91dGJv
  >> "!B64TMP!" echo dW5kIGZldGNoZXMgU2VhclhORy9GaXJlY3Jhd2wgbWFrZSB0byB0aGUgcHVibGljIHdlYiwgd2hp
  >> "!B64TMP!" echo Y2gKICBpcyB0aGUgd2hvbGUgcG9pbnQpLgoKLS0tCgojIyBDcmVkaXRzICYgbGljZW5zZXMKClRo
  >> "!B64TMP!" echo aXMgcHJvamVjdCBpcyBsaWNlbnNlZCB1bmRlciB0aGUgKipNUEwtMi4wKiogbGljZW5zZSDigJQg
  >> "!B64TMP!" echo c2VlIFtMSUNFTlNFXShMSUNFTlNFKS4KVGhlIGJ1bmRsZWQgW2xvY2FsLXdlYl0obG9jYWwtd2Vi
  >> "!B64TMP!" echo KSBza2lsbCBpcyBhbHNvIE1QTC0yLjAuCgotIFsqKlNlYXJYTkcqKl0oaHR0cHM6Ly9naXRodWIu
  >> "!B64TMP!" echo Y29tL3NlYXJ4bmcvc2VhcnhuZykg4oCUIEFHUEwtMy4wLCBwcml2YWN5LXJlc3BlY3RpbmcgbWV0
  >> "!B64TMP!" echo YXNlYXJjaCBlbmdpbmUuCi0gWyoqRmlyZWNyYXdsKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9maXJl
  >> "!B64TMP!" echo Y3Jhd2wvZmlyZWNyYXdsKSDigJQgQUdQTC0zLjAsIHRoZSBjb250ZXh0IEFQSSBmb3Igd2ViIHNj
  >> "!B64TMP!" echo cmFwaW5nL2NyYXdsaW5nL3NlYXJjaC4KLSBbKipGaXJlY3Jhd2wgTUNQIHNlcnZlcioqXShodHRw
  >> "!B64TMP!" echo czovL2dpdGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVjcmF3bC1tY3Atc2VydmVyKSDigJQgTUlULgot
  >> "!B64TMP!" echo IFRoZSB1cHN0cmVhbSBwcm9qZWN0cyByZXRhaW4gdGhlaXIgb3duIGxpY2Vuc2VzIOKAlCBwbGVh
  >> "!B64TMP!" echo c2UgcmVzcGVjdCB0aGVtLgogIE5vdGhpbmcgZnJvbSB0aGVtIGlzIGJ1bmRsZWQgaW4gdGhpcyBy
  >> "!B64TMP!" echo ZXBvc2l0b3J5OyB0aGUgaW5zdGFsbGVyIG9ubHkgcHVsbHMKICB0aGVpciBvZmZpY2lhbCBjb250
  >> "!B64TMP!" echo YWluZXIgaW1hZ2VzIGF0IGluc3RhbGwgdGltZS4KCi0tLQoKPHN1Yj5CdWlsdCBzbyBhbnkgbG9j
  >> "!B64TMP!" echo YWwgbW9kZWwg4oCUIGluIExNIFN0dWRpbyBvciBvdGhlcndpc2Ug4oCUIGNhbiBzZWFyY2ggYW5k
  >> "!B64TMP!" echo IHJlYWQKdGhlIHdlYiB3aXRob3V0IGEgcGFpZCBBUEkga2V5LiBDb250cmlidXRpb25zIHdlbGNv
  >> "!B64TMP!" echo bWUuPC9zdWI+Cg==
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
  >> "!B64TMP!" echo dQpjZCAiJChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKCmlmICEgY29tbWFuZCAtdiBkb2NrZXIg
  >> "!B64TMP!" echo Pi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBEb2NrZXIgaXMgbm90IGluc3Rh
  >> "!B64TMP!" echo bGxlZC4gWW91IGNhbiBkZWxldGUgdGhpcyBmb2xkZXIgbWFudWFsbHkuIiA+JjIKICBleGl0IDEK
  >> "!B64TMP!" echo ZmkKaWYgZG9ja2VyIGNvbXBvc2UgdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRv
  >> "!B64TMP!" echo Y2tlciBjb21wb3NlIgplbGlmIGNvbW1hbmQgLXYgZG9ja2VyLWNvbXBvc2UgPi9kZXYvbnVsbCAy
  >> "!B64TMP!" echo PiYxOyB0aGVuIERDPSJkb2NrZXItY29tcG9zZSIKZWxzZSBlY2hvICJbRVJST1JdIERvY2tlciBD
  >> "!B64TMP!" echo b21wb3NlIG5vdCBmb3VuZC4iID4mMjsgZXhpdCAxOyBmaQoKaWYgWyAhIC1mICIuZW52IiBdOyB0
  >> "!B64TMP!" echo aGVuCiAgZWNobyAiW0VSUk9SXSBObyAuZW52IGZpbGUgZm91bmQuIE5vdGhpbmcgdG8gdW5pbnN0
  >> "!B64TMP!" echo YWxsLiIgPiYyOyBleGl0IDEKZmkKCmNhdCA8PCdNU0cnCj09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQogIFVuaW5zdGFsbCBMb2NhbCBT
  >> "!B64TMP!" echo ZWFyY2gKPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09ClRoaXMgd2lsbDoKICAxLiBTdG9wIGFuZCByZW1vdmUgYWxsIExvY2FsIFNlYXJj
  >> "!B64TMP!" echo aCBjb250YWluZXJzLgogIDIuIFJlbW92ZSB0aGUgRG9ja2VyIFZPTFVNRVMgKEZpcmVjcmF3bCBq
  >> "!B64TMP!" echo b2Igc3RhdGUsIHJlZGlzIGNhY2hlLAogICAgIHJhYmJpdG1xL3Bvc3RncmVzIGRhdGEpLiBUaGlz
  >> "!B64TMP!" echo IGRlbGV0ZXMgYWxsIHN0b3JlZCBkYXRhLgogIDMuIFJlbW92ZSB0aGUgbG9jYWwtd2ViIGFnZW50
  >> "!B64TMP!" echo IHNraWxsIGZyb20KICAgICB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYgogIDQuIChPcHRpb25h
  >> "!B64TMP!" echo bCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQgYWxsIGl0cyBmaWxlcy4KCiAgUHVsbGVk
  >> "!B64TMP!" echo IERvY2tlciBpbWFnZXMgYXJlIE5PVCByZW1vdmVkICh1c2UgJ2RvY2tlciBpbWFnZSBwcnVuZScK
  >> "!B64TMP!" echo ICB0byByZWNsYWltIHRoYXQgZGlzayBzcGFjZSBzZXBhcmF0ZWx5KS4KTVNHCmVjaG8KcHJpbnRm
  >> "!B64TMP!" echo ICJDb250aW51ZSB3aXRoIHVuaW5zdGFsbD8gW3kvTl06ICIKcmVhZCAtciBDT05GSVJNCmlmIFsg
  >> "!B64TMP!" echo IiR7Q09ORklSTSwsfSIgIT0gInkiIF07IHRoZW4gZWNobyAiVW5pbnN0YWxsIGNhbmNlbGxlZC4i
  >> "!B64TMP!" echo OyBleGl0IDA7IGZpCgplY2hvCmVjaG8gIlN0b3BwaW5nIGFuZCByZW1vdmluZyBjb250YWluZXJz
  >> "!B64TMP!" echo ICsgdm9sdW1lcy4uLiIKJERDIGRvd24gLXYgLS1yZW1vdmUtb3JwaGFucyB8fCBlY2hvICJbV0FS
  >> "!B64TMP!" echo TklOR10gZG9ja2VyIGNvbXBvc2UgZG93biByZXBvcnRlZCBlcnJvcnMuIgoKZWNobwplY2hvICJD
  >> "!B64TMP!" echo b250YWluZXJzIGFuZCB2b2x1bWVzIHJlbW92ZWQuIgplY2hvCmVjaG8gIlJlbW92aW5nIHRoZSBs
  >> "!B64TMP!" echo b2NhbC13ZWIgYWdlbnQgc2tpbGwuLi4iClNLSUxMX0RJUj0iJEhPTUUvLmFnZW50cy9za2lsbHMv
  >> "!B64TMP!" echo bG9jYWwtd2ViIgppZiBbIC1kICIkU0tJTExfRElSIiBdOyB0aGVuCiAgcm0gLXJmICIkU0tJTExf
  >> "!B64TMP!" echo RElSIgogIGVjaG8gIiAgUmVtb3ZlZCAkU0tJTExfRElSIgplbHNlCiAgZWNobyAiICBTa2lsbCBu
  >> "!B64TMP!" echo b3QgZm91bmQgKGFscmVhZHkgcmVtb3ZlZCkgLSBub3RoaW5nIHRvIGRvLiIKZmkKZWNobwpwcmlu
  >> "!B64TMP!" echo dGYgIkFsc28gZGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQgQUxMIGl0cyBmaWxlcz8gW3kv
  >> "!B64TMP!" echo Tl06ICIKcmVhZCAtciBERUxGSUxFUwppZiBbICIke0RFTEZJTEVTLCx9IiAhPSAieSIgXTsgdGhl
  >> "!B64TMP!" echo bgogIGVjaG8KICBlY2hvICJVbmluc3RhbGwgZmluaXNoZWQuIFRoZSBmb2xkZXIgd2FzIGtlcHQ6
  >> "!B64TMP!" echo IgogIGVjaG8gIiAgJChwd2QpIgogIGVjaG8gIiAgWW91IGNhbiBkZWxldGUgaXQgbWFudWFsbHkg
  >> "!B64TMP!" echo aWYgeW91IG5vIGxvbmdlciBuZWVkIHRoZSBzY3JpcHRzLiIKICBleGl0IDAKZmkKClRBUkdFVD0i
  >> "!B64TMP!" echo JChwd2QpIgpjZCAiJEhPTUUiCmVjaG8gIkRlbGV0aW5nIGluc3RhbGwgZm9sZGVyOiAkVEFSR0VU
  >> "!B64TMP!" echo IgpybSAtcmYgIiRUQVJHRVQiCmVjaG8KZWNobyAiVW5pbnN0YWxsIGNvbXBsZXRlLiBHb29kYnll
  >> "!B64TMP!" echo ISIK
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
  > "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYgpkZXNjcmlwdGlvbjogU2VhcmNoIHRoZSB3ZWIgYW5kIHJlYWQg
  >> "!B64TMP!" echo d2ViIHBhZ2VzIHRocm91Z2ggdGhlIGxvY2FsIHByaXZhdGUgc3RhY2sg4oCUIFNlYXJYTkcgYW5k
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBvbiBsb2NhbGhvc3QgKHBvcnRzIHJlYWQgZnJvbSB0aGUgbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo IC5lbnYsIGRlZmF1bHRzIDk5OTAvOTk5MSkuIE5vIEFQSSBrZXlzLCBubyBleHRlcm5hbCBzZXJ2
  >> "!B64TMP!" echo aWNlcywgbm8gTUNQIHRvb2xzLiBVc2Ugd2hlbmV2ZXIgdGhlIHVzZXIgYXNrcyBhYm91dCBhbnl0
  >> "!B64TMP!" echo aGluZyBjdXJyZW50LCByZWNlbnQsIG9yIHlvdSBhcmUgdW5zdXJlIGFib3V0OiBuZXdzLCBldmVu
  >> "!B64TMP!" echo dHMsIGxhdGVzdCB2ZXJzaW9ucyBvciByZWxlYXNlcywgZG9jdW1lbnRhdGlvbiwgZmFjdHMgdG8g
  >> "!B64TMP!" echo dmVyaWZ5LCAid2hhdCBkbyB5b3Uga25vdyBhYm91dCBYIiBxdWVzdGlvbnMg4oCUIGV2ZW4gd2hl
  >> "!B64TMP!" echo biB0aGV5IGRvbid0IGV4cGxpY2l0bHkgc2F5ICJzZWFyY2ggdGhlIHdlYiIuCi0tLQoKIyBMb2Nh
  >> "!B64TMP!" echo bCB3ZWIgcmVzZWFyY2gKClRoaXMgbWFjaGluZSBydW5zIGEgcHJpdmF0ZSB3ZWItcmVzZWFyY2gg
  >> "!B64TMP!" echo c3RhY2sgb24gbG9jYWxob3N0OgoKLSAqKlNlYXJYTkcqKiDigJQgbWV0YXNlYXJjaCB3aXRoIGEg
  >> "!B64TMP!" echo SlNPTiBBUEksIGF0IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIGJ5IGRlZmF1bHQKLSAqKkZpcmVj
  >> "!B64TMP!" echo cmF3bCoqIOKAlCB0dXJucyBhbnkgVVJMIGludG8gY2xlYW4gTWFya2Rvd24sIGF0IGBodHRwOi8v
  >> "!B64TMP!" echo bG9jYWxob3N0Ojk5OTFgIGJ5IGRlZmF1bHQKCkV2ZXJ5dGhpbmcgc3RheXMgbG9jYWw7IG5vIEFQ
  >> "!B64TMP!" echo SSBrZXlzIGFyZSBuZWVkZWQuIFRoZSBhY3R1YWwgcG9ydHMgYXJlIHJlYWQKZnJvbSBgU0VBUlhO
  >> "!B64TMP!" echo R19QT1JUYCAvIGBGSVJFQ1JBV0xfUE9SVGAgaW4gdGhlIGxvY2FsLXNlYXJjaCBpbnN0YWxsIGZv
  >> "!B64TMP!" echo bGRlcidzCmAuZW52YCAodGhlIHNhbWUgZmlsZSB0aGUgY29tcG9zZSBzZXR1cCB1c2VzKSwgc28g
  >> "!B64TMP!" echo aWYgY3VzdG9tIHBvcnRzIHdlcmUgcGlja2VkCmF0IHNldHVwIHRpbWUsIHRoZSBzY3JpcHRzIGZv
  >> "!B64TMP!" echo bGxvdyB0aGVtIGF1dG9tYXRpY2FsbHkuIEhlbHBlciBzY3JpcHRzIChpbiB0aGlzCnNraWxsJ3Mg
  >> "!B64TMP!" echo YHNjcmlwdHMvYCBkaXJlY3RvcnkpIGRvIHRoZSBIVFRQIGFuZCBEb2NrZXIgd29yayBmb3IgeW91
  >> "!B64TMP!" echo IOKAlCBydW4gdGhlbQp3aXRoIHRoZSBCYXNoIHRvb2wgdXNpbmcgYHB5dGhvbmAuIFRoZSBzZXJ2
  >> "!B64TMP!" echo aWNlcyBsaXZlIGluIERvY2tlciBjb250YWluZXJzOwpgZW5zdXJlX3N0YWNrLnB5YCBzdGFydHMg
  >> "!B64TMP!" echo dGhlIERvY2tlciBlbmdpbmUgYW5kIHRoZSBjb250YWluZXJzIGF1dG9tYXRpY2FsbHkKaWYgdGhl
  >> "!B64TMP!" echo eSBhcmVuJ3QgcnVubmluZyAoYW5kIG5ldmVyIHN0b3BzIHRoZW0g4oCUIHN0b3BwaW5nIGlzIHRo
  >> "!B64TMP!" echo ZSB1c2VyJ3Mgam9iLAp2aWEgU3RvcC5iYXQgLyBzdG9wLnNoKS4KCiMjIFdvcmtmbG93CgoxLiAq
  >> "!B64TMP!" echo Kk1ha2Ugc3VyZSB0aGUgc3RhY2sgaXMgcnVubmluZyoqIOKAlCBkbyB0aGlzIG9uY2UgYmVmb3Jl
  >> "!B64TMP!" echo IHRoZSBmaXJzdCBzZWFyY2g6CgogICBgYGBiYXNoCiAgIHB5dGhvbiAiPHNraWxsLWJhc2UtZGly
  >> "!B64TMP!" echo Pi9zY3JpcHRzL2Vuc3VyZV9zdGFjay5weSIKICAgYGBgCgogICBUaGlzIGlzIGZhc3Qgd2hlbiB0
  >> "!B64TMP!" echo aGUgc3RhY2sgaXMgYWxyZWFkeSB1cC4gSWYgaXQncyBkb3duLCB0aGUgc2NyaXB0IHN0YXJ0cwog
  >> "!B64TMP!" echo ICB0aGUgRG9ja2VyIGVuZ2luZSAoaWYgaXQncyBvZmYpIGFuZCB0aGUgY29udGFpbmVycyAodGhl
  >> "!B64TMP!" echo IHNhbWUgY29tbWFuZAogICBSdW4uYmF0IC8gcnVuLnNoIHJ1bikgYW5kIHdhaXRzIHVudGlsIGJv
  >> "!B64TMP!" echo dGggZW5kcG9pbnRzIGFuc3dlci4gR2l2ZSB0aGUgQmFzaAogICBjYWxsIGEgMTAtbWludXRlIHRp
  >> "!B64TMP!" echo bWVvdXQgKGVuZ2luZSBib290ICsgY29udGFpbmVyIGJvb3QpOyBvbmx5IGEgZmlyc3QtZXZlcgog
  >> "!B64TMP!" echo ICBzdGFydCAocHVsbGluZyB+MyBHQiBvZiBpbWFnZXMpIGNhbiBleGNlZWQgdGhhdC4gSWYgdGhl
  >> "!B64TMP!" echo IHNjcmlwdCByZXBvcnRzIGl0CiAgIGNvdWxkIG5vdCBsYXVuY2ggdGhlIERvY2tlciBlbmdpbmUg
  >> "!B64TMP!" echo YXQgYWxsLCBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgRG9ja2VyCiAgIERlc2t0b3AsIHRoZW4gcmUt
  >> "!B64TMP!" echo cnVuIHRoZSBzY3JpcHQuCgoyLiAqKkZpbmQgVVJMcyoqIOKAlCBzZWFyY2ggdGhlIHdlYjoKCiAg
  >> "!B64TMP!" echo IGBgYGJhc2gKICAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NlYXJjaC5w
  >> "!B64TMP!" echo eSIgInlvdXIgcXVlcnkgaGVyZSIKICAgYGBgCgogICBQcmludHMgdGhlIHRvcCByZXN1bHRzIGFz
  >> "!B64TMP!" echo IGB0aXRsZSAvIHVybCAvIH4zMDAtY2hhciBzbmlwcGV0YC4KICAgVXNlZnVsIG9wdGlvbnM6IGAt
  >> "!B64TMP!" echo LWxpbWl0IDEwYCwgYC0tdGltZS1yYW5nZSBkYXl8d2Vla3xtb250aGAsCiAgIGAtLWNhdGVnb3Jp
  >> "!B64TMP!" echo ZXMgaXQsbmV3cyxnZW5lcmFsYC4KCjMuICoqUmVhZCB0aGUgcGFnZXMqKiDigJQgc2NyYXBlIHRo
  >> "!B64TMP!" echo ZSAx4oCTMyBtb3N0IHJlbGV2YW50IHJlc3VsdCBVUkxzIGZvciBmdWxsIHRleHQ6CgogICBgYGBi
  >> "!B64TMP!" echo YXNoCiAgIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9zY3JhcGUucHkiICJo
  >> "!B64TMP!" echo dHRwczovL2V4YW1wbGUuY29tL2FydGljbGUiCiAgIGBgYAoKICAgUHJpbnRzIGNsZWFuIE1hcmtk
  >> "!B64TMP!" echo b3duICh0cnVuY2F0ZWQgYXQgMjAsMDAwIGNoYXJzIGJ5IGRlZmF1bHQ7IHJhaXNlIHdpdGgKICAg
  >> "!B64TMP!" echo YC0tbWF4LWNoYXJzYCkuIE9ubHkgZXZlciBzY3JhcGUgVVJMcyB0aGF0IHRoZSBzZWFyY2ggcmVz
  >> "!B64TMP!" echo dWx0cyBhY3R1YWxseQogICByZXR1cm5lZCDigJQgbmV2ZXIgaW52ZW50IG9yIGd1ZXNzIFVSTHMu
  >> "!B64TMP!" echo Cgo0LiAqKkFuc3dlciB3aXRoIGNpdGF0aW9ucyoqIOKAlCBiYWNrIGVhY2ggZmFjdHVhbCBjbGFp
  >> "!B64TMP!" echo bSB3aXRoIHRoZSBVUkwgeW91IHJlYWQuCgojIyBFcnJvciBoYW5kbGluZwoKLSBJZiBhIHNlYXJj
  >> "!B64TMP!" echo aCBvciBzY3JhcGUgZmFpbHMsIHJldHJ5ICoqb25jZSoqIHdpdGggYSBkaWZmZXJlbnQgcXVlcnkg
  >> "!B64TMP!" echo KHNlYXJjaCkKICBvciBhIGRpZmZlcmVudCByZXN1bHQgVVJMIChzY3JhcGUpLgotIElmIHJlcXVl
  >> "!B64TMP!" echo c3RzIGZhaWwgd2l0aCBjb25uZWN0aW9uIGVycm9ycywgdGhlIHN0YWNrIGlzbid0IHJ1bm5pbmcg
  >> "!B64TMP!" echo KG9yIHdlbnQKICBkb3duKS4gUnVuIGBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy9l
  >> "!B64TMP!" echo bnN1cmVfc3RhY2sucHkiYCDigJQgaXQgc3RhcnRzCiAgdGhlIERvY2tlciBlbmdpbmUgKGlmIG5l
  >> "!B64TMP!" echo ZWRlZCkgYW5kIHRoZSBjb250YWluZXJzLCBhbmQgd2FpdHMgdW50aWwgdGhleQogIGFuc3dlciDi
  >> "!B64TMP!" echo gJQgdGhlbiByZXRyeSB0aGUgZmFpbGVkIG9wZXJhdGlvbiBvbmNlLiBPbmx5IGlmIHRoZSBzY3Jp
  >> "!B64TMP!" echo cHQgcmVwb3J0cwogIGl0IGNvdWxkIG5vdCBsYXVuY2ggdGhlIGVuZ2luZSBhdCBhbGwgc2hvdWxk
  >> "!B64TMP!" echo IHlvdSBhc2sgdGhlIHVzZXIgdG8gc3RhcnQKICBEb2NrZXIgRGVza3RvcCBtYW51YWxseS4KLSBP
  >> "!B64TMP!" echo bmx5IGlmIHRoZSBzY3JpcHQgcmVwb3J0cyBpdCBjb3VsZCBub3QgZmluZCB0aGUgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoIGluc3RhbGwKICBmb2xkZXI6IGFzayB0aGUgdXNlciB3aGVyZSB0aGF0IGZvbGRlciBpcywg
  >> "!B64TMP!" echo dGhlbiByZS1ydW4gdGhlIHNjcmlwdCB3aXRoCiAgYExPQ0FMX1NFQVJDSF9ESVI9PHRoYXQgcGF0
  >> "!B64TMP!" echo aD5gLiBEb24ndCBkbyB0aGlzIHByZWVtcHRpdmVseSDigJQgdGhlIGZvbGRlciBpcwogIG5vcm1h
  >> "!B64TMP!" echo bGx5IGRldGVjdGVkIGF1dG9tYXRpY2FsbHkgKGZyb20gdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhl
  >> "!B64TMP!" echo IHJ1bm5pbmcKICBjb250YWluZXJzLCB0aGUgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoIGluc3RhbGxlciwgb3IgZnJvbQogIH4vbG9jYWwtc2VhcmNoKS4KLSBTY3JhcGUgb3V0cHV0
  >> "!B64TMP!" echo IGlzIGxvbmcuIEV4dHJhY3Qgb25seSB0aGUgcGFydHMgeW91IG5lZWQgZm9yIHRoZSBhbnN3ZXI7
  >> "!B64TMP!" echo IGRvbid0CiAgcGFzdGUgd2hvbGUgcGFnZXMgYmFjayB0byB0aGUgdXNlci4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\SKILL.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/LICENSE ---
set "NEED_B64=1"
if exist "!SRC!\local-web\LICENSE" (
  copy /Y "!SRC!\local-web\LICENSE" "!TARGET!\local-web\LICENSE" >nul 2>&1
  if exist "!TARGET!\local-web\LICENSE" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/LICENSE  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2410305736.b64"
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
  >> "!B64TMP!" echo UHVibGljIExpY2Vuc2UsIHYuIDIuMC4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\LICENSE"
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
  >> "!B64TMP!" echo cyBydW5uaW5nIGJlZm9yZSBhbnkgd2ViIHJlc2VhcmNoLgoKVGhlIHN0YWNrIGlzIGEgc2V0IG9m
  >> "!B64TMP!" echo IERvY2tlciBjb250YWluZXJzIChkb2NrZXItY29tcG9zZS55bWwgaW4gdGhlCmxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aCBpbnN0YWxsIGZvbGRlcikuIFRoZSBlbmRwb2ludHMgYXJlIE5PVCBoYXJkY29kZWQgaGVyZToK
  >> "!B64TMP!" echo Y29uZmlnLnB5IHJlYWRzIFNFQVJYTkdfUE9SVCAvIEZJUkVDUkFXTF9QT1JUIGZyb20gdGhlIGlu
  >> "!B64TMP!" echo c3RhbGwgZm9sZGVyJ3MKLmVudiAodGhlIHNhbWUgZmlsZSB0aGUgY29tcG9zZSBzZXR1cCB1c2Vz
  >> "!B64TMP!" echo OyBkZWZhdWx0cyA5OTkwIC8gOTk5MSksIHNvCmN1c3RvbSBwb3J0cyBwaWNrZWQgYXQgc2V0dXAg
  >> "!B64TMP!" echo dGltZSBhcmUgcmVzcGVjdGVkLgoKRGVmYXVsdCBtb2RlOgogICogQm90aCBlbmRwb2ludHMgYW5z
  >> "!B64TMP!" echo d2VyaW5nIC0+IHByaW50IHN0YXR1cywgZXhpdCAwIChmYXN0IHBhdGgsIDwgMSBzKS4KICAqIE90
  >> "!B64TMP!" echo aGVyd2lzZTogbWFrZSBzdXJlIHRoZSBEb2NrZXIgZW5naW5lIGlzIHJ1bm5pbmcgKGlmIGl0IGlz
  >> "!B64TMP!" echo IGRvd24sIGxhdW5jaAogICAgRG9ja2VyIERlc2t0b3AgLyB0aGUgZG9ja2VyIHNlcnZpY2UgYW5k
  >> "!B64TMP!" echo IHdhaXQgZm9yIHRoZSBkYWVtb24pLCB0aGVuIHN0YXJ0CiAgICB0aGUgY29udGFpbmVycyB3aXRo
  >> "!B64TMP!" echo IGBkb2NrZXIgY29tcG9zZSB1cCAtZGAgaW4gdGhlIGluc3RhbGwgZm9sZGVyICh0aGUKICAgIHNh
  >> "!B64TMP!" echo bWUgY29tbWFuZCBSdW4uYmF0IC8gcnVuLnNoIHJ1biwgd2l0aG91dCB0aGUgaW50ZXJhY3RpdmUg
  >> "!B64TMP!" echo YHBhdXNlYCkgYW5kCiAgICB3YWl0IHVudGlsIGJvdGggZW5kcG9pbnRzIGFuc3dlciBhZ2Fpbi4K
  >> "!B64TMP!" echo ICAgIFRoZSBzdGFjayBpcyBORVZFUiBzdG9wcGVkIGJ5IHRoaXMgc2NyaXB0LgoKT3B0aW9uczoK
  >> "!B64TMP!" echo ICAgIC0tY2hlY2sgICBPbmx5IHJlcG9ydCBzdGF0dXM7IG5ldmVyIHN0YXJ0IGFueXRoaW5nLgoK
  >> "!B64TMP!" echo RXhpdCBjb2RlczoKICAgIDAgIHN0YWNrIGlzIHJlYWR5ICh3YXMgYWxyZWFkeSB1cCwgb3Igd2Fz
  >> "!B64TMP!" echo IGp1c3Qgc3RhcnRlZCkKICAgIDEgIHN0YWNrIGlzIGRvd24gYW5kIGNvdWxkIG5vdCBiZSBicm91
  >> "!B64TMP!" echo Z2h0IHVwCiAgICAyICBwcmVyZXF1aXNpdGVzIG1pc3NpbmcgKGluc3RhbGwgZm9sZGVyLCBEb2Nr
  >> "!B64TMP!" echo ZXIsIGNvbXBvc2UpCgpUaGUgaW5zdGFsbCBmb2xkZXIgKGhvbGRzIGRvY2tlci1jb21wb3NlLnlt
  >> "!B64TMP!" echo bCkgaXMgZm91bmQgYnkgY29uZmlnLnB5LCBpbiBvcmRlcjoKICAgIDEuIHRoZSBMT0NBTF9TRUFS
  >> "!B64TMP!" echo Q0hfRElSIGVudiB2YXIgKGV4cGxpY2l0IG92ZXJyaWRlKSwKICAgIDIuIHRoZSBjb21wb3NlIGxh
  >> "!B64TMP!" echo YmVsIG9uIHRoZSBjb250YWluZXJzIOKAlCBjb21wb3NlIHRhZ3MgZWFjaCBjb250YWluZXIgd2l0
  >> "!B64TMP!" echo aAogICAgICAgdGhlIGRpcmVjdG9yeSBpdCB3YXMgc3RhcnRlZCBmcm9tIChlbmdpbmUgbXVzdCBi
  >> "!B64TMP!" echo ZSB1cCksCiAgICAzLiBpbnN0YWxsLWRpci50eHQg4oCUIHRoZSBwYXRoIHJlY29yZGVkIGJ5IHRo
  >> "!B64TMP!" echo ZSBsb2NhbC1zZWFyY2ggaW5zdGFsbGVyCiAgICAgICB3aGVuIGl0IGNvcGllZCB0aGlzIHNraWxs
  >> "!B64TMP!" echo LAogICAgNC4gfi9sb2NhbC1zZWFyY2guCiIiIgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IG9zCmlt
  >> "!B64TMP!" echo cG9ydCBzaHV0aWwKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQppbXBv
  >> "!B64TMP!" echo cnQgdXJsbGliLmVycm9yCmltcG9ydCB1cmxsaWIucmVxdWVzdAoKc3lzLnBhdGguaW5zZXJ0KDAs
  >> "!B64TMP!" echo IG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZp
  >> "!B64TMP!" echo ZyAgIyBzaWJsaW5nIG1vZHVsZTogaW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5k
  >> "!B64TMP!" echo cG9pbnRzCgpSRUFEWV9USU1FT1VUID0gMjQwICAjIHNlY29uZHMgdG8gd2FpdCBmb3IgdGhlIHN0
  >> "!B64TMP!" echo YWNrIGFmdGVyIGBjb21wb3NlIHVwIC1kYApQT0xMX0VWRVJZID0gMwpESVNQTEFZID0geyJzZWFy
  >> "!B64TMP!" echo eG5nIjogIlNlYXJYTkciLCAiZmlyZWNyYXdsIjogIkZpcmVjcmF3bCJ9CgoKZGVmIGVuZHBvaW50
  >> "!B64TMP!" echo X3VwKHVybCwgdGltZW91dD00KToKICAgICIiIlRydWUgaWYgdGhlIGVuZHBvaW50IGFjY2VwdHMg
  >> "!B64TMP!" echo Y29ubmVjdGlvbnMgKGFueSBIVFRQIHN0YXR1cyBjb3VudHMpLiIiIgogICAgcmVxID0gdXJsbGli
  >> "!B64TMP!" echo LnJlcXVlc3QuUmVxdWVzdCh1cmwsIGhlYWRlcnM9eyJVc2VyLUFnZW50IjogInpjb2RlLWxvY2Fs
  >> "!B64TMP!" echo LXdlYi8xLjAifSkKICAgIHRyeToKICAgICAgICB3aXRoIHVybGxpYi5yZXF1ZXN0LnVybG9wZW4o
  >> "!B64TMP!" echo cmVxLCB0aW1lb3V0PXRpbWVvdXQpOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgZXhjZXB0
  >> "!B64TMP!" echo IHVybGxpYi5lcnJvci5IVFRQRXJyb3I6CiAgICAgICAgcmV0dXJuIFRydWUgICMgZ290IGFuIEhU
  >> "!B64TMP!" echo VFAgcmVzcG9uc2UgKGV2ZW4gNHh4LzV4eCkgPSBzZXJ2aWNlIGlzIHVwCiAgICBleGNlcHQgRXhj
  >> "!B64TMP!" echo ZXB0aW9uOgogICAgICAgIHJldHVybiBGYWxzZSAgIyBjb25uZWN0aW9uIHJlZnVzZWQgLyByZXNl
  >> "!B64TMP!" echo dCAvIHRpbWVvdXQgPSBkb3duCgoKZGVmIHBvcnRfb2YodXJsKToKICAgIHJldHVybiB1cmwucnNw
  >> "!B64TMP!" echo bGl0KCI6IiwgMSlbMV0KCgpkZWYgc3RhdHVzKGVuZHBvaW50cyk6CiAgICByZXR1cm4ge25hbWU6
  >> "!B64TMP!" echo IGVuZHBvaW50X3VwKHVybCkgZm9yIG5hbWUsIHVybCBpbiBlbmRwb2ludHMuaXRlbXMoKX0KCgpk
  >> "!B64TMP!" echo ZWYgcmVhZHlfbWVzc2FnZShlbmRwb2ludHMpOgogICAgcmV0dXJuICJTdGFjayBpcyByZWFkeSAo
  >> "!B64TMP!" echo U2VhclhORyA6ezB9LCBGaXJlY3Jhd2wgOnsxfSkuIi5mb3JtYXQoCiAgICAgICAgcG9ydF9vZihl
  >> "!B64TMP!" echo bmRwb2ludHNbInNlYXJ4bmciXSksIHBvcnRfb2YoZW5kcG9pbnRzWyJmaXJlY3Jhd2wiXSkpCgoK
  >> "!B64TMP!" echo ZGVmIGNvbXBvc2VfY29tbWFuZCgpOgogICAgaWYgc2h1dGlsLndoaWNoKCJkb2NrZXIiKToKICAg
  >> "!B64TMP!" echo ICAgICByYyA9IHN1YnByb2Nlc3MucnVuKAogICAgICAgICAgICBbImRvY2tlciIsICJjb21wb3Nl
  >> "!B64TMP!" echo IiwgInZlcnNpb24iXSwKICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3Rk
  >> "!B64TMP!" echo ZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwKICAgICAgICApCiAgICAgICAgaWYgcmMucmV0dXJuY29k
  >> "!B64TMP!" echo ZSA9PSAwOgogICAgICAgICAgICByZXR1cm4gWyJkb2NrZXIiLCAiY29tcG9zZSJdCiAgICBpZiBz
  >> "!B64TMP!" echo aHV0aWwud2hpY2goImRvY2tlci1jb21wb3NlIik6CiAgICAgICAgcmV0dXJuIFsiZG9ja2VyLWNv
  >> "!B64TMP!" echo bXBvc2UiXQogICAgcmV0dXJuIE5vbmUKCgpkZWYgZG9ja2VyX2VuZ2luZV91cCgpOgogICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgIHJldHVybiBzdWJwcm9jZXNzLnJ1bigKICAgICAgICAgICAgWyJkb2NrZXIiLCAi
  >> "!B64TMP!" echo aW5mbyJdLAogICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3Vi
  >> "!B64TMP!" echo cHJvY2Vzcy5ERVZOVUxMLAogICAgICAgICkucmV0dXJuY29kZSA9PSAwCiAgICBleGNlcHQgKE9T
  >> "!B64TMP!" echo RXJyb3IsIEZpbGVOb3RGb3VuZEVycm9yKToKICAgICAgICByZXR1cm4gRmFsc2UKCgpkZWYgZmlu
  >> "!B64TMP!" echo ZF9kb2NrZXJfZGVza3RvcF9leGUoKToKICAgIGNhbmRpZGF0ZXMgPSBbCiAgICAgICAgciJDOlxQ
  >> "!B64TMP!" echo cm9ncmFtIEZpbGVzXERvY2tlclxEb2NrZXJcRG9ja2VyIERlc2t0b3AuZXhlIiwKICAgICAgICBv
  >> "!B64TMP!" echo cy5wYXRoLmV4cGFuZHZhcnMociIlTE9DQUxBUFBEQVRBJVxQcm9ncmFtc1xEb2NrZXIgRGVza3Rv
  >> "!B64TMP!" echo cFxEb2NrZXIgRGVza3RvcC5leGUiKSwKICAgIF0KICAgIGZvciBwIGluIGNhbmRpZGF0ZXM6CiAg
  >> "!B64TMP!" echo ICAgICAgaWYgb3MucGF0aC5pc2ZpbGUocCk6CiAgICAgICAgICAgIHJldHVybiBwCiAgICByZXR1
  >> "!B64TMP!" echo cm4gTm9uZQoKCmRlZiBzdGFydF9kb2NrZXJfZW5naW5lKCk6CiAgICAiIiJUcnkgdG8gbGF1bmNo
  >> "!B64TMP!" echo IHRoZSBEb2NrZXIgZW5naW5lIGZvciB0aGlzIE9TLiBUcnVlIGlmIHRoZSBsYXVuY2ggd2FzCiAg
  >> "!B64TMP!" echo ICBpbml0aWF0ZWQgKG5vdCB0aGF0IGl0IGJlY2FtZSByZWFkeSDigJQgdGhhdCdzIHdhaXRfZm9y
  >> "!B64TMP!" echo X2VuZ2luZSdzIGpvYikuIiIiCiAgICBpbXBvcnQgcGxhdGZvcm0KICAgIHN5c3RlbSA9IHBsYXRm
  >> "!B64TMP!" echo b3JtLnN5c3RlbSgpCiAgICBpZiBzeXN0ZW0gPT0gIldpbmRvd3MiOgogICAgICAgIGV4ZSA9IGZp
  >> "!B64TMP!" echo bmRfZG9ja2VyX2Rlc2t0b3BfZXhlKCkKICAgICAgICBpZiBub3QgZXhlOgogICAgICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gRmFsc2UKICAgICAgICB0cnk6CiAgICAgICAgICAgIHN1YnByb2Nlc3MuUG9wZW4oW2V4
  >> "!B64TMP!" echo ZV0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVM
  >> "!B64TMP!" echo TCwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCkKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAg
  >> "!B64TMP!" echo ICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBpZiBzeXN0
  >> "!B64TMP!" echo ZW0gPT0gIkRhcndpbiI6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzdWJwcm9jZXNzLlBvcGVu
  >> "!B64TMP!" echo KFsib3BlbiIsICItLWJhY2tncm91bmQiLCAiLWEiLCAiRG9ja2VyIl0sCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nl
  >> "!B64TMP!" echo c3MuREVWTlVMTCkKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBleGNlcHQgT1NFcnJv
  >> "!B64TMP!" echo cjoKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAjIExpbnV4OiBiZXN0IGVmZm9ydCB3aXRo
  >> "!B64TMP!" echo b3V0IGFuIGludGVyYWN0aXZlIHBhc3N3b3JkIHByb21wdC4KICAgIHRyeToKICAgICAgICBpZiBo
  >> "!B64TMP!" echo YXNhdHRyKG9zLCAiZ2V0ZXVpZCIpIGFuZCBvcy5nZXRldWlkKCkgPT0gMDoKICAgICAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIHN1YnByb2Nlc3MucnVuKFsic3lzdGVtY3RsIiwgInN0YXJ0IiwgImRvY2tlciJdLAog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVM
  >> "!B64TMP!" echo TCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLkRF
  >> "!B64TMP!" echo Vk5VTEwpLnJldHVybmNvZGUgPT0gMAogICAgICAgIHJldHVybiBzdWJwcm9jZXNzLnJ1bihbInN1
  >> "!B64TMP!" echo ZG8iLCAiLW4iLCAic3lzdGVtY3RsIiwgInN0YXJ0IiwgImRvY2tlciJdLAogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLAogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKS5yZXR1cm5jb2RlID09
  >> "!B64TMP!" echo IDAKICAgIGV4Y2VwdCAoT1NFcnJvciwgRmlsZU5vdEZvdW5kRXJyb3IpOgogICAgICAgIHJldHVy
  >> "!B64TMP!" echo biBGYWxzZQoKCmRlZiB3YWl0X2Zvcl9lbmdpbmUodGltZW91dD0xODApOgogICAgZGVhZGxpbmUg
  >> "!B64TMP!" echo PSB0aW1lLnRpbWUoKSArIHRpbWVvdXQKICAgIHdoaWxlIHRpbWUudGltZSgpIDwgZGVhZGxpbmU6
  >> "!B64TMP!" echo CiAgICAgICAgaWYgZG9ja2VyX2VuZ2luZV91cCgpOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQog
  >> "!B64TMP!" echo ICAgICAgIHRpbWUuc2xlZXAoMykKICAgIHJldHVybiBGYWxzZQoKCmRlZiBtYWluKCk6CiAgICBh
  >> "!B64TMP!" echo cCA9IGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKGRlc2NyaXB0aW9uPSJFbnN1cmUgdGhlIGxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaCBEb2NrZXIgc3RhY2sgaXMgcnVubmluZy4iKQogICAgYXAuYWRkX2FyZ3VtZW50KCIt
  >> "!B64TMP!" echo LWNoZWNrIiwgYWN0aW9uPSJzdG9yZV90cnVlIiwKICAgICAgICAgICAgICAgICAgICBoZWxwPSJv
  >> "!B64TMP!" echo bmx5IHJlcG9ydCBzdGF0dXM7IG5ldmVyIHN0YXJ0IGFueXRoaW5nIikKICAgIGFyZ3MgPSBhcC5w
  >> "!B64TMP!" echo YXJzZV9hcmdzKCkKCiAgICBlbmRwb2ludHMgPSBjb25maWcuZW5kcG9pbnRzKGNvbmZpZy5maW5k
  >> "!B64TMP!" echo X2luc3RhbGxfZGlyKCkpCiAgICBzdCA9IHN0YXR1cyhlbmRwb2ludHMpCiAgICBpZiBhbGwoc3Qu
  >> "!B64TMP!" echo dmFsdWVzKCkpOgogICAgICAgIHByaW50KHJlYWR5X21lc3NhZ2UoZW5kcG9pbnRzKSkKICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gMAoKICAgIHByaW50KCJMb2NhbC1zZWFyY2ggc3RhY2sgaXMgRE9XTjoiLCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICBmb3IgbmFtZSwgdXJsIGluIGVuZHBvaW50cy5pdGVtcygpOgogICAg
  >> "!B64TMP!" echo ICAgIG1hcmsgPSAiT0sgICIgaWYgc3RbbmFtZV0gZWxzZSAiRE9XTiIKICAgICAgICBwcmludChm
  >> "!B64TMP!" echo IiAgW3ttYXJrfV0ge0RJU1BMQVlbbmFtZV19IDp7cG9ydF9vZih1cmwpfSIsIGZpbGU9c3lzLnN0
  >> "!B64TMP!" echo ZGVycikKICAgIGlmIGFyZ3MuY2hlY2s6CiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBub3QgZG9j
  >> "!B64TMP!" echo a2VyX2VuZ2luZV91cCgpOgogICAgICAgIHByaW50KCJEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5u
  >> "!B64TMP!" echo aW5nIOKAlCB0cnlpbmcgdG8gc3RhcnQgaXQgLi4uIiwKICAgICAgICAgICAgICBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgaWYgbm90IHN0YXJ0X2RvY2tlcl9lbmdpbmUoKToKICAgICAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoIkNvdWxkIG5vdCBzdGFydCB0aGUgRG9ja2VyIGVuZ2luZSBhdXRvbWF0aWNhbGx5ICIK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgIihEb2NrZXIgRGVza3RvcCBub3QgZm91bmQgaW4gdGhlIHVzdWFs
  >> "!B64TMP!" echo IGxvY2F0aW9ucz8pLiAiCiAgICAgICAgICAgICAgICAgICJTdGFydCBpdCBtYW51YWxseSwgdGhl
  >> "!B64TMP!" echo biByZS1ydW4gdGhpcyBzY3JpcHQuIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMgogICAgICAgIHByaW50KCJXYWl0aW5nIGZvciB0aGUgRG9ja2VyIGVuZ2luZSB0byBjb21l
  >> "!B64TMP!" echo IHVwIC4uLiIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBpZiBub3Qgd2FpdF9mb3JfZW5naW5l
  >> "!B64TMP!" echo KHRpbWVvdXQ9MTgwKToKICAgICAgICAgICAgcHJpbnQoIlRoZSBEb2NrZXIgZW5naW5lIHdhcyBs
  >> "!B64TMP!" echo YXVuY2hlZCBidXQgZGlkIG5vdCBhbnN3ZXIgd2l0aGluICIKICAgICAgICAgICAgICAgICAgIjE4
  >> "!B64TMP!" echo MCBzLiBDaGVjayBEb2NrZXIgRGVza3RvcCwgdGhlbiByZS1ydW4gdGhpcyBzY3JpcHQuIiwKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMgoKICAg
  >> "!B64TMP!" echo ICMgUmVjb21wdXRlZCBub3cgdGhhdCB0aGUgZW5naW5lIGlzIHVwOiB0aGUgY29tcG9zZS1sYWJl
  >> "!B64TMP!" echo bCBsb29rdXAgKHdoaWNoCiAgICAjIG5lZWRzIHRoZSBlbmdpbmUpIGNhbiBmaW5kIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsIGRpciB3aGVyZSB0aGUgb3RoZXIgbWV0aG9kcwogICAgIyBjb3VsZCBub3QuCiAgICBpbnN0
  >> "!B64TMP!" echo YWxsX2RpciA9IGNvbmZpZy5maW5kX2luc3RhbGxfZGlyKCkKICAgIGlmIG5vdCBpbnN0YWxsX2Rp
  >> "!B64TMP!" echo cjoKICAgICAgICBwcmludCgiQ291bGQgbm90IGZpbmQgdGhlIGxvY2FsLXNlYXJjaCBpbnN0YWxs
  >> "!B64TMP!" echo IGZvbGRlciAiCiAgICAgICAgICAgICAgIihubyBkb2NrZXItY29tcG9zZS55bWwgZm91bmQpLiBB
  >> "!B64TMP!" echo c2sgdGhlIHVzZXIgd2hlcmUgdGhlaXIgIgogICAgICAgICAgICAgICJsb2NhbC1zZWFyY2ggZm9s
  >> "!B64TMP!" echo ZGVyIGlzLCB0aGVuIHJlLXJ1biB0aGlzIHNjcmlwdCB3aXRoICIKICAgICAgICAgICAgICAiTE9D
  >> "!B64TMP!" echo QUxfU0VBUkNIX0RJUiBzZXQgdG8gdGhhdCBwYXRoLCBvciBzdGFydCB0aGUgc3RhY2sgbWFudWFs
  >> "!B64TMP!" echo bHkgIgogICAgICAgICAgICAgICIoUnVuLmJhdCAvIHJ1bi5zaCkuIiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgICAgIHJldHVybiAyCgogICAgY29tcG9zZSA9IGNvbXBvc2VfY29tbWFuZCgpCiAgICBp
  >> "!B64TMP!" echo ZiBub3QgY29tcG9zZToKICAgICAgICBwcmludCgiTmVpdGhlciAnZG9ja2VyIGNvbXBvc2UnIG5v
  >> "!B64TMP!" echo ciAnZG9ja2VyLWNvbXBvc2UnIGlzIGF2YWlsYWJsZS4iLAogICAgICAgICAgICAgIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIHByaW50KGYiU3RhcnRpbmcgc3RhY2sgaW4g
  >> "!B64TMP!" echo e2luc3RhbGxfZGlyfSAuLi4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICBwcm9jID0gc3VicHJvY2Vz
  >> "!B64TMP!" echo cy5ydW4oY29tcG9zZSArIFsidXAiLCAiLWQiXSwgY3dkPWluc3RhbGxfZGlyKQogICAgaWYgcHJv
  >> "!B64TMP!" echo Yy5yZXR1cm5jb2RlICE9IDA6CiAgICAgICAgcHJpbnQoIidkb2NrZXIgY29tcG9zZSB1cCAtZCcg
  >> "!B64TMP!" echo ZmFpbGVkIOKAlCBzZWUgb3V0cHV0IGFib3ZlLiIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMQoKICAgIHByaW50KCJXYWl0aW5nIGZvciBlbmRwb2ludHMgLi4uIiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgZGVhZGxpbmUgPSB0aW1lLnRpbWUoKSArIFJFQURZX1RJTUVPVVQKICAgIHdo
  >> "!B64TMP!" echo aWxlIHRpbWUudGltZSgpIDwgZGVhZGxpbmU6CiAgICAgICAgc3QgPSBzdGF0dXMoZW5kcG9pbnRz
  >> "!B64TMP!" echo KQogICAgICAgIGlmIGFsbChzdC52YWx1ZXMoKSk6CiAgICAgICAgICAgIHByaW50KHJlYWR5X21l
  >> "!B64TMP!" echo c3NhZ2UoZW5kcG9pbnRzKSkKICAgICAgICAgICAgcmV0dXJuIDAKICAgICAgICB0aW1lLnNsZWVw
  >> "!B64TMP!" echo KFBPTExfRVZFUlkpCgogICAgZm9yIG5hbWUsIHVybCBpbiBlbmRwb2ludHMuaXRlbXMoKToKICAg
  >> "!B64TMP!" echo ICAgICBtYXJrID0gIk9LICAiIGlmIHN0W25hbWVdIGVsc2UgIkRPV04iCiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo ZiIgIFt7bWFya31dIHtESVNQTEFZW25hbWVdfSA6e3BvcnRfb2YodXJsKX0iLCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICBwcmludChmIlN0YWNrIGRpZCBub3QgYmVjb21lIHJlYWR5IHdpdGhpbiB7UkVB
  >> "!B64TMP!" echo RFlfVElNRU9VVH1zLiBJbnNwZWN0IHdpdGg6XG4iCiAgICAgICAgICBmIiAgICBjZCB7aW5zdGFs
  >> "!B64TMP!" echo bF9kaXJ9ICYmIGRvY2tlciBjb21wb3NlIGxvZ3MgLS10YWlsIDUwIiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgcmV0dXJuIDEKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQo
  >> "!B64TMP!" echo bWFpbigpKQo=
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
  >> "!B64TMP!" echo Z29yaWVzIGl0LG5ld3MsZ2VuZXJhbF0KClByaW50cyB1cCB0byBgbGltaXRgIHJlc3VsdHMsIGVh
  >> "!B64TMP!" echo Y2ggYXM6CiAgICBOLiA8dGl0bGU+CiAgICAgICA8dXJsPgogICAgICAgPHNuaXBwZXQ+CiIiIgpp
  >> "!B64TMP!" echo bXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwppbXBvcnQgdXJsbGliLnBhcnNlCmltcG9y
  >> "!B64TMP!" echo dCB1cmxsaWIucmVxdWVzdAoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5w
  >> "!B64TMP!" echo YXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTog
  >> "!B64TMP!" echo aW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5kcG9pbnRzCgojIFBvcnQgY29tZXMg
  >> "!B64TMP!" echo ZnJvbSBTRUFSWE5HX1BPUlQgaW4gdGhlIGluc3RhbGwgZm9sZGVyJ3MgLmVudiAoZGVmYXVsdCA5
  >> "!B64TMP!" echo OTkwKS4KQkFTRSA9IGNvbmZpZy5lbmRwb2ludHMoY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIoKSlb
  >> "!B64TMP!" echo InNlYXJ4bmciXSArICIvc2VhcmNoIgoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5
  >> "!B64TMP!" echo cy5hcmd2WzE6XQogICAgbGltaXQsIHRpbWVfcmFuZ2UsIGNhdGVnb3JpZXMgPSA4LCBOb25lLCBO
  >> "!B64TMP!" echo b25lCiAgICBxdWVyeV9wYXJ0cyA9IFtdCiAgICBpID0gMAogICAgd2hpbGUgaSA8IGxlbihhcmdz
  >> "!B64TMP!" echo KToKICAgICAgICBhID0gYXJnc1tpXQogICAgICAgIGlmIGEgPT0gIi0tbGltaXQiOgogICAgICAg
  >> "!B64TMP!" echo ICAgICBpICs9IDEKICAgICAgICAgICAgbGltaXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICBlbGlm
  >> "!B64TMP!" echo IGEgPT0gIi0tdGltZS1yYW5nZSI6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICB0aW1l
  >> "!B64TMP!" echo X3JhbmdlID0gYXJnc1tpXQogICAgICAgIGVsaWYgYSA9PSAiLS1jYXRlZ29yaWVzIjoKICAgICAg
  >> "!B64TMP!" echo ICAgICAgaSArPSAxCiAgICAgICAgICAgIGNhdGVnb3JpZXMgPSBhcmdzW2ldCiAgICAgICAgZWxp
  >> "!B64TMP!" echo ZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgICAgIHByaW50KGYidW5rbm93biBvcHRpb246
  >> "!B64TMP!" echo IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbHNl
  >> "!B64TMP!" echo OgogICAgICAgICAgICBxdWVyeV9wYXJ0cy5hcHBlbmQoYSkKICAgICAgICBpICs9IDEKICAgIHF1
  >> "!B64TMP!" echo ZXJ5ID0gIiAiLmpvaW4ocXVlcnlfcGFydHMpLnN0cmlwKCkKICAgIGlmIG5vdCBxdWVyeToKICAg
  >> "!B64TMP!" echo ICAgICBwcmludCgndXNhZ2U6IHdlYl9zZWFyY2gucHkgInF1ZXJ5IiBbLS1saW1pdCBOXSBbLS10
  >> "!B64TMP!" echo aW1lLXJhbmdlIFJdIFstLWNhdGVnb3JpZXMgQ10nLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIDIKCiAgICBwYXJhbXMgPSB7InEiOiBxdWVyeSwgImZvcm1hdCI6ICJqc29uIiwgImxh
  >> "!B64TMP!" echo bmd1YWdlIjogImVuIn0KICAgIGlmIHRpbWVfcmFuZ2U6CiAgICAgICAgcGFyYW1zWyJ0aW1lX3Jh
  >> "!B64TMP!" echo bmdlIl0gPSB0aW1lX3JhbmdlCiAgICBpZiBjYXRlZ29yaWVzOgogICAgICAgIHBhcmFtc1siY2F0
  >> "!B64TMP!" echo ZWdvcmllcyJdID0gY2F0ZWdvcmllcwogICAgdXJsID0gQkFTRSArICI/IiArIHVybGxpYi5wYXJz
  >> "!B64TMP!" echo ZS51cmxlbmNvZGUocGFyYW1zKQogICAgcmVxID0gdXJsbGliLnJlcXVlc3QuUmVxdWVzdCh1cmws
  >> "!B64TMP!" echo IGhlYWRlcnM9eyJVc2VyLUFnZW50IjogInpjb2RlLWxvY2FsLXdlYi8xLjAifSkKICAgIHRyeToK
  >> "!B64TMP!" echo ICAgICAgICB3aXRoIHVybGxpYi5yZXF1ZXN0LnVybG9wZW4ocmVxLCB0aW1lb3V0PTMwKSBhcyBy
  >> "!B64TMP!" echo OgogICAgICAgICAgICBkYXRhID0ganNvbi5sb2FkKHIpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFz
  >> "!B64TMP!" echo IGU6CiAgICAgICAgcHJpbnQoZiJTRUFSQ0ggRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoIklzIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgcnVubmluZz8gUnVuIHNj
  >> "!B64TMP!" echo cmlwdHMvZW5zdXJlX3N0YWNrLnB5ICIKICAgICAgICAgICAgICAiKGl0IHN0YXJ0cyB0aGUgRG9j
  >> "!B64TMP!" echo a2VyIGNvbnRhaW5lcnMgaWYgbmVlZGVkKSwgdGhlbiByZXRyeS4iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIDEKCiAgICByZXN1bHRzID0gZGF0YS5nZXQoInJlc3VsdHMiLCBbXSlb
  >> "!B64TMP!" echo OmxpbWl0XQogICAgaWYgbm90IHJlc3VsdHM6CiAgICAgICAgcHJpbnQoIihubyByZXN1bHRzKSIp
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIDAKICAgIGZvciBuLCBoaXQgaW4gZW51bWVyYXRlKHJlc3VsdHMsIDEp
  >> "!B64TMP!" echo OgogICAgICAgIHRpdGxlID0gKGhpdC5nZXQoInRpdGxlIikgb3IgIiIpLnN0cmlwKCkKICAgICAg
  >> "!B64TMP!" echo ICByZXN1bHRfdXJsID0gaGl0LmdldCgidXJsIikgb3IgIiIKICAgICAgICBjb250ZW50ID0gKGhp
  >> "!B64TMP!" echo dC5nZXQoImNvbnRlbnQiKSBvciAiIikuc3RyaXAoKS5yZXBsYWNlKCJcbiIsICIgIikKICAgICAg
  >> "!B64TMP!" echo ICBpZiBsZW4oY29udGVudCkgPiAzMDA6CiAgICAgICAgICAgIGNvbnRlbnQgPSBjb250ZW50Wzoz
  >> "!B64TMP!" echo MDBdICsgIuKApiIKICAgICAgICBwcmludChmIntufS4ge3RpdGxlfSIpCiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo ZiIgICB7cmVzdWx0X3VybH0iKQogICAgICAgIGlmIGNvbnRlbnQ6CiAgICAgICAgICAgIHByaW50
  >> "!B64TMP!" echo KGYiICAge2NvbnRlbnR9IikKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9f
  >> "!B64TMP!" echo IjoKICAgIHN5cy5leGl0KG1haW4oKSkK
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
  >> "!B64TMP!" echo ZWJfc2NyYXBlLnB5IDx1cmw+IFstLW1heC1jaGFycyAyMDAwMF0KClByaW50cyB0aGUgcGFnZSdz
  >> "!B64TMP!" echo IE1hcmtkb3duIHRvIHN0ZG91dCwgdHJ1bmNhdGVkIGF0IC0tbWF4LWNoYXJzLgoiIiIKaW1wb3J0
  >> "!B64TMP!" echo IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMKaW1wb3J0IHVybGxpYi5yZXF1ZXN0CgpzeXMucGF0
  >> "!B64TMP!" echo aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQpp
  >> "!B64TMP!" echo bXBvcnQgY29uZmlnICAjIHNpYmxpbmcgbW9kdWxlOiBpbnN0YWxsLWRpciBsb29rdXAgKyAuZW52
  >> "!B64TMP!" echo LWRyaXZlbiBlbmRwb2ludHMKCiMgUG9ydCBjb21lcyBmcm9tIEZJUkVDUkFXTF9QT1JUIGluIHRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYgKGRlZmF1bHQgOTk5MSkuCkVORFBPSU5UID0gY29uZmln
  >> "!B64TMP!" echo LmVuZHBvaW50cyhjb25maWcuZmluZF9pbnN0YWxsX2RpcigpKVsiZmlyZWNyYXdsIl0gKyAiL3Yx
  >> "!B64TMP!" echo L3NjcmFwZSIKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAg
  >> "!B64TMP!" echo IGlmIG5vdCBhcmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgi
  >> "!B64TMP!" echo dXNhZ2U6IHdlYl9zY3JhcGUucHkgPHVybD4gWy0tbWF4LWNoYXJzIE5dIiwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgIHJldHVybiAyCiAgICB1cmwgPSBhcmdzWzBdCiAgICBtYXhfY2hhcnMgPSAy
  >> "!B64TMP!" echo MDAwMAogICAgaSA9IDEKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgaWYgYXJnc1tp
  >> "!B64TMP!" echo XSA9PSAiLS1tYXgtY2hhcnMiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAgbWF4
  >> "!B64TMP!" echo X2NoYXJzID0gaW50KGFyZ3NbaSArIDFdKQogICAgICAgICAgICBpICs9IDIKICAgICAgICBlbHNl
  >> "!B64TMP!" echo OgogICAgICAgICAgICBpICs9IDEKCiAgICBib2R5ID0ganNvbi5kdW1wcyh7InVybCI6IHVybCwg
  >> "!B64TMP!" echo ImZvcm1hdHMiOiBbIm1hcmtkb3duIl19KS5lbmNvZGUoKQogICAgcmVxID0gdXJsbGliLnJlcXVl
  >> "!B64TMP!" echo c3QuUmVxdWVzdCgKICAgICAgICBFTkRQT0lOVCwKICAgICAgICBkYXRhPWJvZHksCiAgICAgICAg
  >> "!B64TMP!" echo aGVhZGVycz17IkNvbnRlbnQtVHlwZSI6ICJhcHBsaWNhdGlvbi9qc29uIiwgIlVzZXItQWdlbnQi
  >> "!B64TMP!" echo OiAiemNvZGUtbG9jYWwtd2ViLzEuMCJ9LAogICAgICAgIG1ldGhvZD0iUE9TVCIsCiAgICApCiAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGltZW91dD05
  >> "!B64TMP!" echo MCkgYXMgcjoKICAgICAgICAgICAgZGF0YSA9IGpzb24ubG9hZChyKQogICAgZXhjZXB0IEV4Y2Vw
  >> "!B64TMP!" echo dGlvbiBhcyBlOgogICAgICAgIHByaW50KGYiU0NSQVBFIEZBSUxFRCBmb3Ige3VybH06IHtlfSIs
  >> "!B64TMP!" echo IGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludCgiSXMgdGhlIGxvY2FsLXNlYXJjaCBzdGFj
  >> "!B64TMP!" echo ayBydW5uaW5nPyBSdW4gc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkgIgogICAgICAgICAgICAgICIo
  >> "!B64TMP!" echo aXQgc3RhcnRzIHRoZSBEb2NrZXIgY29udGFpbmVycyBpZiBuZWVkZWQpLCB0aGVuIHJldHJ5LiIs
  >> "!B64TMP!" echo IGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIHBheWxvYWQgPSBkYXRhLmdl
  >> "!B64TMP!" echo dCgiZGF0YSIpIG9yIHt9CiAgICBtYXJrZG93biA9IHBheWxvYWQuZ2V0KCJtYXJrZG93biIpIG9y
  >> "!B64TMP!" echo ICIiIGlmIGlzaW5zdGFuY2UocGF5bG9hZCwgZGljdCkgZWxzZSAiIgogICAgaWYgbm90IG1hcmtk
  >> "!B64TMP!" echo b3duOgogICAgICAgIHByaW50KCJTQ1JBUEUgUkVUVVJORUQgTk8gTUFSS0RPV04gZm9yIiwgdXJs
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKVs6ODAwXSwg
  >> "!B64TMP!" echo ZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgbGVuKG1hcmtkb3duKSA+
  >> "!B64TMP!" echo IG1heF9jaGFyczoKICAgICAgICBtYXJrZG93biA9IG1hcmtkb3duWzptYXhfY2hhcnNdICsgZiJc
  >> "!B64TMP!" echo blxuWy4uLiB0cnVuY2F0ZWQgYXQge21heF9jaGFyc30gY2hhcnMgLi4uXSIKICAgIHByaW50KG1h
  >> "!B64TMP!" echo cmtkb3duKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lz
  >> "!B64TMP!" echo LmV4aXQobWFpbigpKQo=
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
  if command -v sed >/dev/null 2>&1; then
    sed 's/\r$//; s/$/\r/' "$f" > "$f.crlf" 2>/dev/null && mv "$f.crlf" "$f" || rm -f "$f.crlf"
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
