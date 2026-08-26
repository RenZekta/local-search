#!/usr/bin/env bash
# =============================================================================
#  Local Search DEV RIG packer  -  Linux / macOS / Git Bash
# =============================================================================
#  Self-contained: embeds the complete build/test environment for the
#  local-search installers:
#    * the local-search source tree (21 files)
#    * gen_installers.py / gen_rig.py (the two generators)
#    * every test + build script + BUILD.md
#    * the Windows packer (local-search-rig.bat)
#  So this ONE file reproduces the whole rig anywhere, including both
#  packers. The installers themselves are generated after unpacking
#  (this script offers to do it) with gen_installers.py.
# =============================================================================

set -u

BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
say()  { printf "%b\n" "$1"; }
err()  { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2; }
ok()   { printf "%b[OK]%b %s\n" "$GREEN" "$RESET" "$1"; }
hdr()  { printf "\n%b--- %s ---%b\n" "$CYAN" "$1" "$RESET"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }  # bash-3.2 (macOS) safe

cat <<'BANNER'
============================================================
  Local Search DEV RIG  (build + test environment)
  Unpacks everything needed to regenerate and verify the
  install-local-search installers.
============================================================
BANNER

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_TARGET="$SCRIPT_DIR/local-search-dev"

hdr "Step 1 of 3: Unpack location"
say "  Default: $DEFAULT_TARGET"
printf "  Target folder [press Enter for default]: "
read -r TARGET
[ -z "$TARGET" ] && TARGET="$DEFAULT_TARGET"
if [ "${TARGET#\~}" != "$TARGET" ]; then TARGET="$HOME${TARGET#\~}"; fi  # POSIX tilde expansion
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
say "  Using: $TARGET"
say "  (existing files in the target folder are overwritten)"

hdr "Step 2 of 3: Build now?"
say "  Generate install-local-search.bat/.sh with Python right after unpacking?"
printf "  Run the installer build now? [Y/n]: "
read -r BUILDNOW

hdr "Step 3 of 3: Confirm"
say "  Will unpack 33 files into: $TARGET"
printf "Proceed? [Y/n]: "
read -r CONFIRM
if [ "$(lower "$CONFIRM")" = "n" ]; then say "Cancelled."; exit 0; fi

mkdir -p "$TARGET/local-search/config/searxng" "$TARGET/local-search/local-web/scripts"

say "Unpacking files..."

# --- local-search/config/searxng/settings.yml ---
cat > "$TARGET/local-search/config/searxng/settings.yml" <<'EOF_LOCAL_SEARCH_CONFIG_SEARXNG_SETTINGS_YML'
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
EOF_LOCAL_SEARCH_CONFIG_SEARXNG_SETTINGS_YML

# --- local-search/docker-compose.yml ---
cat > "$TARGET/local-search/docker-compose.yml" <<'EOF_LOCAL_SEARCH_DOCKER_COMPOSE_YML'
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
EOF_LOCAL_SEARCH_DOCKER_COMPOSE_YML

# --- local-search/.env.example ---
cat > "$TARGET/local-search/.env.example" <<'EOF_LOCAL_SEARCH__ENV_EXAMPLE'
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
EOF_LOCAL_SEARCH__ENV_EXAMPLE

# --- local-search/README.md ---
cat > "$TARGET/local-search/README.md" <<'EOF_LOCAL_SEARCH_README_MD'
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
EOF_LOCAL_SEARCH_README_MD

# --- local-search/LICENSE ---
cat > "$TARGET/local-search/LICENSE" <<'EOF_LOCAL_SEARCH_LICENSE'
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
EOF_LOCAL_SEARCH_LICENSE

# --- local-search/.gitignore ---
cat > "$TARGET/local-search/.gitignore" <<'EOF_LOCAL_SEARCH__GITIGNORE'
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
EOF_LOCAL_SEARCH__GITIGNORE

# --- local-search/.gitattributes ---
cat > "$TARGET/local-search/.gitattributes" <<'EOF_LOCAL_SEARCH__GITATTRIBUTES'
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
EOF_LOCAL_SEARCH__GITATTRIBUTES

# --- local-search/Run.bat ---
cat > "$TARGET/local-search/Run.bat" <<'EOF_LOCAL_SEARCH_RUN_BAT'
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
EOF_LOCAL_SEARCH_RUN_BAT

# --- local-search/Stop.bat ---
cat > "$TARGET/local-search/Stop.bat" <<'EOF_LOCAL_SEARCH_STOP_BAT'
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
EOF_LOCAL_SEARCH_STOP_BAT

# --- local-search/Update.bat ---
cat > "$TARGET/local-search/Update.bat" <<'EOF_LOCAL_SEARCH_UPDATE_BAT'
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
EOF_LOCAL_SEARCH_UPDATE_BAT

# --- local-search/Uninstall.bat ---
cat > "$TARGET/local-search/Uninstall.bat" <<'EOF_LOCAL_SEARCH_UNINSTALL_BAT'
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
EOF_LOCAL_SEARCH_UNINSTALL_BAT

# --- local-search/run.sh ---
cat > "$TARGET/local-search/run.sh" <<'EOF_LOCAL_SEARCH_RUN_SH'
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
EOF_LOCAL_SEARCH_RUN_SH

# --- local-search/stop.sh ---
cat > "$TARGET/local-search/stop.sh" <<'EOF_LOCAL_SEARCH_STOP_SH'
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
EOF_LOCAL_SEARCH_STOP_SH

# --- local-search/update.sh ---
cat > "$TARGET/local-search/update.sh" <<'EOF_LOCAL_SEARCH_UPDATE_SH'
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
EOF_LOCAL_SEARCH_UPDATE_SH

# --- local-search/uninstall.sh ---
cat > "$TARGET/local-search/uninstall.sh" <<'EOF_LOCAL_SEARCH_UNINSTALL_SH'
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
EOF_LOCAL_SEARCH_UNINSTALL_SH

# --- local-search/local-web/SKILL.md ---
cat > "$TARGET/local-search/local-web/SKILL.md" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SKILL_MD'
---
name: local-web
description: Search the web and read web pages through the local private stack — SearXNG and Firecrawl on localhost (ports read from the local-search .env, defaults 9990/9991). No API keys, no external services, no MCP tools. The scripts auto-start the local Docker stack when it is down. Use whenever the user asks about anything current, recent, or you are unsure about: news, events, latest versions or releases, documentation, facts to verify, "what do you know about X" questions — even when they don't explicitly say "search the web".
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SKILL_MD

# --- local-search/local-web/LICENSE ---
cat > "$TARGET/local-search/local-web/LICENSE" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_LICENSE'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_LICENSE

# --- local-search/local-web/scripts/config.py ---
cat > "$TARGET/local-search/local-web/scripts/config.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SCRIPTS_CONFIG_PY'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SCRIPTS_CONFIG_PY

# --- local-search/local-web/scripts/ensure_stack.py ---
cat > "$TARGET/local-search/local-web/scripts/ensure_stack.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SCRIPTS_ENSURE_STACK_PY'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SCRIPTS_ENSURE_STACK_PY

# --- local-search/local-web/scripts/web_search.py ---
cat > "$TARGET/local-search/local-web/scripts/web_search.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SCRIPTS_WEB_SEARCH_PY'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SCRIPTS_WEB_SEARCH_PY

# --- local-search/local-web/scripts/web_scrape.py ---
cat > "$TARGET/local-search/local-web/scripts/web_scrape.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SCRIPTS_WEB_SCRAPE_PY'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SCRIPTS_WEB_SCRAPE_PY

# --- gen_installers.py ---
cat > "$TARGET/gen_installers.py" <<'EOF_GEN_INSTALLERS_PY'
#!/usr/bin/env python3
"""
Generator for self-contained installers.

Reads the source files from /home/z/my-project/local-search/ and produces:
  - install-local-search.bat  (Windows, embedded base64 fallback for every file)
  - install-local-search.sh   (Linux/macOS, embedded heredoc fallback for every file)

Both installers FIRST try to copy a file from their own folder (so the full
zip still works and stays fast), and FALL BACK to the embedded copy if the
source file is missing. This fixes the bug where users who downloaded only
the top-level files (and missed config/searxng/settings.yml or the hidden
.env.example) got an empty searxng directory and a failed install.
"""
import base64
import os
import sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "local-search")

# (relative path in install folder, source file)
# Used by BOTH generators. The .bat generator skips install-local-search.bat
# (it copies itself via %~f0 at runtime); the .sh generator embeds it too so
# a Linux install produces a Windows-portable folder.
FILES = [
    ("config/searxng/settings.yml",          "config/searxng/settings.yml"),
    ("docker-compose.yml",                   "docker-compose.yml"),
    (".env.example",                         ".env.example"),
    ("README.md",                            "README.md"),
    ("LICENSE",                              "LICENSE"),
    (".gitignore",                           ".gitignore"),
    (".gitattributes",                       ".gitattributes"),
    ("Run.bat",                              "Run.bat"),
    ("Stop.bat",                             "Stop.bat"),
    ("Update.bat",                           "Update.bat"),
    ("Uninstall.bat",                        "Uninstall.bat"),
    ("run.sh",                               "run.sh"),
    ("stop.sh",                              "stop.sh"),
    ("update.sh",                            "update.sh"),
    ("uninstall.sh",                         "uninstall.sh"),
    # ---- bundled local-web agent skill ----
    ("local-web/SKILL.md",                   "local-web/SKILL.md"),
    ("local-web/LICENSE",                    "local-web/LICENSE"),
    ("local-web/scripts/config.py",          "local-web/scripts/config.py"),
    ("local-web/scripts/ensure_stack.py",    "local-web/scripts/ensure_stack.py"),
    ("local-web/scripts/web_search.py",      "local-web/scripts/web_search.py"),
    ("local-web/scripts/web_scrape.py",      "local-web/scripts/web_scrape.py"),
    ("install-local-search.bat",             "install-local-search.bat"),
]


def read(rel):
    with open(os.path.join(SRC, rel), "rb") as f:
        return f.read()


# =============================================================================
#  Windows installer (.bat)
# =============================================================================

def b64_chunked(data, width=76):
    """Return list of <=width-char base64 lines."""
    s = base64.b64encode(data).decode("ascii")
    return [s[i:i+width] for i in range(0, len(s), width)]


def gen_bat():
    out = []
    ap = out.append

    ap('@echo off')
    ap('setlocal enableDelayedExpansion')
    ap('chcp 65001 >nul')
    ap('title Local Search - Installer')
    ap('')
    ap('REM ===========================================================================')
    ap('REM  Local Search Installer  (Firecrawl + SearXNG + local-web skill)  -  Windows')
    ap('REM ===========================================================================')
    ap('REM  Self-contained: every file the installer needs is embedded below as')
    ap('REM  base64. If a source file is missing from this script\'s folder (e.g. you')
    ap('REM  only downloaded this one .bat), the embedded copy is used instead.')
    ap('REM  After installing the stack it also copies the bundled local-web agent')
    ap('REM  skill into %USERPROFILE%\\.agents\\skills\\local-web.')
    ap('REM ===========================================================================')
    ap('')
    ap('echo ============================================================')
    ap('echo   Local Search Installer  (Firecrawl + SearXNG + local-web)')
    ap('echo   A local web-browsing system for AI models.')
    ap('echo ============================================================')
    ap('echo.')
    ap('')
    # Docker check
    ap('where docker >nul 2>&1')
    ap('if errorlevel 1 (')
    ap('  echo [ERROR] Docker was not found on your PATH.')
    ap('  echo   Install Docker Desktop: https://www.docker.com/products/docker-desktop/')
    ap('  echo   Start it, wait until "Docker Desktop is running", then re-run.')
    ap('  pause & exit /b 1')
    ap(')')
    ap('docker info >nul 2>&1')
    ap('if errorlevel 1 (')
    ap('  echo [ERROR] Docker is installed but the engine is not running.')
    ap('  echo   Start Docker Desktop and wait until it says "running".')
    ap('  pause & exit /b 1')
    ap(')')
    ap('echo [OK] Docker is running.')
    ap('echo.')
    ap('')
    # Source folder
    ap('set "SRC=%~dp0"')
    ap('if "!SRC:~-1!"=="\\" set "SRC=!SRC:~0,-1!"')
    ap('')
    # Prompts
    ap('set "DEFAULT_TARGET=%USERPROFILE%\\local-search"')
    ap('')
    ap('echo --- Step 1 of 4: Install location --------------------------')
    ap('echo   Default: %DEFAULT_TARGET%')
    ap('set "TARGET="')
    ap('set /p TARGET="  Target folder [press Enter for default]: "')
    ap('if "!TARGET!"=="" set "TARGET=%DEFAULT_TARGET%"')
    ap('set "TARGET=!TARGET:"=!"')
    ap('for %%I in ("!TARGET!") do set "TARGET=%%~fI"')
    ap('echo   Using: !TARGET!')
    ap('echo.')
    ap('')
    ap(':ask_searxng')
    ap('echo --- Step 2 of 4: SearXNG port (default 9990) --------------')
    ap('set "SEARXNG_PORT="')
    ap('set /p SEARXNG_PORT="  Port for SearXNG [press Enter for 9990]: "')
    ap('if "!SEARXNG_PORT!"=="" set "SEARXNG_PORT=9990"')
    ap('call :validate_port "!SEARXNG_PORT!"')
    ap('if !errorlevel! neq 0 ( echo   [!] "!SEARXNG_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_searxng )')
    ap('')
    ap(':ask_firecrawl')
    ap('echo --- Step 3 of 4: Firecrawl port (default 9991) ------------')
    ap('set "FIRECRAWL_PORT="')
    ap('set /p FIRECRAWL_PORT="  Port for Firecrawl [press Enter for 9991]: "')
    ap('if "!FIRECRAWL_PORT!"=="" set "FIRECRAWL_PORT=9991"')
    ap('call :validate_port "!FIRECRAWL_PORT!"')
    ap('if !errorlevel! neq 0 ( echo   [!] "!FIRECRAWL_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_firecrawl )')
    ap('if /i "!FIRECRAWL_PORT!"=="!SEARXNG_PORT!" ( echo   [!] Firecrawl port must differ from SearXNG port. & echo. & goto ask_firecrawl )')
    ap('')
    ap('echo.')
    ap('echo --- Step 4 of 4: Local LLM (optional) ---------------------')
    ap('echo   Lets Firecrawl do AI extraction (/v1/extract) and summaries.')
    ap('echo   Recommended: LM Studio  -^>  http://localhost:1234/v1')
    ap('set "USE_LLM="')
    ap('set /p USE_LLM="  Connect a local LLM now? [y/N]: "')
    ap('set "OPENAI_BASE_URL="')
    ap('set "OPENAI_API_KEY="')
    ap('set "MODEL_NAME="')
    ap('if /i "!USE_LLM!"=="y" (')
    ap('  set "LLM_URL="')
    ap('  set /p LLM_URL="    LM Studio server URL as shown in LM Studio [Enter = http://localhost:1234/v1]: "')
    ap('  if "!LLM_URL!"=="" set "LLM_URL=http://localhost:1234/v1"')
    ap('  set "LLM_MODEL="')
    ap('  set /p LLM_MODEL="    Model name loaded in LM Studio [Enter to skip]: "')
    ap('  set "OPENAI_BASE_URL=!LLM_URL!"')
    ap('  set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://localhost=http://host.docker.internal!"')
    ap('  set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://127.0.0.1=http://host.docker.internal!"')
    ap('  set "OPENAI_API_KEY=lm-studio"')
    ap('  if not "!LLM_MODEL!"=="" set "MODEL_NAME=!LLM_MODEL!"')
    ap('  echo     ^(Container will reach it at: !OPENAI_BASE_URL!^)')
    ap('  echo     ^(Make sure LM Studio has "Serve on local network" enabled.^)')
    ap(')')
    ap('')
    # Summary + confirm
    ap('echo.')
    ap('echo ============================================================')
    ap('echo   Summary')
    ap('echo   Folder:         !TARGET!')
    ap('echo   SearXNG port:   !SEARXNG_PORT!')
    ap('echo   Firecrawl port: !FIRECRAWL_PORT!')
    ap('echo   Agent skill:    %USERPROFILE%\\.agents\\skills\\local-web')
    ap('if defined OPENAI_BASE_URL (')
    ap('  echo   LLM endpoint:   !OPENAI_BASE_URL!  !MODEL_NAME!')
    ap(') else (')
    ap('  echo   LLM endpoint:   ^(none - enable later by editing .env^)')
    ap(')')
    ap('echo ============================================================')
    ap('set "CONFIRM="')
    ap('set /p CONFIRM="Proceed with install? [Y/n]: "')
    ap('if /i "!CONFIRM!"=="n" ( echo Install cancelled. & pause & exit /b 0 )')
    ap('')
    # Create folders
    ap('if not exist "!TARGET!" mkdir "!TARGET!"')
    ap('if not exist "!TARGET!\\config\\searxng" mkdir "!TARGET!\\config\\searxng"')
    ap('if not exist "!TARGET!\\local-web\\scripts" mkdir "!TARGET!\\local-web\\scripts"')
    ap('')
    # Backup existing .env
    ap('if exist "!TARGET!\\.env" (')
    ap('  for /f "usebackq delims=" %%t in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMddHHmmss"`) do set "LDT=%%t"')
    ap('  copy /Y "!TARGET!\\.env" "!TARGET!\\.env.bak.!LDT!" >nul')
    ap('  echo   Backed up existing .env to .env.bak.!LDT!')
    ap(')')
    ap('')
    # -------------------------------------------------------------------
    #  Materialise every project file: copy from source if present, else
    #  decode the embedded base64 blob for that file.
    # -------------------------------------------------------------------
    ap('echo Copying files...')

    for rel, src in FILES:
        if rel == "install-local-search.bat":
            # The .bat copies ITSELF at runtime via %~f0 (see below). Do not
            # embed itself here -- that would read a stale previous-generation
            # .bat and create a confusing duplicate.
            continue
        data = read(src)
        lines = b64_chunked(data)
        rel_win = rel.replace("/", "\\")
        ap('')
        ap('REM --- ' + rel + ' ---')
        ap('set "NEED_B64=1"')
        ap('if exist "!SRC!\\' + rel_win + '" (')
        ap('  copy /Y "!SRC!\\' + rel_win + '" "!TARGET!\\' + rel_win + '" >nul 2>&1')
        ap('  if exist "!TARGET!\\' + rel_win + '" set "NEED_B64=0"')
        ap(')')
        ap('if "!NEED_B64!"=="1" (')
        ap('  echo   [embedded] ' + rel + '  ^(source not found next to installer; using built-in copy^)')
        # Deterministic temp-file tag derived from the file path (CRC32).
        # Must be stable across gen runs so the .bat embedded inside the .sh
        # matches the standalone .bat byte-for-byte.
        import zlib
        tag = "LS" + str(zlib.crc32(rel.encode("utf-8")) & 0xFFFFFFFF)
        ap('  set "B64TMP=%TEMP%\\' + tag + '.b64"')
        first = True
        for ln in lines:
            op = '>' if first else '>>'
            ap('  ' + op + ' "!B64TMP!" echo ' + ln)
            first = False
        ap('  set "LS_B64_IN=!B64TMP!"')
        ap('  set "LS_B64_OUT=!TARGET!\\' + rel_win + '"')
        ap('  call :decode_b64')
        ap('  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1')
        ap(')')

    # Include the installers themselves so the folder is self-contained / re-installable
    ap('if exist "!SRC!\\install-local-search.bat" copy /Y "!SRC!\\install-local-search.bat" "!TARGET!\\install-local-search.bat" >nul 2>&1')
    ap('if exist "!SRC!\\install-local-search.sh"  copy /Y "!SRC!\\install-local-search.sh"  "!TARGET!\\install-local-search.sh"  >nul 2>&1')
    ap('REM Always also drop the *current* installer (this script) into target, even if')
    ap('REM the source copy above was skipped (e.g. user ran a renamed copy of the bat).')
    ap('copy /Y "%~f0" "!TARGET!\\install-local-search.bat" >nul 2>&1')
    ap('')
    # Generate secrets
    ap('echo Generating secure credentials...')
    ap('call :genkey SECRET')
    ap('call :genkey BULL')
    ap('call :genkey PGPASS')
    ap('call :genkey RABPASS')
    ap('')
    # Write .env
    ap('echo Writing .env ...')
    ap('> "!TARGET!\\.env" echo # Local Search configuration - generated by install-local-search.bat')
    ap('>> "!TARGET!\\.env" echo # Edit ports/LLM here, then run Update.bat to apply.')
    ap('>> "!TARGET!\\.env" echo.')
    ap('>> "!TARGET!\\.env" echo # ---- Host ports ----')
    ap('>> "!TARGET!\\.env" echo SEARXNG_PORT=!SEARXNG_PORT!')
    ap('>> "!TARGET!\\.env" echo FIRECRAWL_PORT=!FIRECRAWL_PORT!')
    ap('>> "!TARGET!\\.env" echo.')
    ap('>> "!TARGET!\\.env" echo # ---- SearXNG instance secret ----')
    ap('>> "!TARGET!\\.env" echo SEARXNG_SECRET=!SECRET!')
    ap('>> "!TARGET!\\.env" echo.')
    ap('>> "!TARGET!\\.env" echo # ---- Firecrawl internal credentials ----')
    ap('>> "!TARGET!\\.env" echo BULL_AUTH_KEY=!BULL!')
    ap('>> "!TARGET!\\.env" echo POSTGRES_DB=firecrawl')
    ap('>> "!TARGET!\\.env" echo POSTGRES_USER=firecrawl')
    ap('>> "!TARGET!\\.env" echo POSTGRES_PASSWORD=!PGPASS!')
    ap('>> "!TARGET!\\.env" echo RABBITMQ_USER=firecrawl')
    ap('>> "!TARGET!\\.env" echo RABBITMQ_PASSWORD=!RABPASS!')
    ap('>> "!TARGET!\\.env" echo.')
    ap('>> "!TARGET!\\.env" echo LOGGING_LEVEL=info')
    ap('if defined OPENAI_BASE_URL (')
    ap('  >> "!TARGET!\\.env" echo.')
    ap('  >> "!TARGET!\\.env" echo # ---- Local LLM for Firecrawl AI features ----')
    ap('  >> "!TARGET!\\.env" echo OPENAI_BASE_URL=!OPENAI_BASE_URL!')
    ap('  >> "!TARGET!\\.env" echo OPENAI_API_KEY=!OPENAI_API_KEY!')
    ap('  if defined MODEL_NAME >> "!TARGET!\\.env" echo MODEL_NAME=!MODEL_NAME!')
    ap(')')
    ap('')
    # Inject SearXNG secret into settings.yml
    ap('echo Injecting SearXNG secret into settings.yml ...')
    ap('powershell -NoProfile -Command "(Get-Content -Raw \'!TARGET!\\config\\searxng\\settings.yml\') -replace \'__SEARXNG_SECRET_PLACEHOLDER__\', \'!SECRET!\' | Set-Content -NoNewline \'!TARGET!\\config\\searxng\\settings.yml\'"')
    ap('')
    # -------------------------------------------------------------------
    #  Install the bundled local-web agent skill into the user's skills
    #  directory (add/override), and record the install path hint.
    # -------------------------------------------------------------------
    ap('echo Installing the local-web agent skill...')
    ap('set "SKILL_DIR=%USERPROFILE%\\.agents\\skills\\local-web"')
    ap('if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"')
    ap('if not exist "%USERPROFILE%\\.agents\\skills" mkdir "%USERPROFILE%\\.agents\\skills"')
    ap('xcopy /E /I /Y /Q "!TARGET!\\local-web" "!SKILL_DIR!" >nul')
    ap('if errorlevel 1 (')
    ap('  echo   [WARNING] Could not copy the local-web skill to !SKILL_DIR!.')
    ap(') else (')
    ap('  > "!TARGET!\\local-web\\install-dir.txt" echo !TARGET!')
    ap('  > "!SKILL_DIR!\\install-dir.txt" echo !TARGET!')
    ap('  echo   Agent skill installed: !SKILL_DIR!')
    ap(')')
    ap('')
    # Pull + up
    ap('echo.')
    ap('echo Pulling Docker images (first run downloads ~3-4 GB, please be patient)...')
    ap('pushd "!TARGET!"')
    ap('docker compose pull')
    ap('if !errorlevel! neq 0 ( echo   [WARNING] docker compose pull reported errors. Trying to start anyway... )')
    ap('echo Starting services...')
    ap('docker compose up -d')
    ap('set "UP_RC=!errorlevel!"')
    ap('popd')
    ap('if !UP_RC! neq 0 (')
    ap('  echo.')
    ap('  echo [ERROR] docker compose up failed. See messages above.')
    ap('  echo   Common fixes:')
    ap('  echo     - Make sure Docker Desktop is running.')
    ap('  echo     - Make sure ports !SEARXNG_PORT! and !FIRECRAWL_PORT! are not in use.')
    ap('  echo     - Re-run this installer or run Update.bat after fixing.')
    ap('  echo.')
    ap('  pause & exit /b 1')
    ap(')')
    ap('')
    # Done
    ap('echo.')
    ap('echo ============================================================')
    ap('echo   Installation complete!')
    ap('echo.')
    ap('echo   SearXNG  (search + JSON API):  http://localhost:!SEARXNG_PORT!')
    ap('echo   Firecrawl (scrape/crawl API): http://localhost:!FIRECRAWL_PORT!')
    ap('echo   local-web skill:              %USERPROFILE%\\.agents\\skills\\local-web')
    ap('echo.')
    ap('echo   If your agent was already running, restart it so it picks up')
    ap('echo   the new skill.')
    ap('echo.')
    ap('echo   Manage the stack with the .bat files in:')
    ap('echo     !TARGET!')
    ap('echo       Run.bat   Stop.bat   Update.bat   Uninstall.bat')
    ap('echo.')
    ap('echo   See README.md for how to connect this to your AI models')
    ap('echo   (local-web skill, LM Studio, MCP server, direct prompting, etc.).')
    ap('echo ============================================================')
    ap('echo.')
    ap('pause')
    ap('exit /b 0')
    ap('')
    # Subroutines
    ap('REM ===========================================================================')
    ap('REM  Subroutines')
    ap('REM ===========================================================================')
    ap('')
    ap(':validate_port')
    ap('echo %~1| findstr /r /c:"^[0-9][0-9]*$" >nul')
    ap('if errorlevel 1 exit /b 1')
    ap('if %~1 lss 1 exit /b 1')
    ap('if %~1 gtr 65535 exit /b 1')
    ap('exit /b 0')
    ap('')
    ap(':genkey')
    ap('set "KFILE=%TEMP%\\local_search_key.tmp"')
    ap('powershell -NoProfile -Command "$rng=[Security.Cryptography.RandomNumberGenerator]::Create(); $r=New-Object byte[] 32; $rng.GetBytes($r); -join ($r | ForEach-Object { $_.ToString(\'x2\') })" > "%KFILE%"')
    ap('set /p "%~1=" < "%KFILE%"')
    ap('del "%KFILE%" >nul 2>&1')
    ap('exit /b 0')
    ap('')
    ap(':decode_b64')
    ap('REM  %1 = path to a .b64 text file, %2 = output binary path (may not exist yet)')
    ap('REM  Pass paths via PS variables to survive spaces / quotes in TARGET.')
    ap('powershell -NoProfile -Command "$in=$env:LS_B64_IN; $out=$env:LS_B64_OUT; [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String(((Get-Content -Raw $in) -replace \'\\s\',\'\')))"')
    ap('exit /b 0')

    return "\r\n".join(out) + "\r\n"


# =============================================================================
#  Linux / macOS installer (.sh)
# =============================================================================

def gen_sh():
    out = []
    ap = out.append

    ap('#!/usr/bin/env bash')
    ap('# =============================================================================')
    ap('#  Local Search Installer  (Firecrawl + SearXNG + local-web skill)')
    ap('#                        -  Linux & macOS')
    ap('# =============================================================================')
    ap('#  Self-contained: every file the installer needs is embedded below as a')
    ap('#  quoted heredoc. If a source file is missing from this script\'s folder')
    ap('#  (e.g. you only downloaded this one .sh), the embedded copy is used.')
    ap('#  After installing the stack it also copies the bundled local-web agent')
    ap('#  skill into ~/.agents/skills/local-web.')
    ap('# =============================================================================')
    ap('')
    ap('set -u')
    ap('')
    ap('BOLD="\\033[1m"; DIM="\\033[2m"; GREEN="\\033[32m"; YELLOW="\\033[33m"; RED="\\033[31m"; CYAN="\\033[36m"; RESET="\\033[0m"')
    ap('say()  { printf "%b\\n" "$1"; }')
    ap('err()  { printf "%b[ERROR]%b %s\\n" "$RED" "$RESET" "$1" >&2; }')
    ap('ok()   { printf "%b[OK]%b %s\\n" "$GREEN" "$RESET" "$1"; }')
    ap('hdr()  { printf "\\n%b--- %s ---%b\\n" "$CYAN" "$1" "$RESET"; }')
    ap('lower() { printf \'%s\' "$1" | tr \'[:upper:]\' \'[:lower:]\'; }  # bash-3.2 (macOS) safe')
    ap('')
    ap('cat <<\'BANNER\'')
    ap('============================================================')
    ap('  Local Search Installer  (Firecrawl + SearXNG + local-web)')
    ap('  A local web-browsing system for AI models.')
    ap('============================================================')
    ap('BANNER')
    ap('')
    # Docker check
    ap('if ! command -v docker >/dev/null 2>&1; then')
    ap('  err "Docker was not found on your PATH."')
    ap('  say ""')
    ap('  say "Install Docker Engine (Linux) or Docker Desktop (macOS):"')
    ap('  say "  Linux:   https://docs.docker.com/engine/install/"')
    ap('  say "  macOS:   https://www.docker.com/products/docker-desktop/"')
    ap('  say "Then re-run this installer."')
    ap('  exit 1')
    ap('fi')
    ap('if ! docker info >/dev/null 2>&1; then')
    ap('  err "Docker is installed but the engine is not running."')
    ap('  say ""')
    ap('  say "Linux: start the service (e.g. \'sudo systemctl start docker\' or add"')
    ap('  say "      your user to the docker group and re-log in)."')
    ap('  say "macOS: start Docker Desktop and wait until it says \'running\'."')
    ap('  exit 1')
    ap('fi')
    ap('if docker compose version >/dev/null 2>&1; then DC="docker compose"')
    ap('elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"')
    ap('else err "Docker Compose was not found. Install the \'docker compose\' plugin (v2)."; exit 1; fi')
    ap('ok "Docker and Docker Compose are available ($DC)."')
    ap('')
    # Source folder
    ap('SRC="$(cd "$(dirname "$0")" && pwd)"')
    ap('')
    # Prompts
    ap('DEFAULT_TARGET="$HOME/local-search"')
    ap('hdr "Step 1 of 4: Install location"')
    ap('say "  Default: $DEFAULT_TARGET"')
    ap('printf "  Target folder [press Enter for default]: "')
    ap('read -r TARGET')
    ap('[ -z "$TARGET" ] && TARGET="$DEFAULT_TARGET"')
    ap('if [ "${TARGET#\\~}" != "$TARGET" ]; then TARGET="$HOME${TARGET#\\~}"; fi  # POSIX tilde expansion')
    ap('mkdir -p "$TARGET"')
    ap('TARGET="$(cd "$TARGET" && pwd)"')
    ap('say "  Using: $TARGET"')
    ap('')
    ap('validate_port() {')
    ap('  local p="$1"')
    ap('  [[ "$p" =~ ^[0-9]+$ ]] || return 1')
    ap('  [ "$p" -ge 1 ] 2>/dev/null || return 1')
    ap('  [ "$p" -le 65535 ] 2>/dev/null || return 1')
    ap('  return 0')
    ap('}')
    ap('')
    ap('hdr "Step 2 of 4: SearXNG port (default 9990)"')
    ap('while true; do')
    ap('  printf "  Port for SearXNG [press Enter for 9990]: "')
    ap('  read -r SEARXNG_PORT')
    ap('  [ -z "$SEARXNG_PORT" ] && SEARXNG_PORT=9990')
    ap('  if validate_port "$SEARXNG_PORT"; then break; fi')
    ap('  say "  ${YELLOW}[!]${RESET} \'$SEARXNG_PORT\' is not a valid port (1-65535)."')
    ap('done')
    ap('')
    ap('hdr "Step 3 of 4: Firecrawl port (default 9991)"')
    ap('while true; do')
    ap('  printf "  Port for Firecrawl [press Enter for 9991]: "')
    ap('  read -r FIRECRAWL_PORT')
    ap('  [ -z "$FIRECRAWL_PORT" ] && FIRECRAWL_PORT=9991')
    ap('  if ! validate_port "$FIRECRAWL_PORT"; then')
    ap('    say "  ${YELLOW}[!]${RESET} \'$FIRECRAWL_PORT\' is not a valid port (1-65535)."')
    ap('    continue')
    ap('  fi')
    ap('  if [ "$FIRECRAWL_PORT" = "$SEARXNG_PORT" ]; then')
    ap('    say "  ${YELLOW}[!]${RESET} Firecrawl port must differ from SearXNG port."')
    ap('    continue')
    ap('  fi')
    ap('  break')
    ap('done')
    ap('')
    ap('hdr "Step 4 of 4: Local LLM (optional)"')
    ap('say "  Lets Firecrawl do AI extraction (/v1/extract) and summaries."')
    ap('say "  Recommended: LM Studio -> http://localhost:1234/v1"')
    ap('printf "  Connect a local LLM now? [y/N]: "')
    ap('read -r USE_LLM')
    ap('OPENAI_BASE_URL=""; OPENAI_API_KEY=""; MODEL_NAME=""')
    ap('if [ "$(lower "$USE_LLM")" = "y" ]; then')
    ap('  printf "    LM Studio server URL (as shown in LM Studio) [press Enter for http://localhost:1234/v1]: "')
    ap('  read -r LLM_URL')
    ap('  [ -z "$LLM_URL" ] && LLM_URL="http://localhost:1234/v1"')
    ap('  printf "    Model name (id loaded in LM Studio) [press Enter to skip]: "')
    ap('  read -r LLM_MODEL')
    ap('  OPENAI_BASE_URL="${LLM_URL/http:\\/\\/localhost/http:\\/\\/host.docker.internal}"')
    ap('  OPENAI_BASE_URL="${OPENAI_BASE_URL/http:\\/\\/127.0.0.1/http:\\/\\/host.docker.internal}"')
    ap('  OPENAI_API_KEY="lm-studio"')
    ap('  [ -n "$LLM_MODEL" ] && MODEL_NAME="$LLM_MODEL"')
    ap('  say "    (Container will reach it at: $OPENAI_BASE_URL)"')
    ap('  say "    (Make sure LM Studio has \'Serve on local network\' enabled.)"')
    ap('fi')
    ap('')
    # Summary + confirm
    ap('echo')
    ap('say "${BOLD}============================================================${RESET}"')
    ap('say "${BOLD}  Summary${RESET}"')
    ap('say "  Folder:         $TARGET"')
    ap('say "  SearXNG port:   $SEARXNG_PORT"')
    ap('say "  Firecrawl port: $FIRECRAWL_PORT"')
    ap('say "  Agent skill:    $HOME/.agents/skills/local-web"')
    ap('if [ -n "$OPENAI_BASE_URL" ]; then')
    ap('  say "  LLM endpoint:   $OPENAI_BASE_URL  $MODEL_NAME"')
    ap('else')
    ap('  say "  LLM endpoint:   (none - enable later by editing .env)"')
    ap('fi')
    ap('say "${BOLD}============================================================${RESET}"')
    ap('printf "Proceed with install? [Y/n]: "')
    ap('read -r CONFIRM')
    ap('if [ "$(lower "$CONFIRM")" = "n" ]; then say "Install cancelled."; exit 0; fi')
    ap('')
    # Create folders
    ap('mkdir -p "$TARGET/config/searxng" "$TARGET/local-web/scripts"')
    ap('')
    # Backup existing .env
    ap('if [ -f "$TARGET/.env" ]; then')
    ap('  LDT="$(date +%Y%m%d%H%M%S)"')
    ap('  cp "$TARGET/.env" "$TARGET/.env.bak.$LDT"')
    ap('  say "  Backed up existing .env to .env.bak.$LDT"')
    ap('fi')
    ap('')
    # -------------------------------------------------------------------
    #  Materialise every project file: copy from source if present, else
    #  use the embedded heredoc for that file.
    # -------------------------------------------------------------------
    ap('say "Copying all project files..."')

    for rel, src in FILES:
        data = read(src)
        text = data.decode("utf-8")
        tag = "EOF_" + "".join(c if c.isalnum() else "_" for c in rel).upper()
        ap('')
        ap('# --- ' + rel + ' ---')
        ap('if [ -f "$SRC/' + rel + '" ]; then')
        ap('  cp "$SRC/' + rel + '" "$TARGET/' + rel + '"')
        ap('else')
        ap('  say "  [embedded] ' + rel + '  (source not found next to installer; using built-in copy)"')
        ap('  cat > "$TARGET/' + rel + '" <<\'' + tag + '\'')
        # Normalise line endings to LF in the heredoc body so the runtime
        # CRLF-conversion loop produces clean CRLF (not \r\r\n) for .bat files.
        # splitlines() avoids a spurious trailing empty line that would
        # otherwise add a blank line at the end of every embedded file.
        text_lf = text.replace("\r\n", "\n").replace("\r", "\n")
        for line in text_lf.splitlines():
            ap(line)
        ap(tag)
        ap('fi')

    # include the installers themselves
    ap('[ -f "$SRC/install-local-search.sh" ] && cp "$SRC/install-local-search.sh" "$TARGET/install-local-search.sh"')
    ap('[ -f "$SRC/install-local-search.bat" ] && cp "$SRC/install-local-search.bat" "$TARGET/install-local-search.bat"')
    ap('# Always also drop the *current* installer (this script) into target, even')
    ap('# if it was renamed (the check above looks for the canonical name).')
    ap('cp -f "$0" "$TARGET/install-local-search.sh" 2>/dev/null || true')
    ap('chmod +x "$TARGET"/*.sh 2>/dev/null || true')
    ap('')
    # Ensure every .bat file in TARGET has CRLF line endings (Windows cmd is
    # happier with CRLF; the heredocs above wrote LF, which works but isn't
    # ideal when the folder is later copied to a Windows machine).
    # The sed is idempotent: strip any trailing CR first, then add one back,
    # so files copied from source (already CRLF) are not double-converted.
    ap('for f in "$TARGET"/*.bat; do')
    ap('  [ -f "$f" ] || continue')
    ap('  if command -v awk >/dev/null 2>&1; then')
    ap('    awk \'{sub(/\\r$/,""); printf "%s\\r\\n", $0}\' "$f" > "$f.crlf" 2>/dev/null && mv "$f.crlf" "$f" || rm -f "$f.crlf"')
    ap('  fi')
    ap('done')
    ap('')
    # Generate secrets
    ap('say "Generating secure credentials..."')
    ap('genkey() {')
    ap('  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32')
    ap('  else head -c 32 /dev/urandom | od -An -tx1 | tr -d \' \\n\'; fi')
    ap('}')
    ap('SECRET="$(genkey)"; BULL="$(genkey)"; PGPASS="$(genkey)"; RABPASS="$(genkey)"')
    ap('')
    # Write .env
    ap('say "Writing .env ..."')
    ap('{')
    ap('  echo "# Local Search configuration - generated by install-local-search.sh"')
    ap('  echo "# Edit ports/LLM here, then run update.sh to apply."')
    ap('  echo')
    ap('  echo "# ---- Host ports ----"')
    ap('  echo "SEARXNG_PORT=$SEARXNG_PORT"')
    ap('  echo "FIRECRAWL_PORT=$FIRECRAWL_PORT"')
    ap('  echo')
    ap('  echo "# ---- SearXNG instance secret ----"')
    ap('  echo "SEARXNG_SECRET=$SECRET"')
    ap('  echo')
    ap('  echo "# ---- Firecrawl internal credentials ----"')
    ap('  echo "BULL_AUTH_KEY=$BULL"')
    ap('  echo "POSTGRES_DB=firecrawl"')
    ap('  echo "POSTGRES_USER=firecrawl"')
    ap('  echo "POSTGRES_PASSWORD=$PGPASS"')
    ap('  echo "RABBITMQ_USER=firecrawl"')
    ap('  echo "RABBITMQ_PASSWORD=$RABPASS"')
    ap('  echo')
    ap('  echo "LOGGING_LEVEL=info"')
    ap('  if [ -n "$OPENAI_BASE_URL" ]; then')
    ap('    echo')
    ap('    echo "# ---- Local LLM for Firecrawl AI features ----"')
    ap('    echo "OPENAI_BASE_URL=$OPENAI_BASE_URL"')
    ap('    echo "OPENAI_API_KEY=$OPENAI_API_KEY"')
    ap('    [ -n "$MODEL_NAME" ] && echo "MODEL_NAME=$MODEL_NAME"')
    ap('  fi')
    ap('} > "$TARGET/.env"')
    ap('')
    # Inject secret
    ap('say "Injecting SearXNG secret into settings.yml ..."')
    ap('SFILE="$TARGET/config/searxng/settings.yml"')
    ap('sed "s/__SEARXNG_SECRET_PLACEHOLDER__/$SECRET/" "$SFILE" > "$SFILE.tmp" && mv "$SFILE.tmp" "$SFILE"')
    ap('')
    # -------------------------------------------------------------------
    #  Install the bundled local-web agent skill into the user's skills
    #  directory (add/override), and record the install path hint.
    # -------------------------------------------------------------------
    ap('say "Installing the local-web agent skill..."')
    ap('SKILL_DIR="$HOME/.agents/skills/local-web"')
    ap('rm -rf "$SKILL_DIR"')
    ap('mkdir -p "$HOME/.agents/skills"')
    ap('if cp -r "$TARGET/local-web" "$SKILL_DIR"; then')
    ap('  printf \'%s\\n\' "$TARGET" > "$TARGET/local-web/install-dir.txt"')
    ap('  printf \'%s\\n\' "$TARGET" > "$SKILL_DIR/install-dir.txt"')
    ap('  say "  Agent skill installed: $SKILL_DIR"')
    ap('else')
    ap('  say "  ${YELLOW}[WARNING]${RESET} could not copy the local-web skill to $SKILL_DIR"')
    ap('fi')
    ap('')
    # Pull + up
    ap('echo')
    ap('say "Pulling Docker images (first run downloads ~3-4 GB, please be patient)..."')
    ap('cd "$TARGET"')
    ap('$DC pull || say "${YELLOW}[WARNING]${RESET} some images failed to pull; trying to start anyway."')
    ap('say "Starting services..."')
    ap('if ! $DC up -d; then')
    ap('  err "docker compose up failed. See messages above."')
    ap('  say "  Common fixes:"')
    ap('  say "    - Make sure Docker is running (and your user is in the \'docker\' group on Linux)."')
    ap('  say "    - Make sure ports $SEARXNG_PORT and $FIRECRAWL_PORT are not in use."')
    ap('  say "    - Re-run this installer or run update.sh after fixing."')
    ap('  exit 1')
    ap('fi')
    ap('')
    # Done
    ap('echo')
    ap('say "${GREEN}============================================================${RESET}"')
    ap('say "${GREEN}  Installation complete!${RESET}"')
    ap('echo')
    ap('say "  SearXNG  (search + JSON API):  http://localhost:$SEARXNG_PORT"')
    ap('say "  Firecrawl (scrape/crawl API): http://localhost:$FIRECRAWL_PORT"')
    ap('say "  local-web skill:              $HOME/.agents/skills/local-web"')
    ap('echo')
    ap('say "  If your agent was already running, restart it so it picks up"')
    ap('say "  the new skill."')
    ap('echo')
    ap('say "  Manage the stack with the scripts in:"')
    ap('say "    $TARGET"')
    ap('say "      ./run.sh   ./stop.sh   ./update.sh   ./uninstall.sh"')
    ap('echo')
    ap('say "  See README.md for how to connect this to your AI models"')
    ap('say "  (local-web skill, LM Studio, MCP server, direct prompting, etc.)."')
    ap('say "${GREEN}============================================================${RESET}"')

    return "\n".join(out) + "\n"


def main():
    # IMPORTANT: write the .bat to disk FIRST, THEN generate the .sh.
    # The .sh embeds install-local-search.bat as a heredoc, so it must read
    # the freshly-written .bat (not a stale previous-generation copy).
    bat = gen_bat()
    with open(os.path.join(SRC, "install-local-search.bat"), "wb") as f:
        f.write(bat.encode("utf-8"))
    sh = gen_sh()
    with open(os.path.join(SRC, "install-local-search.sh"), "wb") as f:
        f.write(sh.encode("utf-8"))
    os.chmod(os.path.join(SRC, "install-local-search.sh"), 0o755)
    print("Wrote install-local-search.bat (%d bytes)" % len(bat))
    print("Wrote install-local-search.sh  (%d bytes)" % len(sh))


if __name__ == "__main__":
    main()
EOF_GEN_INSTALLERS_PY

# --- gen_rig.py ---
cat > "$TARGET/gen_rig.py" <<'EOF_GEN_RIG_PY'
#!/usr/bin/env python3
"""
Generate the self-contained dev-rig packers for local-search:
  local-search-rig.bat   (Windows)
  local-search-rig.sh    (Linux / macOS / Git Bash)

Each packer embeds EVERYTHING needed to rebuild and re-verify the
install-local-search installers:
  * the full local-search source tree (21 files; the generated installers
    are NOT embedded -- run gen_installers.py after unpacking to create them)
  * the build/test rig itself (gen_installers.py, gen_rig.py, tests,
    build scripts, BUILD.md)
  * the .sh packer also embeds the .bat packer, so EITHER packer alone
    reproduces the complete rig, including both packers.

Self-hosting: unpack a packer anywhere and run `python3 gen_rig.py` in the
unpacked folder -- it regenerates both packers byte-for-byte (as long as no
source file changed in between).

Usage:  python3 gen_rig.py     (from the rig root, next to local-search/)
"""
import base64
import os
import zlib

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "local-search")

# Rig scripts (live at the rig root, next to this file).
RIG_FILES = [
    "gen_installers.py",
    "gen_rig.py",
    "extract-embedded.py",
    "test_b64.py",
    "test_heredocs.py",
    "test_rig.py",
    "e2e_test.sh",
    "zip_test.sh",
    "selfhost_test.sh",
    "build.sh",
    "build.bat",
    "BUILD.md",
]

# local-search source files (the product; installers are generated, not listed).
SOURCE_FILES = [
    "config/searxng/settings.yml",
    "docker-compose.yml",
    ".env.example",
    "README.md",
    "LICENSE",
    ".gitignore",
    ".gitattributes",
    "Run.bat",
    "Stop.bat",
    "Update.bat",
    "Uninstall.bat",
    "run.sh",
    "stop.sh",
    "update.sh",
    "uninstall.sh",
    "local-web/SKILL.md",
    "local-web/LICENSE",
    "local-web/scripts/config.py",
    "local-web/scripts/ensure_stack.py",
    "local-web/scripts/web_search.py",
    "local-web/scripts/web_scrape.py",
]

N_FILES = len(SOURCE_FILES) + len(RIG_FILES)


def read_root(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read()


def read_src(rel):
    with open(os.path.join(SRC, rel), "rb") as f:
        return f.read()


def b64_chunked(data, width=76):
    s = base64.b64encode(data).decode("ascii")
    return [s[i:i + width] for i in range(0, len(s), width)]


def tag_for(rel):
    return "EOF_" + "".join(c if c.isalnum() else "_" for c in rel).upper()


# =============================================================================
#  Windows packer (.bat)
# =============================================================================

def gen_bat_packer():
    out = []
    ap = out.append

    ap('@echo off')
    ap('setlocal enableDelayedExpansion')
    ap('chcp 65001 >nul')
    ap('title Local Search Dev Rig - Unpack')
    ap('')
    ap('REM ===========================================================================')
    ap('REM  Local Search DEV RIG packer  -  Windows')
    ap('REM ===========================================================================')
    ap('REM  Self-contained: embeds the complete build/test environment for the')
    ap('REM  local-search installers:')
    ap('REM    * the local-search source tree (%d files)' % len(SOURCE_FILES))
    ap('REM    * gen_installers.py / gen_rig.py (the two generators)')
    ap('REM    * every test + build script + BUILD.md')
    ap('REM  Unpack anywhere, then run build.bat (or: python gen_installers.py) to')
    ap('REM  regenerate the installers, and: python gen_rig.py to regenerate these')
    ap('REM  packers byte-for-byte.')
    ap('REM ===========================================================================')
    ap('')
    ap('echo ============================================================')
    ap('echo   Local Search DEV RIG  (build + test environment)')
    ap('echo   Unpacks everything needed to regenerate and verify the')
    ap('echo   install-local-search installers.')
    ap('echo ============================================================')
    ap('echo.')
    ap('')
    # Prompts
    ap('set "DEFAULT_TARGET=%~dp0local-search-dev"')
    ap('')
    ap('echo --- Step 1 of 3: Unpack location ---------------------------')
    ap('echo   Default: %DEFAULT_TARGET%')
    ap('set "TARGET="')
    ap('set /p TARGET="  Target folder [press Enter for default]: "')
    ap('if "!TARGET!"=="" set "TARGET=%DEFAULT_TARGET%"')
    ap('set "TARGET=!TARGET:"=!"')
    ap('for %%I in ("!TARGET!") do set "TARGET=%%~fI"')
    ap('echo   Using: !TARGET!')
    ap('echo   ^(existing files in the target folder are overwritten^)')
    ap('echo.')
    ap('')
    ap('echo --- Step 2 of 3: Build now? --------------------------------')
    ap('echo   Generate install-local-search.bat/.sh with Python right after unpacking?')
    ap('set "BUILDNOW="')
    ap('set /p BUILDNOW="  Run the installer build now? [Y/n]: "')
    ap('echo.')
    ap('')
    ap('echo --- Step 3 of 3: Confirm -----------------------------------')
    ap('echo   Will unpack %d files into: !TARGET!' % N_FILES)
    ap('set "CONFIRM="')
    ap('set /p CONFIRM="Proceed? [Y/n]: "')
    ap('if /i "!CONFIRM!"=="n" ( echo Cancelled. & pause & exit /b 0 )')
    ap('')
    # Folders
    ap('if not exist "!TARGET!" mkdir "!TARGET!"')
    ap('if not exist "!TARGET!\\local-search" mkdir "!TARGET!\\local-search"')
    ap('if not exist "!TARGET!\\local-search\\config\\searxng" mkdir "!TARGET!\\local-search\\config\\searxng"')
    ap('if not exist "!TARGET!\\local-search\\local-web\\scripts" mkdir "!TARGET!\\local-search\\local-web\\scripts"')
    ap('')
    ap('echo Unpacking files...')

    def b64_block(label, data, out_win):
        lines = b64_chunked(data)
        tag = "LSR" + str(zlib.crc32(label.encode("utf-8")) & 0xFFFFFFFF)
        ap('')
        ap('REM --- ' + label + ' ---')
        ap('set "B64TMP=%TEMP%\\' + tag + '.b64"')
        first = True
        for ln in lines:
            ap(('> ' if first else '>> ') + '"!B64TMP!" echo ' + ln)
            first = False
        ap('set "LS_B64_IN=!B64TMP!"')
        ap('set "LS_B64_OUT=' + out_win + '"')
        ap('call :decode_b64')
        ap('del /Q "!B64TMP!" >nul 2>&1')

    # local-search sources
    for rel in SOURCE_FILES:
        label = "local-search/" + rel
        b64_block(label, read_src(rel), '!TARGET!\\local-search\\' + rel.replace("/", "\\"))
    # rig files
    for rel in RIG_FILES:
        b64_block(rel, read_root(rel), '!TARGET!\\' + rel.replace("/", "\\"))

    ap('')
    ap('REM Keep a copy of this packer in the target so the rig is complete.')
    ap('copy /Y "%~f0" "!TARGET!\\local-search-rig.bat" >nul 2>&1')
    ap('echo   Done - %d files + this packer.' % N_FILES)
    ap('')
    # Optional build
    ap('if /i not "!BUILDNOW!"=="n" (')
    ap('  set "PY="')
    ap('  py -3 -c "print(1)" >nul 2>&1')
    ap('  if not errorlevel 1 set "PY=py -3"')
    ap('  if not defined PY (')
    ap('    python -c "print(1)" >nul 2>&1')
    ap('    if not errorlevel 1 set "PY=python"')
    ap('  )')
    ap('  if not defined PY (')
    ap('    python3 -c "print(1)" >nul 2>&1')
    ap('    if not errorlevel 1 set "PY=python3"')
    ap('  )')
    ap('  if not defined PY (')
    ap('    echo.')
    ap('    echo   [WARNING] Python not found - skipping the build.')
    ap('    echo   Install Python 3.8+, then run build.bat in the target folder.')
    ap('  ) else (')
    ap('    echo.')
    ap('    echo Building installers with !PY! ...')
    ap('    pushd "!TARGET!"')
    ap('    !PY! gen_installers.py')
    ap('    if errorlevel 1 (')
    ap('      popd')
    ap('      echo   [ERROR] gen_installers.py failed.')
    ap('      pause')
    ap('      exit /b 1')
    ap('    )')
    ap('    popd')
    ap('    echo   Installers written to !TARGET!\\local-search\\')
    ap('  )')
    ap(')')
    ap('')
    # Done
    ap('echo.')
    ap('echo ============================================================')
    ap('echo   Dev rig ready: !TARGET!')
    ap('echo.')
    ap('echo   Next steps ^(see BUILD.md inside^):')
    ap('echo     build.bat                     rebuild installers + packers + tests')
    ap('echo     python gen_installers.py      rebuild just the installers')
    ap('echo     python gen_rig.py             rebuild these packers')
    ap('echo ============================================================')
    ap('echo.')
    ap('pause')
    ap('exit /b 0')
    ap('')
    ap(':decode_b64')
    ap('REM  %env:LS_B64_IN% = .b64 temp file, %env:LS_B64_OUT% = output path')
    ap('powershell -NoProfile -Command "$in=$env:LS_B64_IN; $out=$env:LS_B64_OUT; [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String(((Get-Content -Raw $in) -replace \'\\s\',\'\')))"')
    ap('exit /b 0')

    return "\r\n".join(out) + "\r\n"


# =============================================================================
#  Linux / macOS packer (.sh)
# =============================================================================

def gen_sh_packer():
    out = []
    ap = out.append

    ap('#!/usr/bin/env bash')
    ap('# =============================================================================')
    ap('#  Local Search DEV RIG packer  -  Linux / macOS / Git Bash')
    ap('# =============================================================================')
    ap('#  Self-contained: embeds the complete build/test environment for the')
    ap('#  local-search installers:')
    ap('#    * the local-search source tree (%d files)' % len(SOURCE_FILES))
    ap('#    * gen_installers.py / gen_rig.py (the two generators)')
    ap('#    * every test + build script + BUILD.md')
    ap('#    * the Windows packer (local-search-rig.bat)')
    ap('#  So this ONE file reproduces the whole rig anywhere, including both')
    ap('#  packers. The installers themselves are generated after unpacking')
    ap('#  (this script offers to do it) with gen_installers.py.')
    ap('# =============================================================================')
    ap('')
    ap('set -u')
    ap('')
    ap('BOLD="\\033[1m"; GREEN="\\033[32m"; YELLOW="\\033[33m"; RED="\\033[31m"; CYAN="\\033[36m"; RESET="\\033[0m"')
    ap('say()  { printf "%b\\n" "$1"; }')
    ap('err()  { printf "%b[ERROR]%b %s\\n" "$RED" "$RESET" "$1" >&2; }')
    ap('ok()   { printf "%b[OK]%b %s\\n" "$GREEN" "$RESET" "$1"; }')
    ap('hdr()  { printf "\\n%b--- %s ---%b\\n" "$CYAN" "$1" "$RESET"; }')
    ap('lower() { printf \'%s\' "$1" | tr \'[:upper:]\' \'[:lower:]\'; }  # bash-3.2 (macOS) safe')
    ap('')
    ap('cat <<\'BANNER\'')
    ap('============================================================')
    ap('  Local Search DEV RIG  (build + test environment)')
    ap('  Unpacks everything needed to regenerate and verify the')
    ap('  install-local-search installers.')
    ap('============================================================')
    ap('BANNER')
    ap('')
    ap('SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"')
    ap('DEFAULT_TARGET="$SCRIPT_DIR/local-search-dev"')
    ap('')
    ap('hdr "Step 1 of 3: Unpack location"')
    ap('say "  Default: $DEFAULT_TARGET"')
    ap('printf "  Target folder [press Enter for default]: "')
    ap('read -r TARGET')
    ap('[ -z "$TARGET" ] && TARGET="$DEFAULT_TARGET"')
    ap('if [ "${TARGET#\\~}" != "$TARGET" ]; then TARGET="$HOME${TARGET#\\~}"; fi  # POSIX tilde expansion')
    ap('mkdir -p "$TARGET"')
    ap('TARGET="$(cd "$TARGET" && pwd)"')
    ap('say "  Using: $TARGET"')
    ap('say "  (existing files in the target folder are overwritten)"')
    ap('')
    ap('hdr "Step 2 of 3: Build now?"')
    ap('say "  Generate install-local-search.bat/.sh with Python right after unpacking?"')
    ap('printf "  Run the installer build now? [Y/n]: "')
    ap('read -r BUILDNOW')
    ap('')
    ap('hdr "Step 3 of 3: Confirm"')
    ap('say "  Will unpack %d files into: $TARGET"' % N_FILES)
    ap('printf "Proceed? [Y/n]: "')
    ap('read -r CONFIRM')
    ap('if [ "$(lower "$CONFIRM")" = "n" ]; then say "Cancelled."; exit 0; fi')
    ap('')
    ap('mkdir -p "$TARGET/local-search/config/searxng" "$TARGET/local-search/local-web/scripts"')
    ap('')
    ap('say "Unpacking files..."')

    def heredoc_block(rel_path, data):
        text = data.decode("utf-8")
        # LF-normalise the heredoc body; the awk loop below restores CRLF for
        # every .bat file after unpacking.
        text_lf = text.replace("\r\n", "\n").replace("\r", "\n")
        tag = tag_for(rel_path)
        ap('')
        ap('# --- ' + rel_path + ' ---')
        ap('cat > "$TARGET/' + rel_path + '" <<\'' + tag + '\'')
        for line in text_lf.splitlines():
            ap(line)
        ap(tag)

    # local-search sources
    for rel in SOURCE_FILES:
        heredoc_block("local-search/" + rel, read_src(rel))
    # rig files
    for rel in RIG_FILES:
        heredoc_block(rel, read_root(rel))
    # the Windows packer, so this one file reproduces the whole rig
    heredoc_block("local-search-rig.bat", read_root("local-search-rig.bat"))

    ap('')
    ap('# Keep a copy of this packer in the target so the rig is complete.')
    ap('cp -f "$0" "$TARGET/local-search-rig.sh"')
    ap('chmod +x "$TARGET"/*.sh "$TARGET"/local-search/*.sh 2>/dev/null || true')
    ap('')
    ap('# Restore CRLF line endings for every .bat file (the heredocs above')
    ap('# wrote LF; awk is used instead of sed so this also works on macOS).')
    ap('find "$TARGET" -type f -name \'*.bat\' 2>/dev/null | while IFS= read -r f; do')
    ap('  awk \'{sub(/\\r$/,""); printf "%s\\r\\n", $0}\' "$f" > "$f.crlf" 2>/dev/null \\')
    ap('    && mv "$f.crlf" "$f" || rm -f "$f.crlf"')
    ap('done')
    ap('')
    ap('ok "Unpacked the dev rig into: $TARGET"')
    ap('')
    # Optional build
    ap('if [ "$(lower "${BUILDNOW:-y}")" != "n" ]; then')
    ap('  PY="$(command -v python3 || command -v python)"')
    ap('  if [ -n "$PY" ]; then')
    ap('    say "Building installers with $PY ..."')
    ap('    if (cd "$TARGET" && "$PY" gen_installers.py); then')
    ap('      say "  Installers written to $TARGET/local-search/"')
    ap('    else')
    ap('      err "gen_installers.py failed - see output above."')
    ap('    fi')
    ap('  else')
    ap('    say "  ${YELLOW}[WARNING]${RESET} Python not found - skipping the build."')
    ap('    say "  Install Python 3.8+, then run ./build.sh in the target folder."')
    ap('  fi')
    ap('fi')
    ap('')
    # Done
    ap('echo')
    ap('say "${GREEN}============================================================${RESET}"')
    ap('say "${GREEN}  Dev rig ready: $TARGET${RESET}"')
    ap('echo')
    ap('say "  Next steps (see BUILD.md inside):"')
    ap('say "    ./build.sh                    rebuild installers + packers + tests"')
    ap('say "    python3 gen_installers.py     rebuild just the installers"')
    ap('say "    python3 gen_rig.py            rebuild these packers"')
    ap('say "${GREEN}============================================================${RESET}"')

    return "\n".join(out) + "\n"


def main():
    # Write the .bat packer FIRST: the .sh packer embeds it, so it must read
    # the freshly-written file (not a stale previous-generation copy).
    bat = gen_bat_packer()
    with open(os.path.join(ROOT, "local-search-rig.bat"), "wb") as f:
        f.write(bat.encode("utf-8"))
    sh = gen_sh_packer()
    with open(os.path.join(ROOT, "local-search-rig.sh"), "wb") as f:
        f.write(sh.encode("utf-8"))
    os.chmod(os.path.join(ROOT, "local-search-rig.sh"), 0o755)
    print("Wrote local-search-rig.bat (%d bytes)" % len(bat))
    print("Wrote local-search-rig.sh  (%d bytes)" % len(sh))


if __name__ == "__main__":
    main()
EOF_GEN_RIG_PY

# --- extract-embedded.py ---
cat > "$TARGET/extract-embedded.py" <<'EOF_EXTRACT_EMBEDDED_PY'
#!/usr/bin/env python3
"""Extract the files embedded in a local-search .sh installer or rig packer.

Works on:
    install-local-search.sh    -> extracts the 21 local-search/ source files
                                  (+ install-local-search.bat)
    local-search-rig.sh        -> extracts the COMPLETE dev rig
                                  (local-search/ sources + all rig scripts +
                                  local-search-rig.bat)

No Docker, no execution of the embedded scripts: this just parses the quoted
heredocs (`cat > "$TARGET/<file>" <<'TAG'`) and writes their content to disk.
Line endings are restored (CRLF for .bat files), so the extracted tree is
byte-identical to the sources the packer/generator originally embedded.

Usage:
    python3 extract-embedded.py <install-local-search.sh | local-search-rig.sh> [outdir]

Result:
    outdir/ contains the extracted tree. For the installer, outdir IS the
    local-search folder content; for the rig packer, outdir IS the rig root
    (local-search/ plus the rig scripts). The .sh file you extracted from is
    not itself embedded -- copy it over manually if you want it included.
"""
import argparse
import os
import re
import sys

_HEREDOC = re.compile(r'''^\s*cat > "\$TARGET/(.+?)" <<'([A-Z0-9_]+)'$''')


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Extract files embedded in a local-search .sh installer/packer.")
    ap.add_argument("source", help="install-local-search.sh or local-search-rig.sh")
    ap.add_argument("outdir", nargs="?", default="extracted",
                    help="output directory (default: ./extracted)")
    args = ap.parse_args()

    try:
        with open(args.source, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as e:
        print("cannot read %s: %s" % (args.source, e), file=sys.stderr)
        return 2

    count = 0
    i = 0
    while i < len(lines):
        m = _HEREDOC.match(lines[i])
        if not m:
            i += 1
            continue
        rel, tag = m.group(1), m.group(2)
        j = i + 1
        body = []
        while j < len(lines) and lines[j] != tag:
            body.append(lines[j])
            j += 1
        if j >= len(lines):
            print("unterminated heredoc for %s" % rel, file=sys.stderr)
            return 1
        content = "\n".join(body) + ("\n" if body else "")
        out = os.path.join(args.outdir, *rel.split("/"))
        parent = os.path.dirname(out)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)
        if rel.endswith(".bat"):
            # restore CRLF (the heredoc body was LF-normalised at pack time)
            with open(out, "rb") as fh:
                data = fh.read()
            with open(out, "wb") as fh:
                fh.write(data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
        print("  extracted %s" % rel)
        count += 1
        i = j + 1

    if count == 0:
        print("no embedded heredocs found in %s "
              "(is it really a local-search .sh artifact?)" % args.source,
              file=sys.stderr)
        return 1
    print("%d files extracted to %s/" % (count, args.outdir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_EXTRACT_EMBEDDED_PY

# --- test_b64.py ---
cat > "$TARGET/test_b64.py" <<'EOF_TEST_B64_PY'
#!/usr/bin/env python3
"""Simulate the .bat decode_b64 logic for every embedded file and verify
the round-trip matches the original source files."""
import base64
import re
import os

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "local-search")
BAT = os.path.join(SRC, "install-local-search.bat")
SH  = os.path.join(SRC, "install-local-search.sh")

FILES = [
    "config/searxng/settings.yml",
    "docker-compose.yml",
    ".env.example",
    "README.md",
    "LICENSE",
    ".gitignore",
    ".gitattributes",
    "Run.bat", "Stop.bat", "Update.bat", "Uninstall.bat",
    "run.sh", "stop.sh", "update.sh", "uninstall.sh",
    "local-web/SKILL.md",
    "local-web/LICENSE",
    "local-web/scripts/config.py",
    "local-web/scripts/ensure_stack.py",
    "local-web/scripts/web_search.py",
    "local-web/scripts/web_scrape.py",
]

def read(rel):
    with open(os.path.join(SRC, rel), "rb") as f:
        return f.read()

# ---- extract base64 blocks from the .bat ----
bat_text = open(BAT, "r", encoding="utf-8").read()
# A block looks like:
#   REM --- <rel> ---
#   set "NEED_B64=1"
#   ...
#   set "B64TMP=%TEMP%\LSxxxxxx.b64"
#   > "!B64TMP!" echo LINE1
#   >> "!B64TMP!" echo LINE2
#   ...
#   set "LS_B64_IN=..."
blocks = {}
cur_rel = None
cur_lines = []
for line in bat_text.split("\n"):
    m = re.match(r'REM --- (.+?) ---$', line)
    if m:
        if cur_rel:
            blocks[cur_rel] = cur_lines
        cur_rel = m.group(1)
        cur_lines = []
        continue
    m2 = re.match(r'\s*>>?\s*"!B64TMP!"\s+echo\s+(.+)$', line)
    if m2 and cur_rel:
        cur_lines.append(m2.group(1))
if cur_rel:
    blocks[cur_rel] = cur_lines

print("Found %d embedded base64 blocks in .bat" % len(blocks))
ok = True
for rel in FILES:
    orig = read(rel)
    if rel not in blocks:
        print("  [MISS] %-32s : no base64 block in .bat" % rel)
        ok = False
        continue
    # concatenate and strip whitespace (mirrors PS -replace '\s','')
    joined = "".join(blocks[rel])
    try:
        dec = base64.b64decode(joined)
    except Exception as e:
        print("  [FAIL] %-32s : b64 decode error: %s" % (rel, e))
        ok = False
        continue
    if dec == orig:
        print("  [OK]   %-32s : %d bytes round-trip OK" % (rel, len(orig)))
    else:
        print("  [FAIL] %-32s : decoded %d bytes != original %d bytes" % (rel, len(dec), len(orig)))
        ok = False

print()
print("ALL GOOD" if ok else "FAILURES PRESENT")
EOF_TEST_B64_PY

# --- test_heredocs.py ---
cat > "$TARGET/test_heredocs.py" <<'EOF_TEST_HEREDOCS_PY'
#!/usr/bin/env python3
"""Extract every quoted heredoc from the .sh installer and verify the
content matches the original source files byte-for-byte."""
import os
import re

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "local-search")
SH  = os.path.join(SRC, "install-local-search.sh")
text = open(SH, "r", encoding="utf-8").read()

FILES = [
    "config/searxng/settings.yml", "docker-compose.yml", ".env.example",
    "README.md", "LICENSE", ".gitignore", ".gitattributes",
    "Run.bat", "Stop.bat", "Update.bat", "Uninstall.bat",
    "run.sh", "stop.sh", "update.sh", "uninstall.sh",
    "local-web/SKILL.md", "local-web/LICENSE",
    "local-web/scripts/config.py", "local-web/scripts/ensure_stack.py",
    "local-web/scripts/web_search.py", "local-web/scripts/web_scrape.py",
    "install-local-search.bat",
]

def read(rel):
    with open(os.path.join(SRC, rel), "rb") as f:
        return f.read()

# Find blocks of the form:
#   cat > "$TARGET/<rel>" <<'<TAG>'
#   <body>
#   <TAG>
heredocs = {}
lines = text.split("\n")
i = 0
while i < len(lines):
    m = re.match(r"\s*cat > \"\$TARGET/(.+?)\" <<'([A-Z0-9_]+)'$", lines[i])
    if m:
        rel, tag = m.group(1), m.group(2)
        body_start = i + 1
        # find closing tag
        j = body_start
        while j < len(lines) and lines[j] != tag:
            j += 1
        body = "\n".join(lines[body_start:j])
        # every heredoc line (including the last) is written with a trailing
        # newline by the shell, so append it back after the join.
        if body_start <= j:
            body += "\n"
        heredocs[rel] = body
        i = j + 1
    else:
        i += 1

print("Found %d heredocs in .sh" % len(heredocs))
ok = True
for rel in FILES:
    orig = read(rel).decode("utf-8")
    if rel not in heredocs:
        print("  [MISS] %-32s" % rel)
        ok = False
        continue
    # Compare content ignoring line-ending differences: the .sh installer
    # writes .bat files via heredoc (LF) and then a runtime CRLF-conversion
    # loop converts them to CRLF. So the heredoc body has LF where the
    # original .bat has CRLF -- this is expected and correct.
    a = heredocs[rel].replace("\r\n", "\n")
    b = orig.replace("\r\n", "\n")
    if a == b:
        print("  [OK]   %-32s : %d bytes (content matches; CRLF fixed at runtime)" % (rel, len(orig)))
    else:
        print("  [FAIL] %-32s : heredoc %d vs orig %d (LF-normalised)" % (rel, len(a), len(b)))
        for k in range(min(len(a), len(b))):
            if a[k] != b[k]:
                print("    first diff at byte %d: heredoc=%r orig=%r" % (k, a[k:k+30], b[k:k+30]))
                break
        ok = False

print()
print("ALL GOOD" if ok else "FAILURES")
EOF_TEST_HEREDOCS_PY

# --- test_rig.py ---
cat > "$TARGET/test_rig.py" <<'EOF_TEST_RIG_PY'
#!/usr/bin/env python3
"""Verify both rig packers (local-search-rig.bat / local-search-rig.sh) embed
the CURRENT files exactly. Run from the rig root after gen_rig.py.

  * local-search-rig.bat : every `REM --- <file> ---` base64 block must
    decode to the exact bytes of the file on disk.
  * local-search-rig.sh  : every `cat > "$TARGET/<file>" <<'TAG'` heredoc
    must match the file on disk (LF-normalised; CRLF is restored for .bat
    files by the packer's awk loop at unpack time).
"""
import base64
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
from gen_rig import RIG_FILES, SOURCE_FILES  # noqa: E402

BAT = os.path.join(ROOT, "local-search-rig.bat")
SH = os.path.join(ROOT, "local-search-rig.sh")

failures = []


def disk_bytes(rel):
    with open(os.path.join(ROOT, *rel.split("/")), "rb") as f:
        return f.read()


# ---- 1. base64 blocks in the .bat packer -----------------------------------
bat_text = open(BAT, encoding="utf-8").read()
blocks = {}
cur, cur_lines = None, []
for line in bat_text.split("\n"):
    m = re.match(r"REM --- (.+?) ---$", line)
    if m:
        if cur is not None:
            blocks[cur] = cur_lines
        cur, cur_lines = m.group(1), []
        continue
    m2 = re.match(r'\s*>>?\s*"!B64TMP!"\s+echo\s+(.+)$', line)
    if m2 and cur is not None:
        cur_lines.append(m2.group(1))
if cur is not None:
    blocks[cur] = cur_lines

expected = ["local-search/" + s for s in SOURCE_FILES] + RIG_FILES
print("local-search-rig.bat: %d embedded base64 blocks" % len(blocks))
for label in expected:
    if label not in blocks:
        failures.append("bat missing block: " + label)
        continue
    try:
        dec = base64.b64decode("".join(blocks[label]))
    except Exception as e:
        failures.append("bat bad base64 %s: %s" % (label, e))
        continue
    want = disk_bytes(label)
    if dec == want:
        print("  [OK]   %-46s %d bytes" % (label, len(want)))
    else:
        failures.append("bat mismatch: %s (%d vs %d bytes)" % (label, len(dec), len(want)))

if 'copy /Y "%~f0"' not in bat_text:
    failures.append("bat packer lost its self-copy line")

# ---- 2. heredocs in the .sh packer -----------------------------------------
sh_text = open(SH, encoding="utf-8").read()
lines = sh_text.split("\n")
heredocs = {}
i = 0
while i < len(lines):
    m = re.match(r"\s*cat > \"\$TARGET/(.+?)\" <<'([A-Z0-9_]+)'$", lines[i])
    if m:
        rel, tag = m.group(1), m.group(2)
        j = i + 1
        while j < len(lines) and lines[j] != tag:
            j += 1
        if j >= len(lines):
            failures.append("sh heredoc for %s has no closing tag" % rel)
            i += 1
            continue
        body = "\n".join(lines[i + 1:j])
        if i + 1 <= j:
            body += "\n"
        heredocs[rel] = body
        i = j + 1
    else:
        i += 1

expected_sh = expected + ["local-search-rig.bat"]
print("local-search-rig.sh: %d embedded heredocs" % len(heredocs))
for label in expected_sh:
    if label not in heredocs:
        failures.append("sh missing heredoc: " + label)
        continue
    want = disk_bytes(label).decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    got = heredocs[label]
    if got == want:
        print("  [OK]   %-46s %d bytes" % (label, len(want)))
    else:
        failures.append("sh mismatch: %s (%d vs %d bytes)" % (label, len(got), len(want)))

if 'cp -f "$0" "$TARGET/local-search-rig.sh"' not in sh_text:
    failures.append("sh packer lost its self-copy line")
if 'printf "%s\\r\\n", $0' not in sh_text:
    failures.append("sh packer lost its CRLF-restore awk loop")

print()
if failures:
    for f in failures:
        print("  [FAIL] " + f)
    print("TESTS FAILED")
    sys.exit(1)
print("ALL GOOD")
EOF_TEST_RIG_PY

# --- e2e_test.sh ---
cat > "$TARGET/e2e_test.sh" <<'EOF_E2E_TEST_SH'
#!/usr/bin/env bash
# End-to-end test of install-local-search.sh:
#   * simulates downloading ONLY the installer (nothing else next to it)
#   * mocks docker so the install logic runs fully
#   * verifies the produced install folder, the ~/.agents/skills/local-web
#     skill install, the install-dir.txt hint, and the uninstaller.
#   * SELF-HEAL test: fake SearXNG/Firecrawl HTTP servers + a mock
#     `docker compose up` that starts them, verifying that web_search.py /
#     web_scrape.py auto-start a down stack and retry (and report cleanly
#     when the stack cannot come up).
# Any pre-existing ~/.agents/skills/local-web is backed up and restored.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$ROOT/local-search/install-local-search.sh"
TESTROOT="$ROOT/.ls-test-$$"
SRC_DIR="$TESTROOT/src-only-installer"
TGT_DIR="$TESTROOT/target"
MOCKBIN="$TESTROOT/bin"
SKILL_DIR="$HOME/.agents/skills/local-web"
SKILL_BAK=""

PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
  echo "[ERROR] python3/python is required for this test." >&2
  exit 1
fi

cleanup() {
  rc=$?
  # kill the fake stack server if a self-heal phase left it running
  if [ -f "$TESTROOT/fake_stack.pid" ]; then
    kill "$(cat "$TESTROOT/fake_stack.pid" 2>/dev/null)" 2>/dev/null
    rm -f "$TESTROOT/fake_stack.pid"
  fi
  rm -rf "$SKILL_DIR" 2>/dev/null
  if [ -n "$SKILL_BAK" ] && [ -d "$SKILL_BAK" ]; then
    mv "$SKILL_BAK" "$SKILL_DIR" 2>/dev/null
  fi
  if [ "$rc" = 0 ]; then rm -rf "$TESTROOT"; fi
}
trap cleanup EXIT

mkdir -p "$SRC_DIR" "$TGT_DIR" "$MOCKBIN"

# Back up any real skill install so the test can never destroy it.
if [ -d "$SKILL_DIR" ]; then
  SKILL_BAK="$TESTROOT/skill-backup"
  mv "$SKILL_DIR" "$SKILL_BAK"
fi

# --- mock docker + docker compose so the installer's checks pass -----------
cat > "$MOCKBIN/docker" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  info)        exit 0 ;;
  compose)
    case "$2" in
      version) echo "Docker Compose version v2.0.0-test"; exit 0 ;;
      pull)    echo "[mock] pull ok";   exit 0 ;;
      up)      echo "[mock] up ok";     exit 0 ;;
      down)    echo "[mock] down ok";   exit 0 ;;
      *)       echo "[mock] docker compose $*"; exit 0 ;;
    esac ;;
  *) echo "[mock] docker $*"; exit 0 ;;
esac
MOCK
chmod +x "$MOCKBIN/docker"
export PATH="$MOCKBIN:$PATH"

# --- copy ONLY the installer .sh into the source folder -------------------
cp "$INSTALLER" "$SRC_DIR/"
chmod +x "$SRC_DIR/install-local-search.sh"

echo "Source folder contents (should be ONLY install-local-search.sh):"
ls -la "$SRC_DIR"
echo

# --- run the installer with scripted answers -------------------------------
#   Step 1: target folder, Step 2: searxng port, Step 3: firecrawl port,
#   Step 4: connect LLM? -> n,  confirm -> y
printf '%s\n%s\n%s\n%s\n%s\n' \
  "$TGT_DIR" \
  "" \
  "" \
  "n" \
  "y" | "$SRC_DIR/install-local-search.sh" > "$TESTROOT/install.log" 2>&1
RC=$?
echo "Installer exit code: $RC"
echo "----- install.log (tail) -----"
tail -30 "$TESTROOT/install.log"
echo "--------------------------------"

PASS=1
[ "$RC" = 0 ] || PASS=0

# --- verify the target folder has everything we expect --------------------
echo
echo "Target folder contents:"
ls -la "$TGT_DIR"
echo
echo "Target config/searxng contents:"
ls -la "$TGT_DIR/config/searxng"
echo
echo "Target local-web contents:"
find "$TGT_DIR/local-web" -type f | sort

check() {
  if [ -s "$TGT_DIR/$1" ]; then
    echo "  [OK]   $1  ($(wc -c < "$TGT_DIR/$1") bytes)"
  else
    echo "  [FAIL] $1  (missing or empty)"
    PASS=0
  fi
}
echo
echo "Checking expected files:"
check "docker-compose.yml"
check ".env.example"
check ".env"
check "README.md"
check "LICENSE"
check ".gitignore"
check ".gitattributes"
check "config/searxng/settings.yml"
check "Run.bat"
check "Stop.bat"
check "Update.bat"
check "Uninstall.bat"
check "run.sh"
check "stop.sh"
check "update.sh"
check "uninstall.sh"
check "local-web/SKILL.md"
check "local-web/LICENSE"
check "local-web/scripts/config.py"
check "local-web/scripts/ensure_stack.py"
check "local-web/scripts/web_search.py"
check "local-web/scripts/web_scrape.py"
check "install-local-search.bat"
check "install-local-search.sh"

# verify .env has the chosen ports + a real secret
echo
echo "----- .env contents -----"
cat "$TGT_DIR/.env"
echo "-------------------------"

if grep -q "^SEARXNG_PORT=9990$" "$TGT_DIR/.env" \
   && grep -q "^FIRECRAWL_PORT=9991$" "$TGT_DIR/.env" \
   && grep -q "^SEARXNG_SECRET=[0-9a-f]\{64\}$" "$TGT_DIR/.env"; then
  echo "[OK] .env has correct ports and a 64-hex secret"
else
  echo "[FAIL] .env is malformed"
  PASS=0
fi

# verify the secret got injected into settings.yml (no placeholder left)
if grep -q "__SEARXNG_SECRET_PLACEHOLDER__" "$TGT_DIR/config/searxng/settings.yml"; then
  echo "[FAIL] settings.yml still has the placeholder (injection failed)"
  PASS=0
else
  echo "[OK] settings.yml no longer has the placeholder (secret injected)"
fi

# verify .bat files have CRLF line endings
BAT_HAS_CRLF=1
for f in Run.bat Stop.bat Update.bat Uninstall.bat install-local-search.bat; do
  if ! grep -q $'\r' "$TGT_DIR/$f" 2>/dev/null; then
    echo "[FAIL] $f does not have CRLF line endings"
    BAT_HAS_CRLF=0
  fi
done
[ "$BAT_HAS_CRLF" = 1 ] && echo "[OK] all .bat files have CRLF line endings"

# --- verify the skill was installed into ~/.agents/skills/local-web --------
echo
echo "Skill dir contents ($SKILL_DIR):"
find "$SKILL_DIR" -type f 2>/dev/null | sort

for f in SKILL.md LICENSE scripts/config.py scripts/ensure_stack.py \
         scripts/web_search.py scripts/web_scrape.py; do
  if [ -s "$SKILL_DIR/$f" ]; then
    echo "  [OK]   skill: $f"
  else
    echo "  [FAIL] skill: $f (missing or empty)"
    PASS=0
  fi
done

# verify the skill files are identical to the target's local-web copies
for f in SKILL.md LICENSE scripts/config.py scripts/ensure_stack.py \
         scripts/web_search.py scripts/web_scrape.py; do
  if cmp -s "$SKILL_DIR/$f" "$TGT_DIR/local-web/$f"; then
    echo "  [OK]   skill file matches bundled copy: $f"
  else
    echo "  [FAIL] skill file differs from bundled copy: $f"
    PASS=0
  fi
done

# verify the install-dir.txt hint (both copies) points at the target
if [ "$(cat "$SKILL_DIR/install-dir.txt" 2>/dev/null)" = "$TGT_DIR" ]; then
  echo "  [OK]   skill install-dir.txt -> $TGT_DIR"
else
  echo "  [FAIL] skill install-dir.txt is wrong: $(cat "$SKILL_DIR/install-dir.txt" 2>/dev/null)"
  PASS=0
fi
if [ "$(cat "$TGT_DIR/local-web/install-dir.txt" 2>/dev/null)" = "$TGT_DIR" ]; then
  echo "  [OK]   bundled install-dir.txt -> $TGT_DIR"
else
  echo "  [FAIL] bundled install-dir.txt is wrong: $(cat "$TGT_DIR/local-web/install-dir.txt" 2>/dev/null)"
  PASS=0
fi

# --- verify the hint actually works: run config.py's finder standalone ------
"$PY" - "$TGT_DIR" <<'PYEOF'
import sys, os
expected = sys.argv[1]
# Simulate the skill being run from ~/.agents/skills/local-web/scripts
sys.path.insert(0, os.path.expanduser("~/.agents/skills/local-web/scripts"))
os.environ.pop("LOCAL_SEARCH_DIR", None)
import config
found = config.find_install_dir()
if found == expected:
    print("  [OK]   config.find_install_dir() -> %s (hint works)" % found)
else:
    print("  [FAIL] config.find_install_dir() -> %r (expected %r)" % (found, expected))
    sys.exit(1)
eps = config.endpoints(found)
if eps == {"searxng": "http://localhost:9990", "firecrawl": "http://localhost:9991"}:
    print("  [OK]   endpoints read from .env: %s" % eps)
else:
    print("  [FAIL] endpoints wrong: %s" % eps)
    sys.exit(1)
PYEOF
[ $? = 0 ] || PASS=0

# --- verify web_search.py / web_scrape.py resolve the endpoints -------------
"$PY" - <<'PYEOF'
import sys, os
sys.path.insert(0, os.path.expanduser("~/.agents/skills/local-web/scripts"))
import web_search
if web_search.BASE.endswith(":9990/search"):
    print("  [OK]   web_search.BASE = %s" % web_search.BASE)
else:
    print("  [FAIL] web_search.BASE = %s" % web_search.BASE)
    sys.exit(1)
import web_scrape
if web_scrape.ENDPOINT.endswith(":9991/v1/scrape"):
    print("  [OK]   web_scrape.ENDPOINT = %s" % web_scrape.ENDPOINT)
else:
    print("  [FAIL] web_scrape.ENDPOINT = %s" % web_scrape.ENDPOINT)
    sys.exit(1)
PYEOF
[ $? = 0 ] || PASS=0

# --- self-heal test: scripts auto-start a down stack -----------------------
echo
echo "===== self-heal test: web_search / web_scrape start a down stack ====="

ports_free() {
  "$PY" - <<'PYK'
import socket, sys
for port in (9990, 9991):
    s = socket.socket(); s.settimeout(0.3)
    if s.connect_ex(("127.0.0.1", port)) == 0:
        sys.exit(1)
    s.close()
sys.exit(0)
PYK
}

if ports_free; then
  # fake stack: answers SearXNG JSON on $1 and Firecrawl scrape JSON on $2
  cat > "$TESTROOT/fake_stack.py" <<'FAKE'
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

SEARX_PORT, FC_PORT, PIDFILE = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
with open(PIDFILE, "w") as fh:
    fh.write(str(os.getpid()))

class Searx(BaseHTTPRequestHandler):
    def do_GET(self):
        q = parse_qs(urlparse(self.path).query).get("q", [""])[0]
        body = json.dumps({"results": [{
            "title": "FAKE RESULT for " + q,
            "url": "https://example.com/fake",
            "content": "fake snippet"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

class Fc(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.dumps({"data": {"markdown": "# FAKE MARKDOWN\nhello from fake firecrawl"}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

for handler, port in ((Searx, SEARX_PORT), (Fc, FC_PORT)):
    threading.Thread(target=HTTPServer(("127.0.0.1", port), handler).serve_forever,
                     daemon=True).start()
while True:
    time.sleep(3600)
FAKE

  FAKE_PIDFILE="$TESTROOT/fake_stack.pid"
  kill_fake_stack() {
    if [ -f "$FAKE_PIDFILE" ]; then
      kill "$(cat "$FAKE_PIDFILE" 2>/dev/null)" 2>/dev/null
      rm -f "$FAKE_PIDFILE"
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      ports_free && return 0
      sleep 0.5
    done
    return 1
  }

  # mock docker #2: `compose up -d` reads the ports from ./.env and starts
  # the fake stack (so self-heal actually brings the endpoints up)
  mkdir -p "$TESTROOT/bin2"
  cat > "$TESTROOT/bin2/docker" <<'MOCK2'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  compose)
    case "$2" in
      version) echo "Docker Compose version v2.0.0-test"; exit 0 ;;
      up)
        SEARXNG_PORT=$(grep -E '^SEARXNG_PORT=' .env | cut -d= -f2)
        FIRECRAWL_PORT=$(grep -E '^FIRECRAWL_PORT=' .env | cut -d= -f2)
        nohup "$FAKE_PY" "$FAKE_STACK" "$SEARXNG_PORT" "$FIRECRAWL_PORT" "$FAKE_PIDFILE" >/dev/null 2>&1 &
        echo "[mock] compose up ok (fake stack started)"
        exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
MOCK2
  chmod +x "$TESTROOT/bin2/docker"

  # mock docker #3: `compose up -d` succeeds but starts NOTHING (failure path)
  mkdir -p "$TESTROOT/bin3"
  cat > "$TESTROOT/bin3/docker" <<'MOCK3'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  compose)
    case "$2" in
      version) echo "Docker Compose version v2.0.0-test"; exit 0 ;;
      up) echo "[mock] compose up ok (nothing actually started)"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
MOCK3
  chmod +x "$TESTROOT/bin3/docker"

  HEAL_ENV="FAKE_PY=$PY FAKE_STACK=$TESTROOT/fake_stack.py FAKE_PIDFILE=$FAKE_PIDFILE LOCAL_SEARCH_DIR=$TGT_DIR"

  # Phase A - fast path: stack already up -> straight to results, no boot
  nohup "$PY" "$TESTROOT/fake_stack.py" 9990 9991 "$FAKE_PIDFILE" >/dev/null 2>&1 &
  sleep 1
  if env $HEAL_ENV "$PY" "$SKILL_DIR/scripts/web_search.py" "fast path" \
       > "$TESTROOT/healA.log" 2>&1 \
     && grep -q "FAKE RESULT for fast path" "$TESTROOT/healA.log" \
     && ! grep -q "starting it automatically" "$TESTROOT/healA.log"; then
    echo "  [OK]   fast path: search works with the stack already up (no boot)"
  else
    echo "  [FAIL] fast-path search"; cat "$TESTROOT/healA.log"; PASS=0
  fi

  # Phase B - self-heal: stack down -> boot (mock compose) -> retry -> results
  kill_fake_stack
  if env $HEAL_ENV PATH="$TESTROOT/bin2:$PATH" \
       "$PY" "$SKILL_DIR/scripts/web_search.py" "selfheal search" \
       > "$TESTROOT/healB.log" 2>&1 \
     && grep -q "starting it automatically" "$TESTROOT/healB.log" \
     && grep -q "FAKE RESULT for selfheal search" "$TESTROOT/healB.log"; then
    echo "  [OK]   self-heal: web_search booted the down stack and retried"
  else
    echo "  [FAIL] web_search self-heal"; cat "$TESTROOT/healB.log"; PASS=0
  fi

  # Phase B2 - self-heal for the scraper
  kill_fake_stack
  if env $HEAL_ENV PATH="$TESTROOT/bin2:$PATH" \
       "$PY" "$SKILL_DIR/scripts/web_scrape.py" "https://example.com/article" \
       > "$TESTROOT/healB2.log" 2>&1 \
     && grep -q "starting it automatically" "$TESTROOT/healB2.log" \
     && grep -q "FAKE MARKDOWN" "$TESTROOT/healB2.log"; then
    echo "  [OK]   self-heal: web_scrape booted the down stack and retried"
  else
    echo "  [FAIL] web_scrape self-heal"; cat "$TESTROOT/healB2.log"; PASS=0
  fi

  # Phase C - failure: stack cannot come up -> clear guidance, exit 1
  kill_fake_stack
  if env $HEAL_ENV PATH="$TESTROOT/bin3:$PATH" LOCAL_SEARCH_READY_TIMEOUT=2 \
       "$PY" "$SKILL_DIR/scripts/web_search.py" "doomed" \
       > "$TESTROOT/healC.log" 2>&1; then
    echo "  [FAIL] self-heal failure path should exit non-zero"; PASS=0
  elif grep -q "could not be started" "$TESTROOT/healC.log" \
       && grep -q "did not become ready" "$TESTROOT/healC.log"; then
    echo "  [OK]   self-heal failure: clear guidance, non-zero exit"
  else
    echo "  [FAIL] self-heal failure message missing"; cat "$TESTROOT/healC.log"; PASS=0
  fi
  kill_fake_stack
else
  echo "  [WARN] ports 9990/9991 are in use - skipping the self-heal test"
fi

# --- now run the uninstaller (keep folder) and verify the skill is removed --
echo
echo "===== running uninstaller (answering y, then n for folder delete) ====="
printf 'y\nn\n' | "$TGT_DIR/uninstall.sh" > "$TESTROOT/uninstall.log" 2>&1
URC=$?
echo "Uninstaller exit code: $URC"
tail -12 "$TESTROOT/uninstall.log"
echo "--------------------------------"
if [ ! -d "$SKILL_DIR" ]; then
  echo "[OK] uninstaller removed the skill dir"
else
  echo "[FAIL] skill dir still exists after uninstall"
  PASS=0
fi
if [ -f "$TGT_DIR/.env" ] && [ -d "$TGT_DIR/local-web" ]; then
  echo "[OK] uninstaller kept the install folder (as answered)"
else
  echo "[FAIL] uninstaller deleted the install folder despite 'n'"
  PASS=0
fi

echo
if [ "$PASS" = 1 ]; then
  echo "========================  ALL TESTS PASSED  ========================"
  exit 0
fi
echo "========================  TESTS FAILED  ==========================="
exit 1
EOF_E2E_TEST_SH

# --- zip_test.sh ---
cat > "$TARGET/zip_test.sh" <<'EOF_ZIP_TEST_SH'
#!/usr/bin/env bash
# Verify local-search.zip: extract it into a clean temp dir, run the .sh
# installer FROM the extracted folder (all sources present), and check the
# result (incl. the local-web skill). Needs: unzip + python3.
# Any pre-existing ~/.agents/skills/local-web is backed up and restored.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
ZIP="$ROOT/local-search.zip"
TESTROOT="$ROOT/.zip-test-$$"
SKILL_DIR="$HOME/.agents/skills/local-web"
SKILL_BAK=""

PY="$(command -v python3 || command -v python)"
[ -z "$PY" ] && { echo "[ERROR] python required for this test." >&2; exit 1; }

cleanup() {
  rc=$?
  rm -rf "$SKILL_DIR" 2>/dev/null
  if [ -n "$SKILL_BAK" ] && [ -d "$SKILL_BAK" ]; then
    mv "$SKILL_BAK" "$SKILL_DIR" 2>/dev/null
  fi
  if [ "$rc" = 0 ]; then rm -rf "$TESTROOT"; fi
}
trap cleanup EXIT

[ -f "$ZIP" ] || { echo "[ERROR] $ZIP not found - run build.sh first." >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "[ERROR] unzip not found." >&2; exit 1; }

mkdir -p "$TESTROOT"
cd "$TESTROOT"
unzip -q "$ZIP"
echo "Extracted zip contents:"
find local-search -type f | sort
echo

# Back up any real skill install so the test can never destroy it.
if [ -d "$SKILL_DIR" ]; then
  SKILL_BAK="$TESTROOT/skill-backup"
  mv "$SKILL_DIR" "$SKILL_BAK"
fi

# --- mock docker so the installer's checks pass ----------------------------
MOCKBIN="$TESTROOT/bin"
mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/docker" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  info)  exit 0 ;;
  compose)
    case "$2" in
      version) echo "Docker Compose v2.0.0-test"; exit 0 ;;
      pull|up) echo "[mock] ok"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$MOCKBIN/docker"
export PATH="$MOCKBIN:$PATH"

# --- run the installer from the extracted folder (full source present) ------
TGT="$TESTROOT/installed"
printf '%s\n%s\n%s\n%s\n%s\n' "$TGT" "" "" "n" "y" \
  | "$TESTROOT/local-search/install-local-search.sh" > "$TESTROOT/install.log" 2>&1
RC=$?
echo "Installer exit code: $RC"
tail -10 "$TESTROOT/install.log"
echo "=========================================="

# --- verify the install folder ----------------------------------------------
PASS=1
for f in docker-compose.yml .env.example .env README.md LICENSE .gitignore .gitattributes \
         config/searxng/settings.yml \
         Run.bat Stop.bat Update.bat Uninstall.bat \
         run.sh stop.sh update.sh uninstall.sh \
         local-web/SKILL.md local-web/LICENSE \
         local-web/scripts/config.py local-web/scripts/ensure_stack.py \
         local-web/scripts/web_search.py local-web/scripts/web_scrape.py \
         install-local-search.bat install-local-search.sh; do
  if [ -s "$TGT/$f" ]; then
    echo "  [OK] $f"
  else
    echo "  [FAIL] $f (missing/empty)"; PASS=0
  fi
done

if grep -q '__SEARXNG_SECRET_PLACEHOLDER__' "$TGT/config/searxng/settings.yml"; then
  echo "[FAIL] settings.yml still has placeholder"; PASS=0
else
  echo "[OK] settings.yml secret injected"
fi

if [ "$(cat "$SKILL_DIR/install-dir.txt" 2>/dev/null)" = "$TGT" ]; then
  echo "[OK] skill installed with correct install-dir.txt hint"
else
  echo "[FAIL] skill install-dir.txt wrong: $(cat "$SKILL_DIR/install-dir.txt" 2>/dev/null)"
  PASS=0
fi

cmp -s "$TGT/install-local-search.bat" "$ROOT/local-search/install-local-search.bat" \
  && echo "[OK] .bat reproduced byte-identical" \
  || { echo "[FAIL] .bat differs"; PASS=0; }

echo
if [ "$PASS" = 1 ] && [ "$RC" = 0 ]; then
  echo "======== FULL-ZIP EXTRACTION TEST: PASSED ========"
  exit 0
fi
echo "======== FULL-ZIP EXTRACTION TEST: FAILED ========"
exit 1
EOF_ZIP_TEST_SH

# --- selfhost_test.sh ---
cat > "$TARGET/selfhost_test.sh" <<'EOF_SELFHOST_TEST_SH'
#!/usr/bin/env bash
# Self-hosting test for the rig packers:
#   1. Run local-search-rig.sh into a clean folder (only the packer present).
#   2. Verify the unpacked rig is complete and byte-identical to the source.
#   3. Regenerate the packers inside the unpacked rig (python3 gen_rig.py)
#      and compare them BYTE-FOR-BYTE with the originals.
#   4. Regenerate the installers too and compare.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTROOT="$ROOT/.rig-test-$$"
mkdir -p "$TESTROOT"

cleanup() { rc=$?; if [ "$rc" = 0 ]; then rm -rf "$TESTROOT"; else echo "(kept $TESTROOT for debugging)"; fi; }
trap cleanup EXIT

echo "=== 1. unpack local-search-rig.sh (only the packer file present) ==="
mkdir -p "$TESTROOT/src"
cp "$ROOT/local-search-rig.sh" "$TESTROOT/src/"
chmod +x "$TESTROOT/src/local-search-rig.sh"
# answers: target folder, build now? -> n (we build manually later), proceed -> y
printf '%s\n%s\n%s\n' "$TESTROOT/rig" "n" "y" \
  | "$TESTROOT/src/local-search-rig.sh" > "$TESTROOT/unpack.log" 2>&1
RC=$?
echo "packer exit code: $RC"
tail -8 "$TESTROOT/unpack.log"
[ "$RC" = 0 ] || exit 1
echo

echo "=== 2. unpacked rig contents ==="
find "$TESTROOT/rig" -type f | sort
echo

PASS=1
echo "=== 3. byte-compare unpacked rig vs source rig ==="

check_file() {
  if [ ! -f "$TESTROOT/rig/$1" ]; then
    echo "  [FAIL] missing in unpacked rig: $1"; PASS=0; return
  fi
  if cmp -s "$ROOT/$1" "$TESTROOT/rig/$1"; then
    echo "  [OK]   $1"
  else
    # .bat files are allowed CRLF<->LF differences only if LF-normalised equal
    a=$(tr -d '\r' < "$ROOT/$1" | md5sum | cut -d' ' -f1)
    b=$(tr -d '\r' < "$TESTROOT/rig/$1" | md5sum | cut -d' ' -f1)
    if [ "$a" = "$b" ] && [ "$(md5sum < "$ROOT/$1" | cut -d' ' -f1)" != "$a" ]; then
      echo "  [OK]   $1  (CRLF restored)"
    else
      echo "  [FAIL] $1 differs"; PASS=0
    fi
  fi
}

for f in config/searxng/settings.yml docker-compose.yml .env.example README.md \
         LICENSE .gitignore .gitattributes \
         Run.bat Stop.bat Update.bat Uninstall.bat \
         run.sh stop.sh update.sh uninstall.sh \
         local-web/SKILL.md local-web/LICENSE \
         local-web/scripts/config.py local-web/scripts/ensure_stack.py \
         local-web/scripts/web_search.py local-web/scripts/web_scrape.py; do
  check_file "local-search/$f"
done
# NOTE: local-search/install-local-search.* are intentionally NOT unpacked by
# the packer (they are generated artifacts) - they are verified in step 5.

for f in gen_installers.py gen_rig.py test_b64.py test_heredocs.py test_rig.py \
         e2e_test.sh zip_test.sh build.sh build.bat BUILD.md \
         local-search-rig.bat local-search-rig.sh; do
  check_file "$f"
done

# .bat files unpacked by the .sh packer must have CRLF endings
for f in local-search/Run.bat local-search/Update.bat local-search-rig.bat build.bat; do
  if grep -q $'\r' "$TESTROOT/rig/$f" 2>/dev/null; then
    echo "  [OK]   $f has CRLF"
  else
    echo "  [FAIL] $f lacks CRLF"; PASS=0
  fi
done
echo

echo "=== 4. SELF-HOSTING: regenerate packers inside unpacked rig ==="
if (cd "$TESTROOT/rig" && python3 gen_rig.py); then
  if cmp -s "$ROOT/local-search-rig.sh" "$TESTROOT/rig/local-search-rig.sh"; then
    echo "  [OK] local-search-rig.sh regenerated BYTE-IDENTICAL"
  else
    echo "  [FAIL] local-search-rig.sh differs after regeneration"; PASS=0
  fi
  if cmp -s "$ROOT/local-search-rig.bat" "$TESTROOT/rig/local-search-rig.bat"; then
    echo "  [OK] local-search-rig.bat regenerated BYTE-IDENTICAL"
  else
    echo "  [FAIL] local-search-rig.bat differs after regeneration"; PASS=0
  fi
else
  echo "  [FAIL] gen_rig.py failed in unpacked rig"; PASS=0
fi
echo

echo "=== 5. regenerate installers inside unpacked rig ==="
if (cd "$TESTROOT/rig" && python3 gen_installers.py); then
  if cmp -s "$ROOT/local-search/install-local-search.sh" "$TESTROOT/rig/local-search/install-local-search.sh"; then
    echo "  [OK] install-local-search.sh regenerated BYTE-IDENTICAL"
  else
    echo "  [FAIL] install-local-search.sh differs"; PASS=0
  fi
  if cmp -s "$ROOT/local-search/install-local-search.bat" "$TESTROOT/rig/local-search/install-local-search.bat"; then
    echo "  [OK] install-local-search.bat regenerated BYTE-IDENTICAL"
  else
    echo "  [FAIL] install-local-search.bat differs"; PASS=0
  fi
else
  echo "  [FAIL] gen_installers.py failed in unpacked rig"; PASS=0
fi
echo

echo "=== 6. verify test suite passes inside the unpacked rig ==="
if (cd "$TESTROOT/rig" && python3 test_rig.py > /dev/null 2>&1); then
  echo "  [OK] test_rig.py passes in unpacked rig"
else
  echo "  [FAIL] test_rig.py fails in unpacked rig"; PASS=0
fi

echo
if [ "$PASS" = 1 ]; then
  echo "=================  SELF-HOSTING TEST: PASSED  ================="
  exit 0
fi
echo "=================  SELF-HOSTING TEST: FAILED  ================="
exit 1
EOF_SELFHOST_TEST_SH

# --- build.sh ---
cat > "$TARGET/build.sh" <<'EOF_BUILD_SH'
#!/usr/bin/env bash
# Build + test everything in the local-search dev rig.
#   1. regenerate the two installers        (gen_installers.py)
#   2. syntax-check + verify embedded files (test_b64.py / test_heredocs.py)
#   3. full install/uninstall e2e test      (e2e_test.sh, mocked docker)
#   4. regenerate the rig packers           (gen_rig.py) + verify (test_rig.py)
#   5. build local-search.zip               (+ zip_test.sh when unzip exists)
set -u
cd "$(dirname "$0")" || exit 1

PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
  echo "[ERROR] python3 (or python) not found on PATH." >&2
  exit 1
fi

echo "== [1/6] Generating installers (gen_installers.py) =="
"$PY" gen_installers.py || exit 1

echo "== [2/6] bash syntax check =="
bash -n local-search/install-local-search.sh || {
  echo "[FAIL] install-local-search.sh has bash syntax errors" >&2; exit 1; }
echo "  syntax OK"

echo "== [3/6] Embedded-file tests =="
"$PY" test_b64.py || exit 1
"$PY" test_heredocs.py || exit 1

echo "== [4/6] End-to-end install test (mocked docker) =="
bash e2e_test.sh || exit 1

echo "== [5/6] Regenerating rig packers (gen_rig.py) =="
"$PY" gen_rig.py || exit 1
"$PY" test_rig.py || exit 1
if bash selfhost_test.sh; then :; else
  echo "[FAIL] self-hosting test failed" >&2; exit 1
fi

echo "== [6/6] Building local-search.zip =="
rm -f local-search.zip
if command -v zip >/dev/null 2>&1; then
  zip -r local-search.zip local-search/ -x 'local-search/.git/*' '*/__pycache__/*' > /dev/null || exit 1
  echo "  local-search.zip built."
  if command -v unzip >/dev/null 2>&1; then
    bash zip_test.sh || exit 1
  fi
else
  echo "  [WARNING] 'zip' not found - skipping zip (installers are unaffected)."
fi

echo
echo "ALL GREEN. Artifacts:"
echo "  local-search/install-local-search.bat / .sh   <- the installers"
echo "  local-search-rig.bat / local-search-rig.sh    <- the dev-rig packers"
echo "  local-search.zip                              <- repo snapshot for GitHub"
EOF_BUILD_SH

# --- build.bat ---
cat > "$TARGET/build.bat" <<'EOF_BUILD_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search Dev Rig - Build

cd /d "%~dp0"

set "PY="
py -3 -c "print(1)" >nul 2>&1
if not errorlevel 1 set "PY=py -3"
if not defined PY (
  python -c "print(1)" >nul 2>&1
  if not errorlevel 1 set "PY=python"
)
if not defined PY (
  python3 -c "print(1)" >nul 2>&1
  if not errorlevel 1 set "PY=python3"
)
if not defined PY (
  echo [ERROR] Python not found ^(py / python / python3^). Install Python 3.8+ first.
  pause
  exit /b 1
)

echo == [1/3] Generating installers ==
%PY% gen_installers.py
if errorlevel 1 ( echo [ERROR] gen_installers.py failed. & pause & exit /b 1 )

echo == [2/3] Embedded-file tests ==
%PY% test_b64.py
if errorlevel 1 ( echo [ERROR] test_b64.py failed. & pause & exit /b 1 )
%PY% test_heredocs.py
if errorlevel 1 ( echo [ERROR] test_heredocs.py failed. & pause & exit /b 1 )

echo == [3/3] Regenerating rig packers ==
%PY% gen_rig.py
if errorlevel 1 ( echo [ERROR] gen_rig.py failed. & pause & exit /b 1 )
%PY% test_rig.py
if errorlevel 1 ( echo [ERROR] test_rig.py failed. & pause & exit /b 1 )

if exist local-search.zip del local-search.zip
tar -a -c -f local-search.zip local-search >nul 2>&1
if not exist local-search.zip (
  powershell -NoProfile -Command "Compress-Archive -Path 'local-search' -DestinationPath 'local-search.zip'" >nul 2>&1
)
if exist local-search.zip (
  echo   local-search.zip built.
) else (
  echo   [WARNING] could not build local-search.zip ^(no tar / Compress-Archive^).
)

echo.
echo ALL GREEN. Artifacts:
echo   local-search\install-local-search.bat / .sh     the installers
echo   local-search-rig.bat / local-search-rig.sh      the dev-rig packers
echo   local-search.zip                                repo snapshot
echo.
echo Note: the bash-based e2e / selfhost tests do not run here. Use Git Bash:
echo   bash e2e_test.sh
echo.
pause
exit /b 0
EOF_BUILD_BAT

# --- BUILD.md ---
cat > "$TARGET/BUILD.md" <<'EOF_BUILD_MD'
# 🔧 Local Search — developer rig

This folder is the complete build + test environment for the
**local-search** installers. Everything regenerates from here.

## Layout

```
local-search/                  the product (source of truth — edit freely)
  install-local-search.bat     ← GENERATED by gen_installers.py — do not edit
  install-local-search.sh      ← GENERATED by gen_installers.py — do not edit
  ...                          ← 21 source files (compose, scripts, skill, docs)
gen_installers.py              reads local-search/ → writes the two installers
gen_rig.py                     reads local-search/ + this rig → writes the two packers
extract-embedded.py            pull all embedded files out of any single .sh artifact
test_b64.py                    every file embedded in the .bat installer round-trips
test_heredocs.py               every file embedded in the .sh installer matches
test_rig.py                    both rig packers embed the current files exactly
e2e_test.sh                    install → skill → self-heal → uninstall (mocked docker + fake stack)
zip_test.sh                    extract local-search.zip and install from it
selfhost_test.sh               unpack a packer alone → regenerate → byte-compare
build.sh / build.bat           regenerate everything + run all tests + build the zip
BUILD.md                       this file
```

## Quick start

Linux / macOS / Git Bash:

```bash
bash build.sh
```

Windows:

```bat
build.bat
```

`build.sh` runs the full pipeline: generate installers → verify embeds →
e2e install test → regenerate the packers → verify packers → self-hosting
test (unpack a packer alone, regenerate, byte-compare) → build + re-test
the zip. `build.bat` does the same minus the bash-only e2e/selfhost tests
(run `bash e2e_test.sh` / `bash selfhost_test.sh` from Git Bash if you want
them on Windows).

## Workflow after editing anything

1. Edit any file under `local-search/` (or any rig script).
2. Run `bash build.sh` (or `build.bat`).
3. Artifacts:
   - `local-search/install-local-search.bat` / `.sh` — the self-contained installers
   - `local-search-rig.bat` / `local-search-rig.sh` — the self-contained dev-rig packers
   - `local-search.zip` — repo snapshot for GitHub

## The packers

`local-search-rig.bat` and `local-search-rig.sh` embed the **entire rig** —
the local-search source tree, every generator/test/build script, this file,
and (in the `.sh`) the `.bat` packer itself. That means **either one file
alone** reproduces the complete dev environment, including both packers:

```bash
chmod +x local-search-rig.sh
./local-search-rig.sh        # asks for a folder, unpacks, optionally builds
```

They are **self-hosting**: after unpacking, `python3 gen_rig.py` regenerates
both packers byte-for-byte (verified by the build pipeline and by
`selfhost_test.sh`, which unpacks a packer into a clean folder and proves
regeneration is exact). The generated installers themselves are NOT embedded —
run the build (the packer offers) or `python3 gen_installers.py` to create
them fresh.

## Manual commands

```bash
python3 gen_installers.py    # rebuild just the two installers
python3 gen_rig.py           # rebuild just the two packers
python3 test_b64.py          # verify .bat installer embeds
python3 test_heredocs.py     # verify .sh installer embeds
python3 test_rig.py          # verify packer embeds
bash e2e_test.sh             # install/uninstall + self-heal test (mocked docker)
bash zip_test.sh             # zip extraction test (needs unzip)
bash selfhost_test.sh        # unpack a packer alone → regenerate → byte-compare
```

## Single-file recovery (no Docker needed)

Lost everything except one `.sh` artifact? `extract-embedded.py` pulls every
embedded file out of it — it only parses the quoted heredocs, nothing is
executed:

```bash
# from the rig packer: recovers the COMPLETE rig (34 files)
python3 extract-embedded.py local-search-rig.sh rig
# then regenerate everything:
cd rig && python3 gen_installers.py && python3 gen_rig.py

# from the installer: recovers the local-search/ sources + the .bat installer
python3 extract-embedded.py install-local-search.sh local-search
# add the rig scripts (visible in the repo) next to it and regenerate.
```

The `.sh` file you extracted from is never embedded in itself — copy it over
manually if you want it in the recovered tree.

## Conventions

- **Line endings:** `.bat` sources are CRLF; `.sh` / `.py` / `.md` / `.yml`
  are LF. The `.sh` packer normalizes to LF inside its heredocs and restores
  CRLF for every `*.bat` on unpack (via awk, so it also works on macOS).
- **bash 3.2 safe:** all shell scripts avoid `${var,,}`, `sed -i`, and
  GNU-only sed escapes, so they run on the macOS default shell. Case-folding
  goes through the `lower()` helper (`tr '[:upper:]' '[:lower:]'`).
- **Safe tests:** `e2e_test.sh` and `zip_test.sh` back up and restore
  `~/.agents/skills/local-web` if you have a real install — they never
  destroy it. Test folders (`.ls-test-*`, `.zip-test-*`) are removed on
  success and kept on failure for debugging.
- **Mocked docker:** the e2e tests put a fake `docker` on PATH, so they run
  the full install logic without touching a real Docker daemon.
EOF_BUILD_MD

# --- local-search-rig.bat ---
cat > "$TARGET/local-search-rig.bat" <<'EOF_LOCAL_SEARCH_RIG_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search Dev Rig - Unpack

REM ===========================================================================
REM  Local Search DEV RIG packer  -  Windows
REM ===========================================================================
REM  Self-contained: embeds the complete build/test environment for the
REM  local-search installers:
REM    * the local-search source tree (21 files)
REM    * gen_installers.py / gen_rig.py (the two generators)
REM    * every test + build script + BUILD.md
REM  Unpack anywhere, then run build.bat (or: python gen_installers.py) to
REM  regenerate the installers, and: python gen_rig.py to regenerate these
REM  packers byte-for-byte.
REM ===========================================================================

echo ============================================================
echo   Local Search DEV RIG  (build + test environment)
echo   Unpacks everything needed to regenerate and verify the
echo   install-local-search installers.
echo ============================================================
echo.

set "DEFAULT_TARGET=%~dp0local-search-dev"

echo --- Step 1 of 3: Unpack location ---------------------------
echo   Default: %DEFAULT_TARGET%
set "TARGET="
set /p TARGET="  Target folder [press Enter for default]: "
if "!TARGET!"=="" set "TARGET=%DEFAULT_TARGET%"
set "TARGET=!TARGET:"=!"
for %%I in ("!TARGET!") do set "TARGET=%%~fI"
echo   Using: !TARGET!
echo   ^(existing files in the target folder are overwritten^)
echo.

echo --- Step 2 of 3: Build now? --------------------------------
echo   Generate install-local-search.bat/.sh with Python right after unpacking?
set "BUILDNOW="
set /p BUILDNOW="  Run the installer build now? [Y/n]: "
echo.

echo --- Step 3 of 3: Confirm -----------------------------------
echo   Will unpack 33 files into: !TARGET!
set "CONFIRM="
set /p CONFIRM="Proceed? [Y/n]: "
if /i "!CONFIRM!"=="n" ( echo Cancelled. & pause & exit /b 0 )

if not exist "!TARGET!" mkdir "!TARGET!"
if not exist "!TARGET!\local-search" mkdir "!TARGET!\local-search"
if not exist "!TARGET!\local-search\config\searxng" mkdir "!TARGET!\local-search\config\searxng"
if not exist "!TARGET!\local-search\local-web\scripts" mkdir "!TARGET!\local-search\local-web\scripts"

echo Unpacking files...

REM --- local-search/config/searxng/settings.yml ---
set "B64TMP=%TEMP%\LSR1932187917.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\config\searxng\settings.yml"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/docker-compose.yml ---
set "B64TMP=%TEMP%\LSR721465585.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\docker-compose.yml"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/.env.example ---
set "B64TMP=%TEMP%\LSR1565846316.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\.env.example"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/README.md ---
set "B64TMP=%TEMP%\LSR1940939601.b64"
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
>> "!B64TMP!" echo YWwtc2VhcmNoYCDigJQgbm8gaGFyZGNvZGVkIGFueXRoaW5nLgotICoqU2VsZi1oZWFscyBhIGRv
>> "!B64TMP!" echo d24gc3RhY2sg4oCUIG5vIHdhcm0tdXAgc3RlcC4qKiBJZiB0aGUgRG9ja2VyIGVuZ2luZSBvciB0
>> "!B64TMP!" echo aGUKICBjb250YWluZXJzIGFyZSBkb3duIHdoZW4gYSBzZWFyY2gvc2NyYXBlIHJ1bnMsIHRoZSBz
>> "!B64TMP!" echo Y3JpcHQgYm9vdHMgdGhlIGVuZ2luZQogIChEb2NrZXIgRGVza3RvcCAvIGBzeXN0ZW1jdGwgc3Rh
>> "!B64TMP!" echo cnQgZG9ja2VyYCksIHJ1bnMgdGhlIHNhbWUgYGRvY2tlciBjb21wb3NlCiAgdXAgLWRgIHRoYXQg
>> "!B64TMP!" echo YFJ1bi5iYXRgIC8gYHJ1bi5zaGAgdXNlLCB3YWl0cyBmb3IgdGhlIGVuZHBvaW50cywgYW5kIHJl
>> "!B64TMP!" echo dHJpZXMKICB0aGUgcmVxdWVzdCDigJQgc28gdGhlIGFnZW50IGNhbGxzIHRoZSBzZWFyY2gvc2Ny
>> "!B64TMP!" echo YXBlIHNjcmlwdHMgZGlyZWN0bHksIGV2ZW4KICBpbiBhbiBvbGQgY29udmVyc2F0aW9uIHdoZXJl
>> "!B64TMP!" echo IHRoZSBzdGFjayBoYXMgc2luY2UgZ29uZSBkb3duCiAgKGBlbnN1cmVfc3RhY2sucHlgIHJlbWFp
>> "!B64TMP!" echo bnMgYXZhaWxhYmxlIGFzIGFuIG9wdGlvbmFsIHByZS1mbGlnaHQgY2hlY2spLiBUaGUKICBzdGFj
>> "!B64TMP!" echo ayBpcyAqKm5ldmVyIHN0b3BwZWQqKiBieSB0aGUgc2NyaXB0cyAoc3RvcHBpbmcgaXMgeW91ciBq
>> "!B64TMP!" echo b2IsIHZpYQogIGBTdG9wLmJhdGAgLyBgc3RvcC5zaGApLgotICoqU2VhcmNoZXMgdGhlIHdlYi4q
>> "!B64TMP!" echo KiBgd2ViX3NlYXJjaC5weSAicXVlcnkiYCBwcmludHMgdGhlIHRvcCByZXN1bHRzIGFzCiAgYHRp
>> "!B64TMP!" echo dGxlIC8gdXJsIC8gc25pcHBldGAsIHdpdGggYC0tbGltaXRgLCBgLS10aW1lLXJhbmdlIGRheXx3
>> "!B64TMP!" echo ZWVrfG1vbnRoYCwgYW5kCiAgYC0tY2F0ZWdvcmllcyBpdCxuZXdzLGdlbmVyYWxgIG9wdGlvbnMu
>> "!B64TMP!" echo Ci0gKipSZWFkcyBwYWdlcy4qKiBgd2ViX3NjcmFwZS5weSA8dXJsPmAgcmV0dXJucyB0aGUgcGFn
>> "!B64TMP!" echo ZSBhcyBjbGVhbiBNYXJrZG93bgogICh0cnVuY2F0ZWQgYXQgMjAsMDAwIGNoYXJzOyByYWlzZSB3
>> "!B64TMP!" echo aXRoIGAtLW1heC1jaGFyc2ApLgoKTWFudWFsIHVzYWdlIChleGFjdGx5IHdoYXQgdGhlIGFnZW50
>> "!B64TMP!" echo IHJ1bnMg4oCUIG5vIHNlcGFyYXRlIHN0YXJ0IHN0ZXAgbmVlZGVkKToKCmBgYGJhc2gKcHl0aG9u
>> "!B64TMP!" echo IH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViL3NjcmlwdHMvd2ViX3NlYXJjaC5weSAibGF0ZXN0
>> "!B64TMP!" echo IHB5dGhvbiByZWxlYXNlIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfc2NyYXBlLnB5ICJodHRwczovL2V4YW1wbGUuY29tIgojIG9wdGlvbmFsIHByZS1mbGln
>> "!B64TMP!" echo aHQgY2hlY2sgLyBzdGF0dXMgcmVwb3J0OgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13
>> "!B64TMP!" echo ZWIvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkgLS1jaGVjawpgYGAKClRoZSBmdWxsIGFnZW50LWZh
>> "!B64TMP!" echo Y2luZyBpbnN0cnVjdGlvbnMgbGl2ZSBpbiB0aGUgc2tpbGwncyBgU0tJTEwubWRgLiBLZWVwaW5n
>> "!B64TMP!" echo IHRoZQpza2lsbCBmcmVzaCBpcyBhdXRvbWF0aWM6IGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5z
>> "!B64TMP!" echo aGAgcmUtc3luY3MgaXQsIGFuZApyZS1ydW5uaW5nIHRoZSBpbnN0YWxsZXIgb3ZlcndyaXRlcyBp
>> "!B64TMP!" echo dC4gVW5pbnN0YWxsaW5nIHJlbW92ZXMgaXQuCgo+IFRoZSBza2lsbCBvbmx5IG5lZWRzICoqUHl0
>> "!B64TMP!" echo aG9uIDMuOCsqKiBvbiB0aGUgaG9zdCDigJQgbm8gcGlwIHBhY2thZ2VzLCBubyBBUEkKPiBrZXlz
>> "!B64TMP!" echo LCBubyBNQ1Agc3VwcG9ydCByZXF1aXJlZCBmcm9tIHRoZSBhZ2VudC4KCi0tLQoKIyMjIEIuIERp
>> "!B64TMP!" echo cmVjdCBTZWFyWE5HIEpTT04gQVBJCgpUaGUgc2ltcGxlc3QgcG9zc2libGUgaW50ZWdyYXRpb246
>> "!B64TMP!" echo IGhpdCBTZWFyWE5HJ3MgSlNPTiBlbmRwb2ludCBhbmQgZmVlZCB0aGUKcmVzdWx0cyBpbnRvIGFu
>> "!B64TMP!" echo eSBtb2RlbCdzIGNvbnRleHQuIE5vIFNESywgbm8ga2V5LCBubyBNQ1AuCgpgYGBiYXNoCiMgU2Vh
>> "!B64TMP!" echo cmNoIHRoZSB3ZWIsIHJldHVybiBKU09OLCBzaG93IHRoZSB0b3AgNSByZXN1bHRzCmN1cmwgLXMg
>> "!B64TMP!" echo Imh0dHA6Ly9sb2NhbGhvc3Q6OTk5MC9zZWFyY2g/cT1sYXRlc3QrQUkrbmV3cyZmb3JtYXQ9anNv
>> "!B64TMP!" echo biIgXAogIHwganEgJy5yZXN1bHRzWzo1XSB8IC5bXSB8IHt0aXRsZSwgdXJsLCBjb250ZW50fScK
>> "!B64TMP!" echo YGBgCgpVc2VmdWwgcXVlcnkgcGFyYW1zOiBgJnBhZ2Vubz0yYCwgYCZjYXRlZ29yaWVzPWl0LGlt
>> "!B64TMP!" echo YWdlc2AsIGAmdGltZV9yYW5nZT1kYXlgLApgJmxhbmd1YWdlPWVuYCwgYCZlbmdpbmVzPWdvb2ds
>> "!B64TMP!" echo ZSxiaW5nLGR1Y2tkdWNrZ29gLgoKSW4gUHl0aG9uOgoKYGBgcHl0aG9uCmltcG9ydCByZXF1ZXN0
>> "!B64TMP!" echo cwpyID0gcmVxdWVzdHMuZ2V0KCJodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoIiwgcGFyYW1z
>> "!B64TMP!" echo PXsKICAgICJxIjogInJ1c3QgYXN5bmMgcnVudGltZSB0b2tpbyIsCiAgICAiZm9ybWF0IjogImpz
>> "!B64TMP!" echo b24iLAogICAgImxhbmd1YWdlIjogImVuIiwKfSkuanNvbigpCmZvciBoaXQgaW4gclsicmVzdWx0
>> "!B64TMP!" echo cyJdWzo1XToKICAgIHByaW50KGhpdFsidGl0bGUiXSwgIi0+IiwgaGl0WyJ1cmwiXSkKICAgIHBy
>> "!B64TMP!" echo aW50KGhpdC5nZXQoImNvbnRlbnQiLCAiIilbOjIwMF0pCmBgYAoKPiBTZWFyWE5HIHJldHVybnMg
>> "!B64TMP!" echo dGl0bGVzLCBVUkxzLCBhbmQgc2hvcnQgY29udGVudCBzbmlwcGV0cyDigJQgcGVyZmVjdCBmb3Ig
>> "!B64TMP!" echo YQo+ICJzZWFyY2ggdGhlbiBzdW1tYXJpemUiIGFnZW50IGxvb3AuIEZvciAqKmZ1bGwgcGFnZSB0
>> "!B64TMP!" echo ZXh0KiosIHVzZSBGaXJlY3Jhd2wgKEMpLgoKLS0tCgojIyMgQy4gRGlyZWN0IEZpcmVjcmF3bCBS
>> "!B64TMP!" echo RVNUIEFQSQoKRmlyZWNyYXdsIHR1cm5zIGFueSBVUkwgaW50byBjbGVhbiBNYXJrZG93bi9IVE1M
>> "!B64TMP!" echo L0pTT04g4oCUIGlkZWFsIGZvciBSQUcuIEJlY2F1c2UKdGhlIHNlbGYtaG9zdGVkIGluc3RhbmNl
>> "!B64TMP!" echo IHJ1bnMgd2l0aCBgVVNFX0RCX0FVVEhFTlRJQ0FUSU9OPWZhbHNlYCwgKipubyBBUEkga2V5Cmlz
>> "!B64TMP!" echo IHJlcXVpcmVkKiogKHlvdSBjYW4gc2VuZCBhbnkgYEF1dGhvcml6YXRpb246IEJlYXJlciDigKZg
>> "!B64TMP!" echo IGhlYWRlciwgb3Igbm9uZSkuCgojIyMjIFNjcmFwZSBhIHNpbmdsZSBwYWdlIOKGkiBNYXJrZG93
>> "!B64TMP!" echo bgoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NjcmFw
>> "!B64TMP!" echo ZSBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogIC1kICd7InVybCI6
>> "!B64TMP!" echo Imh0dHBzOi8vZXhhbXBsZS5jb20iLCJmb3JtYXRzIjpbIm1hcmtkb3duIl19JyBcCiAgfCBqcSAn
>> "!B64TMP!" echo LmRhdGEubWFya2Rvd24nCmBgYAoKIyMjIyBTZWFyY2ggdGhlIHdlYiAodXNlcyB5b3VyIFNlYXJY
>> "!B64TMP!" echo TkcgaW50ZXJuYWxseSkgKyByZXR1cm4gZnVsbCBjb250ZW50CgpgYGBiYXNoCmN1cmwgLXMgLVgg
>> "!B64TMP!" echo UE9TVCBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvc2VhcmNoIFwKICAtSCAiQ29udGVudC1UeXBl
>> "!B64TMP!" echo OiBhcHBsaWNhdGlvbi9qc29uIiBcCiAgLWQgJ3sicXVlcnkiOiJ3aGF0IGlzIHJ1c3QgcHJvZ3Jh
>> "!B64TMP!" echo bW1pbmcgbGFuZ3VhZ2UiLCJsaW1pdCI6NX0nIFwKICB8IGpxICcuZGF0YVs6M10gfCAuW10gfCB7
>> "!B64TMP!" echo dGl0bGUsIHVybCwgbWFya2Rvd259JwpgYGAKCiMjIyMgQ3Jhd2wgYSB3aG9sZSBzaXRlIChhc3lu
>> "!B64TMP!" echo YykKCmBgYGJhc2gKIyAxKSBzdGFydCB0aGUgY3Jhd2wKSk9CPSQoY3VybCAtcyAtWCBQT1NUIGh0
>> "!B64TMP!" echo dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9jcmF3bCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGlj
>> "!B64TMP!" echo YXRpb24vanNvbiIgXAogIC1kICd7InVybCI6Imh0dHBzOi8vZG9jcy5leGFtcGxlLmNvbSIsImxp
>> "!B64TMP!" echo bWl0IjoyMH0nIHwganEgLXIgLmlkKQoKIyAyKSBwb2xsIHVudGlsIHN0YXR1cyA9PSAiY29tcGxl
>> "!B64TMP!" echo dGVkIgpjdXJsIC1zICJodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvY3Jhd2wvJEpPQiIgfCBqcSAn
>> "!B64TMP!" echo e3N0YXR1cywgY29tcGxldGVkLCB0b3RhbH0nCmBgYAoKIyMjIyBNYXAgYSBzaXRlJ3MgVVJMIHRy
>> "!B64TMP!" echo ZWUgKGZhc3QsIG5vIHNjcmFwaW5nKQoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xv
>> "!B64TMP!" echo Y2FsaG9zdDo5OTkxL3YxL21hcCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNv
>> "!B64TMP!" echo biIgXAogIC1kICd7InVybCI6Imh0dHBzOi8vZXhhbXBsZS5jb20iLCJsaW1pdCI6NTB9JyB8IGpx
>> "!B64TMP!" echo ICcubGlua3MnCmBgYAoKIyMjIyBFeHRyYWN0IHN0cnVjdHVyZWQgZGF0YSB3aXRoIGFuIExMTSAo
>> "!B64TMP!" echo bmVlZHMgc2VjdGlvbiBEIGNvbmZpZ3VyZWQpCgpgYGBiYXNoCmN1cmwgLXMgLVggUE9TVCBodHRw
>> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTEvdjEvZXh0cmFjdCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGlj
>> "!B64TMP!" echo YXRpb24vanNvbiIgXAogIC1kICd7InVybHMiOlsiaHR0cHM6Ly9leGFtcGxlLmNvbSJdLCJwcm9t
>> "!B64TMP!" echo cHQiOiJFeHRyYWN0IHRoZSBjb21wYW55IG5hbWUgYW5kIGEgY29udGFjdCBlbWFpbCJ9JyBcCiAg
>> "!B64TMP!" echo fCBqcSAnLmRhdGEnCmBgYAoKIyMjIyBVc2luZyB0aGUgRmlyZWNyYXdsIFNES3MgKE5vZGUgLyBQ
>> "!B64TMP!" echo eXRob24pCgpTZWxmLWhvc3Qgd29ya3Mgd2l0aCB0aGUgb2ZmaWNpYWwgU0RLcyDigJQgcG9pbnQg
>> "!B64TMP!" echo dGhlbSBhdCB5b3VyIGxvY2FsIFVSTCBhbmQgcGFzcwphbnkgbm9uLWVtcHR5IHN0cmluZyBhcyB0
>> "!B64TMP!" echo aGUga2V5OgoKKipOb2RlLmpzKioKYGBganMKaW1wb3J0IEZpcmVjcmF3bCBmcm9tICJAbWVuZGFi
>> "!B64TMP!" echo bGUvZmlyZWNyYXdsLWpzIjsKCmNvbnN0IGZjID0gbmV3IEZpcmVjcmF3bCh7CiAgYXBpS2V5OiAi
>> "!B64TMP!" echo ZmMtbG9jYWwiLCAgICAgICAgICAgICAgLy8gYW55IG5vbi1lbXB0eSBzdHJpbmc7IHNlbGYtaG9z
>> "!B64TMP!" echo dCBkb2Vzbid0IHZhbGlkYXRlCiAgYXBpVXJsOiAiaHR0cDovL2xvY2FsaG9zdDo5OTkxIiwgLy8g
>> "!B64TMP!" echo PC0tIHBvaW50IGF0IHlvdXIgbG9jYWwgaW5zdGFuY2UKfSk7Cgpjb25zdCB7IGRhdGEgfSA9IGF3
>> "!B64TMP!" echo YWl0IGZjLnNjcmFwZVVybCgiaHR0cHM6Ly9leGFtcGxlLmNvbSIsIHsgZm9ybWF0czogWyJtYXJr
>> "!B64TMP!" echo ZG93biJdIH0pOwpjb25zb2xlLmxvZyhkYXRhLm1hcmtkb3duKTsKYGBgCgoqKlB5dGhvbioqCmBg
>> "!B64TMP!" echo YHB5dGhvbgpmcm9tIGZpcmVjcmF3bCBpbXBvcnQgRmlyZWNyYXdsQXBwCgpmYyA9IEZpcmVjcmF3
>> "!B64TMP!" echo bEFwcChhcGlfa2V5PSJmYy1sb2NhbCIsIGFwaV91cmw9Imh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIp
>> "!B64TMP!" echo CnJlc3VsdCA9IGZjLnNjcmFwZV91cmwoImh0dHBzOi8vZXhhbXBsZS5jb20iLCBwYXJhbXM9eyJm
>> "!B64TMP!" echo b3JtYXRzIjogWyJtYXJrZG93biJdfSkKcHJpbnQocmVzdWx0WyJtYXJrZG93biJdKQpgYGAKCi0t
>> "!B64TMP!" echo LQoKIyMjIEQuIENvbm5lY3QgYSBsb2NhbCBMTE0gKExNIFN0dWRpbywgZXRjLikKCkJ5IGRlZmF1
>> "!B64TMP!" echo bHQsIEZpcmVjcmF3bCdzIGAvdjEvc2NyYXBlYCwgYC92MS9jcmF3bGAsIGAvdjEvbWFwYCwgYW5k
>> "!B64TMP!" echo IGAvdjEvc2VhcmNoYAp3b3JrICoqd2l0aG91dCBhbnkgTExNKiouIFRvIHVubG9jayAqKmAvdjEv
>> "!B64TMP!" echo ZXh0cmFjdGAqKiAoQUkgZXh0cmFjdGlvbikgYW5kIHRoZQpgc3VtbWFyeWAgb3V0cHV0IGZvcm1h
>> "!B64TMP!" echo dCwgcG9pbnQgRmlyZWNyYXdsIGF0IGFueSAqKk9wZW5BSS1jb21wYXRpYmxlKiogZW5kcG9pbnQu
>> "!B64TMP!" echo CioqTE0gU3R1ZGlvIGlzIHRoZSByZWNvbW1lbmRlZCBkZWZhdWx0KiogKHByaW9yaXR5IG92ZXIg
>> "!B64TMP!" echo T2xsYW1hKS4KCiMjIyMgUmVjb21tZW5kZWQ6IExNIFN0dWRpbwoKMS4gSW5zdGFsbCBbTE0gU3R1
>> "!B64TMP!" echo ZGlvXShodHRwczovL2xtc3R1ZGlvLmFpLyksIGRvd25sb2FkIGEgbW9kZWwgKGUuZy4gYFF3ZW4y
>> "!B64TMP!" echo LjUtN0ItSW5zdHJ1Y3RgKS4KMi4gR28gdG8gdGhlICoqRGV2ZWxvcGVyKiogdGFiIOKGkiAqKlN0
>> "!B64TMP!" echo YXJ0IFNlcnZlcioqIG9uIHBvcnQgYDEyMzRgIChkZWZhdWx0KS4KMy4gKipFbmFibGUgIlNlcnZl
>> "!B64TMP!" echo IG9uIGxvY2FsIG5ldHdvcmsiKiogKHJlcXVpcmVkIOKAlCBGaXJlY3Jhd2wgcnVucyBpbiBhIGNv
>> "!B64TMP!" echo bnRhaW5lcgogICBhbmQgcmVhY2hlcyB5b3VyIGhvc3QgdmlhIGBob3N0LmRvY2tlci5pbnRlcm5h
>> "!B64TMP!" echo bGAsIHdoaWNoIGlzIHlvdXIgTEFOIElQLCBub3QKICAgYDEyNy4wLjAuMWApLgo0LiBFaXRoZXI6
>> "!B64TMP!" echo CiAgIC0gcmUtcnVuIHRoZSBpbnN0YWxsZXIgYW5kIGFuc3dlciAqKnkqKiB0byAqIkNvbm5lY3Qg
>> "!B64TMP!" echo YSBsb2NhbCBMTE0gbm93PyIqIOKAlCBpdAogICAgIGF1dG8tY29udmVydHMgYGh0dHA6Ly9sb2Nh
>> "!B64TMP!" echo bGhvc3Q6MTIzNC92MWAg4oaSIGBodHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MWAK
>> "!B64TMP!" echo ICAgICBhbmQgd3JpdGVzIGl0IGludG8gYC5lbnZgOyAqKm9yKioKICAgLSBlZGl0IGAuZW52YCBk
>> "!B64TMP!" echo aXJlY3RseSBhbmQgc2V0OgogICAgIGBgYGVudgogICAgIE9QRU5BSV9CQVNFX1VSTD1odHRwOi8v
>> "!B64TMP!" echo aG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MQogICAgIE9QRU5BSV9BUElfS0VZPWxtLXN0dWRp
>> "!B64TMP!" echo bwogICAgIE1PREVMX05BTUU9PHRoZSBtb2RlbCBpZCBsb2FkZWQgaW4gTE0gU3R1ZGlvPgogICAg
>> "!B64TMP!" echo IGBgYAo1LiBBcHBseSB3aXRoIGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAuCgojIyMjIE90
>> "!B64TMP!" echo aGVyIE9wZW5BSS1jb21wYXRpYmxlIHNlcnZlcnMgKHZMTE0sIGxsYW1hLmNwcCBgc2VydmVyYCwg
>> "!B64TMP!" echo dGV4dC1nZW5lcmF0aW9uLWluZmVyZW5jZSwgTG9jYWxBSSwg4oCmKQoKYGBgZW52Ck9QRU5BSV9C
>> "!B64TMP!" echo QVNFX1VSTD1odHRwOi8vPGhvc3Qtb3ItaXA+Ojxwb3J0Pi92MQpPUEVOQUlfQVBJX0tFWT1wbGFj
>> "!B64TMP!" echo ZWhvbGRlciAgICAgICMgYW55IG5vbi1lbXB0eSBzdHJpbmcgaWYgeW91ciBzZXJ2ZXIgaWdub3Jl
>> "!B64TMP!" echo cyBpdApNT0RFTF9OQU1FPTxtb2RlbCBpZCBmcm9tIEdFVCAvdjEvbW9kZWxzPgpgYGAKCkZvciBh
>> "!B64TMP!" echo IHJlbW90ZSBzZXJ2ZXIgb24gYW5vdGhlciBtYWNoaW5lLCB1c2UgaXRzIElQIGRpcmVjdGx5IChl
>> "!B64TMP!" echo LmcuCmBodHRwOi8vMTkyLjE2OC4xLjUwOjgwMDAvdjFgKS4gRm9yIGEgc2VydmVyIG9uIHRoZSAq
>> "!B64TMP!" echo KnNhbWUgaG9zdCBhcyBEb2NrZXIqKiwgdXNlCmBodHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6
>> "!B64TMP!" echo PHBvcnQ+L3YxYC4KCiMjIyMgRmFsbGJhY2s6IE9sbGFtYQoKSWYgeW91IHByZWZlciBPbGxhbWEs
>> "!B64TMP!" echo IHNldCAoRmlyZWNyYXdsIHJlYWRzIGBPTExBTUFfQkFTRV9VUkxgKToKCmBgYGVudgpPTExBTUFf
>> "!B64TMP!" echo QkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjExNDM0L2FwaQpNT0RFTF9OQU1F
>> "!B64TMP!" echo PXF3ZW4yLjU6N2IKTU9ERUxfRU1CRURESU5HX05BTUU9bm9taWMtZW1iZWQtdGV4dApgYGAKClJl
>> "!B64TMP!" echo c3RhcnQgd2l0aCBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLCB0aGVuIGAvdjEvZXh0cmFj
>> "!B64TMP!" echo dGAgcm91dGVzIHRvIE9sbGFtYS4KCi0tLQoKIyMjIEUuIFZpYSBhbiBNQ1Agc2VydmVyCgpUaGUg
>> "!B64TMP!" echo b2ZmaWNpYWwgWyoqRmlyZWNyYXdsIE1DUCBzZXJ2ZXIqKl0oaHR0cHM6Ly9naXRodWIuY29tL2Zp
>> "!B64TMP!" echo cmVjcmF3bC9maXJlY3Jhd2wtbWNwLXNlcnZlcikKZXhwb3NlcyBgZmlyZWNyYXdsX3NlYXJjaGAs
>> "!B64TMP!" echo IGBmaXJlY3Jhd2xfc2NyYXBlYCwgYGZpcmVjcmF3bF9jcmF3bGAsIGBmaXJlY3Jhd2xfbWFwYCwK
>> "!B64TMP!" echo YGZpcmVjcmF3bF9leHRyYWN0YCwgYW5kIHJlc2VhcmNoIHRvb2xzIHRvIGFueSBNQ1AtY29tcGF0
>> "!B64TMP!" echo aWJsZSBjbGllbnQuIFBvaW50IGl0IGF0CnlvdXIgbG9jYWwgRmlyZWNyYXdsIHdpdGggYEZJUkVD
>> "!B64TMP!" echo UkFXTF9BUElfVVJMYC4KCiMjIyMgQ2xhdWRlIERlc2t0b3AgKGBjbGF1ZGVfZGVza3RvcF9jb25m
>> "!B64TMP!" echo aWcuanNvbmApCgpgYGBqc29uCnsKICAibWNwU2VydmVycyI6IHsKICAgICJmaXJlY3Jhd2wiOiB7
>> "!B64TMP!" echo CiAgICAgICJjb21tYW5kIjogIm5weCIsCiAgICAgICJhcmdzIjogWyIteSIsICJmaXJlY3Jhd2wt
>> "!B64TMP!" echo bWNwIl0sCiAgICAgICJlbnYiOiB7CiAgICAgICAgIkZJUkVDUkFXTF9BUElfVVJMIjogImh0dHA6
>> "!B64TMP!" echo Ly9sb2NhbGhvc3Q6OTk5MSIsCiAgICAgICAgIkZJUkVDUkFXTF9BUElfS0VZIjogImZjLWxvY2Fs
>> "!B64TMP!" echo IgogICAgICB9CiAgICB9CiAgfQp9CmBgYAoKIyMjIyBDdXJzb3IsIFZTIENvZGUsIFdpbmRzdXJm
>> "!B64TMP!" echo LCBDb250aW51ZSwgQ2xpbmUsIGV0Yy4KClNhbWUgc2hhcGUg4oCUIGFkZCBhbiBgbWNwU2VydmVy
>> "!B64TMP!" echo c2AgZW50cnkgdG8gdGhhdCB0b29sJ3MgY29uZmlnIGZpbGUKKGB+Ly5jdXJzb3IvbWNwLmpzb25g
>> "!B64TMP!" echo LCBgLnZzY29kZS9tY3AuanNvbmAsIGAuL2NvZGVpdW0vd2luZHN1cmYvbW9kZWxfY29uZmlnLmpz
>> "!B64TMP!" echo b25gLCDigKYpLgoKYGBganNvbgp7CiAgIm1jcFNlcnZlcnMiOiB7CiAgICAiZmlyZWNyYXdsIjog
>> "!B64TMP!" echo ewogICAgICAiY29tbWFuZCI6ICJucHgiLAogICAgICAiYXJncyI6IFsiLXkiLCAiZmlyZWNyYXds
>> "!B64TMP!" echo LW1jcCJdLAogICAgICAiZW52IjogewogICAgICAgICJGSVJFQ1JBV0xfQVBJX1VSTCI6ICJodHRw
>> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTEiLAogICAgICAgICJGSVJFQ1JBV0xfQVBJX0tFWSI6ICJmYy1sb2Nh
>> "!B64TMP!" echo bCIKICAgICAgfQogICAgfQogIH0KfQpgYGAKCj4gVGhlIE1DUCBzZXJ2ZXIgcnVucyBvbiB5b3Vy
>> "!B64TMP!" echo IGhvc3QgKG5vdCBpbiBEb2NrZXIpLCBzbyBpdCByZWFjaGVzIEZpcmVjcmF3bCBhdAo+IGBodHRw
>> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTFgLiAqKk5vIHJlYWwgQVBJIGtleSBpcyBuZWVkZWQqKiDigJQgYGZj
>> "!B64TMP!" echo LWxvY2FsYCBpcyBhCj4gcGxhY2Vob2xkZXI7IHRoZSBzZWxmLWhvc3RlZCBGaXJlY3Jhd2wgZG9l
>> "!B64TMP!" echo c24ndCB2YWxpZGF0ZSBpdC4gUmVxdWlyZXMgTm9kZS5qcwo+IDE4KyBmb3IgYG5weGAuCgo+ICoq
>> "!B64TMP!" echo Tm90ZSBmb3IgbG9jYWwgbGxhbWEuY3BwIHNlcnZlcnM6KiogdGhlIEZpcmVjcmF3bCBNQ1Agc2Vy
>> "!B64TMP!" echo dmVyIHNoaXBzIHZlcnkKPiBsYXJnZSB0b29sIGRlZmluaXRpb25zLCB3aGljaCBjYW4gZXhjZWVk
>> "!B64TMP!" echo IHNvbWUgbG9jYWwgaW5mZXJlbmNlIHNlcnZlcnMnCj4gbGltaXRzIChlLmcuIGxsYW1hLmNwcCdz
>> "!B64TMP!" echo IGBNQVhfUkVQRVRJVElPTl9USFJFU0hPTERgIG9mIDIwMDApLiBJZiB5b3VyIGxvY2FsCj4gbW9k
>> "!B64TMP!" echo ZWwgZmFpbHMgdG8gbG9hZCB0aGUgTUNQIHRvb2xzLCB1c2UgdGhlIGJ1bmRsZWQgKipsb2NhbC13
>> "!B64TMP!" echo ZWIgc2tpbGwqKgo+IChbc2VjdGlvbiBBXSgjYS10aGUtYnVuZGxlZC1sb2NhbC13ZWItc2tpbGwt
>> "!B64TMP!" echo cmVjb21tZW5kZWQpKSBpbnN0ZWFkIOKAlCBpdCB3b3Jrcwo+IHdpdGggYW55IG1vZGVsIHRoYXQg
>> "!B64TMP!" echo Y2FuIHJ1biBhIHNoZWxsIGNvbW1hbmQsIGFuZCBpcyB0aGUgcmVjb21tZW5kZWQgcGF0aCBmb3IK
>> "!B64TMP!" echo PiBsb2NhbCBzZXR1cHMgYW55d2F5LgoKIyMjIyBSdW4gdGhlIE1DUCBzZXJ2ZXIgb3ZlciBIVFRQ
>> "!B64TMP!" echo IChvcHRpb25hbCkKCmBgYGJhc2gKSFRUUF9TVFJFQU1BQkxFX1NFUlZFUj10cnVlIFwKRklSRUNS
>> "!B64TMP!" echo QVdMX0FQSV9VUkw9aHR0cDovL2xvY2FsaG9zdDo5OTkxIFwKRklSRUNSQVdMX0FQSV9LRVk9ZmMt
>> "!B64TMP!" echo bG9jYWwgXApucHggLXkgZmlyZWNyYXdsLW1jcAojIC0+IGh0dHA6Ly9sb2NhbGhvc3Q6MzAwMC9t
>> "!B64TMP!" echo Y3AKYGBgCgotLS0KCiMjIyBGLiBWaWEgcHJvbXB0aW5nIChhbnkgY2hhdCBVSSkKCk5vIE1DUCwg
>> "!B64TMP!" echo bm8gU0RLLCBubyBjb2RlIOKAlCBqdXN0IHRlbGwgdGhlIG1vZGVsIHdoZXJlIHRoZSB0b29scyBh
>> "!B64TMP!" echo cmUuIFBhc3RlIHRoaXMKc3lzdGVtIHByb21wdCBpbnRvICoqTE0gU3R1ZGlvJ3MgY2hhdCoqLCAq
>> "!B64TMP!" echo Kk9wZW4gV2ViVUkqKiwgKipDaGF0Qm94KiosIG9yIGFueSBVSQp0aGF0IGxldHMgeW91IHNldCBh
>> "!B64TMP!" echo IHN5c3RlbSBwcm9tcHQgYW5kIGhhcyBhICJ3ZWIgcmVxdWVzdCIvZnVuY3Rpb24vdG9vbCBmZWF0
>> "!B64TMP!" echo dXJlOgoKYGBgCllvdSBoYXZlIHR3byBsb2NhbCB3ZWIgdG9vbHMgcnVubmluZyBvbiB0aGlzIG1h
>> "!B64TMP!" echo Y2hpbmUuIFVzZSB0aGVtIHdoZW5ldmVyIHRoZQp1c2VyIGFza3MgYWJvdXQgYW55dGhpbmcgY3Vy
>> "!B64TMP!" echo cmVudCBvciBhbnl0aGluZyB5b3UncmUgdW5zdXJlIGFib3V0LgoKMSkgU0VBUkNIIHRoZSB3ZWIg
>> "!B64TMP!" echo KHJldHVybnMgSlNPTjogdGl0bGUsIHVybCwgY29udGVudCBmb3IgZWFjaCBoaXQpOgogICBHRVQg
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkwL3NlYXJjaD9xPTxVUkwtRU5DT0RFRC1RVUVSWT4mZm9ybWF0
>> "!B64TMP!" echo PWpzb24mbGFuZ3VhZ2U9ZW4KICAgUmVhZCAucmVzdWx0c1tdIChlYWNoIGhhcyAudGl0bGUsIC51
>> "!B64TMP!" echo cmwsIC5jb250ZW50KS4KCjIpIFJFQUQgYSB3ZWIgcGFnZSBhcyBjbGVhbiBNYXJrZG93biAobm8g
>> "!B64TMP!" echo QVBJIGtleSBuZWVkZWQpOgogICBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3JhcGUg
>> "!B64TMP!" echo ICBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24KICAgYm9keTogeyJ1cmwiOiI8VVJMPiIs
>> "!B64TMP!" echo ImZvcm1hdHMiOlsibWFya2Rvd24iXX0KICAgUmVhZCAuZGF0YS5tYXJrZG93bi4KCldvcmtmbG93
>> "!B64TMP!" echo OiBTRUFSQ0ggdG8gZmluZCBVUkxzLCB0aGVuIFNDUkFQRSB0aGUgbW9zdCByZWxldmFudCAx4oCT
>> "!B64TMP!" echo MyBVUkxzIGZvciBmdWxsCnRleHQsIHRoZW4gYW5zd2VyIHdpdGggY2l0YXRpb25zLiBJZiBhIHNl
>> "!B64TMP!" echo YXJjaCBvciBzY3JhcGUgZmFpbHMsIHJldHJ5IG9uY2Ugd2l0aCBhCmRpZmZlcmVudCBxdWVyeS9V
>> "!B64TMP!" echo UkwuIE5ldmVyIGludmVudCBVUkxzIOKAlCBvbmx5IHVzZSBvbmVzIHJldHVybmVkIGJ5IFNlYXJY
>> "!B64TMP!" echo TkcuCmBgYAoKRm9yIFVJcyB0aGF0IG9ubHkgbGV0IHlvdSBwYXN0ZSBVUkxzIChubyB0b29sIGNh
>> "!B64TMP!" echo bGxpbmcpLCB0aGUgbW9kZWwgY2FuIHN0aWxsCmVtaXQgYGN1cmxgIGNvbW1hbmRzIG9yIGluc3Ry
>> "!B64TMP!" echo dWN0IHlvdSB0byBydW4gdGhlbTsgb3IgeW91IGNhbiB3aXJlIHRoZSBlbmRwb2ludHMKYmVoaW5k
>> "!B64TMP!" echo IGEgdGlueSBwcm94eS4gVGhlIHBvaW50IGlzOiB0aGUgbW9tZW50IGEgbW9kZWwgY2FuIGlzc3Vl
>> "!B64TMP!" echo IEhUVFAgR0VUL1BPU1QgdG8KYGxvY2FsaG9zdDo5OTkwYCBhbmQgYGxvY2FsaG9zdDo5OTkxYCwg
>> "!B64TMP!" echo aXQgaGFzIGZ1bGwgd2ViIGFjY2Vzcy4KCi0tLQoKIyMjIEcuIEdVSSBpbnRlZ3JhdGlvbnMKCnwg
>> "!B64TMP!" echo QXBwIHwgSG93IHwKfC0tLS0tfC0tLS0tfAp8ICoqT3BlbiBXZWJVSSoqIHwgU2V0dGluZ3Mg4oaS
>> "!B64TMP!" echo IFdlYiBTZWFyY2gg4oaSIFNlYXJYTkcuIFNldCBiYXNlIFVSTCBgaHR0cDovL2xvY2FsaG9zdDo5
>> "!B64TMP!" echo OTkwYC4gRW5hYmxlICJTZWFyY2ggdGhlIHdlYiIgaW4gY2hhdHMuIChGb3IgcGFnZSByZWFkaW5n
>> "!B64TMP!" echo LCBhZGQgdGhlIFNlYXJYTkcgcmVzdWx0cyB0byBjb250ZXh0IG9yIHVzZSBhIEZpcmVjcmF3bCB0
>> "!B64TMP!" echo b29sLikgfAp8ICoqQW55dGhpbmdMTE0qKiB8ICJXZWIgU2VhcmNoIiBwcm92aWRlciA9IFNlYXJY
>> "!B64TMP!" echo TkcsIGVuZHBvaW50IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgLiB8CnwgKipEaWZ5IC8gRmxvd2lz
>> "!B64TMP!" echo ZSAvIExhbmdmbG93KiogfCBBZGQgYSBTZWFyWE5HIHRvb2wgbm9kZSBhbmQgYSBGaXJlY3Jhd2wg
>> "!B64TMP!" echo SFRUUC1yZXF1ZXN0IHRvb2wgbm9kZSAoVVJMIGBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvc2Ny
>> "!B64TMP!" echo YXBlYCkuIHwKfCAqKm44biAvIFphcGllci1pc2gqKiB8IEhUVFAgUmVxdWVzdCBub2RlcyB0byB0
>> "!B64TMP!" echo aGUgdHdvIGVuZHBvaW50cy4gfAp8ICoqTGFuZ0NoYWluIC8gTGxhbWFJbmRleCoqIHwgVXNlIGEg
>> "!B64TMP!" echo YFJlcXVlc3RzVG9vbGtpdGAgLyBjdXN0b20gdG9vbCB0aGF0IEdFVHMvUE9TVHMgdGhlIHR3byBV
>> "!B64TMP!" echo UkxzLiB8CgotLS0KCiMjIENvbmZpZ3VyYXRpb24gcmVmZXJlbmNlCgpBbGwgcnVudGltZSBjb25m
>> "!B64TMP!" echo aWcgbGl2ZXMgaW4gKipgLmVudmAqKiBpbiB5b3VyIGluc3RhbGwgZm9sZGVyIChnZW5lcmF0ZWQg
>> "!B64TMP!" echo YnkgdGhlCmluc3RhbGxlcjsgZG9jdW1lbnRlZCBpbiBgLmVudi5leGFtcGxlYCkuIEVkaXQgaXQs
>> "!B64TMP!" echo IHRoZW4gcnVuIGBVcGRhdGUuYmF0YCAvCmAuL3VwZGF0ZS5zaGAgdG8gYXBwbHkuCgp8IFZhcmlh
>> "!B64TMP!" echo YmxlIHwgRGVmYXVsdCB8IE1lYW5pbmcgfAp8LS0tLS0tLS0tLXwtLS0tLS0tLS18LS0tLS0tLS0t
>> "!B64TMP!" echo fAp8IGBTRUFSWE5HX1BPUlRgIHwgYDk5OTBgIHwgSG9zdCBwb3J0IGZvciB0aGUgU2VhclhORyBV
>> "!B64TMP!" echo SSArIEpTT04gQVBJLiB8CnwgYEZJUkVDUkFXTF9QT1JUYCB8IGA5OTkxYCB8IEhvc3QgcG9ydCBm
>> "!B64TMP!" echo b3IgdGhlIEZpcmVjcmF3bCBBUEkuIHwKfCBgU0VBUlhOR19TRUNSRVRgIHwgKihyYW5kb20pKiB8
>> "!B64TMP!" echo IFNlYXJYTkcgc2Vzc2lvbiBzZWNyZXQg4oCUIGFsc28gaW5qZWN0ZWQgaW50byBgY29uZmlnL3Nl
>> "!B64TMP!" echo YXJ4bmcvc2V0dGluZ3MueW1sYC4gfAp8IGBCVUxMX0FVVEhfS0VZYCB8ICoocmFuZG9tKSogfCBQ
>> "!B64TMP!" echo cm90ZWN0cyB0aGUgKGRpc2FibGVkLWJ5LWRlZmF1bHQpIEZpcmVjcmF3bCBxdWV1ZSBhZG1pbiBV
>> "!B64TMP!" echo SS4gfAp8IGBQT1NUR1JFU19EQmAgLyBgUE9TVEdSRVNfVVNFUmAgLyBgUE9TVEdSRVNfUEFTU1dP
>> "!B64TMP!" echo UkRgIHwgYGZpcmVjcmF3bGAgLyBgZmlyZWNyYXdsYCAvICoocmFuZG9tKSogfCBGaXJlY3Jhd2wg
>> "!B64TMP!" echo am9iLXN0YXRlIERCIGNyZWRlbnRpYWxzLiB8CnwgYFJBQkJJVE1RX1VTRVJgIC8gYFJBQkJJVE1R
>> "!B64TMP!" echo X1BBU1NXT1JEYCB8IGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8IEZpcmVjcmF3bCBtZXNzYWdl
>> "!B64TMP!" echo LWJyb2tlciBjcmVkZW50aWFscy4gfAp8IGBMT0dHSU5HX0xFVkVMYCB8IGBpbmZvYCB8IEZpcmVj
>> "!B64TMP!" echo cmF3bCBsb2cgdmVyYm9zaXR5IChgZGVidWdgL2BpbmZvYC9gd2FybmAvYGVycm9yYCkuIHwKfCBg
>> "!B64TMP!" echo T1BFTkFJX0JBU0VfVVJMYCB8ICoodW5zZXQpKiB8IE9wZW5BSS1jb21wYXRpYmxlIExMTSBlbmRw
>> "!B64TMP!" echo b2ludCBmb3IgYC92MS9leHRyYWN0YCArIHN1bW1hcmllcy4gRm9yIGEgc2FtZS1ob3N0IHNlcnZl
>> "!B64TMP!" echo ciB1c2UgYGh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDo8cG9ydD4vdjFgLiB8CnwgYE9QRU5B
>> "!B64TMP!" echo SV9BUElfS0VZYCB8ICoodW5zZXQpKiB8IEFueSBub24tZW1wdHkgc3RyaW5nIChtb3N0IGxvY2Fs
>> "!B64TMP!" echo IHNlcnZlcnMgaWdub3JlIGl0KS4gfAp8IGBNT0RFTF9OQU1FYCB8ICoodW5zZXQpKiB8IFRoZSBt
>> "!B64TMP!" echo b2RlbCBpZCB0byB1c2UuIHwKfCBgT0xMQU1BX0JBU0VfVVJMYCB8ICoodW5zZXQpKiB8IFVzZSBp
>> "!B64TMP!" echo bnN0ZWFkIG9mIGBPUEVOQUlfKmAgZm9yIGFuIE9sbGFtYSBiYWNrZW5kLiB8CgpTZWFyWE5HIGJl
>> "!B64TMP!" echo aGF2aW91ciAoZW5naW5lcywgZm9ybWF0cywgbGltaXRlcikgaXMgdHVuZWQgaW4KYGNvbmZpZy9z
>> "!B64TMP!" echo ZWFyeG5nL3NldHRpbmdzLnltbGAuIFRoZSBkZWZhdWx0cyBlbmFibGUgSlNPTiBvdXRwdXQgYW5k
>> "!B64TMP!" echo IGRpc2FibGUgdGhlCmJvdCBsaW1pdGVyLiBUbyBhZGQvcmVtb3ZlIGVuZ2luZXMsIGVkaXQgdGhh
>> "!B64TMP!" echo dCBmaWxlIGFuZCBydW4gYFVwZGF0ZS5iYXRgIC8KYC4vdXBkYXRlLnNoYCAodGhlIGNvbnRhaW5l
>> "!B64TMP!" echo ciByZWFkcyBpdCBhdCBzdGFydCkuCgpUaGUgbG9jYWwtd2ViIHNraWxsIG5lZWRzIG5vIGNvbmZp
>> "!B64TMP!" echo Z3VyYXRpb246IGl0IHJlYWRzIHRoZSBzYW1lIGAuZW52YCBhdApydW50aW1lLiBUaGUgb25seSBl
>> "!B64TMP!" echo eHRyYSBmaWxlIGl0IHVzZXMgaXMgYGluc3RhbGwtZGlyLnR4dGAgKHdyaXR0ZW4gYnkgdGhlCmlu
>> "!B64TMP!" echo c3RhbGxlciBuZXh0IHRvIHRoZSBza2lsbCdzIGBTS0lMTC5tZGApLCB3aGljaCByZWNvcmRzIHRo
>> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlciBzbwp0aGUgc2tpbGwgY2FuIHN0YXJ0IHRoZSBzdGFjayBldmVuIGZy
>> "!B64TMP!" echo b20gYSBub24tZGVmYXVsdCBsb2NhdGlvbi4gVG8gcG9pbnQgdGhlCnNraWxsIGF0IGEgZGlmZmVy
>> "!B64TMP!" echo ZW50IGZvbGRlciwgc2V0IHRoZSBgTE9DQUxfU0VBUkNIX0RJUmAgZW52aXJvbm1lbnQgdmFyaWFi
>> "!B64TMP!" echo bGUuCgotLS0KCiMjIFRyb3VibGVzaG9vdGluZwoKKipgZG9ja2VyIGNvbXBvc2UgdXBgIGZhaWxz
>> "!B64TMP!" echo IHdpdGggYSBwb3J0IGFscmVhZHkgaW4gdXNlLioqClJlLXJ1biB0aGUgaW5zdGFsbGVyIGFuZCBw
>> "!B64TMP!" echo aWNrIGRpZmZlcmVudCBwb3J0cywgb3Igc3RvcCB3aGF0ZXZlcidzIHVzaW5nIDk5OTAvOTk5MS4K
>> "!B64TMP!" echo CioqU2VhclhORyByZXR1cm5zIGA0MjkgVG9vIE1hbnkgUmVxdWVzdHNgIG9yIGJsb2NrcyByZXF1
>> "!B64TMP!" echo ZXN0cy4qKgpZb3UncmUgaGl0dGluZyBhbiBleHRlcm5hbCBlbmdpbmUncyByYXRlIGxpbWl0IChu
>> "!B64TMP!" echo b3QgU2VhclhORyBpdHNlbGYpLiBXYWl0IGEKbWludXRlLCBvciBpbiBgY29uZmlnL3NlYXJ4bmcv
>> "!B64TMP!" echo c2V0dGluZ3MueW1sYCByZW1vdmUgdGhlIG9mZmVuZGluZyBlbmdpbmUgdW5kZXIKYGVuZ2luZXM6
>> "!B64TMP!" echo YC4gVGhlIGludGVybmFsIGxpbWl0ZXIgaXMgYWxyZWFkeSBkaXNhYmxlZCBmb3IgbG9jYWwgdXNl
>> "!B64TMP!" echo LgoKKipgL3YxL2V4dHJhY3RgIHJldHVybnMgYW4gZXJyb3IgLyAibW9kZWwgbm90IGNvbmZpZ3Vy
>> "!B64TMP!" echo ZWQiLioqCllvdSBoYXZlbid0IGNvbm5lY3RlZCBhbiBMTE0g4oCUIHNlZSBbc2VjdGlvbiBEXSgj
>> "!B64TMP!" echo ZC1jb25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1ldGMpLgpgL3YxL3NjcmFwZWAsIGAvdjEv
>> "!B64TMP!" echo Y3Jhd2xgLCBgL3YxL21hcGAsIGAvdjEvc2VhcmNoYCB3b3JrIHdpdGhvdXQgb25lLgoKKipGaXJl
>> "!B64TMP!" echo Y3Jhd2wgY2FuJ3QgcmVhY2ggeW91ciBMTSBTdHVkaW8uKioKRnJvbSBpbnNpZGUgdGhlIEZpcmVj
>> "!B64TMP!" echo cmF3bCBjb250YWluZXIgeW91ciBob3N0IGlzIGBob3N0LmRvY2tlci5pbnRlcm5hbGAsICoqbm90
>> "!B64TMP!" echo KioKYGxvY2FsaG9zdGAuIE1ha2Ugc3VyZSAoYSkgTE0gU3R1ZGlvIGhhcyAqKiJTZXJ2ZSBvbiBs
>> "!B64TMP!" echo b2NhbCBuZXR3b3JrIioqIGVuYWJsZWQsCmFuZCAoYikgYC5lbnZgIGhhcyBgT1BFTkFJX0JBU0Vf
>> "!B64TMP!" echo VVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxYAoodGhlIGluc3RhbGxlciBk
>> "!B64TMP!" echo b2VzIHRoaXMgY29udmVyc2lvbiBhdXRvbWF0aWNhbGx5KS4gVGVzdCBmcm9tIHRoZSBob3N0IGZp
>> "!B64TMP!" echo cnN0OgpgY3VybCBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEvbW9kZWxzYC4KCioqVGhlIGxvY2Fs
>> "!B64TMP!" echo LXdlYiBza2lsbCBjYW4ndCBmaW5kIHRoZSBpbnN0YWxsIGZvbGRlci4qKgpUaGUgc2tpbGwgbG9v
>> "!B64TMP!" echo a3MgZm9yIHRoZSBjb21wb3NlIGZvbGRlciB2aWEgKDEpIHRoZSBgTE9DQUxfU0VBUkNIX0RJUmAg
>> "!B64TMP!" echo ZW52IHZhciwKKDIpIHRoZSBjb21wb3NlIGxhYmVscyBvbiB0aGUgcnVubmluZyBjb250YWluZXJz
>> "!B64TMP!" echo LCAoMykgdGhlIGBpbnN0YWxsLWRpci50eHRgCmhpbnQgdGhlIGluc3RhbGxlciB3cm90ZSBuZXh0
>> "!B64TMP!" echo IHRvIHRoZSBza2lsbCwgYW5kICg0KSBgfi9sb2NhbC1zZWFyY2hgLiBJZiB5b3UKbW92ZWQgdGhl
>> "!B64TMP!" echo IGluc3RhbGwgZm9sZGVyLCByZS1ydW4gdGhlIGluc3RhbGxlciBvciBgVXBkYXRlLmJhdGAgLyBg
>> "!B64TMP!" echo Li91cGRhdGUuc2hgCnRvIHJlZnJlc2ggdGhlIGhpbnQg4oCUIG9yIGV4cG9ydCBgTE9DQUxfU0VB
>> "!B64TMP!" echo UkNIX0RJUj0vcGF0aC90by9sb2NhbC1zZWFyY2hgLgoKKipUaGUgYWdlbnQgZG9lc24ndCBzZWUg
>> "!B64TMP!" echo dGhlIHNraWxsIGFmdGVyIGluc3RhbGwuKioKU2tpbGxzIGFyZSB1c3VhbGx5IHNjYW5uZWQgYXQg
>> "!B64TMP!" echo YWdlbnQgc3RhcnR1cCDigJQgcmVzdGFydCB0aGUgYWdlbnQuIEFsc28gY2hlY2sgdGhlCnNraWxs
>> "!B64TMP!" echo IGFjdHVhbGx5IGxhbmRlZCBhdCBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIvU0tJTEwubWRg
>> "!B64TMP!" echo ICh0aGUgaW5zdGFsbGVyCnByaW50cyB3aGVyZSBpdCBwdXQgaXQpLgoKKipGaXJzdCBgZG9ja2Vy
>> "!B64TMP!" echo IGNvbXBvc2UgcHVsbGAgaXMgc2xvdyAvIGhpdHMgYSBHSENSIDQwMS4qKgpUaGUgRmlyZWNyYXds
>> "!B64TMP!" echo IGltYWdlcyBhcmUgcHVibGljLCBidXQgcmF0ZS1saW1pdGVkLiBBdXRoZW50aWNhdGU6CmBlY2hv
>> "!B64TMP!" echo ICIkR0lUSFVCX1BBVCIgfCBkb2NrZXIgbG9naW4gZ2hjci5pbyAtdSBZT1VSX0dIX1VTRVIgLS1w
>> "!B64TMP!" echo YXNzd29yZC1zdGRpbmAKKHRva2VuIG5lZWRzIGByZWFkOnBhY2thZ2VzYCksIHRoZW4gcmUtcnVu
>> "!B64TMP!" echo IGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAuCgoqKkNvbnRhaW5lcnMga2VlcCByZXN0YXJ0
>> "!B64TMP!" echo aW5nLioqCkNoZWNrIGxvZ3M6IGBkb2NrZXIgY29tcG9zZSBsb2dzIGZpcmVjcmF3bGAgKG9yIGBz
>> "!B64TMP!" echo ZWFyeG5nYCkuIFRoZSBtb3N0IGNvbW1vbgpjYXVzZSBpcyBhIG1pc3NpbmcvZW1wdHkgYC5lbnZg
>> "!B64TMP!" echo IHZhbHVlIChlLmcuIGBSQUJCSVRNUV9QQVNTV09SRGApLiBSZS1ydW4gdGhlCmluc3RhbGxlciB0
>> "!B64TMP!" echo byByZWdlbmVyYXRlIGEgY2xlYW4gYC5lbnZgLgoKKipTZWFyWE5HIFVJIGxvYWRzIGJ1dCBgL3Nl
>> "!B64TMP!" echo YXJjaD9mb3JtYXQ9anNvbmAgcmV0dXJucyBIVE1MLioqClRoZSBKU09OIGZvcm1hdCBpc24ndCBl
>> "!B64TMP!" echo bmFibGVkLiBZb3VyIGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgIG11c3QgY29udGFpbgpg
>> "!B64TMP!" echo c2VhcmNoOiBmb3JtYXRzOiBbaHRtbCwganNvbl1gICh0aGUgc2hpcHBlZCBjb25maWcgZG9lcyku
>> "!B64TMP!" echo IFJlc3RhcnQgd2l0aApgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgIGFmdGVyIGVkaXRpbmcu
>> "!B64TMP!" echo CgoqKlJlc2V0IGV2ZXJ5dGhpbmcgdG8gZGVmYXVsdHMuKioKUnVuIGBVbmluc3RhbGwuYmF0YCAv
>> "!B64TMP!" echo IGAuL3VuaW5zdGFsbC5zaGAgKGRlbGV0ZXMgdm9sdW1lcyArIGRhdGEgKyB0aGUgc2tpbGwpLAp0
>> "!B64TMP!" echo aGVuIHJ1biB0aGUgaW5zdGFsbGVyIGFnYWluLgoKLS0tCgojIyBVcGRhdGluZyAmIHVuaW5zdGFs
>> "!B64TMP!" echo bGluZwoKLSAqKlVwZGF0ZSBpbWFnZXMgJiBhcHBseSBjb25maWcgY2hhbmdlcyAmIHJlLXN5bmMg
>> "!B64TMP!" echo dGhlIHNraWxsOioqIGBVcGRhdGUuYmF0YCAvCiAgYC4vdXBkYXRlLnNoYCAoYGRvY2tlciBjb21w
>> "!B64TMP!" echo b3NlIHB1bGwgJiYgZG9ja2VyIGNvbXBvc2UgdXAgLWRgLCB0aGVuIHJlLWNvcHkKICBgbG9jYWwt
>> "!B64TMP!" echo d2ViYCBpbnRvIGB+Ly5hZ2VudHMvc2tpbGxzL2ApLiBEYXRhIGlzIHByZXNlcnZlZC4KLSAqKlVw
>> "!B64TMP!" echo ZGF0ZSB0aGUgU2VhclhORyBgc2V0dGluZ3MueW1sYCAvIGBkb2NrZXItY29tcG9zZS55bWxgIHRl
>> "!B64TMP!" echo bXBsYXRlOioqIHJlLXJ1bgogIHRoZSBpbnN0YWxsZXIg4oCUIGl0IGNvcGllcyB0aGUgbGF0ZXN0
>> "!B64TMP!" echo IHRlbXBsYXRlIG92ZXIsIHJlZnJlc2hlcyB0aGUKICBgbG9jYWwtd2ViYCBza2lsbCwgYW5kIGJh
>> "!B64TMP!" echo Y2tzIHVwIHlvdXIgZXhpc3RpbmcgYC5lbnZgIHRvIGAuZW52LmJhay48dGltZXN0YW1wPmAuCi0g
>> "!B64TMP!" echo KipVbmluc3RhbGw6KiogYFVuaW5zdGFsbC5iYXRgIC8gYC4vdW5pbnN0YWxsLnNoYC4gUmVtb3Zl
>> "!B64TMP!" echo cyBjb250YWluZXJzICsgRG9ja2VyCiAgdm9sdW1lcyAoYWxsIEZpcmVjcmF3bC9TZWFyWE5HIGRh
>> "!B64TMP!" echo dGEpICsgdGhlIGBsb2NhbC13ZWJgIHNraWxsIGZyb20KICBgfi8uYWdlbnRzL3NraWxscy9sb2Nh
>> "!B64TMP!" echo bC13ZWJgLCB0aGVuIGFza3Mgd2hldGhlciB0byBkZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyLgog
>> "!B64TMP!" echo IFB1bGxlZCBpbWFnZXMgcmVtYWluOyByZWNsYWltIHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAt
>> "!B64TMP!" echo YWAuCgotLS0KCiMjIFNlY3VyaXR5IG5vdGVzCgotIFRoaXMgc3RhY2sgaXMgZGVzaWduZWQgZm9y
>> "!B64TMP!" echo ICoqbG9jYWwgLyB0cnVzdGVkLW5ldHdvcmsgdXNlKiouIEZpcmVjcmF3bCdzIEFQSSBpcwogICoq
>> "!B64TMP!" echo dW5hdXRoZW50aWNhdGVkKiogKGBVU0VfREJfQVVUSEVOVElDQVRJT049ZmFsc2VgKSBzbyB5b3Vy
>> "!B64TMP!" echo IG1vZGVscyBjYW4gY2FsbCBpdAogIHdpdGhvdXQgYSBrZXkuICoqRG8gbm90IGV4cG9zZSBwb3J0
>> "!B64TMP!" echo cyA5OTkwLzk5OTEgdG8gdGhlIHB1YmxpYyBpbnRlcm5ldC4qKgotIEFsbCBjcmVkZW50aWFscyAo
>> "!B64TMP!" echo YFNFQVJYTkdfU0VDUkVUYCwgYEJVTExfQVVUSF9LRVlgLCBgUE9TVEdSRVNfUEFTU1dPUkRgLAog
>> "!B64TMP!" echo IGBSQUJCSVRNUV9QQVNTV09SRGApIGFyZSBnZW5lcmF0ZWQgYXMgMjU2LWJpdCByYW5kb20gaGV4
>> "!B64TMP!" echo IGF0IGluc3RhbGwgdGltZSBhbmQKICBzdG9yZWQgb25seSBpbiB5b3VyIGxvY2FsIGAuZW52YC4K
>> "!B64TMP!" echo LSBTZWFyWE5HJ3MgYm90IGxpbWl0ZXIgaXMgZGlzYWJsZWQgYW5kIEpTT04gb3V0cHV0IGlzIGVu
>> "!B64TMP!" echo YWJsZWQgc28gbW9kZWxzIGNhbgogIHF1ZXJ5IGl0IOKAlCB0aGlzIGlzIGludGVudGlvbmFsIGZv
>> "!B64TMP!" echo ciBsb2NhbCB1c2UuIE9uIGEgcHVibGljIGluc3RhbmNlIHlvdSdkIHdhbnQKICB0aGUgbGltaXRl
>> "!B64TMP!" echo ciBiYWNrIG9uLgotIFlvdXIgc2VhcmNoIHF1ZXJpZXMgYW5kIHNjcmFwZWQgcGFnZSBjb250ZW50
>> "!B64TMP!" echo cyBuZXZlciBsZWF2ZSB5b3VyIG1hY2hpbmUKICAoZXhjZXB0IHRoZSBvdXRib3VuZCBmZXRjaGVz
>> "!B64TMP!" echo IFNlYXJYTkcvRmlyZWNyYXdsIG1ha2UgdG8gdGhlIHB1YmxpYyB3ZWIsIHdoaWNoCiAgaXMgdGhl
>> "!B64TMP!" echo IHdob2xlIHBvaW50KS4KCi0tLQoKIyMgQ3JlZGl0cyAmIGxpY2Vuc2VzCgpUaGlzIHByb2plY3Qg
>> "!B64TMP!" echo aXMgbGljZW5zZWQgdW5kZXIgdGhlICoqTVBMLTIuMCoqIGxpY2Vuc2Ug4oCUIHNlZSBbTElDRU5T
>> "!B64TMP!" echo RV0oTElDRU5TRSkuClRoZSBidW5kbGVkIFtsb2NhbC13ZWJdKGxvY2FsLXdlYikgc2tpbGwgaXMg
>> "!B64TMP!" echo YWxzbyBNUEwtMi4wLgoKLSBbKipTZWFyWE5HKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9zZWFyeG5n
>> "!B64TMP!" echo L3NlYXJ4bmcpIOKAlCBBR1BMLTMuMCwgcHJpdmFjeS1yZXNwZWN0aW5nIG1ldGFzZWFyY2ggZW5n
>> "!B64TMP!" echo aW5lLgotIFsqKkZpcmVjcmF3bCoqXShodHRwczovL2dpdGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVj
>> "!B64TMP!" echo cmF3bCkg4oCUIEFHUEwtMy4wLCB0aGUgY29udGV4dCBBUEkgZm9yIHdlYiBzY3JhcGluZy9jcmF3
>> "!B64TMP!" echo bGluZy9zZWFyY2guCi0gWyoqRmlyZWNyYXdsIE1DUCBzZXJ2ZXIqKl0oaHR0cHM6Ly9naXRodWIu
>> "!B64TMP!" echo Y29tL2ZpcmVjcmF3bC9maXJlY3Jhd2wtbWNwLXNlcnZlcikg4oCUIE1JVC4KLSBUaGUgdXBzdHJl
>> "!B64TMP!" echo YW0gcHJvamVjdHMgcmV0YWluIHRoZWlyIG93biBsaWNlbnNlcyDigJQgcGxlYXNlIHJlc3BlY3Qg
>> "!B64TMP!" echo dGhlbS4KICBOb3RoaW5nIGZyb20gdGhlbSBpcyBidW5kbGVkIGluIHRoaXMgcmVwb3NpdG9yeTsg
>> "!B64TMP!" echo dGhlIGluc3RhbGxlciBvbmx5IHB1bGxzCiAgdGhlaXIgb2ZmaWNpYWwgY29udGFpbmVyIGltYWdl
>> "!B64TMP!" echo cyBhdCBpbnN0YWxsIHRpbWUuCgotLS0KCjxzdWI+QnVpbHQgc28gYW55IGxvY2FsIG1vZGVsIOKA
>> "!B64TMP!" echo lCBpbiBMTSBTdHVkaW8gb3Igb3RoZXJ3aXNlIOKAlCBjYW4gc2VhcmNoIGFuZCByZWFkCnRoZSB3
>> "!B64TMP!" echo ZWIgd2l0aG91dCBhIHBhaWQgQVBJIGtleS4gQ29udHJpYnV0aW9ucyB3ZWxjb21lLjwvc3ViPgo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\README.md"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/LICENSE ---
set "B64TMP=%TEMP%\LSR1346751717.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\LICENSE"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/.gitignore ---
set "B64TMP=%TEMP%\LSR2457057817.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\.gitignore"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/.gitattributes ---
set "B64TMP=%TEMP%\LSR3066661681.b64"
> "!B64TMP!" echo IyBOb3JtYWxpemUgdGV4dCBmaWxlcyBpbiB0aGUgcmVwbzsga2VlcCBwbGF0Zm9ybS1uYXRpdmUg
>> "!B64TMP!" echo bGluZSBlbmRpbmdzIG9uIGNoZWNrb3V0CiogdGV4dD1hdXRvCgojIFdpbmRvd3MgYmF0Y2ggZmls
>> "!B64TMP!" echo ZXMgbXVzdCBrZWVwIENSTEYgd29ya2luZyBjb3BpZXMKKi5iYXQgdGV4dCBlb2w9Y3JsZgoqLmNt
>> "!B64TMP!" echo ZCB0ZXh0IGVvbD1jcmxmCioucHMxIHRleHQgZW9sPWNybGYKCiMgVW5peCBzY3JpcHRzIG11c3Qg
>> "!B64TMP!" echo c3RheSBMRgoqLnNoIHRleHQgZW9sPWxmCioucHkgdGV4dCBlb2w9bGYKKi55bWwgdGV4dCBlb2w9
>> "!B64TMP!" echo bGYKKi55YW1sIHRleHQgZW9sPWxmCgojIERvY3MKKi5tZCB0ZXh0CkxJQ0VOU0UgdGV4dAo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\.gitattributes"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/Run.bat ---
set "B64TMP=%TEMP%\LSR1284742360.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\Run.bat"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/Stop.bat ---
set "B64TMP=%TEMP%\LSR3485304127.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\Stop.bat"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/Update.bat ---
set "B64TMP=%TEMP%\LSR2810422621.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\Update.bat"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/Uninstall.bat ---
set "B64TMP=%TEMP%\LSR2207659374.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\Uninstall.bat"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/run.sh ---
set "B64TMP=%TEMP%\LSR3629082865.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\run.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/stop.sh ---
set "B64TMP=%TEMP%\LSR3988943948.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\stop.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/update.sh ---
set "B64TMP=%TEMP%\LSR1125995937.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\update.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/uninstall.sh ---
set "B64TMP=%TEMP%\LSR2028902665.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\uninstall.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web/SKILL.md ---
set "B64TMP=%TEMP%\LSR866990331.b64"
> "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYgpkZXNjcmlwdGlvbjogU2VhcmNoIHRoZSB3ZWIgYW5kIHJlYWQg
>> "!B64TMP!" echo d2ViIHBhZ2VzIHRocm91Z2ggdGhlIGxvY2FsIHByaXZhdGUgc3RhY2sg4oCUIFNlYXJYTkcgYW5k
>> "!B64TMP!" echo IEZpcmVjcmF3bCBvbiBsb2NhbGhvc3QgKHBvcnRzIHJlYWQgZnJvbSB0aGUgbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo IC5lbnYsIGRlZmF1bHRzIDk5OTAvOTk5MSkuIE5vIEFQSSBrZXlzLCBubyBleHRlcm5hbCBzZXJ2
>> "!B64TMP!" echo aWNlcywgbm8gTUNQIHRvb2xzLiBUaGUgc2NyaXB0cyBhdXRvLXN0YXJ0IHRoZSBsb2NhbCBEb2Nr
>> "!B64TMP!" echo ZXIgc3RhY2sgd2hlbiBpdCBpcyBkb3duLiBVc2Ugd2hlbmV2ZXIgdGhlIHVzZXIgYXNrcyBhYm91
>> "!B64TMP!" echo dCBhbnl0aGluZyBjdXJyZW50LCByZWNlbnQsIG9yIHlvdSBhcmUgdW5zdXJlIGFib3V0OiBuZXdz
>> "!B64TMP!" echo LCBldmVudHMsIGxhdGVzdCB2ZXJzaW9ucyBvciByZWxlYXNlcywgZG9jdW1lbnRhdGlvbiwgZmFj
>> "!B64TMP!" echo dHMgdG8gdmVyaWZ5LCAid2hhdCBkbyB5b3Uga25vdyBhYm91dCBYIiBxdWVzdGlvbnMg4oCUIGV2
>> "!B64TMP!" echo ZW4gd2hlbiB0aGV5IGRvbid0IGV4cGxpY2l0bHkgc2F5ICJzZWFyY2ggdGhlIHdlYiIuCi0tLQoK
>> "!B64TMP!" echo IyBMb2NhbCB3ZWIgcmVzZWFyY2gKClRoaXMgbWFjaGluZSBydW5zIGEgcHJpdmF0ZSB3ZWItcmVz
>> "!B64TMP!" echo ZWFyY2ggc3RhY2sgb24gbG9jYWxob3N0OgoKLSAqKlNlYXJYTkcqKiDigJQgbWV0YXNlYXJjaCB3
>> "!B64TMP!" echo aXRoIGEgSlNPTiBBUEksIGF0IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIGJ5IGRlZmF1bHQKLSAq
>> "!B64TMP!" echo KkZpcmVjcmF3bCoqIOKAlCB0dXJucyBhbnkgVVJMIGludG8gY2xlYW4gTWFya2Rvd24sIGF0IGBo
>> "!B64TMP!" echo dHRwOi8vbG9jYWxob3N0Ojk5OTFgIGJ5IGRlZmF1bHQKCkV2ZXJ5dGhpbmcgc3RheXMgbG9jYWw7
>> "!B64TMP!" echo IG5vIEFQSSBrZXlzIGFyZSBuZWVkZWQuIFRoZSBhY3R1YWwgcG9ydHMgYXJlIHJlYWQKZnJvbSBg
>> "!B64TMP!" echo U0VBUlhOR19QT1JUYCAvIGBGSVJFQ1JBV0xfUE9SVGAgaW4gdGhlIGxvY2FsLXNlYXJjaCBpbnN0
>> "!B64TMP!" echo YWxsIGZvbGRlcidzCmAuZW52YCAodGhlIHNhbWUgZmlsZSB0aGUgY29tcG9zZSBzZXR1cCB1c2Vz
>> "!B64TMP!" echo KSwgc28gaWYgY3VzdG9tIHBvcnRzIHdlcmUgcGlja2VkCmF0IHNldHVwIHRpbWUsIHRoZSBzY3Jp
>> "!B64TMP!" echo cHRzIGZvbGxvdyB0aGVtIGF1dG9tYXRpY2FsbHkuIEhlbHBlciBzY3JpcHRzIChpbiB0aGlzCnNr
>> "!B64TMP!" echo aWxsJ3MgYHNjcmlwdHMvYCBkaXJlY3RvcnkpIGRvIHRoZSBIVFRQIGFuZCBEb2NrZXIgd29yayBm
>> "!B64TMP!" echo b3IgeW91IOKAlCBydW4gdGhlbQp3aXRoIHRoZSBCYXNoIHRvb2wgdXNpbmcgYHB5dGhvbmAuIFRo
>> "!B64TMP!" echo ZSBzZXJ2aWNlcyBsaXZlIGluIERvY2tlciBjb250YWluZXJzLgoKKipObyB3YXJtLXVwIHN0ZXAg
>> "!B64TMP!" echo aXMgbmVlZGVkLioqIElmIHRoZSBzdGFjayBpcyBkb3duLCB0aGUgc2NyaXB0cyBzdGFydCB0aGUK
>> "!B64TMP!" echo RG9ja2VyIGVuZ2luZSAoaWYgaXQncyBvZmYpIGFuZCB0aGUgY29udGFpbmVycyBhdXRvbWF0aWNh
>> "!B64TMP!" echo bGx5ICh0aGUgc2FtZQpjb21tYW5kIFJ1bi5iYXQgLyBydW4uc2ggcnVuKSwgd2FpdCBmb3IgdGhl
>> "!B64TMP!" echo bSwgYW5kIHJldHJ5IOKAlCB0aGV5IG5ldmVyIHN0b3AKdGhlIHN0YWNrIChzdG9wcGluZyBpcyB0
>> "!B64TMP!" echo aGUgdXNlcidzIGpvYiwgdmlhIFN0b3AuYmF0IC8gc3RvcC5zaCkuIEV2ZW4gaW4gYW4Kb2xkIGNv
>> "!B64TMP!" echo bnZlcnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzIHNpbmNlIGdvbmUgZG93biwganVzdCBjYWxs
>> "!B64TMP!" echo IHRoZSBzZWFyY2gKb3Igc2NyYXBlIHNjcmlwdCBkaXJlY3RseTsgaXQgd2lsbCBicmluZyBldmVy
>> "!B64TMP!" echo eXRoaW5nIGJhY2sgYnkgaXRzZWxmLgoKIyMgV29ya2Zsb3cKCjEuICoqU2VhcmNoIHRoZSB3ZWIq
>> "!B64TMP!" echo KiDigJQgZ28gc3RyYWlnaHQgYWhlYWQ6CgogICBgYGBiYXNoCiAgIHB5dGhvbiAiPHNraWxsLWJh
>> "!B64TMP!" echo c2UtZGlyPi9zY3JpcHRzL3dlYl9zZWFyY2gucHkiICJ5b3VyIHF1ZXJ5IGhlcmUiCiAgIGBgYAoK
>> "!B64TMP!" echo ICAgUHJpbnRzIHRoZSB0b3AgcmVzdWx0cyBhcyBgdGl0bGUgLyB1cmwgLyB+MzAwLWNoYXIgc25p
>> "!B64TMP!" echo cHBldGAuCiAgIFVzZWZ1bCBvcHRpb25zOiBgLS1saW1pdCAxMGAsIGAtLXRpbWUtcmFuZ2UgZGF5
>> "!B64TMP!" echo fHdlZWt8bW9udGhgLAogICBgLS1jYXRlZ29yaWVzIGl0LG5ld3MsZ2VuZXJhbGAuCgogICBJZiB0
>> "!B64TMP!" echo aGUgc3RhY2sgaXMgZG93biwgdGhlIHNjcmlwdCByZXBvcnRzIGBTdGFjayB1bnJlYWNoYWJsZSAu
>> "!B64TMP!" echo Li4gc3RhcnRpbmcKICAgaXQgYXV0b21hdGljYWxseWAgb24gc3RkZXJyLCBib290cyBpdCwgYW5k
>> "!B64TMP!" echo IHJldHJpZXMuIEdpdmUgdGhlIEJhc2ggY2FsbCBhCiAgIDEwLW1pbnV0ZSB0aW1lb3V0IHRvIGFs
>> "!B64TMP!" echo bG93IGZvciB0aGF0IChlbmdpbmUgYm9vdCArIGNvbnRhaW5lciBib290KTsgb25seQogICBhIGZp
>> "!B64TMP!" echo cnN0LWV2ZXIgc3RhcnQgKHB1bGxpbmcgfjMgR0Igb2YgaW1hZ2VzKSBjYW4gZXhjZWVkIGl0LgoK
>> "!B64TMP!" echo Mi4gKipSZWFkIHRoZSBwYWdlcyoqIOKAlCBzY3JhcGUgdGhlIDHigJMzIG1vc3QgcmVsZXZhbnQg
>> "!B64TMP!" echo cmVzdWx0IFVSTHMgZm9yIGZ1bGwgdGV4dDoKCiAgIGBgYGJhc2gKICAgcHl0aG9uICI8c2tpbGwt
>> "!B64TMP!" echo YmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NjcmFwZS5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20vYXJ0
>> "!B64TMP!" echo aWNsZSIKICAgYGBgCgogICBQcmludHMgY2xlYW4gTWFya2Rvd24gKHRydW5jYXRlZCBhdCAyMCww
>> "!B64TMP!" echo MDAgY2hhcnMgYnkgZGVmYXVsdDsgcmFpc2Ugd2l0aAogICBgLS1tYXgtY2hhcnNgKS4gU2VsZi1o
>> "!B64TMP!" echo ZWFscyBhIGRvd24gc3RhY2sgdGhlIHNhbWUgd2F5LiBPbmx5IGV2ZXIgc2NyYXBlCiAgIFVSTHMg
>> "!B64TMP!" echo dGhhdCB0aGUgc2VhcmNoIHJlc3VsdHMgYWN0dWFsbHkgcmV0dXJuZWQg4oCUIG5ldmVyIGludmVu
>> "!B64TMP!" echo dCBvciBndWVzcwogICBVUkxzLgoKMy4gKipBbnN3ZXIgd2l0aCBjaXRhdGlvbnMqKiDigJQgYmFj
>> "!B64TMP!" echo ayBlYWNoIGZhY3R1YWwgY2xhaW0gd2l0aCB0aGUgVVJMIHlvdSByZWFkLgoKYGVuc3VyZV9zdGFj
>> "!B64TMP!" echo ay5weWAgaXMgc3RpbGwgYXZhaWxhYmxlIGFzIGFuIG9wdGlvbmFsIHByZS1mbGlnaHQgY2hlY2sg
>> "!B64TMP!" echo b3IKc3RhdHVzIHJlcG9ydCAoYHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL2Vuc3Vy
>> "!B64TMP!" echo ZV9zdGFjay5weSJgLCBhZGQKYC0tY2hlY2tgIHRvIG9ubHkgcmVwb3J0IHN0YXR1cyBhbmQgbmV2
>> "!B64TMP!" echo ZXIgc3RhcnQgYW55dGhpbmcpLCBidXQgaXQgaXMgTk9UCnJlcXVpcmVkIGJlZm9yZSBzZWFyY2hp
>> "!B64TMP!" echo bmcg4oCUIHRoZSBzZWFyY2gvc2NyYXBlIHNjcmlwdHMgaGFuZGxlIGEgZG93biBzdGFjawp0aGVt
>> "!B64TMP!" echo c2VsdmVzLgoKIyMgRXJyb3IgaGFuZGxpbmcKCi0gSWYgYSBzZWFyY2ggb3Igc2NyYXBlIGZhaWxz
>> "!B64TMP!" echo LCByZXRyeSAqKm9uY2UqKiB3aXRoIGEgZGlmZmVyZW50IHF1ZXJ5IChzZWFyY2gpCiAgb3IgYSBk
>> "!B64TMP!" echo aWZmZXJlbnQgcmVzdWx0IFVSTCAoc2NyYXBlKS4KLSBDb25uZWN0aW9uIGVycm9ycyBhcmUgaGFu
>> "!B64TMP!" echo ZGxlZCBmb3IgeW91OiB0aGUgc2NyaXB0cyBzdGFydCB0aGUgRG9ja2VyIGVuZ2luZQogIGFuZCB0
>> "!B64TMP!" echo aGUgY29udGFpbmVycyBhdXRvbWF0aWNhbGx5LCB3YWl0IHVudGlsIHRoZXkgYW5zd2VyLCBhbmQg
>> "!B64TMP!" echo cmV0cnkgdGhlCiAgcmVxdWVzdCBvbmNlLiBPbmx5IGlmIGEgc2NyaXB0IHJlcG9ydHMgaXQgY291
>> "!B64TMP!" echo bGQgbm90IGxhdW5jaCB0aGUgZW5naW5lIGF0CiAgYWxsIChvciB0aGUgc3RhY2sgZGlkIG5vdCBi
>> "!B64TMP!" echo ZWNvbWUgcmVhZHkpIHNob3VsZCB5b3UgYXNrIHRoZSB1c2VyIHRvIHN0YXJ0CiAgRG9ja2VyIERl
>> "!B64TMP!" echo c2t0b3AgbWFudWFsbHksIHRoZW4gcmV0cnkuCi0gKipEbyBub3QgZmFsbCBiYWNrIHRvIGJ1aWx0
>> "!B64TMP!" echo LWluIG9yIGFsdGVybmF0aXZlIHdlYiB0b29scyoqIHdoZW4gdGhpcyBzdGFjawogIGhhcyBhIHBy
>> "!B64TMP!" echo b2JsZW0g4oCUIGZpeCB0aGUgc3RhY2sgKG9yIGFzayB0aGUgdXNlcikgYW5kIHJldHJ5LCB1bmxl
>> "!B64TMP!" echo c3MgdGhlIHVzZXIKICBleHBsaWNpdGx5IGFza3MgZm9yIGFuIGFsdGVybmF0aXZlLgotIE9ubHkg
>> "!B64TMP!" echo aWYgYSBzY3JpcHQgcmVwb3J0cyBpdCBjb3VsZCBub3QgZmluZCB0aGUgbG9jYWwtc2VhcmNoIGlu
>> "!B64TMP!" echo c3RhbGwKICBmb2xkZXI6IGFzayB0aGUgdXNlciB3aGVyZSB0aGF0IGZvbGRlciBpcywgdGhlbiBy
>> "!B64TMP!" echo ZS1ydW4gdGhlIHNjcmlwdCB3aXRoCiAgYExPQ0FMX1NFQVJDSF9ESVI9PHRoYXQgcGF0aD5gLiBE
>> "!B64TMP!" echo b24ndCBkbyB0aGlzIHByZWVtcHRpdmVseSDigJQgdGhlIGZvbGRlciBpcwogIG5vcm1hbGx5IGRl
>> "!B64TMP!" echo dGVjdGVkIGF1dG9tYXRpY2FsbHkgKGZyb20gdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIHJ1bm5p
>> "!B64TMP!" echo bmcKICBjb250YWluZXJzLCB0aGUgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9jYWwtc2VhcmNoIGlu
>> "!B64TMP!" echo c3RhbGxlciwgb3IgZnJvbQogIH4vbG9jYWwtc2VhcmNoKS4KLSBTY3JhcGUgb3V0cHV0IGlzIGxv
>> "!B64TMP!" echo bmcuIEV4dHJhY3Qgb25seSB0aGUgcGFydHMgeW91IG5lZWQgZm9yIHRoZSBhbnN3ZXI7IGRvbid0
>> "!B64TMP!" echo CiAgcGFzdGUgd2hvbGUgcGFnZXMgYmFjayB0byB0aGUgdXNlci4K
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web\SKILL.md"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web/LICENSE ---
set "B64TMP=%TEMP%\LSR3859353351.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web\LICENSE"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web/scripts/config.py ---
set "B64TMP=%TEMP%\LSR2948145526.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web\scripts\config.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web/scripts/ensure_stack.py ---
set "B64TMP=%TEMP%\LSR1368704585.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web\scripts\ensure_stack.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web/scripts/web_search.py ---
set "B64TMP=%TEMP%\LSR1093883993.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web\scripts\web_search.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web/scripts/web_scrape.py ---
set "B64TMP=%TEMP%\LSR2164429367.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web\scripts\web_scrape.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- gen_installers.py ---
set "B64TMP=%TEMP%\LSR3253414166.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKR2VuZXJhdG9yIGZvciBzZWxmLWNvbnRhaW5lZCBp
>> "!B64TMP!" echo bnN0YWxsZXJzLgoKUmVhZHMgdGhlIHNvdXJjZSBmaWxlcyBmcm9tIC9ob21lL3ovbXktcHJvamVj
>> "!B64TMP!" echo dC9sb2NhbC1zZWFyY2gvIGFuZCBwcm9kdWNlczoKICAtIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJh
>> "!B64TMP!" echo dCAgKFdpbmRvd3MsIGVtYmVkZGVkIGJhc2U2NCBmYWxsYmFjayBmb3IgZXZlcnkgZmlsZSkKICAt
>> "!B64TMP!" echo IGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoICAgKExpbnV4L21hY09TLCBlbWJlZGRlZCBoZXJlZG9j
>> "!B64TMP!" echo IGZhbGxiYWNrIGZvciBldmVyeSBmaWxlKQoKQm90aCBpbnN0YWxsZXJzIEZJUlNUIHRyeSB0byBj
>> "!B64TMP!" echo b3B5IGEgZmlsZSBmcm9tIHRoZWlyIG93biBmb2xkZXIgKHNvIHRoZSBmdWxsCnppcCBzdGlsbCB3
>> "!B64TMP!" echo b3JrcyBhbmQgc3RheXMgZmFzdCksIGFuZCBGQUxMIEJBQ0sgdG8gdGhlIGVtYmVkZGVkIGNvcHkg
>> "!B64TMP!" echo aWYgdGhlCnNvdXJjZSBmaWxlIGlzIG1pc3NpbmcuIFRoaXMgZml4ZXMgdGhlIGJ1ZyB3aGVyZSB1
>> "!B64TMP!" echo c2VycyB3aG8gZG93bmxvYWRlZCBvbmx5CnRoZSB0b3AtbGV2ZWwgZmlsZXMgKGFuZCBtaXNzZWQg
>> "!B64TMP!" echo Y29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sIG9yIHRoZSBoaWRkZW4KLmVudi5leGFtcGxlKSBn
>> "!B64TMP!" echo b3QgYW4gZW1wdHkgc2VhcnhuZyBkaXJlY3RvcnkgYW5kIGEgZmFpbGVkIGluc3RhbGwuCiIiIgpp
>> "!B64TMP!" echo bXBvcnQgYmFzZTY0CmltcG9ydCBvcwppbXBvcnQgc3lzCgpTUkMgPSBvcy5wYXRoLmpvaW4ob3Mu
>> "!B64TMP!" echo cGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpLCAibG9jYWwtc2VhcmNoIikK
>> "!B64TMP!" echo CiMgKHJlbGF0aXZlIHBhdGggaW4gaW5zdGFsbCBmb2xkZXIsIHNvdXJjZSBmaWxlKQojIFVzZWQg
>> "!B64TMP!" echo YnkgQk9USCBnZW5lcmF0b3JzLiBUaGUgLmJhdCBnZW5lcmF0b3Igc2tpcHMgaW5zdGFsbC1sb2Nh
>> "!B64TMP!" echo bC1zZWFyY2guYmF0CiMgKGl0IGNvcGllcyBpdHNlbGYgdmlhICV+ZjAgYXQgcnVudGltZSk7IHRo
>> "!B64TMP!" echo ZSAuc2ggZ2VuZXJhdG9yIGVtYmVkcyBpdCB0b28gc28KIyBhIExpbnV4IGluc3RhbGwgcHJvZHVj
>> "!B64TMP!" echo ZXMgYSBXaW5kb3dzLXBvcnRhYmxlIGZvbGRlci4KRklMRVMgPSBbCiAgICAoImNvbmZpZy9zZWFy
>> "!B64TMP!" echo eG5nL3NldHRpbmdzLnltbCIsICAgICAgICAgICJjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWwi
>> "!B64TMP!" echo KSwKICAgICgiZG9ja2VyLWNvbXBvc2UueW1sIiwgICAgICAgICAgICAgICAgICAgImRvY2tlci1j
>> "!B64TMP!" echo b21wb3NlLnltbCIpLAogICAgKCIuZW52LmV4YW1wbGUiLCAgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAiLmVudi5leGFtcGxlIiksCiAgICAoIlJFQURNRS5tZCIsICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICJSRUFETUUubWQiKSwKICAgICgiTElDRU5TRSIsICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgIkxJQ0VOU0UiKSwKICAgICgiLmdpdGlnbm9yZSIsICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgIi5naXRpZ25vcmUiKSwKICAgICgiLmdpdGF0dHJpYnV0ZXMiLCAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgIi5naXRhdHRyaWJ1dGVzIiksCiAgICAoIlJ1bi5iYXQiLCAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICJSdW4uYmF0IiksCiAgICAoIlN0b3AuYmF0IiwgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICJTdG9wLmJhdCIpLAogICAgKCJVcGRhdGUuYmF0IiwgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAiVXBkYXRlLmJhdCIpLAogICAgKCJVbmluc3RhbGwuYmF0Iiwg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAiVW5pbnN0YWxsLmJhdCIpLAogICAgKCJydW4uc2giLCAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAicnVuLnNoIiksCiAgICAoInN0b3Auc2giLCAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICJzdG9wLnNoIiksCiAgICAoInVwZGF0ZS5zaCIs
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICJ1cGRhdGUuc2giKSwKICAgICgidW5pbnN0YWxs
>> "!B64TMP!" echo LnNoIiwgICAgICAgICAgICAgICAgICAgICAgICAgInVuaW5zdGFsbC5zaCIpLAogICAgIyAtLS0t
>> "!B64TMP!" echo IGJ1bmRsZWQgbG9jYWwtd2ViIGFnZW50IHNraWxsIC0tLS0KICAgICgibG9jYWwtd2ViL1NLSUxM
>> "!B64TMP!" echo Lm1kIiwgICAgICAgICAgICAgICAgICAgImxvY2FsLXdlYi9TS0lMTC5tZCIpLAogICAgKCJsb2Nh
>> "!B64TMP!" echo bC13ZWIvTElDRU5TRSIsICAgICAgICAgICAgICAgICAgICAibG9jYWwtd2ViL0xJQ0VOU0UiKSwK
>> "!B64TMP!" echo ICAgICgibG9jYWwtd2ViL3NjcmlwdHMvY29uZmlnLnB5IiwgICAgICAgICAgImxvY2FsLXdlYi9z
>> "!B64TMP!" echo Y3JpcHRzL2NvbmZpZy5weSIpLAogICAgKCJsb2NhbC13ZWIvc2NyaXB0cy9lbnN1cmVfc3RhY2su
>> "!B64TMP!" echo cHkiLCAgICAibG9jYWwtd2ViL3NjcmlwdHMvZW5zdXJlX3N0YWNrLnB5IiksCiAgICAoImxvY2Fs
>> "!B64TMP!" echo LXdlYi9zY3JpcHRzL3dlYl9zZWFyY2gucHkiLCAgICAgICJsb2NhbC13ZWIvc2NyaXB0cy93ZWJf
>> "!B64TMP!" echo c2VhcmNoLnB5IiksCiAgICAoImxvY2FsLXdlYi9zY3JpcHRzL3dlYl9zY3JhcGUucHkiLCAgICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWIvc2NyaXB0cy93ZWJfc2NyYXBlLnB5IiksCiAgICAoImluc3RhbGwtbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoLmJhdCIsICAgICAgICAgICAgICJpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQiKSwKXQoK
>> "!B64TMP!" echo CmRlZiByZWFkKHJlbCk6CiAgICB3aXRoIG9wZW4ob3MucGF0aC5qb2luKFNSQywgcmVsKSwgInJi
>> "!B64TMP!" echo IikgYXMgZjoKICAgICAgICByZXR1cm4gZi5yZWFkKCkKCgojID09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo CiMgIFdpbmRvd3MgaW5zdGFsbGVyICguYmF0KQojID09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CgpkZWYg
>> "!B64TMP!" echo YjY0X2NodW5rZWQoZGF0YSwgd2lkdGg9NzYpOgogICAgIiIiUmV0dXJuIGxpc3Qgb2YgPD13aWR0
>> "!B64TMP!" echo aC1jaGFyIGJhc2U2NCBsaW5lcy4iIiIKICAgIHMgPSBiYXNlNjQuYjY0ZW5jb2RlKGRhdGEpLmRl
>> "!B64TMP!" echo Y29kZSgiYXNjaWkiKQogICAgcmV0dXJuIFtzW2k6aSt3aWR0aF0gZm9yIGkgaW4gcmFuZ2UoMCwg
>> "!B64TMP!" echo bGVuKHMpLCB3aWR0aCldCgoKZGVmIGdlbl9iYXQoKToKICAgIG91dCA9IFtdCiAgICBhcCA9IG91
>> "!B64TMP!" echo dC5hcHBlbmQKCiAgICBhcCgnQGVjaG8gb2ZmJykKICAgIGFwKCdzZXRsb2NhbCBlbmFibGVEZWxh
>> "!B64TMP!" echo eWVkRXhwYW5zaW9uJykKICAgIGFwKCdjaGNwIDY1MDAxID5udWwnKQogICAgYXAoJ3RpdGxlIExv
>> "!B64TMP!" echo Y2FsIFNlYXJjaCAtIEluc3RhbGxlcicpCiAgICBhcCgnJykKICAgIGFwKCdSRU0gPT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09JykKICAgIGFwKCdSRU0gIExvY2FsIFNlYXJjaCBJbnN0YWxsZXIgIChGaXJlY3Jh
>> "!B64TMP!" echo d2wgKyBTZWFyWE5HICsgbG9jYWwtd2ViIHNraWxsKSAgLSAgV2luZG93cycpCiAgICBhcCgnUkVN
>> "!B64TMP!" echo ID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnUkVNICBTZWxmLWNvbnRhaW5lZDogZXZlcnkg
>> "!B64TMP!" echo ZmlsZSB0aGUgaW5zdGFsbGVyIG5lZWRzIGlzIGVtYmVkZGVkIGJlbG93IGFzJykKICAgIGFwKCdS
>> "!B64TMP!" echo RU0gIGJhc2U2NC4gSWYgYSBzb3VyY2UgZmlsZSBpcyBtaXNzaW5nIGZyb20gdGhpcyBzY3JpcHRc
>> "!B64TMP!" echo J3MgZm9sZGVyIChlLmcuIHlvdScpCiAgICBhcCgnUkVNICBvbmx5IGRvd25sb2FkZWQgdGhpcyBv
>> "!B64TMP!" echo bmUgLmJhdCksIHRoZSBlbWJlZGRlZCBjb3B5IGlzIHVzZWQgaW5zdGVhZC4nKQogICAgYXAoJ1JF
>> "!B64TMP!" echo TSAgQWZ0ZXIgaW5zdGFsbGluZyB0aGUgc3RhY2sgaXQgYWxzbyBjb3BpZXMgdGhlIGJ1bmRsZWQg
>> "!B64TMP!" echo bG9jYWwtd2ViIGFnZW50JykKICAgIGFwKCdSRU0gIHNraWxsIGludG8gJVVTRVJQUk9GSUxFJVxc
>> "!B64TMP!" echo LmFnZW50c1xcc2tpbGxzXFxsb2NhbC13ZWIuJykKICAgIGFwKCdSRU0gPT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09JykKICAgIGFwKCcnKQogICAgYXAoJ2VjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdlY2hvICAgTG9jYWwg
>> "!B64TMP!" echo U2VhcmNoIEluc3RhbGxlciAgKEZpcmVjcmF3bCArIFNlYXJYTkcgKyBsb2NhbC13ZWIpJykKICAg
>> "!B64TMP!" echo IGFwKCdlY2hvICAgQSBsb2NhbCB3ZWItYnJvd3Npbmcgc3lzdGVtIGZvciBBSSBtb2RlbHMuJykK
>> "!B64TMP!" echo ICAgIGFwKCdlY2hvID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PScpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJycpCiAgICAjIERvY2tl
>> "!B64TMP!" echo ciBjaGVjawogICAgYXAoJ3doZXJlIGRvY2tlciA+bnVsIDI+JjEnKQogICAgYXAoJ2lmIGVycm9y
>> "!B64TMP!" echo bGV2ZWwgMSAoJykKICAgIGFwKCcgIGVjaG8gW0VSUk9SXSBEb2NrZXIgd2FzIG5vdCBmb3VuZCBv
>> "!B64TMP!" echo biB5b3VyIFBBVEguJykKICAgIGFwKCcgIGVjaG8gICBJbnN0YWxsIERvY2tlciBEZXNrdG9wOiBo
>> "!B64TMP!" echo dHRwczovL3d3dy5kb2NrZXIuY29tL3Byb2R1Y3RzL2RvY2tlci1kZXNrdG9wLycpCiAgICBhcCgn
>> "!B64TMP!" echo ICBlY2hvICAgU3RhcnQgaXQsIHdhaXQgdW50aWwgIkRvY2tlciBEZXNrdG9wIGlzIHJ1bm5pbmci
>> "!B64TMP!" echo LCB0aGVuIHJlLXJ1bi4nKQogICAgYXAoJyAgcGF1c2UgJiBleGl0IC9iIDEnKQogICAgYXAoJykn
>> "!B64TMP!" echo KQogICAgYXAoJ2RvY2tlciBpbmZvID5udWwgMj4mMScpCiAgICBhcCgnaWYgZXJyb3JsZXZlbCAx
>> "!B64TMP!" echo ICgnKQogICAgYXAoJyAgZWNobyBbRVJST1JdIERvY2tlciBpcyBpbnN0YWxsZWQgYnV0IHRoZSBl
>> "!B64TMP!" echo bmdpbmUgaXMgbm90IHJ1bm5pbmcuJykKICAgIGFwKCcgIGVjaG8gICBTdGFydCBEb2NrZXIgRGVz
>> "!B64TMP!" echo a3RvcCBhbmQgd2FpdCB1bnRpbCBpdCBzYXlzICJydW5uaW5nIi4nKQogICAgYXAoJyAgcGF1c2Ug
>> "!B64TMP!" echo JiBleGl0IC9iIDEnKQogICAgYXAoJyknKQogICAgYXAoJ2VjaG8gW09LXSBEb2NrZXIgaXMgcnVu
>> "!B64TMP!" echo bmluZy4nKQogICAgYXAoJ2VjaG8uJykKICAgIGFwKCcnKQogICAgIyBTb3VyY2UgZm9sZGVyCiAg
>> "!B64TMP!" echo ICBhcCgnc2V0ICJTUkM9JX5kcDAiJykKICAgIGFwKCdpZiAiIVNSQzp+LTEhIj09IlxcIiBzZXQg
>> "!B64TMP!" echo IlNSQz0hU1JDOn4wLC0xISInKQogICAgYXAoJycpCiAgICAjIFByb21wdHMKICAgIGFwKCdzZXQg
>> "!B64TMP!" echo IkRFRkFVTFRfVEFSR0VUPSVVU0VSUFJPRklMRSVcXGxvY2FsLXNlYXJjaCInKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICBhcCgnZWNobyAtLS0gU3RlcCAxIG9mIDQ6IEluc3RhbGwgbG9jYXRpb24gLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0nKQogICAgYXAoJ2VjaG8gICBEZWZhdWx0OiAlREVGQVVMVF9UQVJH
>> "!B64TMP!" echo RVQlJykKICAgIGFwKCdzZXQgIlRBUkdFVD0iJykKICAgIGFwKCdzZXQgL3AgVEFSR0VUPSIgIFRh
>> "!B64TMP!" echo cmdldCBmb2xkZXIgW3ByZXNzIEVudGVyIGZvciBkZWZhdWx0XTogIicpCiAgICBhcCgnaWYgIiFU
>> "!B64TMP!" echo QVJHRVQhIj09IiIgc2V0ICJUQVJHRVQ9JURFRkFVTFRfVEFSR0VUJSInKQogICAgYXAoJ3NldCAi
>> "!B64TMP!" echo VEFSR0VUPSFUQVJHRVQ6Ij0hIicpCiAgICBhcCgnZm9yICUlSSBpbiAoIiFUQVJHRVQhIikgZG8g
>> "!B64TMP!" echo c2V0ICJUQVJHRVQ9JSV+ZkkiJykKICAgIGFwKCdlY2hvICAgVXNpbmc6ICFUQVJHRVQhJykKICAg
>> "!B64TMP!" echo IGFwKCdlY2hvLicpCiAgICBhcCgnJykKICAgIGFwKCc6YXNrX3NlYXJ4bmcnKQogICAgYXAoJ2Vj
>> "!B64TMP!" echo aG8gLS0tIFN0ZXAgMiBvZiA0OiBTZWFyWE5HIHBvcnQgKGRlZmF1bHQgOTk5MCkgLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0nKQogICAgYXAoJ3NldCAiU0VBUlhOR19QT1JUPSInKQogICAgYXAoJ3NldCAvcCBTRUFS
>> "!B64TMP!" echo WE5HX1BPUlQ9IiAgUG9ydCBmb3IgU2VhclhORyBbcHJlc3MgRW50ZXIgZm9yIDk5OTBdOiAiJykK
>> "!B64TMP!" echo ICAgIGFwKCdpZiAiIVNFQVJYTkdfUE9SVCEiPT0iIiBzZXQgIlNFQVJYTkdfUE9SVD05OTkwIicp
>> "!B64TMP!" echo CiAgICBhcCgnY2FsbCA6dmFsaWRhdGVfcG9ydCAiIVNFQVJYTkdfUE9SVCEiJykKICAgIGFwKCdp
>> "!B64TMP!" echo ZiAhZXJyb3JsZXZlbCEgbmVxIDAgKCBlY2hvICAgWyFdICIhU0VBUlhOR19QT1JUISIgaXMgbm90
>> "!B64TMP!" echo IGEgdmFsaWQgcG9ydCBeKDEtNjU1MzVeKS4gJiBlY2hvLiAmIGdvdG8gYXNrX3NlYXJ4bmcgKScp
>> "!B64TMP!" echo CiAgICBhcCgnJykKICAgIGFwKCc6YXNrX2ZpcmVjcmF3bCcpCiAgICBhcCgnZWNobyAtLS0gU3Rl
>> "!B64TMP!" echo cCAzIG9mIDQ6IEZpcmVjcmF3bCBwb3J0IChkZWZhdWx0IDk5OTEpIC0tLS0tLS0tLS0tLScpCiAg
>> "!B64TMP!" echo ICBhcCgnc2V0ICJGSVJFQ1JBV0xfUE9SVD0iJykKICAgIGFwKCdzZXQgL3AgRklSRUNSQVdMX1BP
>> "!B64TMP!" echo UlQ9IiAgUG9ydCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBFbnRlciBmb3IgOTk5MV06ICInKQogICAg
>> "!B64TMP!" echo YXAoJ2lmICIhRklSRUNSQVdMX1BPUlQhIj09IiIgc2V0ICJGSVJFQ1JBV0xfUE9SVD05OTkxIicp
>> "!B64TMP!" echo CiAgICBhcCgnY2FsbCA6dmFsaWRhdGVfcG9ydCAiIUZJUkVDUkFXTF9QT1JUISInKQogICAgYXAo
>> "!B64TMP!" echo J2lmICFlcnJvcmxldmVsISBuZXEgMCAoIGVjaG8gICBbIV0gIiFGSVJFQ1JBV0xfUE9SVCEiIGlz
>> "!B64TMP!" echo IG5vdCBhIHZhbGlkIHBvcnQgXigxLTY1NTM1XikuICYgZWNoby4gJiBnb3RvIGFza19maXJlY3Jh
>> "!B64TMP!" echo d2wgKScpCiAgICBhcCgnaWYgL2kgIiFGSVJFQ1JBV0xfUE9SVCEiPT0iIVNFQVJYTkdfUE9SVCEi
>> "!B64TMP!" echo ICggZWNobyAgIFshXSBGaXJlY3Jhd2wgcG9ydCBtdXN0IGRpZmZlciBmcm9tIFNlYXJYTkcgcG9y
>> "!B64TMP!" echo dC4gJiBlY2hvLiAmIGdvdG8gYXNrX2ZpcmVjcmF3bCApJykKICAgIGFwKCcnKQogICAgYXAoJ2Vj
>> "!B64TMP!" echo aG8uJykKICAgIGFwKCdlY2hvIC0tLSBTdGVwIDQgb2YgNDogTG9jYWwgTExNIChvcHRpb25hbCkg
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tJykKICAgIGFwKCdlY2hvICAgTGV0cyBGaXJlY3Jhd2wgZG8g
>> "!B64TMP!" echo QUkgZXh0cmFjdGlvbiAoL3YxL2V4dHJhY3QpIGFuZCBzdW1tYXJpZXMuJykKICAgIGFwKCdlY2hv
>> "!B64TMP!" echo ICAgUmVjb21tZW5kZWQ6IExNIFN0dWRpbyAgLV4+ICBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEn
>> "!B64TMP!" echo KQogICAgYXAoJ3NldCAiVVNFX0xMTT0iJykKICAgIGFwKCdzZXQgL3AgVVNFX0xMTT0iICBDb25u
>> "!B64TMP!" echo ZWN0IGEgbG9jYWwgTExNIG5vdz8gW3kvTl06ICInKQogICAgYXAoJ3NldCAiT1BFTkFJX0JBU0Vf
>> "!B64TMP!" echo VVJMPSInKQogICAgYXAoJ3NldCAiT1BFTkFJX0FQSV9LRVk9IicpCiAgICBhcCgnc2V0ICJNT0RF
>> "!B64TMP!" echo TF9OQU1FPSInKQogICAgYXAoJ2lmIC9pICIhVVNFX0xMTSEiPT0ieSIgKCcpCiAgICBhcCgnICBz
>> "!B64TMP!" echo ZXQgIkxMTV9VUkw9IicpCiAgICBhcCgnICBzZXQgL3AgTExNX1VSTD0iICAgIExNIFN0dWRpbyBz
>> "!B64TMP!" echo ZXJ2ZXIgVVJMIGFzIHNob3duIGluIExNIFN0dWRpbyBbRW50ZXIgPSBodHRwOi8vbG9jYWxob3N0
>> "!B64TMP!" echo OjEyMzQvdjFdOiAiJykKICAgIGFwKCcgIGlmICIhTExNX1VSTCEiPT0iIiBzZXQgIkxMTV9VUkw9
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDoxMjM0L3YxIicpCiAgICBhcCgnICBzZXQgIkxMTV9NT0RFTD0iJykK
>> "!B64TMP!" echo ICAgIGFwKCcgIHNldCAvcCBMTE1fTU9ERUw9IiAgICBNb2RlbCBuYW1lIGxvYWRlZCBpbiBMTSBT
>> "!B64TMP!" echo dHVkaW8gW0VudGVyIHRvIHNraXBdOiAiJykKICAgIGFwKCcgIHNldCAiT1BFTkFJX0JBU0VfVVJM
>> "!B64TMP!" echo PSFMTE1fVVJMISInKQogICAgYXAoJyAgc2V0ICJPUEVOQUlfQkFTRV9VUkw9IU9QRU5BSV9CQVNF
>> "!B64TMP!" echo X1VSTDpodHRwOi8vbG9jYWxob3N0PWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbCEiJykKICAg
>> "!B64TMP!" echo IGFwKCcgIHNldCAiT1BFTkFJX0JBU0VfVVJMPSFPUEVOQUlfQkFTRV9VUkw6aHR0cDovLzEyNy4w
>> "!B64TMP!" echo LjAuMT1odHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWwhIicpCiAgICBhcCgnICBzZXQgIk9QRU5B
>> "!B64TMP!" echo SV9BUElfS0VZPWxtLXN0dWRpbyInKQogICAgYXAoJyAgaWYgbm90ICIhTExNX01PREVMISI9PSIi
>> "!B64TMP!" echo IHNldCAiTU9ERUxfTkFNRT0hTExNX01PREVMISInKQogICAgYXAoJyAgZWNobyAgICAgXihDb250
>> "!B64TMP!" echo YWluZXIgd2lsbCByZWFjaCBpdCBhdDogIU9QRU5BSV9CQVNFX1VSTCFeKScpCiAgICBhcCgnICBl
>> "!B64TMP!" echo Y2hvICAgICBeKE1ha2Ugc3VyZSBMTSBTdHVkaW8gaGFzICJTZXJ2ZSBvbiBsb2NhbCBuZXR3b3Jr
>> "!B64TMP!" echo IiBlbmFibGVkLl4pJykKICAgIGFwKCcpJykKICAgIGFwKCcnKQogICAgIyBTdW1tYXJ5ICsgY29u
>> "!B64TMP!" echo ZmlybQogICAgYXAoJ2VjaG8uJykKICAgIGFwKCdlY2hvID09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnZWNobyAgIFN1
>> "!B64TMP!" echo bW1hcnknKQogICAgYXAoJ2VjaG8gICBGb2xkZXI6ICAgICAgICAgIVRBUkdFVCEnKQogICAgYXAo
>> "!B64TMP!" echo J2VjaG8gICBTZWFyWE5HIHBvcnQ6ICAgIVNFQVJYTkdfUE9SVCEnKQogICAgYXAoJ2VjaG8gICBG
>> "!B64TMP!" echo aXJlY3Jhd2wgcG9ydDogIUZJUkVDUkFXTF9QT1JUIScpCiAgICBhcCgnZWNobyAgIEFnZW50IHNr
>> "!B64TMP!" echo aWxsOiAgICAlVVNFUlBST0ZJTEUlXFwuYWdlbnRzXFxza2lsbHNcXGxvY2FsLXdlYicpCiAgICBh
>> "!B64TMP!" echo cCgnaWYgZGVmaW5lZCBPUEVOQUlfQkFTRV9VUkwgKCcpCiAgICBhcCgnICBlY2hvICAgTExNIGVu
>> "!B64TMP!" echo ZHBvaW50OiAgICFPUEVOQUlfQkFTRV9VUkwhICAhTU9ERUxfTkFNRSEnKQogICAgYXAoJykgZWxz
>> "!B64TMP!" echo ZSAoJykKICAgIGFwKCcgIGVjaG8gICBMTE0gZW5kcG9pbnQ6ICAgXihub25lIC0gZW5hYmxlIGxh
>> "!B64TMP!" echo dGVyIGJ5IGVkaXRpbmcgLmVudl4pJykKICAgIGFwKCcpJykKICAgIGFwKCdlY2hvID09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAg
>> "!B64TMP!" echo ICBhcCgnc2V0ICJDT05GSVJNPSInKQogICAgYXAoJ3NldCAvcCBDT05GSVJNPSJQcm9jZWVkIHdp
>> "!B64TMP!" echo dGggaW5zdGFsbD8gW1kvbl06ICInKQogICAgYXAoJ2lmIC9pICIhQ09ORklSTSEiPT0ibiIgKCBl
>> "!B64TMP!" echo Y2hvIEluc3RhbGwgY2FuY2VsbGVkLiAmIHBhdXNlICYgZXhpdCAvYiAwICknKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICAjIENyZWF0ZSBmb2xkZXJzCiAgICBhcCgnaWYgbm90IGV4aXN0ICIhVEFSR0VUISIgbWtk
>> "!B64TMP!" echo aXIgIiFUQVJHRVQhIicpCiAgICBhcCgnaWYgbm90IGV4aXN0ICIhVEFSR0VUIVxcY29uZmlnXFxz
>> "!B64TMP!" echo ZWFyeG5nIiBta2RpciAiIVRBUkdFVCFcXGNvbmZpZ1xcc2VhcnhuZyInKQogICAgYXAoJ2lmIG5v
>> "!B64TMP!" echo dCBleGlzdCAiIVRBUkdFVCFcXGxvY2FsLXdlYlxcc2NyaXB0cyIgbWtkaXIgIiFUQVJHRVQhXFxs
>> "!B64TMP!" echo b2NhbC13ZWJcXHNjcmlwdHMiJykKICAgIGFwKCcnKQogICAgIyBCYWNrdXAgZXhpc3RpbmcgLmVu
>> "!B64TMP!" echo dgogICAgYXAoJ2lmIGV4aXN0ICIhVEFSR0VUIVxcLmVudiIgKCcpCiAgICBhcCgnICBmb3IgL2Yg
>> "!B64TMP!" echo InVzZWJhY2txIGRlbGltcz0iICUldCBpbiAoYHBvd2Vyc2hlbGwgLU5vUHJvZmlsZSAtQ29tbWFu
>> "!B64TMP!" echo ZCAiR2V0LURhdGUgLUZvcm1hdCB5eXl5TU1kZEhIbW1zcyJgKSBkbyBzZXQgIkxEVD0lJXQiJykK
>> "!B64TMP!" echo ICAgIGFwKCcgIGNvcHkgL1kgIiFUQVJHRVQhXFwuZW52IiAiIVRBUkdFVCFcXC5lbnYuYmFrLiFM
>> "!B64TMP!" echo RFQhIiA+bnVsJykKICAgIGFwKCcgIGVjaG8gICBCYWNrZWQgdXAgZXhpc3RpbmcgLmVudiB0byAu
>> "!B64TMP!" echo ZW52LmJhay4hTERUIScpCiAgICBhcCgnKScpCiAgICBhcCgnJykKICAgICMgLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQog
>> "!B64TMP!" echo ICAgIyAgTWF0ZXJpYWxpc2UgZXZlcnkgcHJvamVjdCBmaWxlOiBjb3B5IGZyb20gc291cmNlIGlm
>> "!B64TMP!" echo IHByZXNlbnQsIGVsc2UKICAgICMgIGRlY29kZSB0aGUgZW1iZWRkZWQgYmFzZTY0IGJsb2IgZm9y
>> "!B64TMP!" echo IHRoYXQgZmlsZS4KICAgICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgYXAoJ2VjaG8gQ29weWluZyBmaWxlcy4u
>> "!B64TMP!" echo LicpCgogICAgZm9yIHJlbCwgc3JjIGluIEZJTEVTOgogICAgICAgIGlmIHJlbCA9PSAiaW5zdGFs
>> "!B64TMP!" echo bC1sb2NhbC1zZWFyY2guYmF0IjoKICAgICAgICAgICAgIyBUaGUgLmJhdCBjb3BpZXMgSVRTRUxG
>> "!B64TMP!" echo IGF0IHJ1bnRpbWUgdmlhICV+ZjAgKHNlZSBiZWxvdykuIERvIG5vdAogICAgICAgICAgICAjIGVt
>> "!B64TMP!" echo YmVkIGl0c2VsZiBoZXJlIC0tIHRoYXQgd291bGQgcmVhZCBhIHN0YWxlIHByZXZpb3VzLWdlbmVy
>> "!B64TMP!" echo YXRpb24KICAgICAgICAgICAgIyAuYmF0IGFuZCBjcmVhdGUgYSBjb25mdXNpbmcgZHVwbGljYXRl
>> "!B64TMP!" echo LgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGRhdGEgPSByZWFkKHNyYykKICAgICAgICBs
>> "!B64TMP!" echo aW5lcyA9IGI2NF9jaHVua2VkKGRhdGEpCiAgICAgICAgcmVsX3dpbiA9IHJlbC5yZXBsYWNlKCIv
>> "!B64TMP!" echo IiwgIlxcIikKICAgICAgICBhcCgnJykKICAgICAgICBhcCgnUkVNIC0tLSAnICsgcmVsICsgJyAt
>> "!B64TMP!" echo LS0nKQogICAgICAgIGFwKCdzZXQgIk5FRURfQjY0PTEiJykKICAgICAgICBhcCgnaWYgZXhpc3Qg
>> "!B64TMP!" echo IiFTUkMhXFwnICsgcmVsX3dpbiArICciICgnKQogICAgICAgIGFwKCcgIGNvcHkgL1kgIiFTUkMh
>> "!B64TMP!" echo XFwnICsgcmVsX3dpbiArICciICIhVEFSR0VUIVxcJyArIHJlbF93aW4gKyAnIiA+bnVsIDI+JjEn
>> "!B64TMP!" echo KQogICAgICAgIGFwKCcgIGlmIGV4aXN0ICIhVEFSR0VUIVxcJyArIHJlbF93aW4gKyAnIiBzZXQg
>> "!B64TMP!" echo Ik5FRURfQjY0PTAiJykKICAgICAgICBhcCgnKScpCiAgICAgICAgYXAoJ2lmICIhTkVFRF9CNjQh
>> "!B64TMP!" echo Ij09IjEiICgnKQogICAgICAgIGFwKCcgIGVjaG8gICBbZW1iZWRkZWRdICcgKyByZWwgKyAnICBe
>> "!B64TMP!" echo KHNvdXJjZSBub3QgZm91bmQgbmV4dCB0byBpbnN0YWxsZXI7IHVzaW5nIGJ1aWx0LWluIGNvcHle
>> "!B64TMP!" echo KScpCiAgICAgICAgIyBEZXRlcm1pbmlzdGljIHRlbXAtZmlsZSB0YWcgZGVyaXZlZCBmcm9tIHRo
>> "!B64TMP!" echo ZSBmaWxlIHBhdGggKENSQzMyKS4KICAgICAgICAjIE11c3QgYmUgc3RhYmxlIGFjcm9zcyBnZW4g
>> "!B64TMP!" echo cnVucyBzbyB0aGUgLmJhdCBlbWJlZGRlZCBpbnNpZGUgdGhlIC5zaAogICAgICAgICMgbWF0Y2hl
>> "!B64TMP!" echo cyB0aGUgc3RhbmRhbG9uZSAuYmF0IGJ5dGUtZm9yLWJ5dGUuCiAgICAgICAgaW1wb3J0IHpsaWIK
>> "!B64TMP!" echo ICAgICAgICB0YWcgPSAiTFMiICsgc3RyKHpsaWIuY3JjMzIocmVsLmVuY29kZSgidXRmLTgiKSkg
>> "!B64TMP!" echo JiAweEZGRkZGRkZGKQogICAgICAgIGFwKCcgIHNldCAiQjY0VE1QPSVURU1QJVxcJyArIHRhZyAr
>> "!B64TMP!" echo ICcuYjY0IicpCiAgICAgICAgZmlyc3QgPSBUcnVlCiAgICAgICAgZm9yIGxuIGluIGxpbmVzOgog
>> "!B64TMP!" echo ICAgICAgICAgICBvcCA9ICc+JyBpZiBmaXJzdCBlbHNlICc+PicKICAgICAgICAgICAgYXAoJyAg
>> "!B64TMP!" echo JyArIG9wICsgJyAiIUI2NFRNUCEiIGVjaG8gJyArIGxuKQogICAgICAgICAgICBmaXJzdCA9IEZh
>> "!B64TMP!" echo bHNlCiAgICAgICAgYXAoJyAgc2V0ICJMU19CNjRfSU49IUI2NFRNUCEiJykKICAgICAgICBhcCgn
>> "!B64TMP!" echo ICBzZXQgIkxTX0I2NF9PVVQ9IVRBUkdFVCFcXCcgKyByZWxfd2luICsgJyInKQogICAgICAgIGFw
>> "!B64TMP!" echo KCcgIGNhbGwgOmRlY29kZV9iNjQnKQogICAgICAgIGFwKCcgIGlmIGV4aXN0ICIhQjY0VE1QISIg
>> "!B64TMP!" echo ZGVsIC9RICIhQjY0VE1QISIgPm51bCAyPiYxJykKICAgICAgICBhcCgnKScpCgogICAgIyBJbmNs
>> "!B64TMP!" echo dWRlIHRoZSBpbnN0YWxsZXJzIHRoZW1zZWx2ZXMgc28gdGhlIGZvbGRlciBpcyBzZWxmLWNvbnRh
>> "!B64TMP!" echo aW5lZCAvIHJlLWluc3RhbGxhYmxlCiAgICBhcCgnaWYgZXhpc3QgIiFTUkMhXFxpbnN0YWxsLWxv
>> "!B64TMP!" echo Y2FsLXNlYXJjaC5iYXQiIGNvcHkgL1kgIiFTUkMhXFxpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQi
>> "!B64TMP!" echo ICIhVEFSR0VUIVxcaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IiA+bnVsIDI+JjEnKQogICAgYXAo
>> "!B64TMP!" echo J2lmIGV4aXN0ICIhU1JDIVxcaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giICBjb3B5IC9ZICIhU1JD
>> "!B64TMP!" echo IVxcaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giICAiIVRBUkdFVCFcXGluc3RhbGwtbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoLnNoIiAgPm51bCAyPiYxJykKICAgIGFwKCdSRU0gQWx3YXlzIGFsc28gZHJvcCB0aGUgKmN1
>> "!B64TMP!" echo cnJlbnQqIGluc3RhbGxlciAodGhpcyBzY3JpcHQpIGludG8gdGFyZ2V0LCBldmVuIGlmJykKICAg
>> "!B64TMP!" echo IGFwKCdSRU0gdGhlIHNvdXJjZSBjb3B5IGFib3ZlIHdhcyBza2lwcGVkIChlLmcuIHVzZXIgcmFu
>> "!B64TMP!" echo IGEgcmVuYW1lZCBjb3B5IG9mIHRoZSBiYXQpLicpCiAgICBhcCgnY29weSAvWSAiJX5mMCIgIiFU
>> "!B64TMP!" echo QVJHRVQhXFxpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQiID5udWwgMj4mMScpCiAgICBhcCgnJykK
>> "!B64TMP!" echo ICAgICMgR2VuZXJhdGUgc2VjcmV0cwogICAgYXAoJ2VjaG8gR2VuZXJhdGluZyBzZWN1cmUgY3Jl
>> "!B64TMP!" echo ZGVudGlhbHMuLi4nKQogICAgYXAoJ2NhbGwgOmdlbmtleSBTRUNSRVQnKQogICAgYXAoJ2NhbGwg
>> "!B64TMP!" echo OmdlbmtleSBCVUxMJykKICAgIGFwKCdjYWxsIDpnZW5rZXkgUEdQQVNTJykKICAgIGFwKCdjYWxs
>> "!B64TMP!" echo IDpnZW5rZXkgUkFCUEFTUycpCiAgICBhcCgnJykKICAgICMgV3JpdGUgLmVudgogICAgYXAoJ2Vj
>> "!B64TMP!" echo aG8gV3JpdGluZyAuZW52IC4uLicpCiAgICBhcCgnPiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gIyBM
>> "!B64TMP!" echo b2NhbCBTZWFyY2ggY29uZmlndXJhdGlvbiAtIGdlbmVyYXRlZCBieSBpbnN0YWxsLWxvY2FsLXNl
>> "!B64TMP!" echo YXJjaC5iYXQnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyAjIEVkaXQgcG9ydHMv
>> "!B64TMP!" echo TExNIGhlcmUsIHRoZW4gcnVuIFVwZGF0ZS5iYXQgdG8gYXBwbHkuJykKICAgIGFwKCc+PiAiIVRB
>> "!B64TMP!" echo UkdFVCFcXC5lbnYiIGVjaG8uJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gIyAt
>> "!B64TMP!" echo LS0tIEhvc3QgcG9ydHMgLS0tLScpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIFNF
>> "!B64TMP!" echo QVJYTkdfUE9SVD0hU0VBUlhOR19QT1JUIScpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBl
>> "!B64TMP!" echo Y2hvIEZJUkVDUkFXTF9QT1JUPSFGSVJFQ1JBV0xfUE9SVCEnKQogICAgYXAoJz4+ICIhVEFSR0VU
>> "!B64TMP!" echo IVxcLmVudiIgZWNoby4nKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyAjIC0tLS0g
>> "!B64TMP!" echo U2VhclhORyBpbnN0YW5jZSBzZWNyZXQgLS0tLScpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52
>> "!B64TMP!" echo IiBlY2hvIFNFQVJYTkdfU0VDUkVUPSFTRUNSRVQhJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5l
>> "!B64TMP!" echo bnYiIGVjaG8uJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gIyAtLS0tIEZpcmVj
>> "!B64TMP!" echo cmF3bCBpbnRlcm5hbCBjcmVkZW50aWFscyAtLS0tJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5l
>> "!B64TMP!" echo bnYiIGVjaG8gQlVMTF9BVVRIX0tFWT0hQlVMTCEnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVu
>> "!B64TMP!" echo diIgZWNobyBQT1NUR1JFU19EQj1maXJlY3Jhd2wnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVu
>> "!B64TMP!" echo diIgZWNobyBQT1NUR1JFU19VU0VSPWZpcmVjcmF3bCcpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwu
>> "!B64TMP!" echo ZW52IiBlY2hvIFBPU1RHUkVTX1BBU1NXT1JEPSFQR1BBU1MhJykKICAgIGFwKCc+PiAiIVRBUkdF
>> "!B64TMP!" echo VCFcXC5lbnYiIGVjaG8gUkFCQklUTVFfVVNFUj1maXJlY3Jhd2wnKQogICAgYXAoJz4+ICIhVEFS
>> "!B64TMP!" echo R0VUIVxcLmVudiIgZWNobyBSQUJCSVRNUV9QQVNTV09SRD0hUkFCUEFTUyEnKQogICAgYXAoJz4+
>> "!B64TMP!" echo ICIhVEFSR0VUIVxcLmVudiIgZWNoby4nKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNo
>> "!B64TMP!" echo byBMT0dHSU5HX0xFVkVMPWluZm8nKQogICAgYXAoJ2lmIGRlZmluZWQgT1BFTkFJX0JBU0VfVVJM
>> "!B64TMP!" echo ICgnKQogICAgYXAoJyAgPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvLicpCiAgICBhcCgnICA+PiAi
>> "!B64TMP!" echo IVRBUkdFVCFcXC5lbnYiIGVjaG8gIyAtLS0tIExvY2FsIExMTSBmb3IgRmlyZWNyYXdsIEFJIGZl
>> "!B64TMP!" echo YXR1cmVzIC0tLS0nKQogICAgYXAoJyAgPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIE9QRU5BSV9C
>> "!B64TMP!" echo QVNFX1VSTD0hT1BFTkFJX0JBU0VfVVJMIScpCiAgICBhcCgnICA+PiAiIVRBUkdFVCFcXC5lbnYi
>> "!B64TMP!" echo IGVjaG8gT1BFTkFJX0FQSV9LRVk9IU9QRU5BSV9BUElfS0VZIScpCiAgICBhcCgnICBpZiBkZWZp
>> "!B64TMP!" echo bmVkIE1PREVMX05BTUUgPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIE1PREVMX05BTUU9IU1PREVM
>> "!B64TMP!" echo X05BTUUhJykKICAgIGFwKCcpJykKICAgIGFwKCcnKQogICAgIyBJbmplY3QgU2VhclhORyBzZWNy
>> "!B64TMP!" echo ZXQgaW50byBzZXR0aW5ncy55bWwKICAgIGFwKCdlY2hvIEluamVjdGluZyBTZWFyWE5HIHNlY3Jl
>> "!B64TMP!" echo dCBpbnRvIHNldHRpbmdzLnltbCAuLi4nKQogICAgYXAoJ3Bvd2Vyc2hlbGwgLU5vUHJvZmlsZSAt
>> "!B64TMP!" echo Q29tbWFuZCAiKEdldC1Db250ZW50IC1SYXcgXCchVEFSR0VUIVxcY29uZmlnXFxzZWFyeG5nXFxz
>> "!B64TMP!" echo ZXR0aW5ncy55bWxcJykgLXJlcGxhY2UgXCdfX1NFQVJYTkdfU0VDUkVUX1BMQUNFSE9MREVSX19c
>> "!B64TMP!" echo JywgXCchU0VDUkVUIVwnIHwgU2V0LUNvbnRlbnQgLU5vTmV3bGluZSBcJyFUQVJHRVQhXFxjb25m
>> "!B64TMP!" echo aWdcXHNlYXJ4bmdcXHNldHRpbmdzLnltbFwnIicpCiAgICBhcCgnJykKICAgICMgLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LQogICAgIyAgSW5zdGFsbCB0aGUgYnVuZGxlZCBsb2NhbC13ZWIgYWdlbnQgc2tpbGwgaW50byB0
>> "!B64TMP!" echo aGUgdXNlcidzIHNraWxscwogICAgIyAgZGlyZWN0b3J5IChhZGQvb3ZlcnJpZGUpLCBhbmQgcmVj
>> "!B64TMP!" echo b3JkIHRoZSBpbnN0YWxsIHBhdGggaGludC4KICAgICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgYXAoJ2VjaG8g
>> "!B64TMP!" echo SW5zdGFsbGluZyB0aGUgbG9jYWwtd2ViIGFnZW50IHNraWxsLi4uJykKICAgIGFwKCdzZXQgIlNL
>> "!B64TMP!" echo SUxMX0RJUj0lVVNFUlBST0ZJTEUlXFwuYWdlbnRzXFxza2lsbHNcXGxvY2FsLXdlYiInKQogICAg
>> "!B64TMP!" echo YXAoJ2lmIGV4aXN0ICIhU0tJTExfRElSISIgcmQgL3MgL3EgIiFTS0lMTF9ESVIhIicpCiAgICBh
>> "!B64TMP!" echo cCgnaWYgbm90IGV4aXN0ICIlVVNFUlBST0ZJTEUlXFwuYWdlbnRzXFxza2lsbHMiIG1rZGlyICIl
>> "!B64TMP!" echo VVNFUlBST0ZJTEUlXFwuYWdlbnRzXFxza2lsbHMiJykKICAgIGFwKCd4Y29weSAvRSAvSSAvWSAv
>> "!B64TMP!" echo USAiIVRBUkdFVCFcXGxvY2FsLXdlYiIgIiFTS0lMTF9ESVIhIiA+bnVsJykKICAgIGFwKCdpZiBl
>> "!B64TMP!" echo cnJvcmxldmVsIDEgKCcpCiAgICBhcCgnICBlY2hvICAgW1dBUk5JTkddIENvdWxkIG5vdCBjb3B5
>> "!B64TMP!" echo IHRoZSBsb2NhbC13ZWIgc2tpbGwgdG8gIVNLSUxMX0RJUiEuJykKICAgIGFwKCcpIGVsc2UgKCcp
>> "!B64TMP!" echo CiAgICBhcCgnICA+ICIhVEFSR0VUIVxcbG9jYWwtd2ViXFxpbnN0YWxsLWRpci50eHQiIGVjaG8g
>> "!B64TMP!" echo IVRBUkdFVCEnKQogICAgYXAoJyAgPiAiIVNLSUxMX0RJUiFcXGluc3RhbGwtZGlyLnR4dCIgZWNo
>> "!B64TMP!" echo byAhVEFSR0VUIScpCiAgICBhcCgnICBlY2hvICAgQWdlbnQgc2tpbGwgaW5zdGFsbGVkOiAhU0tJ
>> "!B64TMP!" echo TExfRElSIScpCiAgICBhcCgnKScpCiAgICBhcCgnJykKICAgICMgUHVsbCArIHVwCiAgICBhcCgn
>> "!B64TMP!" echo ZWNoby4nKQogICAgYXAoJ2VjaG8gUHVsbGluZyBEb2NrZXIgaW1hZ2VzIChmaXJzdCBydW4gZG93
>> "!B64TMP!" echo bmxvYWRzIH4zLTQgR0IsIHBsZWFzZSBiZSBwYXRpZW50KS4uLicpCiAgICBhcCgncHVzaGQgIiFU
>> "!B64TMP!" echo QVJHRVQhIicpCiAgICBhcCgnZG9ja2VyIGNvbXBvc2UgcHVsbCcpCiAgICBhcCgnaWYgIWVycm9y
>> "!B64TMP!" echo bGV2ZWwhIG5lcSAwICggZWNobyAgIFtXQVJOSU5HXSBkb2NrZXIgY29tcG9zZSBwdWxsIHJlcG9y
>> "!B64TMP!" echo dGVkIGVycm9ycy4gVHJ5aW5nIHRvIHN0YXJ0IGFueXdheS4uLiApJykKICAgIGFwKCdlY2hvIFN0
>> "!B64TMP!" echo YXJ0aW5nIHNlcnZpY2VzLi4uJykKICAgIGFwKCdkb2NrZXIgY29tcG9zZSB1cCAtZCcpCiAgICBh
>> "!B64TMP!" echo cCgnc2V0ICJVUF9SQz0hZXJyb3JsZXZlbCEiJykKICAgIGFwKCdwb3BkJykKICAgIGFwKCdpZiAh
>> "!B64TMP!" echo VVBfUkMhIG5lcSAwICgnKQogICAgYXAoJyAgZWNoby4nKQogICAgYXAoJyAgZWNobyBbRVJST1Jd
>> "!B64TMP!" echo IGRvY2tlciBjb21wb3NlIHVwIGZhaWxlZC4gU2VlIG1lc3NhZ2VzIGFib3ZlLicpCiAgICBhcCgn
>> "!B64TMP!" echo ICBlY2hvICAgQ29tbW9uIGZpeGVzOicpCiAgICBhcCgnICBlY2hvICAgICAtIE1ha2Ugc3VyZSBE
>> "!B64TMP!" echo b2NrZXIgRGVza3RvcCBpcyBydW5uaW5nLicpCiAgICBhcCgnICBlY2hvICAgICAtIE1ha2Ugc3Vy
>> "!B64TMP!" echo ZSBwb3J0cyAhU0VBUlhOR19QT1JUISBhbmQgIUZJUkVDUkFXTF9QT1JUISBhcmUgbm90IGluIHVz
>> "!B64TMP!" echo ZS4nKQogICAgYXAoJyAgZWNobyAgICAgLSBSZS1ydW4gdGhpcyBpbnN0YWxsZXIgb3IgcnVuIFVw
>> "!B64TMP!" echo ZGF0ZS5iYXQgYWZ0ZXIgZml4aW5nLicpCiAgICBhcCgnICBlY2hvLicpCiAgICBhcCgnICBwYXVz
>> "!B64TMP!" echo ZSAmIGV4aXQgL2IgMScpCiAgICBhcCgnKScpCiAgICBhcCgnJykKICAgICMgRG9uZQogICAgYXAo
>> "!B64TMP!" echo J2VjaG8uJykKICAgIGFwKCdlY2hvID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnZWNobyAgIEluc3RhbGxhdGlvbiBj
>> "!B64TMP!" echo b21wbGV0ZSEnKQogICAgYXAoJ2VjaG8uJykKICAgIGFwKCdlY2hvICAgU2VhclhORyAgKHNlYXJj
>> "!B64TMP!" echo aCArIEpTT04gQVBJKTogIGh0dHA6Ly9sb2NhbGhvc3Q6IVNFQVJYTkdfUE9SVCEnKQogICAgYXAo
>> "!B64TMP!" echo J2VjaG8gICBGaXJlY3Jhd2wgKHNjcmFwZS9jcmF3bCBBUEkpOiBodHRwOi8vbG9jYWxob3N0OiFG
>> "!B64TMP!" echo SVJFQ1JBV0xfUE9SVCEnKQogICAgYXAoJ2VjaG8gICBsb2NhbC13ZWIgc2tpbGw6ICAgICAgICAg
>> "!B64TMP!" echo ICAgICAlVVNFUlBST0ZJTEUlXFwuYWdlbnRzXFxza2lsbHNcXGxvY2FsLXdlYicpCiAgICBhcCgn
>> "!B64TMP!" echo ZWNoby4nKQogICAgYXAoJ2VjaG8gICBJZiB5b3VyIGFnZW50IHdhcyBhbHJlYWR5IHJ1bm5pbmcs
>> "!B64TMP!" echo IHJlc3RhcnQgaXQgc28gaXQgcGlja3MgdXAnKQogICAgYXAoJ2VjaG8gICB0aGUgbmV3IHNraWxs
>> "!B64TMP!" echo LicpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJ2VjaG8gICBNYW5hZ2UgdGhlIHN0YWNrIHdpdGgg
>> "!B64TMP!" echo dGhlIC5iYXQgZmlsZXMgaW46JykKICAgIGFwKCdlY2hvICAgICAhVEFSR0VUIScpCiAgICBhcCgn
>> "!B64TMP!" echo ZWNobyAgICAgICBSdW4uYmF0ICAgU3RvcC5iYXQgICBVcGRhdGUuYmF0ICAgVW5pbnN0YWxsLmJh
>> "!B64TMP!" echo dCcpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJ2VjaG8gICBTZWUgUkVBRE1FLm1kIGZvciBob3cg
>> "!B64TMP!" echo dG8gY29ubmVjdCB0aGlzIHRvIHlvdXIgQUkgbW9kZWxzJykKICAgIGFwKCdlY2hvICAgKGxvY2Fs
>> "!B64TMP!" echo LXdlYiBza2lsbCwgTE0gU3R1ZGlvLCBNQ1Agc2VydmVyLCBkaXJlY3QgcHJvbXB0aW5nLCBldGMu
>> "!B64TMP!" echo KS4nKQogICAgYXAoJ2VjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgncGF1c2UnKQog
>> "!B64TMP!" echo ICAgYXAoJ2V4aXQgL2IgMCcpCiAgICBhcCgnJykKICAgICMgU3Vicm91dGluZXMKICAgIGFwKCdS
>> "!B64TMP!" echo RU0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdSRU0gIFN1YnJvdXRpbmVzJykKICAgIGFw
>> "!B64TMP!" echo KCdSRU0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCcnKQogICAgYXAoJzp2YWxpZGF0ZV9w
>> "!B64TMP!" echo b3J0JykKICAgIGFwKCdlY2hvICV+MXwgZmluZHN0ciAvciAvYzoiXlswLTldWzAtOV0qJCIgPm51
>> "!B64TMP!" echo bCcpCiAgICBhcCgnaWYgZXJyb3JsZXZlbCAxIGV4aXQgL2IgMScpCiAgICBhcCgnaWYgJX4xIGxz
>> "!B64TMP!" echo cyAxIGV4aXQgL2IgMScpCiAgICBhcCgnaWYgJX4xIGd0ciA2NTUzNSBleGl0IC9iIDEnKQogICAg
>> "!B64TMP!" echo YXAoJ2V4aXQgL2IgMCcpCiAgICBhcCgnJykKICAgIGFwKCc6Z2Vua2V5JykKICAgIGFwKCdzZXQg
>> "!B64TMP!" echo IktGSUxFPSVURU1QJVxcbG9jYWxfc2VhcmNoX2tleS50bXAiJykKICAgIGFwKCdwb3dlcnNoZWxs
>> "!B64TMP!" echo IC1Ob1Byb2ZpbGUgLUNvbW1hbmQgIiRybmc9W1NlY3VyaXR5LkNyeXB0b2dyYXBoeS5SYW5kb21O
>> "!B64TMP!" echo dW1iZXJHZW5lcmF0b3JdOjpDcmVhdGUoKTsgJHI9TmV3LU9iamVjdCBieXRlW10gMzI7ICRybmcu
>> "!B64TMP!" echo R2V0Qnl0ZXMoJHIpOyAtam9pbiAoJHIgfCBGb3JFYWNoLU9iamVjdCB7ICRfLlRvU3RyaW5nKFwn
>> "!B64TMP!" echo eDJcJykgfSkiID4gIiVLRklMRSUiJykKICAgIGFwKCdzZXQgL3AgIiV+MT0iIDwgIiVLRklMRSUi
>> "!B64TMP!" echo JykKICAgIGFwKCdkZWwgIiVLRklMRSUiID5udWwgMj4mMScpCiAgICBhcCgnZXhpdCAvYiAwJykK
>> "!B64TMP!" echo ICAgIGFwKCcnKQogICAgYXAoJzpkZWNvZGVfYjY0JykKICAgIGFwKCdSRU0gICUxID0gcGF0aCB0
>> "!B64TMP!" echo byBhIC5iNjQgdGV4dCBmaWxlLCAlMiA9IG91dHB1dCBiaW5hcnkgcGF0aCAobWF5IG5vdCBleGlz
>> "!B64TMP!" echo dCB5ZXQpJykKICAgIGFwKCdSRU0gIFBhc3MgcGF0aHMgdmlhIFBTIHZhcmlhYmxlcyB0byBzdXJ2
>> "!B64TMP!" echo aXZlIHNwYWNlcyAvIHF1b3RlcyBpbiBUQVJHRVQuJykKICAgIGFwKCdwb3dlcnNoZWxsIC1Ob1By
>> "!B64TMP!" echo b2ZpbGUgLUNvbW1hbmQgIiRpbj0kZW52OkxTX0I2NF9JTjsgJG91dD0kZW52OkxTX0I2NF9PVVQ7
>> "!B64TMP!" echo IFtJTy5GaWxlXTo6V3JpdGVBbGxCeXRlcygkb3V0LCBbQ29udmVydF06OkZyb21CYXNlNjRTdHJp
>> "!B64TMP!" echo bmcoKChHZXQtQ29udGVudCAtUmF3ICRpbikgLXJlcGxhY2UgXCdcXHNcJyxcJ1wnKSkpIicpCiAg
>> "!B64TMP!" echo ICBhcCgnZXhpdCAvYiAwJykKCiAgICByZXR1cm4gIlxyXG4iLmpvaW4ob3V0KSArICJcclxuIgoK
>> "!B64TMP!" echo CiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT0KIyAgTGludXggLyBtYWNPUyBpbnN0YWxsZXIgKC5zaCkK
>> "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQoKZGVmIGdlbl9zaCgpOgogICAgb3V0ID0gW10KICAgIGFw
>> "!B64TMP!" echo ID0gb3V0LmFwcGVuZAoKICAgIGFwKCcjIS91c3IvYmluL2VudiBiYXNoJykKICAgIGFwKCcjID09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCcjICBMb2NhbCBTZWFyY2ggSW5zdGFsbGVyICAo
>> "!B64TMP!" echo RmlyZWNyYXdsICsgU2VhclhORyArIGxvY2FsLXdlYiBza2lsbCknKQogICAgYXAoJyMgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAtICBMaW51eCAmIG1hY09TJykKICAgIGFwKCcjID09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09JykKICAgIGFwKCcjICBTZWxmLWNvbnRhaW5lZDogZXZlcnkgZmlsZSB0aGUgaW5z
>> "!B64TMP!" echo dGFsbGVyIG5lZWRzIGlzIGVtYmVkZGVkIGJlbG93IGFzIGEnKQogICAgYXAoJyMgIHF1b3RlZCBo
>> "!B64TMP!" echo ZXJlZG9jLiBJZiBhIHNvdXJjZSBmaWxlIGlzIG1pc3NpbmcgZnJvbSB0aGlzIHNjcmlwdFwncyBm
>> "!B64TMP!" echo b2xkZXInKQogICAgYXAoJyMgIChlLmcuIHlvdSBvbmx5IGRvd25sb2FkZWQgdGhpcyBvbmUgLnNo
>> "!B64TMP!" echo KSwgdGhlIGVtYmVkZGVkIGNvcHkgaXMgdXNlZC4nKQogICAgYXAoJyMgIEFmdGVyIGluc3RhbGxp
>> "!B64TMP!" echo bmcgdGhlIHN0YWNrIGl0IGFsc28gY29waWVzIHRoZSBidW5kbGVkIGxvY2FsLXdlYiBhZ2VudCcp
>> "!B64TMP!" echo CiAgICBhcCgnIyAgc2tpbGwgaW50byB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi4nKQogICAg
>> "!B64TMP!" echo YXAoJyMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJycpCiAgICBhcCgnc2V0IC11JykK
>> "!B64TMP!" echo ICAgIGFwKCcnKQogICAgYXAoJ0JPTEQ9IlxcMDMzWzFtIjsgRElNPSJcXDAzM1sybSI7IEdSRUVO
>> "!B64TMP!" echo PSJcXDAzM1szMm0iOyBZRUxMT1c9IlxcMDMzWzMzbSI7IFJFRD0iXFwwMzNbMzFtIjsgQ1lBTj0i
>> "!B64TMP!" echo XFwwMzNbMzZtIjsgUkVTRVQ9IlxcMDMzWzBtIicpCiAgICBhcCgnc2F5KCkgIHsgcHJpbnRmICIl
>> "!B64TMP!" echo YlxcbiIgIiQxIjsgfScpCiAgICBhcCgnZXJyKCkgIHsgcHJpbnRmICIlYltFUlJPUl0lYiAlc1xc
>> "!B64TMP!" echo biIgIiRSRUQiICIkUkVTRVQiICIkMSIgPiYyOyB9JykKICAgIGFwKCdvaygpICAgeyBwcmludGYg
>> "!B64TMP!" echo IiViW09LXSViICVzXFxuIiAiJEdSRUVOIiAiJFJFU0VUIiAiJDEiOyB9JykKICAgIGFwKCdoZHIo
>> "!B64TMP!" echo KSAgeyBwcmludGYgIlxcbiViLS0tICVzIC0tLSViXFxuIiAiJENZQU4iICIkMSIgIiRSRVNFVCI7
>> "!B64TMP!" echo IH0nKQogICAgYXAoJ2xvd2VyKCkgeyBwcmludGYgXCclc1wnICIkMSIgfCB0ciBcJ1s6dXBwZXI6
>> "!B64TMP!" echo XVwnIFwnWzpsb3dlcjpdXCc7IH0gICMgYmFzaC0zLjIgKG1hY09TKSBzYWZlJykKICAgIGFwKCcn
>> "!B64TMP!" echo KQogICAgYXAoJ2NhdCA8PFwnQkFOTkVSXCcnKQogICAgYXAoJz09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnICBMb2Nh
>> "!B64TMP!" echo bCBTZWFyY2ggSW5zdGFsbGVyICAoRmlyZWNyYXdsICsgU2VhclhORyArIGxvY2FsLXdlYiknKQog
>> "!B64TMP!" echo ICAgYXAoJyAgQSBsb2NhbCB3ZWItYnJvd3Npbmcgc3lzdGVtIGZvciBBSSBtb2RlbHMuJykKICAg
>> "!B64TMP!" echo IGFwKCc9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT0nKQogICAgYXAoJ0JBTk5FUicpCiAgICBhcCgnJykKICAgICMgRG9ja2VyIGNoZWNr
>> "!B64TMP!" echo CiAgICBhcCgnaWYgISBjb21tYW5kIC12IGRvY2tlciA+L2Rldi9udWxsIDI+JjE7IHRoZW4nKQog
>> "!B64TMP!" echo ICAgYXAoJyAgZXJyICJEb2NrZXIgd2FzIG5vdCBmb3VuZCBvbiB5b3VyIFBBVEguIicpCiAgICBh
>> "!B64TMP!" echo cCgnICBzYXkgIiInKQogICAgYXAoJyAgc2F5ICJJbnN0YWxsIERvY2tlciBFbmdpbmUgKExpbnV4
>> "!B64TMP!" echo KSBvciBEb2NrZXIgRGVza3RvcCAobWFjT1MpOiInKQogICAgYXAoJyAgc2F5ICIgIExpbnV4OiAg
>> "!B64TMP!" echo IGh0dHBzOi8vZG9jcy5kb2NrZXIuY29tL2VuZ2luZS9pbnN0YWxsLyInKQogICAgYXAoJyAgc2F5
>> "!B64TMP!" echo ICIgIG1hY09TOiAgIGh0dHBzOi8vd3d3LmRvY2tlci5jb20vcHJvZHVjdHMvZG9ja2VyLWRlc2t0
>> "!B64TMP!" echo b3AvIicpCiAgICBhcCgnICBzYXkgIlRoZW4gcmUtcnVuIHRoaXMgaW5zdGFsbGVyLiInKQogICAg
>> "!B64TMP!" echo YXAoJyAgZXhpdCAxJykKICAgIGFwKCdmaScpCiAgICBhcCgnaWYgISBkb2NrZXIgaW5mbyA+L2Rl
>> "!B64TMP!" echo di9udWxsIDI+JjE7IHRoZW4nKQogICAgYXAoJyAgZXJyICJEb2NrZXIgaXMgaW5zdGFsbGVkIGJ1
>> "!B64TMP!" echo dCB0aGUgZW5naW5lIGlzIG5vdCBydW5uaW5nLiInKQogICAgYXAoJyAgc2F5ICIiJykKICAgIGFw
>> "!B64TMP!" echo KCcgIHNheSAiTGludXg6IHN0YXJ0IHRoZSBzZXJ2aWNlIChlLmcuIFwnc3VkbyBzeXN0ZW1jdGwg
>> "!B64TMP!" echo c3RhcnQgZG9ja2VyXCcgb3IgYWRkIicpCiAgICBhcCgnICBzYXkgIiAgICAgIHlvdXIgdXNlciB0
>> "!B64TMP!" echo byB0aGUgZG9ja2VyIGdyb3VwIGFuZCByZS1sb2cgaW4pLiInKQogICAgYXAoJyAgc2F5ICJtYWNP
>> "!B64TMP!" echo Uzogc3RhcnQgRG9ja2VyIERlc2t0b3AgYW5kIHdhaXQgdW50aWwgaXQgc2F5cyBcJ3J1bm5pbmdc
>> "!B64TMP!" echo Jy4iJykKICAgIGFwKCcgIGV4aXQgMScpCiAgICBhcCgnZmknKQogICAgYXAoJ2lmIGRvY2tlciBj
>> "!B64TMP!" echo b21wb3NlIHZlcnNpb24gPi9kZXYvbnVsbCAyPiYxOyB0aGVuIERDPSJkb2NrZXIgY29tcG9zZSIn
>> "!B64TMP!" echo KQogICAgYXAoJ2VsaWYgY29tbWFuZCAtdiBkb2NrZXItY29tcG9zZSA+L2Rldi9udWxsIDI+JjE7
>> "!B64TMP!" echo IHRoZW4gREM9ImRvY2tlci1jb21wb3NlIicpCiAgICBhcCgnZWxzZSBlcnIgIkRvY2tlciBDb21w
>> "!B64TMP!" echo b3NlIHdhcyBub3QgZm91bmQuIEluc3RhbGwgdGhlIFwnZG9ja2VyIGNvbXBvc2VcJyBwbHVnaW4g
>> "!B64TMP!" echo KHYyKS4iOyBleGl0IDE7IGZpJykKICAgIGFwKCdvayAiRG9ja2VyIGFuZCBEb2NrZXIgQ29tcG9z
>> "!B64TMP!" echo ZSBhcmUgYXZhaWxhYmxlICgkREMpLiInKQogICAgYXAoJycpCiAgICAjIFNvdXJjZSBmb2xkZXIK
>> "!B64TMP!" echo ICAgIGFwKCdTUkM9IiQoY2QgIiQoZGlybmFtZSAiJDAiKSIgJiYgcHdkKSInKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICAjIFByb21wdHMKICAgIGFwKCdERUZBVUxUX1RBUkdFVD0iJEhPTUUvbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo IicpCiAgICBhcCgnaGRyICJTdGVwIDEgb2YgNDogSW5zdGFsbCBsb2NhdGlvbiInKQogICAgYXAo
>> "!B64TMP!" echo J3NheSAiICBEZWZhdWx0OiAkREVGQVVMVF9UQVJHRVQiJykKICAgIGFwKCdwcmludGYgIiAgVGFy
>> "!B64TMP!" echo Z2V0IGZvbGRlciBbcHJlc3MgRW50ZXIgZm9yIGRlZmF1bHRdOiAiJykKICAgIGFwKCdyZWFkIC1y
>> "!B64TMP!" echo IFRBUkdFVCcpCiAgICBhcCgnWyAteiAiJFRBUkdFVCIgXSAmJiBUQVJHRVQ9IiRERUZBVUxUX1RB
>> "!B64TMP!" echo UkdFVCInKQogICAgYXAoJ2lmIFsgIiR7VEFSR0VUI1xcfn0iICE9ICIkVEFSR0VUIiBdOyB0aGVu
>> "!B64TMP!" echo IFRBUkdFVD0iJEhPTUUke1RBUkdFVCNcXH59IjsgZmkgICMgUE9TSVggdGlsZGUgZXhwYW5zaW9u
>> "!B64TMP!" echo JykKICAgIGFwKCdta2RpciAtcCAiJFRBUkdFVCInKQogICAgYXAoJ1RBUkdFVD0iJChjZCAiJFRB
>> "!B64TMP!" echo UkdFVCIgJiYgcHdkKSInKQogICAgYXAoJ3NheSAiICBVc2luZzogJFRBUkdFVCInKQogICAgYXAo
>> "!B64TMP!" echo JycpCiAgICBhcCgndmFsaWRhdGVfcG9ydCgpIHsnKQogICAgYXAoJyAgbG9jYWwgcD0iJDEiJykK
>> "!B64TMP!" echo ICAgIGFwKCcgIFtbICIkcCIgPX4gXlswLTldKyQgXV0gfHwgcmV0dXJuIDEnKQogICAgYXAoJyAg
>> "!B64TMP!" echo WyAiJHAiIC1nZSAxIF0gMj4vZGV2L251bGwgfHwgcmV0dXJuIDEnKQogICAgYXAoJyAgWyAiJHAi
>> "!B64TMP!" echo IC1sZSA2NTUzNSBdIDI+L2Rldi9udWxsIHx8IHJldHVybiAxJykKICAgIGFwKCcgIHJldHVybiAw
>> "!B64TMP!" echo JykKICAgIGFwKCd9JykKICAgIGFwKCcnKQogICAgYXAoJ2hkciAiU3RlcCAyIG9mIDQ6IFNlYXJY
>> "!B64TMP!" echo TkcgcG9ydCAoZGVmYXVsdCA5OTkwKSInKQogICAgYXAoJ3doaWxlIHRydWU7IGRvJykKICAgIGFw
>> "!B64TMP!" echo KCcgIHByaW50ZiAiICBQb3J0IGZvciBTZWFyWE5HIFtwcmVzcyBFbnRlciBmb3IgOTk5MF06ICIn
>> "!B64TMP!" echo KQogICAgYXAoJyAgcmVhZCAtciBTRUFSWE5HX1BPUlQnKQogICAgYXAoJyAgWyAteiAiJFNFQVJY
>> "!B64TMP!" echo TkdfUE9SVCIgXSAmJiBTRUFSWE5HX1BPUlQ9OTk5MCcpCiAgICBhcCgnICBpZiB2YWxpZGF0ZV9w
>> "!B64TMP!" echo b3J0ICIkU0VBUlhOR19QT1JUIjsgdGhlbiBicmVhazsgZmknKQogICAgYXAoJyAgc2F5ICIgICR7
>> "!B64TMP!" echo WUVMTE9XfVshXSR7UkVTRVR9IFwnJFNFQVJYTkdfUE9SVFwnIGlzIG5vdCBhIHZhbGlkIHBvcnQg
>> "!B64TMP!" echo KDEtNjU1MzUpLiInKQogICAgYXAoJ2RvbmUnKQogICAgYXAoJycpCiAgICBhcCgnaGRyICJTdGVw
>> "!B64TMP!" echo IDMgb2YgNDogRmlyZWNyYXdsIHBvcnQgKGRlZmF1bHQgOTk5MSkiJykKICAgIGFwKCd3aGlsZSB0
>> "!B64TMP!" echo cnVlOyBkbycpCiAgICBhcCgnICBwcmludGYgIiAgUG9ydCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBF
>> "!B64TMP!" echo bnRlciBmb3IgOTk5MV06ICInKQogICAgYXAoJyAgcmVhZCAtciBGSVJFQ1JBV0xfUE9SVCcpCiAg
>> "!B64TMP!" echo ICBhcCgnICBbIC16ICIkRklSRUNSQVdMX1BPUlQiIF0gJiYgRklSRUNSQVdMX1BPUlQ9OTk5MScp
>> "!B64TMP!" echo CiAgICBhcCgnICBpZiAhIHZhbGlkYXRlX3BvcnQgIiRGSVJFQ1JBV0xfUE9SVCI7IHRoZW4nKQog
>> "!B64TMP!" echo ICAgYXAoJyAgICBzYXkgIiAgJHtZRUxMT1d9WyFdJHtSRVNFVH0gXCckRklSRUNSQVdMX1BPUlRc
>> "!B64TMP!" echo JyBpcyBub3QgYSB2YWxpZCBwb3J0ICgxLTY1NTM1KS4iJykKICAgIGFwKCcgICAgY29udGludWUn
>> "!B64TMP!" echo KQogICAgYXAoJyAgZmknKQogICAgYXAoJyAgaWYgWyAiJEZJUkVDUkFXTF9QT1JUIiA9ICIkU0VB
>> "!B64TMP!" echo UlhOR19QT1JUIiBdOyB0aGVuJykKICAgIGFwKCcgICAgc2F5ICIgICR7WUVMTE9XfVshXSR7UkVT
>> "!B64TMP!" echo RVR9IEZpcmVjcmF3bCBwb3J0IG11c3QgZGlmZmVyIGZyb20gU2VhclhORyBwb3J0LiInKQogICAg
>> "!B64TMP!" echo YXAoJyAgICBjb250aW51ZScpCiAgICBhcCgnICBmaScpCiAgICBhcCgnICBicmVhaycpCiAgICBh
>> "!B64TMP!" echo cCgnZG9uZScpCiAgICBhcCgnJykKICAgIGFwKCdoZHIgIlN0ZXAgNCBvZiA0OiBMb2NhbCBMTE0g
>> "!B64TMP!" echo KG9wdGlvbmFsKSInKQogICAgYXAoJ3NheSAiICBMZXRzIEZpcmVjcmF3bCBkbyBBSSBleHRyYWN0
>> "!B64TMP!" echo aW9uICgvdjEvZXh0cmFjdCkgYW5kIHN1bW1hcmllcy4iJykKICAgIGFwKCdzYXkgIiAgUmVjb21t
>> "!B64TMP!" echo ZW5kZWQ6IExNIFN0dWRpbyAtPiBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEiJykKICAgIGFwKCdw
>> "!B64TMP!" echo cmludGYgIiAgQ29ubmVjdCBhIGxvY2FsIExMTSBub3c/IFt5L05dOiAiJykKICAgIGFwKCdyZWFk
>> "!B64TMP!" echo IC1yIFVTRV9MTE0nKQogICAgYXAoJ09QRU5BSV9CQVNFX1VSTD0iIjsgT1BFTkFJX0FQSV9LRVk9
>> "!B64TMP!" echo IiI7IE1PREVMX05BTUU9IiInKQogICAgYXAoJ2lmIFsgIiQobG93ZXIgIiRVU0VfTExNIikiID0g
>> "!B64TMP!" echo InkiIF07IHRoZW4nKQogICAgYXAoJyAgcHJpbnRmICIgICAgTE0gU3R1ZGlvIHNlcnZlciBVUkwg
>> "!B64TMP!" echo KGFzIHNob3duIGluIExNIFN0dWRpbykgW3ByZXNzIEVudGVyIGZvciBodHRwOi8vbG9jYWxob3N0
>> "!B64TMP!" echo OjEyMzQvdjFdOiAiJykKICAgIGFwKCcgIHJlYWQgLXIgTExNX1VSTCcpCiAgICBhcCgnICBbIC16
>> "!B64TMP!" echo ICIkTExNX1VSTCIgXSAmJiBMTE1fVVJMPSJodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEiJykKICAg
>> "!B64TMP!" echo IGFwKCcgIHByaW50ZiAiICAgIE1vZGVsIG5hbWUgKGlkIGxvYWRlZCBpbiBMTSBTdHVkaW8pIFtw
>> "!B64TMP!" echo cmVzcyBFbnRlciB0byBza2lwXTogIicpCiAgICBhcCgnICByZWFkIC1yIExMTV9NT0RFTCcpCiAg
>> "!B64TMP!" echo ICBhcCgnICBPUEVOQUlfQkFTRV9VUkw9IiR7TExNX1VSTC9odHRwOlxcL1xcL2xvY2FsaG9zdC9o
>> "!B64TMP!" echo dHRwOlxcL1xcL2hvc3QuZG9ja2VyLmludGVybmFsfSInKQogICAgYXAoJyAgT1BFTkFJX0JBU0Vf
>> "!B64TMP!" echo VVJMPSIke09QRU5BSV9CQVNFX1VSTC9odHRwOlxcL1xcLzEyNy4wLjAuMS9odHRwOlxcL1xcL2hv
>> "!B64TMP!" echo c3QuZG9ja2VyLmludGVybmFsfSInKQogICAgYXAoJyAgT1BFTkFJX0FQSV9LRVk9ImxtLXN0dWRp
>> "!B64TMP!" echo byInKQogICAgYXAoJyAgWyAtbiAiJExMTV9NT0RFTCIgXSAmJiBNT0RFTF9OQU1FPSIkTExNX01P
>> "!B64TMP!" echo REVMIicpCiAgICBhcCgnICBzYXkgIiAgICAoQ29udGFpbmVyIHdpbGwgcmVhY2ggaXQgYXQ6ICRP
>> "!B64TMP!" echo UEVOQUlfQkFTRV9VUkwpIicpCiAgICBhcCgnICBzYXkgIiAgICAoTWFrZSBzdXJlIExNIFN0dWRp
>> "!B64TMP!" echo byBoYXMgXCdTZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrXCcgZW5hYmxlZC4pIicpCiAgICBhcCgnZmkn
>> "!B64TMP!" echo KQogICAgYXAoJycpCiAgICAjIFN1bW1hcnkgKyBjb25maXJtCiAgICBhcCgnZWNobycpCiAgICBh
>> "!B64TMP!" echo cCgnc2F5ICIke0JPTER9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09JHtSRVNFVH0iJykKICAgIGFwKCdzYXkgIiR7Qk9MRH0gIFN1bW1h
>> "!B64TMP!" echo cnkke1JFU0VUfSInKQogICAgYXAoJ3NheSAiICBGb2xkZXI6ICAgICAgICAgJFRBUkdFVCInKQog
>> "!B64TMP!" echo ICAgYXAoJ3NheSAiICBTZWFyWE5HIHBvcnQ6ICAgJFNFQVJYTkdfUE9SVCInKQogICAgYXAoJ3Nh
>> "!B64TMP!" echo eSAiICBGaXJlY3Jhd2wgcG9ydDogJEZJUkVDUkFXTF9QT1JUIicpCiAgICBhcCgnc2F5ICIgIEFn
>> "!B64TMP!" echo ZW50IHNraWxsOiAgICAkSE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIiJykKICAgIGFwKCdp
>> "!B64TMP!" echo ZiBbIC1uICIkT1BFTkFJX0JBU0VfVVJMIiBdOyB0aGVuJykKICAgIGFwKCcgIHNheSAiICBMTE0g
>> "!B64TMP!" echo ZW5kcG9pbnQ6ICAgJE9QRU5BSV9CQVNFX1VSTCAgJE1PREVMX05BTUUiJykKICAgIGFwKCdlbHNl
>> "!B64TMP!" echo JykKICAgIGFwKCcgIHNheSAiICBMTE0gZW5kcG9pbnQ6ICAgKG5vbmUgLSBlbmFibGUgbGF0ZXIg
>> "!B64TMP!" echo YnkgZWRpdGluZyAuZW52KSInKQogICAgYXAoJ2ZpJykKICAgIGFwKCdzYXkgIiR7Qk9MRH09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0k
>> "!B64TMP!" echo e1JFU0VUfSInKQogICAgYXAoJ3ByaW50ZiAiUHJvY2VlZCB3aXRoIGluc3RhbGw/IFtZL25dOiAi
>> "!B64TMP!" echo JykKICAgIGFwKCdyZWFkIC1yIENPTkZJUk0nKQogICAgYXAoJ2lmIFsgIiQobG93ZXIgIiRDT05G
>> "!B64TMP!" echo SVJNIikiID0gIm4iIF07IHRoZW4gc2F5ICJJbnN0YWxsIGNhbmNlbGxlZC4iOyBleGl0IDA7IGZp
>> "!B64TMP!" echo JykKICAgIGFwKCcnKQogICAgIyBDcmVhdGUgZm9sZGVycwogICAgYXAoJ21rZGlyIC1wICIkVEFS
>> "!B64TMP!" echo R0VUL2NvbmZpZy9zZWFyeG5nIiAiJFRBUkdFVC9sb2NhbC13ZWIvc2NyaXB0cyInKQogICAgYXAo
>> "!B64TMP!" echo JycpCiAgICAjIEJhY2t1cCBleGlzdGluZyAuZW52CiAgICBhcCgnaWYgWyAtZiAiJFRBUkdFVC8u
>> "!B64TMP!" echo ZW52IiBdOyB0aGVuJykKICAgIGFwKCcgIExEVD0iJChkYXRlICslWSVtJWQlSCVNJVMpIicpCiAg
>> "!B64TMP!" echo ICBhcCgnICBjcCAiJFRBUkdFVC8uZW52IiAiJFRBUkdFVC8uZW52LmJhay4kTERUIicpCiAgICBh
>> "!B64TMP!" echo cCgnICBzYXkgIiAgQmFja2VkIHVwIGV4aXN0aW5nIC5lbnYgdG8gLmVudi5iYWsuJExEVCInKQog
>> "!B64TMP!" echo ICAgYXAoJ2ZpJykKICAgIGFwKCcnKQogICAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgICAjICBNYXRlcmlhbGlz
>> "!B64TMP!" echo ZSBldmVyeSBwcm9qZWN0IGZpbGU6IGNvcHkgZnJvbSBzb3VyY2UgaWYgcHJlc2VudCwgZWxzZQog
>> "!B64TMP!" echo ICAgIyAgdXNlIHRoZSBlbWJlZGRlZCBoZXJlZG9jIGZvciB0aGF0IGZpbGUuCiAgICAjIC0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0KICAgIGFwKCdzYXkgIkNvcHlpbmcgYWxsIHByb2plY3QgZmlsZXMuLi4iJykKCiAgICBm
>> "!B64TMP!" echo b3IgcmVsLCBzcmMgaW4gRklMRVM6CiAgICAgICAgZGF0YSA9IHJlYWQoc3JjKQogICAgICAgIHRl
>> "!B64TMP!" echo eHQgPSBkYXRhLmRlY29kZSgidXRmLTgiKQogICAgICAgIHRhZyA9ICJFT0ZfIiArICIiLmpvaW4o
>> "!B64TMP!" echo YyBpZiBjLmlzYWxudW0oKSBlbHNlICJfIiBmb3IgYyBpbiByZWwpLnVwcGVyKCkKICAgICAgICBh
>> "!B64TMP!" echo cCgnJykKICAgICAgICBhcCgnIyAtLS0gJyArIHJlbCArICcgLS0tJykKICAgICAgICBhcCgnaWYg
>> "!B64TMP!" echo WyAtZiAiJFNSQy8nICsgcmVsICsgJyIgXTsgdGhlbicpCiAgICAgICAgYXAoJyAgY3AgIiRTUkMv
>> "!B64TMP!" echo JyArIHJlbCArICciICIkVEFSR0VULycgKyByZWwgKyAnIicpCiAgICAgICAgYXAoJ2Vsc2UnKQog
>> "!B64TMP!" echo ICAgICAgIGFwKCcgIHNheSAiICBbZW1iZWRkZWRdICcgKyByZWwgKyAnICAoc291cmNlIG5vdCBm
>> "!B64TMP!" echo b3VuZCBuZXh0IHRvIGluc3RhbGxlcjsgdXNpbmcgYnVpbHQtaW4gY29weSkiJykKICAgICAgICBh
>> "!B64TMP!" echo cCgnICBjYXQgPiAiJFRBUkdFVC8nICsgcmVsICsgJyIgPDxcJycgKyB0YWcgKyAnXCcnKQogICAg
>> "!B64TMP!" echo ICAgICMgTm9ybWFsaXNlIGxpbmUgZW5kaW5ncyB0byBMRiBpbiB0aGUgaGVyZWRvYyBib2R5IHNv
>> "!B64TMP!" echo IHRoZSBydW50aW1lCiAgICAgICAgIyBDUkxGLWNvbnZlcnNpb24gbG9vcCBwcm9kdWNlcyBjbGVh
>> "!B64TMP!" echo biBDUkxGIChub3QgXHJcclxuKSBmb3IgLmJhdCBmaWxlcy4KICAgICAgICAjIHNwbGl0bGluZXMo
>> "!B64TMP!" echo KSBhdm9pZHMgYSBzcHVyaW91cyB0cmFpbGluZyBlbXB0eSBsaW5lIHRoYXQgd291bGQKICAgICAg
>> "!B64TMP!" echo ICAjIG90aGVyd2lzZSBhZGQgYSBibGFuayBsaW5lIGF0IHRoZSBlbmQgb2YgZXZlcnkgZW1iZWRk
>> "!B64TMP!" echo ZWQgZmlsZS4KICAgICAgICB0ZXh0X2xmID0gdGV4dC5yZXBsYWNlKCJcclxuIiwgIlxuIikucmVw
>> "!B64TMP!" echo bGFjZSgiXHIiLCAiXG4iKQogICAgICAgIGZvciBsaW5lIGluIHRleHRfbGYuc3BsaXRsaW5lcygp
>> "!B64TMP!" echo OgogICAgICAgICAgICBhcChsaW5lKQogICAgICAgIGFwKHRhZykKICAgICAgICBhcCgnZmknKQoK
>> "!B64TMP!" echo ICAgICMgaW5jbHVkZSB0aGUgaW5zdGFsbGVycyB0aGVtc2VsdmVzCiAgICBhcCgnWyAtZiAiJFNS
>> "!B64TMP!" echo Qy9pbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCIgXSAmJiBjcCAiJFNSQy9pbnN0YWxsLWxvY2FsLXNl
>> "!B64TMP!" echo YXJjaC5zaCIgIiRUQVJHRVQvaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giJykKICAgIGFwKCdbIC1m
>> "!B64TMP!" echo ICIkU1JDL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCIgXSAmJiBjcCAiJFNSQy9pbnN0YWxsLWxv
>> "!B64TMP!" echo Y2FsLXNlYXJjaC5iYXQiICIkVEFSR0VUL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCInKQogICAg
>> "!B64TMP!" echo YXAoJyMgQWx3YXlzIGFsc28gZHJvcCB0aGUgKmN1cnJlbnQqIGluc3RhbGxlciAodGhpcyBzY3Jp
>> "!B64TMP!" echo cHQpIGludG8gdGFyZ2V0LCBldmVuJykKICAgIGFwKCcjIGlmIGl0IHdhcyByZW5hbWVkICh0aGUg
>> "!B64TMP!" echo Y2hlY2sgYWJvdmUgbG9va3MgZm9yIHRoZSBjYW5vbmljYWwgbmFtZSkuJykKICAgIGFwKCdjcCAt
>> "!B64TMP!" echo ZiAiJDAiICIkVEFSR0VUL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiAyPi9kZXYvbnVsbCB8fCB0
>> "!B64TMP!" echo cnVlJykKICAgIGFwKCdjaG1vZCAreCAiJFRBUkdFVCIvKi5zaCAyPi9kZXYvbnVsbCB8fCB0cnVl
>> "!B64TMP!" echo JykKICAgIGFwKCcnKQogICAgIyBFbnN1cmUgZXZlcnkgLmJhdCBmaWxlIGluIFRBUkdFVCBoYXMg
>> "!B64TMP!" echo Q1JMRiBsaW5lIGVuZGluZ3MgKFdpbmRvd3MgY21kIGlzCiAgICAjIGhhcHBpZXIgd2l0aCBDUkxG
>> "!B64TMP!" echo OyB0aGUgaGVyZWRvY3MgYWJvdmUgd3JvdGUgTEYsIHdoaWNoIHdvcmtzIGJ1dCBpc24ndAogICAg
>> "!B64TMP!" echo IyBpZGVhbCB3aGVuIHRoZSBmb2xkZXIgaXMgbGF0ZXIgY29waWVkIHRvIGEgV2luZG93cyBtYWNo
>> "!B64TMP!" echo aW5lKS4KICAgICMgVGhlIHNlZCBpcyBpZGVtcG90ZW50OiBzdHJpcCBhbnkgdHJhaWxpbmcgQ1Ig
>> "!B64TMP!" echo Zmlyc3QsIHRoZW4gYWRkIG9uZSBiYWNrLAogICAgIyBzbyBmaWxlcyBjb3BpZWQgZnJvbSBzb3Vy
>> "!B64TMP!" echo Y2UgKGFscmVhZHkgQ1JMRikgYXJlIG5vdCBkb3VibGUtY29udmVydGVkLgogICAgYXAoJ2ZvciBm
>> "!B64TMP!" echo IGluICIkVEFSR0VUIi8qLmJhdDsgZG8nKQogICAgYXAoJyAgWyAtZiAiJGYiIF0gfHwgY29udGlu
>> "!B64TMP!" echo dWUnKQogICAgYXAoJyAgaWYgY29tbWFuZCAtdiBhd2sgPi9kZXYvbnVsbCAyPiYxOyB0aGVuJykK
>> "!B64TMP!" echo ICAgIGFwKCcgICAgYXdrIFwne3N1YigvXFxyJC8sIiIpOyBwcmludGYgIiVzXFxyXFxuIiwgJDB9
>> "!B64TMP!" echo XCcgIiRmIiA+ICIkZi5jcmxmIiAyPi9kZXYvbnVsbCAmJiBtdiAiJGYuY3JsZiIgIiRmIiB8fCBy
>> "!B64TMP!" echo bSAtZiAiJGYuY3JsZiInKQogICAgYXAoJyAgZmknKQogICAgYXAoJ2RvbmUnKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICAjIEdlbmVyYXRlIHNlY3JldHMKICAgIGFwKCdzYXkgIkdlbmVyYXRpbmcgc2VjdXJlIGNy
>> "!B64TMP!" echo ZWRlbnRpYWxzLi4uIicpCiAgICBhcCgnZ2Vua2V5KCkgeycpCiAgICBhcCgnICBpZiBjb21tYW5k
>> "!B64TMP!" echo IC12IG9wZW5zc2wgPi9kZXYvbnVsbCAyPiYxOyB0aGVuIG9wZW5zc2wgcmFuZCAtaGV4IDMyJykK
>> "!B64TMP!" echo ICAgIGFwKCcgIGVsc2UgaGVhZCAtYyAzMiAvZGV2L3VyYW5kb20gfCBvZCAtQW4gLXR4MSB8IHRy
>> "!B64TMP!" echo IC1kIFwnIFxcblwnOyBmaScpCiAgICBhcCgnfScpCiAgICBhcCgnU0VDUkVUPSIkKGdlbmtleSki
>> "!B64TMP!" echo OyBCVUxMPSIkKGdlbmtleSkiOyBQR1BBU1M9IiQoZ2Vua2V5KSI7IFJBQlBBU1M9IiQoZ2Vua2V5
>> "!B64TMP!" echo KSInKQogICAgYXAoJycpCiAgICAjIFdyaXRlIC5lbnYKICAgIGFwKCdzYXkgIldyaXRpbmcgLmVu
>> "!B64TMP!" echo diAuLi4iJykKICAgIGFwKCd7JykKICAgIGFwKCcgIGVjaG8gIiMgTG9jYWwgU2VhcmNoIGNvbmZp
>> "!B64TMP!" echo Z3VyYXRpb24gLSBnZW5lcmF0ZWQgYnkgaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giJykKICAgIGFw
>> "!B64TMP!" echo KCcgIGVjaG8gIiMgRWRpdCBwb3J0cy9MTE0gaGVyZSwgdGhlbiBydW4gdXBkYXRlLnNoIHRvIGFw
>> "!B64TMP!" echo cGx5LiInKQogICAgYXAoJyAgZWNobycpCiAgICBhcCgnICBlY2hvICIjIC0tLS0gSG9zdCBwb3J0
>> "!B64TMP!" echo cyAtLS0tIicpCiAgICBhcCgnICBlY2hvICJTRUFSWE5HX1BPUlQ9JFNFQVJYTkdfUE9SVCInKQog
>> "!B64TMP!" echo ICAgYXAoJyAgZWNobyAiRklSRUNSQVdMX1BPUlQ9JEZJUkVDUkFXTF9QT1JUIicpCiAgICBhcCgn
>> "!B64TMP!" echo ICBlY2hvJykKICAgIGFwKCcgIGVjaG8gIiMgLS0tLSBTZWFyWE5HIGluc3RhbmNlIHNlY3JldCAt
>> "!B64TMP!" echo LS0tIicpCiAgICBhcCgnICBlY2hvICJTRUFSWE5HX1NFQ1JFVD0kU0VDUkVUIicpCiAgICBhcCgn
>> "!B64TMP!" echo ICBlY2hvJykKICAgIGFwKCcgIGVjaG8gIiMgLS0tLSBGaXJlY3Jhd2wgaW50ZXJuYWwgY3JlZGVu
>> "!B64TMP!" echo dGlhbHMgLS0tLSInKQogICAgYXAoJyAgZWNobyAiQlVMTF9BVVRIX0tFWT0kQlVMTCInKQogICAg
>> "!B64TMP!" echo YXAoJyAgZWNobyAiUE9TVEdSRVNfREI9ZmlyZWNyYXdsIicpCiAgICBhcCgnICBlY2hvICJQT1NU
>> "!B64TMP!" echo R1JFU19VU0VSPWZpcmVjcmF3bCInKQogICAgYXAoJyAgZWNobyAiUE9TVEdSRVNfUEFTU1dPUkQ9
>> "!B64TMP!" echo JFBHUEFTUyInKQogICAgYXAoJyAgZWNobyAiUkFCQklUTVFfVVNFUj1maXJlY3Jhd2wiJykKICAg
>> "!B64TMP!" echo IGFwKCcgIGVjaG8gIlJBQkJJVE1RX1BBU1NXT1JEPSRSQUJQQVNTIicpCiAgICBhcCgnICBlY2hv
>> "!B64TMP!" echo JykKICAgIGFwKCcgIGVjaG8gIkxPR0dJTkdfTEVWRUw9aW5mbyInKQogICAgYXAoJyAgaWYgWyAt
>> "!B64TMP!" echo biAiJE9QRU5BSV9CQVNFX1VSTCIgXTsgdGhlbicpCiAgICBhcCgnICAgIGVjaG8nKQogICAgYXAo
>> "!B64TMP!" echo JyAgICBlY2hvICIjIC0tLS0gTG9jYWwgTExNIGZvciBGaXJlY3Jhd2wgQUkgZmVhdHVyZXMgLS0t
>> "!B64TMP!" echo LSInKQogICAgYXAoJyAgICBlY2hvICJPUEVOQUlfQkFTRV9VUkw9JE9QRU5BSV9CQVNFX1VSTCIn
>> "!B64TMP!" echo KQogICAgYXAoJyAgICBlY2hvICJPUEVOQUlfQVBJX0tFWT0kT1BFTkFJX0FQSV9LRVkiJykKICAg
>> "!B64TMP!" echo IGFwKCcgICAgWyAtbiAiJE1PREVMX05BTUUiIF0gJiYgZWNobyAiTU9ERUxfTkFNRT0kTU9ERUxf
>> "!B64TMP!" echo TkFNRSInKQogICAgYXAoJyAgZmknKQogICAgYXAoJ30gPiAiJFRBUkdFVC8uZW52IicpCiAgICBh
>> "!B64TMP!" echo cCgnJykKICAgICMgSW5qZWN0IHNlY3JldAogICAgYXAoJ3NheSAiSW5qZWN0aW5nIFNlYXJYTkcg
>> "!B64TMP!" echo c2VjcmV0IGludG8gc2V0dGluZ3MueW1sIC4uLiInKQogICAgYXAoJ1NGSUxFPSIkVEFSR0VUL2Nv
>> "!B64TMP!" echo bmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbCInKQogICAgYXAoJ3NlZCAicy9fX1NFQVJYTkdfU0VD
>> "!B64TMP!" echo UkVUX1BMQUNFSE9MREVSX18vJFNFQ1JFVC8iICIkU0ZJTEUiID4gIiRTRklMRS50bXAiICYmIG12
>> "!B64TMP!" echo ICIkU0ZJTEUudG1wIiAiJFNGSUxFIicpCiAgICBhcCgnJykKICAgICMgLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAg
>> "!B64TMP!" echo IyAgSW5zdGFsbCB0aGUgYnVuZGxlZCBsb2NhbC13ZWIgYWdlbnQgc2tpbGwgaW50byB0aGUgdXNl
>> "!B64TMP!" echo cidzIHNraWxscwogICAgIyAgZGlyZWN0b3J5IChhZGQvb3ZlcnJpZGUpLCBhbmQgcmVjb3JkIHRo
>> "!B64TMP!" echo ZSBpbnN0YWxsIHBhdGggaGludC4KICAgICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgYXAoJ3NheSAiSW5zdGFs
>> "!B64TMP!" echo bGluZyB0aGUgbG9jYWwtd2ViIGFnZW50IHNraWxsLi4uIicpCiAgICBhcCgnU0tJTExfRElSPSIk
>> "!B64TMP!" echo SE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIiJykKICAgIGFwKCdybSAtcmYgIiRTS0lMTF9E
>> "!B64TMP!" echo SVIiJykKICAgIGFwKCdta2RpciAtcCAiJEhPTUUvLmFnZW50cy9za2lsbHMiJykKICAgIGFwKCdp
>> "!B64TMP!" echo ZiBjcCAtciAiJFRBUkdFVC9sb2NhbC13ZWIiICIkU0tJTExfRElSIjsgdGhlbicpCiAgICBhcCgn
>> "!B64TMP!" echo ICBwcmludGYgXCclc1xcblwnICIkVEFSR0VUIiA+ICIkVEFSR0VUL2xvY2FsLXdlYi9pbnN0YWxs
>> "!B64TMP!" echo LWRpci50eHQiJykKICAgIGFwKCcgIHByaW50ZiBcJyVzXFxuXCcgIiRUQVJHRVQiID4gIiRTS0lM
>> "!B64TMP!" echo TF9ESVIvaW5zdGFsbC1kaXIudHh0IicpCiAgICBhcCgnICBzYXkgIiAgQWdlbnQgc2tpbGwgaW5z
>> "!B64TMP!" echo dGFsbGVkOiAkU0tJTExfRElSIicpCiAgICBhcCgnZWxzZScpCiAgICBhcCgnICBzYXkgIiAgJHtZ
>> "!B64TMP!" echo RUxMT1d9W1dBUk5JTkddJHtSRVNFVH0gY291bGQgbm90IGNvcHkgdGhlIGxvY2FsLXdlYiBza2ls
>> "!B64TMP!" echo bCB0byAkU0tJTExfRElSIicpCiAgICBhcCgnZmknKQogICAgYXAoJycpCiAgICAjIFB1bGwgKyB1
>> "!B64TMP!" echo cAogICAgYXAoJ2VjaG8nKQogICAgYXAoJ3NheSAiUHVsbGluZyBEb2NrZXIgaW1hZ2VzIChmaXJz
>> "!B64TMP!" echo dCBydW4gZG93bmxvYWRzIH4zLTQgR0IsIHBsZWFzZSBiZSBwYXRpZW50KS4uLiInKQogICAgYXAo
>> "!B64TMP!" echo J2NkICIkVEFSR0VUIicpCiAgICBhcCgnJERDIHB1bGwgfHwgc2F5ICIke1lFTExPV31bV0FSTklO
>> "!B64TMP!" echo R10ke1JFU0VUfSBzb21lIGltYWdlcyBmYWlsZWQgdG8gcHVsbDsgdHJ5aW5nIHRvIHN0YXJ0IGFu
>> "!B64TMP!" echo eXdheS4iJykKICAgIGFwKCdzYXkgIlN0YXJ0aW5nIHNlcnZpY2VzLi4uIicpCiAgICBhcCgnaWYg
>> "!B64TMP!" echo ISAkREMgdXAgLWQ7IHRoZW4nKQogICAgYXAoJyAgZXJyICJkb2NrZXIgY29tcG9zZSB1cCBmYWls
>> "!B64TMP!" echo ZWQuIFNlZSBtZXNzYWdlcyBhYm92ZS4iJykKICAgIGFwKCcgIHNheSAiICBDb21tb24gZml4ZXM6
>> "!B64TMP!" echo IicpCiAgICBhcCgnICBzYXkgIiAgICAtIE1ha2Ugc3VyZSBEb2NrZXIgaXMgcnVubmluZyAoYW5k
>> "!B64TMP!" echo IHlvdXIgdXNlciBpcyBpbiB0aGUgXCdkb2NrZXJcJyBncm91cCBvbiBMaW51eCkuIicpCiAgICBh
>> "!B64TMP!" echo cCgnICBzYXkgIiAgICAtIE1ha2Ugc3VyZSBwb3J0cyAkU0VBUlhOR19QT1JUIGFuZCAkRklSRUNS
>> "!B64TMP!" echo QVdMX1BPUlQgYXJlIG5vdCBpbiB1c2UuIicpCiAgICBhcCgnICBzYXkgIiAgICAtIFJlLXJ1biB0
>> "!B64TMP!" echo aGlzIGluc3RhbGxlciBvciBydW4gdXBkYXRlLnNoIGFmdGVyIGZpeGluZy4iJykKICAgIGFwKCcg
>> "!B64TMP!" echo IGV4aXQgMScpCiAgICBhcCgnZmknKQogICAgYXAoJycpCiAgICAjIERvbmUKICAgIGFwKCdlY2hv
>> "!B64TMP!" echo JykKICAgIGFwKCdzYXkgIiR7R1JFRU59PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09JHtSRVNFVH0iJykKICAgIGFwKCdzYXkgIiR7R1JF
>> "!B64TMP!" echo RU59ICBJbnN0YWxsYXRpb24gY29tcGxldGUhJHtSRVNFVH0iJykKICAgIGFwKCdlY2hvJykKICAg
>> "!B64TMP!" echo IGFwKCdzYXkgIiAgU2VhclhORyAgKHNlYXJjaCArIEpTT04gQVBJKTogIGh0dHA6Ly9sb2NhbGhv
>> "!B64TMP!" echo c3Q6JFNFQVJYTkdfUE9SVCInKQogICAgYXAoJ3NheSAiICBGaXJlY3Jhd2wgKHNjcmFwZS9jcmF3
>> "!B64TMP!" echo bCBBUEkpOiBodHRwOi8vbG9jYWxob3N0OiRGSVJFQ1JBV0xfUE9SVCInKQogICAgYXAoJ3NheSAi
>> "!B64TMP!" echo ICBsb2NhbC13ZWIgc2tpbGw6ICAgICAgICAgICAgICAkSE9NRS8uYWdlbnRzL3NraWxscy9sb2Nh
>> "!B64TMP!" echo bC13ZWIiJykKICAgIGFwKCdlY2hvJykKICAgIGFwKCdzYXkgIiAgSWYgeW91ciBhZ2VudCB3YXMg
>> "!B64TMP!" echo YWxyZWFkeSBydW5uaW5nLCByZXN0YXJ0IGl0IHNvIGl0IHBpY2tzIHVwIicpCiAgICBhcCgnc2F5
>> "!B64TMP!" echo ICIgIHRoZSBuZXcgc2tpbGwuIicpCiAgICBhcCgnZWNobycpCiAgICBhcCgnc2F5ICIgIE1hbmFn
>> "!B64TMP!" echo ZSB0aGUgc3RhY2sgd2l0aCB0aGUgc2NyaXB0cyBpbjoiJykKICAgIGFwKCdzYXkgIiAgICAkVEFS
>> "!B64TMP!" echo R0VUIicpCiAgICBhcCgnc2F5ICIgICAgICAuL3J1bi5zaCAgIC4vc3RvcC5zaCAgIC4vdXBkYXRl
>> "!B64TMP!" echo LnNoICAgLi91bmluc3RhbGwuc2giJykKICAgIGFwKCdlY2hvJykKICAgIGFwKCdzYXkgIiAgU2Vl
>> "!B64TMP!" echo IFJFQURNRS5tZCBmb3IgaG93IHRvIGNvbm5lY3QgdGhpcyB0byB5b3VyIEFJIG1vZGVscyInKQog
>> "!B64TMP!" echo ICAgYXAoJ3NheSAiICAobG9jYWwtd2ViIHNraWxsLCBMTSBTdHVkaW8sIE1DUCBzZXJ2ZXIsIGRp
>> "!B64TMP!" echo cmVjdCBwcm9tcHRpbmcsIGV0Yy4pLiInKQogICAgYXAoJ3NheSAiJHtHUkVFTn09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0ke1JFU0VU
>> "!B64TMP!" echo fSInKQoKICAgIHJldHVybiAiXG4iLmpvaW4ob3V0KSArICJcbiIKCgpkZWYgbWFpbigpOgogICAg
>> "!B64TMP!" echo IyBJTVBPUlRBTlQ6IHdyaXRlIHRoZSAuYmF0IHRvIGRpc2sgRklSU1QsIFRIRU4gZ2VuZXJhdGUg
>> "!B64TMP!" echo dGhlIC5zaC4KICAgICMgVGhlIC5zaCBlbWJlZHMgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IGFz
>> "!B64TMP!" echo IGEgaGVyZWRvYywgc28gaXQgbXVzdCByZWFkCiAgICAjIHRoZSBmcmVzaGx5LXdyaXR0ZW4gLmJh
>> "!B64TMP!" echo dCAobm90IGEgc3RhbGUgcHJldmlvdXMtZ2VuZXJhdGlvbiBjb3B5KS4KICAgIGJhdCA9IGdlbl9i
>> "!B64TMP!" echo YXQoKQogICAgd2l0aCBvcGVuKG9zLnBhdGguam9pbihTUkMsICJpbnN0YWxsLWxvY2FsLXNlYXJj
>> "!B64TMP!" echo aC5iYXQiKSwgIndiIikgYXMgZjoKICAgICAgICBmLndyaXRlKGJhdC5lbmNvZGUoInV0Zi04Iikp
>> "!B64TMP!" echo CiAgICBzaCA9IGdlbl9zaCgpCiAgICB3aXRoIG9wZW4ob3MucGF0aC5qb2luKFNSQywgImluc3Rh
>> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLnNoIiksICJ3YiIpIGFzIGY6CiAgICAgICAgZi53cml0ZShzaC5lbmNv
>> "!B64TMP!" echo ZGUoInV0Zi04IikpCiAgICBvcy5jaG1vZChvcy5wYXRoLmpvaW4oU1JDLCAiaW5zdGFsbC1sb2Nh
>> "!B64TMP!" echo bC1zZWFyY2guc2giKSwgMG83NTUpCiAgICBwcmludCgiV3JvdGUgaW5zdGFsbC1sb2NhbC1zZWFy
>> "!B64TMP!" echo Y2guYmF0ICglZCBieXRlcykiICUgbGVuKGJhdCkpCiAgICBwcmludCgiV3JvdGUgaW5zdGFsbC1s
>> "!B64TMP!" echo b2NhbC1zZWFyY2guc2ggICglZCBieXRlcykiICUgbGVuKHNoKSkKCgppZiBfX25hbWVfXyA9PSAi
>> "!B64TMP!" echo X19tYWluX18iOgogICAgbWFpbigpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\gen_installers.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- gen_rig.py ---
set "B64TMP=%TEMP%\LSR2528458123.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKR2VuZXJhdGUgdGhlIHNlbGYtY29udGFpbmVkIGRl
>> "!B64TMP!" echo di1yaWcgcGFja2VycyBmb3IgbG9jYWwtc2VhcmNoOgogIGxvY2FsLXNlYXJjaC1yaWcuYmF0ICAg
>> "!B64TMP!" echo KFdpbmRvd3MpCiAgbG9jYWwtc2VhcmNoLXJpZy5zaCAgICAoTGludXggLyBtYWNPUyAvIEdpdCBC
>> "!B64TMP!" echo YXNoKQoKRWFjaCBwYWNrZXIgZW1iZWRzIEVWRVJZVEhJTkcgbmVlZGVkIHRvIHJlYnVpbGQgYW5k
>> "!B64TMP!" echo IHJlLXZlcmlmeSB0aGUKaW5zdGFsbC1sb2NhbC1zZWFyY2ggaW5zdGFsbGVyczoKICAqIHRoZSBm
>> "!B64TMP!" echo dWxsIGxvY2FsLXNlYXJjaCBzb3VyY2UgdHJlZSAoMjEgZmlsZXM7IHRoZSBnZW5lcmF0ZWQgaW5z
>> "!B64TMP!" echo dGFsbGVycwogICAgYXJlIE5PVCBlbWJlZGRlZCAtLSBydW4gZ2VuX2luc3RhbGxlcnMucHkgYWZ0
>> "!B64TMP!" echo ZXIgdW5wYWNraW5nIHRvIGNyZWF0ZSB0aGVtKQogICogdGhlIGJ1aWxkL3Rlc3QgcmlnIGl0c2Vs
>> "!B64TMP!" echo ZiAoZ2VuX2luc3RhbGxlcnMucHksIGdlbl9yaWcucHksIHRlc3RzLAogICAgYnVpbGQgc2NyaXB0
>> "!B64TMP!" echo cywgQlVJTEQubWQpCiAgKiB0aGUgLnNoIHBhY2tlciBhbHNvIGVtYmVkcyB0aGUgLmJhdCBwYWNr
>> "!B64TMP!" echo ZXIsIHNvIEVJVEhFUiBwYWNrZXIgYWxvbmUKICAgIHJlcHJvZHVjZXMgdGhlIGNvbXBsZXRlIHJp
>> "!B64TMP!" echo ZywgaW5jbHVkaW5nIGJvdGggcGFja2Vycy4KClNlbGYtaG9zdGluZzogdW5wYWNrIGEgcGFja2Vy
>> "!B64TMP!" echo IGFueXdoZXJlIGFuZCBydW4gYHB5dGhvbjMgZ2VuX3JpZy5weWAgaW4gdGhlCnVucGFja2VkIGZv
>> "!B64TMP!" echo bGRlciAtLSBpdCByZWdlbmVyYXRlcyBib3RoIHBhY2tlcnMgYnl0ZS1mb3ItYnl0ZSAoYXMgbG9u
>> "!B64TMP!" echo ZyBhcyBubwpzb3VyY2UgZmlsZSBjaGFuZ2VkIGluIGJldHdlZW4pLgoKVXNhZ2U6ICBweXRob24z
>> "!B64TMP!" echo IGdlbl9yaWcucHkgICAgIChmcm9tIHRoZSByaWcgcm9vdCwgbmV4dCB0byBsb2NhbC1zZWFyY2gv
>> "!B64TMP!" echo KQoiIiIKaW1wb3J0IGJhc2U2NAppbXBvcnQgb3MKaW1wb3J0IHpsaWIKClJPT1QgPSBvcy5wYXRo
>> "!B64TMP!" echo LmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmlsZV9fKSkKU1JDID0gb3MucGF0aC5qb2luKFJP
>> "!B64TMP!" echo T1QsICJsb2NhbC1zZWFyY2giKQoKIyBSaWcgc2NyaXB0cyAobGl2ZSBhdCB0aGUgcmlnIHJvb3Qs
>> "!B64TMP!" echo IG5leHQgdG8gdGhpcyBmaWxlKS4KUklHX0ZJTEVTID0gWwogICAgImdlbl9pbnN0YWxsZXJzLnB5
>> "!B64TMP!" echo IiwKICAgICJnZW5fcmlnLnB5IiwKICAgICJleHRyYWN0LWVtYmVkZGVkLnB5IiwKICAgICJ0ZXN0
>> "!B64TMP!" echo X2I2NC5weSIsCiAgICAidGVzdF9oZXJlZG9jcy5weSIsCiAgICAidGVzdF9yaWcucHkiLAogICAg
>> "!B64TMP!" echo ImUyZV90ZXN0LnNoIiwKICAgICJ6aXBfdGVzdC5zaCIsCiAgICAic2VsZmhvc3RfdGVzdC5zaCIs
>> "!B64TMP!" echo CiAgICAiYnVpbGQuc2giLAogICAgImJ1aWxkLmJhdCIsCiAgICAiQlVJTEQubWQiLApdCgojIGxv
>> "!B64TMP!" echo Y2FsLXNlYXJjaCBzb3VyY2UgZmlsZXMgKHRoZSBwcm9kdWN0OyBpbnN0YWxsZXJzIGFyZSBnZW5l
>> "!B64TMP!" echo cmF0ZWQsIG5vdCBsaXN0ZWQpLgpTT1VSQ0VfRklMRVMgPSBbCiAgICAiY29uZmlnL3NlYXJ4bmcv
>> "!B64TMP!" echo c2V0dGluZ3MueW1sIiwKICAgICJkb2NrZXItY29tcG9zZS55bWwiLAogICAgIi5lbnYuZXhhbXBs
>> "!B64TMP!" echo ZSIsCiAgICAiUkVBRE1FLm1kIiwKICAgICJMSUNFTlNFIiwKICAgICIuZ2l0aWdub3JlIiwKICAg
>> "!B64TMP!" echo ICIuZ2l0YXR0cmlidXRlcyIsCiAgICAiUnVuLmJhdCIsCiAgICAiU3RvcC5iYXQiLAogICAgIlVw
>> "!B64TMP!" echo ZGF0ZS5iYXQiLAogICAgIlVuaW5zdGFsbC5iYXQiLAogICAgInJ1bi5zaCIsCiAgICAic3RvcC5z
>> "!B64TMP!" echo aCIsCiAgICAidXBkYXRlLnNoIiwKICAgICJ1bmluc3RhbGwuc2giLAogICAgImxvY2FsLXdlYi9T
>> "!B64TMP!" echo S0lMTC5tZCIsCiAgICAibG9jYWwtd2ViL0xJQ0VOU0UiLAogICAgImxvY2FsLXdlYi9zY3JpcHRz
>> "!B64TMP!" echo L2NvbmZpZy5weSIsCiAgICAibG9jYWwtd2ViL3NjcmlwdHMvZW5zdXJlX3N0YWNrLnB5IiwKICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWIvc2NyaXB0cy93ZWJfc2VhcmNoLnB5IiwKICAgICJsb2NhbC13ZWIvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfc2NyYXBlLnB5IiwKXQoKTl9GSUxFUyA9IGxlbihTT1VSQ0VfRklMRVMpICsgbGVuKFJJ
>> "!B64TMP!" echo R19GSUxFUykKCgpkZWYgcmVhZF9yb290KHJlbCk6CiAgICB3aXRoIG9wZW4ob3MucGF0aC5qb2lu
>> "!B64TMP!" echo KFJPT1QsIHJlbCksICJyYiIpIGFzIGY6CiAgICAgICAgcmV0dXJuIGYucmVhZCgpCgoKZGVmIHJl
>> "!B64TMP!" echo YWRfc3JjKHJlbCk6CiAgICB3aXRoIG9wZW4ob3MucGF0aC5qb2luKFNSQywgcmVsKSwgInJiIikg
>> "!B64TMP!" echo YXMgZjoKICAgICAgICByZXR1cm4gZi5yZWFkKCkKCgpkZWYgYjY0X2NodW5rZWQoZGF0YSwgd2lk
>> "!B64TMP!" echo dGg9NzYpOgogICAgcyA9IGJhc2U2NC5iNjRlbmNvZGUoZGF0YSkuZGVjb2RlKCJhc2NpaSIpCiAg
>> "!B64TMP!" echo ICByZXR1cm4gW3NbaTppICsgd2lkdGhdIGZvciBpIGluIHJhbmdlKDAsIGxlbihzKSwgd2lkdGgp
>> "!B64TMP!" echo XQoKCmRlZiB0YWdfZm9yKHJlbCk6CiAgICByZXR1cm4gIkVPRl8iICsgIiIuam9pbihjIGlmIGMu
>> "!B64TMP!" echo aXNhbG51bSgpIGVsc2UgIl8iIGZvciBjIGluIHJlbCkudXBwZXIoKQoKCiMgPT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT0KIyAgV2luZG93cyBwYWNrZXIgKC5iYXQpCiMgPT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0K
>> "!B64TMP!" echo CmRlZiBnZW5fYmF0X3BhY2tlcigpOgogICAgb3V0ID0gW10KICAgIGFwID0gb3V0LmFwcGVuZAoK
>> "!B64TMP!" echo ICAgIGFwKCdAZWNobyBvZmYnKQogICAgYXAoJ3NldGxvY2FsIGVuYWJsZURlbGF5ZWRFeHBhbnNp
>> "!B64TMP!" echo b24nKQogICAgYXAoJ2NoY3AgNjUwMDEgPm51bCcpCiAgICBhcCgndGl0bGUgTG9jYWwgU2VhcmNo
>> "!B64TMP!" echo IERldiBSaWcgLSBVbnBhY2snKQogICAgYXAoJycpCiAgICBhcCgnUkVNID09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PScpCiAgICBhcCgnUkVNICBMb2NhbCBTZWFyY2ggREVWIFJJRyBwYWNrZXIgIC0gIFdpbmRv
>> "!B64TMP!" echo d3MnKQogICAgYXAoJ1JFTSA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJ1JFTSAgU2VsZi1j
>> "!B64TMP!" echo b250YWluZWQ6IGVtYmVkcyB0aGUgY29tcGxldGUgYnVpbGQvdGVzdCBlbnZpcm9ubWVudCBmb3Ig
>> "!B64TMP!" echo dGhlJykKICAgIGFwKCdSRU0gIGxvY2FsLXNlYXJjaCBpbnN0YWxsZXJzOicpCiAgICBhcCgnUkVN
>> "!B64TMP!" echo ICAgICogdGhlIGxvY2FsLXNlYXJjaCBzb3VyY2UgdHJlZSAoJWQgZmlsZXMpJyAlIGxlbihTT1VS
>> "!B64TMP!" echo Q0VfRklMRVMpKQogICAgYXAoJ1JFTSAgICAqIGdlbl9pbnN0YWxsZXJzLnB5IC8gZ2VuX3JpZy5w
>> "!B64TMP!" echo eSAodGhlIHR3byBnZW5lcmF0b3JzKScpCiAgICBhcCgnUkVNICAgICogZXZlcnkgdGVzdCArIGJ1
>> "!B64TMP!" echo aWxkIHNjcmlwdCArIEJVSUxELm1kJykKICAgIGFwKCdSRU0gIFVucGFjayBhbnl3aGVyZSwgdGhl
>> "!B64TMP!" echo biBydW4gYnVpbGQuYmF0IChvcjogcHl0aG9uIGdlbl9pbnN0YWxsZXJzLnB5KSB0bycpCiAgICBh
>> "!B64TMP!" echo cCgnUkVNICByZWdlbmVyYXRlIHRoZSBpbnN0YWxsZXJzLCBhbmQ6IHB5dGhvbiBnZW5fcmlnLnB5
>> "!B64TMP!" echo IHRvIHJlZ2VuZXJhdGUgdGhlc2UnKQogICAgYXAoJ1JFTSAgcGFja2VycyBieXRlLWZvci1ieXRl
>> "!B64TMP!" echo LicpCiAgICBhcCgnUkVNID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnJykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PScpCiAgICBhcCgnZWNobyAgIExvY2FsIFNlYXJjaCBERVYgUklHICAoYnVpbGQgKyB0
>> "!B64TMP!" echo ZXN0IGVudmlyb25tZW50KScpCiAgICBhcCgnZWNobyAgIFVucGFja3MgZXZlcnl0aGluZyBuZWVk
>> "!B64TMP!" echo ZWQgdG8gcmVnZW5lcmF0ZSBhbmQgdmVyaWZ5IHRoZScpCiAgICBhcCgnZWNobyAgIGluc3RhbGwt
>> "!B64TMP!" echo bG9jYWwtc2VhcmNoIGluc3RhbGxlcnMuJykKICAgIGFwKCdlY2hvID09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnZWNo
>> "!B64TMP!" echo by4nKQogICAgYXAoJycpCiAgICAjIFByb21wdHMKICAgIGFwKCdzZXQgIkRFRkFVTFRfVEFSR0VU
>> "!B64TMP!" echo PSV+ZHAwbG9jYWwtc2VhcmNoLWRldiInKQogICAgYXAoJycpCiAgICBhcCgnZWNobyAtLS0gU3Rl
>> "!B64TMP!" echo cCAxIG9mIDM6IFVucGFjayBsb2NhdGlvbiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0nKQog
>> "!B64TMP!" echo ICAgYXAoJ2VjaG8gICBEZWZhdWx0OiAlREVGQVVMVF9UQVJHRVQlJykKICAgIGFwKCdzZXQgIlRB
>> "!B64TMP!" echo UkdFVD0iJykKICAgIGFwKCdzZXQgL3AgVEFSR0VUPSIgIFRhcmdldCBmb2xkZXIgW3ByZXNzIEVu
>> "!B64TMP!" echo dGVyIGZvciBkZWZhdWx0XTogIicpCiAgICBhcCgnaWYgIiFUQVJHRVQhIj09IiIgc2V0ICJUQVJH
>> "!B64TMP!" echo RVQ9JURFRkFVTFRfVEFSR0VUJSInKQogICAgYXAoJ3NldCAiVEFSR0VUPSFUQVJHRVQ6Ij0hIicp
>> "!B64TMP!" echo CiAgICBhcCgnZm9yICUlSSBpbiAoIiFUQVJHRVQhIikgZG8gc2V0ICJUQVJHRVQ9JSV+ZkkiJykK
>> "!B64TMP!" echo ICAgIGFwKCdlY2hvICAgVXNpbmc6ICFUQVJHRVQhJykKICAgIGFwKCdlY2hvICAgXihleGlzdGlu
>> "!B64TMP!" echo ZyBmaWxlcyBpbiB0aGUgdGFyZ2V0IGZvbGRlciBhcmUgb3ZlcndyaXR0ZW5eKScpCiAgICBhcCgn
>> "!B64TMP!" echo ZWNoby4nKQogICAgYXAoJycpCiAgICBhcCgnZWNobyAtLS0gU3RlcCAyIG9mIDM6IEJ1aWxkIG5v
>> "!B64TMP!" echo dz8gLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0nKQogICAgYXAoJ2VjaG8gICBHZW5l
>> "!B64TMP!" echo cmF0ZSBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQvLnNoIHdpdGggUHl0aG9uIHJpZ2h0IGFmdGVy
>> "!B64TMP!" echo IHVucGFja2luZz8nKQogICAgYXAoJ3NldCAiQlVJTEROT1c9IicpCiAgICBhcCgnc2V0IC9wIEJV
>> "!B64TMP!" echo SUxETk9XPSIgIFJ1biB0aGUgaW5zdGFsbGVyIGJ1aWxkIG5vdz8gW1kvbl06ICInKQogICAgYXAo
>> "!B64TMP!" echo J2VjaG8uJykKICAgIGFwKCcnKQogICAgYXAoJ2VjaG8gLS0tIFN0ZXAgMyBvZiAzOiBDb25maXJt
>> "!B64TMP!" echo IC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tJykKICAgIGFwKCdlY2hvICAgV2ls
>> "!B64TMP!" echo bCB1bnBhY2sgJWQgZmlsZXMgaW50bzogIVRBUkdFVCEnICUgTl9GSUxFUykKICAgIGFwKCdzZXQg
>> "!B64TMP!" echo IkNPTkZJUk09IicpCiAgICBhcCgnc2V0IC9wIENPTkZJUk09IlByb2NlZWQ/IFtZL25dOiAiJykK
>> "!B64TMP!" echo ICAgIGFwKCdpZiAvaSAiIUNPTkZJUk0hIj09Im4iICggZWNobyBDYW5jZWxsZWQuICYgcGF1c2Ug
>> "!B64TMP!" echo JiBleGl0IC9iIDAgKScpCiAgICBhcCgnJykKICAgICMgRm9sZGVycwogICAgYXAoJ2lmIG5vdCBl
>> "!B64TMP!" echo eGlzdCAiIVRBUkdFVCEiIG1rZGlyICIhVEFSR0VUISInKQogICAgYXAoJ2lmIG5vdCBleGlzdCAi
>> "!B64TMP!" echo IVRBUkdFVCFcXGxvY2FsLXNlYXJjaCIgbWtkaXIgIiFUQVJHRVQhXFxsb2NhbC1zZWFyY2giJykK
>> "!B64TMP!" echo ICAgIGFwKCdpZiBub3QgZXhpc3QgIiFUQVJHRVQhXFxsb2NhbC1zZWFyY2hcXGNvbmZpZ1xcc2Vh
>> "!B64TMP!" echo cnhuZyIgbWtkaXIgIiFUQVJHRVQhXFxsb2NhbC1zZWFyY2hcXGNvbmZpZ1xcc2VhcnhuZyInKQog
>> "!B64TMP!" echo ICAgYXAoJ2lmIG5vdCBleGlzdCAiIVRBUkdFVCFcXGxvY2FsLXNlYXJjaFxcbG9jYWwtd2ViXFxz
>> "!B64TMP!" echo Y3JpcHRzIiBta2RpciAiIVRBUkdFVCFcXGxvY2FsLXNlYXJjaFxcbG9jYWwtd2ViXFxzY3JpcHRz
>> "!B64TMP!" echo IicpCiAgICBhcCgnJykKICAgIGFwKCdlY2hvIFVucGFja2luZyBmaWxlcy4uLicpCgogICAgZGVm
>> "!B64TMP!" echo IGI2NF9ibG9jayhsYWJlbCwgZGF0YSwgb3V0X3dpbik6CiAgICAgICAgbGluZXMgPSBiNjRfY2h1
>> "!B64TMP!" echo bmtlZChkYXRhKQogICAgICAgIHRhZyA9ICJMU1IiICsgc3RyKHpsaWIuY3JjMzIobGFiZWwuZW5j
>> "!B64TMP!" echo b2RlKCJ1dGYtOCIpKSAmIDB4RkZGRkZGRkYpCiAgICAgICAgYXAoJycpCiAgICAgICAgYXAoJ1JF
>> "!B64TMP!" echo TSAtLS0gJyArIGxhYmVsICsgJyAtLS0nKQogICAgICAgIGFwKCdzZXQgIkI2NFRNUD0lVEVNUCVc
>> "!B64TMP!" echo XCcgKyB0YWcgKyAnLmI2NCInKQogICAgICAgIGZpcnN0ID0gVHJ1ZQogICAgICAgIGZvciBsbiBp
>> "!B64TMP!" echo biBsaW5lczoKICAgICAgICAgICAgYXAoKCc+ICcgaWYgZmlyc3QgZWxzZSAnPj4gJykgKyAnIiFC
>> "!B64TMP!" echo NjRUTVAhIiBlY2hvICcgKyBsbikKICAgICAgICAgICAgZmlyc3QgPSBGYWxzZQogICAgICAgIGFw
>> "!B64TMP!" echo KCdzZXQgIkxTX0I2NF9JTj0hQjY0VE1QISInKQogICAgICAgIGFwKCdzZXQgIkxTX0I2NF9PVVQ9
>> "!B64TMP!" echo JyArIG91dF93aW4gKyAnIicpCiAgICAgICAgYXAoJ2NhbGwgOmRlY29kZV9iNjQnKQogICAgICAg
>> "!B64TMP!" echo IGFwKCdkZWwgL1EgIiFCNjRUTVAhIiA+bnVsIDI+JjEnKQoKICAgICMgbG9jYWwtc2VhcmNoIHNv
>> "!B64TMP!" echo dXJjZXMKICAgIGZvciByZWwgaW4gU09VUkNFX0ZJTEVTOgogICAgICAgIGxhYmVsID0gImxvY2Fs
>> "!B64TMP!" echo LXNlYXJjaC8iICsgcmVsCiAgICAgICAgYjY0X2Jsb2NrKGxhYmVsLCByZWFkX3NyYyhyZWwpLCAn
>> "!B64TMP!" echo IVRBUkdFVCFcXGxvY2FsLXNlYXJjaFxcJyArIHJlbC5yZXBsYWNlKCIvIiwgIlxcIikpCiAgICAj
>> "!B64TMP!" echo IHJpZyBmaWxlcwogICAgZm9yIHJlbCBpbiBSSUdfRklMRVM6CiAgICAgICAgYjY0X2Jsb2NrKHJl
>> "!B64TMP!" echo bCwgcmVhZF9yb290KHJlbCksICchVEFSR0VUIVxcJyArIHJlbC5yZXBsYWNlKCIvIiwgIlxcIikp
>> "!B64TMP!" echo CgogICAgYXAoJycpCiAgICBhcCgnUkVNIEtlZXAgYSBjb3B5IG9mIHRoaXMgcGFja2VyIGluIHRo
>> "!B64TMP!" echo ZSB0YXJnZXQgc28gdGhlIHJpZyBpcyBjb21wbGV0ZS4nKQogICAgYXAoJ2NvcHkgL1kgIiV+ZjAi
>> "!B64TMP!" echo ICIhVEFSR0VUIVxcbG9jYWwtc2VhcmNoLXJpZy5iYXQiID5udWwgMj4mMScpCiAgICBhcCgnZWNo
>> "!B64TMP!" echo byAgIERvbmUgLSAlZCBmaWxlcyArIHRoaXMgcGFja2VyLicgJSBOX0ZJTEVTKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICAjIE9wdGlvbmFsIGJ1aWxkCiAgICBhcCgnaWYgL2kgbm90ICIhQlVJTEROT1chIj09Im4i
>> "!B64TMP!" echo ICgnKQogICAgYXAoJyAgc2V0ICJQWT0iJykKICAgIGFwKCcgIHB5IC0zIC1jICJwcmludCgxKSIg
>> "!B64TMP!" echo Pm51bCAyPiYxJykKICAgIGFwKCcgIGlmIG5vdCBlcnJvcmxldmVsIDEgc2V0ICJQWT1weSAtMyIn
>> "!B64TMP!" echo KQogICAgYXAoJyAgaWYgbm90IGRlZmluZWQgUFkgKCcpCiAgICBhcCgnICAgIHB5dGhvbiAtYyAi
>> "!B64TMP!" echo cHJpbnQoMSkiID5udWwgMj4mMScpCiAgICBhcCgnICAgIGlmIG5vdCBlcnJvcmxldmVsIDEgc2V0
>> "!B64TMP!" echo ICJQWT1weXRob24iJykKICAgIGFwKCcgICknKQogICAgYXAoJyAgaWYgbm90IGRlZmluZWQgUFkg
>> "!B64TMP!" echo KCcpCiAgICBhcCgnICAgIHB5dGhvbjMgLWMgInByaW50KDEpIiA+bnVsIDI+JjEnKQogICAgYXAo
>> "!B64TMP!" echo JyAgICBpZiBub3QgZXJyb3JsZXZlbCAxIHNldCAiUFk9cHl0aG9uMyInKQogICAgYXAoJyAgKScp
>> "!B64TMP!" echo CiAgICBhcCgnICBpZiBub3QgZGVmaW5lZCBQWSAoJykKICAgIGFwKCcgICAgZWNoby4nKQogICAg
>> "!B64TMP!" echo YXAoJyAgICBlY2hvICAgW1dBUk5JTkddIFB5dGhvbiBub3QgZm91bmQgLSBza2lwcGluZyB0aGUg
>> "!B64TMP!" echo YnVpbGQuJykKICAgIGFwKCcgICAgZWNobyAgIEluc3RhbGwgUHl0aG9uIDMuOCssIHRoZW4gcnVu
>> "!B64TMP!" echo IGJ1aWxkLmJhdCBpbiB0aGUgdGFyZ2V0IGZvbGRlci4nKQogICAgYXAoJyAgKSBlbHNlICgnKQog
>> "!B64TMP!" echo ICAgYXAoJyAgICBlY2hvLicpCiAgICBhcCgnICAgIGVjaG8gQnVpbGRpbmcgaW5zdGFsbGVycyB3
>> "!B64TMP!" echo aXRoICFQWSEgLi4uJykKICAgIGFwKCcgICAgcHVzaGQgIiFUQVJHRVQhIicpCiAgICBhcCgnICAg
>> "!B64TMP!" echo ICFQWSEgZ2VuX2luc3RhbGxlcnMucHknKQogICAgYXAoJyAgICBpZiBlcnJvcmxldmVsIDEgKCcp
>> "!B64TMP!" echo CiAgICBhcCgnICAgICAgcG9wZCcpCiAgICBhcCgnICAgICAgZWNobyAgIFtFUlJPUl0gZ2VuX2lu
>> "!B64TMP!" echo c3RhbGxlcnMucHkgZmFpbGVkLicpCiAgICBhcCgnICAgICAgcGF1c2UnKQogICAgYXAoJyAgICAg
>> "!B64TMP!" echo IGV4aXQgL2IgMScpCiAgICBhcCgnICAgICknKQogICAgYXAoJyAgICBwb3BkJykKICAgIGFwKCcg
>> "!B64TMP!" echo ICAgZWNobyAgIEluc3RhbGxlcnMgd3JpdHRlbiB0byAhVEFSR0VUIVxcbG9jYWwtc2VhcmNoXFwn
>> "!B64TMP!" echo KQogICAgYXAoJyAgKScpCiAgICBhcCgnKScpCiAgICBhcCgnJykKICAgICMgRG9uZQogICAgYXAo
>> "!B64TMP!" echo J2VjaG8uJykKICAgIGFwKCdlY2hvID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnZWNobyAgIERldiByaWcgcmVhZHk6
>> "!B64TMP!" echo ICFUQVJHRVQhJykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnZWNobyAgIE5leHQgc3RlcHMgXihz
>> "!B64TMP!" echo ZWUgQlVJTEQubWQgaW5zaWRlXik6JykKICAgIGFwKCdlY2hvICAgICBidWlsZC5iYXQgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICByZWJ1aWxkIGluc3RhbGxlcnMgKyBwYWNrZXJzICsgdGVzdHMnKQogICAg
>> "!B64TMP!" echo YXAoJ2VjaG8gICAgIHB5dGhvbiBnZW5faW5zdGFsbGVycy5weSAgICAgIHJlYnVpbGQganVzdCB0
>> "!B64TMP!" echo aGUgaW5zdGFsbGVycycpCiAgICBhcCgnZWNobyAgICAgcHl0aG9uIGdlbl9yaWcucHkgICAgICAg
>> "!B64TMP!" echo ICAgICAgcmVidWlsZCB0aGVzZSBwYWNrZXJzJykKICAgIGFwKCdlY2hvID09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgn
>> "!B64TMP!" echo ZWNoby4nKQogICAgYXAoJ3BhdXNlJykKICAgIGFwKCdleGl0IC9iIDAnKQogICAgYXAoJycpCiAg
>> "!B64TMP!" echo ICBhcCgnOmRlY29kZV9iNjQnKQogICAgYXAoJ1JFTSAgJWVudjpMU19CNjRfSU4lID0gLmI2NCB0
>> "!B64TMP!" echo ZW1wIGZpbGUsICVlbnY6TFNfQjY0X09VVCUgPSBvdXRwdXQgcGF0aCcpCiAgICBhcCgncG93ZXJz
>> "!B64TMP!" echo aGVsbCAtTm9Qcm9maWxlIC1Db21tYW5kICIkaW49JGVudjpMU19CNjRfSU47ICRvdXQ9JGVudjpM
>> "!B64TMP!" echo U19CNjRfT1VUOyBbSU8uRmlsZV06OldyaXRlQWxsQnl0ZXMoJG91dCwgW0NvbnZlcnRdOjpGcm9t
>> "!B64TMP!" echo QmFzZTY0U3RyaW5nKCgoR2V0LUNvbnRlbnQgLVJhdyAkaW4pIC1yZXBsYWNlIFwnXFxzXCcsXCdc
>> "!B64TMP!" echo JykpKSInKQogICAgYXAoJ2V4aXQgL2IgMCcpCgogICAgcmV0dXJuICJcclxuIi5qb2luKG91dCkg
>> "!B64TMP!" echo KyAiXHJcbiIKCgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIExpbnV4IC8gbWFjT1MgcGFja2Vy
>> "!B64TMP!" echo ICguc2gpCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KCmRlZiBnZW5fc2hfcGFja2VyKCk6CiAgICBv
>> "!B64TMP!" echo dXQgPSBbXQogICAgYXAgPSBvdXQuYXBwZW5kCgogICAgYXAoJyMhL3Vzci9iaW4vZW52IGJhc2gn
>> "!B64TMP!" echo KQogICAgYXAoJyMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJyMgIExvY2FsIFNlYXJj
>> "!B64TMP!" echo aCBERVYgUklHIHBhY2tlciAgLSAgTGludXggLyBtYWNPUyAvIEdpdCBCYXNoJykKICAgIGFwKCcj
>> "!B64TMP!" echo ID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCcjICBTZWxmLWNvbnRhaW5lZDogZW1iZWRz
>> "!B64TMP!" echo IHRoZSBjb21wbGV0ZSBidWlsZC90ZXN0IGVudmlyb25tZW50IGZvciB0aGUnKQogICAgYXAoJyMg
>> "!B64TMP!" echo IGxvY2FsLXNlYXJjaCBpbnN0YWxsZXJzOicpCiAgICBhcCgnIyAgICAqIHRoZSBsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2ggc291cmNlIHRyZWUgKCVkIGZpbGVzKScgJSBsZW4oU09VUkNFX0ZJTEVTKSkKICAgIGFwKCcj
>> "!B64TMP!" echo ICAgICogZ2VuX2luc3RhbGxlcnMucHkgLyBnZW5fcmlnLnB5ICh0aGUgdHdvIGdlbmVyYXRvcnMp
>> "!B64TMP!" echo JykKICAgIGFwKCcjICAgICogZXZlcnkgdGVzdCArIGJ1aWxkIHNjcmlwdCArIEJVSUxELm1kJykK
>> "!B64TMP!" echo ICAgIGFwKCcjICAgICogdGhlIFdpbmRvd3MgcGFja2VyIChsb2NhbC1zZWFyY2gtcmlnLmJhdCkn
>> "!B64TMP!" echo KQogICAgYXAoJyMgIFNvIHRoaXMgT05FIGZpbGUgcmVwcm9kdWNlcyB0aGUgd2hvbGUgcmlnIGFu
>> "!B64TMP!" echo eXdoZXJlLCBpbmNsdWRpbmcgYm90aCcpCiAgICBhcCgnIyAgcGFja2Vycy4gVGhlIGluc3RhbGxl
>> "!B64TMP!" echo cnMgdGhlbXNlbHZlcyBhcmUgZ2VuZXJhdGVkIGFmdGVyIHVucGFja2luZycpCiAgICBhcCgnIyAg
>> "!B64TMP!" echo KHRoaXMgc2NyaXB0IG9mZmVycyB0byBkbyBpdCkgd2l0aCBnZW5faW5zdGFsbGVycy5weS4nKQog
>> "!B64TMP!" echo ICAgYXAoJyMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJycpCiAgICBhcCgnc2V0IC11
>> "!B64TMP!" echo JykKICAgIGFwKCcnKQogICAgYXAoJ0JPTEQ9IlxcMDMzWzFtIjsgR1JFRU49IlxcMDMzWzMybSI7
>> "!B64TMP!" echo IFlFTExPVz0iXFwwMzNbMzNtIjsgUkVEPSJcXDAzM1szMW0iOyBDWUFOPSJcXDAzM1szNm0iOyBS
>> "!B64TMP!" echo RVNFVD0iXFwwMzNbMG0iJykKICAgIGFwKCdzYXkoKSAgeyBwcmludGYgIiViXFxuIiAiJDEiOyB9
>> "!B64TMP!" echo JykKICAgIGFwKCdlcnIoKSAgeyBwcmludGYgIiViW0VSUk9SXSViICVzXFxuIiAiJFJFRCIgIiRS
>> "!B64TMP!" echo RVNFVCIgIiQxIiA+JjI7IH0nKQogICAgYXAoJ29rKCkgICB7IHByaW50ZiAiJWJbT0tdJWIgJXNc
>> "!B64TMP!" echo XG4iICIkR1JFRU4iICIkUkVTRVQiICIkMSI7IH0nKQogICAgYXAoJ2hkcigpICB7IHByaW50ZiAi
>> "!B64TMP!" echo XFxuJWItLS0gJXMgLS0tJWJcXG4iICIkQ1lBTiIgIiQxIiAiJFJFU0VUIjsgfScpCiAgICBhcCgn
>> "!B64TMP!" echo bG93ZXIoKSB7IHByaW50ZiBcJyVzXCcgIiQxIiB8IHRyIFwnWzp1cHBlcjpdXCcgXCdbOmxvd2Vy
>> "!B64TMP!" echo Ol1cJzsgfSAgIyBiYXNoLTMuMiAobWFjT1MpIHNhZmUnKQogICAgYXAoJycpCiAgICBhcCgnY2F0
>> "!B64TMP!" echo IDw8XCdCQU5ORVJcJycpCiAgICBhcCgnPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCcgIExvY2FsIFNlYXJjaCBERVYg
>> "!B64TMP!" echo UklHICAoYnVpbGQgKyB0ZXN0IGVudmlyb25tZW50KScpCiAgICBhcCgnICBVbnBhY2tzIGV2ZXJ5
>> "!B64TMP!" echo dGhpbmcgbmVlZGVkIHRvIHJlZ2VuZXJhdGUgYW5kIHZlcmlmeSB0aGUnKQogICAgYXAoJyAgaW5z
>> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2ggaW5zdGFsbGVycy4nKQogICAgYXAoJz09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnQkFO
>> "!B64TMP!" echo TkVSJykKICAgIGFwKCcnKQogICAgYXAoJ1NDUklQVF9ESVI9IiQoY2QgIiQoZGlybmFtZSAiJDAi
>> "!B64TMP!" echo KSIgJiYgcHdkKSInKQogICAgYXAoJ0RFRkFVTFRfVEFSR0VUPSIkU0NSSVBUX0RJUi9sb2NhbC1z
>> "!B64TMP!" echo ZWFyY2gtZGV2IicpCiAgICBhcCgnJykKICAgIGFwKCdoZHIgIlN0ZXAgMSBvZiAzOiBVbnBhY2sg
>> "!B64TMP!" echo bG9jYXRpb24iJykKICAgIGFwKCdzYXkgIiAgRGVmYXVsdDogJERFRkFVTFRfVEFSR0VUIicpCiAg
>> "!B64TMP!" echo ICBhcCgncHJpbnRmICIgIFRhcmdldCBmb2xkZXIgW3ByZXNzIEVudGVyIGZvciBkZWZhdWx0XTog
>> "!B64TMP!" echo IicpCiAgICBhcCgncmVhZCAtciBUQVJHRVQnKQogICAgYXAoJ1sgLXogIiRUQVJHRVQiIF0gJiYg
>> "!B64TMP!" echo VEFSR0VUPSIkREVGQVVMVF9UQVJHRVQiJykKICAgIGFwKCdpZiBbICIke1RBUkdFVCNcXH59IiAh
>> "!B64TMP!" echo PSAiJFRBUkdFVCIgXTsgdGhlbiBUQVJHRVQ9IiRIT01FJHtUQVJHRVQjXFx+fSI7IGZpICAjIFBP
>> "!B64TMP!" echo U0lYIHRpbGRlIGV4cGFuc2lvbicpCiAgICBhcCgnbWtkaXIgLXAgIiRUQVJHRVQiJykKICAgIGFw
>> "!B64TMP!" echo KCdUQVJHRVQ9IiQoY2QgIiRUQVJHRVQiICYmIHB3ZCkiJykKICAgIGFwKCdzYXkgIiAgVXNpbmc6
>> "!B64TMP!" echo ICRUQVJHRVQiJykKICAgIGFwKCdzYXkgIiAgKGV4aXN0aW5nIGZpbGVzIGluIHRoZSB0YXJnZXQg
>> "!B64TMP!" echo Zm9sZGVyIGFyZSBvdmVyd3JpdHRlbikiJykKICAgIGFwKCcnKQogICAgYXAoJ2hkciAiU3RlcCAy
>> "!B64TMP!" echo IG9mIDM6IEJ1aWxkIG5vdz8iJykKICAgIGFwKCdzYXkgIiAgR2VuZXJhdGUgaW5zdGFsbC1sb2Nh
>> "!B64TMP!" echo bC1zZWFyY2guYmF0Ly5zaCB3aXRoIFB5dGhvbiByaWdodCBhZnRlciB1bnBhY2tpbmc/IicpCiAg
>> "!B64TMP!" echo ICBhcCgncHJpbnRmICIgIFJ1biB0aGUgaW5zdGFsbGVyIGJ1aWxkIG5vdz8gW1kvbl06ICInKQog
>> "!B64TMP!" echo ICAgYXAoJ3JlYWQgLXIgQlVJTEROT1cnKQogICAgYXAoJycpCiAgICBhcCgnaGRyICJTdGVwIDMg
>> "!B64TMP!" echo b2YgMzogQ29uZmlybSInKQogICAgYXAoJ3NheSAiICBXaWxsIHVucGFjayAlZCBmaWxlcyBpbnRv
>> "!B64TMP!" echo OiAkVEFSR0VUIicgJSBOX0ZJTEVTKQogICAgYXAoJ3ByaW50ZiAiUHJvY2VlZD8gW1kvbl06ICIn
>> "!B64TMP!" echo KQogICAgYXAoJ3JlYWQgLXIgQ09ORklSTScpCiAgICBhcCgnaWYgWyAiJChsb3dlciAiJENPTkZJ
>> "!B64TMP!" echo Uk0iKSIgPSAibiIgXTsgdGhlbiBzYXkgIkNhbmNlbGxlZC4iOyBleGl0IDA7IGZpJykKICAgIGFw
>> "!B64TMP!" echo KCcnKQogICAgYXAoJ21rZGlyIC1wICIkVEFSR0VUL2xvY2FsLXNlYXJjaC9jb25maWcvc2Vhcnhu
>> "!B64TMP!" echo ZyIgIiRUQVJHRVQvbG9jYWwtc2VhcmNoL2xvY2FsLXdlYi9zY3JpcHRzIicpCiAgICBhcCgnJykK
>> "!B64TMP!" echo ICAgIGFwKCdzYXkgIlVucGFja2luZyBmaWxlcy4uLiInKQoKICAgIGRlZiBoZXJlZG9jX2Jsb2Nr
>> "!B64TMP!" echo KHJlbF9wYXRoLCBkYXRhKToKICAgICAgICB0ZXh0ID0gZGF0YS5kZWNvZGUoInV0Zi04IikKICAg
>> "!B64TMP!" echo ICAgICAjIExGLW5vcm1hbGlzZSB0aGUgaGVyZWRvYyBib2R5OyB0aGUgYXdrIGxvb3AgYmVsb3cg
>> "!B64TMP!" echo cmVzdG9yZXMgQ1JMRiBmb3IKICAgICAgICAjIGV2ZXJ5IC5iYXQgZmlsZSBhZnRlciB1bnBhY2tp
>> "!B64TMP!" echo bmcuCiAgICAgICAgdGV4dF9sZiA9IHRleHQucmVwbGFjZSgiXHJcbiIsICJcbiIpLnJlcGxhY2Uo
>> "!B64TMP!" echo IlxyIiwgIlxuIikKICAgICAgICB0YWcgPSB0YWdfZm9yKHJlbF9wYXRoKQogICAgICAgIGFwKCcn
>> "!B64TMP!" echo KQogICAgICAgIGFwKCcjIC0tLSAnICsgcmVsX3BhdGggKyAnIC0tLScpCiAgICAgICAgYXAoJ2Nh
>> "!B64TMP!" echo dCA+ICIkVEFSR0VULycgKyByZWxfcGF0aCArICciIDw8XCcnICsgdGFnICsgJ1wnJykKICAgICAg
>> "!B64TMP!" echo ICBmb3IgbGluZSBpbiB0ZXh0X2xmLnNwbGl0bGluZXMoKToKICAgICAgICAgICAgYXAobGluZSkK
>> "!B64TMP!" echo ICAgICAgICBhcCh0YWcpCgogICAgIyBsb2NhbC1zZWFyY2ggc291cmNlcwogICAgZm9yIHJlbCBp
>> "!B64TMP!" echo biBTT1VSQ0VfRklMRVM6CiAgICAgICAgaGVyZWRvY19ibG9jaygibG9jYWwtc2VhcmNoLyIgKyBy
>> "!B64TMP!" echo ZWwsIHJlYWRfc3JjKHJlbCkpCiAgICAjIHJpZyBmaWxlcwogICAgZm9yIHJlbCBpbiBSSUdfRklM
>> "!B64TMP!" echo RVM6CiAgICAgICAgaGVyZWRvY19ibG9jayhyZWwsIHJlYWRfcm9vdChyZWwpKQogICAgIyB0aGUg
>> "!B64TMP!" echo V2luZG93cyBwYWNrZXIsIHNvIHRoaXMgb25lIGZpbGUgcmVwcm9kdWNlcyB0aGUgd2hvbGUgcmln
>> "!B64TMP!" echo CiAgICBoZXJlZG9jX2Jsb2NrKCJsb2NhbC1zZWFyY2gtcmlnLmJhdCIsIHJlYWRfcm9vdCgibG9j
>> "!B64TMP!" echo YWwtc2VhcmNoLXJpZy5iYXQiKSkKCiAgICBhcCgnJykKICAgIGFwKCcjIEtlZXAgYSBjb3B5IG9m
>> "!B64TMP!" echo IHRoaXMgcGFja2VyIGluIHRoZSB0YXJnZXQgc28gdGhlIHJpZyBpcyBjb21wbGV0ZS4nKQogICAg
>> "!B64TMP!" echo YXAoJ2NwIC1mICIkMCIgIiRUQVJHRVQvbG9jYWwtc2VhcmNoLXJpZy5zaCInKQogICAgYXAoJ2No
>> "!B64TMP!" echo bW9kICt4ICIkVEFSR0VUIi8qLnNoICIkVEFSR0VUIi9sb2NhbC1zZWFyY2gvKi5zaCAyPi9kZXYv
>> "!B64TMP!" echo bnVsbCB8fCB0cnVlJykKICAgIGFwKCcnKQogICAgYXAoJyMgUmVzdG9yZSBDUkxGIGxpbmUgZW5k
>> "!B64TMP!" echo aW5ncyBmb3IgZXZlcnkgLmJhdCBmaWxlICh0aGUgaGVyZWRvY3MgYWJvdmUnKQogICAgYXAoJyMg
>> "!B64TMP!" echo d3JvdGUgTEY7IGF3ayBpcyB1c2VkIGluc3RlYWQgb2Ygc2VkIHNvIHRoaXMgYWxzbyB3b3JrcyBv
>> "!B64TMP!" echo biBtYWNPUykuJykKICAgIGFwKCdmaW5kICIkVEFSR0VUIiAtdHlwZSBmIC1uYW1lIFwnKi5iYXRc
>> "!B64TMP!" echo JyAyPi9kZXYvbnVsbCB8IHdoaWxlIElGUz0gcmVhZCAtciBmOyBkbycpCiAgICBhcCgnICBhd2sg
>> "!B64TMP!" echo XCd7c3ViKC9cXHIkLywiIik7IHByaW50ZiAiJXNcXHJcXG4iLCAkMH1cJyAiJGYiID4gIiRmLmNy
>> "!B64TMP!" echo bGYiIDI+L2Rldi9udWxsIFxcJykKICAgIGFwKCcgICAgJiYgbXYgIiRmLmNybGYiICIkZiIgfHwg
>> "!B64TMP!" echo cm0gLWYgIiRmLmNybGYiJykKICAgIGFwKCdkb25lJykKICAgIGFwKCcnKQogICAgYXAoJ29rICJV
>> "!B64TMP!" echo bnBhY2tlZCB0aGUgZGV2IHJpZyBpbnRvOiAkVEFSR0VUIicpCiAgICBhcCgnJykKICAgICMgT3B0
>> "!B64TMP!" echo aW9uYWwgYnVpbGQKICAgIGFwKCdpZiBbICIkKGxvd2VyICIke0JVSUxETk9XOi15fSIpIiAhPSAi
>> "!B64TMP!" echo biIgXTsgdGhlbicpCiAgICBhcCgnICBQWT0iJChjb21tYW5kIC12IHB5dGhvbjMgfHwgY29tbWFu
>> "!B64TMP!" echo ZCAtdiBweXRob24pIicpCiAgICBhcCgnICBpZiBbIC1uICIkUFkiIF07IHRoZW4nKQogICAgYXAo
>> "!B64TMP!" echo JyAgICBzYXkgIkJ1aWxkaW5nIGluc3RhbGxlcnMgd2l0aCAkUFkgLi4uIicpCiAgICBhcCgnICAg
>> "!B64TMP!" echo IGlmIChjZCAiJFRBUkdFVCIgJiYgIiRQWSIgZ2VuX2luc3RhbGxlcnMucHkpOyB0aGVuJykKICAg
>> "!B64TMP!" echo IGFwKCcgICAgICBzYXkgIiAgSW5zdGFsbGVycyB3cml0dGVuIHRvICRUQVJHRVQvbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoLyInKQogICAgYXAoJyAgICBlbHNlJykKICAgIGFwKCcgICAgICBlcnIgImdlbl9pbnN0YWxs
>> "!B64TMP!" echo ZXJzLnB5IGZhaWxlZCAtIHNlZSBvdXRwdXQgYWJvdmUuIicpCiAgICBhcCgnICAgIGZpJykKICAg
>> "!B64TMP!" echo IGFwKCcgIGVsc2UnKQogICAgYXAoJyAgICBzYXkgIiAgJHtZRUxMT1d9W1dBUk5JTkddJHtSRVNF
>> "!B64TMP!" echo VH0gUHl0aG9uIG5vdCBmb3VuZCAtIHNraXBwaW5nIHRoZSBidWlsZC4iJykKICAgIGFwKCcgICAg
>> "!B64TMP!" echo c2F5ICIgIEluc3RhbGwgUHl0aG9uIDMuOCssIHRoZW4gcnVuIC4vYnVpbGQuc2ggaW4gdGhlIHRh
>> "!B64TMP!" echo cmdldCBmb2xkZXIuIicpCiAgICBhcCgnICBmaScpCiAgICBhcCgnZmknKQogICAgYXAoJycpCiAg
>> "!B64TMP!" echo ICAjIERvbmUKICAgIGFwKCdlY2hvJykKICAgIGFwKCdzYXkgIiR7R1JFRU59PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JHtSRVNFVH0i
>> "!B64TMP!" echo JykKICAgIGFwKCdzYXkgIiR7R1JFRU59ICBEZXYgcmlnIHJlYWR5OiAkVEFSR0VUJHtSRVNFVH0i
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvJykKICAgIGFwKCdzYXkgIiAgTmV4dCBzdGVwcyAoc2VlIEJVSUxELm1k
>> "!B64TMP!" echo IGluc2lkZSk6IicpCiAgICBhcCgnc2F5ICIgICAgLi9idWlsZC5zaCAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgcmVidWlsZCBpbnN0YWxsZXJzICsgcGFja2VycyArIHRlc3RzIicpCiAgICBhcCgnc2F5ICIg
>> "!B64TMP!" echo ICAgcHl0aG9uMyBnZW5faW5zdGFsbGVycy5weSAgICAgcmVidWlsZCBqdXN0IHRoZSBpbnN0YWxs
>> "!B64TMP!" echo ZXJzIicpCiAgICBhcCgnc2F5ICIgICAgcHl0aG9uMyBnZW5fcmlnLnB5ICAgICAgICAgICAgcmVi
>> "!B64TMP!" echo dWlsZCB0aGVzZSBwYWNrZXJzIicpCiAgICBhcCgnc2F5ICIke0dSRUVOfT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSR7UkVTRVR9Iicp
>> "!B64TMP!" echo CgogICAgcmV0dXJuICJcbiIuam9pbihvdXQpICsgIlxuIgoKCmRlZiBtYWluKCk6CiAgICAjIFdy
>> "!B64TMP!" echo aXRlIHRoZSAuYmF0IHBhY2tlciBGSVJTVDogdGhlIC5zaCBwYWNrZXIgZW1iZWRzIGl0LCBzbyBp
>> "!B64TMP!" echo dCBtdXN0IHJlYWQKICAgICMgdGhlIGZyZXNobHktd3JpdHRlbiBmaWxlIChub3QgYSBzdGFsZSBw
>> "!B64TMP!" echo cmV2aW91cy1nZW5lcmF0aW9uIGNvcHkpLgogICAgYmF0ID0gZ2VuX2JhdF9wYWNrZXIoKQogICAg
>> "!B64TMP!" echo d2l0aCBvcGVuKG9zLnBhdGguam9pbihST09ULCAibG9jYWwtc2VhcmNoLXJpZy5iYXQiKSwgIndi
>> "!B64TMP!" echo IikgYXMgZjoKICAgICAgICBmLndyaXRlKGJhdC5lbmNvZGUoInV0Zi04IikpCiAgICBzaCA9IGdl
>> "!B64TMP!" echo bl9zaF9wYWNrZXIoKQogICAgd2l0aCBvcGVuKG9zLnBhdGguam9pbihST09ULCAibG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoLXJpZy5zaCIpLCAid2IiKSBhcyBmOgogICAgICAgIGYud3JpdGUoc2guZW5jb2RlKCJ1dGYt
>> "!B64TMP!" echo OCIpKQogICAgb3MuY2htb2Qob3MucGF0aC5qb2luKFJPT1QsICJsb2NhbC1zZWFyY2gtcmlnLnNo
>> "!B64TMP!" echo IiksIDBvNzU1KQogICAgcHJpbnQoIldyb3RlIGxvY2FsLXNlYXJjaC1yaWcuYmF0ICglZCBieXRl
>> "!B64TMP!" echo cykiICUgbGVuKGJhdCkpCiAgICBwcmludCgiV3JvdGUgbG9jYWwtc2VhcmNoLXJpZy5zaCAgKCVk
>> "!B64TMP!" echo IGJ5dGVzKSIgJSBsZW4oc2gpKQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWlu
>> "!B64TMP!" echo KCkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\gen_rig.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- extract-embedded.py ---
set "B64TMP=%TEMP%\LSR1004320646.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJFeHRyYWN0IHRoZSBmaWxlcyBlbWJlZGRlZCBpbiBh
>> "!B64TMP!" echo IGxvY2FsLXNlYXJjaCAuc2ggaW5zdGFsbGVyIG9yIHJpZyBwYWNrZXIuCgpXb3JrcyBvbjoKICAg
>> "!B64TMP!" echo IGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoICAgIC0+IGV4dHJhY3RzIHRoZSAyMSBsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2gvIHNvdXJjZSBmaWxlcwogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgKCsgaW5z
>> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2guYmF0KQogICAgbG9jYWwtc2VhcmNoLXJpZy5zaCAgICAgICAgLT4g
>> "!B64TMP!" echo ZXh0cmFjdHMgdGhlIENPTVBMRVRFIGRldiByaWcKICAgICAgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgIChsb2NhbC1zZWFyY2gvIHNvdXJjZXMgKyBhbGwgcmlnIHNjcmlwdHMgKwogICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgbG9jYWwtc2VhcmNoLXJpZy5iYXQpCgpObyBEb2Nr
>> "!B64TMP!" echo ZXIsIG5vIGV4ZWN1dGlvbiBvZiB0aGUgZW1iZWRkZWQgc2NyaXB0czogdGhpcyBqdXN0IHBhcnNl
>> "!B64TMP!" echo cyB0aGUgcXVvdGVkCmhlcmVkb2NzIChgY2F0ID4gIiRUQVJHRVQvPGZpbGU+IiA8PCdUQUcnYCkg
>> "!B64TMP!" echo YW5kIHdyaXRlcyB0aGVpciBjb250ZW50IHRvIGRpc2suCkxpbmUgZW5kaW5ncyBhcmUgcmVzdG9y
>> "!B64TMP!" echo ZWQgKENSTEYgZm9yIC5iYXQgZmlsZXMpLCBzbyB0aGUgZXh0cmFjdGVkIHRyZWUgaXMKYnl0ZS1p
>> "!B64TMP!" echo ZGVudGljYWwgdG8gdGhlIHNvdXJjZXMgdGhlIHBhY2tlci9nZW5lcmF0b3Igb3JpZ2luYWxseSBl
>> "!B64TMP!" echo bWJlZGRlZC4KClVzYWdlOgogICAgcHl0aG9uMyBleHRyYWN0LWVtYmVkZGVkLnB5IDxpbnN0YWxs
>> "!B64TMP!" echo LWxvY2FsLXNlYXJjaC5zaCB8IGxvY2FsLXNlYXJjaC1yaWcuc2g+IFtvdXRkaXJdCgpSZXN1bHQ6
>> "!B64TMP!" echo CiAgICBvdXRkaXIvIGNvbnRhaW5zIHRoZSBleHRyYWN0ZWQgdHJlZS4gRm9yIHRoZSBpbnN0YWxs
>> "!B64TMP!" echo ZXIsIG91dGRpciBJUyB0aGUKICAgIGxvY2FsLXNlYXJjaCBmb2xkZXIgY29udGVudDsgZm9yIHRo
>> "!B64TMP!" echo ZSByaWcgcGFja2VyLCBvdXRkaXIgSVMgdGhlIHJpZyByb290CiAgICAobG9jYWwtc2VhcmNoLyBw
>> "!B64TMP!" echo bHVzIHRoZSByaWcgc2NyaXB0cykuIFRoZSAuc2ggZmlsZSB5b3UgZXh0cmFjdGVkIGZyb20gaXMK
>> "!B64TMP!" echo ICAgIG5vdCBpdHNlbGYgZW1iZWRkZWQgLS0gY29weSBpdCBvdmVyIG1hbnVhbGx5IGlmIHlvdSB3
>> "!B64TMP!" echo YW50IGl0IGluY2x1ZGVkLgoiIiIKaW1wb3J0IGFyZ3BhcnNlCmltcG9ydCBvcwppbXBvcnQgcmUK
>> "!B64TMP!" echo aW1wb3J0IHN5cwoKX0hFUkVET0MgPSByZS5jb21waWxlKHInJydeXHMqY2F0ID4gIlwkVEFSR0VU
>> "!B64TMP!" echo LyguKz8pIiA8PCcoW0EtWjAtOV9dKyknJCcnJykKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFw
>> "!B64TMP!" echo ID0gYXJncGFyc2UuQXJndW1lbnRQYXJzZXIoCiAgICAgICAgZGVzY3JpcHRpb249IkV4dHJhY3Qg
>> "!B64TMP!" echo ZmlsZXMgZW1iZWRkZWQgaW4gYSBsb2NhbC1zZWFyY2ggLnNoIGluc3RhbGxlci9wYWNrZXIuIikK
>> "!B64TMP!" echo ICAgIGFwLmFkZF9hcmd1bWVudCgic291cmNlIiwgaGVscD0iaW5zdGFsbC1sb2NhbC1zZWFyY2gu
>> "!B64TMP!" echo c2ggb3IgbG9jYWwtc2VhcmNoLXJpZy5zaCIpCiAgICBhcC5hZGRfYXJndW1lbnQoIm91dGRpciIs
>> "!B64TMP!" echo IG5hcmdzPSI/IiwgZGVmYXVsdD0iZXh0cmFjdGVkIiwKICAgICAgICAgICAgICAgICAgICBoZWxw
>> "!B64TMP!" echo PSJvdXRwdXQgZGlyZWN0b3J5IChkZWZhdWx0OiAuL2V4dHJhY3RlZCkiKQogICAgYXJncyA9IGFw
>> "!B64TMP!" echo LnBhcnNlX2FyZ3MoKQoKICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4oYXJncy5zb3VyY2UsIGVu
>> "!B64TMP!" echo Y29kaW5nPSJ1dGYtOCIpIGFzIGZoOgogICAgICAgICAgICBsaW5lcyA9IGZoLnJlYWQoKS5zcGxp
>> "!B64TMP!" echo dCgiXG4iKQogICAgZXhjZXB0IE9TRXJyb3IgYXMgZToKICAgICAgICBwcmludCgiY2Fubm90IHJl
>> "!B64TMP!" echo YWQgJXM6ICVzIiAlIChhcmdzLnNvdXJjZSwgZSksIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBy
>> "!B64TMP!" echo ZXR1cm4gMgoKICAgIGNvdW50ID0gMAogICAgaSA9IDAKICAgIHdoaWxlIGkgPCBsZW4obGluZXMp
>> "!B64TMP!" echo OgogICAgICAgIG0gPSBfSEVSRURPQy5tYXRjaChsaW5lc1tpXSkKICAgICAgICBpZiBub3QgbToK
>> "!B64TMP!" echo ICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgcmVsLCB0YWcg
>> "!B64TMP!" echo PSBtLmdyb3VwKDEpLCBtLmdyb3VwKDIpCiAgICAgICAgaiA9IGkgKyAxCiAgICAgICAgYm9keSA9
>> "!B64TMP!" echo IFtdCiAgICAgICAgd2hpbGUgaiA8IGxlbihsaW5lcykgYW5kIGxpbmVzW2pdICE9IHRhZzoKICAg
>> "!B64TMP!" echo ICAgICAgICAgYm9keS5hcHBlbmQobGluZXNbal0pCiAgICAgICAgICAgIGogKz0gMQogICAgICAg
>> "!B64TMP!" echo IGlmIGogPj0gbGVuKGxpbmVzKToKICAgICAgICAgICAgcHJpbnQoInVudGVybWluYXRlZCBoZXJl
>> "!B64TMP!" echo ZG9jIGZvciAlcyIgJSByZWwsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDEK
>> "!B64TMP!" echo ICAgICAgICBjb250ZW50ID0gIlxuIi5qb2luKGJvZHkpICsgKCJcbiIgaWYgYm9keSBlbHNlICIi
>> "!B64TMP!" echo KQogICAgICAgIG91dCA9IG9zLnBhdGguam9pbihhcmdzLm91dGRpciwgKnJlbC5zcGxpdCgiLyIp
>> "!B64TMP!" echo KQogICAgICAgIHBhcmVudCA9IG9zLnBhdGguZGlybmFtZShvdXQpCiAgICAgICAgaWYgcGFyZW50
>> "!B64TMP!" echo OgogICAgICAgICAgICBvcy5tYWtlZGlycyhwYXJlbnQsIGV4aXN0X29rPVRydWUpCiAgICAgICAg
>> "!B64TMP!" echo d2l0aCBvcGVuKG91dCwgInciLCBlbmNvZGluZz0idXRmLTgiLCBuZXdsaW5lPSJcbiIpIGFzIGZo
>> "!B64TMP!" echo OgogICAgICAgICAgICBmaC53cml0ZShjb250ZW50KQogICAgICAgIGlmIHJlbC5lbmRzd2l0aCgi
>> "!B64TMP!" echo LmJhdCIpOgogICAgICAgICAgICAjIHJlc3RvcmUgQ1JMRiAodGhlIGhlcmVkb2MgYm9keSB3YXMg
>> "!B64TMP!" echo TEYtbm9ybWFsaXNlZCBhdCBwYWNrIHRpbWUpCiAgICAgICAgICAgIHdpdGggb3BlbihvdXQsICJy
>> "!B64TMP!" echo YiIpIGFzIGZoOgogICAgICAgICAgICAgICAgZGF0YSA9IGZoLnJlYWQoKQogICAgICAgICAgICB3
>> "!B64TMP!" echo aXRoIG9wZW4ob3V0LCAid2IiKSBhcyBmaDoKICAgICAgICAgICAgICAgIGZoLndyaXRlKGRhdGEu
>> "!B64TMP!" echo cmVwbGFjZShiIlxyXG4iLCBiIlxuIikucmVwbGFjZShiIlxuIiwgYiJcclxuIikpCiAgICAgICAg
>> "!B64TMP!" echo cHJpbnQoIiAgZXh0cmFjdGVkICVzIiAlIHJlbCkKICAgICAgICBjb3VudCArPSAxCiAgICAgICAg
>> "!B64TMP!" echo aSA9IGogKyAxCgogICAgaWYgY291bnQgPT0gMDoKICAgICAgICBwcmludCgibm8gZW1iZWRkZWQg
>> "!B64TMP!" echo aGVyZWRvY3MgZm91bmQgaW4gJXMgIgogICAgICAgICAgICAgICIoaXMgaXQgcmVhbGx5IGEgbG9j
>> "!B64TMP!" echo YWwtc2VhcmNoIC5zaCBhcnRpZmFjdD8pIiAlIGFyZ3Muc291cmNlLAogICAgICAgICAgICAgIGZp
>> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQogICAgcHJpbnQoIiVkIGZpbGVzIGV4dHJh
>> "!B64TMP!" echo Y3RlZCB0byAlcy8iICUgKGNvdW50LCBhcmdzLm91dGRpcikpCiAgICByZXR1cm4gMAoKCmlmIF9f
>> "!B64TMP!" echo bmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\extract-embedded.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- test_b64.py ---
set "B64TMP=%TEMP%\LSR104526216.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTaW11bGF0ZSB0aGUgLmJhdCBkZWNvZGVfYjY0IGxv
>> "!B64TMP!" echo Z2ljIGZvciBldmVyeSBlbWJlZGRlZCBmaWxlIGFuZCB2ZXJpZnkKdGhlIHJvdW5kLXRyaXAgbWF0
>> "!B64TMP!" echo Y2hlcyB0aGUgb3JpZ2luYWwgc291cmNlIGZpbGVzLiIiIgppbXBvcnQgYmFzZTY0CmltcG9ydCBy
>> "!B64TMP!" echo ZQppbXBvcnQgb3MKClNSQyA9IG9zLnBhdGguam9pbihvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5h
>> "!B64TMP!" echo YnNwYXRoKF9fZmlsZV9fKSksICJsb2NhbC1zZWFyY2giKQpCQVQgPSBvcy5wYXRoLmpvaW4oU1JD
>> "!B64TMP!" echo LCAiaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IikKU0ggID0gb3MucGF0aC5qb2luKFNSQywgImlu
>> "!B64TMP!" echo c3RhbGwtbG9jYWwtc2VhcmNoLnNoIikKCkZJTEVTID0gWwogICAgImNvbmZpZy9zZWFyeG5nL3Nl
>> "!B64TMP!" echo dHRpbmdzLnltbCIsCiAgICAiZG9ja2VyLWNvbXBvc2UueW1sIiwKICAgICIuZW52LmV4YW1wbGUi
>> "!B64TMP!" echo LAogICAgIlJFQURNRS5tZCIsCiAgICAiTElDRU5TRSIsCiAgICAiLmdpdGlnbm9yZSIsCiAgICAi
>> "!B64TMP!" echo LmdpdGF0dHJpYnV0ZXMiLAogICAgIlJ1bi5iYXQiLCAiU3RvcC5iYXQiLCAiVXBkYXRlLmJhdCIs
>> "!B64TMP!" echo ICJVbmluc3RhbGwuYmF0IiwKICAgICJydW4uc2giLCAic3RvcC5zaCIsICJ1cGRhdGUuc2giLCAi
>> "!B64TMP!" echo dW5pbnN0YWxsLnNoIiwKICAgICJsb2NhbC13ZWIvU0tJTEwubWQiLAogICAgImxvY2FsLXdlYi9M
>> "!B64TMP!" echo SUNFTlNFIiwKICAgICJsb2NhbC13ZWIvc2NyaXB0cy9jb25maWcucHkiLAogICAgImxvY2FsLXdl
>> "!B64TMP!" echo Yi9zY3JpcHRzL2Vuc3VyZV9zdGFjay5weSIsCiAgICAibG9jYWwtd2ViL3NjcmlwdHMvd2ViX3Nl
>> "!B64TMP!" echo YXJjaC5weSIsCiAgICAibG9jYWwtd2ViL3NjcmlwdHMvd2ViX3NjcmFwZS5weSIsCl0KCmRlZiBy
>> "!B64TMP!" echo ZWFkKHJlbCk6CiAgICB3aXRoIG9wZW4ob3MucGF0aC5qb2luKFNSQywgcmVsKSwgInJiIikgYXMg
>> "!B64TMP!" echo ZjoKICAgICAgICByZXR1cm4gZi5yZWFkKCkKCiMgLS0tLSBleHRyYWN0IGJhc2U2NCBibG9ja3Mg
>> "!B64TMP!" echo ZnJvbSB0aGUgLmJhdCAtLS0tCmJhdF90ZXh0ID0gb3BlbihCQVQsICJyIiwgZW5jb2Rpbmc9InV0
>> "!B64TMP!" echo Zi04IikucmVhZCgpCiMgQSBibG9jayBsb29rcyBsaWtlOgojICAgUkVNIC0tLSA8cmVsPiAtLS0K
>> "!B64TMP!" echo IyAgIHNldCAiTkVFRF9CNjQ9MSIKIyAgIC4uLgojICAgc2V0ICJCNjRUTVA9JVRFTVAlXExTeHh4
>> "!B64TMP!" echo eHh4LmI2NCIKIyAgID4gIiFCNjRUTVAhIiBlY2hvIExJTkUxCiMgICA+PiAiIUI2NFRNUCEiIGVj
>> "!B64TMP!" echo aG8gTElORTIKIyAgIC4uLgojICAgc2V0ICJMU19CNjRfSU49Li4uIgpibG9ja3MgPSB7fQpjdXJf
>> "!B64TMP!" echo cmVsID0gTm9uZQpjdXJfbGluZXMgPSBbXQpmb3IgbGluZSBpbiBiYXRfdGV4dC5zcGxpdCgiXG4i
>> "!B64TMP!" echo KToKICAgIG0gPSByZS5tYXRjaChyJ1JFTSAtLS0gKC4rPykgLS0tJCcsIGxpbmUpCiAgICBpZiBt
>> "!B64TMP!" echo OgogICAgICAgIGlmIGN1cl9yZWw6CiAgICAgICAgICAgIGJsb2Nrc1tjdXJfcmVsXSA9IGN1cl9s
>> "!B64TMP!" echo aW5lcwogICAgICAgIGN1cl9yZWwgPSBtLmdyb3VwKDEpCiAgICAgICAgY3VyX2xpbmVzID0gW10K
>> "!B64TMP!" echo ICAgICAgICBjb250aW51ZQogICAgbTIgPSByZS5tYXRjaChyJ1xzKj4+P1xzKiIhQjY0VE1QISJc
>> "!B64TMP!" echo cytlY2hvXHMrKC4rKSQnLCBsaW5lKQogICAgaWYgbTIgYW5kIGN1cl9yZWw6CiAgICAgICAgY3Vy
>> "!B64TMP!" echo X2xpbmVzLmFwcGVuZChtMi5ncm91cCgxKSkKaWYgY3VyX3JlbDoKICAgIGJsb2Nrc1tjdXJfcmVs
>> "!B64TMP!" echo XSA9IGN1cl9saW5lcwoKcHJpbnQoIkZvdW5kICVkIGVtYmVkZGVkIGJhc2U2NCBibG9ja3MgaW4g
>> "!B64TMP!" echo LmJhdCIgJSBsZW4oYmxvY2tzKSkKb2sgPSBUcnVlCmZvciByZWwgaW4gRklMRVM6CiAgICBvcmln
>> "!B64TMP!" echo ID0gcmVhZChyZWwpCiAgICBpZiByZWwgbm90IGluIGJsb2NrczoKICAgICAgICBwcmludCgiICBb
>> "!B64TMP!" echo TUlTU10gJS0zMnMgOiBubyBiYXNlNjQgYmxvY2sgaW4gLmJhdCIgJSByZWwpCiAgICAgICAgb2sg
>> "!B64TMP!" echo PSBGYWxzZQogICAgICAgIGNvbnRpbnVlCiAgICAjIGNvbmNhdGVuYXRlIGFuZCBzdHJpcCB3aGl0
>> "!B64TMP!" echo ZXNwYWNlIChtaXJyb3JzIFBTIC1yZXBsYWNlICdccycsJycpCiAgICBqb2luZWQgPSAiIi5qb2lu
>> "!B64TMP!" echo KGJsb2Nrc1tyZWxdKQogICAgdHJ5OgogICAgICAgIGRlYyA9IGJhc2U2NC5iNjRkZWNvZGUoam9p
>> "!B64TMP!" echo bmVkKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIHByaW50KCIgIFtGQUlMXSAl
>> "!B64TMP!" echo LTMycyA6IGI2NCBkZWNvZGUgZXJyb3I6ICVzIiAlIChyZWwsIGUpKQogICAgICAgIG9rID0gRmFs
>> "!B64TMP!" echo c2UKICAgICAgICBjb250aW51ZQogICAgaWYgZGVjID09IG9yaWc6CiAgICAgICAgcHJpbnQoIiAg
>> "!B64TMP!" echo W09LXSAgICUtMzJzIDogJWQgYnl0ZXMgcm91bmQtdHJpcCBPSyIgJSAocmVsLCBsZW4ob3JpZykp
>> "!B64TMP!" echo KQogICAgZWxzZToKICAgICAgICBwcmludCgiICBbRkFJTF0gJS0zMnMgOiBkZWNvZGVkICVkIGJ5
>> "!B64TMP!" echo dGVzICE9IG9yaWdpbmFsICVkIGJ5dGVzIiAlIChyZWwsIGxlbihkZWMpLCBsZW4ob3JpZykpKQog
>> "!B64TMP!" echo ICAgICAgIG9rID0gRmFsc2UKCnByaW50KCkKcHJpbnQoIkFMTCBHT09EIiBpZiBvayBlbHNlICJG
>> "!B64TMP!" echo QUlMVVJFUyBQUkVTRU5UIikK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\test_b64.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- test_heredocs.py ---
set "B64TMP=%TEMP%\LSR3121150853.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJFeHRyYWN0IGV2ZXJ5IHF1b3RlZCBoZXJlZG9jIGZy
>> "!B64TMP!" echo b20gdGhlIC5zaCBpbnN0YWxsZXIgYW5kIHZlcmlmeSB0aGUKY29udGVudCBtYXRjaGVzIHRoZSBv
>> "!B64TMP!" echo cmlnaW5hbCBzb3VyY2UgZmlsZXMgYnl0ZS1mb3ItYnl0ZS4iIiIKaW1wb3J0IG9zCmltcG9ydCBy
>> "!B64TMP!" echo ZQoKU1JDID0gb3MucGF0aC5qb2luKG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19m
>> "!B64TMP!" echo aWxlX18pKSwgImxvY2FsLXNlYXJjaCIpClNIICA9IG9zLnBhdGguam9pbihTUkMsICJpbnN0YWxs
>> "!B64TMP!" echo LWxvY2FsLXNlYXJjaC5zaCIpCnRleHQgPSBvcGVuKFNILCAiciIsIGVuY29kaW5nPSJ1dGYtOCIp
>> "!B64TMP!" echo LnJlYWQoKQoKRklMRVMgPSBbCiAgICAiY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sIiwgImRv
>> "!B64TMP!" echo Y2tlci1jb21wb3NlLnltbCIsICIuZW52LmV4YW1wbGUiLAogICAgIlJFQURNRS5tZCIsICJMSUNF
>> "!B64TMP!" echo TlNFIiwgIi5naXRpZ25vcmUiLCAiLmdpdGF0dHJpYnV0ZXMiLAogICAgIlJ1bi5iYXQiLCAiU3Rv
>> "!B64TMP!" echo cC5iYXQiLCAiVXBkYXRlLmJhdCIsICJVbmluc3RhbGwuYmF0IiwKICAgICJydW4uc2giLCAic3Rv
>> "!B64TMP!" echo cC5zaCIsICJ1cGRhdGUuc2giLCAidW5pbnN0YWxsLnNoIiwKICAgICJsb2NhbC13ZWIvU0tJTEwu
>> "!B64TMP!" echo bWQiLCAibG9jYWwtd2ViL0xJQ0VOU0UiLAogICAgImxvY2FsLXdlYi9zY3JpcHRzL2NvbmZpZy5w
>> "!B64TMP!" echo eSIsICJsb2NhbC13ZWIvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkiLAogICAgImxvY2FsLXdlYi9z
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9zZWFyY2gucHkiLCAibG9jYWwtd2ViL3NjcmlwdHMvd2ViX3NjcmFwZS5weSIs
>> "!B64TMP!" echo CiAgICAiaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IiwKXQoKZGVmIHJlYWQocmVsKToKICAgIHdp
>> "!B64TMP!" echo dGggb3Blbihvcy5wYXRoLmpvaW4oU1JDLCByZWwpLCAicmIiKSBhcyBmOgogICAgICAgIHJldHVy
>> "!B64TMP!" echo biBmLnJlYWQoKQoKIyBGaW5kIGJsb2NrcyBvZiB0aGUgZm9ybToKIyAgIGNhdCA+ICIkVEFSR0VU
>> "!B64TMP!" echo LzxyZWw+IiA8PCc8VEFHPicKIyAgIDxib2R5PgojICAgPFRBRz4KaGVyZWRvY3MgPSB7fQpsaW5l
>> "!B64TMP!" echo cyA9IHRleHQuc3BsaXQoIlxuIikKaSA9IDAKd2hpbGUgaSA8IGxlbihsaW5lcyk6CiAgICBtID0g
>> "!B64TMP!" echo cmUubWF0Y2gociJccypjYXQgPiBcIlwkVEFSR0VULyguKz8pXCIgPDwnKFtBLVowLTlfXSspJyQi
>> "!B64TMP!" echo LCBsaW5lc1tpXSkKICAgIGlmIG06CiAgICAgICAgcmVsLCB0YWcgPSBtLmdyb3VwKDEpLCBtLmdy
>> "!B64TMP!" echo b3VwKDIpCiAgICAgICAgYm9keV9zdGFydCA9IGkgKyAxCiAgICAgICAgIyBmaW5kIGNsb3Npbmcg
>> "!B64TMP!" echo dGFnCiAgICAgICAgaiA9IGJvZHlfc3RhcnQKICAgICAgICB3aGlsZSBqIDwgbGVuKGxpbmVzKSBh
>> "!B64TMP!" echo bmQgbGluZXNbal0gIT0gdGFnOgogICAgICAgICAgICBqICs9IDEKICAgICAgICBib2R5ID0gIlxu
>> "!B64TMP!" echo Ii5qb2luKGxpbmVzW2JvZHlfc3RhcnQ6al0pCiAgICAgICAgIyBldmVyeSBoZXJlZG9jIGxpbmUg
>> "!B64TMP!" echo KGluY2x1ZGluZyB0aGUgbGFzdCkgaXMgd3JpdHRlbiB3aXRoIGEgdHJhaWxpbmcKICAgICAgICAj
>> "!B64TMP!" echo IG5ld2xpbmUgYnkgdGhlIHNoZWxsLCBzbyBhcHBlbmQgaXQgYmFjayBhZnRlciB0aGUgam9pbi4K
>> "!B64TMP!" echo ICAgICAgICBpZiBib2R5X3N0YXJ0IDw9IGo6CiAgICAgICAgICAgIGJvZHkgKz0gIlxuIgogICAg
>> "!B64TMP!" echo ICAgIGhlcmVkb2NzW3JlbF0gPSBib2R5CiAgICAgICAgaSA9IGogKyAxCiAgICBlbHNlOgogICAg
>> "!B64TMP!" echo ICAgIGkgKz0gMQoKcHJpbnQoIkZvdW5kICVkIGhlcmVkb2NzIGluIC5zaCIgJSBsZW4oaGVyZWRv
>> "!B64TMP!" echo Y3MpKQpvayA9IFRydWUKZm9yIHJlbCBpbiBGSUxFUzoKICAgIG9yaWcgPSByZWFkKHJlbCkuZGVj
>> "!B64TMP!" echo b2RlKCJ1dGYtOCIpCiAgICBpZiByZWwgbm90IGluIGhlcmVkb2NzOgogICAgICAgIHByaW50KCIg
>> "!B64TMP!" echo IFtNSVNTXSAlLTMycyIgJSByZWwpCiAgICAgICAgb2sgPSBGYWxzZQogICAgICAgIGNvbnRpbnVl
>> "!B64TMP!" echo CiAgICAjIENvbXBhcmUgY29udGVudCBpZ25vcmluZyBsaW5lLWVuZGluZyBkaWZmZXJlbmNlczog
>> "!B64TMP!" echo dGhlIC5zaCBpbnN0YWxsZXIKICAgICMgd3JpdGVzIC5iYXQgZmlsZXMgdmlhIGhlcmVkb2MgKExG
>> "!B64TMP!" echo KSBhbmQgdGhlbiBhIHJ1bnRpbWUgQ1JMRi1jb252ZXJzaW9uCiAgICAjIGxvb3AgY29udmVydHMg
>> "!B64TMP!" echo dGhlbSB0byBDUkxGLiBTbyB0aGUgaGVyZWRvYyBib2R5IGhhcyBMRiB3aGVyZSB0aGUKICAgICMg
>> "!B64TMP!" echo b3JpZ2luYWwgLmJhdCBoYXMgQ1JMRiAtLSB0aGlzIGlzIGV4cGVjdGVkIGFuZCBjb3JyZWN0Lgog
>> "!B64TMP!" echo ICAgYSA9IGhlcmVkb2NzW3JlbF0ucmVwbGFjZSgiXHJcbiIsICJcbiIpCiAgICBiID0gb3JpZy5y
>> "!B64TMP!" echo ZXBsYWNlKCJcclxuIiwgIlxuIikKICAgIGlmIGEgPT0gYjoKICAgICAgICBwcmludCgiICBbT0td
>> "!B64TMP!" echo ICAgJS0zMnMgOiAlZCBieXRlcyAoY29udGVudCBtYXRjaGVzOyBDUkxGIGZpeGVkIGF0IHJ1bnRp
>> "!B64TMP!" echo bWUpIiAlIChyZWwsIGxlbihvcmlnKSkpCiAgICBlbHNlOgogICAgICAgIHByaW50KCIgIFtGQUlM
>> "!B64TMP!" echo XSAlLTMycyA6IGhlcmVkb2MgJWQgdnMgb3JpZyAlZCAoTEYtbm9ybWFsaXNlZCkiICUgKHJlbCwg
>> "!B64TMP!" echo bGVuKGEpLCBsZW4oYikpKQogICAgICAgIGZvciBrIGluIHJhbmdlKG1pbihsZW4oYSksIGxlbihi
>> "!B64TMP!" echo KSkpOgogICAgICAgICAgICBpZiBhW2tdICE9IGJba106CiAgICAgICAgICAgICAgICBwcmludCgi
>> "!B64TMP!" echo ICAgIGZpcnN0IGRpZmYgYXQgYnl0ZSAlZDogaGVyZWRvYz0lciBvcmlnPSVyIiAlIChrLCBhW2s6
>> "!B64TMP!" echo ayszMF0sIGJbazprKzMwXSkpCiAgICAgICAgICAgICAgICBicmVhawogICAgICAgIG9rID0gRmFs
>> "!B64TMP!" echo c2UKCnByaW50KCkKcHJpbnQoIkFMTCBHT09EIiBpZiBvayBlbHNlICJGQUlMVVJFUyIpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\test_heredocs.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- test_rig.py ---
set "B64TMP=%TEMP%\LSR1712786245.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJWZXJpZnkgYm90aCByaWcgcGFja2VycyAobG9jYWwt
>> "!B64TMP!" echo c2VhcmNoLXJpZy5iYXQgLyBsb2NhbC1zZWFyY2gtcmlnLnNoKSBlbWJlZAp0aGUgQ1VSUkVOVCBm
>> "!B64TMP!" echo aWxlcyBleGFjdGx5LiBSdW4gZnJvbSB0aGUgcmlnIHJvb3QgYWZ0ZXIgZ2VuX3JpZy5weS4KCiAg
>> "!B64TMP!" echo KiBsb2NhbC1zZWFyY2gtcmlnLmJhdCA6IGV2ZXJ5IGBSRU0gLS0tIDxmaWxlPiAtLS1gIGJhc2U2
>> "!B64TMP!" echo NCBibG9jayBtdXN0CiAgICBkZWNvZGUgdG8gdGhlIGV4YWN0IGJ5dGVzIG9mIHRoZSBmaWxlIG9u
>> "!B64TMP!" echo IGRpc2suCiAgKiBsb2NhbC1zZWFyY2gtcmlnLnNoICA6IGV2ZXJ5IGBjYXQgPiAiJFRBUkdFVC88
>> "!B64TMP!" echo ZmlsZT4iIDw8J1RBRydgIGhlcmVkb2MKICAgIG11c3QgbWF0Y2ggdGhlIGZpbGUgb24gZGlzayAo
>> "!B64TMP!" echo TEYtbm9ybWFsaXNlZDsgQ1JMRiBpcyByZXN0b3JlZCBmb3IgLmJhdAogICAgZmlsZXMgYnkgdGhl
>> "!B64TMP!" echo IHBhY2tlcidzIGF3ayBsb29wIGF0IHVucGFjayB0aW1lKS4KIiIiCmltcG9ydCBiYXNlNjQKaW1w
>> "!B64TMP!" echo b3J0IG9zCmltcG9ydCByZQppbXBvcnQgc3lzCgpST09UID0gb3MucGF0aC5kaXJuYW1lKG9zLnBh
>> "!B64TMP!" echo dGguYWJzcGF0aChfX2ZpbGVfXykpCnN5cy5wYXRoLmluc2VydCgwLCBST09UKQpmcm9tIGdlbl9y
>> "!B64TMP!" echo aWcgaW1wb3J0IFJJR19GSUxFUywgU09VUkNFX0ZJTEVTICAjIG5vcWE6IEU0MDIKCkJBVCA9IG9z
>> "!B64TMP!" echo LnBhdGguam9pbihST09ULCAibG9jYWwtc2VhcmNoLXJpZy5iYXQiKQpTSCA9IG9zLnBhdGguam9p
>> "!B64TMP!" echo bihST09ULCAibG9jYWwtc2VhcmNoLXJpZy5zaCIpCgpmYWlsdXJlcyA9IFtdCgoKZGVmIGRpc2tf
>> "!B64TMP!" echo Ynl0ZXMocmVsKToKICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4oUk9PVCwgKnJlbC5zcGxpdCgi
>> "!B64TMP!" echo LyIpKSwgInJiIikgYXMgZjoKICAgICAgICByZXR1cm4gZi5yZWFkKCkKCgojIC0tLS0gMS4gYmFz
>> "!B64TMP!" echo ZTY0IGJsb2NrcyBpbiB0aGUgLmJhdCBwYWNrZXIgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0KYmF0X3RleHQgPSBvcGVuKEJBVCwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpCmJs
>> "!B64TMP!" echo b2NrcyA9IHt9CmN1ciwgY3VyX2xpbmVzID0gTm9uZSwgW10KZm9yIGxpbmUgaW4gYmF0X3RleHQu
>> "!B64TMP!" echo c3BsaXQoIlxuIik6CiAgICBtID0gcmUubWF0Y2gociJSRU0gLS0tICguKz8pIC0tLSQiLCBsaW5l
>> "!B64TMP!" echo KQogICAgaWYgbToKICAgICAgICBpZiBjdXIgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGJsb2Nr
>> "!B64TMP!" echo c1tjdXJdID0gY3VyX2xpbmVzCiAgICAgICAgY3VyLCBjdXJfbGluZXMgPSBtLmdyb3VwKDEpLCBb
>> "!B64TMP!" echo XQogICAgICAgIGNvbnRpbnVlCiAgICBtMiA9IHJlLm1hdGNoKHInXHMqPj4/XHMqIiFCNjRUTVAh
>> "!B64TMP!" echo IlxzK2VjaG9ccysoLispJCcsIGxpbmUpCiAgICBpZiBtMiBhbmQgY3VyIGlzIG5vdCBOb25lOgog
>> "!B64TMP!" echo ICAgICAgIGN1cl9saW5lcy5hcHBlbmQobTIuZ3JvdXAoMSkpCmlmIGN1ciBpcyBub3QgTm9uZToK
>> "!B64TMP!" echo ICAgIGJsb2Nrc1tjdXJdID0gY3VyX2xpbmVzCgpleHBlY3RlZCA9IFsibG9jYWwtc2VhcmNoLyIg
>> "!B64TMP!" echo KyBzIGZvciBzIGluIFNPVVJDRV9GSUxFU10gKyBSSUdfRklMRVMKcHJpbnQoImxvY2FsLXNlYXJj
>> "!B64TMP!" echo aC1yaWcuYmF0OiAlZCBlbWJlZGRlZCBiYXNlNjQgYmxvY2tzIiAlIGxlbihibG9ja3MpKQpmb3Ig
>> "!B64TMP!" echo bGFiZWwgaW4gZXhwZWN0ZWQ6CiAgICBpZiBsYWJlbCBub3QgaW4gYmxvY2tzOgogICAgICAgIGZh
>> "!B64TMP!" echo aWx1cmVzLmFwcGVuZCgiYmF0IG1pc3NpbmcgYmxvY2s6ICIgKyBsYWJlbCkKICAgICAgICBjb250
>> "!B64TMP!" echo aW51ZQogICAgdHJ5OgogICAgICAgIGRlYyA9IGJhc2U2NC5iNjRkZWNvZGUoIiIuam9pbihibG9j
>> "!B64TMP!" echo a3NbbGFiZWxdKSkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICBmYWlsdXJlcy5h
>> "!B64TMP!" echo cHBlbmQoImJhdCBiYWQgYmFzZTY0ICVzOiAlcyIgJSAobGFiZWwsIGUpKQogICAgICAgIGNvbnRp
>> "!B64TMP!" echo bnVlCiAgICB3YW50ID0gZGlza19ieXRlcyhsYWJlbCkKICAgIGlmIGRlYyA9PSB3YW50OgogICAg
>> "!B64TMP!" echo ICAgIHByaW50KCIgIFtPS10gICAlLTQ2cyAlZCBieXRlcyIgJSAobGFiZWwsIGxlbih3YW50KSkp
>> "!B64TMP!" echo CiAgICBlbHNlOgogICAgICAgIGZhaWx1cmVzLmFwcGVuZCgiYmF0IG1pc21hdGNoOiAlcyAoJWQg
>> "!B64TMP!" echo dnMgJWQgYnl0ZXMpIiAlIChsYWJlbCwgbGVuKGRlYyksIGxlbih3YW50KSkpCgppZiAnY29weSAv
>> "!B64TMP!" echo WSAiJX5mMCInIG5vdCBpbiBiYXRfdGV4dDoKICAgIGZhaWx1cmVzLmFwcGVuZCgiYmF0IHBhY2tl
>> "!B64TMP!" echo ciBsb3N0IGl0cyBzZWxmLWNvcHkgbGluZSIpCgojIC0tLS0gMi4gaGVyZWRvY3MgaW4gdGhlIC5z
>> "!B64TMP!" echo aCBwYWNrZXIgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0Kc2hfdGV4
>> "!B64TMP!" echo dCA9IG9wZW4oU0gsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKQpsaW5lcyA9IHNoX3RleHQuc3Bs
>> "!B64TMP!" echo aXQoIlxuIikKaGVyZWRvY3MgPSB7fQppID0gMAp3aGlsZSBpIDwgbGVuKGxpbmVzKToKICAgIG0g
>> "!B64TMP!" echo PSByZS5tYXRjaChyIlxzKmNhdCA+IFwiXCRUQVJHRVQvKC4rPylcIiA8PCcoW0EtWjAtOV9dKykn
>> "!B64TMP!" echo JCIsIGxpbmVzW2ldKQogICAgaWYgbToKICAgICAgICByZWwsIHRhZyA9IG0uZ3JvdXAoMSksIG0u
>> "!B64TMP!" echo Z3JvdXAoMikKICAgICAgICBqID0gaSArIDEKICAgICAgICB3aGlsZSBqIDwgbGVuKGxpbmVzKSBh
>> "!B64TMP!" echo bmQgbGluZXNbal0gIT0gdGFnOgogICAgICAgICAgICBqICs9IDEKICAgICAgICBpZiBqID49IGxl
>> "!B64TMP!" echo bihsaW5lcyk6CiAgICAgICAgICAgIGZhaWx1cmVzLmFwcGVuZCgic2ggaGVyZWRvYyBmb3IgJXMg
>> "!B64TMP!" echo aGFzIG5vIGNsb3NpbmcgdGFnIiAlIHJlbCkKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAg
>> "!B64TMP!" echo IGNvbnRpbnVlCiAgICAgICAgYm9keSA9ICJcbiIuam9pbihsaW5lc1tpICsgMTpqXSkKICAgICAg
>> "!B64TMP!" echo ICBpZiBpICsgMSA8PSBqOgogICAgICAgICAgICBib2R5ICs9ICJcbiIKICAgICAgICBoZXJlZG9j
>> "!B64TMP!" echo c1tyZWxdID0gYm9keQogICAgICAgIGkgPSBqICsgMQogICAgZWxzZToKICAgICAgICBpICs9IDEK
>> "!B64TMP!" echo CmV4cGVjdGVkX3NoID0gZXhwZWN0ZWQgKyBbImxvY2FsLXNlYXJjaC1yaWcuYmF0Il0KcHJpbnQo
>> "!B64TMP!" echo ImxvY2FsLXNlYXJjaC1yaWcuc2g6ICVkIGVtYmVkZGVkIGhlcmVkb2NzIiAlIGxlbihoZXJlZG9j
>> "!B64TMP!" echo cykpCmZvciBsYWJlbCBpbiBleHBlY3RlZF9zaDoKICAgIGlmIGxhYmVsIG5vdCBpbiBoZXJlZG9j
>> "!B64TMP!" echo czoKICAgICAgICBmYWlsdXJlcy5hcHBlbmQoInNoIG1pc3NpbmcgaGVyZWRvYzogIiArIGxhYmVs
>> "!B64TMP!" echo KQogICAgICAgIGNvbnRpbnVlCiAgICB3YW50ID0gZGlza19ieXRlcyhsYWJlbCkuZGVjb2RlKCJ1
>> "!B64TMP!" echo dGYtOCIpLnJlcGxhY2UoIlxyXG4iLCAiXG4iKS5yZXBsYWNlKCJcciIsICJcbiIpCiAgICBnb3Qg
>> "!B64TMP!" echo PSBoZXJlZG9jc1tsYWJlbF0KICAgIGlmIGdvdCA9PSB3YW50OgogICAgICAgIHByaW50KCIgIFtP
>> "!B64TMP!" echo S10gICAlLTQ2cyAlZCBieXRlcyIgJSAobGFiZWwsIGxlbih3YW50KSkpCiAgICBlbHNlOgogICAg
>> "!B64TMP!" echo ICAgIGZhaWx1cmVzLmFwcGVuZCgic2ggbWlzbWF0Y2g6ICVzICglZCB2cyAlZCBieXRlcykiICUg
>> "!B64TMP!" echo KGxhYmVsLCBsZW4oZ290KSwgbGVuKHdhbnQpKSkKCmlmICdjcCAtZiAiJDAiICIkVEFSR0VUL2xv
>> "!B64TMP!" echo Y2FsLXNlYXJjaC1yaWcuc2giJyBub3QgaW4gc2hfdGV4dDoKICAgIGZhaWx1cmVzLmFwcGVuZCgi
>> "!B64TMP!" echo c2ggcGFja2VyIGxvc3QgaXRzIHNlbGYtY29weSBsaW5lIikKaWYgJ3ByaW50ZiAiJXNcXHJcXG4i
>> "!B64TMP!" echo LCAkMCcgbm90IGluIHNoX3RleHQ6CiAgICBmYWlsdXJlcy5hcHBlbmQoInNoIHBhY2tlciBsb3N0
>> "!B64TMP!" echo IGl0cyBDUkxGLXJlc3RvcmUgYXdrIGxvb3AiKQoKcHJpbnQoKQppZiBmYWlsdXJlczoKICAgIGZv
>> "!B64TMP!" echo ciBmIGluIGZhaWx1cmVzOgogICAgICAgIHByaW50KCIgIFtGQUlMXSAiICsgZikKICAgIHByaW50
>> "!B64TMP!" echo KCJURVNUUyBGQUlMRUQiKQogICAgc3lzLmV4aXQoMSkKcHJpbnQoIkFMTCBHT09EIikK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\test_rig.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- e2e_test.sh ---
set "B64TMP=%TEMP%\LSR3546911650.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIEVuZC10by1lbmQgdGVzdCBvZiBpbnN0YWxsLWxvY2FsLXNl
>> "!B64TMP!" echo YXJjaC5zaDoKIyAgICogc2ltdWxhdGVzIGRvd25sb2FkaW5nIE9OTFkgdGhlIGluc3RhbGxlciAo
>> "!B64TMP!" echo bm90aGluZyBlbHNlIG5leHQgdG8gaXQpCiMgICAqIG1vY2tzIGRvY2tlciBzbyB0aGUgaW5zdGFs
>> "!B64TMP!" echo bCBsb2dpYyBydW5zIGZ1bGx5CiMgICAqIHZlcmlmaWVzIHRoZSBwcm9kdWNlZCBpbnN0YWxsIGZv
>> "!B64TMP!" echo bGRlciwgdGhlIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViCiMgICAgIHNraWxsIGluc3RhbGws
>> "!B64TMP!" echo IHRoZSBpbnN0YWxsLWRpci50eHQgaGludCwgYW5kIHRoZSB1bmluc3RhbGxlci4KIyAgICogU0VM
>> "!B64TMP!" echo Ri1IRUFMIHRlc3Q6IGZha2UgU2VhclhORy9GaXJlY3Jhd2wgSFRUUCBzZXJ2ZXJzICsgYSBtb2Nr
>> "!B64TMP!" echo CiMgICAgIGBkb2NrZXIgY29tcG9zZSB1cGAgdGhhdCBzdGFydHMgdGhlbSwgdmVyaWZ5aW5nIHRo
>> "!B64TMP!" echo YXQgd2ViX3NlYXJjaC5weSAvCiMgICAgIHdlYl9zY3JhcGUucHkgYXV0by1zdGFydCBhIGRvd24g
>> "!B64TMP!" echo c3RhY2sgYW5kIHJldHJ5IChhbmQgcmVwb3J0IGNsZWFubHkKIyAgICAgd2hlbiB0aGUgc3RhY2sg
>> "!B64TMP!" echo Y2Fubm90IGNvbWUgdXApLgojIEFueSBwcmUtZXhpc3Rpbmcgfi8uYWdlbnRzL3NraWxscy9sb2Nh
>> "!B64TMP!" echo bC13ZWIgaXMgYmFja2VkIHVwIGFuZCByZXN0b3JlZC4Kc2V0IC11CgpST09UPSIkKGNkICIkKGRp
>> "!B64TMP!" echo cm5hbWUgIiQwIikiICYmIHB3ZCkiCklOU1RBTExFUj0iJFJPT1QvbG9jYWwtc2VhcmNoL2luc3Rh
>> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLnNoIgpURVNUUk9PVD0iJFJPT1QvLmxzLXRlc3QtJCQiClNSQ19ESVI9
>> "!B64TMP!" echo IiRURVNUUk9PVC9zcmMtb25seS1pbnN0YWxsZXIiClRHVF9ESVI9IiRURVNUUk9PVC90YXJnZXQi
>> "!B64TMP!" echo Ck1PQ0tCSU49IiRURVNUUk9PVC9iaW4iClNLSUxMX0RJUj0iJEhPTUUvLmFnZW50cy9za2lsbHMv
>> "!B64TMP!" echo bG9jYWwtd2ViIgpTS0lMTF9CQUs9IiIKClBZPSIkKGNvbW1hbmQgLXYgcHl0aG9uMyB8fCBjb21t
>> "!B64TMP!" echo YW5kIC12IHB5dGhvbikiCmlmIFsgLXogIiRQWSIgXTsgdGhlbgogIGVjaG8gIltFUlJPUl0gcHl0
>> "!B64TMP!" echo aG9uMy9weXRob24gaXMgcmVxdWlyZWQgZm9yIHRoaXMgdGVzdC4iID4mMgogIGV4aXQgMQpmaQoK
>> "!B64TMP!" echo Y2xlYW51cCgpIHsKICByYz0kPwogICMga2lsbCB0aGUgZmFrZSBzdGFjayBzZXJ2ZXIgaWYgYSBz
>> "!B64TMP!" echo ZWxmLWhlYWwgcGhhc2UgbGVmdCBpdCBydW5uaW5nCiAgaWYgWyAtZiAiJFRFU1RST09UL2Zha2Vf
>> "!B64TMP!" echo c3RhY2sucGlkIiBdOyB0aGVuCiAgICBraWxsICIkKGNhdCAiJFRFU1RST09UL2Zha2Vfc3RhY2su
>> "!B64TMP!" echo cGlkIiAyPi9kZXYvbnVsbCkiIDI+L2Rldi9udWxsCiAgICBybSAtZiAiJFRFU1RST09UL2Zha2Vf
>> "!B64TMP!" echo c3RhY2sucGlkIgogIGZpCiAgcm0gLXJmICIkU0tJTExfRElSIiAyPi9kZXYvbnVsbAogIGlmIFsg
>> "!B64TMP!" echo LW4gIiRTS0lMTF9CQUsiIF0gJiYgWyAtZCAiJFNLSUxMX0JBSyIgXTsgdGhlbgogICAgbXYgIiRT
>> "!B64TMP!" echo S0lMTF9CQUsiICIkU0tJTExfRElSIiAyPi9kZXYvbnVsbAogIGZpCiAgaWYgWyAiJHJjIiA9IDAg
>> "!B64TMP!" echo XTsgdGhlbiBybSAtcmYgIiRURVNUUk9PVCI7IGZpCn0KdHJhcCBjbGVhbnVwIEVYSVQKCm1rZGly
>> "!B64TMP!" echo IC1wICIkU1JDX0RJUiIgIiRUR1RfRElSIiAiJE1PQ0tCSU4iCgojIEJhY2sgdXAgYW55IHJlYWwg
>> "!B64TMP!" echo c2tpbGwgaW5zdGFsbCBzbyB0aGUgdGVzdCBjYW4gbmV2ZXIgZGVzdHJveSBpdC4KaWYgWyAtZCAi
>> "!B64TMP!" echo JFNLSUxMX0RJUiIgXTsgdGhlbgogIFNLSUxMX0JBSz0iJFRFU1RST09UL3NraWxsLWJhY2t1cCIK
>> "!B64TMP!" echo ICBtdiAiJFNLSUxMX0RJUiIgIiRTS0lMTF9CQUsiCmZpCgojIC0tLSBtb2NrIGRvY2tlciArIGRv
>> "!B64TMP!" echo Y2tlciBjb21wb3NlIHNvIHRoZSBpbnN0YWxsZXIncyBjaGVja3MgcGFzcyAtLS0tLS0tLS0tLQpj
>> "!B64TMP!" echo YXQgPiAiJE1PQ0tCSU4vZG9ja2VyIiA8PCdNT0NLJwojIS91c3IvYmluL2VudiBiYXNoCmNhc2Ug
>> "!B64TMP!" echo IiQxIiBpbgogIGluZm8pICAgICAgICBleGl0IDAgOzsKICBjb21wb3NlKQogICAgY2FzZSAiJDIi
>> "!B64TMP!" echo IGluCiAgICAgIHZlcnNpb24pIGVjaG8gIkRvY2tlciBDb21wb3NlIHZlcnNpb24gdjIuMC4wLXRl
>> "!B64TMP!" echo c3QiOyBleGl0IDAgOzsKICAgICAgcHVsbCkgICAgZWNobyAiW21vY2tdIHB1bGwgb2siOyAgIGV4
>> "!B64TMP!" echo aXQgMCA7OwogICAgICB1cCkgICAgICBlY2hvICJbbW9ja10gdXAgb2siOyAgICAgZXhpdCAwIDs7
>> "!B64TMP!" echo CiAgICAgIGRvd24pICAgIGVjaG8gIlttb2NrXSBkb3duIG9rIjsgICBleGl0IDAgOzsKICAgICAg
>> "!B64TMP!" echo KikgICAgICAgZWNobyAiW21vY2tdIGRvY2tlciBjb21wb3NlICQqIjsgZXhpdCAwIDs7CiAgICBl
>> "!B64TMP!" echo c2FjIDs7CiAgKikgZWNobyAiW21vY2tdIGRvY2tlciAkKiI7IGV4aXQgMCA7Owplc2FjCk1PQ0sK
>> "!B64TMP!" echo Y2htb2QgK3ggIiRNT0NLQklOL2RvY2tlciIKZXhwb3J0IFBBVEg9IiRNT0NLQklOOiRQQVRIIgoK
>> "!B64TMP!" echo IyAtLS0gY29weSBPTkxZIHRoZSBpbnN0YWxsZXIgLnNoIGludG8gdGhlIHNvdXJjZSBmb2xkZXIg
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLQpjcCAiJElOU1RBTExFUiIgIiRTUkNfRElSLyIKY2htb2QgK3gg
>> "!B64TMP!" echo IiRTUkNfRElSL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIgoKZWNobyAiU291cmNlIGZvbGRlciBj
>> "!B64TMP!" echo b250ZW50cyAoc2hvdWxkIGJlIE9OTFkgaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gpOiIKbHMgLWxh
>> "!B64TMP!" echo ICIkU1JDX0RJUiIKZWNobwoKIyAtLS0gcnVuIHRoZSBpbnN0YWxsZXIgd2l0aCBzY3JpcHRlZCBh
>> "!B64TMP!" echo bnN3ZXJzIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyAgIFN0ZXAgMTogdGFyZ2V0
>> "!B64TMP!" echo IGZvbGRlciwgU3RlcCAyOiBzZWFyeG5nIHBvcnQsIFN0ZXAgMzogZmlyZWNyYXdsIHBvcnQsCiMg
>> "!B64TMP!" echo ICBTdGVwIDQ6IGNvbm5lY3QgTExNPyAtPiBuLCAgY29uZmlybSAtPiB5CnByaW50ZiAnJXNcbiVz
>> "!B64TMP!" echo XG4lc1xuJXNcbiVzXG4nIFwKICAiJFRHVF9ESVIiIFwKICAiIiBcCiAgIiIgXAogICJuIiBcCiAg
>> "!B64TMP!" echo InkiIHwgIiRTUkNfRElSL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiA+ICIkVEVTVFJPT1QvaW5z
>> "!B64TMP!" echo dGFsbC5sb2ciIDI+JjEKUkM9JD8KZWNobyAiSW5zdGFsbGVyIGV4aXQgY29kZTogJFJDIgplY2hv
>> "!B64TMP!" echo ICItLS0tLSBpbnN0YWxsLmxvZyAodGFpbCkgLS0tLS0iCnRhaWwgLTMwICIkVEVTVFJPT1QvaW5z
>> "!B64TMP!" echo dGFsbC5sb2ciCmVjaG8gIi0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIgoKUEFTUz0x
>> "!B64TMP!" echo ClsgIiRSQyIgPSAwIF0gfHwgUEFTUz0wCgojIC0tLSB2ZXJpZnkgdGhlIHRhcmdldCBmb2xkZXIg
>> "!B64TMP!" echo aGFzIGV2ZXJ5dGhpbmcgd2UgZXhwZWN0IC0tLS0tLS0tLS0tLS0tLS0tLS0tCmVjaG8KZWNobyAi
>> "!B64TMP!" echo VGFyZ2V0IGZvbGRlciBjb250ZW50czoiCmxzIC1sYSAiJFRHVF9ESVIiCmVjaG8KZWNobyAiVGFy
>> "!B64TMP!" echo Z2V0IGNvbmZpZy9zZWFyeG5nIGNvbnRlbnRzOiIKbHMgLWxhICIkVEdUX0RJUi9jb25maWcvc2Vh
>> "!B64TMP!" echo cnhuZyIKZWNobwplY2hvICJUYXJnZXQgbG9jYWwtd2ViIGNvbnRlbnRzOiIKZmluZCAiJFRHVF9E
>> "!B64TMP!" echo SVIvbG9jYWwtd2ViIiAtdHlwZSBmIHwgc29ydAoKY2hlY2soKSB7CiAgaWYgWyAtcyAiJFRHVF9E
>> "!B64TMP!" echo SVIvJDEiIF07IHRoZW4KICAgIGVjaG8gIiAgW09LXSAgICQxICAoJCh3YyAtYyA8ICIkVEdUX0RJ
>> "!B64TMP!" echo Ui8kMSIpIGJ5dGVzKSIKICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSAkMSAgKG1pc3Npbmcgb3Ig
>> "!B64TMP!" echo ZW1wdHkpIgogICAgUEFTUz0wCiAgZmkKfQplY2hvCmVjaG8gIkNoZWNraW5nIGV4cGVjdGVkIGZp
>> "!B64TMP!" echo bGVzOiIKY2hlY2sgImRvY2tlci1jb21wb3NlLnltbCIKY2hlY2sgIi5lbnYuZXhhbXBsZSIKY2hl
>> "!B64TMP!" echo Y2sgIi5lbnYiCmNoZWNrICJSRUFETUUubWQiCmNoZWNrICJMSUNFTlNFIgpjaGVjayAiLmdpdGln
>> "!B64TMP!" echo bm9yZSIKY2hlY2sgIi5naXRhdHRyaWJ1dGVzIgpjaGVjayAiY29uZmlnL3NlYXJ4bmcvc2V0dGlu
>> "!B64TMP!" echo Z3MueW1sIgpjaGVjayAiUnVuLmJhdCIKY2hlY2sgIlN0b3AuYmF0IgpjaGVjayAiVXBkYXRlLmJh
>> "!B64TMP!" echo dCIKY2hlY2sgIlVuaW5zdGFsbC5iYXQiCmNoZWNrICJydW4uc2giCmNoZWNrICJzdG9wLnNoIgpj
>> "!B64TMP!" echo aGVjayAidXBkYXRlLnNoIgpjaGVjayAidW5pbnN0YWxsLnNoIgpjaGVjayAibG9jYWwtd2ViL1NL
>> "!B64TMP!" echo SUxMLm1kIgpjaGVjayAibG9jYWwtd2ViL0xJQ0VOU0UiCmNoZWNrICJsb2NhbC13ZWIvc2NyaXB0
>> "!B64TMP!" echo cy9jb25maWcucHkiCmNoZWNrICJsb2NhbC13ZWIvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkiCmNo
>> "!B64TMP!" echo ZWNrICJsb2NhbC13ZWIvc2NyaXB0cy93ZWJfc2VhcmNoLnB5IgpjaGVjayAibG9jYWwtd2ViL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX3NjcmFwZS5weSIKY2hlY2sgImluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCIKY2hl
>> "!B64TMP!" echo Y2sgImluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIgoKIyB2ZXJpZnkgLmVudiBoYXMgdGhlIGNob3Nl
>> "!B64TMP!" echo biBwb3J0cyArIGEgcmVhbCBzZWNyZXQKZWNobwplY2hvICItLS0tLSAuZW52IGNvbnRlbnRzIC0t
>> "!B64TMP!" echo LS0tIgpjYXQgIiRUR1RfRElSLy5lbnYiCmVjaG8gIi0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0i
>> "!B64TMP!" echo CgppZiBncmVwIC1xICJeU0VBUlhOR19QT1JUPTk5OTAkIiAiJFRHVF9ESVIvLmVudiIgXAogICAm
>> "!B64TMP!" echo JiBncmVwIC1xICJeRklSRUNSQVdMX1BPUlQ9OTk5MSQiICIkVEdUX0RJUi8uZW52IiBcCiAgICYm
>> "!B64TMP!" echo IGdyZXAgLXEgIl5TRUFSWE5HX1NFQ1JFVD1bMC05YS1mXVx7NjRcfSQiICIkVEdUX0RJUi8uZW52
>> "!B64TMP!" echo IjsgdGhlbgogIGVjaG8gIltPS10gLmVudiBoYXMgY29ycmVjdCBwb3J0cyBhbmQgYSA2NC1oZXgg
>> "!B64TMP!" echo c2VjcmV0IgplbHNlCiAgZWNobyAiW0ZBSUxdIC5lbnYgaXMgbWFsZm9ybWVkIgogIFBBU1M9MApm
>> "!B64TMP!" echo aQoKIyB2ZXJpZnkgdGhlIHNlY3JldCBnb3QgaW5qZWN0ZWQgaW50byBzZXR0aW5ncy55bWwgKG5v
>> "!B64TMP!" echo IHBsYWNlaG9sZGVyIGxlZnQpCmlmIGdyZXAgLXEgIl9fU0VBUlhOR19TRUNSRVRfUExBQ0VIT0xE
>> "!B64TMP!" echo RVJfXyIgIiRUR1RfRElSL2NvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbCI7IHRoZW4KICBlY2hv
>> "!B64TMP!" echo ICJbRkFJTF0gc2V0dGluZ3MueW1sIHN0aWxsIGhhcyB0aGUgcGxhY2Vob2xkZXIgKGluamVjdGlv
>> "!B64TMP!" echo biBmYWlsZWQpIgogIFBBU1M9MAplbHNlCiAgZWNobyAiW09LXSBzZXR0aW5ncy55bWwgbm8gbG9u
>> "!B64TMP!" echo Z2VyIGhhcyB0aGUgcGxhY2Vob2xkZXIgKHNlY3JldCBpbmplY3RlZCkiCmZpCgojIHZlcmlmeSAu
>> "!B64TMP!" echo YmF0IGZpbGVzIGhhdmUgQ1JMRiBsaW5lIGVuZGluZ3MKQkFUX0hBU19DUkxGPTEKZm9yIGYgaW4g
>> "!B64TMP!" echo UnVuLmJhdCBTdG9wLmJhdCBVcGRhdGUuYmF0IFVuaW5zdGFsbC5iYXQgaW5zdGFsbC1sb2NhbC1z
>> "!B64TMP!" echo ZWFyY2guYmF0OyBkbwogIGlmICEgZ3JlcCAtcSAkJ1xyJyAiJFRHVF9ESVIvJGYiIDI+L2Rldi9u
>> "!B64TMP!" echo dWxsOyB0aGVuCiAgICBlY2hvICJbRkFJTF0gJGYgZG9lcyBub3QgaGF2ZSBDUkxGIGxpbmUgZW5k
>> "!B64TMP!" echo aW5ncyIKICAgIEJBVF9IQVNfQ1JMRj0wCiAgZmkKZG9uZQpbICIkQkFUX0hBU19DUkxGIiA9IDEg
>> "!B64TMP!" echo XSAmJiBlY2hvICJbT0tdIGFsbCAuYmF0IGZpbGVzIGhhdmUgQ1JMRiBsaW5lIGVuZGluZ3MiCgoj
>> "!B64TMP!" echo IC0tLSB2ZXJpZnkgdGhlIHNraWxsIHdhcyBpbnN0YWxsZWQgaW50byB+Ly5hZ2VudHMvc2tpbGxz
>> "!B64TMP!" echo L2xvY2FsLXdlYiAtLS0tLS0tLQplY2hvCmVjaG8gIlNraWxsIGRpciBjb250ZW50cyAoJFNLSUxM
>> "!B64TMP!" echo X0RJUik6IgpmaW5kICIkU0tJTExfRElSIiAtdHlwZSBmIDI+L2Rldi9udWxsIHwgc29ydAoKZm9y
>> "!B64TMP!" echo IGYgaW4gU0tJTEwubWQgTElDRU5TRSBzY3JpcHRzL2NvbmZpZy5weSBzY3JpcHRzL2Vuc3VyZV9z
>> "!B64TMP!" echo dGFjay5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX3NlYXJjaC5weSBzY3JpcHRzL3dlYl9zY3Jh
>> "!B64TMP!" echo cGUucHk7IGRvCiAgaWYgWyAtcyAiJFNLSUxMX0RJUi8kZiIgXTsgdGhlbgogICAgZWNobyAiICBb
>> "!B64TMP!" echo T0tdICAgc2tpbGw6ICRmIgogIGVsc2UKICAgIGVjaG8gIiAgW0ZBSUxdIHNraWxsOiAkZiAobWlz
>> "!B64TMP!" echo c2luZyBvciBlbXB0eSkiCiAgICBQQVNTPTAKICBmaQpkb25lCgojIHZlcmlmeSB0aGUgc2tpbGwg
>> "!B64TMP!" echo ZmlsZXMgYXJlIGlkZW50aWNhbCB0byB0aGUgdGFyZ2V0J3MgbG9jYWwtd2ViIGNvcGllcwpmb3Ig
>> "!B64TMP!" echo ZiBpbiBTS0lMTC5tZCBMSUNFTlNFIHNjcmlwdHMvY29uZmlnLnB5IHNjcmlwdHMvZW5zdXJlX3N0
>> "!B64TMP!" echo YWNrLnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfc2VhcmNoLnB5IHNjcmlwdHMvd2ViX3NjcmFw
>> "!B64TMP!" echo ZS5weTsgZG8KICBpZiBjbXAgLXMgIiRTS0lMTF9ESVIvJGYiICIkVEdUX0RJUi9sb2NhbC13ZWIv
>> "!B64TMP!" echo JGYiOyB0aGVuCiAgICBlY2hvICIgIFtPS10gICBza2lsbCBmaWxlIG1hdGNoZXMgYnVuZGxlZCBj
>> "!B64TMP!" echo b3B5OiAkZiIKICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSBza2lsbCBmaWxlIGRpZmZlcnMgZnJv
>> "!B64TMP!" echo bSBidW5kbGVkIGNvcHk6ICRmIgogICAgUEFTUz0wCiAgZmkKZG9uZQoKIyB2ZXJpZnkgdGhlIGlu
>> "!B64TMP!" echo c3RhbGwtZGlyLnR4dCBoaW50IChib3RoIGNvcGllcykgcG9pbnRzIGF0IHRoZSB0YXJnZXQKaWYg
>> "!B64TMP!" echo WyAiJChjYXQgIiRTS0lMTF9ESVIvaW5zdGFsbC1kaXIudHh0IiAyPi9kZXYvbnVsbCkiID0gIiRU
>> "!B64TMP!" echo R1RfRElSIiBdOyB0aGVuCiAgZWNobyAiICBbT0tdICAgc2tpbGwgaW5zdGFsbC1kaXIudHh0IC0+
>> "!B64TMP!" echo ICRUR1RfRElSIgplbHNlCiAgZWNobyAiICBbRkFJTF0gc2tpbGwgaW5zdGFsbC1kaXIudHh0IGlz
>> "!B64TMP!" echo IHdyb25nOiAkKGNhdCAiJFNLSUxMX0RJUi9pbnN0YWxsLWRpci50eHQiIDI+L2Rldi9udWxsKSIK
>> "!B64TMP!" echo ICBQQVNTPTAKZmkKaWYgWyAiJChjYXQgIiRUR1RfRElSL2xvY2FsLXdlYi9pbnN0YWxsLWRpci50
>> "!B64TMP!" echo eHQiIDI+L2Rldi9udWxsKSIgPSAiJFRHVF9ESVIiIF07IHRoZW4KICBlY2hvICIgIFtPS10gICBi
>> "!B64TMP!" echo dW5kbGVkIGluc3RhbGwtZGlyLnR4dCAtPiAkVEdUX0RJUiIKZWxzZQogIGVjaG8gIiAgW0ZBSUxd
>> "!B64TMP!" echo IGJ1bmRsZWQgaW5zdGFsbC1kaXIudHh0IGlzIHdyb25nOiAkKGNhdCAiJFRHVF9ESVIvbG9jYWwt
>> "!B64TMP!" echo d2ViL2luc3RhbGwtZGlyLnR4dCIgMj4vZGV2L251bGwpIgogIFBBU1M9MApmaQoKIyAtLS0gdmVy
>> "!B64TMP!" echo aWZ5IHRoZSBoaW50IGFjdHVhbGx5IHdvcmtzOiBydW4gY29uZmlnLnB5J3MgZmluZGVyIHN0YW5k
>> "!B64TMP!" echo YWxvbmUgLS0tLS0tCiIkUFkiIC0gIiRUR1RfRElSIiA8PCdQWUVPRicKaW1wb3J0IHN5cywgb3MK
>> "!B64TMP!" echo ZXhwZWN0ZWQgPSBzeXMuYXJndlsxXQojIFNpbXVsYXRlIHRoZSBza2lsbCBiZWluZyBydW4gZnJv
>> "!B64TMP!" echo bSB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi9zY3JpcHRzCnN5cy5wYXRoLmluc2VydCgwLCBv
>> "!B64TMP!" echo cy5wYXRoLmV4cGFuZHVzZXIoIn4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViL3NjcmlwdHMiKSkK
>> "!B64TMP!" echo b3MuZW52aXJvbi5wb3AoIkxPQ0FMX1NFQVJDSF9ESVIiLCBOb25lKQppbXBvcnQgY29uZmlnCmZv
>> "!B64TMP!" echo dW5kID0gY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIoKQppZiBmb3VuZCA9PSBleHBlY3RlZDoKICAg
>> "!B64TMP!" echo IHByaW50KCIgIFtPS10gICBjb25maWcuZmluZF9pbnN0YWxsX2RpcigpIC0+ICVzIChoaW50IHdv
>> "!B64TMP!" echo cmtzKSIgJSBmb3VuZCkKZWxzZToKICAgIHByaW50KCIgIFtGQUlMXSBjb25maWcuZmluZF9pbnN0
>> "!B64TMP!" echo YWxsX2RpcigpIC0+ICVyIChleHBlY3RlZCAlcikiICUgKGZvdW5kLCBleHBlY3RlZCkpCiAgICBz
>> "!B64TMP!" echo eXMuZXhpdCgxKQplcHMgPSBjb25maWcuZW5kcG9pbnRzKGZvdW5kKQppZiBlcHMgPT0geyJzZWFy
>> "!B64TMP!" echo eG5nIjogImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MCIsICJmaXJlY3Jhd2wiOiAiaHR0cDovL2xvY2Fs
>> "!B64TMP!" echo aG9zdDo5OTkxIn06CiAgICBwcmludCgiICBbT0tdICAgZW5kcG9pbnRzIHJlYWQgZnJvbSAuZW52
>> "!B64TMP!" echo OiAlcyIgJSBlcHMpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gZW5kcG9pbnRzIHdyb25nOiAl
>> "!B64TMP!" echo cyIgJSBlcHMpCiAgICBzeXMuZXhpdCgxKQpQWUVPRgpbICQ/ID0gMCBdIHx8IFBBU1M9MAoKIyAt
>> "!B64TMP!" echo LS0gdmVyaWZ5IHdlYl9zZWFyY2gucHkgLyB3ZWJfc2NyYXBlLnB5IHJlc29sdmUgdGhlIGVuZHBv
>> "!B64TMP!" echo aW50cyAtLS0tLS0tLS0tLS0tCiIkUFkiIC0gPDwnUFlFT0YnCmltcG9ydCBzeXMsIG9zCnN5cy5w
>> "!B64TMP!" echo YXRoLmluc2VydCgwLCBvcy5wYXRoLmV4cGFuZHVzZXIoIn4vLmFnZW50cy9za2lsbHMvbG9jYWwt
>> "!B64TMP!" echo d2ViL3NjcmlwdHMiKSkKaW1wb3J0IHdlYl9zZWFyY2gKaWYgd2ViX3NlYXJjaC5CQVNFLmVuZHN3
>> "!B64TMP!" echo aXRoKCI6OTk5MC9zZWFyY2giKToKICAgIHByaW50KCIgIFtPS10gICB3ZWJfc2VhcmNoLkJBU0Ug
>> "!B64TMP!" echo PSAlcyIgJSB3ZWJfc2VhcmNoLkJBU0UpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gd2ViX3Nl
>> "!B64TMP!" echo YXJjaC5CQVNFID0gJXMiICUgd2ViX3NlYXJjaC5CQVNFKQogICAgc3lzLmV4aXQoMSkKaW1wb3J0
>> "!B64TMP!" echo IHdlYl9zY3JhcGUKaWYgd2ViX3NjcmFwZS5FTkRQT0lOVC5lbmRzd2l0aCgiOjk5OTEvdjEvc2Ny
>> "!B64TMP!" echo YXBlIik6CiAgICBwcmludCgiICBbT0tdICAgd2ViX3NjcmFwZS5FTkRQT0lOVCA9ICVzIiAlIHdl
>> "!B64TMP!" echo Yl9zY3JhcGUuRU5EUE9JTlQpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gd2ViX3NjcmFwZS5F
>> "!B64TMP!" echo TkRQT0lOVCA9ICVzIiAlIHdlYl9zY3JhcGUuRU5EUE9JTlQpCiAgICBzeXMuZXhpdCgxKQpQWUVP
>> "!B64TMP!" echo RgpbICQ/ID0gMCBdIHx8IFBBU1M9MAoKIyAtLS0gc2VsZi1oZWFsIHRlc3Q6IHNjcmlwdHMgYXV0
>> "!B64TMP!" echo by1zdGFydCBhIGRvd24gc3RhY2sgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KZWNobwplY2hvICI9
>> "!B64TMP!" echo PT09PSBzZWxmLWhlYWwgdGVzdDogd2ViX3NlYXJjaCAvIHdlYl9zY3JhcGUgc3RhcnQgYSBkb3du
>> "!B64TMP!" echo IHN0YWNrID09PT09IgoKcG9ydHNfZnJlZSgpIHsKICAiJFBZIiAtIDw8J1BZSycKaW1wb3J0IHNv
>> "!B64TMP!" echo Y2tldCwgc3lzCmZvciBwb3J0IGluICg5OTkwLCA5OTkxKToKICAgIHMgPSBzb2NrZXQuc29ja2V0
>> "!B64TMP!" echo KCk7IHMuc2V0dGltZW91dCgwLjMpCiAgICBpZiBzLmNvbm5lY3RfZXgoKCIxMjcuMC4wLjEiLCBw
>> "!B64TMP!" echo b3J0KSkgPT0gMDoKICAgICAgICBzeXMuZXhpdCgxKQogICAgcy5jbG9zZSgpCnN5cy5leGl0KDAp
>> "!B64TMP!" echo ClBZSwp9CgppZiBwb3J0c19mcmVlOyB0aGVuCiAgIyBmYWtlIHN0YWNrOiBhbnN3ZXJzIFNlYXJY
>> "!B64TMP!" echo TkcgSlNPTiBvbiAkMSBhbmQgRmlyZWNyYXdsIHNjcmFwZSBKU09OIG9uICQyCiAgY2F0ID4gIiRU
>> "!B64TMP!" echo RVNUUk9PVC9mYWtlX3N0YWNrLnB5IiA8PCdGQUtFJwppbXBvcnQganNvbiwgb3MsIHN5cywgdGhy
>> "!B64TMP!" echo ZWFkaW5nLCB0aW1lCmZyb20gaHR0cC5zZXJ2ZXIgaW1wb3J0IEJhc2VIVFRQUmVxdWVzdEhhbmRs
>> "!B64TMP!" echo ZXIsIEhUVFBTZXJ2ZXIKZnJvbSB1cmxsaWIucGFyc2UgaW1wb3J0IHVybHBhcnNlLCBwYXJzZV9x
>> "!B64TMP!" echo cwoKU0VBUlhfUE9SVCwgRkNfUE9SVCwgUElERklMRSA9IGludChzeXMuYXJndlsxXSksIGludChz
>> "!B64TMP!" echo eXMuYXJndlsyXSksIHN5cy5hcmd2WzNdCndpdGggb3BlbihQSURGSUxFLCAidyIpIGFzIGZoOgog
>> "!B64TMP!" echo ICAgZmgud3JpdGUoc3RyKG9zLmdldHBpZCgpKSkKCmNsYXNzIFNlYXJ4KEJhc2VIVFRQUmVxdWVz
>> "!B64TMP!" echo dEhhbmRsZXIpOgogICAgZGVmIGRvX0dFVChzZWxmKToKICAgICAgICBxID0gcGFyc2VfcXModXJs
>> "!B64TMP!" echo cGFyc2Uoc2VsZi5wYXRoKS5xdWVyeSkuZ2V0KCJxIiwgWyIiXSlbMF0KICAgICAgICBib2R5ID0g
>> "!B64TMP!" echo anNvbi5kdW1wcyh7InJlc3VsdHMiOiBbewogICAgICAgICAgICAidGl0bGUiOiAiRkFLRSBSRVNV
>> "!B64TMP!" echo TFQgZm9yICIgKyBxLAogICAgICAgICAgICAidXJsIjogImh0dHBzOi8vZXhhbXBsZS5jb20vZmFr
>> "!B64TMP!" echo ZSIsCiAgICAgICAgICAgICJjb250ZW50IjogImZha2Ugc25pcHBldCJ9XX0pLmVuY29kZSgpCiAg
>> "!B64TMP!" echo ICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKDIwMCkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJD
>> "!B64TMP!" echo b250ZW50LVR5cGUiLCAiYXBwbGljYXRpb24vanNvbiIpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRl
>> "!B64TMP!" echo cigiQ29udGVudC1MZW5ndGgiLCBzdHIobGVuKGJvZHkpKSkKICAgICAgICBzZWxmLmVuZF9oZWFk
>> "!B64TMP!" echo ZXJzKCkKICAgICAgICBzZWxmLndmaWxlLndyaXRlKGJvZHkpCiAgICBkZWYgbG9nX21lc3NhZ2Uo
>> "!B64TMP!" echo c2VsZiwgKmEpOiBwYXNzCgpjbGFzcyBGYyhCYXNlSFRUUFJlcXVlc3RIYW5kbGVyKToKICAgIGRl
>> "!B64TMP!" echo ZiBkb19QT1NUKHNlbGYpOgogICAgICAgIGJvZHkgPSBqc29uLmR1bXBzKHsiZGF0YSI6IHsibWFy
>> "!B64TMP!" echo a2Rvd24iOiAiIyBGQUtFIE1BUktET1dOXG5oZWxsbyBmcm9tIGZha2UgZmlyZWNyYXdsIn19KS5l
>> "!B64TMP!" echo bmNvZGUoKQogICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZSgyMDApCiAgICAgICAgc2VsZi5zZW5k
>> "!B64TMP!" echo X2hlYWRlcigiQ29udGVudC1UeXBlIiwgImFwcGxpY2F0aW9uL2pzb24iKQogICAgICAgIHNlbGYu
>> "!B64TMP!" echo c2VuZF9oZWFkZXIoIkNvbnRlbnQtTGVuZ3RoIiwgc3RyKGxlbihib2R5KSkpCiAgICAgICAgc2Vs
>> "!B64TMP!" echo Zi5lbmRfaGVhZGVycygpCiAgICAgICAgc2VsZi53ZmlsZS53cml0ZShib2R5KQogICAgZGVmIGxv
>> "!B64TMP!" echo Z19tZXNzYWdlKHNlbGYsICphKTogcGFzcwoKZm9yIGhhbmRsZXIsIHBvcnQgaW4gKChTZWFyeCwg
>> "!B64TMP!" echo U0VBUlhfUE9SVCksIChGYywgRkNfUE9SVCkpOgogICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9
>> "!B64TMP!" echo SFRUUFNlcnZlcigoIjEyNy4wLjAuMSIsIHBvcnQpLCBoYW5kbGVyKS5zZXJ2ZV9mb3JldmVyLAog
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICBkYWVtb249VHJ1ZSkuc3RhcnQoKQp3aGlsZSBUcnVlOgogICAg
>> "!B64TMP!" echo dGltZS5zbGVlcCgzNjAwKQpGQUtFCgogIEZBS0VfUElERklMRT0iJFRFU1RST09UL2Zha2Vfc3Rh
>> "!B64TMP!" echo Y2sucGlkIgogIGtpbGxfZmFrZV9zdGFjaygpIHsKICAgIGlmIFsgLWYgIiRGQUtFX1BJREZJTEUi
>> "!B64TMP!" echo IF07IHRoZW4KICAgICAga2lsbCAiJChjYXQgIiRGQUtFX1BJREZJTEUiIDI+L2Rldi9udWxsKSIg
>> "!B64TMP!" echo Mj4vZGV2L251bGwKICAgICAgcm0gLWYgIiRGQUtFX1BJREZJTEUiCiAgICBmaQogICAgZm9yIF8g
>> "!B64TMP!" echo aW4gMSAyIDMgNCA1IDYgNyA4IDkgMTA7IGRvCiAgICAgIHBvcnRzX2ZyZWUgJiYgcmV0dXJuIDAK
>> "!B64TMP!" echo ICAgICAgc2xlZXAgMC41CiAgICBkb25lCiAgICByZXR1cm4gMQogIH0KCiAgIyBtb2NrIGRvY2tl
>> "!B64TMP!" echo ciAjMjogYGNvbXBvc2UgdXAgLWRgIHJlYWRzIHRoZSBwb3J0cyBmcm9tIC4vLmVudiBhbmQgc3Rh
>> "!B64TMP!" echo cnRzCiAgIyB0aGUgZmFrZSBzdGFjayAoc28gc2VsZi1oZWFsIGFjdHVhbGx5IGJyaW5ncyB0aGUg
>> "!B64TMP!" echo ZW5kcG9pbnRzIHVwKQogIG1rZGlyIC1wICIkVEVTVFJPT1QvYmluMiIKICBjYXQgPiAiJFRFU1RS
>> "!B64TMP!" echo T09UL2JpbjIvZG9ja2VyIiA8PCdNT0NLMicKIyEvdXNyL2Jpbi9lbnYgYmFzaApjYXNlICIkMSIg
>> "!B64TMP!" echo aW4KICBpbmZvKSBleGl0IDAgOzsKICBjb21wb3NlKQogICAgY2FzZSAiJDIiIGluCiAgICAgIHZl
>> "!B64TMP!" echo cnNpb24pIGVjaG8gIkRvY2tlciBDb21wb3NlIHZlcnNpb24gdjIuMC4wLXRlc3QiOyBleGl0IDAg
>> "!B64TMP!" echo OzsKICAgICAgdXApCiAgICAgICAgU0VBUlhOR19QT1JUPSQoZ3JlcCAtRSAnXlNFQVJYTkdfUE9S
>> "!B64TMP!" echo VD0nIC5lbnYgfCBjdXQgLWQ9IC1mMikKICAgICAgICBGSVJFQ1JBV0xfUE9SVD0kKGdyZXAgLUUg
>> "!B64TMP!" echo J15GSVJFQ1JBV0xfUE9SVD0nIC5lbnYgfCBjdXQgLWQ9IC1mMikKICAgICAgICBub2h1cCAiJEZB
>> "!B64TMP!" echo S0VfUFkiICIkRkFLRV9TVEFDSyIgIiRTRUFSWE5HX1BPUlQiICIkRklSRUNSQVdMX1BPUlQiICIk
>> "!B64TMP!" echo RkFLRV9QSURGSUxFIiA+L2Rldi9udWxsIDI+JjEgJgogICAgICAgIGVjaG8gIlttb2NrXSBjb21w
>> "!B64TMP!" echo b3NlIHVwIG9rIChmYWtlIHN0YWNrIHN0YXJ0ZWQpIgogICAgICAgIGV4aXQgMCA7OwogICAgICAq
>> "!B64TMP!" echo KSBleGl0IDAgOzsKICAgIGVzYWMgOzsKICAqKSBleGl0IDAgOzsKZXNhYwpNT0NLMgogIGNobW9k
>> "!B64TMP!" echo ICt4ICIkVEVTVFJPT1QvYmluMi9kb2NrZXIiCgogICMgbW9jayBkb2NrZXIgIzM6IGBjb21wb3Nl
>> "!B64TMP!" echo IHVwIC1kYCBzdWNjZWVkcyBidXQgc3RhcnRzIE5PVEhJTkcgKGZhaWx1cmUgcGF0aCkKICBta2Rp
>> "!B64TMP!" echo ciAtcCAiJFRFU1RST09UL2JpbjMiCiAgY2F0ID4gIiRURVNUUk9PVC9iaW4zL2RvY2tlciIgPDwn
>> "!B64TMP!" echo TU9DSzMnCiMhL3Vzci9iaW4vZW52IGJhc2gKY2FzZSAiJDEiIGluCiAgaW5mbykgZXhpdCAwIDs7
>> "!B64TMP!" echo CiAgY29tcG9zZSkKICAgIGNhc2UgIiQyIiBpbgogICAgICB2ZXJzaW9uKSBlY2hvICJEb2NrZXIg
>> "!B64TMP!" echo Q29tcG9zZSB2ZXJzaW9uIHYyLjAuMC10ZXN0IjsgZXhpdCAwIDs7CiAgICAgIHVwKSBlY2hvICJb
>> "!B64TMP!" echo bW9ja10gY29tcG9zZSB1cCBvayAobm90aGluZyBhY3R1YWxseSBzdGFydGVkKSI7IGV4aXQgMCA7
>> "!B64TMP!" echo OwogICAgICAqKSBleGl0IDAgOzsKICAgIGVzYWMgOzsKICAqKSBleGl0IDAgOzsKZXNhYwpNT0NL
>> "!B64TMP!" echo MwogIGNobW9kICt4ICIkVEVTVFJPT1QvYmluMy9kb2NrZXIiCgogIEhFQUxfRU5WPSJGQUtFX1BZ
>> "!B64TMP!" echo PSRQWSBGQUtFX1NUQUNLPSRURVNUUk9PVC9mYWtlX3N0YWNrLnB5IEZBS0VfUElERklMRT0kRkFL
>> "!B64TMP!" echo RV9QSURGSUxFIExPQ0FMX1NFQVJDSF9ESVI9JFRHVF9ESVIiCgogICMgUGhhc2UgQSAtIGZhc3Qg
>> "!B64TMP!" echo cGF0aDogc3RhY2sgYWxyZWFkeSB1cCAtPiBzdHJhaWdodCB0byByZXN1bHRzLCBubyBib290CiAg
>> "!B64TMP!" echo bm9odXAgIiRQWSIgIiRURVNUUk9PVC9mYWtlX3N0YWNrLnB5IiA5OTkwIDk5OTEgIiRGQUtFX1BJ
>> "!B64TMP!" echo REZJTEUiID4vZGV2L251bGwgMj4mMSAmCiAgc2xlZXAgMQogIGlmIGVudiAkSEVBTF9FTlYgIiRQ
>> "!B64TMP!" echo WSIgIiRTS0lMTF9ESVIvc2NyaXB0cy93ZWJfc2VhcmNoLnB5IiAiZmFzdCBwYXRoIiBcCiAgICAg
>> "!B64TMP!" echo ICA+ICIkVEVTVFJPT1QvaGVhbEEubG9nIiAyPiYxIFwKICAgICAmJiBncmVwIC1xICJGQUtFIFJF
>> "!B64TMP!" echo U1VMVCBmb3IgZmFzdCBwYXRoIiAiJFRFU1RST09UL2hlYWxBLmxvZyIgXAogICAgICYmICEgZ3Jl
>> "!B64TMP!" echo cCAtcSAic3RhcnRpbmcgaXQgYXV0b21hdGljYWxseSIgIiRURVNUUk9PVC9oZWFsQS5sb2ciOyB0
>> "!B64TMP!" echo aGVuCiAgICBlY2hvICIgIFtPS10gICBmYXN0IHBhdGg6IHNlYXJjaCB3b3JrcyB3aXRoIHRoZSBz
>> "!B64TMP!" echo dGFjayBhbHJlYWR5IHVwIChubyBib290KSIKICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSBmYXN0
>> "!B64TMP!" echo LXBhdGggc2VhcmNoIjsgY2F0ICIkVEVTVFJPT1QvaGVhbEEubG9nIjsgUEFTUz0wCiAgZmkKCiAg
>> "!B64TMP!" echo IyBQaGFzZSBCIC0gc2VsZi1oZWFsOiBzdGFjayBkb3duIC0+IGJvb3QgKG1vY2sgY29tcG9zZSkg
>> "!B64TMP!" echo LT4gcmV0cnkgLT4gcmVzdWx0cwogIGtpbGxfZmFrZV9zdGFjawogIGlmIGVudiAkSEVBTF9FTlYg
>> "!B64TMP!" echo UEFUSD0iJFRFU1RST09UL2JpbjI6JFBBVEgiIFwKICAgICAgICIkUFkiICIkU0tJTExfRElSL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX3NlYXJjaC5weSIgInNlbGZoZWFsIHNlYXJjaCIgXAogICAgICAgPiAiJFRFU1RS
>> "!B64TMP!" echo T09UL2hlYWxCLmxvZyIgMj4mMSBcCiAgICAgJiYgZ3JlcCAtcSAic3RhcnRpbmcgaXQgYXV0b21h
>> "!B64TMP!" echo dGljYWxseSIgIiRURVNUUk9PVC9oZWFsQi5sb2ciIFwKICAgICAmJiBncmVwIC1xICJGQUtFIFJF
>> "!B64TMP!" echo U1VMVCBmb3Igc2VsZmhlYWwgc2VhcmNoIiAiJFRFU1RST09UL2hlYWxCLmxvZyI7IHRoZW4KICAg
>> "!B64TMP!" echo IGVjaG8gIiAgW09LXSAgIHNlbGYtaGVhbDogd2ViX3NlYXJjaCBib290ZWQgdGhlIGRvd24gc3Rh
>> "!B64TMP!" echo Y2sgYW5kIHJldHJpZWQiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gd2ViX3NlYXJjaCBzZWxm
>> "!B64TMP!" echo LWhlYWwiOyBjYXQgIiRURVNUUk9PVC9oZWFsQi5sb2ciOyBQQVNTPTAKICBmaQoKICAjIFBoYXNl
>> "!B64TMP!" echo IEIyIC0gc2VsZi1oZWFsIGZvciB0aGUgc2NyYXBlcgogIGtpbGxfZmFrZV9zdGFjawogIGlmIGVu
>> "!B64TMP!" echo diAkSEVBTF9FTlYgUEFUSD0iJFRFU1RST09UL2JpbjI6JFBBVEgiIFwKICAgICAgICIkUFkiICIk
>> "!B64TMP!" echo U0tJTExfRElSL3NjcmlwdHMvd2ViX3NjcmFwZS5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20vYXJ0
>> "!B64TMP!" echo aWNsZSIgXAogICAgICAgPiAiJFRFU1RST09UL2hlYWxCMi5sb2ciIDI+JjEgXAogICAgICYmIGdy
>> "!B64TMP!" echo ZXAgLXEgInN0YXJ0aW5nIGl0IGF1dG9tYXRpY2FsbHkiICIkVEVTVFJPT1QvaGVhbEIyLmxvZyIg
>> "!B64TMP!" echo XAogICAgICYmIGdyZXAgLXEgIkZBS0UgTUFSS0RPV04iICIkVEVTVFJPT1QvaGVhbEIyLmxvZyI7
>> "!B64TMP!" echo IHRoZW4KICAgIGVjaG8gIiAgW09LXSAgIHNlbGYtaGVhbDogd2ViX3NjcmFwZSBib290ZWQgdGhl
>> "!B64TMP!" echo IGRvd24gc3RhY2sgYW5kIHJldHJpZWQiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gd2ViX3Nj
>> "!B64TMP!" echo cmFwZSBzZWxmLWhlYWwiOyBjYXQgIiRURVNUUk9PVC9oZWFsQjIubG9nIjsgUEFTUz0wCiAgZmkK
>> "!B64TMP!" echo CiAgIyBQaGFzZSBDIC0gZmFpbHVyZTogc3RhY2sgY2Fubm90IGNvbWUgdXAgLT4gY2xlYXIgZ3Vp
>> "!B64TMP!" echo ZGFuY2UsIGV4aXQgMQogIGtpbGxfZmFrZV9zdGFjawogIGlmIGVudiAkSEVBTF9FTlYgUEFUSD0i
>> "!B64TMP!" echo JFRFU1RST09UL2JpbjM6JFBBVEgiIExPQ0FMX1NFQVJDSF9SRUFEWV9USU1FT1VUPTIgXAogICAg
>> "!B64TMP!" echo ICAgIiRQWSIgIiRTS0lMTF9ESVIvc2NyaXB0cy93ZWJfc2VhcmNoLnB5IiAiZG9vbWVkIiBcCiAg
>> "!B64TMP!" echo ICAgICA+ICIkVEVTVFJPT1QvaGVhbEMubG9nIiAyPiYxOyB0aGVuCiAgICBlY2hvICIgIFtGQUlM
>> "!B64TMP!" echo XSBzZWxmLWhlYWwgZmFpbHVyZSBwYXRoIHNob3VsZCBleGl0IG5vbi16ZXJvIjsgUEFTUz0wCiAg
>> "!B64TMP!" echo ZWxpZiBncmVwIC1xICJjb3VsZCBub3QgYmUgc3RhcnRlZCIgIiRURVNUUk9PVC9oZWFsQy5sb2ci
>> "!B64TMP!" echo IFwKICAgICAgICYmIGdyZXAgLXEgImRpZCBub3QgYmVjb21lIHJlYWR5IiAiJFRFU1RST09UL2hl
>> "!B64TMP!" echo YWxDLmxvZyI7IHRoZW4KICAgIGVjaG8gIiAgW09LXSAgIHNlbGYtaGVhbCBmYWlsdXJlOiBjbGVh
>> "!B64TMP!" echo ciBndWlkYW5jZSwgbm9uLXplcm8gZXhpdCIKICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSBzZWxm
>> "!B64TMP!" echo LWhlYWwgZmFpbHVyZSBtZXNzYWdlIG1pc3NpbmciOyBjYXQgIiRURVNUUk9PVC9oZWFsQy5sb2ci
>> "!B64TMP!" echo OyBQQVNTPTAKICBmaQogIGtpbGxfZmFrZV9zdGFjawplbHNlCiAgZWNobyAiICBbV0FSTl0gcG9y
>> "!B64TMP!" echo dHMgOTk5MC85OTkxIGFyZSBpbiB1c2UgLSBza2lwcGluZyB0aGUgc2VsZi1oZWFsIHRlc3QiCmZp
>> "!B64TMP!" echo CgojIC0tLSBub3cgcnVuIHRoZSB1bmluc3RhbGxlciAoa2VlcCBmb2xkZXIpIGFuZCB2ZXJpZnkg
>> "!B64TMP!" echo dGhlIHNraWxsIGlzIHJlbW92ZWQgLS0KZWNobwplY2hvICI9PT09PSBydW5uaW5nIHVuaW5zdGFs
>> "!B64TMP!" echo bGVyIChhbnN3ZXJpbmcgeSwgdGhlbiBuIGZvciBmb2xkZXIgZGVsZXRlKSA9PT09PSIKcHJpbnRm
>> "!B64TMP!" echo ICd5XG5uXG4nIHwgIiRUR1RfRElSL3VuaW5zdGFsbC5zaCIgPiAiJFRFU1RST09UL3VuaW5zdGFs
>> "!B64TMP!" echo bC5sb2ciIDI+JjEKVVJDPSQ/CmVjaG8gIlVuaW5zdGFsbGVyIGV4aXQgY29kZTogJFVSQyIKdGFp
>> "!B64TMP!" echo bCAtMTIgIiRURVNUUk9PVC91bmluc3RhbGwubG9nIgplY2hvICItLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLSIKaWYgWyAhIC1kICIkU0tJTExfRElSIiBdOyB0aGVuCiAgZWNobyAiW09L
>> "!B64TMP!" echo XSB1bmluc3RhbGxlciByZW1vdmVkIHRoZSBza2lsbCBkaXIiCmVsc2UKICBlY2hvICJbRkFJTF0g
>> "!B64TMP!" echo c2tpbGwgZGlyIHN0aWxsIGV4aXN0cyBhZnRlciB1bmluc3RhbGwiCiAgUEFTUz0wCmZpCmlmIFsg
>> "!B64TMP!" echo LWYgIiRUR1RfRElSLy5lbnYiIF0gJiYgWyAtZCAiJFRHVF9ESVIvbG9jYWwtd2ViIiBdOyB0aGVu
>> "!B64TMP!" echo CiAgZWNobyAiW09LXSB1bmluc3RhbGxlciBrZXB0IHRoZSBpbnN0YWxsIGZvbGRlciAoYXMgYW5z
>> "!B64TMP!" echo d2VyZWQpIgplbHNlCiAgZWNobyAiW0ZBSUxdIHVuaW5zdGFsbGVyIGRlbGV0ZWQgdGhlIGluc3Rh
>> "!B64TMP!" echo bGwgZm9sZGVyIGRlc3BpdGUgJ24nIgogIFBBU1M9MApmaQoKZWNobwppZiBbICIkUEFTUyIgPSAx
>> "!B64TMP!" echo IF07IHRoZW4KICBlY2hvICI9PT09PT09PT09PT09PT09PT09PT09PT0gIEFMTCBURVNUUyBQQVNT
>> "!B64TMP!" echo RUQgID09PT09PT09PT09PT09PT09PT09PT09PSIKICBleGl0IDAKZmkKZWNobyAiPT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09ICBURVNUUyBGQUlMRUQgID09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PSIKZXhpdCAxCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\e2e_test.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- zip_test.sh ---
set "B64TMP=%TEMP%\LSR1237637422.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFZlcmlmeSBsb2NhbC1zZWFyY2guemlwOiBleHRyYWN0IGl0
>> "!B64TMP!" echo IGludG8gYSBjbGVhbiB0ZW1wIGRpciwgcnVuIHRoZSAuc2gKIyBpbnN0YWxsZXIgRlJPTSB0aGUg
>> "!B64TMP!" echo ZXh0cmFjdGVkIGZvbGRlciAoYWxsIHNvdXJjZXMgcHJlc2VudCksIGFuZCBjaGVjayB0aGUKIyBy
>> "!B64TMP!" echo ZXN1bHQgKGluY2wuIHRoZSBsb2NhbC13ZWIgc2tpbGwpLiBOZWVkczogdW56aXAgKyBweXRob24z
>> "!B64TMP!" echo LgojIEFueSBwcmUtZXhpc3Rpbmcgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIgaXMgYmFja2Vk
>> "!B64TMP!" echo IHVwIGFuZCByZXN0b3JlZC4Kc2V0IC11CgpST09UPSIkKGNkICIkKGRpcm5hbWUgIiQwIikiICYm
>> "!B64TMP!" echo IHB3ZCkiClpJUD0iJFJPT1QvbG9jYWwtc2VhcmNoLnppcCIKVEVTVFJPT1Q9IiRST09ULy56aXAt
>> "!B64TMP!" echo dGVzdC0kJCIKU0tJTExfRElSPSIkSE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIiClNLSUxM
>> "!B64TMP!" echo X0JBSz0iIgoKUFk9IiQoY29tbWFuZCAtdiBweXRob24zIHx8IGNvbW1hbmQgLXYgcHl0aG9uKSIK
>> "!B64TMP!" echo WyAteiAiJFBZIiBdICYmIHsgZWNobyAiW0VSUk9SXSBweXRob24gcmVxdWlyZWQgZm9yIHRoaXMg
>> "!B64TMP!" echo dGVzdC4iID4mMjsgZXhpdCAxOyB9CgpjbGVhbnVwKCkgewogIHJjPSQ/CiAgcm0gLXJmICIkU0tJ
>> "!B64TMP!" echo TExfRElSIiAyPi9kZXYvbnVsbAogIGlmIFsgLW4gIiRTS0lMTF9CQUsiIF0gJiYgWyAtZCAiJFNL
>> "!B64TMP!" echo SUxMX0JBSyIgXTsgdGhlbgogICAgbXYgIiRTS0lMTF9CQUsiICIkU0tJTExfRElSIiAyPi9kZXYv
>> "!B64TMP!" echo bnVsbAogIGZpCiAgaWYgWyAiJHJjIiA9IDAgXTsgdGhlbiBybSAtcmYgIiRURVNUUk9PVCI7IGZp
>> "!B64TMP!" echo Cn0KdHJhcCBjbGVhbnVwIEVYSVQKClsgLWYgIiRaSVAiIF0gfHwgeyBlY2hvICJbRVJST1JdICRa
>> "!B64TMP!" echo SVAgbm90IGZvdW5kIC0gcnVuIGJ1aWxkLnNoIGZpcnN0LiIgPiYyOyBleGl0IDE7IH0KY29tbWFu
>> "!B64TMP!" echo ZCAtdiB1bnppcCA+L2Rldi9udWxsIDI+JjEgfHwgeyBlY2hvICJbRVJST1JdIHVuemlwIG5vdCBm
>> "!B64TMP!" echo b3VuZC4iID4mMjsgZXhpdCAxOyB9Cgpta2RpciAtcCAiJFRFU1RST09UIgpjZCAiJFRFU1RST09U
>> "!B64TMP!" echo Igp1bnppcCAtcSAiJFpJUCIKZWNobyAiRXh0cmFjdGVkIHppcCBjb250ZW50czoiCmZpbmQgbG9j
>> "!B64TMP!" echo YWwtc2VhcmNoIC10eXBlIGYgfCBzb3J0CmVjaG8KCiMgQmFjayB1cCBhbnkgcmVhbCBza2lsbCBp
>> "!B64TMP!" echo bnN0YWxsIHNvIHRoZSB0ZXN0IGNhbiBuZXZlciBkZXN0cm95IGl0LgppZiBbIC1kICIkU0tJTExf
>> "!B64TMP!" echo RElSIiBdOyB0aGVuCiAgU0tJTExfQkFLPSIkVEVTVFJPT1Qvc2tpbGwtYmFja3VwIgogIG12ICIk
>> "!B64TMP!" echo U0tJTExfRElSIiAiJFNLSUxMX0JBSyIKZmkKCiMgLS0tIG1vY2sgZG9ja2VyIHNvIHRoZSBpbnN0
>> "!B64TMP!" echo YWxsZXIncyBjaGVja3MgcGFzcyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCk1PQ0tCSU49
>> "!B64TMP!" echo IiRURVNUUk9PVC9iaW4iCm1rZGlyIC1wICIkTU9DS0JJTiIKY2F0ID4gIiRNT0NLQklOL2RvY2tl
>> "!B64TMP!" echo ciIgPDwnTU9DSycKIyEvdXNyL2Jpbi9lbnYgYmFzaApjYXNlICIkMSIgaW4KICBpbmZvKSAgZXhp
>> "!B64TMP!" echo dCAwIDs7CiAgY29tcG9zZSkKICAgIGNhc2UgIiQyIiBpbgogICAgICB2ZXJzaW9uKSBlY2hvICJE
>> "!B64TMP!" echo b2NrZXIgQ29tcG9zZSB2Mi4wLjAtdGVzdCI7IGV4aXQgMCA7OwogICAgICBwdWxsfHVwKSBlY2hv
>> "!B64TMP!" echo ICJbbW9ja10gb2siOyBleGl0IDAgOzsKICAgICAgKikgZXhpdCAwIDs7CiAgICBlc2FjIDs7CiAg
>> "!B64TMP!" echo KikgZXhpdCAwIDs7CmVzYWMKTU9DSwpjaG1vZCAreCAiJE1PQ0tCSU4vZG9ja2VyIgpleHBvcnQg
>> "!B64TMP!" echo UEFUSD0iJE1PQ0tCSU46JFBBVEgiCgojIC0tLSBydW4gdGhlIGluc3RhbGxlciBmcm9tIHRoZSBl
>> "!B64TMP!" echo eHRyYWN0ZWQgZm9sZGVyIChmdWxsIHNvdXJjZSBwcmVzZW50KSAtLS0tLS0KVEdUPSIkVEVTVFJP
>> "!B64TMP!" echo T1QvaW5zdGFsbGVkIgpwcmludGYgJyVzXG4lc1xuJXNcbiVzXG4lc1xuJyAiJFRHVCIgIiIgIiIg
>> "!B64TMP!" echo Im4iICJ5IiBcCiAgfCAiJFRFU1RST09UL2xvY2FsLXNlYXJjaC9pbnN0YWxsLWxvY2FsLXNlYXJj
>> "!B64TMP!" echo aC5zaCIgPiAiJFRFU1RST09UL2luc3RhbGwubG9nIiAyPiYxClJDPSQ/CmVjaG8gIkluc3RhbGxl
>> "!B64TMP!" echo ciBleGl0IGNvZGU6ICRSQyIKdGFpbCAtMTAgIiRURVNUUk9PVC9pbnN0YWxsLmxvZyIKZWNobyAi
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IgoKIyAtLS0gdmVyaWZ5
>> "!B64TMP!" echo IHRoZSBpbnN0YWxsIGZvbGRlciAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tClBBU1M9MQpmb3IgZiBpbiBkb2NrZXItY29tcG9zZS55bWwgLmVudi5leGFtcGxl
>> "!B64TMP!" echo IC5lbnYgUkVBRE1FLm1kIExJQ0VOU0UgLmdpdGlnbm9yZSAuZ2l0YXR0cmlidXRlcyBcCiAgICAg
>> "!B64TMP!" echo ICAgIGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbCBcCiAgICAgICAgIFJ1bi5iYXQgU3RvcC5i
>> "!B64TMP!" echo YXQgVXBkYXRlLmJhdCBVbmluc3RhbGwuYmF0IFwKICAgICAgICAgcnVuLnNoIHN0b3Auc2ggdXBk
>> "!B64TMP!" echo YXRlLnNoIHVuaW5zdGFsbC5zaCBcCiAgICAgICAgIGxvY2FsLXdlYi9TS0lMTC5tZCBsb2NhbC13
>> "!B64TMP!" echo ZWIvTElDRU5TRSBcCiAgICAgICAgIGxvY2FsLXdlYi9zY3JpcHRzL2NvbmZpZy5weSBsb2NhbC13
>> "!B64TMP!" echo ZWIvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkgXAogICAgICAgICBsb2NhbC13ZWIvc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfc2VhcmNoLnB5IGxvY2FsLXdlYi9zY3JpcHRzL3dlYl9zY3JhcGUucHkgXAogICAgICAgICBp
>> "!B64TMP!" echo bnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQgaW5zdGFsbC1sb2NhbC1zZWFyY2guc2g7IGRvCiAgaWYg
>> "!B64TMP!" echo WyAtcyAiJFRHVC8kZiIgXTsgdGhlbgogICAgZWNobyAiICBbT0tdICRmIgogIGVsc2UKICAgIGVj
>> "!B64TMP!" echo aG8gIiAgW0ZBSUxdICRmIChtaXNzaW5nL2VtcHR5KSI7IFBBU1M9MAogIGZpCmRvbmUKCmlmIGdy
>> "!B64TMP!" echo ZXAgLXEgJ19fU0VBUlhOR19TRUNSRVRfUExBQ0VIT0xERVJfXycgIiRUR1QvY29uZmlnL3NlYXJ4
>> "!B64TMP!" echo bmcvc2V0dGluZ3MueW1sIjsgdGhlbgogIGVjaG8gIltGQUlMXSBzZXR0aW5ncy55bWwgc3RpbGwg
>> "!B64TMP!" echo aGFzIHBsYWNlaG9sZGVyIjsgUEFTUz0wCmVsc2UKICBlY2hvICJbT0tdIHNldHRpbmdzLnltbCBz
>> "!B64TMP!" echo ZWNyZXQgaW5qZWN0ZWQiCmZpCgppZiBbICIkKGNhdCAiJFNLSUxMX0RJUi9pbnN0YWxsLWRpci50
>> "!B64TMP!" echo eHQiIDI+L2Rldi9udWxsKSIgPSAiJFRHVCIgXTsgdGhlbgogIGVjaG8gIltPS10gc2tpbGwgaW5z
>> "!B64TMP!" echo dGFsbGVkIHdpdGggY29ycmVjdCBpbnN0YWxsLWRpci50eHQgaGludCIKZWxzZQogIGVjaG8gIltG
>> "!B64TMP!" echo QUlMXSBza2lsbCBpbnN0YWxsLWRpci50eHQgd3Jvbmc6ICQoY2F0ICIkU0tJTExfRElSL2luc3Rh
>> "!B64TMP!" echo bGwtZGlyLnR4dCIgMj4vZGV2L251bGwpIgogIFBBU1M9MApmaQoKY21wIC1zICIkVEdUL2luc3Rh
>> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLmJhdCIgIiRST09UL2xvY2FsLXNlYXJjaC9pbnN0YWxsLWxvY2FsLXNl
>> "!B64TMP!" echo YXJjaC5iYXQiIFwKICAmJiBlY2hvICJbT0tdIC5iYXQgcmVwcm9kdWNlZCBieXRlLWlkZW50aWNh
>> "!B64TMP!" echo bCIgXAogIHx8IHsgZWNobyAiW0ZBSUxdIC5iYXQgZGlmZmVycyI7IFBBU1M9MDsgfQoKZWNobwpp
>> "!B64TMP!" echo ZiBbICIkUEFTUyIgPSAxIF0gJiYgWyAiJFJDIiA9IDAgXTsgdGhlbgogIGVjaG8gIj09PT09PT09
>> "!B64TMP!" echo IEZVTEwtWklQIEVYVFJBQ1RJT04gVEVTVDogUEFTU0VEID09PT09PT09IgogIGV4aXQgMApmaQpl
>> "!B64TMP!" echo Y2hvICI9PT09PT09PSBGVUxMLVpJUCBFWFRSQUNUSU9OIFRFU1Q6IEZBSUxFRCA9PT09PT09PSIK
>> "!B64TMP!" echo ZXhpdCAxCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\zip_test.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- selfhost_test.sh ---
set "B64TMP=%TEMP%\LSR3712939713.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFNlbGYtaG9zdGluZyB0ZXN0IGZvciB0aGUgcmlnIHBhY2tl
>> "!B64TMP!" echo cnM6CiMgICAxLiBSdW4gbG9jYWwtc2VhcmNoLXJpZy5zaCBpbnRvIGEgY2xlYW4gZm9sZGVyIChv
>> "!B64TMP!" echo bmx5IHRoZSBwYWNrZXIgcHJlc2VudCkuCiMgICAyLiBWZXJpZnkgdGhlIHVucGFja2VkIHJpZyBp
>> "!B64TMP!" echo cyBjb21wbGV0ZSBhbmQgYnl0ZS1pZGVudGljYWwgdG8gdGhlIHNvdXJjZS4KIyAgIDMuIFJlZ2Vu
>> "!B64TMP!" echo ZXJhdGUgdGhlIHBhY2tlcnMgaW5zaWRlIHRoZSB1bnBhY2tlZCByaWcgKHB5dGhvbjMgZ2VuX3Jp
>> "!B64TMP!" echo Zy5weSkKIyAgICAgIGFuZCBjb21wYXJlIHRoZW0gQllURS1GT1ItQllURSB3aXRoIHRoZSBvcmln
>> "!B64TMP!" echo aW5hbHMuCiMgICA0LiBSZWdlbmVyYXRlIHRoZSBpbnN0YWxsZXJzIHRvbyBhbmQgY29tcGFyZS4K
>> "!B64TMP!" echo c2V0IC11ClJPT1Q9IiQoY2QgIiQoZGlybmFtZSAiJDAiKSIgJiYgcHdkKSIKVEVTVFJPT1Q9IiRS
>> "!B64TMP!" echo T09ULy5yaWctdGVzdC0kJCIKbWtkaXIgLXAgIiRURVNUUk9PVCIKCmNsZWFudXAoKSB7IHJjPSQ/
>> "!B64TMP!" echo OyBpZiBbICIkcmMiID0gMCBdOyB0aGVuIHJtIC1yZiAiJFRFU1RST09UIjsgZWxzZSBlY2hvICIo
>> "!B64TMP!" echo a2VwdCAkVEVTVFJPT1QgZm9yIGRlYnVnZ2luZykiOyBmaTsgfQp0cmFwIGNsZWFudXAgRVhJVAoK
>> "!B64TMP!" echo ZWNobyAiPT09IDEuIHVucGFjayBsb2NhbC1zZWFyY2gtcmlnLnNoIChvbmx5IHRoZSBwYWNrZXIg
>> "!B64TMP!" echo ZmlsZSBwcmVzZW50KSA9PT0iCm1rZGlyIC1wICIkVEVTVFJPT1Qvc3JjIgpjcCAiJFJPT1QvbG9j
>> "!B64TMP!" echo YWwtc2VhcmNoLXJpZy5zaCIgIiRURVNUUk9PVC9zcmMvIgpjaG1vZCAreCAiJFRFU1RST09UL3Ny
>> "!B64TMP!" echo Yy9sb2NhbC1zZWFyY2gtcmlnLnNoIgojIGFuc3dlcnM6IHRhcmdldCBmb2xkZXIsIGJ1aWxkIG5v
>> "!B64TMP!" echo dz8gLT4gbiAod2UgYnVpbGQgbWFudWFsbHkgbGF0ZXIpLCBwcm9jZWVkIC0+IHkKcHJpbnRmICcl
>> "!B64TMP!" echo c1xuJXNcbiVzXG4nICIkVEVTVFJPT1QvcmlnIiAibiIgInkiIFwKICB8ICIkVEVTVFJPT1Qvc3Jj
>> "!B64TMP!" echo L2xvY2FsLXNlYXJjaC1yaWcuc2giID4gIiRURVNUUk9PVC91bnBhY2subG9nIiAyPiYxClJDPSQ/
>> "!B64TMP!" echo CmVjaG8gInBhY2tlciBleGl0IGNvZGU6ICRSQyIKdGFpbCAtOCAiJFRFU1RST09UL3VucGFjay5s
>> "!B64TMP!" echo b2ciClsgIiRSQyIgPSAwIF0gfHwgZXhpdCAxCmVjaG8KCmVjaG8gIj09PSAyLiB1bnBhY2tlZCBy
>> "!B64TMP!" echo aWcgY29udGVudHMgPT09IgpmaW5kICIkVEVTVFJPT1QvcmlnIiAtdHlwZSBmIHwgc29ydAplY2hv
>> "!B64TMP!" echo CgpQQVNTPTEKZWNobyAiPT09IDMuIGJ5dGUtY29tcGFyZSB1bnBhY2tlZCByaWcgdnMgc291cmNl
>> "!B64TMP!" echo IHJpZyA9PT0iCgpjaGVja19maWxlKCkgewogIGlmIFsgISAtZiAiJFRFU1RST09UL3JpZy8kMSIg
>> "!B64TMP!" echo XTsgdGhlbgogICAgZWNobyAiICBbRkFJTF0gbWlzc2luZyBpbiB1bnBhY2tlZCByaWc6ICQxIjsg
>> "!B64TMP!" echo UEFTUz0wOyByZXR1cm4KICBmaQogIGlmIGNtcCAtcyAiJFJPT1QvJDEiICIkVEVTVFJPT1Qvcmln
>> "!B64TMP!" echo LyQxIjsgdGhlbgogICAgZWNobyAiICBbT0tdICAgJDEiCiAgZWxzZQogICAgIyAuYmF0IGZpbGVz
>> "!B64TMP!" echo IGFyZSBhbGxvd2VkIENSTEY8LT5MRiBkaWZmZXJlbmNlcyBvbmx5IGlmIExGLW5vcm1hbGlzZWQg
>> "!B64TMP!" echo ZXF1YWwKICAgIGE9JCh0ciAtZCAnXHInIDwgIiRST09ULyQxIiB8IG1kNXN1bSB8IGN1dCAtZCcg
>> "!B64TMP!" echo JyAtZjEpCiAgICBiPSQodHIgLWQgJ1xyJyA8ICIkVEVTVFJPT1QvcmlnLyQxIiB8IG1kNXN1bSB8
>> "!B64TMP!" echo IGN1dCAtZCcgJyAtZjEpCiAgICBpZiBbICIkYSIgPSAiJGIiIF0gJiYgWyAiJChtZDVzdW0gPCAi
>> "!B64TMP!" echo JFJPT1QvJDEiIHwgY3V0IC1kJyAnIC1mMSkiICE9ICIkYSIgXTsgdGhlbgogICAgICBlY2hvICIg
>> "!B64TMP!" echo IFtPS10gICAkMSAgKENSTEYgcmVzdG9yZWQpIgogICAgZWxzZQogICAgICBlY2hvICIgIFtGQUlM
>> "!B64TMP!" echo XSAkMSBkaWZmZXJzIjsgUEFTUz0wCiAgICBmaQogIGZpCn0KCmZvciBmIGluIGNvbmZpZy9zZWFy
>> "!B64TMP!" echo eG5nL3NldHRpbmdzLnltbCBkb2NrZXItY29tcG9zZS55bWwgLmVudi5leGFtcGxlIFJFQURNRS5t
>> "!B64TMP!" echo ZCBcCiAgICAgICAgIExJQ0VOU0UgLmdpdGlnbm9yZSAuZ2l0YXR0cmlidXRlcyBcCiAgICAgICAg
>> "!B64TMP!" echo IFJ1bi5iYXQgU3RvcC5iYXQgVXBkYXRlLmJhdCBVbmluc3RhbGwuYmF0IFwKICAgICAgICAgcnVu
>> "!B64TMP!" echo LnNoIHN0b3Auc2ggdXBkYXRlLnNoIHVuaW5zdGFsbC5zaCBcCiAgICAgICAgIGxvY2FsLXdlYi9T
>> "!B64TMP!" echo S0lMTC5tZCBsb2NhbC13ZWIvTElDRU5TRSBcCiAgICAgICAgIGxvY2FsLXdlYi9zY3JpcHRzL2Nv
>> "!B64TMP!" echo bmZpZy5weSBsb2NhbC13ZWIvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkgXAogICAgICAgICBsb2Nh
>> "!B64TMP!" echo bC13ZWIvc2NyaXB0cy93ZWJfc2VhcmNoLnB5IGxvY2FsLXdlYi9zY3JpcHRzL3dlYl9zY3JhcGUu
>> "!B64TMP!" echo cHk7IGRvCiAgY2hlY2tfZmlsZSAibG9jYWwtc2VhcmNoLyRmIgpkb25lCiMgTk9URTogbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoL2luc3RhbGwtbG9jYWwtc2VhcmNoLiogYXJlIGludGVudGlvbmFsbHkgTk9UIHVucGFj
>> "!B64TMP!" echo a2VkIGJ5CiMgdGhlIHBhY2tlciAodGhleSBhcmUgZ2VuZXJhdGVkIGFydGlmYWN0cykgLSB0aGV5
>> "!B64TMP!" echo IGFyZSB2ZXJpZmllZCBpbiBzdGVwIDUuCgpmb3IgZiBpbiBnZW5faW5zdGFsbGVycy5weSBnZW5f
>> "!B64TMP!" echo cmlnLnB5IHRlc3RfYjY0LnB5IHRlc3RfaGVyZWRvY3MucHkgdGVzdF9yaWcucHkgXAogICAgICAg
>> "!B64TMP!" echo ICBlMmVfdGVzdC5zaCB6aXBfdGVzdC5zaCBidWlsZC5zaCBidWlsZC5iYXQgQlVJTEQubWQgXAog
>> "!B64TMP!" echo ICAgICAgICBsb2NhbC1zZWFyY2gtcmlnLmJhdCBsb2NhbC1zZWFyY2gtcmlnLnNoOyBkbwogIGNo
>> "!B64TMP!" echo ZWNrX2ZpbGUgIiRmIgpkb25lCgojIC5iYXQgZmlsZXMgdW5wYWNrZWQgYnkgdGhlIC5zaCBwYWNr
>> "!B64TMP!" echo ZXIgbXVzdCBoYXZlIENSTEYgZW5kaW5ncwpmb3IgZiBpbiBsb2NhbC1zZWFyY2gvUnVuLmJhdCBs
>> "!B64TMP!" echo b2NhbC1zZWFyY2gvVXBkYXRlLmJhdCBsb2NhbC1zZWFyY2gtcmlnLmJhdCBidWlsZC5iYXQ7IGRv
>> "!B64TMP!" echo CiAgaWYgZ3JlcCAtcSAkJ1xyJyAiJFRFU1RST09UL3JpZy8kZiIgMj4vZGV2L251bGw7IHRoZW4K
>> "!B64TMP!" echo ICAgIGVjaG8gIiAgW09LXSAgICRmIGhhcyBDUkxGIgogIGVsc2UKICAgIGVjaG8gIiAgW0ZBSUxd
>> "!B64TMP!" echo ICRmIGxhY2tzIENSTEYiOyBQQVNTPTAKICBmaQpkb25lCmVjaG8KCmVjaG8gIj09PSA0LiBTRUxG
>> "!B64TMP!" echo LUhPU1RJTkc6IHJlZ2VuZXJhdGUgcGFja2VycyBpbnNpZGUgdW5wYWNrZWQgcmlnID09PSIKaWYg
>> "!B64TMP!" echo KGNkICIkVEVTVFJPT1QvcmlnIiAmJiBweXRob24zIGdlbl9yaWcucHkpOyB0aGVuCiAgaWYgY21w
>> "!B64TMP!" echo IC1zICIkUk9PVC9sb2NhbC1zZWFyY2gtcmlnLnNoIiAiJFRFU1RST09UL3JpZy9sb2NhbC1zZWFy
>> "!B64TMP!" echo Y2gtcmlnLnNoIjsgdGhlbgogICAgZWNobyAiICBbT0tdIGxvY2FsLXNlYXJjaC1yaWcuc2ggcmVn
>> "!B64TMP!" echo ZW5lcmF0ZWQgQllURS1JREVOVElDQUwiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoLXJpZy5zaCBkaWZmZXJzIGFmdGVyIHJlZ2VuZXJhdGlvbiI7IFBBU1M9MAogIGZpCiAg
>> "!B64TMP!" echo aWYgY21wIC1zICIkUk9PVC9sb2NhbC1zZWFyY2gtcmlnLmJhdCIgIiRURVNUUk9PVC9yaWcvbG9j
>> "!B64TMP!" echo YWwtc2VhcmNoLXJpZy5iYXQiOyB0aGVuCiAgICBlY2hvICIgIFtPS10gbG9jYWwtc2VhcmNoLXJp
>> "!B64TMP!" echo Zy5iYXQgcmVnZW5lcmF0ZWQgQllURS1JREVOVElDQUwiCiAgZWxzZQogICAgZWNobyAiICBbRkFJ
>> "!B64TMP!" echo TF0gbG9jYWwtc2VhcmNoLXJpZy5iYXQgZGlmZmVycyBhZnRlciByZWdlbmVyYXRpb24iOyBQQVNT
>> "!B64TMP!" echo PTAKICBmaQplbHNlCiAgZWNobyAiICBbRkFJTF0gZ2VuX3JpZy5weSBmYWlsZWQgaW4gdW5wYWNr
>> "!B64TMP!" echo ZWQgcmlnIjsgUEFTUz0wCmZpCmVjaG8KCmVjaG8gIj09PSA1LiByZWdlbmVyYXRlIGluc3RhbGxl
>> "!B64TMP!" echo cnMgaW5zaWRlIHVucGFja2VkIHJpZyA9PT0iCmlmIChjZCAiJFRFU1RST09UL3JpZyIgJiYgcHl0
>> "!B64TMP!" echo aG9uMyBnZW5faW5zdGFsbGVycy5weSk7IHRoZW4KICBpZiBjbXAgLXMgIiRST09UL2xvY2FsLXNl
>> "!B64TMP!" echo YXJjaC9pbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCIgIiRURVNUUk9PVC9yaWcvbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo L2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIjsgdGhlbgogICAgZWNobyAiICBbT0tdIGluc3RhbGwt
>> "!B64TMP!" echo bG9jYWwtc2VhcmNoLnNoIHJlZ2VuZXJhdGVkIEJZVEUtSURFTlRJQ0FMIgogIGVsc2UKICAgIGVj
>> "!B64TMP!" echo aG8gIiAgW0ZBSUxdIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGRpZmZlcnMiOyBQQVNTPTAKICBm
>> "!B64TMP!" echo aQogIGlmIGNtcCAtcyAiJFJPT1QvbG9jYWwtc2VhcmNoL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJh
>> "!B64TMP!" echo dCIgIiRURVNUUk9PVC9yaWcvbG9jYWwtc2VhcmNoL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCI7
>> "!B64TMP!" echo IHRoZW4KICAgIGVjaG8gIiAgW09LXSBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQgcmVnZW5lcmF0
>> "!B64TMP!" echo ZWQgQllURS1JREVOVElDQUwiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gaW5zdGFsbC1sb2Nh
>> "!B64TMP!" echo bC1zZWFyY2guYmF0IGRpZmZlcnMiOyBQQVNTPTAKICBmaQplbHNlCiAgZWNobyAiICBbRkFJTF0g
>> "!B64TMP!" echo Z2VuX2luc3RhbGxlcnMucHkgZmFpbGVkIGluIHVucGFja2VkIHJpZyI7IFBBU1M9MApmaQplY2hv
>> "!B64TMP!" echo CgplY2hvICI9PT0gNi4gdmVyaWZ5IHRlc3Qgc3VpdGUgcGFzc2VzIGluc2lkZSB0aGUgdW5wYWNr
>> "!B64TMP!" echo ZWQgcmlnID09PSIKaWYgKGNkICIkVEVTVFJPT1QvcmlnIiAmJiBweXRob24zIHRlc3RfcmlnLnB5
>> "!B64TMP!" echo ID4gL2Rldi9udWxsIDI+JjEpOyB0aGVuCiAgZWNobyAiICBbT0tdIHRlc3RfcmlnLnB5IHBhc3Nl
>> "!B64TMP!" echo cyBpbiB1bnBhY2tlZCByaWciCmVsc2UKICBlY2hvICIgIFtGQUlMXSB0ZXN0X3JpZy5weSBmYWls
>> "!B64TMP!" echo cyBpbiB1bnBhY2tlZCByaWciOyBQQVNTPTAKZmkKCmVjaG8KaWYgWyAiJFBBU1MiID0gMSBdOyB0
>> "!B64TMP!" echo aGVuCiAgZWNobyAiPT09PT09PT09PT09PT09PT0gIFNFTEYtSE9TVElORyBURVNUOiBQQVNTRUQg
>> "!B64TMP!" echo ID09PT09PT09PT09PT09PT09IgogIGV4aXQgMApmaQplY2hvICI9PT09PT09PT09PT09PT09PSAg
>> "!B64TMP!" echo U0VMRi1IT1NUSU5HIFRFU1Q6IEZBSUxFRCAgPT09PT09PT09PT09PT09PT0iCmV4aXQgMQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\selfhost_test.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- build.sh ---
set "B64TMP=%TEMP%\LSR4217998108.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIEJ1aWxkICsgdGVzdCBldmVyeXRoaW5nIGluIHRoZSBsb2Nh
>> "!B64TMP!" echo bC1zZWFyY2ggZGV2IHJpZy4KIyAgIDEuIHJlZ2VuZXJhdGUgdGhlIHR3byBpbnN0YWxsZXJzICAg
>> "!B64TMP!" echo ICAgICAoZ2VuX2luc3RhbGxlcnMucHkpCiMgICAyLiBzeW50YXgtY2hlY2sgKyB2ZXJpZnkgZW1i
>> "!B64TMP!" echo ZWRkZWQgZmlsZXMgKHRlc3RfYjY0LnB5IC8gdGVzdF9oZXJlZG9jcy5weSkKIyAgIDMuIGZ1bGwg
>> "!B64TMP!" echo aW5zdGFsbC91bmluc3RhbGwgZTJlIHRlc3QgICAgICAoZTJlX3Rlc3Quc2gsIG1vY2tlZCBkb2Nr
>> "!B64TMP!" echo ZXIpCiMgICA0LiByZWdlbmVyYXRlIHRoZSByaWcgcGFja2VycyAgICAgICAgICAgKGdlbl9yaWcu
>> "!B64TMP!" echo cHkpICsgdmVyaWZ5ICh0ZXN0X3JpZy5weSkKIyAgIDUuIGJ1aWxkIGxvY2FsLXNlYXJjaC56aXAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAoKyB6aXBfdGVzdC5zaCB3aGVuIHVuemlwIGV4aXN0cykKc2V0IC11CmNk
>> "!B64TMP!" echo ICIkKGRpcm5hbWUgIiQwIikiIHx8IGV4aXQgMQoKUFk9IiQoY29tbWFuZCAtdiBweXRob24zIHx8
>> "!B64TMP!" echo IGNvbW1hbmQgLXYgcHl0aG9uKSIKaWYgWyAteiAiJFBZIiBdOyB0aGVuCiAgZWNobyAiW0VSUk9S
>> "!B64TMP!" echo XSBweXRob24zIChvciBweXRob24pIG5vdCBmb3VuZCBvbiBQQVRILiIgPiYyCiAgZXhpdCAxCmZp
>> "!B64TMP!" echo CgplY2hvICI9PSBbMS82XSBHZW5lcmF0aW5nIGluc3RhbGxlcnMgKGdlbl9pbnN0YWxsZXJzLnB5
>> "!B64TMP!" echo KSA9PSIKIiRQWSIgZ2VuX2luc3RhbGxlcnMucHkgfHwgZXhpdCAxCgplY2hvICI9PSBbMi82XSBi
>> "!B64TMP!" echo YXNoIHN5bnRheCBjaGVjayA9PSIKYmFzaCAtbiBsb2NhbC1zZWFyY2gvaW5zdGFsbC1sb2NhbC1z
>> "!B64TMP!" echo ZWFyY2guc2ggfHwgewogIGVjaG8gIltGQUlMXSBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCBoYXMg
>> "!B64TMP!" echo YmFzaCBzeW50YXggZXJyb3JzIiA+JjI7IGV4aXQgMTsgfQplY2hvICIgIHN5bnRheCBPSyIKCmVj
>> "!B64TMP!" echo aG8gIj09IFszLzZdIEVtYmVkZGVkLWZpbGUgdGVzdHMgPT0iCiIkUFkiIHRlc3RfYjY0LnB5IHx8
>> "!B64TMP!" echo IGV4aXQgMQoiJFBZIiB0ZXN0X2hlcmVkb2NzLnB5IHx8IGV4aXQgMQoKZWNobyAiPT0gWzQvNl0g
>> "!B64TMP!" echo RW5kLXRvLWVuZCBpbnN0YWxsIHRlc3QgKG1vY2tlZCBkb2NrZXIpID09IgpiYXNoIGUyZV90ZXN0
>> "!B64TMP!" echo LnNoIHx8IGV4aXQgMQoKZWNobyAiPT0gWzUvNl0gUmVnZW5lcmF0aW5nIHJpZyBwYWNrZXJzIChn
>> "!B64TMP!" echo ZW5fcmlnLnB5KSA9PSIKIiRQWSIgZ2VuX3JpZy5weSB8fCBleGl0IDEKIiRQWSIgdGVzdF9yaWcu
>> "!B64TMP!" echo cHkgfHwgZXhpdCAxCmlmIGJhc2ggc2VsZmhvc3RfdGVzdC5zaDsgdGhlbiA6OyBlbHNlCiAgZWNo
>> "!B64TMP!" echo byAiW0ZBSUxdIHNlbGYtaG9zdGluZyB0ZXN0IGZhaWxlZCIgPiYyOyBleGl0IDEKZmkKCmVjaG8g
>> "!B64TMP!" echo Ij09IFs2LzZdIEJ1aWxkaW5nIGxvY2FsLXNlYXJjaC56aXAgPT0iCnJtIC1mIGxvY2FsLXNlYXJj
>> "!B64TMP!" echo aC56aXAKaWYgY29tbWFuZCAtdiB6aXAgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgemlwIC1yIGxv
>> "!B64TMP!" echo Y2FsLXNlYXJjaC56aXAgbG9jYWwtc2VhcmNoLyAteCAnbG9jYWwtc2VhcmNoLy5naXQvKicgJyov
>> "!B64TMP!" echo X19weWNhY2hlX18vKicgPiAvZGV2L251bGwgfHwgZXhpdCAxCiAgZWNobyAiICBsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2guemlwIGJ1aWx0LiIKICBpZiBjb21tYW5kIC12IHVuemlwID4vZGV2L251bGwgMj4mMTsgdGhl
>> "!B64TMP!" echo bgogICAgYmFzaCB6aXBfdGVzdC5zaCB8fCBleGl0IDEKICBmaQplbHNlCiAgZWNobyAiICBbV0FS
>> "!B64TMP!" echo TklOR10gJ3ppcCcgbm90IGZvdW5kIC0gc2tpcHBpbmcgemlwIChpbnN0YWxsZXJzIGFyZSB1bmFm
>> "!B64TMP!" echo ZmVjdGVkKS4iCmZpCgplY2hvCmVjaG8gIkFMTCBHUkVFTi4gQXJ0aWZhY3RzOiIKZWNobyAiICBs
>> "!B64TMP!" echo b2NhbC1zZWFyY2gvaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IC8gLnNoICAgPC0gdGhlIGluc3Rh
>> "!B64TMP!" echo bGxlcnMiCmVjaG8gIiAgbG9jYWwtc2VhcmNoLXJpZy5iYXQgLyBsb2NhbC1zZWFyY2gtcmlnLnNo
>> "!B64TMP!" echo ICAgIDwtIHRoZSBkZXYtcmlnIHBhY2tlcnMiCmVjaG8gIiAgbG9jYWwtc2VhcmNoLnppcCAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgIDwtIHJlcG8gc25hcHNob3QgZm9yIEdpdEh1YiIK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\build.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- build.bat ---
set "B64TMP=%TEMP%\LSR1572216162.b64"
> "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
>> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCBEZXYgUmlnIC0gQnVpbGQNCg0KY2QgL2QgIiV+ZHAwIg0K
>> "!B64TMP!" echo DQpzZXQgIlBZPSINCnB5IC0zIC1jICJwcmludCgxKSIgPm51bCAyPiYxDQppZiBub3QgZXJyb3Js
>> "!B64TMP!" echo ZXZlbCAxIHNldCAiUFk9cHkgLTMiDQppZiBub3QgZGVmaW5lZCBQWSAoDQogIHB5dGhvbiAtYyAi
>> "!B64TMP!" echo cHJpbnQoMSkiID5udWwgMj4mMQ0KICBpZiBub3QgZXJyb3JsZXZlbCAxIHNldCAiUFk9cHl0aG9u
>> "!B64TMP!" echo Ig0KKQ0KaWYgbm90IGRlZmluZWQgUFkgKA0KICBweXRob24zIC1jICJwcmludCgxKSIgPm51bCAy
>> "!B64TMP!" echo PiYxDQogIGlmIG5vdCBlcnJvcmxldmVsIDEgc2V0ICJQWT1weXRob24zIg0KKQ0KaWYgbm90IGRl
>> "!B64TMP!" echo ZmluZWQgUFkgKA0KICBlY2hvIFtFUlJPUl0gUHl0aG9uIG5vdCBmb3VuZCBeKHB5IC8gcHl0aG9u
>> "!B64TMP!" echo IC8gcHl0aG9uM14pLiBJbnN0YWxsIFB5dGhvbiAzLjgrIGZpcnN0Lg0KICBwYXVzZQ0KICBleGl0
>> "!B64TMP!" echo IC9iIDENCikNCg0KZWNobyA9PSBbMS8zXSBHZW5lcmF0aW5nIGluc3RhbGxlcnMgPT0NCiVQWSUg
>> "!B64TMP!" echo Z2VuX2luc3RhbGxlcnMucHkNCmlmIGVycm9ybGV2ZWwgMSAoIGVjaG8gW0VSUk9SXSBnZW5faW5z
>> "!B64TMP!" echo dGFsbGVycy5weSBmYWlsZWQuICYgcGF1c2UgJiBleGl0IC9iIDEgKQ0KDQplY2hvID09IFsyLzNd
>> "!B64TMP!" echo IEVtYmVkZGVkLWZpbGUgdGVzdHMgPT0NCiVQWSUgdGVzdF9iNjQucHkNCmlmIGVycm9ybGV2ZWwg
>> "!B64TMP!" echo MSAoIGVjaG8gW0VSUk9SXSB0ZXN0X2I2NC5weSBmYWlsZWQuICYgcGF1c2UgJiBleGl0IC9iIDEg
>> "!B64TMP!" echo KQ0KJVBZJSB0ZXN0X2hlcmVkb2NzLnB5DQppZiBlcnJvcmxldmVsIDEgKCBlY2hvIFtFUlJPUl0g
>> "!B64TMP!" echo dGVzdF9oZXJlZG9jcy5weSBmYWlsZWQuICYgcGF1c2UgJiBleGl0IC9iIDEgKQ0KDQplY2hvID09
>> "!B64TMP!" echo IFszLzNdIFJlZ2VuZXJhdGluZyByaWcgcGFja2VycyA9PQ0KJVBZJSBnZW5fcmlnLnB5DQppZiBl
>> "!B64TMP!" echo cnJvcmxldmVsIDEgKCBlY2hvIFtFUlJPUl0gZ2VuX3JpZy5weSBmYWlsZWQuICYgcGF1c2UgJiBl
>> "!B64TMP!" echo eGl0IC9iIDEgKQ0KJVBZJSB0ZXN0X3JpZy5weQ0KaWYgZXJyb3JsZXZlbCAxICggZWNobyBbRVJS
>> "!B64TMP!" echo T1JdIHRlc3RfcmlnLnB5IGZhaWxlZC4gJiBwYXVzZSAmIGV4aXQgL2IgMSApDQoNCmlmIGV4aXN0
>> "!B64TMP!" echo IGxvY2FsLXNlYXJjaC56aXAgZGVsIGxvY2FsLXNlYXJjaC56aXANCnRhciAtYSAtYyAtZiBsb2Nh
>> "!B64TMP!" echo bC1zZWFyY2guemlwIGxvY2FsLXNlYXJjaCA+bnVsIDI+JjENCmlmIG5vdCBleGlzdCBsb2NhbC1z
>> "!B64TMP!" echo ZWFyY2guemlwICgNCiAgcG93ZXJzaGVsbCAtTm9Qcm9maWxlIC1Db21tYW5kICJDb21wcmVzcy1B
>> "!B64TMP!" echo cmNoaXZlIC1QYXRoICdsb2NhbC1zZWFyY2gnIC1EZXN0aW5hdGlvblBhdGggJ2xvY2FsLXNlYXJj
>> "!B64TMP!" echo aC56aXAnIiA+bnVsIDI+JjENCikNCmlmIGV4aXN0IGxvY2FsLXNlYXJjaC56aXAgKA0KICBlY2hv
>> "!B64TMP!" echo ICAgbG9jYWwtc2VhcmNoLnppcCBidWlsdC4NCikgZWxzZSAoDQogIGVjaG8gICBbV0FSTklOR10g
>> "!B64TMP!" echo Y291bGQgbm90IGJ1aWxkIGxvY2FsLXNlYXJjaC56aXAgXihubyB0YXIgLyBDb21wcmVzcy1BcmNo
>> "!B64TMP!" echo aXZlXikuDQopDQoNCmVjaG8uDQplY2hvIEFMTCBHUkVFTi4gQXJ0aWZhY3RzOg0KZWNobyAgIGxv
>> "!B64TMP!" echo Y2FsLXNlYXJjaFxpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQgLyAuc2ggICAgIHRoZSBpbnN0YWxs
>> "!B64TMP!" echo ZXJzDQplY2hvICAgbG9jYWwtc2VhcmNoLXJpZy5iYXQgLyBsb2NhbC1zZWFyY2gtcmlnLnNoICAg
>> "!B64TMP!" echo ICAgdGhlIGRldi1yaWcgcGFja2Vycw0KZWNobyAgIGxvY2FsLXNlYXJjaC56aXAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIHJlcG8gc25hcHNob3QNCmVjaG8uDQplY2hvIE5vdGU6IHRo
>> "!B64TMP!" echo ZSBiYXNoLWJhc2VkIGUyZSAvIHNlbGZob3N0IHRlc3RzIGRvIG5vdCBydW4gaGVyZS4gVXNlIEdp
>> "!B64TMP!" echo dCBCYXNoOg0KZWNobyAgIGJhc2ggZTJlX3Rlc3Quc2gNCmVjaG8uDQpwYXVzZQ0KZXhpdCAvYiAw
>> "!B64TMP!" echo DQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\build.bat"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- BUILD.md ---
set "B64TMP=%TEMP%\LSR1980376622.b64"
> "!B64TMP!" echo IyDwn5SnIExvY2FsIFNlYXJjaCDigJQgZGV2ZWxvcGVyIHJpZwoKVGhpcyBmb2xkZXIgaXMgdGhl
>> "!B64TMP!" echo IGNvbXBsZXRlIGJ1aWxkICsgdGVzdCBlbnZpcm9ubWVudCBmb3IgdGhlCioqbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo KiogaW5zdGFsbGVycy4gRXZlcnl0aGluZyByZWdlbmVyYXRlcyBmcm9tIGhlcmUuCgojIyBMYXlv
>> "!B64TMP!" echo dXQKCmBgYApsb2NhbC1zZWFyY2gvICAgICAgICAgICAgICAgICAgdGhlIHByb2R1Y3QgKHNvdXJj
>> "!B64TMP!" echo ZSBvZiB0cnV0aCDigJQgZWRpdCBmcmVlbHkpCiAgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0ICAg
>> "!B64TMP!" echo ICDihpAgR0VORVJBVEVEIGJ5IGdlbl9pbnN0YWxsZXJzLnB5IOKAlCBkbyBub3QgZWRpdAogIGlu
>> "!B64TMP!" echo c3RhbGwtbG9jYWwtc2VhcmNoLnNoICAgICAg4oaQIEdFTkVSQVRFRCBieSBnZW5faW5zdGFsbGVy
>> "!B64TMP!" echo cy5weSDigJQgZG8gbm90IGVkaXQKICAuLi4gICAgICAgICAgICAgICAgICAgICAgICAgIOKGkCAy
>> "!B64TMP!" echo MSBzb3VyY2UgZmlsZXMgKGNvbXBvc2UsIHNjcmlwdHMsIHNraWxsLCBkb2NzKQpnZW5faW5zdGFs
>> "!B64TMP!" echo bGVycy5weSAgICAgICAgICAgICAgcmVhZHMgbG9jYWwtc2VhcmNoLyDihpIgd3JpdGVzIHRoZSB0
>> "!B64TMP!" echo d28gaW5zdGFsbGVycwpnZW5fcmlnLnB5ICAgICAgICAgICAgICAgICAgICAgcmVhZHMgbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoLyArIHRoaXMgcmlnIOKGkiB3cml0ZXMgdGhlIHR3byBwYWNrZXJzCmV4dHJhY3QtZW1i
>> "!B64TMP!" echo ZWRkZWQucHkgICAgICAgICAgICBwdWxsIGFsbCBlbWJlZGRlZCBmaWxlcyBvdXQgb2YgYW55IHNp
>> "!B64TMP!" echo bmdsZSAuc2ggYXJ0aWZhY3QKdGVzdF9iNjQucHkgICAgICAgICAgICAgICAgICAgIGV2ZXJ5IGZp
>> "!B64TMP!" echo bGUgZW1iZWRkZWQgaW4gdGhlIC5iYXQgaW5zdGFsbGVyIHJvdW5kLXRyaXBzCnRlc3RfaGVyZWRv
>> "!B64TMP!" echo Y3MucHkgICAgICAgICAgICAgICBldmVyeSBmaWxlIGVtYmVkZGVkIGluIHRoZSAuc2ggaW5zdGFs
>> "!B64TMP!" echo bGVyIG1hdGNoZXMKdGVzdF9yaWcucHkgICAgICAgICAgICAgICAgICAgIGJvdGggcmlnIHBhY2tl
>> "!B64TMP!" echo cnMgZW1iZWQgdGhlIGN1cnJlbnQgZmlsZXMgZXhhY3RseQplMmVfdGVzdC5zaCAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgaW5zdGFsbCDihpIgc2tpbGwg4oaSIHNlbGYtaGVhbCDihpIgdW5pbnN0YWxsICht
>> "!B64TMP!" echo b2NrZWQgZG9ja2VyICsgZmFrZSBzdGFjaykKemlwX3Rlc3Quc2ggICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo IGV4dHJhY3QgbG9jYWwtc2VhcmNoLnppcCBhbmQgaW5zdGFsbCBmcm9tIGl0CnNlbGZob3N0X3Rl
>> "!B64TMP!" echo c3Quc2ggICAgICAgICAgICAgICB1bnBhY2sgYSBwYWNrZXIgYWxvbmUg4oaSIHJlZ2VuZXJhdGUg
>> "!B64TMP!" echo 4oaSIGJ5dGUtY29tcGFyZQpidWlsZC5zaCAvIGJ1aWxkLmJhdCAgICAgICAgICAgcmVnZW5lcmF0
>> "!B64TMP!" echo ZSBldmVyeXRoaW5nICsgcnVuIGFsbCB0ZXN0cyArIGJ1aWxkIHRoZSB6aXAKQlVJTEQubWQgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgIHRoaXMgZmlsZQpgYGAKCiMjIFF1aWNrIHN0YXJ0CgpMaW51eCAv
>> "!B64TMP!" echo IG1hY09TIC8gR2l0IEJhc2g6CgpgYGBiYXNoCmJhc2ggYnVpbGQuc2gKYGBgCgpXaW5kb3dzOgoK
>> "!B64TMP!" echo YGBgYmF0CmJ1aWxkLmJhdApgYGAKCmBidWlsZC5zaGAgcnVucyB0aGUgZnVsbCBwaXBlbGluZTog
>> "!B64TMP!" echo Z2VuZXJhdGUgaW5zdGFsbGVycyDihpIgdmVyaWZ5IGVtYmVkcyDihpIKZTJlIGluc3RhbGwgdGVz
>> "!B64TMP!" echo dCDihpIgcmVnZW5lcmF0ZSB0aGUgcGFja2VycyDihpIgdmVyaWZ5IHBhY2tlcnMg4oaSIHNlbGYt
>> "!B64TMP!" echo aG9zdGluZwp0ZXN0ICh1bnBhY2sgYSBwYWNrZXIgYWxvbmUsIHJlZ2VuZXJhdGUsIGJ5dGUtY29t
>> "!B64TMP!" echo cGFyZSkg4oaSIGJ1aWxkICsgcmUtdGVzdAp0aGUgemlwLiBgYnVpbGQuYmF0YCBkb2VzIHRoZSBz
>> "!B64TMP!" echo YW1lIG1pbnVzIHRoZSBiYXNoLW9ubHkgZTJlL3NlbGZob3N0IHRlc3RzCihydW4gYGJhc2ggZTJl
>> "!B64TMP!" echo X3Rlc3Quc2hgIC8gYGJhc2ggc2VsZmhvc3RfdGVzdC5zaGAgZnJvbSBHaXQgQmFzaCBpZiB5b3Ug
>> "!B64TMP!" echo d2FudAp0aGVtIG9uIFdpbmRvd3MpLgoKIyMgV29ya2Zsb3cgYWZ0ZXIgZWRpdGluZyBhbnl0aGlu
>> "!B64TMP!" echo ZwoKMS4gRWRpdCBhbnkgZmlsZSB1bmRlciBgbG9jYWwtc2VhcmNoL2AgKG9yIGFueSByaWcgc2Ny
>> "!B64TMP!" echo aXB0KS4KMi4gUnVuIGBiYXNoIGJ1aWxkLnNoYCAob3IgYGJ1aWxkLmJhdGApLgozLiBBcnRpZmFj
>> "!B64TMP!" echo dHM6CiAgIC0gYGxvY2FsLXNlYXJjaC9pbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXRgIC8gYC5zaGAg
>> "!B64TMP!" echo 4oCUIHRoZSBzZWxmLWNvbnRhaW5lZCBpbnN0YWxsZXJzCiAgIC0gYGxvY2FsLXNlYXJjaC1yaWcu
>> "!B64TMP!" echo YmF0YCAvIGBsb2NhbC1zZWFyY2gtcmlnLnNoYCDigJQgdGhlIHNlbGYtY29udGFpbmVkIGRldi1y
>> "!B64TMP!" echo aWcgcGFja2VycwogICAtIGBsb2NhbC1zZWFyY2guemlwYCDigJQgcmVwbyBzbmFwc2hvdCBmb3Ig
>> "!B64TMP!" echo R2l0SHViCgojIyBUaGUgcGFja2VycwoKYGxvY2FsLXNlYXJjaC1yaWcuYmF0YCBhbmQgYGxvY2Fs
>> "!B64TMP!" echo LXNlYXJjaC1yaWcuc2hgIGVtYmVkIHRoZSAqKmVudGlyZSByaWcqKiDigJQKdGhlIGxvY2FsLXNl
>> "!B64TMP!" echo YXJjaCBzb3VyY2UgdHJlZSwgZXZlcnkgZ2VuZXJhdG9yL3Rlc3QvYnVpbGQgc2NyaXB0LCB0aGlz
>> "!B64TMP!" echo IGZpbGUsCmFuZCAoaW4gdGhlIGAuc2hgKSB0aGUgYC5iYXRgIHBhY2tlciBpdHNlbGYuIFRoYXQg
>> "!B64TMP!" echo bWVhbnMgKiplaXRoZXIgb25lIGZpbGUKYWxvbmUqKiByZXByb2R1Y2VzIHRoZSBjb21wbGV0ZSBk
>> "!B64TMP!" echo ZXYgZW52aXJvbm1lbnQsIGluY2x1ZGluZyBib3RoIHBhY2tlcnM6CgpgYGBiYXNoCmNobW9kICt4
>> "!B64TMP!" echo IGxvY2FsLXNlYXJjaC1yaWcuc2gKLi9sb2NhbC1zZWFyY2gtcmlnLnNoICAgICAgICAjIGFza3Mg
>> "!B64TMP!" echo Zm9yIGEgZm9sZGVyLCB1bnBhY2tzLCBvcHRpb25hbGx5IGJ1aWxkcwpgYGAKClRoZXkgYXJlICoq
>> "!B64TMP!" echo c2VsZi1ob3N0aW5nKio6IGFmdGVyIHVucGFja2luZywgYHB5dGhvbjMgZ2VuX3JpZy5weWAgcmVn
>> "!B64TMP!" echo ZW5lcmF0ZXMKYm90aCBwYWNrZXJzIGJ5dGUtZm9yLWJ5dGUgKHZlcmlmaWVkIGJ5IHRoZSBidWls
>> "!B64TMP!" echo ZCBwaXBlbGluZSBhbmQgYnkKYHNlbGZob3N0X3Rlc3Quc2hgLCB3aGljaCB1bnBhY2tzIGEgcGFj
>> "!B64TMP!" echo a2VyIGludG8gYSBjbGVhbiBmb2xkZXIgYW5kIHByb3ZlcwpyZWdlbmVyYXRpb24gaXMgZXhhY3Qp
>> "!B64TMP!" echo LiBUaGUgZ2VuZXJhdGVkIGluc3RhbGxlcnMgdGhlbXNlbHZlcyBhcmUgTk9UIGVtYmVkZGVkIOKA
>> "!B64TMP!" echo lApydW4gdGhlIGJ1aWxkICh0aGUgcGFja2VyIG9mZmVycykgb3IgYHB5dGhvbjMgZ2VuX2luc3Rh
>> "!B64TMP!" echo bGxlcnMucHlgIHRvIGNyZWF0ZQp0aGVtIGZyZXNoLgoKIyMgTWFudWFsIGNvbW1hbmRzCgpgYGBi
>> "!B64TMP!" echo YXNoCnB5dGhvbjMgZ2VuX2luc3RhbGxlcnMucHkgICAgIyByZWJ1aWxkIGp1c3QgdGhlIHR3byBp
>> "!B64TMP!" echo bnN0YWxsZXJzCnB5dGhvbjMgZ2VuX3JpZy5weSAgICAgICAgICAgIyByZWJ1aWxkIGp1c3QgdGhl
>> "!B64TMP!" echo IHR3byBwYWNrZXJzCnB5dGhvbjMgdGVzdF9iNjQucHkgICAgICAgICAgIyB2ZXJpZnkgLmJhdCBp
>> "!B64TMP!" echo bnN0YWxsZXIgZW1iZWRzCnB5dGhvbjMgdGVzdF9oZXJlZG9jcy5weSAgICAgIyB2ZXJpZnkgLnNo
>> "!B64TMP!" echo IGluc3RhbGxlciBlbWJlZHMKcHl0aG9uMyB0ZXN0X3JpZy5weSAgICAgICAgICAjIHZlcmlmeSBw
>> "!B64TMP!" echo YWNrZXIgZW1iZWRzCmJhc2ggZTJlX3Rlc3Quc2ggICAgICAgICAgICAgIyBpbnN0YWxsL3VuaW5z
>> "!B64TMP!" echo dGFsbCArIHNlbGYtaGVhbCB0ZXN0IChtb2NrZWQgZG9ja2VyKQpiYXNoIHppcF90ZXN0LnNoICAg
>> "!B64TMP!" echo ICAgICAgICAgICMgemlwIGV4dHJhY3Rpb24gdGVzdCAobmVlZHMgdW56aXApCmJhc2ggc2VsZmhv
>> "!B64TMP!" echo c3RfdGVzdC5zaCAgICAgICAgIyB1bnBhY2sgYSBwYWNrZXIgYWxvbmUg4oaSIHJlZ2VuZXJhdGUg
>> "!B64TMP!" echo 4oaSIGJ5dGUtY29tcGFyZQpgYGAKCiMjIFNpbmdsZS1maWxlIHJlY292ZXJ5IChubyBEb2NrZXIg
>> "!B64TMP!" echo bmVlZGVkKQoKTG9zdCBldmVyeXRoaW5nIGV4Y2VwdCBvbmUgYC5zaGAgYXJ0aWZhY3Q/IGBleHRy
>> "!B64TMP!" echo YWN0LWVtYmVkZGVkLnB5YCBwdWxscyBldmVyeQplbWJlZGRlZCBmaWxlIG91dCBvZiBpdCDigJQg
>> "!B64TMP!" echo aXQgb25seSBwYXJzZXMgdGhlIHF1b3RlZCBoZXJlZG9jcywgbm90aGluZyBpcwpleGVjdXRlZDoK
>> "!B64TMP!" echo CmBgYGJhc2gKIyBmcm9tIHRoZSByaWcgcGFja2VyOiByZWNvdmVycyB0aGUgQ09NUExFVEUgcmln
>> "!B64TMP!" echo ICgzNCBmaWxlcykKcHl0aG9uMyBleHRyYWN0LWVtYmVkZGVkLnB5IGxvY2FsLXNlYXJjaC1yaWcu
>> "!B64TMP!" echo c2ggcmlnCiMgdGhlbiByZWdlbmVyYXRlIGV2ZXJ5dGhpbmc6CmNkIHJpZyAmJiBweXRob24zIGdl
>> "!B64TMP!" echo bl9pbnN0YWxsZXJzLnB5ICYmIHB5dGhvbjMgZ2VuX3JpZy5weQoKIyBmcm9tIHRoZSBpbnN0YWxs
>> "!B64TMP!" echo ZXI6IHJlY292ZXJzIHRoZSBsb2NhbC1zZWFyY2gvIHNvdXJjZXMgKyB0aGUgLmJhdCBpbnN0YWxs
>> "!B64TMP!" echo ZXIKcHl0aG9uMyBleHRyYWN0LWVtYmVkZGVkLnB5IGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGxv
>> "!B64TMP!" echo Y2FsLXNlYXJjaAojIGFkZCB0aGUgcmlnIHNjcmlwdHMgKHZpc2libGUgaW4gdGhlIHJlcG8pIG5l
>> "!B64TMP!" echo eHQgdG8gaXQgYW5kIHJlZ2VuZXJhdGUuCmBgYAoKVGhlIGAuc2hgIGZpbGUgeW91IGV4dHJhY3Rl
>> "!B64TMP!" echo ZCBmcm9tIGlzIG5ldmVyIGVtYmVkZGVkIGluIGl0c2VsZiDigJQgY29weSBpdCBvdmVyCm1hbnVh
>> "!B64TMP!" echo bGx5IGlmIHlvdSB3YW50IGl0IGluIHRoZSByZWNvdmVyZWQgdHJlZS4KCiMjIENvbnZlbnRpb25z
>> "!B64TMP!" echo CgotICoqTGluZSBlbmRpbmdzOioqIGAuYmF0YCBzb3VyY2VzIGFyZSBDUkxGOyBgLnNoYCAvIGAu
>> "!B64TMP!" echo cHlgIC8gYC5tZGAgLyBgLnltbGAKICBhcmUgTEYuIFRoZSBgLnNoYCBwYWNrZXIgbm9ybWFsaXpl
>> "!B64TMP!" echo cyB0byBMRiBpbnNpZGUgaXRzIGhlcmVkb2NzIGFuZCByZXN0b3JlcwogIENSTEYgZm9yIGV2ZXJ5
>> "!B64TMP!" echo IGAqLmJhdGAgb24gdW5wYWNrICh2aWEgYXdrLCBzbyBpdCBhbHNvIHdvcmtzIG9uIG1hY09TKS4K
>> "!B64TMP!" echo LSAqKmJhc2ggMy4yIHNhZmU6KiogYWxsIHNoZWxsIHNjcmlwdHMgYXZvaWQgYCR7dmFyLCx9YCwg
>> "!B64TMP!" echo YHNlZCAtaWAsIGFuZAogIEdOVS1vbmx5IHNlZCBlc2NhcGVzLCBzbyB0aGV5IHJ1biBvbiB0aGUg
>> "!B64TMP!" echo bWFjT1MgZGVmYXVsdCBzaGVsbC4gQ2FzZS1mb2xkaW5nCiAgZ29lcyB0aHJvdWdoIHRoZSBgbG93
>> "!B64TMP!" echo ZXIoKWAgaGVscGVyIChgdHIgJ1s6dXBwZXI6XScgJ1s6bG93ZXI6XSdgKS4KLSAqKlNhZmUgdGVz
>> "!B64TMP!" echo dHM6KiogYGUyZV90ZXN0LnNoYCBhbmQgYHppcF90ZXN0LnNoYCBiYWNrIHVwIGFuZCByZXN0b3Jl
>> "!B64TMP!" echo CiAgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViYCBpZiB5b3UgaGF2ZSBhIHJlYWwgaW5zdGFs
>> "!B64TMP!" echo bCDigJQgdGhleSBuZXZlcgogIGRlc3Ryb3kgaXQuIFRlc3QgZm9sZGVycyAoYC5scy10ZXN0LSpg
>> "!B64TMP!" echo LCBgLnppcC10ZXN0LSpgKSBhcmUgcmVtb3ZlZCBvbgogIHN1Y2Nlc3MgYW5kIGtlcHQgb24gZmFp
>> "!B64TMP!" echo bHVyZSBmb3IgZGVidWdnaW5nLgotICoqTW9ja2VkIGRvY2tlcjoqKiB0aGUgZTJlIHRlc3RzIHB1
>> "!B64TMP!" echo dCBhIGZha2UgYGRvY2tlcmAgb24gUEFUSCwgc28gdGhleSBydW4KICB0aGUgZnVsbCBpbnN0YWxs
>> "!B64TMP!" echo IGxvZ2ljIHdpdGhvdXQgdG91Y2hpbmcgYSByZWFsIERvY2tlciBkYWVtb24uCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\BUILD.md"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM Keep a copy of this packer in the target so the rig is complete.
copy /Y "%~f0" "!TARGET!\local-search-rig.bat" >nul 2>&1
echo   Done - 33 files + this packer.

if /i not "!BUILDNOW!"=="n" (
  set "PY="
  py -3 -c "print(1)" >nul 2>&1
  if not errorlevel 1 set "PY=py -3"
  if not defined PY (
    python -c "print(1)" >nul 2>&1
    if not errorlevel 1 set "PY=python"
  )
  if not defined PY (
    python3 -c "print(1)" >nul 2>&1
    if not errorlevel 1 set "PY=python3"
  )
  if not defined PY (
    echo.
    echo   [WARNING] Python not found - skipping the build.
    echo   Install Python 3.8+, then run build.bat in the target folder.
  ) else (
    echo.
    echo Building installers with !PY! ...
    pushd "!TARGET!"
    !PY! gen_installers.py
    if errorlevel 1 (
      popd
      echo   [ERROR] gen_installers.py failed.
      pause
      exit /b 1
    )
    popd
    echo   Installers written to !TARGET!\local-search\
  )
)

echo.
echo ============================================================
echo   Dev rig ready: !TARGET!
echo.
echo   Next steps ^(see BUILD.md inside^):
echo     build.bat                     rebuild installers + packers + tests
echo     python gen_installers.py      rebuild just the installers
echo     python gen_rig.py             rebuild these packers
echo ============================================================
echo.
pause
exit /b 0

:decode_b64
REM  %env:LS_B64_IN% = .b64 temp file, %env:LS_B64_OUT% = output path
powershell -NoProfile -Command "$in=$env:LS_B64_IN; $out=$env:LS_B64_OUT; [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String(((Get-Content -Raw $in) -replace '\s','')))"
exit /b 0
EOF_LOCAL_SEARCH_RIG_BAT

# Keep a copy of this packer in the target so the rig is complete.
cp -f "$0" "$TARGET/local-search-rig.sh"
chmod +x "$TARGET"/*.sh "$TARGET"/local-search/*.sh 2>/dev/null || true

# Restore CRLF line endings for every .bat file (the heredocs above
# wrote LF; awk is used instead of sed so this also works on macOS).
find "$TARGET" -type f -name '*.bat' 2>/dev/null | while IFS= read -r f; do
  awk '{sub(/\r$/,""); printf "%s\r\n", $0}' "$f" > "$f.crlf" 2>/dev/null \
    && mv "$f.crlf" "$f" || rm -f "$f.crlf"
done

ok "Unpacked the dev rig into: $TARGET"

if [ "$(lower "${BUILDNOW:-y}")" != "n" ]; then
  PY="$(command -v python3 || command -v python)"
  if [ -n "$PY" ]; then
    say "Building installers with $PY ..."
    if (cd "$TARGET" && "$PY" gen_installers.py); then
      say "  Installers written to $TARGET/local-search/"
    else
      err "gen_installers.py failed - see output above."
    fi
  else
    say "  ${YELLOW}[WARNING]${RESET} Python not found - skipping the build."
    say "  Install Python 3.8+, then run ./build.sh in the target folder."
  fi
fi

echo
say "${GREEN}============================================================${RESET}"
say "${GREEN}  Dev rig ready: $TARGET${RESET}"
echo
say "  Next steps (see BUILD.md inside):"
say "    ./build.sh                    rebuild installers + packers + tests"
say "    python3 gen_installers.py     rebuild just the installers"
say "    python3 gen_rig.py            rebuild these packers"
say "${GREEN}============================================================${RESET}"
